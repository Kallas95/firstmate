#!/usr/bin/env bash
# Focused lifecycle contract checks for Firstmate's additive Pi model-status badge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/.pi/extensions/fm-model-status-badge.ts"
TMP_ROOT=$(fm_test_tmproot fm-model-status-badge)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node not found for Pi model-status badge test"
  exit 0
fi

mkdir -p "$TMP_ROOT/project"
cp "$EXT" "$TMP_ROOT/project/fm-model-status-badge.ts"
printf '%s\n' '{"type":"module"}' >"$TMP_ROOT/project/package.json"
cat >"$TMP_ROOT/project/typescript-loader.mjs" <<'JS'
import { readFile } from "node:fs/promises";

export async function load(url, context, nextLoad) {
  if (!new URL(url).pathname.endsWith(".ts")) return nextLoad(url, context);

  let source = await readFile(new URL(url), "utf8");
  source = source
    .replace(/^import type .*;\r?\n/m, "")
    .replace(/:\s*(?:ExtensionAPI|ExtensionContext)(?=\))/g, "")
    .replace(/:\s*void(?=\s*\{)/g, "");
  return { format: "module", shortCircuit: true, source };
}
JS

out=$(cd "$TMP_ROOT/project" && node --no-warnings --experimental-loader ./typescript-loader.mjs --input-type=module 2>&1 <<'JS'
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
