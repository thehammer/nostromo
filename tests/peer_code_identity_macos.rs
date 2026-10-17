//! The real code-identity check (AP1b), against real signed processes.
//!
//! These tests compile a tiny C client, sign copies of it the ways that
//! matter (`codesign -s -`, with and without the hardened runtime, with
//! `get-task-allow`, inside a fake `Nostromo.app` bundle), pin one of them,
//! and point [`MacPeerVerifier`] (and once, the whole daemon) at a socket the
//! client connected to. Nothing touches the installed app, `~/.nostromo` or the
//! user's daemon: every file and socket lives in a temp dir.
//!
//! They need `cc`, `codesign` and `lipo` (Xcode command-line tools). If those
//! are missing the tests FAIL, loudly; they never skip.
//!
//! The helper (`helper.c` below), by first argument:
//!
//! * `client SOCK FRAMES ACTION [EXEC]`: connect to `SOCK`, write the bytes of
//!   file `FRAMES` (unless `-`), then
//!   * `hold`: copy whatever the socket delivers to stdout until EOF;
//!   * `exec`: `execv(EXEC, {EXEC, "hold", fd})` straight away;
//!   * `goexec`: wait for one byte, then `execv(EXEC, {EXEC, "holdw", fd})`;
//!   * `gofork`: wait for one byte, fork; the child writes `c` and holds, the
//!     parent waits for the child.
//! * `hold FD` / `holdw FD`: (after an exec) hold the inherited socket;
//!   `holdw` first writes `b`.
//!
//! Every helper exits when the socket reaches EOF, so dropping the test's end
//! of a connection reaps forked grandchildren too; direct children are also
//! killed on drop.

#![cfg(target_os = "macos")]

use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use nostromo::ipc::{
    decisions::DecisionRegistry,
    peer_verify::{
        audit_token, still_same_operator, verify_code, CodeIdentity, MacPeerVerifier, OperatorPin, PeerInfo,
        PeerVerifier, UnverifiedReason, APP_BUNDLE_ID, INSTALLED_APP_EXE, PIN_FILE_NAME,
    },
    protocol::{ClientMsg, DecisionChoice, ServerMsg, Topic, PROTOCOL_VERSION},
    server::Server,
    PtyManager, SessionManager,
};

const HELPER_C: &str = r#"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef VARIANT
#define VARIANT "plain"
#endif
/* Distinct per build, so each variant has its own cdhash. */
volatile const char variant[] = "nostromo-test-helper-" VARIANT;

static void die(const char *what) {
    fprintf(stderr, "helper(%s): %s: %s\n", (const char *)variant, what, strerror(errno));
    exit(2);
}

static void write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) { if (errno == EINTR) continue; die("write"); }
        buf += n; len -= (size_t)n;
    }
}

static void hold(int fd) {
    char buf[65536];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) exit(0);
        fwrite(buf, 1, (size_t)n, stdout);
        fflush(stdout);
    }
}

static void wait_go(int fd) {
    char c;
    ssize_t n;
    do { n = read(fd, &c, 1); } while (n < 0 && errno == EINTR);
    if (n != 1) exit(0);
}

static void exec_hold(const char *path, const char *mode, int fd) {
    char fdstr[16];
    snprintf(fdstr, sizeof fdstr, "%d", fd);
    char *const args[] = {(char *)path, (char *)mode, fdstr, NULL};
    execv(path, args);
    die("execv");
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "hold") == 0) hold(atoi(argv[2]));
    if (argc >= 3 && strcmp(argv[1], "holdw") == 0) {
        int fd = atoi(argv[2]);
        write_all(fd, "b", 1);
        hold(fd);
    }
    if (argc < 5 || strcmp(argv[1], "client") != 0) {
        fprintf(stderr, "usage: helper client SOCK FRAMES ACTION [EXEC] | hold FD | holdw FD\n");
        return 64;
    }
    const char *sock = argv[2], *frames = argv[3], *action = argv[4];
    const char *exec_path = argc >= 6 ? argv[5] : NULL;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) die("socket");
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(sock) >= sizeof addr.sun_path) { errno = ENAMETOOLONG; die("socket path"); }
    strcpy(addr.sun_path, sock);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) die("connect");

    if (strcmp(frames, "-") != 0) {
        int in = open(frames, O_RDONLY);
        if (in < 0) die("open frames");
        char buf[65536];
        ssize_t n;
        while ((n = read(in, buf, sizeof buf)) > 0) write_all(fd, buf, (size_t)n);
        close(in);
    }

    if (strcmp(action, "hold") == 0) hold(fd);
    if (strcmp(action, "exec") == 0 && exec_path) exec_hold(exec_path, "hold", fd);
    if (strcmp(action, "goexec") == 0 && exec_path) { wait_go(fd); exec_hold(exec_path, "holdw", fd); }
    if (strcmp(action, "gofork") == 0) {
        wait_go(fd);
        pid_t child = fork();
        if (child < 0) die("fork");
        if (child == 0) { write_all(fd, "c", 1); hold(fd); }
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        return 0;
    }
    fprintf(stderr, "helper: unknown action %s\n", action);
    return 64;
}
"#;

