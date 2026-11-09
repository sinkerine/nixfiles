import assert from "node:assert/strict";
import test from "node:test";
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync} from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {execFileSync} from "node:child_process";

const packageRoot = process.env.E2E_SUBAGENTS_PACKAGE;
if (!packageRoot) throw new Error("Set E2E_SUBAGENTS_PACKAGE to the Nix package or source checkout under test.");
const {createJiti} = await import(pathToFileURL(path.join(packageRoot, "node_modules/jiti/lib/jiti.mjs")).href);
const jiti = createJiti(import.meta.url);
const {resolveWorkflowResource} = await jiti.import(path.join(packageRoot, "src/workflows/workflow-resources.ts"));
const {consumeWorkflowResourcePermit, authorizeWorkflowResourceHost} = await jiti.import(path.join(packageRoot, "src/shared/workflow-child-permit.ts"));
const {runWorkflowScript} = await jiti.import(path.join(packageRoot, "src/workflows/scripted-workflow.ts"));
const {executeWorkflowHostCommand} = await jiti.import(path.join(packageRoot, "src/workflows/host-command.ts"));
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

test("native verification runs and reuses host evidence without a model child", async () => {
  const temporary = mkdtempSync(path.join(os.tmpdir(), "e2e-native-"));
  const cwd = path.join(temporary, "repo's quoted path");
  mkdirSync(cwd);
  const git = (...args) => execFileSync("git", ["-C", cwd, ...args], {stdio: "pipe"});
  git("init", "-q"); git("config", "user.name", "Test"); git("config", "user.email", "test@example.invalid");
  writeFileSync(path.join(cwd, "source"), "input"); git("add", "."); git("commit", "-qm", "fixture");
  const runDir = path.join(cwd, ".git/e2e-feature/native"); mkdirSync(runDir, {recursive: true});
  const recipe = path.join(runDir, "recipe's.json");
  writeFileSync(recipe, JSON.stringify({version: 1, checks: [{id: "units", command: "test -f source", timeout_seconds: 5}]}));
  const runner = process.env.E2E_RUNNER ?? path.join(temporary, "runner");
  if (!process.env.E2E_RUNNER) {
    mkdirSync(path.join(runner, "bin"), {recursive: true});
    const script = fileURLToPath(new URL("../scripts/verify.py", import.meta.url));
    writeFileSync(path.join(runner, "bin/e2e-feature-run"), "#!/bin/sh\nexec python3 -B " + quote(script) + " \"$@\"\n", {mode: 0o755});
  }
  const source = readFileSync(new URL("../../../pi-coding-agent-extensions/e2e-verification.ts", import.meta.url), "utf8")
    .replaceAll("@SUBAGENTS@", packageRoot).replaceAll("@E2E_RUNNER@", runner);
  const extensionPath = path.join(temporary, "e2e-verification.ts"); writeFileSync(extensionPath, source);
  const {default: extension} = await jiti.import(process.env.E2E_EXTENSION ?? extensionPath);
  const handlers = new Map();
  extension({on: (name, handler) => handlers.set(name, handler)});
  const ctx = {cwd, sessionManager: {getSessionId: () => "native-test"}};
  let children = 0;
  try {
    handlers.get("session_start")({}, ctx);
    const invoke = async (extra = {}) => {
      const resolved = resolveWorkflowResource("e2e-verify", {feature: "native", recipe, checks: ["units"], ...extra}, "native-test");
      assert.equal(resolved.ok, true, resolved.error);
      const resource = resolved.resource;
      assert.equal(typeof consumeWorkflowResourcePermit(resource.permit, resource.script), "object");
      const result = await runWorkflowScript({script: resource.script, cwd,
        launch: async () => {children++; throw new Error("No model child is permitted");},
        status: async () => {throw new Error("No polling is needed");},
        host: async (key, params, signal) => {
          assert.equal(authorizeWorkflowResourceHost(resource.permit, key, params.command), undefined);
          assert.match(authorizeWorkflowResourceHost(resource.permit, key, "echo unauthorized"), /not allowed/);
          return executeWorkflowHostCommand({key, params, cwd, defaultOutputPath: path.join(temporary, `host-${Date.now()}.log`), signal});
        },
      });
      assert.ok(JSON.stringify(result.value).length < 1000, "workflow receipt stays compact");
      return {result: result.value, detail: JSON.parse(readFileSync(result.value.receipt, "utf8"))};
    };
    const first = await invoke(); assert.equal(first.result.ok, true); assert.equal(first.detail.checks[0].reused, false);
    const second = await invoke(); assert.equal(second.result.ok, true); assert.equal(second.detail.checks[0].reused, true);
    writeFileSync(path.join(cwd, "source"), "edited");
    assert.equal((await invoke()).detail.checks[0].reused, false);
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe, jobs: true}, "native-test").ok, false);
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe, jobs: 17}, "native-test").ok, false);
    writeFileSync(recipe, JSON.stringify({version: 1, max_parallel: 2, resources: {browser: {}}, checks: [
      {id: "setup", command: "test -f source", phase: "full"},
      {id: "journey", command: "test -f source", needs: ["setup"], resources: ["browser"], phase: "e2e"},
    ]}));
    const journey = await invoke({checks: ["journey"], phase: "e2e", jobs: 1});
    assert.equal(journey.detail.max_parallel, 1);
    assert.deepEqual(journey.detail.checks.map(check => check.id), ["setup", "journey"]);
    writeFileSync(recipe, JSON.stringify({version: 1, checks: [{id: "units", command: "exit 9", timeout_seconds: 5}]}));
    await assert.rejects(invoke, /Host command .verify. failed/);
    assert.equal(children, 0);
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe: path.join(temporary, "e2e-verification.ts")}, "native-test").ok, false);
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe, command: "echo forbidden"}, "native-test").ok, false);
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe}, "other-session").ok, false);
    assert.equal(existsSync(path.join(cwd, "INJECTED")), false);
  } finally {
    handlers.get("session_shutdown")();
    assert.equal(resolveWorkflowResource("e2e-verify", {feature: "native", recipe}, "native-test").ok, false);
    rmSync(temporary, {recursive: true, force: true});
  }
});
