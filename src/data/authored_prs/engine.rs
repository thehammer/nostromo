//! The engine loop: demand, relay signals and timers in; requests (inside the
//! budget) and snapshots out.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use tracing::{debug, info, warn};

use super::budget::{
    error_backoff, Bucket, Demand, Posture, RateState, LINGER, MIN_SEARCH_GAP, RELAY_COALESCE,
    TOKEN_EARLY_RETRY, TOKEN_RETRY,
};
use super::classify::{classify, group_of, Classified, RawPr};
use super::github::{Api, ApiError, Failure, Meta, SearchItem, SearchPage, Target, MAX_ALIASES};
use super::links::{key_string, AuthoredPrStore};
use super::memory::FocusMemory;
use super::notice::attention_key;
use super::ownership::{self, Link, OpenFocus, PrKey, WorkingCopy};
use super::snapshot::*;
use super::usage::{Record, UsageLog};
use super::working_copy::{SessionRef, WorkingCopies};
use super::{Clock, DemandInputs, Deps, FocusInfo, FocusProvider, TokenResolver};
use crate::data::github_client::GithubClient;
use crate::data::relay_client::{QueueSignal, RelayEvent, RelayStatus};
use crate::data::work::untrusted::one_line;
use crate::mother::MotherJob;

/// How often the relay's connected flag is looked at (it has no signal for "down").
const RELAY_STATUS_POLL: Duration = Duration::from_secs(2);
/// Snapshots are published at most this often.
const DEBOUNCE: Duration = Duration::from_millis(250);
/// How long a refused refresh stays visible.
const REFRESH_BLOCK_SHOWN: Duration = Duration::from_secs(10);
/// Ownership (working copies) is looked at this often while someone watches.
const OWNERSHIP_EVERY: Duration = Duration::from_secs(30);
/// The usage line (counts only) is logged this long after start, so a
/// post-install check sees it, and then every [`USAGE_LOG_EVERY`].
const USAGE_LOG_FIRST: Duration = Duration::from_secs(60);
const USAGE_LOG_EVERY: Duration = Duration::from_secs(3600);
const ORG_LOOKUPS_PER_DAY: usize = 5;
const DAY: Duration = Duration::from_secs(24 * 3600);
/// Never sleep less than this: a guard against a hot loop.
const MIN_SLEEP: Duration = Duration::from_millis(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    None,
    NeedSearch,
    Draining,
}

struct Pr {
    /// `owner/name` as GitHub spells it.
    repo: String,
    number: u64,
    title: String,
    updated_at: DateTime<Utc>,
    draft: bool,
    detail: Option<Classified>,
    details_unavailable: bool,
    lifecycle: Lifecycle,
    ended: Option<(DateTime<Utc>, Instant)>,
    /// In memory only: never serialised, never logged.
    head_ref: Option<String>,
    head_sha: Option<String>,
    in_search: bool,
}

struct RelayRead {
    repo: String,
    due: Instant,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    Poll,
    Relay,
}

pub(super) struct Engine {
    api: Option<Api>,
    api_base: String,
    clock: Arc<dyn Clock>,
    relay_status: Arc<RelayStatus>,
    relay_configured: bool,
    relay_rx: Option<mpsc::UnboundedReceiver<QueueSignal>>,
    jobs_rx: watch::Receiver<Vec<MotherJob>>,
    focuses: FocusProvider,
    projects_root: std::path::PathBuf,
    demand_rx: watch::Receiver<Demand>,
    refresh_rx: mpsc::UnboundedReceiver<()>,
    told_rx: mpsc::UnboundedReceiver<PrKey>,
    out: watch::Sender<Option<AuthoredPrsSnapshot>>,
    store: Arc<AuthoredPrStore>,
    memory: Arc<FocusMemory>,

    me: Option<String>,
    prs: BTreeMap<PrKey, Pr>,
    total_open: u32,
    search_etag: Option<String>,

    posture: Posture,
    rate_limited: bool,
    resumes_at: Option<DateTime<Utc>>,
    rate: RateState,
    poll_bucket: Bucket,
    relay_bucket: Bucket,
    usage: UsageLog,

    stage: Stage,
    want_search: bool,
    dirty: BTreeSet<PrKey>,
    departed: BTreeSet<PrKey>,
    relay_reads: BTreeMap<PrKey, RelayRead>,
    last_search: Option<Instant>,
    last_pending: Option<Instant>,
    last_full: Option<Instant>,
    pending_checked: Option<DateTime<Utc>>,
    checked_at: Option<DateTime<Utc>>,

    token: TokenState,
    token_retry: Option<Instant>,
    /// When the token was last rejected (a 401), for the early-retry bound.
    token_rejected_at: Option<Instant>,
    /// Looks for a token again while there is none.
    resolver: Option<TokenResolver>,
    last_token_check: Instant,
    error_count: u32,
    last_error: bool,
    retry_at: Option<(Instant, DateTime<Utc>)>,

    catching_up: bool,
    /// A reconnect arrived while a reconcile was running: that reconcile began
    /// before it, so it must not end the catch-up; run another.
    reconcile_again: bool,
    refresh_blocked: Option<(RefreshBlocked, Instant)>,

    hidden_orgs: BTreeSet<u64>,
    org_names: HashMap<u64, String>,
    org_lookups: Vec<Instant>,

    copies: WorkingCopies,
    last_ownership: Option<Instant>,
    last_status_poll: Option<Instant>,
    publish_at: Option<Instant>,
    last_published: Option<AuthoredPrsSnapshot>,
    next_usage_log: Instant,
}

fn make_api(c: &GithubClient, base: &str) -> Api {
    Api::new(c.http.clone(), c.token().to_owned(), base.to_owned())
}

fn key_of(repo: &str, number: u64) -> PrKey {
    PrKey {
        repo: repo.to_ascii_lowercase(),
        number,
    }
}

