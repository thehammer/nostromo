//! This feature's own GitHub requests: the discovery search, the GraphQL detail
//! batch, the identity read and the organisation-name lookup.
//!
//! Deliberately not Perri's conditional GET: its errors and logs carry URLs,
//! and a URL names a repo and a PR number. Nothing here puts a URL, a title or
//! a login in an error. Every request carries [`USER_AGENT`] so the feature's
//! traffic can be told from Perri's (in a test, or in GitHub's own logs).

use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use reqwest::header::{
    HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, ETAG, IF_NONE_MATCH, USER_AGENT as UA,
};
use serde::Deserialize;

use super::budget::{parse_retry_after, RateObs, Resource};
use super::classify::{RawMergeQueue, RawPr};
use super::snapshot::{safe_segment, valid_repo};

pub const USER_AGENT: &str = "nostromd authored-prs";

/// The discovery query: every open PR the token's user authored, any repo the
/// token can read. Never review-requested, never assigned.
pub const SEARCH_PATH: &str =
    "/search/issues?q=is:pr+is:open+author:@me+archived:false&sort=updated&order=desc&per_page=100";

pub const MAX_ALIASES: usize = 20;
/// GitHub's own advice for a secondary rate limit that names no `Retry-After`:
/// wait at least a minute.
pub const SECONDARY_WAIT: Duration = Duration::from_secs(60);
const MAX_BODY: usize = 16 * 1024 * 1024;

/// Why a request failed. No variant carries a URL or any response text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiError {
    /// 401.
    Unauthorized,
    /// 429 or 403: stop until `Retry-After`, the reset of an exhausted limit, or a minute.
    /// `wait` is the server's `Retry-After`; `None` means until the reset in `Meta::rate`
    /// (or a minute when there is none).
    RateLimited {
        wait: Option<Duration>,
    },
    /// Any other non-success status, or a body that could not be read.
    Status(u16),
    Transport,
    Malformed,
}

impl ApiError {
    /// A class name for logs; never content.
    pub fn class(&self) -> &'static str {
        match self {
            ApiError::Unauthorized => "unauthorized",
            ApiError::RateLimited { .. } => "rate_limited",
            ApiError::Status(s) if *s >= 500 => "server_error",
            ApiError::Status(_) => "client_error",
            ApiError::Transport => "transport",
            ApiError::Malformed => "malformed",
        }
    }
}

/// What came back, apart from the body.
#[derive(Debug, Clone, Default)]
pub struct Meta {
    pub etag: Option<String>,
    pub rate: Option<(Resource, RateObs)>,
    /// Organisation ids named by `X-GitHub-SSO: partial-results; organizations=…`.
    pub sso_orgs: Vec<u64>,
}

pub struct Reply {
    pub status: u16,
    pub meta: Meta,
    pub body: Vec<u8>,
}

/// A failed request, with whatever rate reading came with it.
pub struct Failure {
    pub error: ApiError,
    pub meta: Meta,
}

#[derive(Clone)]
pub struct Api {
    http: reqwest::Client,
    token: String,
    base: String,
}

fn header_str<'a>(h: &'a HeaderMap, name: &str) -> Option<&'a str> {
    h.get(name).and_then(|v| v.to_str().ok())
}

fn read_meta(h: &HeaderMap) -> Meta {
    let rate = (|| {
        let resource = Resource::from_header(header_str(h, "x-ratelimit-resource")?)?;
        let remaining = header_str(h, "x-ratelimit-remaining")?.parse().ok()?;
        let limit = header_str(h, "x-ratelimit-limit")?.parse().ok()?;
        let reset: i64 = header_str(h, "x-ratelimit-reset")?.parse().ok()?;
        let reset = Utc.timestamp_opt(reset, 0).single()?;
        Some((
            resource,
            RateObs {
                remaining,
                limit,
                reset,
            },
        ))
    })();
    let sso_orgs = header_str(h, "x-github-sso")
        .and_then(|v| v.split("organizations=").nth(1))
        .map(|ids| {
            ids.split(',')
                .filter_map(|i| i.trim().parse::<u64>().ok())
                .take(10)
                .collect()
        })
        .unwrap_or_default();
    Meta {
        etag: h.get(ETAG).and_then(|v| v.to_str().ok()).map(str::to_owned),
        rate,
        sso_orgs,
    }
}

