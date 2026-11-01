#!/usr/bin/env bash
# Unit test for ota.sh publishing (make test): xcodegen/xcodebuild are stubbed, OTA_DIR is a temp dir,
# OTA_BASE_URL is set so no tailscale call is made (port of talon-palette-ios scripts/test-ota.sh). Never signs, builds or serves anything.
# ota.sh runs from a throwaway git copy of this working tree, so its "HEAD + clean tree + ship-gate pass" checks are real.
set -euo pipefail
export SIGN_EXEC=  # tests never sign: keep the PATH stubs, not ios-sign-exec
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/.." && pwd)"
fail() { echo "ota test FAILED: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
(cd "$src" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
  [ -e "$f" ] || continue
  mkdir -p "$repo/$(dirname "$f")" && cp -p "$f" "$repo/$f"
done)
git -C "$repo" init -q
(cd "$src" && git ls-files -co --exclude-standard -z) | (cd "$repo" && xargs -0 git add --)
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m "chore: test fixture" --no-verify
sha="$(git -C "$repo" rev-parse HEAD)"
short="$(git -C "$repo" rev-parse --short HEAD)"

mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/xcodegen"
cat >"$tmp/bin/xcodebuild" <<'EOF2'
#!/bin/bash
# Stub: records every call; on -exportArchive copies the options plist and drops a fake .ipa that has a real
# Payload layout (Info.plist with the bundle id and the archived build number, plus an extension) so ota.sh can look inside it.
echo "$*" >>"$OTA_TEST_LOG"
while [ $# -gt 0 ]; do
  case "$1" in
    -archivePath) arch="$2"; shift ;;
    CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
    archive) is_archive=1 ;;
    -exportPath) exp="$2"; shift ;;
    -exportOptionsPlist) cp "$2" "$OTA_TEST_LOG.options.plist"; shift ;;
  esac
  shift
done
[ -z "${is_archive:-}" ] || echo "$build" >"$OTA_TEST_LOG.build"
build="$(cat "$OTA_TEST_LOG.build" 2>/dev/null || true)"
if [ -n "${is_archive:-}" ] && [ -n "${arch:-}" ]; then
  app="$arch/Products/Applications/PocketPalette.app"
  mkdir -p "$app/PlugIns/Widget.appex"
  plutil -create xml1 "$app/Info.plist"
  plutil -insert CFBundleIdentifier -string "com.trillium.pocketpalette" "$app/Info.plist"
  plutil -insert CFBundleVersion -string "$build" "$app/Info.plist"
  echo x >"$app/PlugIns/Widget.appex/Info.plist"
fi
if [ -n "${exp:-}" ]; then
  mkdir -p "$exp" "$exp/stage/Payload/PocketPalette.app/PlugIns/Widget.appex"
  plutil -create xml1 "$exp/stage/Payload/PocketPalette.app/Info.plist"
  plutil -insert CFBundleIdentifier -string "com.trillium.pocketpalette" "$exp/stage/Payload/PocketPalette.app/Info.plist"
  plutil -insert CFBundleVersion -string "${OTA_TEST_BUILD:-$build}" "$exp/stage/Payload/PocketPalette.app/Info.plist"
  echo x >"$exp/stage/Payload/PocketPalette.app/PlugIns/Widget.appex/Info.plist"
  [ -z "${OTA_TEST_NO_EXTENSION:-}" ] || rm -rf "$exp/stage/Payload/PocketPalette.app/PlugIns"
  (cd "$exp/stage" && zip -q -r "$exp/PocketPalette.ipa" Payload)
fi
EOF2
chmod +x "$tmp/bin/"*
export OTA_TEST_LOG="$tmp/xcodebuild.log"
export SHIP_PASS_DIR="$tmp/pass"
ota() { PATH="$tmp/bin:$PATH" DEVELOPMENT_TEAM="${TEAM:-85PWBA3B59}" OTA_DIR="$tmp/ota" "$repo/scripts/ota.sh"; }
pass() { mkdir -p "$SHIP_PASS_DIR"; printf '{"commit":"%s","passed_at":"2026-01-01T00:00:00Z"}\n' "${1:-$sha}" >"$SHIP_PASS_DIR/$sha.json"; }

base=https://mac.tail0.ts.net:8782
if OTA_BASE_URL=http://insecure.example ota >/dev/null 2>&1; then fail "accepted a non-https OTA_BASE_URL"; fi
# runbooks-c62: one team. The export options and the archive must agree on it.
if TEAM=ABCDE12345 OTA_BASE_URL=https://x.example ota >/dev/null 2>&1; then fail "accepted a team that differs from exportOptions.plist"; fi

# The ship gate comes first: no pass file, a pass file for another commit, or a changed tree publishes nothing.
if OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "published without a ship-gate pass"; fi
pass "0000000000000000000000000000000000000000"
if OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "published with a pass file for another commit"; fi
pass
echo changed >>"$repo/README.md"
if OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "published a tree that changed after the gate"; fi
git -C "$repo" checkout -q README.md
[ ! -e "$tmp/ota" ] || fail "a refused publish touched OTA_DIR"
[ ! -s "$OTA_TEST_LOG" ] || fail "a refused publish ran xcodebuild"

