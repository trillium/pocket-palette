#!/usr/bin/env bash
# Unit test for scripts/phone-session.sh (make test): xcrun is a stub on PATH that keeps the "phone" in files, HOME,
# the ledger and OTA_DIR are temporary. Covers the lock, the restore check, the unreachable marker and its retry,
# status propagation and the timeout.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ps_sh="$here/phone-session.sh"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"
fail() { echo "phone-session test FAILED: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -z "${holder:-}" ] || kill "$holder" 2>/dev/null || true' EXIT

export HOME="$tmp/home" DEVICE_ID=FAKE-DEVICE
mkdir -p "$HOME"
phone="$tmp/phone"; stubs="$tmp/stubs"; mkdir -p "$phone" "$stubs"
export STUB_PHONE="$phone" OTA_DIR="$tmp/ota" INSTALL_LEDGER="$tmp/ledger.tsv" PHONE_SESSION_TIMEOUT=30m
lock="$HOME/.fm-phone-lock"; marker="$HOME/.fm-phone-restore-pending"
stable_id="$BUNDLE_ID"; beta_id="$BETA_BUNDLE_ID"; export stable_id beta_id

# The stub phone: stable/beta hold the installed bundleVersion (absent = not installed), offline makes devicectl fail,
# install.log records installs. An .ipa "contains" the build number it installs.
cat >"$stubs/xcrun" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "devicectl device" ] || exit 64
[ ! -e "$STUB_PHONE/offline" ] || { echo "device is locked" >&2; exit 1; }
case "$3" in
  info)
    out=""; while [ $# -gt 0 ]; do [ "$1" != --json-output ] || out="$2"; shift; done
    apps=""
    for a in "stable:$stable_id" "beta:$beta_id"; do
      [ -f "$STUB_PHONE/${a%%:*}" ] || continue
      apps="$apps${apps:+,}{\"bundleIdentifier\":\"${a#*:}\",\"version\":\"0.1.0\",\"bundleVersion\":\"$(cat "$STUB_PHONE/${a%%:*}")\"}"
    done
    echo "{\"result\":{\"apps\":[$apps]}}" >"$out" ;;
  install)
    last="${*: -1}"; echo "$*" >>"$STUB_PHONE/install.log"
    case "$last" in *.ipa) cp "$last" "$STUB_PHONE/stable" ;; *) echo beta-install >"$STUB_PHONE/beta" ;; esac ;;
esac
STUB
chmod +x "$stubs/xcrun"
export PATH="$stubs:$PATH"

# Known good: commit abc1234, build 1, gate pass; the kept OTA artifact for it has build 20261024000000.
good_build=20261024000000
mkdir -p "$OTA_DIR/builds/$good_build" "$OTA_DIR/builds/20261020000000"
echo "$good_build" >"$OTA_DIR/builds/$good_build/$APP_NAME.ipa"
jq -n --arg id "$good_build" '{id: $id, version: "0.1.0", short: "abc1234", commit: "abc1234ffffffffffffffffffffffffffffffff", pass: true}' \
  >"$OTA_DIR/builds/$good_build/meta.json"
echo 1 >"$OTA_DIR/builds/20261020000000/$APP_NAME.ipa"
jq -n '{id: "20261020000000", version: "0.1.0", short: "old0000", commit: "old0000fffffffffffffffffffffffffffffffff", pass: true}' \
  >"$OTA_DIR/builds/20261020000000/meta.json"
reset_ledger() {
  printf '2026-10-20T00:00:00Z\tFAKE-DEVICE\t%s\told0000\t1\tyes\n2026-10-24T00:00:00Z\tFAKE-DEVICE\t%s\tabc1234\t1\tyes\n' \
    "$stable_id" "$stable_id" >"$INSTALL_LEDGER"
  printf '2026-10-25T00:00:00Z\tFAKE-DEVICE\t%s\tbad9999\t5\tno\n2026-10-25T00:00:01Z\tFAKE-DEVICE\t%s\tabc1234\t9\tyes\n' \
    "$stable_id" "$beta_id" >>"$INSTALL_LEDGER"
}
reset_phone() { rm -rf "$phone" "$lock" "$marker"; mkdir -p "$phone"; echo 1 >"$phone/stable"; echo 7 >"$phone/beta"; reset_ledger; }
run() { "$ps_sh" "$@" 2>&1; }  # merged output, caller reads $?
installs() { [ -f "$phone/install.log" ] && wc -l <"$phone/install.log" | tr -d ' ' || echo 0; }