const GET_TASK_ALLOW_ENTITLEMENTS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
"#;

// ── building and signing the helpers ─────────────────────────────────────────

/// The signed helper binaries, built once per test process.
struct Helpers {
    /// `-i com.hammer.nostromo -o runtime`: the one the tests pin.
    pinned: PathBuf,
    /// Another build (another cdhash), `-i com.example.unpinned -o runtime`.
    unpinned: PathBuf,
    /// Another build, signed `-i com.hammer.nostromo -o runtime` as the main
    /// executable of `Nostromo.app` whose `Info.plist` claims the app's id.
    fake_bundle_exe: PathBuf,
    /// Another build, `-i com.hammer.nostromo` without the hardened runtime.
    no_runtime: PathBuf,
    /// Another build, `-i com.hammer.nostromo -o runtime` + `get-task-allow`.
    get_task_allow: PathBuf,
    /// Another build (another cdhash), `-i com.hammer.nostromo -o runtime`:
    /// passes every code check except being the pinned cdhash. Stands for an
    /// attacker's own client signed with the app's identifier.
    impostor: PathBuf,
}

fn run(cmd: &mut Command) -> std::process::Output {
    let shown = format!("{cmd:?}");
    let out = cmd
        .output()
        .unwrap_or_else(|e| panic!("cannot run {shown}: {e} (these tests need the Xcode command-line tools)"));
    assert!(
        out.status.success(),
        "{shown} failed ({}):\nstdout: {}\nstderr: {}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

fn compile(dir: &Path, variant: &str, out: &Path) {
    let src = dir.join("helper.c");
    if !src.exists() {
        fs::write(&src, HELPER_C).unwrap();
    }
    run(Command::new("cc")
        .arg("-O0")
        .arg(format!("-DVARIANT=\"{variant}\""))
        .arg("-o")
        .arg(out)
        .arg(&src));
}

fn codesign(path: &Path, identifier: &str, runtime: bool, entitlements: Option<&Path>) {
    let mut cmd = Command::new("codesign");
    cmd.args(["--force", "-s", "-", "-i", identifier]);
    if runtime {
        cmd.args(["-o", "runtime"]);
    }
    if let Some(ent) = entitlements {
        cmd.arg("--entitlements").arg(ent);
    }
    run(cmd.arg(path));
}

fn helpers() -> &'static Helpers {
    static HELPERS: OnceLock<Helpers> = OnceLock::new();
    HELPERS.get_or_init(|| {
        let root = Path::new(env!("CARGO_TARGET_TMPDIR"));
        // Sweep the helpers of earlier runs whose process is gone.
        for entry in fs::read_dir(root).into_iter().flatten().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(pid) = name.strip_prefix("peer_code_identity_macos-").and_then(|p| p.parse::<i32>().ok()) else {
                continue;
            };
            // SAFETY: kill with signal 0 only probes for the process.
            let gone = unsafe { libc::kill(pid, 0) } != 0
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
            if gone {
                let _ = fs::remove_dir_all(entry.path());
            }
        }
        let dir = root.join(format!("peer_code_identity_macos-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let pinned = dir.join("pinned-helper");
        compile(&dir, "pinned", &pinned);
        codesign(&pinned, APP_BUNDLE_ID, true, None);

        let unpinned = dir.join("unpinned-helper");
        compile(&dir, "unpinned", &unpinned);
        codesign(&unpinned, "com.example.unpinned", true, None);

        let app = dir.join("Fake/Nostromo.app");
        fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        fs::write(
            app.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                 <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
                 <plist version=\"1.0\"><dict>\
                 <key>CFBundleIdentifier</key><string>{APP_BUNDLE_ID}</string>\
                 <key>CFBundleExecutable</key><string>Nostromo</string>\
                 <key>CFBundlePackageType</key><string>APPL</string>\
                 </dict></plist>\n"
            ),
        )
        .unwrap();
        let fake_bundle_exe = app.join("Contents/MacOS/Nostromo");
        compile(&dir, "fake-bundle", &fake_bundle_exe);
        codesign(&app, APP_BUNDLE_ID, true, None);

        let no_runtime = dir.join("no-runtime-helper");
        compile(&dir, "no-runtime", &no_runtime);
        codesign(&no_runtime, APP_BUNDLE_ID, false, None);

        let get_task_allow = dir.join("get-task-allow-helper");
        compile(&dir, "get-task-allow", &get_task_allow);
        let ent = dir.join("get-task-allow.plist");
        fs::write(&ent, GET_TASK_ALLOW_ENTITLEMENTS).unwrap();
        codesign(&get_task_allow, APP_BUNDLE_ID, true, Some(&ent));

        let impostor = dir.join("impostor-helper");
        compile(&dir, "impostor", &impostor);
        codesign(&impostor, APP_BUNDLE_ID, true, None);

        Helpers { pinned, unpinned, fake_bundle_exe, no_runtime, get_task_allow, impostor }
    })
}

/// The cdhash of every architecture slice of `path`, as `codesign -dvvv`
/// reports it.
fn cdhashes(path: &Path) -> Vec<String> {
    let archs = run(Command::new("lipo").arg("-archs").arg(path));
    let archs = String::from_utf8(archs.stdout).unwrap();
    let mut out = Vec::new();
    for arch in archs.split_whitespace() {
        let shown = run(Command::new("codesign").args(["-dvvv", "--arch", arch]).arg(path));
        // codesign -d prints to stderr.
        let text = String::from_utf8_lossy(&shown.stderr).into_owned() + &String::from_utf8_lossy(&shown.stdout);
        let hash = text
            .lines()
            .find_map(|l| l.strip_prefix("CDHash="))
            .unwrap_or_else(|| panic!("no CDHash= line for {} ({arch}):\n{text}", path.display()));
        out.push(hash.trim().to_string());
    }
    assert!(!out.is_empty(), "lipo found no architectures in {}", path.display());
    out
}

/// A 0600 pin at `<dir>/operator-app.pin` naming `identifier` and the
/// cdhashes of `binary`.
fn write_pin_for(dir: &Path, identifier: &str, binary: &Path) -> PathBuf {
    let mut text = format!("# test pin\nidentifier {identifier}\n");
    for hash in cdhashes(binary) {
        text.push_str(&format!("cdhash {hash}\n"));
    }
    let path = dir.join(PIN_FILE_NAME);
    fs::write(&path, text).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    path
}

// ── running them ─────────────────────────────────────────────────────────────

/// A running helper; killed (and reaped) on drop.
struct Helper {
    child: Child,
    stdout: PathBuf,
}

impl Helper {
    fn spawn(binary: &Path, dir: &Path, socket: &Path, frames: Option<&Path>, action: &str, exec: Option<&Path>) -> Self {
        let stdout = dir.join(format!("helper-{}.out", uniq()));
        let mut cmd = Command::new(binary);
        cmd.arg("client").arg(socket).arg(frames.map_or(PathBuf::from("-"), Path::to_path_buf)).arg(action);
        if let Some(exec) = exec {
            cmd.arg(exec);
        }
        let child = cmd
            .stdin(Stdio::null())
            .stdout(fs::File::create(&stdout).unwrap())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap_or_else(|e| panic!("cannot start {}: {e}", binary.display()));
        Helper { child, stdout }
    }

    fn pid(&self) -> i32 {
        self.child.id() as i32
    }

    fn output(&self) -> Vec<u8> {
        fs::read(&self.stdout).unwrap_or_default()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn uniq() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    N.fetch_add(1, Ordering::SeqCst)
}

/// Accept the helper's connection, failing (not hanging) if it never comes.
fn accept(listener: &UnixListener, helper: &mut Helper) -> UnixStream {
    listener.set_nonblocking(true).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
                return stream;
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if let Some(status) = helper.child.try_wait().unwrap() {
                    panic!("the helper exited ({status}) before connecting");
                }
                assert!(Instant::now() < deadline, "the helper did not connect within 10 s");
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => panic!("accept: {e}"),
        }
    }
}

