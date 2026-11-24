import Darwin
import Foundation

// A local socket that carries one line of text per message, for the app and its MCP helper.
// A Unix domain socket in the user's own data folder, so only this user's processes can reach
// it, and the app knows a session has ended the moment its connection closes.

public enum LineSocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    /// Another copy of the app answers on this socket.
    case alreadyServed(String)
    case system(call: String, code: Int32)
    case closed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "The socket path is too long for macOS: \(path)"
        case .alreadyServed(let path): "Another copy of the app is already serving \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .closed: "The connection closed"
        case .timedOut: "No answer in time"
        }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw LineSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A connected socket, or a thrown error.
    static func connect(path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.system(call: "socket", code: errno) }
        noSignalOnBrokenPipe(fd)
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LineSocketError.system(call: "connect", code: code)
        }
        return fd
    }

    /// A write to a closed connection returns an error instead of killing the process.
    static func noSignalOnBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Writes every byte, waiting up to a second at a time while the socket's buffer is full.
    static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                bytes = bytes.dropFirst(written)
                continue
            }
            if written < 0, errno == EAGAIN || errno == EINTR {
                var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&waiting, 1, 1000) <= 0 { return false }
                continue
            }
            return false
        }
        return true
    }

    /// Takes every complete line out of `pending`.
    static func takeLines(_ pending: inout [UInt8]) -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// The app's end: listens on a socket file and hands each line it receives to `handlers`,
/// tagged with the connection it came on. Its work runs on a private queue, and so do the
/// handlers.
public final class LineSocketServer: @unchecked Sendable {
    public typealias ConnectionID = Int

    public struct Handlers: Sendable {
        public var opened: @Sendable (ConnectionID) -> Void
        public var line: @Sendable (ConnectionID, String) -> Void
        public var closed: @Sendable (ConnectionID) -> Void

        public init(
            opened: @escaping @Sendable (ConnectionID) -> Void,
            line: @escaping @Sendable (ConnectionID, String) -> Void,
            closed: @escaping @Sendable (ConnectionID) -> Void
        ) {
            self.opened = opened
            self.line = line
            self.closed = closed
        }
    }

    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var pending: [UInt8] = []
        init(fd: Int32) { self.fd = fd }
    }

    /// The most a line may hold before the connection is dropped.
    static let longestLine = 1 << 20

    public let path: String
    private let handlers: Handlers
    private let queue = DispatchQueue(label: "dev.lubelski.mac-tally-lamp.socket")
    // Everything below is touched only on `queue`, apart from `init`.
    private var acceptSource: DispatchSourceRead?
    private var connections: [ConnectionID: Connection] = [:]
    private var nextID = 1

    /// Starts listening. A socket file left by a copy that quit without removing it is
    /// replaced. One that answers belongs to a copy that is running, and is left alone.
    public init(path: String, handlers: Handlers) throws {
        self.path = path
        self.handlers = handlers
        var address = try UnixSocket.address(path)
        if FileManager.default.fileExists(atPath: path) {
            if let fd = try? UnixSocket.connect(path: path) {
                Darwin.close(fd)
                throw LineSocketError.alreadyServed(path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocketError.system(call: "socket", code: errno) }
        guard UnixSocket.withSockaddr(&address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw LineSocketError.system(call: "bind", code: code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw LineSocketError.system(call: "listen", code: code)
        }
        UnixSocket.setNonBlocking(fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
    }

    public func send(_ line: String, to id: ConnectionID) {
        queue.async { [self] in
            guard let connection = connections[id] else { return }
            if !UnixSocket.writeAll(connection.fd, line + "\n") { drop(id) }
        }
    }

    /// Stops listening, closes every connection, and removes the socket file.
    public func close() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for id in Array(connections.keys) { drop(id) }
            unlink(path)
        }
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.setNonBlocking(fd)
            UnixSocket.noSignalOnBrokenPipe(fd)
            let id = nextID
            nextID += 1
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(id) }
            source.setCancelHandler { Darwin.close(fd) }
            connection.source = source
            connections[id] = connection
            handlers.opened(id)
            source.resume()
        }
    }

    private func readAvailable(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(connection.fd, &buffer, buffer.count)
        if count > 0 {
            connection.pending.append(contentsOf: buffer[0..<count])
            for line in UnixSocket.takeLines(&connection.pending) { handlers.line(id, line) }
            if connection.pending.count > Self.longestLine { drop(id) }
            return
        }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        drop(id)
    }

    private func drop(_ id: ConnectionID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()
        handlers.closed(id)
    }
}

/// The helper's end: one connection, used one request and one reply at a time. Its calls
/// block, for at most `timeout` per read.
public final class LineSocketClient {
    private var fd: Int32
    private var pending: [UInt8] = []

    public init(path: String, timeout: TimeInterval = 10) throws {
        fd = try UnixSocket.connect(path: path)
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    public func send(_ line: String) throws {
        guard fd >= 0, UnixSocket.writeAll(fd, line + "\n") else { throw LineSocketError.closed }
    }

    public func readLine() throws -> String {
        while true {
            if let line = UnixSocket.takeLines(&pending).first { return line }
            guard fd >= 0 else { throw LineSocketError.closed }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                pending.append(contentsOf: buffer[0..<count])
                continue
            }
            if count == 0 { throw LineSocketError.closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw LineSocketError.timedOut }
            throw LineSocketError.system(call: "read", code: errno)
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }
}
