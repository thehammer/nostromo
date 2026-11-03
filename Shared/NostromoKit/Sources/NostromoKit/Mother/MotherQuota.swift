import Foundation

// The quota gate's wire shape: Mother's `quota` block (the `quota` key of a subscribe snapshot, of the
// `quota` event and of the `quota-gate` ack) and the `quota-gate` command. The contract is Mother's
// golden fixture, vendored as `tests/fixtures/mother-contract/quota_block.json`.

/// The gate's state as the broker reported it. A string this build does not know is `.unknown`: it is
/// shown as "unknown" and the control is disabled, never guessed at.
public enum MotherQuotaGate: Equatable, Sendable {
    case on
    case off
    case offUntilReset
    case unknown(String)

    public init(wire: String?) {
        switch wire {
        case "on": self = .on
        case "off": self = .off
        case "off_until_reset": self = .offUntilReset
        default: self = .unknown(wire ?? "")
        }
    }

    /// The gate lets no work through only while it is on; both off states are the loud ones.
    public var isOff: Bool { self == .off || self == .offUntilReset }
    public var isUnknown: Bool { if case .unknown = self { return true } else { return false } }
}

/// What the operator can ask the gate to become: the `state` of a `quota-gate` command.
public enum MotherQuotaGateRequest: String, CaseIterable, Equatable, Sendable {
    case on
    case off
    case offUntilReset = "off_until_reset"

    /// The `data` of the command envelope (no job id). `origin` names this client in Mother's audit.
    public var commandData: [String: String] { ["state": rawValue, "origin": "nostromo"] }

    /// The gate state a broker that applied this request reports.
    public var resultingGate: MotherQuotaGate {
        switch self {
        case .on: return .on
        case .off: return .off
        case .offUntilReset: return .offUntilReset
        }
    }

    public var isTurningOff: Bool { self != .on }
}

public struct MotherQuotaWindow: Equatable, Sendable {
    public var usedPct: Double
    public var capPct: Double
    /// When the window resets; nil when unknown.
    public var resetsAt: Date?

    public init(usedPct: Double, capPct: Double, resetsAt: Date?) {
        self.usedPct = usedPct
        self.capPct = capPct
        self.resetsAt = resetsAt
    }

    /// At or over the cap: Mother holds new work for this window.
    public var isOverCap: Bool { usedPct >= capPct }
}

