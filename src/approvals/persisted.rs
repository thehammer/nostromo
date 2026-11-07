//! Persisted rules (AP6): the "Always allow…" rules, kept in a Nostromo-owned file,
//! `<approvals dir>/rules.json` (user decision U2).
//!
//! Nothing here ever touches a Claude settings file, and the file is never a source of
//! authority:
//!
//! - A rule is created only by the broker, from one of a held request's own AP4
//!   [`rules::Candidate`]s, after a human answer ([`super::broker`]).
//! - On load every stored rule is re-derived with [`rules::revalidate`] from its
//!   `source_command`; a rule AP4 would not offer today (or a hand-edited one) stays listed
//!   as **inactive** and never matches.
//! - The file is bound to a SHA-256 kept in memory and in a `rules.json.sha256` sidecar. A
//!   mismatch, a parse error, a bad mode, a symlink or an oversized file at load, or a change
//!   the daemon did not make while it runs, **quarantines** the file: no persisted rule
//!   matches and no new one is written until the human chooses Keep or Discard.
//!
//! Only the daemon writes the file: a temp file in the same directory (`O_EXCL`,
//! `O_NOFOLLOW`, mode 0600), `fsync`, `rename`, `fsync` of the directory.

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::rules::{self, CandidateKind, Inactive, PersistedRuleRecord, Spec};
use super::wire::{PersistedRuleWire, RuleScopeChoice, RulesQuarantineWire};

/// The most rules the file may hold.
pub const MAX_PERSISTED_RULES: usize = 200;
/// The largest rules file the daemon reads.
pub const MAX_FILE_BYTES: u64 = 1024 * 1024;
/// How often a use count is written to disk at most.
pub const USES_FLUSH_INTERVAL: Duration = Duration::from_secs(10);
/// The file's name inside the approvals directory.
pub const RULES_FILE: &str = "rules.json";
/// The hash sidecar's name.
pub const SIDECAR_FILE: &str = "rules.json.sha256";
/// How long one rule's file-system re-check may take at load.
const REVALIDATE_TIMEOUT: Duration = Duration::from_secs(2);

const FILE_VERSION: u32 = 1;

/// Where a persisted rule applies.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Scope {
    /// Sessions whose working directory is `root` or below it.
    Repo {
        root: PathBuf,
    },
    AllRepos,
}

impl Scope {
    pub fn choice(&self) -> RuleScopeChoice {
        match self {
            Self::Repo { .. } => RuleScopeChoice::Repo,
            Self::AllRepos => RuleScopeChoice::AllRepos,
        }
    }

    /// Does this scope cover a session started in `cwd`? Compared after resolving symlinks
    /// (leniently, like the matcher's own path checks).
    fn covers(&self, cwd: Option<&Path>) -> bool {
        match self {
            Self::AllRepos => true,
            Self::Repo { root } => {
                let Some(cwd) = cwd else { return false };
                let cwd = rules::canonical_lenient(cwd).unwrap_or_else(|| cwd.to_path_buf());
                let root = rules::canonical_lenient(root).unwrap_or_else(|| root.clone());
                cwd.starts_with(&root)
            }
        }
    }
}

/// One persisted rule, as `rules.json` stores it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PersistedRule {
    pub id: String,
    pub rule_text: String,
    pub summary: String,
    pub kind: CandidateKind,
    pub spec: Spec,
    /// The plain command of the request the rule was created from ([`rules::revalidate`]'s input).
    pub source_command: String,
    pub scope: Scope,
    pub created_at_ms: u64,
    pub created_from_request_id: String,
    pub created_by_window: String,
    #[serde(default)]
    pub uses: u64,
}

