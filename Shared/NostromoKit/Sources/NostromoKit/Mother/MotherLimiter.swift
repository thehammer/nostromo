import Foundation

// Mother's backpressure limiter block: the `limiter` key of a subscribe snapshot and of each `limiter` event.
// Read-only: Nostromo shows it and never changes it. The contract is Mother's golden fixture, vendored as
// `tests/fixtures/mother-contract/limiter_block.json`; its `_doc` defines every field.

public struct MotherLimiter: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case off, observe, enforce
        case unknown(String)

        public init(wire: String?) {
            switch wire {
            case "off": self = .off
            case "observe": self = .observe
            case "enforce": self = .enforce
            default: self = .unknown(wire ?? "")
            }
        }
    }

    public enum ConcurrencyState: Equatable, Sendable {
        case steady, backoff, ramp, uncalibrated
        case unknown(String)

        public init(wire: String?) {
            switch wire {
            case "steady": self = .steady
            case "backoff": self = .backoff
            case "ramp": self = .ramp
            case "uncalibrated": self = .uncalibrated
            default: self = .unknown(wire ?? "")
            }
        }
    }

    public enum BurnWindow: Equatable, Sendable {
        case fiveHour, sevenDay
        case unknown(String)

        public init(wire: String?) {
            switch wire {
            case "five_hour": self = .fiveHour
            case "seven_day": self = .sevenDay
            default: self = .unknown(wire ?? "")
            }
        }
    }

    public enum InteractiveState: Equatable, Sendable {
        case ok, high, unknownState
        case unknown(String)

        public init(wire: String?) {
            switch wire {
            case "ok": self = .ok
            case "high": self = .high
            case "unknown": self = .unknownState
            default: self = .unknown(wire ?? "")
            }
        }
    }

    public struct Concurrency: Equatable, Sendable {
        public var ceiling: Int?
        public var allowed: Int?
        public var effective: Int?
        public var state: ConcurrencyState
        public var detail: String?
    }

    public struct Burn: Equatable, Sendable {
        public var fleetUsdPerMin: Double?
        public var sustainableUsdPerMin: Double?
        /// Projected / sustainable: 1.0 is exactly sustainable.
        public var pace: Double?
        public var window: BurnWindow
        public var calibrated: Bool?
    }

    public struct Reserve: Equatable, Sendable {
        public var pct: Double?
        public var holding: Bool?
        public var enforceable: Bool?
    }

    public struct Interactive: Equatable, Sendable {
        public var state: InteractiveState
        public var pctPerHour: Double?
    }

    public struct Distress: Equatable, Sendable {
        /// The wire's ISO timestamp, kept as sent.
        public var at: String?
        public var agoSeconds: Int?
        /// `api_retry`, `result_error`, `rate_limit_rejected`, `failure_routed`, or a string this build does not know.
        public var kind: String?
        /// An HTTP code such as 429, or a reason string; as text.
        public var status: String?
        public var jobId: String?
    }

    /// What the limiter's own view of a waiting job is, when it differs from what dispatch does.
    public struct Would: Equatable, Sendable {
        public var code: String
        public var reason: String
    }

    public struct Waiting: Equatable, Sendable {
        public var id: String
        public var code: String
        public var reason: String
        public var source: String?
        public var advisory: Bool
        public var would: Would?
        public var since: String?
    }

    public var version: Int?
    public var mode: Mode
    public var ageSeconds: Int?
    public var stale: Bool
    /// The runner's limiter fault text (`why`); nil when there is none. A fault means fixed concurrency.
    public var fault: String?
    public var concurrency: Concurrency?
    public var burn: Burn?
    public var reserve: Reserve?
    public var interactive: Interactive?
    public var overageInUse: Bool?
    public var gate: MotherQuotaGate?
    public var lastDistress: Distress?
    public var distress24h: Int?
    public var waiting: [Waiting]

    /// The limiter is not computing: dispatch uses fixed concurrency.
    public var isNotRunning: Bool { stale || fault != nil }

    /// Every mode except `off` is shown as a strip line. A mode this build does not know (a newer Mother) is
    /// shown as `Limiter (<mode>)` rather than hidden, so a new mode can never disappear silently; an empty or
    /// missing mode string is not shown.
    public var isShown: Bool {
        switch mode {
        case .observe, .enforce: return true
        case .off: return false
        case .unknown(let raw): return !raw.isEmpty
        }
    }

    /// The wait entry for one job, if the block lists it.
    public func waitingEntry(for jobId: String) -> Waiting? { waiting.first { $0.id == jobId } }

    /// Decode the `limiter` value of an envelope's `data`. nil when it is absent or not an object (an older
    /// Mother). Unknown keys are ignored; a missing optional value is nil, never a guessed default.
    public static func decode(_ value: Any?) -> MotherLimiter? {
        guard let obj = value as? [String: Any] else { return nil }
        return MotherLimiter(
            version: count(obj["v"]),
            mode: Mode(wire: obj["mode"] as? String),
            ageSeconds: count(obj["age_s"]),
            stale: obj["stale"] as? Bool ?? false,
            fault: fault(obj["fault"]),
            concurrency: (obj["concurrency"] as? [String: Any]).map {
                Concurrency(ceiling: count($0["ceiling"]), allowed: count($0["allowed"]),
                            effective: count($0["effective"]), state: ConcurrencyState(wire: $0["state"] as? String),
                            detail: nonEmpty($0["detail"]))
            },
            burn: (obj["burn"] as? [String: Any]).map {
                Burn(fleetUsdPerMin: number($0["fleet_usd_per_min"]),
                     sustainableUsdPerMin: number($0["sustainable_usd_per_min"]),
                     pace: number($0["pace"]), window: BurnWindow(wire: $0["window"] as? String),
                     calibrated: $0["calibrated"] as? Bool)
            },
            reserve: (obj["reserve"] as? [String: Any]).map {
                Reserve(pct: number($0["pct"]), holding: $0["holding"] as? Bool, enforceable: $0["enforceable"] as? Bool)
            },
            interactive: (obj["interactive"] as? [String: Any]).map {
                Interactive(state: InteractiveState(wire: $0["state"] as? String), pctPerHour: number($0["pct_per_hour"]))
            },
            overageInUse: obj["overage_in_use"] as? Bool,
            gate: (obj["gate"] as? String).map { MotherQuotaGate(wire: $0) },
            lastDistress: (obj["last_distress"] as? [String: Any]).map {
                Distress(at: $0["at"] as? String, agoSeconds: count($0["ago_s"]), kind: $0["kind"] as? String,
                         status: text($0["status"]), jobId: nonEmpty($0["job_id"]))
            },
            distress24h: count(obj["distress_24h"]),
            waiting: (obj["waiting"] as? [[String: Any]] ?? []).compactMap(waiting))
    }

    /// `decode` from raw JSON bytes of the block itself.
    public static func decode(json: Data) -> MotherLimiter? {
        decode(try? JSONSerialization.jsonObject(with: json))
    }

    /// A `limiter.wait` object of a job record (`{code, reason, source, advisory, would, since}`); nil when it is
    /// absent or has no reason to show.
    public static func decodeWait(_ value: Any?) -> Waiting? {
        guard var entry = waiting(value, requireId: false) else { return nil }
        entry.id = ""
        return entry
    }

    // MARK: Decoding helpers

    private static func waiting(_ value: Any?) -> Waiting? { waiting(value, requireId: true) }

    private static func waiting(_ value: Any?, requireId: Bool) -> Waiting? {
        guard let obj = value as? [String: Any] else { return nil }
        let id = obj["id"] as? String
        if requireId && (id ?? "").isEmpty { return nil }
        guard let reason = nonEmpty(obj["reason"]) else { return nil }
        let would = (obj["would"] as? [String: Any]).flatMap { w -> Would? in
            guard let reason = nonEmpty(w["reason"]) else { return nil }
            return Would(code: w["code"] as? String ?? "", reason: reason)
        }
        return Waiting(id: id ?? "", code: obj["code"] as? String ?? "", reason: reason,
                       source: obj["source"] as? String, advisory: obj["advisory"] as? Bool ?? false,
                       would: would, since: obj["since"] as? String)
    }

    private static func fault(_ value: Any?) -> String? {
        guard let obj = value as? [String: Any] else { return nil }
        return nonEmpty(obj["why"]) ?? "limiter fault"
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// A string, or a JSON number shown as an integer (an HTTP status).
    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = number(value) { return Int(exactly: n.rounded()).map(String.init) ?? String(n) }
        return nil
    }

    private static let sane = 1e12

    private static func number(_ value: Any?) -> Double? {
        // A JSON boolean is not a number here.
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite && abs(v) <= sane ? v : nil
    }

    private static func count(_ value: Any?) -> Int? {
        guard let v = number(value) else { return nil }
        return Int(exactly: v.rounded(.towardZero))
    }
}