impl Engine {
    pub(super) fn new(
        deps: Deps,
        inputs: DemandInputs,
        out: watch::Sender<Option<AuthoredPrsSnapshot>>,
        store: Arc<AuthoredPrStore>,
        memory: Arc<FocusMemory>,
    ) -> Self {
        let (api, token) = match &deps.github {
            Some(c) => (Some(make_api(c, &deps.api_base)), TokenState::Connected),
            None => (None, TokenState::Missing),
        };
        Engine {
            api,
            api_base: deps.api_base,
            clock: deps.clock,
            relay_status: deps.relay_status,
            relay_configured: deps.relay_configured,
            relay_rx: deps.relay_rx,
            jobs_rx: deps.jobs_rx,
            focuses: deps.focuses,
            projects_root: deps.projects_root,
            demand_rx: inputs.demand_rx,
            refresh_rx: inputs.refresh_rx,
            told_rx: inputs.told_rx,
            out,
            store,
            memory,
            me: None,
            prs: BTreeMap::new(),
            total_open: 0,
            search_etag: None,
            posture: Posture::Idle,
            rate_limited: false,
            resumes_at: None,
            rate: RateState::default(),
            poll_bucket: Bucket::default(),
            relay_bucket: Bucket::default(),
            usage: UsageLog::default(),
            stage: Stage::None,
            want_search: false,
            dirty: BTreeSet::new(),
            departed: BTreeSet::new(),
            relay_reads: BTreeMap::new(),
            last_search: None,
            last_pending: None,
            last_full: None,
            pending_checked: None,
            checked_at: None,
            token,
            token_retry: None,
            token_rejected_at: None,
            resolver: deps.token_resolver,
            last_token_check: Instant::now(),
            error_count: 0,
            last_error: false,
            retry_at: None,
            // A relay that is configured has not been reconciled with yet.
            catching_up: deps.relay_configured,
            reconcile_again: false,
            refresh_blocked: None,
            hidden_orgs: BTreeSet::new(),
            org_names: HashMap::new(),
            org_lookups: Vec::new(),
            copies: WorkingCopies::default(),
            last_ownership: None,
            last_status_poll: None,
            publish_at: None,
            last_published: None,
            next_usage_log: Instant::now() + USAGE_LOG_FIRST,
        }
    }

    pub(super) async fn run(mut self) {
        self.mark_publish(Instant::now());
        let mut relay_connected = self.relay_status.connected();
        // A dropped sender makes `changed()` fail at once, every time: stop watching.
        let mut jobs_open = true;
        loop {
            self.tick().await;
            let wake = self.next_wake();
            tokio::select! {
                changed = self.demand_rx.changed() => {
                    if changed.is_err() { return; }
                    self.on_demand_changed();
                }
                Some(()) = self.refresh_rx.recv() => self.on_refresh(),
                Some(key) = self.told_rx.recv() => self.on_told(key),
                sig = recv_signal(&mut self.relay_rx) => match sig {
                    Some(QueueSignal::Reconnected) => self.on_reconnected(),
                    Some(QueueSignal::Event(ev)) => self.on_relay_event(&ev),
                    None => self.relay_rx = None,
                },
                changed = self.jobs_rx.changed(), if jobs_open => {
                    if changed.is_err() {
                        jobs_open = false;
                    }
                    self.mark_publish(Instant::now());
                }
                _ = tokio::time::sleep_until(wake) => {}
            }
            let connected = self.relay_status.connected();
            if connected != relay_connected {
                relay_connected = connected;
                self.mark_publish(Instant::now());
            }
        }
    }

    // ── inputs ────────────────────────────────────────────────────────────────

    fn on_demand_changed(&mut self) {
        // A change of demand retries a rejected token early, but at most once per
        // TOKEN_EARLY_RETRY: each retry is a 401 that is never charged.
        if self.token == TokenState::Rejected
            && self
                .token_rejected_at
                .is_none_or(|t| t.elapsed() >= TOKEN_EARLY_RETRY)
        {
            self.token = TokenState::Connected;
            self.token_retry = None;
        }
        self.mark_publish(Instant::now());
    }

    fn on_refresh(&mut self) {
        let now = Instant::now();
        match self.posture {
            Posture::Paused => {
                self.refresh_blocked =
                    Some((RefreshBlocked::RateLimited, now + REFRESH_BLOCK_SHOWN));
            }
            Posture::Idle => {}
            _ if self.stage != Stage::None => {
                self.refresh_blocked = Some((RefreshBlocked::Running, now + REFRESH_BLOCK_SHOWN));
            }
            _ => {
                self.stage = Stage::NeedSearch;
                self.last_full = Some(now);
            }
        }
        self.mark_publish(now);
    }

    /// The user told a focus about this PR: read it again so the new-comment
    /// cutoff (the told time) applies, and publish the told record now.
    fn on_told(&mut self, key: PrKey) {
        let now = Instant::now();
        if self.prs.contains_key(&key) {
            self.dirty.insert(key);
        }
        self.mark_publish(now);
    }

    fn on_reconnected(&mut self) {
        self.catching_up = true;
        if self.posture.active() && self.stage == Stage::None {
            self.stage = Stage::NeedSearch;
            self.last_full = Some(Instant::now());
        } else if self.stage == Stage::Draining {
            // Its search ran before this reconnect.
            self.reconcile_again = true;
        }
        self.mark_publish(Instant::now());
    }

