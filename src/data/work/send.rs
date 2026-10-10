//! Send a work item to an agent or Mother job: placeholder until T5
//! (teri-fred-t5-send-to-agent) lands.

use super::hub::HubContext;
use super::model::{SendOutcome, SendPreview, WorkError};
use super::service::SendRequest;

pub async fn preview(_ctx: &HubContext, _item_id: &str) -> Result<SendPreview, WorkError> {
    Err(WorkError::not_available())
}

pub async fn send(_ctx: &HubContext, _request: SendRequest) -> Result<SendOutcome, WorkError> {
    Err(WorkError::not_available())
}