fn read_byte(stream: &mut UnixStream, what: &str) -> u8 {
    let mut b = [0u8; 1];
    stream.read_exact(&mut b).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
    b[0]
}

/// A listener on a fresh temp socket. Returns (tempdir, listener, socket path).
fn listen() -> (tempfile::TempDir, UnixListener, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("s.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    (dir, listener, socket)
}

fn bytes_file(dir: &Path, bytes: &[u8]) -> PathBuf {
    let path = dir.join(format!("frames-{}.bin", uniq()));
    fs::write(&path, bytes).unwrap();
    path
}

/// Connect `binary` (it writes `a`, then holds), and return what the verifier
/// makes of it, checking code against a pin for `pin_binary`. The verifier's
/// installed-app path is `binary` itself: the path binding is not in play.
fn verify_helper(binary: &Path, pin_binary: &Path) -> PeerInfo {
    verify_helper_at(binary, pin_binary, binary)
}

/// As [`verify_helper`], with the verifier told that the installed app lives
/// at `app_exe` (the path binding).
fn verify_helper_at(binary: &Path, pin_binary: &Path, app_exe: &Path) -> PeerInfo {
    inspect_helper(binary, pin_binary, |pin| MacPeerVerifier::with_app_exe(pin, app_exe))
}

/// As [`verify_helper_at`], for a verifier the caller builds from the pin's path
/// (e.g. [`MacPeerVerifier::new`], which uses the real installed-app path).
fn inspect_helper(binary: &Path, pin_binary: &Path, verifier: impl FnOnce(PathBuf) -> MacPeerVerifier) -> PeerInfo {
    let (dir, listener, socket) = listen();
    let pin = write_pin_for(dir.path(), APP_BUNDLE_ID, pin_binary);
    let mut helper = Helper::spawn(binary, dir.path(), &socket, Some(&bytes_file(dir.path(), b"a")), "hold", None);
    let mut stream = accept(&listener, &mut helper);
    assert_eq!(read_byte(&mut stream, "the helper's first byte"), b'a');
    let info = verifier(pin).inspect(stream.as_fd(), true).expect("the helper is alive and identifiable");
    assert_eq!(info.pid, helper.pid(), "the peer is the helper");
    info
}

fn unverified(reason: UnverifiedReason) -> CodeIdentity {
    CodeIdentity::Unverified { reason }
}

// ── the cases ────────────────────────────────────────────────────────────────

#[test]
fn the_pinned_helper_is_pinned_as_the_app() {
    let h = helpers();
    let info = verify_helper(&h.pinned, &h.pinned);
    assert_eq!(info.code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
    assert_ne!(info.pidversion, 0);
    assert_eq!(info.path_bundle_id, None, "the helper is in no bundle");
}

#[test]
fn a_fake_bundle_claiming_the_apps_id_fails_the_requirement() {
    let h = helpers();
    // Same identifier, the right Info.plist, a bundle named Nostromo.app; but
    // another cdhash than the pinned one.
    let info = verify_helper(&h.fake_bundle_exe, &h.pinned);
    assert_eq!(
        info.path_bundle_id.as_deref(),
        Some(APP_BUNDLE_ID),
        "the plist does claim the app's id (diagnostic only)"
    );
    assert_eq!(info.code, unverified(UnverifiedReason::RequirementFailed));
}

#[test]
fn a_binary_with_another_identifier_fails_the_requirement() {
    let h = helpers();
    let info = verify_helper(&h.unpinned, &h.pinned);
    assert_eq!(info.code, unverified(UnverifiedReason::RequirementFailed));
}

#[test]
fn pinned_code_without_the_hardened_runtime_is_refused() {
    let h = helpers();
    let info = verify_helper(&h.no_runtime, &h.no_runtime);
    assert_eq!(info.code, unverified(UnverifiedReason::NoRuntime));
}

#[test]
fn pinned_code_that_allows_a_debugger_to_attach_is_refused() {
    let h = helpers();
    let info = verify_helper(&h.get_task_allow, &h.get_task_allow);
    assert_eq!(info.code, unverified(UnverifiedReason::GetTaskAllow));
}

// ── the installed-path binding ───────────────────────────────────────────────
//
// The pin file is user-writable, so a cdhash in it must not by itself make a
// binary "the app": pinned code is accepted only when it runs from the
// installed app's path.

#[test]
fn pinned_code_running_from_another_existing_file_than_the_installed_app_is_refused_as_wrong_path() {
    let h = helpers();
    // The installed app is (some other file at) h.unpinned; the pinned helper runs from elsewhere.
    let info = verify_helper_at(&h.pinned, &h.pinned, &h.unpinned);
    assert_eq!(info.code, unverified(UnverifiedReason::WrongPath));
}

#[test]
fn pinned_code_is_refused_as_wrong_path_when_nothing_is_installed_at_the_expected_path() {
    let h = helpers();
    let nowhere = tempfile::tempdir().unwrap();
    let missing = nowhere.path().join("Nostromo.app/Contents/MacOS/Nostromo");
    assert!(!missing.exists());
    let info = verify_helper_at(&h.pinned, &h.pinned, &missing);
    assert_eq!(info.code, unverified(UnverifiedReason::WrongPath));
}

#[test]
fn rewriting_the_pin_to_name_an_attackers_binary_does_not_make_it_the_app_when_it_is_not_at_the_installed_path() {
    let h = helpers();
    // The attacker signs its own client with the app's identifier and writes ITS cdhash
    // into the (user-writable) pin: the code check alone passes...
    let at_its_own_path = verify_helper(&h.impostor, &h.impostor);
    assert_eq!(
        at_its_own_path.code,
        CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() },
        "precondition: with the path binding out of play the rewritten pin does match"
    );
    // ...but the real app lives elsewhere (the installed path), so it is refused.
    let info = verify_helper_at(&h.impostor, &h.impostor, &h.pinned);
    assert_eq!(info.code, unverified(UnverifiedReason::WrongPath));
}

#[test]
fn residual_risk_an_attacker_who_also_replaces_the_installed_app_and_rewrites_the_pin_is_accepted() {
    // Documented in docs/operator-app-trust.md: the pin and the path are not a root of
    // trust. Replace the binary AT the installed path AND rewrite the pin to match, and
    // the verifier (by design) calls it the app. This test pins that boundary: if it ever
    // starts failing, the doc's residual-risk section needs updating too.
    let h = helpers();
    let info = verify_helper_at(&h.impostor, &h.impostor, &h.impostor);
    assert_eq!(info.code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
}

#[test]
fn a_binary_with_the_apps_identifier_but_another_cdhash_fails_the_requirement_even_at_the_installed_path() {
    let h = helpers();
    // The pin is the genuine app's (original pin); the impostor sits at the expected path
    // (it replaced the installed binary) but its cdhash is not the pinned one.
    let info = verify_helper_at(&h.impostor, &h.pinned, &h.impostor);
    assert_eq!(info.code, unverified(UnverifiedReason::RequirementFailed));
}

#[test]
fn the_installed_app_may_be_named_through_a_symlink() {
    let h = helpers();
    let links = tempfile::tempdir().unwrap();
    let link = links.path().join("Nostromo-link");
    std::os::unix::fs::symlink(&h.pinned, &link).unwrap();
    let info = verify_helper_at(&h.pinned, &h.pinned, &link);
    assert_eq!(info.code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
}

#[test]
fn a_symlink_to_a_different_binary_is_not_the_installed_app() {
    let h = helpers();
    let links = tempfile::tempdir().unwrap();
    let link = links.path().join("Nostromo-link");
    std::os::unix::fs::symlink(&h.unpinned, &link).unwrap();
    let info = verify_helper_at(&h.pinned, &h.pinned, &link);
    assert_eq!(info.code, unverified(UnverifiedReason::WrongPath));
}

// ── the directory-swap race ──────────────────────────────────────────────────
//
// The path the kernel reports for a peer is a snapshot; resolving it through the
// filesystem *later* (canonicalize) is a second look at a name the peer controls.
// A same-uid attacker needs no rights for this: run a pinned-cdhash client from
// `<dir>/x/Nostromo`, and keep `renamex_np(RENAME_SWAP)`-ing `<dir>/x` with a
// symlink to the installed app's directory. Whenever the verifier resolves the
// stored name while the symlink is in place, it lands on the installed binary.

/// Exchanges `a` and `b` (a directory and a symlink) atomically, over and over,
/// until `stop`. Returns how many swaps it made.
fn swap_loop(a: PathBuf, b: PathBuf, stop: Arc<AtomicBool>) -> std::thread::JoinHandle<u64> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    std::thread::spawn(move || {
        let (a, b) = (CString::new(a.as_os_str().as_bytes()).unwrap(), CString::new(b.as_os_str().as_bytes()).unwrap());
        let mut swaps = 0u64;
        while !stop.load(Ordering::Relaxed) {
            // SAFETY: both are valid NUL-terminated paths for the duration of the call.
            let rc = unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_SWAP) };
            assert_eq!(rc, 0, "RENAME_SWAP failed: {}", std::io::Error::last_os_error());
            swaps += 1;
        }
        swaps
    })
}

