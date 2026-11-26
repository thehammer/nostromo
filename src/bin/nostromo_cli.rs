//! `nostromo`: the command line for the local daemon. One subcommand group,
//! `device`, pairs and manages phones, iPads and satellite Macs. With no
//! subcommand it prints help and exits 0 (there is no TUI any more).

use std::io::Write;

use clap::{Parser, Subcommand};
use nostromo::device_cli;
use nostromo::ipc::devices::{Egress, SatelliteAdmin};

#[derive(Parser)]
#[command(name = "nostromo", about = "Manage the local Nostromo daemon", version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Pair and manage phones, iPads and satellite Macs.
    #[command(subcommand)]
    Device(Device),
    /// Enrol this Mac as a satellite of a primary.
    #[command(subcommand)]
    Uplink(Uplink),
    /// Push notifications: classify hosts, set work owners, show status.
    #[command(subcommand)]
    Push(Push),
}

#[derive(Subcommand)]
enum Push {
    /// Mark a host as `work` (default for any host) or `personal`. Only a shell
    /// on the primary can; the phone shows the class read-only.
    Host {
        name: String,
        #[arg(value_parser = parse_host_class)]
        class: nostromo::push::wire::HostClass,
    },
    /// Manage the owners whose repository names never appear in a notification.
    #[command(subcommand)]
    WorkOwner(WorkOwner),
    /// Devices, their settings and last delivery, and the relay URL (no tokens).
    Status,
}

#[derive(Subcommand)]
enum WorkOwner {
    /// Add an owner (`Carefeed` is always in the list and cannot be removed).
    Add { owner: String },
}

fn parse_host_class(s: &str) -> Result<nostromo::push::wire::HostClass, String> {
    match s {
        "work" => Ok(nostromo::push::wire::HostClass::Work),
        "personal" => Ok(nostromo::push::wire::HostClass::Personal),
        _ => Err(format!("'{s}': expected work or personal")),
    }
}

#[derive(Subcommand)]
enum Uplink {
    /// Redeem a satellite enrolment code (from `nostromo device pair --satellite <host>`
    /// on the primary) and save the token for the uplink.
    Pair {
        /// The primary's WebSocket URL, e.g. ws://10.0.0.5:47101
        #[arg(long)]
        url: String,
        /// The code shown on the primary.
        code: String,
        /// Where to save the token (default: the `[uplink]` token_path, else ~/.nostromo/uplink-token).
        #[arg(long)]
        token_path: Option<std::path::PathBuf>,
    },
}

#[derive(Subcommand)]
enum Device {
    /// Show a pairing code and QR; stays running until the device pairs.
    Pair {
        /// A name to suggest for the device.
        name: Option<String>,
        /// Issue a satellite enrolment code for this host instead.
        #[arg(long, value_name = "HOST")]
        satellite: Option<String>,
        /// The satellite's device-admin level: full, revoke-only, read-only or off.
        #[arg(long, value_parser = parse_admin, requires = "satellite")]
        admin: Option<SatelliteAdmin>,
        /// What the satellite may publish upstream: work (default) or personal.
        #[arg(long, value_parser = parse_egress, requires = "satellite")]
        egress: Option<Egress>,
    },
    /// List paired devices.
    List {
        /// Include satellite Macs and their admin level.
        #[arg(long)]
        all: bool,
    },
    /// Revoke a device by name or id.
    Revoke { device: String },
    /// Change a satellite's device-admin level.
    Admin {
        host: String,
        #[arg(value_parser = parse_admin)]
        level: SatelliteAdmin,
    },
}

fn parse_admin(s: &str) -> Result<SatelliteAdmin, String> {
    SatelliteAdmin::parse(s)
        .ok_or_else(|| format!("'{s}': expected full, revoke-only, read-only or off"))
}

fn parse_egress(s: &str) -> Result<Egress, String> {
    Egress::parse(s).ok_or_else(|| format!("'{s}': expected work or personal"))
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let cli = Cli::parse();
    let result = match cli.command {
        Some(Command::Device(device)) => run(device).await,
        Some(Command::Uplink(uplink)) => run_uplink(uplink).await,
        Some(Command::Push(push)) => run_push(push),
        None => {
            use clap::CommandFactory;
            let _ = Cli::command().print_help();
            println!();
            return;
        }
    };
    let code = match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("{e:#}");
            device_cli::EXIT_FAILED
        }
    };
    let _ = std::io::stdout().flush();
    std::process::exit(code);
}

async fn run(device: Device) -> anyhow::Result<i32> {
    let client = device_cli::connect().await?;
    let mut out = std::io::stdout();
    match device {
        Device::Pair {
            name,
            satellite,
            admin,
            egress,
        } => {
            let cancel = async {
                let _ = tokio::signal::ctrl_c().await;
            };
            device_cli::pair(&client, name, satellite, admin, egress, &mut out, cancel).await
        }
        Device::List { all } => device_cli::list(&client, all, &mut out).await,
        Device::Revoke { device } => device_cli::revoke(&client, &device, &mut out).await,
        Device::Admin { host, level } => {
            device_cli::set_admin(&client, &host, level, &mut out).await
        }
    }
}

async fn run_uplink(uplink: Uplink) -> anyhow::Result<i32> {
    let Uplink::Pair {
        url,
        code,
        token_path,
    } = uplink;
    let config = nostromo::config::Config::load(None)?;
    let host = config.satellite_setup().map(|s| s.host).or_else(|_| {
        let name = config
            .host_name
            .clone()
            .ok_or_else(|| anyhow::anyhow!("set host_name in config.toml first"))?;
        if nostromo::config::valid_host_name(&name) {
            Ok(name)
        } else {
            Err(anyhow::anyhow!(
                "host_name {name:?} is not a valid host name (^[a-z][a-z0-9-]{{0,15}}$); fix config.toml first"
            ))
        }
    })?;
    let token_path = token_path
        .or_else(|| config.uplink.as_ref().map(|u| u.token_path.clone()))
        .unwrap_or_else(nostromo::config::default_uplink_token_path);
    let mut out = std::io::stdout();
    nostromo::uplink_cli::pair(&url, &code, &host, &token_path, &mut out).await
}

fn run_push(push: Push) -> anyhow::Result<i32> {
    let mut out = std::io::stdout();
    match push {
        Push::Status => {
            let config = nostromo::config::Config::load(None)?;
            nostromo::push::cli::status(&config, &mut out)?;
        }
        Push::Host { name, class } => {
            let path = nostromo::config::default_config_path()?;
            nostromo::push::cli::set_host_class(&path, &name, class)?;
            writeln!(out, "{name}: {class:?}")?;
        }
        Push::WorkOwner(WorkOwner::Add { owner }) => {
            let path = nostromo::config::default_config_path()?;
            let added = nostromo::push::cli::add_work_owner(&path, &owner)?;
            writeln!(
                out,
                "{owner}: {}",
                if added { "added" } else { "already a work owner" }
            )?;
        }
    }
    Ok(0)
}
