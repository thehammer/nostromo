//! The `current-pr/<tag>.json` / `current-pr.dirty` file contract — **one pin
//! per focus** (W7, D1).
//!
//! Both `PerriView::load_pr`/`clear_current_pr` (TUI), the daemon-hosted
//! `perri.load_pr`/`perri.clear_current_pr` MCP handlers, and the IPC
//! `PerriAction` path write through this module instead of duplicating the
//! file shape, so no host can drift on what "the PR under review" means on
//! disk. `PerriPrNativeSource` is the reader.
//!
//! ## Why sharded, and why still here
//!
//! Before W7 this was a single `<state_dir>/current-pr.json`: one "PR under
//! review" for the whole machine, silently owned by whichever focus picked one
//! up most recently. Every other notion of "where am I" in the daemon is
//! already keyed by focus tag, and the one that wasn't was overriding the ones
//! that were — see `.claude/prds/pr-review-concurrency-model.md`.
//!
//! The pins stay in Perri's state dir (`~/.claude/state/perri`) rather than
//! moving under `~/.nostromo/`: this file shape is a contract with three
//! writers, two of which (the TUI and the IPC action path) have no MCP access,
//! and relocating it would force them through MCP for no gain this wedge asks
//! for.
//!
//! ## One sentinel, not N
//!
//! There is still exactly one `current-pr.dirty`. The watcher behind it is a
//! 500 ms `path.exists()` poll ([`crate::data::dirty_file`]), not inotify, so
//! one sentinel per focus would be N polling tasks at 2 Hz. One sentinel plus
//! a directory rescan on wake keeps that at one (D2).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::json;

/// Directory name, under the Perri state dir, holding one `<tag>.json` per
/// focus that has a PR under review.
const PINS_DIR: &str = "current-pr";

/// The focus tag a host with exactly one Perri surface and no focus registry
/// writes under: the TUI's `PerriView`, and the IPC `PerriAction` path when
/// the client didn't name a focus.
///
/// Not a fallback for the MCP tools — those refuse an unattributable caller
/// (D4). It is the honest name for these two hosts' single surface: the
/// built-in `perri` focus exists in every deployment, its tag is stable, and
/// `FocusStore.remove` refuses to delete it. Writing there is attribution, not
/// a guess.
pub const BUILTIN_PERRI_TAG: &str = "perri";

/// The pre-W7 single global pointer. Read once at startup so its existence can
/// be logged, then deleted — never adopted. See [`discard_legacy_pointer`].
const LEGACY_POINTER: &str = "current-pr.json";

/// Why a pin-store call failed — **as a value, not a string prefix**.
///
/// The MCP handlers have to answer one question about every failure here: is
/// this the caller's fault or the machine's? They used to answer it with
/// `e.starts_with("invalid_tag")`, duplicated at two sites. That made a
/// literal prefix inside a human-readable message load-bearing API with no
/// type protecting it — rewording [`validate_tag`]'s message would silently
/// reclassify every rejected tag as `io_error`, and no test could see it
/// happen. The variant is the classification now; [`PinError::code`] is the
/// single place the mapping lives, and `Display` still renders exactly the
/// same text so no `detail` a caller reads has changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PinError {
    /// The focus tag is not a name that may be joined to a path.
    InvalidTag(String),
    /// The repo slug is not in `"owner/repo"` form.
    InvalidRepo(String),
    /// The filesystem refused, or the pin could not be rendered to write.
    Io(String),
}

impl PinError {
    /// The MCP error code this failure is reported under. A malformed tag or
    /// repo slug came in with the request and no retry will fix it; anything
    /// else is the machine's.
    pub fn code(&self) -> &'static str {
        match self {
            PinError::InvalidTag(_) | PinError::InvalidRepo(_) => "invalid_args",
            PinError::Io(_) => "io_error",
        }
    }
}

impl std::fmt::Display for PinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PinError::InvalidTag(detail) => write!(f, "invalid_tag: {detail}"),
            PinError::InvalidRepo(detail) => write!(f, "invalid_repo: {detail}"),
            PinError::Io(detail) => write!(f, "io_error: {detail}"),
        }
    }
}

impl std::error::Error for PinError {}

/// Validate a `"owner/repo"` slug: non-empty, exactly one `/`, both halves
/// non-empty, and restricted to `[A-Za-z0-9._-]` so it can never be
/// misinterpreted as a path/shell fragment once it ends up in a GitHub API
/// URL or a cache filename.
pub fn validate_repo_slug(repo: &str) -> Result<(), PinError> {
    let mut parts = repo.split('/');
    let (owner, name) = match (parts.next(), parts.next(), parts.next()) {
        (Some(o), Some(n), None) if !o.is_empty() && !n.is_empty() => (o, n),
        _ => {
            return Err(PinError::InvalidRepo(format!(
                "{repo:?} must be in \"owner/repo\" form"
            )));
        }
    };
    let is_valid_char = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');
    if !owner.chars().all(is_valid_char) || !name.chars().all(is_valid_char) {
        return Err(PinError::InvalidRepo(format!(
            "{repo:?} contains characters outside [A-Za-z0-9._-]"
        )));
    }
    Ok(())
}

