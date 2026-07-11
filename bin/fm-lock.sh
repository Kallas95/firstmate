#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

# Windows (Git Bash/MSYS): the native parent chain is invisible to MSYS ps
# (the shell's PPID reads as 1), so walk it via PowerShell CIM instead.
# Lock-file pids are then Windows pids; holder_alive falls back the same way.
harness_pid_win() {
  local pid=$$ ppid top wpid out
  command -v powershell.exe >/dev/null 2>&1 || return 1
  # Climb the MSYS side first: nested shells hit dead fork intermediates in
  # the native chain, but the TOP MSYS ancestor's native parent is the live
  # harness process.
  top=$pid
  while :; do
    ppid=$(cat "/proc/$pid/ppid" 2>/dev/null) || break
    [ -n "$ppid" ] && [ "$ppid" -gt 1 ] || break
    pid=$ppid; top=$pid
  done
  wpid=$(cat "/proc/$top/winpid" 2>/dev/null) || return 1
  out=$(FM_WPID="$wpid" FM_HARNESS_RE="$HARNESS_RE" powershell.exe -NoProfile -Command '
    $id = [int]$env:FM_WPID
    for ($i = 0; $i -lt 12 -and $id -gt 4; $i++) {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
      if (-not $p) { exit 1 }
      $n = $p.Name -replace "\.exe$",""
      if ($n -match $env:FM_HARNESS_RE) { Write-Output $p.ProcessId; exit 0 }
      if ($n -match "^(node|python[0-9.]*)$" -and $p.CommandLine -match $env:FM_HARNESS_RE) { Write-Output $p.ProcessId; exit 0 }
      $id = $p.ParentProcessId
    }
    exit 1' 2>/dev/null | tr -d '\r ')
  [ -n "$out" ] || return 1
  echo "$out"
}

holder_alive_win() {  # true if $1 is a live WINDOWS pid that looks like a harness
  local out
  command -v powershell.exe >/dev/null 2>&1 || return 1
  out=$(FM_WPID="$1" powershell.exe -NoProfile -Command '
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$env:FM_WPID)" -ErrorAction SilentlyContinue
    if ($p) { Write-Output (($p.Name -replace "\.exe$","") + " " + $p.CommandLine) }' 2>/dev/null | tr -d '\r')
  [ -n "$out" ] && printf '%s' "$out" | grep -qE "$HARNESS_RE"
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  if kill -0 "$pid" 2>/dev/null && comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
    printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE" && return 0
  fi
  holder_alive_win "$pid"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || me=$(harness_pid_win) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
