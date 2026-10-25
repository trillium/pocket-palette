#!/usr/bin/env bash
# The beta flavour resolves the way the runbook needs (rule 1: two apps per product): distinct bundle ids, names, icons,
# App Group and URL scheme for the app AND its widget extension (the widget id stays a child of the app id, the beta
# widget shares the beta App Group), the BETA condition only on beta, same team and version. Needs xcodegen and xcodebuild
# (-showBuildSettings only: no build, no simulator, no Apple account). Runs in a throwaway copy of this working tree.
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-beta.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "beta test FAILED: $*" >&2; exit 1; }

(cd "$src" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
  [ -e "$f" ] || continue
  mkdir -p "$tmp/$(dirname "$f")" && cp -p "$f" "$tmp/$f"
done)
rm -f "$tmp/Config/Local.xcconfig"
(cd "$tmp" && xcodegen generate --quiet)

setting() { # setting SCHEME KEY: the app target as the scheme builds it
  (cd "$tmp" && xcodebuild -project PocketPalette.xcodeproj -scheme "$1" -showBuildSettings 2>/dev/null) \
    | sed -nE "s/^ +$2 = (.*)$/\1/p" | head -1
}
wsetting() { # wsetting CONFIGURATION KEY: the widget extension target
  (cd "$tmp" && xcodebuild -project PocketPalette.xcodeproj -target PocketPaletteWidget -configuration "$1" -showBuildSettings 2>/dev/null) \
    | sed -nE "s/^ +$2 = (.*)$/\1/p" | head -1
}
expect() { # expect SCHEME KEY VALUE
  local got; got="$(setting "$1" "$2")"
  [ "$got" = "$3" ] || fail "scheme '$1' $2: expected '$3', got '$got'"
}
wexpect() { # wexpect CONFIGURATION KEY VALUE
  local got; got="$(wsetting "$1" "$2")"
  [ "$got" = "$3" ] || fail "widget ($1) $2: expected '$3', got '$got'"
}

schemes="$(cd "$tmp" && xcodebuild -list -project PocketPalette.xcodeproj | sed -n '/Schemes:/,$p')"
grep -qx '[[:space:]]*PocketPalette' <<<"$schemes" || fail "stable scheme 'PocketPalette' missing"
grep -qx '[[:space:]]*PocketPalette Beta' <<<"$schemes" || fail "scheme 'PocketPalette Beta' missing"

stable="PocketPalette"; beta="PocketPalette Beta"
expect "$stable" PRODUCT_BUNDLE_IDENTIFIER com.trillium.pocketpalette
expect "$stable" APP_GROUP_ID group.com.trillium.pocketpalette
expect "$stable" PALETTE_URL_SCHEME pocketpalette
expect "$stable" DISPLAY_NAME PocketPalette
expect "$stable" ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
expect "$stable" CONFIGURATION Debug
if setting "$stable" SWIFT_ACTIVE_COMPILATION_CONDITIONS | grep -qw BETA; then fail "stable build has the BETA condition"; fi
wexpect Debug PRODUCT_BUNDLE_IDENTIFIER com.trillium.pocketpalette.widget
wexpect Debug APP_GROUP_ID group.com.trillium.pocketpalette

expect "$beta" PRODUCT_BUNDLE_IDENTIFIER com.trillium.pocketpalette.beta
expect "$beta" APP_GROUP_ID group.com.trillium.pocketpalette.beta
expect "$beta" PALETTE_URL_SCHEME pocketpalette-beta
expect "$beta" DISPLAY_NAME "PocketPalette β"
expect "$beta" PRODUCT_NAME "PocketPalette β"
expect "$beta" PRODUCT_MODULE_NAME PocketPalette
expect "$beta" ASSETCATALOG_COMPILER_APPICON_NAME AppIcon-Beta
expect "$beta" CONFIGURATION Beta
expect "$beta" DEVELOPMENT_TEAM "$(setting "$stable" DEVELOPMENT_TEAM)"
setting "$beta" SWIFT_ACTIVE_COMPILATION_CONDITIONS | grep -qw BETA || fail "beta build lacks the BETA condition"
setting "$beta" GCC_PREPROCESSOR_DEFINITIONS | grep -qw 'BETA=1' || fail "beta build lacks BETA=1"
# The widget extension is a child of the beta app id, in the beta App Group, and keeps its own product name.
wexpect Beta PRODUCT_BUNDLE_IDENTIFIER com.trillium.pocketpalette.beta.widget
wexpect Beta APP_GROUP_ID group.com.trillium.pocketpalette.beta
wexpect Beta PALETTE_URL_SCHEME pocketpalette-beta
wexpect Beta PRODUCT_NAME PocketPaletteWidget
wexpect Beta DISPLAY_NAME "PocketPalette β"
wsetting Beta SWIFT_ACTIVE_COMPILATION_CONDITIONS | grep -qw BETA || fail "beta widget lacks the BETA condition"

# Both targets read the group from the entitlements and Info.plist through the same variable (no hardcoded id left).
grep -q 'APP_GROUP_ID' "$tmp/App/Resources/PocketPalette.entitlements" "$tmp/Widget/PocketPaletteWidget.entitlements" \
  "$tmp/App/Resources/AppInfo.plist" "$tmp/Widget/Info.plist" || fail "an entitlements/Info.plist file does not use APP_GROUP_ID"
! grep -rq 'group\.com\.trillium\.pocketpalette' "$tmp/App/Resources" "$tmp/Widget" || fail "a hardcoded App Group remains in App/Resources or Widget"

# A machine-local bundle id (Local.xcconfig) carries through to the beta suffix, widget included.
printf 'PRODUCT_BUNDLE_IDENTIFIER = com.example.local\nAPP_GROUP_ID = group.com.example.local\n' >"$tmp/Config/Local.xcconfig"
(cd "$tmp" && xcodegen generate --quiet)
expect "$stable" PRODUCT_BUNDLE_IDENTIFIER com.example.local
expect "$beta" PRODUCT_BUNDLE_IDENTIFIER com.example.local.beta
expect "$beta" APP_GROUP_ID group.com.example.local.beta
wexpect Beta PRODUCT_BUNDLE_IDENTIFIER com.example.local.beta.widget
echo "beta test ok"
