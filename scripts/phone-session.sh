#!/usr/bin/env bash
# make phone-session CMD='...': the one wrapper every device session goes through (runbooks-84o rule 5).
#   phone-session.sh <command...>
# Takes the phone lock (mkdir $PHONE_LOCK, default ~/.fm-phone-lock, holding pid, start time and command), records the
# installed apps (xcrun devicectl device info apps), runs the command under a watchdog (PHONE_SESSION_TIMEOUT, default
# 30m, plain seconds or Ns/Nm/Nh), and on exit, INT, TERM or timeout restores the stable app: if the installed stable
# build differs from the last known good one, the kept ship-gated artifact is reinstalled and verified. Beta is never
# touched. The lock is always released and the exit status is the command's (124 on timeout).
#   Last known good = newest INSTALL_LEDGER line for the stable bundle id with gate pass yes. Its artifact is the kept
#   ship-gated OTA build (OTA_DIR/builds/<id>/, meta.json pass true, same commit); with none, nothing is installed.
#   Phone locked/offline: one plain sentence, ~/.fm-phone-restore-pending (PHONE_RESTORE_MARKER) is written for the audit,
#   exit non-zero; the next run with the marker present retries the restore before anything else.
# Device: DEVICE_ID from the environment or Config/Local.xcconfig. Never uploads anything. Bash 3.2 compatible.
# shellcheck disable=SC2329  # the trap handlers are reached by signal, not by name
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -gt 0 ] || { echo "usage: phone-session.sh <command...>   (or: make phone-session CMD='...')" >&2; exit 2; }
for t in jq xcrun; do require_tool "$t" "needed by make phone-session"; done

LOCK="${PHONE_LOCK:-$HOME/.fm-phone-lock}"
MARKER="${PHONE_RESTORE_MARKER:-$HOME/.fm-phone-restore-pending}"
OTA_DIR="${OTA_DIR:-$HOME/ota/$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')}"
device="$(cfg DEVICE_ID)"
[ -n "$device" ] || die "no device: set DEVICE_ID (env or Config/Local.xcconfig); list devices with 'xcrun devicectl list devices'"

timeout_s="${PHONE_SESSION_TIMEOUT:-30m}"
case "$timeout_s" in
  *h) timeout_s=$(( ${timeout_s%h} * 3600 )) ;;
  *m) timeout_s=$(( ${timeout_s%m} * 60 )) ;;
  *s) timeout_s=${timeout_s%s} ;;
esac
case "$timeout_s" in ''|*[!0-9]*) die "PHONE_SESSION_TIMEOUT must be seconds or Ns/Nm/Nh" ;; esac

say() { echo "phone-session: $*" >&2; }
now() { date +%s; }

# --- lock ---------------------------------------------------------------------------------------------------
reclaimed=0
acquire_lock() {
  local tries=0 pid started age holder
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -le 5 ] || die "cannot take the phone lock $LOCK"
    pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    started="$(cat "$LOCK/started" 2>/dev/null || true)"
    holder="pid ${pid:-?}, running '$(cat "$LOCK/command" 2>/dev/null || echo '?')'"
    case "$started" in ''|*[!0-9]*) age=$((timeout_s + 1)) ;; *) age=$(( $(now) - started )) ;; esac
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$age" -le "$timeout_s" ]; then
      die "phone lock $LOCK is held by $holder (started ${age}s ago); refusing"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      say "reclaiming $LOCK: held by $holder for ${age}s, longer than the ${timeout_s}s timeout"
    else
      say "reclaiming stale $LOCK: holder $holder is gone"
    fi
    reclaimed=1
    # rename first: of two racing reclaimers only one rename succeeds
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then rm -rf "$LOCK.stale.$$"; fi
  done
  printf '%s\n' "$$" >"$LOCK/pid"; now >"$LOCK/started"; printf '%s\n' "$*" >"$LOCK/command"
}

# --- apps on the phone --------------------------------------------------------------------------------------
# list_apps FILE: JSON listing of the installed apps; non-zero when the phone cannot be reached.
list_apps() { xcrun devicectl device info apps --device "$device" --json-output "$1" >/dev/null 2>&1 && [ -s "$1" ]; }
# app_build FILE BUNDLE -> the installed bundleVersion ("" when the app is not installed)
app_build() { jq -r --arg b "$2" '[.result.apps[]? | select(.bundleIdentifier == $b) | .bundleVersion][0] // ""' "$1"; }
app_summary() { jq -r '[.result.apps[]? | "\(.bundleIdentifier) \(.version // "?") (\(.bundleVersion // "?"))"] | sort | join(", ")' "$1"; }

