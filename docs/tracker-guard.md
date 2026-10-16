# Tracker sensitive-text guard

`src/sensitive_text.rs` is a pure detector for PHI-shaped text and secrets. The tracker calls it on every agent write (an agent write containing a match is refused with `possible_sensitive_data`, naming the field and class, never the text) and on pane and file text (badged and withheld from the agent). It is **best effort, not a compliance control**: it is measured, not proven.

```rust
use nostromo::sensitive_text::{scan, first_class, GuardConfig};

let cfg = GuardConfig::default();
let findings = scan(text, &cfg);   // Vec<Finding { class, range }>, ordered by start
let class = first_class(text, &cfg); // Option<Class>
```

A `Finding` is a class and a byte range in the ORIGINAL text. It deliberately carries no copy of the matched text, so `Debug`, `Display`, logs and error responses cannot echo it. `scan` never panics on any input and no code path slices text by assumed byte offsets, so a panic message cannot carry matched text either (a fuzz test in `tests/sensitive_text_hardening.rs` holds this).

Text longer than `MAX_SCAN_BYTES` (1 MiB) is not scanned: `scan` returns one `Class::Oversize` finding (`oversize`) covering the whole input, so a caller that refuses or withholds on any finding fails closed. T0b caps agent fields far below this anyway; the cap only bounds the time a rogue caller can make the guard spend.

## Normalisation

The patterns are ASCII-only and run on a normalised view of the text, with offsets mapped back to the original:

- Invisible characters (`data::work::is_invisible`: zero-width, bidi overrides, Unicode tag characters, soft hyphen, ...) are removed, so `219-<ZWSP>09-9999` is an SSN. Whitespace such as `\n` and `\t` is never removed. A hidden character can also stand in for a space (`SSN<ZWSP>219-09-9999`), so text that contains one is scanned twice, once with them removed and once with each read as a space.
- Compatibility forms are folded to ASCII: fullwidth letters and punctuation (`ＡＫＩＡ…`, `＠`, `＝`), any Unicode decimal digit (Arabic-Indic, Devanagari, Thai, mathematical digits, ...), and en dash, minus and similar dashes read as `-`. This uses NFKC from the `unicode-normalization` crate already in the tree, plus the digit and dash folding NFKC leaves out.
- Only ASCII letters and digits count as "glued" to a value, so text in scripts written without spaces (`社会保障号219-09-9999`) is still scanned.

## What it detects

| Class (`as_str`) | Matches | Look-alikes it ignores |
|---|---|---|
| `ssn` | `ddd-dd-dddd`, area not `000`/`666`/`9xx`, group not `00`, serial not `0000` | inside a longer digit/alnum run, one segment of a dotted/hyphenated id (`1219-09-9999`, `x-219-09-9999`, `1.2.3-45-6789`) |
| `card` | 13-19 digits, single spaces or dashes between whole groups (4-4-4-4, 4-6-5), Luhn-valid, not one repeated digit, first digit 3-6 or 2221-2720 | UUIDs, SHAs, `PORTAL-1F2`-style ids, timestamps, epoch values, ids glued to letters or path segments |
| `dob` | a date (`MM/DD/YYYY`, `MM.DD.YYYY`, `MM-DD-YYYY`, `YYYY-MM-DD`, `Mon D, YYYY`, `D Mon YYYY`) starting within 30 characters after `DOB`, `D.O.B`, `date of birth`, `birth date`, `born` | plain dates, dates far from a label, `Adobe`, `reborn` |
| `mrn` | `MRN` or `medical record [number\|num\|no\|#]` followed by an id of 4+ characters containing a digit | the label with no id (`Add MRN to the list`) |
| `phone` | NANP `(312) 555-0142`, `312-555-0142`, `312.555.0142`, `312 555 0142`, `1-312-555-0142`, and `+1` forms with or without separators | bare 10-digit runs without `+1`, `312-5550-142`, order ids |
| `personal_email` | any address whose domain (and its parents) is not in `GuardConfig::work_email_domains` (default `carefeed.com`, `users.noreply.github.com`; subdomains count) | `git@host:path` SSH remotes, `logo@2x.png`, `pkg@1.2.3` |
| `secret` | AWS access key ids (`AKIA`/`ASIA`), `aws_secret_access_key` assignments, GitHub `ghp_ gho_ ghs_ ghu_ ghr_ github_pat_`, Slack `xox[abeprs]-` and `xapp-`, `sk-ant-`, `sk-` (20+ chars), Stripe `sk_live_`/`sk_test_`/`rk_live_`/`rk_test_`/`pk_live_`, npm `npm_`, Google `AIza`, JWTs, `-----BEGIN … PRIVATE KEY`, `Bearer <20+ chars>`, `Authorization: Basic <base64>`, `scheme://user:pass@host`, `password/passwd/pwd/secret/token/api_key` `=` or `:` followed by 8+ characters | `sk-` or `Bearer` followed by a plain lowercase slug, URL passwords that are whole placeholders (`${NAME}`, `$NAME`, `<password>`, `%s`, `{{NAME}}`, `****`), the `@` of URL userinfo (`mongodb+srv://u:p@c.example.net` is a secret, not also an email), placeholders (`<…>`, `${…}`), redactions (`********`) and paths and URLs as `password=` values, `token=abc` |