/// The words the strip, the popover and the job lines show. Pure, so each wording is tested without a window.
public enum MotherLimiterPresentation {
    public static let notRunningText = "limiter not running — fixed concurrency"

    /// `Limiter (observe) · 3 of 5 allowed · 4 running · backoff: +1 in 9m · last 429 6m ago`. In observe mode the
    /// numbers are what the limiter *would* do: `would allow 3 of 5`.
    public static func lineText(_ limiter: MotherLimiter) -> String {
        guard limiter.isShown else { return "" }
        let observe = limiter.mode == .observe
        var head = observe ? "Limiter (observe)" : "Limiter"
        if case .unknown(let raw) = limiter.mode { head = "Limiter (\(raw))" }
        var parts = [head]
        if limiter.isNotRunning { parts.append(notRunningText); return parts.joined(separator: " · ") }
        if let c = limiter.concurrency {
            if let allowed = c.allowed {
                let of = c.ceiling.map { " of \($0)" } ?? ""
                parts.append(observe ? "would allow \(allowed)\(of)" : "\(allowed)\(of) allowed")
            }
            if let running = c.effective { parts.append("\(running) running") }
            if let state = stateText(c) { parts.append(state) }
        }
        if let d = limiter.lastDistress { parts.append("last \(distressName(d)) \(ago(d.agoSeconds))") }
        return parts.joined(separator: " · ")
    }

