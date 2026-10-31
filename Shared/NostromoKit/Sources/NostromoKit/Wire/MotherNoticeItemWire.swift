import Foundation

/// One job of a Mother job notice: `TurnOrigin::MotherJobNotice` in the daemon
/// (`{"type":"mother_job_notice","items":[…]}`).
///
/// Display data only, and untrusted: `title` is whatever a plan or a job was called. Nothing here is
/// drawn as markup; `WakeMarkerText` sanitises and caps it.
public struct MotherNoticeItemWire: Codable, Equatable {
    public let jobId:    String
    /// The job's title; empty when the wire has none.
    public let title:    String
    /// The job's state as the daemon names it (`succeeded`, `failed`, `awaiting`, …). An unknown
    /// state is kept as text.
    public let state:    String
    /// The states the job passed through since the last notice, oldest first.
    public let since:    [String]
    public let prUrl:    String?
    public let prNumber: Int?

    public init(jobId: String, title: String, state: String, since: [String] = [],
                prUrl: String? = nil, prNumber: Int? = nil) {
        self.jobId = jobId
        self.title = title
        self.state = state
        self.since = since
        self.prUrl = prUrl
        self.prNumber = prNumber
    }

    enum CodingKeys: String, CodingKey {
        case jobId    = "job_id"
        case title, state, since
        case prUrl    = "pr_url"
        case prNumber = "pr_number"
    }

    /// Tolerant: a missing `title` is `""`, a missing `since` is empty and a missing PR is nil.
    /// An item with no job id (or no state) is not one and throws, so the origin skips it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let jobId = try c.decode(String.self, forKey: .jobId)
        guard !jobId.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .jobId, in: c, debugDescription: "empty job id")
        }
        self.init(jobId: jobId,
                  title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "",
                  state: try c.decode(String.self, forKey: .state),
                  since: (try? c.decodeIfPresent([String].self, forKey: .since)) ?? [],
                  prUrl: (try? c.decodeIfPresent(String.self, forKey: .prUrl)) ?? nil,
                  prNumber: (try? c.decodeIfPresent(Int.self, forKey: .prNumber)) ?? nil)
    }
}
