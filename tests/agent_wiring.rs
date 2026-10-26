//! Daemon wiring guards for disabled agents, run against `wire_agents` (the
//! function `nostromd` uses) with a recording spawner. This file is its own
//! test binary (its own process), so the process-global work service is
//! untouched by any other test.

use nostromo::agents::{
    wire_agents, AgentSpawner, CalendarRx, EnabledAgents, MailboxRx, PerriPrRx, PerriQueueRx,
    PerriSources, TeriSources, TodosRx,
};
use nostromo::data::work::work_service;
use nostromo::huey::{HueyConfig, HueyDeps, HueyEngine, HueySources};
use tokio::sync::{mpsc, watch};

/// Records which spawn methods ran; hands back receivers whose senders it
/// keeps alive, as a real source would.
#[derive(Default)]
struct Recorder {
    calls: Vec<&'static str>,
    /// `start_huey` calls, kept apart so the Fred/Perri/Teri call lists stay as they were.
    huey_calls: usize,
    keep: Vec<Box<dyn std::any::Any + Send>>,
}

impl Recorder {
    fn rx<T: Send + Sync + 'static>(&mut self, v: T) -> watch::Receiver<T> {
        let (tx, rx) = watch::channel(v);
        self.keep.push(Box::new(tx));
        rx
    }
}

impl AgentSpawner for Recorder {
    fn start_huey(&mut self) -> HueySources {
        self.huey_calls += 1;
        let dir = tempfile::tempdir().unwrap();
        let context = nostromo::huey::context::ContextEnv::for_home(
            dir.path(),
            dir.path().join("code"),
            dir.path().to_path_buf(),
            "test".into(),
        );
        let src = HueyEngine::spawn(HueyDeps::new(
            dir.path().to_path_buf(),
            HueyConfig::default(),
            context,
        ));
        self.keep.push(Box::new(dir));
        src
    }
    fn start_perri(&mut self) -> PerriSources {
        self.calls.push("perri");
        let (queue_refresh_tx, _r1) = mpsc::unbounded_channel();
        let (queue_relay_tx, _r2) = mpsc::unbounded_channel();
        let (pr_refresh_tx, _r3) = mpsc::unbounded_channel();
        PerriSources {
            queue_rx: self.rx(None),
            queue_refresh_tx,
            queue_relay_tx,
            pr_rx: self.rx(nostromo::data::perri_pr::no_prs()),
            pr_refresh_tx,
        }
    }
    fn start_fred(&mut self) -> (MailboxRx, CalendarRx) {
        self.calls.push("fred");
        (self.rx(None), self.rx(None))
    }
    fn start_teri(&mut self) -> TeriSources {
        self.calls.push("teri");
        TeriSources {
            todos_rx: self.rx(None),
            work_hub: None,
        }
    }
    fn start_perri_broadcaster(&mut self, _q: PerriQueueRx, _p: PerriPrRx) {
        self.calls.push("perri-broadcaster");
    }
    fn start_fred_broadcaster(&mut self, _m: MailboxRx, _c: CalendarRx) {
        self.calls.push("fred-broadcaster");
    }
    fn start_teri_broadcaster(&mut self, _t: TodosRx) {
        self.calls.push("teri-broadcaster");
    }
}

fn wire(enabled: EnabledAgents) -> (Recorder, nostromo::agents::WiredAgents) {
    let mut rec = Recorder::default();
    let wired = wire_agents(enabled, &mut rec);
    (rec, wired)
}

fn only_off(agent: &str) -> EnabledAgents {
    let mut e = EnabledAgents::all();
    match agent {
        "perri" => e.perri = false,
        "fred" => e.fred = false,
        _ => e.teri = false,
    }
    e
}

