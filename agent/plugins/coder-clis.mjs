// Executor CLIs ported from yahaagent/src/adapters/{codex,pi}.mjs (MIT, same
// author): Codex via saved ChatGPT login, Pi via Coding-Plan providers. Only
// the config shape was adapted to this project's agent.json.

import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess, throwIfCancelled } from '../kernel/process.mjs';
import { EXECUTION_RESULT_PROTOCOL } from '../kernel/result.mjs';

function codexError(message, code, details = {}) {
  return Object.assign(new Error(message), { code, ...details });
}

function reportsUsageLimit(event) {
  if (!['error', 'turn.failed'].includes(event.type)) return false;
  const limit = /\b(?:(?:usage|rate)[ _-]+limit(?:ed|s)?(?:[ _-]+(?:reached|exceeded|exhausted))?|insufficient[ _-]+quota|quota[ _-]+(?:exceeded|exhausted))\b/i;
  const inspect = (value, depth) => {
    if (typeof value === 'string') return limit.test(value);
    if (!value || typeof value !== 'object' || depth === 0) return false;
    return ['message', 'error', 'code'].some(key => inspect(value[key], depth - 1));
  };
  return inspect(event, 4);
}

function usageLimitError(details = {}) {
  return codexError('Codex 明确报告用量或请求频率限制，本轮已停止。请检查账号额度或稍后重试；不会自动重放任务。', 'CODEX_USAGE_LIMIT', details);
}

export function codexTimeoutMs(config = {}, mode = 'execute') {
  return config[mode === 'plan' ? 'planningTimeoutMs' : 'executionTimeoutMs'] ?? config.timeoutMs ?? 600_000;
}

