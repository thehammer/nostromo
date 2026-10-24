//! Wire types for Mother's "headless crew" job keys (quality gates, the lens
//! review wave, decisions, attention, progress).
//!
//! The contract is vendored under `tests/fixtures/mother-contract/` (see
//! `scripts/mother-contract.py`). Every type here is deliberately lenient:
//! every field defaults, unknown keys are ignored (never `deny_unknown_fields`)
//! and enum-like values stay plain strings so a value Mother adds later still
//! decodes.
//!
//! Wire payloads carry no free text, so none of these types has a field for
//! gate output, finding text, claim quotes or checklist text (`excerpt`,
//! `summary`, `quote`, `output`, `text`). Do not add one, even an optional one.
//! The `label` and `consequence` strings are Mother-templated option text.

use serde::{Deserialize, Serialize};

// ── gates ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CrewGates {
    pub mode: Option<String>,
    pub posture: Option<String>,
    /// `running`, `passed`, `failed`, `incomplete`, `exhausted`, ...
    pub status: Option<String>,
    pub attempt: Option<u32>,
    pub max_attempts: Option<u32>,
    pub head_sha: Option<String>,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub results: Vec<GateResultEntry>,
    pub not_run: Vec<String>,
    /// True when the wire's `override` is present and non-null. Its content
    /// is not read, and is re-serialized as `override: true`.
    #[serde(
        rename = "override",
        deserialize_with = "lenient::present",
        skip_serializing_if = "std::ops::Not::not"
    )]
    pub overridden: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GateResultEntry {
    pub name: String,
    /// `passed`, `failed`, `skipped`, `unavailable`, or a value from the future.
    pub result: String,
    pub blocking: bool,
    pub duration_s: Option<u64>,
    pub exit_code: Option<i64>,
    pub unavailable_reason: Option<String>,
}

// ── review wave ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ReviewWave {
    pub mode: Option<String>,
    pub cycle: Option<u32>,
    pub cycle_cap: Option<u32>,
    pub status: Option<String>,
    pub budget_usd: Option<f64>,
    pub spent_usd: Option<f64>,
    pub lenses: Vec<LensEntry>,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub adherence: Option<WaveAdherence>,
    pub coverage_gaps: Option<u32>,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub claims: Option<ClaimCounts>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LensEntry {
    pub reviewer: String,
    pub lens: String,
    /// `pending`, `running`, `done`, `skipped`, `error`, or a value from the future.
    pub state: String,
    pub skip_reason: Option<String>,
    #[serde(deserialize_with = "lenient::object")]
    pub findings: LensFindings,
    pub cost_usd: Option<f64>,
    pub examined_files: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LensFindings {
    pub blocking: u32,
    pub advisory: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WaveAdherence {
    pub state: Option<String>,
    pub verdict: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ClaimCounts {
    pub verified: u32,
    pub refuted: u32,
    pub unverified: u32,
}

// ── decisions ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CrewDecision {
    pub id: String,
    pub kind: String,
    pub options: Vec<DecisionOption>,
    pub opened_at: Option<String>,
    pub resolved_at: Option<String>,
    pub resolution: Option<DecisionResolution>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DecisionOption {
    /// `resume_with_guidance`, `escalate`, `override_open`, `cancel`, or a value from the future.
    pub id: String,
    pub label: String,
    pub consequence: String,
    pub takes_text: bool,
}

/// How a decision was resolved. Mother has not pinned its shape: accept a bare
/// option id or an object, so either never costs the decision.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct DecisionResolution {
    pub option: Option<String>,
    pub source: Option<String>,
    pub at: Option<String>,
}

impl<'de> Deserialize<'de> for DecisionResolution {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Option(String),
            Object {
                #[serde(default)]
                option: Option<String>,
                #[serde(default)]
                source: Option<String>,
                #[serde(default)]
                at: Option<String>,
            },
        }
        Ok(match Raw::deserialize(d)? {
            Raw::Option(option) => Self {
                option: Some(option),
                ..Self::default()
            },
            Raw::Object { option, source, at } => Self { option, source, at },
        })
    }
}

