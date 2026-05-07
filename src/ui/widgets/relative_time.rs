//! Port of the bash relative-time formatter from lib/fred/format.sh.
//!
//! Returns strings like "just now", "5m", "2h", "3d".

use chrono::{DateTime, Utc};

/// Format `dt` as a human-friendly relative time string relative to `now`.
pub fn format_relative(dt: &DateTime<Utc>, now: &DateTime<Utc>) -> String {
    let secs = (now.timestamp() - dt.timestamp()).max(0);
    if secs < 60 {
        "just now".to_string()
    } else if secs < 3600 {
        format!("{}m", secs / 60)
    } else if secs < 86400 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}d", secs / 86400)
    }
}

/// Format relative to `Utc::now()`.
pub fn format_relative_now(dt: &DateTime<Utc>) -> String {
    format_relative(dt, &Utc::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    #[test]
    fn test_just_now() {
        let now = Utc::now();
        assert_eq!(format_relative(&now, &now), "just now");
    }

    #[test]
    fn test_minutes() {
        let now = Utc::now();
        let past = now - Duration::minutes(7);
        assert_eq!(format_relative(&past, &now), "7m");
    }

    #[test]
    fn test_hours() {
        let now = Utc::now();
        let past = now - Duration::hours(3);
        assert_eq!(format_relative(&past, &now), "3h");
    }

    #[test]
    fn test_days() {
        let now = Utc::now();
        let past = now - Duration::days(2);
        assert_eq!(format_relative(&past, &now), "2d");
    }
}
