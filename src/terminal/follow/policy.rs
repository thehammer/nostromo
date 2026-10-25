//! [`DeliveryPolicy`]: when to deliver what a followed terminal produced.
//!
//! A pure state machine. The caller reports output with
//! [`on_output`](DeliveryPolicy::on_output), asks what to do on a timer with
//! [`on_tick`](DeliveryPolicy::on_tick), and reports each delivery with
//! [`on_delivered`](DeliveryPolicy::on_delivered). Time is whatever
//! `Instant`s the caller passes in, so every rule is testable with explicit
//! times.

use std::collections::VecDeque;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use regex::Regex;

/// Cursor line that looks like a shell or REPL prompt waiting for input.
static PROMPT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:[$#%>❯]|>>>)\s*$").expect("prompt regex"));

const FLOOD_WINDOW: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(3600);

/// What a delivery contains.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryKind {
    /// Lines assembled from the output stream.
    Lines,
    /// A snapshot of the full-screen program's screen.
    Screen,
}

/// Why following paused itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PauseReason {
    /// Output volume, or repeated capped deliveries, crossed a flood
    /// threshold.
    TooMuchOutput,
    /// More than [`DeliveryPolicy::MAX_DELIVERIES_PER_HOUR`] in a rolling hour.
    TooManyDeliveries,
}

/// The answer to [`DeliveryPolicy::on_tick`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Nothing to do yet.
    Wait,
    /// Deliver now.
    Deliver { kind: DeliveryKind },
    /// Stop following until [`DeliveryPolicy::resume`]. Returned once.
    Pause { reason: PauseReason },
}

/// Delivery timing, batching and flood state for one followed terminal.
#[derive(Debug)]
pub struct DeliveryPolicy {
    /// Output has arrived since the last delivery.
    pending: bool,
    /// Where the sustained-output interval is measured from: the last
    /// delivery when this burst continues straight on from it, else the
    /// burst's first output.
    interval_start: Option<Instant>,
    last_output: Option<Instant>,
    last_delivery: Option<Instant>,
    /// `(when, bytes, lines)` for output in the last 60 seconds.
    output_window: VecDeque<(Instant, usize, usize)>,
    deliveries: VecDeque<Instant>,
    consecutive_capped: u32,
    paused: bool,
    screen_hash: Option<u64>,
    delivered_screen_hash: Option<u64>,
}

impl DeliveryPolicy {
    /// Quiet time after which output counts as settled.
    pub const SETTLE_QUIET: Duration = Duration::from_millis(800);
    /// Quiet time that suffices when the cursor line looks like a prompt.
    pub const PROMPT_SETTLE_QUIET: Duration = Duration::from_millis(200);
    /// Minimum gap between deliveries while output never settles.
    pub const MIN_SUSTAINED_INTERVAL: Duration = Duration::from_secs(10);
    /// Lines per delivery before head/tail truncation.
    pub const CAP_LINES: usize = 200;
    /// Bytes per delivery before head/tail truncation.
    pub const CAP_BYTES: usize = 16 * 1024;
    /// Lines kept from the start of a truncated delivery.
    pub const HEAD: usize = 50;
    /// Lines kept from the end of a truncated delivery.
    pub const TAIL: usize = 100;
    /// Flood: more lines than this in 60 seconds pauses following.
    pub const FLOOD_LINES_60S: usize = 5000;
    /// Flood: more bytes than this in 60 seconds pauses following.
    pub const FLOOD_BYTES_60S: usize = 1024 * 1024;
    /// Flood: this many capped deliveries in a row pauses following.
    pub const FLOOD_CONSECUTIVE_CAPPED: u32 = 3;
    /// More deliveries than this in a rolling hour pauses following.
    pub const MAX_DELIVERIES_PER_HOUR: usize = 60;

    /// A running policy with nothing pending.
    pub fn new() -> Self {
        Self {
            pending: false,
            interval_start: None,
            last_output: None,
            last_delivery: None,
            output_window: VecDeque::new(),
            deliveries: VecDeque::new(),
            consecutive_capped: 0,
            paused: false,
            screen_hash: None,
            delivered_screen_hash: None,
        }
    }

    /// Record `bytes_len` bytes / `lines_len` committed lines of output at
    /// `now`. Ignored while paused (the caller discards that output).
    pub fn on_output(&mut self, now: Instant, bytes_len: usize, lines_len: usize) {
        if self.paused {
            return;
        }
        if !self.pending {
            self.pending = true;
            let continues = self
                .last_delivery
                .filter(|&at| now.duration_since(at) < Self::SETTLE_QUIET);
            self.interval_start = Some(continues.unwrap_or(now));
        }
        self.last_output = Some(now);
        self.output_window.push_back((now, bytes_len, lines_len));
    }

