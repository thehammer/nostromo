import Foundation

/// Deadlock-safe `Process` + stdout capture.
///
/// `Pipe` has a fixed ~64KB OS buffer. If a child process writes more than
/// that before its parent reads any of it, the child blocks in `write()`
/// waiting for the buffer to drain — and if the parent is meanwhile blocked
/// in `waitUntilExit()` (which only returns once the child has exited), the
/// two processes deadlock forever. This is exactly what happened with
/// `mother list --format json`: an unfiltered job list eventually exceeded
/// 64KB and wedged the Nostromo GUI at ~98% CPU with dozens of zombie
/// children.
///
/// `runCapturingStdout` avoids this by draining the pipe *before* waiting for
/// exit: `readDataToEndOfFile()` blocks until the child closes its write end
/// (which happens at exit), so it both collects the full output and acts as
/// the wait — a child that outproduces the pipe buffer simply blocks on
/// `write()` until this read drains it, rather than deadlocking against a
/// parent that hasn't read anything yet.
///
/// Foundation-only (no Combine/SwiftUI) so this file can compile directly
/// into both the app target and the `NostromoTests` logic-test target.
enum ProcessRunner {

    /// Runs `url` with `arguments`, capturing stdout fully.
    ///
    /// - Returns: `nil` if the process fails to launch. Otherwise the full
    ///   captured stdout `data` and the child's `status` (exit code).
    static func runCapturingStdout(
        _ url: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> (data: Data, status: Int32)? {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = arguments
        if let environment {
            proc.environment = environment
        }

        let pipe = Pipe()
        proc.standardOutput = pipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Drain FIRST. readDataToEndOfFile() blocks until the child closes
        // its write end (i.e. at exit), so this both collects all output and
        // waits for the child — without ever risking a full-buffer deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return (data, proc.terminationStatus)
    }
}