impl Api {
    pub fn new(http: reqwest::Client, token: String, base: String) -> Self {
        Api {
            http,
            token,
            base: base.trim_end_matches('/').to_owned(),
        }
    }

    fn headers(&self) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(
            ACCEPT,
            HeaderValue::from_static("application/vnd.github+json"),
        );
        h.insert(
            "X-GitHub-Api-Version",
            HeaderValue::from_static("2022-11-28"),
        );
        h.insert(UA, HeaderValue::from_static(USER_AGENT));
        if let Ok(mut v) = HeaderValue::from_str(&format!("Bearer {}", self.token)) {
            v.set_sensitive(true);
            h.insert(AUTHORIZATION, v);
        }
        h
    }

    async fn finish(&self, resp: reqwest::Response) -> Result<Reply, Failure> {
        let status = resp.status().as_u16();
        let meta = read_meta(resp.headers());
        let retry_after = header_str(resp.headers(), "retry-after").and_then(parse_retry_after);
        let remaining_zero = meta.rate.is_some_and(|(_, o)| o.remaining == 0);
        if status == 401 {
            return Err(Failure {
                error: ApiError::Unauthorized,
                meta,
            });
        }
        if status == 429 || status == 403 {
            // A 403 or 429 that is not a primary limit (`remaining` above zero, no
            // `Retry-After`) is a secondary limit: pause for a bounded minute.
            let error = if let Some(wait) = retry_after {
                ApiError::RateLimited { wait: Some(wait) }
            } else if remaining_zero {
                ApiError::RateLimited { wait: None }
            } else {
                ApiError::RateLimited {
                    wait: Some(SECONDARY_WAIT),
                }
            };
            return Err(Failure { error, meta });
        }
        if status == 304 {
            return Ok(Reply {
                status,
                meta,
                body: Vec::new(),
            });
        }
        if !(200..300).contains(&status) {
            return Err(Failure {
                error: ApiError::Status(status),
                meta,
            });
        }
        match resp.bytes().await {
            Ok(b) if b.len() <= MAX_BODY => Ok(Reply {
                status,
                meta,
                body: b.to_vec(),
            }),
            Ok(_) => Err(Failure {
                error: ApiError::Malformed,
                meta,
            }),
            Err(_) => Err(Failure {
                error: ApiError::Transport,
                meta,
            }),
        }
    }

    async fn get(&self, path: &str, etag: Option<&str>) -> Result<Reply, Failure> {
        let mut req = self
            .http
            .get(format!("{}{}", self.base, path))
            .headers(self.headers());
        if let Some(e) = etag {
            if let Ok(v) = HeaderValue::from_str(e) {
                req = req.header(IF_NONE_MATCH, v);
            }
        }
        match req.send().await {
            Ok(r) => self.finish(r).await,
            Err(_) => Err(Failure {
                error: ApiError::Transport,
                meta: Meta::default(),
            }),
        }
    }

    /// The login the token belongs to (`GET /user`, charged 1).
    pub async fn user(&self) -> Result<(String, Meta), Failure> {
        #[derive(Deserialize)]
        struct U {
            login: String,
        }
        let reply = self.get("/user", None).await?;
        let u: U = serde_json::from_slice(&reply.body).map_err(|_| Failure {
            error: ApiError::Malformed,
            meta: reply.meta.clone(),
        })?;
        Ok((u.login, reply.meta))
    }

    /// An organisation's login by id (`GET /organizations/{id}`, charged 1).
    pub async fn org_name(&self, id: u64) -> Result<(String, Meta), Failure> {
        #[derive(Deserialize)]
        struct O {
            login: String,
        }
        let reply = self.get(&format!("/organizations/{id}"), None).await?;
        let o: O = serde_json::from_slice(&reply.body).map_err(|_| Failure {
            error: ApiError::Malformed,
            meta: reply.meta.clone(),
        })?;
        Ok((o.login, reply.meta))
    }

    /// The discovery search. `None` items means 304: reuse the last list.
    pub async fn search(&self, etag: Option<&str>) -> Result<SearchResult, Failure> {
        let reply = self.get(SEARCH_PATH, etag).await?;
        if reply.status == 304 {
            return Ok(SearchResult {
                meta: reply.meta,
                page: None,
            });
        }
        #[derive(Deserialize)]
        struct Raw {
            #[serde(default)]
            total_count: u32,
            #[serde(default)]
            items: Vec<RawItem>,
        }
        #[derive(Deserialize)]
        struct RawItem {
            number: u64,
            #[serde(default)]
            title: String,
            updated_at: DateTime<Utc>,
            #[serde(default)]
            draft: Option<bool>,
            #[serde(default)]
            repository_url: String,
            #[serde(default)]
            user: Option<RawUser>,
        }
        #[derive(Deserialize)]
        struct RawUser {
            #[serde(default)]
            login: String,
        }
        let raw: Raw = serde_json::from_slice(&reply.body).map_err(|_| Failure {
            error: ApiError::Malformed,
            meta: reply.meta.clone(),
        })?;
        let items = raw
            .items
            .into_iter()
            .filter_map(|i| {
                let repo = repo_from_url(&i.repository_url)?;
                Some(SearchItem {
                    repo,
                    number: i.number,
                    title: i.title,
                    updated_at: i.updated_at,
                    draft: i.draft.unwrap_or(false),
                    login: i.user.map(|u| u.login).unwrap_or_default(),
                })
            })
            .collect();
        Ok(SearchResult {
            meta: reply.meta,
            page: Some(SearchPage {
                total_count: raw.total_count,
                items,
            }),
        })
    }

    /// One GraphQL detail batch, at most [`MAX_ALIASES`] PRs. Result `i` is
    /// the `i`th target's PR, or `None` when GitHub gave none (no access, gone).
    pub async fn detail(&self, targets: &[Target]) -> Result<DetailBatch, Failure> {
        self.run_detail(detail_query(targets), targets.len()).await
    }

    /// One PR as the merge needs it, read right now: the detail fields plus
    /// `mergeable` and `mergeStateStatus`. `None` when GitHub gave none.
    pub async fn detail_for_merge(&self, target: &Target) -> Result<Option<RawPr>, Failure> {
        let batch = self
            .run_detail(merge_query(std::slice::from_ref(target)), 1)
            .await?;
        Ok(batch.prs.into_iter().next().flatten())
    }

    async fn run_detail(&self, query: String, count: usize) -> Result<DetailBatch, Failure> {
        let req = self
            .http
            .post(format!("{}/graphql", self.base))
            .headers(self.headers())
            .json(&serde_json::json!({ "query": query }));
        let reply = match req.send().await {
            Ok(r) => self.finish(r).await?,
            Err(_) => {
                return Err(Failure {
                    error: ApiError::Transport,
                    meta: Meta::default(),
                })
            }
        };
        let v: serde_json::Value = serde_json::from_slice(&reply.body).map_err(|_| Failure {
            error: ApiError::Malformed,
            meta: reply.meta.clone(),
        })?;
        // A secondary limit arrives as a 200 with `errors[].type == RATE_LIMITED`
        // and `data: null`.
        let rate_limited = v
            .get("errors")
            .and_then(|e| e.as_array())
            .is_some_and(|errs| {
                errs.iter()
                    .any(|e| e.get("type").and_then(|t| t.as_str()) == Some("RATE_LIMITED"))
            });
        if rate_limited {
            let exhausted = reply.meta.rate.is_some_and(|(_, o)| o.remaining == 0);
            return Err(Failure {
                error: ApiError::RateLimited {
                    wait: (!exhausted).then_some(SECONDARY_WAIT),
                },
                meta: reply.meta,
            });
        }
        let data = v.get("data").filter(|d| d.is_object());
        let Some(data) = data else {
            return Err(Failure {
                error: ApiError::Malformed,
                meta: reply.meta,
            });
        };
        let cost = data
            .pointer("/rateLimit/cost")
            .and_then(|c| c.as_u64())
            .unwrap_or(1);
        let errors = v.get("errors").and_then(|e| e.as_array());
        let prs = (0..count)
            .map(|i| {
                data.get(format!("p{i}"))
                    .and_then(|r| r.get("pullRequest"))
                    .filter(|p| !p.is_null())
                    .and_then(|p| serde_json::from_value::<RawPr>(p.clone()).ok())
                    .map(|mut raw| {
                        // A field GitHub could not resolve comes back `null` beside an
                        // error: that is "could not read", never "there is no queue".
                        if errors.is_some_and(|e| queue_field_failed(e, i)) {
                            raw.merge_queue = None;
                            raw.repository.merge_queue = None;
                        }
                        raw
                    })
            })
            .collect::<Vec<_>>();
        let mut prs = prs;
        let extra = self.read_base_queues(&mut prs).await;
        Ok(DetailBatch {
            meta: reply.meta,
            cost: cost + extra,
            prs,
        })
    }

    /// The second read: `repository.mergeQueue(branch: <base>)` for every open PR
    /// whose base is not the default branch (the default branch's queue came
    /// with the first answer). A PR whose read fails keeps `None` (unknown):
    /// nothing here fails the batch. Returns the GraphQL points it cost.
    async fn read_base_queues(&self, prs: &mut [Option<RawPr>]) -> u64 {
        let wanted: Vec<(usize, String, String, String)> = prs
            .iter()
            .enumerate()
            .filter_map(|(i, p)| {
                let p = p.as_ref().filter(|p| p.needs_base_queue_read())?;
                let (owner, name) = p.repository.name_with_owner.split_once('/')?;
                (safe_segment(owner) && safe_segment(name)).then(|| {
                    (
                        i,
                        owner.to_owned(),
                        name.to_owned(),
                        p.base_ref_name.clone(),
                    )
                })
            })
            .collect();
        if wanted.is_empty() {
            return 0;
        }
        let (query, variables) = base_queue_query(&wanted);
        let req = self
            .http
            .post(format!("{}/graphql", self.base))
            .headers(self.headers())
            .json(&serde_json::json!({ "query": query, "variables": variables }));
        let Ok(resp) = req.send().await else {
            return 0;
        };
        let Ok(reply) = self.finish(resp).await else {
            return 0;
        };
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(&reply.body) else {
            return 0;
        };
        let Some(data) = v.get("data").filter(|d| d.is_object()) else {
            return 0;
        };
        let errors = v.get("errors").and_then(|e| e.as_array());
        for (k, (i, ..)) in wanted.iter().enumerate() {
            let failed = errors.is_some_and(|e| base_queue_failed(e, k));
            let read = data
                .get(format!("b{k}"))
                .and_then(|r| r.as_object())
                .filter(|_| !failed)
                .and_then(|r| r.get("mergeQueue"))
                .and_then(|q| match q {
                    serde_json::Value::Null => Some(None),
                    other => serde_json::from_value::<RawMergeQueue>(other.clone())
                        .ok()
                        .map(Some),
                });
            if let Some(Some(raw)) = prs.get_mut(*i) {
                raw.base_branch_queue = read;
            }
        }
        data.pointer("/rateLimit/cost")
            .and_then(|c| c.as_u64())
            .unwrap_or(1)
    }

    /// Squash-merge the PR, and only if its head is still `sha`
    /// (`PUT /repos/{repo}/pulls/{number}/merge`). The body is the method and
    /// the SHA and nothing else: no admin or bypass parameter, no commit
    /// message. GitHub's reply text is never read: only the status says what
    /// happened.
    pub async fn merge(&self, repo: &str, number: u64, sha: &str) -> Result<(), MergeError> {
        if !valid_repo(repo) {
            return Err(MergeError::NotFound);
        }
        let resp = self
            .http
            .put(format!("{}/repos/{repo}/pulls/{number}/merge", self.base))
            .headers(self.headers())
            .json(&serde_json::json!({ "merge_method": "squash", "sha": sha }))
            .send()
            .await
            .map_err(|_| MergeError::Transport)?;
        let status = resp.status().as_u16();
        let meta = read_meta(resp.headers());
        let retry_after = header_str(resp.headers(), "retry-after").and_then(parse_retry_after);
        let exhausted = meta.rate.is_some_and(|(_, o)| o.remaining == 0);
        Err(match status {
            200..=299 => return Ok(()),
            401 => MergeError::Unauthorized,
            429 => MergeError::RateLimited,
            // A 403 is a limit when GitHub says so, and a token without the
            // right to merge otherwise.
            403 if retry_after.is_some() || exhausted => MergeError::RateLimited,
            403 => MergeError::Forbidden,
            404 => MergeError::NotFound,
            405 => MergeError::NotAllowed,
            409 => MergeError::HeadMoved,
            422 => MergeError::Unmergeable,
            _ => MergeError::Transport,
        })
    }

    /// Add the PR (GraphQL node id `node_id`) to its merge queue, and only if
    /// its head is still `head`. GitHub's reply text is never forwarded or
    /// logged: the HTTP status, the error `type` and, for the one distinction
    /// those cannot make (the head moved), a bounded look at the message decide.
    pub async fn enqueue(&self, node_id: &str, head: &str) -> Result<(), MergeError> {
        if node_id.is_empty()
            || node_id.len() > 100
            || !node_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'=')
        {
            return Err(MergeError::Unmergeable);
        }
        let resp = self
            .http
            .post(format!("{}/graphql", self.base))
            .headers(self.headers())
            .json(&serde_json::json!({
                "query": ENQUEUE_MUTATION,
                "variables": { "pr": node_id, "head": head },
            }))
            .send()
            .await
            .map_err(|_| MergeError::Transport)?;
        let status = resp.status().as_u16();
        let meta = read_meta(resp.headers());
        let retry_after = header_str(resp.headers(), "retry-after").and_then(parse_retry_after);
        let exhausted = meta.rate.is_some_and(|(_, o)| o.remaining == 0);
        match status {
            200..=299 => {}
            401 => return Err(MergeError::Unauthorized),
            429 => return Err(MergeError::RateLimited),
            403 if retry_after.is_some() || exhausted => return Err(MergeError::RateLimited),
            403 => return Err(MergeError::Forbidden),
            404 => return Err(MergeError::NotFound),
            _ => return Err(MergeError::Transport),
        }
        let body = resp.bytes().await.map_err(|_| MergeError::Transport)?;
        if body.len() > MAX_BODY {
            return Err(MergeError::Transport);
        }
        let v: serde_json::Value =
            serde_json::from_slice(&body).map_err(|_| MergeError::Transport)?;
        if let Some(errors) = v
            .get("errors")
            .and_then(|e| e.as_array())
            .filter(|e| !e.is_empty())
        {
            return Err(classify_enqueue_errors(errors));
        }
        let entry = v.pointer("/data/enqueuePullRequest/mergeQueueEntry");
        if entry.is_some_and(|e| e.is_object()) {
            Ok(())
        } else {
            Err(MergeError::Unmergeable)
        }
    }
}

