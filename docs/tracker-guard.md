# Tracker sensitive-text guard

`src/sensitive_text.rs` is a pure detector for PHI-shaped text and secrets. The tracker calls it on every agent write (an agent write containing a match is refused with `possible_sensitive_data`, naming the field and class, never the text) and on pane and file text (badged and withheld from the agent). It is **best effort, not a compliance control**: it is measured, not proven.

```rust
use nostromo::sensitive_text::{scan, first_class, GuardConfig};

let cfg = GuardConfig::default();
let findings = scan(text, &cfg);   // Vec<Finding { class, range }>, ordered by start
let class = first_class(text, &cfg); // Option<Class>
```

A `Finding` is a class and a byte range. It deliberately carries no copy of the matched text, so `Debug`, `Display`, logs and error responses cannot echo it.

## What it detects

| Class (`as_str`) | Matches | Look-alikes it ignores |
|---|---|---|
| `ssn` | `ddd-dd-dddd`, area not `000`/`666`/`9xx`, group not `00`, serial not `0000` | inside a longer digit/alnum run, one segment of a dotted/hyphenated id (`1219-09-9999`, `x-219-09-9999`, `1.2.3-45-6789`) |
| `card` | 13-19 digits, single spaces or dashes between whole groups (4-4-4-4, 4-6-5), Luhn-valid, not one repeated digit, first digit 3-6 or 2221-2720 | UUIDs, SHAs, `PORTAL-1F2`-style ids, timestamps, epoch values, ids glued to letters or path segments |
| `dob` | a date (`MM/DD/YYYY`, `YYYY-MM-DD`, `Mon D, YYYY`, `D Mon YYYY`) starting within 30 characters after `DOB`, `D.O.B`, `date of birth`, `birth date`, `born` | plain dates, dates far from a label, `Adobe`, `reborn` |
| `mrn` | `MRN` or `medical record [number\|num\|no\|#]` followed by an id of 4+ characters containing a digit | the label with no id (`Add MRN to the list`) |
| `phone` | NANP `(312) 555-0142`, `312-555-0142`, `312.555.0142`, `312 555 0142`, `1-312-555-0142`, and `+1` forms with or without separators | bare 10-digit runs without `+1`, `312-5550-142`, order ids |
| `personal_email` | any address whose domain (and its parents) is not in `GuardConfig::work_email_domains` (default `carefeed.com`, `users.noreply.github.com`; subdomains count) | `git@host:path` SSH remotes, `logo@2x.png`, `pkg@1.2.3` |
| `secret` | AWS access key ids (`AKIA`/`ASIA`), `aws_secret_access_key` assignments, GitHub `ghp_ gho_ ghs_ ghu_ ghr_ github_pat_`, Slack `xoxa/b/p/r-`, `sk-ant-`, `sk-` (20+ chars), `sk_live_`/`rk_live_`, JWTs, `-----BEGIN … PRIVATE KEY`, `Bearer <20+ chars>`, `scheme://user:pass@host`, `password/passwd/pwd/secret/token/api_key` `=` or `:` followed by 8+ characters | `sk-` or `Bearer` followed by a plain lowercase slug, placeholders (`<…>`, `${…}`), redactions (`********`), paths and URLs as values, `token=abc` |

## What it does not detect

- **Names.** Resident, patient, family and staff names are not detected. This is the largest gap, and why the tracker guidance tells agents to refer to things by id.
- **Free-text clinical detail**: diagnoses, medications, symptoms, care notes, addresses.
- **Unlabelled dates of birth** (a date with no `DOB`/`born` label nearby), partial dates, and ages.
- **Unlabelled MRNs and account numbers**, driver's licence and passport numbers, ITINs, Medicare/insurance ids.
- **Obfuscated values**: digits spelled out, split across lines, with unusual separators, or in non-ASCII digits.- **Non-NANP phone numbers** and bare 10-digit phone numbers without `+1`.
- **Cards on networks outside first digit 3-6 / 2221-2720**, and cards with irregular grouping.
- **Secrets without a recognisable shape**: a random password in prose, vendor keys with no fixed prefix.

## Known false alarms

- `Co-Authored-By: Claude <noreply@anthropic.com>` is a `personal_email` (its domain is not on the work list). Add the domain to `work_email_domains` if it matters.
- `Token: rotating the key` is a `secret`: the `password=`/`token:` rule is deliberately the plain "8+ characters after the separator" rule, so a word of 8+ letters counts.
- `pwd: /path` and `token: https://…` are not flagged (paths and URLs are skipped); other values are.

## Measured rates

Both are asserted in `tests/sensitive_text_corpus.rs`:

- **Miss rate:** every line of `tests/fixtures/sensitive_text/positives.txt` (`class<TAB>text`, all values synthetic) yields a finding of its tagged class.
- **False alarms:** at most 1% of `tests/fixtures/sensitive_text/benign.txt` (synthetic tracker lines modelled on real shapes: Sentry ids, Jira keys, SHAs, UUIDs, ARNs, versions, work emails, order ids) yields any finding. Failures print offending line numbers and classes.

The corpora are synthetic, so these are floors, not promises. Run the scan below to see real behaviour on real notes.

## Measuring on your own notes

```bash
python3 scripts/tracker/guard_false_alarm_scan.py          # per-class counts and rates
python3 scripts/tracker/guard_false_alarm_scan.py --list   # also `path:line  class`, no text
```

It reads `~/Code/*/.claude/wip/**/index.md` and `~/.claude/wip/**/index.md`, runs `cargo run --quiet --bin sensitive-text-scan` on their lines, and prints the per-class count and rate against all lines. It writes nothing, commits nothing and never prints note text: the binary prints only `line_no<TAB>class`, and the script maps line numbers back to `path:line`. Open the listed lines yourself; a flag is either a false alarm to tune or real sensitive text to scrub. Run it locally (not in a job), because the notes are yours.

The binary can be used directly: `sensitive-text-scan < file` prints `line_no<TAB>class` per finding, 1-based, and exits 0 whether or not anything was found.

## Changing a pattern

1. Add the positive to `positives.txt` or the look-alike to `benign.txt`, then the table test.
2. Change the pattern in `src/sensitive_text.rs`.
3. `cargo test --test sensitive_text_corpus`. The benign budget is 1%; do not trade a miss for a false alarm silently.

A new `[[bin]]` in `Cargo.toml` must also be added to the stub list in `.rwx/sandbox.yml`.
