//! Which `nostromo-mcp-bridge` connections are live, per pty id.
//!
//! In memory only. Backs the `mcp_bridge_*` fields of `nostromo_get_self`
//! and the app-facing "tools offline" signal: a pty whose bridge was seen
//! but whose live count is now 0 has lost its `mcp__nostromo__*` tools.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::SystemTime;

#[derive(Debug, Clone, Copy)]
struct Entry {
    live: u64,
    /// Times the live count went 0 → 1, since daemon start.
    connects: u64,
    last_seen: SystemTime,
}

#[derive(Debug, Default)]
pub struct BridgeRegistry {
    entries: Mutex<HashMap<String, Entry>>,
}

impl BridgeRegistry {
    /// A bridge connection for `pty_id` was accepted. Returns true when this
    /// took the live count from 0 to 1. An empty id (an unidentified caller)
    /// is not tracked.
    pub fn open(&self, pty_id: &str) -> bool {
        if pty_id.is_empty() {
            return false;
        }
        let mut entries = self.lock();
        let entry = entries.entry(pty_id.to_owned()).or_insert(Entry {
            live: 0,
            connects: 0,
            last_seen: SystemTime::now(),
        });
        entry.live += 1;
        entry.last_seen = SystemTime::now();
        let first = entry.live == 1;
        if first {
            entry.connects += 1;
        }
        first
    }

    /// A bridge connection for `pty_id` ended. Returns true when this took the
    /// live count from 1 to 0.
    pub fn close(&self, pty_id: &str) -> bool {
        let mut entries = self.lock();
        let Some(entry) = entries.get_mut(pty_id) else {
            return false;
        };
        if entry.live == 0 {
            return false;
        }
        entry.live -= 1;
        entry.last_seen = SystemTime::now();
        entry.live == 0
    }

    /// `Some(live > 0)` for a pty that has ever had a bridge; `None` otherwise.
    pub fn connected(&self, pty_id: &str) -> Option<bool> {
        self.lock().get(pty_id).map(|e| e.live > 0)
    }

    /// Live connections for `pty_id`.
    pub fn live(&self, pty_id: &str) -> u64 {
        self.lock().get(pty_id).map_or(0, |e| e.live)
    }

    /// Connections after the first to take this pty from no bridge to a
    /// bridge, since daemon start.
    pub fn reconnects(&self, pty_id: &str) -> u64 {
        self.lock()
            .get(pty_id)
            .map_or(0, |e| e.connects.saturating_sub(1))
    }

    /// When a connection for `pty_id` last opened or closed.
    pub fn last_seen(&self, pty_id: &str) -> Option<SystemTime> {
        self.lock().get(pty_id).map(|e| e.last_seen)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Entry>> {
        self.entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
