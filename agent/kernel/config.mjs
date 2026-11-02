// Configuration: load agent.json (falling back to agent.example.json), keep
// the validation style of yahaagent's config.mjs, and redact secrets the same way.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const AGENT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const RUNS_DIR = path.join(AGENT_DIR, '..', '.runs');

function intOr(value, fallback, { min = 1, max = 2_147_483_647 } = {}) {
  return Number.isSafeInteger(value) && value >= min && value <= max ? value : fallback;
}

export function redact(value, secret) {
  if (!secret) return value;
  if (typeof value === 'string') return value.replaceAll(secret, '[REDACTED]');
  if (Array.isArray(value)) return value.map((item) => redact(item, secret));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [redact(key, secret), redact(item, secret)]));
  }
  return value;
}

/**
 * Minimal .env loader: existing environment always wins, values never re-parsed.
 * Accepts `export KEY=...`; quoted values are taken verbatim, unquoted values
 * drop a trailing ` # comment` and surrounding whitespace.
 */
export function loadDotEnv(file = path.join(AGENT_DIR, '..', '.env')) {
  if (!fs.existsSync(file)) return [];
  const loaded = [];
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/);
    if (!match || line.trim().startsWith('#')) continue;
    const raw = match[2].trim();
    const quoted = raw.match(/^(["'])(.*)\1$/);
    const value = quoted ? quoted[2] : raw.replace(/\s+#.*$/, '').trim();
    if (!Object.hasOwn(process.env, match[1])) process.env[match[1]] = value;
    loaded.push(match[1]);
  }
  return loaded;
}

export function loadConfig(configPath) {
  const explicit = typeof configPath === 'string';
  const file = explicit ? configPath : path.join(AGENT_DIR, '..', 'agent.json');
  const fallback = path.join(AGENT_DIR, '..', 'agent.example.json');
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (explicit || !fs.existsSync(fallback)) {
      throw Object.assign(new Error(`Configuration file is missing: ${file}`), { code: 'CONFIG_MISSING', cause: error });
    }
    raw = fs.readFileSync(fallback, 'utf8');
  }
  let config;
  try {
    config = JSON.parse(raw);
  } catch (error) {
    throw Object.assign(new Error(`Configuration is not valid JSON: ${file}`), { code: 'CONFIG_INVALID', cause: error });
  }

  if (!config.llm || typeof config.llm.endpoint !== 'string' || !/^https:\/\//.test(config.llm.endpoint)) {
    throw Object.assign(new Error('llm.endpoint must be an HTTPS URL.'), { code: 'CONFIG_INVALID' });
  }
  if (typeof config.llm.model !== 'string' || !config.llm.model.trim()) {
    throw Object.assign(new Error('llm.model is required.'), { code: 'CONFIG_INVALID' });
  }
  if (!['glm', 'jev', 'codex'].includes(config.router?.provider)) {
    throw Object.assign(new Error('router.provider must be glm, jev or codex.'), { code: 'CONFIG_INVALID' });
  }
  if (typeof config.codex?.command !== 'string' || !config.codex.command.trim()) {
    throw Object.assign(new Error('codex.command is required.'), { code: 'CONFIG_INVALID' });
  }
  if (typeof config.pi?.command !== 'string' || !config.pi.command.trim()) {
    throw Object.assign(new Error('pi.command is required.'), { code: 'CONFIG_INVALID' });
  }
  if (!Array.isArray(config.verify?.commands)) {
    throw Object.assign(new Error('verify.commands must be an array.'), { code: 'CONFIG_INVALID' });
  }

  const workspace = path.resolve(AGENT_DIR, '..', config.workspace ?? '..');
  if (!fs.existsSync(workspace) || !fs.statSync(workspace).isDirectory()) {
    throw Object.assign(new Error(`workspace does not exist: ${workspace}`), { code: 'CONFIG_INVALID' });
  }

  // Relative paths in the config resolve against the yahamic repo root (the
  // parent of agent/), matching how "../yahallmwiki" reads naturally.
  const repoRoot = path.resolve(AGENT_DIR, '..', '..');
  const absolute = (value) => (typeof value === 'string' && value && !path.isAbsolute(value) ? path.resolve(repoRoot, value) : value);
  // Bare command names ("codex", "pi") stay PATH lookups; only paths are resolved.
  const commandPath = (value) => (typeof value === 'string' && value.includes('/') ? absolute(value) : value);
  const wiki = config.wiki?.repository
    ? {
        ...config.wiki,
        repository: absolute(config.wiki.repository),
        home: absolute(config.wiki.home ?? path.join(config.wiki.repository, 'wiki')),
        stateHome: absolute(config.wiki.stateHome ?? path.join(config.wiki.repository, 'state')),
      }
    : config.wiki;

  return {
    ...config,
    workspace,
    agentDir: AGENT_DIR,
    codex: { ...config.codex, command: commandPath(config.codex.command) },
    pi: { ...config.pi, command: commandPath(config.pi.command) },
    wiki,
    llm: {
      ...config.llm,
      apiKeyEnv: config.llm.apiKeyEnv ?? 'ZHIPU_API_KEY',
      maxOutputTokens: intOr(config.llm.maxOutputTokens, 8192, { min: 256, max: 65536 }),
      timeoutMs: intOr(config.llm.timeoutMs, 180_000, { min: 1000 }),
    },
    limits: {
      maxTasks: intOr(config.limits?.maxTasks, 8, { min: 1, max: 32 }),
      maxAttemptsPerTask: intOr(config.limits?.maxAttemptsPerTask, 2, { min: 1, max: 3 }),
      maxCodexExecutions: intOr(config.limits?.maxCodexExecutions, 1, { min: 0, max: 8 }),
    },
  };
}
