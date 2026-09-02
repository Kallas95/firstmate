#!/usr/bin/env bash
# Focused lifecycle contract checks for Firstmate's additive Pi model-status badge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-model-status-badge.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMP_ROOT=$(fm_test_tmproot fm-model-status-badge)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "skip: node or npm not found for Pi model-status badge test"
  exit 0
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

mkdir -p "$TMP_ROOT/project/node_modules/@earendil-works"
cp "$EXT" "$TMP_ROOT/project/fm-model-status-badge.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/project/node_modules/@earendil-works/pi-coding-agent"
printf '%s\n' '{"type":"module"}' >"$TMP_ROOT/project/package.json"

out=$(cd "$TMP_ROOT/project" && node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
};
const extension = await import(`${pathToFileURL("./fm-model-status-badge.ts").href}?test=${Date.now()}`);
extension.default(pi);

for (const event of ["session_start", "model_select", "thinking_level_select", "session_shutdown"]) {
  if (!handlers.has(event)) throw new Error(`badge did not register ${event}`);
}
if (handlers.size !== 4) throw new Error(`badge registered unexpected lifecycle hooks: ${[...handlers.keys()].join(", ")}`);

const statuses = [];
const ui = {
  setStatus(key, value) {
    statuses.push([key, value]);
  },
};
const context = {
  hasUI: true,
  ui,
  model: { provider: "openrouter", id: "openai/gpt-4.1-nano" },
  thinkingLevel: "medium",
};

handlers.get("session_start")({}, context);
if (JSON.stringify(statuses.pop()) !== JSON.stringify(["firstmate-model-status-badge", "openrouter · medium"])) {
  throw new Error("session start did not render only provider and effort");
}

context.model = { provider: "ollama-cloud", id: "qwen3.5:cloud" };
context.thinkingLevel = "off";
handlers.get("model_select")({}, context);
if (JSON.stringify(statuses.pop()) !== JSON.stringify(["firstmate-model-status-badge", "ollama-cloud · off"])) {
  throw new Error("model change did not refresh provider and effort");
}

context.thinkingLevel = "xhigh";
handlers.get("thinking_level_select")({}, context);
if (JSON.stringify(statuses.pop()) !== JSON.stringify(["firstmate-model-status-badge", "ollama-cloud · xhigh"])) {
  throw new Error("thinking-level change did not refresh the badge");
}

context.model = undefined;
handlers.get("model_select")({}, context);
if (JSON.stringify(statuses.pop()) !== JSON.stringify(["firstmate-model-status-badge", undefined])) {
  throw new Error("missing model did not clear the badge");
}

handlers.get("session_shutdown")({}, context);
if (JSON.stringify(statuses.pop()) !== JSON.stringify(["firstmate-model-status-badge", undefined])) {
  throw new Error("session shutdown did not clear the badge");
}

const noUiContext = {
  ...context,
  hasUI: false,
  ui: {
    setStatus() {
      throw new Error("badge touched UI without one");
    },
  },
};
for (const event of ["session_start", "model_select", "thinking_level_select", "session_shutdown"]) {
  handlers.get(event)({}, noUiContext);
}
JS
)
status=$?
[ "$status" -eq 0 ] || fail "Pi model-status badge lifecycle contract failed: $out"
[ -z "$out" ] || fail "Pi model-status badge lifecycle contract printed output: $out"
pass "Pi model-status badge is an additive provider and effort status only, refreshes on model and effort changes, clears on shutdown, and is inert without UI"
