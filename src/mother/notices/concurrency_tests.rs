//! MF2a-13: the engine's lock is a leaf. Feed updates, turn events, settings,
//! registry pushes, timers and readers run on many threads at once, with a
//! session port that (like the real session manager) takes a "manager" lock
//! and reads the engine back while it delivers, and a registry push made
//! while that same "manager" lock is held. Bounded iterations; the test fails
//! (instead of hanging) if they do not all finish.

use super::*;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{OnceLock, Weak};
use std::thread;
use std::time::Duration;

use crate::mother::notices::NoticeScope;

const ITERATIONS: usize = 300;
const DEADLINE: Duration = Duration::from_secs(60);

/// A port shaped like `ManagerPort`: it takes the manager's lock, and while
/// holding it reads the engine (as a session manager calling back would).
struct ReentrantPort {
    engine: OnceLock<Weak<NoticeEngine>>,
    manager: Arc<Mutex<()>>,
    calls: AtomicUsize,
}

impl ReentrantPort {
    fn engine(&self) -> Option<Arc<NoticeEngine>> {
        self.engine.get().and_then(Weak::upgrade)
    }
}

impl SessionPort for ReentrantPort {
    fn deliver(
        &self,
        tag: &str,
        _key: &str,
        _merged: &str,
        _fresh: &str,
    ) -> anyhow::Result<NoticeDelivery> {
        let _manager = self.manager.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(engine) = self.engine() {
            let _ = engine.notice_of("c-0");
            let _ = engine.focus_state(tag);
            let _ = engine.state_msg();
        }
        match self.calls.fetch_add(1, Ordering::SeqCst) % 4 {
            0 => Ok(NoticeDelivery::Woke),
            1 => Ok(NoticeDelivery::Queued),
            2 => Ok(NoticeDelivery::Replaced),
            _ => Err(anyhow::anyhow!("no live session")),
        }
    }

    fn withdraw(&self, tag: &str) {
        let _manager = self.manager.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(engine) = self.engine() {
            let _ = engine.focus_state(tag);
        }
    }
}

const STATES: [&str; 6] = [
    "queued",
    "running",
    "succeeded",
    "failed",
    "awaiting",
    "cancelled",
];

