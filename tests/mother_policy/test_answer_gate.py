"""Source-scanning policy for answering and acknowledging Mother from the Mac (MC3).

The trust rule: a control in the Mother panel that sends `answer` (an option button, the
free-text Answer) or `ack` (Acknowledge) is only ever driven by a person at this Mac. So

  1. every function in MotherView.swift / MotherJobDetail.swift whose body CALLS
     `answerMotherDecision(`, `ackMotherAttention(` or `answerJob(` first calls
     `HumanGesture.permit(` (app-control, synthetic, stale and AX-press-without-VoiceOver
     input is refused there);
  2. nothing in those controls claims a key equivalent (Return/Escape must never answer or
     acknowledge a hold; the Details sheet's Escape-closes `done` button is outside the
     `MotherJobDetail` class region and is allowed);
  3. nothing in those two files activates the app or orders a window front, so an answer
     control can never be put under the pointer by the app itself.

These are tests of what the source LOOKS like (a textual heuristic, not a control-flow proof),
in the same spirit as test_details_sheet_policy.py. Each check is a plain function over source
text, with "bites" tests on synthetic sources so a check that cannot fail would be noticed.

Run with:  python3 -m unittest discover -s tests/mother_policy -v
"""
import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VIEWS = os.path.join(REPO_ROOT, "macOS", "Nostromo", "UI", "Views")
MOTHER_VIEW = os.path.join(VIEWS, "MotherView.swift")
MOTHER_DETAIL = os.path.join(VIEWS, "MotherJobDetail.swift")

CLASS_START = "final class MotherJobDetail: NSView {"
CLASS_END = "// MARK: - PlanChecklistView"

SEND_CALLEES = ("answerMotherDecision", "ackMotherAttention", "answerJob")
PERMIT = r"\bHumanGesture\s*\.\s*permit\s*\("

# (description, pattern) over code with comments and string-literal text removed.
# `NSLayoutConstraint.activate([...])` is layout, not app activation, so it is excepted.
ACTIVATION = [
    ("NSApp.activate", r"\bNSApp\s*\.\s*activate\w*\b"),
    (".activate(", r"(?<!NSLayoutConstraint)\.\s*activate\w*\s*\("),
    ("makeKeyAndOrderFront", r"\bmakeKeyAndOrderFront\b"),
    ("orderFrontRegardless", r"\borderFrontRegardless\b"),
    ("requestUserAttention", r"\brequestUserAttention\b"),
]


# --------------------------------------------------------------------------
# Source handling (same comment/string stripper as test_details_sheet_policy.py)
# --------------------------------------------------------------------------

def code_view(src):
    """`src` with comments removed and string-literal text blanked, line for line.

    The code inside a string's `\\( ... )` interpolation is kept (it is code). Newlines are
    preserved so line numbers still match the original.
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


def match_close(code, open_idx):
    """Index just past the bracket that closes the one at `open_idx` (or len(code) if unbalanced)."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    opener = code[open_idx]
    closer = pairs[opener]
    depth, j = 0, open_idx
    while j < len(code):
        if code[j] == opener:
            depth += 1
        elif code[j] == closer:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return len(code)


def line_of(code, idx):
    return code.count("\n", 0, idx) + 1


# --------------------------------------------------------------------------
# Check 1: a gesture permit before every send
# --------------------------------------------------------------------------

FUNC_HEAD = re.compile(r"\bfunc\s+([A-Za-z_]\w*|[^\s\w(]+)\s*(?:<[^>{]*>)?\s*\(")


def functions_with_bodies(code):
    """[(name, head_line, body_start, body_end)] for each `func` that has a body.

    A protocol requirement (`func answerJob(...)` with no `{` after its signature) has no body
    and is left out. body_start/body_end index the text between the braces.
    """
    found = []
    for m in FUNC_HEAD.finditer(code):
        after_params = match_close(code, m.end() - 1)
        tail = re.match(r"[^\n{]*\{|[^\n{]*\n\s*\{", code[after_params:])
        if not tail:
            continue
        open_idx = after_params + tail.end() - 1
        found.append((m.group(1), line_of(code, m.start()), open_idx + 1, match_close(code, open_idx) - 1))
    return found


