// Sink node: render a human-readable summary into the report namespace for
// MCP clients and the CLI. The durable report.json is written by kernel/run.mjs.

export function createSinkReport() {
  return {
    async execute({ read, run }) {
      const plan = read('plan');
      const execution = read('execution');
      const verify = read('verify');
      const assignments = read('assignments');
      const lines = [`任务：${run.task}`];
      if (plan?.summary) lines.push(`计划：${plan.summary}`);
      if (assignments?.rework) lines.push('（验证未通过后返工，重新路由执行者）');
      for (const result of execution?.results ?? []) {
        const mark = result.status === 'completed' ? '✓' : result.status === 'failed' ? '✗' : '⚠';
        lines.push(`${mark} ${result.taskId} [${result.worker}] ${result.status}：${String(result.summary).slice(0, 300)}`);
        for (const question of result.questions ?? []) lines.push(`    ? ${question}`);
      }
      for (const check of verify?.checks ?? []) {
        lines.push(`${check.passed ? '✓' : '✗'} 验证：${check.label}`);
      }
      if (verify && verify.allPassed === null) lines.push('⚠ 未配置验证命令，结果未验证。');
      return { outputs: { report: { text: lines.join('\n') } } };
    },
  };
}
