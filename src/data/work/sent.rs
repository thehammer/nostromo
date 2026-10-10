//! The sent ledger (`~/.nostromo/teri/sent.json`): which work items were sent
//! to an agent or Mother job. Placeholder until T5 lands: the ledger is empty.

use super::model::SentMarker;

/// Live markers for `item_id`.
pub fn markers_for(_item_id: &str) -> Vec<SentMarker> {
    Vec::new()
}
