import AppKit
import ObjectiveC
import XCTest

/// The test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass` on the NostromoTests target). XCTest
/// instantiates it once, before any test runs.
///
/// It makes every `NSWindow` created in the test process default to `animationBehavior = .none`. A test
/// window that is ordered in and then closed with AppKit's default animation parks a libdispatch worker in
/// `NSAnimation _runBlocking` for good; enough of them starve the global pool and every later
/// `DispatchQueue.global` job (`RepoOrgResolver`, ...) never runs (see `TestIsolationTests`). ~30 test files
/// make windows without ever setting the behavior, so the default is set at the source: the designated
/// initializers (`NSPanel`, `NSWindowController`/hosting-controller windows and nib windows all reach one).
/// A test that wants the default animation sets `.default` after creating the window.
@objc(NostromoTestBundleSetup)
final class TestBundleSetup: NSObject {
    /// `Unmanaged` on every object parameter and result: the initializers consume `self` and return it owned, and
    /// ARC-managed `AnyObject` in a swizzled `@convention(c)`/block pair gets that ownership wrong (segv).
    private static let installed: Bool = {
        typealias Obj = Unmanaged<AnyObject>
        typealias Rect4 = @convention(c) (Obj, Selector, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool) -> Obj?
        typealias Rect5 = @convention(c) (Obj, Selector, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool, NSScreen?) -> Obj?
        typealias Coder = @convention(c) (Obj, Selector, NSCoder) -> Obj?
        func quiet(_ w: Obj?) -> Obj? {
            (w?.takeUnretainedValue() as? NSWindow)?.animationBehavior = .none
            return w
        }
        let rect4 = #selector(NSWindow.init(contentRect:styleMask:backing:defer:))
        let rect5 = #selector(NSWindow.init(contentRect:styleMask:backing:defer:screen:))
        let coder = NSSelectorFromString("initWithCoder:")
        if let m = class_getInstanceMethod(NSWindow.self, rect4) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Rect4.self)
            let block: @convention(block) (Obj, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool) -> Obj? = { o, r, sm, b, d in
                quiet(orig(o, rect4, r, sm, b, d))
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(NSWindow.self, rect5) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Rect5.self)
            let block: @convention(block) (Obj, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool, NSScreen?) -> Obj? = { o, r, sm, b, d, s in
                quiet(orig(o, rect5, r, sm, b, d, s))
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(NSWindow.self, coder) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Coder.self)
            let block: @convention(block) (Obj, NSCoder) -> Obj? = { o, c in
                quiet(orig(o, coder, c))
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // The Overview's saved filter must never come from, or go to, the developer's own preferences.
        let suite = "nostromo.tests.authoredPrsFilter"
        UserDefaults().removePersistentDomain(forName: suite)
        if let defaults = UserDefaults(suiteName: suite) { AuthoredPrsFilterStore.defaults = defaults }
        // The operator's real ~/.nostromo is watched for the whole run (`RealNostromoGuard`), and the temporary
        // home every `NostromoHome` path resolves to under tests is removed when the run ends.
        RealNostromoGuard.recordBaseline()
        XCTestObservationCenter.shared.addTestObserver(TestHomeCleanup())
        return true
    }()

    /// Idempotent. Called by the principal class's `init` and by `TestIsolationTests` (so the hook is
    /// verifiable even if the bundle is loaded without a principal class).
    static func install() { _ = installed }

    override init() {
        Self.install()
        super.init()
    }
}
