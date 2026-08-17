import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "diagnostics")

/// **Debug ▸ Copy daemon diagnostics.**
///
/// The one-layer-down sibling of `TranscriptDiagnostics`: where that reports
/// what the transcript view costs, this reports what the daemon round trip
/// costs — daemon-side MCP tool-dispatch latency (fetched over the MCP
/// socket) merged with this process's own IPC round-trip stats
/// (`NostromodClient.latency`).
///
/// No persistence, no background sampler — purely on-demand, same spirit as
/// `TranscriptDiagnostics`.
enum DaemonDiagnostics {

    // MARK: - Socket resolution

    /// Resolve the MCP socket to query, mirroring `src/mcp/socket.rs`:
    /// `NOSTROMO_MCP_SOCKET` if set, else the daemon-hosted socket
    /// (`~/.nostromo/mcp-daemon.sock`) if it exists, else the TUI-hosted
    /// socket (`~/.nostromo/mcp.sock`).
    static func mcpSocketPath() -> String {
        if let v = ProcessInfo.processInfo.environment["NOSTROMO_MCP_SOCKET"] { return v }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let daemonSocket = "\(home)/.nostromo/mcp-daemon.sock"
        if FileManager.default.fileExists(atPath: daemonSocket) { return daemonSocket }
        return "\(home)/.nostromo/mcp.sock"
    }

    // MARK: - One-shot MCP fetch

    /// Fetch `nostromo.get_daemon_diagnostics` over a fresh, one-shot
    /// connection to the MCP socket.
    ///
    /// The daemon's MCP transport is a Unix socket speaking
    /// newline-delimited JSON-RPC 2.0, preceded by one identification line
    /// (see `src/mcp/server.rs`). `initialize` is not required before
    /// `tools/call`.
    ///
    /// Returns the parsed diagnostics object on success. On any failure,
    /// returns `["error": "<specific reason>", "socket": <path>]` — the local
    /// `ipc` half of the report is still useful without the daemon half, but
    /// a missing daemon half must be visible in the output, not silently
    /// absent.
    static func fetchDaemonReport(timeout: TimeInterval = 2.0) -> [String: Any] {
        let path = mcpSocketPath()

        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "socket_missing: no file at path", "socket": path]
        }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return ["error": "socket_create_failed errno=\(errno)", "socket": path]
        }
        defer { Darwin.close(sock) }

        // A wedged daemon must not hang the copy indefinitely.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
        let pathBytes = path.utf8CString                       // includes NUL
        guard pathBytes.count <= cap else {
            return ["error": "socket_path_too_long", "socket": path]
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, len)
            }
        }
        guard connectResult == 0 else {
            return ["error": "connect_failed errno=\(errno)", "socket": path]
        }

        let helloLine = "{\"type\":\"hello\",\"pty_id\":\"macos-debug-menu\"}\n"
        let requestLine = """
            {"jsonrpc":"2.0","id":1,"method":"tools/call",\
            "params":{"name":"nostromo.get_daemon_diagnostics","arguments":{}}}\n
            """

        guard writeAll(sock, helloLine), writeAll(sock, requestLine) else {
            return ["error": "write_failed errno=\(errno)", "socket": path]
        }

        guard let line = readLineFromSocket(sock) else {
            return ["error": "read_timeout_or_eof errno=\(errno)", "socket": path]
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return ["error": "malformed_reply: not a JSON object", "socket": path]
        }

        // An older daemon that predates this tool answers with a JSON-RPC
        // error object (method not found) — that is a diagnosis, not noise,
        // so surface its message rather than falling through to a generic
        // "malformed reply".
        if let errObj = envelope["error"] as? [String: Any] {
            let message = errObj["message"] as? String ?? "unknown JSON-RPC error"
            return ["error": "daemon_rpc_error: \(message)", "socket": path]
        }

        guard let result = envelope["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let textData = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: textData) as? [String: Any]
        else {
            return ["error": "malformed_reply: unexpected tools/call result shape", "socket": path]
        }

        return parsed
    }

    // MARK: - Combined report

    /// Merge the daemon-side report with this process's local IPC stats into
    /// one pretty-printed, sorted-keys JSON document.
    static func reportJSON(timeout: TimeInterval = 2.0) -> String {
        let daemon = fetchDaemonReport(timeout: timeout)

        let encoder = JSONEncoder()
        let ipcSnapshot = AppStore.shared.client.latency.snapshot()
        guard let ipcData = try? encoder.encode(ipcSnapshot),
              let ipc = try? JSONSerialization.jsonObject(with: ipcData)
        else { return "{}" }

        let merged: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "mcpSocket": mcpSocketPath(),
            "daemon": daemon,
            "ipc": ipc,
        ]

        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(
                withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Debug ▸ Copy daemon diagnostics.
    ///
    /// Fetches (socket I/O included) off the main thread, then hops back to
    /// copy to the pasteboard — never blocks the UI on a socket read.
    static func copyReportToPasteboard() {
        DispatchQueue.global(qos: .userInitiated).async {
            let json = reportJSON()
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(json, forType: .string)
                log.info("daemon diagnostics copied to pasteboard")
            }
        }
    }

    // MARK: - Raw socket helpers

    private static func writeAll(_ sock: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                Darwin.write(sock, buf.baseAddress!.advanced(by: off), buf.count - off)
            }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// Read bytes until (and excluding) the first `\n`, or `nil` on
    /// EOF/error/timeout before one is found.
    private static func readLineFromSocket(_ sock: Int32) -> Data? {
        var result = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(sock, &byte, 1)
            if n <= 0 { return nil }
            if byte == 0x0A { return result }
            result.append(byte)
            if result.count > 4 * 1024 * 1024 { return nil } // runaway guard
        }
    }
}