/// The second read's query: one alias per PR, the branch passed as a variable
/// (a branch name is never spliced into the query text).
fn base_queue_query(wanted: &[(usize, String, String, String)]) -> (String, serde_json::Value) {
    let mut decls = Vec::new();
    let mut body = String::new();
    let mut vars = serde_json::Map::new();
    for (k, (_, owner, name, base)) in wanted.iter().enumerate() {
        decls.push(format!("$b{k}: String!"));
        body.push_str(&format!(
            "  b{k}: repository(owner: \"{owner}\", name: \"{name}\") {{ mergeQueue(branch: $b{k}) {{ id }} }}\n"
        ));
        vars.insert(format!("b{k}"), serde_json::Value::String(base.clone()));
    }
    (
        format!(
            "query AuthoredPrBaseQueue({}) {{\n  rateLimit {{ cost remaining limit resetAt }}\n{body}}}\n",
            decls.join(", ")
        ),
        serde_json::Value::Object(vars),
    )
}

/// Did GraphQL report an error on alias `b{index}` of the second read?
fn base_queue_failed(errors: &[serde_json::Value], index: usize) -> bool {
    let alias = format!("b{index}");
    errors.iter().any(|e| {
        e.get("path")
            .and_then(|p| p.as_array())
            .and_then(|p| p.first())
            .and_then(|a| a.as_str())
            == Some(alias.as_str())
    })
}

