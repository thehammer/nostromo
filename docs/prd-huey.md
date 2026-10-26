# PRD: Huey, a morning report written for one person about their own work

**Author:** Ada
**Status:** Approved by Hammer, revision 4 (Ada, 2026-10-25): simulation findings, Hammer's decisions and the PRD changes requested in `docs/plan-huey.md`
**Slug:** `huey` (pairs with Archie's plan of the same slug)
**Sources:** Claude Docs brief "Newsfeed: Brief for Ada" (2026-10-23); idea note `~/.claude/ideas/2026-10-24-huey-focus.md`; the user's direction change of 2026-10-25; the simulation notes `~/.claude/notes/huey-sim-2026-10-25.md` (two hand-run reports on Sendai) and the sample interests file `~/.claude/huey/interests.md` used in run 2.
**Surface:** Huey is a new **built-in Nostromo agent**, alongside Fred, Perri and Teri, inside the Nostromo repo and under Nostromo's license. As a user sees it: a focus named **Huey** on Sendai (the personal Mac Mini), with a report pane and its own Claude session, on by default and switchable off like any built-in agent. Later, a separate instance on Kobe (the work MacBook).

## Problem

The news that matters to Hammer's work (new Claude and Claude Code features,
MCP and agent SDK releases, how other people are building agentic software)
is spread across a dozen changelogs, blogs and aggregators. Keeping up means
skimming all of them, and even then the connection to his own work happens
by luck: a Claude Code release that would remove a workaround in Nostromo, or
a write-up of a pattern that a Mother job is fighting with right now, gets
noticed weeks late or never.

A generic feed does not fix this. It still hands over the job of deciding
"does this matter to me, and for what?", and that is the expensive part. The
brief's original shape (clusters of stories grouped by topic, each with a
score) is a better feed, but still a feed.

What is missing is someone who reads everything overnight, knows what Hammer
is working on this week and how those projects actually run, and leaves a
short note on the desk: "these three things matter, here is the project each
one touches, here is how it touches it." Nothing produces that today.

The simulation showed two things the note must get right. The most useful
items hide inside primary sources (a single "Added" line in a changelog), not
in headlines, so skimming misses them. And the loudest news of the week (a
new API version and 2.0 SDKs with a license change) can matter not at all,
because none of Hammer's projects uses an Anthropic SDK. Relevance has to be
about what a project is affected by, not what it is near.

## Audience

One reader, Hammer, in one moment: **the first ten minutes of the working
day**, coffee in hand, before opening the tracker or the review queue,
deciding what today is for. In v1 that is at the Mac, usually early
morning. (Reading it on the phone during the commute is the obvious next
step, and is deferred; see Out of scope.) He reads the report once, top to
bottom, and acts on at most one or two items: opens a link, asks a follow-up
in the Huey session, or drops an idea or todo. If the report takes more than
about three minutes to read, or two days in a row are padding, he will stop
opening it.

Two machines, two separate readers in effect:

- **Sendai (personal Mac Mini, always on).** Personal and open-source
  projects: Nostromo, Mother, Bishop, the agent cohort, home projects.
  **v1 runs here only.**
- **Kobe (Carefeed work MacBook).** Carefeed work. A later, separate
  instance whose report only ever knows about work context. It is in this
  PRD only to fix the privacy line now, so v1 does not paint it into a
  corner.

Secondary audience, deferred: other Nostromo users, who get Huey as a
built-in agent and would run it with their own interests and sources. v1
decisions should not make that impossible, but nothing in v1 is built for
them.

## The experience

### Setting Huey up on a machine (once)

Huey is on by default, but on a machine where it has never been set up it
reads nothing, fetches nothing and sends nothing. Opening the Huey focus
there shows only: "Huey is not set up on this machine. It has read
nothing.", the list of context sources it *would* read, and one button,
**Set up Huey on this machine**. Opening the focus does not read anything.

Only when Hammer clicks that button does Huey look at the machine's context,
and then it shows:

1. The context sources it read, listed plainly.
2. A **draft interests file** Huey wrote from that context (the projects it
   found and what they seem to be about), opened for Hammer to edit. The
   simulation's report without an interests file was visibly thinner, so
   Huey does not run without one.
3. A short **"how each project runs"** line per project Huey found (see
   below), for Hammer to glance at and correct.

Nothing is fetched and nothing is sent to a model until he confirms. When
he confirms, Huey is set up on that machine and the first report follows
(immediately, or at the next scheduled time if he prefers). On Kobe, nobody
clicks the button in v1, so Huey reads literally nothing there.

Huey keeps its files (the interests file, past reports, digests, setup
state) in **Nostromo's own folder, not in `~/.claude`**, because
`~/.claude` is synced publicly. The interests file describes Hammer's work
and preferences and must not end up in a public repo.

