//! Owners the author's PR list leaves out (`authored_prs_exclude_orgs`).
//!
//! Fixed for the daemon's life. The list is built from validated logins (see
//! `Config::resolve_authored_prs_exclude_orgs`), but is re-normalised here so
//! a caller cannot put anything but a login into the search query. Nothing in
//! this module logs or formats a name.

/// Lowercased GitHub owner logins to leave out. Empty changes nothing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExcludedOrgs(Vec<String>);

impl ExcludedOrgs {
    pub fn new<I, S>(orgs: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut out: Vec<String> = Vec::new();
        for o in orgs {
            let o = o.as_ref().trim().to_ascii_lowercase();
            let login = !o.is_empty()
                && o.len() <= 39
                && o.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
            if login && !out.contains(&o) {
                out.push(o);
            }
        }
        ExcludedOrgs(out)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The owner part of `owner/name` (any case) is excluded.
    pub fn covers_repo(&self, repo: &str) -> bool {
        match repo.split_once('/') {
            Some((owner, _)) => self.covers_owner(owner),
            None => false,
        }
    }

    /// An organisation login (any case) is excluded.
    pub fn covers_owner(&self, owner: &str) -> bool {
        self.0.iter().any(|o| o.eq_ignore_ascii_case(owner))
    }

    /// A persisted store key: `owner/name#number`.
    pub fn covers_key(&self, key: &str) -> bool {
        self.covers_repo(key.split('#').next().unwrap_or(""))
    }

    /// The query qualifiers (`+-org:login` each) that ask GitHub to leave the
    /// owners out at the source. Logins are `[a-z0-9-]`, so they need no
    /// percent-encoding; `+` is the space between qualifiers.
    pub fn search_qualifiers(&self) -> String {
        self.0.iter().map(|o| format!("+-org:{o}")).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_owner_matches_whatever_its_case() {
        let x = ExcludedOrgs::new(["Carefeed"]);
        assert!(x.covers_repo("carefeed/app"));
        assert!(x.covers_repo("CAREFEED/App"));
        assert!(x.covers_key("carefeed/app#4"));
        assert!(!x.covers_repo("carefeed-labs/app"));
        assert!(!x.covers_repo("thehammer/carefeed"));
        assert!(!x.covers_repo("carefeed"));
    }

    #[test]
    fn anything_that_is_not_a_login_is_dropped() {
        let x = ExcludedOrgs::new(["a/b", "c d", "", "ok", "x&y=1", "OK"]);
        assert_eq!(x.search_qualifiers(), "+-org:ok");
    }

    #[test]
    fn empty_adds_no_qualifiers() {
        let x = ExcludedOrgs::default();
        assert!(x.is_empty());
        assert_eq!(x.search_qualifiers(), "");
        assert!(!x.covers_repo("a/b"));
    }
}
