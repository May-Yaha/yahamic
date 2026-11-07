import test from 'node:test';
import assert from 'node:assert/strict';
import { createCoder } from '../plugins/coder.mjs';
import { createVerifier } from '../plugins/verifier.mjs';
import { runProcess, allowlistedEnv } from '../kernel/process.mjs';

const config = {
  workspace: '/w',
  limits: { maxTasks: 8, maxAttemptsPerTask: 2, maxCodexExecutions: 1 },
  pi: { command: 'pi', glm: { provider: 'zai-coding-cn', model: 'glm-5.3', apiKeyEnv: 'Z', timeoutMs: 1000 }, kimi: { provider: 'kimi-coding', model: 'k3', apiKeyEnv: 'K', timeoutMs: 1000 } },
  verify: { commands: [] },
};

function ctx(facts, counters = {}) {
  return {
    read: ns => structuredClone(facts[ns]),
    config,
    signal: null,
    emit: () => {},
    counter: name => counters[name] ?? null,
    tick: async name => { counters[name] = (counters[name] ?? 0) + 1; },
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

test('execution.history is append-only across rounds and codex calls tick the blackboard counter', async () => {
  const coder = createCoder({
    runPi: async () => { throw new Error('pi down'); },
    runCodex: async () => ({ text: '{"status":"completed","summary":"ok","questions":[]}' }),
  });
  const counters = {};
  const round1 = await coder.execute(ctx({
    assignments: { tasks: [planTasks[0]], assignments: [{ taskId: 't1', worker: 'glm', reason: '' }] },
    plan: { summary: 's', tasks: [planTasks[0]] },
  }, counters));
  assert.equal(round1.outputs.execution.allCompleted, false);
  const round2 = await coder.execute(ctx({
    assignments: { tasks: [planTasks[0]], assignments: [{ taskId: 't1', worker: 'codex', reason: '' }] },
    plan: { summary: 's', tasks: [planTasks[0]] },
    execution: round1.outputs.execution,
  }, counters));
  assert.deepEqual(round2.outputs.execution.history.map(r => `${r.worker}:${r.status}`), ['glm:failed', 'codex:completed']);
  assert.equal(round2.outputs.execution.results.length, 1, 'results stays the current round');
  assert.equal(round2.outputs.execution.allCompleted, true);
  assert.equal(counters['codex-calls'], 1);
  // Budget comes from the counter, not from the (possibly truncated) results.
  const round3 = await coder.execute(ctx({
    assignments: { tasks: [planTasks[1]], assignments: [{ taskId: 't2', worker: 'codex', reason: '' }] },
    plan: { summary: 's', tasks: planTasks },
    execution: { results: [], history: [] },
  }, counters));
  assert.equal(round3.terminal.status, 'blocked');
});

test('PROCESS_EXIT_FAILED carries output tails into verifier diagnostics', async () => {
  const verifier = createVerifier({});
  const local = { ...config, workspace: process.cwd(), verify: { commands: [
    { command: process.execPath, args: ['-e', "console.log('x'.repeat(9000));console.error('boom-detail');process.exit(3)"], label: 'tail' },
  ] } };
  const result = await verifier.execute({ ...ctx({}), config: local });
  const check = result.outputs.verify.checks[0];
  assert.equal(check.exitCode, 3);
  assert.match(check.diagnostics, /^PROCESS_EXIT_FAILED/);
  assert.match(check.diagnostics, /boom-detail/);
  assert.ok(check.diagnostics.length <= 4096);
});

test('verify/doctor child env is an allowlist: secrets never reach the child', async () => {
  const env = allowlistedEnv({ PATH: '/bin', https_proxy: 'http://p', DEVELOPER_DIR: '/d', ZHIPU_API_KEY: 'secret', NODE_OPTIONS: '--x' });
  assert.deepEqual(env, { PATH: '/bin', https_proxy: 'http://p', DEVELOPER_DIR: '/d' });
  const seen = [];
  await createVerifier({ runProcess: async ({ env: childEnv }) => { seen.push(childEnv); return { stdout: '', stderr: '', exitCode: 0 }; } })
    .execute({ ...ctx({}), config: { ...config, verify: { commands: [{ command: 'true' }] } } });
  process.env.YAHA_TEST_SECRET = 'leak';
  try {
    const out = await runProcess({ command: process.execPath, args: ['-e', 'process.stdout.write(String(process.env.YAHA_TEST_SECRET))'], env: allowlistedEnv() });
    assert.equal(out.stdout, 'undefined');
  } finally {
    delete process.env.YAHA_TEST_SECRET;
  }
  assert.equal(Object.hasOwn(seen[0], 'ZHIPU_API_KEY'), false);
});