# 1. lock taken for the command and released afterwards; stable unchanged -> no install
reset_phone
out="$(run bash -c 'echo "held by $(cat '"$lock"'/pid)" ; cat '"$lock"'/command >&2')" || fail "plain session failed: $out"
grep -q "held by [0-9]" <<<"$out" || fail "lock was not held while the command ran: $out"
grep -q "bash -c" <<<"$out" || fail "lock does not record the command: $out"
[ ! -e "$lock" ] || fail "lock not released"
[ "$(installs)" = 0 ] || fail "installed although stable was unchanged"
grep -q "no restore needed" <<<"$out" || fail "no restore message: $out"
[ ! -e "$marker" ] || fail "marker written on a clean session"
grep -q "installed before: .*$stable_id 0.1.0 (1)" <<<"$out" || fail "apps were not recorded before the run: $out"

# 2. stale lock (dead pid) is reported and reclaimed; the stable app is checked first
reset_phone
mkdir "$lock"; echo 999999 >"$lock/pid"; date +%s >"$lock/started"; echo old >"$lock/command"
out="$(run true)" || fail "stale lock blocked the wrapper: $out"
grep -q "reclaiming stale" <<<"$out" || fail "stale lock not reported: $out"
[ ! -e "$lock" ] || fail "lock not released after reclaim"
# 2b. a live holder older than the timeout is reclaimed too
sleep 30 & holder=$!
mkdir "$lock"; echo "$holder" >"$lock/pid"; echo $(( $(date +%s) - 4000 )) >"$lock/started"; echo slow >"$lock/command"
out="$(run true)" || fail "over-age lock blocked the wrapper: $out"
grep -q "longer than the" <<<"$out" || fail "over-age lock not reported: $out"
kill "$holder"; holder=""

# 3. live lock refused with who holds it; the command does not run
reset_phone
sleep 30 & holder=$!
mkdir "$lock"; echo "$holder" >"$lock/pid"; date +%s >"$lock/started"; echo "make beta" >"$lock/command"
if out="$(run touch "$tmp/ran")"; then fail "live lock was not refused"; fi
grep -q "held by pid $holder, running 'make beta'" <<<"$out" || fail "refusal does not say who holds the lock: $out"
[ ! -e "$tmp/ran" ] || fail "command ran under a live lock"
[ -d "$lock" ] && [ "$(cat "$lock/pid")" = "$holder" ] || fail "a refused wrapper disturbed the holder's lock"
kill "$holder"; holder=""

# 4. stable replaced during the session -> known good reinstalled and verified; beta untouched; ledger line
reset_phone
out="$(run bash -c "echo 99 >'$phone/stable'")" || fail "restore session failed: $out"
[ "$(cat "$phone/stable")" = "$good_build" ] || fail "stable not restored: $(cat "$phone/stable")"
[ "$(installs)" = 1 ] || fail "wrong install count: $(cat "$phone/install.log")"
grep -q "$OTA_DIR/builds/$good_build/$APP_NAME.ipa" "$phone/install.log" || fail "wrong install: $(cat "$phone/install.log")"
[ "$(cat "$phone/beta")" = 7 ] || fail "beta was touched"
grep -q "restored stable" <<<"$out" || fail "no restore message: $out"
last="$(tail -1 "$INSTALL_LEDGER")"
IFS=$'\t' read -r when dev bundle commit build gate note <<<"$last"
[ "$dev" = FAKE-DEVICE ] && [ "$bundle" = "$stable_id" ] && [ "$commit" = abc1234 ] && [ "$build" = "$good_build" ] \
  && [ "$gate" = yes ] && [ "$note" = restore ] && [[ "$when" == 20*Z ]] || fail "restore ledger line wrong: $last"
[ ! -e "$lock" ] && [ ! -e "$marker" ] || fail "lock or marker left behind"
# the restored build is now the known good one: a second session is clean
out="$(run true)" || fail "second session failed: $out"
[ "$(installs)" = 1 ] || fail "reinstalled a build that was already the known good"

# 4b. stable removed entirely is restored too; an installed beta is not a stable app
reset_phone; rm "$phone/stable"
run true >/dev/null || fail "restore of a missing stable failed"
[ "$(cat "$phone/stable")" = "$good_build" ] && [ "$(cat "$phone/beta")" = 7 ] || fail "missing stable not restored cleanly"

# 5. no kept artifact for the known-good commit: say so, install nothing, fail
reset_phone; rm -rf "$OTA_DIR/builds/$good_build"
if out="$(run bash -c "echo 99 >'$phone/stable'")"; then fail "unrestorable stable exited 0"; fi
grep -q "no kept ship-gated artifact for known-good commit abc1234" <<<"$out" || fail "no plain message for the missing artifact: $out"
[ "$(installs)" = 0 ] && [ "$(cat "$phone/stable")" = 99 ] || fail "installed something without an artifact"
[ ! -e "$lock" ] || fail "lock left behind"
mkdir -p "$OTA_DIR/builds/$good_build"; echo "$good_build" >"$OTA_DIR/builds/$good_build/$APP_NAME.ipa"
jq -n --arg id "$good_build" '{id: $id, version: "0.1.0", short: "abc1234", commit: "abc1234ffffffffffffffffffffffffffffffff", pass: true}' \
  >"$OTA_DIR/builds/$good_build/meta.json"