export function subscriptionEnvironment(source = process.env) {
  const env = { ...source };
  for (const key of Object.keys(env)) {
    if (['CODEX_API_KEY', 'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'OPENAI_FEDERATION_RULE_ID', 'OPENAI_IDENTITY_TOKEN_FILE'].includes(key.toUpperCase())
      || /ACCESS_TOKEN|WORKLOAD_IDENTITY/i.test(key)
      || /(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD)$/i.test(key)
      || /^(?:GLM|KIMI|MOONSHOT|ZAI|ZHIPU|JEV|TYPESAFE)_/i.test(key)) {
      delete env[key];
    }
  }
  return env;
}

/** Use saved ChatGPT authentication; never fall back to an API-key provider. */
export async function runCodex({ prompt, workspace, config = {}, mode = 'execute', schemaPath, onEvent, signal }) {
  throwIfCancelled(signal);
  if (!['plan', 'execute'].includes(mode) || typeof prompt !== 'string' || !prompt.trim()) {
    throw codexError('Invalid Codex request.', 'CODEX_INVALID_REQUEST');
  }
  const command = config.command ?? 'codex';
  const timeoutMs = codexTimeoutMs(config, mode);
  const env = subscriptionEnvironment();
  if (config.proxyUrl) {
    let proxy;
    try { proxy = new URL(config.proxyUrl); } catch { throw codexError('Invalid Codex proxy URL.', 'CODEX_INVALID_PROXY'); }
    if (!['http:', 'https:'].includes(proxy.protocol) || proxy.username || proxy.password) throw codexError('Codex proxy must use HTTP(S) without embedded credentials.', 'CODEX_INVALID_PROXY');
    for (const name of ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy']) env[name] = proxy.href;
  }
  let auth;
  try {
    auth = await runProcess({ command, args: ['login', 'status'], cwd: workspace, env, timeoutMs: Math.min(timeoutMs, 30_000), signal });
  } catch (error) {
    if (error.code === 'PROCESS_CANCELLED') throw error;
    if (error.code === 'PROCESS_SPAWN_FAILED') {
      if (error.causeCode === 'ENOENT') {
        throw codexError('无法启动 Codex：命令或工作目录不存在。请检查 codex.command 和工作区路径；配置 Codex 可执行文件的绝对路径可避免终端 PATH 差异。', 'CODEX_COMMAND_NOT_FOUND');
      }
      throw codexError(`无法启动 Codex（${error.causeCode ?? '未知启动错误'}）。请检查 codex.command 对应文件是否可执行。`, 'CODEX_START_FAILED');
    }
    if (error.code === 'PROCESS_TIMEOUT') {
      throw codexError('Codex 登录状态检查超时，尚未确认登录状态。请在同一终端检查配置的 Codex 命令能否正常运行。', 'CODEX_AUTH_CHECK_TIMEOUT', { timeoutMs: error.timeoutMs, durationMs: error.durationMs });
    }
    throw codexError(`无法确认 Codex 登录状态（${error.code}${Number.isInteger(error.exitCode) ? `，退出码 ${error.exitCode}` : ''}）。请使用配置的 Codex 命令运行 login status 查看原因。`, 'CODEX_AUTH_CHECK_FAILED');
  }
  if (!`${auth.stdout}\n${auth.stderr}`.includes('Logged in using ChatGPT')) {
    throw codexError('Codex requires a saved ChatGPT subscription login. Run codex login first.', 'CODEX_SUBSCRIPTION_REQUIRED');
  }

  const args = ['exec', '--json', '--ephemeral', '--ignore-user-config', '--skip-git-repo-check', '--sandbox', mode === 'plan' ? 'read-only' : 'workspace-write'];
  if (config.model) args.push('--model', config.model);
  if (schemaPath) args.push('--output-schema', schemaPath);
  args.push('-');

  let text = '';
  let usage = null;
  let completed = false;
  let failed = false;
  let pendingError = false;
  let usageLimited = false;
  let malformed = false;
  try {
    await runProcess({
      command, args, cwd: workspace, input: prompt, env, timeoutMs, signal, outputMode: 'stream',
      onLine(line) {
        if (!line.trim()) return;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          malformed = true;
          return;
        }
        if (!event || typeof event !== 'object' || typeof event.type !== 'string') {
          malformed = true;
          return;
        }
        const usageLimit = reportsUsageLimit(event);
        if (event.type === 'turn.failed' && !usageLimit) failed = true;
        if (event.type === 'error') pendingError = true;
        if (usageLimit) usageLimited = true;
        if (event.type === 'turn.completed') {
          completed = true;
          pendingError = false;
          usageLimited = false;
          usage = event.usage ?? null;
        }
        if (event.type === 'item.completed' && event.item?.type === 'agent_message' && event.item.phase !== 'commentary' && typeof event.item.text === 'string') text = event.item.text;
        if (event.type === 'agent_message' && event.phase !== 'commentary' && typeof event.text === 'string') text = event.text;
        onEvent?.(event);
      },
    });
  } catch (error) {
    if (error.code === 'PROCESS_CANCELLED') throw error;
    throwIfCancelled(signal);
    if (error.code === 'PROCESS_EXIT_FAILED' && !error.signal && usageLimited) {
      throw usageLimitError(Number.isInteger(error.exitCode) ? { exitCode: error.exitCode } : {});
    }
    throw error;
  }
  throwIfCancelled(signal);
  if (usageLimited) throw usageLimitError();
  if (failed || pendingError) throw codexError('Codex reported a failed turn.', 'CODEX_TURN_FAILED');
  if (malformed) throw codexError('Codex returned invalid event data.', 'CODEX_INVALID_EVENTS');
  if (!completed || !text.trim()) throw codexError('Codex did not return a completed final response.', 'CODEX_MISSING_FINAL');
  return { text, usage };
}

// --- Pi (Coding Plan providers) ------------------------------------------------

const PROVIDER_KEYS = {
  'zai-coding-cn': 'ZAI_CODING_CN_API_KEY',
  'kimi-coding': 'KIMI_API_KEY',
};

function redact(value, secret) {
  if (typeof value === 'string') return value.replaceAll(secret, '[REDACTED]');
  if (Array.isArray(value)) return value.map((item) => redact(item, secret));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key, secret), redact(item, secret)]));
  }
  return value;
}

function childEnvironment(apiKeyEnv, providerKey, key, agentDir) {
  const env = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (name === apiKeyEnv || /(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD)$/.test(name)) continue;
    if (name.startsWith('PI_')) continue;
    env[name] = value;
  }
  env[providerKey] = key;
  env.PI_CODING_AGENT_DIR = agentDir;
  env.PI_OFFLINE = '1';
  return env;
}

