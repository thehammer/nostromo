use super::*;
use crate::approvals::shell;
use std::collections::BTreeMap;
use std::os::unix::fs::symlink;
use std::sync::Mutex;

fn specs(cmd: &str, cwd: Option<&str>) -> Vec<TargetSpec> {
    let parse = shell::parse(cmd);
    targets(cmd, &parse, cwd.map(Path::new), Path::new("/home/u"))
}

fn path_of(s: &TargetSpec) -> (String, bool) {
    match &s.operand {
        Operand::Path { path, relative, .. } => (path.to_string_lossy().into_owned(), *relative),
        other => panic!("expected a path, got {other:?}"),
    }
}

fn cant_of(s: &TargetSpec) -> (String, String) {
    match &s.operand {
        Operand::CantResolve { text, why } => (text.clone(), why.clone()),
        other => panic!("expected can't resolve, got {other:?}"),
    }
}

// ---- targets() ----

#[test]
fn two_rm_commands_give_two_targets() {
    let t = specs(
        "rm -rf build/ && rm -rf target/debug/incremental",
        Some("/w"),
    );
    assert_eq!(t.len(), 2);
    assert_eq!(path_of(&t[0]), ("/w/build".into(), true));
    assert_eq!(path_of(&t[1]), ("/w/target/debug/incremental".into(), true));
}

#[test]
fn a_bash_c_payload_is_looked_into() {
    let t = specs("bash -c 'rm -r /tmp/x'", None);
    assert_eq!(t.len(), 1);
    assert_eq!(path_of(&t[0]), ("/tmp/x".into(), false));
}

#[test]
fn mv_has_sources_and_a_destination() {
    let t = specs("mv /a /b /c/", None);
    assert_eq!(t.len(), 2);
    assert_eq!(path_of(&t[0]).0, "/a");
    assert_eq!(path_of(&t[1]).0, "/b");
    assert_eq!(t[0].dest.as_deref(), Some("/c"));
}

#[test]
fn double_dash_ends_flags() {
    let t = specs("rm -- -weird", Some("/w"));
    assert_eq!(path_of(&t[0]).0, "/w/-weird");
}

#[test]
fn what_cannot_be_resolved_says_so() {
    for cmd in [
        "rm $DIR/x",
        "rm \"$(pwd)\"/x",
        "rm {a,b}",
        "rm ~other/x",
        "rm \"*.log\"",
        "rm '*.log'",
        "rm ../x",
    ] {
        let t = specs(cmd, Some("/w"));
        assert_eq!(t.len(), 1, "{cmd}");
        assert!(matches!(t[0].operand, Operand::CantResolve { .. }), "{cmd}");
    }
    assert_eq!(cant_of(&specs("rm $DIR/x", Some("/w"))[0]).0, "$DIR/x");
}

#[test]
fn a_bare_glob_resolves() {
    let t = specs("rm /tmp/*.log", None);
    assert_eq!(path_of(&t[0]).0, "/tmp/*.log");
}

#[test]
fn an_unknown_flag_means_nothing_resolves() {
    let t = specs("rm --no-preserve-root /x", None);
    assert_eq!(cant_of(&t[0]).1, "unknown flag");
    let t = specs("rmdir -z /x", None);
    assert_eq!(cant_of(&t[0]).1, "unknown flag");
}

#[test]
fn a_relative_operand_after_a_cd_cannot_be_resolved() {
    let t = specs("cd sub && rm x", Some("/w"));
    assert_eq!(cant_of(&t[0]), ("x".into(), "after a cd".into()));
    // an absolute one still can
    let t = specs("cd sub && rm /abs", Some("/w"));
    assert_eq!(path_of(&t[0]).0, "/abs");
    // before the cd is fine
    let t = specs("rm x; cd sub", Some("/w"));
    assert_eq!(path_of(&t[0]), ("/w/x".into(), true));
    for cmd in [
        "git -C sub rm x; rm y",
        "env -C sub true; rm y",
        "pushd sub; rm y",
    ] {
        let t = specs(cmd, Some("/w"));
        let last = t.last().unwrap();
        assert_eq!(cant_of(last).1, "after a cd", "{cmd}");
    }
}

#[test]
fn a_relative_operand_without_a_cwd_cannot_be_resolved() {
    assert!(matches!(
        specs("rm x", None)[0].operand,
        Operand::CantResolve { .. }
    ));
}

