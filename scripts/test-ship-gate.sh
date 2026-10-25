#!/usr/bin/env bash
# Unit test for scripts/ship-gate.sh and scripts/install.sh (make check): the gate refuses before it builds anything when
# an fm/* branch is unmerged, HEAD is not the integrated branch head, the tree is dirty or the smoke step fails; a pass
# writes build/ship-pass/<sha>.json; `make stable-install` refuses without a pass file for HEAD and proceeds with one,
# `make beta` needs none (xcodebuild and devicectl stubbed on PATH; `make check` and smoke.sh stubbed in the sandbox).
# The full smoke run is `make ship-gate` itself. Runs in a throwaway git copy of this working tree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/.." && pwd)"
fail() { echo "ship-gate test FAILED: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
(cd "$src" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
  [ -e "$f" ] || continue
  mkdir -p "$repo/$(dirname "$f")" && cp -p "$f" "$repo/$f"
done)
rm -f "$repo/Config/Local.xcconfig" "$repo/Config/Version.xcconfig"
# The sandbox replaces the two slow steps: `make check` (a no-op) and smoke.sh (writes the result file the contract asks for).
sed -i '' 's/^check: .*/check:/' "$repo/Makefile"
cat >"$repo/scripts/smoke.sh" <<'SMOKE'
#!/usr/bin/env bash
[ -z "${SMOKE_STUB_FAIL:-}" ] || exit 1
[ -n "${SMOKE_STUB_SILENT:-}" ] || echo '{"selfCheckPassed": true, "commit": "stub"}' >"$SMOKE_RESULT"
SMOKE
git -C "$repo" init -q -b main
(cd "$src" && git ls-files -co --exclude-standard -z) | (cd "$repo" && xargs -0 git add --)
g() { git -C "$repo" -c user.name=t -c user.email=t@example.com "$@"; }
g commit -q -m "chore: base" --no-verify
echo more >"$repo/extra.txt"; g add -- extra.txt; g commit -q -m "chore: tip" --no-verify
head_sha="$(g rev-parse HEAD)"
gate() { SHIP_BRANCH="${BRANCH:-main}" SHIP_PASS_DIR="$tmp/pass" "$repo/scripts/ship-gate.sh" 2>&1; }  # ignores the caller's SHIP_BRANCH

g branch fm/unlanded; g checkout -q fm/unlanded; echo w >"$repo/w.txt"; g add -- w.txt; g commit -q -m "feat: unlanded" --no-verify; g checkout -q main
out="$(gate)" && fail "accepted an unmerged fm/* branch"
grep -q "fm/unlanded ahead=1" <<<"$out" || fail "wrong refusal for an unmerged branch: $out"
g branch -q -D fm/unlanded
out="$(BRANCH=nope gate)" && fail "accepted a branch that does not exist"
grep -q "does not exist" <<<"$out" || fail "wrong refusal for a missing branch: $out"
g checkout -q --detach HEAD~1
out="$(gate)" && fail "accepted a HEAD that is not the branch head"
grep -q "is not the head of main" <<<"$out" || fail "wrong refusal for a stale HEAD: $out"
g checkout -q main
echo dirty >>"$repo/extra.txt"
out="$(gate)" && fail "accepted a dirty tree"
grep -q "not clean" <<<"$out" || fail "wrong refusal for a dirty tree: $out"
echo untracked >"$repo/new.txt"
g checkout -q -- extra.txt
out="$(gate)" && fail "accepted an untracked file"
grep -q "not clean" <<<"$out" || fail "wrong refusal for an untracked file: $out"
rm -f "$repo/new.txt"
[ ! -e "$tmp/pass" ] || fail "a refused gate wrote a pass file"

out="$(SMOKE_STUB_FAIL=1 gate)" && fail "gate passed with a failing smoke"
grep -qF "smoke test failed" <<<"$out" || fail "failing smoke not reported: $out"
out="$(SMOKE_STUB_SILENT=1 gate)" && fail "gate passed with a smoke that wrote no result"
grep -qF "selfCheckPassed" <<<"$out" || fail "silent smoke not reported: $out"
[ ! -e "$tmp/pass/$head_sha.json" ] || fail "pass file written by a failing smoke"

out="$(gate)" || fail "gate failed on a good tree: $out"
pass="$tmp/pass/$head_sha.json"
[ -f "$pass" ] || fail "no pass file at $pass"
jq -e --arg c "$head_sha" '.commit == $c and (.short | length) >= 7 and .branch == "main" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\+[0-9]+$"))
  and (.passed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and .checks == ["head-is-branch-tip","tree-clean","make-check","smoke-built-app"]
  and .smoke.selfCheckPassed == true' "$pass" >/dev/null || fail "pass file has the wrong shape: $(cat "$pass")"
[ -z "$(g status --porcelain)" ] || fail "the gate left the tree dirty"

# make stable-install / make beta (scripts/install.sh): xcodebuild "builds" an empty .app, xcrun records devicectl calls.
stubs="$tmp/stubs"; mkdir -p "$stubs"
cat >"$stubs/xcodebuild" <<'STUB'
#!/usr/bin/env bash
dd="" cfg=""
while [ $# -gt 0 ]; do
  case "$1" in -derivedDataPath) dd="$2"; shift ;; -configuration) cfg="$2"; shift ;; esac
  shift
done
name="PocketPalette"; [ "$cfg" != Beta ] || name="PocketPalette β"
mkdir -p "$dd/Build/Products/$cfg-iphoneos/$name.app"
STUB
cat >"$stubs/xcrun" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_XCRUN_LOG"
STUB
chmod +x "$stubs"/*
export STUB_XCRUN_LOG="$tmp/xcrun.log" INSTALL_LEDGER="$tmp/ledger.tsv" DEVICE_ID=FAKE-DEVICE DEVELOPMENT_TEAM=ABCDE12345
: >"$STUB_XCRUN_LOG"
inst() { (cd "$repo" && PATH="$stubs:$PATH" "$@" 2>&1); }

if out="$(inst make stable-install LEDGER="$INSTALL_LEDGER")"; then fail "stable-install ran without a pass file"; fi
grep -qF "no ship-gate pass" <<<"$out" || fail "stable-install refusal unclear: $out"
[ ! -s "$STUB_XCRUN_LOG" ] && [ ! -e "$INSTALL_LEDGER" ] || fail "stable-install touched the device or the ledger without a pass"

mkdir -p "$repo/build/ship-pass"   # build/ is gitignored, so the pass file leaves the tree clean
cp "$pass" "$repo/build/ship-pass/$head_sha.json"
inst make stable-install LEDGER="$INSTALL_LEDGER" >/dev/null || fail "stable-install failed with a valid pass"
grep -q 'devicectl device install app --device FAKE-DEVICE .*/Release-iphoneos/PocketPalette.app' "$STUB_XCRUN_LOG" \
  || fail "devicectl not called as expected: $(cat "$STUB_XCRUN_LOG")"
IFS=$'\t' read -r when dev bundle commit _ gatepass <"$INSTALL_LEDGER"
[ "$dev" = FAKE-DEVICE ] && [ "$bundle" = com.trillium.pocketpalette ] && [ "$commit" = "$(g rev-parse --short HEAD)" ] \
  && [ "$gatepass" = yes ] && [[ "$when" == 20*Z ]] || fail "ledger line wrong: $(cat "$INSTALL_LEDGER")"

echo more >>"$repo/extra.txt"; g commit -q -am "chore: newer" --no-verify   # a pass for an older commit does not count
if out="$(inst make stable-install LEDGER="$INSTALL_LEDGER")"; then fail "stable-install accepted a pass for an older commit"; fi
grep -qF "no ship-gate pass" <<<"$out" || fail "stale pass not refused clearly: $out"
cp "$pass" "$repo/build/ship-pass/$(g rev-parse HEAD).json"   # right file name, wrong commit inside
if inst make stable-install LEDGER="$INSTALL_LEDGER" >/dev/null; then fail "stable-install accepted a pass naming another commit"; fi
[ "$(wc -l <"$INSTALL_LEDGER" | tr -d ' ')" = 1 ] || fail "refused installs must not reach the ledger"

: >"$STUB_XCRUN_LOG"   # beta needs no pass, installs the .beta bundle and records gate pass: no
rm -f "$repo"/build/ship-pass/*.json
inst make beta LEDGER="$INSTALL_LEDGER" >/dev/null || fail "make beta failed"
grep -q 'devicectl device install app --device FAKE-DEVICE .*/Beta-iphoneos/PocketPalette β.app' "$STUB_XCRUN_LOG" \
  || fail "beta devicectl call wrong: $(cat "$STUB_XCRUN_LOG")"
IFS=$'\t' read -r _ _ bundle _ _ gatepass < <(tail -1 "$INSTALL_LEDGER")
[ "$bundle" = com.trillium.pocketpalette.beta ] && [ "$gatepass" = no ] || fail "beta ledger line wrong: $(tail -1 "$INSTALL_LEDGER")"
if out="$(inst env -u DEVICE_ID make beta LEDGER="$INSTALL_LEDGER")"; then fail "make beta ran without a device"; fi
grep -qF "no device" <<<"$out" || fail "missing device not explained: $out"
echo "ship-gate test ok"
