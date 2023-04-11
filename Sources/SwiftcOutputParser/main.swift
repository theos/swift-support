import Foundation

struct Options {
    let debug: Bool
    let colored: Bool
    let lockPath: String
    let arch: String?
}

guard CommandLine.argc >= 4 else {
    print("Usage: \(CommandLine.arguments[0]) <colored: 0|1> </path/to/output.lock|-> [arch]")
    exit(EX_USAGE)
}

var errorOccurred = false

let options = Options(
    debug: ProcessInfo.processInfo.environment["DEBUG_OUTPUT"] != nil,
    colored: CommandLine.arguments[1] == "1",
    lockPath: CommandLine.arguments[2],
    arch: CommandLine.arguments[3]
)

var lockPath = options.lockPath
let lock: FileLock?
if lockPath == "-" {
    lock = nil
} else {
    lock = .init(at: URL(fileURLWithPath: lockPath))
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

    func print() {
        let handle: FileHandle
        switch self {
        case .raw:
            handle = .standardError
        default:
            handle = .standardOutput
        }
        handle.write(Data("\(self)\n".utf8))
    }
}

let encoder = PropertyListEncoder()

@rethrows protocol RethrowingGet {
    associatedtype Success
    func get() throws -> Success
}

extension RethrowingGet {
    func rethrowGet() rethrows -> Success {
        return try get()
    }
}

extension Result: RethrowingGet {}

// if withLock throws, falls back to calling body unlocked
func tryWithLock<T>(_ body: () throws -> T) rethrows -> T {
    guard let lock = lock else { return try body() }
    let result: Result<T, Error>
    do {
        result = try lock.withLock {
            Result { try body() }
        }
    } catch {
        return try body()
    }
    return try result.rethrowGet()
}

func sendOutput(_ message: SemanticMessage) {
    tryWithLock { message.print() }
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
        case skipped
        case finished
        case signalled
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
        if (kind == .finished && (exitStatus ?? 0) != 0) || kind == .signalled {
            errorOccurred = true
        }

        var allMessages: [SemanticMessage] = []
        if let output = output {
            allMessages.append(.raw(output))
        }

        switch inputs {
        case []:
            // the new Swift driver seems to (buggily?) provide an empty inputs
            // array for WMO builds
            allMessages.append(SemanticMessage.compiling(file: "module interface"))
        case let inputs?:
            allMessages += inputs.filter {
                !$0.hasSuffix(".pch") && !$0.hasSuffix(".xc.swift")
            }.map(SemanticMessage.compiling)
        case nil:
            break
        }

        return allMessages
    }
}

struct MergeModuleOutput: OutputBody {
    enum Kind: String, Decodable {
        case began
        case finished
    }

    struct OutputFile: Decodable {
        let type: String
        let path: String
    }

    let kind: Kind
    let outputs: [OutputFile]?

    var messages: [SemanticMessage] {
        (outputs ?? [])
            .filter { $0.type == "objc-header" }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
            .map(SemanticMessage.swiftmoduleHeader)
    }
}

struct Output: Decodable {
    enum Name: String, Decodable {
        case compile
        case mergeModule = "merge-module"
        case emitModule = "emit-module"

        var bodyType: OutputBody.Type {
            switch self {
            case .compile:
                return CompileOutput.self
            case .emitModule:
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
    let data = Data(bodyText.utf8)

    let decoder = JSONDecoder()
    let output: Output
    // don't halt and catch fire if we can't parse this output. Just move on.
    do {
        output = try decoder.decode(Output.self, from: data)
    } catch {
        debugPrint(error)
        return
    }

    tryWithLock {
        for message in output.body.messages {
            sendOutput(message)
        }
    }
}

func spitItOut(startingWith firstLine: String) {
    fputs("\(firstLine)\n", stderr)
    while let line = readLine(strippingNewline: false) {
        fputs(line, stderr)
    }
}

func parse() throws {
    while let line = readLine() {
        if line.hasPrefix("error:") {
            tryWithLock { print(line) }
            errorOccurred = true
            continue
        }
        if line.hasPrefix("warning:") {
            tryWithLock { print(line) }
            continue
        }
        // `line` should always be a number (because parseBody eats the rest away).
        // If it isn't numeric, that probably means swiftc is outputting some error,
        // in which case we should just spit it out
        guard let charsToRead = Int(line) else {
            errorOccurred = true
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

if errorOccurred {
    exit(1)
}
