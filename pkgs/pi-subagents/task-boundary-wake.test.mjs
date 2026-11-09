import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { test } from 'node:test';

const packageRoot = process.env.PI_TEST_PACKAGE;
assert.ok(packageRoot, 'PI_TEST_PACKAGE must name the package being tested');
const { createJiti } = await import(pathToFileURL(path.join(packageRoot, 'node_modules/jiti/lib/jiti.mjs')));
const bootstrap = createJiti(import.meta.url);
const { resolveHostPeerAliases } = await bootstrap.import(path.join(packageRoot, 'src/runs/background/runner-aliases.ts'));
const { aliases, missing } = resolveHostPeerAliases(process.env.PI_TEST_HOST);
assert.deepEqual(missing, []);
const jiti = createJiti(import.meta.url, { alias: aliases });
const { runWorkflowScript } = await jiti.import(path.join(packageRoot, 'src/workflows/scripted-workflow.ts'));
const { incrementalChildCompletionTriggersTurn } = await jiti.import(path.join(packageRoot, 'src/runs/background/notify.ts'));
const successful = (key) => ({ key, ok: true, runId: `run-${key}`, output: 'done', outputReference: `/reports/${key}.md`, artifactPaths: [] });

// A successful review releases parent judgment before its slower sibling finishes.
// The ordinary implementation completion stays quiet, and no policy leaks into the child contract.
test('task boundary wakes while a sibling remains active, with no polling', async () => {
  let releaseSibling;
  const sibling = new Promise((resolve) => { releaseSibling = resolve; });
  const notices = [];
  const launched = [];
  let earlyWake = false;
  const result = await runWorkflowScript({
    workflowRunId: 'workflow-test',
    timeoutMs: 5000,
    script: `
      const lane = runs.run('implement', { agent: 'worker', task: 'implement' }).then(() =>
        runs.run('review', { agent: 'reviewer', task: 'review', notifyOnComplete: true })
      );
      const sibling = runs.run('sibling', { agent: 'worker', task: 'independent' });
      return Promise.all([lane, sibling]);
    `,
    async launch(key, params) {
      launched.push({ key, params });
      assert.equal(Object.hasOwn(params, 'notifyOnComplete'), false);
      if (key === 'sibling') await sibling;
      return successful(key);
    },
    async status() { throw new Error('Polling is unnecessary'); },
    onChildSettled(notice) {
      notices.push(notice);
      if (notice.childKey === 'implement') {
        assert.equal(incrementalChildCompletionTriggersTurn(notice, undefined), false);
      }
      if (notice.childKey === 'review') {
        assert.equal(notice.workflowRunning, true);
        assert.equal(notice.outputReference, '/reports/review.md');
        assert.equal(incrementalChildCompletionTriggersTurn(notice, undefined), true);
        earlyWake = true;
        releaseSibling();
      }
    },
  });
  assert.equal(earlyWake, true);
  assert.equal(result.children.length, 3);
  assert.equal(launched.length, 3);
  assert.equal(notices.filter((notice) => notice.notifyOnComplete).length, 1);
});

test('quiet scheduled success stays quiet and actionable failures still wake', () => {
  const boundary = { outcome: 'completed', workflowRunning: true, notifyOnComplete: true };
  assert.equal(incrementalChildCompletionTriggersTurn(boundary, { id: 'schedule', quiet: true }), false);
  assert.equal(incrementalChildCompletionTriggersTurn({ ...boundary, notifyOnComplete: false }, undefined), false);
  for (const outcome of ['failed', 'paused', 'stopped']) {
    assert.equal(incrementalChildCompletionTriggersTurn({ ...boundary, outcome, notifyOnComplete: false }, undefined), true);
  }
  assert.equal(incrementalChildCompletionTriggersTurn({ outcome: 'completed', workflowRunning: false }, undefined), true);
});

test('rejects a malformed completion policy before launching its child', async () => {
  let launches = 0;
  await assert.rejects(runWorkflowScript({
    script: `return runs.run('bad', { agent: 'worker', task: 'x', notifyOnComplete: 'yes' });`,
    timeoutMs: 5000,
    async launch(key) { launches++; return successful(key); },
    async status(key) { return successful(key); },
  }), /notifyOnComplete must be true or false/);
  assert.equal(launches, 0);
});

test('rejects a launch-only receipt when task completion must wake the parent', async () => {
  let launches = 0;
  await assert.rejects(runWorkflowScript({
    script: `return runs.run('dispatch', { agent: 'reviewer', task: 'review', async: true, notifyOnComplete: true });`,
    timeoutMs: 5000,
    async launch(key) { launches++; return successful(key); },
    async status(key) { return successful(key); },
  }), /notifyOnComplete requires an awaited child/);
  assert.equal(launches, 0);
});

test('reusing the same keyed child does not deliver a second boundary wake', async () => {
  let launches = 0;
  let wakes = 0;
  await runWorkflowScript({
    workflowRunId: 'workflow-repeat',
    script: `
      const params = { agent: 'reviewer', task: 'review', notifyOnComplete: true };
      await runs.run('review', params);
      return runs.run('review', params);
    `,
    timeoutMs: 5000,
    async launch(key) { launches++; return successful(key); },
    async status(key) { return successful(key); },
    onChildSettled(notice) { if (incrementalChildCompletionTriggersTurn(notice, undefined)) wakes++; },
  });
  assert.equal(launches, 1);
  assert.equal(wakes, 1);
});
