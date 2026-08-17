#!/usr/bin/env bash
# Throwaway probe: what does the spawn actually send to the terminal backend?
set -u
EVID_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=${FM_EVIDENCE_REPO:?}
# shellcheck source=/dev/null
. "$REPO/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-guard-probe)
FAKE="$TMP_ROOT/fake"
fakebin=$(fm_fakebin "$FAKE")
cat > "$TMP_ROOT/tmux.staged" <<'SH'
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
install -m 755 "$TMP_ROOT/tmux.staged" "$fakebin/tmux"
fm_fake_exit0 "$fakebin" treehouse pi claude opencode
home="$TMP_ROOT/home"; proj="$TMP_ROOT/project"; wt="$TMP_ROOT/wt"
mkdir -p "$home/data/probe" "$home/projects" "$home/state" "$home/config"
printf 'pi\n' > "$home/config/crew-harness"
fm_git_worktree "$proj" "$wt" wt-probe
touch "$home/state/.last-watcher-beat"
printf 'brief\n' > "$home/data/probe/brief.md"
LOG="$TMP_ROOT/tmux.log"
FM_TMUX_LOG="$LOG" FM_ROOT_OVERRIDE="$REPO" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  PATH="$fakebin:$PATH" \
  "$REPO/bin/fm-spawn.sh" probe "$proj" --mode no-mistakes --yolo off >/dev/null 2>&1
echo "=== tmux log lines mentioning pi-ext ==="
grep -n 'pi-ext' "$LOG" | head -5
echo "=== state files ==="
ls "$home/state" | head -20
echo "=== any state file mentioning pi-ext ==="
grep -rln 'pi-ext' "$home/state" | head -5
cp "$LOG" "$EVID_DIR/probe-tmux.log" 2>/dev/null || true
