import Foundation

struct Options {
    let debug: Bool
    let colored: Bool
    let jobserver: String
    let arch: String?
}

guard CommandLine.argc >= 4 else {
    print("Usage: \(CommandLine.arguments[0]) <colored: 0|1> </path/to/jobserver/socket|-> [arch]")
    exit(EX_USAGE)
}

@discardableResult
func check<T: SignedInteger>(_ code: T, _ fn: String, file: StaticString = #file, line: Int = #line) -> T {
    if code < 0 {
        perror("Error: \(fn)() failed at \(file):\(line) (errno=\(errno))")
        exit(1)
    }
    return code
}

let options = Options(
    debug: ProcessInfo.processInfo.environment["DEBUG_OUTPUT"] != nil,
    colored: CommandLine.arguments[1] == "1",
    jobserver: CommandLine.arguments[2],
    arch: CommandLine.arguments[3]
)

var jobserver = options.jobserver
var sfd: Int32?
if jobserver != "-" {
    let socketFD = check(socket(AF_UNIX, SOCK_STREAM, 0), "socket")
    var addr = sockaddr_un()
    addr.sun_family = .init(AF_UNIX)
    addr.sun_len = .init(jobserver.utf8.count)
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        jobserver.withUTF8 {
            UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(start: sunPath, count: 1))
                .copyMemory(from: UnsafeRawBufferPointer($0))
        }
    }
    let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
    check(withUnsafePointer(to: &addr) {
        connect(socketFD, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), addrLen)
    }, "connect")
    sfd = socketFD
}

func outputPrint(_ message: String, terminator: String = "\n") {
    if let sfd = sfd {
        var combined = "\(message)\(terminator)"
        combined.withUTF8 { bytes in
            withUnsafePointer(to: bytes.count) {
                let buf = UnsafeBufferPointer(start: $0, count: 1)
                let rawBuf = UnsafeRawBufferPointer(buf)
                check(send(sfd, rawBuf.baseAddress!, rawBuf.count, 0), "send")
            }
            check(send(sfd, bytes.baseAddress!, bytes.count, 0), "send")
        }
    } else {
        print(message, terminator: terminator)
    }
}

func debugPrint(_ message: Any) {
    guard options.debug else { return }
    print("\(message)")
}

enum Format {
    enum Color: Int {
        case red = 1
        case green = 2
        case yellow = 3
        case blue = 4
        case magenta = 5
        case cyan = 6
    }

    case notice
    case making
    case stage(Color)
    case warning
    case error

    func apply(to message: String) -> String {
        func format(_ string: String) -> String { options.colored ? "\u{001B}[\(string)": "" }
        switch self {
        case .notice:
            return "\(format("0;36m"))==> \(format("1;36m"))Notice:\(format("m")) \(message)"
        case .making:
            return "\(format("1;31m"))> \(format("1;3;39m"))\(message)…\(format("m"))"
        case .stage(let color):
            return "\(format("0;3\(color.rawValue)m"))==> \(format("1;39m"))\(message)…\(format("m"))"
        case .warning:
            return "\(format("0;33m"))==> \(format("1;33m"))Warning:\(format("m")) \(message)"
        case .error:
            return "\(format("0;31m"))==> \(format("1;31m"))Error:\(format("m")) \(message)"
        }
    }
}

enum SemanticMessage: CustomStringConvertible {
    case raw(String)
    case compiling(file: String)
    case swiftmoduleHeader(header: String)

    var description: String {
        let archStr = options.arch.map { " (\($0))" } ?? ""
        switch self {
        case .raw(let string):
            return string
        case .compiling(let file):
            return Format.stage(.green).apply(to: "Compiling \(file)\(archStr)")
        case .swiftmoduleHeader(let header):
            return Format.stage(.blue).apply(to: "Generating \(header)\(archStr)")
        }
    }
}

extension Decodable {
    init(container: SingleValueDecodingContainer) throws {
        self = try container.decode(Self.self)
    }
}

protocol OutputBody: Decodable {
    var messages: [SemanticMessage] { get }
}

struct CompileOutput: OutputBody {
    enum Kind: String, Decodable {
        case began
        case finished
    }

    let kind: Kind
    let inputs: [String]?
    let exitStatus: Int?
    let output: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case inputs
        case exitStatus = "exit-status"
        case output
    }

    var messages: [SemanticMessage] {
        if kind == .finished && (exitStatus ?? 0) != 0, let output = output {
            return [.raw(output)]
        } else if let inputs = inputs {
            return inputs.filter {
                !$0.hasSuffix(".pch") && !$0.hasSuffix(".xc.swift")
            }.map(SemanticMessage.compiling)
        } else {
            return []
        }
    }
}

struct MergeModuleOutput: OutputBody {
    enum Kind: String, Decodable {
        case began
    }

    struct OutputFile: Decodable {
        let type: String
        let path: String
    }

    let kind: Kind
    let outputs: [OutputFile]

    var messages: [SemanticMessage] {
        outputs
            .filter { $0.type == "objc-header" }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
            .map(SemanticMessage.swiftmoduleHeader)
    }
}

struct Output: Decodable {
    enum Name: String, Decodable {
        case compile
        case mergeModule = "merge-module"

        var bodyType: OutputBody.Type {
            switch self {
            case .compile:
                return CompileOutput.self
            case .mergeModule:
                return MergeModuleOutput.self
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
    }

    let name: Name
    let body: OutputBody

    init(from decoder: Decoder) throws {
        let nameContainer = try decoder.container(keyedBy: CodingKeys.self)
        let name = try nameContainer.decode(Name.self, forKey: .name)
        self.name = name

        let bodyContainer = try decoder.singleValueContainer()
        body = try name.bodyType.init(container: bodyContainer)
    }
}

func parseBody(ofLength totalLength: Int) throws {
    let bodyText = sequence(state: 0) { (length: inout Int) -> String? in
        // it is important that we only consume the next line if we have not surpassed the required
        // length. Otherwise, we may consume a line from the next body. Due to this, the length check
        // must occur *before* we call readLine.
        guard length < totalLength,
            let line = readLine(strippingNewline: false)
            else { return nil }
        length += line.utf8.count
        return line
    }.joined().dropLast() // drop \n on final line
    guard let data = bodyText.data(using: .utf8) else { return }

    let decoder = JSONDecoder()
    let output: Output
    // don't halt and catch fire if we can't parse this output. Just move on.
    do {
        output = try decoder.decode(Output.self, from: data)
    } catch {
        debugPrint(error)
        return
    }

    output.body.messages.forEach { outputPrint("\($0)") }
}

func spitItOut(startingWith firstLine: String) {
    fputs("\(firstLine)\n", stderr)
    while let line = readLine(strippingNewline: false) {
        fputs(line, stderr)
    }
}

func parse() throws {
    while let line = readLine() {
        // `line` should always be a number (because parseBody eats the rest away).
        // If it isn't numeric, that probably means swiftc is outputting some error,
        // in which case we should just spit it out
        guard let charsToRead = Int(line) else {
            return spitItOut(startingWith: line)
        }
        try parseBody(ofLength: charsToRead)
        fflush(stdout)
    }
}

do {
    try parse()
} catch {
    if options.debug {
        fputs("Error: \(error)\n", stderr)
    }
    exit(1)
}