    fn on_relay_event(&mut self, ev: &RelayEvent) {
        let now = Instant::now();
        let wall = self.clock.now();
        let Some(repo) = ev.repo.as_deref().filter(|r| valid_repo(r)) else {
            return;
        };
        let ty = ev.event_type.as_str();
        match ty {
            "pr.closed" | "pr.merged" => {
                let Some(n) = ev.number else { return };
                let key = key_of(repo, n);
                if let Some(pr) = self.prs.get_mut(&key) {
                    if pr.lifecycle == Lifecycle::Open {
                        let merged = ev.merged == Some(true) || ty == "pr.merged";
                        pr.lifecycle = if merged {
                            Lifecycle::Merged
                        } else {
                            Lifecycle::Closed
                        };
                        pr.ended = Some((wall, now));
                        self.relay_reads.remove(&key);
                        self.dirty.remove(&key);
                        // The last PR an earlier failed read was for is gone: no
                        // request is left that could succeed and clear the error.
                        if self.last_error
                            && self.dirty.is_empty()
                            && self.relay_reads.is_empty()
                            && !self.want_search
                        {
                            self.last_error = false;
                        }
                        self.mark_publish(now);
                    }
                }
            }
            "pr.opened"
            | "pr.reopened"
            | "pr.synchronize"
            | "pr.review_submitted"
            | "pr.review_requested"
            | "pr.review_request_removed" => {
                let Some(n) = ev.number else { return };
                let key = key_of(repo, n);
                let known = self.prs.get(&key);
                let wanted = match known {
                    Some(pr) => pr.lifecycle == Lifecycle::Open || ty == "pr.reopened",
                    // Unknown: only a PR that says it is mine. The author is
                    // verified from the read; the hint alone adds nothing.
                    None => {
                        matches!(ty, "pr.opened" | "pr.reopened")
                            && match (&self.me, ev.author.as_deref()) {
                                (Some(me), Some(a)) => me.eq_ignore_ascii_case(a),
                                _ => false,
                            }
                    }
                };
                if wanted {
                    self.want_read(key, repo, now);
                }
            }
            "ci.completed" => {
                let Some(sha) = ev.head_sha.as_deref() else {
                    return;
                };
                let lc = repo.to_ascii_lowercase();
                let hit = self
                    .prs
                    .iter()
                    .find(|(k, p)| {
                        k.repo == lc
                            && p.lifecycle == Lifecycle::Open
                            && p.head_sha.as_deref() == Some(sha)
                    })
                    .map(|(k, p)| (k.clone(), p.repo.clone()));
                if let Some((key, spelled)) = hit {
                    self.want_read(key, &spelled, now);
                }
            }
            _ => {}
        }
    }

    /// A relay event wants a PR read. Active: one coalesced read on the relay
    /// bucket. Idle or paused: the PR is only marked dirty, and the next
    /// reconcile picks it up.
    fn want_read(&mut self, key: PrKey, repo: &str, now: Instant) {
        if self.posture.active() {
            self.relay_reads.entry(key).or_insert(RelayRead {
                repo: repo.to_owned(),
                due: now + RELAY_COALESCE,
            });
        } else if self.prs.contains_key(&key) {
            self.dirty.insert(key);
        }
    }

    fn mark_publish(&mut self, now: Instant) {
        if self.publish_at.is_none() {
            self.publish_at = Some(now + DEBOUNCE);
        }
    }

    // ── the tick: posture, due work, publish ──────────────────────────────────

    fn blocked(&self, now: Instant) -> bool {
        if self.api.is_none() {
            return true;
        }
        if self.token == TokenState::Rejected && self.token_retry.is_some_and(|t| now < t) {
            return true;
        }
        self.retry_at.is_some_and(|(t, _)| now < t)
    }

    fn update_posture(&mut self, now: Instant, wall: DateTime<Utc>) {
        let demand = *self.demand_rx.borrow();
        let (posture, resumes_at, rate_limited) = self.rate.apply(demand, wall);
        self.rate_limited = rate_limited;
        self.resumes_at = resumes_at;
        if posture == self.posture {
            return;
        }
        info!(from = ?self.posture, to = ?posture, "authored-prs posture");
        let was_active = self.posture.active();
        self.posture = posture;
        if posture.active() && !was_active {
            // Leaving idle (or a pause) costs exactly one full reconcile.
            self.stage = Stage::NeedSearch;
            self.reconcile_again = false;
            self.last_full = Some(now);
            self.last_pending = Some(now);
        }
        if !posture.active() {
            self.want_search = false;
            // Reads the relay asked for become dirty marks for the next reconcile.
            for (k, _) in std::mem::take(&mut self.relay_reads) {
                if self.prs.contains_key(&k) {
                    self.dirty.insert(k);
                }
            }
        }
        self.mark_publish(now);
    }

    async fn tick(&mut self) {
        let now = Instant::now();
        let wall = self.clock.now();
        self.update_posture(now, wall);
        self.recheck_token(now).await;

        if self.refresh_blocked.is_some_and(|(_, until)| now >= until) {
            self.refresh_blocked = None;
            self.mark_publish(now);
        }
        // Merged and closed PRs linger for a minute, then go.
        let before = self.prs.len();
        self.prs.retain(|_, p| {
            p.ended
                .is_none_or(|(_, at)| now.saturating_duration_since(at) < LINGER)
        });
        if self.prs.len() != before {
            self.mark_publish(now);
        }
        if now >= self.next_usage_log {
            self.next_usage_log = now + USAGE_LOG_EVERY;
            let u = self.usage.view(now);
            info!(
                "authored-prs usage: charged={} not_modified={} search={} graphql_points={} relay={} posture={:?}",
                u.window.charged,
                u.window.not_modified,
                u.window.search,
                u.window.graphql_points,
                u.window.relay_charged,
                self.posture
            );
        }
        if self
            .last_status_poll
            .is_none_or(|t| now.saturating_duration_since(t) >= RELAY_STATUS_POLL)
        {
            self.last_status_poll = Some(now);
            // Cheap: a changed relay state shows up in the next build.
            self.mark_publish_if_relay_changed(now);
        }

        if let Some(cad) = self.posture.cadence() {
            if !self.blocked(now) {
                self.schedule(now, cad);
                self.work(now).await;
            }
        }

        if self.posture != Posture::Idle
            && self
                .last_ownership
                .is_none_or(|t| now.saturating_duration_since(t) >= OWNERSHIP_EVERY)
        {
            self.last_ownership = Some(now);
            self.mark_publish(now);
        }

        if self.publish_at.is_some_and(|t| now >= t) {
            self.publish_at = None;
            let (infos, copies) = self.owner_inputs(now).await;
            self.publish(now, wall, &infos, &copies);
        }
    }

