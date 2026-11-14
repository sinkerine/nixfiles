import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { randomBytes } from "node:crypto";
import { acquireGoalLock } from "./storage/goal-lock.ts";
import { renameAtomicSync } from "./storage/atomic-rename.ts";

export type Status = "active" | "paused" | "blocked" | "complete" | "budget_limited";
export interface Wait {
  reason: string; deadline: string;
  message?: { source_agent_id: string; prefix: string };
}
export interface Goal {
  version: 1; id: string; objective: string; status: Status; statusReason?: string;
  ownerSessionId: string; repoRoot: string; cwd: string;
  tokenBudget: number | null; tokensUsed: number; timeUsedSeconds: number;
  deferContinuation: boolean; wait: Wait | null; retry: { at: number; reason: string } | null;
  noProgressTurns: number; revision: number; createdAt: string; updatedAt: string;
  archivedAt?: string; goalTurns: number;
  blocker?: { reason: string; turn: number; count: number };
  history: { at: string; event: string; sessionId: string; detail?: string }[];
}
export function stateDirectory(env = process.env): string {
  return path.join(env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "pi-goal/goals");
}
export class Store {
  readonly directory: string;
  constructor(directory = stateDirectory()) { this.directory = directory; }
  private file(id: string): string {
    if (!/^[a-zA-Z0-9_-]{1,80}$/.test(id)) throw new Error("Invalid goal id");
    return path.join(this.directory, `${id}.json`);
  }
  read(id: string): Goal | undefined {
    try {
      const goal = JSON.parse(fs.readFileSync(this.file(id), "utf8")) as Goal;
      if (goal.version !== 1 || goal.id !== id) throw new Error(`Invalid goal record ${id}`);
      return goal;
    } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  }
  list(repoRoot: string): Goal[] {
    if (!fs.existsSync(this.directory)) return [];
    return fs.readdirSync(this.directory).filter(n => n.endsWith(".json"))
      .map(n => this.read(n.slice(0, -5))!).filter(g => !g.archivedAt && g.repoRoot === repoRoot);
  }
  private write(goal: Goal): void {
    const file = this.file(goal.id);
    const temp = `${file}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
    try { fs.writeFileSync(temp, JSON.stringify(goal, null, 2) + "\n", { mode: 0o600 }); renameAtomicSync(temp, file); }
    finally { fs.rmSync(temp, { force: true }); }
  }
  create(objective: string, session: string, repoRoot: string, cwd: string, budget: number | null = null, snapshot?: Goal): Goal {
    if (!objective.trim()) throw new Error("Objective must not be empty");
    if (budget !== null && (!Number.isSafeInteger(budget) || budget < 1)) throw new Error("Budget must be a positive integer");
    const id = Date.now().toString(36) + randomBytes(4).toString("hex");
    const lock = acquireGoalLock(path.join(this.directory, ".locks"), id);
    try {
      const at = new Date().toISOString();
      const goal: Goal = { version: 1, id, objective, status: snapshot?.status ?? "active",
        statusReason: snapshot?.statusReason, ownerSessionId: session, repoRoot, cwd,
        tokenBudget: budget, tokensUsed: snapshot?.tokensUsed ?? 0, timeUsedSeconds: snapshot?.timeUsedSeconds ?? 0,
        deferContinuation: !!snapshot, wait: snapshot?.wait ?? null, retry: snapshot?.retry ?? null,
        noProgressTurns: 0, goalTurns: 0, revision: 1, createdAt: at, updatedAt: at,
        history: [{ at, event: snapshot ? "fork" : "create", sessionId: session, detail: snapshot?.id }] };
      this.write(goal); return goal;
    } finally { lock.release(); }
  }
  mutate(id: string, sessionId: string, event: string, apply: (goal: Goal) => void): Goal {
    this.file(id);
    const lock = acquireGoalLock(path.join(this.directory, ".locks"), id);
    try {
      const goal = this.read(id);
      if (!goal) throw new Error(`Goal ${id} not found`);
      apply(goal);
      goal.revision++;
      goal.updatedAt = new Date().toISOString();
      goal.history = [...goal.history, { at: goal.updatedAt, event, sessionId }].slice(-50);
      this.write(goal); return goal;
    } finally { lock.release(); }
  }
}
export function publicGoal(goal?: Goal) {
  return goal && !goal.archivedAt ? { id: goal.id, status: goal.status, statusReason: goal.statusReason,
    objectivePreview: goal.objective.slice(0, 200), ownerSessionId: goal.ownerSessionId,
    tokensUsed: goal.tokensUsed, tokenBudget: goal.tokenBudget, wait: goal.wait } : null;
}
