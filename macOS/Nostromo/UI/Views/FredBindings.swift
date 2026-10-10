import AppKit

/// The Fred lane's glue to the app: builds the native HUD the daemon's
/// `fred_hud` pane maps to (see `DynamicFocusView.makeLeafView`).
enum FredBindings {
    static func makeSurface(focus: Focus) -> NSView {
        FredHUD()
    }
}