    /// With no token, look for one again (at most once per [`TOKEN_EARLY_RETRY`],
    /// and only while someone watches), on a blocking thread: it reads files.
    async fn recheck_token(&mut self, now: Instant) {
        if self.api.is_some()
            || self.token != TokenState::Missing
            || *self.demand_rx.borrow() == Demand::Idle
            || now.saturating_duration_since(self.last_token_check) < TOKEN_EARLY_RETRY
        {
            return;
        }
        let Some(resolver) = self.resolver.clone() else {
            return;
        };
        self.last_token_check = now;
        let found = tokio::task::spawn_blocking(move || resolver())
            .await
            .ok()
            .flatten();
        if let Some(c) = found {
            info!("authored-prs: a GitHub token is available now");
            self.api = Some(make_api(&c, &self.api_base));
            self.token = TokenState::Connected;
            self.mark_publish(now);
        }
    }

    fn mark_publish_if_relay_changed(&mut self, now: Instant) {
        let info = self.relay_info();
        let changed = self
            .last_published
            .as_ref()
            .is_none_or(|p| p.relay.state != info.state || p.relay.since != info.since);
        if changed {
            self.mark_publish(now);
        }
    }

    /// Decide what is due by cadence.
    fn schedule(&mut self, now: Instant, cad: super::budget::Cadence) {
        let due = |last: Option<Instant>, every: Duration| {
            last.is_none_or(|t| now.saturating_duration_since(t) >= every)
        };
        if self.stage == Stage::None && due(self.last_full, cad.full) {
            self.stage = Stage::NeedSearch;
            self.last_full = Some(now);
        }
        if self.stage == Stage::None
            && !self.want_search
            && due(self.last_search, cad.search.max(MIN_SEARCH_GAP))
        {
            self.want_search = true;
        }
        if due(self.last_pending, cad.pending_ci) {
            self.last_pending = Some(now);
            let pending: Vec<PrKey> = self
                .prs
                .iter()
                .filter(|(_, p)| {
                    p.lifecycle == Lifecycle::Open
                        && p.detail
                            .as_ref()
                            .is_some_and(|d| d.checks.state == ChecksState::Pending)
                        && !self.relay_covers(&p.repo)
                })
                .map(|(k, _)| k.clone())
                .collect();
            self.dirty.extend(pending);
        }
    }

    /// Is the relay live for this repo's organisation right now?
    fn relay_covers(&self, repo: &str) -> bool {
        self.relay_configured
            && self.relay_status.connected()
            && !self.catching_up
            && repo
                .split('/')
                .next()
                .is_some_and(|o| o.eq_ignore_ascii_case(&self.relay_status.org()))
    }

    async fn work(&mut self, now: Instant) {
        let Some(cad) = self.posture.cadence() else {
            return;
        };
        let mut guard = 0;
        while guard < 64 {
            guard += 1;
            let now = Instant::now();
            if self.blocked(now) || !self.posture.active() {
                break;
            }
            let mut progressed = false;

            // 1. Discovery search.
            if matches!(self.stage, Stage::NeedSearch) || self.want_search {
                let gap_ok = self
                    .last_search
                    .is_none_or(|t| now.saturating_duration_since(t) >= MIN_SEARCH_GAP);
                if gap_ok && self.poll_bucket.has_room(now, cad.poll_cap) {
                    if !self.ensure_me(Source::Poll).await {
                        break;
                    }
                    progressed = true;
                    if !self.do_search().await {
                        break;
                    }
                }
            }

            // 2. Detail reads for what is dirty (poll bucket).
            let now = Instant::now();
            if !self.dirty.is_empty()
                && self.stage != Stage::NeedSearch
                && self.poll_bucket.has_room(now, cad.poll_cap)
            {
                if !self.ensure_me(Source::Poll).await {
                    break;
                }
                let batch: Vec<PrKey> = self.dirty.iter().take(MAX_ALIASES).cloned().collect();
                progressed = true;
                if !self.do_detail(batch, Source::Poll).await {
                    break;
                }
            }

            // 3. Relay-triggered reads (their own bucket).
            let now = Instant::now();
            let due: Vec<PrKey> = self
                .relay_reads
                .iter()
                .filter(|(_, r)| r.due <= now)
                .map(|(k, _)| k.clone())
                .take(MAX_ALIASES)
                .collect();
            if !due.is_empty() && self.relay_bucket.has_room(now, cad.relay_cap) {
                if !self.ensure_me(Source::Relay).await {
                    break;
                }
                progressed = true;
                if !self.do_detail(due, Source::Relay).await {
                    break;
                }
            }

            // 4. Names of organisations whose repos SSO hid from the search.
            if self.lookup_org_name().await {
                progressed = true;
            }

            if !progressed {
                break;
            }
        }
        let _ = now;
        self.finish_cycle();
    }

    /// A reconcile or a cadence search is done once the PRs it marked are read.
    fn finish_cycle(&mut self) {
        if self.last_error || !self.dirty.is_empty() {
            return;
        }
        match self.stage {
            Stage::Draining if self.reconcile_again => {
                self.reconcile_again = false;
                self.stage = Stage::NeedSearch;
                self.last_full = Some(Instant::now());
            }
            Stage::Draining => {
                self.stage = Stage::None;
                self.catching_up = false;
                self.checked_at = self.pending_checked.take().or(self.checked_at);
                self.mark_publish(Instant::now());
            }
            Stage::None if !self.want_search => {
                if let Some(t) = self.pending_checked.take() {
                    self.checked_at = Some(t);
                    self.mark_publish(Instant::now());
                }
            }
            _ => {}
        }
    }

    // ── requests ──────────────────────────────────────────────────────────────

    fn charge(&mut self, now: Instant, source: Source, rec: Record) {
        if rec.charged {
            match source {
                Source::Poll => self.poll_bucket.charge(now),
                Source::Relay => self.relay_bucket.charge(now),
            }
        }
        self.usage.record(now, rec);
        self.mark_publish(now);
    }

    fn record(&self, charged: bool, search: bool, points: u64, source: Source) -> Record {
        Record {
            charged,
            not_modified: !charged && search,
            search,
            graphql_points: points,
            relay: source == Source::Relay,
            posture: self.posture,
        }
    }

