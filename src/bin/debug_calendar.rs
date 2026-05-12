//! debug-calendar — run the calendar fetch and print results to stdout.
//!
//! Usage: debug-calendar [--config path]
//!
//! Hits the same Graph API endpoint nostromo uses, deserialises events with the
//! same struct, runs build_snapshot logic, and prints every event + the final
//! snapshot summary.  Useful for diagnosing blank calendar issues without
//! starting the full TUI.

use anyhow::{Context, Result};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use clap::Parser;
use serde::Deserialize;
use std::path::PathBuf;

use nostromo::{config::Config, data::graph_client::GraphClient};

#[derive(Parser, Debug)]
#[command(name = "debug-calendar", about = "Debug calendar Graph API fetch")]
struct Args {
    #[arg(long)]
    config: Option<PathBuf>,

    /// Show raw JSON for each event
    #[arg(long)]
    raw: bool,
}

// ── Same structs as fred_calendar_native ─────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphEvent {
    subject: Option<String>,
    start: Option<GraphDt>,
    end: Option<GraphDt>,
    response_status: Option<GraphResponseStatus>,
    is_cancelled: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphDt {
    date_time: Option<String>,
    time_zone: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphResponseStatus {
    response: Option<String>,
}

fn parse_dt(s: &str) -> Option<DateTime<Utc>> {
    let clean = s.trim_end_matches('Z').split('.').next().unwrap_or(s);
    let with_z = format!("{clean}Z");
    DateTime::parse_from_rfc3339(&with_z)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

fn calendar_view_path() -> String {
    let today_local = chrono::Local::now().date_naive();
    let start_local = today_local.and_hms_opt(0, 0, 0).expect("midnight valid");
    let start_utc: DateTime<Utc> =
        chrono::TimeZone::from_local_datetime(&chrono::Local, &start_local)
            .single()
            .unwrap_or_else(|| Utc::now().with_timezone(&chrono::Local))
            .with_timezone(&Utc);
    let end_utc = start_utc + ChronoDuration::hours(24);
    format!(
        "/me/calendarView?startDateTime={}&endDateTime={}&$select=subject,start,end,responseStatus,isCancelled&$top=50",
        start_utc.format("%Y-%m-%dT%H:%M:%SZ"),
        end_utc.format("%Y-%m-%dT%H:%M:%SZ"),
    )
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let config = Config::load(args.config.as_deref())
        .context("loading config")?;

    let client_id = config.graph_client_id.clone()
        .context("graph_client_id not set in config")?;
    let tenant = config.graph_tenant.clone()
        .unwrap_or_else(|| "common".to_owned());
    let cache_path = config.graph_token_cache_path();

    let graph = GraphClient::new(client_id, tenant, cache_path).await?;

    println!("Checking auth…");
    match graph.ensure_authed().await? {
        Some(prompt) => {
            println!("⚠  Need to sign in: {} (code: {})", prompt.verification_uri, prompt.user_code);
            return Ok(());
        }
        None => println!("✓ Authenticated"),
    }

    let path = calendar_view_path();
    println!("\nFetching: https://graph.microsoft.com/v1.0{path}\n");

    // Fetch raw JSON so we can show it if --raw
    let url = format!("https://graph.microsoft.com/v1.0{path}");
    let page: serde_json::Value = graph.get_json(&url).await?;

    let arr = page.get("value").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    println!("Raw event count from API: {}", arr.len());

    if let Some(err) = page.get("error") {
        println!("⚠  API error: {err}");
        return Ok(());
    }

    println!();
    let now = Utc::now();
    let mut shown = 0usize;

    for item in &arr {
        if args.raw {
            println!("{}", serde_json::to_string_pretty(item)?);
            println!("---");
        }

        match serde_json::from_value::<GraphEvent>(item.clone()) {
            Ok(ev) => {
                let subject = ev.subject.as_deref().unwrap_or("(no subject)");
                let start_raw = ev.start.as_ref().and_then(|d| d.date_time.as_deref()).unwrap_or("?");
                let end_raw   = ev.end.as_ref().and_then(|d| d.date_time.as_deref()).unwrap_or("?");
                let tz        = ev.start.as_ref().and_then(|d| d.time_zone.as_deref()).unwrap_or("?");
                let start_utc = ev.start.as_ref().and_then(|d| d.date_time.as_deref()).and_then(parse_dt);
                let response  = ev.response_status.as_ref().and_then(|r| r.response.as_deref()).unwrap_or("");
                let cancelled = ev.is_cancelled.unwrap_or(false);

                let is_now = start_utc.map(|s| s <= now).unwrap_or(false)
                    && ev.end.as_ref().and_then(|d| d.date_time.as_deref()).and_then(parse_dt)
                       .map(|e| e > now).unwrap_or(false);

                let local_start = start_utc.map(|s| {
                    let l: chrono::DateTime<chrono::Local> = s.into();
                    l.format("%H:%M").to_string()
                }).unwrap_or_else(|| "?".to_owned());

                let status_tag = if cancelled || subject.starts_with("Canceled:") {
                    " [cancelled]"
                } else if response == "declined" {
                    " [declined]"
                } else if is_now {
                    " ← NOW"
                } else {
                    ""
                };

                println!(
                    "  {local_start} CDT  |  {subject}{status_tag}"
                );
                println!(
                    "           raw start={start_raw} tz={tz}  utc_parsed={}  end={end_raw}",
                    start_utc.map(|s| s.to_string()).unwrap_or_else(|| "PARSE FAIL".to_owned())
                );
                shown += 1;
            }
            Err(e) => {
                println!("  ⚠  deserialise failed: {e}");
                println!("     raw: {}", serde_json::to_string(item)?);
            }
        }
        println!();
    }

    println!("─────────────────────────────");
    println!("Total: {} events from API, {} deserialized OK", arr.len(), shown);

    Ok(())
}
