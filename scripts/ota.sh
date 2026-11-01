#!/usr/bin/env bash
# make ota: NON-CAPTAIN FALLBACK. The captain's phone is installed by `make ship-gate && make stable-install` (automatic,
# over Tailscale, no link, no tap); this is never his install path.
# Build an ad-hoc-signed .ipa (app + widget) and publish it as an OTA (itms-services) install
# package: manifest.plist + index.html + the .ipa, written to OTA_DIR (default ~/ota/pocketpalette). Follows
# runbooks-c62 and mirrors ~/code/TinyKeyboard/ota-publish.sh. `make ota-serve` exposes OTA_DIR over tailnet-only
# HTTPS for a tester's device. The kept builds are also what phone-session restores the stable app from.
# It refuses to publish unless `make ship-gate` left a pass file for exactly this commit, and it keeps the last good
# builds as a Rollback list (docs/ota.md). Needs: team 85PWBA3B59 in DEVELOPMENT_TEAM (Config/Local.xcconfig) and ota/exportOptions.plist,
# its "Apple Development" identity in the keychain, the phone registered for the team, jq, and the tailscale CLI
# when OTA_BASE_URL is unset.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONFIGURATION=Release
OTA_DIR="${OTA_DIR:-$HOME/ota/pocketpalette}"
OTA_HTTPS_PORT="${OTA_HTTPS_PORT:-8782}"
TITLE="$(cfg DISPLAY_NAME)"
OPTIONS="$ROOT/ota/exportOptions.plist"
SHIP_PASS_DIR="${SHIP_PASS_DIR:-$BUILD_DIR/ship-pass}"
OTA_KEEP_PREVIOUS="${OTA_KEEP_PREVIOUS:-3}"

tools="jq python3 git unzip xcodebuild"
[ -n "${OTA_BASE_URL:-}" ] || tools="tailscale $tools"
for t in $tools; do require_tool "$t" "needed by make ota"; done
is_placeholder "$TEAM_ID" && die "DEVELOPMENT_TEAM is unset (Config/Local.xcconfig)"
export_team="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$OPTIONS")"
[ "$export_team" = "$TEAM_ID" ] || die "ota/exportOptions.plist teamID $export_team != DEVELOPMENT_TEAM $TEAM_ID"

# Never publish a build the ship gate has not passed: the pass file must name exactly this commit, and the tree must
# still be the committed one. A broken or unvetted build never replaces a working one on the phone.
head_sha="$(git -C "$ROOT" rev-parse HEAD)"
pass_file="$SHIP_PASS_DIR/$head_sha.json"
[ -f "$pass_file" ] || die "no ship-gate pass for HEAD ${head_sha:0:7} ($pass_file): run 'make ship-gate' first; nothing was published"
jq -e --arg c "$head_sha" '.commit == $c' "$pass_file" >/dev/null || die "ship-gate pass file does not name HEAD ${head_sha:0:7}; nothing was published"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || die "working tree changed since the ship gate passed; commit it and run 'make ship-gate' again"
short="$(git -C "$ROOT" rev-parse --short HEAD)"
passed_at="$(jq -r .passed_at "$pass_file")"

# Absolute base URL baked into the manifest and the install link; it must match where ota-serve exposes OTA_DIR.
# Default: this Mac's tailnet name on OTA_HTTPS_PORT (the HTTPS root and :8443 are Funnel on this Mac).
if [ -n "${OTA_BASE_URL:-}" ]; then
  while [ "${OTA_BASE_URL%/}" != "$OTA_BASE_URL" ]; do OTA_BASE_URL="${OTA_BASE_URL%/}"; done
  case "$OTA_BASE_URL" in
    https://*) ;;
    *) die "OTA_BASE_URL must start with https:// (iOS refuses itms-services manifests over plain HTTP)" ;;
  esac
else
  host="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
  { [ -n "$host" ] && [ "$host" != "null" ]; } || die "no tailnet hostname from 'tailscale status --json' (is Tailscale up with MagicDNS?)"
  OTA_BASE_URL="https://$host:$OTA_HTTPS_PORT"
fi

# Build artifacts (archive, dSYMs, embedded profiles) never go inside OTA_DIR: that folder is served.
work="$(mktemp -d "${TMPDIR:-/tmp}/pocketpalette-ota.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/$APP_NAME.xcarchive"
export_dir="$work/export"

# A fresh build number per publish, or iOS silently skips reinstalling "the same" build.
# Command-line build settings apply to every target, so the extension keeps matching the app.
BUNDLE_VERSION="$(date -u +%Y%m%d%H%M%S)"
# What the install page shows, so the captain can tell which source a build came from: semver plus commit.
VERSION_LABEL="$("$ROOT/scripts/version.sh" --full) ($short)"

generate_project
echo "archiving $SCHEME for team $TEAM_ID (build $BUNDLE_VERSION)..."
prov=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
${SIGN_EXEC:+$SIGN_EXEC }xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "generic/platform=iOS" \
  -archivePath "$archive" -derivedDataPath "$DERIVED" "${prov[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUNDLE_VERSION" archive -quiet

