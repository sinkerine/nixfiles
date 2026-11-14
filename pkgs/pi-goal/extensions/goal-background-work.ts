/**
 * Background subagent awareness for automatic continuation.
 *
 * pi-subagents wakes the parent session itself when a background run finishes
 * or needs attention: completions, supervisor asks, and control notices all
 * start a turn with `triggerTurn: true`. An automatic checkpoint dispatched
 * while those runs are still active only produces an idle "still waiting"
 * turn that re-reads the whole context, so the scheduler asks pi-subagents'
 * in-process RPC (`subagents:rpc:v1`, method `status`) how many runs are
 * active before it dispatches one.
 *
 * The probe fails open: until pi-subagents answers or announces itself, and
 * whenever a status reply is missing, continuation behaves as it did before
 * this module existed.
 */

import { randomUUID } from "node:crypto";

export const SUBAGENT_RPC_REQUEST_EVENT = "subagents:rpc:v1:request";
export const SUBAGENT_RPC_READY_EVENT = "subagents:rpc:v1:ready";
export const SUBAGENT_RPC_REPLY_EVENT_PREFIX = "subagents:rpc:v1:reply:";
export const SUBAGENT_ASYNC_STARTED_EVENT = "subagent:async-started";

/** How long to wait for pi-subagents to answer an RPC request. */
export const BACKGROUND_PROBE_TIMEOUT_MS = 3_000;
/**
 * Longest a checkpoint is held while runs stay active without anything waking
 * the session. Completion and attention notices normally arrive much sooner;
 * this only bounds the wait when a notice is lost.
 */
export const BACKGROUND_HOLD_HEARTBEAT_MS = 30 * 60_000;

interface EventBusLike {
	on(channel: string, handler: (data: unknown) => void): unknown;
	emit(channel: string, data: unknown): void;
}

function activeRunCount(reply: unknown): number | undefined {
	if (!reply || typeof reply !== "object") return undefined;
	const r = reply as { success?: unknown; data?: { fleet?: { totalActive?: unknown } } };
	if (r.success !== true) return undefined;
	const total = r.data?.fleet?.totalActive;
	return typeof total === "number" && Number.isFinite(total) && total >= 0 ? total : undefined;
}

function unsubscribeQuietly(unsubscribe: unknown): void {
	try { if (typeof unsubscribe === "function") unsubscribe(); } catch { /* listener already gone */ }
}

export class BackgroundWorkProbe {
	private available = false;
	private disposed = false;
	private readonly events: EventBusLike | undefined;
	private readonly timeoutMs: number;
	private readonly unsubscribers: unknown[] = [];

	constructor(events: EventBusLike | undefined, timeoutMs = BACKGROUND_PROBE_TIMEOUT_MS) {
		this.events = typeof events?.on === "function" && typeof events.emit === "function" ? events : undefined;
		this.timeoutMs = timeoutMs;
		if (!this.events) return;
		// pi-subagents may load before or after this extension. Its ready event,
		// a run start, or an answer to this ping all prove it is present.
		const present = () => { this.available = true; };
		this.unsubscribers.push(this.events.on(SUBAGENT_RPC_READY_EVENT, present));
		this.unsubscribers.push(this.events.on(SUBAGENT_ASYNC_STARTED_EVENT, present));
		void this.request("ping").then(reply => { if (reply && (reply as { success?: unknown }).success === true) present(); });
	}

	/** Whether pi-subagents is known to be loaded; probes are sent only then. */
	isAvailable(): boolean { return this.available && !this.disposed; }

	/**
	 * Active background runs owned by the current session (running, queued, or
	 * pending), or undefined when pi-subagents is not known or does not answer.
	 */
	async activeRuns(): Promise<number | undefined> {
		if (!this.isAvailable()) return undefined;
		return activeRunCount(await this.request("status"));
	}

	dispose(): void {
		this.disposed = true;
		for (const unsubscribe of this.unsubscribers.splice(0)) unsubscribeQuietly(unsubscribe);
	}

	private request(method: "ping" | "status"): Promise<unknown> {
		const events = this.events;
		if (!events || this.disposed) return Promise.resolve(undefined);
		return new Promise(resolve => {
			const requestId = randomUUID();
			let settled = false;
			let unsubscribe: unknown;
			const finish = (reply: unknown) => {
				if (settled) return;
				settled = true;
				clearTimeout(timer);
				unsubscribeQuietly(unsubscribe);
				resolve(reply);
			};
			const timer = setTimeout(() => finish(undefined), this.timeoutMs);
			timer.unref?.();
			unsubscribe = events.on(`${SUBAGENT_RPC_REPLY_EVENT_PREFIX}${requestId}`, finish);
			try {
				events.emit(SUBAGENT_RPC_REQUEST_EVENT, { version: 1, requestId, method });
			} catch {
				finish(undefined);
			}
		});
	}
}
