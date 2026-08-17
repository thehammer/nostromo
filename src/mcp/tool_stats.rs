//! In-process, on-demand latency snapshot for MCP tool dispatch.
//!
//! `ToolStats` is **not** a metrics pipeline: there is no persistence, no
//! external backend, and no periodic sampler. It keeps a bounded rolling
//! window of recent call durations per tool name in memory, plus a few
//! all-time counters, and resets whenever the daemon process restarts.
//! `nostromo.get_daemon_diagnostics` (see
//! [`crate::mcp::tools::daemon_diagnostics`]) is the only reader.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde_json::{json, Value};

/// Number of most-recent samples retained per tool. Percentiles (`p50_ms`,
/// `p95_ms`) are computed over this window; `calls` and `max_ms` are
/// all-time and are not affected by samples ageing out of the ring.
pub const SAMPLE_WINDOW: usize = 256;

/// Per-tool latency samples.
struct ToolSamples {
    /// All-time call count for this tool.
    calls: u64,
    /// All-time maximum observed duration, in milliseconds. Survives samples
    /// ageing out of `samples`.
    max_ms: f64,
    /// Duration of the most recent call, in milliseconds.
    last_ms: f64,
    /// Rolling window of the most recent durations, in milliseconds. Bounded
    /// at `SAMPLE_WINDOW`; oldest sample is dropped when full.
    samples: VecDeque<f64>,
}

impl ToolSamples {
    fn new() -> Self {
        Self {
            calls: 0,
            max_ms: 0.0,
            last_ms: 0.0,
            samples: VecDeque::with_capacity(SAMPLE_WINDOW),
        }
    }

    fn record(&mut self, elapsed_ms: f64) {
        self.calls += 1;
        self.last_ms = elapsed_ms;
        if elapsed_ms > self.max_ms {
            self.max_ms = elapsed_ms;
        }
        if self.samples.len() == SAMPLE_WINDOW {
            self.samples.pop_front();
        }
        self.samples.push_back(elapsed_ms);
    }
}

/// Bounded, in-memory latency store for MCP tool dispatch.
///
/// Shared across every connection: `McpSharedState` is cheap-clone (`Arc`),
/// and `tool_stats` is one of the fields carried inside it, so every MCP
/// connection records into and reads from the same store. It is constructed
/// once per MCP server (see `McpSharedState::new`), so for the
/// `nostromd`-hosted server its uptime is effectively daemon uptime.
pub struct ToolStats {
    inner: Mutex<HashMap<String, ToolSamples>>,
    started_at: Instant,
    started_at_wall: DateTime<Utc>,
}

impl ToolStats {
    /// Construct an empty store, stamped with the current time.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            started_at: Instant::now(),
            started_at_wall: Utc::now(),
        }
    }

    /// Record one completed dispatch of `tool`, having taken `elapsed`.
    ///
    /// Never panics: if the internal mutex is poisoned (a prior panicking
    /// holder), recovers via the poison guard rather than propagating —
    /// diagnostics bookkeeping must never take the daemon down.
    pub fn record(&self, tool: &str, elapsed: Duration) {
        let elapsed_ms = elapsed.as_secs_f64() * 1000.0;
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard
            .entry(tool.to_string())
            .or_insert_with(ToolSamples::new)
            .record(elapsed_ms);
    }

    /// Seconds since this store (and, for the daemon-hosted MCP server, the
    /// daemon itself) started.
    pub fn uptime_secs(&self) -> u64 {
        self.started_at.elapsed().as_secs()
    }

    /// RFC 3339 wall-clock timestamp of when this store was created.
    pub fn started_at_rfc3339(&self) -> String {
        self.started_at_wall.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
    }

    /// Snapshot the `tools` array plus totals, matching the shape documented
    /// on [`crate::mcp::tools::daemon_diagnostics::handle`].
    ///
    /// `tools` is sorted by `p95_ms` descending, then `name` ascending, so
    /// "which tool is slow" is answered by reading the top of the list and
    /// the output is deterministic for tests.
    pub fn snapshot_json(&self) -> Value {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());

        let mut total_calls: u64 = 0;
        let mut rows: Vec<(String, Value, f64)> = Vec::with_capacity(guard.len());
        for (name, samples) in guard.iter() {
            total_calls += samples.calls;
            let (p50, p95) = percentiles(&samples.samples);
            let row = json!({
                "name": name,
                "calls": samples.calls,
                "window": samples.samples.len(),
                "p50_ms": p50,
                "p95_ms": p95,
                "max_ms": round3(samples.max_ms),
                "last_ms": round3(samples.last_ms),
            });
            rows.push((name.clone(), row, p95));
        }

        rows.sort_by(|a, b| {
            b.2.partial_cmp(&a.2)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.0.cmp(&b.0))
        });

        let distinct_tools = guard.len();
        json!({
            "uptime_secs": self.uptime_secs(),
            "total_calls": total_calls,
            "distinct_tools": distinct_tools,
            "sample_window": SAMPLE_WINDOW,
            "tools": rows.into_iter().map(|(_, row, _)| row).collect::<Vec<_>>(),
        })
    }
}