/// Validate a focus tag before it is joined to a filesystem path.
///
/// Same `[A-Za-z0-9._-]` rule [`validate_repo_slug`] applies, and for the same
/// reason: a tag reaches this module from a self-asserted `pty_id` on the MCP
/// Hello frame or from an agent-supplied `view_id`, and an unvalidated one
/// joined to a filename is a directory escape. `..` is additionally rejected
/// outright — it passes the character rule but is not a name.
pub fn validate_tag(tag: &str) -> Result<(), PinError> {
    if tag.is_empty() {
        return Err(PinError::InvalidTag(
            "focus tag must not be empty".to_owned(),
        ));
    }
    if tag == "." || tag == ".." {
        return Err(PinError::InvalidTag(format!("{tag:?} is not a focus tag")));
    }
    let is_valid_char = |c: char| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');
    if !tag.chars().all(is_valid_char) {
        return Err(PinError::InvalidTag(format!(
            "{tag:?} contains characters outside [A-Za-z0-9._-]"
        )));
    }
    Ok(())
}

/// One focus's PR under review, as stored.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Pin {
    pub number: u64,
    pub repo: String,
    pub highlights: Option<String>,
}

/// `<state_dir>/current-pr/` — the directory holding one pin file per focus.
pub fn pins_dir(state_dir: &Path) -> PathBuf {
    state_dir.join(PINS_DIR)
}

/// `<state_dir>/current-pr/<tag>.json`, or an error if `tag` is not a name
/// that may be joined to a path.
pub fn pin_path(state_dir: &Path, tag: &str) -> Result<PathBuf, PinError> {
    validate_tag(tag)?;
    Ok(pins_dir(state_dir).join(format!("{tag}.json")))
}

/// Write `<state_dir>/current-pr/<tag>.json` and touch `current-pr.dirty`.
///
/// Matches the shape `PerriPrNativeSource` expects: `{ number, repo,
/// highlights }` — `highlights` serializes as `null` when absent.
pub fn write_pointer(
    state_dir: &Path,
    tag: &str,
    number: u64,
    repo: &str,
    highlights: Option<&str>,
) -> Result<(), PinError> {
    validate_repo_slug(repo)?;
    let json_path = pin_path(state_dir, tag)?;

    std::fs::create_dir_all(pins_dir(state_dir)).map_err(|e| PinError::Io(e.to_string()))?;

    let pointer = json!({
        "number": number,
        "repo": repo,
        "highlights": highlights,
    });
    let text = serde_json::to_string_pretty(&pointer)
        .map_err(|e| PinError::Io(format!("could not render the pin: {e}")))?;

    std::fs::write(&json_path, text.as_bytes()).map_err(|e| PinError::Io(e.to_string()))?;

    touch_current_pr_dirty(state_dir)
}

/// Remove `tag`'s pin (a no-op when it doesn't exist) and touch
/// `current-pr.dirty` so the watcher picks up the cleared state.
///
/// Only ever touches `tag`'s own file: this is the guarantee behind "no call
/// made in one focus changes what any other focus reports as under review."
pub fn clear_pointer(state_dir: &Path, tag: &str) -> Result<(), PinError> {
    let json_path = pin_path(state_dir, tag)?;
    if json_path.exists() {
        std::fs::remove_file(&json_path).map_err(|e| PinError::Io(e.to_string()))?;
    }
    touch_current_pr_dirty(state_dir)
}

/// Delete `tag`'s pin because the focus itself is gone (D8/D10). Returns
/// whether there was a pin to delete, so the caller can log an eviction that
/// actually evicted something.
///
/// Genuine deletion, not a tombstone: `nostromo.create_focus` derives its tag
/// deterministically from `(agent, title)`, so create/close/recreate produces
/// the *same* tag. Anything short of removing the file would resurrect the old
/// focus's pin under the new focus — the PRD's "a removed focus's pin never
/// resurfaces" criterion, failing.
pub fn remove_pin(state_dir: &Path, tag: &str) -> Result<bool, PinError> {
    let json_path = pin_path(state_dir, tag)?;
    if !json_path.exists() {
        return Ok(false);
    }
    std::fs::remove_file(&json_path).map_err(|e| PinError::Io(e.to_string()))?;
    touch_current_pr_dirty(state_dir)?;
    Ok(true)
}

