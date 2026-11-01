import test from 'node:test';
import assert from 'node:assert/strict';
import { loadGraph, runGraph, GraphError } from '../kernel/graph.mjs';
import { createRegistry } from '../kernel/plugins.mjs';
import { createBlackboard } from '../kernel/blackboard.mjs';

function echoPlugin(id, impl) {
  return { id, factory: (params) => ({ async execute(ctx) { return impl(ctx, params); } }) };
}

function registryWith(...plugins) {
  const registry = createRegistry();
  for (const { id, factory } of plugins) registry.register(id, factory);
  return registry;
}

const goodNodes = [
  { id: 'src', type: 'source', plugin: 'a', outputs: ['data'] },
  { id: 'dec', type: 'decision', plugin: 'b', inputs: ['data'], outputs: ['plan'] },
  { id: 'act', type: 'action', plugin: 'a', inputs: ['plan'], outputs: ['work'] },
  { id: 'sink', type: 'sink', plugin: 'a', inputs: ['work'] },
];
const goodEdges = [
  { from: 'src', to: 'dec' }, { from: 'dec', to: 'act' }, { from: 'act', to: 'sink' },
];

function baseDef(overrides = {}) {
  return {
    id: 'test',
    counters: { rework: { max: 1 } },
    nodes: structuredClone(goodNodes),
    edges: structuredClone(goodEdges),
    ...overrides,
  };
}

test('loadGraph accepts a valid graph and computes topological order', () => {
  const registry = registryWith(echoPlugin('a', () => ({ outputs: {} })), echoPlugin('b', () => ({ outputs: {} })));
  const graph = loadGraph(baseDef(), registry);
  assert.equal(graph.id, 'test');
  assert.deepEqual(graph.order, ['src', 'dec', 'act', 'sink']);
});

test('loadGraph rejects unknown plugin, dangling ns, duplicate node and self edge', () => {
  const registry = registryWith(echoPlugin('a', () => ({ outputs: {} })));
  assert.throws(() => loadGraph(baseDef(), registry), GraphError); // plugin b missing
  registry.register('b', () => ({ async execute() { return { outputs: {} }; } }));
  const dangling = baseDef();
  dangling.nodes[1].inputs = ['missing'];
  assert.throws(() => loadGraph(dangling, registry), /references namespace missing/);
  const duplicate = baseDef({ nodes: [...structuredClone(goodNodes), { id: 'src', type: 'sink', plugin: 'a' }] });
  assert.throws(() => loadGraph(duplicate, registry), /Duplicate node/);
  const selfEdge = baseDef({ edges: [...structuredClone(goodEdges), { from: 'src', to: 'src' }] });
  assert.throws(() => loadGraph(selfEdge, registry), /Self edge/);
});

test('hidden cycles and unguarded backedges are rejected — the constitution rules', () => {
  const registry = registryWith(echoPlugin('a', () => ({ outputs: {} })), echoPlugin('b', () => ({ outputs: {} })));
  const cycle = baseDef({ edges: [
    { from: 'src', to: 'dec' }, { from: 'dec', to: 'act' }, { from: 'act', to: 'dec' }, { from: 'act', to: 'sink' },
  ] });
  assert.throws(() => loadGraph(cycle, registry), /cycle without an explicit guarded backedge/);
  const unguarded = baseDef({ edges: [
    ...structuredClone(goodEdges),
    { from: 'act', to: 'dec', backedge: true, guard: { counter: 'nope', max: 1 } },
  ] });
  assert.throws(() => loadGraph(unguarded, registry), /guard referencing a declared counter/);
});

test('node timeoutMs is rejected rather than silently ignored', () => {
  const registry = registryWith(echoPlugin('a', () => ({ outputs: {} })), echoPlugin('b', () => ({ outputs: {} })));
  const def = baseDef();
  def.nodes[0].timeoutMs = 1000;
  assert.throws(() => loadGraph(def, registry), /timeoutMs/);
});

test('runGraph executes nodes in topological order and writes declared outputs', async () => {
  const order = [];
  const registry = registryWith(
    echoPlugin('a', async () => { order.push('a'); return { outputs: {} }; }),
    echoPlugin('b', async (ctx) => { order.push('b'); return { outputs: { plan: { seen: ctx.read('data') } } }; }),
  );
  const graph = loadGraph(baseDef(), registry);
  const blackboard = createBlackboard({ run: { id: 'r1', graph: 'test', task: 't' }, counters: graph.counters });
  const outcome = await runGraph({ graph, registry, blackboard });
  assert.equal(outcome.status, 'completed');
  assert.deepEqual(order, ['a', 'b', 'a', 'a']);
  assert.deepEqual(blackboard.read('plan'), { seen: undefined }); // src wrote nothing yet
});

