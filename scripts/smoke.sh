#!/usr/bin/env bash
# The ship gate's smoke step (make ship-gate, gate 3/4): prove the BUILT app does its job, not just that it compiles.
# Default: build the stable scheme (Release) for the simulator, install it, launch it with `-FMSelfCheck 1` and require
# the app's `FMSelfCheck: ok <bundle id> <version> (<build>)` stdout line (App/Sources/SelfCheck.swift).
#
# Extending it for your app (the rest of the gate stays as is):
#   - Make `SelfCheck.report` fail unless the things that matter work (backend reachable, store opens, ...).
#   - Add launch arguments to `launch_args` and assertions after the "self-check ok" line, using the app's stdout
#     in $out or anything the app wrote into its data container ($(xcrun simctl get_app_container $udid $BUNDLE_ID data)).
#   - Start any fake dependency (loopback receiver, stub server) before the launch and kill it in `cleanup`.
# Contract with ship-gate.sh: exit 0 only on success; if $SMOKE_RESULT names a file, write one JSON object into it
# (ship-gate stores it as .smoke in the pass file; keep `selfCheckPassed` and `commit`).
# SMOKE_TIMEOUT (seconds, default 90) bounds the wait for the app. Needs: xcodebuild, xcrun simctl, jq.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-90}"
for t in git jq xcodebuild xcrun; do require_tool "$t" "needed by the smoke step"; done

launch_args=(-FMSelfCheck 1)

work="$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")"
udid="" booted_by_us="" launcher_pid=""
cleanup() {
  [ -z "$launcher_pid" ] || kill "$launcher_pid" 2>/dev/null || true
  if [ -n "$udid" ]; then
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    [ -z "$booted_by_us" ] || xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

generate_project
dest="$(sim_destination)"
udid="${dest##*id=}"
short="$(git -C "$ROOT" rev-parse --short HEAD)"
echo "smoke: building $SCHEME (Release, simulator) at $short"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination "$dest" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build -quiet >"$work/build.log" 2>&1 \
  || { tail -30 "$work/build.log" >&2; die "smoke: the simulator build failed"; }
app="$DERIVED/Build/Products/Release-iphonesimulator/$APP_NAME.app"
[ -d "$app" ] || die "smoke: built app not found at $app"

sim_line="$(xcrun simctl list devices | grep "$udid" || true)"  # a variable, not grep -q in a pipe: SIGPIPE + pipefail
if [ "${sim_line#*Booted}" = "$sim_line" ]; then
  xcrun simctl boot "$udid" && booted_by_us=1
  xcrun simctl bootstatus "$udid" -b >/dev/null
fi
xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"

out="$work/app.out"
xcrun simctl launch --console "$udid" "$BUNDLE_ID" "${launch_args[@]}" >"$out" 2>&1 &
launcher_pid=$!
waited=0
until grep -q '^FMSelfCheck: ' "$out" 2>/dev/null || [ "$waited" -ge "$SMOKE_TIMEOUT" ]; do sleep 1; waited=$((waited + 1)); done
line="$(grep '^FMSelfCheck: ' "$out" | head -1 || true)"
[ -n "$line" ] || die "smoke: the app printed no FMSelfCheck line within ${SMOKE_TIMEOUT}s (did it launch? output: $(head -c 400 "$out"))"
case "$line" in "FMSelfCheck: ok $BUNDLE_ID "*) ;; *) die "smoke: self-check failed: $line" ;; esac
echo "smoke: self-check ok ($line)"

if [ -n "${SMOKE_RESULT:-}" ]; then
  jq -n --arg commit "$short" --arg line "$line" '{selfCheckPassed: true, commit: $commit, selfCheckLine: $line}' >"$SMOKE_RESULT"
fi
