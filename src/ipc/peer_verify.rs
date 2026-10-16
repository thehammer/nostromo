//! Who is on the other end of a Unix-socket connection, and is it the
//! Nostromo Mac app?
//!
//! The daemon socket is mode 0600, so every peer runs as the user. That still
//! includes an agent's own Bash, which must not be able to answer the agent's
//! own decision. So a Unix connection is the operator app
//! ([`PeerTrust::OperatorApp`]) only when **both** hold:
//!
//! - the connecting process's executable lives in an app bundle whose
//!   `CFBundleIdentifier` is the Nostromo app's (resolved by a
//!   [`PeerVerifier`] from the socket), and
//! - its `Hello` claimed `client_kind = "mac_app"`.
//!
//! The app is ad-hoc signed (no Team ID), so a code-signature requirement is
//! not available. A same-uid process that builds a fake `.app` with the same
//! bundle id is a known residual risk.
//!
//! [`classify_peer`] is the **only** place that assigns `OperatorApp`.

use std::path::{Path, PathBuf};

use tokio::net::UnixStream;

use super::peer::PeerTrust;

/// The Nostromo app's bundle identifier.
pub const APP_BUNDLE_ID: &str = "com.hammer.nostromo";
/// The isolated QA instance's bundle identifier. Accepted only when the daemon
/// runs in QA mode (`NOSTROMO_QA_DAEMON=1`).
pub const QA_BUNDLE_ID: &str = "com.hammer.nostromo.qa";
/// The `Hello.client_kind` the Mac app sends.
pub const MAC_APP_CLIENT_KIND: &str = "mac_app";

/// What the daemon could learn about the process behind a Unix connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    pub pid: i32,
    /// The executable's path (`proc_pidpath`).
    pub exe: PathBuf,
    /// `CFBundleIdentifier` of the app bundle enclosing `exe`, if `exe` is
    /// inside one and its `Info.plist` could be read.
    pub bundle_id: Option<String>,
}

/// Resolves the process behind a Unix connection. Injected into
/// [`crate::ipc::Server::bind`] so tests can stand in for the Mac app.
pub trait PeerVerifier: Send + Sync {
    fn inspect(&self, stream: &UnixStream) -> Option<PeerInfo>;
}

/// The real verifier: peer pid, then its executable path, then the enclosing
/// app bundle's `CFBundleIdentifier`.
#[derive(Debug, Default, Clone, Copy)]
pub struct MacPeerVerifier;

impl PeerVerifier for MacPeerVerifier {
    fn inspect(&self, stream: &UnixStream) -> Option<PeerInfo> {
        let pid = peer_pid(stream)?;
        let exe = exe_of(pid)?;
        let bundle_id = bundle_id_for_exe(&exe);
        Some(PeerInfo { pid, exe, bundle_id })
    }
}

/// `CFBundleIdentifier` of the app bundle enclosing `exe`, when `exe` has the
/// shape `<X>.app/Contents/MacOS/<exe>` and the bundle's `Info.plist` reads.
pub fn bundle_id_for_exe(exe: &Path) -> Option<String> {
    let info = app_bundle_of(exe)?.join("Contents").join("Info.plist");
    let plist = plist::Value::from_file(info).ok()?;
    plist.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_owned)
}

/// The trust of a Unix connection after its `Hello`. Pure: `info` is what the
/// verifier resolved (if anything), `client_kind` is the Hello's claim, and
/// `qa_mode` is whether the daemon accepts the QA instance's bundle id.
///
/// `OperatorApp` iff the Hello claimed [`MAC_APP_CLIENT_KIND`] **and** the
/// peer's executable is `<X>.app/Contents/MacOS/<exe>` in a bundle whose id is
/// [`APP_BUNDLE_ID`] (or [`QA_BUNDLE_ID`] in QA mode). Everything else is
/// `LocalOther`.
pub fn classify_peer(info: Option<&PeerInfo>, client_kind: Option<&str>, qa_mode: bool) -> PeerTrust {
    let claims_app = client_kind == Some(MAC_APP_CLIENT_KIND);
    let is_app = info.is_some_and(|info| {
        let accepted_id = match info.bundle_id.as_deref() {
            Some(APP_BUNDLE_ID) => true,
            Some(QA_BUNDLE_ID) => qa_mode,
            _ => false,
        };
        accepted_id && app_bundle_of(&info.exe).is_some()
    });
    if claims_app && is_app {
        PeerTrust::OperatorApp
    } else {
        PeerTrust::LocalOther
    }
}

