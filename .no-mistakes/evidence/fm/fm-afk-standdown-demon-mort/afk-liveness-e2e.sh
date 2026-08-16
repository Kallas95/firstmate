#!/usr/bin/env bash
# End-to-end demonstration of "stand supervision down for a LIVE away daemon,
# not for the away flag" (branch fm/fm-afk-standdown-demon-mort).
#
# Builds fixture firstmate homes that differ ONLY in away-daemon liveness:
#   off              no state/.afk
#   daemon           state/.afk + a live process recorded in the daemon lock
#   armed-no-daemon  state/.afk + a DEAD pid recorded in the same lock
# and runs the REAL mechanisms a first mate meets at turn end and at restart,
# once against the base commit and once against this branch.
#
# Usage: afk-liveness-e2e.sh <worktree-root> <base-commit>
set -u

ROOT=$1
BASE=$2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  [ -n "${TMP:-}" ] && [ -d "${TMP:-}" ] && /bin/rm -rf -- "${TMP:?}"
}
trap cleanup EXIT

hr() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
sub() { printf '\n--- %s\n' "$1"; }

# --- two checkouts of the toolbelt: the base commit and this branch ----------
mkdir -p "$TMP/base-checkout" "$TMP/head-checkout"
git -C "$ROOT" archive "$BASE" bin | tar -x -C "$TMP/base-checkout"
cp -R "$ROOT/bin" "$TMP/head-checkout/bin"

# A throwaway git repo to stand in for FM_ROOT (the toolbelt checkout the
# session-start digest inspects); scripts still come from the two bin/ dirs.
git init -q -b main "$TMP/fmroot" && git -C "$TMP/fmroot" commit -q --allow-empty -m init

# --- fixture homes ----------------------------------------------------------
# make_home <name> <off|daemon|dead> <bin-dir>
make_home() {
  local name=$1 kind=$2 bindir=$3 home="$TMP/$1" pid lock dead
  mkdir -p "$home/state" "$home/data" "$home/config"
  git init -q "$home" >/dev/null && git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  cp -R "$bindir" "$home/bin"
  # one task in flight: the home genuinely needs supervision
  printf 'task=demo\n' > "$home/state/demo.meta"
  lock="$home/state/.supervise-daemon.lock"
  case "$kind" in
    off) : ;;
    daemon)
      date '+%s' > "$home/state/.afk"
      sleep 900 >/dev/null 2>&1 & pid=$!
      PIDS+=("$pid")
      mkdir -p "$lock"
      printf '%s\n' "$pid" > "$lock/pid"
      bash -c '. "$1"; fm_pid_identity "$2"' _ "$home/bin/fm-wake-lib.sh" "$pid" > "$lock/pid-identity"
      ;;
    dead)
      date '+%s' > "$home/state/.afk"
      dead=999999
      while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
      mkdir -p "$lock"
      printf '%s\n' "$dead" > "$lock/pid"
      printf 'dead away-mode daemon identity\n' > "$lock/pid-identity"
      ;;
  esac
  # The arm stub stands in for a real watcher launch: it records that it ran and
  # reports the actionable close the real bin/fm-watch-arm.sh reports. Written
  # over the copied executable, so it keeps that file's mode.
  cat > "$home/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: demo-task no progress for 21m\n'
exit 0
ARM
  printf '%s\n' "$home"
}

# The Stop hook runs as a child of the harness holding the session lock.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"; ln -sf /bin/bash "$FAKEBIN/claude"
run_stop_hook() {
  local home=$1 rc=0
  printf '%s\n' '{"session_id":"demo","stop_hook_active":false}' \
    | FM_HOME="$home" "$FAKEBIN/claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf '\n[hook exit=%s]  [watcher arm ran: %s]  [state/.afk still present: %s]\n' \
    "$rc" \
    "$([ -e "$home/state/arm-ran" ] && echo yes || echo 'NO - hook stood down')" \
    "$([ -e "$home/state/.afk" ] && echo yes || echo no)"
}

run_turnend_guard() {
  local home=$1 rc=0
  printf '{"stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$home" bash "$home/bin/fm-turnend-guard.sh" 2>&1 || rc=$?
  printf '\n[guard exit=%s]\n' "$rc"
}

run_session_start() {
  local home=$1
  FM_ROOT_OVERRIDE="$TMP/fmroot" FM_HOME="$home" "$home/bin/fm-session-start.sh" 2>/dev/null
}

# The three places the digest speaks about away mode: the supervision operating
# line, the fleet-digest AFK subsection, and the closing next-step block.
digest_slice() {
  local out
  out=$(cat)
  printf '\n[supervision operating instructions]\n'
  printf '%s\n' "$out" | grep -E '^- Away mode:'
  printf '\n[fleet digest, AFK subsection]\n'
  printf '%s\n' "$out" | grep -A4 '^AFK$' | tail -n +3 | grep -v -E '^(=+|-+)?$'
  printf '\n[next step]\n'
  printf '%s\n' "$out" | grep -A2 '^Away mode '
}

