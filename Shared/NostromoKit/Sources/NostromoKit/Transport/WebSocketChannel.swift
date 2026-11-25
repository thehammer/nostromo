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

    /// `bearer == nil` opens a pairing-only socket.
    init(host: String, port: UInt16, bearer: String?) {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        components.port = Int(port)
        components.path = "/"
        var request = URLRequest(url: components.url ?? URL(string: "ws://invalid.invalid/")!)
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
