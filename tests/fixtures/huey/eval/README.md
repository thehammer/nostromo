# Huey eval scenarios

Fixtures for `nostromo-huey-eval` (see `docs/huey.md`). Opt-in, real model, never run in CI.

Everything here is synthetic. News items, versions, projects and hosts are made up (`example.com` hosts, invented version numbers). `simulation-2026-10-25` is a synthetic stand-in for the 2026-10-25 hand-run: it keeps the two items that mattered (a `decider: "person"` hook option and the retry watchdog) buried in otherwise noisy changelog entries, and the API-version and SDK news that mattered to nothing.

Per scenario:

- `pool.json`: the frozen news, in compact form (`id`, `class`, `title`, `url`, `published`, `text`). Optional `recent_extra` adds older first-party items for the Also-in-the-news pool.
- `context/`: `code/<project>/` (the runner makes each a git repository and reads `.eval-commits`, lines of `<days ago>|<subject>`) and `home/` (the `dot-` prefix becomes `.`, so `home/dot-claude` is `~/.claude`). A scenario that runs more than once has `context/<name>/` per run.
- `interests.md`, `posture.json`: as on a real machine. Either may also sit inside a context directory, which wins.
- `ledger.json` (optional): earlier shown items, for follow-ups.
- `expect.toml`: the date and one `[[run]]` per run, each a set of assertions over the produced report. The keys are the fields of `Checks` in `src/bin/nostromo_huey_eval.rs`.
