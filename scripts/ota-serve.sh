#!/usr/bin/env bash
# make ota-serve: serve OTA_DIR (what `make ota` publishes) over tailnet-only HTTPS. Idempotent.
#   1. a static server on 127.0.0.1:OTA_LOCAL_PORT (python3 http.server, backgrounded, loopback only)
#   2. `tailscale serve --bg --https=OTA_HTTPS_PORT` in front of it, with a real *.ts.net certificate
# Never Funnel: it refuses if the port is already mapped to something else or is Funnel-enabled.
# Does not survive a reboot of the Mac: run it again. Stop: docs/ota.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OTA_DIR="${OTA_DIR:-$HOME/ota/pocketpalette}"
OTA_LOCAL_PORT="${OTA_LOCAL_PORT:-8792}"
OTA_HTTPS_PORT="${OTA_HTTPS_PORT:-8782}"
STATE_DIR="${OTA_STATE_DIR:-$HOME/.cache/pocketpalette-ota}"   # pid + log, outside the served folder
for t in python3 tailscale jq lsof; do require_tool "$t" "needed by make ota-serve"; done
mkdir -p "$OTA_DIR" "$STATE_DIR"

# 1. loopback static server
listener="$(lsof -nP -t -iTCP:"$OTA_LOCAL_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
if [ -n "$listener" ]; then
  [ "$listener" = "$(cat "$STATE_DIR/http.pid" 2>/dev/null || true)" ] \
    || die "port $OTA_LOCAL_PORT is held by another process (pid $listener); set OTA_LOCAL_PORT"
  echo "static server already running (pid $listener) on 127.0.0.1:$OTA_LOCAL_PORT"
else
  nohup python3 -m http.server "$OTA_LOCAL_PORT" --bind 127.0.0.1 --directory "$OTA_DIR" \
    >"$STATE_DIR/http.log" 2>&1 </dev/null &
  echo $! >"$STATE_DIR/http.pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    lsof -nP -iTCP:"$OTA_LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.3
  done
  lsof -nP -iTCP:"$OTA_LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1 || die "static server did not start (see $STATE_DIR/http.log)"
  echo "static server started (pid $(cat "$STATE_DIR/http.pid")) on 127.0.0.1:$OTA_LOCAL_PORT serving $OTA_DIR"
fi

# 2. tailnet-only HTTPS in front of it
host="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
{ [ -n "$host" ] && [ "$host" != "null" ]; } || die "no tailnet hostname (is Tailscale up with MagicDNS?)"
key="$host:$OTA_HTTPS_PORT"
target="http://127.0.0.1:$OTA_LOCAL_PORT"
status="$(tailscale serve status --json)"
current="$(printf '%s' "$status" | jq -r --arg k "$key" '.Web[$k].Handlers["/"].Proxy // empty')"
if [ -z "$current" ]; then
  printf '%s' "$status" | jq -e --arg p "$OTA_HTTPS_PORT" '.TCP[$p] == null' >/dev/null \
    || die "tailnet port $OTA_HTTPS_PORT is already in use by another serve config; set OTA_HTTPS_PORT"
  tailscale serve --bg --https="$OTA_HTTPS_PORT" "$target" >/dev/null
  echo "tailscale serve: https://$key/ -> $target"
elif [ "$current" = "$target" ]; then
  echo "tailscale serve already maps https://$key/ -> $target"
else
  die "https://$key/ already proxies $current; set OTA_HTTPS_PORT"
fi
if tailscale serve status --json | jq -e --arg k "$key" '.AllowFunnel[$k] == true' >/dev/null; then
  die "https://$key is Funnel-enabled (public); OTA must stay tailnet-only: tailscale funnel --https=$OTA_HTTPS_PORT off"
fi
echo "tailnet-only (no Funnel). install page: https://$key/"
