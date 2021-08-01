import Foundation

@discardableResult
public func check<T: SignedInteger>(_ code: T, _ fn: String, file: StaticString = #file, line: Int = #line) -> T {
    if code < 0 {
        perror("Error: \(fn)() failed at \(file):\(line) (errno=\(errno))")
        exit(1)
    }
    return code
}

public enum SocketKind {
    case client
    case server
}

public func createSocket(path: String, kind: SocketKind) -> Int32 {
    #if os(Linux)
    let socketType = Int32(SOCK_STREAM.rawValue)
    #else
    let socketType = SOCK_STREAM
    #endif
    let serverFD = check(socket(AF_UNIX, socketType, 0), "socket")

    var addr = sockaddr_un()
    let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
    addr.sun_family = .init(AF_UNIX)
    #if !os(Linux)
    addr.sun_len = .init(addrLen)
    #endif
    var path = path
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        path.withUTF8 {
            UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(start: sunPath, count: 1))
                .copyMemory(from: UnsafeRawBufferPointer($0))
        }
    }

    check(withUnsafePointer(to: &addr) {
        (kind == .client ? connect : bind)(
            serverFD, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), addrLen
        )
    }, kind == .client ? "connect" : "bind")

    return serverFD
}

public struct JobserverPayload: Codable {
    public let fileDescriptor: Int32
    public let message: String

    public init(fileDescriptor: Int32, message: String) {
        self.fileDescriptor = fileDescriptor
        self.message = message
    }

    public func print() {
        FileHandle(fileDescriptor: fileDescriptor)
            .write(message.data(using: .utf8)!)
    }
}
