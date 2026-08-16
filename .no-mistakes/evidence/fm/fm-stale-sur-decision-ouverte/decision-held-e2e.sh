#!/usr/bin/env bash
# End-to-end demonstration of the decision-held stale absorb, driving the REAL
# bin/fm-watch.sh binary (not a unit harness) against a realistic state dir:
# one crew that posted a captain decision (needs-decision) and then sat idle on
# a provably-working pane.
#
# The same fixture is replayed through the BASE-commit watcher and the watcher on
# this branch, so the transcript shows the user-visible difference: how many
# times firstmate's LLM is woken while the captain has not answered yet. Each
# "wake" below is one watcher poll cycle; the watcher exits when it surfaces a
# reason, which is what re-arms firstmate and costs a full captain turn.
#
# Usage: decision-held-e2e.sh <repo-root> <base-bin-tree>
set -u

REPO=${1:?repo root}
BASE_TREE=${2:?base bin tree}

# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-held-e2e)

FIXED_WATCH="$REPO/bin/fm-watch.sh"
BASE_WATCH="$BASE_TREE/bin/fm-watch.sh"
DRAIN="$REPO/bin/fm-wake-drain.sh"

WINDOW="fleet:fm-api-shape"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
PANE_LINE='claude - idle - waiting on the captain to answer'
WOKEN=0

hr() { printf '\n%s\n' "==============================================================================="; }
say() { printf '%s\n' "$*"; }

# A crew that has asked the captain a question and gone quiet: an open
# needs-decision as the last status line, an idle unchanged pane, and a backend
# that still reports its agent working (the provably-working verdict).
new_case() {  # <name>
  local dir state
  dir=$(make_case "$1"); state="$dir/state"
  printf '%s\n' "$PANE_LINE" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$WINDOW" > "$state/api.meta"
  printf 'needs-decision [key=api-shape]: ship the v2 endpoint as PATCH or POST?\n' > "$state/api.status"
  prime_status_seen "$state" "$state/api.status"
  printf '%s' "$(hash_text "$PANE_LINE")" > "$state/.hash-$KEY"
  printf '1\n' > "$state/.count-$KEY"
  printf '%s\n' "$dir"
}

# Drain and acknowledge, exactly as firstmate does when it is woken, so the next
# cycle starts from a clean queue and a consumed recovery generation.
settle() {  # <dir> <show-queue:0|1>
  local dir=$1 show=$2 state="$dir/state"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2>"$dir/drain.err" || true
  if [ "$show" = 1 ]; then
    grep -E "$(printf '\t')(stale|signal|heartbeat)$(printf '\t')" "$dir/drain.out" \
      | sed 's/^/      captain queue: /' || true
    sed -n 's/^\(api \[key=.*\)$/      captain queue: \1/p' "$dir/drain.out" || true
  fi
  ack_drain_err "$state" "$dir/drain.err" >/dev/null 2>&1 || true
}

# One watcher wake cycle. Prints what the captain actually experiences: either
# the watcher surfaced a reason on stdout and exited (firstmate woken, one turn
# spent), or it stayed alive and absorbed the wake silently.
poll() {  # <dir> <watch-bin> <label> [VAR=VAL...]
  local dir=$1 watch=$2 label=$3; shift 3
  local state="$dir/state" out="$dir/watch.out" pid surfaced=0
  : > "$out"
  env PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$watch" > "$out" 2>"$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" 60 >/dev/null 2>&1 || true
  printf '\n--- %s\n' "$label"
  if [ -s "$out" ]; then
    surfaced=1; WOKEN=$((WOKEN + 1))
    printf '    >>> FIRSTMATE WOKEN (watcher exited, one captain turn spent):\n'
    sed 's/^/          /' "$out"
  else
    printf '    absorbed - watcher still polling, firstmate never woken\n'
  fi
  tail -n 1 "$state/.watch-triage.log" 2>/dev/null | sed 's/.*\] /      triage log: /'
  printf '      state: '
  [ -e "$state/.decision-held-$KEY" ] && printf 'decision-held-marker=set '
  [ -e "$state/.decision-resurfaced-$KEY" ] && printf 'decision-resurfaced-throttle=set '
  if [ -e "$state/.stale-since-$KEY" ]; then
    printf 'WEDGE-TIMER-ARMED(idle %ss) ' "$(( $(date +%s) - $(cat "$state/.stale-since-$KEY") ))"
  else
    printf 'wedge-timer-disarmed '
  fi
  printf '\n'
  settle "$dir" "$surfaced"
}