# OTA_EXPORT=adhoc (default): export an ad-hoc .ipa; needs the Apple ID signed in to Xcode to make the distribution profile.
# OTA_EXPORT=archive: zip the Apple Development-signed .app straight out of the archive. It needs only the team
# provisioning profiles already installed (no Xcode account), and installs only on the devices those profiles list.
ipa_src="$export_dir/$APP_NAME.ipa"
case "${OTA_EXPORT:-adhoc}" in
  adhoc)
    echo "exporting ad-hoc .ipa..."
    ${SIGN_EXEC:+$SIGN_EXEC }xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
      -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates -quiet ;;
  archive)
    echo "packaging the development-signed app from the archive (OTA_EXPORT=archive)..."
    mkdir -p "$export_dir/Payload"
    built_app="$(find "$archive/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
    [ -n "$built_app" ] || die "no .app in the archive"
    cp -R "$built_app" "$export_dir/Payload/"
    ${SIGN_EXEC:+$SIGN_EXEC }codesign --verify --deep --strict "$export_dir/Payload/$(basename "$built_app")" || die "the archived app's signature does not verify"
    (cd "$export_dir" && zip -q -r -y "$APP_NAME.ipa" Payload) ;;
  *) die "OTA_EXPORT must be adhoc or archive" ;;
esac

[ -f "$ipa_src" ] || die "expected ipa not found at $ipa_src"

# Look inside the exported .ipa before publishing: it must be this app at the build number we just stamped, with the widget.
# (The commit is bound by the pass file above: the pass names HEAD and the tree is clean, so the archive is that commit.)
unzip -q -o "$ipa_src" 'Payload/*.app/Info.plist' 'Payload/*.app/PlugIns/*' -d "$work/ipa" || die "cannot read the exported .ipa"
app_dir="$(find "$work/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_dir/Info.plist" 2>/dev/null || true)" = "$BUNDLE_ID" ] \
  || die "the exported .ipa is not $BUNDLE_ID; nothing was published"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Info.plist" 2>/dev/null || true)" = "$BUNDLE_VERSION" ] \
  || die "the exported .ipa is not build $BUNDLE_VERSION; nothing was published"
ls -d "$app_dir"/PlugIns/*.appex >/dev/null 2>&1 || die "the exported .ipa has no widget extension; nothing was published"

# Publish: stage the new build under builds/<id>/ (ipa + its own manifest + meta), then move it into place, then
# refresh the top-level copies and the page. Earlier builds stay untouched until they fall off the rollback list.
mkdir -p "$OTA_DIR/builds"
ipa_name="$APP_NAME.ipa"
stage="$OTA_DIR/builds/.staging-$BUNDLE_VERSION"
rm -rf "$stage"; mkdir -p "$stage"
cp -f "$ipa_src" "$stage/$ipa_name"

# Escape sed replacement metacharacters so a URL's '&' is not read as "the match".
sed_escape() { printf '%s' "$1" | sed -e 's/[&\]/\\&/g'; }
write_manifest() { # $1 ipa url, $2 destination
  sed -e "s#__IPA_URL__#$(sed_escape "$1")#g" \
      -e "s#__BUNDLE_ID__#$(sed_escape "$BUNDLE_ID")#g" \
      -e "s#__BUNDLE_VERSION__#$(sed_escape "$BUNDLE_VERSION")#g" \
      -e "s#__TITLE__#$(sed_escape "$TITLE")#g" \
      "$ROOT/ota/manifest.plist.template" >"$2"
}
write_manifest "$OTA_BASE_URL/builds/$BUNDLE_VERSION/$ipa_name" "$stage/manifest.plist"
jq -n --arg id "$BUNDLE_VERSION" --arg version "$("$ROOT/scripts/version.sh" --full)" --arg short "$short" \
  --arg commit "$head_sha" --arg passed_at "$passed_at" --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{id: $id, version: $version, short: $short, commit: $commit, passed_at: $passed_at, built_at: $built_at, pass: true}' >"$stage/meta.json"
mv "$stage" "$OTA_DIR/builds/$BUNDLE_VERSION"

# Top-level copies of the newest build keep the documented URLs (/manifest.plist, /PocketPalette.ipa) working.
cp -f "$ipa_src" "$OTA_DIR/$ipa_name"
write_manifest "$OTA_BASE_URL/$ipa_name" "$OTA_DIR/manifest.plist"
python3 "$ROOT/scripts/ota-page.py" --dir "$OTA_DIR" --base "$OTA_BASE_URL" --title "$TITLE" \
  --template "$ROOT/ota/index.html.template" --keep "$OTA_KEEP_PREVIOUS"

manifest_url="$OTA_BASE_URL/manifest.plist"
install_url="itms-services://?action=download-manifest&url=$(printf '%s' "$manifest_url" | jq -sRr @uri)"
echo ""
echo "published $VERSION_LABEL build $BUNDLE_VERSION to $OTA_DIR"
echo "  install page: $OTA_BASE_URL/"
echo "  install link: $install_url"
echo "if it is not already served: make ota-serve"