// ── attention and answers ────────────────────────────────────────────────────

/// One attention reason. `acked` is only present on `attention_reasons`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AttentionEntry {
    /// `progress_stalled`, `burn_ahead`, `gates_incomplete`, `decision_awaiting`, or a value from the future.
    pub reason: String,
    pub since: Option<String>,
    pub acked: Option<bool>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LastAnswer {
    pub source: Option<String>,
    pub session: Option<String>,
    pub agent: Option<String>,
    pub option: Option<String>,
    pub at: Option<String>,
}

// ── progress ─────────────────────────────────────────────────────────────────

/// Mother's `.progress` overlay (also the `progress_updated` event detail).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CrewProgress {
    pub v: Option<u32>,
    pub pct: Option<u32>,
    /// Mother-written display text for the stage (`paused · <reason>` when paused).
    pub label: Option<String>,
    pub stage: Option<String>,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub signals: Option<ProgressSignals>,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub eta: Option<ProgressEta>,
    pub paused: bool,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub moved_back: Option<MovedBack>,
    pub flags: Vec<ProgressFlag>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ProgressSignals {
    pub stage: Option<String>,
    #[serde(deserialize_with = "lenient::opt_object")]
    pub gates: Option<GateSignal>,
    pub elapsed_active_s: Option<u64>,
    /// Spend so far in USD. Mother's recordings send `{usd, of_usd, basis, fraction}`;
    /// older fixtures sent a bare number. Both read as the USD figure; anything else is missing.
    #[serde(deserialize_with = "cost_usd")]
    pub cost: Option<f64>,
}

fn cost_usd<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(match v {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::Object(o) => o.get("usd").and_then(serde_json::Value::as_f64),
        _ => None,
    })
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GateSignal {
    pub passed: u32,
    pub failed: u32,
    pub total: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ProgressEta {
    pub lo_s: Option<u64>,
    pub hi_s: Option<u64>,
    pub label: Option<String>,
    /// `repo`, `fleet`, `none`, or a value from the future.
    pub basis: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MovedBack {
    pub reason: Option<String>,
    pub at: Option<String>,
}

/// A progress flag: Mother's plan writes objects (`{reason, since, detail}`),
/// the fixtures have none, and a bare string must work too. Only `reason` and
/// `since` are kept; `detail` is not read.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct ProgressFlag {
    pub reason: String,
    pub since: Option<String>,
}

impl<'de> Deserialize<'de> for ProgressFlag {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Reason(String),
            Object {
                #[serde(default)]
                reason: String,
                #[serde(default)]
                since: Option<String>,
            },
        }
        Ok(match Raw::deserialize(d)? {
            Raw::Reason(reason) => Self {
                reason,
                since: None,
            },
            Raw::Object { reason, since } => Self { reason, since },
        })
    }
}

// ── lenient decoding ─────────────────────────────────────────────────────────

/// Per-key lenient `deserialize_with` helpers for the new `MotherJob` keys
/// (locked bet B2: a malformed new key never costs the job).
///
/// Each helper reads its key as a JSON value, then tries the target type. On
/// failure it yields the type's default and logs one content-free warning
/// (job id when known, key path, error class; deduped per run exactly like the
/// job-level warning in [`super::decode`]).
pub mod lenient {
    use crate::mother::decode::{describe, warn_unreadable_key};
    use serde::de::{DeserializeOwned, Deserializer, Error as _, Unexpected};
    use serde::Deserialize;
    use serde_json::Value;

    /// The JSON shape a key must have. serde would otherwise read `[]` as an
    /// all-defaults struct, quietly turning a malformed key into an empty one.
    #[derive(Clone, Copy)]
    pub enum Shape {
        Object,
        Array,
        Scalar,
    }

