"""PASS/FAIL/WARN/INFO/SKIP line reporter shared by the QA scripts."""
from collections import Counter


class Report:
    def __init__(self):
        self.counts = Counter()

    def _emit(self, level, step, detail):
        self.counts[level] += 1
        try:
            print(f"{level} {step}: {detail}", flush=True)
        except OSError:
            pass   # stdout went away (| head, closed terminal): keep going, the clean-up must still run

    def passed(self, step, detail):
        self._emit("PASS", step, detail)

    def fail(self, step, detail):
        self._emit("FAIL", step, detail)

    def warn(self, step, detail):
        self._emit("WARN", step, detail)

    def info(self, step, detail):
        self._emit("INFO", step, detail)

    def skip(self, step, detail):
        self._emit("SKIP", step, detail)

    def summary(self, left_changed=None):
        """Print the final line; the return value is the exit status (1 on any FAIL).

        `left_changed` (a list, or None for scripts that never change anything) is appended as
        ` | left changed: a; b` or ` | left changed: nothing`."""
        c = self.counts
        tail = ""
        if left_changed is not None:
            tail = " | left changed: " + ("; ".join(left_changed) if left_changed else "nothing")
        try:
            print(f"SUMMARY: {c['PASS']} pass, {c['FAIL']} fail, {c['WARN']} warn, {c['INFO']} info, {c['SKIP']} skip{tail}",
                  flush=True)
        except OSError:
            pass
        return 1 if c["FAIL"] else 0
