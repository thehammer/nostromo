//! The Huey surface: what the Report and Context panes show, and what their
//! actions do (H6).
//!
//! Showing a pane only reads what Huey already wrote (and, before setup, what
//! is held in memory): it never runs, fetches or writes. An action is carried
//! out only after the server has checked that it came from the verified Mac
//! app; setup can be confirmed from a human click and from nowhere else.

use chrono::NaiveDate;
use serde_json::{json, Value};
use tracing::{info, warn};

use super::context::LiveInputs;
use super::render::{self, action, HueyDocument};
use super::setup::{self, InterestsStatus, SetupState};
use super::store::{Verdict, VerdictKind};
use super::{HueyHandle, Trigger, TriggerRefused};
use crate::ipc::protocol::DocAction;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The whole setup scan (live PR and job reads included) gets this long.
const SCAN_BUDGET: Duration = Duration::from_secs(90);

/// Clears the "a scan is running" flag however the scan ends.
struct ScanningGuard<'a>(&'a AtomicBool);

impl Drop for ScanningGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// The two panes the daemon binds when it seeds the `huey` focus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HueyPane {
    /// `huey.report`
    Report,
    /// `huey.context`
    Context,
}

impl HueyPane {
    pub const REPORT_SOURCE: &'static str = "huey.report";
    pub const CONTEXT_SOURCE: &'static str = "huey.context";

    pub fn from_source(source: &str) -> Option<Self> {
        match source {
            Self::REPORT_SOURCE => Some(Self::Report),
            Self::CONTEXT_SOURCE => Some(Self::Context),
            _ => None,
        }
    }

    pub fn source(self) -> &'static str {
        match self {
            Self::Report => Self::REPORT_SOURCE,
            Self::Context => Self::CONTEXT_SOURCE,
        }
    }
}

/// What an action did.
#[derive(Debug, Clone, PartialEq)]
pub struct ActionOutcome {
    pub ok: bool,
    /// Plain English for the reader: why it was refused, or what started.
    pub message: Option<String>,
    /// For the Mac to open: `https:` or a `file:` URL inside the Huey root.
    pub open_url: Option<String>,
    /// `Some(params)` when the pane must be rebound to new params
    /// (`Some(None)`: back to "current", no params).
    pub rebind: Option<Option<Value>>,
}

impl ActionOutcome {
    fn done(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: Some(message.into()),
            open_url: None,
            rebind: None,
        }
    }

    fn refused(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: Some(message.into()),
            open_url: None,
            rebind: None,
        }
    }

    fn rebound(params: Option<Value>) -> Self {
        Self {
            ok: true,
            message: None,
            open_url: None,
            rebind: Some(params),
        }
    }
}

/// Why a run could not be started from a surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum StartError {
    #[error("Huey is not set up on this machine")]
    NotSetUp,
    #[error(transparent)]
    Refused(#[from] TriggerRefused),
}

/// A pane's binding params: the report and version it shows. Anything that
/// does not parse is "not given".
#[derive(Debug, Clone, Copy, Default)]
struct Selector {
    date: Option<NaiveDate>,
    version: Option<u32>,
}

/// A `YYYY-MM-DD` string; anything else is `None`.
pub(crate) fn parse_date(v: &Value) -> Option<NaiveDate> {
    v.as_str()?.parse().ok()
}

/// A whole number that fits a version; anything else is `None`.
pub(crate) fn parse_version(v: &Value) -> Option<u32> {
    u32::try_from(v.as_u64()?).ok()
}

impl Selector {
    fn parse(params: Option<&Value>) -> Self {
        let Some(obj) = params.and_then(Value::as_object) else {
            return Self::default();
        };
        Self {
            date: obj.get("date").and_then(parse_date),
            version: obj.get("version").and_then(parse_version),
        }
    }

    fn is_empty(&self) -> bool {
        self.date.is_none() && self.version.is_none()
    }
}

impl HueyHandle {
    /// What a pane bound to `pane` shows for its binding `params`
    /// (`{date, version}`, or none for "current"). Reads only: it never
    /// runs anything and writes nothing.
    pub fn pane_document(&self, pane: HueyPane, params: Option<&Value>) -> HueyDocument {
        match pane {
            HueyPane::Report => self.report_pane(Selector::parse(params)),
            HueyPane::Context => self.context_pane(Selector::parse(params)),
        }
    }

