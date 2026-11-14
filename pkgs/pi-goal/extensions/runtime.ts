import { Store, publicGoal, type Goal, type Status, type Wait } from "./store.ts";

// From pi-goal-x goal-session-safety.ts (MIT; see LICENSE.pi-goal-x).
export function isDelegatedGoalSession(env: Record<string, string | undefined> = process.env): boolean {
  const depth = Number(env.PI_SUBAGENT_DEPTH);
  return env.PI_SUBAGENT_CHILD === "1" || (Number.isFinite(depth) && depth > 0);
}
export interface Binding { goalId: string; sessionId: string; snapshot?: Goal }
export interface Host {
  entry(type: string, data: unknown): void;
  notify(text: string, goal: Goal | null): void;
  dispatch(goal: Goal): void;
  activeRuns(): Promise<number | undefined>;
  idle(): boolean;
  schedule(at: number): void;
}
/** A Paseo agent-message is host work, never direct user authorization. */
export function agentEnvelope(text: string): { source?: string; body: string } | undefined {
  // Matcher adapted from pi-goal-x workflow-efficiency.patch (MIT).
  const match = /^<paseo-system\b([^>]{0,4096})>\s*([\s\S]*)/.exec(text);
  if (!match || !/\bkind="agent-message"/.test(match[1]!)) return;
  return { source: /\bsource-agent-id="([^"]+)"/.exec(match[1]!)?.[1], body: match[2]! };
}
export class Runtime {
  bound?: string;
  userTriggered = false;
  continuation = false;
  private dispatching = false;
  private accountingId?: string;
  begin(): void { this.accountingId = this.bound; }