### Every morning, a report is waiting

At a configured time (default: ready by **06:30 local, every day including
weekends**), a new report exists. It covers everything published **since the
last report**, not a fixed number of days, so a missed morning is caught up
rather than skipped. Hammer opens the **Huey** focus and today's report is
already on screen, no waiting, no spinner. It reads like a short note
addressed to him, not a list of headlines:

1. **A one-line opener** with the date and the gist ("Two things for
   Nostromo today, one for Mother; quiet otherwise.").
2. **Picks, at most five, usually two to four.** Each pick has:
   - a plain headline in Huey's words (not the source's title);
   - one or two sentences on what actually happened;
   - **"For <project>:"** one or two sentences on **how that project is
     affected**: something it could adopt, a workaround it could delete,
     something that breaks or changes for it, a decision it bears on. The
     line names something concrete in the project (an open PR, a tracker
     item, an idea, a Mother job, how the project runs);
   - **what Huey checked**: either "Checked: <what>" (for example, "Mother's
     workers run `claude -p`; they would pick this up") or, when Huey could
     not tell, "To check: <the one specific thing>";
   - the primary link first, plus "also covered by" links when the same
     story appeared in several places (one story is one pick, never three).
3. **"Also in the news"**, one line: the week's top first-party
   announcement, whether or not it touches his work (see below). Omitted
   when there is nothing new to put there.
4. **"Also noted"**, at most five one-line items with links, each tied to one
   of Hammer's stated interests and tagged with it in a few words. Worth
   knowing, but not something a project is affected by today. Items in a
   "want less of" interest never appear here.
5. **A footer** saying what Huey looked at and left out:
   - how many items, from which sources;
   - which first-party sources it **read in full** for the window (every
     changelog version and release note since the last report, not just
     the newest heading);
   - which sources had **no new items** (normal, and shown as such) and
     which **failed** (shown as a problem);
   - the projects it treated as in flight;
   - **notable items it dropped, with a reason in a few words** (at most
     five: "no project uses an Anthropic SDK", "ignored: PHP", "want less
     of: benchmarks"). An item shown anywhere in the report, including the
     Also-in-the-news line, is never also listed as dropped.

Every item appears in at most one place in a report. The whole report,
footer and Also-in-the-news line included, stays within about three minutes
of reading: 600 words for a normal day. The footer on its own is never more
than 100 words.

On a slow news day the report says so and stops: "Nothing that touches your
work today." plus the Also-in-the-news line and the Also-noted list if there
are any. That body stays under 150 words (the footer is not counted on a
quiet day, but still holds to its own 100). Huey never pads to reach a
count.

### "Also in the news": staying broadly current

Huey is about Hammer's work, but he also wants to know the one big thing
everyone using Claude will be talking about, even when it touches none of his
projects. The simulation's week is the example: the 2026-10-21 API version
and the 2.0 SDKs (breaking changes, MIT to Apache 2.0) affected no Sendai
project, and he still wants to hear about it.

So each report may carry **one line**, labelled **"Also in the news (not
tied to your work)"**: a headline, one sentence on what happened, and the
primary link, in about 40 words. It has no "For <project>:" line and no
hook of any kind; Huey does not try to connect it to his work.

- **Where it comes from:** first-party sources only (Anthropic news, Claude
  docs release notes, the Claude Code changelog). Never an aggregator or
  blog, though "also covered by" links are allowed.
- **Which item:** the most significant first-party announcement of the past
  seven days that Hammer has not already been shown. Normally Huey judges
  significance for Claude users broadly: new models, API versions, breaking
  changes, licensing, pricing and limits, major new capabilities rank above
  fixes and minor features. If every eligible candidate is a minor fix,
  Huey may leave the line out, and the footer says so in a few words
  ("Also in the news: only minor fixes this week"). It never promotes a
  minor fix to fill the line. Under a critical budget, when no model runs,
  it is decided by rule instead: the newest unshown item from Anthropic
  news, else from the docs release notes, else from the changelog.
- **No repeats:** an item that is a pick in today's report, or that appeared
  anywhere in a report in the last 14 days (including a no-model headline
  report), is not eligible; Huey takes the next one. If the top item would otherwise sit in today's Also noted, it
  moves up to this line instead.
- **Nothing new, no line:** if no first-party item from the past week is
  eligible, the line is left out. It is never filled with something minor
  for the sake of it.
- **Ignore entirely still wins:** an announcement that falls under an
  "ignore entirely" entry is not eligible. Matching no stated interest is
  fine; that is the point of the line.

### The rule that keeps picks honest

A pick exists because a project is affected, and Huey says how it knows.

- **Affected, and confirmed where Huey can check.** Huey checks a pick's
  claim against the project wherever the project itself can answer it:
  does it use that SDK, that feature, that variable, that hook. If the check
  shows the project is **not** affected, the item is not a pick. It may
  appear in Also noted if it matches an interest; otherwise it is dropped
  and named in the footer. (Simulation example: the 2026-10-21 API version
  and 2.0 SDKs were the week's biggest Anthropic news, and dropped, because
  no Sendai project uses an Anthropic SDK.)
- **Specific, or demoted.** A pick whose "For" line cannot name a concrete
  effect on a concrete part of the project becomes an Also-noted item. Huey
  never writes "could be useful" to keep an item in the picks.
- **At most one "To check" pick per report.** Where Huey genuinely cannot
  tell (the answer is not visible in the project or the digest), one pick
  may stand with a single, specific "To check". Any further unconfirmed
  picks move to Also noted. With the "how it runs" lines in place this
  should be rare; a report full of "check whether..." means the digest is
  missing something, and the footer makes that visible.

### Huey reads primary sources properly

The simulation's two best items were single "Added" lines in the Claude
Code changelog that a skim missed. So for first-party sources (the Claude
Code changelog, Claude docs release notes, MCP and agent SDK releases,
Anthropic news) Huey reads **everything published since the last report**,
every version and every entry, before deciding what matters. Aggregators
and blogs are a supplement, not the main diet.

Some sources show no dates (the Anthropic news page is one). For those, an
item counts as new when Huey **first sees it** after the last report. The
first time Huey ever reads such a source, what is already there is the
baseline, not news.

Quiet sources are normal: MCP spec releases can go months without a new
version, and agent SDK releases often only bump the bundled CLI. The footer
says "no new items" for them, so quiet never looks like broken.

### Hammer can see and correct what Huey thinks he is working on

Next to each report is the **context Huey used for it**: a short, readable
digest, the same thing the curating model received. It has, per project:

- what is in flight (open PRs, tracker items, ideas, Mother jobs, recent
  merges);
- a short, stable **"how it runs"** line: language, how agents are invoked
  (for example "Mother's workers run `claude -p` non-interactively"), which
  Claude Code features it relies on (hooks, mods, skills, MCP servers),
  which SDKs it uses or does not;
- the project's **current posture** where one exists, such as Bishop's
  budget posture or Mother's queue state.

Huey writes the "how it runs" lines itself and shows them with the digest.
They are summaries, never file contents. When one is wrong, Hammer corrects
it in the interests file (or asks the session to), and **his correction
wins** over what Huey would have written, from the next report on.

He steers Huey through the **interests file**, which he can edit in any
editor. It has four sections, which the simulation showed were enough to
drive what gets dropped and how things rank:

- **What I care about, and why**
- **Want more of**
- **Want less of**
- **Ignore entirely** (topics or projects)

plus any "how it runs" corrections. He can also tell the Huey session "less
benchmark news", "stop mentioning the photos project" or "Mother does set
the watchdog variable"; the session makes that change in the interests file,
where he can see it, and it applies from the next report. No hidden profile,
no silent drift.

### Drill in from the report

The focus's Claude session already knows today's report and its context.
Hammer can say "tell me more about 2", "what would this mean for the
tracker pane?", "go and check that To-check for me", or "make this an idea"
and get an answer grounded in that pick and its sources, without pasting
anything.

### Iterating on the report itself

The report's shape will be tuned against real output over the first weeks.
Hammer (or whoever is helping him tune it) can ask the session to **regenerate today's report
now**, after changing interests or the report's instructions, and compare it
with the earlier version. Past reports stay available by date, so a week of
output can be read side by side.

### When things go wrong, he can tell

- If the model run fails, Huey tries once more 10 minutes later, without
  Hammer doing anything. If the retry fails too, today counts as missing.
- If today's report is missing (machine asleep, fetch failed, model failed
  twice), the focus shows the most recent report **clearly labelled with
  its date and the reason today's is missing**. An old report is never
  presented as today's. The next report covers the gap.
