#!/usr/bin/env bash
# A separate Tern window with Flightdeck and made-up work, for screenshots.
# Nothing touches your own Tern, sessions, omp spend or Flightdeck data: Tern
# runs with its own config and daemon, Flightdeck's server on its own port,
# reading made-up omp usage.
#
#   scripts/showcase.sh [dir]     (default /tmp/flightdeck-showcase; replaced each run)
#
# Then drive it with `tern ctl --control <dir>/desktop.sock …` (shot NAME,
# appearance light|dark, click X Y), or use scripts/showcase-shots.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
D=${1:-/private/tmp/flightdeck-showcase}
TERN=/Applications/Tern.app/Contents/MacOS/tern
BUN=$(command -v bun || echo "$HOME/.bun/bin/bun")
PORT=${FLIGHTDECK_PORT:-8096}

# A previous showcase: its window, daemon, server and agents.
pkill -f -- "--control $D/desktop.sock" 2>/dev/null || true
pkill -f -- "daemon --socket $D/daemon.sock" 2>/dev/null || true
pkill -f -- "$D/config/plugin-data/flightdeck" 2>/dev/null || true
for p in $(pgrep -x omp 2>/dev/null); do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -q "$D" && kill "$p" || true; done
rm -rf "$D"
mkdir -p "$D"
D=$(cd "$D" && pwd -P)   # /tmp is /private/tmp: Git reports the real path, so use it everywhere
DATA="$D/config/plugin-data/flightdeck"
mkdir -p "$DATA"

"$BUN" "$here/server/scripts/showcase.ts" "$DATA" "$D"

# The made-up task sessions' agents, as the window would publish them; the sidebar open.
cat >"$DATA/kv.json" <<JSON
{"panel-open": true, "mission:agents": {
  "01950010-0000-7000-8000-000000000010": "working", "01950011-0000-7000-8000-000000000011": "idle",
  "01950012-0000-7000-8000-000000000012": "waiting", "01950020-0000-7000-8000-000000000020": "working",
  "01950021-0000-7000-8000-000000000021": "working", "01950040-0000-7000-8000-000000000040": "working"}}
JSON

# Follow the system's light or dark appearance (showcase-shots.sh switches it).
echo '{"theme": "System"}' >"$D/config/settings.json"

export TERN_CONFIG_DIR="$D/config" TERN_DAEMON_SOCKET="$D/daemon.sock"
export FLIGHTDECK_PORT=$PORT FLIGHTDECK_OMP_SESSIONS="$D/omp-sessions"
"$TERN" plugin link "$here" >/dev/null
cd "$D"
nohup "$TERN" --control "$D/desktop.sock" >"$D/tern.log" 2>&1 &
for _ in $(seq 60); do "$TERN" ctl --control "$D/desktop.sock" ready >/dev/null 2>&1 && break; sleep 1; done
"$TERN" ctl --control "$D/desktop.sock" size 1600 1000 >/dev/null

# Spaces: each repository with an omp agent beside its shell (idle: nothing is
# asked of them), and one worktree with uncommitted changes. Then the starting
# session (home) goes.
first=$("$TERN" ls --json | jq -r '.sessions[0].id')
for r in payments storefront design-system platform-infra; do
  s=$("$TERN" new session "$r" --cwd "$D/repos/$r" | tr -dc 0-9)
  sess=$("$TERN" ls --json | jq -r --arg p "$s" '.sessions[] | select([.tabs[].blocks[].id | tostring] | index($p)) | .id')
  "$TERN" new tab "$sess" --cwd "$D/repos/$r" -- omp >/dev/null
done
"$TERN" new session refund --cwd "$D/worktrees/payments/refund-webhooks" >/dev/null
"$TERN" ctl --control "$D/desktop.sock" carly lua "cx.sessions:switch('payments'); cx.sessions:close($first)" >/dev/null
echo "Showcase window ready: control socket $D/desktop.sock, Flightdeck on port $PORT"