#[test]
fn swapping_the_attackers_directory_with_a_symlink_to_the_installed_app_never_makes_it_the_app() {
    const ATTEMPTS: u32 = 300;
    let h = helpers();
    let root = tempfile::tempdir().unwrap();

    // The "installed app": a copy of the pinned helper in its own directory. The attacker's
    // client is ANOTHER copy of it (same cdhash, so the code check and the pin cannot tell
    // them apart: only where it is and which file it is can).
    let installed_dir = root.path().join("installed");
    let attacker_dir = root.path().join("x");
    fs::create_dir(&installed_dir).unwrap();
    fs::create_dir(&attacker_dir).unwrap();
    let installed = installed_dir.join("Nostromo");
    let attacker = attacker_dir.join("Nostromo");
    fs::copy(&h.pinned, &installed).unwrap();
    fs::copy(&h.pinned, &attacker).unwrap();
    let trap = root.path().join("trap");
    std::os::unix::fs::symlink(&installed_dir, &trap).unwrap();

    // Preconditions, so a pass is not vacuous: the installed copy IS accepted at the
    // installed path, and the attacker's copy, standing still, is refused.
    let genuine = verify_helper_at(&installed, &installed, &installed);
    assert_eq!(genuine.code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
    let standing_still = verify_helper_at(&attacker, &installed, &installed);
    assert_eq!(standing_still.code, unverified(UnverifiedReason::WrongPath));

    // The race: the attacker's client is connected; the directory it runs from is swapped
    // with the symlink in a tight loop while the daemon inspects it again and again.
    let (dir, listener, socket) = listen();
    let verifier = MacPeerVerifier::with_app_exe(write_pin_for(dir.path(), APP_BUNDLE_ID, &h.pinned), &installed);
    let mut helper = Helper::spawn(&attacker, dir.path(), &socket, Some(&bytes_file(dir.path(), b"a")), "hold", None);
    let mut stream = accept(&listener, &mut helper);
    assert_eq!(read_byte(&mut stream, "the attacker's first byte"), b'a');

    let stop = Arc::new(AtomicBool::new(false));
    let swapper = swap_loop(attacker_dir.clone(), trap.clone(), Arc::clone(&stop));
    let mut pinned = 0;
    let mut outcomes = Vec::new();
    for attempt in 0..ATTEMPTS {
        // Alternate the Hello-time inspection and the answer-time re-check.
        let info = if attempt % 2 == 0 {
            verifier.inspect(stream.as_fd(), true)
        } else {
            verifier.reinspect(stream.as_fd(), &standing_still)
        }
        .expect("the attacker is alive and identifiable");
        assert_eq!(info.pid, helper.pid());
        if matches!(info.code, CodeIdentity::Pinned { .. }) {
            pinned += 1;
        }
        outcomes.push(info.code);
    }
    stop.store(true, Ordering::Relaxed);
    let swaps = swapper.join().unwrap();

    assert!(swaps >= u64::from(ATTEMPTS), "the swap loop must really have run alongside ({swaps} swaps)");
    assert_eq!(pinned, 0, "{pinned} of {ATTEMPTS} inspections called the attacker the installed app");
    assert!(
        outcomes.iter().all(|code| *code == unverified(UnverifiedReason::WrongPath)),
        "every inspection must refuse as WrongPath: {outcomes:?}"
    );
}

#[test]
#[allow(clippy::redundant_closure)] // `new` is generic over `Into<PathBuf>`; the closure pins the argument type
fn by_default_the_app_must_run_from_the_installed_applications_path() {
    let h = helpers();
    let dir = tempfile::tempdir().unwrap();
    let verifier = MacPeerVerifier::new(dir.path().join(PIN_FILE_NAME));
    assert_eq!(verifier.app_exe(), Path::new(INSTALLED_APP_EXE));
    assert_eq!(INSTALLED_APP_EXE, "/Applications/Nostromo.app/Contents/MacOS/Nostromo");

    // A correctly signed and pinned helper that is run from a temp dir (not from
    // /Applications) is not the app: it used to be Pinned wherever it ran.
    let info = inspect_helper(&h.pinned, &h.pinned, |pin| MacPeerVerifier::new(pin));
    assert_eq!(info.code, unverified(UnverifiedReason::WrongPath));
}

#[test]
fn a_token_taken_before_an_exec_names_no_code_afterwards_and_a_fresh_one_names_the_new_image() {
    let h = helpers();
    let (dir, listener, socket) = listen();
    let pin = OperatorPin::load(&write_pin_for(dir.path(), APP_BUNDLE_ID, &h.pinned)).unwrap();
    let mut helper =
        Helper::spawn(&h.unpinned, dir.path(), &socket, Some(&bytes_file(dir.path(), b"a")), "goexec", Some(&h.pinned));
    let mut stream = accept(&listener, &mut helper);
    assert_eq!(read_byte(&mut stream, "the unpinned image's byte"), b'a');

    let before = audit_token(stream.as_fd()).expect("token before the exec");
    assert_eq!(before.pid(), helper.pid());
    assert_eq!(verify_code(&before, &pin), unverified(UnverifiedReason::RequirementFailed), "before: the unpinned image");

    stream.write_all(b"g").unwrap();
    assert_eq!(read_byte(&mut stream, "the exec'd image's byte"), b'b');

    let after = audit_token(stream.as_fd()).expect("token after the exec");
    assert_eq!(after.pid(), before.pid(), "exec keeps the pid");
    assert_ne!(after.pidversion(), before.pidversion(), "exec changes the pidversion");
    assert_eq!(
        verify_code(&before, &pin),
        unverified(UnverifiedReason::NoSuchCode),
        "the old token must name no running code once the process exec'd"
    );
    assert_eq!(verify_code(&after, &pin), CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
}

#[test]
fn a_forked_child_writing_on_the_apps_socket_is_another_peer() {
    let h = helpers();
    let (dir, listener, socket) = listen();
    let verifier = MacPeerVerifier::with_app_exe(write_pin_for(dir.path(), APP_BUNDLE_ID, &h.pinned), &h.pinned);
    let mut helper = Helper::spawn(&h.pinned, dir.path(), &socket, Some(&bytes_file(dir.path(), b"a")), "gofork", None);
    let mut stream = accept(&listener, &mut helper);
    assert_eq!(read_byte(&mut stream, "the app's byte"), b'a');

    let accepted = verifier.inspect(stream.as_fd(), true).expect("the app");
    assert_eq!(accepted.pid, helper.pid());
    assert_eq!(accepted.code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });

    stream.write_all(b"g").unwrap();
    assert_eq!(read_byte(&mut stream, "the forked child's byte"), b'c');

    let now = verifier.reinspect(stream.as_fd(), &accepted).expect("the child");
    // Reap the grandchild even if an assertion below fails.
    let child_pid = now.pid;
    struct KillOnDrop(i32);
    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            // SAFETY: kill has no memory-safety preconditions.
            unsafe { libc::kill(self.0, libc::SIGKILL) };
        }
    }
    let _reap = (child_pid != accepted.pid && child_pid > 1).then(|| KillOnDrop(child_pid));

    assert_ne!(now.pid, accepted.pid, "the socket's peer is now the child that wrote last");
    assert!(!still_same_operator(&accepted, Some(&now)), "a forked fd sharer is not the verified operator");
}