    /// Report the current screen text of an alternate-screen program. At
    /// settle, a screen equal to the one last delivered is not delivered
    /// again. Call before [`on_tick`](Self::on_tick) while in alt screen; if
    /// never called, any pending output delivers.
    pub fn observe_screen(&mut self, text: &str) {
        self.screen_hash = Some(hash_text(text));
    }

    /// Decide what to do at `now`.
    ///
    /// `cursor_line` is the text on the cursor's line (the prompt candidate);
    /// `alt_screen` says a full-screen program is showing, which makes
    /// deliveries [`DeliveryKind::Screen`].
    ///
    /// Order: flood checks, then settle (800 ms quiet, or 200 ms at a prompt),
    /// then the sustained-output interval (10 s). A [`Decision::Pause`] is
    /// returned once; until [`resume`](Self::resume) every tick is
    /// [`Decision::Wait`].
    pub fn on_tick(
        &mut self,
        now: Instant,
        cursor_line: Option<&str>,
        alt_screen: bool,
    ) -> Decision {
        if self.paused {
            return Decision::Wait;
        }
        if let Some(reason) = self.flood(now) {
            return self.pause(reason);
        }
        if !self.pending {
            return Decision::Wait;
        }
        if !self.due(now, cursor_line) {
            return Decision::Wait;
        }

        let kind = if alt_screen {
            DeliveryKind::Screen
        } else {
            DeliveryKind::Lines
        };
        if kind == DeliveryKind::Screen
            && self.screen_hash.is_some()
            && self.screen_hash == self.delivered_screen_hash
        {
            self.clear_pending();
            return Decision::Wait;
        }

        self.prune_deliveries(now);
        if self.deliveries.len() >= Self::MAX_DELIVERIES_PER_HOUR {
            return self.pause(PauseReason::TooManyDeliveries);
        }
        self.deliveries.push_back(now);
        self.last_delivery = Some(now);
        self.clear_pending();
        if kind == DeliveryKind::Screen {
            self.delivered_screen_hash = self.screen_hash;
        }
        Decision::Deliver { kind }
    }

    /// Report a delivery made after [`Decision::Deliver`]. `capped` says the
    /// text was truncated (`Truncated::omitted > 0`); three capped
    /// deliveries in a row make the next tick pause.
    pub fn on_delivered(&mut self, capped: bool) {
        self.consecutive_capped = if capped {
            self.consecutive_capped + 1
        } else {
            0
        };
    }

    /// Leave the paused state with fresh windows and counters.
    pub fn resume(&mut self, _now: Instant) {
        *self = Self::new();
    }

    fn flood(&mut self, now: Instant) -> Option<PauseReason> {
        while self
            .output_window
            .front()
            .is_some_and(|&(at, ..)| now.duration_since(at) > FLOOD_WINDOW)
        {
            self.output_window.pop_front();
        }
        let (bytes, lines) = self
            .output_window
            .iter()
            .fold((0, 0), |(b, l), &(_, bytes, lines)| (b + bytes, l + lines));
        let flooded = lines > Self::FLOOD_LINES_60S
            || bytes > Self::FLOOD_BYTES_60S
            || self.consecutive_capped >= Self::FLOOD_CONSECUTIVE_CAPPED;
        flooded.then_some(PauseReason::TooMuchOutput)
    }

    fn pause(&mut self, reason: PauseReason) -> Decision {
        self.paused = true;
        self.clear_pending();
        Decision::Pause { reason }
    }

    /// Whether pending output should be delivered at `now`.
    fn due(&self, now: Instant, cursor_line: Option<&str>) -> bool {
        let quiet = self
            .last_output
            .map_or(Duration::ZERO, |at| now.duration_since(at));
        let at_prompt = cursor_line.is_some_and(|line| PROMPT_RE.is_match(line.trim()));
        let settle = if at_prompt {
            Self::PROMPT_SETTLE_QUIET
        } else {
            Self::SETTLE_QUIET
        };
        if quiet >= settle {
            return true;
        }
        // Not from a stale delivery: output after a long idle spell must not
        // be cut off at its first line.
        let since = self.interval_start.unwrap_or(now);
        now.duration_since(since) >= Self::MIN_SUSTAINED_INTERVAL
    }

    fn prune_deliveries(&mut self, now: Instant) {
        while self
            .deliveries
            .front()
            .is_some_and(|&at| now.duration_since(at) >= HOUR)
        {
            self.deliveries.pop_front();
        }
    }

    fn clear_pending(&mut self) {
        self.pending = false;
        self.interval_start = None;
    }
}

impl Default for DeliveryPolicy {
    fn default() -> Self {
        Self::new()
    }
}

fn hash_text(text: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}