    impl Shape {
        fn accepts(self, v: &Value) -> bool {
            match self {
                Shape::Object => v.is_object(),
                Shape::Array => v.is_array(),
                Shape::Scalar => !v.is_object() && !v.is_array(),
            }
        }
    }

    /// Decode `d` as `T`, falling back to `T::default()` (null is the default too).
    pub fn decode_key<'de, D, T>(d: D, key: &'static str, shape: Shape) -> Result<T, D::Error>
    where
        D: Deserializer<'de>,
        T: DeserializeOwned + Default,
    {
        let mut value = Value::deserialize(d)?;
        if value.is_null() {
            return Ok(T::default());
        }
        if !shape.accepts(&value) {
            warn_unreadable_key(key, ".", "invalid type");
            return Ok(T::default());
        }
        // A Go producer writes a nil slice as `null`: read a null object member as missing
        // (so its default applies) rather than as a type error that would drop the key.
        strip_null_members(&mut value);
        match serde_path_to_error::deserialize::<_, T>(value) {
            Ok(t) => Ok(t),
            Err(e) => {
                let (path, class) = describe(&e);
                warn_unreadable_key(key, &path, class);
                Ok(T::default())
            }
        }
    }

    fn strip_null_members(v: &mut Value) {
        match v {
            Value::Object(m) => {
                m.retain(|_, member| !member.is_null());
                m.values_mut().for_each(strip_null_members);
            }
            Value::Array(items) => items.iter_mut().for_each(strip_null_members),
            _ => {}
        }
    }

    macro_rules! lenient_keys {
        ($($name:ident => $key:literal, $shape:ident);* $(;)?) => {$(
            pub fn $name<'de, D, T>(d: D) -> Result<T, D::Error>
            where
                D: Deserializer<'de>,
                T: DeserializeOwned + Default,
            {
                decode_key(d, $key, Shape::$shape)
            }
        )*};
    }

    lenient_keys! {
        activity => "activity", Scalar;
        pr_url => "pr_url", Scalar;
        gates => "gates", Object;
        review_wave => "review_wave", Object;
        decision => "decision", Object;
        attention => "attention", Array;
        attention_reasons => "attention_reasons", Array;
        last_answer => "last_answer", Object;
        progress => "progress", Object;
        criteria_source => "criteria_source", Scalar;
    }

    /// True iff the key is present and not null. Never fails: it is how the
    /// opaque `crew` blob (and `gates.override`) is reduced to a flag without
    /// being stored. A bool (the serialized form) is taken as is.
    pub fn present<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
        Ok(match Value::deserialize(d)? {
            Value::Null => false,
            Value::Bool(b) => b,
            _ => true,
        })
    }

    /// An optional nested object. Null is `None`; anything but an object is an
    /// `invalid type` error, which the enclosing top-level key turns into its default.
    pub fn opt_object<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
    where
        D: Deserializer<'de>,
        T: DeserializeOwned,
    {
        match Value::deserialize(d)? {
            Value::Null => Ok(None),
            v @ Value::Object(_) => T::deserialize(v).map(Some).map_err(D::Error::custom),
            other => Err(D::Error::invalid_type(unexpected(&other), &"an object")),
        }
    }

    /// Like [`opt_object`] for a nested object that is not optional.
    pub fn object<'de, D, T>(d: D) -> Result<T, D::Error>
    where
        D: Deserializer<'de>,
        T: DeserializeOwned + Default,
    {
        Ok(opt_object(d)?.unwrap_or_default())
    }

    /// What kind of value was found, with no content: serde's own `Unexpected`
    /// would embed the number or string.
    fn unexpected(v: &Value) -> Unexpected<'static> {
        match v {
            Value::Null => Unexpected::Unit,
            Value::Bool(_) => Unexpected::Other("a boolean"),
            Value::Number(_) => Unexpected::Other("a number"),
            Value::String(_) => Unexpected::Other("a string"),
            Value::Array(_) => Unexpected::Seq,
            Value::Object(_) => Unexpected::Map,
        }
    }
}
