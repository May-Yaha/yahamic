import test from 'node:test';
import assert from 'node:assert/strict';
import { createBlackboard, BlackboardError } from '../kernel/blackboard.mjs';
import { parseDecision, parseExecutionResult, isExecutionResult } from '../kernel/result.mjs';

test('blackboard writes namespaces, notifies subscribers and snapshots atomically-shaped state', () => {
  const seen = [];
  const board = createBlackboard({
    run: { id: 'r1', graph: 'g', task: 't' },
    counters: { rework: { max: 2 } },
    onPersist: snapshot => seen.push(snapshot),
  });
  board.write('repo', { tree: ['a/'] }, { node: 'repo-scan' });
  board.write('plan', { tasks: [] }, { node: 'plan' });
  assert.deepEqual(board.read('repo'), { tree: ['a/'] });
  assert.deepEqual(Object.keys(board.read()), ['repo', 'plan']);
  const snap = board.snapshot();
  assert.equal(snap.run.id, 'r1');
  assert.equal(snap.journal.length, 2);
  assert.ok(seen.length >= 2);
  // snapshot is a deep copy — later writes cannot mutate it.
  board.write('repo', { tree: ['b/'] }, { node: 'repo-scan' });
  assert.deepEqual(snap.facts.repo, { tree: ['a/'] });
});

test('guard/consume enforces backedge budgets; tick fails closed for plugin budgets', async () => {
  const board = createBlackboard({ run: { id: 'r2', graph: 'g', task: 't' }, counters: { rework: { max: 2 }, 'llm-calls': { max: 2 } } });
  assert.equal(board.guardPasses('rework', 2), true);
  assert.equal(board.consume('rework'), true);
  assert.equal(board.consume('rework'), true);
  assert.equal(board.consume('rework'), false); // budget closed
  assert.equal(board.counter('rework'), 2);
  await board.tick('llm-calls');
  await board.tick('llm-calls');
  await assert.rejects(() => board.tick('llm-calls'), BlackboardError);
  assert.throws(() => board.guardPasses('undeclared', 1), BlackboardError);
});

test('parseDecision accepts a single json fence and rejects prose with embedded json', () => {
  const validate = value => { if (!value || value.ok !== true) throw new Error('not ok'); return value; };
  assert.deepEqual(parseDecision('```json\n{"ok":true}\n```', validate), { ok: true });
  assert.deepEqual(parseDecision('{"ok":true}', validate), { ok: true });
  assert.throws(() => parseDecision('我觉得 {"ok":true} 大概可以', validate), error => error.code === 'DECISION_NOT_JSON');
  const failure = (() => { try { return parseDecision('{"ok":false}', validate); } catch (error) { return error; } })();
  assert.equal(failure.code, 'DECISION_INVALID');
  assert.equal(failure.diagnostics.reason, 'not ok');
});

test('execution result protocol keeps the three terminal states strict', () => {
  assert.equal(isExecutionResult({ status: 'completed', summary: 's', questions: [] }), true);
  assert.equal(isExecutionResult({ status: 'needs_input', summary: 's', questions: ['q'] }), true);
  assert.equal(isExecutionResult({ status: 'completed', summary: 's', questions: ['q'] }), false);
  assert.equal(isExecutionResult({ status: 'completed', summary: '', questions: [] }), false);
  const parsed = parseExecutionResult({ text: '{"status":"needs_input","summary":"缺参数","questions":["哪个?"]}' });
  assert.deepEqual(parsed.questions, ['哪个?']);
  assert.throws(() => parseExecutionResult({ text: 'done, I think' }), error => error.code === 'DECISION_NOT_JSON');
});
