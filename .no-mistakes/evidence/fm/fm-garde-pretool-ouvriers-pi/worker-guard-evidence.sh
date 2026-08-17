#!/usr/bin/env bash
# End-to-end evidence driver for the worker command guard.
#
# Spawns a REAL Pi worker with bin/fm-spawn.sh, then drives the per-task Pi
# extension that spawn generated through the same tool_call handler Pi itself
# calls, one acceptance-criterion tool call at a time, with Pi's own tool names
# (bash, read, grep, write, edit) and Pi's own input fields (command, path).
# Then the same for the Claude application point through its recorded PreToolUse
# hook command, the one-owner proof, and the guard-absent outcomes.
#
# Section 0 reproduces the reported hole against the BASE commit's spawn.
# Perimeter cases live in perimeter-cases.tsv beside this file.
set -u

EVID_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=${FM_EVIDENCE_REPO:?set FM_EVIDENCE_REPO to the worktree root}
BASE_ROOT=${FM_EVIDENCE_BASE_ROOT:-}
CASES="$EVID_DIR/perimeter-cases.tsv"

# shellcheck source=/dev/null
. "$REPO/tests/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-worker-guard-evidence)

hr() { printf '%s\n' "--------------------------------------------------------------------------------"; }
title() { printf '\n'; hr; printf '%s\n' "$1"; hr; }

make_fakebin() {  # <dir>
  local dir=$1 fakebin staged
  fakebin=$(fm_fakebin "$dir")
  staged="$dir/tmux.staged"
  cat > "$staged" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  install -m 755 "$staged" "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi claude opencode
  printf '%s\n' "$fakebin"
}

# make_case <name> <harness> <id> <fmroot: real|copy|<path>>
make_case() {
  local name=$1 harness=$2 id=$3 mode=$4 case_dir home proj wt fakebin fmroot
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  case "$mode" in
    real) fmroot="$REPO" ;;
    copy)
      fmroot="$case_dir/fmroot"
      mkdir -p "$fmroot"
      cp -R "$REPO/bin" "$fmroot/bin"
      cp "$REPO/AGENTS.md" "$fmroot/AGENTS.md"
      ;;
    *) fmroot="$mode" ;;
  esac
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$fmroot"
}

run_spawn() {  # <home> <wt> <fakebin> <fmroot> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 fmroot=$4
  shift 4
  set -- "$@" --mode no-mistakes --yolo off
  FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$fmroot/bin/fm-spawn.sh" "$@" 2>&1
}

# drive_pi <ext> <toolName> <tool-json>: load the generated extension in a plain
# Node host and fire one tool_call through the very handler Pi calls.
# Prints allow | block<TAB>reason | unguarded (no tool_call handler at all).
drive_pi() {
  EXT_PATH="$1" TOOL_NAME="$2" TOOL_INPUT="$3" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
if (typeof handlers["tool_call"] !== "function") {
  process.stdout.write("unguarded (this worker registers no tool_call handler)");
} else {
  const r = await handlers["tool_call"]({
    type: "tool_call", toolName: process.env.TOOL_NAME,
    input: JSON.parse(process.env.TOOL_INPUT),
  });
  if (r && r.block) process.stdout.write("block\t" + String(r.reason || ""));
  else process.stdout.write("allow");
}
EOF
}

reason_code() { printf '%s' "$1" | grep -o '\[[a-z-]*\]' | head -1; }

# --- 0. the reported hole, against the BASE commit --------------------------

if [ -n "$BASE_ROOT" ]; then
  title "0. The reported hole, reproduced against the BASE commit's fm-spawn.sh"
  IFS='|' read -r Z_HOME Z_PROJ Z_WT Z_FAKEBIN Z_FMROOT <<EOF
