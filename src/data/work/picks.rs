//! Teri's picks: placeholder until T4 (teri-fred-t4-picks) lands.

use super::hub::HubContext;
use super::model::WorkError;

/// Start (or ignore, if one is in flight) a picks generation.
pub async fn refresh(_ctx: &HubContext, _reason: &str) -> Result<(), WorkError> {
    Err(WorkError::not_available())
}