    fn observe(&mut self, meta: &Meta) {
        if let Some((res, mut obs)) = meta.rate {
            // A header's reset is never trusted past an hour from now.
            obs.reset = obs.reset.min(self.clock.now() + chrono::Duration::hours(1));
            self.rate.observe(res, obs);
        }
        for id in &meta.sso_orgs {
            if self.hidden_orgs.len() < MAX_HIDDEN_ORGS * 2 {
                self.hidden_orgs.insert(*id);
            }
        }
    }

    fn succeeded(&mut self) {
        self.error_count = 0;
        self.last_error = false;
        self.retry_at = None;
    }

    fn on_failure(&mut self, f: Failure, source: Source) {
        let now = Instant::now();
        let wall = self.clock.now();
        self.observe(&f.meta);
        warn!(class = f.error.class(), "authored-prs request failed");
        match f.error {
            ApiError::Unauthorized => {
                self.token = TokenState::Rejected;
                self.token_retry = Some(now + TOKEN_RETRY);
                self.token_rejected_at = Some(now);
            }
            ApiError::RateLimited { wait } => {
                let until = match wait {
                    Some(w) => wall + chrono::Duration::from_std(w).unwrap_or_default(),
                    None => f
                        .meta
                        .rate
                        .map(|(_, o)| o.reset)
                        .unwrap_or(wall + chrono::Duration::seconds(60)),
                };
                self.rate
                    .pause_until(until.min(wall + chrono::Duration::hours(1)));
            }
            _ => {
                self.error_count += 1;
                let d = error_backoff(self.error_count);
                self.retry_at = Some((
                    now + d,
                    wall + chrono::Duration::from_std(d).unwrap_or_default(),
                ));
                self.last_error = true;
            }
        }
        let _ = source;
        self.mark_publish(now);
    }

    async fn ensure_me(&mut self, source: Source) -> bool {
        if self.me.is_some() {
            return true;
        }
        let Some(api) = self.api.clone() else {
            return false;
        };
        match api.user().await {
            Ok((login, meta)) => {
                let now = Instant::now();
                self.observe(&meta);
                let rec = self.record(true, false, 0, source);
                self.charge(now, source, rec);
                self.me = Some(login);
                self.succeeded();
                true
            }
            Err(f) => {
                self.on_failure(f, source);
                false
            }
        }
    }

    /// Resolve one hidden organisation's name: at most 5 a day, each at most
    /// once per daemon lifetime. A failure leaves the generic label.
    async fn lookup_org_name(&mut self) -> bool {
        let now = Instant::now();
        self.org_lookups
            .retain(|t| now.saturating_duration_since(*t) < DAY);
        let Some(id) = self
            .hidden_orgs
            .iter()
            .find(|id| !self.org_names.contains_key(id))
            .copied()
        else {
            return false;
        };
        let cad = match self.posture.cadence() {
            Some(c) => c,
            None => return false,
        };
        if self.org_lookups.len() >= ORG_LOOKUPS_PER_DAY
            || !self.poll_bucket.has_room(now, cad.poll_cap)
        {
            return false;
        }
        let Some(api) = self.api.clone() else {
            return false;
        };
        self.org_lookups.push(now);
        match api.org_name(id).await {
            Ok((login, meta)) => {
                self.observe(&meta);
                let rec = self.record(true, false, 0, Source::Poll);
                self.charge(Instant::now(), Source::Poll, rec);
                self.org_names.insert(id, login);
            }
            Err(f) => {
                self.observe(&f.meta);
                self.org_names.insert(id, String::new());
            }
        }
        self.mark_publish(now);
        true
    }

    async fn do_search(&mut self) -> bool {
        let Some(api) = self.api.clone() else {
            return false;
        };
        let started = Instant::now();
        self.last_search = Some(started);
        let full = self.stage == Stage::NeedSearch;
        let wall = self.clock.now();
        match api.search(self.search_etag.as_deref()).await {
            Ok(res) => {
                let now = Instant::now();
                self.observe(&res.meta);
                self.succeeded();
                self.token = TokenState::Connected;
                match res.page {
                    None => {
                        let rec = self.record(false, true, 0, Source::Poll);
                        self.charge(now, Source::Poll, rec);
                        if full {
                            self.mark_all_dirty();
                        }
                    }
                    Some(page) => {
                        let rec = self.record(true, true, 0, Source::Poll);
                        self.charge(now, Source::Poll, rec);
                        self.search_etag = res.meta.etag.clone();
                        self.apply_search(page, full);
                    }
                }
                self.want_search = false;
                if full {
                    self.stage = Stage::Draining;
                }
                self.pending_checked = Some(wall);
                debug!(
                    prs = self.prs.len(),
                    dirty = self.dirty.len(),
                    duration_ms = started.elapsed().as_millis() as u64,
                    "authored-prs search done"
                );
                true
            }
            Err(f) => {
                self.on_failure(f, Source::Poll);
                false
            }
        }
    }

    fn mark_all_dirty(&mut self) {
        self.dirty.extend(self.prs.keys().cloned());
    }

    fn apply_search(&mut self, page: SearchPage, full: bool) {
        self.total_open = page.total_count;
        let mut seen = BTreeSet::new();
        for item in page.items {
            let SearchItem {
                repo,
                number,
                title,
                updated_at,
                draft,
                ..
            } = item;
            let key = key_of(&repo, number);
            seen.insert(key.clone());
            match self.prs.get_mut(&key) {
                Some(pr) => {
                    pr.in_search = true;
                    if pr.updated_at != updated_at {
                        self.dirty.insert(key.clone());
                    }
                    pr.title = title;
                    pr.updated_at = updated_at;
                    pr.draft = draft;
                    if pr.lifecycle != Lifecycle::Open {
                        // Back in the open set: a reopened PR comes back as new.
                        pr.lifecycle = Lifecycle::Open;
                        pr.ended = None;
                        self.dirty.insert(key.clone());
                    }
                }
                None => {
                    self.prs.insert(
                        key.clone(),
                        Pr {
                            repo,
                            number,
                            title,
                            updated_at,
                            draft,
                            detail: None,
                            details_unavailable: false,
                            lifecycle: Lifecycle::Open,
                            ended: None,
                            head_ref: None,
                            head_sha: None,
                            in_search: true,
                        },
                    );
                    self.dirty.insert(key);
                }
            }
        }
        // A PR that left the result set: learn whether it merged or closed.
        let left: Vec<PrKey> = self
            .prs
            .iter()
            .filter(|(k, p)| p.in_search && p.lifecycle == Lifecycle::Open && !seen.contains(*k))
            .map(|(k, _)| k.clone())
            .collect();
        for k in left {
            if let Some(p) = self.prs.get_mut(&k) {
                p.in_search = false;
            }
            self.departed.insert(k.clone());
            self.dirty.insert(k);
        }
        if full {
            self.mark_all_dirty();
        }
    }

