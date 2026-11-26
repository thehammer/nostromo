//! `nostromo push ...` (W13): the operator's classification of hosts, edited
//! only from a shell on the primary (there is no wire message for it, S5), and
//! a status read-out that never prints a token.

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::Utc;
use toml_edit::{value, DocumentMut, Item, Table};

use crate::config::{Config, PushConfig};
use crate::push::devices::{write_private_atomic, DeviceStore};
use crate::push::sent_log::SentLog;
use crate::push::wire::HostClass;

/// `[push.hosts]`: mark `host` as `work` or `personal`. The engine re-reads the
/// table on each render, so no restart is needed. Other keys and comments in the
/// file are kept.
pub fn set_host_class(config_path: &Path, host: &str, class: HostClass) -> Result<()> {
    if !crate::config::valid_host_name(host) {
        bail!("{host:?} is not a host name (^[a-z][a-z0-9-]{{0,15}}$)");
    }
    let mut doc = read_doc(config_path)?;
    let hosts = sub_table(push_table(&mut doc)?, "hosts")?;
    hosts[host] = value(match class {
        HostClass::Work => "work",
        HostClass::Personal => "personal",
    });
    write_doc(config_path, &doc)
}

/// `push.work_owners`: add an owner whose repositories never show a name. The
/// list only grows (`Carefeed` is always in it). `false` if it was there.
pub fn add_work_owner(config_path: &Path, owner: &str) -> Result<bool> {
    let owner = owner.trim();
    let valid = (1..=39).contains(&owner.len())
        && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !valid {
        bail!("{owner:?} is not a GitHub owner name");
    }
    let mut doc = read_doc(config_path)?;
    let push = push_table(&mut doc)?;
    let list = push
        .entry("work_owners")
        .or_insert_with(|| value(toml_edit::Array::new()))
        .as_array_mut()
        .context("push.work_owners is not a list")?;
    let known = std::iter::once(crate::config::DEFAULT_WORK_OWNER)
        .chain(list.iter().filter_map(|v| v.as_str()))
        .any(|o| o.eq_ignore_ascii_case(owner));
    if known {
        return Ok(false);
    }
    list.push(owner);
    write_doc(config_path, &doc)?;
    Ok(true)
}

/// Devices with their settings and last delivery, and the relay URL. Never a token.
pub fn status(config: &Config, out: &mut impl Write) -> Result<()> {
    let push = config.push.clone().unwrap_or_default();
    let dir = state_dir(&push);
    writeln!(
        out,
        "relay: {}",
        push.relay_url.as_deref().unwrap_or("(not set)")
    )?;
    writeln!(out, "enabled: {}", push.enabled)?;
    for (host, class) in &push.hosts {
        writeln!(out, "host {host}: {class:?}")?;
    }
    writeln!(
        out,
        "work owners: {}",
        push.resolved_work_owners().join(", ")
    )?;
    let devices = DeviceStore::load(dir.join("devices.json"));
    let log = SentLog::load(dir.join("sent.jsonl"), Utc::now());
    // A corrupt file reads as no devices, and the phone only sees "failed": say why.
    if let Some(file) = devices.unreadable_file() {
        writeln!(
            out,
            "registrations refused until the file is moved aside: {}",
            file.display()
        )?;
    }
    let mut any = false;
    for device in devices.iter() {
        any = true;
        let status = log.status(&device.push_id);
        let on = |b: bool| if b { "on" } else { "off" };
        let kinds = &device.prefs.kinds;
        writeln!(
            out,
            "device {}: {:?}, mother {}, decision {}, review {}, quiet {}-{} ({}), evening {}, last delivery {}{}",
            device.device_id,
            device.environment,
            on(kinds.mother),
            on(kinds.decision),
            on(kinds.review),
            device.prefs.quiet.start,
            device.prefs.quiet.end,
            on(device.prefs.quiet.enabled),
            device.prefs.evening_summary.as_deref().unwrap_or("off"),
            status
                .last_ok_at
                .map_or("never".to_string(), |t| t.to_rfc3339()),
            status
                .failing_since
                .map_or(String::new(), |t| format!(", failing since {}", t.to_rfc3339())),
        )?;
    }
    if !any && devices.unreadable_file().is_none() {
        writeln!(out, "no devices registered")?;
    }
    Ok(())
}

fn state_dir(push: &PushConfig) -> PathBuf {
    push.state_dir.clone().unwrap_or_else(|| {
        dirs_next::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".nostromo")
            .join("push")
    })
}

fn read_doc(path: &Path) -> Result<DocumentMut> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    text.parse()
        .with_context(|| format!("parsing {}", path.display()))
}

fn write_doc(path: &Path, doc: &DocumentMut) -> Result<()> {
    write_private_atomic(path, doc.to_string().as_bytes())
}

fn push_table(doc: &mut DocumentMut) -> Result<&mut Table> {
    sub_table(doc.as_table_mut(), "push")
}

fn sub_table<'a>(table: &'a mut Table, key: &str) -> Result<&'a mut Table> {
    let item = table.entry(key).or_insert_with(|| {
        let mut t = Table::new();
        t.set_implicit(true);
        Item::Table(t)
    });
    item.as_table_mut()
        .with_context(|| format!("{key} is not a table"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifying_a_host_keeps_the_rest_of_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "# mine\nhost_name = \"tokyo\"\n\n[push]\nrelay_url = \"https://r\"\n",
        )
        .unwrap();
        set_host_class(&path, "sendai", HostClass::Personal).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# mine") && text.contains("host_name = \"tokyo\""));
        let cfg: Config = toml::from_str(&text).unwrap();
        let push = cfg.push.unwrap();
        assert_eq!(push.relay_url.as_deref(), Some("https://r"));
        assert_eq!(push.hosts.get("sendai"), Some(&HostClass::Personal));
    }

    #[test]
    fn a_work_owner_is_added_once_and_the_default_cannot_be_added_again() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        assert!(add_work_owner(&path, "Acme").unwrap());
        assert!(!add_work_owner(&path, "acme").unwrap());
        assert!(!add_work_owner(&path, "carefeed").unwrap());
        let cfg: Config = toml::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            cfg.push.unwrap().resolved_work_owners(),
            ["Carefeed", "Acme"]
        );
        assert!(add_work_owner(&path, "bad owner").is_err());
    }

    fn status_text(state_dir: &Path) -> String {
        let config = Config {
            push: Some(PushConfig {
                state_dir: Some(state_dir.to_path_buf()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let mut out = Vec::new();
        status(&config, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn a_corrupt_devices_file_is_named_in_the_status_instead_of_reading_as_no_devices() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("devices.json");
        std::fs::write(&file, b"{ not json").unwrap();
        let text = status_text(dir.path());
        assert!(
            text.contains(&format!(
                "registrations refused until the file is moved aside: {}",
                file.display()
            )),
            "{text}"
        );
        assert!(!text.contains("no devices registered"), "{text}");
    }

    #[test]
    fn a_missing_devices_file_is_no_devices_and_not_a_refusal() {
        let dir = tempfile::tempdir().unwrap();
        let text = status_text(dir.path());
        assert!(text.contains("no devices registered"), "{text}");
        assert!(!text.contains("refused"), "{text}");
    }

    #[test]
    fn a_host_name_that_is_not_valid_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        assert!(set_host_class(&path, "Not A Host", HostClass::Work).is_err());
        assert!(!path.exists());
    }
}
