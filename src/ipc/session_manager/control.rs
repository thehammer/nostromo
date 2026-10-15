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
    let failure = |reason: String, refused: bool| ControlFailure { reason, refused };
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
    match tokio::time::timeout(CONTROL_TIMEOUT, rx).await {
        Ok(Ok(reply)) if reply.ok => Ok(reply),
        Ok(Ok(reply)) => Err(failure(
            reply
                .error
                .or(reply.error_code)
                .unwrap_or_else(|| "the session refused the change".to_owned()),
            true,
        )),
        Ok(Err(_)) => Err(failure(EXITED.to_owned(), false)),
        Err(_) => {
            shared.waiters.lock().unwrap().remove(&id);
            Err(failure(
                format!(
                    "the session did not answer within {} s",
                    CONTROL_TIMEOUT.as_secs()
                ),
                false,
            ))
        }
    }
}
