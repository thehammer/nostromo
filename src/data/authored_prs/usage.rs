//! Counts of this feature's own GitHub requests: a rolling hour and since the
//! daemon started. Counts only; never a path, a repo or a number.

use std::collections::VecDeque;

use tokio::time::Instant;

use super::budget::{Posture, HOUR};
use super::snapshot::{UsageCounts, UsageView};

#[derive(Debug, Clone, Copy)]
pub struct Record {
    /// Counted against GitHub's budget (a 200; a 304 is not).
    pub charged: bool,
    pub not_modified: bool,
    pub search: bool,
    pub graphql_points: u64,
    /// Caused by a relay event rather than by the poll.
    pub relay: bool,
    pub posture: Posture,
}

impl Record {
    fn add_to(&self, c: &mut UsageCounts) {
        if self.charged {
            c.charged += 1;
            if self.relay {
                c.relay_charged += 1;
            }
            match self.posture {
                Posture::Visible => c.visible_charged += 1,
                Posture::Hidden => c.hidden_charged += 1,
                _ => {}
            }
        }
        if self.not_modified {
            c.not_modified += 1;
        }
        if self.search {
            c.search += 1;
        }
        c.graphql_points += self.graphql_points;
    }
}

#[derive(Debug, Default)]
pub struct UsageLog {
    recent: VecDeque<(Instant, Record)>,
    total: UsageCounts,
}

impl UsageLog {
    pub fn record(&mut self, now: Instant, r: Record) {
        self.prune(now);
        r.add_to(&mut self.total);
        self.recent.push_back((now, r));
    }

    fn prune(&mut self, now: Instant) {
        while self
            .recent
            .front()
            .is_some_and(|(t, _)| now.saturating_duration_since(*t) >= HOUR)
        {
            self.recent.pop_front();
        }
    }

    pub fn view(&mut self, now: Instant) -> UsageView {
        self.prune(now);
        let mut window = UsageCounts::default();
        for (_, r) in &self.recent {
            r.add_to(&mut window);
        }
        UsageView {
            window_secs: HOUR.as_secs(),
            window,
            since_start: self.total,
        }
    }
}