/// Read `tag`'s pin, if it has one.
pub fn read_pin(state_dir: &Path, tag: &str) -> Option<Pin> {
    let path = pin_path(state_dir, tag).ok()?;
    parse_pin(&std::fs::read_to_string(path).ok()?)
}

/// Read every focus's pin: `tag -> Pin`.
///
/// A file that doesn't parse, or whose stem isn't a valid tag, is skipped
/// rather than failing the whole read — one hand-edited or half-written file
/// must not blank every focus's review.
pub fn read_pins(state_dir: &Path) -> HashMap<String, Pin> {
    let mut out = HashMap::new();
    let Ok(entries) = std::fs::read_dir(pins_dir(state_dir)) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(tag) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if validate_tag(tag).is_err() {
            tracing::warn!(tag, "skipping current-pr pin with an invalid tag");
            continue;
        }
        let raw = match std::fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(e) => {
                // Its two sibling skips above both warn; this one used to
                // drop out silently, so a focus's review could vanish with
                // nothing anywhere to say why.
                tracing::warn!(tag, "skipping unreadable current-pr pin: {e}");
                continue;
            }
        };
        match parse_pin(&raw) {
            Some(pin) => {
                out.insert(tag.to_owned(), pin);
            }
            None => tracing::warn!(tag, "skipping unparseable current-pr pin"),
        }
    }
    out
}

/// What one backstop sweep actually did.
///
/// `dropped` alone could not distinguish "there was nothing to collect" from
/// "there was, and every unlink failed" — the two outcomes are the opposite
/// of each other, and the second *is* the zombie-pin scenario this backstop
/// exists to prevent, in progress. Both are reported so a caller can log them
/// differently and a test can tell them apart.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PinSweep {
    /// Tags whose pin file was removed.
    pub dropped: Vec<String>,
    /// Why a pin that should have been collected wasn't, one entry each.
    /// Non-empty means a stale pin is still on disk and will be served.
    pub errors: Vec<String>,
}

impl PinSweep {
    /// True when the sweep found nothing to do — as opposed to finding
    /// something and failing at it.
    pub fn is_quiet(&self) -> bool {
        self.dropped.is_empty() && self.errors.is_empty()
    }
}

/// Drop every pin whose tag is not in `live`, reporting what happened.
///
/// The backstop half of D8: eviction on focus removal is the primary
/// mechanism, but a missed eviction (the daemon was down when the focus went
/// away, a push was never delivered) must not be able to produce a zombie pin
/// that resurfaces under a reused tag. Mirrors
/// `PaneRegistry::load_store`'s load-time re-validation of persisted bindings
/// against live state.
///
/// An **empty** `live` set is treated as "the registry isn't known yet" and
/// drops nothing — the same reconnect hazard guarded at the eviction hook
/// (D8a). A daemon that has genuinely lost every focus keeps its pins until a
/// real removal says otherwise; the alternative silently discards every pin on
/// a startup that races the Mac's first registry push.
pub fn retain_pins(state_dir: &Path, live: &HashSet<String>) -> PinSweep {
    let mut sweep = PinSweep::default();
    if live.is_empty() {
        return sweep;
    }
    for tag in read_pins(state_dir).into_keys() {
        if live.contains(&tag) {
            continue;
        }
        // Every failure here leaves a pin on disk that this sweep decided
        // should be gone, so none of them may be swallowed. The primary
        // eviction path at `server.rs` already matches
        // `Ok(true)/Ok(false)/Err(e)` on `remove_pin`; this is the same
        // standard applied to the backstop.
        match pin_path(state_dir, &tag) {
            Ok(path) => match std::fs::remove_file(&path) {
                Ok(()) => sweep.dropped.push(tag),
                Err(e) => sweep
                    .errors
                    .push(format!("could not unlink `{tag}`'s pin: {e}")),
            },
            Err(e) => sweep
                .errors
                .push(format!("could not resolve `{tag}`'s pin path: {e}")),
        }
    }
    if !sweep.dropped.is_empty() {
        // Its three siblings (`write_pointer`, `clear_pointer`, `remove_pin`)
        // all propagate this. Dropping it meant a sweep could delete the pins
        // and then have every Perri surface keep rendering the PRs it just
        // evicted until the next 30s poll happened to notice.
        if let Err(e) = touch_current_pr_dirty(state_dir) {
            sweep
                .errors
                .push(format!("pins were swept but no refresh was signalled: {e}"));
        }
    }
    sweep
}