$(make_case base-commit pi guard-evidence-base "$BASE_ROOT")
EOF
  run_spawn "$Z_HOME" "$Z_WT" "$Z_FAKEBIN" "$Z_FMROOT" guard-evidence-base "$Z_PROJ" >/dev/null
  Z_EXT="$Z_HOME/state/guard-evidence-base.pi-ext.ts"
  printf '  BEFORE (base commit) Pi worker, read tool on /srv/app/.env:\n'
  printf '    %s\n' "$(drive_pi "$Z_EXT" read '{"path":"/srv/app/.env"}')"
  printf '  BEFORE (base commit) Pi worker, bash tool running sudo:\n'
  printf '    %s\n' "$(drive_pi "$Z_EXT" bash '{"command":"sudo rm -rf /"}')"
fi

# --- 1. live Pi worker ------------------------------------------------------

IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN FMROOT <<EOF
$(make_case pi-live pi guard-evidence-pi real)
EOF

title "1. AFTER: a real Pi worker spawned by this branch's bin/fm-spawn.sh"
TMUX_LOG="$TMP_ROOT/pi-live-tmux.log"
FM_TMUX_LOG="$TMUX_LOG" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$FMROOT" guard-evidence-pi "$PROJ_DIR" >/dev/null
printf '  spawn exit: %s\n' "$?"
EXT="$HOME_DIR/state/guard-evidence-pi.pi-ext.ts"
printf '  per-task Pi extension written: %s\n' "$(basename "$EXT")"
printf '  the pi launch this spawn actually issued carries it:\n'
printf '    %s\n' "$(grep -o -- "pi' -e '[^']*pi-ext.ts'" "$TMUX_LOG" | head -1)"

title "2. Acceptance criterion 1, through that Pi worker's own tools"
printf '  %-8s %-6s %-8s %-42s %s\n' EXPECTED TOOL FIELD 'TOOL CALL' 'VERDICT'
FAILURES=0
while IFS=$'\t' read -r expected tool field value; do
  [ -n "${expected:-}" ] || continue
  json=$(jq -cn --arg k "$field" --arg v "$value" '{($k):$v}')
  out=$(drive_pi "$EXT" "$tool" "$json")
  case "$out" in
    block*) verdict="REFUSED $(reason_code "$out")"; actual=REFUSE ;;
    allow)  verdict="allowed"; actual=ALLOW ;;
    *)      verdict="UNEXPECTED: $out"; actual=? ;;
  esac
  printf '  %-8s %-6s %-8s %-42s %s\n' "$expected" "$tool" "$field" "$value" "$verdict"
  [ "$actual" = "$expected" ] || { FAILURES=$((FAILURES + 1)); printf '  !! MISMATCH on: %s\n' "$value"; }
done < "$CASES"
printf '\n  mismatches: %s\n' "$FAILURES"

# --- 3. the Claude application point ----------------------------------------

IFS='|' read -r C_HOME C_PROJ C_WT C_FAKEBIN C_FMROOT <<EOF
$(make_case claude-live claude guard-evidence-claude real)
EOF
run_spawn "$C_HOME" "$C_WT" "$C_FAKEBIN" "$C_FMROOT" guard-evidence-claude "$C_PROJ" >/dev/null
SETTINGS="$C_WT/.claude/settings.local.json"
HOOK=$(jq -r '(.hooks.PreToolUse // [])[0].hooks[0].command // empty' "$SETTINGS")