/// Did GraphQL report an error on one of the merge queue fields of alias `p{index}`?
fn queue_field_failed(errors: &[serde_json::Value], index: usize) -> bool {
    let alias = format!("p{index}");
    errors.iter().any(|e| {
        let Some(path) = e.get("path").and_then(|p| p.as_array()) else {
            return false;
        };
        path.first().and_then(|a| a.as_str()) == Some(alias.as_str())
            && path.iter().any(|seg| {
                matches!(
                    seg.as_str(),
                    Some("mergeQueue" | "isInMergeQueue" | "mergeQueueEntry")
                )
            })
    })
}

/// The structured name of a GraphQL error: GitHub's `type`, or the spec's
/// `extensions.code`, upper-cased.
fn error_kinds(e: &serde_json::Value) -> Vec<String> {
    [
        e.get("type").and_then(|t| t.as_str()),
        e.pointer("/extensions/code").and_then(|t| t.as_str()),
    ]
    .into_iter()
    .flatten()
    .map(|k| k.to_ascii_uppercase())
    .collect()
}

/// What GraphQL errors on an enqueue come to. Anything not recognised is GitHub
/// declining to enqueue (`Unmergeable`: `queue_refused`).
///
/// The structured name (`type` or `extensions.code`) decides wherever GitHub
/// gives one. GitHub's real wording for a moved head is unverified, so the
/// message text is the last resort for that one distinction only, and a miss
/// is a refusal that sends nothing more.
fn classify_enqueue_errors(errors: &[serde_json::Value]) -> MergeError {
    let has = |names: &[&str]| {
        errors
            .iter()
            .any(|e| error_kinds(e).iter().any(|k| names.contains(&k.as_str())))
    };
    if has(&["RATE_LIMITED"]) {
        return MergeError::RateLimited;
    }
    if has(&["FORBIDDEN", "INSUFFICIENT_SCOPES"]) {
        return MergeError::Forbidden;
    }
    if has(&["NOT_FOUND"]) {
        return MergeError::NotFound;
    }
    if has(&[
        "STALE_HEAD",
        "HEAD_OID_MISMATCH",
        "EXPECTED_HEAD_OID_MISMATCH",
        "HEAD_CHANGED",
    ]) {
        return MergeError::HeadMoved;
    }
    let head_moved = errors.iter().any(|e| {
        let m = e
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        m.contains("head")
            && ["modified", "match", "expected", "changed"]
                .iter()
                .any(|w| m.contains(w))
    });
    if head_moved {
        MergeError::HeadMoved
    } else {
        MergeError::Unmergeable
    }
}

