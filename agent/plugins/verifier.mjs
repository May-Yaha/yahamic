// Action node: run the configured verification commands in the workspace.
// Command failures are data (written to the verify namespace for the router's
// next decision), never node failures; only cancellation interrupts the run.

import path from 'node:path';
import { runProcess } from '../kernel/process.mjs';

const DIAGNOSTIC_LIMIT = 4096;

function diagnosticsOf(stdout, stderr) {
  const text = `${stderr.trim()}\n${stdout.trim()}`.trim();
  return text.length > DIAGNOSTIC_LIMIT ? text.slice(-DIAGNOSTIC_LIMIT) : text;
}

export function createVerifier(params) {
  const runProcessImpl = params.runProcess ?? runProcess;
  return {
    async execute({ config, signal, emit }) {
      const commands = config.verify?.commands ?? [];
      if (commands.length === 0) {
        return { outputs: { verify: { checks: [], allPassed: null, note: '未配置验证命令。' } } };
      }
      const checks = [];
      for (const entry of commands) {
        const label = typeof entry.label === 'string' && entry.label.trim() ? entry.label : `${entry.command} ${(entry.args ?? []).join(' ')}`.trim();
        emit({ type: 'verify_started', label });
        try {
          const result = await runProcessImpl({
            command: entry.command,
            args: entry.args ?? [],
            cwd: entry.cwd ? path.resolve(config.workspace, entry.cwd) : config.workspace,
            timeoutMs: entry.timeoutMs ?? 600_000,
            signal,
            outputMode: 'capture',
          });
          checks.push({ label, command: entry.command, passed: result.exitCode === 0, exitCode: result.exitCode, diagnostics: diagnosticsOf(result.stdout, result.stderr) });
        } catch (error) {
          if (error?.code === 'PROCESS_CANCELLED' || signal?.aborted) throw error;
          checks.push({ label, command: entry.command, passed: false, exitCode: error?.exitCode ?? null, diagnostics: `${error?.code ?? 'ERROR'}: ${error instanceof Error ? error.message : String(error)}` });
        }
        emit({ type: 'verify_finished', label, passed: checks[checks.length - 1].passed });
      }
      return { outputs: { verify: { checks, allPassed: checks.every(check => check.passed) } } };
    },
  };
}