impl Default for ToolStats {
    fn default() -> Self {
        Self::new()
    }
}

/// Round a millisecond figure to 3 decimal places.
fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

/// Nearest-rank p50/p95 over `samples`, sorted ascending internally.
///
/// `index = min(n - 1, max(0, ceil(p * n) - 1))`. Empty window yields `0.0`
/// for both. This exact rule is mirrored on the Swift side
/// (`IPCLatencyStats`) so the two implementations cannot silently drift —
/// the shared 1..=100 ms fixture is asserted identically on both sides.
fn percentiles(samples: &VecDeque<f64>) -> (f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mut sorted: Vec<f64> = samples.iter().copied().collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();
    let rank = |p: f64| -> f64 {
        let idx = ((p * n as f64).ceil() as isize - 1).clamp(0, n as isize - 1) as usize;
        sorted[idx]
    };
    (round3(rank(0.5)), round3(rank(0.95)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_over_1_to_100ms() {
        let stats = ToolStats::new();
        for ms in 1..=100u64 {
            stats.record("t", Duration::from_millis(ms));
        }
        let snap = stats.snapshot_json();
        let row = &snap["tools"][0];
        assert_eq!(row["calls"], 100);
        assert_eq!(row["p50_ms"], 50.0);
        assert_eq!(row["p95_ms"], 95.0);
        assert_eq!(row["max_ms"], 100.0);
    }

    #[test]
    fn max_ms_survives_aged_out_spike() {
        let stats = ToolStats::new();
        // A deliberate spike, then flood with small samples so the spike ages
        // out of the retained window while remaining the all-time max.
        stats.record("t", Duration::from_millis(9999));
        for _ in 0..(SAMPLE_WINDOW + 200) {
            stats.record("t", Duration::from_millis(1));
        }
        let snap = stats.snapshot_json();
        let row = &snap["tools"][0];
        assert_eq!(row["calls"], SAMPLE_WINDOW as u64 + 201);
        assert_eq!(row["window"], SAMPLE_WINDOW);
        assert_eq!(row["max_ms"], 9999.0);
    }

    #[test]
    fn empty_store_snapshots_without_panic() {
        let stats = ToolStats::new();
        let snap = stats.snapshot_json();
        assert_eq!(snap["total_calls"], 0);
        assert_eq!(snap["distinct_tools"], 0);
        assert_eq!(snap["tools"], json!([]));
    }

    #[test]
    fn snapshot_orders_by_p95_desc_then_name_asc() {
        let stats = ToolStats::new();
        stats.record("fast", Duration::from_millis(1));
        stats.record("slow", Duration::from_millis(100));
        stats.record("also_slow", Duration::from_millis(100));
        let snap = stats.snapshot_json();
        let names: Vec<&str> = snap["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["also_slow", "slow", "fast"]);
    }
}
