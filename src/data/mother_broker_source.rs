//! Broker-driven Mother job source.
//!
//! Subscribes to the `BrokerClient` event stream and maintains an in-memory
//! job map, replacing the 2-second `mother list` poll and the statusline-file
//! watcher from the old `mother_poll` module.
//!
//! ## Event flow
//!
//! 1. `BrokerEvent::Snapshot` → seed the job map; emit `MotherJobs` + `MotherStatusline`.
//! 2. `BrokerEvent::StateChange` → apply fold; emit events; fire `AwaitDetected` on
//!    new awaiting transitions.
//! 3. `BrokerEvent::CurrentActivity` → update the job's `current_activity` field; emit.
//! 4. `BrokerEvent::Reconnected` → clear the map and wait for the fresh snapshot.
//! 5. `BrokerEvent::Hello` / `BrokerEvent::Ping` → no-op.

use std::collections::{HashMap, HashSet};

use tokio::sync::{broadcast, mpsc};
use tracing::{debug, warn};

use crate::{
    event::AppEvent,
    mother::{
        broker_client::{BrokerClient, BrokerEvent},
        MotherJob, MotherStatus,
    },
};

/// Spawn the broker-driven Mother data source.
///
/// The source maintains its own subscription to `broker`'s event stream and
/// emits `AppEvent::MotherJobs`, `AppEvent::MotherStatusline`, and
/// `AppEvent::AwaitDetected` events onto `tx`.
///
/// The spawned task exits cleanly when the broadcast channel is closed (i.e.
/// when the `BrokerClient` is dropped).
pub fn spawn(broker: BrokerClient, tx: mpsc::UnboundedSender<AppEvent>) {
    let mut events_rx = broker.subscribe();
    tokio::spawn(async move {
        let mut jobs: HashMap<String, MotherJob> = HashMap::new();
        let mut seen_awaiting: HashSet<String> = HashSet::new();

        loop {
            match events_rx.recv().await {
                Ok(event) => {
                    handle_event(event, &mut jobs, &mut seen_awaiting, &tx);
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    warn!("broker source: lagged by {n} messages; job map may be stale until next Reconnected");
                }
                Err(broadcast::error::RecvError::Closed) => {
                    debug!("broker source: event channel closed; task exiting");
                    break;
                }
            }
        }
    });
}

fn handle_event(
    event: BrokerEvent,
    jobs: &mut HashMap<String, MotherJob>,
    seen_awaiting: &mut HashSet<String>,
    tx: &mpsc::UnboundedSender<AppEvent>,
) {
    match event {
        BrokerEvent::Snapshot {
            jobs: snapshot_jobs,
            ..
        } => {
            jobs.clear();
            seen_awaiting.clear();
            for job in snapshot_jobs {
                jobs.insert(job.id.clone(), job);
            }
            emit(jobs, tx);
        }

        BrokerEvent::StateChange {
            job_id,
            new_state,
            question,
            paused_reason,
        } => {
            let job = jobs.entry(job_id.clone()).or_insert_with(|| {
                // New job seen after snapshot (race). Create a minimal record.
                MotherJob {
                    id: job_id.clone(),
                    state: new_state.clone(),
                    repo: String::new(),
                    isolation: String::new(),
                    title: String::new(),
                    created_at: None,
                    started_at: None,
                    finished_at: None,
                    plan_path: None,
                    question: None,
                    paused_reason: None,
                    adherence_status: None,
                    current_tier: None,
                    current_activity: None,
                }
            });

            job.state = new_state.clone();

            if new_state == "awaiting" {
                job.question = question;
                job.paused_reason = paused_reason;

                if !seen_awaiting.contains(&job_id) {
                    seen_awaiting.insert(job_id.clone());
                    let _ = tx.send(AppEvent::AwaitDetected(Box::new(job.clone())));
                }
            } else {
                // Clear await fields when leaving awaiting state.
                if new_state != "awaiting" {
                    job.question = None;
                    job.paused_reason = None;
                }
                seen_awaiting.remove(&job_id);
            }

            emit(jobs, tx);
        }

        BrokerEvent::CurrentActivity { job_id, activity } => {
            if let Some(job) = jobs.get_mut(&job_id) {
                job.current_activity = Some(activity);
            }
            // Don't emit on every current_activity — too noisy.  The Mother view
            // re-renders on Tick and reads from state.mother_jobs directly.
        }

        BrokerEvent::Reconnected => {
            // Clear state; wait for the fresh Snapshot.
            jobs.clear();
            seen_awaiting.clear();
            debug!("broker source: reconnected; cleared job map");
        }

        BrokerEvent::Hello { .. } | BrokerEvent::Ping => {
            // Liveness-only; no action needed.
        }
    }
}

/// Emit the current job list and derived status line.
fn emit(jobs: &HashMap<String, MotherJob>, tx: &mpsc::UnboundedSender<AppEvent>) {
    let job_list: Vec<MotherJob> = jobs.values().cloned().collect();
    let status = MotherStatus::from_jobs(&job_list);
    let _ = tx.send(AppEvent::MotherJobs(job_list));
    let _ = tx.send(AppEvent::MotherStatusline(status));
}
