// NostromoKit — WebSocketChannel.swift
//
// One `URLSessionWebSocketTask` and what both the main client and the pairing client need from it:
// text frames in and out, a ping, and a way to turn whatever went wrong into a `ConnectionFailure`.
// It sets no `Origin` header (the daemon refuses an upgrade that has one) and puts the token only in
// the `Authorization` header, never in the URL.

import Foundation

final class WebSocketChannel: @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    /// The address cannot be turned into a `ws://` URL. Never replaced by a fallback address: a
    /// socket (and the token on it) goes only where the operator's address says.
    struct BadAddress: Error, Equatable {}

    /// The `ws://host:port/` URL for `host`, or `nil` when `host` is not usable. An IPv6 literal keeps
    /// its brackets (`[::1]`); a bare one (`::1`) gets them.
    static func url(host: String, port: UInt16) -> URL? {
        let bare = host.trimmingCharacters(in: .whitespaces)
        guard !bare.isEmpty else { return nil }
        let bracketed = bare.contains(":") && !bare.hasPrefix("[") ? "[\(bare)]" : bare
        var components = URLComponents()
        components.scheme = "ws"
        components.host = bracketed
        components.port = Int(port)
        components.path = "/"
        guard let url = components.url, url.scheme == "ws", url.host != nil else { return nil }
        return url
    }

    /// `bearer == nil` opens a pairing-only socket. Throws `BadAddress` for a host that has no URL.
    init(host: String, port: UInt16, bearer: String?) throws {
        guard let url = Self.url(host: host, port: port) else { throw BadAddress() }
        var request = URLRequest(url: url)
        // Longer than the 20 s ping so an idle but healthy socket is never cut by the request timeout;
        // the clients run their own, shorter, handshake deadline.
        request.timeoutInterval = 30
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
    }

    func resume() { task.resume() }

    func send(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// The next text (or binary) frame's bytes.
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data):   return data
        @unknown default:       return Data()
        }
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    /// Explains why `error` (thrown by `send`, `receive` or `sendPing`) ended the socket.
    func failure(for error: Error) -> ConnectionFailure {
        Self.failure(for: error,
                     closeCode: task.closeCode.rawValue,
                     httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
    }

    /// Pure core of `failure(for:)`, so the table test can drive it without a socket.
    static func failure(for error: Error, closeCode: Int, httpStatus: Int?) -> ConnectionFailure {
        if error is BadAddress { return .badAddress }
        if closeCode == ConnectionFailure.unauthorizedCloseCode { return .closed(code: closeCode) }
        if let status = httpStatus, status != 101 { return .httpStatus(status) }
        if let urlError = error as? URLError { return .transport(urlError.code) }
        if closeCode != 0 { return .closed(code: closeCode) }
        return .other
    }
}

/// Thrown by `withDeadline` when the time is up.
struct TimeoutError: Error {}

/// Runs `body`, giving up with `TimeoutError` after `seconds`. Unlike a task group this returns as
/// soon as the deadline passes: a socket read does not end on task cancellation, so the caller closes
/// the channel to end the abandoned `body`.
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                               _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = ResumeOnce(continuation)
        let work = Task {
            do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.resume(.failure(TimeoutError())) { work.cancel() }
        }
    }
}

/// Resumes a continuation at most once; the first caller wins.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// Returns whether this call was the one that resumed.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
