//! Mother job queue client — phase 1 stub.
//!
//! Phase 3 will wire this up to the real `mother` binary's job queue (JSON
//! socket or state directory) to display job status in the status bar and
//! surface inline `await` approval modals.

/// Summary of the Mother queue for display in the status bar.
#[derive(Debug, Clone, Default)]
pub struct MotherStatus {
    pub running: usize,
    pub queued: usize,
    pub awaiting: usize,
    pub last_failed: Option<String>,
}

impl MotherStatus {
    /// Phase 1: always returns an empty stub.
    pub fn load() -> Self {
        Self::default()
    }

    pub fn status_line(&self) -> String {
        if self.awaiting > 0 {
            format!("⚙ mother: {} awaiting", self.awaiting)
        } else if self.running > 0 || self.queued > 0 {
            format!("⚙ mother: {} running, {} queued", self.running, self.queued)
        } else {
            "⚙ mother: idle".to_string()
        }
    }
}
