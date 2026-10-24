//! `nostromo-google-auth --account <label> [--no-browser]`
//!
//! Signs one configured Google account in once (desktop loopback + PKCE) and
//! writes its token file. Run it on the Mac that runs `nostromd`: the
//! browser's redirect goes to `127.0.0.1` on this machine.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

use nostromo::config::{Config, FredAccounts, FredProvider};
use nostromo::data::google_client::{GoogleClient, GoogleOAuthClient, GoogleOptions};

#[derive(Parser)]
#[command(about = "Sign in a configured Google account for Nostromo's Fred agent")]
struct Args {
    /// The `label` of a `[[fred_accounts]]` entry with provider = "google".
    #[arg(long)]
    account: String,
    /// Config file to read (default: the standard config location).
    #[arg(long)]
    config: Option<PathBuf>,
    /// Print the sign-in URL instead of opening the browser.
    #[arg(long)]
    no_browser: bool,
}

#[tokio::main]
async fn main() -> ExitCode {
    match run(Args::parse()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            eprintln!("{reason}");
            ExitCode::FAILURE
        }
    }
}

async fn run(args: Args) -> Result<(), String> {
    let config = Config::load(args.config.as_deref()).map_err(|e| format!("Could not read the config: {e:#}"))?;
    let (accounts, warnings) = config.resolve_fred_accounts();
    for w in warnings {
        eprintln!("warning: {w}");
    }
    let FredAccounts::Configured(accounts) = accounts else {
        return Err("No [[fred_accounts]] in the config.".to_owned());
    };
    let account = accounts
        .iter()
        .find(|a| a.label == args.account && a.provider == FredProvider::Google)
        .ok_or_else(|| format!("No Google account labelled '{}' in [[fred_accounts]].", args.account))?;

    let oauth_path = config.google_oauth_client_path();
    let oauth = GoogleOAuthClient::load(&oauth_path)
        .map_err(|e| format!("Google OAuth client file missing or invalid: {} ({e})", oauth_path.display()))?;

    let opts = GoogleOptions { open_browser: !args.no_browser, ..GoogleOptions::default() };
    let client = GoogleClient::shared(account, oauth, opts).map_err(|e| format!("{e:#}"))?;

    let label = account.label.clone();
    let email = client
        .run_loopback_until_done(|prompt| {
            println!("Open this link to sign in '{label}' (it expires at {}):", prompt.expires_at.format("%H:%M UTC"));
            println!("{}", prompt.verification_uri);
        })
        .await
        .map_err(|e| e.to_string())?;
    println!("Signed in {} as {email}", account.label);
    Ok(())
}
