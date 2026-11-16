import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerWorkflowResource, type WorkflowResourceRegistration } from "@SUBAGENTS@/src/api/workflow-resources.ts";

/** Wait on the submitting host without spending model turns on status polling. */
export default function qexWait(pi: ExtensionAPI) {
  let registration: WorkflowResourceRegistration | undefined;
  const dispose = () => { registration?.dispose(); registration = undefined; };
  pi.on("session_start", (_event, ctx) => {
    dispose();
    const sessionId = ctx.sessionManager.getSessionId();
    if (!sessionId) return;
    registration = registerWorkflowResource({ sessionId, definition: {
      name: "qex-wait", version: 1,
      resolve(args) {
        if (Object.keys(args).some(key => !["id", "timeoutMs"].includes(key))) return { error: "qex-wait accepts id and timeoutMs; run it on the host that submitted the job." };
        if (typeof args.id !== "string" || !/^(?:[a-f0-9]{8,32}|[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/.test(args.id)) return { error: "id must be the retained qex UUID or a lowercase hexadecimal prefix of at least 8 characters." };
        // Include queue wait in this deadline; the job execution timeout starts at admission.
        const timeoutMs = args.timeoutMs ?? 3_600_000;
        if (typeof timeoutMs !== "number" || !Number.isSafeInteger(timeoutMs) || timeoutMs < 60_000 || timeoutMs > 86_340_000) return { error: "timeoutMs must be 60000..86340000; allow for queue wait plus execution." };
        const command = `@QEX@/bin/qex status ${args.id} --wait --timeout ${timeoutMs / 1000}s --json --no-logs`;
        const params = { kind: "command", command, timeoutMs: timeoutMs + 60_000, role: "gate" };
        return {
          script: `const result = await runs.host("wait", ${JSON.stringify(params)}); return {ok: result.ok, state: result.state, exitCode: result.exitCode, receipt: result.outputPath, durationMs: result.durationMs, jobId: ${JSON.stringify(args.id)}};`,
          hostCommands: [{ key: "wait", command }],
        };
      },
    } });
  });
  pi.on("session_shutdown", dispose);
}