title "3. The SAME perimeter through the Claude worker's own PreToolUse hook"
printf '  registered matcher: %s\n' "$(jq -r '(.hooks.PreToolUse // [])[0].matcher' "$SETTINGS")"
printf '  registered command: %s\n\n' "$HOOK"
claude_call() {  # <payload>
  local out rc
  out=$(printf '%s' "$1" | bash -c "$HOOK" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then printf 'allowed\n'
  else printf 'REFUSED (exit %s) %s\n' "$rc" "$(reason_code "$out")"; fi
}
printf '  %-62s %s\n' '{"tool_name":"Bash",...{"command":"sudo id"}}' "$(claude_call '{"tool_name":"Bash","tool_input":{"command":"sudo id"}}')"
printf '  %-62s %s\n' '{"tool_name":"Read",...{"file_path":"/srv/app/.env"}}' "$(claude_call '{"tool_name":"Read","tool_input":{"file_path":"/srv/app/.env"}}')"
printf '  %-62s %s\n' '{"tool_name":"Bash",...{"command":"git push origin main"}}' "$(claude_call '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')"
printf '  %-62s %s\n' '{"tool_name":"Bash",...{"command":"git push origin HEAD"}}' "$(claude_call '{"tool_name":"Bash","tool_input":{"command":"git push origin HEAD"}}')"

# --- 4. one perimeter owner, two application points -------------------------

title "4. One perimeter owner: neutralize it and BOTH points change together"
IFS='|' read -r B_HOME B_PROJ B_WT B_FAKEBIN B_FMROOT <<EOF
$(make_case both-points pi guard-evidence-both copy)
EOF
run_spawn "$B_HOME" "$B_WT" "$B_FAKEBIN" "$B_FMROOT" guard-evidence-both "$B_PROJ" >/dev/null
B_EXT="$B_HOME/state/guard-evidence-both.pi-ext.ts"
B_CHECK="$B_FMROOT/bin/fm-worker-pretool-check.sh"
printf '  with bin/fm-worker-command-policy.mjs present:\n'
printf '    pi     -> %s\n' "$(reason_code "$(drive_pi "$B_EXT" bash '{"command":"ssh host"}')")"
printf '    claude -> %s\n' "$(reason_code "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ssh host"}}' | "$B_CHECK" --claude 2>&1)")"
rm -f "$B_FMROOT/bin/fm-worker-command-policy.mjs"
printf '  after removing that single owner:\n'
printf '    pi     -> %s\n' "$(reason_code "$(drive_pi "$B_EXT" bash '{"command":"ssh host"}')")"
printf '    claude -> %s\n' "$(reason_code "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ssh host"}}' | "$B_CHECK" --claude 2>&1)")"

# --- 5. no silent pass when the guard is absent -----------------------------

title "5. A worker without an active guard is refused, never silently permissive"
IFS='|' read -r M_HOME M_PROJ M_WT M_FAKEBIN M_FMROOT <<EOF
$(make_case guard-gone pi guard-evidence-gone copy)
EOF
run_spawn "$M_HOME" "$M_WT" "$M_FAKEBIN" "$M_FMROOT" guard-evidence-gone "$M_PROJ" >/dev/null
M_EXT="$M_HOME/state/guard-evidence-gone.pi-ext.ts"
rm -f "$M_FMROOT/bin/fm-worker-pretool-check.sh"
printf '  Pi worker whose guard transport was removed, ordinary tool call:\n'
printf '    %s\n' "$(drive_pi "$M_EXT" bash '{"command":"echo ordinary work"}' | tr '\t' ' ')"

IFS='|' read -r P_HOME P_PROJ P_WT P_FAKEBIN P_FMROOT <<EOF
$(make_case preflight pi guard-evidence-preflight copy)
EOF
rm -f "$P_FMROOT/bin/fm-worker-command-policy.mjs"
PRE_OUT=$(run_spawn "$P_HOME" "$P_WT" "$P_FAKEBIN" "$P_FMROOT" guard-evidence-preflight "$P_PROJ"); PRE_RC=$?
printf '\n  fm-spawn.sh launching a Pi worker whose guard runtime is missing:\n'
printf '    exit %s: %s\n' "$PRE_RC" "$PRE_OUT"
printf '    per-task extension written: %s\n' \
  "$([ -f "$P_HOME/state/guard-evidence-preflight.pi-ext.ts" ] && echo yes || echo no)"

IFS='|' read -r U_HOME U_PROJ U_WT U_FAKEBIN U_FMROOT <<EOF
$(make_case unwired opencode guard-evidence-unwired copy)
EOF
UNWIRED=$(run_spawn "$U_HOME" "$U_WT" "$U_FAKEBIN" "$U_FMROOT" guard-evidence-unwired "$U_PROJ"); U_RC=$?
printf '\n  fm-spawn.sh launching a worker on a harness with no application point:\n'
printf '    exit %s\n' "$U_RC"
printf '%s\n' "$UNWIRED" | grep WARNING | sed 's/^/    /'

printf '\n'
hr
printf 'RESULT: %s mismatch(es) against perimeter-cases.tsv\n' "$FAILURES"
hr
exit "$FAILURES"
