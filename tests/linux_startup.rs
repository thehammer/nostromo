//! Linux primary: the daemon starts and stays up on a bare host.
//!
//! A Linux primary has no operator app, no `mother`, `gh` or `aws` on PATH and
//! no `~/.claude` directory. These tests start the real `nostromd` binary in a
//! hermetic HOME with an empty PATH and assert what an operator can observe:
//! the process stays alive, the IPC socket appears, and the log says the right
//! things (one actionable warning about `mother`, no noise about tools the
//! documented primary config turned off).
#![cfg(target_os = "linux")]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use tempfile::TempDir;

/// A running daemon plus the hermetic directories it lives in. Killed on drop,
/// so a failing assertion never leaks a process.
struct Daemon {
    child: Child,
    home: TempDir,
    _empty_path: TempDir,
}

impl Daemon {
    fn start(config_toml: Option<&str>) -> Self {
        let home = tempfile::tempdir().expect("home tempdir");
        let empty_path = tempfile::tempdir().expect("empty PATH tempdir");

        if let Some(cfg) = config_toml {
            let dir = home.path().join(".config").join("nostromo");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("config.toml"), cfg).unwrap();
        }

        let child = Command::new(env!("CARGO_BIN_EXE_nostromd"))
            .env_clear()
            .env("HOME", home.path())
            .env("PATH", empty_path.path())
            .env("RUST_LOG", "info")
            .env("NOSTROMD_TCP_ADDR", "127.0.0.1:0")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn nostromd");

        Daemon {
            child,
            home,
            _empty_path: empty_path,
        }
    }

    fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    fn socket_path(&self) -> PathBuf {
        self.home.path().join(".nostromo").join("nostromd.sock")
    }

    fn log_dir(&self) -> PathBuf {
        self.home.path().join(".cache").join("nostromd").join("log")
    }

    /// Every JSON log line from every `nostromd.log*` file, as (LEVEL, message).
    fn log_lines(&self) -> Vec<(String, String)> {
        let Ok(entries) = std::fs::read_dir(self.log_dir()) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("nostromd.log") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(entry.path()) else {
                continue;
            };
            for line in text.lines() {
                let Ok(v) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                let level = v["level"].as_str().unwrap_or("").to_string();
                let message = v["fields"]["message"].as_str().unwrap_or("").to_string();
                out.push((level, message));
            }
        }
        out
    }

    /// Poll until `pred` holds over the log lines, or the deadline passes.
    fn wait_for_logs(
        &self,
        timeout: Duration,
        pred: impl Fn(&[(String, String)]) -> bool,
    ) -> Vec<(String, String)> {
        let deadline = Instant::now() + timeout;
        loop {
            let lines = self.log_lines();
            if pred(&lines) || Instant::now() >= deadline {
                return lines;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// Let the daemon run for the fixed startup window, failing early if it dies.
    fn run_startup_window(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            assert!(
                self.is_alive(),
                "nostromd exited during its first 3 seconds; log: {:?}",
                self.log_lines()
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(self.is_alive(), "nostromd is not running after 3 seconds");
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn is_warn(level: &str) -> bool {
    level.eq_ignore_ascii_case("WARN")
}

fn is_warn_or_error(level: &str) -> bool {
    is_warn(level) || level.eq_ignore_ascii_case("ERROR")
}

fn mentions(message: &str, needle: &str) -> bool {
    message.to_lowercase().contains(&needle.to_lowercase())
}

fn assert_socket_exists(path: &Path) {
    assert!(
        path.exists(),
        "IPC socket {} was not created",
        path.display()
    );
}

#[test]
fn bare_primary_stays_up_and_warns_once_about_mother() {
    let mut d = Daemon::start(None);
    d.run_startup_window();

    assert_socket_exists(&d.socket_path());

    let lines = d.wait_for_logs(Duration::from_secs(5), |l| {
        l.iter()
            .any(|(lvl, m)| is_warn(lvl) && mentions(m, "mother CLI not found"))
    });

    let mother_warns: Vec<_> = lines
        .iter()
        .filter(|(lvl, m)| is_warn(lvl) && mentions(m, "mother CLI not found"))
        .collect();
    assert_eq!(
        mother_warns.len(),
        1,
        "expected exactly one WARN about the missing mother CLI, got {mother_warns:?}; all lines: {lines:?}"
    );

    assert!(
        lines
            .iter()
            .any(|(_, m)| mentions(m, "operator app verification unavailable")),
        "expected the operator-app-verification-unavailable line; got {lines:?}"
    );

    assert!(d.is_alive(), "nostromd died while the log was being read");
}

#[test]
fn documented_primary_config_starts_clean() {
    let config = "\
authored_prs_enabled = false
[agents.fred]
enabled = false
[agents.teri]
enabled = false
[agents.huey]
enabled = false
[agents.perri]
enabled = false
";
    let mut d = Daemon::start(Some(config));
    d.run_startup_window();

    assert_socket_exists(&d.socket_path());

    // Give the mother poller time to have logged its single warning, if any.
    let lines = d.wait_for_logs(Duration::from_secs(5), |l| {
        l.iter().any(|(_, m)| mentions(m, "mother CLI not found"))
    });

    for subject in ["gh", "aws", "bishop", "huey"] {
        let offenders: Vec<_> = lines
            .iter()
            .filter(|(lvl, m)| {
                is_warn_or_error(lvl)
                    && m.to_lowercase()
                        .split(|c: char| !c.is_alphanumeric())
                        .any(|w| w == subject)
            })
            .collect();
        assert!(
            offenders.is_empty(),
            "the documented primary config must not warn or error about {subject}: {offenders:?}"
        );
    }

    let mother_warns = lines
        .iter()
        .filter(|(lvl, m)| is_warn(lvl) && mentions(m, "mother"))
        .count();
    assert!(
        mother_warns <= 1,
        "at most one WARN about mother is allowed, got {mother_warns}; lines: {lines:?}"
    );

    assert!(d.is_alive(), "nostromd died while the log was being read");
}

#[test]
fn activity_tailer_survives_missing_claude_dir_and_follows_file_when_it_appears() {
    let mut d = Daemon::start(None);
    d.run_startup_window();

    // Append a valid event; the file (and ~/.claude) may or may not exist yet.
    let claude_dir = d.home.path().join(".claude");
    std::fs::create_dir_all(&claude_dir).unwrap();
    let event = serde_json::json!({
        "ts": "2026-11-23T12:00:00Z",
        "agent": "cody",
        "kind": "tool_use",
        "summary": "linux startup test event",
        "tool_name": "Read",
    });
    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(claude_dir.join("activity.jsonl"))
            .unwrap();
        writeln!(f, "{event}").unwrap();
    }

    // Give the tailer time to notice and process the line.
    std::thread::sleep(Duration::from_secs(2));

    assert!(d.is_alive(), "nostromd died after activity.jsonl appeared");
    let lines = d.log_lines();
    assert!(
        !lines
            .iter()
            .any(|(_, m)| mentions(m, "activity tailer exited")),
        "the activity tailer must keep following the file; lines: {lines:?}"
    );
}
