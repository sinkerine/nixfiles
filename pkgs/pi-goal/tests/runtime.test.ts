import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawn } from "node:child_process";
import { Store } from "../extensions/store.ts";
import { Runtime, isDelegatedGoalSession, type Binding } from "../extensions/runtime.ts";
import { networkErrorBackoffPlan } from "../extensions/network-error-backoff.ts";
import { fetchQuotaRetryPlan, quotaAvailablePlan, QUOTA_RESET_GRACE_MS } from "../extensions/quota-retry.ts";
import { BackgroundWorkProbe } from "../extensions/goal-background-work.ts";
import { EventEmitter } from "node:events";

function setup(t: TestContext) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-goal-test-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new Store(path.join(dir, "goals"));
  function session(id: string) {
    const state = { dispatches: 0, notices: [] as string[], entries: [] as { type: string; data: unknown }[],
      scheduled: [] as number[], active: undefined as number | undefined, idle: true };
    const runtime = new Runtime(store, id, dir, dir, {
      entry(type, data) { state.entries.push({ type, data }); },
      notify(text) { state.notices.push(text); },
      dispatch() { state.dispatches++; state.idle = false; },
      async activeRuns() { return state.active; }, idle() { return state.idle; },
      schedule(at) { state.scheduled.push(at); },
    });
    runtime.userTriggered = true;
    return { r: runtime, s: state };
  }
  return { dir, store, session };
}

