"""Source-scanning policy for the Mother Details sheet (MC2-9).

The sheet shows `mother status <id>` text: gate output and finding text that may hold PHI. The
promise is that this text is shown on this Mac only: it is never logged, sent to the daemon or
the broker, or stored; the process that produces it is spawned only through ProcessRunner; and
the only things the sheet's code asks the host for are the `mother` binary and whether the app
is on Mother's own broker.

These are tests of what the source LOOKS like (a textual heuristic, not a control-flow proof),
in the same spirit as tests/ios_policy. Each check is a plain function over source text, with a
"bites" test on a synthetic source so a check that cannot fail would be noticed.

Run with:  python3 -m unittest discover -s tests/mother_policy -v
"""
import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VIEW = os.path.join(REPO_ROOT, "macOS", "Nostromo", "UI", "Views", "MotherJobDetail.swift")
START_MARKER = "// MARK: - Details sheet"
END_MARKER = "// MARK: - MotherCountsChips"

# (description, pattern) over code with comments and string-literal text removed.
FORBIDDEN = [
    ("a log call (`log.`)", r"\blog\s*\."),
    ("Logger(", r"\bLogger\s*\("),
    ("os_log", r"\bos_log\b"),
    ("NSLog", r"\bNSLog\b"),
    ("print(", r"(?<![\w.])print\s*\("),
    ("debugPrint", r"\bdebugPrint\b"),
    ("dump(", r"(?<![\w.])dump\s*\("),
    ("AppStore", r"\bAppStore\b"),
    ("NostromodClient", r"\bNostromodClient\b"),
    ("client.send", r"\bclient\s*\.\s*send\b"),
    ("UserDefaults", r"\bUserDefaults\b"),
    ("write(to", r"\bwrite\s*\(\s*to\b"),
    ("FileManager", r"\bFileManager\b"),
]
ALLOWED_HOST_MEMBERS = {"motherBinary", "usesDefaultBroker"}
# Spawning a process any way other than ProcessRunner.
SPAWNERS = [("Process()", r"(?<![\w.])Process\s*\("), ("NSTask", r"\bNSTask\b"), ("posix_spawn", r"\bposix_spawn\b"),
            ("system(", r"(?<![\w.])system\s*\(")]
LOGGED_IDENTIFIERS = r"\b(content|text|output|shownText)\b"


# --------------------------------------------------------------------------
# Source handling
# --------------------------------------------------------------------------

def code_view(src):
    """`src` with comments removed and string-literal text blanked, line for line.

    The code inside a string's `\\( ... )` interpolation is kept (it is code, and it is where a
    logged value would hide). Newlines are preserved so line numbers still match the original.
    """
    out, i, n = [], 0, len(src)

    def skip_string(i, quote):
        """Consume a string literal body starting after its opening quote; returns the index after it."""
        out.append('"')
        while i < n:
            if src.startswith(quote, i):
                out.append('"')
                return i + len(quote)
            c = src[i]
            if c == "\\" and i + 1 < n:
                if src[i + 1] == "(":                      # interpolation: keep its code
                    depth, j = 1, i + 2
                    while j < n and depth:
                        depth += {"(": 1, ")": -1}.get(src[j], 0)
                        j += 1
                    out.append(" " + code_view(src[i + 2:j - 1]) + " ")
                    i = j
                else:
                    i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        return i

    while i < n:
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("\n" * src.count("\n", i, end))
            i = end
        elif src.startswith('"""', i):
            i = skip_string(i + 3, '"""')
        elif src[i] == '"':
            i = skip_string(i + 1, '"')
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def region_lines(src):
    """[(line number, original text, code text)] for the lines between the two markers.

    Raises AssertionError when a marker is missing (the policy would otherwise scan nothing).
    """
    lines = src.split("\n")
    marks = {m: [i for i, ln in enumerate(lines) if ln.strip() == m] for m in (START_MARKER, END_MARKER)}
    assert len(marks[START_MARKER]) == 1, f"expected exactly one line `{START_MARKER}`, found {len(marks[START_MARKER])}"
    assert len(marks[END_MARKER]) == 1, f"expected exactly one line `{END_MARKER}`, found {len(marks[END_MARKER])}"
    start, end = marks[START_MARKER][0], marks[END_MARKER][0]
    assert start < end, f"`{START_MARKER}` must come before `{END_MARKER}`"
    code = code_view(src).split("\n")
    assert len(code) == len(lines), "the comment/string stripper lost track of the lines; fix code_view"
    return [(i + 1, lines[i], code[i]) for i in range(start + 1, end)]


