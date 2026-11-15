//! What the hand-off verbs need from the PR list, apart from sockets and
//! sessions: the current row of a PR, the facts a notice may use, the told and
//! link records, and the suggestions "Start a session…" prefills.
//!
//! Nothing here logs: a PR's repo, number, check names, logins, focus names and
//! the message text never reach a log line.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use tokio::sync::watch;

use super::links::{key_string, AuthoredPrStore};
use super::memory::FocusMemory;
use super::notice::{compose, digest, PrFacts};
use super::ownership::PrKey;
use super::snapshot::{AuthoredPr, AuthoredPrsSnapshot, Lifecycle, OwnerKind, ReviewState};
use super::wire::{AuthoredPrResult, LastTold, StartOk};
use super::working_copy::{find_transcript, first_cwd, working_copy_at};
use super::{Clock, DemandBoard};
use crate::mother::origin::SessionHistory;

const REMEMBERED_STARTS: usize = 64;

pub struct AuthoredPrActions {
    board: Arc<DemandBoard>,
    snapshot: watch::Receiver<Option<AuthoredPrsSnapshot>>,
    store: Arc<AuthoredPrStore>,
    memory: Arc<FocusMemory>,
    projects_root: PathBuf,
    agents_dir: PathBuf,
    clock: Arc<dyn Clock>,
    starts: Mutex<VecDeque<(String, AuthoredPrResult<StartOk>)>>,
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
        AuthoredPrActions {
            board: Arc::clone(&handle.demand),
            snapshot: handle.snapshot.clone(),
            store: Arc::clone(&handle.store),
            memory: Arc::clone(&handle.memory),
            projects_root,
            agents_dir,
            clock,
            starts: Mutex::new(VecDeque::new()),
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

    fn changed(&self, row: &AuthoredPr) {
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