/// The `<X>.app` directory of an executable at `<X>.app/Contents/MacOS/<exe>`.
fn app_bundle_of(exe: &Path) -> Option<&Path> {
    let macos = exe.parent()?;
    let contents = macos.parent()?;
    let app = contents.parent()?;
    let is_app = macos.file_name()? == "MacOS"
        && contents.file_name()? == "Contents"
        && app.extension()? == "app";
    is_app.then_some(app)
}

/// The pid of the process at the other end of `stream`.
fn peer_pid(stream: &UnixStream) -> Option<i32> {
    if let Some(pid) = stream.peer_cred().ok().and_then(|cred| cred.pid()) {
        return Some(pid);
    }
    local_peer_pid(stream)
}

/// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)`: the pid of the process that
/// connected, recorded by the kernel at connect time.
#[cfg(target_os = "macos")]
fn local_peer_pid(stream: &UnixStream) -> Option<i32> {
    use std::os::fd::AsRawFd;

    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `pid` and `len` are valid for writes of the sizes passed, and the
    // fd belongs to `stream`, which outlives the call.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    };
    (rc == 0 && pid > 0).then_some(pid)
}

#[cfg(not(target_os = "macos"))]
fn local_peer_pid(_stream: &UnixStream) -> Option<i32> {
    None
}

/// The executable path of `pid` (`proc_pidpath`).
#[cfg(target_os = "macos")]
fn exe_of(pid: i32) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStringExt;

    let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: `buf` is valid for writes of `buf.len()` bytes.
    let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
    if len <= 0 {
        return None;
    }
    buf.truncate(len as usize);
    Some(PathBuf::from(std::ffi::OsString::from_vec(buf)))
}

