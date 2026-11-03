#!/bin/bash
# Records WHEN a display stops showing Nostromo, and what was frontmost, so a surprise Space switch can be
# attributed: did Nostromo come forward first (our activation), or another app?
#
# Every second it takes a snapshot of the on-screen app windows (owner name and bounds only, no titles or
# contents) and the frontmost app. It writes a line ONLY when something changed, so the log stays small.
#
#   scripts/debug/space-watch.sh [--hours N] [--log PATH]
#
# Default log: ~/.nostromo-debug/space-watch.log. Stop with Ctrl-C. Needs no special permission
# (window owner names and bounds do not need Screen Recording; titles would, and are not read).
set -u
hours=24
log="$HOME/.nostromo-debug/space-watch.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --hours) hours="$2"; shift 2 ;;
    --log) log="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$log")"
end=$(( $(date +%s) + hours * 3600 ))
last=""
echo "$(date '+%F %T') start (hours=$hours)" >> "$log"
while [ "$(date +%s)" -lt "$end" ]; do
  front="$(lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | sed -n 's/^"\([^"]*\)".*/\1/p' | head -1)"
  snap="$(osascript -l JavaScript -e "$(cat "$here/space-watch.js"); run()" 2>/dev/null)"
  state="front=$front $snap"
  if [ "$state" != "$last" ]; then
    echo "$(date '+%F %T') front=\"$front\" $snap" >> "$log"
    last="$state"
  fi
  sleep 1
done
echo "$(date '+%F %T') end" >> "$log"
