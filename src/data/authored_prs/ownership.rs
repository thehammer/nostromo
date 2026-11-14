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

    // Open focuses working on this repo and branch.
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
