#!/usr/bin/env bash
# make upload: send build/<App>.xcarchive to App Store Connect (TestFlight) with
#   xcodebuild -exportArchive  (ExportOptions destination=upload, App Store Connect API key auth).
# This is the only Apple-facing step and it is DRY-RUN BY DEFAULT: it validates prerequisites and prints the
# exact command with credential values masked. A real upload needs CONFIRM_UPLOAD=1 (make upload CONFIRM=1).
# The default export is TestFlight-internal-only; set TESTFLIGHT_INTERNAL_ONLY=0 to allow external testers.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

internal="${TESTFLIGHT_INTERNAL_ONLY:-1}"; [ "$internal" = 0 ] && internal_plist="false" || internal_plist="true"
mkdir -p "$BUILD_DIR"
opts="$BUILD_DIR/ExportOptions-upload.plist"
cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>testFlightInternalTestingOnly</key><${internal_plist}/>
</dict>
</plist>
PLIST
plutil -lint "$opts" >/dev/null || die "generated export options are not a valid plist"

confirm="${CONFIRM_UPLOAD:-0}"
if [ "$confirm" = 1 ]; then
  "$(dirname "${BASH_SOURCE[0]}")/doctor.sh" --signing || die "doctor --signing failed; fix the FAIL lines above"
  [ -d "$ARCHIVE_PATH" ] || die "no archive at ${ARCHIVE_PATH#"$ROOT"/}: run 'make archive' first"
  archive_is_signed || die "archive is unsigned (made with archive-unsigned?): run 'make archive'"
  args=(-exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$opts" -allowProvisioningUpdates)
  while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done < <(asc_auth_args)
  echo "uploading build $(cfg CURRENT_PROJECT_VERSION) of $APP_NAME ($BUNDLE_ID) to App Store Connect..."
  xcodebuild "${args[@]}"
  echo "uploaded. Processing takes a few minutes; then add testers in App Store Connect > TestFlight."
  exit 0
fi

echo "DRY RUN (no network, no upload). Set CONFIRM_UPLOAD=1 to send for real."
echo "app:      $APP_NAME  bundle id: $BUNDLE_ID  team: ${TEAM_ID:-<unset>}"
echo "version:  $(cfg MARKETING_VERSION) build $(cfg CURRENT_PROJECT_VERSION)  internal-only: $internal_plist"
if [ -d "$ARCHIVE_PATH" ]; then
  if archive_is_signed; then echo "archive:  ${ARCHIVE_PATH#"$ROOT"/} (present, signed)"
  else echo "archive:  ${ARCHIVE_PATH#"$ROOT"/} (present but UNSIGNED: a real upload would refuse it)"; fi
else echo "archive:  ${ARCHIVE_PATH#"$ROOT"/} MISSING -- run 'make archive' first"; fi
echo "options:  ${opts#"$ROOT"/} (valid plist)"
echo "would run:"
echo "  xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH#"$ROOT"/} -exportPath ${EXPORT_PATH#"$ROOT"/} \\"
echo "    -exportOptionsPlist ${opts#"$ROOT"/} -allowProvisioningUpdates \\"
echo "    -authenticationKeyPath \"\$ASC_KEY_PATH\" -authenticationKeyID \"\$ASC_KEY_ID\" -authenticationKeyIssuerID \"\$ASC_ISSUER_ID\""
echo "prerequisite check (informational in a dry run):"
"$(dirname "${BASH_SOURCE[0]}")/doctor.sh" --signing | sed -n '/== Signing/,$p' | sed 's/^/  /' || true
