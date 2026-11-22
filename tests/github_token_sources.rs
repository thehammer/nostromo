//! `GITHUB_TOKEN` beats every other token source. Its own test binary, so no
//! other test in the process can remove the variable while this one runs.

use std::os::unix::fs::PermissionsExt;

#[tokio::test]
async fn github_token_env_wins_over_gh_token_hosts_and_the_gh_cli() {
    let dir = tempfile::tempdir().unwrap();
    let gh = dir.path().join("gh");
    std::fs::write(&gh, "#!/bin/sh\necho gho_fromTheGhCli0123456789abcdef\n").unwrap();
    std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let hosts = dir.path().join("hosts.yml");
    std::fs::write(&hosts, "github.com:\n  oauth_token: from_hosts\n").unwrap();

    std::env::set_var("GITHUB_TOKEN", "from_github_env");
    std::env::set_var("GH_TOKEN", "from_gh_env");
    std::env::set_var("NOSTROMO_GH_CLI", &gh);

    let client = nostromo::data::github_client::GithubClient::new(Some(&hosts)).unwrap();
    assert_eq!(client.token(), "from_github_env");
}