def send_calls(code, callees=SEND_CALLEES):
    """[(callee, index)] for each CALL of a send function (a `func name(` declaration is not a call)."""
    calls = []
    for callee in callees:
        for m in re.finditer(rf"\b{callee}\s*\(", code):
            if re.search(r"\bfunc\s+$", code[:m.start()]):
                continue
            calls.append((callee, m.start()))
    return sorted(calls, key=lambda c: c[1])


def ungated_sends(src):
    """One message per send call that has no `HumanGesture.permit(` earlier in the same function body.

    Applies to every function whose body contains the call (an enclosing function counts too), and
    to a call that sits in no function at all (nothing can be said to gate it).
    """
    code = code_view(src)
    orig = src.split("\n")
    funcs = functions_with_bodies(code)
    permits = [m.start() for m in re.finditer(PERMIT, code)]
    found = []
    for callee, idx in send_calls(code):
        no = line_of(code, idx)
        enclosing = [f for f in funcs if f[2] <= idx < f[3]]
        if not enclosing:
            found.append(f"line {no}: {orig[no - 1].strip()!r} calls {callee}( outside any function body; "
                         f"it must be inside a function that first calls HumanGesture.permit(")
        for name, head_line, start, end in enclosing:
            if not any(start <= p < idx for p in permits):
                found.append(f"line {no}: {orig[no - 1].strip()!r} calls {callee}( in `{name}` (line {head_line}) "
                             f"without a HumanGesture.permit( earlier in the same function")
    return sorted(set(found), key=lambda s: int(re.match(r"line (\d+)", s).group(1)))


# --------------------------------------------------------------------------
# Check 2: no key equivalents
# --------------------------------------------------------------------------

def class_region(src):
    """[(line number, original text, code text)] for the lines of the `MotherJobDetail` class.

    From `final class MotherJobDetail: NSView {` to `// MARK: - PlanChecklistView`. Raises
    AssertionError when a marker is missing or misplaced (the policy would otherwise scan nothing).
    """
    lines = src.split("\n")
    starts = [i for i, ln in enumerate(lines) if ln.strip() == CLASS_START]
    ends = [i for i, ln in enumerate(lines) if ln.strip() == CLASS_END]
    assert len(starts) == 1, f"expected exactly one line `{CLASS_START}`, found {len(starts)}"
    assert len(ends) == 1, f"expected exactly one line `{CLASS_END}`, found {len(ends)}"
    assert starts[0] < ends[0], f"`{CLASS_START}` must come before `{CLASS_END}`"
    code = code_view(src).split("\n")
    assert len(code) == len(lines), "the comment/string stripper lost track of the lines; fix code_view"
    return [(i + 1, lines[i], code[i]) for i in range(starts[0], ends[0])]


def key_equivalent_assignments(lines):
    """One message per `keyEquivalent = ...` assignment in `lines` ([(no, original, code)])."""
    return [f"line {no}: {orig.strip()!r} assigns keyEquivalent; no answer or acknowledge control may claim a key"
            for no, orig, code in lines if re.search(r"\bkeyEquivalent\s*=(?!=)", code)]


def whole_file_lines(src):
    code = code_view(src).split("\n")
    return [(i + 1, ln, code[i]) for i, ln in enumerate(src.split("\n"))]


def key_equivalents_in_mother_view(src):
    return key_equivalent_assignments(whole_file_lines(src))


def key_equivalents_in_detail_class(src):
    return key_equivalent_assignments(class_region(src))


# --------------------------------------------------------------------------
# Check 3: no app activation
# --------------------------------------------------------------------------

def activations(src):
    """One message per line that activates the app or orders a window front."""
    return [f"line {no}: {orig.strip()!r} uses {what}; nothing here may bring the app or a window forward"
            for no, orig, code in whole_file_lines(src) for what, pattern in ACTIVATION if re.search(pattern, code)]


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def block(msgs):
    return "\n" + "\n".join(msgs)


# --------------------------------------------------------------------------
# The policy, over the real files
# --------------------------------------------------------------------------

class AnswerGatePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.view = read(MOTHER_VIEW)
        cls.detail = read(MOTHER_DETAIL)

    def test_the_scan_still_finds_the_free_text_answer_call_so_a_rename_cannot_empty_it(self):
        code = code_view(self.detail)
        calls = [c for c in send_calls(code) if c[0] == "answerJob"]
        self.assertGreaterEqual(len(calls), 1, "no `answerJob(` call found in MotherJobDetail.swift; "
                                               "the gate scan would check nothing for the free-text Answer")
        funcs = {f[0] for f in functions_with_bodies(code)}
        self.assertIn("didTapAnswer", funcs)
        self.assertGreater(len(funcs), 10, "the function finder lost the file's functions")

    def test_the_class_region_exists_and_is_the_detail_pane(self):
        region = class_region(self.detail)
        code = "\n".join(c for _, _, c in region)
        self.assertGreater(len(region), 300)
        self.assertIn("didTapAnswer", code)

    def test_every_send_in_the_detail_pane_is_preceded_by_a_gesture_permit(self):
        self.assertEqual(ungated_sends(self.detail), [], block(ungated_sends(self.detail)))

    def test_every_send_in_the_mother_view_is_preceded_by_a_gesture_permit(self):
        self.assertEqual(ungated_sends(self.view), [], block(ungated_sends(self.view)))

    def test_no_answer_or_acknowledge_control_claims_a_key_equivalent(self):
        self.assertEqual(key_equivalents_in_mother_view(self.view), [], block(key_equivalents_in_mother_view(self.view)))
        self.assertEqual(key_equivalents_in_detail_class(self.detail), [], block(key_equivalents_in_detail_class(self.detail)))

    def test_the_details_sheets_escape_key_is_outside_the_checked_class_region(self):
        # the sheet's Escape-closes `done` button is allowed; this pins that the region really excludes it
        self.assertTrue(any("keyEquivalent" in c for _, _, c in whole_file_lines(self.detail)),
                        "the Details sheet's `done.keyEquivalent` moved or went away; revisit the class-region markers")
        self.assertEqual(key_equivalents_in_detail_class(self.detail), [])

    def test_neither_file_activates_the_app_or_orders_a_window_front(self):
        for name, src in (("MotherView.swift", self.view), ("MotherJobDetail.swift", self.detail)):
            with self.subTest(name):
                self.assertEqual(activations(src), [], block(activations(src)))


# --------------------------------------------------------------------------
# The checks bite
# --------------------------------------------------------------------------

def swift(body):
    return f"import AppKit\nfinal class Thing: NSView {{\n{body}\n}}\n"


