import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROVIDER = "magpie";
const MODEL = "gpt-6.1-sol";

// Skill frontmatter cannot pick a model, so switch the parent session here.
// The input event fires before /skill:name is expanded.
export default function (pi: ExtensionAPI) {
  pi.on("input", async (event, ctx) => {
    if (!/^\/skill:e2e-feature(\s|$)/.test(event.text)) {
      return { action: "continue" };
    }
    if (ctx.model?.provider === PROVIDER && ctx.model.id === MODEL) {
      return { action: "continue" };
    }

    const model = ctx.modelRegistry.find(PROVIDER, MODEL);
    if (!model || !(await pi.setModel(model))) {
      ctx.ui.notify(
        `e2e-feature requires ${PROVIDER}/${MODEL}, which could not be selected; not starting.`,
        "error",
      );
      return { action: "handled" };
    }

    ctx.ui.notify(`e2e-feature: parent model set to ${PROVIDER}/${MODEL}`, "info");
    return { action: "continue" };
  });
}