  readonly store: Store; readonly session: string; readonly repoRoot: string; readonly cwd: string; readonly host: Host;
  constructor(store: Store, session: string, repoRoot: string, cwd: string, host: Host) {
    this.store = store; this.session = session; this.repoRoot = repoRoot; this.cwd = cwd; this.host = host;
  }
  goal(id = this.bound): Goal | undefined { return id ? this.store.read(id) : undefined; }
  private save(goal: Goal): Goal {
    if (goal.id === this.bound) this.host.entry("pi-goal:snapshot", { goalId: goal.id, snapshot: goal });
    return goal;
  }
  private bind(goal: Goal): Goal {
    this.bound = goal.id;
    this.host.entry("pi-goal:bind", { goalId: goal.id, sessionId: this.session, snapshot: goal });
    return goal;
  }
  private unbind(goal: Goal): void {
    if (this.bound !== goal.id) return;
    this.host.entry("pi-goal:unbind", { goalId: goal.id, sessionId: this.session }); this.bound = undefined;
  }
  private releaseForeignBinding(): void {
    const goal = this.goal();
    if (goal && goal.ownerSessionId !== this.session) {
      this.unbind(goal);
      this.host.notify(`goal ${goal.id} adopted by ${goal.ownerSessionId}`, null);
    }
  }
  restore(binding?: Binding): void {
    this.bound = undefined;
    if (!binding) return;
    const goal = this.store.read(binding.goalId);
    if (binding.sessionId !== this.session) {
      const snapshot = binding.snapshot ?? goal;
      if (!snapshot || snapshot.archivedAt || snapshot.status === "complete") return;
      this.bind(this.store.create(snapshot.objective, this.session, this.repoRoot, this.cwd, snapshot.tokenBudget, snapshot));
    } else if (goal && !goal.archivedAt && goal.status !== "complete") {
      this.bound = goal.id; this.releaseForeignBinding();
    }
  }
  create(objective: string, budget?: number): Goal {
    this.releaseForeignBinding();
    const current = this.goal();
    if (current && !current.archivedAt && current.status !== "complete") throw new Error("This session already has an unfinished goal; complete or clear it first.");
    return this.bind(this.store.create(objective, this.session, this.repoRoot, this.cwd, budget ?? null));
  }
  adopt(id: string): Goal {
    this.releaseForeignBinding();
    const current = this.goal();
    if (current && current.id !== id && !current.archivedAt && current.status !== "complete") throw new Error("Complete or clear this session's unfinished goal before adopting another.");
    return this.bind(this.store.mutate(id, this.session, "adopt", goal => {
      if (goal.archivedAt || goal.status === "complete") throw new Error("Cannot adopt an archived or completed goal");
      goal.ownerSessionId = this.session; goal.deferContinuation = !this.userTriggered;
    }));
  }
  update(args: { goal_id?: string; status?: Status; reason?: string; continuation?: { kind: "ready" } | (Wait & { kind: "wait" }) }, user = this.userTriggered): Goal {
    if (!args.goal_id) this.releaseForeignBinding();
    const id = args.goal_id ?? this.bound;
    if (!id) throw new Error("No goal is bound");
    if (!user && id !== this.bound) throw new Error("Changing another session's goal requires a user-triggered turn");
    if ((args.status === "paused" || args.status === "active") && !user) throw new Error("Pause and resume require a user-triggered turn");
    if (args.status === "blocked" && !args.reason?.trim()) throw new Error("Blocked requires a reason");
    const wait = args.continuation?.kind === "wait" ? args.continuation : undefined;
    if (wait && (!wait.reason.trim() || !Number.isFinite(Date.parse(wait.deadline)) || Date.parse(wait.deadline) <= Date.now())) throw new Error("Wait requires a reason and a future finite deadline");
    if (wait?.message && (!/^[A-Za-z0-9_-]{1,128}$/.test(wait.message.source_agent_id) || !/^\S{1,80}$/u.test(wait.message.prefix))) throw new Error("Message waits require a source agent id and a single-token prefix");
    const goal = this.save(this.store.mutate(id, this.session, "update", goal => {
      if (goal.archivedAt) throw new Error("Goal is archived");
      if (!user && goal.ownerSessionId !== this.session) throw new Error(`Goal ${goal.id} is owned by session ${goal.ownerSessionId}`);
      // The semantic three-turn blocker audit is the Codex prompt contract;
      // requiring repeated tool declarations would reintroduce checkpoints.
      if (args.status) {
        if (args.status === "active" && goal.tokenBudget !== null && goal.tokensUsed >= goal.tokenBudget) throw new Error("Token budget exhausted");
        goal.status = args.status; goal.statusReason = args.reason;
        goal.wait = null; goal.retry = null;
        if (args.status === "active") { goal.noProgressTurns = 0; goal.deferContinuation = false; }
      }
      if (wait) goal.wait = { reason: wait.reason, deadline: wait.deadline, message: wait.message };
    }));
    this.host.notify(`Goal ${goal.id}: ${goal.status}`, goal);
    if (goal.status === "complete") this.unbind(goal);
    return goal;
  }
  clear(id?: string, user = this.userTriggered): Goal {
    if (!user) throw new Error("Clear requires a user-triggered turn");
    if (!id) this.releaseForeignBinding();
    id ??= this.bound;
    if (!id) throw new Error("No goal is bound");
    const goal = this.save(this.store.mutate(id, this.session, "clear", g => { g.archivedAt = new Date().toISOString(); }));
    this.unbind(goal); this.host.notify(`Goal ${goal.id} cleared`, goal); return goal;
  }
  input(text: string, directUser: boolean): void {
    const goal = this.goal();
    if (!goal || goal.ownerSessionId !== this.session) return;
    const envelope = agentEnvelope(text);
    const condition = goal.wait?.message;
    const matches = envelope && condition && envelope.source === condition.source_agent_id &&
      envelope.body.startsWith(condition.prefix) && /^(?:\s|<\/paseo-system>|$)/.test(envelope.body.slice(condition.prefix.length));
    if (!directUser && !matches) return;
    this.save(this.store.mutate(goal.id, this.session, "input", g => {
      if (g.ownerSessionId !== this.session) return;
      if (directUser) g.deferContinuation = false;
      // Expiration remains authoritative even if a late producer arrives.
      if (directUser || !g.wait || Date.parse(g.wait.deadline) > Date.now()) g.wait = null;
    }));
  }
  account(tokens: number, seconds: number): void {
    const goal = this.goal(this.accountingId ?? this.bound);
    if (!goal || goal.ownerSessionId !== this.session || goal.archivedAt) return;
    this.save(this.store.mutate(goal.id, this.session, "usage", g => {
      if (g.ownerSessionId !== this.session) return;
      g.tokensUsed += tokens; g.timeUsedSeconds += seconds;
    }));
  }
  finish(tools: number, aborted = false, failed = false): void {
    const goal = this.goal();
    if (!goal || goal.ownerSessionId !== this.session || goal.archivedAt) return;
    const updated = this.save(this.store.mutate(goal.id, this.session, "turn", g => {
      if (g.ownerSessionId !== this.session) return;
      if (this.continuation && aborted && g.status === "active") { g.status = "paused"; g.statusReason = "interrupted by user"; }
      if (tools) g.noProgressTurns = 0;
      else if (this.continuation && !failed && !aborted && !g.retry) g.noProgressTurns++;
      if (g.noProgressTurns >= 3 && g.status === "active") { g.status = "blocked"; g.statusReason = "no progress in 3 continuation turns"; }
    }));
    if (updated.status !== goal.status) this.host.notify(`Goal ${updated.id}: ${updated.statusReason}`, updated);
  }
  context(): string | undefined {
    this.releaseForeignBinding();
    const goal = this.goal();
    if (!goal || goal.archivedAt || goal.status === "complete") return;
    return `[Goal ${goal.id}: ${goal.status}${goal.statusReason ? ` (${goal.statusReason})` : ""}; owner ${goal.ownerSessionId}]\n` +
      `${goal.objective.slice(0, 2000)}${goal.objective.length > 2000 ? "\nUse get_goal for full text." : ""}\n` +
      `Usage ${goal.tokensUsed}/${goal.tokenBudget ?? "unlimited"} tokens; ${Math.round(goal.timeUsedSeconds)} seconds.` +
      (goal.wait ? `\nWait: ${JSON.stringify(goal.wait)}` : "");
  }
  async settle(): Promise<void> {
    if (this.dispatching || !this.host.idle()) return;
    this.dispatching = true;
    try {
      this.releaseForeignBinding();
      let goal = this.goal();
      if (!goal || goal.archivedAt) return;
      if (goal.status !== "active" || goal.deferContinuation) return;
      if (goal.tokenBudget !== null && goal.tokensUsed >= goal.tokenBudget) {
        let limited = false;
        goal = this.store.mutate(goal.id, this.session, "budget", g => {
          if (g.ownerSessionId === this.session && g.status === "active" && !g.archivedAt) { g.status = "budget_limited"; limited = true; }
        });
        this.releaseForeignBinding();
        if (limited) { this.save(goal); this.host.notify("Token budget reached", goal); }
        return;
      }
      if (goal.wait) {
        const deadline = Date.parse(goal.wait.deadline);
        if (deadline > Date.now()) { this.host.schedule(deadline); return; }
        let expired = false;
        goal = this.store.mutate(goal.id, this.session, "wait-expired", g => {
          if (g.ownerSessionId !== this.session || g.status !== "active" || g.archivedAt || !g.wait || Date.parse(g.wait.deadline) > Date.now()) return;
          g.status = "blocked"; g.statusReason = `wait deadline expired: ${g.wait.reason}`; g.wait = null; expired = true;
        });
        this.releaseForeignBinding();
        if (expired) { this.save(goal); this.host.notify(goal.statusReason!, goal); }
        return;
      }
      if (goal.retry && goal.retry.at > Date.now()) { this.host.schedule(goal.retry.at); return; }
      if ((await this.host.activeRuns() ?? 0) > 0) return;
      // The probe yields. Re-read *all* guards immediately before dispatch.
      if (!this.host.idle()) return;
      this.releaseForeignBinding();
      goal = this.goal();
      if (!goal || goal.archivedAt || goal.ownerSessionId !== this.session || goal.status !== "active" ||
          goal.deferContinuation || goal.wait || (goal.retry && goal.retry.at > Date.now()) ||
          (goal.tokenBudget !== null && goal.tokensUsed >= goal.tokenBudget) || !this.host.idle()) return;
      this.host.dispatch(goal);
    } finally { this.dispatching = false; }
  }
  details(goal = this.goal()) { return { piGoal: 1 as const, goal: publicGoal(goal) }; }
}