/// Read, log and **delete** a pre-W7 bare `<state_dir>/current-pr.json`.
/// Returns whether one was found.
///
/// Deliberately not migrated. The legacy file records *what* was under review
/// and says nothing about *who* was reviewing it — that was the defect. Any
/// tag we picked for it would be a guess, and a guess that silently hands one
/// focus another's review target is worse than starting empty, which the
/// PRD's lifecycle criteria explicitly permit.
pub fn discard_legacy_pointer(state_dir: &Path) -> bool {
    let legacy = state_dir.join(LEGACY_POINTER);
    if !legacy.exists() {
        return false;
    }
    let described = std::fs::read_to_string(&legacy)
        .ok()
        .and_then(|raw| parse_pin(&raw))
        .map(|p| format!("{}#{}", p.repo, p.number))
        .unwrap_or_else(|| "unparseable".to_owned());
    match std::fs::remove_file(&legacy) {
        Ok(()) => tracing::info!(
            pin = %described,
            "discarded pre-W7 global current-pr.json; the PR under review is now per-focus \
             and cannot be attributed to one retroactively"
        ),
        Err(e) => tracing::warn!(pin = %described, "could not remove legacy current-pr.json: {e}"),
    }
    true
}

/// Parse the on-disk pin shape. Tolerant of the extra keys the pre-W7 reader
/// declared (`title`/`author`/`url`) and the writer never emitted — the file
/// is unversioned and has never had a strict contract.
fn parse_pin(raw: &str) -> Option<Pin> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let number = value.get("number")?.as_u64()?;
    let repo = value.get("repo")?.as_str()?.to_owned();
    if validate_repo_slug(&repo).is_err() {
        return None;
    }
    let highlights = value
        .get("highlights")
        .and_then(|v| v.as_str())
        .map(str::to_owned);
    Some(Pin {
        number,
        repo,
        highlights,
    })
}

/// Touch `current-pr.dirty` to wake `PerriPrNativeSource`'s watcher.
fn touch_current_pr_dirty(state_dir: &Path) -> Result<(), PinError> {
    std::fs::create_dir_all(state_dir).map_err(|e| PinError::Io(e.to_string()))?;
    let dirty_path = state_dir.join("current-pr.dirty");
    std::fs::write(&dirty_path, b"").map_err(|e| PinError::Io(e.to_string()))
}

