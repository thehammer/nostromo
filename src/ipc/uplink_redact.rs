//! What a `work` satellite may publish upstream: fixed-vocabulary metadata
//! only, never Carefeed text (W10; the sequencing memo's per-topic publish
//! table, `work` column).
//!
//! [`redact_for_uplink_metadata`] is an exhaustive match over every
//! `ServerMsg` variant (no `_` arm), so a new frame cannot be added without
//! deciding whether it may leave a work host. It rebuilds each allowed frame
//! from an allow-list of fields; anything it does not copy is blanked.
//! [`is_uplink_metadata_shape`] is the pure check the primary runs on what a
//! `work` satellite sent: re-running the redaction there would re-hash the
//! `f-` tags, so its output never equals its input.

use sha2::{Digest, Sha256};

use crate::ipc::peer::SensitiveTags;
use crate::ipc::protocol::{DecisionChoice, FocusMeta, ServerMsg, SessionInfo};
use crate::mother::crew::{
    AttentionEntry, CrewDecision, CrewGates, CrewProgress, GateResultEntry, GateSignal, LensEntry,
    LensFindings, MovedBack, ProgressEta, ProgressFlag, ProgressSignals, ReviewWave,
};
use crate::mother::{MotherJob, MotherStatus};

/// Job states Mother reports. Anything else is sent as `other`.
const STATES: &[&str] = &[
    "queued",
    "ready",
    "running",
    "awaiting",
    "paused",
    "succeeded",
    "failed",
    "cancelled",
    "canceled",
    "blocked",
];
/// Reason, activity, attention, flag and decision-kind words (Mother's crew
/// vocabulary). Anything else is sent as `other`.
const REASONS: &[&str] = &[
    "gate_hold",
    "gate_fix",
    "review_wave",
    "review_hold",
    "decision_awaiting",
    "gates",
    "review",
    "build",
    "rework",
    "present",
    "done",
    "decision",
    "question",
    "plan_review",
    "approval",
    "budget",
    "rate_limit",
    "quota",
    "auth",
    "stale",
    "conflict",
    "ci_failed",
    "gates_failed",
    "review_blocked",
    "blocked",
    "timeout",
    "crashed",
    "idle",
    "working",
    "waiting",
    "queued",
    "running",
    "failed",
    "cancelled",
    "none",
];
const STAGES: &[&str] = &["build", "rework", "gates", "review", "present", "done"];
const RESULTS: &[&str] = &[
    "passed",
    "failed",
    "skipped",
    "unavailable",
    "running",
    "pending",
    "overridden",
    "none",
];
const BASES: &[&str] = &["none", "history", "default", "fallback", "estimate"];
/// The agents a session can run as, by bare name. Another agent is `other`.
const AGENTS: &[&str] = &[
    "claude", "codex", "gemini", "cody", "perri", "redd", "marty", "ada", "archie", "mother",
    "huey", "bishop",
];
const BUCKETS: &[&str] = &["requested", "needs_review", "changes_req", "dependabot"];
const OTHER: &str = "other";
const MAX_COUNT: u64 = 100_000;
const MAX_LIST: usize = 512;

/// HMAC-SHA256 (RFC 2104) over `sha2`, for the pseudonymous tags.
fn hmac_sha256(key: &[u8; 32], msg: &[u8]) -> [u8; 32] {
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for (i, k) in key.iter().enumerate() {
        ipad[i] ^= k;
        opad[i] ^= k;
    }
    let inner = Sha256::new()
        .chain_update(ipad)
        .chain_update(msg)
        .finalize();
    Sha256::new()
        .chain_update(opad)
        .chain_update(inner)
        .finalize()
        .into()
}

fn hex8(bytes: &[u8]) -> String {
    bytes.iter().take(4).map(|b| format!("{b:02x}")).collect()
}

