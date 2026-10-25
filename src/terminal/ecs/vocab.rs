//! Load and resolve the remote-shell vocabulary (see [`super`]).
//!
//! [`EcsVocabulary::load`] reads the files afresh every time it is called: the
//! daemon loads once per request and never caches, so editing the layer's data
//! changes the next request (T-2a-2). [`EcsVocabulary::resolve`] turns the four
//! words an agent supplies into an [`EcsTarget`], validating each level
//! against the data; anything outside it is an [`InvalidTarget`] that lists
//! what would have been valid.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use regex::Regex;
use serde::Deserialize;
use tracing::warn;

use crate::config::TerminalConfig;
use crate::ipc::protocol::{RemoteShellEnvironment, RemoteShellProject, TerminalTarget};

/// What the layer writes where a profile has not been chosen yet.
pub const CONFIGURE_ME: &str = "CONFIGURE_ME";

/// The most any of the data files may hold. The real files are a few KiB.
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
/// How much of a rejected value an [`InvalidTarget`] quotes back.
const MAX_GIVEN_CHARS: usize = 64;

/// Where the vocabulary's files are. Each list is tried in order; the first
/// file that exists is used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EcsPaths {
    pub config: Vec<PathBuf>,
    pub local: Vec<PathBuf>,
    pub aliases_script: Vec<PathBuf>,
}

impl EcsPaths {
    /// Exactly these three files, no fallbacks.
    pub fn new(config: PathBuf, local: PathBuf, aliases_script: PathBuf) -> Self {
        Self {
            config: vec![config],
            local: vec![local],
            aliases_script: vec![aliases_script],
        }
    }

    /// `[terminal]` from `config.toml`, else the usual places under `~/.claude`.
    pub fn from_config(cfg: &TerminalConfig) -> Self {
        let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
        let claude = home.join(".claude");
        let layer = claude.join("layers/carefeed/lib/services/ecs");
        let legacy = claude.join("lib/services/ecs");
        let pick = |configured: &Option<PathBuf>, defaults: Vec<PathBuf>| match configured
            .as_ref()
            .filter(|p| !p.as_os_str().is_empty())
        {
            Some(p) => vec![expand_tilde(p, &home)],
            None => defaults,
        };
        Self {
            config: pick(
                &cfg.ecs_config,
                vec![layer.join("config.json"), legacy.join("config.json")],
            ),
            local: pick(&cfg.ecs_local, vec![claude.join("ecs-local.json")]),
            aliases_script: pick(
                &cfg.ecs_aliases_script,
                vec![layer.join("ecs.sh"), legacy.join("ecs.sh")],
            ),
        }
    }

    fn first_existing(candidates: &[PathBuf]) -> Option<&Path> {
        candidates.iter().map(PathBuf::as_path).find(|p| p.is_file())
    }
}

fn expand_tilde(path: &Path, home: &Path) -> PathBuf {
    match path.strip_prefix("~") {
        Ok(rest) => home.join(rest),
        Err(_) => path.to_path_buf(),
    }
}

/// Why no vocabulary could be loaded. The daemon says the same thing to every
/// caller: remote shells are not configured, and `problem` is why.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{problem}")]
pub struct VocabError {
    pub problem: String,
}

impl VocabError {
    fn new(problem: impl Into<String>) -> Self {
        Self {
            problem: problem.into(),
        }
    }
}

/// Which of the four words was not in the vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetField {
    Project,
    Environment,
    Service,
    ShellType,
}

impl TargetField {
    pub fn as_str(self) -> &'static str {
        match self {
            TargetField::Project => "project",
            TargetField::Environment => "environment",
            TargetField::Service => "service",
            TargetField::ShellType => "shell_type",
        }
    }
}

/// A word outside the vocabulary: which field, what was given (clipped) and
/// every value that would have been accepted for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidTarget {
    pub field: TargetField,
    pub given: String,
    pub valid: Vec<String>,
}

impl InvalidTarget {
    pub fn detail(&self) -> String {
        format!(
            "unknown {} '{}'; valid: {}",
            self.field.as_str(),
            self.given,
            self.valid.join(", ")
        )
    }
}

/// A resolved remote shell: canonical names and everything the connect needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EcsTarget {
    pub project: String,
    pub environment: String,
    /// The service's short name (`scheduler`), not the ECS service name.
    pub service: String,
    pub shell_type: String,
    pub cluster: String,
    /// The ECS service's own name (`production-admin-portal-scheduler`).
    pub service_name: String,
    pub container: String,
    pub region: String,
    /// The AWS profile for the environment; `None` when it is missing or
    /// still [`CONFIGURE_ME`].
    pub profile: Option<String>,
    /// The command the shell runs (`/bin/bash`, `php artisan tinker`).
    pub shell_command: String,
}