/// Touch `queue.dirty` to wake `PerriQueueNativeSource`'s watcher.
pub fn touch_queue_dirty(state_dir: &Path) -> Result<(), PinError> {
    std::fs::create_dir_all(state_dir).map_err(|e| PinError::Io(e.to_string()))?;
    let dirty_path = state_dir.join("queue.dirty");
    std::fs::write(&dirty_path, b"").map_err(|e| PinError::Io(e.to_string()))
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    const TAG: &str = "perri";

    fn pin_file(dir: &Path, tag: &str) -> PathBuf {
        pin_path(dir, tag).expect("test tags are valid")
    }

    #[test]
    fn write_pointer_produces_a_pin_compatible_json() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), TAG, 42, "acme/widget", Some("check auth")).unwrap();

        let content = std::fs::read_to_string(pin_file(dir.path(), TAG)).unwrap();
        let pin: Pin = serde_json::from_str(&content).expect("must deserialize as Pin");
        assert_eq!(pin.number, 42);
        assert_eq!(pin.repo, "acme/widget");
        assert_eq!(pin.highlights.as_deref(), Some("check auth"));
    }

    #[test]
    fn write_pointer_without_highlights_writes_null() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), TAG, 7, "acme/anvil", None).unwrap();

        let content = std::fs::read_to_string(pin_file(dir.path(), TAG)).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        assert!(parsed["highlights"].is_null());
    }

    #[test]
    fn write_pointer_touches_dirty_sentinel() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), TAG, 1, "acme/widget", None).unwrap();
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn clear_pointer_on_missing_file_is_a_noop() {
        let dir = TempDir::new().unwrap();
        clear_pointer(dir.path(), TAG).expect("clearing an absent pointer must not error");
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn clear_pointer_removes_existing_file_and_touches_dirty() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), TAG, 5, "acme/foo", None).unwrap();
        assert!(pin_file(dir.path(), TAG).exists());

        clear_pointer(dir.path(), TAG).unwrap();
        assert!(!pin_file(dir.path(), TAG).exists());
        assert!(dir.path().join("current-pr.dirty").exists());
    }

    #[test]
    fn touch_queue_dirty_creates_sentinel() {
        let dir = TempDir::new().unwrap();
        touch_queue_dirty(dir.path()).unwrap();
        assert!(dir.path().join("queue.dirty").exists());
    }

    #[test]
    fn validate_repo_slug_accepts_well_formed_slugs() {
        assert!(validate_repo_slug("acme/widget").is_ok());
        assert!(validate_repo_slug("acme-corp/widget.rs_v2").is_ok());
    }

    #[test]
    fn validate_repo_slug_rejects_missing_slash() {
        assert!(validate_repo_slug("acmewidget").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_extra_slash() {
        assert!(validate_repo_slug("acme/widget/extra").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_empty_halves() {
        assert!(validate_repo_slug("/widget").is_err());
        assert!(validate_repo_slug("acme/").is_err());
        assert!(validate_repo_slug("/").is_err());
        assert!(validate_repo_slug("").is_err());
    }

    #[test]
    fn validate_repo_slug_rejects_unsafe_characters() {
        assert!(validate_repo_slug("org/repo;rm -rf /").is_err());
        assert!(validate_repo_slug("org/repo whitespace").is_err());
    }

    #[test]
    fn write_pointer_rejects_unsafe_repo_and_writes_no_file() {
        let dir = TempDir::new().unwrap();
        let result = write_pointer(dir.path(), TAG, 1, "org/repo;rm -rf /", None);
        assert!(result.is_err());
        assert!(!pin_file(dir.path(), TAG).exists());
    }

    // ── lifecycle: the pins survive a restart (W7) ───────────────────────────
    //
    // "A focus's PR under review survives a daemon restart: after restart, the
    // focus reports the same PR." A restart carries nothing in memory, so the
    // observable form of that criterion is: whatever a running daemon wrote,
    // a cold read of the store gives back — per focus, unmixed.

    #[test]
    fn every_focus_s_pin_is_read_back_from_a_cold_store_after_a_restart() {
        let dir = TempDir::new().unwrap();
        write_pointer(
            dir.path(),
            "perri",
            4526,
            "Carefeed/admin-portal",
            Some("check the recipient service"),
        )
        .unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();

        // The restart: no in-memory state, just the directory.
        let pins = read_pins(dir.path());

        assert_eq!(
            pins.len(),
            2,
            "both focuses' pins must come back, not just the last one written"
        );
        assert_eq!(
            pins.get("perri"),
            Some(&Pin {
                number: 4526,
                repo: "Carefeed/admin-portal".to_owned(),
                highlights: Some("check the recipient service".to_owned()),
            }),
        );
        assert_eq!(
            pins.get("operations"),
            Some(&Pin {
                number: 42,
                repo: "Carefeed/operations".to_owned(),
                highlights: None,
            }),
        );
    }

    #[test]
    fn each_focus_reloads_its_own_pin_after_a_restart_and_never_another_s() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();

        let perri = read_pin(dir.path(), "perri").expect("perri's pin survives the restart");
        let ops = read_pin(dir.path(), "operations").expect("operations' pin survives too");

        assert_eq!(
            (perri.number, perri.repo.as_str()),
            (4526, "Carefeed/admin-portal")
        );
        assert_eq!((ops.number, ops.repo.as_str()), (42, "Carefeed/operations"));
        assert!(
            read_pin(dir.path(), "fred").is_none(),
            "a focus that never picked one up still has none after a restart"
        );
    }

    #[test]
    fn a_pin_cleared_before_a_restart_does_not_come_back_after_one() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();
        clear_pointer(dir.path(), "perri").unwrap();

        let pins = read_pins(dir.path());
        assert!(!pins.contains_key("perri"), "a cleared pin stays cleared");
        assert_eq!(
            pins.get("operations").map(|p| p.number),
            Some(42),
            "and clearing one focus's pin left the other's alone across the restart"
        );
    }

    /// One hand-edited or half-written file must not blank every focus's
    /// review. `read_pins` is the cold read the whole store recovers from, so
    /// a single unparseable file that took the batch down with it would
    /// silently discard every other focus's in-progress review — and the pins
    /// it dropped are gone, not merely unread, once `retain_pins` reconciles
    /// against the result.
    #[test]
    fn a_corrupt_pin_file_does_not_blank_the_other_focuses_pins() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();

        // Half-written by a daemon killed mid-write, or hand-edited.
        std::fs::write(pin_file(dir.path(), "perri"), r#"{"number":4526,"repo""#).unwrap();

        let pins = read_pins(dir.path());
        assert_eq!(
            pins.get("operations"),
            Some(&Pin {
                number: 42,
                repo: "Carefeed/operations".to_owned(),
                highlights: None,
            }),
            "an untouched focus's pin must survive its neighbour's corruption intact"
        );
        assert!(
            !pins.contains_key("perri"),
            "and the corrupt file is simply absent, never a half-parsed pin"
        );
        assert_eq!(pins.len(), 1, "exactly the one bad file is skipped");
    }

    // ── retain_pins: the backstop against a zombie pin (W7 — D8) ─────────────
    //
    // Eviction on focus removal is the primary mechanism; this is what catches
    // the removal the daemon was not running to see. It is a sweep over the
    // whole pins directory, so its restraint matters as much as its reach.

    fn live(tags: &[&str]) -> HashSet<String> {
        tags.iter().map(|t| (*t).to_owned()).collect()
    }

    #[test]
    fn a_pin_whose_focus_no_longer_exists_is_dropped_and_named() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "cody-core-1234", 42, "Carefeed/operations", None).unwrap();

        let sweep = retain_pins(dir.path(), &live(&["perri"]));

        assert_eq!(
            sweep.dropped,
            vec!["cody-core-1234".to_owned()],
            "the caller is told which focuses it just forgot, so the removal is \
             auditable rather than a silent unlink"
        );
        assert!(
            sweep.errors.is_empty(),
            "a sweep that removed what it meant to has nothing to report: {:?}",
            sweep.errors
        );
        assert!(
            !pin_file(dir.path(), "cody-core-1234").exists(),
            "a pin for a focus that no longer exists must be gone from disk, or it \
             resurfaces the moment the tag is reused"
        );
    }

    #[test]
    fn a_pin_whose_focus_is_still_live_is_left_alone() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();

        let sweep = retain_pins(dir.path(), &live(&["perri", "operations"]));

        assert!(
            sweep.is_quiet(),
            "a sweep with every focus accounted for must drop nothing — and must \
             not have *failed* to drop something either: {sweep:?}"
        );
        assert_eq!(
            read_pin(dir.path(), "perri").map(|p| p.number),
            Some(4526),
            "a live focus keeps the PR it was reviewing across the sweep"
        );
        assert_eq!(
            read_pin(dir.path(), "operations").map(|p| p.number),
            Some(42)
        );
    }

    /// D8a, at the backstop. An empty live set is "nobody has told us which
    /// focuses exist yet", not "no focus exists" — the shape a startup that
    /// races the Mac's first registry push takes. Treating the two the same
    /// discards every pin on the machine, and the discard is irreversible.
    #[test]
    fn a_sweep_that_does_not_know_which_focuses_exist_drops_nothing() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "operations", 42, "Carefeed/operations", None).unwrap();

        let sweep = retain_pins(dir.path(), &HashSet::new());

        assert!(
            sweep.is_quiet(),
            "an unknown registry is not evidence that every focus was deleted: {sweep:?}"
        );
        assert_eq!(
            read_pins(dir.path()).len(),
            2,
            "every pin must survive a sweep run before the registry is known"
        );
    }

    #[test]
    fn a_sweep_that_dropped_a_pin_wakes_the_watcher() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(dir.path(), "cody-core-1234", 42, "Carefeed/operations", None).unwrap();
        // The writes above touched the sentinel; clear it so this observes the
        // sweep's own signal and not theirs.
        std::fs::remove_file(dir.path().join("current-pr.dirty")).unwrap();

        retain_pins(dir.path(), &live(&["perri"]));

        assert!(
            dir.path().join("current-pr.dirty").exists(),
            "a focus whose pin vanished must see that within a poll interval, not \
             at the next unrelated write"
        );
    }

    #[test]
    fn a_sweep_that_dropped_nothing_does_not_wake_the_watcher() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        std::fs::remove_file(dir.path().join("current-pr.dirty")).unwrap();

        retain_pins(dir.path(), &live(&["perri"]));

        assert!(
            !dir.path().join("current-pr.dirty").exists(),
            "a sweep that changed nothing must not wake every Perri surface on the \
             machine — this runs on a schedule, and a false wake is a rescan"
        );
    }

    /// The other half of `dropped`: a pin the sweep decided must go, and
    /// could not remove. This is the zombie-pin scenario the backstop exists
    /// to prevent, *in progress* — the stale pin is still on disk and will
    /// still be served to whatever focus reuses the tag — so it may not be
    /// swallowed. A sweep that silently skips it is indistinguishable from a
    /// sweep that found nothing to do, which is the opposite outcome.
    #[test]
    fn a_pin_that_cannot_be_unlinked_is_reported_rather_than_silently_skipped() {
        use std::os::unix::fs::PermissionsExt;

        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(
            dir.path(),
            "cody-core-1234",
            42,
            "Carefeed/operations",
            None,
        )
        .unwrap();

        // Make the unlink fail without making the pin unreadable: `read_pins`
        // must still enumerate `cody-core-1234` for the sweep to reach it at
        // all. A read-only pins dir does exactly that — r-x still lists and
        // reads the file, but unlinking from it is EACCES. (A pin planted as
        // a *directory* does not work: `read_pins` skips it at its
        // `read_to_string` arm, so the sweep never sees the tag.)
        let pins = pins_dir(dir.path());
        std::fs::set_permissions(&pins, std::fs::Permissions::from_mode(0o555)).unwrap();
        let sweep = retain_pins(dir.path(), &live(&["perri"]));
        // Restored before the assertions so a failure still leaves the
        // TempDir removable.
        std::fs::set_permissions(&pins, std::fs::Permissions::from_mode(0o755)).unwrap();

        assert!(
            sweep.dropped.is_empty(),
            "nothing was actually removed, so nothing may be claimed as dropped — \
             a caller logging `dropped` would otherwise report an eviction that \
             never happened: {:?}",
            sweep.dropped
        );
        assert!(
            !sweep.errors.is_empty(),
            "a pin the sweep could not unlink is still on disk and will resurface \
             under a reused tag; the sweep must say so instead of returning \
             quietly, which reads as `there was nothing to collect`"
        );
        assert!(
            sweep.errors.iter().any(|e| e.contains("cody-core-1234")),
            "the report must name the focus whose pin is stuck, or it cannot be \
             acted on: {:?}",
            sweep.errors
        );
        assert!(
            !sweep.is_quiet(),
            "`is_quiet` is how a caller decides whether to log at all — a sweep \
             that failed to evict a zombie pin is the loudest outcome there is, \
             not a quiet one: {sweep:?}"
        );
    }

    /// The failure the sweep can hit *after* the unlinks succeed. Its three
    /// siblings (`write_pointer`, `clear_pointer`, `remove_pin`) all propagate
    /// a failed sentinel touch; swallowing it here means the pins are gone and
    /// every Perri surface keeps rendering the PRs the sweep just evicted
    /// until some unrelated write happens to wake the watcher.
    #[test]
    fn a_sweep_that_dropped_a_pin_but_could_not_signal_the_refresh_reports_that_too() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        write_pointer(
            dir.path(),
            "cody-core-1234",
            42,
            "Carefeed/operations",
            None,
        )
        .unwrap();

        // The sentinel path is occupied by a directory, so the touch fails
        // (EISDIR) while the pin unlinks still succeed.
        std::fs::remove_file(dir.path().join("current-pr.dirty")).unwrap();
        std::fs::create_dir(dir.path().join("current-pr.dirty")).unwrap();

        let sweep = retain_pins(dir.path(), &live(&["perri"]));

        assert_eq!(
            sweep.dropped,
            vec!["cody-core-1234".to_owned()],
            "the unlink itself worked, so the eviction must still be reported: {sweep:?}"
        );
        assert!(
            !sweep.errors.is_empty(),
            "a sweep that evicted pins and then failed to wake the watcher left \
             every Perri surface showing PRs that are no longer under review — \
             partial success is not success"
        );
        assert!(
            sweep
                .errors
                .iter()
                .any(|e| e.contains("no refresh was signalled")),
            "the report must distinguish `could not delete the pin` from `deleted \
             the pin but nobody was told`; they need different remedies: {:?}",
            sweep.errors
        );
        assert!(
            !sweep.is_quiet(),
            "a sweep with a half-applied outcome must not read as quiet: {sweep:?}"
        );
    }

    // ── the pre-W7 global pointer is discarded, never adopted ────────────────

    #[test]
    fn a_pre_w7_bare_current_pr_json_is_deleted_and_yields_no_pins() {
        let dir = TempDir::new().unwrap();
        let legacy = dir.path().join("current-pr.json");
        std::fs::write(
            &legacy,
            r#"{"number":4526,"repo":"Carefeed/admin-portal","highlights":null}"#,
        )
        .unwrap();

        assert!(
            discard_legacy_pointer(dir.path()),
            "a legacy pointer that was there must be reported as found"
        );
        assert!(
            !legacy.exists(),
            "the legacy pointer must be deleted, not left to be re-read every startup"
        );
        assert!(
            read_pins(dir.path()).is_empty(),
            "the legacy PR names no focus, so it must not resurface under any tag"
        );
        assert!(
            read_pin(dir.path(), BUILTIN_PERRI_TAG).is_none(),
            "and least of all under the built-in Perri focus, which would be a guess"
        );
    }

    #[test]
    fn an_unparseable_legacy_pointer_is_discarded_just_the_same() {
        let dir = TempDir::new().unwrap();
        let legacy = dir.path().join("current-pr.json");
        std::fs::write(&legacy, "{ this is not json").unwrap();

        assert!(discard_legacy_pointer(dir.path()));
        assert!(!legacy.exists());
        assert!(read_pins(dir.path()).is_empty());
    }

    #[test]
    fn discarding_a_legacy_pointer_that_was_never_there_reports_nothing() {
        let dir = TempDir::new().unwrap();
        assert!(
            !discard_legacy_pointer(dir.path()),
            "a fresh install has no legacy pointer to announce"
        );
        assert!(read_pins(dir.path()).is_empty());
    }

    #[test]
    fn discarding_the_legacy_pointer_leaves_the_per_focus_pins_untouched() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        std::fs::write(
            dir.path().join("current-pr.json"),
            r#"{"number":42,"repo":"Carefeed/operations","highlights":null}"#,
        )
        .unwrap();

        discard_legacy_pointer(dir.path());

        let pins = read_pins(dir.path());
        assert_eq!(pins.len(), 1, "only the legacy file goes");
        assert_eq!(pins.get("perri").map(|p| p.number), Some(4526));
    }

    // ── a tag is a filename, and is validated as one ─────────────────────────

    /// Every path-bearing tag `validate_tag` must refuse. A tag arrives from a
    /// self-asserted `pty_id` or an agent-supplied `view_id`, so an
    /// unvalidated one joined to a filename is a directory escape.
    const PATH_BEARING_TAGS: &[&str] = &[
        "..",
        ".",
        "",
        "../evil",
        "a/b",
        "/absolute",
        "nested/../../escape",
        "trailing/",
        "back\\slash",
        "null\0byte",
    ];

    #[test]
    fn a_tag_that_is_not_a_plain_filename_is_refused_and_never_joined_to_a_path() {
        let dir = TempDir::new().unwrap();
        for tag in PATH_BEARING_TAGS {
            assert!(
                validate_tag(tag).is_err(),
                "validate_tag({tag:?}) must refuse a tag that is not a plain name"
            );
            assert!(
                pin_path(dir.path(), tag).is_err(),
                "pin_path({tag:?}) must refuse rather than return a path to join"
            );
        }
    }

    #[test]
    fn a_directory_escape_tag_writes_no_file_anywhere_and_clears_nothing() {
        let root = TempDir::new().unwrap();
        // The state dir is a *child* of `root`, so an escaping tag has
        // somewhere real to escape to and this test can see it land there.
        let state_dir = root.path().join("perri-state");
        write_pointer(&state_dir, "perri", 1, "acme/widget", None).unwrap();
        let before = tree_snapshot(root.path());

        for tag in ["../../escaped", "../escaped", "..", "a/b"] {
            let err = write_pointer(&state_dir, tag, 4526, "Carefeed/admin-portal", None)
                .expect_err("an escaping tag must be refused");
            assert!(
                matches!(err, PinError::InvalidTag(_)),
                "the refusal must name the tag as the problem, got {err:?}"
            );
            assert_eq!(
                err.code(),
                "invalid_args",
                "…and an escaping tag is the caller's error, not the disk's: {err}"
            );
            assert!(
                clear_pointer(&state_dir, tag).is_err(),
                "clearing under an escaping tag must be refused too, not silently unlink"
            );
            assert!(
                remove_pin(&state_dir, tag).is_err(),
                "and so must an eviction under one"
            );
        }

        assert_eq!(
            tree_snapshot(root.path()),
            before,
            "a refused tag must leave the filesystem byte-for-byte as it was — \
             no file created, moved or removed, inside the pins dir or out of it"
        );
    }

    #[test]
    fn a_pin_file_whose_name_is_not_a_valid_tag_is_skipped_rather_than_adopted() {
        let dir = TempDir::new().unwrap();
        write_pointer(dir.path(), "perri", 4526, "Carefeed/admin-portal", None).unwrap();
        // Stem `.` — a name `validate_tag` refuses, planted directly in the
        // pins dir the way a hand edit or an older binary could.
        std::fs::write(
            pins_dir(dir.path()).join("..json"),
            r#"{"number":42,"repo":"Carefeed/operations","highlights":null}"#,
        )
        .unwrap();

        let pins = read_pins(dir.path());
        assert_eq!(
            pins.len(),
            1,
            "only the well-named pin is served: {:?}",
            pins.keys().collect::<Vec<_>>()
        );
        assert_eq!(pins.get("perri").map(|p| p.number), Some(4526));
    }

    /// Every path under `root`, relative and sorted — a cheap "did anything at
    /// all change on disk?" fingerprint.
    fn tree_snapshot(root: &Path) -> Vec<PathBuf> {
        fn walk(dir: &Path, root: &Path, out: &mut Vec<PathBuf>) {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                out.push(path.strip_prefix(root).unwrap_or(&path).to_path_buf());
                if path.is_dir() {
                    walk(&path, root, out);
                }
            }
        }
        let mut out = Vec::new();
        walk(root, root, &mut out);
        out.sort();
        out
    }
}