/// `f-` plus 8 hex of HMAC-SHA256(host_key, tag): stable per host, opaque
/// to everyone without the key.
pub fn pseudonymous_tag(host_key: &[u8; 32], tag: &str) -> String {
    format!("f-{}", hex8(&hmac_sha256(host_key, tag.as_bytes())))
}

/// A short, lower-case-hex reference to a Mother job: the id's last eight
/// characters when they are hex already, else a keyed hash of the id.
fn short_ref(host_key: &[u8; 32], id: &str) -> String {
    let tail: String = id
        .chars()
        .rev()
        .take(8)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if tail.len() == 8 && is_hex8(&tail) {
        tail
    } else {
        hex8(&hmac_sha256(host_key, id.as_bytes()))
    }
}

fn is_hex8(s: &str) -> bool {
    s.len() == 8
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_focus_tag(s: &str) -> bool {
    s.strip_prefix("f-").is_some_and(is_hex8)
}

fn in_vocab(s: &str, set: &[&str]) -> bool {
    s == OTHER || set.contains(&s)
}

fn vocab(s: &str, set: &[&str]) -> String {
    if set.contains(&s) {
        s.to_string()
    } else {
        OTHER.to_string()
    }
}

fn vocab_opt(s: &Option<String>, set: &[&str]) -> Option<String> {
    s.as_deref().map(|v| vocab(v, set))
}

fn agent(name: &str) -> String {
    let bare = name
        .trim()
        .rsplit(':')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    vocab(&bare, AGENTS)
}

/// A timestamp is kept only if it parses: it is a number, not text.
fn ts(s: &Option<String>) -> Option<String> {
    s.as_deref()
        .filter(|v| chrono::DateTime::parse_from_rfc3339(v).is_ok())
        .map(str::to_string)
}

fn cap32(n: Option<u32>) -> Option<u32> {
    n.map(|n| n.min(MAX_COUNT as u32))
}

fn cap64(n: Option<u64>) -> Option<u64> {
    n.map(|n| n.min(MAX_COUNT))
}

fn tag_ok_request_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

// ── Mother job ───────────────────────────────────────────────────────────────

fn metadata_job(job: &MotherJob, key: &[u8; 32]) -> MotherJob {
    let mut out = MotherJob {
        id: short_ref(key, &job.id),
        state: vocab(&job.state, STATES),
        paused_reason: vocab_opt(&job.paused_reason, REASONS),
        activity: vocab_opt(&job.activity, REASONS),
        crew_opt_in: job.crew_opt_in,
        ..MotherJob::default()
    };
    out.gates = job.gates.as_ref().map(|g| CrewGates {
        status: vocab_opt(&g.status, RESULTS),
        attempt: cap32(g.attempt),
        max_attempts: cap32(g.max_attempts),
        results: g
            .results
            .iter()
            .take(MAX_LIST)
            .map(|r| GateResultEntry {
                result: vocab(&r.result, RESULTS),
                blocking: r.blocking,
                ..GateResultEntry::default()
            })
            .collect(),
        ..CrewGates::default()
    });
    out.review_wave = job.review_wave.as_ref().map(|w| ReviewWave {
        cycle: cap32(w.cycle),
        cycle_cap: cap32(w.cycle_cap),
        status: vocab_opt(&w.status, RESULTS),
        lenses: w
            .lenses
            .iter()
            .take(MAX_LIST)
            .map(|l| LensEntry {
                state: vocab(&l.state, RESULTS),
                findings: LensFindings {
                    blocking: l.findings.blocking.min(MAX_COUNT as u32),
                    advisory: l.findings.advisory.min(MAX_COUNT as u32),
                },
                ..LensEntry::default()
            })
            .collect(),
        coverage_gaps: cap32(w.coverage_gaps),
        ..ReviewWave::default()
    });
    out.decision = job.decision.as_ref().map(|d| CrewDecision {
        kind: vocab(&d.kind, REASONS),
        resolved_at: d.resolved_at.as_ref().map(|_| "resolved".to_string()),
        ..CrewDecision::default()
    });
    let entries = |src: &[AttentionEntry]| -> Vec<AttentionEntry> {
        src.iter()
            .take(MAX_LIST)
            .map(|a| AttentionEntry {
                reason: vocab(&a.reason, REASONS),
                since: ts(&a.since),
                acked: a.acked,
            })
            .collect()
    };
    out.attention = entries(&job.attention);
    out.attention_reasons = entries(&job.attention_reasons);
    out.progress = job.progress.as_ref().map(|p| CrewProgress {
        v: cap32(p.v),
        pct: p.pct.map(|n| n.min(100)),
        stage: vocab_opt(&p.stage, STAGES),
        signals: p.signals.as_ref().map(|s| ProgressSignals {
            stage: vocab_opt(&s.stage, STAGES),
            gates: s.gates.as_ref().map(|g| GateSignal {
                passed: g.passed.min(MAX_COUNT as u32),
                failed: g.failed.min(MAX_COUNT as u32),
                total: g.total.min(MAX_COUNT as u32),
            }),
            elapsed_active_s: cap64(s.elapsed_active_s),
            cost: None,
        }),
        eta: p.eta.as_ref().map(|e| ProgressEta {
            lo_s: cap64(e.lo_s),
            hi_s: cap64(e.hi_s),
            label: None,
            basis: vocab_opt(&e.basis, BASES),
        }),
        paused: p.paused,
        moved_back: p.moved_back.as_ref().map(|m| MovedBack {
            reason: vocab_opt(&m.reason, REASONS),
            at: None,
        }),
        flags: p
            .flags
            .iter()
            .take(MAX_LIST)
            .map(|f| ProgressFlag {
                reason: vocab(&f.reason, REASONS),
                since: ts(&f.since),
            })
            .collect(),
        label: None,
        updated_at: None,
    });
    out
}

/// Is `j` exactly what [`metadata_job`] makes? The redaction is idempotent on
/// its own output (a ref that is already eight hex is kept whatever the key),
/// so a job passes only if redacting it changes nothing: every blanked field is
/// blank, every word is in its vocabulary, every list and number is within its
/// cap. A new `MotherJob` field the redaction does not copy is checked here
/// with no further edit.
fn job_shape_ok(j: &MotherJob) -> bool {
    is_hex8(&j.id) && metadata_job(j, &[0u8; 32]) == *j
}

// ── Focus and session frames ─────────────────────────────────────────────────

fn metadata_focus(m: &FocusMeta, key: &[u8; 32]) -> FocusMeta {
    let agent_name = agent(&m.agent_name);
    FocusMeta {
        tag: pseudonymous_tag(key, &m.tag),
        display_name: agent_name.clone(),
        agent_name,
        project_name: None,
        org: None,
        is_built_in: m.is_built_in,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
        initial_model: None,
        initial_effort: None,
        no_codebase: None,
    }
}

fn focus_shape_ok(m: &FocusMeta) -> bool {
    is_focus_tag(&m.tag)
        && in_vocab(&m.agent_name, AGENTS)
        && m.display_name == m.agent_name
        && m.project_name.is_none()
        && m.org.is_none()
        && m.session_summary.is_none()
        && m.label.is_none()
        && m.project_path.is_none()
        && m.select_for_client.is_none()
        && m.initial_model.is_none()
        && m.initial_effort.is_none()
        && m.no_codebase.is_none()
}

fn metadata_session(s: &SessionInfo, key: &[u8; 32]) -> SessionInfo {
    SessionInfo {
        tag: pseudonymous_tag(key, &s.tag),
        agent_name: agent(&s.agent_name),
        view_name: String::new(),
        session_id: None,
        alive: s.alive,
        remote_control: s.remote_control,
        state: s.state,
        stop_reason: None,
        mcp_bridge_connected: s.mcp_bridge_connected,
        agent_turns: None,
        agent_messages: None,
        agent_problems: None,
        activity_epoch: None,
        last_problem: None,
    }
}

fn session_shape_ok(s: &SessionInfo) -> bool {
    is_focus_tag(&s.tag)
        && in_vocab(&s.agent_name, AGENTS)
        && s.view_name.is_empty()
        && s.session_id.is_none()
        && s.stop_reason.is_none()
        && s.agent_turns.is_none()
        && s.agent_messages.is_none()
        && s.agent_problems.is_none()
        && s.activity_epoch.is_none()
        && s.last_problem.is_none()
}

/// The shape of `msg` as a `work` satellite may publish it, or `None` when
/// the frame may not leave a work host at all.
///
/// Frames that carry no `host` field (and so cannot be attributed on the
/// primary), transcripts, panes, approvals' content, Teri/Fred/work frames,
/// terminals and every administrative frame return `None`. The match has no
/// wildcard arm on purpose.
///
/// `tags` is the daemon's [`SensitiveTags`], the list the network redaction
/// uses. A pseudonymous tag looks the same for a Huey (sensitive) focus as for
/// any other, so the primary's shape check cannot catch it: nothing about a
/// sensitive focus leaves a `work` host. A focus-scoped frame for a sensitive
/// tag returns `None`; the list frames drop their sensitive sessions, focuses
/// and jobs.
pub fn redact_for_uplink_metadata(
    msg: ServerMsg,
    host_key: &[u8; 32],
    tags: &SensitiveTags,
) -> Option<ServerMsg> {
    match msg {
        ServerMsg::MotherJobs { jobs, host } => Some(ServerMsg::MotherJobs {
            jobs: jobs
                .iter()
                .filter(|j| !j.is_work_send() && !tags.job_is_sensitive(&j.id))
                .take(MAX_LIST)
                .map(|j| metadata_job(j, host_key))
                .collect(),
            host,
        }),
        ServerMsg::MotherStatusline(status) => Some(ServerMsg::MotherStatusline(MotherStatus {
            running: status.running.min(MAX_COUNT as usize),
            queued: status.queued.min(MAX_COUNT as usize),
            failed: status.failed.min(MAX_COUNT as usize),
            awaiting: status.awaiting.min(MAX_COUNT as usize),
            host: status.host,
        })),
        ServerMsg::PerriState { tag, .. } if tags.tag_is_sensitive(&tag) => None,
        ServerMsg::SessionState { tag, .. }
        | ServerMsg::SessionBridge { tag, .. }
        | ServerMsg::ApprovalPending { tag, .. }
        | ServerMsg::DecisionRequest { tag, .. }
        | ServerMsg::DecisionResolved { tag, .. }
        | ServerMsg::TrackerSummary { tag, .. }
            if tags.tag_is_sensitive(&tag) =>
        {
            None
        }
        ServerMsg::FocusCreated { meta, .. }
            if tags.focus_is_sensitive(&meta.tag, &meta.agent_name) =>
        {
            None
        }
        ServerMsg::PerriState {
            tag, queue, host, ..
        } => Some(ServerMsg::PerriState {
            tag: pseudonymous_tag(host_key, &tag),
            queue: queue
                .iter()
                .take(MAX_LIST)
                .map(|q| crate::data::perri_queue::PrQueueItem {
                    number: q.number,
                    bucket: vocab(&q.bucket, BUCKETS),
                    ..Default::default()
                })
                .collect(),
            current: None,
            jira_site: None,
            host,
        }),
        ServerMsg::SessionState { tag, state, host } => Some(ServerMsg::SessionState {
            tag: pseudonymous_tag(host_key, &tag),
            state,
            host,
        }),
        ServerMsg::SessionBridge {
            tag,
            connected,
            host,
        } => Some(ServerMsg::SessionBridge {
            tag: pseudonymous_tag(host_key, &tag),
            connected,
            host,
        }),
        ServerMsg::SessionListResp { sessions, host } => Some(ServerMsg::SessionListResp {
            sessions: sessions
                .iter()
                .filter(|s| !tags.focus_is_sensitive(&s.tag, &s.agent_name))
                .take(MAX_LIST)
                .map(|s| metadata_session(s, host_key))
                .collect(),
            host,
        }),
        ServerMsg::FocusListResp { focuses, host } => Some(ServerMsg::FocusListResp {
            focuses: focuses
                .iter()
                .filter(|m| !tags.focus_is_sensitive(&m.tag, &m.agent_name))
                .take(MAX_LIST)
                .map(|m| metadata_focus(m, host_key))
                .collect(),
            host,
        }),
        ServerMsg::FocusRegistryUpdated { focuses, host } => {
            Some(ServerMsg::FocusRegistryUpdated {
                focuses: focuses
                    .iter()
                    .filter(|m| !tags.focus_is_sensitive(&m.tag, &m.agent_name))
                    .take(MAX_LIST)
                    .map(|m| metadata_focus(m, host_key))
                    .collect(),
                host,
            })
        }
        ServerMsg::FocusCreated { meta, host } => Some(ServerMsg::FocusCreated {
            meta: metadata_focus(&meta, host_key),
            host,
        }),
        ServerMsg::ApprovalPending { tag, count, host } => Some(ServerMsg::ApprovalPending {
            tag: pseudonymous_tag(host_key, &tag),
            count: count.min(MAX_COUNT as u32),
            host,
        }),
        ServerMsg::DecisionRequest {
            tag,
            request_id,
            choices,
            host,
            ..
        } => {
            if !tag_ok_request_id(&request_id) {
                return None;
            }
            Some(ServerMsg::DecisionRequest {
                tag: pseudonymous_tag(host_key, &tag),
                request_id,
                prompt: String::new(),
                detail: None,
                choices: (0..choices.len().min(MAX_LIST))
                    .map(|i| DecisionChoice {
                        id: format!("c{i}"),
                        label: String::new(),
                        detail: None,
                        is_default: false,
                    })
                    .collect(),
                context_pane_id: None,
                host,
            })
        }
        ServerMsg::DecisionResolved {
            tag,
            request_id,
            resolution,
            host,
            ..
        } => {
            if !tag_ok_request_id(&request_id) {
                return None;
            }
            Some(ServerMsg::DecisionResolved {
                tag: pseudonymous_tag(host_key, &tag),
                request_id,
                resolution,
                choice_id: None,
                host,
            })
        }
        ServerMsg::TrackerSummary {
            tag,
            has_tracker,
            counts,
            host,
        } => Some(ServerMsg::TrackerSummary {
            tag: pseudonymous_tag(host_key, &tag),
            has_tracker,
            counts: crate::tracker::Counts {
                todo: counts.todo.min(MAX_COUNT as usize),
                in_progress: counts.in_progress.min(MAX_COUNT as usize),
                blocked: counts.blocked.min(MAX_COUNT as usize),
                needs_you: counts.needs_you.min(MAX_COUNT as usize),
                done: counts.done.min(MAX_COUNT as usize),
            },
            host,
        }),

        // Everything else stays on the host: no host field to attribute it
        // by, content, administration, or another peer's business.
        ServerMsg::Welcome { .. }
        | ServerMsg::Activity(..)
        | ServerMsg::TeriState { .. }
        | ServerMsg::MotherAwaitDetected(..)
        | ServerMsg::FredState { .. }
        | ServerMsg::Pong
        | ServerMsg::Error { .. }
        | ServerMsg::SessionSpawned { .. }
        | ServerMsg::SessionTurns { .. }
        | ServerMsg::SessionTurnDelta { .. }
        | ServerMsg::SessionTurnOrigin { .. }
        | ServerMsg::SessionPermissionRequest { .. }
        | ServerMsg::SessionExited { .. }
        | ServerMsg::SessionDown { .. }
        | ServerMsg::SessionSummaryUpdate { .. }
        | ServerMsg::MotherPeek { .. }
        | ServerMsg::FocusLayout { .. }
        | ServerMsg::PaneContent { .. }
        | ServerMsg::ApprovalRequest { .. }
        | ServerMsg::ApprovalPreview { .. }
        | ServerMsg::ApprovalsSnapshot { .. }
        | ServerMsg::ApprovalResolved { .. }
        | ServerMsg::ApprovalSessionRules { .. }
        | ServerMsg::ApprovalRules { .. }
        | ServerMsg::ApprovalGuardBlocked { .. }
        | ServerMsg::ApprovalsLogPage { .. }
        | ServerMsg::ApprovalsLogDetail { .. }
        | ServerMsg::ApprovalsLogRefused { .. }
        | ServerMsg::ApprovalAnswerRefused { .. }
        | ServerMsg::ClaudeLoginState { .. }
        | ServerMsg::PaneActionResult { .. }
        | ServerMsg::Notification { .. }
        | ServerMsg::ActivitySnapshot { .. }
        | ServerMsg::ActivityHealth { .. }
        | ServerMsg::WorkSourceStatus { .. }
        | ServerMsg::WorkSnapshot { .. }
        | ServerMsg::TeriPicks { .. }
        | ServerMsg::WorkDetail { .. }
        | ServerMsg::WorkSendPreview { .. }
        | ServerMsg::WorkSendResult { .. }
        | ServerMsg::Withheld { .. }
        | ServerMsg::ModelCatalog { .. }
        | ServerMsg::SessionModelState(..)
        | ServerMsg::ModelDefaults { .. }
        | ServerMsg::ModelRequestResult { .. }
        | ServerMsg::SessionQueue { .. }
        | ServerMsg::SessionQueueResult { .. }
        | ServerMsg::SessionQueueReturned { .. }
        | ServerMsg::SessionTasks { .. }
        | ServerMsg::SessionTaskDetail { .. }
        | ServerMsg::SessionCommands { .. }
        | ServerMsg::ConversationHistory { .. }
        | ServerMsg::ConversationResumeResult { .. }
        | ServerMsg::ConversationHistoryChanged { .. }
        | ServerMsg::ConversationResumeFailed { .. }
        | ServerMsg::SessionTaskStopResult { .. }
        | ServerMsg::SessionMcpResult { .. }
        | ServerMsg::SessionTaskOutputResult { .. }
        | ServerMsg::TrackerBoard { .. }
        | ServerMsg::TrackerEditResult { .. }
        | ServerMsg::TerminalList { .. }
        | ServerMsg::TerminalState { .. }
        | ServerMsg::TerminalClosed(..)
        | ServerMsg::TerminalReplay { .. }
        | ServerMsg::TerminalOutput { .. }
        | ServerMsg::TerminalRefused { .. }
        | ServerMsg::TerminalRemoteSummary { .. }
        | ServerMsg::TerminalStagingList { .. }
        | ServerMsg::RemoteShellTargets { .. }
        | ServerMsg::RemoteShellConfirmRequest { .. }
        | ServerMsg::RemoteShellResolved { .. }
        | ServerMsg::DaemonReconnected
        | ServerMsg::MotherNoticeState { .. }
        | ServerMsg::AuthoredPrPreview { .. }
        | ServerMsg::AuthoredPrNotifyResult { .. }
        | ServerMsg::AuthoredPrStartSessionResult { .. }
        | ServerMsg::AuthoredPrLinkResult { .. }
        | ServerMsg::AuthoredPrMergeResult { .. }
        | ServerMsg::AuthoredPrs { .. }
        | ServerMsg::PairOffer { .. }
        | ServerMsg::Paired { .. }
        | ServerMsg::PairRefused { .. }
        | ServerMsg::Unauthorized { .. }
        | ServerMsg::DeviceUnpaired
        | ServerMsg::DevicePairing { .. }
        | ServerMsg::DevicePairOutcome { .. }
        | ServerMsg::Devices { .. }
        | ServerMsg::DeviceRevoked { .. }
        | ServerMsg::DeviceAdminError { .. }
        | ServerMsg::Hosts { .. }
        | ServerMsg::HostUnavailable { .. }
        | ServerMsg::DeviceAdminLevel { .. } => None,
    }
}

/// Does `msg` have the shape [`redact_for_uplink_metadata`] produces (host
/// tag aside: the `f-` hashes cannot be recomputed here)? A pure check on
/// what the primary received from a `work` satellite: every field the
/// metadata function blanks is absent or empty, every focus tag is `f-` and
/// eight hex, every job ref is eight hex, every enum is in its vocabulary
/// (or `other`), counts are bounded. Variants outside the metadata set are
/// `false`.
pub fn is_uplink_metadata_shape(msg: &ServerMsg) -> bool {
    match msg {
        ServerMsg::MotherJobs { jobs, .. } => {
            jobs.len() <= MAX_LIST && jobs.iter().all(job_shape_ok)
        }
        ServerMsg::MotherStatusline(s) => [s.running, s.queued, s.failed, s.awaiting]
            .iter()
            .all(|n| *n as u64 <= MAX_COUNT),
        ServerMsg::PerriState {
            tag,
            queue,
            current,
            jira_site,
            ..
        } => {
            is_focus_tag(tag)
                && current.is_none()
                && jira_site.is_none()
                && queue.len() <= MAX_LIST
                && queue.iter().all(|q| {
                    in_vocab(&q.bucket, BUCKETS)
                        && q.repo.is_empty()
                        && q.title.is_empty()
                        && q.author.is_empty()
                        && q.url.is_empty()
                        && q.head_sha.is_empty()
                        && q.tickets.is_empty()
                        && !q.new_activity
                        && !q.is_bot
                })
        }
        ServerMsg::SessionState { tag, .. } | ServerMsg::SessionBridge { tag, .. } => {
            is_focus_tag(tag)
        }
        ServerMsg::SessionListResp { sessions, .. } => {
            sessions.len() <= MAX_LIST && sessions.iter().all(session_shape_ok)
        }
        ServerMsg::FocusListResp { focuses, .. }
        | ServerMsg::FocusRegistryUpdated { focuses, .. } => {
            focuses.len() <= MAX_LIST && focuses.iter().all(focus_shape_ok)
        }
        ServerMsg::FocusCreated { meta, .. } => focus_shape_ok(meta),
        ServerMsg::ApprovalPending { tag, count, .. } => {
            is_focus_tag(tag) && u64::from(*count) <= MAX_COUNT
        }
        ServerMsg::DecisionRequest {
            tag,
            request_id,
            prompt,
            detail,
            choices,
            context_pane_id,
            ..
        } => {
            is_focus_tag(tag)
                && tag_ok_request_id(request_id)
                && prompt.is_empty()
                && detail.is_none()
                && context_pane_id.is_none()
                && choices.len() <= MAX_LIST
                && choices.iter().enumerate().all(|(i, c)| {
                    c.id == format!("c{i}")
                        && c.label.is_empty()
                        && c.detail.is_none()
                        && !c.is_default
                })
        }
        ServerMsg::DecisionResolved {
            tag,
            request_id,
            choice_id,
            ..
        } => is_focus_tag(tag) && tag_ok_request_id(request_id) && choice_id.is_none(),
        ServerMsg::TrackerSummary { tag, counts, .. } => {
            is_focus_tag(tag)
                && [
                    counts.todo,
                    counts.in_progress,
                    counts.blocked,
                    counts.needs_you,
                    counts.done,
                ]
                .iter()
                .all(|n| *n as u64 <= MAX_COUNT)
        }
        _ => false,
    }
}
