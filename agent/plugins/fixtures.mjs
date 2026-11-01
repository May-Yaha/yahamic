// Fixture plugins for offline demos and tests: same plugin ids as the real
// ones, deterministic behaviour, zero model calls. Tests can also inject
// custom implementations via createRegistry().register overrides.

export function fixtureRepo(_params) {
  return {
    async execute() {
      return { outputs: { repo: { workspace: '/demo/workspace', task: 'demo', tree: ['firmware/', 'mac/'], readme: '# demo', manifests: {} } } };
    },
  };
}

export function fixtureWiki(_params) {
  return {
    async execute() {
      return { outputs: { wiki: { queries: ['demo'], hits: [{ file: 'rules/demo.md', title: '演示知识', status: 'active', snippet: '演示条目' }], pages: [] } } };
    },
  };
}

export function fixturePlan(params) {
  const tasks = params.tasks ?? [
    { id: 'demo-task', title: '演示任务', description: '在 README 追加一行演示文本。', kind: 'simple', dependsOn: [], acceptance: ['README 包含演示文本'] },
  ];
  return {
    async execute({ run }) {
      return { outputs: { plan: { summary: `围绕「${run.task.slice(0, 40)}」的演示计划`, tasks } } };
    },
  };
}

export function fixtureRouter(params) {
  const worker = params.worker ?? 'glm';
  return {
    async execute({ read }) {
      const assignments = read('plan');
      return {
        outputs: {
          assignments: {
            tasks: assignments.tasks,
            assignments: assignments.tasks.map(task => ({ taskId: task.id, worker: params.byKind?.[task.kind] ?? worker, reason: 'fixture' })),
            rework: Boolean(read('execution')?.results?.length),
          },
        },
      };
    },
  };
}

// Fixture round counters keyed by node id: the registry builds a fresh
// instance per execution, so per-instance closures would reset every rework.
const roundsByNode = new Map();

export function fixtureCoder(_params) {
  // Always reports completed: guarded rework is driven by fixtureVerifier's
  // failRounds, which keeps the router's candidate rotation exercisable.
  return {
    async execute({ read, node }) {
      const round = (roundsByNode.get(`coder:${node.id}`) ?? 0) + 1;
      roundsByNode.set(`coder:${node.id}`, round);
      const assignments = read('assignments');
      const previous = read('execution')?.results ?? [];
      const results = assignments.assignments.map(assignment => ({
        taskId: assignment.taskId,
        worker: assignment.worker,
        status: 'completed',
        summary: `fixture 执行完成（第 ${round} 轮，${previous.length} 条历史）`,
        questions: [],
      }));
      return { outputs: { execution: { results, usage: [] } } };
    },
  };
}

export function fixtureVerifier(params) {
  // failRounds: how many initial rounds report failure (default 1) to drive
  // exactly that many guarded reworks before passing.
  const failRounds = params.failRounds ?? 1;
  return {
    async execute({ node }) {
      const round = (roundsByNode.get(`verifier:${node.id}`) ?? 0) + 1;
      roundsByNode.set(`verifier:${node.id}`, round);
      const passed = round > failRounds;
      return {
        outputs: {
          verify: {
            checks: [{ label: 'fixture-check', command: 'demo', passed, exitCode: passed ? 0 : 1, diagnostics: passed ? '' : `第 ${round} 轮模拟失败（failRounds=${failRounds}）` }],
            allPassed: passed,
          },
        },
      };
    },
  };
}

export function fixtureCapture(_params) {
  return {
    async execute() {
      return { outputs: { capture: { captured: false, reason: 'fixture' } } };
    },
  };
}

export function fixtureReport() {
  return {
    async execute({ read, run }) {
      const execution = read('execution');
      const verify = read('verify');
      return {
        outputs: {
          report: {
            text: [
              `任务：${run.task}`,
              ...(execution?.results ?? []).map(r => `${r.status === 'completed' ? '✓' : '✗'} ${r.taskId} [${r.worker}] ${r.summary}`),
              ...(verify?.checks ?? []).map(c => `${c.passed ? '✓' : '✗'} 验证：${c.label}`),
            ].join('\n'),
          },
        },
      };
    },
  };
}

export function fixturePlugins() {
  return {
    'source-repo': fixtureRepo,
    'source-wiki': fixtureWiki,
    plan: fixturePlan,
    router: fixtureRouter,
    coder: fixtureCoder,
    verifier: fixtureVerifier,
    'sink-capture': fixtureCapture,
    'sink-report': fixtureReport,
  };
}