/// The one mutation that adds a PR to its base branch's merge queue. It carries
/// the PR's node id and the head it must still be at (`expectedHeadOid`), and
/// nothing else: `jump` would skip the queue and is never sent, and there is no
/// admin or bypass input.
const ENQUEUE_MUTATION: &str = "mutation EnqueueAuthoredPr($pr: ID!, $head: GitObjectID!) { enqueuePullRequest(input: { pullRequestId: $pr, expectedHeadOid: $head }) { mergeQueueEntry { id } } }";

/// Why a merge request did not merge. No variant carries any response text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergeError {
    /// 401.
    Unauthorized,
    /// 403 that is not a rate limit: the token may not merge here.
    Forbidden,
    /// 404.
    NotFound,
    /// 405: GitHub says the PR is not mergeable now (a protection rule).
    NotAllowed,
    /// 409: the head is no longer the SHA that was sent.
    HeadMoved,
    /// 422.
    Unmergeable,
    /// 429, or a 403 that carries a limit.
    RateLimited,
    /// No answer, or an unexpected status.
    Transport,
}

pub struct SearchResult {
    pub meta: Meta,
    pub page: Option<SearchPage>,
}

#[derive(Debug, Clone)]
pub struct SearchPage {
    pub total_count: u32,
    pub items: Vec<SearchItem>,
}

