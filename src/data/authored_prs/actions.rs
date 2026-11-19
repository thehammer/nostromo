//! What the hand-off verbs need from the PR list, apart from sockets and
//! sessions: the current row of a PR, the facts a notice may use, the told and
//! link records, and the suggestions "Start a session…" prefills.
//!
//! Nothing here logs: a PR's repo, number, check names, logins, focus names and
//! the message text never reach a log line.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;

use super::links::{key_string, AuthoredPrStore};
use super::memory::FocusMemory;
use super::merge::MergeBook;
use super::notice::{compose, digest, PrFacts};
use super::ownership::PrKey;
use super::snapshot::{AuthoredPr, AuthoredPrsSnapshot, Lifecycle, OwnerKind, ReviewState};
use super::verdicts::{short_sha, Verdict, VerdictRecord, VerdictStore};
use super::wire::{AuthoredPrResult, LastTold, StartOk};
use super::working_copy::{find_transcript, first_cwd, working_copy_at};
use super::{ApiSlot, Clock, DemandBoard};
use crate::mother::origin::SessionHistory;

const REMEMBERED_STARTS: usize = 64;
/// How long a verdict for a head the daemon does not hold waits for the PR to
/// be read again.
const REFRESH_WAIT: Duration = Duration::from_secs(4);
/// How long a delivered preview stays spent, and how many are remembered.
const SENT_TTL_SECS: i64 = 600;
const REMEMBERED_SENDS: usize = 64;

/// One delivered preview: the PR, who it went to (`new` for a new session),
/// and the digest of the text.
struct SentMark {
    pr: String,
    target: String,
    digest: String,
    at: chrono::DateTime<chrono::Utc>,
}

pub struct AuthoredPrActions {
    board: Arc<DemandBoard>,
    pub(super) snapshot: watch::Receiver<Option<AuthoredPrsSnapshot>>,
    store: Arc<AuthoredPrStore>,
    memory: Arc<FocusMemory>,
    projects_root: PathBuf,
    agents_dir: PathBuf,
    pub(super) clock: Arc<dyn Clock>,
    /// Perri's verdicts on PR heads.
    pub(super) verdicts: Arc<VerdictStore>,
    /// The engine's GitHub client: the Merge verb uses the same token.
    pub(super) api: ApiSlot,
    /// Merges in flight and answered.
    pub(super) merges: MergeBook,
    /// How long `record_verdict` waits for its one refresh to show up.
    refresh_wait: Duration,
    starts: Mutex<VecDeque<(String, AuthoredPrResult<StartOk>)>>,
    /// Previews already sent, so a replayed send (a dropped connection and a
    /// second press) delivers nothing. A new preview of the PR re-arms it.
    sent: Mutex<VecDeque<SentMark>>,
    /// Held for a whole "start a session", so two requests with one id cannot
    /// both create a focus.
    pub start_gate: tokio::sync::Mutex<()>,
}

/// What a message is composed from, with the row it came from.
pub struct Composed {
    pub text: String,
    pub digest: String,
    pub row: AuthoredPr,
}

impl AuthoredPrActions {
    pub fn new(
        handle: &super::AuthoredPrsHandle,
        projects_root: PathBuf,
        agents_dir: PathBuf,
        clock: Arc<dyn Clock>,
    ) -> Self {
        Self::from_parts(
            Arc::clone(&handle.demand),
            handle.snapshot.clone(),
            Arc::clone(&handle.store),
            Arc::clone(&handle.memory),
            projects_root,
            agents_dir,
            clock,
        )
        .with_merge(Arc::clone(&handle.verdicts), Arc::clone(&handle.api))
    }

    /// Share Perri's verdicts and the engine's GitHub client with the verbs
    /// (`from_parts` starts with an empty verdict store and no client).
    pub fn with_merge(mut self, verdicts: Arc<VerdictStore>, api: ApiSlot) -> Self {
        self.verdicts = verdicts;
        self.api = api;
        self
    }

    /// Wait `wait` (not the default few seconds) for the refresh a verdict for
    /// an unseen head asks for.
    pub fn with_refresh_wait(mut self, wait: Duration) -> Self {
        self.refresh_wait = wait;
        self
    }

    /// The same from its parts, for a test that feeds the snapshot itself.
    pub fn from_parts(
        board: Arc<DemandBoard>,
        snapshot: watch::Receiver<Option<AuthoredPrsSnapshot>>,
        store: Arc<AuthoredPrStore>,
        memory: Arc<FocusMemory>,
        projects_root: PathBuf,
        agents_dir: PathBuf,
        clock: Arc<dyn Clock>,
    ) -> Self {
        AuthoredPrActions {
            board,
            snapshot,
            store,
            memory,
            projects_root,
            agents_dir,
            clock,
            verdicts: Arc::new(VerdictStore::in_memory()),
            api: Arc::new(Mutex::new(None)),
            merges: MergeBook::default(),
            refresh_wait: REFRESH_WAIT,
            starts: Mutex::new(VecDeque::new()),
            sent: Mutex::new(VecDeque::new()),
            start_gate: tokio::sync::Mutex::new(()),
        }
    }

