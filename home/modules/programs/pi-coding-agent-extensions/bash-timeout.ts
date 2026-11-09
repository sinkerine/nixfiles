import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const DEFAULT_TIMEOUT_SECONDS = 120;

export default function bashTimeout(pi: ExtensionAPI) {
  // tool_call also covers nested calls from codemode and other extensions.
  pi.on("tool_call", (event) => {
    if (event.toolName !== "bash") return;

    const timeout = event.input.timeout;
    if (typeof timeout !== "number" || !Number.isFinite(timeout) || timeout <= 0) {
      event.input.timeout = DEFAULT_TIMEOUT_SECONDS;
    }
  });

  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.bash_timeout =
      `Bash commands default to a ${DEFAULT_TIMEOUT_SECONDS}-second execution timeout. ` +
      "Set an explicit positive timeout in seconds for commands expected to take longer. " +
      "Scope filesystem searches to relevant directories.";
  });
}
