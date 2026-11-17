import AppKit
import ObjectiveC

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
    private static let installed: Bool = {
        typealias Rect4 = @convention(c) (AnyObject, Selector, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool) -> AnyObject?
        typealias Rect5 = @convention(c) (AnyObject, Selector, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool, NSScreen?) -> AnyObject?
        typealias Coder = @convention(c) (AnyObject, Selector, NSCoder) -> AnyObject?
        let rect4 = #selector(NSWindow.init(contentRect:styleMask:backing:defer:))
        let rect5 = #selector(NSWindow.init(contentRect:styleMask:backing:defer:screen:))
        let coder = NSSelectorFromString("initWithCoder:")
        if let m = class_getInstanceMethod(NSWindow.self, rect4) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Rect4.self)
            let block: @convention(block) (AnyObject, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool) -> AnyObject? = { o, r, sm, b, d in
                let w = orig(o, rect4, r, sm, b, d); (w as? NSWindow)?.animationBehavior = .none; return w
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(NSWindow.self, rect5) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Rect5.self)
            let block: @convention(block) (AnyObject, NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool, NSScreen?) -> AnyObject? = { o, r, sm, b, d, s in
                let w = orig(o, rect5, r, sm, b, d, s); (w as? NSWindow)?.animationBehavior = .none; return w
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(NSWindow.self, coder) {
            let orig = unsafeBitCast(method_getImplementation(m), to: Coder.self)
            let block: @convention(block) (AnyObject, NSCoder) -> AnyObject? = { o, c in
                let w = orig(o, coder, c); (w as? NSWindow)?.animationBehavior = .none; return w
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
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
