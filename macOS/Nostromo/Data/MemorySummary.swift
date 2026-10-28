import Darwin
import Foundation
import MachO

/// A cheap, content-free statement of where this process's memory is, for the places that must be
/// able to say it without attaching any tool (the pane-blank capture, the diagnostics stream, the
/// memory watchdog's log line).
///
/// The incident that wrote this: the app sat at 1.8 GB for hours with 1.68 GB of it in "Malloc Small",
/// and the only way to learn that was `footprint -p` and `heap -s` run by hand against the live app.
/// Everything here is what those two tools would have said first — the dirty bytes per VM category and
/// the live malloc block count — from two kernel calls, with no walk over the heap. **Never** run
/// `heap` in process: it suspends every thread for as long as the heap is large.
///
/// Content-free by construction: numbers, plus category names from a fixed vocabulary (`categoryName`).
struct MemorySummary: Equatable {

    struct Category: Equatable {
        let name: String
        let dirtyBytes: Int
    }

    /// One VM region as the Mach VM reports it: its `user_tag` and the bytes of it that are dirty.
    struct Region {
        let tag: UInt32
        let dirtyBytes: Int
    }

    let physicalFootprintBytes: Int
    /// Live malloc blocks across every zone: the number that was 16 million at the incident.
    let mallocBlocksInUse: Int
    let mallocBytesInUse: Int
    /// Largest dirty first, ties by name, never empty ones, at most the `limit` it was built with.
    let categories: [Category]

    // MARK: - Capture

    /// A summary of this process now. A walk over the VM regions and one `malloc_zone_statistics` per zone; safe on any thread.
    /// Measured at 36.9 ms (median) with 2.0 million live blocks and 10,000 regions on a CI Mac
    /// (`MemorySummaryCostTests`); the incident's 16 million block heap was never measured. It grows with
    /// the heap: not for the main thread of a big app. Known exceptions, accepted because each runs once per
    /// rare event, not on a hot path: `PaneRenderWatch.report` (a pane-blank capture, built on the main thread
    /// at the draw that detected the blank, so the report shows the pane as it was) and
    /// `TranscriptDiagnostics.snapshot` (the on-demand diagnostics report and its sample stream).
    static func capture(limit: Int = 5) -> MemorySummary {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return MemorySummary(physicalFootprintBytes: TranscriptDiagnostics.physicalFootprint(),
                             mallocBlocksInUse: Int(stats.blocks_in_use),
                             mallocBytesInUse: Int(stats.size_in_use),
                             categories: categories(from: regions(), limit: limit))
    }

