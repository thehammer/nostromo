//! Who is on the other end of a Unix-socket connection, and is it the
//! Nostromo Mac app?
//!
//! The daemon socket is mode 0600, so every peer runs as the user. That still
//! includes an agent's own Bash, which must not be able to answer the agent's
//! own decision. So a Unix connection is the operator app
//! ([`PeerTrust::OperatorApp`]) only when **both** hold:
//!
//! - its `Hello` claimed `client_kind = "mac_app"`, and
//! - the **running code** behind the socket is the pinned, installed app. The
//!   kernel's audit token for the peer (`LOCAL_PEERTOKEN`) names the process
//!   image; the Security framework looks the code up **by that token** (never
//!   by pid or path), checks it against the requirement
//!   `identifier "<id>" and (cdhash H"<a>" or …)` built from the pin file
//!   `make mac-install` writes ([`OperatorPin`]), and reads the kernel's status
//!   flags for it: it must be valid and run under the hardened runtime, the
//!   kernel must be **enforcing** that runtime (`CS_HARD`, `CS_KILL` and
//!   `CS_ENFORCEMENT`; absent when SIP is disabled), and it must be neither
//!   debuggable (`get-task-allow`) nor being debugged.
//!
//! Where the executable lives, and what an `Info.plist` next to it says, no
//! longer matter: a fake bundle claiming the Nostromo bundle id has another
//! cdhash. `path_bundle_id` is still read, for a diagnostic only.
//!
//! The socket's peer is the **last process to use it**, not the one that
//! connected, and a process can `exec` another image under the same pid. So an
//! answer is accepted only when it carries the per-connection nonce the daemon
//! issued after verification, and a fresh inspection at answer time still sees
//! the same process (see [`still_same_operator`]).
//!
//! Residual risks (closable only with a Developer ID Team ID and a root-owned
//! install): a same-uid attacker can replace `/Applications/Nostromo.app`
//! **and** rewrite the pin to match, replace the daemon or its launchd plist,
//! or post OS-level events into the app if its host holds Accessibility or
//! Input Monitoring permission. The pin is not a root of trust: it raises the
//! bar from "run a process" to "rewrite installed files". With SIP disabled
//! the kernel enforces no runtime, so the operator app cannot answer at all
//! ([`UnverifiedReason::RuntimeNotEnforced`]). See
//! `docs/operator-app-trust.md`.
//!
//! [`classify_peer`] is the **only** place that assigns `OperatorApp`.

use std::fmt;
use std::io::Read;
use std::os::fd::BorrowedFd;
use std::path::{Path, PathBuf};

use super::peer::PeerTrust;

/// The Nostromo app's bundle identifier.
pub const APP_BUNDLE_ID: &str = "com.hammer.nostromo";
/// The isolated QA instance's bundle identifier. Accepted only when the daemon
/// runs in QA mode (`NOSTROMO_QA_DAEMON=1`).
pub const QA_BUNDLE_ID: &str = "com.hammer.nostromo.qa";
/// The `Hello.client_kind` the Mac app sends.
pub const MAC_APP_CLIENT_KIND: &str = "mac_app";
/// The pin file's name, next to the daemon's socket.
pub const PIN_FILE_NAME: &str = "operator-app.pin";

/// What the daemon could learn about the process behind a Unix connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerInfo {
    /// The peer's pid, from its audit token.
    pub pid: i32,
    /// The kernel's per-image generation of `pid`: it changes when the process
    /// `exec`s. 0 when no audit token was available.
    pub pidversion: u32,
    /// The executable's path (`proc_pidpath`). Diagnostic only.
    pub exe: PathBuf,
    /// `CFBundleIdentifier` of the app bundle enclosing `exe`, if any.
    /// Diagnostic only (the "old app" warning); never a reason to trust.
    pub path_bundle_id: Option<String>,
    /// Whether the running code is the pinned operator app.
    pub code: CodeIdentity,
}

/// What the Security framework says about the code running behind a peer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodeIdentity {
    /// The running code satisfies the pin's requirement, under the hardened
    /// runtime, not debuggable and not being debugged.
    Pinned { identifier: String },
    Unverified { reason: UnverifiedReason },
}

/// Why a peer's code is not [`CodeIdentity::Pinned`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnverifiedReason {
    /// Not checked: the `Hello` did not claim to be the Mac app.
    NotChecked,
    /// The pin file is missing.
    NoPin,
    /// The pin file is malformed, not owned by the daemon's user, or group- or
    /// world-writable.
    BadPin,
    /// The socket gave no audit token.
    NoToken,
    /// No running code matches the token: the process exited or `exec`'d since.
    NoSuchCode,
    /// The code does not satisfy the pin's requirement (another identifier or
    /// cdhash).
    RequirementFailed,
    /// Not signed with the hardened runtime.
    NoRuntime,
    /// Signed with the hardened runtime, but the kernel does not enforce it
    /// (`CS_HARD`, `CS_KILL` or `CS_ENFORCEMENT` missing): System Integrity
    /// Protection is disabled, so the runtime blocks no injected library.
    RuntimeNotEnforced,
    /// Signed with `get-task-allow`: a debugger may attach.
    GetTaskAllow,
    /// A debugger is attached.
    Debugged,
    /// The kernel does not consider the code validly signed, or the dynamic
    /// signing information could not be read.
    NotValid,
    /// This platform has no code-signing check; nothing is ever pinned.
    Unsupported,
}

impl fmt::Display for UnverifiedReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

/// Resolves the process behind a Unix connection. Injected into
/// [`crate::ipc::Server::bind`] so tests can stand in for the Mac app.
pub trait PeerVerifier: Send + Sync {
    /// What is behind `fd` now. `verify_code` runs the code-signing check
    /// (only worth it when the `Hello` claimed to be the Mac app); without it
    /// `code` is `Unverified { NotChecked }`.
    fn inspect(&self, fd: BorrowedFd<'_>, verify_code: bool) -> Option<PeerInfo>;

    /// A fresh, fully verified inspection at answer time, for comparison with
    /// `accepted` by [`still_same_operator`]. A real verifier ignores
    /// `accepted` (the default); it exists so a test double can answer "the
    /// same peer as before" without knowing which connection `fd` is.
    fn reinspect(&self, fd: BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
        let _ = accepted;
        self.inspect(fd, true)
    }
}

/// The real verifier: the peer's audit token, then the code that token names,
/// checked against the pin at `pin_path`.
#[derive(Debug, Clone)]
pub struct MacPeerVerifier {
    pin_path: PathBuf,
}

impl MacPeerVerifier {
    /// A verifier that reads the pin from `pin_path` on every check, so a
    /// reinstall (which rewrites the pin) needs no daemon restart.
    pub fn new(pin_path: impl Into<PathBuf>) -> Self {
        Self { pin_path: pin_path.into() }
    }