#[derive(Debug, Clone)]
pub struct SearchItem {
    /// `owner/name` as GitHub spells it.
    pub repo: String,
    pub number: u64,
    pub title: String,
    pub updated_at: DateTime<Utc>,
    pub draft: bool,
    pub login: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// `owner/name`.
    pub repo: String,
    pub number: u64,
}

pub struct DetailBatch {
    pub meta: Meta,
    /// GraphQL points this request cost.
    pub cost: u64,
    pub prs: Vec<Option<RawPr>>,
}

/// `owner/name` from `…/repos/<owner>/<name>`.
fn repo_from_url(url: &str) -> Option<String> {
    let mut parts = url.rsplit('/');
    let name = parts.next()?;
    let owner = parts.next()?;
    (safe_segment(owner) && safe_segment(name)).then(|| format!("{owner}/{name}"))
}

/// The one query this feature sends. It names counts, states, timestamps and
/// logins only: never `body`, `bodyText`, `bodyHTML`, or a check's `output`,
/// `summary` or `text`.
pub fn detail_query(targets: &[Target]) -> String {
    query_with(targets, "")
}

/// The detail query plus `mergeable` and `mergeStateStatus`: what the merge reads
/// right before it acts. Never sent by the poll, so the poll's cost is unchanged.
pub fn merge_query(targets: &[Target]) -> String {
    query_with(targets, " mergeable mergeStateStatus")
}

