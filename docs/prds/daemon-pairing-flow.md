# PRD: Pair a phone or iPad with Nostromo, and take it back

**Author:** Ada
**Status:** Draft (Ada, 2026-10-10)
**Answers:** Q1 in `docs/plans/backplane-sequencing.md`
**Unblocks:** W11 `ios-ws-client`. It also asks for daemon-side and Mac-app behaviour that W9 and W11 do not plan yet (see "In scope").
**Consistent with:** `docs/visions/iphone.md`, `docs/visions/ipad.md`

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
untrustworthy, the operator won't let mail and todos onto the phone, and the
phone loses half its value.

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

**The primary path is the Mac app**, from either Mac: Sendai at home or Kobe
at work. The operator chooses **Pair a Device…** in the Mac app. A window
shows:

- a large QR code and, next to it, the same pairing information as text: the
  server address the phone should use (the server's address, never the
  Mac's) and a six-digit code, grouped `123 456` for reading aloud or
  typing;
- a live countdown ("Expires in 4:52"). Codes last five minutes and work
  once;
- one line stating what the new device will be allowed to see: **"Will see
  mail and todos"**, with a checkbox the operator can clear before the code
  is used (see "Mail and todos" below);
- a Cancel button, which invalidates the code at once.

The window stays up until one of three things happens. **The device pairs**:
the window changes, unprompted, to "Paired: Hammer's iPhone. Includes mail
and todos" and offers Done. **The code expires**: the window says "This code
expired" and offers **New Code**. **The operator cancels.**

**The terminal path** is `nostromo device pair`. It is for when no Mac app
is at hand, such as an SSH session to the server. It shows the same things
in text: the address, the code, a text QR, the remaining time and the
mail-and-todos scope. It *stays running* until the same three outcomes, and
reports them in plain words: "Paired: iPad. Includes mail and todos.",
"Code expired. Run the command again for a new one.", or Ctrl-C to cancel,
which invalidates the code. A flag lets the operator issue a code that
excludes mail and todos. A name passed on the command line pre-fills the
name the device will be offered; it is not required.

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
host/port form, no permission prompts other than the camera, and the camera
prompt appears only if the operator taps Scan.

**Scanning.** The operator points the in-app scanner at the QR. Pointing the
iPhone's own Camera app at the QR also works: it offers to open Nostromo,
which lands directly on the confirmation step.

**Typing.** The operator types two things: the server address, exactly as
the Mac or terminal shows it, and the six digits. If this device has paired
before, the address is already filled in. The code field accepts digits
only, moves through them as they are typed, and submits on the sixth digit
or on Return. The whole path works from a hardware keyboard without
touching the screen.

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

**Success** is live data, not a checkmark. After **Pair**, the app shows
"Paired as iPad. Includes mail and todos" (or "Mail and todos are off for
this iPad") for a moment, then the app's normal tabs with the real Mother
queue already populated. At the same moment, the Mac window or terminal
reports the pairing. The operator never sees, copies or types the device's
credential, on any surface, at any time.

Counting from first launch, the scan path is **Scan Code → (point the
camera) → Pair**: three actions to a working app.

### Living with paired devices

**The device list.** The Mac app has a **Devices** list. `nostromo device
list` in a terminal shows the same thing. Each row shows the name, the kind
(iPhone/iPad), when it was paired, when it was last seen ("Connected now" or
"2 h ago"), and whether it sees mail and todos. Revoked devices stay visible
in a separate **Revoked** group with the time they were revoked, so the
history is not lost. Nothing in the list is secret.

**Revoking: the lost-phone path.** In the Devices list the operator selects
the row, clicks **Revoke**, and confirms a dialog that names the device
("Revoke Hammer's iPhone? It will be disconnected immediately and will need
to pair again."). From an open Mac app this takes at most four clicks and
well under a minute. The row then reports what actually happened.
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

### Mail and todos (the sensitive-data choice)

Decision: **a per-device permission. It is granted at pairing time by
whoever issues the code, it is on by default, and it can be changed later
from the Mac or terminal.**

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
| Device revoked / unknown | **This iPhone is no longer paired with Nostromo. Pair it again to reconnect.** |

The address and device kind are the real ones. In the "unreachable" and
"wrong" cases the screen keeps what the operator entered, so a retry is one
tap. An unreachable attempt does not use up the code.

## Acceptance criteria

**First launch and pairing (device)**

1. A fresh install with no pairing opens the **Pair with Nostromo** screen.
   It shows both **Scan Code** and **Enter Code Instead**. No discovery
   sheet or host/port form appears, and no permission prompt appears before
   the operator taps Scan.
2. The app completes pairing and runs normally with Local Network permission
   denied and with camera permission denied (typed path).
3. Scan path: from first launch, **Scan Code**, scanning a valid code and
   **Pair** (three operator actions) reach the main tabs with the server's
   current Mother queue showing.
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
10. The success screen states whether the device includes mail and todos.

**Starting a pairing (Mac app and terminal)**

11. **Pair a Device…** in the Mac app shows a QR, the server address, the
    code grouped as `NNN NNN`, a visibly counting-down expiry, the
    mail-and-todos checkbox (checked), and Cancel. The address shown is the
    server's, not the Mac's.
12. The same works from Kobe, the managed Mac that only dials out, with no
    connection initiated *toward* Kobe. — **ambitious bet**: the operator is
    at a Mac when he decides to pair or revoke. A headless server should
    never force an SSH session for a once-a-year task.
13. When a device redeems the code, the Mac window changes on its own within
    2 seconds to "Paired: <final name>" with the device's mail-and-todos
    scope. — **ambitious bet** (applies to 13 and 14): the operator should
    see the result where he started, not have to check the phone and
    wonder.
14. `nostromo device pair` stays running and prints the address, code, a
    text QR and remaining time. On redemption it prints "Paired: <final
    name>" with the scope and exits successfully. On expiry it prints that
    the code expired and exits unsuccessfully. Ctrl-C invalidates the code,
    so entering it afterwards on a device gives the "wrong" message.
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

19. Each of the four failure states shows exactly its sentence from the
    failure-copy table, with the real address and device kind substituted.
20. After a "wrong" or "unreachable" result, the entered address and code are
    still in place, and a further attempt needs one tap.
21. A pairing attempt that fails as unreachable does not use up the code. A
    later attempt with the same code inside its five minutes succeeds.
22. With an existing pairing and the server unreachable, the device: stays
    paired; never shows the pairing screen; shows last-known content and the
    "Can't reach Nostromo at <address>" banner; and reconnects without user
    action once the server is reachable again. The same holds across an app
    relaunch while still unreachable.

**Device list and revocation**

23. The Mac app's Devices list and `nostromo device list` both show, for
    every device: name, kind, paired time, last seen ("Connected now" for a
    live connection), and mail-and-todos on/off. Revoked devices appear in a
    separate group with their revoke time.
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

34. A device paired with mail and todos on shows Fred and Teri content. A
    device paired with it off never shows any, and its Fred and Teri tabs
    show the "turned off for this <device>" explanation instead of an empty
    list.
35. Changing a connected device's mail-and-todos setting from the Mac
    Devices list (or the terminal) changes what the device shows within 5
    seconds, without a re-pair or relaunch. Turning it off removes content
    already on screen. — **ambitious bet**: lending the iPad has to be a
    toggle, not "un-pair, re-pair, set up again".
36. Nothing on the device can widen its own mail-and-todos access.

**The credential**

37. No screen, window, terminal output, list, notification or log the
    operator can see ever shows the device's credential, and no flow asks
    the operator to type or paste one.

## In scope

- The device first-launch pairing screen, scan and typed paths,
  confirmation, success, and the four failure states. This is iPhone and
  iPad, one flow.
- Scanning from the system Camera app into the confirmation step.
- Device Settings: server address (editable), this device's name and
  mail-and-todos scope (read-only), **Un-pair This iPhone/iPad**.
- The "no longer paired" screen, and wiping content on revoke or un-pair.
- The "can't reach" banner and stale-content behaviour for a paired device.
- Mac app: **Pair a Device…** and **Devices** (list, revoke, mail-and-todos
  toggle), working from either Mac, including Kobe. *This is Mac-app work
  that neither W9 nor W11 currently plans. Archie to place it.*
- Terminal: `nostromo device pair` waiting for and reporting the outcome;
  `device list` showing the columns above; `device revoke` by name; a way to
  change a device's mail-and-todos setting.

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
  one Nostromo.

## Product risks

- **A leaked code pairs a stranger, with mail and todos on by default.** A
  photo of the Mac screen, or a code read aloud, is enough within five
  minutes. Mitigations as experienced: single use, five minutes, a live
  "Paired: <name>" report where the code was issued, wrong-attempt lockout,
  and a list where an unexpected device is obvious and one revoke away. If
  this still feels too open, the answer is to change the default, not to
  add steps.
- **"Can't reach" mistaken for "broken pairing".** If VPN-off ever lands on
  the pairing screen or loses the pairing, the operator re-pairs needlessly
  and stops trusting the app. Criterion 22 exists to prevent this; it is
  the criterion most likely to regress quietly.
- **Device management from the managed work laptop.** Showing the device
  list and pair or revoke controls on Kobe, an employer-managed machine,
  puts personal-device administration on a computer the operator does not
  fully control (see open question 2).
- **Stale entries pile up.** Reinstalling the app or a dead phone leaves a
  device that never returns. "Last seen" and on-device un-pair keep this
  readable. If the list still grows noisy, the operator will stop reading
  it, and then a strange device won't stand out.
- **Wiping content on revoke surprises the operator** when he revoked the
  wrong device. That is acceptable: re-pairing is quick, and leaving mail
  on a device the operator meant to cut off is not.
- **The bets in criteria 12 and 13 slip.** That leaves a headless server and
  SSH as the only way to pair, which is the "fiddly" outcome this PRD is
  written to prevent. Treat a fallback to terminal-only as a scope cut that
  needs Ada's sign-off, not a quiet implementation detail.

## Open questions

1. **Should mail and todos be on by default for a newly paired device?**
   This PRD says yes (it is the operator's own device, and Fred and Teri are
   headline content). Choose "off" if you would rather opt each device in
   explicitly. Nothing else in the flow changes.
2. **Should Kobe (the managed work Mac) be allowed to pair and revoke
   personal devices, or only see the list?** This PRD lets Kobe do
   everything, because the lost-phone moment may happen at work. If you'd
   rather keep device administration off the employer's machine, Kobe gets
   a read-only list and pairing moves to Sendai or the terminal.

---

## Design-loop notes for Ada

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
