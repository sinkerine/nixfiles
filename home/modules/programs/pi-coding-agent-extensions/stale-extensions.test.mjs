import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

const extPath = process.env.STALE_EXTENSIONS_EXTENSION
  ? pathToFileURL(process.env.STALE_EXTENSIONS_EXTENSION).href
  : new URL("./stale-extensions.ts", import.meta.url).href;

const { default: staleExtensions } = await import(extPath);

test("warns once per disk change in UI and clears if reverted", () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "pi-stale-ext-"));
  const prevDir = process.env.PI_CODING_AGENT_DIR;
  const prevChild = process.env.PI_SUBAGENT_CHILD;
  process.env.PI_CODING_AGENT_DIR = dir;
  delete process.env.PI_SUBAGENT_CHILD;

  try {
    mkdirSync(path.join(dir, "extensions"), { recursive: true });
    const targetV1 = path.join(dir, "store-v1.ts");
    const targetV2 = path.join(dir, "store-v2.ts");
    writeFileSync(targetV1, "// v1\n");
    writeFileSync(targetV2, "// v2\n");
    symlinkSync(targetV1, path.join(dir, "extensions", "bash-timeout.ts"));
    writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ packages: ["/nix/store/aaa-pi-goal"] }));

    const handlers = new Map();
    staleExtensions({ on: (name, fn) => handlers.set(name, fn) });

    const notifications = [];
    const statuses = [];
    const ctx = {
      hasUI: true,
      ui: {
        notify: (msg, level) => notifications.push({ msg, level }),
        setStatus: (key, val) => statuses.push({ key, val }),
      },
    };

    handlers.get("session_start")({}, ctx);
    handlers.get("before_agent_start")({}, ctx);
    assert.equal(notifications.length, 0);
    assert.equal(statuses.length, 0);

    // Simulate home-manager switch updating a package pin.
    writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ packages: ["/nix/store/bbb-pi-goal"] }));
    handlers.get("before_agent_start")({}, ctx);
    handlers.get("turn_end")({}, ctx);
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].level, "warning");
    assert.match(notifications[0].msg, /\/reload/);
    assert.equal(statuses.at(-1).val, "⚠ Extensions updated — run /reload");

    // Local extension symlink change also triggers a fresh warning.
    unlinkSync(path.join(dir, "extensions", "bash-timeout.ts"));
    symlinkSync(targetV2, path.join(dir, "extensions", "bash-timeout.ts"));
    handlers.get("before_agent_start")({}, ctx);
    assert.equal(notifications.length, 2);

    // Reverting to original clears the status.
    writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ packages: ["/nix/store/aaa-pi-goal"] }));
    unlinkSync(path.join(dir, "extensions", "bash-timeout.ts"));
    symlinkSync(targetV1, path.join(dir, "extensions", "bash-timeout.ts"));
    handlers.get("before_agent_start")({}, ctx);
    assert.equal(statuses.at(-1).val, undefined);
  } finally {
    if (prevDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = prevDir;
    if (prevChild === undefined) delete process.env.PI_SUBAGENT_CHILD;
    else process.env.PI_SUBAGENT_CHILD = prevChild;
    rmSync(dir, { recursive: true, force: true });
  }
});
