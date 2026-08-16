#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and names every local commit that landing it would drop. See AGENTS.md prime
# directives, project management, and task lifecycle.
#
# The local-commit guard exists because a task worktree is always freshened from
# origin's default-branch tip, never from the local default branch. On a project
# whose local default branch carries commits origin does not have (a fork that
# cannot merge upstream, or local adoptions of unmerged upstream work), a branch
# cut from that fresh base does not contain them, so landing it naively would
# erase them. The guard names those commits and the reconciliation that keeps
# them: `git merge <default>` inside the task branch.
#
# --drop-local-commits is the deliberate escape hatch for the case where losing
# them IS the intent. It is never the default and never silent: it refuses unless
# the guard actually triggered, prints every dropped commit, records them in
# state/<id>.local-merge-drop before touching the branch, and then resets the
# default branch to the task branch. Dropped commits stay recoverable by the full
# SHAs in that record. Being destructive, it needs the captain's explicit word.
# Usage: fm-merge-local.sh [--drop-local-commits] <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

DROP_LOCAL=no
ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --drop-local-commits) DROP_LOCAL=yes ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option '$1'; usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1 ;;
    *)
      [ -z "$ID" ] || { echo "error: unexpected argument '$1'; usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1; }
      ID=$1
      ;;
  esac
  shift
done
[ -n "$ID" ] || { echo "usage: fm-merge-local.sh [--drop-local-commits] <task-id>" >&2; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Commits on the local default branch that the task branch does not contain.
# Empty means the merge is a clean fast-forward and nothing local is dropped;
# non-empty is exactly the trap this guard exists for.
DROPPED=$(git -C "$PROJ" rev-list "$BRANCH..$DEFAULT")

if [ -n "$DROPPED" ]; then
  if [ "$DROP_LOCAL" != yes ]; then
    {
      echo "REFUSED: landing $BRANCH would drop $(printf '%s\n' "$DROPPED" | wc -l | tr -d ' ') commit(s) that exist only on local $DEFAULT:"
      git -C "$PROJ" log --no-decorate --format='  %h %s' "$BRANCH..$DEFAULT"
      echo "$BRANCH was cut from origin/$DEFAULT, so it never contained them."
      echo "Reconcile first: run 'git merge $DEFAULT' inside $BRANCH (in its own worktree), resolve any conflicts, then retry this merge."
      echo "If dropping those commits is genuinely intended, re-run with --drop-local-commits (destructive; needs the captain's explicit word)."
    } >&2
    exit 1
  fi

  before=$(git -C "$PROJ" rev-parse "$DEFAULT")
  RECORD="$STATE/$ID.local-merge-drop"
  {
    echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ') fm-merge-local.sh --drop-local-commits"
    echo "task=$ID"
    echo "project=$PROJ"
    echo "default=$DEFAULT"
    echo "branch=$BRANCH"
    echo "default_before=$before"
    git -C "$PROJ" log --no-decorate --format='dropped=%H %s' "$BRANCH..$DEFAULT"
  } >> "$RECORD"

  echo "DROPPING $(printf '%s\n' "$DROPPED" | wc -l | tr -d ' ') local-only commit(s) from $DEFAULT as explicitly authorized:"
  git -C "$PROJ" log --no-decorate --format='  %H %s' "$BRANCH..$DEFAULT"
  echo "recorded in $RECORD (recoverable by full SHA)"

  git -C "$PROJ" reset --hard "$BRANCH" >/dev/null
  after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
  echo "reset local $DEFAULT to $BRANCH ($(git -C "$PROJ" rev-parse --short "$before") -> $after) in $PROJ"
  exit 0
fi

if [ "$DROP_LOCAL" = yes ]; then
  echo "note: --drop-local-commits was unnecessary; $BRANCH already contains every local $DEFAULT commit"
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
