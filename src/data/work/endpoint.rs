//! Checks for user-supplied service endpoints, applied before a credential is
//! sent anywhere or a link is shown. Small and generic so every work source
//! that sends a token somewhere configurable (Sentry now, Jira next) can use
//! the same rules with its own host test.

use url::{Host, Url};

/// `raw` as an API base: `https`, no user info, no explicit port, no query or
/// fragment, a host `host_ok` accepts, and a path that is exactly `api_path`
/// (a trailing slash is fine). Returns the canonical `https://host{api_path}`.
///
/// Parsing with the same `url` crate the HTTP client uses means what is
/// checked here is the host the request will really go to (`https://good@evil`
/// is `evil`, `https://evil\@good` is `evil`).
pub fn https_api_base(raw: &str, host_ok: impl Fn(&str) -> bool, api_path: &str) -> Option<String> {
    let url = https_url(raw, host_ok)?;
    if url.query().is_some() || url.fragment().is_some() || url.path().trim_end_matches('/') != api_path {
        return None;
    }
    Some(format!("https://{}{api_path}", url.host_str()?))
}

/// `raw` as a link worth showing: `https`, no user info, no explicit port and
/// a host `host_ok` accepts. Returns the normalised URL.
pub fn https_link(raw: &str, host_ok: impl Fn(&str) -> bool) -> Option<String> {
    https_url(raw.trim(), host_ok).map(String::from)
}

/// A slug that is safe to put in a URL path as it is: `[a-z0-9_-]+`.
pub fn is_slug(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

fn https_url(raw: &str, host_ok: impl Fn(&str) -> bool) -> Option<Url> {
    let url = Url::parse(raw).ok()?;
    let plain = url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none();
    match (plain, url.host()) {
        (true, Some(Host::Domain(host))) if host_ok(host) => Some(url),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sentry(host: &str) -> bool {
        host == "sentry.io" || host.ends_with(".sentry.io")
    }

    #[test]
    fn only_https_sentry_hosts_with_the_exact_api_path_pass() {
        for ok in ["https://sentry.io/api/0", "https://sentry.io/api/0/", "https://us.sentry.io/api/0", "HTTPS://Acme.Sentry.IO/api/0"] {
            assert!(https_api_base(ok, sentry, "/api/0").is_some(), "{ok}");
        }
        for bad in [
            "http://sentry.io/api/0",
            "https://evil.example/api/0",
            "https://sentry.io.evil.example/api/0",
            "https://notsentry.io/api/0",
            "https://sentry.io@evil.example/api/0",
            "https://evil.example\\@sentry.io/api/0",
            "https://sentry.io:8443/api/0",
            "https://sentry.io/api/0/../../x",
            "https://sentry.io/api/1",
            "https://sentry.io/api/0?x=1",
            "https://127.0.0.1/api/0",
            "ftp://sentry.io/api/0",
            "",
        ] {
            assert!(https_api_base(bad, sentry, "/api/0").is_none(), "{bad}");
        }
    }

    #[test]
    fn links_keep_only_https_on_an_accepted_host() {
        assert!(https_link("https://acme.sentry.io/organizations/acme/issues/1/", sentry).is_some());
        for bad in ["http://sentry.io/x", "javascript:alert(1)", "file:///etc/passwd", "https://sentry.io@evil.example/x"] {
            assert!(https_link(bad, sentry).is_none(), "{bad}");
        }
    }

    #[test]
    fn slugs_are_lowercase_words() {
        assert!(is_slug("acme") && is_slug("my-org_2"));
        for bad in ["", "Acme", "a b", "x/../..", "a%2Fb", "a.b", "acme?x=1"] {
            assert!(!is_slug(bad), "{bad:?}");
        }
    }
}
