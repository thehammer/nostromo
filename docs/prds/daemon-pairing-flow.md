# PRD: Pair a phone or iPad with Nostromo, and take it back

**Author:** Ada
**Status:** Signed off by Ada 2026-11-23. Design loop closed for Archie (D1–D7 signed; the operator answered Q1, Q2, Q4, Q7 and Q8 of Ada's memo). Open questions 3 and 5 were answered by the operator on 2026-11-23. One operator question stays open, open question 4, whose v1 default is permissive and must be confirmed before W10 ships. See "Sign-off and decision log" at the end.
**Answers:** Q1 in `docs/plans/backplane-sequencing.md`
**Unblocks:** W11 `ios-ws-client`, W15 `mac-device-admin`, and the device verbs in W9/W10.
**Consistent with:** `docs/visions/iphone.md`, `docs/visions/ipad.md` (both amended 2026-11-23 to match this sequence)

> **How to read this PRD after sign-off.** Text marked **(v1)** is a decision for
> this version. Text marked **(later, when opened up)** is deliberately deferred:
> it describes the experience we expect when the operator widens what reaches a
> device, and it is **not** an acceptance criterion for v1. The operator called
> v1 "a conservative first step"; the deferred items are where it opens up.

## Problem

The phone and iPad can no longer find Nostromo by themselves. Local-network
discovery is blocked on the managed laptop, and the daemon is moving to a
headless Linux box at home that the devices reach over the home network or
WireGuard. From now on each device has to be *introduced* to Nostromo once.
After that it is trusted until the operator takes the trust away.

That introduction is the only setup step the mobile surface has. It happens
rarely: twice at the start, then after a lost phone, a revoke, or a server
move. Each time, the operator will have forgotten how it worked last time.
If it is fiddly, the mobile surface never gets used. If it feels
untrustworthy, the operator won't trust the phone with anything that matters
(including, later, mail and todos), and it never becomes the place he checks.

Today the iOS app's first launch opens a local-network discovery sheet. Its
fallback is a manual form asking for a Mac's LAN IP and port. Neither works
for a server reached over a VPN. Nothing anywhere lets the operator see which
devices can reach Nostromo, or cut one off.

## Audience

One operator (Hammer), with these devices:

- **iPhone.** Paired once at home, usually standing at a desk with the Mac in
  front of him. Re-paired after a replacement or a lost phone. After that it
  is used on the commuter train over WireGuard and on cellular.
- **iPad.** Paired once. It often sits on a desk or stand with a Magic
  Keyboard attached. Holding it up to scan a screen is awkward, so typing has
  to be a full path, not a fallback.
- **The Macs.** Sendai at home and Kobe, the managed work laptop, both run
  the Mac app. These are where the operator *is* when he decides to pair or
  revoke. The server itself (Tokyo) is headless. The operator rarely has a
  shell open on it, and he reaches it over SSH only when something is wrong.
- **The bad day.** The phone is lost on a train. The operator is at a Mac,
  rattled, and wants it cut off *now*. This happens maybe once in the life
  of the product, and it has to work the first time without a manual.

## The experience

### Starting a pairing: from the Mac app (primary) or a terminal (equal fallback)

**The primary path is the Mac app on Sendai** (home). The operator chooses
**Pair a Device…** in the Mac app. A window shows:

- a large QR code and, next to it, the same pairing information as text: the
  server address the phone should use (the server's address, never the
  Mac's) and a six-digit code, grouped `123 456` for reading aloud or
  typing;
- a live countdown ("Expires in 4:52"). Codes last five minutes and work
  once;
- **(v1)** one line, with no checkbox: **"Mail, calendar and todos aren't shared from your Macs in this version."** The window never promises content that will
  not arrive (see "Mail and todos" below);
- a Cancel button, which invalidates the code at once.

The window stays up until one of four things happens. **The device pairs**:
the window changes, unprompted, to "Paired: Hammer's iPhone" and offers
Done. **The code expires**: the window says "This code expired" and offers
**New Code**. **The operator cancels** (closing the window counts as
Cancel). **(v1) The Mac loses its connection to the server** (VPN drops, lid
closes): the code dies at once, and the window says **"Lost the connection
to your Nostromo server, so this code no longer works."** Its **New Code**
button is disabled, with "Waiting for the server…", until the connection
returns. It never shows a fresh code that cannot work.

**(v1) Kobe does not pair.** Kobe, the Carefeed-managed Mac, can see the
Devices list and revoke (the lost-phone path works at work), but it cannot
issue a pairing code. On Kobe, **Pair a Device…** shows: **"Pairing new
devices is turned off on this Mac. Pair from sendai or run `nostromo device
pair` on your server."** The principle: actions that *reduce* access are safe
from any surface; actions that *widen* it come only from surfaces the
operator fully controls. See "Device administration from each Mac" below.

**The terminal path** is `nostromo device pair`. It is for when no Mac app
is at hand, such as an SSH session to the server. It shows the same things
in text: the address, the code, a text QR, the remaining time and the same
mail-and-todos line as the window. It *stays running* until one of the same
outcomes, and reports them in plain words: "Paired: iPad.", "Code expired.
Run the command again for a new one.", Ctrl-C to cancel (which invalidates
the code), or, if it loses the server: **"Lost the connection to the server.
This code no longer works. Run the command again when you're connected."**
and exits unsuccessfully. A name passed on the command line pre-fills the
name the device will be offered; it is not required. **(later, when opened
up)** A flag to issue a code that excludes mail and todos.

The TUI is not a pairing surface.

If the Mac app cannot currently reach the server, **Pair a Device…** shows
"Can't reach your Nostromo server, so this Mac can't make a pairing code
right now." It never shows a code that cannot work.

### On the phone or iPad

**First launch with no pairing** opens a single screen titled **Pair with
Nostromo**:

> On your Mac, choose **Pair a Device…** in Nostromo (or run
> `nostromo device pair` on your server). Then scan the code it shows.

It has two clearly visible buttons, **Scan Code** (primary) and **Enter Code
Instead**. Nothing else asks for attention: no discovery sheet, no
host/port form, and no permission prompts other than two that iOS owns:
the camera, only after the operator taps Scan; and, on home Wi-Fi when the
server shares that network, iOS's own Local Network question, which appears
only after the operator scans or submits a code, never on this first screen.
(iOS asks that question for any connection to an address on the same Wi-Fi
network; over the VPN, on cellular, or when the server is on a different
subnet it never appears.) **(v1)** There is no pre-prompt screen before
iOS's alert: it would add a screen to a three-action flow for an alert most
operators answer once.

**Scanning.** The operator points the in-app scanner at the QR. Pointing the
iPhone's own Camera app at the QR also works: it offers to open Nostromo,
which lands directly on the confirmation step.

**Typing.** The operator types two things: the server address, exactly as
the Mac or terminal shows it, and the six digits. If this device has paired
before, the address is already filled in. The code field accepts digits
only, moves through them as they are typed, and submits on the sixth digit
or on Return. The whole path works from a hardware keyboard without
touching the screen.

**Checking the code first.** After a scan or a typed code, the device asks
the server about the code *before* showing the confirmation step. So
"expired", "wrong", "can't reach" and the Local Network state appear right
away, before the operator types a name. **(v1)** Two rules:

- The check does **not** use up the code. Only **Pair** does. A wrong code at
  the check counts toward the five-wrong-attempts lockout; an unreachable
  check does not.
- If the code expires or is cancelled between the check and **Pair**, tapping
  **Pair** shows the matching failure sentence and keeps the name the
  operator edited.

**Confirmation.** One screen, whichever path was used:

> Pair this iPad with Nostromo at 10.0.0.5?
> Name: **[ iPad ]**  *(editable)*
> **Pair**

The name is pre-filled with the device's kind ("iPhone", "iPad"), or with
the name given on the server side if there was one. **The device's name is
decided here, on the device, by the operator holding it.** The Mac never
asks for one. If an active device already has that name, the new device is
paired under a distinct name such as "iPad 2", and that final name is what
the success screen and the device list both show.

**(v1) A pairing link on a device that is already paired.** Any pairing QR
can open the app at this step (system Camera), so the confirmation says what
will happen to the current pairing:

**What counts as the same server (v1).** The device treats the code's server
as "the same server" only if that server shows it already knows this
device's pairing, and the device never hands over its credential, or
anything that could be replayed as it, to find out. A server that cannot
show this, whatever address or name it claims, is a **different server** and
gets the loud warning below. A malicious QR therefore cannot harvest the
device's credential, and cannot pass itself off as the operator's server to
get the quieter "replaces" line. One pairing code can answer "does this
server know this device?" at most once: a second attempt with the same code
reveals nothing new.

- **Same server.** The confirmation adds: **"This replaces this iPhone's
  current pairing. The old one will be revoked."** After **Pair**, the old
  entry moves to the Revoked group with the note **"Replaced by
  re-pairing"**. Because a revoked name does not block reuse, the device
  keeps its name ("iPhone", not "iPhone 2").
- **Different server** (any server that does not show it knows this
  device's pairing, including a real server move that did not carry the
  device list across): the confirmation
  leads with a warning line in the alert style: **"This iPhone is paired with
  Nostromo at 10.0.0.5. Pairing with 10.0.0.9 disconnects it from 10.0.0.5
  and removes its Nostromo content."** **Pair** wipes local content (as on
  revoke), then pairs. Where the old server is reachable, it revokes the old
  entry; where it is not, the old entry goes stale, as with un-pair while
  unreachable.

