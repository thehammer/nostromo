//! Wire types of the push feature (W13): what a phone registers, what it sets,
//! what the primary answers, and the two facts stamped on a `DecisionRequest`.
//!
//! Every type here is additive on the wire: absent fields decode to a default,
//! so an older peer's frame still decodes.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Whether the operator's Mac that presents decisions is being used.
/// Stamped by the originating daemon on a `DecisionRequest`; never sent to a
/// phone and never put in a relay request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Presence {
    Active,
    Away,
}

/// The asking agent mapped to a fixed set on the originating daemon, so a raw
/// agent or session name never leaves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentClass {
    Mother,
    Perri,
    Fred,
    Teri,
    Claudia,
    /// Also what a class this build does not know decodes to.
    #[serde(other)]
    Other,
}

impl AgentClass {
    /// Map an agent name to the fixed set. Anything else (including a dynamic
    /// session's own name) is `Other`.
    pub fn from_agent_name(name: &str) -> Self {
        match name.trim().to_ascii_lowercase().as_str() {
            "mother" => Self::Mother,
            "perri" => Self::Perri,
            "fred" => Self::Fred,
            "teri" => Self::Teri,
            "claudia" => Self::Claudia,
            _ => Self::Other,
        }
    }
}

/// The kinds a device can switch on or off.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushKind {
    Mother,
    Decision,
    Review,
}

impl PushKind {
    /// The relay's `kind` word for an individual notification.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mother => "mother",
            Self::Decision => "decision",
            Self::Review => "review",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushEnvironment {
    Sandbox,
    Production,
}

impl PushEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Production => "production",
        }
    }
}

/// What this build of the phone app can do. Every flag defaults to `false`,
/// so a `RegisterPush` without the field (or a flag a daemon predates) reads
/// as "cannot".
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushCapabilities {
    #[serde(default)]
    pub nse_withdraw: bool,
}

/// `HH:MM` quiet hours in the phone's local time.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuietHours {
    #[serde(default = "default_quiet_start")]
    pub start: String,
    #[serde(default = "default_quiet_end")]
    pub end: String,
    /// Off keeps the times: the morning digest still fires at `end`.
    #[serde(default = "default_true")]
    pub enabled: bool,
}

impl Default for QuietHours {
    fn default() -> Self {
        Self {
            start: default_quiet_start(),
            end: default_quiet_end(),
            enabled: true,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushKinds {
    #[serde(default = "default_true")]
    pub mother: bool,
    #[serde(default = "default_true")]
    pub decision: bool,
    #[serde(default = "default_true")]
    pub review: bool,
}

impl Default for PushKinds {
    fn default() -> Self {
        Self {
            mother: true,
            decision: true,
            review: true,
        }
    }
}

impl PushKinds {
    pub fn enabled(&self, kind: PushKind) -> bool {
        match kind {
            PushKind::Mother => self.mother,
            PushKind::Decision => self.decision,
            PushKind::Review => self.review,
        }
    }
}

/// One device's notification settings. `tz` is an IANA zone name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushPrefs {
    #[serde(default)]
    pub kinds: PushKinds,
    #[serde(default)]
    pub quiet: QuietHours,
    /// `HH:MM`; `None` turns the evening summary off.
    #[serde(default = "default_evening")]
    pub evening_summary: Option<String>,
    #[serde(default = "default_tz")]
    pub tz: String,
}

impl Default for PushPrefs {
    fn default() -> Self {
        Self {
            kinds: PushKinds::default(),
            quiet: QuietHours::default(),
            evening_summary: default_evening(),
            tz: default_tz(),
        }
    }
}

/// How the operator classified a host, on the primary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostClass {
    #[default]
    Work,
    Personal,
}

/// What a notification attempt came to. The seven words the sent log shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PushOutcome {
    DeliveredToApple,
    RejectedByApple,
    RelayUnreachable,
    HeldQuietHours,
    Coalesced,
    Withdrawn,
    SkippedResolvedInGrace,
}

/// A line of the sent log as the phone sees it (never the device reference).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushSentEntry {
    pub ts: DateTime<Utc>,
    pub kind: String,
    pub host: String,
    pub title: String,
    pub body: String,
    pub outcome: PushOutcome,
}

/// One item waiting on the operator, as the reconcile-on-open answer lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushWaitingItem {
    pub item_ref: String,
    pub kind: PushKind,
    pub host: String,
    /// `Job 3f9a1c2e`, `PR #4821`; absent for a decision.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub ref_: Option<String>,
}

/// The reply to `RegisterPush` and `SetPushPrefs`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushStatusBody {
    pub prefs: PushPrefs,
    /// Read-only: only a shell on the primary changes it.
    pub host_classes: BTreeMap<String, HostClass>,
    /// Read-only; always holds `Carefeed`.
    pub work_owners: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_ok_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failing_since: Option<DateTime<Utc>>,
}

fn default_true() -> bool {
    true
}
fn default_quiet_start() -> String {
    "22:00".to_string()
}
fn default_quiet_end() -> String {
    "07:00".to_string()
}
fn default_evening() -> Option<String> {
    Some("17:30".to_string())
}
fn default_tz() -> String {
    "UTC".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_agent_class_from_a_newer_build_reads_as_other() {
        let class: AgentClass = serde_json::from_str("\"robot_butler\"").unwrap();
        assert_eq!(class, AgentClass::Other);
        let known: AgentClass = serde_json::from_str("\"perri\"").unwrap();
        assert_eq!(known, AgentClass::Perri);
    }

    #[test]
    fn an_agent_name_maps_to_the_fixed_set_ignoring_case_and_padding() {
        for (name, want) in [
            ("mother", AgentClass::Mother),
            ("perri", AgentClass::Perri),
            ("fred", AgentClass::Fred),
            ("teri", AgentClass::Teri),
            ("claudia", AgentClass::Claudia),
            ("Claudia", AgentClass::Claudia),
            ("CLAUDIA", AgentClass::Claudia),
            ("  Perri  ", AgentClass::Perri),
            ("MoThEr", AgentClass::Mother),
            ("\tfred\n", AgentClass::Fred),
        ] {
            assert_eq!(AgentClass::from_agent_name(name), want, "{name:?}");
        }
    }

    #[test]
    fn anything_else_including_a_sessions_own_name_is_other() {
        for name in [
            "",
            "cody",
            "marty",
            "ada",
            "archie",
            "redd",
            "claude",
            "claudia-3f2a",
            "claudia in my-project",
            "Claudia in `nostromo`",
            "mother of dragons",
            "perri:review",
            "perri2",
            "claud ia",
            "secret-agent-man",
        ] {
            assert_eq!(
                AgentClass::from_agent_name(name),
                AgentClass::Other,
                "{name:?}"
            );
        }
    }

    #[test]
    fn the_per_kind_switches_each_govern_their_own_kind() {
        let off = PushKinds {
            mother: false,
            decision: true,
            review: true,
        };
        assert!(!off.enabled(PushKind::Mother));
        assert!(off.enabled(PushKind::Decision) && off.enabled(PushKind::Review));
        let only_review = PushKinds {
            mother: false,
            decision: false,
            review: true,
        };
        assert!(only_review.enabled(PushKind::Review));
        assert!(!only_review.enabled(PushKind::Decision) && !only_review.enabled(PushKind::Mother));
    }
}