    /// `backoff: +1 in 9m` (the broker's detail), or just the state; nil for a steady or unknown state.
    public static func stateText(_ c: MotherLimiter.Concurrency) -> String? {
        let name: String
        switch c.state {
        case .steady: return nil
        case .backoff: name = "backoff"
        case .ramp: name = "ramp"
        case .uncalibrated: name = "uncalibrated"
        case .unknown(let s): name = s.isEmpty ? "state unknown" : s
        }
        return c.detail.map { "\(name): \($0)" } ?? name
    }

    /// `429`, or the kind in words when there is no status.
    public static func distressName(_ d: MotherLimiter.Distress) -> String {
        d.status ?? d.kind.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "distress"
    }

    /// `6m ago`, `45s ago`, `2h ago`; `ago` alone for an unknown age.
    public static func ago(_ seconds: Int?) -> String {
        guard let s = seconds else { return "(time unknown)" }
        let v = max(0, s)
        if v < 60 { return "\(v)s ago" }
        if v < 3600 { return "\(v / 60)m ago" }
        if v < 86_400 { return "\(v / 3600)h ago" }
        return "\(v / 86_400)d ago"
    }

    /// The on-demand values, one `(title, value)` row each. A value the block did not carry is left out.
    public static func detailRows(_ limiter: MotherLimiter) -> [(title: String, value: String)] {
        var rows: [(String, String)] = []
        let would = limiter.mode == .observe
        if would { rows.append(("Mode", "observe: shows what the limiter would do, dispatch is unchanged")) }
        if limiter.isNotRunning {
            rows.append(("Status", notRunningText + (limiter.fault.map { " (\($0))" } ?? "")))
        }
        if let b = limiter.burn {
            var v: [String] = []
            if let f = b.fleetUsdPerMin, let s = b.sustainableUsdPerMin {
                v.append("$\(money(f))/min vs $\(money(s))/min sustainable")
            } else if let f = b.fleetUsdPerMin { v.append("$\(money(f))/min") }
            if let p = b.pace {
                let window: String
                switch b.window {
                case .fiveHour: window = " (5h window)"
                case .sevenDay: window = " (7d window)"
                case .unknown: window = ""
                }
                v.append("pace \(String(format: "%.2f", p))×\(window)")
            }
            if b.calibrated == false { v.append("not calibrated yet") }
            rows.append(("Burn", v.isEmpty ? "unknown" : v.joined(separator: " · ")))
        }
        if let r = limiter.reserve {
            var v: [String] = []
            if let pct = r.pct { v.append("\(plain(pct))% of 5h kept for interactive") }
            if let h = r.holding { v.append(h ? "holding" : "not holding") }
            if r.enforceable == false { v.append("advisory (not enforceable now)") }
            if !v.isEmpty { rows.append(("Reserve", v.joined(separator: " · "))) }
        }
        if let i = limiter.interactive {
            let state: String
            switch i.state {
            case .ok: state = "ok"
            case .high: state = "high"
            case .unknownState: state = "unknown"
            case .unknown(let s): state = s.isEmpty ? "unknown" : s
            }
            rows.append(("Interactive", i.pctPerHour.map { "\(state) · \(plain($0))%/h" } ?? state))
        }
        if let o = limiter.overageInUse { rows.append(("Overage", o ? "in use" : "not in use")) }
        if let g = limiter.gate {
            let name: String
            switch g {
            case .on: name = "on"
            case .off: name = "off"
            case .offUntilReset: name = "off until reset"
            case .unknown(let s): name = s.isEmpty ? "unknown" : s
            }
            rows.append(("Gate", name))
        }
        if let d = limiter.lastDistress {
            var v = [distressName(d), ago(d.agoSeconds)]
            if let k = d.kind { v.append(k.replacingOccurrences(of: "_", with: " ")) }
            if let j = d.jobId { v.append("job \(j)") }
            rows.append(("Last distress", v.joined(separator: " · ")))
        } else if limiter.distress24h != nil {
            rows.append(("Last distress", "none"))
        }
        if let n = limiter.distress24h { rows.append(("Distress, 24h", "\(n)")) }
        return rows
    }

    /// `Waiting: next to start`, plus `(would: reserve held for interactive work)` when the limiter's view differs.
    public static func waitText(_ wait: MotherLimiter.Waiting) -> String {
        var text = "Waiting: \(wait.reason)"
        if let would = wait.would, would.reason != wait.reason { text += " (would: \(would.reason))" }
        return text
    }

    private static func money(_ v: Double) -> String { String(format: "%.2f", v) }

    private static func plain(_ v: Double) -> String {
        if let whole = Int(exactly: v), abs(v) < 1e15 { return String(whole) }
        return String(format: "%.1f", v)
    }
}