#[tokio::test]
async fn everything_enabled_spawns_every_source_and_broadcaster() {
    let (rec, wired) = wire(EnabledAgents::all());
    assert_eq!(
        rec.calls,
        [
            "perri",
            "perri-broadcaster",
            "fred",
            "fred-broadcaster",
            "teri",
            "teri-broadcaster"
        ]
    );
    assert!(wired.parked.is_empty());
    assert!(wired.perri_queue_refresh_tx.is_some() && wired.perri_pr_refresh_tx.is_some());
    assert!(wired.perri_queue_relay_tx.is_some());
}

#[tokio::test]
async fn disabled_perri_spawns_no_poller_or_broadcaster_and_parks_its_senders() {
    let (rec, wired) = wire(only_off("perri"));
    assert_eq!(
        rec.calls,
        ["fred", "fred-broadcaster", "teri", "teri-broadcaster"]
    );
    assert_eq!(wired.parked.len(), 2);
    assert!(wired.perri_queue_refresh_tx.is_none() && wired.perri_pr_refresh_tx.is_none());
    assert!(wired.perri_queue_relay_tx.is_none());
    assert!(
        wired.perri_queue_rx.has_changed().is_ok(),
        "receiver must stay open"
    );
    assert!(wired.perri_pr_rx.has_changed().is_ok());
}

#[tokio::test]
async fn disabled_fred_spawns_no_poller_or_broadcaster_and_parks_its_senders() {
    let (rec, wired) = wire(only_off("fred"));
    assert_eq!(
        rec.calls,
        ["perri", "perri-broadcaster", "teri", "teri-broadcaster"]
    );
    assert_eq!(wired.parked.len(), 2);
    assert!(wired.fred_mailbox_rx.has_changed().is_ok());
    assert!(wired.fred_calendar_rx.has_changed().is_ok());
    assert!(wired.fred_mailbox_rx.borrow().is_none());
}

#[tokio::test]
async fn disabled_teri_spawns_nothing_parks_its_sender_and_leaves_the_null_work_service() {
    let (rec, wired) = wire(only_off("teri"));
    assert_eq!(
        rec.calls,
        ["perri", "perri-broadcaster", "fred", "fred-broadcaster"]
    );
    assert_eq!(wired.parked.len(), 1);
    assert!(wired.work_hub.is_none());
    assert!(wired.teri_todos_rx.has_changed().is_ok());
    assert!(work_service().detail("any-item").await.is_err());
    assert!(work_service().refresh(None, false).await.is_err());
}

#[tokio::test]
async fn everything_disabled_spawns_nothing_and_keeps_all_receivers_open() {
    let (rec, wired) = wire(EnabledAgents {
        fred: false,
        huey: false,
        perri: false,
        teri: false,
    });
    assert!(rec.calls.is_empty());
    assert_eq!(rec.huey_calls, 0);
    assert!(wired.huey.is_none());
    assert_eq!(wired.parked.len(), 6);
    assert!(wired.huey_rx.has_changed().is_ok());
    assert!(wired.perri_queue_rx.has_changed().is_ok());
    assert!(wired.teri_todos_rx.has_changed().is_ok());
    assert!(wired.fred_calendar_rx.has_changed().is_ok());
}

#[tokio::test]
async fn huey_is_started_by_default_and_hands_out_a_live_handle() {
    let (rec, wired) = wire(EnabledAgents::all());
    assert_eq!(rec.huey_calls, 1);
    assert!(wired.huey.is_some());
    assert!(wired.parked.is_empty());
}

#[tokio::test]
async fn disabled_huey_is_never_started_and_parks_its_receiver() {
    let mut e = EnabledAgents::all();
    e.huey = false;
    let (rec, wired) = wire(e);
    assert_eq!(rec.huey_calls, 0);
    assert!(wired.huey.is_none());
    assert_eq!(wired.parked.len(), 1);
    assert!(
        wired.huey_rx.has_changed().is_ok(),
        "receiver must stay open"
    );
    assert_eq!(rec.calls.len(), 6, "the other agents still start");
}