impl PersistedRule {
    pub fn record(&self) -> PersistedRuleRecord {
        PersistedRuleRecord {
            rule_text: self.rule_text.clone(),
            kind: self.kind,
            spec: self.spec.clone(),
            source_command: self.source_command.clone(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct FileBody {
    v: u32,
    rules: Vec<PersistedRule>,
}

/// A rule and whether it may match.
#[derive(Debug, Clone)]
pub struct StoredRule {
    pub rule: PersistedRule,
    pub inactive: Option<Inactive>,
}

/// A file that is off until the human reviews it.
#[derive(Debug, Clone)]
pub struct Quarantine {
    pub reason: String,
    /// Hash of the file's bytes as found ("" when it could not be read).
    pub file_sha256: String,
    /// What the file parsed to (empty when it did not parse) and whether each rule would stay active.
    pub rules: Vec<(PersistedRule, Option<Inactive>)>,
}

impl Quarantine {
    /// `(reason, file hash)`, as reports and log entries carry it.
    fn summary(&self) -> (String, String) {
        (self.reason.clone(), self.file_sha256.clone())
    }
}

/// What [`RulesStore::open`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadReport {
    pub active: usize,
    pub inactive: usize,
    pub quarantined: Option<(String, String)>,
}

/// Why a rule could not be added.
#[derive(Debug)]
pub enum AddError {
    Quarantined,
    Limit,
    Write(io::Error),
}

/// Why a change to the rules file was refused.
#[derive(Debug)]
pub enum ChangeError {
    Quarantined,
    NotQuarantined,
    /// Keep: the file is not the one the human reviewed.
    StaleHash,
    /// Keep: the file cannot be read as rules; only Discard is possible.
    Unreadable(&'static str),
    Write(io::Error),
}

/// What [`RulesStore::check_external`] decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum External {
    Unchanged,
    /// The file changed behind the daemon's back: quarantined (reason, hash).
    Quarantined(String, String),
    /// The file was deleted: the rules are gone.
    Deleted,
}

struct Inner {
    rules: Vec<StoredRule>,
    quarantine: Option<Quarantine>,
    /// Hash of the file as the daemon last wrote or accepted it.
    written_sha: Option<String>,
    uses_dirty: bool,
    last_flush: Instant,
}

/// The rules file and the rules it holds.
pub struct RulesStore {
    dir: PathBuf,
    inner: Mutex<Inner>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn sha_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// The file's bytes, or why they cannot be trusted. `strict`: also refuse a bad mode.
fn read_file(path: &Path, strict: bool) -> Result<Option<Vec<u8>>, &'static str> {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("unreadable"),
    };
    if meta.file_type().is_symlink() {
        return Err("symlink");
    }
    if !meta.is_file() {
        return Err("not_a_regular_file");
    }
    if strict && meta.mode() & 0o077 != 0 {
        return Err("bad_mode");
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err("too_large");
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "unreadable")?;
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "unreadable")?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err("too_large");
    }
    Ok(Some(bytes))
}

fn parse(bytes: &[u8]) -> Result<Vec<PersistedRule>, &'static str> {
    let body: FileBody = serde_json::from_slice(bytes).map_err(|_| "parse_error")?;
    if body.v != FILE_VERSION {
        return Err("unsupported_version");
    }
    if body.rules.len() > MAX_PERSISTED_RULES {
        return Err("too_many_rules");
    }
    let mut ids = std::collections::HashSet::new();
    if !body.rules.iter().all(|r| ids.insert(r.id.clone())) {
        return Err("duplicate_ids");
    }
    Ok(body.rules)
}

fn judge(rules: Vec<PersistedRule>, home: &Path) -> Vec<StoredRule> {
    rules
        .into_iter()
        .map(|rule| {
            let inactive = rules::revalidate_within(REVALIDATE_TIMEOUT, &rule.record(), home).err();
            StoredRule { rule, inactive }
        })
        .collect()
}

impl RulesStore {
    /// Open the store in `dir` (the approvals directory) and load the file.
    pub fn open(dir: &Path, home: &Path) -> (Self, LoadReport) {
        let store = Self {
            dir: dir.to_path_buf(),
            inner: Mutex::new(Inner {
                rules: Vec::new(),
                quarantine: None,
                written_sha: None,
                uses_dirty: false,
                last_flush: Instant::now(),
            }),
        };
        let report = store.load(home);
        (store, report)
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join(RULES_FILE)
    }

    fn sidecar(&self) -> PathBuf {
        self.dir.join(SIDECAR_FILE)
    }