function addUsage(total, usage) {
  if (!usage || typeof usage !== 'object') return total;
  total ??= {
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
  const number = (value) => Number.isFinite(value) && value >= 0 ? value : 0;
  for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens']) {
    total[field] += number(usage[field]);
  }
  for (const field of ['reasoning', 'cacheWrite1h']) {
    if (Number.isFinite(usage[field]) && usage[field] >= 0) {
      total[field] = (total[field] ?? 0) + usage[field];
    }
  }
  for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'total']) {
    total.cost[field] += number(usage.cost?.[field]);
  }
  return total;
}

/** Run one isolated Pi coding task. No provider calls occur before this function. */
export async function runPi({ prompt, workspace, config, systemPrompt = EXECUTION_RESULT_PROTOCOL, onEvent, signal }) {
  throwIfCancelled(signal);
  const providerKey = PROVIDER_KEYS[config.provider];
  if (!providerKey) throw new Error(`Unsupported Pi Coding Plan provider: ${config.provider}`);
  const key = process.env[config.apiKeyEnv];
  if (!key?.trim()) throw new Error(`Missing Pi credential environment variable: ${config.apiKeyEnv}`);
  if (typeof prompt !== 'string' || !prompt.trim()) throw new Error('Pi prompt must not be empty');
  if (!config.model || !config.command) throw new Error('Pi command and model are required');

  const agentDir = await mkdtemp(join(tmpdir(), 'yahamic-agent-pi-'));
  let lastAssistant;
  let usage = null;
  let protocolError;
  let settled = false;
  try {
    const args = [
      '--print', '--mode', 'json', '--no-session', '--offline',
      '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes',
      '--no-approve', '--provider', config.provider, '--model', config.model,
    ];
    if (systemPrompt) args.push('--append-system-prompt', systemPrompt);
    await runProcess({
      command: config.command,
      args,
      cwd: workspace,
      input: prompt,
      env: childEnvironment(config.apiKeyEnv, providerKey, key, agentDir),
      timeoutMs: config.timeoutMs,
      outputMode: 'stream',
      signal,
      onLine(line) {
        if (!line.trim() || protocolError) return;
        let event;
        try {
          event = JSON.parse(line);
          if (!event || typeof event !== 'object' || Array.isArray(event) || typeof event.type !== 'string') {
            throw new Error('Expected a Pi JSON event');
          }
        } catch {
          protocolError = new Error('Pi returned an invalid JSONL event');
          throw protocolError;
        }
        event = redact(event, key);
        if (event.type === 'message_end') {
          const message = event.message;
          if (message?.role === 'assistant') lastAssistant = message;
          if (message?.role === 'assistant' || message?.role === 'toolResult') {
            usage = addUsage(usage, message.usage);
          }
        } else if (event.type === 'compaction_end') {
          usage = addUsage(usage, event.result?.usage);
        } else if (event.type === 'agent_settled') {
          settled = true;
        }
        onEvent?.(event);
      },
    });
    throwIfCancelled(signal);
    if (protocolError) throw protocolError;
    if (!lastAssistant) throw new Error('Pi exited without a completed assistant message');
    if (lastAssistant.stopReason !== 'stop') {
      throw new Error(`Pi task did not complete (${lastAssistant.stopReason ?? 'unknown'}): ${lastAssistant.errorMessage ?? 'no final answer'}`);
    }
    if (!settled) throw new Error('Pi exited before agent_settled');
    const textBlocks = (Array.isArray(lastAssistant.content) ? lastAssistant.content : [])
      .filter((block) => block.type === 'text' && typeof block.text === 'string');
    const text = textBlocks.map((block) => block.text).join('\n');
    if (!text.trim()) throw new Error('Pi completed without a text result');
    return { text, usage, stopReason: lastAssistant.stopReason, textBlockCount: textBlocks.length };
  } catch (error) {
    const failure = protocolError ?? error;
    const safeError = new Error(redact(failure instanceof Error ? failure.message : String(failure), key));
    if (typeof failure?.code === 'string') safeError.code = redact(failure.code, key);
    if (typeof failure?.signal === 'string' || failure?.signal === null) {
      safeError.signal = redact(failure.signal, key);
    }
    if (Number.isInteger(failure?.exitCode) || failure?.exitCode === null) {
      safeError.exitCode = failure.exitCode;
    }
    for (const field of ['timeoutMs', 'durationMs']) {
      if (Number.isSafeInteger(failure?.[field]) && failure[field] >= 0) safeError[field] = failure[field];
    }
    throw safeError;
  } finally {
    await rm(agentDir, { recursive: true, force: true });
  }
}
