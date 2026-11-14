//! Which focus owns a PR. Pure: facts in, an [`Owner`] out.
//!
//! Evidence, in order: a Mother job whose verified origin is a focus and whose
//! PR is this one; a link the user made (slice 3; the map is empty for now);
//! an open focus whose working copy is on the PR's repo and head branch.
//! Never guess: two plausible owners are `ambiguous`.

use std::collections::{BTreeMap, HashMap};

use super::snapshot::{Candidate, Owner, OwnerKind, Via, MAX_CANDIDATES, MAX_NAME};
use crate::data::work::untrusted::one_line;
use crate::mother::notices::pr_state::PrRef;
use crate::mother::origin::OriginKind;
use crate::mother::MotherJob;

/// A PR's identity for ownership: lowercased `owner/name` and number.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PrKey {
    pub repo: String,
    pub number: u64,
}

/// A focus that is open (in the registry the Mac pushed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenFocus {
    pub tag: String,
    pub name: String,
}

/// Where a focus's session is working right now, as read from files.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WorkingCopy {
    /// Lowercased `owner/name` of the `origin` remote, when it is GitHub's.
    pub repo: Option<String>,
    /// The checked-out branch; `None` when detached.
    pub branch: Option<String>,
}

/// A link the user made between a PR and a focus (slice 3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    pub tag: String,
    pub name: String,
    pub open: bool,
}

struct Claim {
    tag: String,
    name: String,
    open: bool,
    via: Via,
    job_id: Option<String>,
}

fn name_of(s: &str) -> String {
    one_line(s, MAX_NAME)
}

fn mother_claims(key: &PrKey, jobs: &[MotherJob]) -> Vec<Claim> {
    // tag -> (created_at of the newest job, claim)
    let mut by_tag: BTreeMap<String, (Option<chrono::DateTime<chrono::Utc>>, Claim)> =
        BTreeMap::new();
    for job in jobs {
        let Some(url) = job.pr_url.as_deref() else {
            continue;
        };
        let Some(pr) = PrRef::parse(url) else {
            continue;
        };
        if pr.number != key.number || format!("{}/{}", pr.owner, pr.name) != key.repo {
            continue;
        }
        let Some(origin) = job.nostromo.as_ref().map(|n| &n.origin) else {
            continue;
        };
        // Only a focus the daemon vouches for owns anything. Unverified, You
        // and Unknown are not owners.
        if origin.kind != OriginKind::Focus {
            continue;
        }
        let Some(tag) = origin.focus_tag.clone() else {
            continue;
        };
        let name = origin
            .focus_name
            .as_deref()
            .or(origin.name_snapshot.as_deref())
            .unwrap_or("");
        let claim = Claim {
            tag: tag.clone(),
            name: name_of(name),
            open: origin.closed != Some(true),
            via: Via::MotherJob,
            job_id: Some(job.id.clone()),
        };
        match by_tag.get(&tag) {
            Some((seen, _)) if *seen >= job.created_at => {}
            _ => {
                by_tag.insert(tag, (job.created_at, claim));
            }
        }
    }
    by_tag.into_values().map(|(_, c)| c).collect()
}

fn candidate(c: &Claim) -> Candidate {
    Candidate {
        tag: c.tag.clone(),
        name: c.name.clone(),
        via: c.via,
        job_id: c.job_id.clone(),
        closed: !c.open,
    }
}

fn ambiguous(mut cands: Vec<Candidate>) -> Owner {
    cands.truncate(MAX_CANDIDATES);
    Owner {
        kind: OwnerKind::Ambiguous,
        tag: None,
        name: None,
        job_id: None,
        via: None,
        candidates: cands,
    }
}

