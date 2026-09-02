// Firstmate's additive stock-Pi provider and effort badge.
//
// This extension deliberately owns only its keyed footer status. It does not replace
// Pi's footer or title, read configuration, register commands or tools, make model
// calls, or participate in any Firstmate lifecycle behavior.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "firstmate-model-status-badge";

function renderBadge(ctx: ExtensionContext): void {
  if (!ctx.hasUI) return;

  const provider = ctx.model?.provider;
  if (!provider) {
    ctx.ui.setStatus(STATUS_KEY, undefined);
    return;
  }

  ctx.ui.setStatus(STATUS_KEY, `${provider} · ${ctx.thinkingLevel}`);
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    renderBadge(ctx);
  });

  pi.on("model_select", (_event, ctx) => {
    renderBadge(ctx);
  });

  pi.on("thinking_level_select", (_event, ctx) => {
    renderBadge(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (ctx.hasUI) ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}