# --- restore ------------------------------------------------------------------------------------------------
restore_status=0   # non-zero when the stable app could not be verified or restored
write_marker() { # $1 commit $2 build
  { printf 'bundle_id=%s\n' "$BUNDLE_ID"; printf 'known_good_commit=%s\n' "$1"; printf 'known_good_build=%s\n' "$2"
    printf 'device=%s\n' "$device"; printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >"$MARKER"
}
unreachable() { # $1 commit $2 build
  say "phone is locked or offline; stable app could not be verified or restored, will retry"
  write_marker "$1" "$2"; restore_status=1
}

restore_stable() {
  restore_status=0
  local good commit="" build="" meta="" art="" art_id="" art_dir="" listing
  good="$(awk -F'\t' -v b="$BUNDLE_ID" '$3 == b && $6 == "yes" { l = $0 } END { print l }' "$INSTALL_LEDGER" 2>/dev/null || true)"
  if [ -z "$good" ]; then
    say "no known-good stable build in $INSTALL_LEDGER (no gate-pass line for $BUNDLE_ID); nothing to restore to"
    return
  fi
  IFS=$'\t' read -r _ _ _ commit build _ <<<"$good"
  for meta in "$OTA_DIR"/builds/*/meta.json; do
    [ -f "$meta" ] || continue
    if jq -e --arg c "$commit" '.pass == true and ((.short == $c) or (.commit | startswith($c)))' "$meta" >/dev/null 2>&1; then
      art_dir="$(dirname "$meta")"; art_id="$(jq -r .id "$meta")"
      [ -f "$art_dir/$APP_NAME.ipa" ] && art="$art_dir/$APP_NAME.ipa"
    fi
  done
  listing="$(mktemp "${TMPDIR:-/tmp}/phone-session-apps.XXXXXX")"
  if ! list_apps "$listing"; then rm -f "$listing"; unreachable "$commit" "$build"; return; fi
  local installed; installed="$(app_build "$listing" "$BUNDLE_ID")"
  if [ -n "$installed" ] && { [ "$installed" = "$build" ] || [ "$installed" = "$art_id" ]; }; then
    say "stable $BUNDLE_ID is the known-good build ($commit, build $installed); no restore needed"
    rm -f "$listing"; rm -f "$MARKER"; return
  fi
  say "stable $BUNDLE_ID is ${installed:+build $installed}${installed:-not installed}; known good is $commit (build $build)"
  if [ -z "$art" ]; then
    say "no kept ship-gated artifact for known-good commit $commit under $OTA_DIR/builds; nothing was installed, stable is NOT restored"
    rm -f "$listing"; restore_status=1; return
  fi
  say "reinstalling known-good $art"
  if ! xcrun devicectl device install app --device "$device" "$art" >&2; then
    rm -f "$listing"
    if list_apps "$listing"; then
      say "reinstall of the known-good stable build failed"; write_marker "$commit" "$build"; restore_status=1
    else unreachable "$commit" "$build"; fi
    rm -f "$listing"; return
  fi
  if ! list_apps "$listing"; then rm -f "$listing"; unreachable "$commit" "$build"; return; fi
  installed="$(app_build "$listing" "$BUNDLE_ID")"; rm -f "$listing"
  if [ "$installed" != "$art_id" ]; then
    say "verification failed: stable $BUNDLE_ID is ${installed:-missing} after the reinstall, expected build $art_id"
    write_marker "$commit" "$build"; restore_status=1; return
  fi
  mkdir -p "$(dirname "$INSTALL_LEDGER")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$device" "$BUNDLE_ID" "$(jq -r .short "$art_dir/meta.json")" \
    "$art_id" yes restore >>"$INSTALL_LEDGER"
  rm -f "$MARKER"
  say "restored stable $BUNDLE_ID to $commit (build $art_id) and verified it with devicectl device info apps"
}

# --- run ----------------------------------------------------------------------------------------------------
cmd_pid=""; wd_pid=""; cmd_status=0; locked=0; finished=0

kill_group() { # $1 pid: TERM the process group, then KILL what is left
  [ -n "$1" ] || return 0
  kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$1" 2>/dev/null || true
}

finish() {
  [ "$finished" = 0 ] || return 0
  finished=1
  [ -z "$wd_pid" ] || kill_group "$wd_pid"
  [ -z "$cmd_pid" ] || kill_group "$cmd_pid"
  if [ "$locked" = 1 ]; then
    restore_stable || true
    rm -rf "$LOCK"
  fi
}
on_signal() { # $1 signal name, $2 conventional exit status
  say "got $1; stopping the command and restoring"
  cmd_status=$2; finish; exit "$2"
}
on_exit() {
  local rc=$?
  [ "$cmd_status" = 0 ] || rc=$cmd_status
  finish
  [ "$rc" != 0 ] || rc=$restore_status
  exit "$rc"
}
trap on_exit EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

acquire_lock "$@"
locked=1

# A crashed earlier session (stale lock) or an unreachable phone (marker) means the stable app may be wrong: check first.
if [ -e "$MARKER" ] || [ "$reclaimed" = 1 ]; then
  [ ! -e "$MARKER" ] || say "restore pending from an earlier session ($MARKER); retrying it first"
  restore_stable
  if [ "$restore_status" != 0 ]; then
    say "not running the command: the stable app is not verified"
    cmd_status=$restore_status; exit "$restore_status"
  fi
fi

before="$(mktemp "${TMPDIR:-/tmp}/phone-session-before.XXXXXX")"
if list_apps "$before"; then say "installed before: $(app_summary "$before")"
else say "phone is locked or offline; could not record the installed apps before the command"; fi
rm -f "$before"

set -m
"$@" </dev/null &
cmd_pid=$!
( sleep "$timeout_s"; : >"$LOCK/timedout"; kill -TERM -- "-$cmd_pid" 2>/dev/null; sleep 2; kill -KILL -- "-$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
wd_pid=$!
set +m
wait "$cmd_pid" && cmd_status=0 || cmd_status=$?
if [ -e "$LOCK/timedout" ]; then say "command exceeded PHONE_SESSION_TIMEOUT (${timeout_s}s) and was killed"; cmd_status=124; fi
cmd_pid=""
exit "$cmd_status"
