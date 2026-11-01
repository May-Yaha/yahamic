import test from 'node:test';
import assert from 'node:assert/strict';
import { createCoder } from '../plugins/coder.mjs';
import { createVerifier } from '../plugins/verifier.mjs';

const config = {
  workspace: '/w',
  limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 },
  pi: { command: 'pi', glm: { provider: 'zai-coding-cn', model: 'glm-5.3', apiKeyEnv: 'Z', timeoutMs: 1000 }, kimi: { provider: 'kimi-coding', model: 'k3', apiKeyEnv: 'K', timeoutMs: 1000 } },
  verify: { commands: [] },
};

function ctx(facts) {
  return {
    read: ns => structuredClone(facts[ns]),
    config,
    signal: null,
    emit: () => {},
  };
}

const planTasks = [
  { id: 't1', title: 'T1', description: 'd', kind: 'simple', dependsOn: [], acceptance: ['x'] },
  { id: 't2', title: 'T2', description: 'd', kind: 'hard', dependsOn: ['t1'], acceptance: ['x'] },
];

test('coder executes assignments serially and parses the strict result protocol', async () => {
  const calls = [];
  const coder = createCoder({
    runPi: async ({ prompt, config: workerConfig }) => {
      calls.push(['pi', workerConfig.provider]);
      assert.match(prompt, /T1/);
      return { text: '{"status":"completed","summary":"done t1","questions":[]}' };
    },
    runCodex: async ({ prompt }) => {
      calls.push(['codex']);
      assert.match(prompt, /T2/);
      return { text: '```json\n{"status":"completed","summary":"done t2","questions":[]}\n```' };
    },
  });
  const result = await coder.execute(ctx({
    assignments: { tasks: planTasks, assignments: [{ taskId: 't1', worker: 'glm', reason: '' }, { taskId: 't2', worker: 'codex', reason: '' }] },
    plan: { summary: 's', tasks: planTasks },
    repo: null,
  }));
  assert.deepEqual(calls, [['pi', 'zai-coding-cn'], ['codex']]);
  assert.deepEqual(result.outputs.execution.results.map(r => r.status), ['completed', 'completed']);
});

test('needs_input short-circuits; executor crashes become router data, not run failures', async () => {
  const coder = createCoder({
    runPi: async () => ({ text: '{"status":"needs_input","summary":"等用户","questions":["要不要删?"]}' }),
    runCodex: async () => { throw new Error('x'); },
  });
  const stopped = await coder.execute(ctx({
    assignments: { tasks: [planTasks[0]], assignments: [{ taskId: 't1', worker: 'glm', reason: '' }] },
    plan: { summary: 's', tasks: [planTasks[0]] },
  }));
  assert.equal(stopped.terminal.status, 'needs_input');

  const crashing = createCoder({
    runPi: async () => ({ text: '{"status":"completed","summary":"ok","questions":[]}' }),
    runCodex: async () => { throw Object.assign(new Error('codex down'), { code: 'CODEX_TURN_FAILED' }); },
  });
  const outcome = await crashing.execute(ctx({
    assignments: { tasks: [planTasks[1]], assignments: [{ taskId: 't2', worker: 'codex', reason: '' }] },
    plan: { summary: 's', tasks: [planTasks[1]] },
  }));
  assert.equal(outcome.terminal, undefined);
  assert.equal(outcome.outputs.execution.results[0].status, 'failed');
  assert.equal(outcome.outputs.execution.results[0].code, 'CODEX_TURN_FAILED');
});

test('coder refuses to exceed the codex execution budget', async () => {
  const coder = createCoder({
    runPi: async () => ({ text: '{"status":"completed","summary":"ok","questions":[]}' }),
    runCodex: async () => ({ text: '{"status":"completed","summary":"ok","questions":[]}' }),
  });
  const outcome = await coder.execute(ctx({
    assignments: { tasks: planTasks, assignments: [
      { taskId: 't2', worker: 'codex', reason: '' },
      { taskId: 't1', worker: 'codex', reason: '超预算的第二单' },
    ] },
    plan: { summary: 's', tasks: planTasks },
  }));
  assert.equal(outcome.terminal.status, 'blocked');
  assert.match(outcome.terminal.reason, /预算耗尽/);
});

test('verifier turns command outcomes into data with bounded diagnostics', async () => {
  const verifier = createVerifier({
    runProcess: async ({ command }) => {
      if (command === 'fail') throw Object.assign(new Error('exit 1'), { code: 'PROCESS_EXIT_FAILED', exitCode: 1 });
      return { stdout: 'ok', stderr: '', exitCode: 0 };
    },
  });
  const local = { ...config, verify: { commands: [
    { command: 'swift', args: ['build'], label: 'swift build' },
    { command: 'fail', label: 'failing' },
  ] } };
  const result = await verifier.execute({ ...ctx({}), config: local });
  assert.deepEqual(result.outputs.verify.checks.map(c => c.passed), [true, false]);
  assert.equal(result.outputs.verify.allPassed, false);
  assert.match(result.outputs.verify.checks[1].diagnostics, /PROCESS_EXIT_FAILED/);

  const empty = await createVerifier({}).execute({ ...ctx({}), config: { ...config, verify: { commands: [] } } });
  assert.equal(empty.outputs.verify.allPassed, null);
});