    /// Carry out an action from a document pane. `params` are the pane's
    /// current binding params.
    pub async fn on_action(
        &self,
        _pane: HueyPane,
        params: Option<&Value>,
        action_id: &str,
    ) -> ActionOutcome {
        let sel = Selector::parse(params);
        match action_id {
            action::SETUP_START | action::SETUP_RESCAN => self.scan_machine().await,
            action::SETUP_OPEN_INTERESTS => self.open_interests().await,
            action::SETUP_IMPORT_INTERESTS => self.import_interests(),
            action::SETUP_CONFIRM => self.confirm_setup(false),
            action::SETUP_CONFIRM_RUN_NOW => self.confirm_setup(true),
            _ if !self.is_set_up() && is_report_action(action_id) => {
                ActionOutcome::refused("Huey is not set up on this machine yet.")
            }
            action::REPORT_PREV => self.step(sel, Step::Earlier),
            action::REPORT_NEXT => self.step(sel, Step::Later),
            action::REPORT_TODAY => ActionOutcome::rebound(None),
            action::REPORT_REGENERATE => self.regenerate_action(),
            id => {
                if let Some(n) = id.strip_prefix(action::REPORT_VERSION_PREFIX) {
                    self.show_version(sel, n)
                } else if let Some(rest) = id.strip_prefix(action::VERDICT_PREFIX) {
                    self.verdict_action(rest)
                } else {
                    ActionOutcome::refused("unknown_action")
                }
            }
        }
    }

    /// Start `trigger` in the background and return at once: refused when
    /// Huey is not set up, a run is going, or (regenerate) the 2-minute
    /// cooldown has not passed.
    pub fn start(&self, trigger: Trigger) -> Result<(), StartError> {
        if !self.is_set_up() {
            return Err(StartError::NotSetUp);
        }
        if self.is_running() {
            return Err(TriggerRefused::AlreadyRunning.into());
        }
        if trigger == Trigger::Regenerate {
            if let Some(left) = self.cooldown_left() {
                return Err(TriggerRefused::Cooldown { seconds: left }.into());
            }
            if self.regenerations_today(self.inner.env.clock.now())
                >= super::MAX_REGENERATIONS_PER_DAY
            {
                return Err(TriggerRefused::DailyCap {
                    max: super::MAX_REGENERATIONS_PER_DAY,
                }
                .into());
            }
        }
        let handle = self.clone();
        tokio::spawn(async move {
            match handle.trigger(trigger).await {
                Ok(outcome) => {
                    info!(trigger = ?trigger, ok = matches!(outcome, super::RunOutcome::Produced { .. }), "huey: started run ended")
                }
                Err(refused) => {
                    warn!(trigger = ?trigger, refused = %refused, "huey: started run refused")
                }
            }
        });
        Ok(())
    }

    /// Tell bound panes to repaint (bumps the [`super::HueyView`]).
    pub fn notify_changed(&self) {
        self.bump();
    }

    // ── reading ──────────────────────────────────────────────────────────────

    fn is_set_up(&self) -> bool {
        self.setup_state() == SetupState::Confirmed
    }

    fn report_pane(&self, sel: Selector) -> HueyDocument {
        if !self.is_set_up() {
            let held = self.inner.scan.lock().unwrap().clone();
            return match held {
                Some(scan) => render::setup_scan_document(&scan, &self.paths.interests()),
                None => render::setup_prescan_document_noted(
                    &self.inner.env.context.sources(&self.paths),
                    self.inner
                        .scan_timed_out
                        .load(Ordering::SeqCst)
                        .then_some("Huey stopped the scan because the scan took too long. Nothing was saved. Press the button to try again."),
                ),
            };
        }
        if sel.is_empty() {
            return self.current_document();
        }
        let Some(date) = sel.date.or_else(|| self.current_date()) else {
            return self.current_document();
        };
        self.document_for(date, sel.version).unwrap_or_else(|| {
            let has_report = !self.store().versions(date).is_empty();
            render::missing_report_document(
                date,
                sel.version.filter(|_| has_report),
                self.nav_actions(date, false),
            )
        })
    }

