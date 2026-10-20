#!/usr/bin/env bash
# Bump the build number (or version) in Config/Base.xcconfig, the single source of truth.
# TestFlight rejects a build number it has already seen for the same MARKETING_VERSION.
# Usage: bump-build.sh              increment CURRENT_PROJECT_VERSION by 1
#        bump-build.sh --set N      set it to N (integer)
#        bump-build.sh --marketing X.Y.Z   set MARKETING_VERSION (and reset build to 1)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
file="$CONFIG_DIR/Base.xcconfig"

set_key() { # set_key KEY VALUE
  KEY="$1" VAL="$2" perl -pi -e 's/^(\s*\Q$ENV{KEY}\E\s*=\s*).*$/$1$ENV{VAL}/' "$file"
}

current="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=' "$file" | sed -E 's/.*=[[:space:]]*//')"
printf '%s' "$current" | grep -qE '^[0-9]+$' || die "CURRENT_PROJECT_VERSION in $file is not an integer: '$current'"

case "${1:-}" in
  "")          new=$((current + 1)); set_key CURRENT_PROJECT_VERSION "$new" ;;
  --set)       printf '%s' "${2:-}" | grep -qE '^[0-9]+$' || die "--set needs an integer"
               new="$2"; set_key CURRENT_PROJECT_VERSION "$new" ;;
  --marketing) printf '%s' "${2:-}" | grep -qE '^[0-9]+(\.[0-9]+){1,2}$' || die "--marketing needs X.Y or X.Y.Z"
               set_key MARKETING_VERSION "$2"; set_key CURRENT_PROJECT_VERSION 1; new=1 ;;
  *)           die "usage: bump-build.sh [--set N | --marketing X.Y.Z]" ;;
esac
echo "$(grep -E '^[[:space:]]*MARKETING_VERSION' "$file" | sed -E 's/.*=[[:space:]]*//') build $new  (${file#"$ROOT"/})"
