# nostromo-doctor tests

Run with:

```
/usr/bin/python3 -m unittest discover -s tests/doctor
```

These tests cover the pure-function contract of `bin/nostromo-doctor` only
(status model, exit-code/worst-status aggregation, report formatting, load
parsing, ps-table parsing and process-tree walking, staleness classification,
error-log filtering, and the per-session stuck-signal classifier). Checks that
touch the live system — the Unix-socket IPC handshake, and `ps`/`git`/
`launchctl` subprocess execution — are verified manually against the plan's
manual checklist, not exercised by this unit test file.
