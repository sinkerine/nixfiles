import * as fs from "node:fs";

interface RenameIO {
	renameSync(source: string, target: string): void;
	rename(source: string, target: string): Promise<void>;
	isDirectorySync(target: string): boolean;
	isDirectory(target: string): Promise<boolean>;
	sleepSync(ms: number): void;
	sleep(ms: number): Promise<void>;
}

let sleeper: Int32Array | undefined;
const native: RenameIO = {
	renameSync: (source, target) => fs.renameSync(source, target),
	rename: (source, target) => fs.promises.rename(source, target),
	isDirectorySync: target => { try { return fs.lstatSync(target).isDirectory(); } catch { return false; } },
	isDirectory: async target => { try { return (await fs.promises.lstat(target)).isDirectory(); } catch { return false; } },
	sleepSync: ms => { sleeper ??= new Int32Array(new SharedArrayBuffer(4)); Atomics.wait(sleeper, 0, 0, ms); },
	sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
};
const transient = new Set(["EPERM", "EACCES", "EBUSY"]);
// Existing critical writers are synchronous. Cap their added sleep at 75ms;
// asynchronous metadata writers can wait longer without blocking Pi's input.
const syncDelays = [5, 10, 20, 40];
const asyncDelays = [...syncDelays, 80, 160];

/** File replacement only: no destination deletion, no retries of ordinary permission errors on POSIX. */
export function atomicRenamer(platform = process.platform, io: RenameIO = native) {
	const retryable = (error: unknown) => platform === "win32" && transient.has((error as NodeJS.ErrnoException | null)?.code ?? "");
	return {
		renameSync(source: string, target: string): void {
			for (let attempt = 0; ; attempt++) {
				try { io.renameSync(source, target); return; }
				catch (error) {
					if (!retryable(error) || attempt >= syncDelays.length || io.isDirectorySync(target)) throw error;
					io.sleepSync(syncDelays[attempt]!);
				}
			}
		},
		async rename(source: string, target: string): Promise<void> {
			for (let attempt = 0; ; attempt++) {
				try { await io.rename(source, target); return; }
				catch (error) {
					if (!retryable(error) || attempt >= asyncDelays.length || await io.isDirectory(target)) throw error;
					await io.sleep(asyncDelays[attempt]!);
				}
			}
		},
	};
}

export const {renameSync: renameAtomicSync, rename: renameAtomic} = atomicRenamer();
