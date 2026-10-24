//! The awaited control request: write a `control_request` to the CLI and wait
//! for its `control_response`. Shared by the model-switch machinery and the
//! background-task preview poller (`get_task_output`).

use std::sync::atomic::Ordering;
use std::time::Duration;

use tokio::sync::oneshot;
use uuid::Uuid;

use super::{write_control_request, Shared};

/// A `control_response`, as handed to the task that sent the request.
#[derive(Debug, Clone)]
pub(super) struct ControlReply {
    pub(super) ok: bool,
    pub(super) error: Option<String>,
    pub(super) error_code: Option<String>,
    pub(super) body: serde_json::Value,
}

/// How long the daemon waits for the answer to one control request.
pub const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);

/// Why a control request failed: the reason shown to the user, and whether
/// the CLI answered with a refusal (so nothing took effect).
pub(super) struct ControlFailure {
    pub(super) reason: String,
    pub(super) refused: bool,
    /// The `code` of the CLI's error, when it gave one.
    pub(super) code: Option<String>,
    /// The CLI did not answer in time (the request may still take effect).
    pub(super) timed_out: bool,
}

impl From<ControlFailure> for String {
    fn from(f: ControlFailure) -> String {
        f.reason
    }
}

/// Send a control request and wait (≤ [`CONTROL_TIMEOUT`]) for its answer.
pub(super) async fn control(
    shared: &Shared,
    request: serde_json::Value,
) -> std::result::Result<ControlReply, ControlFailure> {
    control_within(shared, request, CONTROL_TIMEOUT).await
}

/// `true` when a CLI's error says it does not know the request (an older CLI)
/// rather than that it refused this one.
pub(super) fn says_unsupported(reason: &str) -> bool {
    let reason = reason.to_lowercase();
    reason.contains("unsupported")
        || reason.contains("not supported")
        || (reason.contains("unknown") && reason.contains("subtype"))
}

/// [`control`] with the wait given (tests shorten it).
pub(super) async fn control_within(
    shared: &Shared,
    request: serde_json::Value,
    timeout: Duration,
) -> std::result::Result<ControlReply, ControlFailure> {
    let failure = |reason: String, refused: bool| ControlFailure {
        reason,
        refused,
        code: None,
        timed_out: false,
    };
    const EXITED: &str = "the session exited";
    let id = format!("model-{}", Uuid::new_v4());
    let (tx, rx) = oneshot::channel();
    shared.waiters.lock().unwrap().insert(id.clone(), tx);
    // Checked after registering: the reader sets `exited` before it drops
    // every waiter, so one of the two always notices an exit.
    if shared.exited.load(Ordering::SeqCst)
        || write_control_request(&shared.stdin, &id, request).is_err()
    {
        shared.waiters.lock().unwrap().remove(&id);
        return Err(failure(EXITED.to_owned(), false));
    }
    match tokio::time::timeout(timeout, rx).await {
        Ok(Ok(reply)) if reply.ok => Ok(reply),
        Ok(Ok(reply)) => Err(ControlFailure {
            reason: reply
                .error
                .or_else(|| reply.error_code.clone())
                .unwrap_or_else(|| "the session refused the change".to_owned()),
            refused: true,
            code: reply.error_code,
            timed_out: false,
        }),
        Ok(Err(_)) => Err(failure(EXITED.to_owned(), false)),
        Err(_) => {
            shared.waiters.lock().unwrap().remove(&id);
            Err(ControlFailure {
                reason: format!(
                    "the session did not answer within {} s",
                    timeout.as_secs().max(1)
                ),
                refused: false,
                code: None,
                timed_out: true,
            })
        }
    }
}
