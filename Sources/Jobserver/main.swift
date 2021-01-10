// an ad hoc, informally-specified, bug-ridden, slow implementation of
// half of GNU Make's jobserver

import Foundation

func usage() -> Never {
    print("Usage: \(CommandLine.arguments[0]) </path/to/jobserver/socket> <expected # of connections|-1>")
    exit(EX_USAGE)
}

guard CommandLine.argc == 3, let connections = Int(CommandLine.arguments[2]), connections >= -1 else {
    usage()
}

@discardableResult
func check<T: SignedInteger>(_ code: T, _ fn: String, file: StaticString = #file, line: Int = #line) -> T {
    if code < 0 {
        perror("Error: \(fn)() failed at \(file):\(line) (errno=\(errno))")
        exit(1)
    }
    return code
}

var path = CommandLine.arguments[1]

// serial output queue
let outputQueue = DispatchQueue(label: "output-queue", qos: .userInteractive)

let serverFD = check(socket(AF_UNIX, SOCK_STREAM, 0), "socket")
var addr = sockaddr_un()
addr.sun_family = .init(AF_UNIX)
addr.sun_len = .init(path.utf8.count)
withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
    path.withUTF8 {
        UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(start: sunPath, count: 1))
            .copyMemory(from: UnsafeRawBufferPointer($0))
    }
}
let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
check(withUnsafePointer(to: &addr) {
    bind(serverFD, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), addrLen)
}, "bind")

check(listen(serverFD, 5), "listen")

let group = DispatchGroup()

func serve(clientFD: Int32) {
    var stringLen: Int = 0
    while true {
        let out = withUnsafeMutablePointer(to: &stringLen) { ptr -> Int in
            let buf = UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(start: ptr, count: 1))
            return check(recv(clientFD, buf.baseAddress!, buf.count, 0), "recv")
        }
        // if 0 then the other end is closed
        guard out != 0 else { break }
        let stringBuf = UnsafeMutablePointer<CChar>.allocate(capacity: stringLen)
        defer { stringBuf.deallocate() }
        check(recv(clientFD, stringBuf, stringLen, 0), "recv")
        let string = String(bytesNoCopy: stringBuf, length: stringLen, encoding: .utf8, freeWhenDone: false)!
        group.enter()
        outputQueue.async {
            print(string, terminator: "")
            group.leave()
        }
    }
    check(close(clientFD), "close")
    group.leave()
}

func loop() {
    var clientAddr = sockaddr_un()
    var clientAddrLen = socklen_t(MemoryLayout.size(ofValue: clientAddr))
    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { clientAddrPtr in
        check(
            accept(serverFD, UnsafeMutableRawPointer(clientAddrPtr).assumingMemoryBound(to: sockaddr.self), &clientAddrLen),
            "accept"
        )
    }
    let clientQueue = DispatchQueue(label: "listener-queue")
    group.enter()
    clientQueue.async {
        serve(clientFD: clientFD)
    }
}

if connections == -1 {
    while true {
        loop()
    }
} else {
    for _ in 0..<connections {
        loop()
    }
}

group.wait()
