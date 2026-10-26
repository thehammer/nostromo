import XCTest
import AppKit
import Darwin

// PROBE (temporary), round 2: which operation leaks AppKit KVO dependency records?
// Counts live instances of AppKit/Foundation classes by walking this process's malloc zones
// (test-only: it is a heap walk), and reports per-iteration deltas through XCTFail.

enum ProbeCensus {
    static let classNames = ["NSKeyValueDependency", "NSKeyValueDependencyContext", "__NSMallocBlock__",
                             "__NSExactBlockVariable__", "NSISRestrictedToNonNegativeVariable",
                             "NSTextFieldCell", "NSLayoutConstraint", "NSView"]

    final class Box {
        var wanted: [UInt: Int] = [:]      // class pointer -> index
        var counts: [Int]
        let mask: UInt
        init(classes: [UInt], mask: UInt) {
            for (i, c) in classes.enumerated() { wanted[c] = i }
            counts = Array(repeating: 0, count: classes.count)
            self.mask = mask
        }
    }

    static func count() -> [String: Int] {
        var classPtrs: [UInt] = []
        var kept: [String] = []
        for n in classNames {
            if let c = NSClassFromString(n) { classPtrs.append(unsafeBitCast(c, to: UInt.self)); kept.append(n) }
        }
        let maskSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_debug_isa_class_mask")
        let mask: UInt = maskSym.map { $0.assumingMemoryBound(to: UInt.self).pointee } ?? 0x0000_000f_ffff_fff8
        let box = Box(classes: classPtrs, mask: mask)
        let ctx = Unmanaged.passUnretained(box).toOpaque()

        var zones: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &zones, &zoneCount) == KERN_SUCCESS, let zones else { return [:] }
        let reader: memory_reader_t = { _, address, _, ptr in
            ptr?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address))
            return KERN_SUCCESS
        }
        let recorder: vm_range_recorder_t = { _, context, _, ranges, count in
            guard let context, let ranges else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            for i in 0 ..< Int(count) {
                let r = ranges[i]
                guard r.size >= 16, let p = UnsafeRawPointer(bitPattern: UInt(r.address)) else { continue }
                let isa = p.load(as: UInt.self)
                if let idx = box.wanted[isa & box.mask] { box.counts[idx] += 1 }
            }
        }
        for z in 0 ..< Int(zoneCount) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[z])),
                  let introspect = zone.pointee.introspect,
                  let enumerate = introspect.pointee.enumerator else { continue }
            _ = enumerate(mach_task_self_, ctx, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE), zones[z], reader, recorder)
        }
        var out: [String: Int] = [:]
        for (i, n) in kept.enumerated() { out[n] = box.counts[i] }
        return out
    }

    static func delta(_ a: [String: Int], _ b: [String: Int], per n: Int) -> String {
        classNames.compactMap { name -> String? in
            guard let x = a[name], let y = b[name] else { return nil }
            let d = y - x
            guard d != 0 else { return nil }
            let short = name.replacingOccurrences(of: "NSKeyValue", with: "KV").replacingOccurrences(of: "__NS", with: "")
                .replacingOccurrences(of: "NSISRestrictedToNonNegativeVariable", with: "ISNonNeg")
            return "\(short) \(d >= 0 ? "+" : "")\(d)"
        }.joined(separator: ", ")
    }
}

final class ViewTreeLeakProbeTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static func blocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }

    private func settle(_ n: Int = 3) {
        for _ in 0 ..< n { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private enum Step: Int { case add = 0, layout, display }

    private func makeHost(inWindow: Bool, dark: Bool = true) -> (NSWindow?, NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        guard inWindow else { return (nil, host) }
        let window = FixedWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        return (window, host)
    }

    private func probe(_ name: String, inWindow: Bool = true, dark: Bool = true, upTo: Step = .display,
                       iterations: Int = 500, clearViaSubviews: Bool = false, build: () -> NSView) {
        let (window, host) = makeHost(inWindow: inWindow, dark: dark)
        func cycle() {
            autoreleasepool {
                let v = build()
                v.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
                host.addSubview(v)
                if upTo.rawValue >= Step.layout.rawValue { host.layoutSubtreeIfNeeded() }
                if upTo.rawValue >= Step.display.rawValue { host.displayIfNeeded(); window?.displayIfNeeded() }
                if clearViaSubviews { host.subviews = [] } else { v.removeFromSuperview() }
            }
        }
        for _ in 0 ..< 30 { cycle() }
        settle()
        let c0 = ProbeCensus.count()
        let b0 = Self.blocksInUse()
        for _ in 0 ..< iterations { cycle() }
        settle(5)
        let c1 = ProbeCensus.count()
        let b1 = Self.blocksInUse()
        XCTFail("PROBE2 \(name) [win=\(inWindow) dark=\(dark) upTo=\(upTo) n=\(iterations)]: "
                + "blocks +\(b1 - b0); \(ProbeCensus.delta(c0, c1, per: iterations))")
    }

    private func label() -> NSTextField {
        let l = NSTextField(labelWithString: "hello world")
        l.textColor = Theme.fg
        return l
    }

    func testProbeSteps() {
        probe("plainLabel", upTo: .add) { label() }
        probe("plainLabel", upTo: .layout) { label() }
        probe("plainLabel", upTo: .display) { label() }
        probe("plainLabel", upTo: .display, iterations: 1500) { label() }
    }

    func testProbeHostKinds() {
        probe("plainLabel", inWindow: false, upTo: .layout) { label() }
        probe("plainLabel", dark: false) { label() }
        probe("plainLabel viaSubviews", clearViaSubviews: true) { label() }
    }

    func testProbeProperties() {
        probe("selectable") { let l = label(); l.isSelectable = true; return l }
        probe("wrapping") {
            let l = label(); l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0; return l
        }
        probe("copyMenuField") { let l = CopyMenuTextField(labelWithString: "hello world"); return l }
        probe("copyMenuFieldSelectable") {
            let l = CopyMenuTextField(labelWithString: "hello world"); l.isSelectable = true; return l
        }
        probe("wrappingLabelWithString") { NSTextField(wrappingLabelWithString: "hello world") }
        probe("fontAndColor") {
            let l = label(); l.font = .systemFont(ofSize: 13); l.textColor = Theme.fg; return l
        }
        probe("attributedString") {
            let l = NSTextField(labelWithAttributedString: NSAttributedString(
                string: "hello", attributes: [.foregroundColor: Theme.fg, .font: NSFont.systemFont(ofSize: 13)]))
            return l
        }
    }

    func testProbeOtherControls() {
        probe("nsView") { NSView() }
        probe("nsTextViewStatic") {
            let t = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
            t.string = "hello"; t.isEditable = false; return t
        }
        probe("nsButton") { NSButton(title: "go", target: nil, action: nil) }
        probe("nsImageView") { NSImageView() }
        probe("nsStackViewWithLabel") {
            let s = NSStackView(views: [NSTextField(labelWithString: "a"), NSTextField(labelWithString: "b")])
            return s
        }
        probe("nsTextFieldFrameInit") {
            let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
            t.isBezeled = false; t.drawsBackground = false; t.isEditable = false; t.stringValue = "hello"; return t
        }
    }

    func testProbeOurViews() {
        probe("userBubble", iterations: 300) { UserBubbleView(text: "a question the user asked") }
        probe("textBlockPlain", iterations: 300) { TextBlockView(text: "Plain words " + String(repeating: "more ", count: 30)) }
        probe("toolCall", iterations: 300) {
            ToolCallView(data: ToolCallData(toolName: "Bash", inputSummary: "ls -la /tmp", inputFull: "{}"))
        }
    }
}
