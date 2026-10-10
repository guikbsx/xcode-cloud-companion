import Foundation

nonisolated enum IPCSocketError: Error, Equatable, Sendable {
    /// The path does not fit a socket address (103 bytes).
    case pathTooLong
    /// Another instance of the app already answers on this socket.
    case alreadyServing
    case unreachable
    case timedOut
    case invalidResponse
    case system(Int32)
}

/// The few POSIX calls a Unix socket needs, and the line framing over it.
nonisolated enum IPCSocket {
    static let maximumLineLength = 64 * 1024

    static func address(path: String) throws(IPCSocketError) -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw .pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func makeSocket() throws(IPCSocketError) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .system(errno) }
        var on: Int32 = 1
        // A peer that left must fail the write, not kill the process.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func connect(_ descriptor: Int32, to path: String) throws(IPCSocketError) -> Bool {
        var address = try address(path: path)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func bind(_ descriptor: Int32, to path: String) throws(IPCSocketError) {
        var address = try address(path: path)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw .system(errno) }
    }

    static func setTimeout(_ seconds: TimeInterval, on descriptor: Int32, option: Int32) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The next line, without its line feed; what follows it stays in `buffer`. Nil when the peer left, stayed silent
    /// past the socket's timeout, or sent more than a line may hold.
    static func readLine(from descriptor: Int32, buffer: inout Data) -> Data? {
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer = Data(buffer[buffer.index(after: end)...])
                return Data(line)
            }
            guard buffer.count <= maximumLineLength else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    static func writeLine(_ line: Data, to descriptor: Int32) -> Bool {
        var remaining = line + Data([0x0A])
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            remaining = Data(remaining.dropFirst(count))
        }
        return true
    }
}

/// The app's side: listens on the socket and answers each line through `handler`. Connections are served on a
/// Dispatch queue, where waiting on a socket blocks no thread of the concurrency pool.
actor IPCSocketServer {
    /// A client that sends nothing for this long is dropped.
    static let idleTimeout: TimeInterval = 10

    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: "com.guik.cumulus.ipc", attributes: .concurrent)
    private var source: (any DispatchSourceRead)?

    init(path: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    var isListening: Bool { source != nil }

    func start() throws(IPCSocketError) {
        guard source == nil else { return }
        if FileManager.default.fileExists(atPath: path) {
            // A socket file with nobody behind it is what a crash leaves; one that answers belongs to another instance.
            let probe = try IPCSocket.makeSocket()
            defer { close(probe) }
            guard try !IPCSocket.connect(probe, to: path) else { throw .alreadyServing }
            unlink(path)
        }
        let descriptor = try IPCSocket.makeSocket()
        do {
            try IPCSocket.bind(descriptor, to: path)
        } catch {
            close(descriptor)
            throw error
        }
        guard listen(descriptor, 16) == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw .system(code)
        }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [queue, handler] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { break }
                // An accepted socket inherits the listener's non-blocking mode; its reads are meant to wait.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                IPCSocket.setTimeout(Self.idleTimeout, on: client, option: SO_RCVTIMEO)
                Self.serve(client, pending: Data(), on: queue, handler: handler)
            }
        }
        source.setCancelHandler { [path] in
            close(descriptor)
            unlink(path)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private static func serve(_ client: Int32, pending: Data, on queue: DispatchQueue, handler: @escaping @Sendable (Data) async -> Data) {
        queue.async {
            var buffer = pending
            guard let line = IPCSocket.readLine(from: client, buffer: &buffer) else {
                close(client)
                return
            }
            let rest = buffer
            Task {
                let reply = await handler(line)
                queue.async {
                    guard IPCSocket.writeLine(reply, to: client) else {
                        close(client)
                        return
                    }
                    serve(client, pending: rest, on: queue, handler: handler)
                }
            }
        }
    }
}

/// The command's side: one connection per request. The waiting happens on a Dispatch queue, off the concurrency pool.
nonisolated struct IPCClient: Sendable {
    private static let queue = DispatchQueue(label: "com.guik.cumulus.ipc.client", attributes: .concurrent)

    var path: String

    func send(_ request: IPCRequest, timeout: TimeInterval) async throws(IPCSocketError) -> IPCResult {
        let line = try await exchange(IPCCodec.encode(request), timeout: timeout)
        guard let response = IPCCodec.decode(IPCResponse.self, from: line), response.id == request.id, let result = response.result else {
            throw .invalidResponse
        }
        return result
    }

    /// Sends one line and returns the line that answers it.
    func exchange(_ line: Data, timeout: TimeInterval) async throws(IPCSocketError) -> Data {
        let path = path
        let result: Result<Data, IPCSocketError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                do throws(IPCSocketError) {
                    continuation.resume(returning: .success(try Self.blockingExchange(line, path: path, timeout: timeout)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    private static func blockingExchange(_ line: Data, path: String, timeout: TimeInterval) throws(IPCSocketError) -> Data {
        let descriptor = try IPCSocket.makeSocket()
        defer { close(descriptor) }
        guard try IPCSocket.connect(descriptor, to: path) else { throw .unreachable }
        IPCSocket.setTimeout(timeout, on: descriptor, option: SO_RCVTIMEO)
        IPCSocket.setTimeout(min(timeout, 5), on: descriptor, option: SO_SNDTIMEO)
        guard IPCSocket.writeLine(line, to: descriptor) else { throw .unreachable }
        var buffer = Data()
        guard let reply = IPCSocket.readLine(from: descriptor, buffer: &buffer) else {
            throw errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .invalidResponse
        }
        return reply
    }

    func ping(timeout: TimeInterval = 0.2) async -> IPCResult? {
        try? await send(IPCRequest(id: "ping", method: IPCMethod.ping), timeout: timeout)
    }
}