impl EcsTarget {
    /// The four canonical words, as the wire and the audit trail name a target.
    pub fn terminal_target(&self) -> TerminalTarget {
        TerminalTarget {
            project: self.project.clone(),
            environment: self.environment.clone(),
            service: self.service.clone(),
            shell_type: self.shell_type.clone(),
        }
    }
}

// ── the files ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct ConfigFile {
    profiles: BTreeMap<String, String>,
    regions: BTreeMap<String, String>,
    projects: BTreeMap<String, ProjectData>,
    shell_types: BTreeMap<String, String>,
    project_shell_overrides: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct ProjectData {
    default_service: Option<String>,
    environments: BTreeMap<String, EnvironmentData>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct EnvironmentData {
    cluster: String,
    services: BTreeMap<String, ServiceData>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct ServiceData {
    service: String,
    container: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct LocalFile {
    profiles: BTreeMap<String, String>,
}

/// The alias tables of `ecs.sh`: lowercase word to canonical name.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct Aliases {
    environment: HashMap<String, String>,
    service: HashMap<String, String>,
    project: HashMap<String, String>,
}

/// The vocabulary as of one load.
#[derive(Debug, Clone)]
pub struct EcsVocabulary {
    config: ConfigFile,
    local_profiles: BTreeMap<String, String>,
    aliases: Aliases,
}

impl EcsVocabulary {
    /// Read the files now. `config.json` is required (missing, unreadable,
    /// malformed or empty is [`VocabError`]); `ecs-local.json` and `ecs.sh`
    /// are optional: without them profiles come from `config.json` and only
    /// canonical names (no aliases) resolve.
    pub fn load(paths: &EcsPaths) -> Result<Self, VocabError> {
        let config_path = EcsPaths::first_existing(&paths.config).ok_or_else(|| {
            VocabError::new(format!(
                "no ECS config.json found (looked for {})",
                join_paths(&paths.config)
            ))
        })?;
        let raw = read_capped(config_path)
            .map_err(|e| VocabError::new(format!("cannot read {}: {e}", config_path.display())))?;
        let file: ConfigFile = serde_json::from_str(&raw).map_err(|e| {
            VocabError::new(format!("{} is not valid: {e}", config_path.display()))
        })?;
        if file.projects.is_empty() || file.shell_types.is_empty() {
            return Err(VocabError::new(format!(
                "{} has no projects or no shell_types",
                config_path.display()
            )));
        }

        let local_profiles = EcsPaths::first_existing(&paths.local)
            .and_then(|p| match read_capped(p) {
                Ok(raw) => match serde_json::from_str::<LocalFile>(&raw) {
                    Ok(local) => Some(local.profiles),
                    Err(e) => {
                        warn!("ignoring {}: {e}", p.display());
                        None
                    }
                },
                Err(e) => {
                    warn!("ignoring {}: {e}", p.display());
                    None
                }
            })
            .unwrap_or_default();

        let aliases = match EcsPaths::first_existing(&paths.aliases_script) {
            Some(p) => match read_capped(p) {
                Ok(text) => parse_aliases(&text),
                Err(e) => {
                    warn!("no ECS aliases: cannot read {}: {e}", p.display());
                    Aliases::default()
                }
            },
            None => {
                warn!(
                    "no ECS aliases: ecs.sh not found (looked for {})",
                    join_paths(&paths.aliases_script)
                );
                Aliases::default()
            }
        };

        Ok(Self {
            config: file,
            local_profiles,
            aliases,
        })
    }

    /// The project's default service, when `config.json` names one that exists
    /// in at least one of its environments (the picker's preselection).
    pub fn default_service(&self, project: &str) -> Option<&str> {
        let project = self.config.projects.get(project)?;
        let default = project.default_service.as_deref()?;
        project
            .environments
            .values()
            .any(|e| e.services.contains_key(default))
            .then_some(default)
    }

    /// Everything that can be asked for, for the app's picker and the agent's
    /// `list` tool. Environments without a region are left out, as
    /// [`Self::resolve`] refuses them.
    pub fn projects(&self) -> Vec<RemoteShellProject> {
        self.config
            .projects
            .iter()
            .map(|(name, p)| RemoteShellProject {
                name: name.clone(),
                default_service: self.default_service(name).map(str::to_owned),
                environments: p
                    .environments
                    .iter()
                    .filter(|(env, _)| self.has_region(env))
                    .map(|(env, e)| RemoteShellEnvironment {
                        name: env.clone(),
                        services: e.services.keys().cloned().collect(),
                    })
                    .collect(),
            })
            .collect()
    }

    /// Every shell type name.
    pub fn shell_types(&self) -> Vec<String> {
        self.config.shell_types.keys().cloned().collect()
    }

    /// Turn the four words (canonical or aliased, any case) into a target.
    pub fn resolve(
        &self,
        project: &str,
        environment: &str,
        service: &str,
        shell_type: &str,
    ) -> Result<EcsTarget, InvalidTarget> {
        let project_name = canonical(&self.aliases.project, project);
        let Some(project_data) = self.config.projects.get(&project_name) else {
            return Err(invalid(
                TargetField::Project,
                project,
                self.config.projects.keys().cloned().collect(),
            ));
        };

        let env_name = canonical(&self.aliases.environment, environment);
        let env_data = project_data
            .environments
            .get(&env_name)
            .filter(|_| self.has_region(&env_name));
        let Some(env_data) = env_data else {
            return Err(invalid(
                TargetField::Environment,
                environment,
                project_data
                    .environments
                    .keys()
                    .filter(|e| self.has_region(e))
                    .cloned()
                    .collect(),
            ));
        };

        let service_name = canonical(&self.aliases.service, service);
        let Some(service_data) = env_data.services.get(&service_name) else {
            return Err(invalid(
                TargetField::Service,
                service,
                env_data.services.keys().cloned().collect(),
            ));
        };

        let shell_name = shell_type.to_ascii_lowercase();
        let shell_command = self
            .config
            .project_shell_overrides
            .get(&project_name)
            .and_then(|o| o.get(&shell_name))
            .or_else(|| self.config.shell_types.get(&shell_name));
        let Some(shell_command) = shell_command else {
            return Err(invalid(
                TargetField::ShellType,
                shell_type,
                self.config.shell_types.keys().cloned().collect(),
            ));
        };

        Ok(EcsTarget {
            project: project_name,
            region: self.config.regions[&env_name].clone(),
            profile: self.profile_for(&env_name),
            environment: env_name,
            service: service_name,
            shell_type: shell_name,
            cluster: env_data.cluster.clone(),
            service_name: service_data.service.clone(),
            container: service_data.container.clone(),
            shell_command: shell_command.clone(),
        })
    }

    fn has_region(&self, environment: &str) -> bool {
        self.config
            .regions
            .get(environment)
            .is_some_and(|r| !r.is_empty())
    }

    /// The personal override first, then the shared one; unset, empty or
    /// still [`CONFIGURE_ME`] is `None` (as `ecs.sh`'s `_ecs_config` picks it).
    fn profile_for(&self, environment: &str) -> Option<String> {
        let local = self
            .local_profiles
            .get(environment)
            .filter(|p| !p.is_empty());
        local
            .or_else(|| self.config.profiles.get(environment))
            .filter(|p| !p.is_empty() && p.as_str() != CONFIGURE_ME)
            .cloned()
    }
}

/// `ecs_resolve_alias`: lowercase, then the alias table, else the lowercase word.
fn canonical(aliases: &HashMap<String, String>, word: &str) -> String {
    let lower = word.to_ascii_lowercase();
    aliases.get(&lower).cloned().unwrap_or(lower)
}

fn invalid(field: TargetField, given: &str, valid: Vec<String>) -> InvalidTarget {
    InvalidTarget {
        field,
        given: given.chars().take(MAX_GIVEN_CHARS).collect(),
        valid,
    }
}

fn read_capped(path: &Path) -> std::io::Result<String> {
    let len = std::fs::metadata(path)?.len();
    if len > MAX_FILE_BYTES {
        return Err(std::io::Error::other(format!(
            "file is {len} bytes (limit {MAX_FILE_BYTES})"
        )));
    }
    std::fs::read_to_string(path)
}

fn join_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

// ── ecs.sh, as text ──────────────────────────────────────────────────────────

fn block_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"declare -A (ECS_[A-Z]+_ALIASES)=\(([^)]*)\)").expect("alias block regex")
    })
}

fn entry_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"^\[([a-z0-9_-]+)\]="([a-z0-9_-]+)"$"#).expect("alias entry regex")
    })
}

/// The three `declare -A ECS_*_ALIASES=( … )` blocks of `ecs.sh`. A block that
/// holds anything but `[word]="word"` entries, blank lines and comments gives
/// no aliases (and a warning); the others are unaffected.
fn parse_aliases(script: &str) -> Aliases {
    let mut aliases = Aliases::default();
    for block in block_re().captures_iter(script) {
        let name = &block[1];
        let table = match name {
            "ECS_ENV_ALIASES" => &mut aliases.environment,
            "ECS_SERVICE_ALIASES" => &mut aliases.service,
            "ECS_PROJECT_ALIASES" => &mut aliases.project,
            _ => continue,
        };
        let mut parsed = HashMap::new();
        let mut ok = true;
        for line in block[2].lines().map(str::trim) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            match entry_re().captures(line) {
                Some(entry) => {
                    parsed.insert(entry[1].to_owned(), entry[2].to_owned());
                }
                None => {
                    warn!("no {name} aliases: an entry is not [word]=\"word\"");
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            *table = parsed;
        }
    }
    aliases
}
