#!/usr/bin/env bash
# QA scenario: attach an image to the agent input, check the chip, remove it.
# Needs the app running with AppControlEnabled and a visible window, and it
# CLICKS / DROPS in the live window — run it when nobody is typing in it.
# Does not send a message (so it costs nothing and touches no agent).
set -euo pipefail
APP="$(dirname "$0")/../../bin/nostromo-app"
IMG="$(mktemp -d)/qa-chip.png"
python3 - "$IMG" <<'PY'
import struct, sys, zlib
w, h = 120, 80
raw = b"".join(b"\x00" + bytes([x * 255 // w, y * 255 // h, 160]) * 1 if False else b"\x00" + b"".join(bytes([x * 255 // w, y * 255 // h, 160]) for x in range(w)) for y in range(h))
def ch(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY
"$APP" expect "Message" >/dev/null                         # the input exists
"$APP" drop "$IMG" --text "Message"                        # drop onto the input
"$APP" wait "qa-chip.png" --timeout 5                      # the chip appears
"$APP" layout-issues | python3 -c '
import json, sys
bad = [i for i in json.load(sys.stdin) if i["class"] in ("NSImageView", "NSButton") and i["zeroSized"]]
sys.exit("zero-sized chip controls: %s" % bad if bad else 0)'
"$APP" click --text "✕"                                   # remove it
"$APP" wait "qa-chip.png" --gone --timeout 5
echo "attach-chip: PASS"
