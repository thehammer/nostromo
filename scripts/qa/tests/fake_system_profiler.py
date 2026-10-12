#!/usr/bin/env python3
"""Stand-in for `system_profiler` (QA_SYSTEM_PROFILER points here in every QA test).

Only `SPDisplaysDataType -json` is understood. What it prints comes from $FAKE_APP_DIR/profiler.json:

  {"gpus": [["Display A", "Display B"], null]}   one entry per GPU: its display names, or null for a GPU
                                                 that has no `spdisplays_ndrvs` key at all
  {"exit": 1}                                    fail with that exit status
  {"raw": "not json"}                            print this text verbatim

Every invocation's argv is appended to $FAKE_APP_DIR/profiler.log (the placement check must run it
read-only, with exactly these arguments).
"""
import json
import os
import sys

d = os.environ["FAKE_APP_DIR"]
with open(os.path.join(d, "profiler.log"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
with open(os.path.join(d, "profiler.json")) as f:
    spec = json.load(f)
if sys.argv[1:] != ["SPDisplaysDataType", "-json"]:
    sys.stderr.write("fake system_profiler: unexpected arguments\n")
    sys.exit(2)
if spec.get("exit"):
    sys.stderr.write("fake system_profiler: failing as told\n")
    sys.exit(spec["exit"])
if "raw" in spec:
    print(spec["raw"])
    sys.exit(0)
gpus = []
for i, names in enumerate(spec.get("gpus", [])):
    gpu = {"_name": f"gpu{i}", "sppci_model": f"gpu{i}"}
    if names is not None:
        gpu["spdisplays_ndrvs"] = [{"_name": n, "_spdisplays_pixels": "3456 x 2234"} for n in names]
    gpus.append(gpu)
print(json.dumps({"SPDisplaysDataType": gpus}, indent=4))
