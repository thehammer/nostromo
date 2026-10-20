import Foundation

/// The folder whose children are the user's code repos. Mirrors the daemon's
/// `Config::code_root_dir` (src/config.rs) so the app and `nostromd` agree:
/// `$NOSTROMO_CODE_ROOT` → `code_root` in `config.toml` → `~/Code`.
public enum CodeRoot {
    /// Where the daemon reads `config.toml` on macOS (`directories::ProjectDirs`).
    public static func defaultConfigURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/nostromo/config.toml")
    }

    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        configText: String? = nil
    ) -> URL {
        let text = configText ?? (try? String(contentsOf: defaultConfigURL(home: home), encoding: .utf8))
        let chosen = nonEmpty(env["NOSTROMO_CODE_ROOT"]) ?? nonEmpty(text.flatMap(configuredValue))
        guard let chosen else { return home.appendingPathComponent("Code") }
        return URL(fileURLWithPath: expandTilde(chosen, home: home.path))
    }

    /// The top-level `code_root = "..."` string from a config.toml, ignoring tables,
    /// comments and other keys. Deliberately minimal: one key, basic or literal strings.
    static func configuredValue(in toml: String) -> String? {
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }  // top-level keys end at the first table
            guard line.hasPrefix("code_root") else { continue }
            let rest = line.dropFirst("code_root".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            let s = String(body[..<end])
            return quote == "\"" ? s.replacingOccurrences(of: "\\\\", with: "\\") : s
        }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }
}