class GateChecksBiteTests(unittest.TestCase):
    def test_each_send_call_without_a_permit_is_caught_and_names_its_function(self):
        for callee, call in (("answerMotherDecision", "host.answerMotherDecision(jobId: j, decisionId: d, option: o, text: t)"),
                             ("ackMotherAttention", "host.ackMotherAttention(jobId: j, reason: r)"),
                             ("answerJob", "host.answerJob(job.id, text: text)")):
            with self.subTest(callee):
                msgs = ungated_sends(swift(f"    @objc func didTap() {{\n        {call}\n    }}"))
                self.assertEqual(len(msgs), 1, msgs)
                self.assertIn("line 4", msgs[0])
                self.assertIn(callee, msgs[0])
                self.assertIn("didTap", msgs[0])

    def test_a_permit_earlier_in_the_same_function_passes(self):
        body = ("    func go() {\n"
                "        guard case .human = HumanGesture.permit(e, control: b) else { return }\n"
                "        host.answerJob(id, text: t)\n"
                "        host.ackMotherAttention(jobId: j, reason: r)\n"
                "        host.answerMotherDecision(jobId: j, decisionId: d, option: o, text: t)\n"
                "    }")
        self.assertEqual(ungated_sends(swift(body)), [])

    def test_a_permit_that_comes_after_the_call_does_not_count(self):
        body = ("    func go() {\n"
                "        host.answerJob(id, text: t)\n"
                "        _ = HumanGesture.permit(e, control: b)\n"
                "    }")
        self.assertEqual(len(ungated_sends(swift(body))), 1)

    def test_a_permit_in_another_function_does_not_count(self):
        body = ("    func check() { _ = HumanGesture.permit(e, control: b) }\n"
                "    func go() { host.answerJob(id, text: t) }")
        msgs = ungated_sends(swift(body))
        self.assertEqual(len(msgs), 1, msgs)
        self.assertIn("`go`", msgs[0])

    def test_a_permit_only_mentioned_in_a_comment_or_string_does_not_count(self):
        body = ("    func go() {\n"
                "        // HumanGesture.permit( is checked by the caller\n"
                "        let s = \"HumanGesture.permit(\"\n"
                "        host.answerJob(id, text: t)\n"
                "    }")
        self.assertEqual(len(ungated_sends(swift(body))), 1)

    def test_a_send_named_only_in_a_comment_or_string_is_not_a_call(self):
        body = ("    func go() {\n"
                "        // host.answerJob(id, text: t) used to be here\n"
                "        let s = \"call answerMotherDecision( later\"\n"
                "    }")
        self.assertEqual(ungated_sends(swift(body)), [])

    def test_a_call_inside_a_nested_closure_is_part_of_the_function_body(self):
        ungated = "    func go() {\n        DispatchQueue.main.async { [weak self] in self?.host.ackMotherAttention(jobId: j, reason: r) }\n    }"
        self.assertEqual(len(ungated_sends(swift(ungated))), 1)
        gated = ("    func go() {\n        guard case .human = HumanGesture.permit(e, control: b) else { return }\n"
                 "        DispatchQueue.main.async { self.host.ackMotherAttention(jobId: j, reason: r) }\n    }")
        self.assertEqual(ungated_sends(swift(gated)), [])

    def test_the_protocol_declaration_without_a_body_is_not_a_call(self):
        src = ("protocol Host: AnyObject {\n"
               "    func answerJob(_ id: String, text: String)\n"
               "    func ackMotherAttention(jobId: String, reason: MotherAttentionReason)\n"
               "    func answerMotherDecision(jobId: String, decisionId: String, option: MotherDecisionOption, text: String)\n"
               "    func cancelJob(_ id: String)\n"
               "}\n")
        self.assertEqual(send_calls(code_view(src)), [])
        self.assertEqual(ungated_sends(src), [])

    def test_a_declaration_with_a_body_is_a_definition_not_a_call(self):
        src = swift("    func answerJob(_ id: String, text: String) {\n        store.send(id, text)\n    }")
        self.assertEqual(send_calls(code_view(src)), [])
        self.assertEqual(ungated_sends(src), [])

    def test_a_protocol_requirement_does_not_swallow_the_next_functions_body(self):
        # the requirement has no body: the finder must not pair it with the `{` of what follows
        src = ("protocol Host {\n    func answerJob(_ id: String, text: String)\n}\n"
               "final class V {\n    func go() {\n        host.answerJob(id, text: t)\n    }\n}\n")
        msgs = ungated_sends(src)
        self.assertEqual(len(msgs), 1, msgs)
        self.assertIn("line 6", msgs[0])
        self.assertEqual([f[0] for f in functions_with_bodies(code_view(src))], ["go"])

    def test_signatures_with_return_types_throws_generics_and_wrapped_parameters_are_found(self):
        src = swift("    func a(x: Int) -> Bool {\n        host.answerJob(id, text: t); return true\n    }\n"
                    "    func b<T>(x: T) throws -> [String: Int] {\n        host.answerJob(id, text: t); return [:]\n    }\n"
                    "    func c(\n        x: Int,\n        y: Int\n    ) {\n        host.answerJob(id, text: t)\n    }\n"
                    "    private func d()\n    {\n        host.answerJob(id, text: t)\n    }")
        msgs = ungated_sends(src)
        self.assertEqual(len(msgs), 4, msgs)
        for name in ("`a`", "`b`", "`c`", "`d`"):
            self.assertTrue(any(name in m for m in msgs), (name, msgs))

    def test_a_send_outside_any_function_is_caught(self):
        src = "final class V {\n    lazy var go: () -> Void = { self.host.answerJob(id, text: t) }\n}\n"
        msgs = ungated_sends(src)
        self.assertEqual(len(msgs), 1, msgs)
        self.assertIn("outside any function", msgs[0])

    def test_every_ungated_function_is_reported_not_just_the_first(self):
        src = swift("    func one() { host.answerJob(a, text: t) }\n    func two() { host.ackMotherAttention(jobId: j, reason: r) }")
        self.assertEqual(len(ungated_sends(src)), 2)

    def test_a_longer_name_that_merely_ends_in_a_send_name_is_not_a_send(self):
        src = swift("    func go() { host.cancelAnswerJobs(); host.reanswerJob(x); host.answerJobs(x) }")
        self.assertEqual(ungated_sends(src), [])


