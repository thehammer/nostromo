# Huey interests (Eval)

## What I care about, and why
- **Agent harnesses that put the human first**: I build tools that run Claude Code for me, so changes to its flags, hooks and permission model matter. Why: they change how my own tools behave.
- **Queue and worker reliability**: retries, stalls and backpressure in unattended jobs. Why: my workers run unattended overnight.

## Want more of
- Concrete changelog items I could adopt or delete a workaround for.

## Want less of
- Model benchmark and leaderboard news.

## Ignore entirely
- Cryptocurrency price chatter (`Bitcoin`, `Ethereum`)

## How it runs
- **relay**: workers run `claude -p` non-interactively and set CLAUDE_CODE_RETRY_WATCHDOG