public struct MotherQuota: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case bishop, cache, none
        case unknown(String)
    }

    public var gate: MotherQuotaGate
    /// Set only while the gate is `off_until_reset`.
    public var until: Date?
    /// The wire's ISO timestamp, kept as sent.
    public var changedAt: String?
    public var changedBy: String?
    public var source: Source
    public var feedAgeSeconds: Int?
    public var stale: Bool
    public var capInvalid: Bool
    public var fiveHour: MotherQuotaWindow?
    public var sevenDay: MotherQuotaWindow?
    /// The wire sent this window but its numbers were unusable, so it was dropped (not the same as never sent).
    public var fiveHourDropped: Bool
    public var sevenDayDropped: Bool

    public init(gate: MotherQuotaGate, until: Date? = nil, changedAt: String? = nil, changedBy: String? = nil,
                source: Source = .none, feedAgeSeconds: Int? = nil, stale: Bool = false, capInvalid: Bool = false,
                fiveHour: MotherQuotaWindow? = nil, sevenDay: MotherQuotaWindow? = nil,
                fiveHourDropped: Bool = false, sevenDayDropped: Bool = false) {
        self.gate = gate
        self.until = until
        self.changedAt = changedAt
        self.changedBy = changedBy
        self.source = source
        self.feedAgeSeconds = feedAgeSeconds
        self.stale = stale
        self.capInvalid = capInvalid
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fiveHourDropped = fiveHourDropped
        self.sevenDayDropped = sevenDayDropped
    }

    /// Decode the `quota` value of an envelope's `data` (a JSON object as `JSONSerialization` gives it).
    /// nil when the key is absent or not an object: an older Mother, "quota status unavailable".
    public static func decode(_ value: Any?) -> MotherQuota? {
        guard let obj = value as? [String: Any] else { return nil }
        let windows = obj["windows"] as? [String: Any]
        let five = window(windows?["five_hour"]), seven = window(windows?["seven_day"])
        return MotherQuota(
            gate: MotherQuotaGate(wire: obj["gate"] as? String),
            until: epoch(obj["until"]),
            changedAt: obj["changed_at"] as? String,
            changedBy: obj["changed_by"] as? String,
            source: source(obj["source"] as? String),
            feedAgeSeconds: count(obj["feed_age_s"]),
            stale: obj["stale"] as? Bool ?? false,
            capInvalid: obj["cap_invalid"] as? Bool ?? false,
            fiveHour: five, sevenDay: seven,
            fiveHourDropped: five == nil && windows?["five_hour"] != nil,
            sevenDayDropped: seven == nil && windows?["seven_day"] != nil)
    }

    /// `decode` from raw JSON bytes of the block itself.
    public static func decode(json: Data) -> MotherQuota? {
        decode(try? JSONSerialization.jsonObject(with: json))
    }

    private static func source(_ wire: String?) -> Source {
        switch wire {
        case "bishop": return .bishop
        case "cache": return .cache
        case "none": return Source.none
        default: return .unknown(wire ?? "")
        }
    }

    private static func window(_ value: Any?) -> MotherQuotaWindow? {
        guard let obj = value as? [String: Any],
              let used = percentValue(obj["used_pct"]), let cap = percentValue(obj["cap_pct"]) else { return nil }
        return MotherQuotaWindow(usedPct: used, capPct: cap, resetsAt: epoch(obj["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        // A JSON boolean is not a number here. (`is Bool` would also match a JSON 0 or 1, so ask CoreFoundation.)
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// A finite number the display can hold: hostile wire values (infinite, absurdly large) are dropped, never trapped on.
    private static let sane = 1e12

    private static func percentValue(_ value: Any?) -> Double? {
        guard let v = number(value), v.isFinite, v >= 0, v <= sane else { return nil }
        return v
    }

    /// A whole number of seconds (the feed's age), or nil when the wire value is not a sane one.
    private static func count(_ value: Any?) -> Int? {
        guard let v = number(value), v.isFinite, abs(v) <= sane else { return nil }
        return Int(exactly: v.rounded(.towardZero))
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let v = number(value), v.isFinite, v >= 0, v <= sane else { return nil }
        return Date(timeIntervalSince1970: v)
    }
}

/// The words the strip, the badge and the control show. Pure, so each wording is tested without a window.
public enum MotherQuotaPresentation {
    public static let unavailableNote = "Quota status unavailable"

    /// A window the broker sent with unusable numbers: `7d unavailable`.
    public static func windowUnavailableText(label: String) -> String { "\(label) unavailable" }

    /// Central time, the operator's own; reset times are shown in it with an explicit zone label.
    public static let displayTimeZone = TimeZone(identifier: "America/Chicago") ?? .current

    /// `5h 15% / 90 · resets 8:40 pm CT`; over the cap: `5h 100% / 90 · paused · resets Thu 8 pm CT`, or
    /// `· over cap, gate off` when the gate is off (Mother is then not holding anything).
    public static func windowText(label: String, _ window: MotherQuotaWindow, now: Date = Date(),
                                  timeZone: TimeZone = displayTimeZone, gate: MotherQuotaGate = .on,
                                  stale: Bool = false) -> String {
        var parts = ["\(label) \(percent(window.usedPct)) / \(plain(window.capPct))"]
        if window.isOverCap {
            // A stale feed makes the gate pass jobs, so "paused" would be false next to "not limiting work".
            parts.append(gate.isOff ? "over cap, gate off" : stale ? "over cap (feed stale)" : "paused")
        }
        if let resets = window.resetsAt {
            parts.append("resets \(resetTime(resets, now: now, timeZone: timeZone))")
        }
        return parts.joined(separator: " · ")
    }

    /// The text of the quiet or loud gate badge.
    public static func badgeText(_ quota: MotherQuota, now: Date = Date(), timeZone: TimeZone = displayTimeZone) -> String {
        switch quota.gate {
        case .on: return quota.stale ? staleGateOnText : "Gate on"
        case .off: return "Gate OFF"
        case .offUntilReset:
            guard let until = quota.until else { return "Gate off until reset" }
            return "Gate off until reset (resets \(resetTime(until, now: now, timeZone: timeZone)))"
        case .unknown: return "Gate unknown"
        }
    }

    /// Shown (in the warning colour) when the feed is stale; nil when it is fresh.
    public static func staleText(_ quota: MotherQuota) -> String? {
        guard quota.stale else { return nil }
        guard let age = quota.feedAgeSeconds else { return "Quota feed stale" }
        return "Quota feed stale (\(max(0, age) / 60)m)"
    }

    /// A stale feed makes the gate pass jobs, so "Mother holds work" would be false.
    public static let staleGateOnText = "Gate on, feed stale: Mother is not limiting work"

    public static let capInvalidText = "cap invalid, using 90"

    /// One spoken sentence for the badge (the OFF states are announced as warnings).
    public static func badgeSpokenText(_ quota: MotherQuota, now: Date = Date(), timeZone: TimeZone = displayTimeZone) -> String {
        switch quota.gate {
        case .on:
            if quota.stale { return "Quota gate on, but the feed is stale. Mother is not limiting work." }
            return "Quota gate on. Mother holds work when a window is over its cap."
        case .off:
            return "Warning: quota gate off. Mother starts work whatever the quota."
        case .offUntilReset:
            let until = quota.until.map { " until \(resetTime($0, now: now, timeZone: timeZone))" } ?? ""
            return "Warning: quota gate off\(until). Mother starts work whatever the quota until the window resets."
        case .unknown:
            return "Quota gate state unknown."
        }
    }

    /// Title and spoken label of one control option.
    public static func optionTitle(_ request: MotherQuotaGateRequest) -> String {
        switch request {
        case .on: return "On"
        case .offUntilReset: return "Off until next reset"
        case .off: return "Off"
        }
    }

    public static func optionSpokenLabel(_ request: MotherQuotaGateRequest) -> String {
        switch request {
        case .on: return "Turn quota gate on"
        case .offUntilReset: return "Turn quota gate off until the next reset"
        case .off: return "Turn quota gate off"
        }
    }

    public static func armedTitle(_ request: MotherQuotaGateRequest) -> String {
        "\(optionTitle(request))?"
    }

    public static let armedPrompt = "Turn gate off? Click again to confirm"

    public static func armedSpokenLabel(_ request: MotherQuotaGateRequest) -> String {
        "Confirm: \(optionSpokenLabel(request).lowercased()). Activate again to confirm."
    }

    /// `8:40 pm CT` for a reset today, `Thu 8 pm CT` for a later day. On the hour the minutes are dropped.
    public static func resetTime(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = cal.dateComponents([.hour, .minute, .weekday], from: date)
        let hour24 = parts.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = parts.minute ?? 0
        let clock = (minute == 0 ? "\(hour12)" : "\(hour12):\(String(format: "%02d", minute))")
            + (hour24 < 12 ? " am" : " pm")
        let zone = zoneLabel(timeZone, at: date)
        if cal.isDate(date, inSameDayAs: now) { return "\(clock) \(zone)" }
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return "\(days[((parts.weekday ?? 1) - 1) % 7]) \(clock) \(zone)"
    }

    private static func zoneLabel(_ zone: TimeZone, at date: Date) -> String {
        if zone.identifier == "America/Chicago" { return "CT" }
        if ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(zone.identifier) { return "UTC" }
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    private static func percent(_ value: Double) -> String { "\(plain(value.rounded()))%" }

    private static func plain(_ value: Double) -> String {
        if let whole = Int(exactly: value), abs(value) < 1e15 { return String(whole) }
        return String(format: "%g", value)
    }
}
