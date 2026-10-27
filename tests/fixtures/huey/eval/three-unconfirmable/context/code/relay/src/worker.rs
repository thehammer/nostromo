use std::process::Command;

/// A queue worker: takes one job and runs it headless.
pub fn run_job(prompt: &str) -> std::io::Result<std::process::ExitStatus> {
    Command::new("claude").args(["-p", prompt]).status()
}