#[test]
fn one_code_check_with_resource_validation_takes_well_under_two_seconds() {
    let h = helpers();
    let (dir, listener, socket) = listen();
    let pin = OperatorPin::load(&write_pin_for(dir.path(), APP_BUNDLE_ID, &h.pinned)).unwrap();
    let mut helper = Helper::spawn(&h.pinned, dir.path(), &socket, Some(&bytes_file(dir.path(), b"a")), "hold", None);
    let mut stream = accept(&listener, &mut helper);
    read_byte(&mut stream, "the helper's byte");
    let token = audit_token(stream.as_fd()).unwrap();

    let started = Instant::now();
    let code = verify_code(&token, &pin);
    let first = started.elapsed();
    let started = Instant::now();
    let _ = verify_code(&token, &pin);
    let second = started.elapsed();

    eprintln!(
        "verify_code: first call {:.2} ms, second call {:.2} ms",
        first.as_secs_f64() * 1e3,
        second.as_secs_f64() * 1e3
    );
    assert_eq!(code, CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() });
    assert!(first < Duration::from_secs(2), "one verify_code took {first:?}");
}

// ── the whole daemon: buffered bytes, then exec the pinned app ───────────────

/// The real verifier, run late: `inspect` waits first, so the helper has
/// certainly `exec`'d the pinned image by the time the daemon verifies it (the
/// interesting case: verification passes). Counts answer-time re-checks.
struct LateVerifier {
    inner: MacPeerVerifier,
    delay: Duration,
    reinspects: std::sync::atomic::AtomicUsize,
}

