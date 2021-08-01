// an ad hoc, informally-specified, bug-ridden, slow implementation of
// half of GNU Make's jobserver

import Foundation
import JobserverCommon

func usage() -> Never {
    print("Usage: \(CommandLine.arguments[0]) </path/to/jobserver/socket> <expected # of connections|-1>")
    exit(EX_USAGE)
}

guard CommandLine.argc == 3, let connections = Int(CommandLine.arguments[2]), connections >= -1 else {
    usage()
}

var path = CommandLine.arguments[1]

// serial output queue
let outputQueue = DispatchQueue(label: "output-queue", qos: .userInteractive)

let serverFD = createSocket(path: path, kind: .server)
check(listen(serverFD, 5), "listen")

let group = DispatchGroup()
let decoder = PropertyListDecoder()

func serve(clientFD: Int32) {
    var payloadLen: Int = 0
    while true {
        let out = withUnsafeMutablePointer(to: &payloadLen) { ptr -> Int in
            let buf = UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(start: ptr, count: 1))
            return check(recv(clientFD, buf.baseAddress!, buf.count, 0), "recv")
        }
        // if 0 then the other end is closed
        guard out != 0 else { break }
        let payloadBuf = UnsafeMutablePointer<CChar>.allocate(capacity: payloadLen)
        defer { payloadBuf.deallocate() }
        var received = 0
        while received != payloadLen {
            received += check(recv(clientFD, payloadBuf + received, payloadLen - received, 0), "recv")
        }
        let payloadData = Data(bytesNoCopy: payloadBuf, count: payloadLen, deallocator: .none)
        let payload = try! decoder.decode(JobserverPayload.self, from: payloadData)
        group.enter()
        outputQueue.async {
            payload.print()
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