def forbidden_in_region(src):
    """One message per offending line of the Details sheet region."""
    found = []
    for no, orig, code in region_lines(src):
        for what, pattern in FORBIDDEN:
            if re.search(pattern, code):
                found.append(f"line {no}: {orig.strip()!r} uses {what}, but the status text is never logged, sent or stored")
    return found


def host_uses_in_region(src):
    """One message per `host.<member>` use other than the two the sheet may ask for."""
    found = []
    for no, orig, code in region_lines(src):
        for member in re.findall(r"\bhost\s*\.\s*(\w+)", code):
            if member not in ALLOWED_HOST_MEMBERS:
                found.append(f"line {no}: {orig.strip()!r} uses host.{member}; the sheet may only use "
                             f"{' and '.join('host.' + m for m in sorted(ALLOWED_HOST_MEMBERS))}")
    return found


def spawns_in_region(src):
    return [f"line {no}: {orig.strip()!r} spawns a process with {what}; use ProcessRunner"
            for no, orig, code in region_lines(src) for what, pattern in SPAWNERS if re.search(pattern, code)]


def logged_text_in_file(src):
    """One message per logger call, anywhere in the file, whose arguments mention the sheet's text.

    A logger is any name bound with `Logger(`, plus `log`. A call's arguments are read to the matching
    parenthesis (so a call over several lines is one call); string text is ignored but `\\(text)`
    interpolations count.
    """
    code = code_view(src)
    orig_lines = src.split("\n")
    names = {"log"} | set(re.findall(r"\b(\w+)\s*(?::[^=\n]+)?=\s*Logger\s*\(", code))
    found = []
    for name in sorted(names):
        for m in re.finditer(rf"(?<![\w.]){re.escape(name)}\s*\.\s*\w+\s*\(", code):
            depth, j = 1, m.end()
            while j < len(code) and depth:
                depth += {"(": 1, ")": -1}.get(code[j], 0)
                j += 1
            args = code[m.end():j - 1]
            if re.search(LOGGED_IDENTIFIERS, args):
                no = code.count("\n", 0, m.start()) + 1
                found.append(f"line {no}: {orig_lines[no - 1].strip()!r} logs `{re.search(LOGGED_IDENTIFIERS, args).group(1)}`, "
                             f"which holds the status text")
    return found


def read_view():
    with open(VIEW, encoding="utf-8") as f:
        return f.read()


# --------------------------------------------------------------------------
# The policy, over the real file
# --------------------------------------------------------------------------

class DetailsSheetPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = read_view()

    def test_the_details_sheet_region_exists_and_is_the_sheet(self):
        region = region_lines(self.src)           # asserts both markers
        code = "\n".join(c for _, _, c in region)
        self.assertGreater(len(region), 50)
        self.assertIn("MotherDetailsSheet", code)
        self.assertIn("loadDetails", code)

    def test_the_status_text_is_never_logged_sent_or_stored(self):
        self.assertEqual(forbidden_in_region(self.src), [], "\n" + "\n".join(forbidden_in_region(self.src)))

    def test_the_sheet_only_asks_the_host_for_the_mother_binary_and_the_broker_kind(self):
        self.assertEqual(host_uses_in_region(self.src), [], "\n" + "\n".join(host_uses_in_region(self.src)))
        code = "\n".join(c for _, _, c in region_lines(self.src))
        self.assertIn("host.motherBinary()", code)     # the policy is about something the sheet really does
        self.assertIn("host.usesDefaultBroker", code)

    def test_the_process_is_spawned_only_through_process_runner(self):
        self.assertEqual(spawns_in_region(self.src), [], "\n" + "\n".join(spawns_in_region(self.src)))
        code = "\n".join(c for _, _, c in region_lines(self.src))
        self.assertIn("ProcessRunner.", code)

    def test_no_log_call_anywhere_in_the_file_mentions_the_sheets_text(self):
        self.assertEqual(logged_text_in_file(self.src), [], "\n" + "\n".join(logged_text_in_file(self.src)))


# --------------------------------------------------------------------------
# The checks bite
# --------------------------------------------------------------------------

def sheet(body):
    return f"import AppKit\nprivate let log = Logger(subsystem: \"x\", category: \"y\")\n{START_MARKER}\n{body}\n{END_MARKER}\n"


