import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A Unix domain socket where `minirun serve` answers local questions such as "what's your
/// status?". Each connection sends one request line and gets one response line back. The socket
/// file is only accessible to the current user.
///
/// Plain POSIX so it builds and is tested on Linux too.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String) async -> String

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false
    /// Requests are small; anything longer is a confused client.
    static let maxRequest = 64 * 1024

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Binds the socket and starts accepting connections on a background thread. Fails if another
    /// `minirun serve` is already answering on this path. A socket file left behind by a process
    /// that died is replaced.
    public func start() throws {
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? ControlSocket.connect(path), probe >= 0 {
                close(probe)
                throw ToolError("Another minirun is already answering on \(path).")
            }
            unlink(path)
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let fd = try ControlSocket.makeSocket()
        do {
            var address = try ControlSocket.address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw ControlSocket.error("bind \(path)") }
            chmod(path, 0o600)
            guard listen(fd, 16) == 0 else { throw ControlSocket.error("listen on \(path)") }
        } catch {
            close(fd)
            throw error
        }

        lock.lock()
        listener = fd
        stopped = false
        lock.unlock()
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "minirun control socket"
        thread.start()
    }

    /// Stops accepting connections and removes the socket file.
    public func stop() {
        lock.lock()
        let fd = listener
        let wasRunning = !stopped && fd >= 0
        stopped = true
        listener = -1
        lock.unlock()
        // The accept loop notices within one poll interval and closes the descriptor itself.
        if wasRunning { unlink(path) }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while !isStopped {
            // Poll rather than block in accept(), so stop() takes effect without closing the
            // descriptor out from under this thread.
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let count = poll(&ready, 1, 250)
            if count < 0 && errno != EINTR { return }
            guard count > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            ControlSocket.configure(client, timeout: 5)
            DispatchQueue.global().async { [handler] in
                guard let request = ControlSocket.readLine(client, limit: Self.maxRequest) else {
                    close(client)
                    return
                }
                Task {
                    let response = await handler(request)
                    ControlSocket.writeLine(client, response)
                    close(client)
                }
            }
        }
    }
}

public enum ControlSocket {
    /// Sends one request line to the socket at `path` and returns the response line.
    public static func request(_ path: String, _ line: String, timeout: Int = 10) throws -> String {
        let fd = try connect(path)
        defer { close(fd) }
        configure(fd, timeout: timeout)
        guard writeLine(fd, line) else { throw error("write to \(path)") }
        guard let response = readLine(fd, limit: 16 * 1024 * 1024) else {
            throw ToolError("No answer on \(path).")
        }
        return response
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = try makeSocket()
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard result == 0 else {
            let failure = error("connect to \(path)")
            close(fd)
            throw failure
        }
        return fd
    }

    static func makeSocket() throws -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw error("socket") }
        #if canImport(Darwin)
        // A client that hangs up early must not kill the daemon with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ToolError("The socket path \(path) is too long (\(bytes.count) bytes; the limit is \(capacity - 1)).") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    /// Read and write timeouts, so a stuck peer can't hold a thread forever.
    static func configure(_ fd: Int32, timeout seconds: Int) {
        var time = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Reads up to the first newline (or the end of the stream). Nil on error, timeout, an empty
    /// stream, or more than `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return String(decoding: data, as: UTF8.self)
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard !data.isEmpty, data.count <= limit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func writeLine(_ fd: Int32, _ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                #if canImport(Darwin)
                send(fd, buffer.baseAddress, buffer.count, 0)
                #else
                send(fd, buffer.baseAddress, buffer.count, Int32(MSG_NOSIGNAL))
                #endif
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    static func error(_ action: String) -> ToolError {
        ToolError("Couldn't \(action): \(String(cString: strerror(errno))).")
    }
}