**Success** is live data, not a checkmark. After **Pair**, the app shows
"Paired as iPad" for a moment, then the app's normal tabs with the real
Mother queue already populated. At the same moment, the Mac window or
terminal reports the pairing. The operator never sees, copies or types the
device's credential, on any surface, at any time.

Counting from first launch, the scan path is **Scan Code → (point the
camera) → Pair**: three actions to a working app. **(v1)** The count is of
the operator's actions inside the app. iOS's one-time system permission
alerts (camera on the first in-app scan; Local Network on home Wi-Fi) are not
counted. The system-Camera path never shows the camera alert.

### Living with paired devices

**The device list.** The Mac app has a **Devices** list. `nostromo device
list` in a terminal shows the same thing. Each row shows the name, the kind
(iPhone/iPad), when it was paired, and when it was last seen ("Connected
now" or "2 h ago"). **(later, when opened up)** a column for whether the
device sees mail and todos; in v1 nothing is shared, so the column would only
ever say "off" and is left out. Revoked devices stay visible in a separate
**Revoked** group with the time they were revoked (and, for a device that
re-paired, "Replaced by re-pairing"), so the history is not lost. Nothing in
the list is secret.

**Device administration from each Mac (v1).** Each Mac has a device-admin
level, held by the server and changeable only on the server (never from the
Mac it applies to):

| Level | Can see the list | Can revoke | Can turn mail and todos **off** | Can pair, or turn anything **on** |
|---|---|---|---|---|
| **full** (Sendai) | yes | yes | not in v1 (later: yes) | pair: yes; turn anything on: nothing to turn on in v1 |
| **revoke-only** (Kobe; new) | yes | yes | not in v1: nothing can be on, so no such control exists (later, when opened up: yes) | **no** |
| read-only | yes | no | no | no |
| off | no | no | no | no |

Kobe is **revoke-only** (operator decision). On a revoke-only Mac the
**Revoke** button works exactly as on Sendai; **Pair a Device…** shows the
"turned off on this Mac" line above and no code. Nothing on Kobe can raise
its own level.

*Ada's choice at sign-off, not an operator decision:* a Mac whose level the
operator has not set is treated as revoke-only, the same "unset means the
cautious class" rule the push PRD uses for host classification. **Sendai
becomes full only when the operator sets it on the server**: at the moment
he enrols Sendai with the server (that step already happens on the server),
or later from the server's terminal. If he does neither, Sendai is
revoke-only too, and his first pairing uses the terminal path
(`nostromo device pair` over SSH) until he raises Sendai's level.

**Revoking: the lost-phone path.** In the Devices list the operator selects
the row, clicks **Revoke**, and confirms a dialog that names the device
("Revoke Hammer's iPhone? It will be disconnected immediately and will need
to pair again."). From an open Mac app, Sendai or Kobe, this takes at most
four clicks and well under a minute. The row then reports what actually happened.
"Disconnected just now" means it was connected and has been cut off.
"Wasn't connected. It will be refused the next time it tries" means it was
offline. In the terminal, `nostromo device revoke` accepts the device's
name as shown in the list. Revoking one device never disturbs any other
device.

**What a revoked device shows.** Within seconds, if it is connected; on its
next attempt, if not, the phone:

- removes every piece of Nostromo content from the screen *and* from the
  device. A relaunch shows no old jobs, mail or todos;
- shows one full-screen message: **"This iPhone is no longer paired with
  Nostromo. Pair it again to reconnect."** with a **Pair Again** button
  leading to the normal pairing screen, address pre-filled.

The same screen appears if the device reaches a Nostromo server that has
never heard of it, for example after a server move that did not carry the
device list across. The sentence is still true.

**Un-pairing from the device itself.** Settings on the phone has **Un-pair
This iPhone**. If the server is reachable, the device is revoked there too,
so stale entries don't pile up in the list. If not, the phone still forgets
everything locally and says so ("Forgotten on this iPhone. Revoke it from
your Mac's Devices list when you can.").

**Server address changes.** Settings shows the server address. It can be
edited without re-pairing. If the new address answers and knows the
device, nothing else happens.

**VPN off is not un-paired.** If the server cannot be reached, the device
**never** goes to the pairing screen and never forgets its pairing. It keeps
showing last-known content, marked stale, under a banner: **"Can't reach
Nostromo at 10.0.0.5. If you're away from home, turn on your VPN."** It
reconnects by itself when the server is reachable again.

**(v1) Local Network refused after pairing.** If an already-paired device is
refused Local Network access by iOS (home Wi-Fi, server on the same
network), the banner instead reads **"Nostromo can't use your local network
to reach 10.0.0.5. Turn it on in Settings or use your VPN."** It is not the
generic VPN banner. Like every failure other than an explicit "you are not
paired" answer from the server, it never sends the device to the pairing
screen.

### What a paired device shows from several Macs (v1)

With Sendai and Kobe both feeding the server, the phone or iPad shows **one
merged list**. "Needs you" items come first, then everything else by
recency, across Macs. On the train the question is "what needs me", not
"which machine is it on".

- **Host badge only when it means something.** Each row carries its Mac's
  name (`kobe`, `sendai`) whenever the list holds rows from more than one
  Mac, live or last-known. So a closed Kobe whose last-known jobs are still
  listed keeps its badges, and so do Sendai's rows beside them. When every
  row comes from one Mac, no row shows a badge.
- **Kobe rows say what they can, in words.** Kobe is a work host: the
  server holds only states, counts and short references from it, never
  titles, questions or transcripts. A Kobe row shows the host badge, a
  reference that depends on the kind, and a phrase from **the same fixed
  vocabulary as push notifications**, so the phone and the lock screen say
  the same thing:
  - a Mother job: `Job <8-character job ref> · <reason phrase>`
    ("Job 3f9a1c2e · asked a question");
  - a PR review: `PR #<number> · <size phrase> · <n> waiting`, or without
    the size phrase when it is unknown;
  - a session or decision: the agent from the fixed set (*Mother*, *Perri*,
    *Fred*, *Teri*, *Claudia*, otherwise *A session*) and its state ("Claudia
    is waiting on you"). Never the session's own name.
- **Tapping a Kobe row** opens a card with that metadata and the line
  **"Details stay on kobe."** It never shows a blank screen or a spinner that
  does not end.
- **Transcripts, read-only, from personal hosts only (v1).** As today, the
  device shows the transcript of a personal-host session that is not marked
  sensitive and is not in a PHI repository, read-only. Kobe (work)
  transcripts, sensitive sessions' transcripts and PHI-repository
  transcripts never reach the device. Opening a Kobe session shows the same
  "Details stay on kobe." card.
- **Nothing from a busy session's message queue.** Messages typed at the Mac
  while an agent is busy (the queue chips) do not appear on the device in
  any form: no text, no count, no take-back. **(later, when opened up)** a
  count on the session row, "2 messages waiting", is a cheap later option
  and safe for work hosts too.

### The device answers nothing in this version (v1)

A paired phone or iPad is a "what needs me, and is it urgent" surface. It
never answers a decision or a permission request, never answers or resumes
a Mother job, never approves, requests changes on or merges a PR, never
enqueues Mother work, and never sends a message into a session. Where the
Mac would offer those controls, the device shows the item read-only and
says where to act ("Answer it on your Mac"). Only the Mac app, by a real
click from the operator, answers anything. **(later, when opened up)** a
device-trust design (for example Face ID-bound device keys with per-action
confirmation) would be its own PRD and security review.

### Mail and todos (the sensitive-data choice)

**(v1) Decision: mail and todos stay on the Macs, for every host.** Nothing
from Fred (mail) or Teri (todos, tickets) reaches any device in this
version, from Sendai or from Kobe. **Calendar stays home too, by default**:
Fred's calendar comes from the same Fred accounts (Microsoft 365 and/or
Google) as the mail. The
operator confirmed on 2026-11-23 that calendar stays home in v1 (open
question 5): no calendar content reaches a device, and the copy below names
it so nothing is promised.

Why, in one line: the operator confirmed on 2026-11-23 that Fred on Sendai
reads Google accounts (no Microsoft 365), and Teri is the Carefeed work
assistant. Mail, calendar and todos still stay home in v1 by decision (Q2 and
open question 5), so nothing about Fred's accounts changes what reaches a
device now. If Fred's Google accounts are personal, mail and calendar from
Sendai could be opened up later; confirm that none is a Carefeed Google
account when that is considered.

What the operator sees in v1:

- **There is no way to turn sharing on in v1, anywhere.** No checkbox, no
  terminal command or flag, and no setting or configuration key on any Mac
  or on the server lets mail, calendar or todos reach the server or a
  device. "Off" is the only state. That also means there is nothing to turn
  off: no "mail and todos" control exists on any surface in v1, including on
  a revoke-only Mac.
- The pairing window and the terminal say **"Mail, calendar and todos aren't shared from your Macs in this version."**
- The device's success screen and confirmation say nothing about mail and
  todos, because there is no choice to report.
- On every device, the Fred and Teri tabs say **"Mail, calendar and todos stay on your Mac in this version."** They never show a spinner, an empty list that
  looks like "no mail", or a "turned off for this iPad" line that implies a
  switch someone could flip.
- Device Settings shows the same sentence as the tabs where the scope would
  be.

**Final v1 copy** (exact strings; any other wording, including "Mail and
todos…" without calendar or without "in this version", is wrong):

| Where | Exact text |
|---|---|
| Mac **Pair a Device…** window (Sendai), and `nostromo device pair` output | `Mail, calendar and todos aren't shared from your Macs in this version.` |
| Device: Fred tab, Teri tab, and device Settings (where the scope would be) | `Mail, calendar and todos stay on your Mac in this version.` |

Nothing else in v1 mentions mail, calendar or todos: not the device
confirmation, the success screen, `nostromo device list`, or the Mac Devices
list.

**(later, when opened up)** The per-device permission below is the
experience we expect once the operator chooses to let mail and todos onto
devices. It is not a v1 criterion. Whether any internal plumbing is built
ahead of time is Archie's call, but no v1 build may contain a reachable way
to turn sharing on: no control, command, flag or configuration key.

Deferred design: **a per-device permission. It is granted at pairing time by
whoever issues the code, it is on by default, and it can be changed later
from the Mac or terminal.** (The default was the PRD's original open
question 1; revisit it when this opens up.)

- **The grant is made on the issuing side, never on the device.** The phone
  receiving the code cannot widen its own access. Whoever holds the Mac or
  the server shell decides. The device is *told* its scope: on the
  confirmation step, on the success screen, and in its own Settings.
- **The default is on.** These are the operator's own devices, the iPad
  vision has Fred's mailbox as a headline capability, and the iOS app
  already has Fred and Teri tabs. An off-by-default would make every first
  pairing look broken. The operator clears the checkbox when, for example,
  lending the iPad to someone.
- **Later changes take effect live.** Turning mail and todos off for a
  connected device removes that content from it within seconds, with no
  re-pair, and its Fred and Teri tabs show "Mail and todos are turned off
  for this iPad. Change this from Devices on your Mac." Turning it on fills
  them in, again without a re-pair.
- A device with mail and todos off never shows a spinner or an empty list
  that looks like "no mail". It always says *why* the tab is empty.

### Failure copy

| State | What the device shows |
|---|---|
| Code expired | **That code has expired. Codes last five minutes. Make a new one on your Mac and enter it here.** |
| Code wrong (or already used) | **That code isn't right. Check the six digits and try again.** |
| Server unreachable | **Can't reach Nostromo at 10.0.0.5. If you're away from home, turn on your VPN and try again.** |
| Local Network refused (v1) | **Nostromo can't use your local network, so it can't reach 10.0.0.5 on this Wi-Fi. Turn on Local Network for Nostromo in Settings, or use your VPN.** Buttons: **Open Settings**, **Try Again**. |
| Device revoked / unknown | **This iPhone is no longer paired with Nostromo. Pair it again to reconnect.** |

The address and device kind are the real ones. In the "unreachable",
"Local Network refused" and "wrong" cases the screen keeps what the operator
entered, so a retry is one tap. An unreachable or Local Network attempt does
not use up the code.

On the issuing side, the Mac window and terminal also have the "Lost the
connection" line above, and the existing "Too many wrong attempts. This code
is no longer valid" line. **(v1)** If two codes are open at once (Sendai's
window and a terminal), a wrong attempt counts against both, and five wrong
attempts lock out both; each place shows the "Too many wrong attempts" line
and offers a new code. Someone typing a code that died for any reason gets
the device's existing "That code isn't right" message.

## Acceptance criteria

Numbers 1–37 keep their original numbers so existing references stay valid.
Criteria amended at sign-off say **(amended 2026-11-23)**. Criteria deferred
out of v1 say **(later, when opened up)** and are not v1 tests. New criteria
start at 38.

**First launch and pairing (device)**

1. A fresh install with no pairing opens the **Pair with Nostromo** screen.
   It shows both **Scan Code** and **Enter Code Instead**. No discovery
   sheet or host/port form appears, and no permission prompt appears before
   the operator taps Scan or submits a typed code.
2. **(amended 2026-11-23)** The app completes pairing and runs normally with
   camera permission denied (typed path), and with Local Network permission
   denied whenever the server is reached over the VPN, over cellular, or on a
   different subnet from the phone's Wi-Fi.
3. **(amended 2026-11-23)** Scan path: from first launch, **Scan Code**,
   scanning a valid code and **Pair** (three operator actions) reach the main
   tabs with the server's current Mother queue showing. iOS's one-time
   camera and Local Network permission alerts are not counted as actions.
4. Typed path: entering the server address and a valid six-digit code, then
   **Pair**, reaches the same state. On an iPad with a hardware keyboard and
   no screen touches, the path can be completed with the keyboard alone.
5. On a device that has paired before (including after a revoke), the typed
   path's address field is pre-filled with the last address used.
6. Scanning the pairing QR with the iPhone's system Camera app offers to open
   Nostromo, and doing so lands on the confirmation step with address and
   code already applied. — **ambitious bet**: on the iPhone this removes
   even the "open the app, find Scan" step. It is the difference between
   pairing feeling like setup and feeling like nothing.
7. The confirmation step shows the server address and an editable name
   pre-filled with the device kind, or with the server-supplied name when one
   was given.
8. After **Pair** with a reachable server, live data appears on the device
   within 3 seconds.
9. If a second device is paired under a name an active device already
   uses, both appear in the device list under distinct names, and the second
   device's success screen shows its final name.
10. **(amended 2026-11-23)** The success screen shows "Paired as <final
    name>" and makes no claim that mail or todos will appear. *(later, when
    opened up: it states whether the device includes mail and todos.)*

**Starting a pairing (Mac app and terminal)**

11. **(amended 2026-11-23)** **Pair a Device…** in the Mac app on Sendai
    shows a QR, the server address, the code grouped as `NNN NNN`, a visibly
    counting-down expiry, the line "Mail, calendar and todos aren't shared from your Macs in this version." with no checkbox, and Cancel. The address shown
    is the server's, not the Mac's.
12. **(amended 2026-11-23; bet narrowed from "pair from Kobe" to "manage
    from Kobe")** From Kobe, the managed Mac that only dials out, the Devices
    list shows and **Revoke** works, with no connection initiated *toward*
    Kobe. **Pair a Device…** on Kobe shows "Pairing new devices is turned off
    on this Mac. Pair from sendai or run `nostromo device pair` on your
    server." and no code. — **ambitious bet**: the operator is at a Mac when
    he decides to revoke. A headless server should never force an SSH
    session for the bad-day task.
13. **(amended 2026-11-23)** When a device redeems the code, the Mac window
    changes on its own within 2 seconds to "Paired: `<final name>`". —
    **ambitious bet** (applies to 13 and 14): the operator should see the
    result where he started, not have to check the phone and wonder.
14. **(amended 2026-11-23)** `nostromo device pair` stays running and prints
    the address, code, a text QR, remaining time and the mail-and-todos line.
    On redemption it prints "Paired: `<final name>`" and exits successfully.
    On expiry it prints that the code expired and exits unsuccessfully.
    Ctrl-C invalidates the code, so entering it afterwards on a device gives
    the "wrong" message.
15. Cancel in the Mac window invalidates the code the same way.
16. A code works exactly once. After five minutes it gives the "expired"
    message.
17. After five wrong codes are tried while a pairing is open, the code
    stops working (later correct entry gives the "wrong" message). The Mac
    window or terminal reports "Too many wrong attempts. This code is no
    longer valid" and offers a new code.
18. If the Mac app cannot reach the server, **Pair a Device…** shows the
    "can't reach your Nostromo server" message and no code.

**Failure states (device)**

19. **(amended 2026-11-23)** Each of the five failure states shows exactly
    its sentence from the failure-copy table, with the real address and
    device kind substituted.
20. **(amended 2026-11-23)** After a "wrong", "unreachable" or "Local Network
    refused" result, the entered address and code are still in place, and a
    further attempt needs one tap.
21. **(amended 2026-11-23)** A pairing attempt that fails as unreachable or
    as Local Network refused does not use up the code. A later attempt with
    the same code inside its five minutes succeeds.
22. With an existing pairing and the server unreachable, the device: stays
    paired; never shows the pairing screen; shows last-known content and the
    "Can't reach Nostromo at `<address>`" banner; and reconnects without user
    action once the server is reachable again. The same holds across an app
    relaunch while still unreachable.

**Device list and revocation**

23. **(amended 2026-11-23)** The Mac app's Devices list and `nostromo device
    list` both show, for every device: name, kind, paired time and last seen
    ("Connected now" for a live connection). Revoked devices appear in a
    separate group with their revoke time. *(later, when opened up: a
    mail-and-todos on/off column.)*
24. From an open Mac app, revoking a named device takes no more than four
    clicks, including a confirmation that names the device. This works from
    Kobe as well as Sendai.
25. Revoking a connected device: within 1 second, the list row reports it
    disconnected; within 5 seconds, the device shows the "no longer paired"
    screen.
26. Revoking a device that is offline: the row says it will be refused next
    time. When the device next reaches the server, it shows the "no longer
    paired" screen.
27. After the "no longer paired" screen has appeared, relaunching the app
    shows no Nostromo content from before the revoke: no jobs, PRs, mail or
    todos. — **ambitious bet**: a lost phone that has been revoked must not
    keep the operator's mail subjects in it once it next touches the
    server.
28. Revoking one device leaves every other paired device connected and
    unaffected.
29. `nostromo device revoke` accepts a device's name as shown in the list.
30. **Pair Again** on the "no longer paired" screen leads to the normal
    pairing flow with the address pre-filled. A successful re-pair appears
    as a new active device. The revoked entry stays in the Revoked group.
31. **Un-pair This iPhone** in device Settings, with the server reachable,
    moves the device to the Revoked group in the list and returns the device
    to the pairing screen. With the server unreachable, the device forgets
    its pairing and content locally and shows the "Forgotten on this
    iPhone…" message.
32. A device that reaches a server which has never paired it shows the "no
    longer paired" screen.
33. Changing the server address in device Settings to another address that
    serves the same server reconnects without re-pairing.

**Mail and todos**

34. **(amended 2026-11-23)** On every paired device, from every host, the
    Fred and Teri tabs show "Mail, calendar and todos stay on your Mac in
    this version." and never show mail, calendar, todo or ticket content, a
    spinner, or an empty list. (Calendar is the v1 default pending open
    question 5.) No surface (Mac window, terminal, device confirmation,
    success screen, device Settings, Devices list) offers a mail-and-todos
    checkbox, flag or toggle. *(later, when opened up: a device paired with
    mail and todos on shows Fred and Teri content; one paired with it off
    shows the "turned off for this `<device>`" explanation.)*
35. **(later, when opened up)** Changing a connected device's mail-and-todos
    setting from the Mac Devices list (or the terminal) changes what the
    device shows within 5 seconds, without a re-pair or relaunch. Turning it
    off removes content already on screen. — **ambitious bet, deferred**:
    lending the iPad has to be a toggle, not "un-pair, re-pair, set up
    again". Not a v1 test.
36. Nothing on the device can widen its own mail-and-todos access.

**The credential**

37. No screen, window, terminal output, list, notification or log the
    operator can see ever shows the device's credential, and no flow asks
    the operator to type or paste one.

**Added at sign-off (2026-11-23), all v1**

*Local Network (D1)*

38. On home Wi-Fi, with the server on the same network and Local Network
    permission denied, a pairing attempt shows exactly the "Local Network
    refused" sentence (not the "unreachable" one), with **Open Settings**
    and **Try Again**. **Try Again** after the permission is granted pairs
    with the same code.
39. On an already-paired device in the same situation, the stale-content
    banner reads exactly "Nostromo can't use your local network to reach
    `<address>`. Turn it on in Settings or use your VPN." The device stays
    paired and never shows the pairing screen.
40. iOS's Local Network alert never appears on the first-launch screen; it
    can appear only after a scan or a typed submit.

*Checking the code before confirmation (D4)*

41. "Expired", "wrong", "unreachable" and "Local Network refused" appear
    before the confirmation step, not after **Pair**.
42. A code that passed the check can still be used: the check alone never
    uses it up. A wrong code at the check counts toward the five-attempt
    lockout; an unreachable check does not.
43. If the code expires or is cancelled after the check and before **Pair**,
    tapping **Pair** shows the matching failure sentence, and the name the
    operator edited is still in the field.

*A code dies with its window or connection (D3)*

44. Closing the Pair window invalidates the code exactly as Cancel does.
45. If the Mac showing a code loses its connection to the server, that code
    stops working at once; the window shows "Lost the connection to your
    Nostromo server, so this code no longer works." and a **New Code**
    button that is disabled, with "Waiting for the server…", until the
    connection returns. No code is shown while disconnected.
46. If `nostromo device pair` loses the server, it prints "Lost the
    connection to the server. This code no longer works. Run the command
    again when you're connected." and exits unsuccessfully.

*Two open codes (D5)*

47. With two pairings open at once, five wrong attempts in total lock out
    both; each issuing surface shows "Too many wrong attempts. This code is
    no longer valid" and offers a new code.

*Pairing link on an already-paired device (D6)*

48. On a device paired with server A, opening a pairing code for server A
    shows "This replaces this `<device>`'s current pairing. The old one will
    be revoked." After **Pair**, the Devices list shows one active entry for
    the device under its existing name (no "2" suffix), and the old entry
    in the Revoked group with "Replaced by re-pairing". The old credential
    no longer works.
49. On a device paired with server A, opening a pairing code for server B
    shows first, in the alert style, "This `<device>` is paired with Nostromo
    at `<A>`. Pairing with `<B>` disconnects it from `<A>` and removes its
    Nostromo content." After **Pair**, relaunching shows no content from A.
    If A was reachable, A's list shows the old entry as revoked.

*Device administration from each Mac (Q1)*

50. On a revoke-only Mac (Kobe), the Devices list is visible and **Revoke**
    works (criteria 24–26 hold from Kobe); **Pair a Device…** shows the
    "turned off on this Mac" line and no code.
51. No control on a revoke-only Mac can change any Mac's device-admin level.
    A Mac whose level was never set behaves as revoke-only.

*What a device shows from several Macs (Q8, D7)*

52. The device shows one list with every "needs you" item above every other
    item, across Macs. When the list holds rows (live or last-known) from
    more than one Mac, every row carries its Mac's name; when every row
    comes from one Mac, no row carries a Mac name. (Test: Kobe disconnected
    with last-known jobs still listed, plus Sendai rows: badges shown. Only
    Sendai rows: no badges.)
53. Each Kobe row shows only its host, its kind's reference and fixed
    phrases: a Mother job as `Job <8-hex ref> · <reason phrase>`; a PR as
    `PR #<number> · <size phrase> · <n> waiting` (no size phrase when
    unknown); a session or decision as the agent from the fixed set (or *A
    session*) and its state. With marker strings in the item's title,
    question, branch, repository and session name, none appears anywhere on
    the device. Tapping the row shows a card with the same metadata and
    "Details stay on kobe.", never an empty screen or an endless spinner.
54. Messages waiting in a busy session's queue on any Mac never appear on a
    device: no text, no count, no take-back control.

*The device answers nothing (Q4)*

55. No screen on a paired device offers a control that answers a decision
    or permission request, answers or resumes a Mother job, acts on a PR
    (approve, request changes, merge), enqueues Mother work, or sends a
    message into a session. A decision or approval the device can show is
    shown read-only with "Answer it on your Mac".

*No way to turn sharing on (Q2), and re-pairing safety (D6), added after review*

56. No Mac window, device screen, terminal command or flag, and no setting
    or configuration key on any Mac or the server, turns on sharing of mail,
    calendar or todos with the server or a device. With every documented
    setting at any value, no mail, calendar, todo or ticket content reaches
    a device.
57. A device already paired with the operator's server opens a pairing code
    from a server that does not know this device (a test server, even one
    claiming the same name and address). That server receives nothing during
    the check or the pairing that lets it connect to the operator's server
    as this device, and the device shows the "different server" warning,
    not the "replaces" line.
58. Repeating the check with the same pairing code reveals nothing beyond
    the first answer about whether the server knows this device.

## In scope

- The device first-launch pairing screen, scan and typed paths, the check
  before confirmation, confirmation (including the replace and
  different-server lines), success, and the five failure states. This is
  iPhone and iPad, one flow.
- Scanning from the system Camera app into the confirmation step.
- Device Settings: server address (editable), this device's name
  (read-only), the "Mail, calendar and todos stay on your Mac in this
  version." line,
  **Un-pair This iPhone/iPad**.
- The "no longer paired" screen, and wiping content on revoke, un-pair, or
  re-pairing to a different server.
- The "can't reach" and "can't use your local network" banners and
  stale-content behaviour for a paired device.
- The merged multi-Mac list, Kobe's metadata-only rows and card.
- Mac app (W15): **Pair a Device…** on Sendai, the "turned off on this Mac"
  state on Kobe, and **Devices** (list, revoke) on both.
- Device-admin levels per Mac, including the new **revoke-only** level,
  changeable only on the server.
- Terminal: `nostromo device pair` waiting for and reporting the outcome
  (including lost connection); `device list` showing the columns above;
  `device revoke` by name.

## Out of scope

- **Pairing from the TUI.** The Mac app and terminal cover every case. A
  third surface is one more thing to forget.
- **Renaming a device after pairing.** Un-pair and pair again if the name
  matters. Revisit only if someone actually asks.
- **Pairing without the home network or VPN.** The device must be able to
  reach the server to pair. No relay or cloud-assisted introduction.
- **Automatic discovery of the server.** The QR or the typed address is the
  only way in. Local-network discovery stays only as the legacy option in
  Settings and never appears on first launch.
- **Detecting whether the VPN is on.** The app reports only what it tried
  and that it failed.
- **Remote wipe of a revoked device that never reconnects.** Revoke stops it
  from getting new data. Data already on a lost, offline phone is protected
  by the phone's own lock, not by Nostromo.
- **Multiple operators, shared devices, or per-device permissions beyond
  mail-and-todos.**
- **Re-authenticating the operator (Touch ID or a password) before pair or
  revoke on the Mac.** The Mac's own login is the boundary.
- **Push-notification registration** (Q2 / W13). Pairing must not wait on
  it.
- **Choosing between several servers on one device.** One device pairs with
  one Nostromo. (Re-pairing to a different server replaces the old one, with
  a warning; see criterion 49.)
- **(v1) Mail and todos on any device**, from any host, and the per-device
  mail-and-todos permission, checkbox, flag and live toggle. *(later, when
  opened up.)*
- **(v1) Pairing from Kobe.** Kobe manages (list, revoke) but never issues a
  code.
- **(v1) Answering anything from a device**: decisions, permission requests,
  Mother questions, PR actions, Mother enqueue, sending messages. *(later,
  when opened up, through its own device-trust PRD.)*
- **(v1) The message queue on a device**: waiting messages, their count, and
  take-back. *(later, when opened up: a count only.)*
- **(v1) A pre-prompt screen before iOS's Local Network alert.**
- **(v1) Kobe item details on a device.** Kobe rows are metadata only. An
  end-to-end-encrypted on-demand fetch through Kobe's own connection is a
  possible later bet, not in this sequence.

## Product risks

- **A leaked code pairs a stranger.** A photo of the Mac screen, or a code
  read aloud, is enough within five minutes. Mitigations as experienced:
  single use, five minutes, a code that dies with its window or connection,
  a live "Paired: `<name>`" report where the code was issued, wrong-attempt
  lockout, and a list where an unexpected device is obvious and one revoke
  away. In v1 a stranger's device would see job states and Sendai's
  non-mail content, never mail or todos. If this still feels too open, the
  answer is to change what a device sees, not to add steps.
- **A pairing QR re-homes a phone to someone else's server.** Any QR in the
  wild can open the app at the confirmation step. The different-server
  warning (criterion 49) is the mitigation; a phone must never quietly start
  showing another server's content as if it were Nostromo's.
- **The phone feels thin.** With mail and todos at home, Kobe rows
  metadata-only and no answering, the device is a "what needs me" surface.
  The risk is that the operator stops opening it. The PRD accepts this for
  v1 as a conservative first step; the deferred items are the path to
  opening it up.
- **"Can't reach" mistaken for "broken pairing".** If VPN-off ever lands on
  the pairing screen or loses the pairing, the operator re-pairs needlessly
  and stops trusting the app. Criterion 22 exists to prevent this; it is
  the criterion most likely to regress quietly.
- **Device management from the managed work laptop.** Showing the device
  list and revoke control on Kobe, an employer-managed machine, puts
  personal-device administration on a computer the operator does not fully
  control. **(v1)** Answered by the revoke-only level: anything that can
  drive Kobe (including remote-management tools that might pass the Mac
  app's real-click check) can only reduce access, never widen it.
- **Stale entries pile up.** Reinstalling the app or a dead phone leaves a
  device that never returns. "Last seen" and on-device un-pair keep this
  readable. If the list still grows noisy, the operator will stop reading
  it, and then a strange device won't stand out.
- **Wiping content on revoke surprises the operator** when he revoked the
  wrong device. That is acceptable: re-pairing is quick, and leaving mail
  on a device the operator meant to cut off is not.
- **The bets in criteria 12 and 13 slip.** That leaves a headless server and
  SSH as the only way to pair or revoke, which is the "fiddly" outcome this
  PRD is written to prevent. Treat a fallback to terminal-only as a scope cut
  that needs Ada's sign-off, not a quiet implementation detail.

## Open questions

The draft's two questions were answered on 2026-11-23 (1 and 2), and so
were questions 3 and 5 (below). One question remains open for the operator,
**question 4, whose default is permissive**: v1 assumes yes, and a "no"
closes things. Nothing waits on the answer to build W9; it must be
confirmed before W10 ships.

1. ~~**Should mail and todos be on by default for a newly paired device?**~~
   **Answered: mail and todos stay on the Macs in v1, for every host** (so
   there is no default to choose yet). Revisit when opening up.
2. ~~**Should Kobe be allowed to pair and revoke personal devices, or only
   see the list?**~~ **Answered: Kobe is revoke-only.** In v1 it can list
   and revoke. (Turning mail and todos off is part of the level, but v1 has
   no such control, because nothing can be on. It applies later, when opened
   up.) It cannot pair or turn anything on.
3. ~~**Which accounts (Microsoft 365 and/or Google) does Fred read on
   Sendai?**~~ **Answered 2026-11-23: Google.** Fred on Sendai reads Google
   accounts and no Microsoft 365. Mail, calendar and todos still stay home in
   v1 (Q2 and question 5), so nothing changes now. The operator did not state
   whether any of the Google accounts is a Carefeed Google account; Carefeed
   uses Microsoft 365, so they are assumed personal. Confirm that when
   opening mail or calendar up to devices later.
4. **Open: does the employer's policy allow Kobe's job states, short
   references and host name to leave Kobe** for the operator's personal
   server, the push relay and Apple, and to show on a personal phone?
   *v1 default (permissive):* yes. Kobe sends only fixed-vocabulary
   metadata, never Carefeed text. The default is permissive because without
   Kobe's metadata the backplane has little purpose: most jobs run there.
   **It must be confirmed against the employer's policy before W10 (the
   satellite uplink) ships.** If the answer is no, Kobe sends nothing to
   the server: the phone shows no Kobe rows, sends no Kobe pushes, and
   Kobe's revoke-only device administration also goes, since it travels
   over the same uplink. Specifically, these lapse: criterion 12 (manage
   from Kobe), the "works from Kobe" part of criterion 24, criterion 50, and
   the lost-phone-at-work path. Revoking then happens from Sendai or the
   server's terminal.
5. ~~**Does calendar stay home too?**~~ **Answered 2026-11-23: yes.**
   Calendar stays on the Macs with mail and todos in v1, and the copy says
   "Mail, calendar and todos…". Fred's calendar comes from the same Google
   accounts as the mail on Sendai.

---

## Design-loop notes for Ada

**Signed off by Ada 2026-11-23.** Archie's turns below are kept as the record
of the loop. The sections above already carry every agreed change; where a
turn below disagrees with them, the sections above win. The sign-off and the
operator's decisions follow the last turn.

**From:** Archie, design loop turn 1 (2026-10-10).
**Plans:** `docs/plans/backplane/W9-ws-transport.md` (daemon and terminal),
`W10-satellite-uplink.md` (relay from a satellite Mac),
`W11-ios-ws-client.md` (iPhone/iPad), `W15-mac-device-admin.md` (new: Mac
app). The sequencing memo marks Q1 answered.

Every one of the six ambitious bets is planned as written. Nothing below
plans less than an acceptance criterion without asking you first. Items
D1–D6 need your sign-off or your copy before W11 and W15 are dispatched.
The rest is for information.

### The flagged criteria

| AC | Decision | Where |
|---|---|---|
| AC12, AC24 (pair and manage from Kobe) | **Planned as written.** The Mac app sends pair/list/revoke/scope to its local daemon. On a satellite, that daemon relays them up the uplink it already dials out on, and answers come back the same way. Nothing connects toward Kobe. The primary, not Kobe, holds how much each Mac may do (`full`, `read-only` or `off`), so your open question 2 becomes a setting, not a redesign. | W9 (admin verbs), W10 (relay and enforcement), W15 (UI) |
| AC13 (Mac window updates on its own) | **Planned.** The pairing is owned by the window's connection, and the outcome is pushed to it. | W9, W10, W15 |
| AC14 (`device pair` stays running) | **Planned as written,** including exit codes and Ctrl-C invalidating the code. | W9 |
| AC35 (live mail-and-todos change) | **Planned as written.** A connected device's permission is re-checked the moment it changes. Off removes content already on screen; on refills it without a reconnect. The daemon side completes in under 1 s. | W9, W11, W15 |
| AC17 (lockout after five wrong attempts) | **Planned,** with the clarification in D5. | W9, W15 |
| AC27 (wipe on revoke) | **Planned.** Note the coupling: AC22 needs last-known content to survive a relaunch, so the phone now keeps an encrypted on-disk copy (readable only while the phone is unlocked). A revoke deletes the credential, then that copy, then shows the screen. | W11 |
| AC6 (system Camera opens the app) | **Planned.** The QR holds a `nostromo://pair?…` link the app registers. iOS's Camera already hands such links to the app that owns them (authenticator apps work this way with `otpauth://`). It needs no web domain. W11 lists an on-device check because the simulator cannot prove it. | W11 |
| AC9 (name dedup) | **Planned as written** ("iPad", "iPad 2", …). Revoked names don't block reuse. | W9 |
| AC31 (un-pair from the device) | **Planned as written.** If the server doesn't answer within 5 s, the phone forgets locally and shows your message. | W9, W11 |

### Needs your sign-off or copy

**D1. Local Network permission (AC2, and "no permission prompts other
than the camera").** *Evidence:* Apple TN3179, "Understanding local network
privacy". It says: "A local network is an IP network associated with a
broadcast-capable network interface. Such interfaces include Wi-Fi and
Ethernet, but not cellular (WWAN) or VPN." It also says an outgoing TCP
connection to a local network address "requires local network access", in
checks that "apply to all networking APIs … `URLSession`". So, when the
phone is on home Wi-Fi and the server's address is on that **same Wi-Fi
subnet**, iOS will show its Local Network alert at the first connection.
If the operator denies it, the connection fails. Nothing in the app can
avoid that. Over WireGuard, on cellular, or when the server sits on a
different routed subnet (a separate VLAN on the UDM Pro), no alert appears
and AC2 holds.
*Proposal:* (a) AC2 reads "…with Local Network permission denied, when the
server is reached over the VPN or from another subnet." (b) The "no
permission prompts other than the camera" line gains "and, on the home
Wi-Fi only, iOS's own Local Network question when the server shares that
network". (c) A fifth failure state, distinct from "unreachable", for
"Local Network access is off and the server is on this Wi-Fi". It needs
your sentence; mine for reference: "Nostromo needs Local Network access to
reach 10.0.0.5 on this Wi-Fi. Turn it on in Settings > Privacy & Security >
Local Network." (d) An operator note: putting Tokyo on its own VLAN removes
the alert entirely. That is the operator's choice, not a product
requirement.

**D2. AC3's three actions on the very first in-app scan.** The first time
**Scan Code** is used, iOS shows its camera-permission alert, a tap the app
cannot suppress (`AVCaptureDevice` requires the grant before capture).
*Proposal:* AC3 counts operator actions in the app, excluding iOS's
one-time permission alert. The system-Camera path in AC6 already has
camera permission and never shows it.

**D3. A pairing lives only as long as the window or command that shows its
code.** Closing the Pair window counts as Cancel. If that Mac loses its
connection to the server while the window is up (VPN drops, laptop lid
closes), the code stops working at once rather than staying redeemable with
nobody watching. That is safer, and it keeps AC13's promise that the
result appears where pairing started. It needs one more message in the
window and the terminal, with **New Code**; mine for reference: "Lost the
connection to your Nostromo server, so this code no longer works."

**D4. The confirmation step comes after a check with the server.** AC7
pre-fills a name given on the server side, and the confirmation step
states the device's scope. Both are known only to the server. So after a
scan or typed code, the device asks the server about the code first, and
then shows the confirmation. As a result, "expired", "wrong" and "can't
reach" appear *before* the confirmation screen rather than after **Pair**.
A wrong code at that check counts toward the AC17 lockout. Behaviour is
otherwise unchanged. Please confirm the order.

**D5. AC17 when two codes are open at once.** A wrong code can't be pinned
on one pairing, so a wrong attempt counts against every pairing open at
that moment. With one pairing open (the normal case) this is exactly
AC17. With two open (Sendai's window and a terminal at the same time),
five wrong attempts lock out both. Information only, unless you object.

**D6. A pairing link opened on a phone that is already paired.** AC6 lets
any pairing QR open the app at the confirmation step. On an already-paired
phone, I propose the confirmation adds one line: "This replaces this
iPhone's current pairing." **Pair** then re-pairs. The old entry stays in
the list until revoked or un-paired; the alternative is to revoke it
automatically. Your call and your copy.

### For information

- **Open question 2 (Kobe).** Both answers are buildable without changing
  the plans. The primary stores each Mac's device-admin level, set with
  `nostromo device admin kobe full|read-only|off` on the server. If the
  operator chooses "read-only", W15 needs one line of copy for the disabled
  controls on Kobe, and one for **Pair a Device…** when it is not allowed
  there. The technical consequence for the operator to weigh: with `full`,
  anything that controls Kobe can pair a device that reads mail and todos.
- **Open question 1 (default on).** Both answers are a one-line default in
  W9/W15. Nothing else changes, as you said.
- **AC37.** To keep it, the terminal no longer has a command that prints a
  credential. Satellite Macs also enrol with a code (`nostromo device pair
  --satellite kobe` on the server, `nostromo uplink pair` on the Mac).
- **AC22 regression guard.** Only an explicit "you are not paired" answer
  from the server moves a device to the pairing screen. W11 tests every
  other failure (timeout, refused, network down, server error) against
  that rule.
- **Technical criteria added:** unauthenticated connection attempts are
  rate-limited per address. Codes live only in the server's memory and are
  never written to disk. The credential is stored as a hash on the server
  and only in the device's Keychain on the device.

### Turn 2 (Archie, 2026-10-18): reconciliation with main, for information

Nothing here changes an acceptance criterion; D1–D6 above still await your
sign-off. The refresh of `docs/plans/backplane-sequencing.md` records the
details.

- **The terminal command keeps its name.** The old `nostromo` binary (the
  terminal UI) was removed on main. The plans add a new, small `nostromo`
  command whose only job is `device …`, `uplink …` and `push …`, so the
  PRD's `nostromo device pair` copy stands.
- **Pair and widen need a real click in the Mac app.** On main, the Mac
  app's sensitive buttons only act on a genuine human click (not app-control
  or synthetic input). W15 applies the same rule to issuing a pairing code,
  turning mail and todos on, and Revoke. This adds no step for a person.
- **Kobe's devices show less.** Kobe is now a "work" host that sends only
  states and counts to the server (no titles, transcripts, mail or todos;
  nothing from the PHI repositories). A paired phone sees Kobe's Mother jobs
  as state and reference only. Mail and todos from Kobe are not sent to the
  server at all, so a device's mail-and-todos permission covers Sendai's
  only. This narrows what AC34/AC35 can show from Kobe; it does not change
  the criteria.
- **No approving from a device.** Approvals and decisions are answered only
  in the verified Mac app (merged on main). A paired device sees "needs you"
  counts; it never sees the request or answers it. The PRD never promised
  otherwise.

### Turn 3 (Archie, 2026-11-23): one new sign-off, one note

D1–D6 above still await your sign-off; nothing in them changed. Main moved
237 commits; the refresh of `docs/plans/backplane-sequencing.md` has the
details. One new item needs you:

**D7. Should a paired phone see, and take back, messages waiting in a busy
session's queue?** On the Mac, a message typed while the agent is busy now
waits as a chip under the composer; the operator can take it back to edit it,
or remove it, and pressing Stop hands the waiting messages back to the
composer. None of that reaches a phone: the daemon refuses the queue view,
take-back and remove to every network peer (`src/ipc/peer.rs:1103-1105`), and
the queue frames never go to one (`:798-800`). On the Mac side, any local
client may watch the queue (`src/ipc/server.rs:1725-1733`); only take-back and
remove are limited to the verified Mac app (`docs/message-queue.md`, "Who may
call what"). Options: (a) the phone shows the
waiting messages and can take one back; (b) the phone shows nothing about
them (today); (c) the phone shows a count only ("2 waiting") on the
session's row. *Proposal: (b) in this version, (c) later if wanted.* A phone
cannot send messages in this version, so it never has a message of its own
waiting; taking one back is driving the session, which stays at the Mac like
approvals; and waiting text is unsent input that need not travel to the
server. If you choose (c), it needs one line of copy (mine for reference:
"2 messages waiting"). (a) would need the device-trust work this PRD leaves
out.

*For information:* when several waiting messages are answered in one turn,
the Mac shows them as separate bubbles under "sent together"; the phone
already draws them the same way (stacked bubbles) and will keep doing so
over the new connection. No criterion changes.


---

## Sign-off and decision log

**Signed off by Ada 2026-11-23.** D1–D7 are signed below. Both open
questions and the sequencing memo's Q3 (multi-host presentation) were
answered by the operator on 2026-11-23. He took the recommendation on every
question and called v1 "a conservative first step; things can open up
later". All of it is written into the sections above.

### Operator decisions (2026-11-23)

Numbers are the operator-question numbers in Ada's sign-off memo (Q1–Q8).
The push PRD's log uses the same numbering.

| # | Decision (v1) | What it reverses or narrows | Later, when opened up |
|---|---|---|---|
| Q1 | **Kobe is `revoke-only`**, a new device-admin level: list, revoke, turn mail and todos off. It cannot pair or turn anything on. In v1 the "turn off" part has no control, because nothing can be on (Q2). (That an unset Mac is revoke-only, and that Sendai becomes full only when set on the server, is Ada's choice, recorded below.) | Narrows AC12's bet from "pair from Kobe" to "manage from Kobe". Reverses the draft's "Kobe does everything" (draft open question 2). | Raise Kobe's level on the server if employer policy and the remote-management question are ever settled. |
| Q2 | **Mail and todos stay on the Macs for every host.** No checkbox, flag, toggle, terminal command or configuration key on any surface or machine can turn sharing on. The pairing window says "Mail, calendar and todos aren't shared from your Macs in this version."; the Fred and Teri tabs and device Settings say "Mail, calendar and todos stay on your Mac in this version." (exact text per AC11, AC34 and the "Final v1 copy" table; "calendar" is Ada's default pending open question 5). Operator answers the same day: Fred on Sendai reads Google accounts (open question 3) and calendar stays home (open question 5), so mail, calendar and todos stay home for every host in v1. | Reverses the draft's "on by default" grant (draft open question 1). AC34 rewritten; AC35 deferred; AC10, AC11, AC13, AC14, AC23 drop the scope wording. | The per-device permission, its default and the live toggle (AC35's bet), once the operator confirms whose mail Fred reads. |
| Q8 (multi-Mac list) | **One merged list**, "needs you" first, host badge whenever the list holds rows from more than one Mac. Kobe rows use push's fixed vocabulary; the tap card says "Details stay on kobe." | Nothing (new). | Sections or a host switcher, if the merged list proves confusing. |
| Q4 | **The device answers nothing in this sequence**: no decisions, approvals, Mother questions, PR actions, enqueue or sending. | Narrows `docs/visions/iphone.md` and `docs/visions/ipad.md` (amended in the same change). | A device-trust PRD (Face ID-bound keys, per-action confirmation) and its own security review. |
| Q7 (= D7) | **Nothing from the message queue on a device**: no text, count or take-back. | Nothing; this is today's behaviour. | A count, "2 messages waiting", on the session row. |
| Open question 3 | **Fred on Sendai reads Google accounts** (no Microsoft 365). Mail, calendar and todos still stay home in v1. | Replaces Ada's working assumption that Fred's mail is probably Carefeed's Microsoft 365 tenant. | Open mail and calendar to devices, after confirming no Google account is Carefeed's. |
| Open question 5 | **Calendar stays home in v1**, with mail and todos. | Nothing (confirms Ada's default). | A calendar quick-view on the phone, if the source is personal. |

### Ada's sign-offs

- **Ada's choices at sign-off (not operator decisions; conservative
  defaults the operator may open up):** a Mac with no device-admin level set
  is revoke-only, and Sendai becomes full only when the operator sets it on
  the server; calendar stays home until the operator answers open question
  5; Kobe rows use per-kind references (criterion 53).
- **Answered 2026-11-23:** open question 3 (Fred on Sendai reads Google
  accounts) and open question 5 (calendar stays home).
- **Still open for the operator:** open question 4 (employer policy on
  Kobe metadata leaving Kobe). The loop is closed for Archie: it has a v1
  default, which is permissive and must be confirmed against the employer's
  policy before W10 ships.

- **D1, Local Network on home Wi-Fi: accepted, with changes.** AC2 rewritten;
  first-screen wording changed; a fifth failure state in Ada's words, with
  **Open Settings** and **Try Again**, that does not use up the code; a
  matching banner for an already-paired device that never sends it to the
  pairing screen. No pre-prompt screen. Operator note, not a requirement:
  putting the server on its own VLAN removes the alert entirely.
- **D2, iOS alerts not counted in AC3: accepted,** extended to the Local
  Network alert.
- **D3, a code dies with its window or connection: accepted, with Ada's
  copy** for the Mac window (New Code disabled until reconnected) and the
  terminal. No new device copy.
- **D4, check before confirmation: accepted,** plus two rules for Redd: the
  check does not use up the code (a wrong code counts toward lockout, an
  unreachable check does not); a code that dies between the check and
  **Pair** shows its sentence and keeps the edited name.
- **D5, lockout across open codes: accepted as written.**
- **D6, pairing link on an already-paired device: accepted, with a change.**
  The old entry is revoked automatically ("Replaced by re-pairing"), so the
  name is kept. A code for a different server gets a loud warning first and
  wipes local content. *Added after review (Ada, 2026-11-23):* "same server"
  means a server that shows it knows this device's pairing without the
  device revealing its credential, and one code can test that at most once
  (criteria 57–58). A malicious QR must not be able to harvest the
  credential.
- **D7: signed as the operator's Q7 answer above.**

### Code facts checked on `origin/main` (d191dd4d) for this sign-off

- The message queue never reaches a network peer: the queue frames are
  local-only (`src/ipc/peer.rs:798-800`), and watch, take-back and remove
  are refused for every network peer (`src/ipc/peer.rs:1103-1105`;
  `docs/message-queue.md`, "Who may call what").
- A network peer cannot send into a session (`SessionSend`,
  `src/ipc/peer.rs:1076`) or answer a decision or approval
  (`DecisionAnswer`, `ApprovalAnswer`, `src/ipc/peer.rs:1085-1086`).
- An agent's decision fails at once with `no_operator` unless the verified
  Mac app is connected (`src/mcp/tools/ask_decision.rs:89-90`).
- Fred's mailbox reads Microsoft Graph, borrowing the `m365` CLI's token
  (`src/data/fred_mailbox_native.rs`, `src/data/graph_client.rs`). Which
  tenant that is on Sendai is not visible in the repo.
