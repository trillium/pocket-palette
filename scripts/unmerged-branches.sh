#!/usr/bin/env bash
# make unmerged: flag worker branches whose commits have not landed on the default branch (runbook rules 2 and 8).
#   scripts/unmerged-branches.sh [REPO...]   default: the repo this script lives in
#   scripts/unmerged-branches.sh --all       every git repo directly under ${IOS_REPOS_ROOT:-/Users/mini0/code}
#                                            that has project.yml, Package.swift or Cargo.toml
# Per repo the default branch is local `main`, else the branch origin/HEAD points at. One line per local branch
# matching fm/*, macbook/* or macbook-wip/* with commits not reachable from it:
#   <repo> <branch> ahead=<n> last=<YYYY-MM-DD>
# A repo with no default branch prints `<repo> no-default-branch` and counts as a failure.
# Exit 0 clean, 1 when any line was printed, 2 on usage errors. Read-only git plumbing: no network, no fetch,
# never checks out or deletes anything.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${IOS_REPOS_ROOT:-/Users/mini0/code}"
repos=(); all=0
for arg in "$@"; do
  case "$arg" in
    --all) all=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unmerged-branches: unknown option $arg" >&2; exit 2 ;;
    *) repos+=("$arg") ;;
  esac
done
if [ "$all" = 1 ]; then
  for d in "$root"/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] || continue
    for marker in project.yml Package.swift Cargo.toml; do
      if [ -e "$d/$marker" ]; then repos+=("$d"); break; fi
    done
  done
elif [ "${#repos[@]}" = 0 ]; then
  repos=("$(git -C "$here" rev-parse --show-toplevel)")
fi

default_ref() { # default_ref REPO: print the default branch ref, or nothing
  local repo="$1" head
  if git -C "$repo" show-ref --verify --quiet refs/heads/main; then echo refs/heads/main; return; fi
  head="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -n "$head" ] && git -C "$repo" show-ref --verify --quiet "$head"; then echo "$head"; fi
}

found=0
for repo in "${repos[@]}"; do
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "unmerged-branches: $repo is not a git repo" >&2; exit 2
  fi
  base="$(default_ref "$repo")"
  if [ -z "$base" ]; then echo "$repo no-default-branch"; found=1; continue; fi
  while read -r branch; do
    [ -n "$branch" ] || continue
    ahead="$(git -C "$repo" rev-list --count "$base..refs/heads/$branch")"
    [ "$ahead" -gt 0 ] || continue
    last="$(git -C "$repo" log -1 --format=%cs "refs/heads/$branch")"
    echo "$repo $branch ahead=$ahead last=$last"
    found=1
  done < <(git -C "$repo" for-each-ref --format='%(refname:strip=2)' refs/heads/fm/ refs/heads/macbook/ refs/heads/macbook-wip/)
done
[ "$found" = 0 ]