#[test]
fn tilde_expands_against_home() {
    assert_eq!(path_of(&specs("rm ~/a", None)[0]).0, "/home/u/a");
    assert_eq!(path_of(&specs("rm -rf ~", None)[0]).0, "/home/u");
}

#[test]
fn unparsed_input_resolves_nothing() {
    let t = specs("rm -rf /x; cat <<EOF\nbody", None);
    assert!(!t.is_empty());
    assert!(t
        .iter()
        .all(|s| matches!(s.operand, Operand::CantResolve { .. })));
}

#[test]
fn the_command_name_is_its_basename_without_regard_to_case() {
    assert_eq!(specs("/bin/rm /x", None).len(), 1);
    assert_eq!(specs("RM /x", None).len(), 1);
    assert!(specs("echo rm /x", None).is_empty());
    assert!(specs("ls /x", None).is_empty());
}

// ---- the walk ----

fn env(root: &Path) -> Env {
    Env {
        cwd: Some(root.join("cwd")),
        home: root.join("home"),
    }
}

fn spec_for(path: PathBuf) -> TargetSpec {
    TargetSpec {
        command: PreviewCommand::Rm,
        operand: Operand::Path {
            path,
            relative: false,
            trailing_slash: false,
        },
        dest: None,
    }
}

fn touch(p: &Path, bytes: usize) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, vec![b'x'; bytes]).unwrap();
}

/// Relative paths, kinds, sizes, modes, mtimes, content hashes and symlink targets: any change shows.
fn fingerprint(root: &Path) -> BTreeMap<String, String> {
    fn go(dir: &Path, root: &Path, out: &mut BTreeMap<String, String>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            let m = std::fs::symlink_metadata(&p).unwrap();
            let rel = p.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            let link = std::fs::read_link(&p)
                .map(|l| l.to_string_lossy().into_owned())
                .unwrap_or_default();
            let content = if m.is_file() {
                let mut h = std::collections::hash_map::DefaultHasher::new();
                std::hash::Hash::hash(&std::fs::read(&p).unwrap(), &mut h);
                std::hash::Hasher::finish(&h)
            } else {
                0
            };
            out.insert(
                rel,
                format!(
                    "{:?}|{}|{:?}|{}|{:o}|{:x}",
                    m.file_type(),
                    m.len(),
                    m.modified().unwrap(),
                    link,
                    std::os::unix::fs::MetadataExt::mode(&m),
                    content
                ),
            );
            if m.is_dir() {
                go(&p, root, out);
            }
        }
    }
    let mut out = BTreeMap::new();
    go(root, root, &mut out);
    out
}

fn walked(root: &Path, specs: &[TargetSpec]) -> ApprovalPreviewWire {
    let before = fingerprint(root);
    let p = walk(specs, Budget::FULL, &RealFs, &env(root));
    assert_eq!(before, fingerprint(root), "the walk changed the tree");
    p
}

#[test]
fn a_directory_is_counted_and_the_tree_is_untouched() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    touch(&r.join("cwd/build/a.txt"), 10);
    touch(&r.join("cwd/build/sub/b.txt"), 20);
    touch(&r.join("cwd/build/sub/deeper/c.txt"), 30);
    let p = walked(r, &[spec_for(r.join("cwd/build"))]);
    assert_eq!(p.state, PreviewState::Complete);
    let t = &p.targets[0];
    assert_eq!(t.exists, Some(true));
    assert_eq!(t.kind, Some(PreviewKind::Dir));
    assert_eq!((t.dirs, t.files, t.bytes), (Some(2), Some(3), Some(60)));
    assert!(!t.at_least);
    assert!(t.flags.is_empty(), "{:?}", t.flags);
}

#[test]
fn a_missing_path_does_not_exist() {
    let d = tempfile::tempdir().unwrap();
    let p = walked(d.path(), &[spec_for(d.path().join("cwd/nope"))]);
    assert_eq!(p.targets[0].exists, Some(false));
}

#[test]
fn a_file_outside_the_cwd_is_flagged() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    touch(&r.join("elsewhere/f"), 5);
    let p = walked(r, &[spec_for(r.join("elsewhere/f"))]);
    assert!(p.targets[0].flags.contains(&PreviewFlag::OutsideCwd));
    assert_eq!(p.targets[0].files, Some(1));
}

