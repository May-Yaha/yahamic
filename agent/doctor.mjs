// Doctor: local checks only, never a model request (yahaagent rule).
// ok = required for a real run; warn = only needed for the related executor.

import fs from 'node:fs';
import path from 'node:path';
import { runProcess, allowlistedEnv } from './kernel/process.mjs';
import { loadConfig } from './kernel/config.mjs';

function commandExists(command) {
  if (!command || typeof command !== 'string') return false;
  if (command.includes('/')) return fs.existsSync(command);
  for (const dir of process.env.PATH.split(path.delimiter)) {
    if (dir && fs.existsSync(path.join(dir, command))) return true;
  }
  return false;
}

export async function doctor({ configPath } = {}) {
  const checks = [];
  const ok = (name, passed, detail = null) => checks.push({ name, status: passed ? 'ok' : 'fail', detail });
  const warn = (name, passed, detail = null) => checks.push({ name, status: passed ? 'ok' : 'warn', detail });

  const [major, minor] = process.versions.node.split('.').map(Number);
  ok('node >= 22.19', major > 22 || (major === 22 && minor >= 19), `current ${process.versions.node}`);

  let config = null;
  try {
    config = loadConfig(configPath);
    ok('config', true, config.workspace);
  } catch (error) {
    ok('config', false, error.message);
    return { ok: false, checks, summary: 'Configuration failed; later checks were skipped.' };
  }

  const envFile = path.join(config.agentDir, '..', '.env');
  ok('.env present', fs.existsSync(envFile), envFile);
  warn(`env ${config.llm.apiKeyEnv}`, Boolean(process.env[config.llm.apiKeyEnv]?.trim()), '决策点(plan/route)必需');
  warn('env ZAI_CODING_CN_API_KEY', Boolean(process.env.ZAI_CODING_CN_API_KEY?.trim()), 'Pi glm 执行者');
  warn('env KIMI_API_KEY', Boolean(process.env.KIMI_API_KEY?.trim()), 'Pi kimi 执行者');
  warn('env TYPESAFE_API_KEY', Boolean(process.env.TYPESAFE_API_KEY?.trim()), 'Jev 路由(可选)');

  warn('codex command', commandExists(config.codex?.command), config.codex?.command);
  if (config.codex?.command && commandExists(config.codex.command)) {
    try {
      const result = await runProcess({ command: config.codex.command, args: ['login', 'status'], env: allowlistedEnv(), timeoutMs: 15_000 });
      ok('codex login', `${result.stdout}\n${result.stderr}`.includes('Logged in using ChatGPT'));
    } catch (error) {
      ok('codex login', false, error?.code ?? error.message);
    }
  }
  warn('pi command', commandExists(config.pi?.command), config.pi?.command);
  for (const entry of config.verify?.commands ?? []) {
    warn(`verify command: ${entry.command}`, commandExists(entry.command), entry.cwd ? `cwd: ${entry.cwd}` : null);
  }
  if (config.wiki?.repository && config.wiki.enabled !== false) {
    const repo = config.wiki.repository; // loadConfig already resolves it
    warn('wiki mcp server', fs.existsSync(path.join(repo, 'dist', 'mcp.js')), repo);
  }

  const failed = checks.filter(check => check.status === 'fail').length;
  const warned = checks.filter(check => check.status === 'warn').length;
  return {
    ok: failed === 0,
    checks,
    summary: `${checks.length} 项检查：${checks.length - failed - warned} 通过，${warned} 警告，${failed} 失败。doctor 不发模型请求。`,
  };
}