    /// Dirty bytes per VM tag, summed, largest first.
    static func categories(from regions: [Region], limit: Int) -> [Category] {
        var byTag: [UInt32: Int] = [:]
        for region in regions where region.dirtyBytes > 0 { byTag[region.tag, default: 0] += region.dirtyBytes }
        return byTag
            .map { Category(name: categoryName(forVMTag: $0.key), dirtyBytes: $0.value) }
            .sorted { $0.dirtyBytes != $1.dirtyBytes ? $0.dirtyBytes > $1.dirtyBytes : $0.name < $1.name }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// The fixed vocabulary: Mach's own names for the VM tags worth naming, `VM tag <n>` for the rest.
    static func categoryName(forVMTag tag: UInt32) -> String {
        switch Int32(truncatingIfNeeded: tag) {
        case VM_MEMORY_MALLOC:                return "Malloc"
        case VM_MEMORY_MALLOC_TINY:           return "Malloc Tiny"
        case VM_MEMORY_MALLOC_SMALL:          return "Malloc Small"
        case VM_MEMORY_MALLOC_MEDIUM:         return "Malloc Medium"
        case VM_MEMORY_MALLOC_LARGE:          return "Malloc Large"
        case VM_MEMORY_MALLOC_HUGE:           return "Malloc Huge"
        case VM_MEMORY_MALLOC_LARGE_REUSABLE: return "Malloc Large Reusable"
        case VM_MEMORY_MALLOC_LARGE_REUSED:   return "Malloc Large Reused"
        case VM_MEMORY_MALLOC_NANO:           return "Malloc Nano"
        case VM_MEMORY_STACK:                 return "Stack"
        case VM_MEMORY_COREGRAPHICS:          return "CoreGraphics"
        case VM_MEMORY_IOSURFACE:             return "IOSurface"
        case VM_MEMORY_SWIFT_RUNTIME:         return "Swift runtime"
        case VM_MEMORY_SWIFT_METADATA:        return "Swift metadata"
        case VM_MEMORY_IMAGEIO:               return "ImageIO"
        case VM_MEMORY_COREUI:                return "CoreUI"
        default:                              return "VM tag \(tag)"
        }
    }

    /// Every name `categoryName` can return other than `VM tag <n>`, so a content check can allow the
    /// vocabulary without copying it.
    static let fixedCategoryNames: Set<String> = [
        "Malloc", "Malloc Tiny", "Malloc Small", "Malloc Medium", "Malloc Large", "Malloc Huge",
        "Malloc Large Reusable", "Malloc Large Reused", "Malloc Nano", "Stack", "CoreGraphics", "IOSurface",
        "Swift runtime", "Swift metadata", "ImageIO", "CoreUI",
    ]

    // MARK: - Rendering

    /// Numbers and fixed names only.
    var jsonObject: [String: Any] {
        [
            "physicalFootprintBytes": physicalFootprintBytes,
            "mallocBlocksInUse": mallocBlocksInUse,
            "mallocBytesInUse": mallocBytesInUse,
            "categories": categories.map { ["name": $0.name, "dirtyBytes": $0.dirtyBytes] as [String: Any] },
        ]
    }

    /// `footprint 1797 MB; 16046602 malloc blocks (1585 MB); largest: Malloc Small 1678 MB, Malloc Large 39 MB`
    var oneLine: String {
        var line = "footprint \(Self.megabytes(physicalFootprintBytes)) MB; "
            + "\(mallocBlocksInUse) malloc blocks (\(Self.megabytes(mallocBytesInUse)) MB)"
        if !categories.isEmpty {
            line += "; largest: " + categories.map { "\($0.name) \(Self.megabytes($0.dirtyBytes)) MB" }.joined(separator: ", ")
        }
        return line
    }

    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }

    // MARK: - VM regions

    /// This task's VM regions, with the dirty bytes of each. `pages_dirtied` and `pages_swapped_out`
    /// are the pages `footprint` calls "Dirty"; resident-but-clean pages are not memory this process
    /// is holding against the system.
    private static func regions() -> [Region] {
        var out: [Region] = []
        var address: mach_vm_address_t = 0
        var depth: UInt32 = 0
        let pageSize = Int(vm_kernel_page_size)
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<Int32>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                depth += 1
                continue
            }
            let dirty = (Int(info.pages_dirtied) + Int(info.pages_swapped_out)) * pageSize
            if dirty > 0 { out.append(Region(tag: info.user_tag, dirtyBytes: dirty)) }
            address += size
        }
        return out
    }
}


/// Cumulative counts of the places that rebuild a view tree, so a capture says which one is churning.
///
/// Why this exists: every new `NSTextField`, `NSImageView`, `NSButton` or `NSTextView` that is shown in a
/// window leaves AppKit KVO records (`NSKeyValueDependency` and friends, three or more per control)
/// behind for good, so the rate at which the app rebuilds controls is the rate at which it leaks
/// (docs/diagnostics.md, "View-tree leak"). The 2026-10-25 heap held two million of them. A heap summary
/// cannot say which of our views made them; this can. Fixed names and numbers only.
enum RebuildCounters {
    enum Site: String, CaseIterable {
        /// `TabBarView.setFocuses` tore the sidebar down and built it again.
        case sidebarRebuilt = "sidebarRebuilt"
        /// `TabBarView.setFocuses` was asked for rows it already shows and did nothing.
        case sidebarSkipped = "sidebarSkipped"
        /// `ReplView` built a turn view (materialisation, a width change, a shed or a splice).
        case turnViewBuilt = "turnViewBuilt"
        /// The Perri view's PR queue list replaced every row.
        case perriQueueListRebuilt = "perriQueueListRebuilt"
    }

    private static let lock = NSLock()
    private static var counts: [Site: Int] = [:]

    static func note(_ site: Site) {
        lock.lock()
        counts[site, default: 0] += 1
        lock.unlock()
    }

    /// Every site, zero included, by its fixed name.
    static var snapshot: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: Site.allCases.map { ($0.rawValue, counts[$0] ?? 0) })
    }
}