#[test]
fn symlinks_are_never_followed() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    touch(&r.join("cwd/t/a"), 1);
    touch(&r.join("outside/big/1"), 1);
    touch(&r.join("outside/big/2"), 1);
    symlink(r.join("outside/big"), r.join("cwd/t/out")).unwrap();
    symlink(r.join("cwd/t"), r.join("cwd/t/loop")).unwrap();
    let p = walked(
        r,
        &[spec_for(r.join("cwd/t")), spec_for(r.join("cwd/t/out"))],
    );
    let t = &p.targets[0];
    assert_eq!((t.dirs, t.files), (Some(0), Some(3)), "a, out, loop");
    let link = &p.targets[1];
    assert_eq!(link.kind, Some(PreviewKind::Symlink));
    assert!(link.flags.contains(&PreviewFlag::Symlink));
    assert_eq!(link.files, None);
}

#[test]
fn globs_expand_sorted_and_a_miss_stays_literal() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    for n in [
        "b.log",
        "a.log",
        "c.txt",
        ".hidden.log",
        "abc",
        "axc",
        "bcd",
    ] {
        touch(&r.join("cwd").join(n), 1);
    }
    let names = |glob: &str| -> Vec<String> {
        walked(r, &[spec_for(r.join("cwd").join(glob))])
            .targets
            .iter()
            .map(|t| {
                t.path
                    .clone()
                    .unwrap()
                    .rsplit('/')
                    .next()
                    .unwrap()
                    .to_owned()
            })
            .collect()
    };
    assert_eq!(names("*.log"), ["a.log", "b.log"]);
    assert_eq!(names("a?c"), ["abc", "axc"]);
    assert_eq!(names("[ab]*"), ["a.log", "abc", "axc", "b.log", "bcd"]);
    let miss = walked(r, &[spec_for(r.join("cwd/*.zip"))]);
    assert_eq!(miss.targets.len(), 1);
    assert!(miss.targets[0].path.as_deref().unwrap().ends_with("*.zip"));
    assert_eq!(miss.targets[0].exists, Some(false));
}

#[test]
fn targets_are_capped_and_the_rest_counted() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    for i in 0..(MAX_TARGETS + 10) {
        touch(&r.join(format!("cwd/f{i:03}")), 1);
    }
    let p = walked(r, &[spec_for(r.join("cwd/f*"))]);
    assert_eq!(p.targets.len(), MAX_TARGETS);
    assert_eq!(p.more, 10);
}

#[test]
fn ten_thousand_files_are_complete() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    for i in 0..10_000 {
        touch(&r.join(format!("cwd/big/d{}/f{i}", i % 50)), 1);
    }
    let p = walked(r, &[spec_for(r.join("cwd/big"))]);
    assert_eq!(p.state, PreviewState::Complete);
    assert_eq!(p.targets[0].files, Some(10_000));
}

#[test]
#[ignore = "slow: builds 120,000 files"]
fn a_huge_tree_stops_at_the_entry_cap() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    for i in 0..120_000 {
        touch(&r.join(format!("cwd/huge/d{}/f{i}", i % 200)), 0);
    }
    let p = walk(
        &[spec_for(r.join("cwd/huge"))],
        Budget {
            max_entries: MAX_ENTRIES,
            time: Duration::from_secs(60),
        },
        &RealFs,
        &env(r),
    );
    assert_eq!(p.state, PreviewState::Partial);
    assert!(p.targets[0].at_least);
}

#[test]
fn the_entry_budget_gives_a_partial_count() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    for i in 0..50 {
        touch(&r.join(format!("cwd/t/f{i}")), 1);
    }
    let p = walk(
        &[spec_for(r.join("cwd/t"))],
        Budget {
            max_entries: 10,
            time: Duration::from_secs(5),
        },
        &RealFs,
        &env(r),
    );
    assert_eq!(p.state, PreviewState::Partial);
    let t = &p.targets[0];
    assert!(t.at_least);
    assert_eq!(t.files, Some(10));
}

// ---- injected file system ----

#[derive(Default)]
struct Fake {
    dirs: BTreeMap<PathBuf, Vec<&'static str>>,
    files: BTreeMap<PathBuf, u64>,
    devs: BTreeMap<PathBuf, u64>,
    denied: Vec<PathBuf>,
    network: Vec<PathBuf>,
    delay: Duration,
    reads: Mutex<Vec<PathBuf>>,
}

