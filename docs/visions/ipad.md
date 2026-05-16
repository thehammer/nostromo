# Nostromo for iPad

## Premise

The iPad is the middle posture between the phone (in-motion triage) and
the Mac (heads-down deep work). Hardware-wise it spans a continuum: a
mini in one hand is closer to a phone; an iPad Pro with a Magic Keyboard
and trackpad is close to a laptop. Software-wise, iPadOS now supports
multi-window, drag-and-drop, real keyboard shortcuts, Stage Manager,
and external-monitor extension.

The bet: the iPad surface should be **adaptive**, picking a posture
based on the active accessories rather than offering a single fixed
layout. Without a keyboard, lean towards iPhone-style triage with more
breathing room. With a keyboard + trackpad, lean towards Mac-style
multi-pane work, with concessions for touch.

The iPad is the most likely "I left my laptop at home but I have an
afternoon to work" backup. It needs to support meaningfully more than
the phone — light implementation work, PR reviewing, longer Claudia
conversations — without pretending to be a full Mac.

## Audience and context of use

The operator, away from the Mac, with the iPad accessible:

- **Couch / weekend / long-form ambient.** Reading agent transcripts,
  reviewing PRs at leisure, asking Claudia exploratory questions. Touch
  primary, occasional keyboard.
- **Café / co-working / travel without laptop.** Magic Keyboard attached,
  doing meaningful work for an hour or two. Reviewing diffs, having a
  multi-turn Claudia session, queuing Mother jobs.
- **Side display next to the Mac (via Sidecar or as a focused panel).**
  Pace bars, Mother queue, calendar — ambient awareness that takes pressure
  off the Mac windows.
- **Meeting / classroom / shared environment.** Surfacing Claudia in
  conversation, taking notes that flow back into Fred's calendar or
  Claudia's context. Apple Pencil for annotation, voice for capture.

The iPad is **not** the place for terminal-density TUI work (no PTY
exposure, no vt100). It is the place where rich graphics, longer-form
reading, and pencil/touch annotation pay off.

## Capabilities

- **Adaptive layout by hardware.** With keyboard + trackpad, present
  multi-pane (sidebar + content + detail), close to Mac-native scaled
  down. Without, present iPhone-style single-pane with tab navigation.
  Detect Magic Keyboard / Smart Connector and switch automatically.
- **Mother queue + plan viewer.** Same triage surface as iPhone but
  with full plan body visible side-by-side, not modal. Approve/deny
  inline with full context. Long-press to open the plan in a dedicated
  reader.
- **Perri PR review, properly sized.** Full diff viewer with side-by-side
  hunks where the screen allows. Apple Pencil annotation on diffs that
  flows back as PR comments. Approve / request-changes / comment inline.
- **Claudia in landscape, with transcripts.** Full transcript pane
  alongside a chat input. Markdown rendering with tables, code blocks,
  foldable tool calls. Voice input via Pencil-tapped dictation or
  hardware keyboard.
- **Fred mailbox + calendar split view.** Side-by-side, similar to
  Mail.app's iPad layout. Tap an email to expand; calendar updates
  in the second pane.
- **Drag-and-drop between agents.** Drag a calendar event onto a
  Claudia message ("can we move this?"). Drag a screenshot from
  Photos into a Mother brief. Drag a PR onto Perri to focus its
  diff pane.
- **External display extension.** When connected to an external monitor,
  use the second screen for the transcript pane, the queue, or pace
  bars — keep the iPad screen for input/active content.
- **Apple Pencil annotation.** Annotate a PR diff with arrows and
  highlights; submit those as part of the review note. Sketch a
  diagram in a Claudia message.
- **Stage Manager / Split View integration.** Native iPadOS
  multitasking — operator can run Nostromo alongside Notes or Safari
  without leaving the app.
- **Same daemon as iPhone.** No new transport; iPad connects the same
  way (Tailscale to Mac daemon or cloud backplane, per the unified
  decision).

## Constraints

- **No PTY, no terminal, no vt100.** Same constraint as the iPhone.
  Operators wanting terminal-density work need the Mac.
- **No code editing UI.** The operator can read code (diffs, snippets
  in Claudia, plan files) but not author new files. PRs get reviewed,
  not authored.
- **Don't replicate Mac-native one-to-one.** The iPad has its own
  conventions (full-screen apps, Stage Manager, gesture nav). Building
  a "Mac windows on an iPad" experience fights the platform. Embrace
  iPadOS idioms.
- **Pencil features are nice-to-have, not foundational.** Plenty of
  iPad operators don't use a Pencil. The app must be fully usable
  without one.
- **Single account, single operator.** Same as Mac/iPhone — no team or
  shared modes.
- **Latency tolerance same as iPhone.** Network round-trip to daemon
  is acceptable; agent latency is whatever it is.

## Resolved decisions (2026-05-16)

- **Shared SwiftUI codebase with iPhone, single Xcode project, dual
  targets.** Conditional layout based on size class + keyboard attachment.
  Same view-models and MCP client. Mac app stays its own project (AppKit
  / SwiftUI hybrid) — different posture, different toolkit conventions.
- **Ship order: after iPhone.** iPhone target ships first (commute use
  case). iPad inherits the codebase and gets its layout adaptations
  enabled afterward.

## Still open
- **Adaptive layout granularity**: how does the app decide between
  phone-style and Mac-style layouts? Probably size-class + keyboard
  attachment, with manual override available. Worth a small PRD to
  pin down the decision rules so users get a predictable result.
- **Pencil features in v1**: ship without, or include basic diff
  annotation from the start? Annotation is more compelling than it
  looks — being able to circle a diff hunk and write "this is the
  bug" is a workflow Mac and iPhone can't replicate. Probably worth
  including from v1 in some form.
- **Stage Manager support**: iPadOS Stage Manager has rough edges and
  doesn't work on older models. Test deliberately; consider whether
  the app needs to behave differently when invoked in Stage Manager vs.
  full-screen.
- **Sidecar interaction with the Mac**: when the iPad is acting as a
  Sidecar second display for the Mac, should the Nostromo iPad app
  *not* run, ceding the screen to the Mac-native app? Or should they
  coexist? Probably the iPad app silences itself on Sidecar — but worth
  confirming.
- **Multi-window**: iPadOS supports multiple windows of the same app
  in Stage Manager and Split View. Useful for "transcript on one side,
  Mother queue on the other." Likely worth supporting.

## Related work

- See `docs/visions/mac-native.md` for the primary heads-down surface.
- See `docs/visions/iphone.md` for the in-motion triage surface this
  shares a codebase with.
- Future PRDs anticipated: adaptive-layout decision rules, Pencil
  annotation on PR diffs, multi-window/Stage Manager integration,
  Sidecar interaction policy.