# 6. phone locked/offline after the session: one plain sentence, marker, non-zero, lock released
reset_phone
if out="$(run bash -c "echo 99 >'$phone/stable'; touch '$phone/offline'")"; then fail "unreachable phone exited 0"; fi
[ "$(grep -c 'phone is locked or offline; stable app could not be verified or restored, will retry' <<<"$out")" = 1 ] \
  || fail "plain unreachable sentence missing or repeated: $out"
[ -f "$marker" ] || fail "no marker"
for want in "bundle_id=$stable_id" known_good_commit=abc1234 known_good_build=1 device=FAKE-DEVICE; do
  grep -qx "$want" "$marker" || fail "marker lacks $want: $(cat "$marker")"
done
grep -q '^time=20' "$marker" || fail "marker has no time"
[ ! -e "$lock" ] || fail "lock left behind after an unreachable phone"
[ "$(installs)" = 0 ] || fail "installed on an unreachable phone"

# 7. marker present: the restore is retried before the command runs
rm "$phone/offline"
out="$(run bash -c "cp '$phone/stable' '$tmp/stable-at-command-start'")" || fail "retry session failed: $out"
grep -q "restore pending" <<<"$out" || fail "retry not announced: $out"
[ "$(cat "$tmp/stable-at-command-start")" = "$good_build" ] || fail "command ran before the restore"
[ ! -e "$marker" ] || fail "marker not cleared after a successful retry"
# 7b. marker present and still unreachable: the command is not run
touch "$phone/offline"; echo "bundle_id=$stable_id" >"$marker"
if out="$(run touch "$tmp/ran-offline")"; then fail "ran a command with the stable app unverified"; fi
[ ! -e "$tmp/ran-offline" ] && [ -e "$marker" ] && [ ! -e "$lock" ] || fail "offline retry mishandled"
rm "$phone/offline" "$marker"

# 8. the command's own status is the wrapper's status
reset_phone
run bash -c 'exit 7' >/dev/null && fail "status 7 became 0"
run bash -c 'exit 7' >/dev/null || rc=$?
[ "${rc:-}" = 7 ] || fail "command status 7 not propagated (got ${rc:-0})"
[ ! -e "$lock" ] || fail "lock left behind after a failing command"

# 9. timeout: the command and its children die, stable is still restored, lock released, status 124
reset_phone
start=$(date +%s)
if out="$(PHONE_SESSION_TIMEOUT=1 run bash -c "echo 99 >'$phone/stable'; sleep 3171 & sleep 3171")"; then rc=0; else rc=$?; fi
[ "$rc" = 124 ] || fail "timeout status $rc, want 124: $out"
[ $(( $(date +%s) - start )) -lt 15 ] || fail "the command was not killed at the timeout"
grep -q "exceeded PHONE_SESSION_TIMEOUT" <<<"$out" || fail "timeout not reported: $out"
[ "$(cat "$phone/stable")" = "$good_build" ] || fail "stable not restored after a timeout"
[ ! -e "$lock" ] || fail "lock left behind after a timeout"
sleep 0.5; ! pgrep -f "sleep 3171" >/dev/null || fail "the timed-out command left a child running"

# 10. TERM/INT to the wrapper: the command is stopped and stable restored
reset_phone
"$ps_sh" bash -c "echo 99 >'$phone/stable'; sleep 3171" >"$tmp/term.out" 2>&1 & wpid=$!
for _ in $(seq 1 50); do [ -f "$lock/pid" ] && [ "$(cat "$phone/stable")" = 99 ] && break; sleep 0.1; done
kill -TERM "$wpid"; wait "$wpid" && rc=0 || rc=$?
[ "$rc" = 143 ] || fail "TERM status $rc, want 143: $(cat "$tmp/term.out")"
[ "$(cat "$phone/stable")" = "$good_build" ] && [ ! -e "$lock" ] || fail "TERM did not restore and release"
sleep 0.5; ! pgrep -f "sleep 3171" >/dev/null || fail "TERM left the command running"

# 11. no command is refused before anything is touched
if out="$("$ps_sh" 2>&1)"; then fail "no command accepted"; fi
[ ! -e "$lock" ] || fail "usage error took the lock"

echo "phone-session test passed"