    /// Read the file, check it against its hash and revalidate every rule.
    fn load(&self, home: &Path) -> LoadReport {
        let mut inner = lock(&self.inner);
        inner.rules.clear();
        inner.quarantine = None;
        inner.written_sha = None;
        let bytes = match read_file(&self.path(), true) {
            Ok(None) => return Self::report(&inner),
            Ok(Some(b)) => b,
            Err(reason) => {
                // Unreadable or untrustworthy: show what can be shown, trust nothing.
                let parsed = read_file(&self.path(), false).ok().flatten();
                self.quarantine(&mut inner, reason, parsed.as_deref(), home);
                return Self::report(&inner);
            }
        };
        let sha = sha_hex(&bytes);
        let recorded = read_file(&self.sidecar(), true)
            .ok()
            .flatten()
            .map(|b| String::from_utf8_lossy(&b).trim().to_owned());
        if recorded.as_deref() != Some(sha.as_str()) {
            self.quarantine(&mut inner, "hash_mismatch", Some(&bytes), home);
            return Self::report(&inner);
        }
        match parse(&bytes) {
            Ok(rules) => {
                inner.rules = judge(rules, home);
                inner.written_sha = Some(sha);
            }
            Err(reason) => self.quarantine(&mut inner, reason, Some(&bytes), home),
        }
        Self::report(&inner)
    }

    fn report(inner: &Inner) -> LoadReport {
        LoadReport {
            active: inner.rules.iter().filter(|r| r.inactive.is_none()).count(),
            inactive: inner.rules.iter().filter(|r| r.inactive.is_some()).count(),
            quarantined: inner.quarantine.as_ref().map(Quarantine::summary),
        }
    }

    /// Turn the rules off until the human reviews `bytes` (what the file holds now).
    fn quarantine(&self, inner: &mut Inner, reason: &str, bytes: Option<&[u8]>, home: &Path) {
        let file_sha256 = bytes.map(sha_hex).unwrap_or_default();
        let rules = bytes
            .and_then(|b| parse(b).ok())
            .map(|rules| {
                judge(rules, home)
                    .into_iter()
                    .map(|s| (s.rule, s.inactive))
                    .collect()
            })
            .unwrap_or_default();
        inner.rules.clear();
        inner.written_sha = None;
        inner.quarantine = Some(Quarantine {
            reason: reason.to_owned(),
            file_sha256,
            rules,
        });
    }

    /// Has the file changed in a way the daemon did not make? Called when the directory
    /// watcher fires. A change quarantines everything.
    pub fn check_external(&self, home: &Path) -> External {
        let mut inner = lock(&self.inner);
        if inner.quarantine.is_some() {
            return External::Unchanged;
        }
        match read_file(&self.path(), false) {
            Ok(None) => {
                if inner.written_sha.is_some() || !inner.rules.is_empty() {
                    inner.rules.clear();
                    inner.written_sha = None;
                    inner.uses_dirty = false;
                    return External::Deleted;
                }
                External::Unchanged
            }
            Ok(Some(bytes)) => {
                if inner.written_sha.as_deref() == Some(sha_hex(&bytes).as_str()) {
                    return External::Unchanged;
                }
                self.quarantine_externally(&mut inner, "external_change", Some(&bytes), home)
            }
            Err(reason) => self.quarantine_externally(&mut inner, reason, None, home),
        }
    }

    /// [`Self::quarantine`], reported as what [`Self::check_external`] decided.
    fn quarantine_externally(
        &self,
        inner: &mut Inner,
        reason: &str,
        bytes: Option<&[u8]>,
        home: &Path,
    ) -> External {
        self.quarantine(inner, reason, bytes, home);
        let (reason, sha) = inner.quarantine.as_ref().expect("just set").summary();
        External::Quarantined(reason, sha)
    }

    pub fn quarantined(&self) -> Option<(String, String)> {
        lock(&self.inner)
            .quarantine
            .as_ref()
            .map(Quarantine::summary)
    }

