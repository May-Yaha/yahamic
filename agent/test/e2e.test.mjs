import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { loadGraphFile } from '../runtime.mjs';
import { createRun } from '../kernel/run.mjs';
import { createDemoRegistry, createOverrideRegistry, createAgentRegistry } from '../plugins/index.mjs';
import { fixtureCoder, fixtureVerifier, fixtureCapture } from '../plugins/fixtures.mjs';

// The production coding graph must load against the REAL registry — this is
// the "graph is the constitution" check: no fixture substitution needed.
test('graphs/coding.json loads against the real plugin registry', () => {
  const graph = loadGraphFile('coding', createAgentRegistry());
  assert.equal(graph.id, 'coding');
  assert.equal(graph.nodes.size, 8);
  assert.ok(graph.backedgeOut.get('verify').length >= 1, 'verify owns the guarded rework backedge');
});

test('full offline run: rework backedge fires once, then completes with persisted artifacts', async () => {
  const events = [];
  const registry = createOverrideRegistry(
    createDemoRegistry(),
    { coder: fixtureCoder({}), verifier: fixtureVerifier({ failRounds: 1 }), 'sink-capture': fixtureCapture({}) },
  );
  const graph = loadGraphFile('coding', registry);
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-e2e-'));
  try {
    const run = createRun({ graph, registry, config: { workspace: dir, limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 } }, task: 'e2e:验证回边与护栏', runDir: dir, emit: event => events.push(event) });
    const report = await run.start();
    assert.equal(report.status, 'completed');
    assert.equal(report.counters.rework, 1, 'exactly one guarded rework happened');
    assert.ok(events.some(e => e.type === 'backedge_taken'));
    assert.ok(events.filter(e => e.type === 'node_started' && e.node === 'route').length >= 2, 'route re-ran after rework');
    const board = JSON.parse(await readFile(path.join(dir, run.id, 'blackboard.json'), 'utf8'));
    assert.equal(board.run.status, 'completed');
    assert.ok(board.facts.report.text.includes('✓'));
    assert.ok(fs.existsSync(path.join(dir, run.id, 'report.json')));
    // The blackboard holds the FINAL verify round (passing); the failed round
    // is visible only through the backedge event and the rework counter.
    assert.equal(report.facts.verify.checks[0].passed, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('rework budget exhausted terminates as blocked, never loops forever', async () => {
  const registry = createOverrideRegistry(
    createDemoRegistry(),
    { verifier: fixtureVerifier({ failRounds: 99 }) },
  );
  const graph = loadGraphFile('coding', registry);
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-e2e-'));
  try {
    const run = createRun({ graph, registry, config: { workspace: dir, limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 } }, task: 'always failing verification', runDir: dir });
    const report = await run.start();
    assert.equal(report.status, 'blocked');
    assert.equal(report.counters.rework, 2, 'guard max=2 caps the loop');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('demo registry runs the same graph fully offline', async () => {
  const registry = createDemoRegistry();
  const graph = loadGraphFile('coding', registry);
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-demo-'));
  try {
    const run = createRun({ graph, registry, config: { workspace: dir, limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 } }, task: 'demo', runDir: dir });
    const report = await run.start();
    assert.equal(report.status, 'completed');
    assert.ok(report.facts.plan.tasks.length >= 1);
    assert.ok(report.facts.report.text.length > 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('verify passing is not enough: failed executors keep the backedge open, then block', async () => {
  const failingCoder = {
    async execute({ read }) {
      const previous = read('execution')?.history ?? [];
      const results = read('assignments').assignments.map(a => ({ taskId: a.taskId, worker: a.worker, status: 'failed', summary: 'boom' }));
      return { outputs: { execution: { results, usage: [], history: [...previous, ...results], allCompleted: false } } };
    },
  };
  const registry = createOverrideRegistry(
    createDemoRegistry(),
    { coder: failingCoder, verifier: fixtureVerifier({ failRounds: 0 }) },
  );
  const graph = loadGraphFile('coding', registry);
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-e2e-'));
  try {
    const run = createRun({ graph, registry, config: { workspace: dir, limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 } }, task: 'executor failure', runDir: dir });
    const report = await run.start();
    assert.equal(report.status, 'blocked');
    assert.equal(report.counters.rework, 2, 'allCompleted=false drove the rework backedge');
    assert.equal(report.facts.execution.history.length, 3, 'history is append-only across rounds');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('wallClockMs aborts in-flight plugins through the run signal and settles blocked', async () => {
  const { loadGraph } = await import('../kernel/graph.mjs');
  const { createRegistry } = await import('../kernel/plugins.mjs');
  const registry = createRegistry();
  registry.register('wait', () => ({
    execute: ({ signal }) => new Promise((_, reject) => {
      signal.addEventListener('abort', () => reject(Object.assign(new Error('cancelled'), { code: 'PROCESS_CANCELLED' })), { once: true });
    }),
  }));
  const graph = loadGraph({ id: 'slow', limits: { wallClockMs: 30 }, nodes: [{ id: 'w', type: 'source', plugin: 'wait', outputs: ['data'] }], edges: [] }, registry);
  const started = Date.now();
  const report = await createRun({ graph, registry, config: {}, task: 'budget' }).start();
  assert.equal(report.status, 'blocked');
  assert.match(report.reason, /Wall-clock budget of 30 ms/);
  assert.ok(Date.now() - started < 2000, 'the plugin was interrupted, not awaited to completion');
});

test('snapshot write failure is journaled and leaves no tmp file behind', async () => {
  const registry = createDemoRegistry();
  const graph = loadGraphFile('coding', registry);
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-e2e-'));
  try {
    const run = createRun({ graph, registry, config: { workspace: dir, limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 } }, task: 'persist failure', runDir: dir });
    // blackboard.json is a non-empty directory: every rename onto it fails.
    fs.mkdirSync(path.join(dir, run.id, 'blackboard.json', 'x'), { recursive: true });
    const report = await run.start();
    assert.equal(report.status, 'completed', 'a failed checkpoint never kills the run');
    assert.ok(run.blackboard.snapshot().journal.some(entry => entry.event === 'persist_failed'));
    assert.deepEqual(fs.readdirSync(path.join(dir, run.id)).filter(name => name.includes('.tmp-')), []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
