import assert from "node:assert/strict";
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs";
import os from "node:os";
import path from "node:path";
import {pathToFileURL} from "node:url";
import test from "node:test";

const packageRoot = process.env.PI_TEST_PACKAGE;
if (!packageRoot) throw new Error("Set PI_TEST_PACKAGE to the installed pi-subagents package.");
const {createJiti} = await import(pathToFileURL(path.join(packageRoot, "node_modules/jiti/lib/jiti.mjs")));
const jiti = createJiti(import.meta.url);
const {resolveWorkflowResource} = await jiti.import(path.join(packageRoot, "src/workflows/workflow-resources.ts"));
const {consumeWorkflowResourcePermit, authorizeWorkflowResourceHost} = await jiti.import(path.join(packageRoot, "src/shared/workflow-child-permit.ts"));
const {runWorkflowScript} = await jiti.import(path.join(packageRoot, "src/workflows/scripted-workflow.ts"));

test("qex wait scopes registration, validates arguments, and uses one authorized host wait", async () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), "qex-wait-unit-"));
  let extensionPath = process.env.QEX_WAIT_EXTENSION;
  if (!extensionPath) {
    const source = readFileSync(new URL("./qex-wait.ts", import.meta.url), "utf8")
      .replaceAll("@SUBAGENTS@", packageRoot).replaceAll("@QEX@", "/nix/store/test-qex");
    extensionPath = path.join(temporary, "qex-wait.ts");
    writeFileSync(extensionPath, source);
  }
  const {default: extension} = await jiti.import(extensionPath);
  const handlers = new Map();
  extension({on: (name, handler) => handlers.set(name, handler)});
  const start = id => handlers.get("session_start")({}, {sessionManager: {getSessionId: () => id}});
  const resolve = (args, session = "qex-unit") => resolveWorkflowResource("qex-wait", args, session);
  try {
    start("qex-unit");
    for (const args of [{}, {id: "$(touch injected)"}, {id: "abcdef"}, {id: "12345678", command: "echo injected"},
      {id: "12345678", timeoutMs: 30000}, {id: "12345678", timeoutMs: "60000"},
      {id: "12345678", timeoutMs: 60000.5}, {id: "12345678", timeoutMs: 86400000}]) {
      assert.equal(resolve(args).ok, false, JSON.stringify(args));
    }
    assert.equal(resolve({id: "12345678"}, "other-session").ok, false);
    assert.equal(resolve({id: "cf76663e-225d-4654-a2c5-b5973abce36b"}).ok, true);
    let waits = 0;
    for (const timeoutMs of [60000, 3600000, 86340000]) {
      const resolved = resolve({id: "1234abcd", timeoutMs});
      assert.equal(resolved.ok, true, resolved.error);
      const resource = resolved.resource;
      consumeWorkflowResourcePermit(resource.permit, resource.script);
      const outcome = await runWorkflowScript({script: resource.script, cwd: temporary,
        launch: async () => {throw new Error("No model worker is needed");},
        status: async () => {throw new Error("No status polling is needed");},
        host: async (key, params) => {
          waits++;
          assert.equal(key, "wait");
          assert.match(params.command, new RegExp(`qex status 1234abcd --wait --timeout ${timeoutMs / 1000}s --json --no-logs$`));
          assert.equal(params.timeoutMs, timeoutMs + 60000);
          assert.equal(authorizeWorkflowResourceHost(resource.permit, key, params.command), undefined);
          assert.match(authorizeWorkflowResourceHost(resource.permit, key, "echo forbidden"), /not allowed/);
          return {ok: true, state: "completed", exitCode: 0, outputPath: "/receipt.json", durationMs: 10, stdout: "", stderr: ""};
        },
      });
      assert.deepEqual(outcome.value, {ok: true, state: "completed", exitCode: 0, receipt: "/receipt.json", durationMs: 10, jobId: "1234abcd"});
    }
    assert.equal(waits, 3);
    // Host failures (including a failed/cancelled job or expired wait) surface immediately.
    const failed = resolve({id: "1234abcd"}).resource;
    consumeWorkflowResourcePermit(failed.permit, failed.script);
    await assert.rejects(runWorkflowScript({script: failed.script, cwd: temporary,
      launch: async () => {throw new Error("No worker");}, status: async () => {throw new Error("No poll");},
      host: async () => {throw new Error("Host command wait failed: exit 9");},
    }), /exit 9/);
    start("qex-replacement");
    assert.equal(resolve({id: "1234abcd"}).ok, false);
    assert.equal(resolve({id: "1234abcd"}, "qex-replacement").ok, true);
    start(undefined);
    assert.equal(resolve({id: "1234abcd"}, "qex-replacement").ok, false);
  } finally {
    handlers.get("session_shutdown")();
    handlers.get("session_shutdown")();
    rmSync(temporary, {recursive: true, force: true});
  }
});