    async fn do_detail(&mut self, keys: Vec<PrKey>, source: Source) -> bool {
        let Some(api) = self.api.clone() else {
            return false;
        };
        let targets: Vec<Target> = keys
            .iter()
            .map(|k| Target {
                repo: self
                    .prs
                    .get(k)
                    .map(|p| p.repo.clone())
                    .or_else(|| self.relay_reads.get(k).map(|r| r.repo.clone()))
                    .unwrap_or_else(|| k.repo.clone()),
                number: k.number,
            })
            .collect();
        match api.detail(&targets).await {
            Ok(batch) => {
                let now = Instant::now();
                self.observe(&batch.meta);
                self.succeeded();
                let rec = self.record(true, false, batch.cost, source);
                self.charge(now, source, rec);
                self.apply_detail(&keys, &targets, batch.prs, now);
                true
            }
            Err(f) => {
                self.on_failure(f, source);
                // Do not retry a failing relay read in a tight loop.
                for k in &keys {
                    if source == Source::Relay {
                        if let Some(r) = self.relay_reads.get_mut(k) {
                            r.due = Instant::now() + Duration::from_secs(60);
                        }
                    }
                }
                false
            }
        }
    }

    fn apply_detail(
        &mut self,
        keys: &[PrKey],
        targets: &[Target],
        prs: Vec<Option<RawPr>>,
        now: Instant,
    ) {
        let wall = self.clock.now();
        let me = self.me.clone().unwrap_or_default();
        for ((key, target), raw) in keys.iter().zip(targets).zip(prs) {
            self.dirty.remove(key);
            self.relay_reads.remove(key);
            let departed = self.departed.remove(key);
            let Some(raw) = raw else {
                if departed {
                    self.prs.remove(key);
                } else if let Some(p) = self.prs.get_mut(key) {
                    p.details_unavailable = true;
                }
                continue;
            };
            let author_is_me = raw
                .author
                .as_ref()
                .is_some_and(|a| a.login.eq_ignore_ascii_case(&me));
            if !author_is_me {
                // Not mine, whatever search or a relay hint said.
                self.prs.remove(key);
                continue;
            }
            let told_at = self
                .store
                .get(&key_string(&key.repo, key.number))
                .and_then(|e| e.told)
                .map(|t| t.at);
            let classified = classify(&raw, told_at);
            if classified.lifecycle != Lifecycle::Open {
                if let Some(p) = self
                    .prs
                    .get_mut(key)
                    .filter(|p| p.lifecycle == Lifecycle::Open)
                {
                    p.lifecycle = classified.lifecycle;
                    p.ended = Some((wall, now));
                }
                continue;
            }
            let repo = if valid_repo(&raw.repository.name_with_owner) {
                raw.repository.name_with_owner.clone()
            } else {
                target.repo.clone()
            };
            let updated = raw.updated_at.unwrap_or(wall);
            let pr = self.prs.entry(key.clone()).or_insert_with(|| Pr {
                repo: repo.clone(),
                number: key.number,
                title: String::new(),
                updated_at: updated,
                draft: false,
                detail: None,
                details_unavailable: false,
                lifecycle: Lifecycle::Open,
                ended: None,
                head_ref: None,
                head_sha: None,
                in_search: false,
            });
            pr.title = raw.title.clone();
            pr.draft = raw.is_draft;
            pr.updated_at = updated;
            pr.lifecycle = Lifecycle::Open;
            pr.ended = None;
            // A fork's branch name never matches a checkout (`on_branch`).
            pr.head_ref = Some(raw.head_ref_name.clone())
                .filter(|s| !s.is_empty() && !raw.is_cross_repository);
            pr.head_sha = Some(raw.head_ref_oid.clone()).filter(|s| !s.is_empty());
            pr.detail = Some(classified);
            pr.details_unavailable = false;
        }
        self.mark_publish(now);
    }

    // ── what to wake for ──────────────────────────────────────────────────────