const FRAGMENT: &str = "fragment AuthoredPr on PullRequest {
  id number title isDraft state merged updatedAt isInMergeQueue mergeQueue { id } mergeQueueEntry { state position }{EXTRA}
  author { __typename login }
  baseRefName headRefName headRefOid isCrossRepository
  repository { nameWithOwner defaultBranchRef { name } mergeQueue { id } }
  commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state contexts(first: 100) { totalCount nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } }
  latestOpinionatedReviews(first: 20) { nodes { state author { __typename login } } }
  reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug organization { login } } ... on Bot { login } } } }
  reviewThreads(first: 100) { totalCount nodes { isResolved } }
  comments(last: 100) { nodes { createdAt author { __typename login } } }
  reviews(last: 50) { nodes { submittedAt author { __typename login } comments { totalCount } } }
}
";

fn query_with(targets: &[Target], extra_fields: &str) -> String {
    let mut q =
        String::from("query AuthoredPrDetail {\n  rateLimit { cost remaining limit resetAt }\n");
    for (i, t) in targets.iter().take(MAX_ALIASES).enumerate() {
        if let Some((owner, name)) = t.repo.split_once('/') {
            if safe_segment(owner) && safe_segment(name) {
                q.push_str(&format!(
                    "  p{i}: repository(owner: \"{owner}\", name: \"{name}\") {{ pullRequest(number: {}) {{ ...AuthoredPr }} }}\n",
                    t.number
                ));
            }
        }
    }
    q.push_str("}\n");
    q.push_str(&FRAGMENT.replacen("{EXTRA}", extra_fields, 1));
    q
}

#[cfg(test)]
mod tests {
    //! How GitHub's GraphQL errors on an enqueue come to a `MergeError`. The
    //! fixtures are GitHub's own error JSON.

    use super::*;
    use serde_json::json;

    const HEAD_WORDING: &str = "Head branch was modified. Review the latest changes and try again.";

    fn classify(errors: serde_json::Value) -> MergeError {
        classify_enqueue_errors(errors.as_array().expect("an array of errors"))
    }

