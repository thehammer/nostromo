//! The wire types of the authored-PR list (`ServerMsg::AuthoredPrs`).
//!
//! Every string that came from GitHub is sanitised with `one_line` and bounded
//! when a row is built (in the engine's `build`); the
//! types here only carry the result. Kit decodes leniently, so every optional
//! field is skipped when absent. The in-memory head branch and the full head SHA are not
//! fields of anything in this file, on purpose: they never reach the wire (a row
//! carries `head_sha_short`, eight hex digits, and nothing more of it).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub use super::verdicts::Verdict;

pub const MAX_PRS: usize = 100;
pub const MAX_TITLE: usize = 300;
pub const MAX_BASE_REF: usize = 100;
pub const MAX_NAME: usize = 120;
pub const MAX_CHECK_NAME: usize = 100;
pub const MAX_FAILING_NAMES: usize = 20;
pub const MAX_LOGINS: usize = 10;
pub const MAX_CANDIDATES: usize = 8;
pub const MAX_HIDDEN_ORGS: usize = 10;
pub const MAX_ORG_NAME: usize = 60;
pub const MAX_NEW_COMMENTS: u32 = 999;
pub const MAX_QUEUE_POSITION: u64 = 9999;

/// How GitHub takes this PR in: a direct squash merge, or through the base
/// branch's merge queue. Absent on the wire when the daemon could not read it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeVia {
    Direct,
    Queue,
}

/// A queued PR's entry state (GitHub's `MergeQueueEntryState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueueState {
    Queued,
    AwaitingChecks,
    Mergeable,
    Unmergeable,
    Locked,
    Unknown,
}