hr "1. bin/fm-afk-launch.sh status - the read-only supervision verdict (this branch)"
for k in off daemon dead; do make_home "s-$k" "$k" "$TMP/head-checkout/bin" >/dev/null; done
for k in off daemon dead; do
  printf '  %-30s -> %s\n' "fixture home away mode: $k" "$(FM_HOME="$TMP/s-$k" "$TMP/s-$k/bin/fm-afk-launch.sh" status)"
done
printf '\n  (the "daemon" and "dead" homes carry the SAME state/.afk file on disk;\n   only the liveness of the process recorded in the daemon lock differs.)\n'

hr "2. TURN END, Stop-owned watcher auto-arm (bin/fm-claude-stop-autoarm.sh)"
sub "BASE $BASE - away flag present, daemon DEAD (the reported defect)"
make_home "b-dead" dead "$TMP/base-checkout/bin" >/dev/null
run_stop_hook "$TMP/b-dead"
sub "THIS BRANCH - away flag present, daemon DEAD"
make_home "h-dead" dead "$TMP/head-checkout/bin" >/dev/null
run_stop_hook "$TMP/h-dead"
sub "THIS BRANCH - away flag present, daemon ALIVE (must be unchanged: one supervision cycle, the daemon's)"
make_home "h-live" daemon "$TMP/head-checkout/bin" >/dev/null
run_stop_hook "$TMP/h-live"
sub "BASE $BASE - away flag present, daemon ALIVE (control)"
make_home "b-live" daemon "$TMP/base-checkout/bin" >/dev/null
run_stop_hook "$TMP/b-live"

hr "3. TURN END, supervision guard block reason (bin/fm-turnend-guard.sh)"
sub "BASE $BASE - away flag present, daemon DEAD"
make_home "b-guard-dead" dead "$TMP/base-checkout/bin" >/dev/null
run_turnend_guard "$TMP/b-guard-dead"
sub "THIS BRANCH - away flag present, daemon DEAD"
make_home "h-guard-dead" dead "$TMP/head-checkout/bin" >/dev/null
run_turnend_guard "$TMP/h-guard-dead"
sub "THIS BRANCH - away flag present, daemon ALIVE (unchanged guidance)"
make_home "h-guard-live" daemon "$TMP/head-checkout/bin" >/dev/null
run_turnend_guard "$TMP/h-guard-live"

hr "4. SESSION START digest (bin/fm-session-start.sh) - what the first mate is told on restart"
make_home "b-ss-dead" dead "$TMP/base-checkout/bin" >/dev/null
make_home "h-ss-dead" dead "$TMP/head-checkout/bin" >/dev/null
make_home "h-ss-live" daemon "$TMP/head-checkout/bin" >/dev/null
sub "BASE $BASE - away flag present, daemon DEAD: supervision line, AFK section, next step"
run_session_start "$TMP/b-ss-dead" | digest_slice
sub "THIS BRANCH - away flag present, daemon DEAD"
run_session_start "$TMP/h-ss-dead" | digest_slice
sub "THIS BRANCH - away flag present, daemon ALIVE (unchanged)"
run_session_start "$TMP/h-ss-live" | digest_slice

hr "5. ENTERING away mode natively: the entry can no longer claim a supervision it has not got"
# start-native writes the flag BEFORE any harness-native background job exists
# and cannot wait for it, so this is the entry the /afk skill must confirm.
make_home "h-entry" off "$TMP/head-checkout/bin" >/dev/null
sub "bin/fm-afk-launch.sh start-native (this branch)"
FM_HOME="$TMP/h-entry" "$TMP/h-entry/bin/fm-afk-launch.sh" start-native
printf '  [exit=%s]  [state/.afk written: %s]\n' "$?" "$([ -e "$TMP/h-entry/state/.afk" ] && echo yes || echo no)"
sub "what the /afk skill must now read before it may report away mode active"
printf '  bin/fm-afk-launch.sh status -> %s\n' "$(FM_HOME="$TMP/h-entry" "$TMP/h-entry/bin/fm-afk-launch.sh" status)"
printf '  (not "daemon", so the skill reports away mode NOT running instead of active)\n'
sub "and the home is not left blind: the Stop-owned auto-arm still covers it"
run_stop_hook "$TMP/h-entry"

hr "6. Flag ownership: no mechanism cleared state/.afk anywhere above"
for h in "$TMP"/h-* "$TMP"/b-* "$TMP"/s-daemon "$TMP"/s-dead; do
  [ -d "$h/state" ] || continue
  printf '  %-16s state/.afk present: %s\n' "$(basename "$h")" "$([ -e "$h/state/.afk" ] && echo yes || echo NO)"
done
printf '\n'
