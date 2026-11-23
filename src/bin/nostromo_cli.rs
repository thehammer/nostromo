//! `nostromo`: the command line for the local daemon. One subcommand group,
//! `device`, pairs and manages phones, iPads and satellite Macs. With no
//! subcommand it prints help and exits 0 (there is no TUI any more).

use std::io::Write;

use clap::{Parser, Subcommand};
use nostromo::device_cli;
use nostromo::ipc::devices::SatelliteAdmin;

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

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let cli = Cli::parse();
    let Some(Command::Device(device)) = cli.command else {
        use clap::CommandFactory;
        let _ = Cli::command().print_help();
        println!();
        return;
    };
    let code = match run(device).await {
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
        } => {
            let cancel = async {
                let _ = tokio::signal::ctrl_c().await;
            };
            device_cli::pair(&client, name, satellite, admin, &mut out, cancel).await
        }
        Device::List { all } => device_cli::list(&client, all, &mut out).await,
        Device::Revoke { device } => device_cli::revoke(&client, &device, &mut out).await,
        Device::Admin { host, level } => {
            device_cli::set_admin(&client, &host, level, &mut out).await
        }
    }
}
