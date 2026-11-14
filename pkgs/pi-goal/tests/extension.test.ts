import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import extension from "../extensions/index.ts";
import { Store } from "../extensions/store.ts";

// This harness exercises the production event and command registrations. The
// separate CLI smoke drives these same paths through the installed Pi runtime.
function harness() {
  const handlers = new Map<string, Function>();
  const tools = new Map<string, any>();
  const commands = new Map<string, any>();
  const entries: any[] = [];
  const messages: any[] = [];
  const pi = {
    events: { on() { return () => {}; }, emit() {} },
    on(name: string, fn: Function) { handlers.set(name, fn); },
    registerTool(tool: any) { tools.set(tool.name, tool); },
    registerCommand(name: string, command: any) { commands.set(name, command); },
    appendEntry(customType: string, data: unknown) { entries.push({ type: "custom", customType, data }); },
    sendMessage(message: any, options: any) { messages.push({ ...message, options }); },
  };
  const ctx = { cwd: os.tmpdir(), hasUI: false, isIdle: () => true, hasPendingMessages: () => false,
    sessionManager: { getSessionId: () => "smoke-session", getBranch: () => entries },
    ui: { notify() {}, confirm: async () => true } };
  return { handlers, tools, commands, entries, messages, ctx, pi,
    async emit(name: string, data = {}) { return handlers.get(name)?.(data, ctx); } };
}
test("delegated factory registers no tools, commands or context handlers", () => {
  const previous = process.env.PI_SUBAGENT_CHILD;
  process.env.PI_SUBAGENT_CHILD = "1";
  try {
    const h = harness(); extension(h.pi as any);
    assert.equal(h.tools.size, 0); assert.equal(h.handlers.size, 0); assert.equal(h.commands.size, 0);
  } finally { if (previous === undefined) delete process.env.PI_SUBAGENT_CHILD; else process.env.PI_SUBAGENT_CHILD = previous; }
});
test("production hooks: no unfocused context, create, continuation, user pause/resume, restart and clear", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-goal-extension-"));
  const old = process.env.XDG_STATE_HOME;
  process.env.XDG_STATE_HOME = dir;
  t.after(() => { if (old === undefined) delete process.env.XDG_STATE_HOME; else process.env.XDG_STATE_HOME = old; fs.rmSync(dir, { recursive: true, force: true }); });
  const h = harness(); extension(h.pi as any);
  await h.emit("session_start");
  const context = await h.emit("context", { messages: [] }); assert.deepEqual(context.messages, []);
  await h.commands.get("goal").handler("write a file", h.ctx);
  assert.equal(h.entries[0].customType, "pi-goal:bind");
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(h.messages.filter(m => m.options.triggerTurn).length, 1);
  const start = h.messages.find(m => m.options.triggerTurn);
  assert.equal(start.customType, "pi-goal"); assert.equal(start.details.piGoal, 1);
  assert.match(start.content, /Never launch, revive, or restart/);
  await h.emit("before_agent_start", { messageType: "custom", message: start });
  await assert.rejects(() => h.tools.get("update_goal").execute("id", { status: "paused" }), /user-triggered/);
  // Out-of-band command explicitly authorizes pause even during continuation.
  await h.commands.get("goal-pause").handler("", h.ctx);
  await h.emit("agent_settled", { aborted: false });
  assert.equal(h.messages.filter(m => m.options.triggerTurn).length, 1);
  await h.emit("session_shutdown"); await h.emit("session_start");
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(h.messages.filter(m => m.options.triggerTurn).length, 1, "paused restart stays paused");
  await h.emit("before_agent_start", { messageType: "user", prompt: "continue the goal" });
  await h.tools.get("update_goal").execute("id", { status: "active" });
  await h.emit("agent_settled", { aborted: false });
  assert.equal(h.messages.filter(m => m.options.triggerTurn).length, 2);
  // A native producer message delivered during a run consumes its saved wait.
  await h.tools.get("update_goal").execute("id", { continuation: { kind: "wait", reason: "SDK", deadline: new Date(Date.now() + 60000).toISOString(), message: { source_agent_id: "sdk", prefix: "READY" } } });
  await h.emit("message_start", { message: { role: "user", content: '<paseo-system kind="agent-message" source-agent-id="sdk">READY</paseo-system>' } });
  const consumed = await h.tools.get("get_goal").execute("id", {});
  assert.equal(JSON.parse(consumed.content[0].text).wait, null);
  await assert.rejects(() => h.tools.get("update_goal").execute("id", { status: "paused" }), /user-triggered/);
  // User steering takes over the next model request even inside a continuation.
  await h.emit("message_start", { message: { role: "user", content: "pause the goal" } });
  await h.tools.get("update_goal").execute("id", { status: "paused" });
  await h.commands.get("goal-clear").handler("", h.ctx);
  assert.equal(h.messages.at(-1).details.goal, null);
  await h.emit("before_agent_start", { messageType: "user", prompt: "create a goal for this" });
  const created = await h.tools.get("create_goal").execute("id", { objective: "full long objective" });
  assert.deepEqual(Object.keys(JSON.parse(created.content[0].text)), ["id", "status"]);
  assert.equal(created.details.piGoal, 1);
  await h.emit("turn_start");
  await h.emit("turn_end", { message: { role: "assistant", usage: { totalTokens: 1 }, stopReason: "error", errorMessage: "connection reset" } });
  const retrying = await h.tools.get("get_goal").execute("id", {});
  assert.ok(JSON.parse(retrying.content[0].text).retry.at > Date.now());
  // Pi can recover within the same run; that success cancels stale goal retry.
  await h.emit("turn_end", { message: { role: "assistant", usage: { totalTokens: 1 }, stopReason: "stop" } });
  const recovered = await h.tools.get("get_goal").execute("id", {});
  assert.equal(JSON.parse(recovered.content[0].text).retry, null);
  const goalId = JSON.parse(created.content[0].text).id;
  new Store().mutate(goalId, "other-session", "adopt", goal => { goal.ownerSessionId = "other-session"; });
  await h.emit("agent_settled", { aborted: false });
  assert.equal(h.messages.at(-1).details.goal, null, "the previous owner's Paseo todo is cleared");
  assert.match(h.messages.at(-1).content, /adopted by other-session/);
  await h.tools.get("create_goal").execute("id", { objective: "new goal after handoff" });
  assert.equal(new Store().read(goalId)!.status, "active", "old tab must not clear the new owner's goal");
  await h.emit("session_shutdown");
});