# A build that is not what the gate vetted is refused before it replaces anything.
if OTA_TEST_BUILD=1 OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "published an .ipa that is not the archived build"; fi
if OTA_TEST_NO_EXTENSION=1 OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "published an .ipa with no widget"; fi
[ ! -e "$tmp/ota/index.html" ] || fail "a refused .ipa still published a page"

out="$(OTA_BASE_URL="$base//" ota)"
for f in PocketPalette.ipa manifest.plist index.html; do [ -f "$tmp/ota/$f" ] || fail "$f not published"; done
plutil -lint -s "$tmp/ota/manifest.plist" || fail "manifest.plist is not a valid plist"
m() { /usr/libexec/PlistBuddy -c "Print :items:0:$1" "$tmp/ota/manifest.plist"; }
[ "$(m assets:0:url)" = "$base/PocketPalette.ipa" ] || fail "ipa url: $(m assets:0:url)"
[ "$(m metadata:bundle-identifier)" = com.trillium.pocketpalette ] || fail "bundle id: $(m metadata:bundle-identifier)"
ver="$(m metadata:bundle-version)"
grep -q "CURRENT_PROJECT_VERSION=$ver" "$OTA_TEST_LOG" || fail "manifest version $ver was not the archived build number"
[ -f "$tmp/ota/builds/$ver/PocketPalette.ipa" ] && [ -f "$tmp/ota/builds/$ver/meta.json" ] || fail "build $ver not kept under builds/"
[ "$(jq -r .commit "$tmp/ota/builds/$ver/meta.json")" = "$sha" ] || fail "meta.json does not name the commit"
link_raw='itms-services://?action=download-manifest&url=https%3A%2F%2Fmac.tail0.ts.net%3A8782%2Fbuilds%2F'"$ver"'%2Fmanifest.plist'
grep -qF "href=\"${link_raw//&/&amp;}\"" "$tmp/ota/index.html" || grep -qF "href=\"$link_raw\"" "$tmp/ota/index.html" \
  || fail "install link wrong in index.html: $(grep -o 'href="[^"]*"' "$tmp/ota/index.html")"
grep -qF "install link: itms-services://?action=download-manifest&url=https%3A%2F%2Fmac.tail0.ts.net%3A8782%2Fmanifest.plist" <<<"$out" \
  || fail "install link not printed: $out"
o() { /usr/libexec/PlistBuddy -c "Print :$1" "$OTA_TEST_LOG.options.plist"; }
[ "$(o teamID)" = 85PWBA3B59 ] || fail "export teamID: $(o teamID)"
[ "$(o method)" = ad-hoc ] || fail "export method: $(o method)"
grep -q -- '-allowProvisioningUpdates -allowProvisioningDeviceRegistration' "$OTA_TEST_LOG" || fail "archive without provisioning flags"
grep -q 'DEVELOPMENT_TEAM=85PWBA3B59' "$OTA_TEST_LOG" || fail "archive not pinned to DEVELOPMENT_TEAM"
grep -qF "version $("$repo/scripts/version.sh" --full) ($short)" "$tmp/ota/index.html" || fail "install page does not show version and commit: $(grep version "$tmp/ota/index.html")"
grep -q "No earlier working build" "$tmp/ota/index.html" || fail "first publish should have an empty rollback list"

# OTA_EXPORT=archive packages the archive's own app (no Xcode account needed); codesign is stubbed here.
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/codesign"; chmod +x "$tmp/bin/codesign"
OTA_EXPORT=archive OTA_BASE_URL="$base" ota >/dev/null
listing="$(unzip -l "$tmp/ota/PocketPalette.ipa")"; grep -q "PlugIns/Widget.appex" <<<"$listing" || fail "archive-packaged .ipa lacks the widget: $listing"
if OTA_EXPORT=bogus OTA_BASE_URL="$base" ota >/dev/null 2>&1; then fail "accepted an unknown OTA_EXPORT"; fi
rm -f "$tmp/bin/codesign"

# Rollback list: every earlier passed build stays installable; only the last three previous ones are kept.
for _ in 1 2 3 4; do sleep 1; OTA_BASE_URL="$base" ota >/dev/null; done
builds="$(find "$tmp/ota/builds" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "$builds" = 4 ] || fail "expected the current build plus 3 previous, found $builds"
[ "$(grep -c 'Rollback to this build' "$tmp/ota/index.html")" = 3 ] || fail "rollback list should have 3 entries"
newest="$(find "$tmp/ota/builds" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"; newest="${newest##*/}"
grep -q "build $newest" "$tmp/ota/index.html" || fail "page does not show the newest build"
! grep -q "$ver" "$tmp/ota/index.html" || fail "pruned build $ver still listed"
# A build with no pass flag in meta.json is never listed, even if its files are on disk.
mkdir -p "$tmp/ota/builds/99999999999999"
cp "$tmp/ota/builds/$newest/manifest.plist" "$tmp/ota/builds/99999999999999/"
echo '{"id":"99999999999999","version":"x","short":"x","passed_at":"x","pass":false}' >"$tmp/ota/builds/99999999999999/meta.json"
python3 "$repo/scripts/ota-page.py" --dir "$tmp/ota" --base "$base" --title t --template "$repo/ota/index.html.template" >/dev/null
! grep -q 99999999999999 "$tmp/ota/index.html" || fail "an unpassed build was listed"
echo "ota test ok"
