#!/usr/bin/env bash
# Screenshots of the showcase window (scripts/showcase.sh), light then dark:
# the sidebar beside an agent, and Mission control's Now, Backlog, Stats and Repos.
#
#   scripts/showcase-shots.sh [dir] [out]   (defaults /private/tmp/flightdeck-showcase, docs/images)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
D=${1:-/private/tmp/flightdeck-showcase}
OUT=$(mkdir -p "${2:-$here/docs/images}" && cd "${2:-$here/docs/images}" && pwd)
export TERN_CONFIG_DIR="$D/config" TERN_DAEMON_SOCKET="$D/daemon.sock"
TERN=/Applications/Tern.app/Contents/MacOS/tern
ctl() { "$TERN" ctl --control "$D/desktop.sock" "$@" >/dev/null; sleep 0.6; }
shot() { (cd "$D" && ctl shot "$1") && cp "$D/target/shots/tern/live/$1.png" "$OUT/$1.png"; }

# The payments agent's tab, then Mission control (its tabs by ] from Now).
agent=$("$TERN" ls --json | jq -r '.sessions[] | select(.name == "payments") | .tabs[1].blocks[0].id')
for mode in light dark; do
  ctl appearance "$mode"
  "$TERN" focus "$agent" >/dev/null; sleep 3
  shot "sidebar-$mode"
  ctl key cmd+alt+shift+m; sleep 3
  for i in 1 2 3 4 5; do ctl key "["; done   # back to Now
  sleep 2; shot "mission-now-$mode"
  ctl key "]"; sleep 3; shot "mission-backlog-$mode"
  ctl key "]"; ctl key "]"; sleep 3; shot "mission-stats-$mode"
  ctl key "]"; sleep 3; shot "mission-repos-$mode"
done
echo "Screenshots in $OUT"