    pub fn len(&self) -> usize {
        lock(&self.inner).rules.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Is another rule allowed (not quarantined, below the cap)? Checked before the human's
    /// allow is written, so a refusal leaves the request held.
    pub fn can_add(&self) -> Result<(), AddError> {
        Self::check_room(&lock(&self.inner))
    }

    fn check_room(inner: &Inner) -> Result<(), AddError> {
        if inner.quarantine.is_some() {
            return Err(AddError::Quarantined);
        }
        if inner.rules.len() >= MAX_PERSISTED_RULES {
            return Err(AddError::Limit);
        }
        Ok(())
    }

    /// Add `rule` (built from a request's own candidate) and write the file. On a failed
    /// write nothing changes in memory.
    pub fn add(&self, rule: PersistedRule) -> Result<(), AddError> {
        let mut inner = lock(&self.inner);
        Self::check_room(&inner)?;
        inner.rules.push(StoredRule {
            rule,
            inactive: None,
        });
        if let Err(e) = self.write_locked(&mut inner) {
            inner.rules.pop();
            return Err(AddError::Write(e));
        }
        Ok(())
    }

    /// Remove rule `id`: `Ok(None)` when there is none.
    pub fn remove(&self, id: &str) -> Result<Option<PersistedRule>, ChangeError> {
        let mut inner = lock(&self.inner);
        if inner.quarantine.is_some() {
            return Err(ChangeError::Quarantined);
        }
        let Some(at) = inner.rules.iter().position(|r| r.rule.id == id) else {
            return Ok(None);
        };
        let removed = inner.rules.remove(at);
        if let Err(e) = self.write_locked(&mut inner) {
            inner.rules.insert(at, removed);
            return Err(ChangeError::Write(e));
        }
        Ok(Some(removed.rule))
    }

    /// The first active rule whose scope covers `cwd` and whose spec covers `req`, checked on
    /// one bounded helper.
    pub fn first_match(
        &self,
        timeout: Duration,
        req: &super::request::PermissionRequest,
        reason_kind: super::request::ReasonKind,
        home: &Path,
        cwd: Option<&Path>,
    ) -> Option<PersistedRule> {
        let rules: Vec<PersistedRule> = {
            let inner = lock(&self.inner);
            if inner.quarantine.is_some() {
                return None;
            }
            inner
                .rules
                .iter()
                .filter(|r| r.inactive.is_none())
                .map(|r| r.rule.clone())
                .collect()
        };
        if rules.is_empty() {
            return None;
        }
        let (req, home, cwd) = (req.clone(), home.to_path_buf(), cwd.map(Path::to_path_buf));
        rules::bounded(timeout, move || {
            rules.into_iter().find(|r| {
                r.scope.covers(cwd.as_deref())
                    && rules::spec_covers(&r.spec, &req, reason_kind, &home, cwd.as_deref())
            })
        })
        .flatten()
    }

    /// Count one use; written to disk at most every [`USES_FLUSH_INTERVAL`].
    pub fn record_use(&self, id: &str) {
        let mut inner = lock(&self.inner);
        let Some(rule) = inner.rules.iter_mut().find(|r| r.rule.id == id) else {
            return;
        };
        rule.rule.uses += 1;
        inner.uses_dirty = true;
        if inner.last_flush.elapsed() >= USES_FLUSH_INTERVAL {
            let _ = self.flush_locked(&mut inner);
        }
    }

    /// Write pending use counts (the daemon calls this at shutdown).
    pub fn flush(&self) -> io::Result<()> {
        let mut inner = lock(&self.inner);
        self.flush_locked(&mut inner)
    }

    fn flush_locked(&self, inner: &mut Inner) -> io::Result<()> {
        if !inner.uses_dirty || inner.quarantine.is_some() {
            return Ok(());
        }
        self.write_locked(inner)
    }

    /// Keep the quarantined file: only if it is still exactly the one the human reviewed
    /// (`expected_sha`). Every rule is revalidated; the file is rewritten and re-bound.
    pub fn keep(&self, expected_sha: &str, home: &Path) -> Result<LoadReport, ChangeError> {
        let mut inner = lock(&self.inner);
        let Some(q) = inner.quarantine.as_ref() else {
            return Err(ChangeError::NotQuarantined);
        };
        let reviewed = q.file_sha256.clone();
        let bytes = match read_file(&self.path(), false) {
            Ok(Some(b)) => b,
            Ok(None) => return Err(ChangeError::Unreadable("missing")),
            Err(reason) => return Err(ChangeError::Unreadable(reason)),
        };
        let sha = sha_hex(&bytes);
        if expected_sha.is_empty() || sha != expected_sha || sha != reviewed {
            return Err(ChangeError::StaleHash);
        }
        let rules = parse(&bytes).map_err(ChangeError::Unreadable)?;
        inner.rules = judge(rules, home);
        inner.quarantine = None;
        if let Err(e) = self.write_locked(&mut inner) {
            // Not re-bound: stay off.
            inner.rules.clear();
            inner.quarantine = Some(Quarantine {
                reason: "keep_failed".into(),
                file_sha256: sha,
                rules: Vec::new(),
            });
            return Err(ChangeError::Write(e));
        }
        Ok(Self::report(&inner))
    }

    /// Discard the quarantined file: replace it with an empty rule set.
    pub fn discard(&self) -> Result<(), ChangeError> {
        let mut inner = lock(&self.inner);
        if inner.quarantine.is_none() {
            return Err(ChangeError::NotQuarantined);
        }
        inner.rules.clear();
        match self.write_locked(&mut inner) {
            Ok(()) => {
                inner.quarantine = None;
                Ok(())
            }
            Err(e) => Err(ChangeError::Write(e)),
        }
    }

    /// The rules and quarantine, as the wire shows them.
    pub fn wire(&self) -> (Vec<PersistedRuleWire>, Option<RulesQuarantineWire>) {
        let inner = lock(&self.inner);
        let rules = inner
            .rules
            .iter()
            .map(|s| wire_rule(&s.rule, s.inactive))
            .collect();
        let quarantine = inner.quarantine.as_ref().map(|q| RulesQuarantineWire {
            reason: q.reason.clone(),
            file_sha256: q.file_sha256.clone(),
            rules_in_file: q.rules.iter().map(|(r, i)| wire_rule(r, *i)).collect(),
        });
        (rules, quarantine)
    }

    /// A copy of rule `id` (active or not).
    pub fn get(&self, id: &str) -> Option<PersistedRule> {
        lock(&self.inner)
            .rules
            .iter()
            .find(|r| r.rule.id == id)
            .map(|r| r.rule.clone())
    }

    /// Serialize the current rules, write the file and its sidecar, and remember the hash.
    fn write_locked(&self, inner: &mut Inner) -> io::Result<()> {
        let body = FileBody {
            v: FILE_VERSION,
            rules: inner.rules.iter().map(|r| r.rule.clone()).collect(),
        };
        let bytes = serde_json::to_vec_pretty(&body).map_err(io::Error::other)?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(io::Error::other("the rules file would be too large"));
        }
        let sha = sha_hex(&bytes);
        write_atomic(&self.dir, RULES_FILE, &bytes)?;
        // The file is now what the daemon wrote, whatever happens to the sidecar.
        inner.written_sha = Some(sha.clone());
        inner.uses_dirty = false;
        inner.last_flush = Instant::now();
        write_atomic(&self.dir, SIDECAR_FILE, format!("{sha}\n").as_bytes())
    }
}

