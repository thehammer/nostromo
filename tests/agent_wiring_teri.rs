//! The enabled-Teri half of the work-service wiring: `wire_agents` installs the
//! hub Teri's source returns as the process-wide work service. Its own test
//! binary (its own process): `tests/agent_wiring.rs` asserts the service is the
//! Null one while Teri is off, and this installs a real one.

use nostromo::agents::{
    wire_agents, AgentSpawner, CalendarRx, EnabledAgents, MailboxRx, PerriPrRx, PerriQueueRx,
    PerriSources, TeriSources, TodosRx,
};
use nostromo::data::work::hub::{HubDeps, WorkHub};
use nostromo::data::work::work_service;
use std::sync::Arc;
use tokio::sync::{broadcast, mpsc, watch};

/// Spawns nothing real; Teri's source hands back `hub`.
struct WithHub {
    hub: Arc<WorkHub>,
    keep: Vec<Box<dyn std::any::Any + Send>>,
}

impl WithHub {
    fn rx<T: Send + Sync + 'static>(&mut self, v: T) -> watch::Receiver<T> {
        let (tx, rx) = watch::channel(v);
        self.keep.push(Box::new(tx));
        rx
    }
}

impl AgentSpawner for WithHub {
    fn start_huey(&mut self) -> nostromo::agents::HueySources {
        let dir = tempfile::tempdir().unwrap();
        let context = nostromo::huey::context::ContextEnv::for_home(
            dir.path(),
            dir.path().join("code"),
            dir.path().to_path_buf(),
            "test".into(),
        );
        let src = nostromo::huey::HueyEngine::spawn(nostromo::huey::HueyDeps::new(
            dir.path().to_path_buf(),
            nostromo::huey::HueyConfig::default(),
            context,
        ));
        self.keep.push(Box::new(dir));
        src
    }
    fn start_perri(&mut self) -> PerriSources {
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
        (self.rx(None), self.rx(None))
    }
    fn start_teri(&mut self) -> TeriSources {
        let todos_rx = self.rx(None);
        TeriSources {
            todos_rx,
            work_hub: Some(self.hub.clone()),
        }
    }
    fn start_perri_broadcaster(&mut self, _q: PerriQueueRx, _p: PerriPrRx) {}
    fn start_fred_broadcaster(&mut self, _m: MailboxRx, _c: CalendarRx) {}
    fn start_teri_broadcaster(&mut self, _t: TodosRx) {}
}

fn same_service(a: &Arc<dyn nostromo::data::work::WorkService>, hub: &Arc<WorkHub>) -> bool {
    std::ptr::eq(Arc::as_ptr(a) as *const (), Arc::as_ptr(hub) as *const ())
}

#[tokio::test]
async fn an_enabled_teri_installs_its_work_hub_as_the_work_service() {
    let dir = tempfile::tempdir().unwrap();
    let (btx, _rx) = broadcast::channel(16);
    let (_ttx, trx) = watch::channel(None);
    let hub = WorkHub::spawn(HubDeps {
        // Not the user's real code folder.
        repo_docs_root: Some(dir.path().join("no-code-here")),
        ..HubDeps::new(btx, trx)
    });
    assert!(
        !same_service(&work_service(), &hub),
        "setup: the Null service is installed first"
    );

    let mut spawner = WithHub {
        hub: hub.clone(),
        keep: Vec::new(),
    };
    let wired = wire_agents(EnabledAgents::all(), &mut spawner);

    assert!(
        wired
            .work_hub
            .as_ref()
            .is_some_and(|h| Arc::ptr_eq(h, &hub)),
        "the hub is handed back"
    );
    assert!(
        same_service(&work_service(), &hub),
        "and installed as the process-wide work service"
    );
}
