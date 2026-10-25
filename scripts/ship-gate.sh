#!/usr/bin/env bash
# make ship-gate: refuse to install a build on the stable app unless it is provably the real app. A build gets a pass
# file only if
#   1. no fm/*, macbook/*, macbook-wip/* branch has commits missing from the default branch (scripts/unmerged-branches.sh),
#      HEAD is the tip of the integrated branch (SHIP_BRANCH, default main), and the working tree is clean, so the
#      build is exactly that merged commit;
#   2. `make check` passes (lint, secrets, all unit tests);
#   3. the app's smoke step passes: scripts/smoke.sh builds the app, launches it and reads back what it did.
#      "It launches" is not enough; the app fills the hook in (see the header of scripts/smoke.sh).
# On success it writes $SHIP_PASS_DIR/<full-commit-sha>.json (default build/ship-pass/), which `make stable-install`
# requires (runbook rule 4). The pass file has the same shape as firstmate-share's, so the scripts stay interchangeable.
# Needs: git, jq (the smoke hook needs Xcode).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIP_BRANCH="${SHIP_BRANCH:-main}"
for t in git jq; do require_tool "$t" "needed by make ship-gate"; done

# --- 1: this exact, merged, clean commit -------------------------------------------------------------------------------
unmerged="$("$ROOT/scripts/unmerged-branches.sh" "$ROOT" || true)"
[ -z "$unmerged" ] || die "ship gate: unmerged worker branches; land them on the default branch first:
$unmerged"
head_sha="$(git -C "$ROOT" rev-parse HEAD)"
tip_sha="$(git -C "$ROOT" rev-parse --verify --quiet "refs/heads/$SHIP_BRANCH" || true)"
[ -n "$tip_sha" ] || die "ship gate: branch '$SHIP_BRANCH' does not exist here (SHIP_BRANCH=<integrated branch>)"
[ "$head_sha" = "$tip_sha" ] || die "ship gate: HEAD ${head_sha:0:7} is not the head of $SHIP_BRANCH (${tip_sha:0:7}); build from the integrated head"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || die "ship gate: working tree is not clean; commit or remove changes first"
echo "gate 1/4: HEAD ${head_sha:0:7} is the head of $SHIP_BRANCH, tree clean"

# --- 2: the single green gate ------------------------------------------------------------------------------------------
echo "gate 2/4: make check"
make -C "$ROOT" check >/dev/null || die "ship gate: make check failed (run it to see why)"
echo "gate 2/4: make check passed"

# --- 3: SMOKE: the built app does its job (scripts/smoke.sh is the app's hook) -----------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/ship-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "gate 3/4: smoke test of the built app"
SMOKE_RESULT="$work/smoke.json" "$ROOT/scripts/smoke.sh" || die "ship gate: smoke test failed: the built app does not do its job"
jq -e 'type == "object" and .selfCheckPassed == true' "$work/smoke.json" >/dev/null 2>&1 \
  || die "ship gate: scripts/smoke.sh passed but wrote no result with selfCheckPassed=true to \$SMOKE_RESULT"
echo "gate 3/4: smoke test passed"

# --- 4: the pass file --------------------------------------------------------------------------------------------------
mkdir -p "$SHIP_PASS_DIR"
pass="$SHIP_PASS_DIR/$head_sha.json"
jq -n --arg commit "$head_sha" --arg short "$(git -C "$ROOT" rev-parse --short HEAD)" --arg branch "$SHIP_BRANCH" \
  --arg version "$(cfg MARKETING_VERSION)+$(cfg CURRENT_PROJECT_VERSION)" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile smoke "$work/smoke.json" \
  '{commit: $commit, short: $short, branch: $branch, version: $version, passed_at: $at,
    checks: ["head-is-branch-tip", "tree-clean", "make-check", "smoke-built-app"], smoke: $smoke[0]}' >"$pass"
echo "gate 4/4: PASS for ${head_sha:0:7}; wrote ${pass#"$ROOT"/}"
