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

use crate::ipc::protocol::{DecisionChoice, FocusMeta, ServerMsg, SessionInfo};
use crate::mother::crew::{
    AttentionEntry, CrewDecision, CrewGates, CrewProgress, GateResultEntry, GateSignal, LensEntry,
    LensFindings, MovedBack, ProgressEta, ProgressFlag, ProgressSignals, ReviewWave,
};
use crate::mother::MotherJob;

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

fn ts_ok(s: &Option<String>) -> bool {
    s.as_deref()
        .is_none_or(|v| chrono::DateTime::parse_from_rfc3339(v).is_ok())
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
        attempt: g.attempt,
        max_attempts: g.max_attempts,
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
        cycle: w.cycle,
        cycle_cap: w.cycle_cap,
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
        coverage_gaps: w.coverage_gaps,
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
        v: p.v,
        pct: p.pct.map(|n| n.min(100)),
        stage: vocab_opt(&p.stage, STAGES),
        signals: p.signals.as_ref().map(|s| ProgressSignals {
            stage: vocab_opt(&s.stage, STAGES),
            gates: s.gates.as_ref().map(|g| GateSignal {
                passed: g.passed,
                failed: g.failed,
                total: g.total,
            }),
            elapsed_active_s: s.elapsed_active_s,
            cost: None,
        }),
        eta: p.eta.as_ref().map(|e| ProgressEta {
            lo_s: e.lo_s,
            hi_s: e.hi_s,
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

fn job_shape_ok(j: &MotherJob) -> bool {
    let blank = j.repo.is_empty()
        && j.isolation.is_empty()
        && j.title.is_empty()
        && j.created_at.is_none()
        && j.started_at.is_none()
        && j.finished_at.is_none()
        && j.plan_path.is_none()
        && j.question.is_none()
        && j.adherence_notes.is_none()
        && j.adherence_status.is_none()
        && j.current_tier.is_none()
        && j.current_activity.is_none()
        && j.kind.is_none()
        && j.phases.is_empty()
        && j.cycles.is_empty()
        && j.origin.is_none()
        && j.nostromo.is_none()
        && j.failure_reason.is_none()
        && j.actual_cost_usd.is_none()
        && j.pr_url.is_none()
        && j.last_answer.is_none()
        && j.criteria_source.is_none();
    let opt = |s: &Option<String>, set: &[&str]| s.as_deref().is_none_or(|v| in_vocab(v, set));
    let attn = |v: &[AttentionEntry]| {
        v.len() <= MAX_LIST
            && v.iter()
                .all(|a| in_vocab(&a.reason, REASONS) && ts_ok(&a.since))
    };
    blank
        && is_hex8(&j.id)
        && in_vocab(&j.state, STATES)
        && opt(&j.paused_reason, REASONS)
        && opt(&j.activity, REASONS)
        && attn(&j.attention)
        && attn(&j.attention_reasons)
        && j.gates.as_ref().is_none_or(|g| {
            g.mode.is_none()
                && g.posture.is_none()
                && g.head_sha.is_none()
                && g.started_at.is_none()
                && g.finished_at.is_none()
                && g.not_run.is_empty()
                && !g.overridden
                && opt(&g.status, RESULTS)
                && g.results.len() <= MAX_LIST
                && g.results.iter().all(|r| {
                    r.name.is_empty()
                        && in_vocab(&r.result, RESULTS)
                        && r.duration_s.is_none()
                        && r.exit_code.is_none()
                        && r.unavailable_reason.is_none()
                })
        })
        && j.review_wave.as_ref().is_none_or(|w| {
            w.mode.is_none()
                && w.budget_usd.is_none()
                && w.spent_usd.is_none()
                && w.adherence.is_none()
                && w.claims.is_none()
                && opt(&w.status, RESULTS)
                && w.lenses.len() <= MAX_LIST
                && w.lenses.iter().all(|l| {
                    l.reviewer.is_empty()
                        && l.lens.is_empty()
                        && in_vocab(&l.state, RESULTS)
                        && l.skip_reason.is_none()
                        && l.cost_usd.is_none()
                        && l.examined_files.is_none()
                        && u64::from(l.findings.blocking) <= MAX_COUNT
                        && u64::from(l.findings.advisory) <= MAX_COUNT
                })
        })
        && j.decision.as_ref().is_none_or(|d| {
            d.id.is_empty()
                && d.options.is_empty()
                && d.opened_at.is_none()
                && d.resolution.is_none()
                && in_vocab(&d.kind, REASONS)
                && d.resolved_at.as_deref().is_none_or(|r| r == "resolved")
        })
        && j.progress.as_ref().is_none_or(|p| {
            p.label.is_none()
                && p.updated_at.is_none()
                && p.pct.is_none_or(|n| n <= 100)
                && opt(&p.stage, STAGES)
                && p.signals
                    .as_ref()
                    .is_none_or(|s| s.cost.is_none() && opt(&s.stage, STAGES))
                && p.eta
                    .as_ref()
                    .is_none_or(|e| e.label.is_none() && opt(&e.basis, BASES))
                && p.moved_back
                    .as_ref()
                    .is_none_or(|m| m.at.is_none() && opt(&m.reason, REASONS))
                && p.flags.len() <= MAX_LIST
                && p.flags
                    .iter()
                    .all(|f| in_vocab(&f.reason, REASONS) && ts_ok(&f.since))
        })
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
pub fn redact_for_uplink_metadata(msg: ServerMsg, host_key: &[u8; 32]) -> Option<ServerMsg> {
    match msg {
        ServerMsg::MotherJobs { jobs, host } => Some(ServerMsg::MotherJobs {
            jobs: jobs
                .iter()
                .filter(|j| !j.is_work_send())
                .take(MAX_LIST)
                .map(|j| metadata_job(j, host_key))
                .collect(),
            host,
        }),
        ServerMsg::MotherStatusline(mut status) => {
            status.running = status.running.min(MAX_COUNT as usize);
            status.queued = status.queued.min(MAX_COUNT as usize);
            status.failed = status.failed.min(MAX_COUNT as usize);
            status.awaiting = status.awaiting.min(MAX_COUNT as usize);
            Some(ServerMsg::MotherStatusline(status))
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
                .take(MAX_LIST)
                .map(|s| metadata_session(s, host_key))
                .collect(),
            host,
        }),
        ServerMsg::FocusListResp { focuses, host } => Some(ServerMsg::FocusListResp {
            focuses: focuses
                .iter()
                .take(MAX_LIST)
                .map(|m| metadata_focus(m, host_key))
                .collect(),
            host,
        }),
        ServerMsg::FocusRegistryUpdated { focuses, host } => {
            Some(ServerMsg::FocusRegistryUpdated {
                focuses: focuses
                    .iter()
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
            counts,
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
