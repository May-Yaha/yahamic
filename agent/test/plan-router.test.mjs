import test from 'node:test';
import assert from 'node:assert/strict';
import { routeAssignments, createRouter } from '../plugins/router.mjs';
import { createPlan, validatePlan } from '../plugins/plan.mjs';

const limits = { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 };
const plan = {
  summary: 's',
  tasks: [
    { id: 'a', title: 'A', description: 'd', kind: 'simple', dependsOn: [], acceptance: ['x'] },
    { id: 'b', title: 'B', description: 'd', kind: 'ui', dependsOn: ['a'], acceptance: ['x'] },
    { id: 'c', title: 'C', description: 'd', kind: 'hard', dependsOn: [], acceptance: ['x'] },
  ],
};

function execCtx(reads, { config } = {}) {
  const facts = { ...reads };
  return {
    read: ns => structuredClone(facts[ns]),
    run: { id: 'r', graph: 'coding', task: '测试任务' },
    config: config ?? { llm: {}, limits, router: { jev: {} } },
    signal: null,
    tick: async () => {},
    counter: () => null,
    emit: () => {},
  };
}

test('validatePlan is ported intact: rejects unknown fields, bad deps and cycles', () => {
  assert.equal(validatePlan({ version: 1, summary: 's', questions: [], tasks: plan.tasks }, 8).tasks.length, 3);
  assert.throws(() => validatePlan({ version: 2, summary: 's', questions: [], tasks: plan.tasks }));
  assert.throws(() => validatePlan({ version: 1, summary: 's', questions: [], tasks: [{ ...plan.tasks[0], rogue: 1 }] }));
  assert.throws(() => validatePlan({ version: 1, summary: 's', questions: [], tasks: [{ ...plan.tasks[0], dependsOn: ['ghost'] }] }));
  const cyclic = [
    { id: 'x', title: 'X', description: 'd', kind: 'simple', dependsOn: ['y'], acceptance: ['x'] },
    { id: 'y', title: 'Y', description: 'd', kind: 'simple', dependsOn: ['x'], acceptance: ['x'] },
  ];
  assert.throws(() => validatePlan({ version: 1, summary: 's', questions: [], tasks: cyclic }), /循环依赖/);
});

test('routing core whitelists by kind, rotates attempted workers, reopens all on verify failure', () => {
  const first = routeAssignments({ plan, execution: null, verify: null, limits });
  // The single Codex execution is reserved for the hard task, so simpler
  // tasks see it pruned from their candidates (yahaagent budget rule).
  assert.deepEqual(first.routed.map(r => r.candidates), [['glm', 'kimi'], ['kimi'], ['codex']]);

  const retried = routeAssignments({
    plan,
    execution: { results: [{ taskId: 'a', worker: 'glm', status: 'completed' }] },
    verify: { checks: [{ passed: false }] },
    limits,
  });
  // verify failed: every task reopens, but 'a' has already burned glm and the
  // hard task still holds the Codex reservation.
  assert.deepEqual(retried.routed.find(r => r.task.id === 'a').candidates, ['kimi']);

  const exhausted = routeAssignments({
    plan: { tasks: [plan.tasks[2]] },
    execution: { results: [{ taskId: 'c', worker: 'codex', status: 'failed' }] },
    verify: null,
    limits,
  });
  assert.equal(exhausted.terminal.status, 'blocked');

  const budget = routeAssignments({
    plan: { tasks: [plan.tasks[2], { id: 'd', title: 'D', description: 'd', kind: 'hard', dependsOn: [], acceptance: ['x'] }] },
    execution: null, verify: null, limits,
  });
  assert.equal(budget.terminal.status, 'blocked');
  assert.match(budget.terminal.reason, /预算不足/);
});

test('plan decision: questions with no tasks becomes needs_input; hard over budget blocks', async () => {
  const questionsText = '```json\n{"version":1,"summary":"信息不足","questions":["哪个模块?"],"tasks":[]}\n```';
  const planPlugin = createPlan({ provider: 'glm', llmImpl: async () => ({ text: questionsText }) });
  const ctx = execCtx({ repo: {}, wiki: {} });
  const needs = await planPlugin.execute(ctx);
  assert.equal(needs.terminal.status, 'needs_input');
  assert.deepEqual(needs.terminal.questions, ['哪个模块?']);

  const twoHard = '```json\n{"version":1,"summary":"两个疑难","questions":[],"tasks":['
    + '{"id":"h1","title":"H1","description":"d","kind":"hard","dependsOn":[],"acceptance":["x"]},'
    + '{"id":"h2","title":"H2","description":"d","kind":"hard","dependsOn":[],"acceptance":["x"]}'
    + ']}\n```';
  const blocked = await createPlan({ provider: 'glm', llmImpl: async () => ({ text: twoHard }) }).execute(execCtx({ repo: {}, wiki: {} }));
  assert.equal(blocked.terminal.status, 'blocked');
  assert.match(blocked.terminal.reason, /hard/);
});