    pub fn store(&self) -> &Arc<AuthoredPrStore> {
        &self.store
    }

    /// The open PR `repo#number` in the latest snapshot (repo compared
    /// case-insensitively).
    pub fn row(&self, repo: &str, number: u64) -> Option<AuthoredPr> {
        let snap = self.snapshot.borrow();
        snap.as_ref()?
            .prs
            .iter()
            .find(|p| {
                p.number == number
                    && p.repo.eq_ignore_ascii_case(repo)
                    && p.lifecycle == Lifecycle::Open
            })
            .cloned()
    }

    pub fn verdicts(&self) -> &Arc<VerdictStore> {
        &self.verdicts
    }

    /// Record Perri's verdict on `head_sha` of `repo#number`. It only records:
    /// it never merges and never talks to GitHub.
    ///
    /// An `approved` is only taken for the head the daemon holds for the PR
    /// (the first 8 hex digits the row carries): a verdict for a commit nobody
    /// has pushed, or the daemon has not seen, would count the moment that
    /// commit became the head. When the head does not match, the PR is asked
    /// to be read once (the poll can lag a fresh push) and the check is made
    /// again; still no match is refused. A `changes_requested` or `comment`
    /// can only block, so it is recorded either way, and the answer says
    /// whether it is for the current head.
    ///
    /// Ok: whether the verdict is for the PR's current head. Error: a code,
    /// `invalid` (`repo`, `number` or `head_sha` is not valid), `pr_unknown`
    /// (the PR is not in the daemon's list) or `head_not_current`.
    pub async fn record_verdict(
        &self,
        repo: &str,
        number: u64,
        head_sha: &str,
        verdict: Verdict,
        by: Option<&str>,
        note: Option<&str>,
    ) -> Result<bool, &'static str> {
        let rec = VerdictRecord::new(repo, number, head_sha, verdict, self.clock.now(), by, note)
            .ok_or("invalid")?;
        let mut current = self.is_current_head(repo, number, head_sha);
        if current != Some(true) && verdict == Verdict::Approved {
            self.refresh_pr(repo, number, head_sha).await;
            current = self.is_current_head(repo, number, head_sha);
        }
        if current != Some(true) && verdict == Verdict::Approved {
            return Err(match current {
                None => "pr_unknown",
                Some(_) => "head_not_current",
            });
        }
        self.verdicts.record(rec);
        // The row shows the verdict: publish (the engine reads the PR again).
        self.board.pr_changed(PrKey {
            repo: repo.to_ascii_lowercase(),
            number,
        });
        Ok(current == Some(true))
    }

    /// Is `head_sha` the head the snapshot holds for `repo#number`? `None`: the
    /// PR is not in the snapshot.
    fn is_current_head(&self, repo: &str, number: u64, head_sha: &str) -> Option<bool> {
        let row = self.row_any(repo, number)?;
        Some(match (row.head_sha_short.as_deref(), short_sha(head_sha)) {
            (Some(held), Some(given)) => held == given,
            _ => false,
        })
    }

    /// Ask the engine to read the PR now and wait (a few seconds at most) for
    /// the snapshot to show `head_sha` for it. A PR not in the list asks for a
    /// full reconcile instead: it may be new.
    async fn refresh_pr(&self, repo: &str, number: u64, head_sha: &str) {
        let mut rx = self.snapshot.clone();
        // Whatever is in the snapshot now was checked already.
        rx.mark_unchanged();
        if self.is_current_head(repo, number, head_sha) == Some(true) {
            return;
        }
        if self.row_any(repo, number).is_some() {
            self.board.pr_changed(PrKey {
                repo: repo.to_ascii_lowercase(),
                number,
            });
        } else {
            self.board.refresh();
        }
        let _ = tokio::time::timeout(self.refresh_wait, async {
            while rx.changed().await.is_ok() {
                if self.is_current_head(repo, number, head_sha) == Some(true) {
                    return;
                }
            }
        })
        .await;
    }

    /// Compose the message from the current facts. Error: a wire code.
    pub fn compose_for(&self, repo: &str, number: u64) -> Result<Composed, &'static str> {
        let row = self.row(repo, number).ok_or("unknown_pr")?;
        let facts = PrFacts {
            repo: row.repo.clone(),
            number: row.number,
            failing_checks: row.checks.failing_names.clone(),
            failed_count: row.checks.failed,
            change_requesters: if row.review.state == ReviewState::ChangesRequested {
                row.review.logins.clone()
            } else {
                Vec::new()
            },
            changes_requested: row.review.state == ReviewState::ChangesRequested,
            new_comments: row.new_comments,
            unresolved_threads: row.unresolved_threads,
        };
        let text = compose(&facts).map_err(|e| e.code())?;
        Ok(Composed {
            digest: digest(&text),
            text,
            row,
        })
    }

    pub fn last_told(row: &AuthoredPr) -> Option<LastTold> {
        row.told.as_ref().map(|t| LastTold {
            name: t.name.clone(),
            at: t.at,
        })
    }

    pub(super) fn changed(&self, row: &AuthoredPr) {
        self.board.pr_changed(PrKey {
            repo: row.repo.to_ascii_lowercase(),
            number: row.number,
        });
    }

    /// The owner of `row` was told: remember it and publish.
    pub fn record_told(&self, row: &AuthoredPr, tag: &str) {
        self.store.told(
            &key_string(&row.repo, row.number),
            tag,
            self.clock.now(),
            &row.attention_key,
        );
        self.changed(row);
    }

    /// Link the PR to `tag`, or unlink it (`None`). `false` when the PR is not
    /// in the list.
    pub fn set_link(&self, repo: &str, number: u64, tag: Option<&str>) -> bool {
        let Some(row) = self.row(repo, number) else {
            return false;
        };
        let key = key_string(&row.repo, row.number);
        match tag {
            Some(tag) => self.store.link(&key, tag, self.clock.now()),
            None => {
                self.store.unlink(&key);
            }
        }
        self.changed(&row);
        true
    }

    /// The result an earlier `start` with this id gave.
    pub fn remembered_start(&self, request_id: &str) -> Option<AuthoredPrResult<StartOk>> {
        self.starts
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .find(|(id, _)| id == request_id)
            .map(|(_, r)| r.clone())
    }

    pub fn remember_start(&self, request_id: &str, result: &AuthoredPrResult<StartOk>) {
        let mut g = self.starts.lock().unwrap_or_else(|e| e.into_inner());
        g.push_back((request_id.to_owned(), result.clone()));
        while g.len() > REMEMBERED_STARTS {
            g.pop_front();
        }
    }

    /// Spend the preview (`repo#number`, `target`, `digest`) before delivering
    /// it. `false` when it was already spent in the last ten minutes and not
    /// previewed again since: the caller answers `already_sent` and delivers
    /// nothing. Taken and checked in one step, so two sends at once cannot
    /// both pass. Give it back with [`release_send`](Self::release_send) when
    /// the delivery fails.
    pub fn claim_send(&self, repo: &str, number: u64, target: &str, digest: &str) -> bool {
        let now = self.clock.now();
        let pr = key_string(repo, number);
        let mut g = self.sent.lock().unwrap_or_else(|e| e.into_inner());
        g.retain(|m| now - m.at < chrono::Duration::seconds(SENT_TTL_SECS));
        if g.iter()
            .any(|m| m.pr == pr && m.target == target && m.digest == digest)
        {
            return false;
        }
        g.push_back(SentMark {
            pr,
            target: target.to_owned(),
            digest: digest.to_owned(),
            at: now,
        });
        while g.len() > REMEMBERED_SENDS {
            g.pop_front();
        }
        true
    }

    /// Undo [`claim_send`](Self::claim_send): nothing was delivered.
    pub fn release_send(&self, repo: &str, number: u64, target: &str, digest: &str) {
        let pr = key_string(repo, number);
        self.sent
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|m| !(m.pr == pr && m.target == target && m.digest == digest));
    }

    /// The PR was previewed again: its earlier sends are no longer spent.
    pub fn rearm_sends(&self, repo: &str, number: u64) {
        let pr = key_string(repo, number);
        self.sent
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|m| m.pr != pr);
    }

    /// Is `agent` a name `~/.claude/agents` offers?
    pub fn agent_is_known(&self, agent: &str) -> bool {
        !agent.is_empty()
            && agent
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
            && self.agents_dir.join(format!("{agent}.md")).is_file()
    }

    /// A folder to offer for a new session, only when sure: the closed owner's
    /// starting folder, or an open focus's checkout, and only when its origin
    /// is the PR's repo. `open_projects` are the open focuses' project paths.
    pub fn suggest_folder(
        &self,
        row: &AuthoredPr,
        history: &SessionHistory,
        open_projects: &[PathBuf],
    ) -> Option<String> {
        let repo = row.repo.to_ascii_lowercase();
        let is_repo = |p: &Path| working_copy_at(p).repo.as_deref() == Some(repo.as_str());
        if row.owner.kind == OwnerKind::Closed {
            if let Some(tag) = row.owner.tag.as_deref() {
                let newest = history
                    .entries()
                    .into_iter()
                    .filter(|(t, _, _)| t == tag)
                    .max_by_key(|(_, _, seen)| *seen);
                let folder = newest
                    .and_then(|(_, sid, _)| find_transcript(&self.projects_root, &sid))
                    .and_then(|t| first_cwd(&t))
                    .filter(|p| is_repo(p));
                if let Some(folder) = folder {
                    return Some(folder.to_string_lossy().into_owned());
                }
            }
        }
        open_projects
            .iter()
            .find(|p| p.is_absolute() && p.is_dir() && is_repo(p))
            .map(|p| p.to_string_lossy().into_owned())
    }

    /// The closed owner's agent, from the focus memory.
    pub fn suggest_agent(&self, row: &AuthoredPr) -> Option<String> {
        if row.owner.kind != OwnerKind::Closed {
            return None;
        }
        self.memory
            .get(row.owner.tag.as_deref()?)
            .map(|m| m.agent_name)
            .filter(|a| self.agent_is_known(a))
    }
}