    fn context_pane(&self, sel: Selector) -> HueyDocument {
        if !self.is_set_up() {
            return render::context_not_set_up_document();
        }
        let store = self.store();
        let Some(date) = sel.date.or_else(|| self.current_date()) else {
            return render::no_digest_document(self.today());
        };
        let Some(version) = sel.version.or_else(|| store.latest_version(date)) else {
            return render::no_digest_document(date);
        };
        match store.load_digest(date, version) {
            Some(digest) => render::context_document(date, version, &digest),
            None => render::no_digest_document(date),
        }
    }

    /// The date of the report the pane shows with no params.
    fn current_date(&self) -> Option<NaiveDate> {
        self.current_document().date
    }

    /// The daemon's local time, for a label.
    pub(super) fn local_stamp(&self, at: chrono::DateTime<chrono::Utc>) -> String {
        self.local_time()
            .to_local(at)
            .format("%Y-%m-%d %H:%M")
            .to_string()
    }

    /// The buttons below a report (or a missing one) dated `date`.
    /// `for_report`: the report exists, so it adds one button per version (when
    /// there is more than one) and, for today's, regenerate.
    pub(super) fn nav_actions(&self, date: NaiveDate, for_report: bool) -> Vec<DocAction> {
        let store = self.store();
        let dates = store.dates();
        let today = self.today();
        let mut out = Vec::new();
        if dates.iter().any(|d| *d < date) {
            out.push(render::button(action::REPORT_PREV, "Earlier", false));
        }
        if dates.iter().any(|d| *d > date) {
            out.push(render::button(action::REPORT_NEXT, "Later", false));
        }
        if date != today {
            out.push(render::button(action::REPORT_TODAY, "Today", false));
        }
        if for_report {
            let versions = store.versions(date);
            if versions.len() > 1 {
                out.extend(versions.into_iter().map(|v| {
                    render::button(
                        &format!("{}{v}", action::REPORT_VERSION_PREFIX),
                        &format!("v{v}"),
                        false,
                    )
                }));
            }
            if date == today {
                out.push(render::button(
                    action::REPORT_REGENERATE,
                    "Regenerate",
                    false,
                ));
            }
        }
        out
    }

    /// The verdict each pick of one version carries now: the latest wins.
    pub fn chosen_verdicts(
        &self,
        date: NaiveDate,
        version: u32,
    ) -> std::collections::BTreeMap<usize, VerdictKind> {
        let mut all: Vec<Verdict> = self
            .store()
            .verdicts(date)
            .into_iter()
            .filter(|v| v.version == version)
            .collect();
        all.sort_by_key(|v| v.at);
        all.into_iter()
            .map(|v| (v.pick as usize, v.verdict))
            .collect()
    }

    fn cooldown_left(&self) -> Option<i64> {
        let end = (*self.inner.last_run_end.lock().unwrap())?;
        let now = self.inner.env.clock.now();
        let left = super::REGENERATE_COOLDOWN_SECS - (now - end).num_seconds();
        (left > 0).then_some(left)
    }

    // ── report actions ───────────────────────────────────────────────────────

    fn shown_date(&self, sel: Selector) -> Option<NaiveDate> {
        sel.date.or_else(|| self.current_date())
    }

    fn step(&self, sel: Selector, step: Step) -> ActionOutcome {
        let Some(shown) = self.shown_date(sel) else {
            return ActionOutcome::refused("There is no report to move from yet.");
        };
        let dates = self.store().dates(); // newest first
        let target = match step {
            Step::Earlier => dates.into_iter().find(|d| *d < shown),
            Step::Later => dates.into_iter().rev().find(|d| *d > shown),
        };
        match target {
            Some(date) => ActionOutcome::rebound(Some(json!({ "date": date.to_string() }))),
            None => ActionOutcome::refused(match step {
                Step::Earlier => "There is no earlier report.",
                Step::Later => "There is no later report.",
            }),
        }
    }