test('router glm path validates the worker against per-task candidates; failure degrades deterministically', async () => {
  const good = '```json\n{"assignments":[{"taskId":"a","worker":"glm","reason":"r"},{"taskId":"b","worker":"kimi","reason":"r"},{"taskId":"c","worker":"codex","reason":"r"}]}\n```';
  const router = createRouter({ provider: 'glm', llmImpl: async () => ({ text: good }) });
  const result = await router.execute(execCtx({ plan }));
  assert.deepEqual(result.outputs.assignments.assignments.map(a => a.worker), ['glm', 'kimi', 'codex']);
  assert.equal(result.outputs.assignments.degraded, undefined);

  const rogue = '```json\n{"assignments":[{"taskId":"a","worker":"codex","reason":"r"},{"taskId":"b","worker":"kimi","reason":"r"},{"taskId":"c","worker":"codex","reason":"r"}]}\n```';
  const degradedRouter = createRouter({ provider: 'glm', llmImpl: async () => ({ text: rogue }) });
  const degraded = await degradedRouter.execute(execCtx({ plan }));
  // 'a' via codex exceeds the single-execution codex budget once 'c' reserves it,
  // so the decision is rejected wholesale and the fallback candidates apply.
  assert.ok(degraded.outputs.assignments.degraded);
  assert.deepEqual(degraded.outputs.assignments.assignments.map(a => a.worker), ['glm', 'kimi', 'codex']);

  const brokenRouter = createRouter({ provider: 'glm', llmImpl: async () => { throw Object.assign(new Error('down'), { code: 'LLM_NETWORK_ERROR' }); } });
  const broken = await brokenRouter.execute(execCtx({ plan }));
  assert.equal(broken.outputs.assignments.degraded, 'LLM_NETWORK_ERROR');
});

test('router LLM output must cover plan ids exactly once; order follows the plan; codex reservation counts', async () => {
  const twoSimple = { summary: 's', tasks: [plan.tasks[0], { ...plan.tasks[0], id: 'a2' }] };
  // max=1, no hard: the first simple task keeps codex as a candidate and
  // reserves it, so the second one must not be offered codex too.
  const routed = routeAssignments({ plan: twoSimple, execution: null, verify: null, limits });
  assert.deepEqual(routed.routed.map(r => r.candidates), [['glm', 'kimi', 'codex'], ['glm', 'kimi']]);

  const reordered = '{"assignments":[{"taskId":"c","worker":"codex"},{"taskId":"b","worker":"kimi"},{"taskId":"a","worker":"glm"}]}';
  const ordered = await createRouter({ provider: 'glm', llmImpl: async () => ({ text: reordered }) }).execute(execCtx({ plan }));
  assert.equal(ordered.outputs.assignments.degraded, undefined);
  assert.deepEqual(ordered.outputs.assignments.assignments.map(a => a.taskId), ['a', 'b', 'c']);

  const duplicate = '{"assignments":[{"taskId":"a","worker":"glm"},{"taskId":"a","worker":"glm"},{"taskId":"c","worker":"codex"}]}';
  const dup = await createRouter({ provider: 'glm', llmImpl: async () => ({ text: duplicate }) }).execute(execCtx({ plan }));
  assert.ok(dup.outputs.assignments.degraded);
  assert.deepEqual(dup.outputs.assignments.assignments.map(a => a.taskId), ['a', 'b', 'c']);

  // history (append-only) is what the router rotates on, not the latest round.
  const rotated = routeAssignments({
    plan: { tasks: [plan.tasks[0]] },
    execution: { results: [], history: [{ taskId: 'a', worker: 'glm', status: 'failed' }, { taskId: 'a', worker: 'kimi', status: 'failed' }] },
    verify: null, limits, codexUsed: 0,
  });
  assert.deepEqual(rotated.routed[0].candidates, ['codex']);
});