/// Resolve the owner of the PR `key` whose head branch is `head_ref`.
pub fn resolve(
    key: &PrKey,
    head_ref: Option<&str>,
    jobs: &[MotherJob],
    focuses: &[OpenFocus],
    copies: &HashMap<String, WorkingCopy>,
    links: &HashMap<PrKey, Link>,
) -> Owner {
    // Mother and linked evidence, one claim per distinct tag (a Mother job
    // outranks a link to the same focus).
    let mut claims = mother_claims(key, jobs);
    if let Some(link) = links.get(key) {
        if !claims.iter().any(|c| c.tag == link.tag) {
            claims.push(Claim {
                tag: link.tag.clone(),
                name: name_of(&link.name),
                open: link.open,
                via: Via::Linked,
                job_id: None,
            });
        }
    }

    // Open focuses working on this repo and branch. `on_branch` compares the
    // PR's head *branch name* only: a PR from a fork never matches, because its
    // branch is not in any checkout of the base repo (a fork's `feat` is not
    // the base repo's `feat`, and a branch named alike must not claim it).
    let on_branch: Vec<Claim> = match head_ref {
        Some(branch) => focuses
            .iter()
            .filter(|f| {
                copies.get(&f.tag).is_some_and(|c| {
                    c.repo.as_deref() == Some(key.repo.as_str())
                        && c.branch.as_deref() == Some(branch)
                })
            })
            .map(|f| Claim {
                tag: f.tag.clone(),
                name: name_of(&f.name),
                open: true,
                via: Via::OnBranch,
                job_id: None,
            })
            .collect(),
        None => Vec::new(),
    };

    if claims.len() >= 2 {
        let mut all: Vec<Candidate> = claims.iter().map(candidate).collect();
        all.extend(
            on_branch
                .iter()
                .filter(|b| !claims.iter().any(|c| c.tag == b.tag))
                .map(candidate),
        );
        return ambiguous(all);
    }

    if let Some(c) = claims.first() {
        let others: Vec<&Claim> = on_branch.iter().filter(|b| b.tag != c.tag).collect();
        if !others.is_empty() {
            // Either an open owner and a different focus on the branch, or a
            // closed owner while someone else is on the branch: never guess.
            let mut all = vec![candidate(c)];
            all.extend(others.into_iter().map(candidate));
            return ambiguous(all);
        }
        if c.open {
            return Owner {
                kind: match c.via {
                    Via::Linked => OwnerKind::Linked,
                    _ => OwnerKind::MotherJob,
                },
                tag: Some(c.tag.clone()),
                name: Some(c.name.clone()),
                job_id: c.job_id.clone(),
                via: Some(c.via),
                candidates: Vec::new(),
            };
        }
        return Owner {
            kind: OwnerKind::Closed,
            tag: Some(c.tag.clone()),
            name: Some(c.name.clone()),
            job_id: c.job_id.clone(),
            via: Some(c.via),
            candidates: Vec::new(),
        };
    }

    match on_branch.len() {
        0 => Owner::unknown(),
        1 => {
            let c = &on_branch[0];
            Owner {
                kind: OwnerKind::OnBranch,
                tag: Some(c.tag.clone()),
                name: Some(c.name.clone()),
                job_id: None,
                via: Some(Via::OnBranch),
                candidates: Vec::new(),
            }
        }
        _ => ambiguous(on_branch.iter().map(candidate).collect()),
    }
}

#[cfg(test)]
mod tests {
    //! Which focus owns a PR: facts in, an owner out. The table is the contract:
    //! a vouched Mother job is an owner, an unvouched one never is, two
    //! plausible owners are ambiguous, and nothing is ever guessed.

    use super::*;
    use crate::mother::origin::{JobAnnotation, OriginView};

    const REPO: &str = "carefeed/app";
    const URL: &str = "https://github.com/Carefeed/app/pull/7";

    fn key() -> PrKey {
        PrKey {
            repo: REPO.into(),
            number: 7,
        }
    }

    fn origin(kind: OriginKind, tag: Option<&str>, closed: Option<bool>) -> OriginView {
        OriginView {
            kind,
            focus_tag: tag.map(str::to_owned),
            name_snapshot: tag.map(|t| format!("{t} (then)")),
            focus_name: tag.map(|t| format!("{t} now")),
            closed,
            session_prefix: None,
        }
    }