    pub fn pin_path(&self) -> &Path {
        &self.pin_path
    }
}

impl PeerVerifier for MacPeerVerifier {
    fn inspect(&self, fd: BorrowedFd<'_>, verify: bool) -> Option<PeerInfo> {
        let token = audit_token(fd);
        let (pid, pidversion) = match &token {
            Some(token) => (token.pid(), token.pidversion()),
            None => (peer_pid(fd)?, 0),
        };
        let exe = exe_of(pid)?;
        let path_bundle_id = bundle_id_for_exe(&exe);
        let code = if !verify {
            CodeIdentity::Unverified { reason: UnverifiedReason::NotChecked }
        } else {
            match (&token, OperatorPin::load(&self.pin_path)) {
                (_, Err(reason)) => CodeIdentity::Unverified { reason },
                (None, Ok(_)) => CodeIdentity::Unverified { reason: no_token_reason() },
                (Some(token), Ok(pin)) => verify_code(token, &pin),
            }
        };
        Some(PeerInfo { pid, pidversion, exe, path_bundle_id, code })
    }
}

#[cfg(target_os = "macos")]
fn no_token_reason() -> UnverifiedReason {
    UnverifiedReason::NoToken
}

#[cfg(not(target_os = "macos"))]
fn no_token_reason() -> UnverifiedReason {
    UnverifiedReason::Unsupported
}

/// `CFBundleIdentifier` of the app bundle enclosing `exe`, when `exe` has the
/// shape `<X>.app/Contents/MacOS/<exe>` and the bundle's `Info.plist` reads.
/// Diagnostic only: anyone can write an `Info.plist`.
pub fn bundle_id_for_exe(exe: &Path) -> Option<String> {
    let info = app_bundle_of(exe)?.join("Contents").join("Info.plist");
    let plist = plist::Value::from_file(info).ok()?;
    plist.as_dictionary()?.get("CFBundleIdentifier")?.as_string().map(str::to_owned)
}

/// The trust of a Unix connection after its `Hello`. Pure: `info` is what the
/// verifier resolved (if anything), `client_kind` is the Hello's claim, and
/// `qa_mode` is whether the daemon accepts the QA instance's identifier.
///
/// `OperatorApp` iff the Hello claimed [`MAC_APP_CLIENT_KIND`] **and** the
/// peer's code is [`CodeIdentity::Pinned`] with identifier [`APP_BUNDLE_ID`]
/// (or [`QA_BUNDLE_ID`] in QA mode). Everything else is `LocalOther`.
pub fn classify_peer(info: Option<&PeerInfo>, client_kind: Option<&str>, qa_mode: bool) -> PeerTrust {
    let claims_app = client_kind == Some(MAC_APP_CLIENT_KIND);
    let is_app = info.is_some_and(|info| match &info.code {
        CodeIdentity::Pinned { identifier } => accepted_identifier(identifier, qa_mode),
        CodeIdentity::Unverified { .. } => false,
    });
    if claims_app && is_app {
        PeerTrust::OperatorApp
    } else {
        PeerTrust::LocalOther
    }
}

/// Whether a pinned identifier is one this daemon lets answer.
pub fn accepted_identifier(identifier: &str, qa_mode: bool) -> bool {
    identifier == APP_BUNDLE_ID || (qa_mode && identifier == QA_BUNDLE_ID)
}

/// Is the peer an answer-time inspection found (`now`) still the operator app
/// that was verified at `Hello` (`accepted`)?
///
/// True only when `now` exists, has the same pid **and** pidversion, and its
/// code is pinned with the same identifier.
///
/// Why both halves of the answer check are needed (spikes on macOS 26):
///
/// - A process can buffer `Hello` + `DecisionAnswer` and then `exec` the
///   genuine app under the same pid. The bytes written before the exec are
///   still readable after it, and `LOCAL_PEERTOKEN` then names the **new**
///   image, so the verification at `Hello` passes. Those buffered bytes cannot
///   hold the `operator_nonce`, which is issued only after verification, so the
///   nonce check refuses them.
/// - The kernel attributes the socket to the **last process to use it**:
///   `LOCAL_PEERPID`/`LOCAL_PEERTOKEN` followed a forked grandchild sharing the
///   fd once it wrote. So an answer written by a sibling sharing the genuine
///   app's socket shows up here as another pid, and one that then `exec`s the
///   genuine binary is still another pid than the one verified at `Hello`.
///   An `exec` by the verified process itself changes its pidversion.
///
/// Returns `bool`, never a trust: [`classify_peer`] stays the only mint.
pub fn still_same_operator(accepted: &PeerInfo, now: Option<&PeerInfo>) -> bool {
    let Some(now) = now else { return false };
    let (CodeIdentity::Pinned { identifier: was }, CodeIdentity::Pinned { identifier: is }) =
        (&accepted.code, &now.code)
    else {
        return false;
    };
    now.pid == accepted.pid && now.pidversion == accepted.pidversion && was == is
}

/// The warning a non-operator connection's `Welcome` is logged with, if it
/// deserves one. Pure, so the wording is testable:
///
/// - the genuine bundle (by its `Info.plist`) without any `client_kind`: an
///   app older than the daemon;
/// - a `mac_app` claim that was refused: why, and how to fix it.
///
/// `None` for an operator (logged at info) and for ordinary peers.
pub fn claim_diagnostic(info: Option<&PeerInfo>, client_kind: Option<&str>, trust: PeerTrust) -> Option<String> {
    if trust == PeerTrust::OperatorApp {
        return None;
    }
    const FIX: &str = "run make mac-install (installs, signs and pins the app)";
    const NOT_ENFORCED: &str = "SIP disabled or runtime not enforced: operator app cannot answer";
    match client_kind {
        None if info.is_some_and(|i| i.path_bundle_id.as_deref() == Some(APP_BUNDLE_ID)) => {
            Some("genuine bundle, no mac_app claim: old app? reinstall app and daemon together".to_string())
        }
        Some(MAC_APP_CLIENT_KIND) => Some(match info.map(|i| &i.code) {
            None => format!("mac_app claim refused: the peer could not be identified; {FIX}"),
            // Reinstalling cannot help here: the host itself does not enforce
            // the runtime.
            Some(CodeIdentity::Unverified { reason: reason @ UnverifiedReason::RuntimeNotEnforced }) => {
                format!("mac_app claim refused: {reason}; {NOT_ENFORCED}")
            }
            Some(CodeIdentity::Unverified { reason }) => format!("mac_app claim refused: {reason}; {FIX}"),
            Some(CodeIdentity::Pinned { identifier }) => {
                format!("mac_app claim refused: identifier {identifier} is not accepted by this daemon; {FIX}")
            }
        }),
        _ => None,
    }
}

// ── the pin ──────────────────────────────────────────────────────────────────

/// The installed operator app's code identity, as `make mac-install` wrote it
/// (`scripts/write-operator-pin.sh`):
///
/// ```text
/// # comment
/// identifier com.hammer.nostromo
/// cdhash <40 hex>      (one line per architecture slice)
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperatorPin {
    identifier: String,
    cdhashes: Vec<String>,
}

/// A pin file is a few hundred bytes; anything much larger is not one.
const MAX_PIN_LEN: u64 = 64 * 1024;

impl OperatorPin {
    /// Parse a pin. Blank lines and `#` comments are ignored. Exactly one
    /// `identifier` (letters, digits, `.`, `-`) and at least one `cdhash` (40
    /// hex digits) are required; any other line is an error.
    pub fn parse(text: &str) -> Result<Self, UnverifiedReason> {
        let bad = UnverifiedReason::BadPin;
        let mut identifier = None;
        let mut cdhashes = Vec::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut words = line.split_whitespace();
            let (Some(key), Some(value), None) = (words.next(), words.next(), words.next()) else {
                return Err(bad);
            };
            match key {
                "identifier" => {
                    let valid = value.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
                    if identifier.is_some() || !valid {
                        return Err(bad);
                    }
                    identifier = Some(value.to_string());
                }
                "cdhash" => {
                    if value.len() != 40 || !value.chars().all(|c| c.is_ascii_hexdigit()) {
                        return Err(bad);
                    }
                    cdhashes.push(value.to_ascii_lowercase());
                }
                _ => return Err(bad),
            }
        }
        match identifier {
            Some(identifier) if !cdhashes.is_empty() => Ok(Self { identifier, cdhashes }),
            _ => Err(bad),
        }
    }

