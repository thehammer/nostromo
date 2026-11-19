//! Perri's verdicts on a PR's head commit, kept so the Overview can tell
//! whether the commit about to be merged is the one Perri approved.
//!
//! `<state_root>/perri-verdicts.json`, mode 0600, written atomically. One record
//! per `repo + number + head_sha` (the full 40-hex head commit): the newest
//! verdict for a head wins (the one it replaced, when different, is kept one
//! level deep as `replaced`). At most [`MAX_RECORDS`] records are kept, the newest
//! ones. A new push is a new head, so a verdict recorded for the old head never
//! applies to it.
//!
//! A record holds the verdict, a time, who recorded it and an optional short
//! plain-text note. The note is data: it is never rendered as markup, never put
//! on the board row and never logged. Nothing in this module logs a repo,
//! number, SHA, name or note.
//!
//! The file is read leniently: unknown fields are ignored, a record that does
//! not validate is dropped, and a file that does not parse starts the store
//! empty (the bytes are kept as a backup, see `load_json_checked`).

use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::snapshot::valid_repo;
use crate::mother::origin::{load_json_checked, write_private};

pub const MAX_RECORDS: usize = 500;
/// The longest `by` kept (characters).
pub const MAX_BY: usize = 80;
/// The longest `note` kept (characters). The MCP tool refuses a longer one.
pub const MAX_NOTE: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Approved,
    ChangesRequested,
    Comment,
}

impl Verdict {
    pub fn parse(s: &str) -> Option<Verdict> {
        match s {
            "approved" => Some(Verdict::Approved),
            "changes_requested" => Some(Verdict::ChangesRequested),
            "comment" => Some(Verdict::Comment),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Approved => "approved",
            Verdict::ChangesRequested => "changes_requested",
            Verdict::Comment => "comment",
        }
    }
}

/// A full head commit: 40 lowercase hex digits.
pub fn is_full_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The first 8 hex digits of a full head commit; `None` for anything else.
pub fn short_sha(full: &str) -> Option<String> {
    is_full_sha(full).then(|| full[..8].to_owned())
}

