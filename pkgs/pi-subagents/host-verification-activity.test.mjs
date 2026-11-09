import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {test} from 'node:test';

const packageRoot = process.env.PI_TEST_PACKAGE;
const {createJiti} = await import(pathToFileURL(path.join(packageRoot, 'node_modules/jiti/lib/jiti.mjs')));
const bootstrap = createJiti(import.meta.url);
const {resolveHostPeerAliases} = await bootstrap.import(path.join(packageRoot, 'src/runs/background/runner-aliases.ts'));
const {aliases, missing} = resolveHostPeerAliases(process.env.PI_TEST_HOST);
assert.deepEqual(missing, []);
const jiti = createJiti(import.meta.url, {alias: aliases});
const {resolveEffectiveAcceptance, evaluateAcceptance} = await jiti.import(path.join(packageRoot, 'src/runs/shared/acceptance.ts'));
const {resolveControlConfig, deriveActivityState, shouldEmitOpenToolAttention} = await jiti.import(path.join(packageRoot, 'src/runs/shared/subagent-control.ts'));

test('host checks publish and clear activity on passing and failing commands', async () => {
  const activity = [];
  const acceptance = resolveEffectiveAcceptance({agentName: 'worker', task: 'Check', agentContract: {version: 1}, explicit: {level: 'verified', verify: [
    {id: 'pass', command: `${process.execPath} -e "process.exit(0)"`},
    {id: 'fail', command: `${process.execPath} -e "process.exit(1)"`},
  ]}});
  const result = await evaluateAcceptance({acceptance, output: '', cwd: process.cwd(), reportOptional: true, onVerifyActivity: command => activity.push(command?.id)});
  assert.deepEqual(activity, ['pass', undefined, 'fail', undefined]);
  assert.deepEqual(result.verifyRuns.map(run => run.status), ['passed', 'failed']);
  assert.equal(result.status, 'rejected');
});

test('host command deadlines replace idle and open-model-tool notices', () => {
  const config = resolveControlConfig();
  assert.equal(deriveActivityState({config, startedAt: 0, turnCount: 4, currentTool: 'host_verification', now: 999999}), undefined);
  assert.equal(shouldEmitOpenToolAttention({config, currentTool: 'host_verification', currentToolStartedAt: 0, now: 999999}), false);
  assert.equal(shouldEmitOpenToolAttention({config, currentTool: 'bash', currentToolStartedAt: 0, now: 999999}), true);
});