fn wire_rule(rule: &PersistedRule, inactive: Option<Inactive>) -> PersistedRuleWire {
    PersistedRuleWire {
        id: rule.id.clone(),
        rule_text: rule.rule_text.clone(),
        summary: rule.summary.clone(),
        kind: rule.kind,
        scope: rule.scope.choice(),
        root: match &rule.scope {
            Scope::Repo { root } => Some(root.to_string_lossy().into_owned()),
            Scope::AllRepos => None,
        },
        created_at_ms: rule.created_at_ms,
        created_from_request_id: rule.created_from_request_id.clone(),
        uses: rule.uses,
        active: inactive.is_none(),
        inactive_reason: inactive.map(|i| i.as_str().to_owned()),
    }
}

/// Write `bytes` to `dir/name`: a fresh temp file (`O_EXCL`, `O_NOFOLLOW`, 0600), `fsync`,
/// `rename`, and an `fsync` of the directory.
fn write_atomic(dir: &Path, name: &str, bytes: &[u8]) -> io::Result<()> {
    let tmp = dir.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, dir.join(name))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
        return result;
    }
    fs::File::open(dir)?.sync_all()
}

#[cfg(test)]
mod tests {
    //! The store's file handling, from outside its API: what ends up on disk, what is trusted
    //! at load, and what a change the daemon did not make does. (Which requests a rule allows is
    //! in `tests/approvals_persisted_rules.rs`.)