    /// Read and parse the pin at `path`. Missing → `NoPin`. Unreadable,
    /// malformed, not a regular file, not owned by this process's user, or
    /// group- or world-writable → `BadPin`.
    ///
    /// The ownership and mode checks are hygiene, not a defence against code
    /// running as the same user: that code can rewrite the pin (and the app)
    /// anyway. They catch a pin left writable by mistake.
    pub fn load(path: &Path) -> Result<Self, UnverifiedReason> {
        use std::os::unix::fs::MetadataExt;

        let file = match std::fs::File::open(path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(UnverifiedReason::NoPin),
            Err(_) => return Err(UnverifiedReason::BadPin),
        };
        let meta = file.metadata().map_err(|_| UnverifiedReason::BadPin)?;
        // SAFETY: geteuid has no preconditions.
        let uid = unsafe { libc::geteuid() };
        if !meta.is_file() || meta.uid() != uid || meta.mode() & 0o022 != 0 {
            return Err(UnverifiedReason::BadPin);
        }
        let mut text = String::new();
        file.take(MAX_PIN_LEN).read_to_string(&mut text).map_err(|_| UnverifiedReason::BadPin)?;
        Self::parse(&text)
    }

    pub fn identifier(&self) -> &str {
        &self.identifier
    }

    pub fn cdhashes(&self) -> &[String] {
        &self.cdhashes
    }

    /// The code requirement the running app must satisfy:
    /// `identifier "<id>" and (cdhash H"<a>" or cdhash H"<b>")`. The
    /// identifier and hashes were validated by [`OperatorPin::parse`], so
    /// nothing in them can break out of the quotes.
    pub fn requirement(&self) -> String {
        let hashes: Vec<String> = self.cdhashes.iter().map(|h| format!("cdhash H\"{h}\"")).collect();
        format!("identifier \"{}\" and ({})", self.identifier, hashes.join(" or "))
    }
}

// ── the audit token ──────────────────────────────────────────────────────────

/// A peer's `audit_token_t`: eight `u32`s, as `LOCAL_PEERTOKEN` returns them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuditToken(pub [u32; 8]);

impl AuditToken {
    /// `audit_token_to_pid` (`<bsm/libbsm.h>`): `val[5]`.
    pub fn pid(&self) -> i32 {
        self.0[5] as i32
    }

    /// `audit_token_to_pidversion`: `val[7]`.
    pub fn pidversion(&self) -> u32 {
        self.0[7]
    }
}

/// `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)`: the audit token of the process
/// that last used the socket's other end.
#[cfg(target_os = "macos")]
pub fn audit_token(fd: BorrowedFd<'_>) -> Option<AuditToken> {
    use std::os::fd::AsRawFd;

    let mut val = [0u32; 8];
    let mut len = std::mem::size_of_val(&val) as libc::socklen_t;
    // SAFETY: `val` and `len` are valid for writes of the sizes passed, and
    // `fd` is borrowed for the duration of the call.
    let rc = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERTOKEN,
            val.as_mut_ptr().cast(),
            &mut len,
        )
    };
    (rc == 0 && len as usize == std::mem::size_of_val(&val)).then_some(AuditToken(val))
}

#[cfg(not(target_os = "macos"))]
pub fn audit_token(_fd: BorrowedFd<'_>) -> Option<AuditToken> {
    None
}

// ── the code check ───────────────────────────────────────────────────────────

/// Kernel code-signing status bits (`<kern/cs_blobs.h>`).
mod cs {
    pub const VALID: u32 = 0x0000_0001;
    pub const GET_TASK_ALLOW: u32 = 0x0000_0004;
    /// The kernel kills the process rather than let it map invalid pages.
    pub const HARD: u32 = 0x0000_0100;
    /// The kernel kills the process if its signature becomes invalid.
    pub const KILL: u32 = 0x0000_0200;
    /// The kernel enforces code signing on the process.
    pub const ENFORCEMENT: u32 = 0x0000_1000;
    pub const RUNTIME: u32 = 0x0001_0000;
    pub const DEBUGGED: u32 = 0x1000_0000;
}

/// Judges the kernel's status flags for a peer whose code already satisfied
/// the pin. Pure, so every combination is unit-tested on any platform.
///
/// `CS_RUNTIME` says only that the signature asks for the hardened runtime;
/// the kernel still sets it when System Integrity Protection is disabled and
/// nothing is enforced (a spike on a SIP-disabled host: `0x22010001`, and a
/// `DYLD_INSERT_LIBRARIES` library ran). So the enforcement bits are required
/// too. `CS_FORCED_LV` (`0x10`) is deliberately not required: whether the
/// kernel sets it may vary by OS version. A SIP-enabled host gives
/// `0x22011311` for the installed recipe.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn check_status_flags(status: u32) -> Result<(), UnverifiedReason> {
    const ENFORCED: u32 = cs::HARD | cs::KILL | cs::ENFORCEMENT;
    if status & cs::VALID == 0 {
        Err(UnverifiedReason::NotValid)
    } else if status & cs::RUNTIME == 0 {
        Err(UnverifiedReason::NoRuntime)
    } else if status & cs::GET_TASK_ALLOW != 0 {
        Err(UnverifiedReason::GetTaskAllow)
    } else if status & cs::DEBUGGED != 0 {
        Err(UnverifiedReason::Debugged)
    } else if status & ENFORCED != ENFORCED {
        Err(UnverifiedReason::RuntimeNotEnforced)
    } else {
        Ok(())
    }
}

