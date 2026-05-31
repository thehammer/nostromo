# Daemon-hosted focuses without a project run at `/` (filesystem root)

**Type:** bug · **Repo:** nostromo (nostromd) · **Status:** open

## Symptom

In the macOS GUI, **Perri** (and any built-in focus — Fred, Teri) hits errors
that don't occur when the same agent is run in Claude Code directly. Observed:
`gh` failing with `expected the "[HOST/]OWNER/REPO" format, got "callimachus"`
when Perri runs repo-aware commands / `perri-load-pr.sh`.

## Root cause

`nostromd` runs with cwd `/` (launchd starts it there; no `WorkingDirectory` in
the plist). In `src/ipc/session_manager.rs:261` the child `claude` cwd is:

    cwd.clone().or_else(|| std::env::current_dir().ok())

So when a focus has **no project directory**, the child inherits the daemon's
cwd = **`/`**. Only dynamic "Claudia in <project>" focuses pass a real
`workingDirectory` (`focus.projectPath`); the built-ins (Perri/Fred/Teri) pass
`nil` → they execute at filesystem root.

Running an agent in `/`:
- breaks `gh`'s `owner/repo` inference (no git remote in `/`), so bare repo
  names reach `gh` and are rejected — the observed Perri error;
- is broadly wrong for any relative path / git / temp-file operation.

In Claude Code the operator launches from a real dir (repo or `$HOME`), so the
agent has git/filesystem context — which is why the error is Nostromo-only.

## Fix

When `SessionSpawn.cwd` is `None`, default the child cwd to the operator's
**home directory** (never inherit `/`). Small change at
`session_manager.rs:261` (e.g. `cwd.or_else(|| dirs::home_dir())` with a final
fallback). Optionally also set `WorkingDirectory` in the nostromd launchd plist
as belt-and-suspenders.

Affects all no-project built-in focuses; Perri is just the most visible.

## Secondary (separate repo, not nostromo)

Perri should pass `owner/repo` (not a bare repo name) to `gh`/`perri-load-pr.sh`
regardless of cwd. That's a Perri-skill robustness item, tracked separately; the
cwd fix removes the Nostromo-specific trigger.