/// Unicode category `Cf` (format characters: bidi overrides and isolates,
/// zero-width joiners and spaces, marks, tag characters) plus the line and
/// paragraph separators. They draw nothing, or reorder what is drawn, so a name
/// holding one can pass for another.
fn is_invisible(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2
        | 0x180E | 0x200B..=0x200F | 0x2028..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F
        | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F
        | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

/// `s` without control or invisible/format characters, then at most `max`
/// characters.
pub fn plain_text(s: &str, max: usize) -> String {
    s.chars()
        .filter(|c| !c.is_control() && !is_invisible(*c))
        .take(max)
        .collect()
}

fn clean(s: Option<&str>, max: usize) -> Option<String> {
    s.map(|s| plain_text(s, max).trim().to_owned())
        .filter(|s| !s.is_empty())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerdictRecord {
    /// `owner/name`, lowercased.
    pub repo: String,
    pub number: u64,
    /// The full head commit the verdict is for.
    pub head_sha: String,
    pub verdict: Verdict,
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// The different verdict for the same head this one replaced (one level):
    /// "approved by X, previously changes requested by Y". Not on the board row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replaced: Option<ReplacedVerdict>,
}

/// What a verdict replaced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplacedVerdict {
    pub verdict: Verdict,
    pub at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<String>,
}

impl VerdictRecord {
    /// A record, or `None` when `repo`, `number` or `head_sha` is not valid.
    /// `by` and `note` are stripped of control and invisible/format characters
    /// and cut to their limits; an empty one is dropped.
    pub fn new(
        repo: &str,
        number: u64,
        head_sha: &str,
        verdict: Verdict,
        at: DateTime<Utc>,
        by: Option<&str>,
        note: Option<&str>,
    ) -> Option<VerdictRecord> {
        if !valid_repo(repo) || number == 0 || !is_full_sha(head_sha) {
            return None;
        }
        Some(VerdictRecord {
            repo: repo.to_ascii_lowercase(),
            number,
            head_sha: head_sha.to_owned(),
            verdict,
            at,
            by: clean(by, MAX_BY),
            note: clean(note, MAX_NOTE),
            replaced: None,
        })
    }

    /// This record is about to replace `prior` (the same head): when the
    /// verdict differs, remember `prior` as what was replaced; when it is the
    /// same verdict, keep what `prior` had replaced.
    fn replacing(mut self, prior: &VerdictRecord) -> VerdictRecord {
        self.replaced = if prior.verdict != self.verdict {
            Some(ReplacedVerdict {
                verdict: prior.verdict,
                at: prior.at,
                by: prior.by.clone(),
            })
        } else {
            prior.replaced.clone()
        };
        self
    }

    fn is_for(&self, repo: &str, number: u64) -> bool {
        self.number == number && self.repo.eq_ignore_ascii_case(repo)
    }
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    /// Each record is validated on its own, so one bad entry costs only itself.
    #[serde(default)]
    records: Vec<serde_json::Value>,
}

/// Perri's verdicts. Cheap to share behind an `Arc`.
pub struct VerdictStore {
    path: Option<PathBuf>,
    /// Oldest first: a new record goes last, so the front is what is dropped.
    records: Mutex<Vec<VerdictRecord>>,
}

impl VerdictStore {
    /// A store that is never written to disk.
    pub fn in_memory() -> Self {
        VerdictStore {
            path: None,
            records: Mutex::new(Vec::new()),
        }
    }

    /// The store under `state_root`. A missing file starts empty; a corrupt one
    /// starts empty too, and is not an error.
    pub fn open(state_root: &std::path::Path) -> Self {
        let path = state_root.join("perri-verdicts.json");
        let (file, _) = load_json_checked::<File>(&path);
        let mut records: Vec<VerdictRecord> = file
            .records
            .into_iter()
            .filter_map(|v| serde_json::from_value::<VerdictRecord>(v).ok())
            .filter_map(|r| {
                // The file is not trusted: the same checks a new record gets.
                let mut rec = VerdictRecord::new(
                    &r.repo,
                    r.number,
                    &r.head_sha,
                    r.verdict,
                    r.at,
                    r.by.as_deref(),
                    r.note.as_deref(),
                )?;
                rec.replaced = r.replaced.map(|p| ReplacedVerdict {
                    by: clean(p.by.as_deref(), MAX_BY),
                    ..p
                });
                Some(rec)
            })
            .collect();
        // Oldest first (stable), then one per head (the later one wins), then the newest N.
        records.sort_by_key(|r| r.at);
        let mut kept: Vec<VerdictRecord> = Vec::with_capacity(records.len());
        for r in records {
            let r = match kept.iter().find(|k| same_head(k, &r)) {
                Some(prior) => r.replacing(prior),
                None => r,
            };
            kept.retain(|k| !same_head(k, &r));
            kept.push(r);
        }
        if kept.len() > MAX_RECORDS {
            kept.drain(..kept.len() - MAX_RECORDS);
        }
        VerdictStore {
            path: Some(path),
            records: Mutex::new(kept),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<VerdictRecord>> {
        self.records.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record `rec`, replacing any earlier verdict for the same head (which it
    /// keeps, one level, as `replaced` when the verdict differs).
    pub fn record(&self, rec: VerdictRecord) {
        let mut g = self.lock();
        let rec = match g.iter().find(|k| same_head(k, &rec)) {
            Some(prior) => rec.replacing(prior),
            None => rec,
        };
        g.retain(|k| !same_head(k, &rec));
        g.push(rec);
        if g.len() > MAX_RECORDS {
            let extra = g.len() - MAX_RECORDS;
            g.drain(..extra);
        }
        if let Some(path) = &self.path {
            let file = File {
                records: g
                    .iter()
                    .filter_map(|r| serde_json::to_value(r).ok())
                    .collect(),
            };
            if write_private(path, &file).is_err() {
                tracing::warn!("perri verdicts could not be written");
            }
        }
    }

    /// The verdict for exactly this head, if any.
    pub fn for_head(&self, repo: &str, number: u64, head_sha: &str) -> Option<VerdictRecord> {
        self.lock()
            .iter()
            .find(|r| r.is_for(repo, number) && r.head_sha == head_sha)
            .cloned()
    }

    /// The newest verdict for the PR, whatever head it is for.
    pub fn newest(&self, repo: &str, number: u64) -> Option<VerdictRecord> {
        self.lock()
            .iter()
            .rev()
            .find(|r| r.is_for(repo, number))
            .cloned()
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn same_head(a: &VerdictRecord, b: &VerdictRecord) -> bool {
    a.number == b.number && a.repo == b.repo && a.head_sha == b.head_sha
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn at(n: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + n, 0).unwrap()
    }

    fn rec(repo: &str, number: u64, sha: &str, v: Verdict, n: i64) -> VerdictRecord {
        VerdictRecord::new(repo, number, sha, v, at(n), Some("perri"), None).unwrap()
    }

    #[test]
    fn a_record_needs_a_valid_repo_number_and_full_sha() {
        let ok = |repo: &str, n: u64, sha: &str| {
            VerdictRecord::new(repo, n, sha, Verdict::Approved, at(0), None, None).is_some()
        };
        let upper = SHA_A.to_uppercase();
        let not_hex = format!("{}g", &SHA_A[..39]);
        assert!(ok("Acme/Web", 1, SHA_A));
        assert!(!ok("acme", 1, SHA_A));
        assert!(!ok("acme/web", 0, SHA_A));
        assert!(!ok("acme/web", 1, "aaaaaaaa"));
        assert!(!ok("acme/web", 1, &upper));
        assert!(!ok("acme/web", 1, &not_hex));
    }

    #[test]
    fn text_fields_lose_control_characters_and_are_cut() {
        let r = VerdictRecord::new(
            "acme/web",
            1,
            SHA_A,
            Verdict::Comment,
            at(0),
            Some(&format!("{}\u{1b}[31m", "x".repeat(200))),
            Some("a\nb\u{0}c"),
        )
        .unwrap();
        assert_eq!(r.by.as_deref().map(|s| s.chars().count()), Some(MAX_BY));
        assert!(!r.by.unwrap().contains('\u{1b}'));
        assert_eq!(r.note.as_deref(), Some("abc"));
    }

    #[test]
    fn invisible_and_format_characters_are_stripped_from_the_name_and_the_note() {
        // A right-to-left override, a zero-width space, a joiner, an isolate, a
        // byte order mark, a soft hyphen and a tag character.
        let sneaky = "pe\u{202E}rri\u{200B}\u{200D}\u{2066}\u{FEFF}\u{AD}\u{E0041}";
        let r = VerdictRecord::new(
            "acme/web",
            1,
            SHA_A,
            Verdict::Comment,
            at(0),
            Some(sneaky),
            Some(&format!("ok\u{202E}\u{200B}{}", "y".repeat(300))),
        )
        .unwrap();
        assert_eq!(r.by.as_deref(), Some("perri"));
        let note = r.note.unwrap();
        assert!(note.starts_with("okyyy"), "{note:?}");
        assert_eq!(note.chars().count(), MAX_NOTE, "cut after stripping");
        // Only invisible characters: no name at all.
        let r = VerdictRecord::new(
            "acme/web",
            1,
            SHA_A,
            Verdict::Comment,
            at(0),
            Some("\u{202E}\u{200B}"),
            None,
        )
        .unwrap();
        assert_eq!(r.by, None);
        // Ordinary text is untouched: letters, accents, CJK, emoji.
        assert_eq!(plain_text("Zoë 日本 ✅", 80), "Zoë 日本 ✅");
    }

    #[test]
    fn the_length_cap_counts_what_is_left_after_stripping() {
        let padded = format!("{}{}", "\u{200B}".repeat(500), "n".repeat(MAX_BY + 20));
        let r = VerdictRecord::new(
            "acme/web",
            1,
            SHA_A,
            Verdict::Comment,
            at(0),
            Some(&padded),
            None,
        )
        .unwrap();
        assert_eq!(r.by.unwrap(), "n".repeat(MAX_BY));
    }

    #[test]
    fn a_different_verdict_for_the_same_head_keeps_what_it_replaced_one_level_deep() {
        let s = VerdictStore::in_memory();
        let by = |who: &str, v: Verdict, n: i64| {
            VerdictRecord::new("acme/web", 1, SHA_A, v, at(n), Some(who), None).unwrap()
        };
        s.record(by("perri", Verdict::ChangesRequested, 0));
        assert_eq!(s.for_head("acme/web", 1, SHA_A).unwrap().replaced, None);

        s.record(by("mallory", Verdict::Approved, 1));
        let r = s.for_head("acme/web", 1, SHA_A).unwrap();
        assert_eq!(r.verdict, Verdict::Approved);
        assert_eq!(r.by.as_deref(), Some("mallory"));
        let p = r.replaced.expect("what it replaced");
        assert_eq!(
            (p.verdict, p.by.as_deref(), p.at),
            (Verdict::ChangesRequested, Some("perri"), at(0))
        );

        // The same verdict again keeps the note of what was replaced.
        s.record(by("perri", Verdict::Approved, 2));
        let r = s.for_head("acme/web", 1, SHA_A).unwrap();
        assert_eq!(r.by.as_deref(), Some("perri"));
        assert_eq!(r.replaced.unwrap().by.as_deref(), Some("perri"));

        // One level: replacing again forgets the oldest.
        s.record(by("x", Verdict::Comment, 3));
        let r = s.for_head("acme/web", 1, SHA_A).unwrap();
        let p = r.replaced.unwrap();
        assert_eq!(p.verdict, Verdict::Approved);
        assert_eq!(s.len(), 1, "the board still has one record per head");
        assert_eq!(s.newest("acme/web", 1).unwrap().verdict, Verdict::Comment);
    }

    #[test]
    fn what_a_verdict_replaced_survives_a_reload_and_is_cleaned_on_the_way_in() {
        let dir = tempfile::tempdir().unwrap();
        let s = VerdictStore::open(dir.path());
        s.record(rec("acme/web", 1, SHA_A, Verdict::ChangesRequested, 0));
        s.record(rec("acme/web", 1, SHA_A, Verdict::Approved, 1));
        let again = VerdictStore::open(dir.path());
        let p = again
            .for_head("acme/web", 1, SHA_A)
            .unwrap()
            .replaced
            .unwrap();
        assert_eq!(p.verdict, Verdict::ChangesRequested);

        // A file that carries a name with a right-to-left override is cleaned.
        std::fs::write(
            dir.path().join("perri-verdicts.json"),
            serde_json::json!({"records": [{
                "repo": "acme/web", "number": 1, "head_sha": SHA_A, "verdict": "approved",
                "at": "2026-11-19T10:00:00Z", "by": "a\u{202E}b",
                "replaced": {"verdict": "comment", "at": "2026-11-19T09:00:00Z", "by": "c\u{200B}d"}
            }]})
            .to_string(),
        )
        .unwrap();
        let r = VerdictStore::open(dir.path())
            .for_head("acme/web", 1, SHA_A)
            .unwrap();
        assert_eq!(r.by.as_deref(), Some("ab"));
        assert_eq!(r.replaced.unwrap().by.as_deref(), Some("cd"));
    }

    #[test]
    fn the_newest_verdict_for_a_head_wins_and_other_heads_are_kept() {
        let s = VerdictStore::in_memory();
        s.record(rec("acme/web", 1, SHA_A, Verdict::ChangesRequested, 0));
        s.record(rec("acme/web", 1, SHA_A, Verdict::Approved, 1));
        s.record(rec("acme/web", 1, SHA_B, Verdict::Comment, 2));
        assert_eq!(s.len(), 2);
        assert_eq!(
            s.for_head("ACME/web", 1, SHA_A).unwrap().verdict,
            Verdict::Approved
        );
        assert_eq!(s.newest("acme/web", 1).unwrap().head_sha, SHA_B);
        assert!(s.for_head("acme/web", 2, SHA_A).is_none());
    }

    #[test]
    fn at_most_500_records_are_kept_the_newest() {
        let s = VerdictStore::in_memory();
        for n in 0..(MAX_RECORDS as u64 + 20) {
            s.record(rec("acme/web", n + 1, SHA_A, Verdict::Approved, n as i64));
        }
        assert_eq!(s.len(), MAX_RECORDS);
        assert!(s.newest("acme/web", 1).is_none());
        assert!(s.newest("acme/web", MAX_RECORDS as u64 + 20).is_some());
    }

    #[test]
    fn records_survive_a_reload_in_a_private_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        VerdictStore::open(dir.path()).record(rec("acme/web", 7, SHA_A, Verdict::Approved, 0));
        let path = dir.path().join("perri-verdicts.json");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let again = VerdictStore::open(dir.path());
        assert_eq!(
            again.for_head("acme/web", 7, SHA_A).unwrap().verdict,
            Verdict::Approved
        );
    }

    #[test]
    fn a_corrupt_file_starts_empty_and_garbage_records_and_fields_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("perri-verdicts.json");
        std::fs::write(&path, "{ not json").unwrap();
        let s = VerdictStore::open(dir.path());
        assert!(s.is_empty());
        s.record(rec("acme/web", 1, SHA_A, Verdict::Approved, 0));
        assert_eq!(VerdictStore::open(dir.path()).len(), 1);

        std::fs::write(
            &path,
            serde_json::json!({
                "future": true,
                "records": [
                    {"repo": "acme/web", "number": 1, "head_sha": SHA_A, "verdict": "approved",
                     "at": "2026-11-19T10:00:00Z", "mystery": [1, 2]},
                    {"repo": "acme/web", "number": 2, "head_sha": "short", "verdict": "approved",
                     "at": "2026-11-19T10:00:00Z"},
                    {"repo": "acme/web", "number": 3, "head_sha": SHA_A, "verdict": "merge_it",
                     "at": "2026-11-19T10:00:00Z"},
                    "garbage", 7, null
                ]
            })
            .to_string(),
        )
        .unwrap();
        let s = VerdictStore::open(dir.path());
        assert_eq!(s.len(), 1);
        assert!(s.for_head("acme/web", 1, SHA_A).is_some());
    }

    #[test]
    fn a_file_with_too_many_records_is_cut_to_the_newest_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let records: Vec<_> = (0..(MAX_RECORDS as u64 + 5))
            .map(|n| rec("acme/web", n + 1, SHA_A, Verdict::Approved, n as i64))
            .collect();
        std::fs::write(
            dir.path().join("perri-verdicts.json"),
            serde_json::json!({ "records": records }).to_string(),
        )
        .unwrap();
        let s = VerdictStore::open(dir.path());
        assert_eq!(s.len(), MAX_RECORDS);
        assert!(s.newest("acme/web", 5).is_none());
        assert!(s.newest("acme/web", 6).is_some());
    }
}