/// A PR that is in its merge queue: the state and, when GitHub says, the
/// 1-based position (bounded). Nothing else of the entry reaches the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueRow {
    pub state: QueueState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenState {
    Connected,
    Missing,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelayState {
    Live,
    CatchingUp,
    Offline,
    NotConfigured,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RelayInfo {
    pub state: RelayState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<DateTime<Utc>>,
    pub org: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PollState {
    Ok,
    Checking,
    RateLimited,
    Paused,
    Error,
    Idle,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PollInfo {
    pub state: PollState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<DateTime<Utc>>,
    pub interval_secs: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumes_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefreshBlocked {
    Running,
    RateLimited,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Group {
    NeedsYou,
    Ready,
    Waiting,
    Draft,
}

impl Group {
    /// Display order: Needs you, Ready, Waiting, Drafts.
    pub fn rank(self) -> u8 {
        match self {
            Group::NeedsYou => 0,
            Group::Ready => 1,
            Group::Waiting => 2,
            Group::Draft => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    Open,
    Merged,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChecksState {
    Passing,
    Failing,
    Pending,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Checks {
    pub state: ChecksState,
    pub passed: u32,
    pub failed: u32,
    pub pending: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failing_names: Vec<String>,
}

impl Checks {
    pub fn none() -> Self {
        Checks {
            state: ChecksState::None,
            passed: 0,
            failed: 0,
            pending: 0,
            failing_names: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewState {
    Approved,
    ChangesRequested,
    ReviewRequested,
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Review {
    pub state: ReviewState,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub logins: Vec<String>,
}

impl Review {
    pub fn none() -> Self {
        Review {
            state: ReviewState::None,
            logins: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OwnerKind {
    MotherJob,
    /// A link the user made from the picker.
    Linked,
    OnBranch,
    Ambiguous,
    Closed,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Via {
    MotherJob,
    Linked,
    OnBranch,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Candidate {
    pub tag: String,
    pub name: String,
    pub via: Via,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    /// This candidate's focus has been closed (sent only when true), so the
    /// list can say which of the candidates can no longer be switched to.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub closed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Owner {
    pub kind: OwnerKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<Via>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub candidates: Vec<Candidate>,
}

impl Owner {
    pub fn unknown() -> Self {
        Owner {
            kind: OwnerKind::Unknown,
            tag: None,
            name: None,
            job_id: None,
            via: None,
            candidates: Vec::new(),
        }
    }
}

/// The focus last told about this PR, and when.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Told {
    pub tag: String,
    pub name: String,
    pub at: DateTime<Utc>,
}

/// Perri's verdict on this PR, as the row shows it: the newest one for the
/// current head when there is one, else the newest one for an older head (the
/// app says "approved an older version"). The note and the full SHA stay in
/// the daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PerriRow {
    pub verdict: Verdict,
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    /// The verdict is for the commit the PR is at now.
    pub for_current_head: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredPr {
    /// `owner/name`.
    pub repo: String,
    pub number: u64,
    /// Rebuilt from the repo and number, never GitHub's own string.
    pub url: String,
    pub title: String,
    pub draft: bool,
    pub updated_at: DateTime<Utc>,
    pub group: Group,
    pub lifecycle: Lifecycle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub details_unavailable: bool,
    pub checks: Checks,
    pub review: Review,
    pub new_comments: u32,
    pub unresolved_threads: u32,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub threads_truncated: bool,
    pub owner: Owner,
    /// Who was last told (a notify the user sent); absent when nobody was.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub told: Option<Told>,
    /// This PR needs the user's attention and its known, open owner has not
    /// been told about the current state: the Mac raises one waiting pill.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub pill: bool,
    /// The first 8 hex digits of the PR's head commit, when the daemon knows it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_sha_short: Option<String>,
    /// Perri's verdict, when one was recorded for this PR.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub perri: Option<PerriRow>,
    /// How the Merge button will take the PR in. Absent when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merge_via: Option<MergeVia>,
    /// Present while the PR is in its merge queue.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue: Option<QueueRow>,
    /// A hash of the facts a notify recorded; stays in the daemon.
    #[serde(skip)]
    pub attention_key: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct UsageCounts {
    pub charged: u64,
    pub not_modified: u64,
    pub search: u64,
    pub graphql_points: u64,
    pub relay_charged: u64,
    pub visible_charged: u64,
    pub hidden_charged: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageView {
    pub window_secs: u64,
    #[serde(flatten)]
    pub window: UsageCounts,
    pub since_start: UsageCounts,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredPrsSnapshot {
    pub generated_at: DateTime<Utc>,
    pub token: TokenState,
    pub relay: RelayInfo,
    pub poll: PollInfo,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_blocked: Option<RefreshBlocked>,
    #[serde(default)]
    pub hidden_orgs: Vec<String>,
    pub total_open: u32,
    pub shown: u32,
    pub prs: Vec<AuthoredPr>,
    pub usage: UsageView,
}

/// A GitHub login as the API allows it (with an optional `[bot]` suffix).
pub fn valid_login(s: &str) -> bool {
    let core = s.strip_suffix("[bot]").unwrap_or(s);
    !core.is_empty()
        && core.len() <= 39
        && core.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// An owner or repo name as GitHub allows it.
pub fn safe_segment(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        && s != "."
        && s != ".."
}

/// `owner/name`, each part passing [`safe_segment`].
pub fn valid_repo(s: &str) -> bool {
    match s.split_once('/') {
        Some((o, n)) => safe_segment(o) && safe_segment(n),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    //! The wire vocabulary: what a login or a repo may look like, the display
    //! order of groups, and the words each state is spelled with.

    use super::*;

    #[test]
    fn a_login_is_one_to_thirty_nine_alphanumerics_or_hyphens_with_an_optional_bot_suffix() {
        let re = regex::Regex::new(r"^[A-Za-z0-9-]{1,39}(\[bot\])?$").unwrap();
        let long_ok = "a".repeat(39);
        let too_long = "a".repeat(40);
        let corpus = [
            "alice",
            "Alice-Bob-9",
            "-",
            "a",
            long_ok.as_str(),
            too_long.as_str(),
            "dependabot[bot]",
            "[bot]",
            "x[bot][bot]",
            "bot[bot]x",
            "",
            " alice",
            "alice ",
            "ali ce",
            "alice\n",
            "ali_ce",
            "ali.ce",
            "alicé",
            "../etc",
            "a/b",
            "<script>",
            "alice[BOT]",
            "alice[bot",
        ];
        for s in corpus {
            assert_eq!(valid_login(s), re.is_match(s), "{s:?}");
        }
    }

    #[test]
    fn a_segment_is_a_safe_owner_or_repo_name() {
        assert!(safe_segment("app"));
        assert!(safe_segment("my-repo_2.0"));
        assert!(safe_segment(&"a".repeat(100)));
        assert!(!safe_segment(&"a".repeat(101)));
        for bad in [
            "", ".", "..", "a b", "a/b", "a\\b", "a?b", "a#b", "a%2fb", "a\n", "é", "a:b", "a\"b",
            "a{b}",
        ] {
            assert!(!safe_segment(bad), "{bad:?}");
        }
        assert!(safe_segment("..a"), "only exactly `..` is a climb");
    }

    #[test]
    fn a_repo_is_owner_slash_name_with_both_parts_safe() {
        assert!(valid_repo("Carefeed/admin-portal"));
        assert!(valid_repo("thehammer/nostromo"));
        for bad in [
            "", "owner", "owner/", "/name", "a/b/c", "a b/c", "o/..", "../n", "o/n\"){", "o/n\n",
        ] {
            assert!(!valid_repo(bad), "{bad:?}");
        }
    }

    #[test]
    fn groups_display_as_needs_you_then_ready_then_waiting_then_drafts() {
        let mut groups = vec![Group::Draft, Group::Waiting, Group::Ready, Group::NeedsYou];
        groups.sort_by_key(|g| g.rank());
        assert_eq!(
            groups,
            vec![Group::NeedsYou, Group::Ready, Group::Waiting, Group::Draft]
        );
    }

    #[test]
    fn states_are_spelled_in_snake_case_on_the_wire() {
        fn word<T: Serialize>(v: T) -> String {
            serde_json::to_value(v)
                .unwrap()
                .as_str()
                .unwrap()
                .to_owned()
        }
        assert_eq!(word(Group::NeedsYou), "needs_you");
        assert_eq!(word(Group::Draft), "draft");
        assert_eq!(word(Lifecycle::Merged), "merged");
        assert_eq!(word(ChecksState::Failing), "failing");
        assert_eq!(word(ReviewState::ChangesRequested), "changes_requested");
        assert_eq!(word(ReviewState::ReviewRequested), "review_requested");
        assert_eq!(word(OwnerKind::MotherJob), "mother_job");
        assert_eq!(word(OwnerKind::OnBranch), "on_branch");
        assert_eq!(word(Via::MotherJob), "mother_job");
        assert_eq!(word(RelayState::CatchingUp), "catching_up");
        assert_eq!(word(RelayState::NotConfigured), "not_configured");
        assert_eq!(word(PollState::RateLimited), "rate_limited");
        assert_eq!(word(TokenState::Rejected), "rejected");
        assert_eq!(word(RefreshBlocked::RateLimited), "rate_limited");
    }

    #[test]
    fn optional_fields_are_absent_not_null_when_empty() {
        let pr = AuthoredPr {
            repo: "o/n".into(),
            number: 1,
            url: "https://github.com/o/n/pull/1".into(),
            title: "t".into(),
            draft: false,
            updated_at: chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap(),
            group: Group::Waiting,
            lifecycle: Lifecycle::Open,
            ended_at: None,
            base_ref: None,
            details_unavailable: false,
            checks: Checks::none(),
            review: Review::none(),
            new_comments: 0,
            unresolved_threads: 0,
            threads_truncated: false,
            owner: Owner::unknown(),
            told: None,
            pill: false,
            head_sha_short: None,
            perri: None,
            merge_via: None,
            queue: None,
            attention_key: String::new(),
        };
        let v = serde_json::to_value(&pr).unwrap();
        let obj = v.as_object().unwrap();
        for absent in [
            "ended_at",
            "base_ref",
            "details_unavailable",
            "threads_truncated",
            "told",
            "pill",
            "attention_key",
        ] {
            assert!(!obj.contains_key(absent), "{absent} should be absent: {v}");
        }
        assert!(!obj["checks"]
            .as_object()
            .unwrap()
            .contains_key("failing_names"));
        assert!(!obj["review"].as_object().unwrap().contains_key("logins"));
        assert_eq!(obj["owner"], serde_json::json!({"kind": "unknown"}));
        // The head branch and SHA are not a field of the row at all.
        assert!(!v.to_string().contains("head"), "{v}");
    }

    #[test]
    fn the_limits_are_the_documented_ones() {
        assert_eq!(MAX_PRS, 100);
        assert_eq!(MAX_TITLE, 300);
        assert_eq!(MAX_CANDIDATES, 8);
        assert_eq!(MAX_LOGINS, 10);
        assert_eq!(MAX_NEW_COMMENTS, 999);
        assert_eq!(MAX_FAILING_NAMES, 20);
    }
}
