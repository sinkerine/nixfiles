import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import path from "node:path";
import {pathToFileURL} from "node:url";
import test from "node:test";

const packageRoot = process.env.PI_TEST_PACKAGE;
const {createJiti} = await import(pathToFileURL(path.join(packageRoot, "node_modules/jiti/lib/jiti.mjs")));
const bootstrap = createJiti(import.meta.url);
const {resolveHostPeerAliases} = await bootstrap.import(path.join(packageRoot, "src/runs/background/runner-aliases.ts"));
const {aliases, missing} = resolveHostPeerAliases(process.env.PI_TEST_HOST);
assert.deepEqual(missing, []);
const jiti = createJiti(import.meta.url, {alias: aliases});
const {flattenSubagentToolOptions} = await jiti.import(path.join(packageRoot, "src/extension/subagent-options.ts"));
const {registerNativeSupervisorClient, topLevelSupervisorTool, TOP_LEVEL_SUPERVISOR_REFUSAL} = await jiti.import(path.join(packageRoot, "src/intercom/native-supervisor-channel.ts"));

test("mixed inline and fenced scripts explain the exact repair and both valid shapes work", () => {
  const script = "return {ok: true};";
  assert.throws(() => flattenSubagentToolOptions({workflow: true, options: {script}}), /remove the top-level workflow field.*Do not combine them/);
  assert.equal(flattenSubagentToolOptions({options: {script}}).workflowScript, script);
  assert.equal(flattenSubagentToolOptions({workflow: true}).workflow, true);
});

test("supervisor registration preserves child metadata, cache identity and actionable parent refusal", async () => {
  const tools = [];
  const pi = {registerTool: tool => tools.push(tool), getAllTools: () => tools};
  registerNativeSupervisorClient(pi, undefined);
  assert.deepEqual(tools, []);
  registerNativeSupervisorClient(pi, {runId: "child-test", agent: "worker", childIndex: 0, channelDir: "/unused"});
  assert.deepEqual(tools.map(tool => tool.name), ["contact_supervisor"]);
  registerNativeSupervisorClient(pi, {runId: "child-test", agent: "worker", childIndex: 0, channelDir: "/unused"});
  assert.equal(tools.length, 1);
  const child = tools[0];
  const parent = topLevelSupervisorTool();
  const parentEntrypoint = readFileSync(path.join(packageRoot, "src/extension/index.ts"), "utf8");
  assert.match(parentEntrypoint, /registerPinnedTool\(pi, topLevelSupervisorTool\(\)\)/);
  // Execution differs, but every advertised tool field must remain identical for fork cache reuse.
  const declaration = ({execute, ...fields}) => fields;
  assert.deepEqual(declaration(parent), declaration(child));
  assert.match(parent.description, /Child sessions only/);
  assert.match(parent.description, /top-level session must never call this tool/);
  assert.match(parent.description, /subagent_supervisor.*ask_user/);
  const result = await parent.execute("parent-test", {reason: "need_decision", message: "test"});
  assert.equal(result.isError, true);
  assert.equal(result.content[0].text, TOP_LEVEL_SUPERVISOR_REFUSAL);
  assert.match(result.content[0].text, /subagent_supervisor.*ask_user/);
  assert.match(result.content[0].text, /Do not retry contact_supervisor here/);
});
