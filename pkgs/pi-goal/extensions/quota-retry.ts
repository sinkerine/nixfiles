/**
 * Goal-level recovery after a provider usage limit.
 *
 * A usage limit outlasts the network-error ladder by hours, so retrying it
 * every 80s only burns autonomous runs. When PI_GOAL_QUOTA_URL points at a
 * magpie quota endpoint (`/api/usage/quotas` or `/v1/magpie/quotas`), the
 * goal instead waits until the first account's exhausted windows reset.
 * Without it, usage limits stay on the network-error ladder.
 */

export const QUOTA_RETRY_URL_ENV = "PI_GOAL_QUOTA_URL";
export const QUOTA_RESET_GRACE_MS = 60_000;
/** Used when the endpoint can't be read or reports allowance left. */
export const QUOTA_FALLBACK_DELAY_MS = 10 * 60_000;

export interface QuotaWindow {
	unlimited?: boolean;
	used?: number;
	resetsAt?: string;
}

export interface QuotaCard {
	provider?: string;
	user?: string;
	name?: string;
	windows?: QuotaWindow[];
}

export interface QuotaRetryPlan {
	at: number;
	reason: string;
}

export function quotaRetryUrl(env: NodeJS.ProcessEnv = process.env): string | undefined {
	const url = env[QUOTA_RETRY_URL_ENV]?.trim();
	return url ? url : undefined;
}

/**
 * An account is usable again once every exhausted window on it has reset;
 * the goal can retry when the first account becomes usable.
 */
export function quotaAvailablePlan(cards: QuotaCard[], now = Date.now()): QuotaRetryPlan | undefined {
	let best: QuotaRetryPlan | undefined;
	for (const card of cards) {
		const windows = (card.windows ?? []).filter(w => !w.unlimited);
		if (windows.length === 0) continue;
		let availableAt = now;
		let known = true;
		for (const w of windows) {
			if ((w.used ?? 0) < 100) continue;
			const reset = w.resetsAt ? Date.parse(w.resetsAt) : NaN;
			if (!Number.isFinite(reset)) { known = false; break; }
			availableAt = Math.max(availableAt, reset);
		}
		if (!known) continue;
		if (!best || availableAt < best.at) {
			best = { at: availableAt, reason: `${card.provider ?? "?"} ${card.user ?? card.name ?? "account"}` };
		}
	}
	return best;
}

export async function fetchQuotaRetryPlan(url: string, now = Date.now()): Promise<QuotaRetryPlan> {
	try {
		const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
		if (!res.ok) throw new Error(`HTTP ${res.status}`);
		const body = (await res.json()) as unknown;
		const data = Array.isArray(body) ? body : (body as { data?: unknown } | null)?.data;
		const plan = quotaAvailablePlan(Array.isArray(data) ? (data as QuotaCard[]) : [], now);
		if (!plan) return { at: now + QUOTA_FALLBACK_DELAY_MS, reason: "no quota windows reported" };
		if (plan.at <= now) return { at: now + QUOTA_FALLBACK_DELAY_MS, reason: `${plan.reason} reports allowance left` };
		return { at: plan.at + QUOTA_RESET_GRACE_MS, reason: `${plan.reason} resets` };
	} catch (error) {
		return { at: now + QUOTA_FALLBACK_DELAY_MS, reason: `quota read failed: ${error instanceof Error ? error.message : String(error)}` };
	}
}

export function formatQuotaRetryTime(at: number): string {
	return new Date(at).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}
