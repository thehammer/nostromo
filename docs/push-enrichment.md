# Push notifications: operator guide to on-phone enrichment (W16)

A push notification from the relay carries a fixed-vocabulary sentence (`Job 3f9a1c2e asked a
question`) and nothing the operator or a repository wrote. **Enrichment** is the one exception: when a
notification arrives on your phone and the phone can reach your Mac (the WireGuard on-demand tunnel is
up), the phone's Notification Service Extension asks the primary, over the phone's own authenticated
socket, for the item's **first line** (a Mother job's question, a PR's title, a decision's prompt, at most
140 characters) and shows it as the notification body. The line never passes through the relay or Apple.
If the phone cannot reach the primary within about four seconds, the notification shows the fixed
sentence, unchanged.

This page is the operator's reference for turning enrichment on and off and for what it can still expose.
Setting up the relay itself is in [`infra/push-relay/README.md`](../infra/push-relay/README.md); the product
contract is [`docs/prds/push-relay.md`](prds/push-relay.md) ("On-phone enrichment") and the plan is
[`docs/plans/backplane/W16-ios-push-enrichment.md`](plans/backplane/W16-ios-push-enrichment.md).

## What turns enrichment on

Enrichment is **default-deny**. The primary returns text for an item only if **all** of these hold:

1. **The item's host is classified `personal`** under `[push.hosts]`. A host that is not listed is `work`,
   and so is a satellite whose egress is `work`: the primary never holds the text of a work host's items.
   Listing a host as `personal` is what turns enrichment on for it:

   ```bash
   nostromo push host sendai personal     # no restart: the engine re-reads the table on each request
   ```

   ```toml
   # ~/.config/nostromo/config.toml on the primary
   [push.hosts]
   sendai = "personal"
   tokyo = "personal"
   kobe = "work"
   ```
2. **The item is not in a PHI repository.** `admin-portal` and `referral-monitor` are always PHI and cannot
   be removed. Add more with `push.phi_repos` (it can only grow; names are compared ignoring case). The
   check looks at the item's repository, plan path, PR URL and the focus that queued it.
3. **The item's repository owner is known and is not a work owner.** `Carefeed` is always a work owner and
   cannot be removed; add others with `nostromo push work-owner add <owner>` or `push.work_owners` (case
   is ignored; no restart). An item with no repository, or whose owner cannot be told, shows no text.
4. **The item is not on a sensitive tag** (Teri, Fred and work-item sessions) **and was not queued from a
   work item.** A decision that names no repository is denied too.

```toml
[push]
relay_url = "https://<function-url>"
work_owners = ["my-employer-org"]   # added to Carefeed
phi_repos = ["billing"]             # added to admin-portal and referral-monitor
```

The phone enforces the other side. The notification settings list each **personal** host with a **Show full
details** switch (**on by default**, per the PRD); a work host's row reads "Details stay on kobe" and has no
switch. The switch is kept on the phone and read by the extension, so turning it off stops enrichment for
that host on that phone at once. Decisions are enriched read-only: the body ends "· answer on your Mac" and
the notification offers no choice buttons.

## Read this before listing a host as `personal`

- **Keep Carefeed checkouts, other than the two PHI repositories, off a personal host, or classify that
  host as work.** For a Carefeed repository that is not `admin-portal` or `referral-monitor`, the owner rule
  is the only guard, and it is only as good as the owner the item reports (taken from the repository's
  remote or the job's PR URL). A fork under your own account, or a remote that does not name `Carefeed`,
  reads as a personal owner, and its question or PR title would be shown. The simple and safe arrangements
  are: only personal projects on Sendai, or leave Sendai classified `work` (then no text is ever returned for it).
- **Second-order exposure.** The text of a personal-host item is whatever its author wrote, and it can mention
  work. A nostromo Mother question such as "Should the uploader skip the Carefeed ticket CORE-1234?" is a
  personal-host, personally owned item and is shown on the lock screen as written. Nothing filters meaning.
  If that matters to you, leave the host's **Show full details** switch off on devices that sit on a lock
  screen, or set iOS "Show Previews" to "When Unlocked".
- Characters that hide or reorder text (zero-width and bidirectional controls, tag characters, soft hyphens,
  fillers) are removed, line breaks end the line, and the line is cut at 140 characters. That is hygiene,
  not a content filter.

## Turn enrichment off

- **Everywhere, from the primary:** classify every host as `work` (`nostromo push host sendai work`) or
  remove the `personal` entries from `[push.hosts]`. The next request from any phone is answered without text;
  no restart and no phone change are needed. Notifications keep their fixed sentences.
- **For one host on one phone:** switch off **Show full details** for it in the phone's notification
  settings.
- **Everything push, not only enrichment:** `enabled = false` under `[push]` (no restart), or remove
  `relay_url`.

## What it does not do

Any paired device can ask for the text of any item it can list: item references are 64-bit random values, every
paired device is yours, and `PushWaiting` already lists them. There is no rate limit on the request (it costs the
same bounded scan as `PushWaiting`). A revoked device is refused like any other verb.

## The socket

The extension opens a one-shot WebSocket with the device token in the `Authorization` header, sends `hello`,
waits for the `Welcome`, sends one `subscribe` on a topic a paired device is never sent a frame on, and then
`push_detail`. The daemon hangs up on a connection whose second frame is not a `subscribe`, which is why the
extension sends one. (The phone's "Un-pair" does the same with `device_unpair_self`.)
