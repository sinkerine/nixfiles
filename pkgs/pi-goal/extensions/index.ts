import * as fs from "node:fs";
import { execFileSync } from "node:child_process";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Runtime, agentEnvelope, isDelegatedGoalSession, type Binding } from "./runtime.ts";
import { Store, type Goal } from "./store.ts";
import { BackgroundWorkProbe } from "./goal-background-work.ts";
import { networkErrorBackoffPlan } from "./network-error-backoff.ts";
import { fetchQuotaRetryPlan, quotaRetryUrl } from "./quota-retry.ts";

const continuation = fs.readFileSync(new URL("../prompts/continuation.md", import.meta.url), "utf8") +
  "\nNever launch, revive, or restart workers solely because this continuation arrived; first confirm from authoritative state (run status, process, files) that no live writer owns the work.\n" +
  "While pi-subagents runs are active you are not woken by continuations; end the turn when nothing is runnable.\n";
const budget = fs.readFileSync(new URL("../prompts/budget_limit.md", import.meta.url), "utf8");
function render(template: string, goal: Goal): string {
  const values: Record<string, string | number> = { objective: goal.objective, tokens_used: goal.tokensUsed,
    token_budget: goal.tokenBudget ?? "unlimited", remaining_tokens: goal.tokenBudget === null ? "unlimited" : Math.max(0, goal.tokenBudget - goal.tokensUsed), time_used_seconds: Math.round(goal.timeUsedSeconds) };
  return template.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, key) => String(values[key] ?? ""));
}
export default function (pi: ExtensionAPI) {
  if (isDelegatedGoalSession()) return;
  let runtime: Runtime | undefined;
  let current: ExtensionContext | undefined;
  let probe: BackgroundWorkProbe | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let queued = false;
  let tools = 0;
  let started = Date.now();
  let errors = 0;
  let failure = false;
  let aborted = false;
  let generation = 0;
  const store = new Store();
  const message = (text: string, goal: Goal, triggerTurn = false) => pi.sendMessage({ customType: "pi-goal",
    content: text, display: false, details: { ...runtime!.details(goal), continuation: triggerTurn } },
    { triggerTurn, deliverAs: "followUp" });
  const schedule = (at: number) => {
    clearTimeout(timer);
    timer = setTimeout(() => { timer = undefined; void runtime?.settle(); }, Math.min(2_147_483_647, Math.max(1, at - Date.now())));
    timer.unref?.();
  };
  const requireRuntime = () => { if (!runtime) throw new Error("Goal session is not initialized"); return runtime; };
  const restore = (ctx: ExtensionContext) => {
    const epoch = generation;
    clearTimeout(timer); queued = false; errors = 0; current = ctx;
    let binding: Binding | undefined;
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom") continue;
      if (entry.customType === "pi-goal:bind") binding = entry.data as Binding;
      if (entry.customType === "pi-goal:unbind") binding = undefined;
      if (entry.customType === "pi-goal:snapshot" && binding && (entry.data as Binding)?.goalId === binding.goalId)
        binding = { ...binding, snapshot: (entry.data as Binding).snapshot };
    }
    let repoRoot = ctx.cwd;
    try { repoRoot = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: ctx.cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { /* non-git cwd */ }
    runtime = new Runtime(store, ctx.sessionManager.getSessionId(), repoRoot, ctx.cwd, {
      entry: (type, data) => pi.appendEntry(type, data),
      notify: (text, goal) => {
        if (goal.status === "budget_limited" && text === "Token budget reached") {
          queued = true; message(render(budget, goal), goal, true);
        } else message(text, goal);
      },
      dispatch: goal => { queued = true; message(render(continuation, goal), goal, true); },
      activeRuns: () => probe?.activeRuns() ?? Promise.resolve(undefined),
      idle: () => epoch === generation && !queued && !!current?.isIdle() && !current?.hasPendingMessages(), schedule,
    });
    runtime.restore(binding);
  };
  pi.on("session_start", async (_event, ctx) => {
    generation++; probe?.dispose(); probe = new BackgroundWorkProbe(pi.events);
    restore(ctx); schedule(Date.now() + 1);
  });
  pi.on("session_tree", async (_event, ctx) => { generation++; restore(ctx); schedule(Date.now() + 1); });
  pi.on("session_shutdown", async () => { generation++; clearTimeout(timer); probe?.dispose(); runtime = undefined; current = undefined; });
  pi.on("before_agent_start", async (event, ctx) => {
    current = ctx; queued = false; clearTimeout(timer);
    const r = requireRuntime();
    const text = event.messageType === "user" ? event.prompt : "";
    const envelope = agentEnvelope(text);
    r.userTriggered = event.messageType === "user" && !envelope;
    r.continuation = event.messageType === "custom" && event.message.customType === "pi-goal" &&
      (event.message.details as { continuation?: boolean })?.continuation === true;
    r.begin();
    r.input(text, r.userTriggered);
    tools = 0; failure = false; aborted = false;
  });
  pi.on("message_start", async (event) => {
    if (event.message.role !== "user" || !runtime) return;
    const text = typeof event.message.content === "string" ? event.message.content :
      event.message.content.filter(b => b.type === "text").map(b => b.text).join("\n");
    const directUser = !agentEnvelope(text);
    runtime.input(text, directUser);
    // Steering messages can arrive inside a running continuation, without a
    // second before_agent_start. The next request is now user-triggered.
    runtime.userTriggered = directUser;
    runtime.continuation = false;
  });
  pi.on("tool_execution_start", async () => { tools++; });
  pi.on("turn_start", async () => { started = Date.now(); });
  pi.on("turn_end", async (event) => {
    const msg = event.message;
    if (msg.role !== "assistant" || !runtime) return;
    runtime.account(msg.usage.totalTokens, (Date.now() - started) / 1000);
    aborted ||= msg.stopReason === "aborted";
    if (msg.stopReason !== "error") {
      if (msg.stopReason !== "aborted") {
        errors = 0; failure = false;
        const goal = runtime.goal();
        if (goal?.retry && goal.ownerSessionId === runtime.session) store.mutate(goal.id, runtime.session, "recovered", g => {
          if (g.ownerSessionId === runtime!.session) g.retry = null;
        });
      }
      return;
    }
    failure = true;
    const r = runtime;
    const goal = r.goal();
    if (!goal || goal.ownerSessionId !== r.session || goal.status !== "active") return;
    const error = msg.errorMessage ?? "Provider error";
    const quota = /quota|usage.?limit|rate.?limit|429|exhausted/i.test(error) ? quotaRetryUrl() : undefined;
    const epoch = generation;
    const plan = quota ? await fetchQuotaRetryPlan(quota) :
      { at: Date.now() + networkErrorBackoffPlan(++errors)!.delayMs, reason: error };
    if (epoch !== generation) return;
    store.mutate(goal.id, r.session, "retry", g => {
      if (g.ownerSessionId === r.session && g.status === "active") g.retry = plan;
    });
  });
  pi.on("agent_settled", async (event, ctx) => {
    current = ctx;
    runtime?.finish(tools, event.aborted || aborted, failure);
    await runtime?.settle();
  });
  pi.on("context", async (event) => {
    const context = runtime?.context();
    // Status-only custom messages are timeline data, never instructions for a model request.
    const messages = event.messages.filter(m => m.role !== "custom" || m.customType !== "pi-goal" ||
      (m.details as { continuation?: boolean })?.continuation === true);
    if (context) messages.push({ role: "custom", customType: "pi-goal-context", content: context, display: false, timestamp: Date.now() });
    return { messages };
  });
  const id = Type.Optional(Type.String());
  const wait = Type.Union([Type.Object({ kind: Type.Literal("ready") }), Type.Object({
    kind: Type.Literal("wait"), reason: Type.String({ minLength: 1 }), deadline: Type.String(),
    message: Type.Optional(Type.Object({ source_agent_id: Type.String({ minLength: 1 }), prefix: Type.String({ minLength: 1 }) })) })]);
  const schemas = {
    get_goal: Type.Object({ goal_id: id }), list_goals: Type.Object({}),
    create_goal: Type.Object({ objective: Type.String({ minLength: 1 }), token_budget: Type.Optional(Type.Integer({ minimum: 1 })) }),
    update_goal: Type.Object({ goal_id: id, status: Type.Optional(Type.Union(["active", "paused", "blocked", "complete"].map(s => Type.Literal(s)))), reason: Type.Optional(Type.String()), continuation: Type.Optional(wait) }),
    adopt_goal: Type.Object({ goal_id: Type.String() }), clear_goal: Type.Object({ goal_id: id }),
  };
  const descriptions = {
    get_goal: "Read the full session goal, or a goal by id.", list_goals: "List this repository's session goals and their owners.",
    create_goal: "Create a session goal only when explicitly requested by user or system/developer instructions. Preserve the full objective verbatim. Returns id and status.",
    update_goal: "Update a goal after completion audit, or same blocker in three consecutive goal turns. Pause/resume only on a user-triggered turn. Waits persist automatically; ready is optional.",
    adopt_goal: "Transfer ownership only on an explicit user or handoff request. Preserves paused state.",
    clear_goal: "Archive a goal only in a user-triggered turn.",
  };
  for (const name of Object.keys(schemas) as (keyof typeof schemas)[]) pi.registerTool({
    name, label: name, description: descriptions[name], parameters: schemas[name], executionMode: "sequential",
    async execute(_call, params) {
      const r = requireRuntime();
      // Each registration has a different schema; dispatch retains its runtime-validated parameters.
      const p = params as { goal_id?: string; objective?: string; token_budget?: number } & Parameters<Runtime["update"]>[0];
      if (name === "list_goals") return { content: [{ type: "text", text: JSON.stringify(store.list(r.repoRoot).map(g => ({ ...r.details(g).goal, bound: g.id === r.bound }))) }], details: r.details() };
      const goal = name === "create_goal" ? r.create(p.objective!, p.token_budget) : name === "update_goal" ? r.update(p) :
        name === "adopt_goal" ? r.adopt(p.goal_id!) : name === "clear_goal" ? r.clear(p.goal_id) : r.goal(p.goal_id);
      return { content: [{ type: "text", text: JSON.stringify(name === "create_goal" ? { id: goal!.id, status: goal!.status } : goal ?? null) }], details: r.details(goal) };
    },
  });
  for (const name of ["goal", "goal-list", "goal-pause", "goal-resume", "goal-clear", "goal-adopt"]) pi.registerCommand(name, {
    description: descriptions[name === "goal" ? "get_goal" : name === "goal-list" ? "list_goals" : name === "goal-adopt" ? "adopt_goal" : name === "goal-clear" ? "clear_goal" : "update_goal"],
    async handler(args, ctx) {
      const r = requireRuntime(); current = ctx;
      const arg = args.trim();
      try {
        if (name === "goal-list") { ctx.ui.notify(JSON.stringify(store.list(r.repoRoot).map(g => r.details(g).goal)), "info"); return; }
        if (name === "goal-clear" && ctx.hasUI && !(await ctx.ui.confirm("Clear goal?", arg || r.bound || "No goal"))) return;
        const goal = name === "goal" ? (arg ? r.create(args) : r.goal()) : name === "goal-adopt" ? (() => {
          const previous = r.userTriggered; r.userTriggered = true;
          try { return r.adopt(arg); } finally { r.userTriggered = previous; }
        })() : name === "goal-clear" ? r.clear(arg || undefined, true) :
          r.update({ goal_id: arg || undefined, status: name === "goal-pause" ? "paused" : "active" }, true);
        if (goal) { message(`Goal ${goal.id}: ${goal.status}`, goal); ctx.ui.notify(JSON.stringify(r.details(goal).goal), "info"); }
        else ctx.ui.notify("No goal is bound", "info");
        schedule(Date.now() + 1);
      } catch (error) { ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); }
    },
  });
}
