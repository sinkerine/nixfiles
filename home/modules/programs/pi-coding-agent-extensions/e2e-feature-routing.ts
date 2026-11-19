import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const provider = "magpie";
const models = ["group/agy-opus", "group/opus", "group/sol"];
const invocation = /^\/skill:e2e-feature(?: |$)/;
const skillBlock = '<skill name="e2e-feature" location="';
const quotaError = /\b(?:insufficient_quota|quota_exhausted|usage_limit_reached|out of (?:quota|its allowance)|quota (?:has been )?(?:exhausted|exceeded)|quota will reset|exceeded your (?:current )?quota|usage limit (?:has been )?reached|hit your (?:\w+ )?limit\b[^\n]*\bresets)\b/i;

export default function (pi: ExtensionAPI) {
  const hasInvocation = (ctx: ExtensionContext) =>
    ctx.sessionManager.getBranch().some((entry) =>
      entry.type === "message" && entry.message.role === "user" &&
      (typeof entry.message.content === "string"
        ? entry.message.content.startsWith(skillBlock)
        : entry.message.content.some((part) => part.type === "text" && part.text.startsWith(skillBlock))),
    );

  pi.on("input", async (event, ctx) => {
    if (!invocation.test(event.text)) return;

    const continuing = hasInvocation(ctx) && ctx.model?.provider === provider && models.includes(ctx.model.id);
    if (!continuing && (ctx.model?.provider !== provider || ctx.model.id !== models[0])) {
      const primary = ctx.modelRegistry.find(provider, models[0]);
      if (!primary || !await pi.setModel(primary)) {
        ctx.ui.notify("E2E feature could not select AGY Opus. Check the Magpie model and credentials.", "error");
        return { action: "handled" };
      }
    }
    pi.setThinkingLevel("medium");
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (event.outcome !== "error" || ctx.model?.provider !== provider) return;
    const index = models.indexOf(ctx.model.id);
    if (index < 0 || index === models.length - 1) return;

    const failed = event.context.contextEntries.findLast((entry) => entry.messages.length > 0)?.sourceEntry;
    if (failed?.type !== "message" || failed.message.role !== "assistant" ||
        failed.message.stopReason !== "error" || failed.message.provider !== provider ||
        failed.message.model !== ctx.model.id || !quotaError.test(failed.message.errorMessage ?? "") ||
        !hasInvocation(ctx)) return;

    const next = ctx.modelRegistry.find(provider, models[index + 1]);
    if (!next || !await pi.setModel(next)) {
      ctx.ui.notify(`E2E feature could not select ${provider}/${models[index + 1]}.`, "error");
      return;
    }
    pi.setThinkingLevel("medium");
    ctx.ui.notify(`E2E feature quota exhausted on ${failed.message.model}. Continuing on ${next.id} (medium).`, "warning");

    return {
      entries: [...event.entries, { type: "context_edit", targetId: failed.id, replacement: null }],
      continue: true,
    };
  });
}