/// The code `token` names, checked against `pin`: looked up by audit token,
/// validated against [`OperatorPin::requirement`] (resources included), then
/// judged by the kernel's own status flags ([`check_status_flags`]): valid,
/// under an enforced hardened runtime, not debuggable, not being debugged.
#[cfg(target_os = "macos")]
pub fn verify_code(token: &AuditToken, pin: &OperatorPin) -> CodeIdentity {
    match check_code(token, pin) {
        Ok(()) => CodeIdentity::Pinned { identifier: pin.identifier().to_string() },
        Err(reason) => CodeIdentity::Unverified { reason },
    }
}

#[cfg(not(target_os = "macos"))]
pub fn verify_code(_token: &AuditToken, _pin: &OperatorPin) -> CodeIdentity {
    CodeIdentity::Unverified { reason: UnverifiedReason::Unsupported }
}

#[cfg(target_os = "macos")]
fn check_code(token: &AuditToken, pin: &OperatorPin) -> Result<(), UnverifiedReason> {
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use security_framework::os::macos::code_signing::{Flags, GuestAttributes, SecCode, SecRequirement};

    /// `errSecCSReqFailed`: the code does not satisfy the requirement.
    const ERR_REQ_FAILED: i32 = -67050;

    let requirement: SecRequirement = pin.requirement().parse().map_err(|_| UnverifiedReason::BadPin)?;
    let bytes: Vec<u8> = token.0.iter().flat_map(|v| v.to_ne_bytes()).collect();
    let token_data = CFData::from_buffer(&bytes);
    let mut attrs = GuestAttributes::new();
    attrs.set_audit_token(token_data.as_concrete_TypeRef());
    let code = SecCode::copy_guest_with_attribues(None, &attrs, Flags::NONE)
        .map_err(|_| UnverifiedReason::NoSuchCode)?;
    code.check_validity(Flags::NONE, &requirement).map_err(|e| {
        if e.code() == ERR_REQ_FAILED {
            UnverifiedReason::RequirementFailed
        } else {
            UnverifiedReason::NotValid
        }
    })?;
    let status = dynamic_status(&code).ok_or(UnverifiedReason::NotValid)?;
    check_status_flags(status)
}

/// The kernel's status flags for running `code`
/// (`SecCodeCopySigningInformation(kSecCSDynamicInformation)`'s
/// `kSecCodeInfoStatus`, which `security-framework` does not wrap).
#[cfg(target_os = "macos")]
fn dynamic_status(code: &security_framework::os::macos::code_signing::SecCode) -> Option<u32> {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::number::CFNumber;
    use core_foundation::string::{CFString, CFStringRef};
    use std::ffi::c_void;

    /// `kSecCSDynamicInformation`.
    const DYNAMIC_INFORMATION: u32 = 1 << 3;

    #[link(name = "Security", kind = "framework")]
    extern "C" {
        fn SecCodeCopySigningInformation(code: *const c_void, flags: u32, information: *mut CFDictionaryRef) -> i32;
        static kSecCodeInfoStatus: CFStringRef;
    }

    let mut info: CFDictionaryRef = std::ptr::null();
    // SAFETY: a `SecCodeRef` is a valid `SecStaticCodeRef` argument (the
    // Security framework documents this), and `info` is valid for one write.
    let rc = unsafe { SecCodeCopySigningInformation(code.as_CFTypeRef(), DYNAMIC_INFORMATION, &mut info) };
    if rc != 0 || info.is_null() {
        return None;
    }
    // SAFETY: on success `info` is a +1 CFDictionary we now own.
    let info: CFDictionary<CFString, CFType> = unsafe { CFDictionary::wrap_under_create_rule(info) };
    // SAFETY: a constant CFString exported by the Security framework.
    let key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoStatus) };
    let status = info.find(&key)?.downcast::<CFNumber>()?.to_i64()?;
    u32::try_from(status).ok()
}

// ── pid and path ─────────────────────────────────────────────────────────────

/// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)`: the pid of the process that last
/// used the socket's other end (not necessarily the one that connected).
#[cfg(target_os = "macos")]
fn peer_pid(fd: BorrowedFd<'_>) -> Option<i32> {
    use std::os::fd::AsRawFd;

    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `pid` and `len` are valid for writes of the sizes passed, and
    // `fd` is borrowed for the duration of the call.
    let rc = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    };
    (rc == 0 && pid > 0).then_some(pid)
}