impl PeerVerifier for LateVerifier {
    fn inspect(&self, fd: std::os::fd::BorrowedFd<'_>, verify_code: bool) -> Option<PeerInfo> {
        std::thread::sleep(self.delay);
        self.inner.inspect(fd, verify_code)
    }

    fn reinspect(&self, fd: std::os::fd::BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
        self.reinspects.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.reinspect(fd, accepted)
    }
}

fn frame(msg: &ClientMsg) -> Vec<u8> {
    let body = serde_json::to_vec(msg).unwrap();
    let mut out = (body.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(&body);
    out
}

fn parse_frames(mut bytes: &[u8]) -> Vec<ServerMsg> {
    let mut out = Vec::new();
    while bytes.len() >= 4 {
        let len = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
        if bytes.len() < 4 + len {
            break;
        }
        if let Ok(msg) = serde_json::from_slice(&bytes[4..4 + len]) {
            out.push(msg);
        }
        bytes = &bytes[4 + len..];
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_answer_buffered_before_execing_the_pinned_app_is_refused_for_lacking_the_nonce() {
    let h = helpers();
    let tmp = tempfile::tempdir().unwrap();
    let socket_path = tmp.path().join("d.sock");
    let pin = write_pin_for(tmp.path(), APP_BUNDLE_ID, &h.pinned);
    let verifier = Arc::new(LateVerifier {
        inner: MacPeerVerifier::with_app_exe(pin, &h.pinned),
        delay: Duration::from_millis(750),
        reinspects: Default::default(),
    });
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
    let server = Server::bind(
        &socket_path,
        Arc::new(Mutex::new(PtyManager::new())),
        Arc::new(Mutex::new(SessionManager::with_store_path(tmp.path().join("sessions.json")))),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
        Arc::clone(&verifier) as Arc<dyn PeerVerifier>,
        false,
    )
    .expect("bind");
    decisions.lock().unwrap().configure_broadcast(server.tx.clone());

    // The agent's decision, already pending (so its id is known to the attacker).
    let choices = vec![DecisionChoice { id: "yes".into(), label: "Yes".into(), detail: None, is_default: false }];
    let (request_id, mut rx, _) =
        decisions.lock().unwrap().submit("cody-x".into(), "Proceed?".into(), None, choices, None);

    // Everything an app would say, written by the unpinned image before the
    // daemon has verified anyone, so it cannot carry a nonce.
    let mut bytes = frame(&ClientMsg::Hello {
        client_id: "buffered-attack".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: Some("mac_app".into()),
    });
    bytes.extend(frame(&ClientMsg::Subscribe { topics: vec![Topic::Decision], renders_decisions: false }));
    bytes.extend(frame(&ClientMsg::DecisionAnswer {
        request_id: request_id.clone(),
        choice_id: Some("yes".into()),
        operator_nonce: None,
    }));
    bytes.extend(frame(&ClientMsg::Ping));
    let frames_file = bytes_file(tmp.path(), &bytes);
    let helper = Helper::spawn(&h.unpinned, tmp.path(), &socket_path, Some(&frames_file), "exec", Some(&h.pinned));

    // Wait until the daemon has said what it will (the Pong after the answer).
    let deadline = Instant::now() + Duration::from_secs(15);
    let frames = loop {
        let frames = parse_frames(&helper.output());
        if frames.iter().any(|m| matches!(m, ServerMsg::Pong)) {
            break frames;
        }
        assert!(Instant::now() < deadline, "no Pong from the daemon within 15 s; got {frames:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };

    // The interesting branch: by the time it was verified the peer WAS the
    // pinned image, so the daemon took it for the operator app...
    let welcome_nonce = frames.iter().find_map(|m| match m {
        ServerMsg::Welcome { operator_nonce, .. } => Some(operator_nonce.clone()),
        _ => None,
    });
    assert!(
        matches!(welcome_nonce, Some(Some(_))),
        "the exec'd pinned image must have been verified as the operator app (Welcome with a nonce): {frames:?}"
    );
    assert!(decisions.lock().unwrap().has_operator(), "it counts as an operator");

    // ...and the answer it had buffered is refused all the same: no nonce.
    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::Error { message } if message.starts_with("not_operator_app"))),
        "the buffered answer must be refused with not_operator_app: {frames:?}"
    );
    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::DecisionResolved { .. })), "{frames:?}");
    assert_eq!(decisions.lock().unwrap().active_request_id("cody-x"), Some(request_id), "still pending");
    assert!(
        matches!(rx.try_recv(), Err(tokio::sync::oneshot::error::TryRecvError::Empty)),
        "the asker must not be answered"
    );
    assert_eq!(
        verifier.reinspects.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "the missing nonce refuses before any answer-time re-check"
    );
    drop(helper);
}