    fn show_version(&self, sel: Selector, n: &str) -> ActionOutcome {
        let Some(shown) = self.shown_date(sel) else {
            return ActionOutcome::refused("There is no report to show a version of.");
        };
        match n.parse::<u32>() {
            Ok(v) if self.store().versions(shown).contains(&v) => {
                ActionOutcome::rebound(Some(json!({ "date": shown.to_string(), "version": v })))
            }
            _ => ActionOutcome::refused(format!(
                "There is no version {n} of the report for {}.",
                shown.format("%b %-d")
            )),
        }
    }

    fn regenerate_action(&self) -> ActionOutcome {
        match self.start(Trigger::Regenerate) {
            Ok(()) => ActionOutcome::done(
                "Regenerating today's report. The new version appears here in a few minutes.",
            ),
            Err(e) => ActionOutcome::refused(start_error_text(e)),
        }
    }

    fn verdict_action(&self, rest: &str) -> ActionOutcome {
        let parts: Vec<&str> = rest.split(':').collect();
        let [date, version, pick, kind] = parts[..] else {
            return ActionOutcome::refused("That verdict link is not valid.");
        };
        let (Ok(date), Ok(version), Ok(pick), Some(kind)) = (
            date.parse::<NaiveDate>(),
            version.parse::<u32>(),
            pick.parse::<u32>(),
            render::verdict_from_slug(kind),
        ) else {
            return ActionOutcome::refused("That verdict link is not valid.");
        };
        match self.save_verdict(date, version, pick, kind, None) {
            Ok(()) => ActionOutcome::done(format!(
                "Recorded: {}.",
                render::verdict_slug(kind).replace('_', " ")
            )),
            Err(why) => ActionOutcome::refused(why),
        }
    }

    /// Record a verdict on pick `pick` (from 1) of one version of `date`.
    pub fn save_verdict(
        &self,
        date: NaiveDate,
        version: u32,
        pick: u32,
        verdict: VerdictKind,
        note: Option<String>,
    ) -> Result<(), String> {
        let store = self.store();
        let report = store
            .load_report(date, version)
            .ok_or_else(|| format!("There is no version {version} of the report for {date}."))?;
        let item_id = usize::try_from(pick)
            .ok()
            .and_then(|n| n.checked_sub(1))
            .and_then(|i| report.picks.get(i))
            .and_then(|p| p.item_ids.first())
            .cloned()
            .ok_or_else(|| format!("That report has no pick {pick}."))?;
        store
            .record_verdict(
                date,
                Verdict {
                    version,
                    pick,
                    item_id,
                    verdict,
                    note,
                    at: self.inner.env.clock.now(),
                },
            )
            .map_err(|_| "Huey could not save that verdict.".to_string())?;
        self.bump();
        Ok(())
    }

    // ── setup actions ────────────────────────────────────────────────────────

    async fn scan_machine(&self) -> ActionOutcome {
        if self.is_set_up() {
            return ActionOutcome::refused("Huey is already set up on this machine.");
        }
        if self.inner.scanning.load(Ordering::SeqCst) {
            return ActionOutcome::done("A scan is already running.");
        }
        match self.run_scan().await {
            Some(_) => ActionOutcome::done("Scanned this machine. Nothing was saved."),
            None if self.inner.scan_timed_out.load(Ordering::SeqCst) => {
                ActionOutcome::refused("The scan took too long. Nothing was saved.")
            }
            None => ActionOutcome::done("A scan is already running."),
        }
    }

    /// Read the context in memory (D6) and hold the result, within
    /// [`SCAN_BUDGET`]. `None` when a scan is already running or this one ran
    /// out of time (then the setup document says so).
    async fn run_scan(&self) -> Option<setup::SetupScan> {
        if self.inner.scanning.swap(true, Ordering::SeqCst) {
            return None;
        }
        let _scanning = ScanningGuard(&self.inner.scanning);
        match tokio::time::timeout(SCAN_BUDGET, self.scan_now()).await {
            Ok(scan) => {
                self.inner.scan_timed_out.store(false, Ordering::SeqCst);
                Some(scan)
            }
            Err(_) => {
                warn!("huey: the setup scan took too long and was stopped");
                self.inner.scan_timed_out.store(true, Ordering::SeqCst);
                self.bump();
                None
            }
        }
    }

