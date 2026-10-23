import Foundation
import NostromoObjCGuard

/// An Objective-C exception that was caught instead of aborting the app.
public struct CaughtObjCException: Equatable, Sendable {
    public let name: String
    public let reason: String?

    public init(name: String, reason: String?) {
        self.name = name
        self.reason = reason
    }
}

/// The smallest possible ObjC `@try/@catch` for calls into AppKit that can raise an
/// NSException (which Swift cannot catch).
public enum ObjCExceptionGuard {
    /// Runs `body` once. Returns the exception it raised, or nil if it completed normally.
    public static func catching(_ body: () -> Void) -> CaughtObjCException? {
        guard let exception = NostromoCatchException(body) else { return nil }
        return CaughtObjCException(name: exception.name.rawValue, reason: exception.reason)
    }
}