    #[test]
    fn a_moved_head_is_head_moved_by_wording_under_an_unprocessable_type() {
        assert_eq!(
            classify(json!([{"type": "UNPROCESSABLE", "message": HEAD_WORDING}])),
            MergeError::HeadMoved
        );
    }

    #[test]
    fn a_moved_head_is_head_moved_by_its_structured_code_whatever_the_message() {
        for e in [
            json!({"extensions": {"code": "STALE_HEAD"}, "message": "Something unrelated"}),
            json!({"extensions": {"code": "stale_head"}}),
            json!({"type": "STALE_HEAD", "message": "Something unrelated"}),
            json!({"type": "UNPROCESSABLE", "extensions": {"code": "STALE_HEAD"}, "message": "x"}),
        ] {
            assert_eq!(classify(json!([e.clone()])), MergeError::HeadMoved, "{e}");
        }
    }

    #[test]
    fn a_moved_head_is_head_moved_by_wording_alone() {
        for m in [
            HEAD_WORDING,
            "Expected head oid does not match the pull request head",
            "the head commit has changed",
        ] {
            assert_eq!(
                classify(json!([{"message": m}])),
                MergeError::HeadMoved,
                "{m}"
            );
        }
    }

    #[test]
    fn any_other_refusal_is_unmergeable_and_none_of_its_words_matter() {
        for e in [
            json!({"type": "UNPROCESSABLE", "message": "Pull request is not mergeable"}),
            json!({"message": "Required status checks have not passed"}),
            json!({"extensions": {"code": "SOMETHING_NEW"}, "message": "nope"}),
            // A "head" mentioned with no word of change in it is not a moved head.
            json!({"type": "UNPROCESSABLE", "message": "The head repository is archived"}),
        ] {
            assert_eq!(classify(json!([e.clone()])), MergeError::Unmergeable, "{e}");
        }
    }

    #[test]
    fn empty_and_odd_shapes_are_unmergeable_never_a_panic() {
        for errors in [
            json!([]),
            json!([{}]),
            json!([null]),
            json!(["a string"]),
            json!([{"type": 7, "message": ["not", "text"]}]),
            json!([{"extensions": "not an object", "message": null}]),
            json!([{"extensions": {"code": 5}}]),
        ] {
            assert_eq!(
                classify(errors.clone()),
                MergeError::Unmergeable,
                "{errors}"
            );
        }
    }

    #[test]
    fn rate_limit_permission_and_missing_node_are_named_by_type_or_by_extensions_code() {
        let cases = [
            ("RATE_LIMITED", MergeError::RateLimited),
            ("FORBIDDEN", MergeError::Forbidden),
            ("INSUFFICIENT_SCOPES", MergeError::Forbidden),
            ("NOT_FOUND", MergeError::NotFound),
        ];
        for (name, want) in cases {
            for e in [
                json!({"type": name, "message": "x"}),
                json!({"extensions": {"code": name}, "message": "x"}),
                json!({"extensions": {"code": name.to_ascii_lowercase()}}),
            ] {
                assert_eq!(classify(json!([e.clone()])), want, "{e}");
            }
        }
    }

    #[test]
    fn a_rate_limit_outranks_a_moved_head_when_both_are_reported() {
        assert_eq!(
            classify(json!([
                {"type": "UNPROCESSABLE", "message": HEAD_WORDING},
                {"type": "RATE_LIMITED", "message": "slow down"}
            ])),
            MergeError::RateLimited
        );
    }

    #[test]
    fn the_base_branch_is_sent_as_a_variable_and_never_spliced_into_the_query_text() {
        let wanted = vec![
            (
                3,
                "o".to_owned(),
                "r".to_owned(),
                "merge/a\"} evil".to_owned(),
            ),
            (5, "o".to_owned(), "r".to_owned(), "main2".to_owned()),
        ];
        let (query, vars) = base_queue_query(&wanted);
        assert!(
            !query.contains("evil") && !query.contains("main2"),
            "{query}"
        );
        assert_eq!(vars["b0"], "merge/a\"} evil");
        assert_eq!(vars["b1"], "main2");
        assert_eq!(vars.as_object().map(|m| m.len()), Some(2));
    }
}
