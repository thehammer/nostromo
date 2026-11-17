//! Applying the user's tracker edit (`ClientMsg::TrackerEdit`, T3a).
//!
//! The server has already checked the peer: only the verified Mac app with
//! its nonce gets here. Nothing in this file touches a session, so an edit
//! can never start or queue an agent turn.

use crate::ipc::protocol::{ServerMsg, TrackerEditError, TrackerPaneOp};
use crate::mcp::state::McpSharedState;

/// Applies `ops` as `pane (you)` on the blocking pool, broadcasts the board,
/// and answers for the asking connection.
pub async fn tracker_edit(
    state: &McpSharedState,
    tag: &str,
    request_id: &str,
    client: &str,
    base_version: u64,
    ops: Vec<TrackerPaneOp>,
) -> ServerMsg {
    let reply = |ok: bool, error: Option<TrackerEditError>, version: u64, created: Vec<String>| {
        ServerMsg::TrackerEditResult {
            tag: tag.to_string(),
            request_id: request_id.to_string(),
            ok,
            error,
            version,
            created,
        }
    };
    let Some(daemon) = &state.daemon else {
        let error = TrackerEditError {
            code: "not_supported".to_string(),
            reason: None,
            index: None,
        };
        return reply(false, Some(error), 0, Vec::new());
    };
    let registry = daemon.tracker.clone();
    let owned_tag = tag.to_string();
    let owned_client = client.to_string();
    let applied = tokio::task::spawn_blocking(move || {
        registry.apply_pane_ops_as(&owned_tag, &owned_client, base_version, &ops)
    })
    .await;
    // The edit is in the file; the pane sees it now, not on a debounce. A
    // refused edit may still have ingested an external save, so flush either way.
    daemon.tracker.flush(&daemon.broadcast_tx);
    match applied {
        Ok(Ok(outcome)) => reply(true, None, outcome.version, outcome.created),
        Ok(Err(err)) => {
            let error = TrackerEditError {
                code: err.code,
                reason: err.reason,
                index: err.index.map(|i| i as u32),
            };
            reply(false, Some(error), 0, Vec::new())
        }
        Err(_) => {
            let error = TrackerEditError {
                code: "io_error".to_string(),
                reason: Some("the edit did not finish".to_string()),
                index: None,
            };
            reply(false, Some(error), 0, Vec::new())
        }
    }
}
