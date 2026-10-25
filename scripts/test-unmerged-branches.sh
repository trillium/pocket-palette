#!/usr/bin/env bash
# Tests for unmerged-branches.sh against throwaway git repos. Run by `make check`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE="2026-10-21T12:00:00Z" GIT_COMMITTER_DATE="2026-10-21T12:00:00Z"
fails=0
expect() { # expect LABEL WANT GOT
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fails=$((fails + 1)); fi
}
run() { out="$("$@" 2>&1)" && code=0 || code=$?; }

root="$tmp/code"; repo="$root/app"
mkdir -p "$repo"; git -C "$repo" init -q -b main; touch "$repo/project.yml"
c() { git -C "$repo" commit -q --allow-empty -m "$1"; }
c "feat: base"
git -C "$repo" checkout -q -b fm/done; c "feat: done"
git -C "$repo" checkout -q main; git -C "$repo" merge -q --no-ff fm/done -m "merge done"
git -C "$repo" checkout -q -b fm/ahead; c "feat: a1"; c "feat: a2"
git -C "$repo" checkout -q main
git -C "$repo" checkout -q -b macbook-wip/x; c "wip: x"
git -C "$repo" checkout -q -b feature/other; c "feat: not a worker branch"
git -C "$repo" checkout -q main
mkdir -p "$root/plain" "$root/notgit"; git -C "$root/plain" init -q -b main   # no marker file: skipped by --all
touch "$root/notgit/project.yml"                                              # marker but not a repo: skipped

want="$repo fm/ahead ahead=2 last=2026-10-21
$repo macbook-wip/x ahead=1 last=2026-10-21"
run "$here/unmerged-branches.sh" "$repo"
expect "single repo lines" "$want" "$out"; expect "single repo exit" 1 "$code"
IOS_REPOS_ROOT="$root" run "$here/unmerged-branches.sh" --all
expect "--all lines" "$want" "$out"; expect "--all exit" 1 "$code"
git -C "$repo" branch -q -D fm/ahead macbook-wip/x
run "$here/unmerged-branches.sh" "$repo"
expect "clean output" "" "$out"; expect "clean exit" 0 "$code"
IOS_REPOS_ROOT="$root" run "$here/unmerged-branches.sh" --all
expect "--all clean exit" 0 "$code"

# no local main: falls back to origin/HEAD; with neither, no-default-branch
git -C "$repo" branch -q -m main trunk
run "$here/unmerged-branches.sh" "$repo"
expect "no default branch line" "$repo no-default-branch" "$out"; expect "no default branch exit" 1 "$code"
git -C "$repo" update-ref refs/remotes/origin/trunk trunk
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
git -C "$repo" checkout -q -b fm/late; c "feat: late"
run "$here/unmerged-branches.sh" "$repo"
expect "origin/HEAD fallback" "$repo fm/late ahead=1 last=2026-10-21" "$out"
run "$here/unmerged-branches.sh" "$tmp/notgit"
expect "not a repo exit" 2 "$code"

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "unmerged-branches tests ok"
