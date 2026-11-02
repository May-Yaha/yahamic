// Action node: execute the routed assignments serially (task DAG order comes
// from the plan's topological sort). Each executor's final message must pass
// the strict result protocol; needs_input/blocked short-circuit the run.

import { runCodex, runPi } from './coder-clis.mjs';
import { EXECUTION_RESULT_PROTOCOL, parseExecutionResult } from '../kernel/result.mjs';

function taskPrompt({ task, plan, repo, verify, workspace }) {
  const evidence = verify?.checks?.length
    ? `\n上一轮验证结果（供修复参考）：\n${verify.checks.map(check => `${check.passed ? '✓' : '✗'} ${check.label ?? check.command}${check.passed ? '' : `\n诊断尾部：\n${(check.diagnostics ?? '').slice(-2000)}`}`).join('\n')}`
    : '';
  const tree = repo?.tree?.length ? repo.tree.slice(0, 80).join('\n') : '';
  return `工作区：${workspace}（yahamic：Mac mini 无线麦克风；firmware/=ESP32-S3 固件 C++ ESP-IDF，mac/=Swift 包 yahamicd+YahaHome）
计划总览：${plan?.summary ?? ''}

执行任务：${task.title}（${task.id}，${task.kind}）
${task.description}
验收条件：
${task.acceptance.map(item => `- ${item}`).join('\n')}
${tree ? `\n目录摘要：\n${tree}\n` : ''}${evidence}
按终态协议输出最后结果。改动必须落在工作区内；不要提交 git、不要推送、不要部署。外层会在你完成后运行独立验证命令。`;
}

export function createCoder(params) {
  const runCodexImpl = params.runCodex ?? runCodex;
  const runPiImpl = params.runPi ?? runPi;
  return {
    async execute({ read, config, signal, emit, tick, counter }) {
      const assignments = read('assignments');
      const plan = read('plan');
      const repo = read('repo');
      const verify = read('verify');
      const workspace = config.workspace;
      const taskById = new Map((plan?.tasks ?? []).map(task => [task.id, task]));

      const results = [];
      const usage = [];
      const previous = read('execution')?.history ?? [];
      // history 跨返工轮次只追加；allCompleted 以每个计划任务最新一次尝试为准。
      const done = (terminal) => {
        const history = [...previous, ...results];
        const latest = new Map(history.map(r => [r.taskId, r.status]));
        const allCompleted = taskById.size > 0 && [...taskById.keys()].every(id => latest.get(id) === 'completed');
        return { outputs: { execution: { results, usage, history, allCompleted } }, ...(terminal ? { terminal } : {}) };
      };
      for (const assignment of assignments?.assignments ?? []) {
        const task = taskById.get(assignment.taskId);
        if (!task) {
          return done({ status: 'blocked', reason: `路由引用了未知任务 ${assignment.taskId}` });
        }
        if (assignment.worker === 'codex') {
          // 黑板计数器 codex-calls 是跨轮次的唯一事实来源（命名受 NS 规则约束，不能用驼峰）。
          if ((counter('codex-calls') ?? 0) >= config.limits.maxCodexExecutions) {
            return done({ status: 'blocked', reason: `Codex 执行预算耗尽（${config.limits.maxCodexExecutions}）。` });
          }
          await tick('codex-calls');
        }
        emit({ type: 'task_started', taskId: task.id, worker: assignment.worker, attemptReason: assignment.reason });
        const prompt = taskPrompt({ task, plan, repo, verify, workspace });
        try {
          const response = assignment.worker === 'codex'
            ? await runCodexImpl({ prompt, workspace, config: config.codex, mode: 'execute', signal })
            : await runPiImpl({
                prompt, workspace, signal,
                config: { command: config.pi.command, ...config.pi[assignment.worker] },
              });
          const result = parseExecutionResult(response);
          usage.push(result.usage);
          results.push({ taskId: task.id, worker: assignment.worker, status: result.status, summary: result.text, questions: result.questions });
          if (result.status === 'needs_input') {
            return done({ status: 'needs_input', questions: result.questions, reason: `任务 ${task.id} 需要用户决策。` });
          }
          if (result.status === 'blocked') {
            return done({ status: 'blocked', reason: `任务 ${task.id} 被 ${assignment.worker} 报告阻塞：${result.text}` });
          }
          emit({ type: 'task_finished', taskId: task.id, worker: assignment.worker, status: 'completed' });
        } catch (error) {
          if (error?.code === 'PROCESS_CANCELLED' || signal?.aborted) throw error;
          // A failed executor attempt is data for the router, not a run failure:
          // record it and let the backedge rework decide what happens next.
          results.push({ taskId: task.id, worker: assignment.worker, status: 'failed', summary: error instanceof Error ? error.message : String(error), code: error?.code ?? null });
          emit({ type: 'task_failed', taskId: task.id, worker: assignment.worker, code: error?.code ?? null });
        }
      }
      // Failed attempts stay as data: allCompleted=false drives the backedge
      // so the router can try the next candidate.
      return done();
    },
  };
}