/// `SO_PEERCRED`: the pid of the process that connected.
#[cfg(target_os = "linux")]
fn peer_pid(fd: BorrowedFd<'_>) -> Option<i32> {
    use std::os::fd::AsRawFd;

    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for writes of the sizes passed, and
    // `fd` is borrowed for the duration of the call.
    let rc = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0 && cred.pid > 0).then_some(cred.pid)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn peer_pid(_fd: BorrowedFd<'_>) -> Option<i32> {
    None
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
/// binary itself, which is never the pinned app).
#[cfg(any(test, feature = "test-support"))]
pub mod testing {
    use std::collections::VecDeque;
    use std::os::fd::BorrowedFd;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::time::Duration;

    use super::{CodeIdentity, PeerInfo, PeerVerifier, UnverifiedReason, APP_BUNDLE_ID};

    /// What the genuine, pinned Mac app looks like to the verifier.
    pub fn app_info() -> PeerInfo {
        PeerInfo {
            pid: 4242,
            pidversion: 1,
            exe: PathBuf::from("/Applications/Nostromo.app/Contents/MacOS/Nostromo"),
            path_bundle_id: Some(APP_BUNDLE_ID.to_string()),
            code: CodeIdentity::Pinned { identifier: APP_BUNDLE_ID.to_string() },
        }
    }

    /// What an agent's script looks like to the verifier (when checked).
    pub fn script_info() -> PeerInfo {
        PeerInfo {
            pid: 4343,
            pidversion: 1,
            exe: PathBuf::from("/usr/bin/python3"),
            path_bundle_id: None,
            code: CodeIdentity::Unverified { reason: UnverifiedReason::RequirementFailed },
        }
    }

    /// Answers each `inspect` from a script, in call order, then with
    /// `fallback` once the script runs out. An `inspect` without
    /// `verify_code` reports `code: Unverified { NotChecked }`, as the real
    /// verifier does. Optionally sleeps first, to stand in for a slow lookup.
    ///
    /// Answer-time `reinspect`s are scripted separately
    /// ([`FakePeerVerifier::with_reinspect`]); once that script runs out (or
    /// when there is none) a re-inspection reports the accepted peer again.
    pub struct FakePeerVerifier {
        script: Mutex<VecDeque<Option<PeerInfo>>>,
        fallback: Option<PeerInfo>,
        reinspect_script: Mutex<VecDeque<Option<PeerInfo>>>,
        reinspects: AtomicUsize,
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

        /// The n-th `inspect` gets `script[n]`; later ones get `fallback`.
        pub fn scripted(script: Vec<Option<PeerInfo>>, fallback: Option<PeerInfo>) -> Self {
            Self {
                script: Mutex::new(script.into()),
                fallback,
                reinspect_script: Mutex::new(VecDeque::new()),
                reinspects: AtomicUsize::new(0),
                delay: None,
                first_delay: Mutex::new(None),
            }
        }

        /// The n-th answer-time `reinspect` gets `script[n]`; later ones report
        /// the accepted peer unchanged.
        pub fn with_reinspect(self, script: Vec<Option<PeerInfo>>) -> Self {
            *self.reinspect_script.lock().unwrap() = script.into();
            self
        }

        /// How many answer-time re-inspections ran.
        pub fn reinspect_count(&self) -> usize {
            self.reinspects.load(Ordering::SeqCst)
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
        fn inspect(&self, _fd: BorrowedFd<'_>, verify_code: bool) -> Option<PeerInfo> {
            let first = self.first_delay.lock().unwrap().take();
            if let Some(delay) = first {
                std::thread::sleep(delay);
            }
            if let Some(delay) = self.delay {
                std::thread::sleep(delay);
            }
            let next = self.script.lock().unwrap().pop_front();
            let mut info = next.unwrap_or_else(|| self.fallback.clone())?;
            if !verify_code {
                info.code = CodeIdentity::Unverified { reason: UnverifiedReason::NotChecked };
            }
            Some(info)
        }

        fn reinspect(&self, _fd: BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
            self.reinspects.fetch_add(1, Ordering::SeqCst);
            let next = self.reinspect_script.lock().unwrap().pop_front();
            next.unwrap_or_else(|| Some(accepted.clone()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::{Path, PathBuf};

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

    // ── classify_peer ─────────────────────────────────────────────────────────

    const ALL_REASONS: [UnverifiedReason; 12] = [
        UnverifiedReason::NotChecked,
        UnverifiedReason::NoPin,
        UnverifiedReason::BadPin,
        UnverifiedReason::NoToken,
        UnverifiedReason::NoSuchCode,
        UnverifiedReason::RequirementFailed,
        UnverifiedReason::NoRuntime,
        UnverifiedReason::RuntimeNotEnforced,
        UnverifiedReason::GetTaskAllow,
        UnverifiedReason::Debugged,
        UnverifiedReason::NotValid,
        UnverifiedReason::Unsupported,
    ];

    fn peer(code: CodeIdentity) -> PeerInfo {
        PeerInfo {
            pid: 100,
            pidversion: 7,
            exe: PathBuf::from("/Applications/Nostromo.app/Contents/MacOS/Nostromo"),
            path_bundle_id: Some(APP_BUNDLE_ID.to_string()),
            code,
        }
    }

    fn pinned(identifier: &str) -> CodeIdentity {
        CodeIdentity::Pinned { identifier: identifier.to_string() }
    }

    fn unverified(reason: UnverifiedReason) -> CodeIdentity {
        CodeIdentity::Unverified { reason }
    }

    #[test]
    fn only_a_mac_app_claim_from_code_pinned_as_the_app_is_the_operator() {
        let mut codes: Vec<(String, Option<CodeIdentity>)> = vec![
            ("no peer info".into(), None),
            ("pinned app".into(), Some(pinned(APP_BUNDLE_ID))),
            ("pinned qa".into(), Some(pinned(QA_BUNDLE_ID))),
            ("pinned other".into(), Some(pinned("com.example.other"))),
            ("pinned app-prefixed".into(), Some(pinned("com.hammer.nostromo.evil"))),
            ("pinned app-suffix".into(), Some(pinned("xcom.hammer.nostromo"))),
            ("pinned upper-cased app".into(), Some(pinned("COM.HAMMER.NOSTROMO"))),
            ("pinned empty".into(), Some(pinned(""))),
        ];
        for reason in ALL_REASONS {
            codes.push((format!("unverified {reason}"), Some(unverified(reason))));
        }
        let claims = [None, Some("mac_app"), Some("MAC_APP"), Some("mac_app "), Some(""), Some("ios_app"), Some("cli")];

        let mut operators = Vec::new();
        for (name, code) in &codes {
            let info = code.clone().map(peer);
            for claim in claims {
                for qa_mode in [false, true] {
                    if classify_peer(info.as_ref(), claim, qa_mode) == PeerTrust::OperatorApp {
                        operators.push((name.as_str(), claim, qa_mode));
                    } else {
                        assert_eq!(classify_peer(info.as_ref(), claim, qa_mode), PeerTrust::LocalOther);
                    }
                }
            }
        }
        assert_eq!(
            operators,
            vec![
                ("pinned app", Some("mac_app"), false),
                ("pinned app", Some("mac_app"), true),
                ("pinned qa", Some("mac_app"), true),
            ],
            "exactly these (code, claim, qa_mode) combinations are the operator app"
        );
    }

    #[test]
    fn the_executables_path_and_its_info_plist_no_longer_decide_who_the_operator_is() {
        // A fake bundle: the right place, the right Info.plist, the wrong code.
        let fake = PeerInfo {
            pid: 1,
            pidversion: 1,
            exe: PathBuf::from("/Applications/Nostromo.app/Contents/MacOS/Nostromo"),
            path_bundle_id: Some(APP_BUNDLE_ID.to_string()),
            code: unverified(UnverifiedReason::RequirementFailed),
        };
        assert_eq!(classify_peer(Some(&fake), Some(MAC_APP_CLIENT_KIND), false), PeerTrust::LocalOther);
        assert_eq!(classify_peer(Some(&fake), Some(MAC_APP_CLIENT_KIND), true), PeerTrust::LocalOther);

        // The pinned code, run from anywhere and with no bundle around it.
        let moved = PeerInfo {
            pid: 1,
            pidversion: 1,
            exe: PathBuf::from("/tmp/somewhere/else/a.out"),
            path_bundle_id: None,
            code: pinned(APP_BUNDLE_ID),
        };
        assert!(matches!(classify_peer(Some(&moved), Some(MAC_APP_CLIENT_KIND), false), PeerTrust::OperatorApp));
        let odd = PeerInfo { path_bundle_id: Some("com.example.other".into()), ..moved };
        assert!(matches!(classify_peer(Some(&odd), Some(MAC_APP_CLIENT_KIND), false), PeerTrust::OperatorApp));
    }

    #[test]
    fn an_unverified_reason_displays_as_its_name() {
        let names: Vec<String> = ALL_REASONS.iter().map(|r| r.to_string()).collect();
        assert_eq!(
            names,
            [
                "NotChecked", "NoPin", "BadPin", "NoToken", "NoSuchCode", "RequirementFailed", "NoRuntime",
                "RuntimeNotEnforced", "GetTaskAllow", "Debugged", "NotValid", "Unsupported",
            ]
        );
    }

    // ── still_same_operator ───────────────────────────────────────────────────

    #[test]
    fn the_same_pinned_process_is_still_the_operator() {
        let accepted = peer(pinned(APP_BUNDLE_ID));
        assert!(still_same_operator(&accepted, Some(&accepted.clone())));
        // The path and the plist are diagnostics; they do not take part.
        let now = PeerInfo { exe: PathBuf::from("/elsewhere"), path_bundle_id: None, ..accepted.clone() };
        assert!(still_same_operator(&accepted, Some(&now)));
        // A QA-mode operator stays itself too.
        let qa = peer(pinned(QA_BUNDLE_ID));
        assert!(still_same_operator(&qa, Some(&qa.clone())));
    }

    #[test]
    fn anything_but_the_same_pinned_process_is_not_still_the_operator() {
        let accepted = peer(pinned(APP_BUNDLE_ID));
        let mut cases: Vec<(String, Option<PeerInfo>)> = vec![
            ("nobody found".into(), None),
            ("another pid (an fd sharer)".into(), Some(PeerInfo { pid: accepted.pid + 1, ..accepted.clone() })),
            ("a new pidversion (exec)".into(), Some(PeerInfo { pidversion: accepted.pidversion + 1, ..accepted.clone() })),
            ("pidversion 0 (no token)".into(), Some(PeerInfo { pidversion: 0, ..accepted.clone() })),
            ("another identifier".into(), Some(PeerInfo { code: pinned(QA_BUNDLE_ID), ..accepted.clone() })),
            (
                "another pid and pidversion".into(),
                Some(PeerInfo { pid: accepted.pid + 1, pidversion: accepted.pidversion + 1, ..accepted.clone() }),
            ),
        ];
        for reason in ALL_REASONS {
            cases.push((format!("now {reason}"), Some(PeerInfo { code: unverified(reason), ..accepted.clone() })));
        }
        for (what, now) in &cases {
            assert!(!still_same_operator(&accepted, now.as_ref()), "{what} must not still be the operator");
        }

        // An accepted peer that was never pinned can never be "still" it.
        for reason in ALL_REASONS {
            let was = PeerInfo { code: unverified(reason), ..accepted.clone() };
            assert!(!still_same_operator(&was, Some(&accepted)), "accepted as {reason}");
            assert!(!still_same_operator(&was, Some(&was.clone())), "accepted and now {reason}");
        }
    }

    // ── claim_diagnostic ──────────────────────────────────────────────────────

    const FIX: &str = "run make mac-install (installs, signs and pins the app)";

    #[test]
    fn a_genuine_bundle_without_a_claim_is_diagnosed_as_an_old_app() {
        let info = PeerInfo { path_bundle_id: Some(APP_BUNDLE_ID.into()), ..peer(unverified(UnverifiedReason::NotChecked)) };
        let trust = classify_peer(Some(&info), None, false);
        assert_eq!(
            claim_diagnostic(Some(&info), None, trust).as_deref(),
            Some("genuine bundle, no mac_app claim: old app? reinstall app and daemon together")
        );
    }

    #[test]
    fn a_refused_mac_app_claim_is_diagnosed_with_its_reason_and_the_fix() {
        for reason in ALL_REASONS.into_iter().filter(|r| *r != UnverifiedReason::RuntimeNotEnforced) {
            let info = peer(unverified(reason));
            let trust = classify_peer(Some(&info), Some(MAC_APP_CLIENT_KIND), false);
            assert_eq!(
                claim_diagnostic(Some(&info), Some(MAC_APP_CLIENT_KIND), trust),
                Some(format!("mac_app claim refused: {reason}; {FIX}"))
            );
        }

        // Nobody identifiable, or pinned under an identifier this daemon does
        // not accept: still refused, still told how to fix it.
        let none = claim_diagnostic(None, Some(MAC_APP_CLIENT_KIND), PeerTrust::LocalOther).unwrap();
        assert!(none.starts_with("mac_app claim refused: ") && none.ends_with(FIX), "{none}");
        let qa = peer(pinned(QA_BUNDLE_ID));
        let trust = classify_peer(Some(&qa), Some(MAC_APP_CLIENT_KIND), false);
        let text = claim_diagnostic(Some(&qa), Some(MAC_APP_CLIENT_KIND), trust).unwrap();
        assert!(text.starts_with("mac_app claim refused: ") && text.contains(QA_BUNDLE_ID) && text.ends_with(FIX), "{text}");
    }

    #[test]
    fn a_host_that_does_not_enforce_the_runtime_is_diagnosed_without_a_reinstall_fix() {
        let info = peer(unverified(UnverifiedReason::RuntimeNotEnforced));
        let trust = classify_peer(Some(&info), Some(MAC_APP_CLIENT_KIND), false);
        let text = claim_diagnostic(Some(&info), Some(MAC_APP_CLIENT_KIND), trust).unwrap();
        assert_eq!(
            text,
            "mac_app claim refused: RuntimeNotEnforced; SIP disabled or runtime not enforced: operator app cannot answer"
        );
        // Never advice to turn a protection off.
        assert!(!text.to_lowercase().contains("disable "), "{text}");
    }

    // ── check_status_flags ────────────────────────────────────────────────────

    /// The installed recipe on a SIP-enabled host (spike, macOS 26.5.1).
    const ENFORCED_RUNTIME: u32 = 0x2201_1311;
    /// The same recipe on a SIP-disabled host (GitHub macos-26 runner).
    const UNENFORCED_RUNTIME: u32 = 0x2201_0001;

    #[test]
    fn an_enforced_hardened_runtime_passes() {
        assert_eq!(check_status_flags(ENFORCED_RUNTIME), Ok(()));
        // CS_FORCED_LV (0x10) is not required.
        assert_eq!(check_status_flags(ENFORCED_RUNTIME & !0x10), Ok(()));
    }

    #[test]
    fn a_runtime_the_host_does_not_enforce_is_refused() {
        assert_eq!(check_status_flags(UNENFORCED_RUNTIME), Err(UnverifiedReason::RuntimeNotEnforced));
        for missing in [cs::HARD, cs::KILL, cs::ENFORCEMENT] {
            assert_eq!(
                check_status_flags(ENFORCED_RUNTIME & !missing),
                Err(UnverifiedReason::RuntimeNotEnforced),
                "missing {missing:#x}"
            );
        }
    }

    #[test]
    fn the_other_status_refusals_still_hold() {
        assert_eq!(check_status_flags(ENFORCED_RUNTIME & !cs::VALID), Err(UnverifiedReason::NotValid));
        // Ad-hoc without the runtime (spike: 0x22000201).
        assert_eq!(check_status_flags(0x2200_0201), Err(UnverifiedReason::NoRuntime));
        // The runtime with get-task-allow (spike: 0x22011315).
        assert_eq!(check_status_flags(0x2201_1315), Err(UnverifiedReason::GetTaskAllow));
        assert_eq!(check_status_flags(ENFORCED_RUNTIME | cs::DEBUGGED), Err(UnverifiedReason::Debugged));
    }

    #[test]
    fn the_operator_and_ordinary_peers_get_no_diagnostic() {
        let app = peer(pinned(APP_BUNDLE_ID));
        let trust = classify_peer(Some(&app), Some(MAC_APP_CLIENT_KIND), false);
        assert!(matches!(trust, PeerTrust::OperatorApp));
        assert_eq!(claim_diagnostic(Some(&app), Some(MAC_APP_CLIENT_KIND), trust), None);

        let script = PeerInfo {
            exe: PathBuf::from("/usr/bin/python3"),
            path_bundle_id: None,
            ..peer(unverified(UnverifiedReason::NotChecked))
        };
        assert_eq!(claim_diagnostic(Some(&script), None, PeerTrust::LocalOther), None);
        assert_eq!(claim_diagnostic(None, None, PeerTrust::LocalOther), None);
        assert_eq!(claim_diagnostic(Some(&script), Some("cli"), PeerTrust::LocalOther), None);
    }

    // ── the pin ───────────────────────────────────────────────────────────────

    const H1: &str = "0123456789abcdef0123456789abcdef01234567";
    const H2: &str = "fedcba9876543210fedcba9876543210fedcba98";

    #[test]
    fn a_pin_with_comments_blank_lines_and_one_cdhash_parses() {
        let text = format!(
            "# written by make mac-install\n\n   \nidentifier com.hammer.nostromo\n  # arm64\n  cdhash {H1}  \n\n"
        );
        let pin = OperatorPin::parse(&text).unwrap();
        assert_eq!(pin.identifier(), "com.hammer.nostromo");
        assert_eq!(pin.cdhashes(), [H1.to_string()]);
    }

    #[test]
    fn a_pin_with_two_cdhashes_keeps_both_in_order_and_lower_cases_them() {
        let text = format!("cdhash {}\nidentifier com.hammer.nostromo.qa\ncdhash {H2}\n", H1.to_ascii_uppercase());
        let pin = OperatorPin::parse(&text).unwrap();
        assert_eq!(pin.identifier(), "com.hammer.nostromo.qa");
        assert_eq!(pin.cdhashes(), [H1.to_string(), H2.to_string()]);
    }

    #[test]
    fn a_malformed_pin_is_a_bad_pin() {
        let id = "identifier com.hammer.nostromo";
        let ok = format!("cdhash {H1}");
        let cases: Vec<(&str, String)> = vec![
            ("empty", String::new()),
            ("only blank lines", "\n\n  \n".into()),
            ("only comments", "# a\n# b\n".into()),
            ("no cdhash", format!("{id}\n")),
            ("no identifier", format!("{ok}\n")),
            ("duplicate identifier", format!("{id}\n{id}\n{ok}\n")),
            ("two different identifiers", format!("{id}\nidentifier com.example.other\n{ok}\n")),
            ("bad hex", format!("{id}\ncdhash {}g\n", &H1[..39])),
            ("cdhash too short", format!("{id}\ncdhash {}\n", &H1[..39])),
            ("cdhash too long", format!("{id}\ncdhash {H1}0\n")),
            ("a full sha256", format!("{id}\ncdhash {H1}{}\n", &H2[..24])),
            ("a good and a bad cdhash", format!("{id}\n{ok}\ncdhash xyz\n")),
            ("unknown key", format!("{id}\n{ok}\nteam ABCDE12345\n")),
            ("key without value", format!("{id}\n{ok}\ncdhash\n")),
            ("identifier without value", format!("identifier\n{ok}\n")),
            ("extra token after identifier", format!("{id} extra\n{ok}\n")),
            ("extra token after cdhash", format!("{id}\n{ok} extra\n")),
            ("trailing comment on a line", format!("{id}\n{ok} # arm64\n")),
            ("identifier with a quote", format!("identifier com.hammer\"nostromo\n{ok}\n")),
            ("identifier closing the quote", format!("identifier com.hammer.nostromo\")or(anchor\n{ok}\n")),
            ("quoted identifier with a space", format!("identifier \"com.hammer nostromo\"\n{ok}\n")),
            ("identifier with a backslash", format!("identifier com\\hammer\n{ok}\n")),
            ("identifier with parentheses", format!("identifier com.hammer.(nostromo)\n{ok}\n")),
            ("key upper-cased", format!("IDENTIFIER com.hammer.nostromo\n{ok}\n")),
        ];
        for (what, text) in cases {
            assert_eq!(OperatorPin::parse(&text), Err(UnverifiedReason::BadPin), "{what}: {text:?}");
        }
    }

    #[test]
    fn a_pins_requirement_names_the_identifier_and_every_cdhash() {
        let one = OperatorPin::parse(&format!("identifier com.hammer.nostromo\ncdhash {H1}\n")).unwrap();
        assert_eq!(one.requirement(), format!("identifier \"com.hammer.nostromo\" and (cdhash H\"{H1}\")"));

        let two = OperatorPin::parse(&format!(
            "identifier com.hammer.nostromo\ncdhash {}\ncdhash {H2}\n",
            H1.to_ascii_uppercase()
        ))
        .unwrap();
        assert_eq!(
            two.requirement(),
            format!("identifier \"com.hammer.nostromo\" and (cdhash H\"{H1}\" or cdhash H\"{H2}\")")
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_pins_requirement_compiles_as_a_code_requirement() {
        use security_framework::os::macos::code_signing::SecRequirement;
        for text in [
            format!("identifier com.hammer.nostromo\ncdhash {H1}\n"),
            format!("identifier com.hammer.nostromo.qa\ncdhash {H1}\ncdhash {H2}\n"),
        ] {
            let req = OperatorPin::parse(&text).unwrap().requirement();
            assert!(req.parse::<SecRequirement>().is_ok(), "the Security framework must accept {req:?}");
        }
    }

    fn write_pin(dir: &Path, mode: u32, text: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(PIN_FILE_NAME);
        fs::write(&path, text).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    fn good_pin_text() -> String {
        format!("identifier com.hammer.nostromo\ncdhash {H1}\n")
    }

    #[test]
    fn loading_a_missing_pin_is_no_pin() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(OperatorPin::load(&dir.path().join(PIN_FILE_NAME)), Err(UnverifiedReason::NoPin));
    }

    #[test]
    fn loading_a_private_well_formed_pin_succeeds() {
        for mode in [0o600, 0o644, 0o400] {
            let dir = tempfile::tempdir().unwrap();
            let pin = OperatorPin::load(&write_pin(dir.path(), mode, &good_pin_text()))
                .unwrap_or_else(|e| panic!("mode {mode:o}: {e}"));
            assert_eq!(pin.identifier(), APP_BUNDLE_ID);
            assert_eq!(pin.cdhashes(), [H1.to_string()]);
        }
    }

    #[test]
    fn loading_a_group_or_world_writable_pin_is_a_bad_pin() {
        for mode in [0o620, 0o602, 0o622, 0o666, 0o777] {
            let dir = tempfile::tempdir().unwrap();
            let path = write_pin(dir.path(), mode, &good_pin_text());
            assert_eq!(OperatorPin::load(&path), Err(UnverifiedReason::BadPin), "mode {mode:o}");
        }
    }

    #[test]
    fn loading_a_malformed_unreadable_or_non_file_pin_is_a_bad_pin() {
        let dir = tempfile::tempdir().unwrap();
        let malformed = write_pin(dir.path(), 0o600, "identifier com.hammer.nostromo\n");
        assert_eq!(OperatorPin::load(&malformed), Err(UnverifiedReason::BadPin));

        let dir = tempfile::tempdir().unwrap();
        fs::create_dir(dir.path().join(PIN_FILE_NAME)).unwrap();
        assert_eq!(OperatorPin::load(&dir.path().join(PIN_FILE_NAME)), Err(UnverifiedReason::BadPin), "a directory");

        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            let dir = tempfile::tempdir().unwrap();
            let unreadable = write_pin(dir.path(), 0o000, &good_pin_text());
            assert_eq!(OperatorPin::load(&unreadable), Err(UnverifiedReason::BadPin), "mode 000");
        }
    }

    #[test]
    fn loading_a_pin_owned_by_another_user_is_a_bad_pin() {
        // A root-owned, world-readable, not-writable system file. (Its content
        // is not a pin either, so run as root this still holds, by the parse;
        // a same-content foreign-owned file cannot be made without root.)
        assert_eq!(OperatorPin::load(Path::new("/etc/hosts")), Err(UnverifiedReason::BadPin));
    }

    // ── the audit token and the real verifier, on a self-connection ───────────

    /// A connected pair over a real listening socket: (accepted end, client end).
    #[cfg(target_os = "macos")]
    fn self_connection(dir: &Path) -> (std::os::unix::net::UnixStream, std::os::unix::net::UnixStream) {
        let path = dir.join("s.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let client = std::os::unix::net::UnixStream::connect(&path).unwrap();
        let (accepted, _) = listener.accept().unwrap();
        (accepted, client)
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_self_connections_audit_token_names_this_process() {
        use std::os::fd::AsFd;
        let dir = tempfile::tempdir().unwrap();
        let (accepted, _client) = self_connection(dir.path());
        let token = audit_token(accepted.as_fd()).expect("LOCAL_PEERTOKEN must answer for a live peer");
        assert_eq!(token.pid(), std::process::id() as i32);
        assert_ne!(token.pidversion(), 0, "a live process has a nonzero pidversion");
        assert_eq!(token.pid(), token.0[5] as i32);
        assert_eq!(token.pidversion(), token.0[7]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_real_verifier_checks_code_only_when_asked_and_reports_a_missing_pin() {
        use std::os::fd::AsFd;
        let dir = tempfile::tempdir().unwrap();
        let (accepted, _client) = self_connection(dir.path());
        let verifier = MacPeerVerifier::new(dir.path().join(PIN_FILE_NAME));
        let token = audit_token(accepted.as_fd()).unwrap();

        let unchecked = verifier.inspect(accepted.as_fd(), false).expect("the peer is this process");
        assert_eq!(unchecked.pid, std::process::id() as i32);
        assert_eq!(unchecked.pidversion, token.pidversion());
        assert_eq!(unchecked.code, CodeIdentity::Unverified { reason: UnverifiedReason::NotChecked });
        assert_eq!(unchecked.path_bundle_id, None, "the test binary is in no app bundle");
        assert_eq!(
            fs::canonicalize(&unchecked.exe).unwrap(),
            fs::canonicalize(std::env::current_exe().unwrap()).unwrap()
        );

        let checked = verifier.inspect(accepted.as_fd(), true).unwrap();
        assert_eq!(checked.code, CodeIdentity::Unverified { reason: UnverifiedReason::NoPin });
        assert_eq!((checked.pid, checked.pidversion), (unchecked.pid, unchecked.pidversion));

        // The default re-inspection is a full check.
        let again = verifier.reinspect(accepted.as_fd(), &checked).unwrap();
        assert_eq!(again.code, CodeIdentity::Unverified { reason: UnverifiedReason::NoPin });
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_real_verifier_reads_the_pin_on_every_check() {
        use std::os::fd::AsFd;
        let dir = tempfile::tempdir().unwrap();
        let (accepted, _client) = self_connection(dir.path());
        let verifier = MacPeerVerifier::new(dir.path().join(PIN_FILE_NAME));
        let code = |v: &MacPeerVerifier| v.inspect(accepted.as_fd(), true).unwrap().code;

        assert_eq!(code(&verifier), unverified(UnverifiedReason::NoPin));
        // A badly permissioned pin appears: BadPin, without a new verifier.
        let path = write_pin(dir.path(), 0o622, &good_pin_text());
        assert_eq!(code(&verifier), unverified(UnverifiedReason::BadPin));
        // Fixed: now the check runs, and this test binary is not the pinned app.
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(code(&verifier), unverified(UnverifiedReason::RequirementFailed));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn verifying_this_test_binary_against_a_foreign_pin_fails_the_requirement() {
        use std::os::fd::AsFd;
        let dir = tempfile::tempdir().unwrap();
        let (accepted, _client) = self_connection(dir.path());
        let token = audit_token(accepted.as_fd()).unwrap();
        let pin = OperatorPin::parse(&good_pin_text()).unwrap();
        assert_eq!(verify_code(&token, &pin), unverified(UnverifiedReason::RequirementFailed));
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
