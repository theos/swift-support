import Foundation

// based on
// https://github.com/apple/swift-tools-support-core/blob/1ed3a9bf3d8ee7ed35a33ea0260d1ee30d54013f/Sources/TSCBasic/Lock.swift#L60

public final class FileLock {
    public enum LockType {
        case exclusive
        case shared
    }

    /// File descriptor to the lock file.
    private var fileDescriptor: CInt?

    /// Path to the lock file.
    private let lockFile: URL

    /// Create an instance of FileLock at the path specified
    ///
    /// Note: The parent directory path should be a valid directory.
    public init(at lockFile: URL) {
        self.lockFile = lockFile
    }

    /// Try to acquire a lock. This method will block until lock the already aquired by other process.
    ///
    /// Note: This method can throw if underlying POSIX methods fail.
    public func lock(type: LockType = .exclusive) throws {
        // Open the lock file.
        if fileDescriptor == nil {
            let fd = lockFile.withUnsafeFileSystemRepresentation {
                open($0!, O_WRONLY | O_CREAT | O_CLOEXEC, 0o666)
            }
            if fd == -1 {
                throw FileLockError.open(file: lockFile, errno: errno)
            }
            self.fileDescriptor = fd
        }
        // Aquire lock on the file.
        while true {
            if type == .exclusive && flock(fileDescriptor!, LOCK_EX) == 0 {
                break
            } else if type == .shared && flock(fileDescriptor!, LOCK_SH) == 0 {
                break
            }
            // Retry if interrupted.
            if errno == EINTR { continue }
            throw FileLockError.acquire(errno: errno)
        }
    }

    /// Unlock the held lock.
    public func unlock() {
        guard let fd = fileDescriptor else { return }
        flock(fd, LOCK_UN)
    }

    deinit {
        guard let fd = fileDescriptor else { return }
        close(fd)
    }

    /// Execute the given block while holding the lock.
    public func withLock<T>(type: LockType = .exclusive, _ body: () throws -> T) throws -> T {
        try lock(type: type)
        defer { unlock() }
        return try body()
    }
}

public enum FileLockError: Error {
    case open(file: URL, errno: CInt)
    case acquire(errno: CInt)
}
