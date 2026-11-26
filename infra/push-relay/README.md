# Nostromo push relay

A small, stateless AWS Lambda that sits between the Nostromo primary and Apple's
push service (APNs). The primary decides *what* to say and *when*; the relay holds
the APNs signing key, passes the notification to Apple, and keeps a seven-day
delivery record. It exists because APNs needs a provider holding a `.p8` key, and
that key should not live on a laptop.

Product contract: [`docs/prds/push-relay.md`](../../docs/prds/push-relay.md).
Plan: [`docs/plans/backplane/W13-push-relay.md`](../../docs/plans/backplane/W13-push-relay.md).

> **Deploying is your step, after the PR merges. Nothing in this repository, and
> no CI job, deploys it or calls AWS or Apple.**

## Privacy note

> Nostromo sends push notifications through a small relay that runs in a
> cloud account dedicated to it, owned personally by the operator and
> separate from any employer account. A notification contains only the kind
> of event, the name of the machine it came from, a short reference number,
> and fixed phrases such as "asked a question" or "times out in 4 min". It
> never contains questions, prompts, PR titles, people's names, mail
> subjects, or the names of work repositories; repository names appear only
> for machines the operator has marked personal, and never for repositories
> owned by the operator's employer. The relay passes each notification to
> Apple and does not store it. It keeps a delivery record — the time, the
> kind of event, whether Apple accepted it, and an anonymous device
> reference — for 7 days, then deletes it. Apple holds an undelivered
> notification for at most 4 hours (or until a decision's deadline). For
> machines the operator has marked personal, fuller details are fetched by
> the phone directly from the operator's own machines over their private VPN
> and are never sent through the relay. For work machines, no fuller details
> reach the phone at all.

What the relay stores: one DynamoDB item per attempt, `{push_id, ts, kind,
outcome, expires_at}` (TTL on `expires_at`), plus a rate counter. What it logs: the
kind, a 6-hex prefix of `push_id`, and Apple's status code. It never stores or logs
a title, body, host, reference or repository, and it has no device registry.

## What you need

- **A dedicated AWS account.** Either a *new* personal AWS account, or a *member
  account in your personal AWS Organization*. **Never a Carefeed account, and not
  your existing general-purpose personal account.** (Decision Q6, 2026-11-23.)
- An Apple Developer account with an app id for the Nostromo iOS app.
- On your machine: the [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html),
  [Cargo Lambda](https://www.cargo-lambda.info/) and a Rust toolchain.
- An AWS CLI profile for that account (`aws sso login` or access keys), used by you
  by hand. Use `--profile <your-relay-profile>` on every command below.

## 1. Create the APNs auth key

1. Apple Developer → *Certificates, Identifiers & Profiles* → *Keys* → **+**.
2. Name it `Nostromo push`, tick **Apple Push Notifications service (APNs)**, continue,
   register, and **download the `.p8`** (Apple lets you download it once).
3. Note the **Key ID** (10 characters) and your **Team ID** (top right of the
   Developer page). The **topic** is the iOS app's bundle id.

No other Apple entitlement is requested. (The notification-filtering entitlement is
not used; withdrawal is "replace in place".)

## 2. Deploy

```bash
cd infra/push-relay
sam build            # uses cargo-lambda (Metadata: BuildMethod rust-cargolambda)
sam deploy --guided  # stack name e.g. nostromo-push-relay; it asks for BudgetAlertEmail
                     # (where the monthly cost alarm writes) and MonthlyBudgetUsd (default 5);
                     # accept the other defaults. "FunctionUrlConfig may be public" is
                     # expected: the bearer token is checked in code
```

The stack creates the function and its URL (reserved concurrency 5), the DynamoDB table
(TTL on `expires_at`), the two Secrets Manager secrets, a log group with 7-day retention
and a monthly cost budget that emails `BudgetAlertEmail` at 80% actual and 100% forecast
spend. The function URL is public (`AuthType: NONE`), so every request anyone sends it is
billed: the concurrency cap and the budget are the tripwires. Note the
`FunctionUrl`, `DaemonTokenSecretArn` and `ApnsSecretArn` outputs.

### A new AWS account: "decreases account's UnreservedConcurrentExecution"

The function reserves 5 of the account's concurrent executions
(`ReservedConcurrentExecutions: 5`), and Lambda will not let a reservation take the
account's *unreserved* concurrency below its minimum (10 on an account whose quota is
still the new-account default of 10). So on a brand-new account the deploy rolls back
with `PushRelayFunction` in `CREATE_FAILED` and this message in the stack events:

```
Specified ReservedConcurrentExecutions for function decreases account's
UnreservedConcurrentExecution below its minimum value of [10].
```

(The number in brackets is the account's minimum, 10 or 100.) Lowering the reservation
does not help: with a quota of 10 no reservation, however small, leaves 10 unreserved.
Either:

1. **Request a quota increase** (the fix): *Service Quotas* → *AWS Lambda* →
   *Concurrent executions* → request at least 15 (the 5 reserved here plus the minimum
   10 unreserved; 110 if the message said 100). Approval is usually minutes to a day. Then
   `sam deploy` again (a stack that rolled back on creation must be deleted first:
   `sam delete`).
2. **Or deploy without the cap** until the increase lands: remove the
   `ReservedConcurrentExecutions: 5` line from `template.yaml`. The function URL is then
   limited only by the account's quota, so the monthly cost budget is the only tripwire:
   put the line back once the quota allows it.

## 3. Fill in the secrets

```bash
# The APNs secret: the .p8 key, key id, team id and the app's bundle id.
python3 - <<'PY' > /tmp/apns-secret.json
import json
print(json.dumps({
    "key_pem": open("AuthKey_XXXXXXXXXX.p8").read(),
    "key_id": "XXXXXXXXXX",
    "team_id": "YYYYYYYYYY",
    "topic": "com.example.Nostromo",
}))
PY
aws secretsmanager put-secret-value --profile <your-relay-profile> \
    --secret-id <ApnsSecretArn> --secret-string file:///tmp/apns-secret.json
rm -P /tmp/apns-secret.json     # or: shred -u /tmp/apns-secret.json on Linux

# The daemon token was generated for you; write it straight to the primary's token
# file, never to the terminal or a command line.
(umask 077; aws secretsmanager get-secret-value --profile <your-relay-profile> \
    --secret-id <DaemonTokenSecretArn> --query SecretString --output text \
    > ~/.nostromo/push-relay-token)
```

Keep the `.p8` somewhere safe and out of this repository.

## 4. Point the primary at it

On the primary (the machine running `nostromd` as `mode = "primary"`):

```toml
# ~/.config/nostromo/config.toml
[push]
relay_url = "https://<function-url>"   # the FunctionUrl output (no trailing path)
# relay_token_path = "~/.nostromo/push-relay-token"   # the default
```

```bash
umask 077
printf '%s' '<daemon token from step 3>' > ~/.nostromo/push-relay-token
```

Restart `nostromd`. Classify your machines (a host you do not classify counts as
*work*; Kobe is work):

```bash
nostromo push host sendai personal
nostromo push work-owner add my-employer-org     # only if you have another employer's org
nostromo push status                              # devices, settings, last delivery; never tokens
```

### Host names

Set `host_name` explicitly in each satellite's `config.toml`. The default comes from
the OS host name, which an MDM may set to something that names a person; a name that
does not match `^[a-z][a-z0-9-]{0,15}$` shows as the literal `host` in a notification.

## Rotating the daemon token (no redeploy)

The new token never appears on a command line, so it stays out of shell history and the
process list:

```bash
umask 077
openssl rand -base64 48 | tr -d '=/+\n' | head -c 48 > /tmp/new-relay-token
aws secretsmanager put-secret-value --profile <your-relay-profile> \
    --secret-id <DaemonTokenSecretArn> --secret-string file:///tmp/new-relay-token
mv /tmp/new-relay-token ~/.nostromo/push-relay-token      # on the primary (mode 600 from the umask)
```

The handler re-reads the secret at most every 5 minutes, so there is a short window
in which the primary's new token is refused until the relay notices; the primary does
not retry, and the next change of state notifies. The APNs key and the provider token
derived from it are cached for at most 50 minutes.

## The API

| Method and path | Purpose |
|---|---|
| `POST /push` | Bearer required. A closed JSON body (unknown fields → 400; `title` ≤ 64 and `body` ≤ 96 characters; `data` keys exactly `item`, `kind`, `host`, `ref`, `resolved`). Sends to APNs over HTTP/2 with an ES256 provider token and answers `{"apns_status": 200, "apns_reason": null}`. `aps.mutable-content: 1` is set only when the body's `mutable_content` is `true`. |
| `GET /records?push_id=<32 hex>` | Bearer required. That reference's delivery records, never older than 7 days (the read enforces it; TTL deletion is lazy). |

Two safety ceilings return 429: 60 pushes per APNs token per 10 minutes (counted on a
hash of the token, never on the `push_id`, which the caller chooses), and 600 per
10 minutes across the whole bearer. Product-level rate shaping is the primary's job.

When Apple answers `410 Unregistered` or `400 BadDeviceToken`, the primary forgets that
token (the device's settings stay) and sends nothing more to it until the phone registers
a fresh one.

## Teardown

Everything the stack made goes with it, but two things live outside the stack:

```bash
# 1. Delete the stack (function, URL, table, log group, budget, both secrets).
sam delete --stack-name <your-stack> --profile <your-relay-profile>

# 2. Secrets Manager keeps a deleted secret for a recovery window (7-30 days) unless it is
#    force-deleted; the APNs key is in one of them. Force-delete both now:
aws secretsmanager delete-secret --profile <your-relay-profile> --secret-id <ApnsSecretArn> \
    --force-delete-without-recovery
aws secretsmanager delete-secret --profile <your-relay-profile> --secret-id <DaemonTokenSecretArn> \
    --force-delete-without-recovery
```

Then, at developer.apple.com, revoke the APNs key (Certificates, Identifiers & Profiles,
Keys): a key that has left your machine should not stay valid. Finally, on the primary,
remove the `[push]` table's `relay_url` (or set `enabled = false`; no restart is needed)
and delete `~/.nostromo/push-relay-token`. `~/.nostromo/push/` holds the registered
devices and the sent log; remove it to forget them.

## Tests and the build

The relay's tests are hermetic: an in-memory store and secrets, an APNs stub on
`wiremock`, a test-generated P-256 key. No AWS, no Apple, no network. From the
repository root, run the crate's tests with Cargo's `test` subcommand and
`--manifest-path infra/push-relay/Cargo.toml` (add `--no-default-features` for the
handler alone, without the AWS SDK). Locally on the maintainer's Mac this runs in
the RWX sandbox: `rwx sandbox exec -- <that command>`. CI runs fmt, clippy with
`-D warnings` and both test builds on every change under `infra/push-relay/`
(`.github/workflows/push-relay.yml`).

## Things only a device can show (operator-verified after deploy)

- That a badge-only push (`aps: {badge: N}` with push type `alert`) corrects the
  badge on a physical iPhone.
- Whether a passive replacement of a delivered notification lights the screen or
  moves it in the list.
