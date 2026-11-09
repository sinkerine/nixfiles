import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerWorkflowResource, type WorkflowResourceRegistration } from "@SUBAGENTS@/src/api/workflow-resources.ts";

const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
const inside = (root: string, target: string) => {
  const relative = path.relative(root, target);
  return relative === "" || (!path.isAbsolute(relative) && relative !== ".." && !relative.startsWith(".." + path.sep));
};

/** Native host verification; no model child or child acceptance report is involved. */
export default function e2eVerification(pi: ExtensionAPI) {
  let registration: WorkflowResourceRegistration | undefined;
  pi.on("session_start", (_event, ctx) => {
    registration?.dispose();
    const cwd = realpathSync(ctx.cwd);
    const sessionId = ctx.sessionManager.getSessionId();
    if (!sessionId) return;
    registration = registerWorkflowResource({ sessionId, definition: {
      name: "e2e-verify", version: 1,
      resolve(args) {
        if (Object.keys(args).some(key => !["feature", "recipe", "checks", "phase", "refresh", "timeoutMs", "jobs"].includes(key))) return { error: "e2e-verify accepts feature, recipe, checks, phase, refresh, timeoutMs, jobs." };
        if (typeof args.feature !== "string" || !/^[a-z0-9][a-z0-9-]{0,79}$/.test(args.feature)) return { error: "feature must be a lowercase slug." };
        if (typeof args.recipe !== "string" || !args.recipe || args.recipe.length > 4096 || args.recipe.includes("\0")) return { error: "recipe must name a JSON file in this worktree or its e2e run directory." };
        if (args.checks !== undefined && (!Array.isArray(args.checks) || args.checks.length > 64 || args.checks.some(id => typeof id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/.test(id)))) return { error: "checks must contain up to 64 safe check ids." };
        if (args.phase !== undefined && !["smoke", "task", "full", "e2e"].includes(args.phase as string)) return { error: "phase must be smoke, task, full, or e2e." };
        if (args.refresh !== undefined && typeof args.refresh !== "boolean") return { error: "refresh must be boolean." };
        if (args.jobs !== undefined && (typeof args.jobs !== "number" || !Number.isSafeInteger(args.jobs) || args.jobs < 1 || args.jobs > 16)) return { error: "jobs must be 1..16 and cannot exceed the recipe limit." };
        const timeoutMs = args.timeoutMs ?? 3_600_000;
        if (typeof timeoutMs !== "number" || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 86_400_000) return { error: "timeoutMs must be 1..86400000." };
        const gitDir = execFileSync("git", ["-C", cwd, "rev-parse", "--absolute-git-dir"], { encoding: "utf8", timeout: 5000 }).trim();
        const recipe = realpathSync(path.resolve(cwd, args.recipe));
        if (!inside(cwd, recipe) && !inside(path.join(gitDir, "e2e-feature", args.feature), recipe)) return { error: "recipe resolves outside this worktree and feature run directory." };
        JSON.parse(readFileSync(recipe, "utf8"));
        const argv = ["verify", "--feature", args.feature, "--recipe", recipe];
        for (const id of (args.checks ?? []) as string[]) argv.push("--check", id);
        if (args.phase) argv.push("--phase", args.phase as string);
        if (args.refresh) argv.push("--refresh");
        if (args.jobs !== undefined) argv.push("--jobs", String(args.jobs));
        const command = "cd " + quote(cwd) + " && " + quote("@E2E_RUNNER@/bin/e2e-feature-run") + " " + argv.map(quote).join(" ");
        const params = { kind: "command", command, timeoutMs, role: "gate" };
        return {
          script: `const result = await runs.host("verify", ${JSON.stringify(params)}); return {ok: result.ok, state: result.state, exitCode: result.exitCode, receipt: result.outputPath, durationMs: result.durationMs};`,
          hostCommands: [{ key: "verify", command }],
        };
      },
    } });
  });
  pi.on("session_shutdown", () => { registration?.dispose(); registration = undefined; });
}