## What it does not detect

- **Names.** Resident, patient, family and staff names are not detected. This is the largest gap, and why the tracker guidance tells agents to refer to things by id.
- **Free-text clinical detail**: diagnoses, medications, symptoms, care notes, addresses.
- **Unlabelled dates of birth** (a date with no `DOB`/`born` label nearby), partial dates, and ages.
- **Unlabelled MRNs and account numbers**, driver's licence and passport numbers, ITINs, Medicare/insurance ids. MRNs shorter than 4 characters.
- **Non-NANP phone numbers** and bare 10-digit phone numbers without `+1`. Phones with spaced separators (`312 - 555 - 0142`).
- **SSNs with spaces or dots** (`219 09 9999`, `219.09.9999`) or as 9 bare digits (`219099999`). These are indistinguishable from versions, order ids and phone fragments; the unlabelled forms are not worth the false alarms.
- **Cards** on networks outside first digit 3-6 / 2221-2720, with irregular grouping, dots as separators (`4111.1111.1111.1111`), double spaces, or a line break inside the number.
- **Homoglyphs**: look-alike letters from another script (Cyrillic `АКІА`), which NFKC does not fold to Latin. Digits in any script and fullwidth forms ARE detected.
- **Email addresses** with a Unicode domain (`jo@bücher.example`), a quoted local part (`"jo hale"@gmail.com`), or the local part `git` (`git@gmail.com` is skipped with `git@github.com:org/repo.git`).
- **`password=` values that start with `$`, `%`, `<`, `{`, `[`, `*`, `/`, `~` or `.`** (`password=$ecret99`): the assignment rule skips them as placeholders and paths. URL passwords are checked by exact placeholder shape instead.
- **Secrets without a recognisable shape**: a random password in prose, vendor keys with no fixed prefix, anything a pattern list here does not name.
- **Text over 1 MiB**: not scanned, reported as `oversize`.

## Known false alarms

- `Co-Authored-By: Claude <noreply@anthropic.com>` is a `personal_email` (its domain is not on the work list). Add the domain to `work_email_domains` if it matters.
- `Token: rotating the key` is a `secret`: the `password=`/`token:` rule is deliberately the plain "8+ characters after the separator" rule, so a word of 8+ letters counts.
- A letters-only label glued to a value by a joiner counts as a label, so `ORD-312-555-0142` is a `phone` and `build-123-45-6789` an `ssn`. Hex-looking words (`dead-`, `face_`), anything with a digit (`a1-`, `PORTAL-1F2-`) and dotted versions (`1.2.3-45-6789`) are still ids.
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

1. Add the positive to `positives.txt` or the look-alike to `benign.txt`, then the table test. Secret-shaped positives must be masked: put a `¦` (U+00A6, stripped by the test loader) inside the key, or GitHub push protection will reject the push.
2. Change the pattern in `src/sensitive_text.rs`.
3. `cargo test --test sensitive_text_corpus`. The benign budget is 1%; do not trade a miss for a false alarm silently.

A new `[[bin]]` in `Cargo.toml` must also be added to the stub list in `.rwx/sandbox.yml`.
