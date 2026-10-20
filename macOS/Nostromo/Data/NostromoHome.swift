import Foundation

/// The directory that contains `.nostromo` for this process.
///
/// `FileManager.homeDirectoryForCurrentUser` comes from the system user database and ignores the
/// `HOME` a launcher sets, so the isolated QA clone (`com.hammer.nostromo.qa`) used to write into the
/// user's real `~/.nostromo`. Every path under `~/.nostromo` is built from `NostromoHome.current`.
///
/// Only the QA bundle id can be redirected (by `NOSTROMO_QA_HOME`, an absolute path of an existing
/// directory). The real app (`com.hammer.nostromo`) gets the real home whatever the environment says,
/// so a stray variable can never move the user's state.
enum NostromoHome {
    static let qaBundleID = "com.hammer.nostromo.qa"
    static let qaHomeEnvKey = "NOSTROMO_QA_HOME"

    /// Pure rule behind `current`; env, bundle id and real home are injected so it is testable.
    static func url(env: [String: String], bundleID: String?, realHome: URL) -> URL {
        guard bundleID == qaBundleID,
              let path = env[qaHomeEnvKey],
              path.hasPrefix("/")
        else { return realHome }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return realHome }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// True only for the QA clone's bundle id (exactly). The QA instance must never start Mother.
    static func isQAInstance(bundleID: String?) -> Bool {
        bundleID == qaBundleID
    }

    static var isQAInstance: Bool {
        isQAInstance(bundleID: Bundle.main.bundleIdentifier)
    }

    /// Whether an offline broker should trigger `mother daemon start`: never for the QA clone.
    static func shouldAttemptMotherDaemonStart(brokerConnected: Bool, isQA: Bool) -> Bool {
        !brokerConnected && !isQA
    }

    static var current: URL {
        url(env: ProcessInfo.processInfo.environment,
            bundleID: Bundle.main.bundleIdentifier,
            realHome: FileManager.default.homeDirectoryForCurrentUser)
    }
}