    async fn scan_now(&self) -> setup::SetupScan {
        let env = &self.inner.env;
        let now = env.clock.now();
        let live = LiveInputs {
            prs: env.live.prs(now).await,
            jobs: env.live.jobs().await,
        };
        let (context, paths) = (env.context.clone(), (*self.paths).clone());
        let scan = tokio::task::spawn_blocking(move || setup::scan(&context, &paths, &live, now))
            .await
            .unwrap_or_else(|_| setup::SetupScan {
                machine: env.context.machine.clone(),
                context_sources: env.context.sources(&self.paths),
                projects: Vec::new(),
                interests: InterestsStatus::Missing,
            });
        *self.inner.scan.lock().unwrap() = Some(scan.clone());
        self.bump();
        scan
    }

    async fn open_interests(&self) -> ActionOutcome {
        let path = self.paths.interests();
        if !path.exists() {
            let held = self.inner.scan.lock().unwrap().clone();
            let scan = match held {
                Some(scan) => scan,
                None => match self.run_scan().await {
                    Some(scan) => scan,
                    None => {
                        return ActionOutcome::refused(
                            "Huey could not scan this machine just now. Try again.",
                        )
                    }
                },
            };
            if setup::write_draft(&self.paths, &scan).is_err() {
                return ActionOutcome::refused("Huey could not write the interests draft.");
            }
            self.note_interests_present();
        }
        match url::Url::from_file_path(&path) {
            Ok(url) => ActionOutcome {
                ok: true,
                message: Some("Opening your interests file.".to_string()),
                open_url: Some(url.to_string()),
                rebind: None,
            },
            Err(()) => ActionOutcome::refused("Huey could not name the interests file."),
        }
    }

    fn import_interests(&self) -> ActionOutcome {
        if self.paths.interests().exists() {
            return ActionOutcome::refused("There is already an interests file here.");
        }
        let legacy = setup::legacy_interests(&self.inner.env.context);
        let Ok(text) = std::fs::read(&legacy) else {
            return ActionOutcome::refused("There is no older interests file to import.");
        };
        if setup::write_atomic(&self.paths.interests(), &text).is_err() {
            return ActionOutcome::refused("Huey could not copy the older interests file.");
        }
        self.note_interests_present();
        ActionOutcome::done(
            "Imported the older interests file. The original was left where it was.",
        )
    }

    /// The held scan now sees the interests file (no new read of the machine).
    fn note_interests_present(&self) {
        if let Some(scan) = self.inner.scan.lock().unwrap().as_mut() {
            scan.interests = InterestsStatus::Existing;
        }
        self.bump();
    }

    fn confirm_setup(&self, run_now: bool) -> ActionOutcome {
        if self.is_set_up() {
            return ActionOutcome::refused("Huey is already set up on this machine.");
        }
        if let Err(refused) = setup::confirm(&self.paths, self.inner.env.clock.now()) {
            return ActionOutcome::refused(refused.0);
        }
        *self.inner.scan.lock().unwrap() = None;
        self.bump();
        let time = self.config.report_time.format("%H:%M");
        if !run_now {
            return ActionOutcome::done(format!(
                "Huey is set up. The first report will be ready by {time}."
            ));
        }
        match self.start(Trigger::RunNow) {
            Ok(()) => ActionOutcome::done("Huey is set up. Writing the first report now."),
            Err(e) => ActionOutcome::done(format!(
                "Huey is set up, but the first report did not start: {}",
                start_error_text(e)
            )),
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Step {
    Earlier,
    Later,
}

fn is_report_action(id: &str) -> bool {
    id.starts_with("report.") || id.starts_with(action::VERDICT_PREFIX)
}

/// Plain English for a refused start.
pub(super) fn start_error_text(e: StartError) -> String {
    match e {
        StartError::NotSetUp => "Huey is not set up on this machine yet.".to_string(),
        StartError::Refused(TriggerRefused::AlreadyRunning) => {
            "A run is already in progress.".to_string()
        }
        StartError::Refused(TriggerRefused::Cooldown { seconds }) => {
            format!("A run just finished. Wait {seconds} s, then try again.")
        }
        StartError::Refused(TriggerRefused::DailyCap { max }) => {
            format!("Today's {max} regenerations are used up. Try again tomorrow.")
        }
    }
}