class KeyEquivalentChecksBiteTests(unittest.TestCase):
    def detail(self, inside="", outside=""):
        return (f"import AppKit\n{outside}\n{CLASS_START}\n{inside}\n}}\n{CLASS_END}\nfinal class Sheet: NSView {{\n{outside}\n}}\n")

    def test_a_key_equivalent_assignment_in_the_detail_class_is_caught_with_its_line(self):
        src = self.detail(inside='    func build() {\n        b.keyEquivalent = "\\r"\n    }')
        msgs = key_equivalents_in_detail_class(src)
        self.assertEqual(len(msgs), 1, msgs)
        self.assertIn("line 5", msgs[0])
        self.assertIn("keyEquivalent", msgs[0])
        self.assertEqual(len(key_equivalents_in_detail_class(self.detail(inside='    func f() { b.keyEquivalent="" }'))), 1)

    def test_an_assignment_outside_the_class_region_is_not_the_class_checks_business(self):
        src = self.detail(outside='    func sheet() { done.keyEquivalent = "\\u{1b}" }')
        self.assertEqual(key_equivalents_in_detail_class(src), [])

    def test_reads_comparisons_comments_strings_and_the_modifier_mask_are_not_assignments(self):
        inside = ('    func f() {\n'
                  '        XCTAssertEqual(b.keyEquivalent, "")\n'
                  '        if b.keyEquivalent == "" {}\n'
                  '        b.keyEquivalentModifierMask = []\n'
                  '        // b.keyEquivalent = "\\r"\n'
                  '        let s = "b.keyEquivalent = x"\n'
                  '    }')
        self.assertEqual(key_equivalents_in_detail_class(self.detail(inside=inside)), [])

    def test_any_assignment_anywhere_in_mother_view_is_caught(self):
        src = 'final class MotherView: NSView {\n    func x() {\n        ack.keyEquivalent = "\\r"\n    }\n}\n'
        msgs = key_equivalents_in_mother_view(src)
        self.assertEqual(len(msgs), 1, msgs)
        self.assertIn("line 3", msgs[0])
        self.assertEqual(key_equivalents_in_mother_view('final class MotherView {\n    let a = 1\n}\n'), [])

    def test_a_missing_or_misordered_class_marker_is_an_error_not_a_pass(self):
        for src in (f"{CLASS_START}\nlet a = 1\n", f"{CLASS_END}\nlet a = 1\n", f"{CLASS_END}\n{CLASS_START}\n",
                    f"{CLASS_START}\n{CLASS_START}\n{CLASS_END}\n"):
            with self.subTest(src):
                with self.assertRaises(AssertionError):
                    class_region(src)


class ActivationChecksBiteTests(unittest.TestCase):
    def test_each_activation_construct_is_caught_and_names_its_line(self):
        samples = {
            "NSApp.activate": "    NSApp.activate(ignoringOtherApps: true)",
            "NSApp.activate (bare)": "    NSApp.activate()",
            ".activate(": "    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])",
            "app.activate": "    app.activate()",
            "makeKeyAndOrderFront": "    window.makeKeyAndOrderFront(nil)",
            "orderFrontRegardless": "    window.orderFrontRegardless()",
            "requestUserAttention": "    NSApp.requestUserAttention(.criticalRequest)",
        }
        for what, line in samples.items():
            with self.subTest(what):
                msgs = activations(f"import AppKit\nfunc f() {{\n{line}\n}}\n")
                self.assertGreaterEqual(len(msgs), 1, msgs)
                self.assertIn("line 3", msgs[0])
                self.assertIn(line.strip(), msgs[0])

    def test_layout_constraint_activation_is_not_app_activation(self):
        src = "func f() {\n    NSLayoutConstraint.activate([\n        a.leadingAnchor.constraint(equalTo: b.leadingAnchor),\n    ])\n}\n"
        self.assertEqual(activations(src), [])

    def test_comments_and_string_text_do_not_trip_the_scan(self):
        src = ('func f() {\n'
               '    // we never call NSApp.activate or makeKeyAndOrderFront here\n'
               '    /* window.orderFrontRegardless() */\n'
               '    let s = "requestUserAttention .activate( NSApp.activate"\n'
               '}\n')
        self.assertEqual(activations(src), [])

    def test_code_inside_a_string_interpolation_is_still_scanned(self):
        self.assertEqual(len(activations('func f() {\n    let s = "x \\(window.makeKeyAndOrderFront(nil))"\n}\n')), 1)


if __name__ == "__main__":
    unittest.main()
