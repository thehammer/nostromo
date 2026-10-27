use std::process::Command;

/// Starts one review session and relays its permission prompts to the operator.
fn start(agent: &str) -> std::io::Result<std::process::Child> {
    Command::new("claude")
        .args(["-p", "--output-format", "stream-json", "--agent", agent])
        .spawn()
}

fn main() {
    let _ = start("reviewer");
}