impl Fake {
    fn dir(mut self, p: &str, names: &[&'static str]) -> Self {
        self.dirs.insert(PathBuf::from(p), names.to_vec());
        self
    }
    fn file(mut self, p: &str, len: u64) -> Self {
        self.files.insert(PathBuf::from(p), len);
        self
    }
}

impl PreviewFs for Fake {
    fn symlink_metadata(&self, path: &Path) -> io::Result<Meta> {
        std::thread::sleep(self.delay);
        self.reads.lock().unwrap().push(path.to_path_buf());
        if self.denied.iter().any(|d| path == d) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let dev = *self.devs.get(path).unwrap_or(&1);
        if self.dirs.contains_key(path) {
            Ok(Meta {
                kind: EntryKind::Dir,
                len: 0,
                dev,
            })
        } else if let Some(len) = self.files.get(path) {
            Ok(Meta {
                kind: EntryKind::File,
                len: *len,
                dev,
            })
        } else {
            Err(io::ErrorKind::NotFound.into())
        }
    }
    fn read_dir(&self, path: &Path) -> io::Result<Box<dyn Iterator<Item = io::Result<OsString>>>> {
        self.reads.lock().unwrap().push(path.to_path_buf());
        if self.denied.iter().any(|d| path == d) {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let names = self.dirs.get(path).ok_or(io::ErrorKind::NotFound)?.clone();
        Ok(Box::new(names.into_iter().map(|n| Ok(OsString::from(n)))))
    }
    fn is_network(&self, path: &Path) -> bool {
        self.network.iter().any(|n| path.starts_with(n))
    }
}

fn fake_env() -> Env {
    Env {
        cwd: Some(PathBuf::from("/w")),
        home: PathBuf::from("/home/u"),
    }
}

fn run(fake: &Fake, p: &str) -> ApprovalPreviewWire {
    walk(
        &[spec_for(PathBuf::from(p))],
        Budget::FULL,
        fake,
        &fake_env(),
    )
}

#[test]
fn a_denied_entry_is_counted_as_unreadable_and_the_preview_survives() {
    let mut f = Fake::default()
        .dir("/w/t", &["ok", "locked"])
        .file("/w/t/ok", 3)
        .dir("/w/t/locked", &["x"]);
    f.denied.push(PathBuf::from("/w/t/locked"));
    let p = run(&f, "/w/t");
    let t = &p.targets[0];
    assert!(t.flags.contains(&PreviewFlag::Unreadable));
    assert_eq!(t.files, Some(1));
    // a denied target itself
    let p = run(&f, "/w/t/locked");
    assert!(p.targets[0].flags.contains(&PreviewFlag::Unreadable));
}

#[test]
fn another_device_is_one_entry_and_not_entered() {
    let mut f = Fake::default()
        .dir("/w/t", &["mnt"])
        .dir("/w/t/mnt", &["a", "b"])
        .file("/w/t/mnt/a", 1)
        .file("/w/t/mnt/b", 1);
    f.devs.insert(PathBuf::from("/w/t/mnt"), 2);
    let p = run(&f, "/w/t");
    let t = &p.targets[0];
    assert!(t.flags.contains(&PreviewFlag::OtherVolume));
    assert_eq!((t.dirs, t.files), (Some(1), Some(0)));
    assert!(!f
        .reads
        .lock()
        .unwrap()
        .contains(&PathBuf::from("/w/t/mnt/a")));
}

#[test]
fn a_network_path_is_never_touched() {
    let mut f = Fake::default().dir("/Volumes/nas/x", &["a"]);
    f.network.push(PathBuf::from("/Volumes"));
    let p = run(&f, "/Volumes/nas/x");
    let t = &p.targets[0];
    assert!(t.flags.contains(&PreviewFlag::Network));
    assert!(t.flags.contains(&PreviewFlag::NotCounted));
    assert_eq!(t.exists, None);
    assert!(f.reads.lock().unwrap().is_empty());
    // and under an outer target
    let mut f = Fake::default()
        .dir("/w/t", &["net"])
        .dir("/w/t/net", &["a"])
        .file("/w/t/net/a", 1);
    f.network.push(PathBuf::from("/w/t/net"));
    let t = &run(&f, "/w/t").targets[0];
    assert!(t.flags.contains(&PreviewFlag::Network));
    assert!(!f
        .reads
        .lock()
        .unwrap()
        .contains(&PathBuf::from("/w/t/net/a")));
}

#[test]
fn the_real_classifier_knows_the_macos_roots() {
    for p in [
        "/Volumes/X/a",
        "/Network/a",
        "/net/host",
        "/System/Volumes/Data/net/x",
        "/System/Volumes/Data/home/u",
    ] {
        assert!(is_network_path(Path::new(p)), "{p}");
    }
    assert!(!is_network_path(Path::new("/Users/u/Volumes")));
    assert!(!is_network_path(Path::new("/tmp")));
}

#[test]
fn a_tcc_folder_under_an_outer_target_is_not_entered_but_one_we_are_in_is() {
    let f = Fake::default()
        .dir("/home/u/proj", &["Desktop", "src"])
        .dir("/home/u/proj/Desktop", &["x"])
        .file("/home/u/proj/Desktop/x", 1)
        .dir("/home/u/proj/src", &["m"])
        .file("/home/u/proj/src/m", 1)
        .dir("/home/u", &["Desktop", "Documents"])
        .dir("/home/u/Desktop", &["secret"])
        .dir("/home/u/Desktop/work", &["a", "b"])
        .file("/home/u/Desktop/work/a", 1)
        .file("/home/u/Desktop/work/b", 1)
        .file("/home/u/Desktop/secret", 1);
    // not a TCC folder under /home/u/proj (those are under home itself): proj walks fully
    let t = &run(&f, "/home/u/proj").targets[0];
    assert_eq!(t.files, Some(2));
    // a target inside Desktop is walked
    let t = &run(&f, "/home/u/Desktop/work").targets[0];
    assert_eq!(t.files, Some(2));
    // the folder itself is never opened
    let t = &run(&f, "/home/u/Desktop").targets[0];
    assert!(t.flags.contains(&PreviewFlag::NotCounted));
    // an outer target that contains a protected folder never opens it
    let f = Fake::default()
        .dir(
            "/home/u/Pictures",
            &["Photos Library.photoslibrary", "keep.png"],
        )
        .file("/home/u/Pictures/keep.png", 7)
        .dir("/home/u/Pictures/Photos Library.photoslibrary", &["db"])
        .file("/home/u/Pictures/Photos Library.photoslibrary/db", 1);
    let t = &run(&f, "/home/u/Pictures").targets[0];
    assert!(t.flags.contains(&PreviewFlag::NotCounted), "{:?}", t.flags);
    assert_eq!(t.dirs, Some(1));
    assert_eq!(t.files, Some(1));
    assert!(!read_under(
        &f,
        "/home/u/Pictures/Photos Library.photoslibrary"
    ));
}

#[test]
fn home_critical_targets_are_flagged_and_not_counted() {
    let f = Fake::default()
        .dir("/", &["Users"])
        .dir("/home", &["u"])
        .dir("/home/u", &["a"])
        .dir("/home/u/.ssh", &["id"])
        .dir("/home/u/Library", &[])
        .dir("/home/u/.claude", &[]);
    for p in [
        "/",
        "/home",
        "/home/u",
        "/home/u/.ssh",
        "/home/u/Library",
        "/home/u/.claude",
    ] {
        let t = &run(&f, p).targets[0];
        assert!(t.flags.contains(&PreviewFlag::HomeCritical), "{p}");
        assert!(t.flags.contains(&PreviewFlag::NotCounted), "{p}");
        assert_eq!(t.files, None, "{p}");
    }
    assert!(!f
        .reads
        .lock()
        .unwrap()
        .iter()
        .any(|p| p != Path::new("/home/u/.ssh") && p.starts_with("/home/u/.ssh")));
    let t = &run(&Fake::default().dir("/w/x", &[]), "/w/x").targets[0];
    assert!(!t.flags.contains(&PreviewFlag::HomeCritical));
}

#[test]
fn the_time_budget_stops_a_slow_file_system() {
    let mut f = Fake::default().dir("/w/t", &["a", "b", "c", "d", "e", "f"]);
    for n in ["a", "b", "c", "d", "e", "f"] {
        f.files.insert(PathBuf::from(format!("/w/t/{n}")), 1);
    }
    f.delay = Duration::from_millis(30);
    let started = Instant::now();
    let p = walk(
        &[spec_for(PathBuf::from("/w/t"))],
        Budget {
            max_entries: 100,
            time: Duration::from_millis(50),
        },
        &f,
        &fake_env(),
    );
    assert!(started.elapsed() < Duration::from_millis(500));
    assert_eq!(p.state, PreviewState::Partial);
    assert!(p.targets[0].at_least);
}

#[test]
fn counting_and_busy_previews_need_no_reads() {
    let specs = vec![
        spec_for(PathBuf::from("/home/u")),
        spec_for(PathBuf::from("/x")),
    ];
    let c = counting(&specs, &fake_env());
    assert_eq!(c.state, PreviewState::Counting);
    assert_eq!(c.targets.len(), 2);
    assert!(c.targets[0].flags.contains(&PreviewFlag::HomeCritical));
    assert!(c.targets[1].flags.contains(&PreviewFlag::OutsideCwd));
    assert_eq!(c.targets[1].exists, None);
    let b = busy(&specs, &fake_env());
    assert!(b.targets[1].flags.contains(&PreviewFlag::Busy));
}

#[test]
fn invisible_characters_in_a_path_show_as_tokens() {
    let p = walk(
        &[spec_for(PathBuf::from("/w/a\u{202E}b"))],
        Budget::FULL,
        &Fake::default(),
        &fake_env(),
    );
    assert!(p.targets[0].path.as_deref().unwrap().contains("U+202E"));
}

// ---- read-only proof ----

#[test]
fn the_preview_source_only_reads_metadata_and_listings() {
    let src = include_str!("../preview.rs");
    // Every `fs::` path is one of the two reads (or the unix mode extension trait).
    let mut seen = BTreeSet::new();
    for (at, _) in src.match_indices("fs::") {
        let name: String = src[at + 4..]
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        seen.insert(name);
    }
    let allowed: BTreeSet<String> = ["symlink_metadata", "read_dir", "MetadataExt"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(
        seen, allowed,
        "preview.rs touches the file system through other calls"
    );
    for banned in [
        // changes
        "remove_",
        "rename",
        "create_dir",
        "File::create",
        "OpenOptions",
        "write",
        "set_permissions",
        "set_len",
        "hard_link",
        "symlink(",
        "fs::copy",
        // reads that follow a link or open a file
        ".metadata(",
        "fs::metadata",
        ".exists()",
        ".is_dir()",
        ".is_file()",
        "File::open",
        "canonicalize",
        // processes and escape hatches
        "Command::new",
        "std::process",
        "spawn",
        "libc",
        "unsafe",
    ] {
        assert!(
            !src.contains(banned),
            "preview.rs must not contain `{banned}`"
        );
    }
}

#[test]
fn an_outer_glob_never_lists_a_tcc_folder_but_a_glob_inside_one_does() {
    let f = Fake::default()
        .dir("/home/u", &["Desktop", "proj"])
        .dir("/home/u/Desktop", &["a.txt"])
        .file("/home/u/Desktop/a.txt", 1)
        .dir("/home/u/proj", &["a.txt"])
        .file("/home/u/proj/a.txt", 1);
    let outer = run(&f, "/home/u/*/a.txt");
    assert!(!f
        .reads
        .lock()
        .unwrap()
        .contains(&PathBuf::from("/home/u/Desktop")));
    assert!(outer
        .targets
        .iter()
        .any(|t| t.path.as_deref() == Some("/home/u/proj/a.txt")));
    let inner = run(&f, "/home/u/Desktop/*.txt");
    assert_eq!(
        inner.targets[0].path.as_deref(),
        Some("/home/u/Desktop/a.txt")
    );
}

#[test]
fn builtin_and_command_wrappers_count_as_a_directory_change() {
    for cmd in [
        "builtin cd sub; rm y",
        "command cd sub; rm y",
        "export PWD=/x; rm y",
    ] {
        let t = specs(cmd, Some("/w"));
        assert!(
            matches!(t.last().unwrap().operand, Operand::CantResolve { .. }),
            "{cmd}"
        );
    }
}

// ---- review fix-ups: the preview fails toward "can't resolve", never toward calm ----

fn mac_env() -> Env {
    Env {
        cwd: Some(PathBuf::from("/tmp/w")),
        home: PathBuf::from("/Users/me"),
    }
}

fn run_in(fake: &Fake, p: &str, env: &Env) -> ApprovalPreviewWire {
    walk(&[spec_for(PathBuf::from(p))], Budget::FULL, fake, env)
}

/// Was anything inside `dir` (not `dir` itself) read?
fn read_under(f: &Fake, dir: &str) -> bool {
    let dir = dir.trim_end_matches('/');
    f.reads
        .lock()
        .unwrap()
        .iter()
        .any(|p| p != Path::new(dir) && p.starts_with(dir))
}

#[test]
fn protected_folders_match_without_regard_to_case_or_alias() {
    for p in [
        "/Users/me/documents",
        "/Users/me/DOCUMENTS",
        "/System/Volumes/Data/Users/me/Documents",
        "/System/Volumes/Data/Users/me/desktop",
    ] {
        let f = Fake::default()
            .dir(p, &["inner"])
            .file(&format!("{p}/inner"), 1);
        let t = &run_in(&f, p, &mac_env()).targets[0];
        assert!(t.flags.contains(&PreviewFlag::NotCounted), "{p}");
        assert_eq!(t.files, None, "{p}");
        assert!(!read_under(&f, &format!("{p}/")), "{p} was read");
    }
}

#[test]
fn home_critical_matches_without_regard_to_case_or_alias() {
    for p in [
        "/Users/me/LIBRARY",
        "/Users/me/.SSH",
        "/System/Volumes/Data/Users/me/.ssh",
        "/System/Volumes/Data/Users/me",
        "/users/ME",
    ] {
        let f = Fake::default()
            .dir(p, &["inner"])
            .file(&format!("{p}/inner"), 1);
        let t = &run_in(&f, p, &mac_env()).targets[0];
        assert!(t.flags.contains(&PreviewFlag::HomeCritical), "{p}");
        assert!(t.flags.contains(&PreviewFlag::NotCounted), "{p}");
        assert!(!read_under(&f, &format!("{p}/")), "{p} was read");
    }
}

#[test]
fn private_aliases_are_the_same_place_for_the_working_folder() {
    let f = Fake::default().dir("/private/tmp/w/x", &[]);
    let t = &run_in(&f, "/private/tmp/w/x", &mac_env()).targets[0];
    assert!(!t.flags.contains(&PreviewFlag::OutsideCwd));
    let f = Fake::default().dir("/tmp/other", &[]);
    let t = &run_in(&f, "/tmp/other", &mac_env()).targets[0];
    assert!(t.flags.contains(&PreviewFlag::OutsideCwd));
}

#[test]
fn newly_listed_privacy_folders_are_never_opened() {
    for dir in ["Music", "Movies", "Library/Calendars", "Library/Cookies"] {
        let p = format!("/Users/me/{dir}");
        let f = Fake::default().dir(&p, &["x"]).file(&format!("{p}/x"), 1);
        let t = &run_in(&f, &p, &mac_env()).targets[0];
        assert!(t.flags.contains(&PreviewFlag::NotCounted), "{dir}");
    }
}

#[test]
fn a_glob_into_a_protected_folder_cannot_resolve_and_is_never_read() {
    let f = Fake::default()
        .dir("/home/u", &["Desktop", "proj"])
        .dir("/home/u/Desktop", &["a.txt"])
        .file("/home/u/Desktop/a.txt", 1)
        .dir("/home/u/proj", &["a.txt"])
        .file("/home/u/proj/a.txt", 1);
    let p = run(&f, "/home/u/*/*.txt");
    let cant = p
        .targets
        .iter()
        .find(|t| t.cant_resolve.as_deref() == Some("/home/u/Desktop/*.txt"))
        .expect("the protected glob is a can't-resolve line");
    assert_eq!(cant.path, None);
    assert_eq!(cant.exists, None);
    assert_eq!(cant.why.as_deref(), Some("not counted: protected folder"));
    assert!(
        !f.reads
            .lock()
            .unwrap()
            .iter()
            .any(|p| p.starts_with("/home/u/Desktop")),
        "a protected folder was read"
    );
    assert!(p
        .targets
        .iter()
        .any(|t| t.path.as_deref() == Some("/home/u/proj/a.txt")));
}

#[test]
fn a_glob_through_an_unreadable_folder_cannot_resolve() {
    let mut f = Fake::default().dir("/w/t", &["a.log"]);
    f.denied.push(PathBuf::from("/w/t"));
    let t = &run(&f, "/w/t/*.log").targets[0];
    assert_eq!(t.cant_resolve.as_deref(), Some("/w/t/*.log"));
    assert_eq!(t.exists, None, "never reported as not existing");
    // a folder that is not there is an honest miss
    let t = &run(&Fake::default(), "/w/gone/*.log").targets[0];
    assert_eq!(t.exists, Some(false));
}

#[test]
fn a_glob_whose_listing_ran_out_of_budget_cannot_resolve() {
    let f = Fake::default().dir("/w/t", &["a.log", "b.log"]);
    let p = walk(
        &[spec_for(PathBuf::from("/w/t/*.log"))],
        Budget {
            max_entries: 0,
            time: Duration::from_secs(5),
        },
        &f,
        &fake_env(),
    );
    assert_eq!(p.state, PreviewState::Partial);
    assert_eq!(p.targets[0].exists, None);
    assert!(p.targets[0].cant_resolve.is_some());
}

#[test]
fn a_target_through_a_symlinked_folder_cannot_resolve() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    touch(&r.join("outside/file"), 1);
    std::fs::create_dir_all(r.join("cwd")).unwrap();
    symlink(r.join("outside"), r.join("cwd/link")).unwrap();
    let p = walked(r, &[spec_for(r.join("cwd/link/file"))]);
    let t = &p.targets[0];
    assert_eq!(t.why.as_deref(), Some("path goes through a link"));
    assert_eq!(t.files, None);
}

#[test]
fn a_trailing_slash_on_a_symlink_cannot_resolve() {
    let d = tempfile::tempdir().unwrap();
    let r = d.path();
    touch(&r.join("outside/file"), 1);
    std::fs::create_dir_all(r.join("cwd")).unwrap();
    symlink(r.join("outside"), r.join("cwd/link")).unwrap();
    let mut spec = spec_for(r.join("cwd/link"));
    spec.operand = Operand::Path {
        path: r.join("cwd/link"),
        relative: false,
        trailing_slash: true,
    };
    let t = &walked(r, &[spec]).targets[0];
    assert!(t.cant_resolve.is_some());
    assert!(t.why.as_deref().unwrap().contains("trailing slash"));
    // without the slash it is the link itself
    let t = &walked(r, &[spec_for(r.join("cwd/link"))]).targets[0];
    assert_eq!(t.kind, Some(PreviewKind::Symlink));
}

#[test]
fn the_parser_records_a_trailing_slash() {
    match &specs("rm -r dir/ other", Some("/w"))[..] {
        [a, b] => {
            assert!(matches!(
                a.operand,
                Operand::Path {
                    trailing_slash: true,
                    ..
                }
            ));
            assert!(matches!(
                b.operand,
                Operand::Path {
                    trailing_slash: false,
                    ..
                }
            ));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_wrapped_removal_is_a_cant_resolve_line() {
    for (cmd, via) in [
        ("sudo rm -rf /x", "sudo"),
        ("env A=1 rm /x", "env"),
        ("nice -n 5 rm /x", "nice"),
        ("timeout 5 rm /x", "timeout"),
        ("xargs rm", "xargs"),
        ("command rm /x", "command"),
        ("sudo mv a b", "sudo"),
        ("find . -delete", "find -delete"),
        ("find . -name x -exec rm {} +", "find -exec"),
    ] {
        let t = specs(cmd, Some("/w"));
        let wrapped = t
            .iter()
            .find(|s| matches!(&s.operand, Operand::CantResolve { why, .. } if why == &format!("runs via {via}")));
        assert!(wrapped.is_some(), "{cmd}: {t:?}");
    }
    let t = specs("sudo rm -rf ~/x; rm foo", Some("/w"));
    assert_eq!(t.len(), 2);
    assert_eq!(cant_of(&t[0]).1, "runs via sudo");
    assert_eq!(path_of(&t[1]).0, "/w/foo");
    assert!(specs("echo rm /x", None).is_empty());
    assert!(specs("find . -name x", None).is_empty());
    assert!(specs("sudo ls /x", None).is_empty());
}

#[test]
fn a_busy_preview_marks_every_path_not_counted() {
    let b = busy(&[spec_for(PathBuf::from("/w/t"))], &fake_env());
    let t = &b.targets[0];
    assert!(t.flags.contains(&PreviewFlag::NotCounted));
    assert!(t.flags.contains(&PreviewFlag::Busy));
    assert_eq!(t.files, None);
}
