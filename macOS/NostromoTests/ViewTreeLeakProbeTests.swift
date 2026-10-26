import XCTest
import AppKit
import Darwin
import ObjectiveC

// PROBE (temporary), round 3: NAME what is left behind when a control is added to / removed from a
// long-lived superview. Walks this process's malloc zones (test-only: it is a heap walk) and builds
// a histogram of live objects by class, plus of non-object blocks by size. Reports through XCTFail.

enum ProbeCensus {
    struct Snapshot {
        var classes: [UInt: Int] = [:]
        var sizes: [Int] = Array(repeating: 0, count: 257)
        var zones = 0
        var blocks = 0
    }

    final class Table {
        let capacity = 1 << 17
        let keys: UnsafeMutablePointer<UInt>
        let counts: UnsafeMutablePointer<Int>
        let sizes: UnsafeMutablePointer<Int>
        var blocks = 0
        let mask: UInt
        init(mask: UInt) {
            self.mask = mask
            keys = .allocate(capacity: capacity); keys.initialize(repeating: 0, count: capacity)
            counts = .allocate(capacity: capacity); counts.initialize(repeating: 0, count: capacity)
            sizes = .allocate(capacity: 257); sizes.initialize(repeating: 0, count: 257)
        }
        deinit { keys.deallocate(); counts.deallocate(); sizes.deallocate() }

        func slot(_ key: UInt) -> Int {
            var i = Int(truncatingIfNeeded: (key >> 3) &* 0x9E37_79B9) & (capacity - 1)
            while keys[i] != 0 && keys[i] != key { i = (i + 1) & (capacity - 1) }
            return i
        }
        func insert(_ key: UInt) { keys[slot(key)] = key }
        func lookup(_ key: UInt) -> Int? {
            let i = slot(key)
            return keys[i] == key ? i : nil
        }
    }

