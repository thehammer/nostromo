"""PASS/FAIL/WARN/INFO line reporter shared by the QA scripts."""
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

    def summary(self):
        """Print the final line; the return value is the exit status (1 on any FAIL)."""
        c = self.counts
        try:
            print(f"SUMMARY: {c['PASS']} pass, {c['FAIL']} fail, {c['WARN']} warn, {c['INFO']} info", flush=True)
        except OSError:
            pass
        return 1 if c["FAIL"] else 0