- If budget is tight (Bishop's posture), the report is **shorter and says
  why** ("Short report: budget is tight today"); the Also-in-the-news line
  stays. If budget is critical, no model runs at all: the report is an
  uncurated list of headlines from first-party sources, labelled as such,
  at most 20 lines followed by "and N more", plus the Also-in-the-news line
  chosen by rule unless that list already contains it. Budget never causes
  a missing report: critical always produces this headline report.
- A no-model headline report does not count as "the last report" for the
  window: the next curated report still covers everything since the last
  curated one, and an item that appeared only in a headline list can still
  become a pick later. It does count against repeats on the
  Also-in-the-news line. Fetching is plain code and costs
  nothing, so there is always something to read.
- A source that fails is named in the footer; one bad feed never sinks the
  report.

### Each machine keeps to itself

The report on Sendai is built only from Sendai's context; Kobe's only from
Kobe's. Neither machine's report can mention the other's projects, repos or
items. In the unattended runs that build reports, the only things that
leave the machine are the digest, the headlines of Huey's own recent
reports, and fetched public news, sent to the model provider; all of
the first two are what Hammer sees next to the report.

The focus's drill-in session is different: it is a normal Claude session,
like any other focus, that Hammer drives himself. The digest-only rule
binds the unattended runs, not that session.

One gap to close before any Kobe instance: `~/.claude` ideas, todos and
notes are synced between machines, so as they stand a work idea written on
Kobe could reach Sendai's digest, and the reverse. Those sources need a
per-machine rule (which items belong to which machine) before Kobe is set
up. Note that the Kobe-to-Sendai direction does not need a Kobe instance:
a work idea written on Kobe can sync to Sendai today. In v1 the setup step
labels those sources as synced from other machines, the digest shows
exactly what was used, and "ignore entirely" removes anything that slips
through.

Worked example from the simulation: a PHP security release was widely
covered the same week. On Sendai it touches nothing (and PHP is in "ignore
entirely"), so it was correctly left out and named in the footer as
dropped. On Kobe, where Carefeed runs PHP, the same item would be a strong
pick. Each machine reaches its own answer from its own context, and neither
learns anything about the other's.

### Turning Huey off, the same way as any built-in agent

Hammer switches Huey off on a machine the same way he switches off Fred,
Perri or Teri: an `[agents.huey]` table with `enabled = false` in that
machine's Nostromo `config.toml`, then a restart of `nostromd`. The app
picks up the change on its next connection. A disabled Huey is gone, not
paused: no scheduled run, no fetching, no model calls, no Huey tools in
agent sessions, no Huey sidebar entry or focus. A malformed `[agents.huey]`
table follows the rule already in place for the other agents: it is ignored
with a warning, and Huey stays on.
Turning Huey back on and restarting brings back its history of past
reports, its setup and the interests file untouched.

## Acceptance criteria

Redd can exercise these against a Huey instance fed with fixture news items,
a fixture context (tracker boards, PRs, ideas, project repos, interests
file) and a controllable clock and budget posture.

**Setup**

1. On a machine where Huey has not been set up, opening the Huey focus
   shows that Huey has read nothing, the list of context sources it would
   read, and a **Set up Huey on this machine** button; opening the focus
   reads no context files and writes nothing (Redd: a read-counting fixture
   root sees zero reads). Only after the button is pressed does Huey read
   context and show the sources read, a draft interests file with the four
   sections, and a "how it runs" line per project found. Until the user
   confirms, no news is fetched, no model is called and no report is
   produced (Redd: advance the clock past the run time, with and without
   the button pressed, and assert no network or model activity and no
   report).
2. If the interests file does not exist when setup runs, Huey writes a draft
   from the machine's context and shows it for editing; no report is
   produced until the user has confirmed setup with an interests file in
   place. The interests file and all other Huey files live in Nostromo's
   own folder; Huey never writes anything under `~/.claude`.

**Arrival and window**

3. Once set up, with the default schedule, a report exists by 06:30 local;
   opening the focus shows it in under one second with no generation step
   visible to the user.
4. A report covers items published (or, for undated sources, first seen)
   since the previous successful curated report. Fixture: no report for two
   days, then a run; items from all three days are eligible. A no-model
   (critical budget) headline report does not move the window: fixture of a
   critical day followed by a normal day; the normal day's report covers
   both days.
5. For an undated source, the first run treats everything on it as
   baseline: none of those items appears as a pick or Also-noted item. An
   item added to the source afterwards is eligible on the next run.

**Shape**

6. A report contains at most 5 picks, at most one Also-in-the-news line and
   at most 5 Also-noted items, in that order, followed by a footer. A fixture day with 200 relevant-looking
   items still yields no more than 5 picks.
7. Every pick has a headline, a "what happened" line, a "For <project>:"
   line, a "Checked:" or "To check:" line, and at least one link; the first
   link points to the original source (the release, the changelog entry,
   the author's post), not an aggregator page, whenever the fixture
   includes the original.
8. A typical report (fixture: a normal day with 3 picks, an
   Also-in-the-news line and 5 Also-noted items) is at most 600 words
   counting the whole rendered report, footer included, and is readable in
   about three minutes. The Also-in-the-news line alone is at most 40
   words, and the footer alone is at most 100 words on every report.
9. A fixture day whose items match nothing in context or interests produces a
   report that says nothing touches current work, with no picks, whose body
   (opener, the "nothing today" line, any Also-in-the-news line and Also
   noted) is under 150 words. The footer is not counted toward the 150, but
   still holds to its 100-word cap.
10. The same story fetched from several sources (fixture: one release on
    GitHub, a blog and an aggregator) appears as one pick or one Also-noted
    item, with the others listed as "also covered by".
11. A story featured on one day does not appear again within 14 days unless
    a fixture adds materially new information (for example a follow-up
    release), in which case the item says what is new. Appearing only in a
    no-model headline report does not count as featured for this rule.
12. The footer lists: the number of items and the sources checked; the
    first-party sources read in full for the window; sources with no new
    items, labelled as quiet; sources that failed, labelled as failed; the
    projects treated as in flight; and up to five notable dropped items,
    each with a short reason. No item shown anywhere in the report
    (including the Also-in-the-news line) is listed as dropped, and no item
    appears in more than one section.

**Honest picks**

13. Every project named in a "For <project>:" line appears in that day's
    digest, and the line names a concrete part of that project (a PR,
    tracker item, idea, job, or a fact from its "how it runs" line) and a
    concrete effect on it. A fixture where no item relates to any context
    produces zero picks, never an invented project.
14. When the project can answer whether it is affected, Huey checks.
    Fixture: a breaking release of an SDK that no fixture project depends
    on. It is not a pick. It may be the Also-in-the-news line (if it is the
    week's top eligible first-party item) or an Also-noted item (if it
    matches a stated interest); otherwise it is listed in the footer as
    dropped with the reason (for example "no project uses this SDK").
15. Fixture: a release of an SDK that one fixture project does depend on.
    It is a pick for that project, and its "Checked:" line says what was
    confirmed.
16. A report has at most one pick with a "To check:" line. Fixture: three
    plausible items whose effect cannot be confirmed from the project or
    digest; at most one is a pick, the others are Also-noted items.
17. An item whose only possible "For" line is non-specific (fixture: a
    general essay matching an interest but touching no project item) is
    never a pick.
18. Every Also-noted item is tagged with a stated interest from the
    interests file. An item that matches only a "want less of" interest, or
    an "ignore entirely" entry, never appears in Also noted.

**Sources**

19. For each first-party source, every entry published since the last
    report is eligible, not only the newest. Fixture: a changelog with eight
    new versions where the only relevant line is an "Added" entry in the
    oldest of the eight; that entry can become a pick.
20. A source with no new entries in the window is listed in the footer as
    having no new items, and nowhere as failed.
21. One failing source (fixture: a feed that times out or returns garbage)
    leaves every other source's items in the report and is named in the
    footer as failed.

**Context and steering**

22. The digest used for a report is viewable from the Huey focus alongside
    that report, and it is exactly what was sent to the model for that
    report (Redd can compare the shown digest with the captured model
    input).
23. The digest has, per project in flight, its open items, a "how it runs"
    line, and its current posture where one exists (fixture: Bishop's budget
    posture appears in the digest).
24. No raw file contents (whole tracker files, notes, diffs, source code,
    manifests) appear in the model input of an unattended report run; only
    the digest does. The "how it runs" lines are summaries within the
    digest. (The focus's drill-in session is a normal Claude session the
    user drives, and this criterion does not apply to it.)
25. A "how it runs" correction in the interests file replaces Huey's own
    line for that project in the next digest.
26. A project or topic listed in "ignore entirely" never appears in the
    digest's in-flight list, a pick or an Also-noted item, even when fixture
    news matches it strongly.
27. An edit to the interests file (by hand, or by the Huey session at the
    user's request) is visible in the file and changes the next report;
    nothing else about the user's preferences is stored out of sight.
28. Asking the Huey session to regenerate today's report produces a new
    version within 5 minutes; both versions remain readable, labelled with
    their generation time.
29. Reports from previous days remain available by date for at least 30
    days.
30. In the Huey session, "tell me more about N" for a pick in today's report
    answers about that pick's story and project without the user supplying
    the link or the context.

**Failure, budget and privacy**

31. A failed model run is retried once, automatically, 10 minutes later
    (fixture: the model fails once, then succeeds; today's report exists and
    is not labelled missing). If the retry also fails, or no report was
    produced today for another reason, the focus shows the latest report
    with its date and a visible reason (machine was asleep, fetch failed,
    model failed). Budget is never a reason: a critical posture produces the
    headline report of criterion 33. A report from a previous day is never
    shown without its date being visible.
32. Under a tight budget posture, the report has at most 3 picks, no
    Also-noted section, and a line saying it was shortened for budget. The
    Also-in-the-news line is still present when an eligible item exists.
33. Under a critical budget posture, no model is called; the report is an
    uncurated, labelled list of headlines and links from first-party
    sources only, at most 20 lines followed by "and N more" when there are
    more (fixture: 35 first-party items gives 20 lines and "and 15 more"),
    plus the Also-in-the-news line chosen by rule (criterion 44), which is
    left out only when its item already appears in that list.
34. A report on Sendai never contains a project, repo, PR, ticket or item
    that exists only in Kobe's context, and the reverse; each instance has
    no way to read the other machine's context (Redd: two instances with
    disjoint fixture contexts, assert no cross-mention in reports, digests
    or model input). Fixture worked example: a PHP security item is dropped
    on an instance whose context has no PHP project, and is a pick on one
    whose context does.

**On/off, like the other built-in agents**

35. With no `[agents.huey]` table in `config.toml`, Huey is on: the daemon's
    welcome lists `huey` among the enabled agents and the Huey focus
    appears in the macOS app (showing the not-set-up state and the **Set up
    Huey on this machine** button until set up, per criterion 1). In v1 the
    Huey focus and its panes are not offered to network clients (iPhone,
    iPad, other LAN peers).
36. With `[agents.huey]` `enabled = false` and `nostromd` restarted, `huey`
    is absent from the welcome's enabled agents, the macOS app shows no Huey
    sidebar entry or focus, Huey's MCP tools are refused, its pane sources
    are neither fetched nor replayed, and no scheduled run, fetch or model
    call happens (Redd: advance the fixture clock past the run time and
    assert no network or model activity and no new report).
37. A malformed `[agents.huey]` (non-table entry, or `enabled` not
    `true`/`false`) does not stop the daemon, logs a warning naming keys
    only, and leaves Huey on.
38. Turning Huey back on and restarting `nostromd` shows the same past
    reports, the same setup state and the same interests file as before it
    was disabled.

**Quality bar**

39. **Ambitious bet:** across a two-week trial, the picks are specific
    enough that Hammer judges at least half of them "useful or interesting"
    and no more than one in ten "hype or wrong project". This is the
    brief's named risk (the "why this matters" line drifting into hype)
    turned into a bar; criteria 13 to 18 are the defence. It is judged by
    Hammer, using a one-word verdict per pick he can leave in the session
    or the report; the verdicts are kept with the report so the two weeks
    can be reviewed.

**Also in the news**

40. A report has at most one Also-in-the-news line, labelled as not tied to
    the user's work. It has no "For <project>:" line, no "Checked:" or "To
    check:" line, and does not name any project from the digest.
41. Its item and primary link come from a first-party source (Anthropic
    news, Claude docs release notes, Claude Code changelog), never an
    aggregator or blog. Fixture: the week's most-discussed story exists
    only on an aggregator and a blog; it is not the Also-in-the-news line.
42. It appears even when the item touches no project and matches no stated
    interest (fixture: a breaking SDK release no project uses, with no
    matching interest; it is the line). An item under "ignore entirely" is
    never the line.
43. An item that is a pick in the same report, or that appeared in any
    section of a report in the previous 14 days (no-model headline reports
    included), is not the line; the next eligible first-party item is
    used. An item never appears both as the
    line and in Also noted.
44. With a model available, the line is the most significant eligible
    first-party item of the past seven days (fixture: a new API version and
    a minor bug fix in the same week; the API version is chosen). Under a
    critical budget, with no model call, it is the newest eligible item from
    Anthropic news, else the docs release notes, else the Claude Code
    changelog.
45. When no first-party item from the past seven days is eligible (fixture:
    a quiet week, or every candidate already shown), the line is omitted
    and nothing takes its place. With a model available, the line may also
    be omitted when every eligible candidate is a minor fix (fixture: a
    week of only bug-fix changelog entries); the footer then says so with a
    short reason, and no minor fix is shown in the line.

## In scope

- Huey as a built-in Nostromo agent in the Nostromo repo: on by default,
  switched off per machine with `[agents.huey] enabled = false`, with the
  same restart and malformed-config behaviour as Fred, Perri and Teri.
- The one-time, lazy setup step per machine (nothing read until "Set up Huey on this machine" is clicked), including the drafted interests file
  and "how it runs" lines.
- The Huey focus on Sendai: today's report, past reports by date, the
  digest per report, and the focus's Claude session for drill-ins, checks,
  regeneration and interest changes.
- A daily scheduled run on Sendai, with the time configurable, covering the
  window since the last report.
- Starting news sources, chosen for signal on the three starting topics
  (new or upcoming Claude functionality, notable real-world AI use, agentic
  software development):
  - first-party, read in full: Claude Code changelog, Claude docs release
    notes, Anthropic news, MCP spec releases, agent SDK releases;
  - curated people: Simon Willison's weblog, Latent Space.
  Adding or removing a source is a configuration change, not a code change,
  as seen by the user.
- Hacker News front page as a **ready-to-add source, off by default**. In
  the simulation 1 of 25 front-page items was usable, and only for Also
  noted.
- Sendai context sources: Nostromo tracker boards, open PRs and recent git
  activity in the configured code root, Mother jobs, Bishop's budget
  posture, `~/.claude` ideas, todos and notes, the interests file, and
  whatever Huey needs to check from each project to write its "how it runs"
  line and confirm picks (summarised in the digest, never sent raw).
- Budget-aware shortening and the no-model headline report, visible in the report; one automatic retry of a failed model run.
- Per-pick verdicts (criterion 39) recorded for the trial, nothing more.

## Out of scope

- **Reading the report on iPhone or iPad.** Deferred until Nostromo has its
  WebSocket backplane and the iOS app can reach Sendai's daemon. The
  commute is the natural next reading moment, so this is the first
  follow-up once that dependency lands. Nothing in v1 should make it
  harder.
- **Kobe (work MacBook) instance.** v1 runs on Sendai only. Kobe follows
  once the report shape has settled, with its own privacy review of which
  work context may go into a digest (Carefeed customer and resident data
  must never reach it). Until then Huey stays in its not-set-up state
  there, even though it is on by default. Before any Kobe instance, the
  synced `~/.claude` ideas, todos and notes need a per-machine rule so work
  items can never reach Sendai's digest and personal items can never reach
  Kobe's.
- **Showing Huey to network clients** (iPhone, iPad, other LAN peers). In
  v1 the Huey focus is hidden from them; it appears only in the macOS app on
  the machine it runs on.
- **More than one "regardless of relevance" item.** Exactly one
  Also-in-the-news line, first-party only. A general "top AI stories"
  section is out of scope.
- **The brief's topic-evolution machinery:** per-topic files with weights
  and cadences, logged thumbs/dismissals feeding Claude-proposed topic
  diffs, topics created from drill-ins. v1 has one interests file and
  conversational edits to it. Revisit after the two-week trial.
- **A cluster browser** (scrollable stories grouped by topic with scores).
  The report replaces it; the session covers "show me every source on this".
- **Story timelines** ("how has this evolved over the last month") and a
  queryable news archive (Callimachus or otherwise).
- **Delivery outside Nostromo:** Slack DM, email digest, push notification
  that the report is ready, Claude Doc copies.
- **Email and calendar as context** (Fred). Personal mail is not work in
  flight, and it is the easiest way to leak something private into a model
  prompt.
- **Papers (arXiv), Reddit and web search** as sources. Noisy or costly;
  add after the trial if there are gaps.
- **Making the report a tracker board.** The tracker holds tasks; the report
  is a document. Turning a pick into a task or idea happens by asking the
  session.
- **A separate repo or license.** Huey lives in the Nostromo repo and
  inherits Nostromo's license; whoever runs Nostromo gets Huey. Packaging
  Huey on its own for people who don't use Nostromo is out of scope.
- **Multiple reports a day** or breaking-news alerts.

## Product risks

- **Hype drift.** The "For <project>:" line becomes generic enthusiasm.
  This is the risk that kills the product. The simulation showed the
  defence works when it is explicit: where a hook was weak, the item was
  demoted to Also noted rather than given an invented "For" line. Criteria
  13 to 18 make that the rule; criterion 39 measures it.
- **Confidently wrong checks.** A "Checked:" line that is wrong does more
  damage than a "To check:" line, because Hammer will act on it. The check
  must say what it looked at, so a wrong one is visible and correctable.
- **Wrong picture of the week.** Stale ideas, old tracker boards or a stale
  "how it runs" line make Huey tie news to projects Hammer has moved on
  from. Mitigated by the visible digest, the ignore list and corrections
  that win; if it is common, the digest needs a recency rule.
- **Becoming one more thing to read.** If the report is long, or quiet days
  are padded, it joins the pile of unread tabs. The hard caps, the
  interest-tied Also noted and the "nothing today" path are deliberate.
- **Privacy creep.** Someone (including Hammer) adds a "useful" context
  source later that drags in private or work material, or the "how it
  runs" lines start quoting files. The per-machine line and the digest-only
  rule are written here so any new source has to be argued for against
  them.
- **Budget competition.** A daily model run competes with real work for the
  weekly limit, and reading primary sources in full costs more than
  skimming. The budget posture rules keep Huey the first thing to give way,
  never the thing that tips a week over.

## Open questions / assumptions

### Settled by Hammer (2026-10-25)

- **iPhone reading is not in v1.** It waits for the WebSocket backplane and
  an iOS app that can reach Sendai (see Out of scope).
- **Huey is a built-in Nostromo agent** in the Nostromo repo, alongside
  Fred, Perri and Teri, under Nostromo's license, with the same
  `[agents.huey]` enable switch and restart behaviour.
- **One-time, lazy setup before Huey does anything on a machine.** Huey is
  on by default and its focus appears, but until Hammer clicks **Set up
  Huey on this machine** it reads nothing; until he confirms the setup it
  fetches nothing and calls no model. This keeps Kobe safe without anyone
  having to remember to turn Huey off.
- **Huey's files live in Nostromo's own folder, not `~/.claude`,** because
  `~/.claude` is synced publicly.
- **Huey also keeps him broadly current, by one line.** Each report carries
  an "Also in the news" line: the week's top first-party announcement,
  shown even when it touches no project and matches no interest (see "Also
  in the news" in The experience, criteria 40 to 45). With a model, Huey
  may leave the line out, with a stated reason in the footer, when every
  candidate is a minor fix; "most significant" is chosen among
  announcements that are more than minor fixes, and a minor fix is never
  used to fill the line.
- **Budget mapping (Bishop's posture to Huey's modes):**
  - *critical* (no model, headline report): Bishop says critical, or the
    weekly limit is at 98% or more, or the model Huey would use is
    exhausted;
  - *tight* (shorter report): "Pump the brakes", "conservative" or
    "elevated"; or the weekly limit is at 90% or more; or Bishop's data is
    stale or more than a day old; **or billing is metered (paying for
    overage), which forces tight on its own**;
  - *normal*: everything else, including when Bishop's posture is not
    available at all (the footer then says "budget posture unavailable").
- **No-model reports and the window:** a critical-budget headline report
  does not move the "since last report" window and does not stop an item
  from becoming a pick later; it does count against repeats on the
  Also-in-the-news line.
- **Huey is hidden from network clients** (iPhone, iPad, LAN peers) in v1.
- **The drill-in session is a normal Claude session.** The digest-only rule
  binds the unattended report runs only.
- **Default model:** Sonnet in both normal and tight modes, configurable.
- **Failed runs:** a failed model run is retried once, 10 minutes later;
  if that fails, today is labelled missing. "Skipped for budget" is not a
  reason a report can be missing, because critical budget always produces
  the headline report (at most 20 lines plus "and N more").

### Open questions for Hammer

None.

### Assumptions (Ada's calls; push back on any)

- **Shape:** opener, at most 5 picks with "For <project>:" and
  "Checked:/To check:" lines, one optional Also-in-the-news line (about 40
  words), at most 5 interest-tagged Also-noted items, footer with a dropped
  list; about three minutes to read; "nothing today"
  instead of padding. Expected to change after a week of real output.
- **Also in the news:** a single line, not a block; the "week" is the past
  seven days regardless of the report window; "ignore entirely" still
  excludes an item from it; if the top item would be in Also noted, it
  moves to this line instead.
- **Honest-pick rule:** checked-and-not-affected drops out of the picks (to
  Also noted if it matches an interest, else the footer's dropped list);
  non-specific becomes Also noted; at most one "To check" pick per report.
- **"How it runs" lines:** written by Huey, shown in the digest and in
  setup, corrected by Hammer in the interests file, and his correction
  wins.
- **Window:** since the last successful curated report. Undated sources
  count an item as new when first seen; their first read is baseline.
- **Sources:** HN front page off by default but ready to add. Quiet sources
  are labelled quiet, not failed.
- **Schedule:** ready by 06:30 local, every day including weekends
  (personal projects happen on weekends). Time is configurable.
- **Delivery surface:** the Huey focus in Nostromo (report pane plus
  session). No Claude Doc, Slack or email in v1.
- **v1 context sources:** tracker boards, open PRs and recent git activity
  in the code root, Mother jobs, Bishop's posture, `~/.claude`
  ideas/todos/notes, the interests file, and what is needed for "how it
  runs" lines and checks. Not email, calendar or chat history.
- **Privacy:** each machine reads only its own context; in unattended runs
  only the visible digest and public news go to the model provider; Kobe
  waits for its own privacy review and a per-machine rule for synced
  ideas, todos and notes.
- **Feedback in v1:** edit the interests file or ask the session to;
  regenerate on demand; one-word verdicts per pick during the trial. No
  automatic learning.
- **Success:** the two-week bar in criterion 39, plus Hammer still opening
  the report most mornings at the end of it. If neither holds, rethink the
  shape before adding sources or machines.
- **Budget:** normal posture gives a full report, tight gives at most 3
  picks, critical gives an uncurated first-party headline list (at most 20
  lines) with no model call. The mapping from Bishop's posture is settled
  above.
- **The sample interests file** (`~/.claude/huey/interests.md`) is a guide
  to the shape only; the real one comes from setup and Hammer's edits, and
  lives in Nostromo's folder. Setup may offer to import the sample.
- **The brief's "Ada"** is this requirements role, not a separate Huey
  agent. Huey itself needs no persona beyond the focus name.
