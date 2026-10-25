//! `HueyConfig`: the optional extra keys of `[agents.huey]`.
//!
//! `enabled` belongs to [`crate::agents::resolve`]. Everything here is
//! optional; a bad value warns (naming the key, never the value) and falls
//! back to its default.

use chrono::NaiveTime;

#[derive(Debug, Clone, PartialEq)]
pub struct HueyConfig {
    /// Ready-by time, local time of the daemon process.
    pub report_time: NaiveTime,
    pub lead_minutes: u32,
    pub model: String,
    pub tight_model: String,
    pub max_budget_usd: f64,
    pub tight_max_budget_usd: f64,
}

impl Default for HueyConfig {
    fn default() -> Self {
        Self {
            report_time: NaiveTime::from_hms_opt(6, 30, 0).expect("valid time"),
            lead_minutes: 30,
            model: "sonnet".to_string(),
            tight_model: "sonnet".to_string(),
            max_budget_usd: 3.0,
            tight_max_budget_usd: 1.0,
        }
    }
}

/// Read the extra keys of the `huey` table in `[agents]`. A missing or
/// non-table `agents` / `huey` gives the defaults with no warning (the agent
/// switch already warns about those shapes).
pub fn resolve(agents: Option<&toml::Value>) -> (HueyConfig, Vec<String>) {
    let mut cfg = HueyConfig::default();
    let mut warnings = Vec::new();
    let Some(table) = agents.and_then(toml::Value::as_table).and_then(|t| {
        // Same winner as `agents::resolve`: the last matching key that is
        // a usable table (a table whose `enabled`, if any, is a bool), so
        // the switch and these settings always come from one table.
        t.iter()
            .filter(|(k, _)| k.eq_ignore_ascii_case("huey"))
            .filter_map(|(_, v)| v.as_table())
            .filter(|t| matches!(t.get("enabled"), None | Some(toml::Value::Boolean(_))))
            .next_back()
    }) else {
        return (cfg, warnings);
    };
    for (key, value) in table {
        let name = crate::agents::escape_key(key);
        let bad = |warnings: &mut Vec<String>, what: &str| {
            warnings.push(format!(
                "agents.huey.{name} must be {what}; using the default"
            ));
        };
        match key.as_str() {
            "enabled" => {}
            "report_time" => match value
                .as_str()
                .and_then(|s| NaiveTime::parse_from_str(s, "%H:%M").ok())
            {
                Some(t) => cfg.report_time = t,
                None => bad(&mut warnings, "a time like \"06:30\""),
            },
            "lead_minutes" => match value.as_integer().filter(|n| (0..=720).contains(n)) {
                Some(n) => cfg.lead_minutes = n as u32,
                None => bad(&mut warnings, "a whole number of minutes from 0 to 720"),
            },
            "model" => match model_name(value) {
                Some(m) => cfg.model = m,
                None => bad(&mut warnings, "a model name"),
            },
            "tight_model" => match model_name(value) {
                Some(m) => cfg.tight_model = m,
                None => bad(&mut warnings, "a model name"),
            },
            "max_budget_usd" => match dollars(value) {
                Some(d) => cfg.max_budget_usd = d,
                None => bad(&mut warnings, "a positive number"),
            },
            "tight_max_budget_usd" => match dollars(value) {
                Some(d) => cfg.tight_max_budget_usd = d,
                None => bad(&mut warnings, "a positive number"),
            },
            _ => warnings.push(format!("unknown key `{name}` in [agents.huey]; ignoring")),
        }
    }
    (cfg, warnings)
}

fn model_name(v: &toml::Value) -> Option<String> {
    let s = v.as_str()?;
    let ok = !s.is_empty()
        && s.len() <= 64
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '[' | ']'));
    ok.then(|| s.to_string())
}

fn dollars(v: &toml::Value) -> Option<f64> {
    let d = match v {
        toml::Value::Float(f) => *f,
        toml::Value::Integer(i) => *i as f64,
        _ => return None,
    };
    (d.is_finite() && d > 0.0 && d <= 1000.0).then_some(d)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(src: &str) -> (HueyConfig, Vec<String>) {
        let v: toml::Value = toml::from_str(src).unwrap();
        resolve(v.get("agents"))
    }

    #[test]
    fn defaults_when_absent() {
        let (c, w) = resolve(None);
        assert_eq!(c, HueyConfig::default());
        assert!(w.is_empty());
        assert_eq!(c.report_time.format("%H:%M").to_string(), "06:30");
    }

    #[test]
    fn good_values_apply() {
        let (c, w) = r("[agents.huey]\nreport_time = \"07:15\"\nlead_minutes = 10\nmodel = \"opus\"\ntight_model = \"haiku\"\nmax_budget_usd = 5\ntight_max_budget_usd = 0.5\n");
        assert!(w.is_empty(), "{w:?}");
        assert_eq!(c.report_time.format("%H:%M").to_string(), "07:15");
        assert_eq!(c.lead_minutes, 10);
        assert_eq!(c.model, "opus");
        assert_eq!(c.tight_model, "haiku");
        assert_eq!(c.max_budget_usd, 5.0);
        assert_eq!(c.tight_max_budget_usd, 0.5);
    }

    #[test]
    fn a_bad_report_time_warns_by_key_and_keeps_the_default() {
        let (c, w) = r("[agents.huey]\nreport_time = \"25:99\"\n");
        assert_eq!(c.report_time, HueyConfig::default().report_time);
        assert_eq!(w.len(), 1);
        assert!(
            w[0].contains("report_time") && !w[0].contains("25:99"),
            "{w:?}"
        );
    }

    #[test]
    fn bad_values_and_unknown_keys_warn_once_each_without_values() {
        let (c, w) = r("[agents.huey]\nlead_minutes = \"soon\"\nmodel = \"has space\"\nmax_budget_usd = -1\nmystery = 1\n");
        assert_eq!(c, HueyConfig::default());
        assert_eq!(w.len(), 4, "{w:?}");
        let all = w.join(" ");
        assert!(!all.contains("soon") && !all.contains("has space"));
    }

    #[test]
    fn case_variant_keys_use_the_same_winner_as_the_agent_switch() {
        let src = "[agents.Huey]\nenabled = false\nreport_time = \"05:00\"\n[agents.huey]\nenabled = true\nreport_time = \"08:00\"\n";
        let v: toml::Value = toml::from_str(src).unwrap();
        let (enabled, _) = crate::agents::resolve(v.get("agents"));
        let (c, _) = resolve(v.get("agents"));
        assert!(enabled.huey, "lowercase `huey` sorts last and wins");
        assert_eq!(c.report_time.format("%H:%M").to_string(), "08:00");
    }

    #[test]
    fn a_non_table_variant_does_not_hide_a_valid_table() {
        let (c, w) = r("[agents]\nHuey = 5\n[agents.huey]\nreport_time = \"08:00\"\n");
        assert_eq!(c.report_time.format("%H:%M").to_string(), "08:00");
        assert!(w.is_empty(), "{w:?}");
        // And the other way round: the valid table is the earlier key.
        let (c, _) = r("[agents.Huey]\nreport_time = \"09:00\"\n[agents]\nhuey = 5\n");
        assert_eq!(c.report_time.format("%H:%M").to_string(), "09:00");
    }

    #[test]
    fn enabled_is_not_an_unknown_key_and_odd_shapes_are_silent() {
        assert!(r("[agents.huey]\nenabled = false\n").1.is_empty());
        assert!(r("[agents]\nhuey = false\n").1.is_empty());
        assert!(r("agents = 3\n").1.is_empty());
    }
}