    use std::os::unix::fs::PermissionsExt;

    use serde_json::json;

    use super::*;
    use crate::approvals::request::{AskRule, PermissionRequest, SettingsSource};

    struct NoSettings;
    impl SettingsSource for NoSettings {
        fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
            Vec::new()
        }
    }

    struct World {
        _tmp: tempfile::TempDir,
        dir: PathBuf,
        home: PathBuf,
    }

    fn world() -> World {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("approvals");
        let home = tmp.path().join("home");
        fs::create_dir_all(&dir).unwrap();
        fs::create_dir_all(home.join("Library/Caches")).unwrap();
        World {
            _tmp: tmp,
            dir,
            home,
        }
    }

    /// A rule as the broker builds it: from AP4's own exact candidate for `command`.
    fn rule(w: &World, id: &str) -> PersistedRule {
        let command = "rm -rf ~/Library/Caches/a";
        let req = PermissionRequest::from_cli(&json!({
            "subtype": "can_use_tool",
            "tool_name": "Bash",
            "input": { "command": command },
            "tool_use_id": "toolu_1",
        }))
        .unwrap();
        let reason = req.reason(None, &NoSettings);
        let c = rules::candidates(&req, &reason, &w.home, None)
            .into_iter()
            .find(|c| c.kind == CandidateKind::Exact)
            .expect("AP4 offers the exact rule");
        PersistedRule {
            id: id.into(),
            rule_text: c.rule_text,
            summary: c.summary,
            kind: c.kind,
            spec: c.spec,
            source_command: command.into(),
            scope: Scope::AllRepos,
            created_at_ms: 1,
            created_from_request_id: "req".into(),
            created_by_window: "w".into(),
            uses: 0,
        }
    }

    fn open(w: &World) -> (RulesStore, LoadReport) {
        RulesStore::open(&w.dir, &w.home)
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    fn put(path: &Path, bytes: &[u8]) {
        fs::write(path, bytes).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn store_with(w: &World, n: usize) {
        let (store, _) = open(w);
        for i in 0..n {
            store.add(rule(w, &format!("r{i}"))).unwrap();
        }
    }

    #[test]
    fn a_write_leaves_a_private_file_its_hash_beside_it_and_no_temporary_files() {
        let w = world();
        let (store, report) = open(&w);
        assert_eq!(
            (report.active, report.inactive, report.quarantined),
            (0, 0, None)
        );
        assert!(
            !w.dir.join(RULES_FILE).exists(),
            "nothing is written until there is a rule"
        );

        store.add(rule(&w, "r1")).unwrap();

        assert_eq!(names(&w.dir), [RULES_FILE, SIDECAR_FILE]);
        let mode =
            |name: &str| fs::metadata(w.dir.join(name)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(RULES_FILE), 0o600);
        assert_eq!(mode(SIDECAR_FILE), 0o600);
        let bytes = fs::read(w.dir.join(RULES_FILE)).unwrap();
        assert_eq!(
            fs::read_to_string(w.dir.join(SIDECAR_FILE)).unwrap().trim(),
            sha_hex(&bytes)
        );
        // And what was written loads again, clean.
        let (again, report) = open(&w);
        assert_eq!((report.active, report.quarantined), (1, None));
        assert_eq!(
            again.get("r1").unwrap().rule_text,
            "Bash(rm -rf ~/Library/Caches/a)"
        );
        assert_eq!(again.check_external(&w.home), External::Unchanged);
    }

    #[test]
    fn a_failed_write_leaves_nothing_behind_and_the_rule_is_not_added() {
        let w = world();
        let (store, _) = open(&w);
        fs::create_dir(w.dir.join(RULES_FILE)).unwrap(); // something that is not a file is in the way

        let result = store.add(rule(&w, "r1"));

        assert!(matches!(result, Err(AddError::Write(_))), "{result:?}");
        assert_eq!(store.len(), 0);
        assert!(
            names(&w.dir).iter().all(|n| !n.ends_with(".tmp")),
            "no temporary file is left: {:?}",
            names(&w.dir)
        );
    }

    #[test]
    fn a_rules_file_that_cannot_be_trusted_at_load_is_quarantined_and_holds_no_active_rule() {
        type Break = Box<dyn Fn(&World)>;
        let cases: Vec<(&str, Break)> = vec![
            (
                "symlink",
                Box::new(|w: &World| {
                    let real = w.dir.join("real.json");
                    fs::rename(w.dir.join(RULES_FILE), &real).unwrap();
                    std::os::unix::fs::symlink(&real, w.dir.join(RULES_FILE)).unwrap();
                }),
            ),
            (
                "mode 0644",
                Box::new(|w: &World| {
                    fs::set_permissions(w.dir.join(RULES_FILE), fs::Permissions::from_mode(0o644))
                        .unwrap()
                }),
            ),
            (
                "mode 0660",
                Box::new(|w: &World| {
                    fs::set_permissions(w.dir.join(RULES_FILE), fs::Permissions::from_mode(0o660))
                        .unwrap()
                }),
            ),
            (
                "over 1 MiB",
                Box::new(|w: &World| {
                    let mut bytes = fs::read(w.dir.join(RULES_FILE)).unwrap();
                    bytes.extend(std::iter::repeat_n(b' ', 1024 * 1024 + 1));
                    put(&w.dir.join(RULES_FILE), &bytes);
                    put(&w.dir.join(SIDECAR_FILE), sha_hex(&bytes).as_bytes());
                }),
            ),
            (
                "201 rules",
                Box::new(|w: &World| {
                    let rules: Vec<PersistedRule> = (0..=MAX_PERSISTED_RULES)
                        .map(|i| rule(w, &format!("r{i}")))
                        .collect();
                    let bytes = serde_json::to_vec(&json!({ "v": 1, "rules": rules })).unwrap();
                    put(&w.dir.join(RULES_FILE), &bytes);
                    put(&w.dir.join(SIDECAR_FILE), sha_hex(&bytes).as_bytes());
                }),
            ),
            (
                "corrupt JSON",
                Box::new(|w: &World| {
                    put(&w.dir.join(RULES_FILE), b"{nope");
                    put(&w.dir.join(SIDECAR_FILE), sha_hex(b"{nope").as_bytes());
                }),
            ),
            (
                "hash of something else",
                Box::new(|w: &World| put(&w.dir.join(SIDECAR_FILE), sha_hex(b"x").as_bytes())),
            ),
            (
                "no hash file",
                Box::new(|w: &World| fs::remove_file(w.dir.join(SIDECAR_FILE)).unwrap()),
            ),
        ];
        for (what, break_it) in cases {
            let w = world();
            store_with(&w, 1);
            break_it(&w);

            let (store, report) = open(&w);

            assert!(report.quarantined.is_some(), "{what}: {report:?}");
            assert_eq!(report.active, 0, "{what}");
            assert!(store.quarantined().is_some(), "{what}");
            assert!(
                store.wire().0.is_empty(),
                "{what}: no rule is listed as in force"
            );
            assert!(
                matches!(store.can_add(), Err(AddError::Quarantined)),
                "{what}: no new rule while quarantined"
            );
            assert!(
                matches!(store.add(rule(&w, "late")), Err(AddError::Quarantined)),
                "{what}"
            );
        }
    }

    #[test]
    fn the_file_holds_at_most_200_rules_and_the_201st_is_refused_without_changing_the_file() {
        let w = world();
        let (store, _) = open(&w);
        for i in 0..MAX_PERSISTED_RULES {
            store.add(rule(&w, &format!("r{i}"))).unwrap();
        }
        let before = fs::read(w.dir.join(RULES_FILE)).unwrap();

        let result = store.add(rule(&w, "one-too-many"));

        assert!(matches!(result, Err(AddError::Limit)), "{result:?}");
        assert!(matches!(store.can_add(), Err(AddError::Limit)));
        assert_eq!(store.len(), MAX_PERSISTED_RULES);
        assert_eq!(fs::read(w.dir.join(RULES_FILE)).unwrap(), before);
        // A removal makes room again.
        assert!(store.remove("r0").unwrap().is_some());
        store.add(rule(&w, "fits-now")).unwrap();
    }

    #[test]
    fn use_counts_reach_the_disk_lazily_and_on_flush_without_looking_like_tampering() {
        let w = world();
        let (store, _) = open(&w);
        store.add(rule(&w, "r1")).unwrap();
        let written = fs::read(w.dir.join(RULES_FILE)).unwrap();

        for _ in 0..3 {
            store.record_use("r1");
        }

        assert_eq!(
            store.get("r1").unwrap().uses,
            3,
            "counted in memory at once"
        );
        assert_eq!(
            fs::read(w.dir.join(RULES_FILE)).unwrap(),
            written,
            "not rewritten on every use"
        );
        store.flush().unwrap();
        let flushed: serde_json::Value =
            serde_json::from_slice(&fs::read(w.dir.join(RULES_FILE)).unwrap()).unwrap();
        assert_eq!(flushed["rules"][0]["uses"], 3);
        assert_eq!(
            fs::read_to_string(w.dir.join(SIDECAR_FILE)).unwrap().trim(),
            sha_hex(&fs::read(w.dir.join(RULES_FILE)).unwrap()),
            "the hash follows the flush"
        );
        assert_eq!(store.check_external(&w.home), External::Unchanged);
        let (again, report) = open(&w);
        assert_eq!(report.quarantined, None);
        assert_eq!(again.get("r1").unwrap().uses, 3);
        // Nothing pending: a second flush changes nothing.
        let after = fs::read(w.dir.join(RULES_FILE)).unwrap();
        store.flush().unwrap();
        assert_eq!(fs::read(w.dir.join(RULES_FILE)).unwrap(), after);
        // An unknown id counts nothing.
        store.record_use("nope");
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn a_change_the_daemon_did_not_make_quarantines_and_a_quarantined_store_refuses_removal() {
        let w = world();
        let (store, _) = open(&w);
        store.add(rule(&w, "r1")).unwrap();
        assert_eq!(store.check_external(&w.home), External::Unchanged);

        let mut edited: serde_json::Value =
            serde_json::from_slice(&fs::read(w.dir.join(RULES_FILE)).unwrap()).unwrap();
        edited["rules"][0]["created_by_window"] = json!("hand");
        fs::write(w.dir.join(RULES_FILE), serde_json::to_vec(&edited).unwrap()).unwrap();

        assert!(matches!(
            store.check_external(&w.home),
            External::Quarantined(..)
        ));
        assert!(store.quarantined().is_some());
        assert!(store.wire().0.is_empty());
        assert!(matches!(store.remove("r1"), Err(ChangeError::Quarantined)));
        assert!(matches!(store.can_add(), Err(AddError::Quarantined)));
    }

    #[test]
    fn keep_only_accepts_the_file_that_was_reviewed_and_discard_leaves_an_empty_bound_file() {
        let w = world();
        let (store, _) = open(&w);
        store.add(rule(&w, "r1")).unwrap();
        fs::write(
            w.dir.join(RULES_FILE),
            fs::read(w.dir.join(RULES_FILE))
                .unwrap()
                .iter()
                .chain(b" ")
                .copied()
                .collect::<Vec<u8>>(),
        )
        .unwrap();
        assert!(matches!(
            store.check_external(&w.home),
            External::Quarantined(..)
        ));
        let (_, reviewed) = store.quarantined().unwrap();

        // Changed again after the review.
        fs::write(w.dir.join(RULES_FILE), b"{\"v\":1,\"rules\":[]}  ").unwrap();
        assert!(matches!(
            store.keep(&reviewed, &w.home),
            Err(ChangeError::StaleHash)
        ));
        assert!(matches!(
            store.keep("", &w.home),
            Err(ChangeError::StaleHash)
        ));
        assert!(store.quarantined().is_some());

        store.discard().unwrap();

        assert!(store.quarantined().is_none());
        assert_eq!(store.len(), 0);
        let bytes = fs::read(w.dir.join(RULES_FILE)).unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["rules"], json!([]));
        assert_eq!(
            fs::read_to_string(w.dir.join(SIDECAR_FILE)).unwrap().trim(),
            sha_hex(&bytes)
        );
        let (_, report) = open(&w);
        assert_eq!(report.quarantined, None);
        assert!(matches!(store.discard(), Err(ChangeError::NotQuarantined)));
    }
}
