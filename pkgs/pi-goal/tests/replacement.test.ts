import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import extension from "../extensions/index.ts";

test("a probe completing after session replacement cannot dispatch into the new session", async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-goal-replacement-"));
  const previous = process.env.XDG_STATE_HOME; process.env.XDG_STATE_HOME = dir;
  t.after(() => { if (previous === undefined) delete process.env.XDG_STATE_HOME; else process.env.XDG_STATE_HOME = previous; fs.rmSync(dir, { recursive: true, force: true }); });
  const bus = new EventEmitter();
  const pending: string[] = [];
  bus.on("subagents:rpc:v1:request", ({ requestId, method }) => {
    if (method === "ping") bus.emit(`subagents:rpc:v1:reply:${requestId}`, { success: true });
    else pending.push(requestId);
  });
  const handlers = new Map<string, Function>();
  const tools = new Map<string, any>();
  const entries: any[] = [];
  const messages: any[] = [];
  let session = "A";
  const ctx = { cwd: dir, isIdle: () => true, hasPendingMessages: () => false,
    sessionManager: { getSessionId: () => session, getBranch: () => entries } };
  const pi = { events: { on(name: string, fn: (d: unknown) => void) { bus.on(name, fn); return () => bus.off(name, fn); }, emit(name: string, data: unknown) { bus.emit(name, data); } },
    on(name: string, fn: Function) { handlers.set(name, fn); }, registerTool(tool: any) { tools.set(tool.name, tool); }, registerCommand() {},
    appendEntry(customType: string, data: unknown) { entries.push({ type: "custom", customType, data }); }, sendMessage(message: any) { messages.push(message); } };
  extension(pi as any);
  const emit = (name: string, event = {}) => handlers.get(name)!(event, ctx);
  await emit("session_start");
  await emit("before_agent_start", { messageType: "user", prompt: "create a goal" });
  await tools.get("create_goal").execute("id", { objective: "A's goal" });
  const settling = emit("agent_settled", { aborted: false });
  await Promise.resolve();
  assert.equal(pending.length, 1);
  await emit("session_shutdown");
  entries.length = 0; session = "B";
  await emit("session_start");
  bus.emit(`subagents:rpc:v1:reply:${pending[0]}`, { success: true, data: { fleet: { totalActive: 0 } } });
  await settling;
  assert.equal(messages.length, 0, "old A must not dispatch its continuation into B");
  await emit("session_shutdown");
});