test('decision terminal (needs_input) short-circuits downstream nodes', async () => {
  let sinkRan = false;
  const registry = registryWith(
    echoPlugin('a', async () => { return { outputs: {} }; }),
    echoPlugin('b', async () => ({ outputs: { plan: {} }, terminal: { status: 'needs_input', questions: ['缺什么?'] } })),
  );
  const def = baseDef();
  def.nodes[3].plugin = 'spy';
  registry.register('spy', () => ({ async execute() { sinkRan = true; return { outputs: {} }; } }));
  const graph = loadGraph(def, registry);
  const blackboard = createBlackboard({ run: { id: 'r2', graph: 'test', task: 't' }, counters: graph.counters });
  const outcome = await runGraph({ graph, registry, blackboard });
  assert.equal(outcome.status, 'needs_input');
  assert.deepEqual(outcome.questions, ['缺什么?']);
  assert.equal(sinkRan, false);
});

test('guarded backedge requeues the target and its downstream once, then blocks at budget', async () => {
  let actRuns = 0;
  const registry = registryWith(echoPlugin('b', async () => ({ outputs: { plan: {} } })));
  registry.register('a', () => ({ async execute() { return { outputs: {} }; } }));
  registry.register('act', () => ({ async execute() { actRuns += 1; return { outputs: { work: actRuns } }; } }));
  const def = baseDef({
    counters: { rework: { max: 1 } },
    nodes: [
      { id: 'src', type: 'source', plugin: 'a', outputs: ['data'] },
      { id: 'dec', type: 'decision', plugin: 'b', inputs: ['data'], outputs: ['plan'] },
      { id: 'act', type: 'action', plugin: 'act', inputs: ['plan'], outputs: ['work'] },
      { id: 'sink', type: 'sink', plugin: 'a', inputs: ['work'] },
    ],
    edges: [
      { from: 'src', to: 'dec' }, { from: 'dec', to: 'act' }, { from: 'act', to: 'sink' },
      { from: 'sink', to: 'dec', backedge: true, guard: { counter: 'rework', max: 1 } },
    ],
  });
  const graph = loadGraph(def, registry);
  const blackboard = createBlackboard({ run: { id: 'r3', graph: 'test', task: 't' }, counters: graph.counters });
  const outcome = await runGraph({ graph, registry, blackboard });
  // act runs twice (initial + one guarded rework), then the budget closes the loop.
  assert.equal(actRuns, 2);
  assert.equal(outcome.status, 'completed');
  assert.equal(blackboard.counter('rework'), 1);
});

test('node failure without fallback blocks the run; with fallback the graph continues', async () => {
  const boom = Object.assign(new Error('boom'), { code: 'X' });
  const registry = registryWith(
    echoPlugin('ok', async () => ({ outputs: {} })),
    echoPlugin('bad', async () => { throw boom; }),
  );
  const defAb = (onError) => baseDef({
    nodes: [
      { id: 'src', type: 'source', plugin: 'bad', outputs: ['data'], ...(onError ? { onError } : {}) },
      { id: 'dec', type: 'decision', plugin: 'ok', inputs: ['data'], outputs: ['plan'] },
      { id: 'act', type: 'action', plugin: 'ok', inputs: ['plan'], outputs: ['work'] },
      { id: 'sink', type: 'sink', plugin: 'ok', inputs: ['work'] },
    ],
  });
  const g1 = loadGraph(defAb(), registry);
  const b1 = createBlackboard({ run: { id: 'r4', graph: 'test', task: 't' }, counters: g1.counters });
  assert.equal((await runGraph({ graph: g1, registry, blackboard: b1 })).status, 'blocked');

  const g2 = loadGraph(defAb('fallback'), registry);
  const b2 = createBlackboard({ run: { id: 'r5', graph: 'test', task: 't' }, counters: g2.counters });
  assert.equal((await runGraph({ graph: g2, registry, blackboard: b2 })).status, 'completed');
});

test('cancellation yields interrupted and keeps blackboard writes', async () => {
  const controller = new AbortController();
  const registry = registryWith(
    echoPlugin('a', async () => ({ outputs: {} })),
    echoPlugin('slow', (ctx) => new Promise((resolve, reject) => {
      ctx.signal.addEventListener('abort', () => reject(Object.assign(new Error('cancelled'), { code: 'PROCESS_CANCELLED' })), { once: true });
    })),
  );
  const def = baseDef({
    nodes: [
      { id: 'src', type: 'source', plugin: 'slow', outputs: ['data'] },
      { id: 'dec', type: 'decision', plugin: 'a', inputs: ['data'], outputs: ['plan'] },
    ],
    edges: [{ from: 'src', to: 'dec' }],
  });
  const graph = loadGraph(def, registry);
  const blackboard = createBlackboard({ run: { id: 'r6', graph: 'test', task: 't' }, counters: graph.counters });
  const promise = runGraph({ graph, registry, blackboard, signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  const outcome = await promise;
  assert.equal(outcome.status, 'interrupted');
});

test('writing an undeclared namespace fails the node', async () => {
  const registry = registryWith(
    echoPlugin('a', async () => ({ outputs: {} })),
    echoPlugin('b', async () => ({ outputs: {} })),
    echoPlugin('leaky', async () => ({ outputs: { rogue: 1 } })),
  );
  const def = baseDef();
  def.nodes[0].plugin = 'leaky';
  const graph = loadGraph(def, registry);
  const blackboard = createBlackboard({ run: { id: 'r7', graph: 'test', task: 't' }, counters: graph.counters });
  const outcome = await runGraph({ graph, registry, blackboard });
  assert.equal(outcome.status, 'blocked');
});