#[test]
fn concurrent_feed_turns_settings_registry_timers_and_reads_never_deadlock() {
    let dir = tempfile::tempdir().unwrap();
    let clock = ManualClock::new(T0);
    let engine = NoticeEngine::new(NoticeConfig {
        store_path: Some(dir.path().join("mother-notices.json")),
        audit: MotherAudit::open(&dir.path().join("audit").join("mother.jsonl")).unwrap(),
        clock: Arc::new(clock.clone()),
    });
    let manager = Arc::new(Mutex::new(()));
    let port = Arc::new(ReentrantPort {
        engine: OnceLock::new(),
        manager: Arc::clone(&manager),
        calls: AtomicUsize::new(0),
    });
    let _ = port.engine.set(Arc::downgrade(&engine));
    engine.set_port(port.clone());
    engine.on_jobs(&[]);

    let mut workers: Vec<(&'static str, thread::JoinHandle<()>)> = Vec::new();

    {
        let engine = Arc::clone(&engine);
        workers.push((
            "feed",
            thread::spawn(move || {
                for i in 0..ITERATIONS {
                    engine.on_jobs(&[
                        job(F, &format!("c-{}", i % 7), STATES[i % STATES.len()])
                            .with_pr(&format!("https://github.com/acme/repo/pull/{}", i % 7)),
                        job(G, &format!("d-{}", i % 5), STATES[(i + 2) % STATES.len()]),
                        job_of_kind(OriginKind::Unverified, Some(F), "u-0", STATES[i % 3]),
                    ]);
                }
            }),
        ));
    }
    {
        let engine = Arc::clone(&engine);
        workers.push((
            "turns",
            thread::spawn(move || {
                for i in 0..ITERATIONS {
                    engine.on_turn(
                        F,
                        &TurnEvent::Started {
                            author: notice_author(&notice_key(F, i as u64)),
                        },
                    );
                    engine.note_job_origin(&format!("c-{}", i % 7), F);
                    engine.on_turn(F, &TurnEvent::Completed);
                    engine.on_turn(
                        G,
                        &TurnEvent::Started {
                            author: TurnAuthor::User,
                        },
                    );
                    engine.on_turn(G, &TurnEvent::Completed);
                    engine.on_turn(
                        F,
                        &TurnEvent::Started {
                            author: TurnAuthor::Cli,
                        },
                    );
                    if i % 50 == 0 {
                        engine.on_turn(F, &TurnEvent::Exited);
                    }
                }
            }),
        ));
    }
    {
        let engine = Arc::clone(&engine);
        workers.push((
            "settings",
            thread::spawn(move || {
                let modes = [NotifyLevel::Wake, NotifyLevel::Quiet, NotifyLevel::Off];
                for i in 0..ITERATIONS {
                    let _ = engine.apply_settings(
                        NoticeScope::Focus,
                        Some(F),
                        Some(modes[i % 3]),
                        None,
                    );
                    if i % 10 == 0 {
                        let _ = engine.apply_settings(
                            NoticeScope::Global,
                            None,
                            None,
                            Some(i % 20 != 0),
                        );
                    }
                    let _ = engine.apply_settings(NoticeScope::Global, None, None, None);
                }
            }),
        ));
    }
    {
        let engine = Arc::clone(&engine);
        let manager = Arc::clone(&manager);
        workers.push((
            "registry",
            thread::spawn(move || {
                for i in 0..ITERATIONS {
                    // As `set_focus_registry` does: under the manager's lock.
                    let _manager = manager.lock().unwrap_or_else(|e| e.into_inner());
                    if i % 3 == 0 {
                        engine.on_registry(&[G.to_owned()], &[F.to_owned()]);
                    } else {
                        engine.on_registry(&[F.to_owned(), G.to_owned()], &[]);
                    }
                }
            }),
        ));
    }
    {
        let engine = Arc::clone(&engine);
        let clock = clock.clone();
        workers.push((
            "timers",
            thread::spawn(move || {
                for _ in 0..ITERATIONS {
                    clock.advance(31 * SEC);
                    engine.tick();
                }
            }),
        ));
    }
    {
        let engine = Arc::clone(&engine);
        workers.push((
            "readers",
            thread::spawn(move || {
                for i in 0..ITERATIONS {
                    let mut jobs = vec![job(F, "c-0", "succeeded"), job(G, "d-0", "running")];
                    engine.annotate(&mut jobs);
                    let _ = engine.notice_of(&format!("c-{}", i % 7));
                    let _ = engine.focus_state(F);
                    let _ = engine.state_msg();
                    engine.pr_event(&format!("c-{}", i % 7), i % 2 == 0);
                    let _ = engine.changes();
                }
            }),
        ));
    }

    let (done_tx, done_rx) = mpsc::channel();
    thread::spawn(move || {
        let outcomes: Vec<(&'static str, bool)> = workers
            .into_iter()
            .map(|(name, handle)| (name, handle.join().is_ok()))
            .collect();
        let _ = done_tx.send(outcomes);
    });
    let outcomes = done_rx
        .recv_timeout(DEADLINE)
        .expect("every worker finishes: a timeout here is a deadlock");
    for (name, ok) in outcomes {
        assert!(ok, "the {name} worker panicked");
    }

    // The engine still works afterwards.
    engine
        .apply_settings(NoticeScope::Global, None, None, Some(true))
        .unwrap();
    let h = "focus-h";
    engine.on_registry(&[F.to_owned(), G.to_owned(), h.to_owned()], &[]);
    let before = port.calls.load(Ordering::SeqCst);
    engine.on_jobs(&[job(h, "fresh", "succeeded")]);
    clock.advance(31 * SEC);
    engine.tick();
    assert!(
        port.calls.load(Ordering::SeqCst) > before,
        "a new change is still delivered"
    );
}

// ── the store is written outside the engine's lock ───────────────────────────

/// An engine with a store file whose first write is held at the gate until the
/// returned sender is used. Receiving on the returned receiver says the write
/// is held.
fn engine_with_first_write_held() -> (
    tempfile::TempDir,
    Arc<NoticeEngine>,
    mpsc::Sender<()>,
    mpsc::Receiver<()>,
) {
    let dir = tempfile::tempdir().unwrap();
    let engine = NoticeEngine::new(NoticeConfig {
        store_path: Some(dir.path().join("mother-notices.json")),
        audit: MotherAudit::open(&dir.path().join("audit").join("mother.jsonl")).unwrap(),
        clock: Arc::new(ManualClock::new(T0)),
    });
    let (held_tx, held_rx) = mpsc::channel::<()>();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let release_rx = Mutex::new(release_rx);
    let first = std::sync::atomic::AtomicBool::new(true);
    *engine.before_write.lock().unwrap() = Some(Arc::new(move || {
        if first.swap(false, Ordering::SeqCst) {
            let _ = held_tx.send(());
            let _ = release_rx.lock().unwrap().recv_timeout(DEADLINE);
        }
    }));
    (dir, engine, release_tx, held_rx)
}

#[test]
fn a_slow_store_write_never_holds_up_the_registry_push_or_readers() {
    let (_dir, engine, release, held) = engine_with_first_write_held();
    let writer = {
        let engine = Arc::clone(&engine);
        thread::spawn(move || engine.on_jobs(&[]))
    };
    held.recv_timeout(Duration::from_secs(10))
        .expect("the first look at the feed writes the store");

    // The manager's lock is held by the registry push (as `set_focus_registry`
    // does) while the write is still going on.
    let (done_tx, done_rx) = mpsc::channel();
    let other = {
        let engine = Arc::clone(&engine);
        thread::spawn(move || {
            engine.on_registry(&[F.to_owned()], &[]);
            let _ = engine.notice_of("none");
            let _ = engine.state_msg();
            let _ = done_tx.send(());
        })
    };
    let ran = done_rx.recv_timeout(Duration::from_secs(10));
    release.send(()).unwrap();
    writer.join().unwrap();
    other.join().unwrap();
    assert!(
        ran.is_ok(),
        "the registry push and readers wait for a store write: it is under the engine lock"
    );
}

#[test]
fn a_store_write_that_lost_the_race_to_a_newer_one_does_not_overwrite_it() {
    let (dir, engine, release, held) = engine_with_first_write_held();
    let writer = {
        let engine = Arc::clone(&engine);
        thread::spawn(move || engine.on_jobs(&[]))
    };
    held.recv_timeout(Duration::from_secs(10)).unwrap();
    // A newer state is written while the first (older) snapshot is held.
    engine
        .apply_settings(NoticeScope::Global, None, None, Some(false))
        .unwrap();
    release.send(()).unwrap();
    writer.join().unwrap();

    let file = std::fs::read_to_string(dir.path().join("mother-notices.json")).unwrap();
    let json: serde_json::Value = serde_json::from_str(&file).unwrap();
    assert_eq!(
        json["enabled"], false,
        "the older snapshot overwrote the newer one"
    );
}
