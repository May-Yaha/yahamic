// Decision point: assign each outstanding task to an executor. Candidate
// whitelists and Codex budget reservation follow yahaagent's workflow rules;
// a failed probabilistic route degrades deterministically to the first
// allowed candidate instead of inventing freedom.

import { askLLM } from './llm-glm.mjs';
import { selectWithJev } from './jev.mjs';
import { parseDecision } from '../kernel/result.mjs';

const CANDIDATES = {
  glm: { id: 'glm', description: 'GLM-5.3：简单局部修改、文档、常规测试；速度快、额度便宜' },
  kimi: { id: 'kimi', description: 'Kimi K3：跨文件功能开发、稍复杂逻辑、SwiftUI 界面' },
  codex: { id: 'codex', description: 'Codex：疑难问题、音频链路/并发/驱动等高风险推理' },
};

function allowedCandidates(kind) {
  if (kind === 'hard') return ['codex'];
  if (kind === 'complex' || kind === 'ui') return ['kimi', 'codex'];
  return ['glm', 'kimi', 'codex'];
}

/**
 * Deterministic routing core: which tasks still need an executor and which
 * candidates remain for each. Verification is workspace-wide, so a failed
 * check reopens every task (same attribution rule as yahaagent).
 */
export function routeAssignments({ plan, execution, verify, limits }) {
  const attemptedByTask = new Map();
  for (const result of execution?.results ?? []) {
    const list = attemptedByTask.get(result.taskId) ?? [];
    list.push(result.worker);
    attemptedByTask.set(result.taskId, list);
  }
  const lastStatus = new Map();
  for (const result of execution?.results ?? []) lastStatus.set(result.taskId, result.status);
  const verifyFailed = (verify?.checks ?? []).some(check => !check.passed);
  const outstanding = plan.tasks.filter(task => verifyFailed || lastStatus.get(task.id) !== 'completed');

  const codexUsed = (execution?.results ?? []).filter(r => r.worker === 'codex').length;
  const hardNeeded = outstanding.filter(t => t.kind === 'hard').length;
  if (hardNeeded > limits.maxCodexExecutions - codexUsed) {
    return { terminal: { status: 'blocked', reason: `Codex 执行预算不足：还需 ${hardNeeded} 个 hard 任务，配额 ${limits.maxCodexExecutions}、已用 ${codexUsed}。` } };
  }

  let codexReserved = codexUsed + hardNeeded;
  const routed = [];
  for (const task of outstanding) {
    const attempted = new Set(attemptedByTask.get(task.id) ?? []);
    let candidates = allowedCandidates(task.kind).filter(id => !attempted.has(id));
    if (candidates.length === 0) {
      return { terminal: { status: 'blocked', reason: `任务 ${task.id} 已尝试全部允许的执行者。` } };
    }
    if (task.kind !== 'hard' && candidates.includes('codex') && codexReserved >= limits.maxCodexExecutions) {
      candidates = candidates.filter(id => id !== 'codex');
      if (candidates.length === 0) {
        return { terminal: { status: 'blocked', reason: `任务 ${task.id} 的候选只剩 Codex 但预算已耗尽。` } };
      }
    }
    routed.push({ task, candidates });
  }
  return { routed, rework: (execution?.results ?? []).length > 0 };
}

export function createRouter(params) {
  const provider = ['glm', 'jev'].includes(params.provider) ? params.provider : 'glm';
  const llmImpl = params.llmImpl ?? askLLM;
  const jevImpl = params.jevImpl ?? selectWithJev;
  return {
    async execute({ read, config, signal, tick, emit }) {
      const plan = read('plan');
      const routed = routeAssignments({ plan, execution: read('execution'), verify: read('verify'), limits: config.limits });
      if (routed.terminal) return { outputs: { assignments: { tasks: [], assignments: [] } }, terminal: routed.terminal };

      let chosen = routed.routed.map(({ task, candidates }) => ({ taskId: task.id, worker: candidates[0], reason: '默认候选' }));
      let degraded = null;

      if (provider === 'jev') {
        const results = [];
        for (const { task, candidates } of routed.routed) {
          try {
            const decision = await jevImpl({
              task: { id: task.id, title: task.title, description: task.description, kind: task.kind },
              candidates: candidates.map(id => CANDIDATES[id]),
              config: config.router.jev,
              signal,
            });
            results.push({ taskId: task.id, worker: decision.choice, reason: `jev (${decision.confidence.toFixed(2)})` });
          } catch (error) {
            degraded = error?.code ?? 'JEV_ERROR';
            results.push({ taskId: task.id, worker: candidates[0], reason: 'Jev 不可用，默认候选' });
          }
        }
        chosen = results;
      } else {
        const prompt = `为以下编码任务选择执行者。候选与分工：
glm=GLM-5.3（simple：局部小改/文档/测试）；kimi=Kimi K3（complex/ui：跨文件功能、SwiftUI 界面）；codex=Codex（hard：疑难/高风险）。
${routed.routed.map(({ task, candidates }) => `任务 ${task.id} [${task.kind}] 允许候选：${candidates.join(',')} — ${task.title}：${task.description}`).join('\n')}
${(() => { const verify = read('verify'); return verify?.checks?.length ? `上轮验证结果：${verify.checks.map(c => `${c.label ?? c.command} ${c.passed ? '通过' : '失败'}`).join('; ')}` : ''; })()}
输出 JSON（可带围栏）：{"assignments":[{"taskId":"...","worker":"glm|kimi|codex","reason":"一句话"}]}，worker 必须落在各自允许候选内，数量一致。`;
        try {
          await tick('llm-calls');
          const result = await llmImpl({ config: config.llm, system: '你是执行者路由器，只输出符合协议的 JSON。', prompt, signal });
          chosen = parseDecision(result.text, value => {
            if (!value || !Array.isArray(value.assignments)) throw new Error('缺少 assignments');
            const allowed = new Map(routed.routed.map(({ task, candidates }) => [task.id, candidates]));
            if (value.assignments.length !== routed.routed.length) throw new Error('assignments 数量不匹配');
            return value.assignments.map(item => {
              if (typeof item?.taskId !== 'string' || !allowed.has(item.taskId)) throw new Error(`未知任务 ${item.taskId}`);
              if (!allowed.get(item.taskId).includes(item.worker)) throw new Error(`任务 ${item.taskId} 的 worker ${item.worker} 不在允许候选内`);
              return { taskId: item.taskId, worker: item.worker, reason: typeof item.reason === 'string' ? item.reason : '' };
            });
          });
        } catch (error) {
          degraded = error?.code ?? 'LLM_ERROR';
          chosen = routed.routed.map(({ task, candidates }) => ({ taskId: task.id, worker: candidates[0], reason: '决策不可用，默认候选' }));
        }
      }

      if (degraded) emit({ type: 'route_degraded', code: degraded, provider });
      return {
        outputs: {
          assignments: { tasks: plan.tasks, assignments: chosen, rework: routed.rework, ...(degraded ? { degraded } : {}) },
        },
      };
    },
  };
}
