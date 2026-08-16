#!/usr/bin/env bash
# End-to-end demonstration of the local-landing guard added by 9c94e91..38bb5cd,
# replaying the measured trap: a fork whose LOCAL default branch carries
# adoptions origin never had, and a worker branch cut from origin's tip (exactly
# what fm-spawn.sh:freshen_spawn_worktree_base produces).
#
# Usage: bash demo-local-landing-guard.sh <path-to-firstmate-worktree>
set -eu

REPO=$1
NEW="$REPO/bin/fm-merge-local.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-landing-demo.XXXXXX")
# The base-commit version, extracted with its exec bit, to show what the same
# trap looked like before this change.
mkdir -p "$LAB/before"
git -C "$REPO" archive ef35d799a846d676c2fd30b1d1e3ed47b0fb2c22 bin/fm-merge-local.sh | tar -x -C "$LAB/before"
OLD="$LAB/before/bin/fm-merge-local.sh"

g() { git -C "$1" -c user.name='Captain' -c user.email='captain@example.invalid' "${@:2}"; }
say() { printf '\n== %s\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" || printf '[exit %s]\n' "$?"; }

build_fixture() {  # <name> <task-id> <with-adoption yes|no> -> case dir
  local name=$1 id=$2 adopt=$3 case_dir proj origin tip
  case_dir="$LAB/$name"; proj="$case_dir/projects/firstmate"; origin="$case_dir/upstream.git"
  mkdir -p "$case_dir/state" "$case_dir/projects"
  git init --quiet -b main "$proj"
  printf 'firstmate\n' > "$proj/README.md"
  g "$proj" add README.md; g "$proj" commit -qm 'upstream: initial'
  git clone --quiet --bare "$proj" "$origin"
  git -C "$proj" remote add origin "file://$origin"
  git -C "$proj" fetch --quiet origin
  git -C "$proj" remote set-head origin --auto >/dev/null 2>&1
  tip=$(git -C "$proj" rev-parse HEAD)
  if [ "$adopt" = yes ]; then
    printf "keep Pi's export confirmation visible\n" > "$proj/calm-export.txt"
    g "$proj" add calm-export.txt
    g "$proj" commit -qm 'adopt upstream PR #2461 locally (calm export confirmation)'
    printf 'remote-secondmate recovery hint\n' > "$proj/recovery-hint.txt"
    g "$proj" add recovery-hint.txt
    g "$proj" commit -qm 'adopt upstream PR #2456 locally (secondmate recovery hint)'
  fi
  # How a worker worktree is really created: hard-reset onto origin's tip.
  git -C "$proj" worktree add --quiet --detach "$case_dir/worker" "$tip"
  git -C "$case_dir/worker" reset --hard --quiet origin/main
  g "$case_dir/worker" checkout --quiet -b "fm/$id"
  printf 'worker deliverable\n' > "$case_dir/worker/feature.txt"
  g "$case_dir/worker" add feature.txt
  g "$case_dir/worker" commit -qm 'feat(bin): the work the crewmate was sent to do'
  printf 'project=%s\nmode=local-only\nyolo=off\n' "$proj" > "$case_dir/state/$id.meta"
  printf '%s\n' "$case_dir"
}

merge_local() {  # <script> <case_dir> <args...>
  local script=$1 case_dir=$2; shift 2
  printf '\n$ fm-merge-local.sh %s\n' "$*"
  ( cd "$case_dir/projects/firstmate" \
    && FM_ROOT_OVERRIDE="$REPO" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
       "$script" "$@" ) || printf '[exit %s]\n' "$?"
}

say 'SCENE 1 - the measured shape: local main = upstream + N local adoptions'
TRAP_CASE=$(build_fixture trap fix-calm-a1 yes)
PROJ="$TRAP_CASE/projects/firstmate"
run git -C "$PROJ" log --oneline --decorate -3 main
run git -C "$PROJ" log --oneline origin/main..main
say 'the worker branch was cut from origin/main, so it does not contain them'
run git -C "$PROJ" log --oneline origin/main..fm/fix-calm-a1
say 'the manual check that caught this four times in two days:'
run git -C "$PROJ" diff main..fm/fix-calm-a1 --stat

say 'SCENE 2 - BEFORE (base commit ef35d79): refused, but names nothing'
merge_local "$OLD" "$TRAP_CASE" fix-calm-a1

say 'SCENE 3 - AFTER (38bb5cd): refused, naming what would disappear and the fix'
merge_local "$NEW" "$TRAP_CASE" fix-calm-a1
say 'local main is untouched by the refusal, and no drop record was written:'
run git -C "$PROJ" log --oneline -1 main
run ls "$TRAP_CASE/state"

say 'SCENE 4 - the reconciliation the refusal names makes the same landing pass'
run git -C "$TRAP_CASE/worker" merge --no-edit main
merge_local "$NEW" "$TRAP_CASE" fix-calm-a1
say 'both the adoptions and the worker deliverable are on local main:'
run git -C "$PROJ" log --oneline -5 main
run ls "$PROJ"

say 'SCENE 5 - a healthy landing keeps passing with no added friction'
CLEAN_CASE=$(build_fixture clean ship-clean-b2 no)
merge_local "$NEW" "$CLEAN_CASE" ship-clean-b2
say 'and the escape hatch cannot silently turn a healthy landing into a reset:'
CLEAN2=$(build_fixture clean2 ship-clean-c3 no)
merge_local "$NEW" "$CLEAN2" ship-clean-c3 --drop-local-commits

say 'SCENE 6 - the escape hatch: explicit, traced, recoverable'
DROP_CASE=$(build_fixture drop fix-drop-d4 yes)
DPROJ="$DROP_CASE/projects/firstmate"
DROPPED_TIP=$(git -C "$DPROJ" rev-parse main)
merge_local "$NEW" "$DROP_CASE" --drop-local-commits fix-drop-d4
say 'the record written before the branch moved:'
run cat "$DROP_CASE/state/fix-drop-d4.local-merge-drop"
run git -C "$DPROJ" for-each-ref 'refs/fm-dropped/**'
say 'the reflog is pruned away; the rescued commits survive anyway:'
run git -C "$DPROJ" reflog expire --expire=now --expire-unreachable=now --all
run git -C "$DPROJ" gc --prune=now --quiet
run git -C "$DPROJ" log --oneline -2 "$DROPPED_TIP"
say 'recovery from the recorded SHA:'
run git -C "$DPROJ" branch rescued-adoptions "$DROPPED_TIP"
run git -C "$DPROJ" log --oneline -3 rescued-adoptions
say 'and the documented per-drop release really frees them:'
run git -C "$DPROJ" branch -D rescued-adoptions
run git -C "$DPROJ" update-ref -d "refs/fm-dropped/fix-drop-d4/$(git -C "$DPROJ" rev-parse --short "$DROPPED_TIP")"
run git -C "$DPROJ" reflog expire --expire=now --expire-unreachable=now --all
run git -C "$DPROJ" gc --prune=now --quiet
printf '\n$ git cat-file -e %s^{commit}   # after the release\n' "$DROPPED_TIP"
if git -C "$DPROJ" cat-file -e "$DROPPED_TIP^{commit}" 2>/dev/null; then
  printf 'still present (rescue ref was not what held it)\n'
else
  printf 'gone - released as documented\n'
fi

say 'SCENE 7 - upstream-bound work is untouched'
PR_CASE=$(build_fixture upstream ship-upstream-e5 yes)
PPROJ="$PR_CASE/projects/firstmate"
printf 'project=%s\nmode=no-mistakes\nyolo=off\n' "$PPROJ" > "$PR_CASE/state/ship-upstream-e5.meta"
say 'the guard is never even consulted for a task that ships through an upstream PR:'
merge_local "$NEW" "$PR_CASE" ship-upstream-e5
say 'and the branch that upstream would see carries only the deliverable, no local adoption:'
run git -C "$PPROJ" log --oneline origin/main..fm/ship-upstream-e5
run git -C "$PPROJ" diff --stat origin/main...fm/ship-upstream-e5

printf '\nlab kept at: %s\n' "$LAB"