    fn job_with(id: &str, pr_url: Option<&str>, origin: Option<OriginView>) -> MotherJob {
        MotherJob {
            id: id.into(),
            pr_url: pr_url.map(str::to_owned),
            nostromo: origin.map(|origin| JobAnnotation {
                origin,
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn focus_job(id: &str, tag: &str) -> MotherJob {
        job_with(
            id,
            Some(URL),
            Some(origin(OriginKind::Focus, Some(tag), None)),
        )
    }

    fn focuses(tags: &[&str]) -> Vec<OpenFocus> {
        tags.iter()
            .map(|t| OpenFocus {
                tag: (*t).into(),
                name: format!("{t} now"),
            })
            .collect()
    }

    fn copy(repo: &str, branch: &str) -> WorkingCopy {
        WorkingCopy {
            repo: Some(repo.into()),
            branch: Some(branch.into()),
        }
    }

    fn resolve_with(
        jobs: &[MotherJob],
        open: &[&str],
        copies: &[(&str, WorkingCopy)],
        head: Option<&str>,
    ) -> Owner {
        let copies: HashMap<String, WorkingCopy> = copies
            .iter()
            .map(|(t, c)| ((*t).to_owned(), c.clone()))
            .collect();
        resolve(&key(), head, jobs, &focuses(open), &copies, &HashMap::new())
    }

    fn tags(o: &Owner) -> Vec<&str> {
        let mut t: Vec<&str> = o.candidates.iter().map(|c| c.tag.as_str()).collect();
        t.sort();
        t
    }

    // ── a Mother job ──────────────────────────────────────────────────────

    #[test]
    fn a_vouched_mother_job_for_this_pr_makes_its_focus_the_owner() {
        let o = resolve_with(
            &[focus_job("job-1", "alpha")],
            &["alpha"],
            &[],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::MotherJob);
        assert_eq!(o.tag.as_deref(), Some("alpha"));
        assert_eq!(
            o.name.as_deref(),
            Some("alpha now"),
            "the focus's current name"
        );
        assert_eq!(o.job_id.as_deref(), Some("job-1"));
        assert_eq!(o.via, Some(Via::MotherJob));
        assert!(o.candidates.is_empty());
    }

    #[test]
    fn the_pr_url_is_matched_by_repo_and_number_without_regard_to_case_or_sub_page() {
        for url in [
            "https://github.com/carefeed/APP/pull/7",
            "https://github.com/Carefeed/app/pull/7/files",
            "https://github.com/Carefeed/app/pull/7?x=1#frag",
        ] {
            let j = job_with(
                "j",
                Some(url),
                Some(origin(OriginKind::Focus, Some("alpha"), None)),
            );
            assert_eq!(
                resolve_with(&[j], &["alpha"], &[], None).kind,
                OwnerKind::MotherJob,
                "{url}"
            );
        }
    }

    #[test]
    fn a_job_for_another_pr_or_with_no_pr_is_no_evidence() {
        for url in [
            Some("https://github.com/Carefeed/app/pull/8"),
            Some("https://github.com/Carefeed/other/pull/7"),
            Some("https://github.com/thehammer/app/pull/7"),
            Some("not a url"),
            None,
        ] {
            let j = job_with(
                "j",
                url,
                Some(origin(OriginKind::Focus, Some("alpha"), None)),
            );
            assert_eq!(
                resolve_with(&[j], &["alpha"], &[], None).kind,
                OwnerKind::Unknown,
                "{url:?}"
            );
        }
    }

    #[test]
    fn two_jobs_from_two_focuses_make_the_pr_ambiguous_naming_both() {
        let o = resolve_with(
            &[focus_job("j1", "alpha"), focus_job("j2", "beta")],
            &["alpha", "beta"],
            &[],
            None,
        );
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(tags(&o), vec!["alpha", "beta"]);
        assert!(o.tag.is_none() && o.name.is_none() && o.job_id.is_none() && o.via.is_none());
    }

    #[test]
    fn two_jobs_from_one_focus_are_one_owner() {
        let o = resolve_with(
            &[focus_job("j1", "alpha"), focus_job("j2", "alpha")],
            &["alpha"],
            &[],
            None,
        );
        assert_eq!(o.kind, OwnerKind::MotherJob);
        assert_eq!(o.tag.as_deref(), Some("alpha"));
    }

    #[test]
    fn the_newest_job_of_a_focus_is_the_one_named() {
        use chrono::TimeZone;
        let mut old = focus_job("old", "alpha");
        old.created_at = Some(chrono::Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap());
        let mut new = focus_job("new", "alpha");
        new.created_at = Some(chrono::Utc.with_ymd_and_hms(2026, 6, 1, 0, 0, 0).unwrap());
        for jobs in [[old.clone(), new.clone()], [new.clone(), old.clone()]] {
            let o = resolve_with(&jobs, &["alpha"], &[], None);
            assert_eq!(o.job_id.as_deref(), Some("new"));
        }
    }

    // ── origins that are not owners ───────────────────────────────────────

    #[test]
    fn unverified_you_and_unknown_origins_are_never_owners() {
        for kind in [OriginKind::Unverified, OriginKind::You, OriginKind::Unknown] {
            let j = job_with("j", Some(URL), Some(origin(kind, Some("alpha"), None)));
            let o = resolve_with(&[j], &["alpha"], &[], None);
            assert_eq!(o.kind, OwnerKind::Unknown, "{kind:?}");
            assert!(
                o.tag.is_none() && o.candidates.is_empty(),
                "{kind:?}: {o:?}"
            );
        }
    }

    #[test]
    fn a_job_with_no_daemon_annotation_or_no_tag_is_not_an_owner() {
        let none = job_with("j", Some(URL), None);
        assert_eq!(
            resolve_with(&[none], &["alpha"], &[], None).kind,
            OwnerKind::Unknown
        );
        let no_tag = job_with("j", Some(URL), Some(origin(OriginKind::Focus, None, None)));
        assert_eq!(
            resolve_with(&[no_tag], &["alpha"], &[], None).kind,
            OwnerKind::Unknown
        );
    }

    #[test]
    fn an_unvouched_job_does_not_stop_a_focus_on_the_branch_from_being_the_owner() {
        let j = job_with(
            "j",
            Some(URL),
            Some(origin(OriginKind::Unverified, Some("alpha"), None)),
        );
        let o = resolve_with(
            &[j],
            &["beta"],
            &[("beta", copy(REPO, "feat"))],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::OnBranch);
        assert_eq!(o.tag.as_deref(), Some("beta"));
    }

    // ── an owner that has closed ──────────────────────────────────────────

    #[test]
    fn a_closed_owner_with_no_open_candidate_is_closed_naming_via_tag_and_name() {
        let j = job_with(
            "job-9",
            Some(URL),
            Some(origin(OriginKind::Focus, Some("gone"), Some(true))),
        );
        let o = resolve_with(&[j], &["alpha"], &[], Some("feat"));
        assert_eq!(o.kind, OwnerKind::Closed);
        assert_eq!(o.via, Some(Via::MotherJob));
        assert_eq!(o.tag.as_deref(), Some("gone"));
        assert_eq!(o.name.as_deref(), Some("gone now"));
        assert_eq!(o.job_id.as_deref(), Some("job-9"));
        assert!(o.candidates.is_empty());
    }

    #[test]
    fn a_closed_owner_falls_back_to_the_name_it_had_when_the_job_was_queued() {
        let mut ov = origin(OriginKind::Focus, Some("gone"), Some(true));
        ov.focus_name = None;
        let o = resolve_with(&[job_with("j", Some(URL), Some(ov))], &[], &[], None);
        assert_eq!(o.kind, OwnerKind::Closed);
        assert_eq!(o.name.as_deref(), Some("gone (then)"));
    }

    #[test]
    fn a_closed_owner_with_an_open_focus_on_the_branch_is_ambiguous() {
        let j = job_with(
            "j",
            Some(URL),
            Some(origin(OriginKind::Focus, Some("gone"), Some(true))),
        );
        let o = resolve_with(
            &[j],
            &["beta"],
            &[("beta", copy(REPO, "feat"))],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(tags(&o), vec!["beta", "gone"]);
    }

    // ── on the branch ─────────────────────────────────────────────────────

    #[test]
    fn an_open_owner_and_a_different_focus_on_the_branch_are_ambiguous() {
        let o = resolve_with(
            &[focus_job("j", "alpha")],
            &["alpha", "beta"],
            &[("beta", copy(REPO, "feat"))],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(tags(&o), vec!["alpha", "beta"]);
    }

    #[test]
    fn the_owner_itself_being_on_the_branch_is_still_one_owner() {
        let o = resolve_with(
            &[focus_job("j", "alpha")],
            &["alpha"],
            &[("alpha", copy(REPO, "feat"))],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::MotherJob);
        assert_eq!(o.tag.as_deref(), Some("alpha"));
    }

    #[test]
    fn with_no_mother_owner_one_focus_on_the_branch_is_on_branch() {
        let o = resolve_with(
            &[],
            &["alpha", "beta"],
            &[("alpha", copy(REPO, "feat")), ("beta", copy(REPO, "other"))],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::OnBranch);
        assert_eq!(o.tag.as_deref(), Some("alpha"));
        assert_eq!(o.name.as_deref(), Some("alpha now"));
        assert_eq!(o.via, Some(Via::OnBranch));
        assert!(o.job_id.is_none() && o.candidates.is_empty());
    }

    #[test]
    fn two_or_more_focuses_on_the_branch_are_ambiguous() {
        let o = resolve_with(
            &[],
            &["alpha", "beta", "gamma"],
            &[
                ("alpha", copy(REPO, "feat")),
                ("beta", copy(REPO, "feat")),
                ("gamma", copy(REPO, "feat")),
            ],
            Some("feat"),
        );
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(tags(&o), vec!["alpha", "beta", "gamma"]);
        assert!(o
            .candidates
            .iter()
            .all(|c| c.via == Via::OnBranch && c.job_id.is_none()));
    }

    #[test]
    fn nothing_to_go_on_is_unknown() {
        assert_eq!(
            resolve_with(&[], &["alpha"], &[], Some("feat")).kind,
            OwnerKind::Unknown
        );
        assert_eq!(resolve_with(&[], &[], &[], None).kind, OwnerKind::Unknown);
    }

    #[test]
    fn a_working_copy_must_match_both_the_repo_and_the_branch() {
        for c in [
            copy("carefeed/other", "feat"),
            copy(REPO, "other-branch"),
            WorkingCopy {
                repo: Some(REPO.into()),
                branch: None,
            },
            WorkingCopy {
                repo: None,
                branch: Some("feat".into()),
            },
            WorkingCopy::default(),
        ] {
            let o = resolve_with(&[], &["alpha"], &[("alpha", c.clone())], Some("feat"));
            assert_eq!(o.kind, OwnerKind::Unknown, "{c:?}");
        }
    }

    #[test]
    fn a_focus_that_is_not_open_is_not_on_any_branch() {
        let o = resolve_with(&[], &[], &[("alpha", copy(REPO, "feat"))], Some("feat"));
        assert_eq!(o.kind, OwnerKind::Unknown);
    }

    #[test]
    fn without_a_known_head_branch_no_focus_is_on_it() {
        let o = resolve_with(&[], &["alpha"], &[("alpha", copy(REPO, "feat"))], None);
        assert_eq!(o.kind, OwnerKind::Unknown);
    }

    // ── a user's link (slice 3) ───────────────────────────────────────────

    #[test]
    fn a_link_owns_the_pr_when_no_job_does_and_a_job_outranks_a_link_to_the_same_focus() {
        let mut links = HashMap::new();
        links.insert(
            key(),
            Link {
                tag: "alpha".into(),
                name: "Alpha".into(),
                open: true,
            },
        );
        let o = resolve(
            &key(),
            None,
            &[],
            &focuses(&["alpha"]),
            &HashMap::new(),
            &links,
        );
        assert_eq!((o.kind, o.via), (OwnerKind::Linked, Some(Via::Linked)));
        assert_eq!(o.tag.as_deref(), Some("alpha"));

        let o = resolve(
            &key(),
            None,
            &[focus_job("j", "alpha")],
            &focuses(&["alpha"]),
            &HashMap::new(),
            &links,
        );
        assert_eq!(o.kind, OwnerKind::MotherJob);

        let o = resolve(
            &key(),
            None,
            &[focus_job("j", "beta")],
            &focuses(&["alpha", "beta"]),
            &HashMap::new(),
            &links,
        );
        assert_eq!(
            o.kind,
            OwnerKind::Ambiguous,
            "a job and a link to different focuses"
        );
        assert_eq!(tags(&o), vec!["alpha", "beta"]);
    }

    // ── bounds ────────────────────────────────────────────────────────────

    #[test]
    fn candidates_are_capped_at_eight() {
        let names: Vec<String> = (0..20).map(|i| format!("f{i:02}")).collect();
        let refs: Vec<&str> = names.iter().map(String::as_str).collect();
        let copies: Vec<(&str, WorkingCopy)> =
            refs.iter().map(|t| (*t, copy(REPO, "feat"))).collect();
        let o = resolve_with(&[], &refs, &copies, Some("feat"));
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(o.candidates.len(), MAX_CANDIDATES);

        let jobs: Vec<MotherJob> = refs
            .iter()
            .map(|t| focus_job(&format!("job-{t}"), t))
            .collect();
        let o = resolve_with(&jobs, &refs, &[], None);
        assert_eq!(o.kind, OwnerKind::Ambiguous);
        assert_eq!(o.candidates.len(), MAX_CANDIDATES);
    }

    #[test]
    fn a_focus_name_is_one_line_and_bounded() {
        let mut ov = origin(OriginKind::Focus, Some("alpha"), None);
        ov.focus_name = Some(format!("line one\nline two\u{1b}[31m {}", "n".repeat(500)));
        let o = resolve_with(&[job_with("j", Some(URL), Some(ov))], &["alpha"], &[], None);
        let name = o.name.expect("a name");
        assert!(name.chars().count() <= MAX_NAME, "{}", name.chars().count());
        assert!(!name.chars().any(|c| c.is_control()), "{name:?}");
    }
}