# Move the wedge timer 500s into the past: the pane has now been idle far past
# FM_STALE_ESCALATE_SECS=240, i.e. the live four-minute wedge cycle has come due.
age_wedge_timer() {  # <dir>
  echo $(( $(date +%s) - 500 )) > "$1/state/.stale-since-$KEY"
}

export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'

hr
say "SCENARIO"
say "  crew 'api' posts: needs-decision [key=api-shape]: ship the v2 endpoint as PATCH or POST?"
say "  ...then waits. Its pane is idle and unchanged; the backend still reports the agent working"
say "  (provably working). The captain has not answered yet."
say "  FM_STALE_ESCALATE_SECS=240 - the live four-minute wedge cycle."

hr
say "PART 1 - BASE COMMIT ef35d79 (bug reproduction): a wedge escalation every 4 minutes"
WOKEN=0
base=$(new_case base-open-decision)
poll "$base" "$BASE_WATCH" "t+0     first sight of the idle pane" FM_STALE_ESCALATE_SECS=240
for n in 1 2 3; do
  age_wedge_timer "$base"
  poll "$base" "$BASE_WATCH" "t+$((n * 4))min   captain still has not answered" FM_STALE_ESCALATE_SECS=240
done
say ""
say "  >>> firstmate turns spent on this un-answered decision: $WOKEN"

hr
say "PART 2 - THIS BRANCH: same fixture, same 240s threshold, wedge timer planted as crossed"
WOKEN=0
fix=$(new_case fixed-open-decision)
poll "$fix" "$FIXED_WATCH" "t+0     first sight of the idle pane" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600
for n in 1 2 3; do
  age_wedge_timer "$fix"   # plant a long-crossed wedge timer anyway
  poll "$fix" "$FIXED_WATCH" "t+$((n * 4))min   captain still has not answered" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600
done
say ""
say "  >>> firstmate turns spent on this un-answered decision: $WOKEN"

hr
say "PART 3 - THIS BRANCH: the long re-surface cadence still rechecks the decision once a window"
say "  (age the status file past FM_PAUSE_RESURFACE_SECS - the bounded recheck, not a wedge)"
back=$(( $(date +%s) - 500 ))
if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$fix/state/api.status"
else touch -m -d "@$back" "$fix/state/api.status"; fi
prime_status_seen "$fix/state" "$fix/state/api.status"
poll "$fix" "$FIXED_WATCH" "t+1h    one bounded recheck per window" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240

hr
say "PART 4 - THIS BRANCH: the captain answers, the crew stays mute - wedge cadence resumes"
ans=$(new_case answered-then-mute)
poll "$ans" "$FIXED_WATCH" "t+0     open decision, absorbed as in part 2" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600
say ""
say "  captain answers: appending 'resolved [key=api-shape]: go with PATCH' to the status log"
printf 'resolved [key=api-shape]: go with PATCH\n' >> "$ans/state/api.status"
prime_status_seen "$ans/state" "$ans/state/api.status"
poll "$ans" "$FIXED_WATCH" "t+1s    decision closed - held tracking cleared, wedge timer re-armed" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600
age_wedge_timer "$ans"
poll "$ans" "$FIXED_WATCH" "t+4min  the crew is STILL mute after the answer" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600

hr
say "PART 5 - THIS BRANCH: a crew with no open decision wedges exactly like today"
old=$(new_case closed-decision)
printf 'needs-decision [key=api-shape]: ship the v2 endpoint as PATCH or POST?\nresolved [key=api-shape]: go with PATCH\n' \
  > "$old/state/api.status"
prime_status_seen "$old/state" "$old/state/api.status"
poll "$old" "$FIXED_WATCH" "t+0     first sight - normal absorb, wedge timer armed" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600
age_wedge_timer "$old"
poll "$old" "$FIXED_WATCH" "t+4min  no open decision -> wedge escalation, unchanged" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600

hr
say "DONE"
