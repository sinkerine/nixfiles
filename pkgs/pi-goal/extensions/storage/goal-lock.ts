// Adapted from pi-goal-x storage/goal-lock.ts (MIT; see LICENSE.pi-goal-x).
import * as fs from "node:fs";
import * as path from "node:path";

function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

/** Short synchronous transactions only. Never steal a live writer's lock on age alone. */
export function acquireGoalLock(directory: string, goalId: string): { release(): void } {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const lockPath = path.join(directory, `${goalId}.lock`);
  for (let attempt = 0; attempt < 5000; attempt++) {
    try {
      fs.writeFileSync(lockPath, JSON.stringify({ pid: process.pid }), { flag: "wx", mode: 0o600 });
      let released = false;
      return { release() { if (!released) { released = true; fs.unlinkSync(lockPath); } } };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      try {
        const stat = fs.statSync(lockPath);
        let pid: number | undefined;
        try { pid = JSON.parse(fs.readFileSync(lockPath, "utf8")).pid; } catch { /* partial write */ }
        // Allow a new lock time to acquire its payload; recover crashed writers.
        if ((Number.isInteger(pid) && pid! > 0 && !pidAlive(pid!)) ||
            (pid === undefined && Date.now() - stat.mtimeMs > 30_000)) fs.unlinkSync(lockPath);
      } catch { /* holder released */ }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2);
    }
  }
  throw new Error(`Goal ${goalId} lock is held by a live writer; try the operation again.`);
}
