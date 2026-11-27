//! Test-only: a process-wide tracing subscriber, so a test's scoped capture
//! (`tracing::subscriber::set_default`) is deterministic.
//!
//! A scoped subscriber alone is not enough. `tracing` caches, per callsite,
//! whether anyone is interested, and a thread that first reaches a callsite
//! while another test's scoped subscriber is being built or dropped can cache
//! "nobody" for it: a later capture silently misses that line. Under libtest
//! (one process, many test threads) that made
//! `data::relay_client::tests::the_event_log_line_names_only_the_event_type`
//! fail about 6 runs in 10 with only the two relay-client tests running. A
//! global subscriber that is interested in everything keeps every callsite
//! enabled; each scoped capture then sees every event of its own thread.

use std::sync::{Mutex, Once};
use tracing_subscriber::layer::SubscriberExt;

static GLOBAL_LINES: Mutex<Vec<String>> = Mutex::new(Vec::new());
static INSTALL: Once = Once::new();

struct Fields(String);

impl tracing::field::Visit for Fields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        use std::fmt::Write;
        let _ = write!(self.0, "{}={:?} ", field.name(), value);
    }
}

struct GlobalCapture;

impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for GlobalCapture {
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let mut fields = Fields(String::new());
        event.record(&mut fields);
        GLOBAL_LINES
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(format!("{} {}", event.metadata().target(), fields.0));
    }
}

/// Install the process-wide subscriber (once). It is interested in every
/// event at every level, and records each event's target and fields for
/// [`global_lines`]. Call it before building a scoped capture.
pub(crate) fn install_global_capture() {
    INSTALL.call_once(|| {
        tracing::subscriber::set_global_default(tracing_subscriber::registry().with(GlobalCapture))
            .expect("no other test installs a process-wide subscriber");
    });
}

/// Every event of the process since [`install_global_capture`], from every
/// thread: other tests' lines are in it too, so assert on absence only.
pub(crate) fn global_lines() -> Vec<String> {
    GLOBAL_LINES
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}