    fn next_wake(&mut self) -> Instant {
        let now = Instant::now();
        let wall = self.clock.now();
        let mut wake = now + Duration::from_secs(3600);
        let mut consider = |t: Instant| {
            if t < wake {
                wake = t;
            }
        };
        if let Some(t) = self.publish_at {
            consider(t);
        }
        if self.relay_configured {
            consider(now + RELAY_STATUS_POLL);
        }
        if let Some((_, t)) = self.refresh_blocked {
            consider(t);
        }
        if let Some(t) = self.rate.next_change() {
            if let Ok(d) = (t - wall).to_std() {
                consider(now + d);
            }
        }
        consider(self.next_usage_log);
        if self.api.is_none()
            && self.token == TokenState::Missing
            && self.resolver.is_some()
            && *self.demand_rx.borrow() != Demand::Idle
        {
            consider(self.last_token_check + TOKEN_EARLY_RETRY);
        }
        for p in self.prs.values() {
            if let Some((_, at)) = p.ended {
                consider(at + LINGER);
            }
        }
        if self.posture != Posture::Idle {
            if let Some(t) = self.last_ownership {
                consider(t + OWNERSHIP_EVERY);
            }
        }
        if let Some(cad) = self.posture.cadence() {
            if self.blocked(now) {
                // Only the end of the block can change anything.
                if let Some((t, _)) = self.retry_at {
                    consider(t);
                }
                if let (TokenState::Rejected, Some(t)) = (self.token, self.token_retry) {
                    consider(t);
                }
            } else {
                let poll_slot = self.poll_bucket.next_slot(now, cad.poll_cap);
                if self.stage == Stage::None {
                    if let Some(t) = self.last_full {
                        consider(t + cad.full);
                    }
                }
                if let Some(t) = self.last_pending {
                    consider(t + cad.pending_ci);
                }
                if self.stage == Stage::None && !self.want_search {
                    consider(
                        self.last_search
                            .map_or(now, |t| t + cad.search.max(MIN_SEARCH_GAP)),
                    );
                }
                if self.stage == Stage::NeedSearch || self.want_search {
                    if let Some(slot) = poll_slot {
                        let gap = self.last_search.map_or(now, |t| t + MIN_SEARCH_GAP);
                        consider(slot.max(gap));
                    }
                } else if !self.dirty.is_empty() {
                    if let Some(slot) = poll_slot {
                        consider(slot);
                    }
                }
                if !self.relay_reads.is_empty() {
                    if let Some(slot) = self.relay_bucket.next_slot(now, cad.relay_cap) {
                        for r in self.relay_reads.values() {
                            consider(r.due.max(slot));
                        }
                    }
                }
            }
        }
        wake.max(now + MIN_SLEEP)
    }

    // ── the snapshot ──────────────────────────────────────────────────────────

    fn relay_info(&self) -> RelayInfo {
        // The relay's ack names the org: one line and bounded before it is sent on.
        let org = one_line(&self.relay_status.org(), MAX_ORG_NAME);
        if !self.relay_configured {
            return RelayInfo {
                state: RelayState::NotConfigured,
                since: None,
                org,
            };
        }
        if !self.relay_status.connected() {
            return RelayInfo {
                state: RelayState::Offline,
                since: self.relay_status.since(),
                org,
            };
        }
        RelayInfo {
            state: if self.catching_up {
                RelayState::CatchingUp
            } else {
                RelayState::Live
            },
            since: None,
            org,
        }
    }

    fn poll_info(&self, wall: DateTime<Utc>) -> PollInfo {
        let cad = self.posture.cadence();
        let interval_secs = cad.map_or(0, |c| c.search.as_secs());
        let retry_at = self
            .retry_at
            .filter(|(t, _)| Instant::now() < *t)
            .map(|(_, w)| w);
        let state = match self.posture {
            Posture::Idle => PollState::Idle,
            Posture::Paused => PollState::Paused,
            _ if self.last_error => PollState::Error,
            _ if self.rate_limited => PollState::RateLimited,
            _ if self.stage != Stage::None || !self.dirty.is_empty() || self.want_search => {
                PollState::Checking
            }
            _ => PollState::Ok,
        };
        let _ = wall;
        PollInfo {
            state,
            checked_at: self.checked_at,
            interval_secs,
            resumes_at: self.resumes_at.filter(|_| self.posture == Posture::Paused),
            retry_at: if self.last_error { retry_at } else { None },
        }
    }

    /// The open focuses and, when some open PR has no Mother owner, their
    /// working copies. The file reads run on a blocking thread, never on the
    /// runtime, and with no lock held: the focus provider returns an owned list.
    async fn owner_inputs(
        &mut self,
        now: Instant,
    ) -> (Vec<FocusInfo>, HashMap<String, WorkingCopy>) {
        let infos = (self.focuses)();
        if infos.is_empty() {
            return (infos, HashMap::new());
        }
        let focuses = open_focuses_of(&infos);
        let links = self.links(&infos);
        let jobs = self.jobs_rx.borrow().clone();
        let needs_copies = self.prs.iter().any(|(k, p)| {
            p.lifecycle == Lifecycle::Open
                && matches!(
                    ownership::resolve(
                        k,
                        p.head_ref.as_deref(),
                        &jobs,
                        &focuses,
                        &HashMap::new(),
                        &links
                    )
                    .kind,
                    OwnerKind::Unknown | OwnerKind::Ambiguous
                )
        });
        if !needs_copies {
            return (infos, HashMap::new());
        }
        let sessions: Vec<SessionRef> = infos
            .iter()
            .map(|f| SessionRef {
                tag: f.tag.clone(),
                session_id: f.session_id.clone(),
                spawn_cwd: f.spawn_cwd.clone(),
                project_path: f.project_path.clone(),
            })
            .collect();
        let mut copies = std::mem::take(&mut self.copies);
        let root = self.projects_root.clone();
        let read = tokio::task::spawn_blocking(move || {
            let map = copies.refresh(now, &root, &sessions);
            (copies, map)
        })
        .await;
        match read {
            Ok((copies, map)) => {
                self.copies = copies;
                (infos, map)
            }
            // The reader panicked: the cache is gone, the answer is "unknown".
            Err(_) => (infos, HashMap::new()),
        }
    }

    /// The links the user made, for the PRs listed: open when the tag is in the
    /// registry, and named from it (or from the focus memory once closed).
    fn links(&self, infos: &[FocusInfo]) -> HashMap<PrKey, Link> {
        self.prs
            .keys()
            .filter_map(|k| {
                let link = self.store.get(&key_string(&k.repo, k.number))?.link?;
                let open = infos.iter().find(|f| f.tag == link.tag);
                let name = open
                    .map(|f| f.name.clone())
                    .or_else(|| self.memory.get(&link.tag).map(|m| m.name))
                    .unwrap_or_default();
                Some((
                    k.clone(),
                    Link {
                        tag: link.tag,
                        name,
                        open: open.is_some(),
                    },
                ))
            })
            .collect()
    }

    fn owners(
        &self,
        infos: &[FocusInfo],
        copies: &HashMap<String, WorkingCopy>,
    ) -> HashMap<PrKey, Owner> {
        let jobs = self.jobs_rx.borrow().clone();
        let focuses = open_focuses_of(infos);
        let links = self.links(infos);
        self.prs
            .iter()
            .map(|(k, p)| {
                (
                    k.clone(),
                    ownership::resolve(k, p.head_ref.as_deref(), &jobs, &focuses, copies, &links),
                )
            })
            .collect()
    }

