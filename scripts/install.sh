#!/usr/bin/env bash
# make beta / make stable-install: build for the connected iPhone and install it with `xcrun devicectl`.
#   install.sh beta     the "<App> Beta" scheme (bundle id <id>.beta); no gate, this is the daily-driver testing app.
#   install.sh stable   the stable scheme and bundle id; REFUSES unless `make ship-gate` left
#                       build/ship-pass/<HEAD sha>.json for exactly this commit on a clean tree (runbook rule 4).
# Device: DEVICE_ID from the environment or Config/Local.xcconfig (`xcrun devicectl list devices`).
# Each successful install appends one tab-separated line to INSTALL_LEDGER (default ~/.ios-install-ledger.tsv):
#   <utc time> <device> <bundle id> <commit[.dirty]> <build number> <gate pass: yes|no>
# Needs signing (docs/signing.md); never uploads anything. Bash 3.2 compatible.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mode="${1:-}"
case "$mode" in
  beta) scheme="$BETA_SCHEME"; configuration="Beta"; bundle="$BETA_BUNDLE_ID" ;;
  stable) scheme="$SCHEME"; configuration="Release"; bundle="$BUNDLE_ID" ;;
  *) echo "usage: install.sh beta|stable" >&2; exit 2 ;;
esac
for t in git jq xcodebuild xcrun; do require_tool "$t" "needed by make $([ "$mode" = beta ] && echo beta || echo stable-install)"; done

head_sha="$(git -C "$ROOT" rev-parse HEAD)"
pass_file="$SHIP_PASS_DIR/$head_sha.json"
gate="no"
[ ! -f "$pass_file" ] || { jq -e --arg c "$head_sha" '.commit == $c' "$pass_file" >/dev/null 2>&1 && gate="yes"; }
if [ "$mode" = stable ]; then
  [ "$gate" = yes ] || die "no ship-gate pass for HEAD ${head_sha:0:7} (${pass_file#"$ROOT"/}): run 'make ship-gate' first; nothing was built or installed"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "working tree changed since the ship gate passed; commit it and run 'make ship-gate' again"
fi

device="$(cfg DEVICE_ID)"
[ -n "$device" ] || die "no device: set DEVICE_ID (env or Config/Local.xcconfig); list devices with 'xcrun devicectl list devices'"
is_placeholder "$TEAM_ID" && die "DEVELOPMENT_TEAM is unset (Config/Base.xcconfig); a device build must be signed"

generate_project
args=()
while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done < <(asc_auth_args)
echo "building $scheme ($configuration) for device $device"
xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration "$configuration" -destination "id=$device" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates ${args[@]+"${args[@]}"} build -quiet
app="$(find "$DERIVED/Build/Products/$configuration-iphoneos" -maxdepth 1 -name '*.app' -type d | head -1)"
[ -n "$app" ] || die "built app not found under $DERIVED/Build/Products/$configuration-iphoneos"

echo "installing $bundle on $device"
xcrun devicectl device install app --device "$device" "$app"

commit="$(git -C "$ROOT" rev-parse --short HEAD)"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || commit="$commit.dirty"
mkdir -p "$(dirname "$INSTALL_LEDGER")"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$device" "$bundle" "$commit" "$(cfg CURRENT_PROJECT_VERSION)" "$gate" >>"$INSTALL_LEDGER"
echo "installed $bundle ($commit, build $(cfg CURRENT_PROJECT_VERSION), gate pass: $gate); ledger: $INSTALL_LEDGER"