test("create binds verbatim objective, compact details; exactly one dispatch and terminal states stop", async t => {
  const { session } = setup(t);
  for (const status of ["complete", "blocked", "paused"] as const) {
    const { r, s } = session(status);
    const goal = r.create("  full\nobjective  ");
    assert.equal(goal.objective, "  full\nobjective  ");
    assert.equal((s.entries[0]!.data as Binding).goalId, goal.id);
    await Promise.all([r.settle(), r.settle()]);
    await r.settle();
    assert.equal(s.dispatches, 1);
    if (status === "blocked") {
      for (let turn = 0; turn < 2; turn++) {
        assert.throws(() => r.update({ status, reason: "dependency unavailable" }), /three consecutive/);
        r.finish(1);
      }
    }
    r.update({ status, reason: "dependency unavailable" });
    s.idle = true; await r.settle(); assert.equal(s.dispatches, 1);
    if (status === "complete") assert.equal(r.bound, undefined);
  }
});
test("resume same session restores active continuation; paused stays paused", async t => {
  const { session } = setup(t);
  const a = session("A"); const goal = a.r.create("work");
  const b = session("A"); b.r.restore(a.s.entries[0]!.data as Binding);
  assert.equal(b.r.bound, goal.id); await b.r.settle(); assert.equal(b.s.dispatches, 1);
  b.r.update({ status: "paused" });
  const c = session("A"); c.r.restore(a.s.entries[0]!.data as Binding);
  await c.r.settle(); assert.equal(c.s.dispatches, 0);
});
test("fork copies historical snapshot and defers until direct user input; original untouched", async t => {
  const { session, store } = setup(t);
  const a = session("A"); const original = a.r.create("original objective", 100);
  const binding = a.s.entries[0]!.data as Binding;
  store.mutate(original.id, "A", "later", g => { g.tokensUsed = 15; });
  const b = session("B"); b.r.restore(binding);
  assert.notEqual(b.r.bound, original.id);
  assert.equal(b.r.goal()!.tokensUsed, 0, "fork uses branch snapshot, not future source state");
  await b.r.settle(); assert.equal(b.s.dispatches, 0);
  b.r.input('<paseo-system kind="agent-message" source-agent-id="other">READY</paseo-system>', false);
  assert.equal(b.r.goal()!.deferContinuation, true);
  b.r.input("continue", true); await b.r.settle(); assert.equal(b.s.dispatches, 1);
  assert.equal(store.read(original.id)!.tokensUsed, 15);
  assert.equal(store.read(original.id)!.ownerSessionId, "A");
  a.r.update({ status: "complete" });
  const historical = session("C"); historical.r.restore(binding);
  assert.equal(historical.r.goal()!.status, "active", "historical fork survives later completion of original");
});
test("adopt revokes old continuation, notices once and preserves paused/blocked states", async t => {
  const { session } = setup(t);
  const a = session("A"); const goal = a.r.create("work");
  const b = session("B"); b.r.adopt(goal.id);
  await a.r.settle(); await a.r.settle(); assert.equal(a.s.dispatches, 0);
  assert.equal(a.s.notices.filter(n => n.includes("adopted by B")).length, 1);
  await b.r.settle(); assert.equal(b.s.dispatches, 1);
  b.r.update({ status: "paused" });
  const c = session("C"); c.r.adopt(goal.id); await c.r.settle();
  assert.equal(c.r.goal()!.status, "paused"); assert.equal(c.s.dispatches, 0);
});
test("pause/resume/clear need user turn; another session can pause by id", async t => {
  const { session } = setup(t); const a = session("A"), b = session("B");
  const goal = a.r.create("work"); b.r.userTriggered = false;
  for (const status of ["paused", "active"] as const) assert.throws(() => b.r.update({ goal_id: goal.id, status }), /user-triggered/);
  assert.throws(() => b.r.clear(goal.id), /user-triggered/);
  b.r.userTriggered = true; b.r.update({ goal_id: goal.id, status: "paused" });
  await a.r.settle(); assert.equal(a.s.dispatches, 0);
  b.r.update({ goal_id: goal.id, status: "active" }); await a.r.settle(); assert.equal(a.s.dispatches, 1);
  b.r.clear(goal.id); a.s.idle = true; await a.r.settle(); assert.equal(a.s.dispatches, 1);
  assert.equal(a.r.details().goal, null);
});
test("active runs hold, zero release, unavailable fails open; ownership rechecked after probe", async t => {
  const { session, store } = setup(t);
  const { r, s } = session("A"); r.create("work"); s.active = 2;
  await r.settle(); assert.equal(s.dispatches, 0);
  s.active = 0; await r.settle(); assert.equal(s.dispatches, 1);
  s.idle = true; s.active = undefined; await r.settle(); assert.equal(s.dispatches, 2);
  s.idle = true;
  r.host.activeRuns = async () => { store.mutate(r.bound!, "B", "adopt", g => { g.ownerSessionId = "B"; }); return 0; };
  await r.settle(); assert.equal(s.dispatches, 2);
});
test("message wait matches source and complete first token; user consumes, expired blocks once", async t => {
  const { session, store } = setup(t); const { r, s } = session("A"); r.create("work");
  const wait = () => r.update({ continuation: { kind: "wait", reason: "SDK", deadline: new Date(Date.now() + 60000).toISOString(), message: { source_agent_id: "sdk", prefix: "SDK_READY" } } });
  assert.throws(() => r.update({ continuation: { kind: "wait", reason: "SDK", deadline: new Date(Date.now() + 60000).toISOString(), message: { source_agent_id: "sdk", prefix: "TWO TOKENS" } } }), /single-token/);
  wait(); await r.settle(); assert.equal(s.dispatches, 0); assert.equal(s.scheduled.length, 1);
  const envelope = (source: string, body: string) => `<paseo-system kind="agent-message" source-agent-id="${source}">${body}</paseo-system>`;
  for (const text of [envelope("wrong", "SDK_READY"), envelope("sdk", "SDK_READYISH"), envelope("sdk", "hi SDK_READY")]) {
    r.input(text, false); assert.ok(r.goal()!.wait);
  }
  r.input(envelope("sdk", "SDK_READY report"), false); assert.equal(r.goal()!.wait, null);
  assert.equal(s.dispatches, 0, "delivery itself starts a turn");
  wait(); r.input("user steering", true); assert.equal(r.goal()!.wait, null);
  wait(); store.mutate(r.bound!, "A", "expired", g => { g.wait!.deadline = new Date(0).toISOString(); });
  r.input(envelope("sdk", "SDK_READY"), false); await r.settle(); await r.settle();
  assert.equal(r.goal()!.status, "blocked");
  assert.equal(s.notices.filter(n => n.startsWith("wait deadline expired")).length, 1);
  r.update({ status: "active" }); wait();
  store.mutate(r.bound!, "A", "expired", g => { g.wait!.deadline = new Date(0).toISOString(); });
  r.input("user steering before idle expiration check", true);
  assert.equal(r.goal()!.wait, null);
});
test("no-progress blocks on third continuation, any tool resets; abort only pauses continuation", t => {
  const { session } = setup(t); const { r } = session("A"); r.create("work");
  r.continuation = true; r.finish(0); r.finish(0); r.finish(1);
  assert.equal(r.goal()!.noProgressTurns, 0);
  r.finish(0); r.finish(0); assert.equal(r.goal()!.status, "active");
  r.finish(0); assert.equal(r.goal()!.status, "blocked");
  r.update({ status: "active" }); r.continuation = false; r.finish(0, true);
  assert.equal(r.goal()!.status, "active"); r.continuation = true; r.finish(0, true);
  assert.equal(r.goal()!.statusReason, "interrupted by user");
});
test("budget accounting rolls through completion; budget sends steering once and prevents resume", async t => {
  const { session } = setup(t); const { r, s } = session("A"); r.create("work", 10); r.begin();
  r.account(10, 3); await r.settle(); await r.settle();
  assert.equal(r.goal()!.status, "budget_limited"); assert.equal(s.dispatches, 0);
  assert.equal(s.notices.filter(n => n === "Token budget reached").length, 1);
  assert.throws(() => r.update({ status: "active" }), /exhausted/);
  r.update({ status: "complete" }); r.account(2, 1);
  assert.equal(r.store.read((s.entries[0]!.data as Binding).goalId)!.tokensUsed, 12);
});
test("no bound goal injects no context; delegated detector includes nested children", t => {
  const { session } = setup(t); assert.equal(session("A").r.context(), undefined);
  assert.equal(isDelegatedGoalSession({ PI_SUBAGENT_CHILD: "1" }), true);
  assert.equal(isDelegatedGoalSession({ PI_SUBAGENT_DEPTH: "2" }), true);
  assert.equal(isDelegatedGoalSession({ PI_SUBAGENT_DEPTH: "0" }), false);
});
test("quota reset uses first usable account plus grace; network ladder plateaus", async () => {
  const now = Date.now();
  const cards = [{ provider: "one", windows: [{ used: 100, resetsAt: new Date(now + 120000).toISOString() }, { used: 100, resetsAt: new Date(now + 180000).toISOString() }] },
    { provider: "two", windows: [{ used: 100, resetsAt: new Date(now + 150000).toISOString() }] }];
  assert.equal(quotaAvailablePlan(cards, now)!.at, now + 150000);
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async () => new Response(JSON.stringify(cards));
    const plan = await fetchQuotaRetryPlan("https://example.invalid", now);
    assert.equal(plan.at, now + 150000 + QUOTA_RESET_GRACE_MS);
  } finally { globalThis.fetch = original; }
  assert.deepEqual([1,2,3,4,5,6].map(i => networkErrorBackoffPlan(i)!.delayMs), [5000,10000,20000,40000,80000,80000]);
});
test("retry timer holds until saved reset time", async t => {
  const { session, store } = setup(t); const { r, s } = session("A"); const goal = r.create("work");
  const at = Date.now() + 60000;
  store.mutate(goal.id, "A", "retry", g => { g.retry = { at, reason: "quota" }; });
  await r.settle(); assert.deepEqual(s.scheduled, [at]); assert.equal(s.dispatches, 0);
  store.mutate(goal.id, "A", "reset", g => { g.retry!.at = 0; });
  await r.settle(); assert.equal(s.dispatches, 1);
});
test("background probe returns active count and unavailable fails open", async () => {
  const emitter = new EventEmitter();
  const bus = { on(name: string, callback: (data: unknown) => void) { emitter.on(name, callback); return () => emitter.off(name, callback); }, emit(name: string, data: unknown) { emitter.emit(name, data); } };
  emitter.on("subagents:rpc:v1:request", ({ requestId, method }) => emitter.emit(`subagents:rpc:v1:reply:${requestId}`, { success: true, data: { fleet: { totalActive: method === "status" ? 3 : 0 } } }));
  const probe = new BackgroundWorkProbe(bus, 10);
  await Promise.resolve(); assert.equal(await probe.activeRuns(), 3); probe.dispose();
  assert.equal(await probe.activeRuns(), undefined);
  const absent = new BackgroundWorkProbe(undefined, 10); assert.equal(await absent.activeRuns(), undefined); absent.dispose();
});
test("two real processes mutate fresh records without losing updates or revision conflicts", async t => {
  const { session, store } = setup(t); const { r } = session("A"); const goal = r.create("work");
  const module = new URL("../extensions/store.ts", import.meta.url).href;
  async function child() {
    const code = `import {Store} from ${JSON.stringify(module)}; const store=new Store(${JSON.stringify(store.directory)}); for(let i=0;i<60;i++) store.mutate(${JSON.stringify(goal.id)},'child','usage',g=>{g.tokensUsed++});`;
    const proc = spawn(process.execPath, ["--experimental-strip-types", "--input-type=module", "-e", code]);
    let err = ""; proc.stderr.on("data", d => { err += d; });
    await new Promise<void>((resolve, reject) => { proc.on("error", reject); proc.on("close", n => n === 0 ? resolve() : reject(new Error(err))); });
  }
  await Promise.all([child(), child()]);
  assert.equal(store.read(goal.id)!.tokensUsed, 120); assert.equal(store.read(goal.id)!.revision, 121);
  assert.equal(store.read(goal.id)!.history.length, 50);
});