    fn build(
        &mut self,
        now: Instant,
        wall: DateTime<Utc>,
        infos: &[FocusInfo],
        copies: &HashMap<String, WorkingCopy>,
    ) -> AuthoredPrsSnapshot {
        self.memory.observe(infos, wall);
        if self.checked_at.is_some() {
            let prs = &self.prs;
            let find = |key: &str| {
                prs.iter()
                    .find(|(k, _)| key_string(&k.repo, k.number) == key)
            };
            self.store.prune(
                wall,
                |key| find(key).is_some_and(|(_, p)| p.lifecycle != Lifecycle::Open),
                |key| find(key).is_some(),
            );
        }
        let owners = self.owners(infos, copies);
        let mut rows: Vec<AuthoredPr> = self
            .prs
            .iter()
            .filter(|(_, p)| valid_repo(&p.repo))
            .map(|(k, p)| {
                let c = p.detail.as_ref();
                let checks = c.map_or_else(Checks::none, |c| c.checks.clone());
                let review = c.map_or_else(Review::none, |c| c.review.clone());
                let new_comments = c.map_or(0, |c| c.new_comments);
                let unresolved = c.map_or(0, |c| c.unresolved_threads);
                let group = group_of(p.draft, &checks, &review, new_comments, unresolved);
                let owner = owners.get(k).cloned().unwrap_or_else(Owner::unknown);
                let requesters: &[String] = if review.state == ReviewState::ChangesRequested {
                    &review.logins
                } else {
                    &[]
                };
                let key_hash = attention_key(
                    &checks.failing_names,
                    requesters,
                    c.and_then(|c| c.newest_comment),
                    unresolved,
                );
                let told_rec = self
                    .store
                    .get(&key_string(&k.repo, k.number))
                    .and_then(|e| e.told);
                let told = told_rec.as_ref().map(|t| Told {
                    tag: t.tag.clone(),
                    name: infos
                        .iter()
                        .find(|f| f.tag == t.tag)
                        .map(|f| f.name.clone())
                        .or_else(|| self.memory.get(&t.tag).map(|m| m.name))
                        .filter(|n| !n.is_empty())
                        .map_or_else(|| "a closed focus".to_owned(), |n| one_line(&n, MAX_NAME)),
                    at: t.at,
                });
                // A pill is a promise that Tell works: never raised for an owner
                // the verbs would refuse (a built-in or a sensitive focus).
                let known_open_owner = matches!(
                    owner.kind,
                    OwnerKind::MotherJob | OwnerKind::Linked | OwnerKind::OnBranch
                ) && owner
                    .tag
                    .as_deref()
                    .is_some_and(|tag| infos.iter().any(|f| f.tag == tag && f.tellable()));
                let pill = group == Group::NeedsYou
                    && !p.draft
                    && p.lifecycle == Lifecycle::Open
                    && known_open_owner
                    && told_rec
                        .as_ref()
                        .is_none_or(|t| t.attention_key != key_hash);
                AuthoredPr {
                    repo: p.repo.clone(),
                    number: p.number,
                    url: format!("https://github.com/{}/pull/{}", p.repo, p.number),
                    title: one_line(&p.title, MAX_TITLE),
                    draft: p.draft,
                    updated_at: p.updated_at,
                    group,
                    lifecycle: p.lifecycle,
                    ended_at: p.ended.map(|(w, _)| w),
                    base_ref: c.and_then(|c| c.base_ref.clone()),
                    details_unavailable: p.details_unavailable,
                    checks,
                    review,
                    new_comments,
                    unresolved_threads: unresolved,
                    threads_truncated: c.is_some_and(|c| c.threads_truncated),
                    owner,
                    told,
                    pill,
                    attention_key: key_hash,
                }
            })
            .collect();
        rows.sort_by(|a, b| {
            a.group
                .rank()
                .cmp(&b.group.rank())
                .then(b.updated_at.cmp(&a.updated_at))
                .then(a.repo.cmp(&b.repo))
                .then(a.number.cmp(&b.number))
        });
        let open = rows
            .iter()
            .filter(|r| r.lifecycle == Lifecycle::Open)
            .count() as u32;
        rows.truncate(MAX_PRS);
        let hidden_orgs = self
            .hidden_orgs
            .iter()
            .take(MAX_HIDDEN_ORGS)
            .map(|id| {
                one_line(
                    self.org_names
                        .get(id)
                        .filter(|name| !name.is_empty())
                        .map_or("an organization", String::as_str),
                    MAX_ORG_NAME,
                )
            })
            .collect();
        AuthoredPrsSnapshot {
            generated_at: wall,
            token: self.token,
            relay: self.relay_info(),
            poll: self.poll_info(wall),
            refresh_blocked: self.refresh_blocked.map(|(r, _)| r),
            hidden_orgs,
            total_open: self.total_open.max(open),
            shown: rows.len() as u32,
            prs: rows,
            usage: self.usage.view(now),
        }
    }

    fn publish(
        &mut self,
        now: Instant,
        wall: DateTime<Utc>,
        infos: &[FocusInfo],
        copies: &HashMap<String, WorkingCopy>,
    ) {
        let snap = self.build(now, wall, infos, copies);
        if let Some(last) = &self.last_published {
            let mut same = last.clone();
            same.generated_at = snap.generated_at;
            if same == snap {
                return;
            }
        }
        self.last_published = Some(snap.clone());
        let _ = self.out.send(Some(snap));
    }
}

fn open_focuses_of(infos: &[FocusInfo]) -> Vec<OpenFocus> {
    infos
        .iter()
        .map(|f| OpenFocus {
            tag: f.tag.clone(),
            name: f.name.clone(),
        })
        .collect()
}

async fn recv_signal(rx: &mut Option<mpsc::UnboundedReceiver<QueueSignal>>) -> Option<QueueSignal> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending().await,
    }
}