class ChecksBiteTests(unittest.TestCase):
    def test_each_forbidden_construct_is_caught_and_names_its_line(self):
        samples = {
            "log.": "    log.info(\"x\")",
            "Logger(": "    let l = Logger(subsystem: \"a\", category: \"b\")",
            "os_log": "    os_log(\"x\")",
            "NSLog": "    NSLog(\"x\")",
            "print(": "    print(text)",
            "debugPrint": "    debugPrint(text)",
            "dump(": "    dump(text)",
            "AppStore": "    let s = AppStore.shared",
            "NostromodClient": "    NostromodClient.shared.go()",
            "client.send": "    client.send(text)",
            "UserDefaults": "    UserDefaults.standard.set(text, forKey: \"k\")",
            "write(to": "    try text.write(to: url, atomically: true, encoding: .utf8)",
            "FileManager": "    FileManager.default.createFile(atPath: p, contents: nil)",
        }
        self.assertEqual(len(samples), len(FORBIDDEN), "every forbidden construct has a sample")
        for what, line in samples.items():
            with self.subTest(what):
                msgs = forbidden_in_region(sheet(line))
                self.assertEqual(len(msgs), 1, msgs)
                self.assertIn("line 4", msgs[0])
                self.assertIn(line.strip(), msgs[0])

    def test_comments_and_string_text_do_not_trip_the_scan(self):
        body = ('    // we never call print( or log.info here, and AppStore is not used\n'
                '    /* NSLog("x") */\n'
                '    let s = "print( log.info FileManager AppStore"\n'
                '    let t = """\n    NSLog UserDefaults\n    """')
        self.assertEqual(forbidden_in_region(sheet(body)), [])

    def test_code_inside_a_string_interpolation_is_still_scanned(self):
        self.assertEqual(len(forbidden_in_region(sheet('    let s = "x \\(UserDefaults.standard)"'))), 1)

    def test_code_outside_the_region_is_not_this_policys_business(self):
        src = f"print(1)\nlog.info(\"x\")\n{START_MARKER}\nlet a = 1\n{END_MARKER}\nFileManager.default\n"
        self.assertEqual(forbidden_in_region(src), [])

    def test_a_missing_or_misordered_marker_is_an_error_not_a_pass(self):
        with self.assertRaises(AssertionError):
            region_lines(f"{START_MARKER}\nlet a = 1\n")
        with self.assertRaises(AssertionError):
            region_lines(f"{END_MARKER}\nlet a = 1\n")
        with self.assertRaises(AssertionError):
            region_lines(f"{END_MARKER}\n{START_MARKER}\n")

    def test_other_host_members_are_caught_and_the_two_allowed_ones_are_not(self):
        self.assertEqual(host_uses_in_region(sheet("    let b = host.motherBinary()\n    if host.usesDefaultBroker {}")), [])
        for member in ("answerJob", "cancelJob", "peek", "brokerConnected", "openPlan"):
            with self.subTest(member):
                msgs = host_uses_in_region(sheet(f"    host.{member}(x)"))
                self.assertEqual(len(msgs), 1, msgs)
                self.assertIn(f"host.{member}", msgs[0])
        self.assertEqual(len(host_uses_in_region(sheet("    self.host.escalateJob(id)"))), 1)
        self.assertEqual(host_uses_in_region(sheet("    let host = self.host")), [])

    def test_other_ways_to_spawn_a_process_are_caught(self):
        for line in ("    let p = Process()", "    let t = NSTask()", "    posix_spawn(&pid, path, nil, nil, args, env)"):
            with self.subTest(line):
                self.assertEqual(len(spawns_in_region(sheet(line))), 1)
        self.assertEqual(spawns_in_region(sheet("    ProcessRunner.runCapturingStdout(bin, arguments: [])")), [])
        self.assertEqual(spawns_in_region(sheet("    let r = MyProcessRunner.run()")), [])

    def test_a_log_call_with_the_text_is_caught_wherever_it_is_in_the_file(self):
        cases = [
            'log.info("status: \\(text)")',
            "log.debug(content)",
            'log.error("failed", output)',
            'logger.notice("x \\(shownText)")',
            'log.info(\n    "multi-line",\n    text\n)',
        ]
        for line in cases:
            with self.subTest(line):
                src = ('let logger = Logger(subsystem: "a", category: "b")\n'
                       'private let log = Logger(subsystem: "a", category: "b")\n' + "func f() {\n" + line + "\n}\n")
                msgs = logged_text_in_file(src)
                self.assertEqual(len(msgs), 1, msgs)
                self.assertIn("line ", msgs[0])

    def test_log_calls_that_do_not_touch_the_text_are_fine(self):
        src = ('private let log = Logger(subsystem: "a", category: "b")\n'
               'log.info("mother status text and output are not logged")\n'      # the words in a literal are not identifiers
               'log.error("job \\(job.id) failed")\n'
               '// log.info(text)\n'
               'let textView = 1; let n = context.count\n')
        self.assertEqual(logged_text_in_file(src), [])


if __name__ == "__main__":
    unittest.main()