    static func snapshot() -> Snapshot {
        let maskSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_debug_isa_class_mask")
        let mask: UInt = maskSym.map { $0.assumingMemoryBound(to: UInt.self).pointee } ?? 0x0000_000f_ffff_fff8
        let table = Table(mask: mask)
        var n: UInt32 = 0
        if let list = objc_copyClassList(&n) {
            for i in 0 ..< Int(n) { table.insert(unsafeBitCast(list[i], to: UInt.self)) }
            free(UnsafeMutableRawPointer(list))
        }
        let ctx = Unmanaged.passUnretained(table).toOpaque()

        var snap = Snapshot()
        var zones: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &zones, &zoneCount) == KERN_SUCCESS, let zones else { return snap }
        snap.zones = Int(zoneCount)
        for z in 0 ..< Int(zoneCount) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[z])),
                  let introspect = zone.pointee.introspect,
                  let enumerate = introspect.pointee.enumerator else { continue }
            _ = enumerate(mach_task_self_, ctx, 4 /* MALLOC_PTR_IN_USE_RANGE_TYPE */, zones[z],
                          { _, address, _, ptr in
                              ptr?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address))
                              return KERN_SUCCESS
                          },
                          { _, context, _, ranges, count in
                              guard let context, let ranges else { return }
                              let t = Unmanaged<Table>.fromOpaque(context).takeUnretainedValue()
                              for i in 0 ..< Int(count) {
                                  let r = ranges[i]
                                  guard r.size >= 16, let p = UnsafeRawPointer(bitPattern: UInt(r.address)) else { continue }
                                  t.blocks += 1
                                  let isa = p.load(as: UInt.self) & t.mask
                                  if isa != 0, let slot = t.lookup(isa) {
                                      t.counts[slot] += 1
                                  } else {
                                      t.sizes[min(Int(r.size) / 16, 256)] += 1
                                  }
                              }
                          })
        }
        for i in 0 ..< table.capacity where table.keys[i] != 0 && table.counts[i] != 0 {
            snap.classes[table.keys[i]] = table.counts[i]
        }
        for i in 0 ... 256 { snap.sizes[i] = table.sizes[i] }
        snap.blocks = table.blocks
        return snap
    }

    static func className(_ ptr: UInt) -> String {
        guard let cls = unsafeBitCast(ptr, to: AnyClass?.self) else { return "?" }
        return String(cString: class_getName(cls))
    }

    /// The biggest movers between two snapshots: "Class +n, ...; size48 +n, ...".
    static func delta(_ a: Snapshot, _ b: Snapshot, top: Int = 7) -> String {
        var moves: [(String, Int)] = []
        for key in Set(a.classes.keys).union(b.classes.keys) {
            let d = (b.classes[key] ?? 0) - (a.classes[key] ?? 0)
            if abs(d) >= 50 { moves.append((className(key), d)) }
        }
        moves.sort { abs($0.1) > abs($1.1) }
        var sizeMoves: [(String, Int)] = []
        for i in 0 ... 256 {
            let d = b.sizes[i] - a.sizes[i]
            if abs(d) >= 100 { sizeMoves.append(("sz\(i * 16)", d)) }
        }
        sizeMoves.sort { abs($0.1) > abs($1.1) }
        func fmt(_ m: [(String, Int)]) -> String {
            m.prefix(top).map { "\($0.0) \($0.1 >= 0 ? "+" : "")\($0.1)" }.joined(separator: ", ")
        }
        return "classes[\(fmt(moves))] sizes[\(fmt(sizeMoves))] (zones \(b.zones), total blocks \(b.blocks))"
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

    private func makeWindow() -> (NSWindow, NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = FixedWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        return (window, host)
    }

    private func label() -> NSTextField {
        let l = NSTextField(labelWithString: "hello world")
        l.textColor = Theme.fg
        return l
    }

    /// Runs `cycle` n times against a long-lived windowed host and reports what it left behind.
    private func probe(_ name: String, n: Int = 500, destroyHostAfter: Bool = false,
                       cycle: (_ host: NSView, _ window: NSWindow) -> Void) {
        var window: NSWindow? = nil
        var host: NSView? = nil
        (window, host) = { let p = makeWindow(); return (Optional(p.0), Optional(p.1)) }()
        addTeardownBlock { [weak w = window] in w?.orderOut(nil); w?.contentView = nil }
        for _ in 0 ..< 30 { autoreleasepool { cycle(host!, window!) } }
        settle()
        let s0 = ProbeCensus.snapshot()
        let b0 = Self.blocksInUse()
        for _ in 0 ..< n { autoreleasepool { cycle(host!, window!) } }
        settle(5)
        let s1 = ProbeCensus.snapshot()
        let b1 = Self.blocksInUse()
        var tail = ""
        if destroyHostAfter {
            autoreleasepool {
                host!.subviews.forEach { $0.removeFromSuperview() }
                window!.orderOut(nil)
                window!.contentView = nil
                host = nil
                window = nil
            }
            settle(8)
            let d = Self.blocksInUse() - b1
            tail = "; after destroying the host/window: blocks \(d >= 0 ? "+" : "")\(d)"
        }
        XCTFail("PROBE3 \(name) n=\(n): blocks +\(b1 - b0) (\(String(format: "%.1f", Double(b1 - b0) / Double(n)))/iter); "
                + ProbeCensus.delta(s0, s1) + tail)
    }

    func testProbeNamesTheLeak() {
        probe("plainLabel add/remove") { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("plainLabel add/remove, host+window destroyed afterwards", destroyHostAfter: true) { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("nsView add/remove (control: no leak expected)") { host, _ in
            let v = NSView(); host.addSubview(v); v.removeFromSuperview()
        }
        probe("nsImageView add/remove") { host, _ in
            let v = NSImageView(); host.addSubview(v); v.removeFromSuperview()
        }
    }

    func testProbeMitigations() {
        probe("label created once, text updated in place (no re-parenting)") { host, _ in
            if host.subviews.isEmpty { host.addSubview(self.label()) }
            (host.subviews[0] as? NSTextField)?.stringValue = "tick \(Int.random(in: 0 ..< 1000))"
        }
        probe("label reparented between two long-lived views") { host, _ in
            let a: NSView
            if let existing = host.subviews.first { a = existing } else {
                a = NSView(); host.addSubview(a)
                let b = NSView(); host.addSubview(b)
            }
            let b = host.subviews[1]
            let l = a.subviews.first ?? b.subviews.first ?? self.label()
            (l.superview === a ? b : a).addSubview(l)
        }
        probe("label via removeFromSuperviewWithoutNeedingDisplay") { host, _ in
            let v = self.label(); host.addSubview(v); v.removeFromSuperviewWithoutNeedingDisplay()
        }
        probe("label with cell.controlView cleared before removal") { host, _ in
            let v = self.label(); host.addSubview(v); v.cell?.controlView = nil; v.removeFromSuperview()
        }
        probe("label added to a short-lived container that is NOT yet in the window (ChatTurnView build)") { host, _ in
            let c = NSView(); c.addSubview(self.label()); c.addSubview(self.label())
            host.addSubview(c); c.removeFromSuperview()
        }
        probe("label added to a short-lived container ALREADY in the window (streaming append)") { host, _ in
            let c = NSView(); host.addSubview(c); c.addSubview(self.label()); c.addSubview(self.label())
            c.removeFromSuperview()
        }
        probe("label in NSStackView arranged/removed (our render() pattern)") { host, _ in
            let s: NSStackView
            if let existing = host.subviews.first as? NSStackView { s = existing } else { s = NSStackView(); host.addSubview(s) }
            s.arrangedSubviews.forEach { $0.removeFromSuperview() }
            s.addArrangedSubview(self.label()); s.addArrangedSubview(self.label())
        }
        probe("CopyMenuTextField add/remove") { host, _ in
            let v = CopyMenuTextField(labelWithString: "hello world"); host.addSubview(v); v.removeFromSuperview()
        }
    }
}