#[cfg(not(target_os = "macos"))]
fn exe_of(pid: i32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

/// Stand-ins for the Mac app and for other local processes, for tests that
/// run the daemon in-process (every connection there comes from the test
/// binary itself, which is never inside an app bundle).
#[cfg(any(test, feature = "test-support"))]
pub mod testing {
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::sync::Mutex;
    use std::time::Duration;

    use tokio::net::UnixStream;

    use super::{PeerInfo, PeerVerifier, APP_BUNDLE_ID};

    /// What the genuine Mac app looks like to the verifier.
    pub fn app_info() -> PeerInfo {
        PeerInfo {
            pid: 4242,
            exe: PathBuf::from("/Applications/Nostromo.app/Contents/MacOS/Nostromo"),
            bundle_id: Some(APP_BUNDLE_ID.to_string()),
        }
    }

    /// What an agent's script looks like to the verifier.
    pub fn script_info() -> PeerInfo {
        PeerInfo { pid: 4343, exe: PathBuf::from("/usr/bin/python3"), bundle_id: None }
    }

    /// Answers each `inspect` from a script, in accept order, then with
    /// `fallback` once the script runs out. Optionally sleeps first, to stand in
    /// for a slow lookup.
    pub struct FakePeerVerifier {
        script: Mutex<VecDeque<Option<PeerInfo>>>,
        fallback: Option<PeerInfo>,
        delay: Option<Duration>,
        /// Sleep only on the very first `inspect`, to stand in for one slow
        /// lookup among otherwise quick ones.
        first_delay: Mutex<Option<Duration>>,
    }

    impl FakePeerVerifier {
        /// Every connection is the genuine app (it still needs the Hello claim).
        pub fn always_app() -> Self {
            Self::scripted(Vec::new(), Some(app_info()))
        }

        /// Every connection is an ordinary local process.
        pub fn always_script() -> Self {
            Self::scripted(Vec::new(), Some(script_info()))
        }

        /// The n-th accepted connection gets `script[n]`; later ones get `fallback`.
        pub fn scripted(script: Vec<Option<PeerInfo>>, fallback: Option<PeerInfo>) -> Self {
            Self { script: Mutex::new(script.into()), fallback, delay: None, first_delay: Mutex::new(None) }
        }

        /// Sleep `delay` (on the calling thread) before every answer.
        pub fn with_delay(mut self, delay: Duration) -> Self {
            self.delay = Some(delay);
            self
        }

        /// Sleep `delay` (on the calling thread) before the FIRST answer only;
        /// every later `inspect` is immediate.
        pub fn with_delay_on_first_inspect(self, delay: Duration) -> Self {
            *self.first_delay.lock().unwrap() = Some(delay);
            self
        }
    }

    impl PeerVerifier for FakePeerVerifier {
        fn inspect(&self, _stream: &UnixStream) -> Option<PeerInfo> {
            let first = self.first_delay.lock().unwrap().take();
            if let Some(delay) = first {
                std::thread::sleep(delay);
            }
            if let Some(delay) = self.delay {
                std::thread::sleep(delay);
            }
            let next = self.script.lock().unwrap().pop_front();
            next.unwrap_or_else(|| self.fallback.clone())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};

    fn info(exe: &str, bundle_id: Option<&str>) -> PeerInfo {
        PeerInfo { pid: 1234, exe: PathBuf::from(exe), bundle_id: bundle_id.map(str::to_string) }
    }

    const APP_EXE: &str = "/Applications/Nostromo.app/Contents/MacOS/Nostromo";

    // ── classify_peer ─────────────────────────────────────────────────────────

    #[test]
    fn the_genuine_app_that_claims_to_be_the_mac_app_is_the_operator() {
        let i = info(APP_EXE, Some(APP_BUNDLE_ID));
        assert_eq!(classify_peer(Some(&i), Some("mac_app"), false), PeerTrust::OperatorApp);
    }

    #[test]
    fn the_genuine_app_that_claims_nothing_is_an_ordinary_local_peer() {
        let i = info(APP_EXE, Some(APP_BUNDLE_ID));
        assert_eq!(classify_peer(Some(&i), None, false), PeerTrust::LocalOther);
    }

    #[test]
    fn the_genuine_app_with_some_other_claim_is_an_ordinary_local_peer() {
        let i = info(APP_EXE, Some(APP_BUNDLE_ID));
        for claim in ["ios_app", "MAC_APP", "mac_app ", "", "operator"] {
            assert_eq!(
                classify_peer(Some(&i), Some(claim), false),
                PeerTrust::LocalOther,
                "claim {claim:?} must not make the app the operator"
            );
        }
    }

    #[test]
    fn the_qa_instance_is_the_operator_only_when_the_daemon_runs_in_qa_mode() {
        let i = info("/x/Nostromo QA.app/Contents/MacOS/Nostromo", Some(QA_BUNDLE_ID));
        assert_eq!(classify_peer(Some(&i), Some("mac_app"), true), PeerTrust::OperatorApp);
        assert_eq!(classify_peer(Some(&i), Some("mac_app"), false), PeerTrust::LocalOther);
    }

    #[test]
    fn the_qa_instance_without_the_claim_is_not_the_operator_even_in_qa_mode() {
        let i = info("/x/Nostromo QA.app/Contents/MacOS/Nostromo", Some(QA_BUNDLE_ID));
        assert_eq!(classify_peer(Some(&i), None, true), PeerTrust::LocalOther);
    }

    #[test]
    fn the_genuine_app_is_still_the_operator_when_the_daemon_runs_in_qa_mode() {
        let i = info(APP_EXE, Some(APP_BUNDLE_ID));
        assert_eq!(classify_peer(Some(&i), Some("mac_app"), true), PeerTrust::OperatorApp);
    }

    #[test]
    fn a_process_outside_any_app_bundle_is_never_the_operator_whatever_it_claims() {
        let own_exe = std::env::current_exe().expect("current_exe");
        for exe in [PathBuf::from("/usr/bin/python3"), own_exe] {
            let i = PeerInfo { pid: 1, exe: exe.clone(), bundle_id: Some(APP_BUNDLE_ID.to_string()) };
            assert_eq!(
                classify_peer(Some(&i), Some("mac_app"), false),
                PeerTrust::LocalOther,
                "{} is not inside an app bundle",
                exe.display()
            );
            assert_eq!(classify_peer(Some(&i), Some("mac_app"), true), PeerTrust::LocalOther);
        }
    }

    #[test]
    fn an_executable_not_at_contents_macos_inside_the_bundle_is_never_the_operator() {
        for exe in [
            "/x/Nostromo.app/Contents/Resources/tool",
            "/x/Nostromo.app/MacOS/Nostromo",
            "/x/Nostromo.app/Nostromo",
            "/x/Nostromo.app/Contents/Nostromo",
        ] {
            let i = info(exe, Some(APP_BUNDLE_ID));
            assert_eq!(
                classify_peer(Some(&i), Some("mac_app"), false),
                PeerTrust::LocalOther,
                "{exe} has the wrong bundle shape"
            );
        }
    }

    #[test]
    fn a_peer_the_verifier_could_not_resolve_is_an_ordinary_local_peer() {
        assert_eq!(classify_peer(None, Some("mac_app"), false), PeerTrust::LocalOther);
        assert_eq!(classify_peer(None, Some("mac_app"), true), PeerTrust::LocalOther);
    }

    #[test]
    fn a_resolved_peer_whose_bundle_has_no_readable_identifier_is_an_ordinary_local_peer() {
        let i = info(APP_EXE, None);
        assert_eq!(classify_peer(Some(&i), Some("mac_app"), false), PeerTrust::LocalOther);
    }

    #[test]
    fn an_app_with_another_bundle_identifier_is_not_the_operator() {
        for id in ["com.apple.Terminal", "com.hammer.nostromo2", "com.hammer.Nostromo", "com.hammer", ""] {
            let i = info("/Applications/Other.app/Contents/MacOS/Other", Some(id));
            assert_eq!(
                classify_peer(Some(&i), Some("mac_app"), true),
                PeerTrust::LocalOther,
                "bundle id {id:?} must not be accepted"
            );
        }
    }

    // ── bundle_id_for_exe ─────────────────────────────────────────────────────

    /// `<root>/Fake.app/Contents/MacOS/Fake` with `plist_bytes` as Info.plist
    /// (or none). Returns the exe path.
    fn make_app(root: &Path, plist_bytes: Option<&[u8]>) -> PathBuf {
        let contents = root.join("Fake.app/Contents");
        fs::create_dir_all(contents.join("MacOS")).unwrap();
        let exe = contents.join("MacOS/Fake");
        fs::write(&exe, b"#!/bin/sh\n").unwrap();
        if let Some(bytes) = plist_bytes {
            fs::write(contents.join("Info.plist"), bytes).unwrap();
        }
        exe
    }

    fn xml_plist(body: &str) -> Vec<u8> {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <plist version=\"1.0\"><dict>{body}</dict></plist>\n"
        )
        .into_bytes()
    }

    #[test]
    fn the_bundle_identifier_is_read_from_an_xml_info_plist() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(
            dir.path(),
            Some(&xml_plist("<key>CFBundleIdentifier</key><string>com.example.fake</string>")),
        );
        assert_eq!(bundle_id_for_exe(&exe).as_deref(), Some("com.example.fake"));
    }

    #[test]
    fn the_bundle_identifier_is_read_from_a_binary_info_plist() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(dir.path(), None);
        let mut d = plist::Dictionary::new();
        d.insert("CFBundleIdentifier".into(), plist::Value::String("com.example.binary".into()));
        plist::Value::Dictionary(d)
            .to_file_binary(dir.path().join("Fake.app/Contents/Info.plist"))
            .unwrap();
        assert_eq!(bundle_id_for_exe(&exe).as_deref(), Some("com.example.binary"));
    }

    #[test]
    fn an_executable_outside_any_app_bundle_has_no_bundle_identifier() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("tool");
        fs::write(&exe, b"x").unwrap();
        // A sibling Info.plist must not be mistaken for a bundle's.
        fs::write(
            dir.path().join("Info.plist"),
            xml_plist("<key>CFBundleIdentifier</key><string>com.hammer.nostromo</string>"),
        )
        .unwrap();
        assert_eq!(bundle_id_for_exe(&exe), None);
        assert_eq!(bundle_id_for_exe(Path::new("/usr/bin/python3")), None);
        assert_eq!(bundle_id_for_exe(&std::env::current_exe().unwrap()), None);
    }

    #[test]
    fn an_app_with_no_info_plist_has_no_bundle_identifier() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(dir.path(), None);
        assert_eq!(bundle_id_for_exe(&exe), None);
    }

    #[test]
    fn an_app_with_an_unreadable_info_plist_has_no_bundle_identifier() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(dir.path(), Some(b"this is not a property list \x00\xff"));
        assert_eq!(bundle_id_for_exe(&exe), None);
    }

    #[test]
    fn an_info_plist_without_a_bundle_identifier_yields_none() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(dir.path(), Some(&xml_plist("<key>CFBundleName</key><string>Fake</string>")));
        assert_eq!(bundle_id_for_exe(&exe), None);
    }

    #[test]
    fn an_info_plist_whose_bundle_identifier_is_not_a_string_yields_none() {
        let dir = tempfile::tempdir().unwrap();
        let exe = make_app(dir.path(), Some(&xml_plist("<key>CFBundleIdentifier</key><integer>7</integer>")));
        assert_eq!(bundle_id_for_exe(&exe), None);
    }

    #[test]
    fn an_executable_inside_the_bundle_but_not_under_contents_macos_has_no_bundle_identifier() {
        let dir = tempfile::tempdir().unwrap();
        make_app(
            dir.path(),
            Some(&xml_plist("<key>CFBundleIdentifier</key><string>com.hammer.nostromo</string>")),
        );
        let helper = dir.path().join("Fake.app/Contents/Resources/tool");
        fs::create_dir_all(helper.parent().unwrap()).unwrap();
        fs::write(&helper, b"x").unwrap();
        assert_eq!(bundle_id_for_exe(&helper), None);
    }

    // ── MacPeerVerifier ───────────────────────────────────────────────────────

    /// The accepted end of a real Unix-socket connection made by this process:
    /// exactly what the daemon inspects.
    async fn accepted_stream_from_this_process() -> (UnixStream, UnixStream, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let client = UnixStream::connect(&path).await.unwrap();
        let (server_side, _) = listener.accept().await.unwrap();
        (server_side, client, dir)
    }

    #[tokio::test]
    async fn the_mac_verifier_resolves_the_connecting_process_and_finds_no_app_bundle_for_a_test_binary() {
        let (server_side, _client, _dir) = accepted_stream_from_this_process().await;

        let resolved = MacPeerVerifier.inspect(&server_side).expect("the peer is this very process");

        assert_eq!(resolved.pid, std::process::id() as i32);
        assert_eq!(
            fs::canonicalize(&resolved.exe).unwrap(),
            fs::canonicalize(std::env::current_exe().unwrap()).unwrap()
        );
        assert_eq!(resolved.bundle_id, None, "a cargo test binary is not inside an app bundle");
        assert_eq!(
            classify_peer(Some(&resolved), Some("mac_app"), false),
            PeerTrust::LocalOther,
            "claiming to be the app from outside the bundle grants nothing"
        );
    }

    // ── T-AP1-1: only classify_peer may mint the operator ────────────────────

    /// Every `.rs` file under `dir`, recursively.
    fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                rust_files(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }

    /// Is this occurrence of the token a pattern or a comparison rather than a
    /// construction?
    fn is_pattern_use(line: &str, token: &str) -> bool {
        let trimmed = line.trim();
        let Some(at) = line.find(token) else { return true };
        if line.contains("matches!") {
            return true;
        }
        let before = line[..at].trim_end();
        if before.ends_with("==") || before.ends_with("!=") {
            return true;
        }
        let after = line[at + token.len()..].trim_start();
        if after.starts_with("==") || after.starts_with("!=") {
            return true;
        }
        // `PeerTrust::OperatorApp | PeerTrust::LocalOther => ...`: the token is
        // on the pattern side of the arrow. `x => PeerTrust::OperatorApp` is a
        // construction.
        if let Some(arrow) = line.find("=>") {
            return at < arrow;
        }
        // A pattern alternation split across lines.
        trimmed.starts_with('|') || trimmed.ends_with('|') || after.starts_with('|')
    }

    #[test]
    fn nothing_but_peer_verify_constructs_the_operator_trust() {
        const TOKEN: &str = "PeerTrust::OperatorApp";
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let own = src.join("ipc/peer_verify.rs");
        let mut files = Vec::new();
        rust_files(&src, &mut files);
        assert!(files.len() > 20, "sanity: the walk must find the crate's sources");

        let mut offenders = Vec::new();
        for file in files.into_iter().filter(|f| *f != own) {
            let text = fs::read_to_string(&file).unwrap();
            let production = text.split("#[cfg(test)]").next().unwrap();
            for (n, line) in production.lines().enumerate() {
                if line.trim_start().starts_with("//") || !line.contains(TOKEN) {
                    continue;
                }
                if !is_pattern_use(line, TOKEN) {
                    offenders.push(format!("{}:{}: {}", file.display(), n + 1, line.trim()));
                }
            }
        }
        assert!(
            offenders.is_empty(),
            "only classify_peer may produce PeerTrust::OperatorApp:\n{}",
            offenders.join("\n")
        );
    }

    #[test]
    fn the_operator_construction_scan_tells_patterns_from_constructions() {
        const T: &str = "PeerTrust::OperatorApp";
        for pattern in [
            "            PeerTrust::OperatorApp | PeerTrust::LocalOther => false,",
            "        PeerTrust::OperatorApp => true,",
            "        if trust == PeerTrust::OperatorApp {",
            "        if trust != PeerTrust::OperatorApp {",
            "        assert!(matches!(trust, PeerTrust::OperatorApp));",
            "            | PeerTrust::OperatorApp",
        ] {
            assert!(is_pattern_use(pattern, T), "should be a pattern use: {pattern}");
        }
        for construction in [
            "        PeerTrust::OperatorApp",
            "        let t = PeerTrust::OperatorApp;",
            "        trust: PeerTrust::OperatorApp,",
            "            Some(_) => PeerTrust::OperatorApp,",
            "        return PeerTrust::OperatorApp;",
        ] {
            assert!(!is_pattern_use(construction, T), "should be a construction: {construction}");
        }
    }
}
