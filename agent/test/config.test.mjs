import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, loadDotEnv } from '../kernel/config.mjs';
import { createSinkCapture } from '../plugins/sink-capture.mjs';

const AGENT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

test('only command values containing a slash are resolved as paths', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-config-'));
  try {
    const example = JSON.parse(fs.readFileSync(path.join(AGENT, 'agent.example.json'), 'utf8'));
    const file = path.join(dir, 'agent.json');
    fs.writeFileSync(file, JSON.stringify({ ...example, codex: { ...example.codex, command: 'codex' }, pi: { ...example.pi, command: 'tools/pi' } }));
    const config = loadConfig(file);
    assert.equal(config.codex.command, 'codex', 'bare names stay PATH lookups');
    assert.ok(path.isAbsolute(config.pi.command) && config.pi.command.endsWith(path.join('tools', 'pi')));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('.env accepts export, inline comments on unquoted values and trims whitespace', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-env-'));
  const keys = ['YAHA_T_EXPORT', 'YAHA_T_COMMENT', 'YAHA_T_QUOTED', 'YAHA_T_HASH', 'YAHA_T_KEEP'];
  try {
    process.env.YAHA_T_KEEP = 'original';
    const file = path.join(dir, '.env');
    fs.writeFileSync(file, [
      '# comment line',
      'export YAHA_T_EXPORT=abc',
      'YAHA_T_COMMENT = value   # trailing note',
      'YAHA_T_QUOTED="keep # this"  ',
      'YAHA_T_HASH=pa#ss',
      'YAHA_T_KEEP=overridden',
    ].join('\n'));
    loadDotEnv(file);
    assert.equal(process.env.YAHA_T_EXPORT, 'abc');
    assert.equal(process.env.YAHA_T_COMMENT, 'value');
    assert.equal(process.env.YAHA_T_QUOTED, 'keep # this');
    assert.equal(process.env.YAHA_T_HASH, 'pa#ss', '# without leading space is part of the value');
    assert.equal(process.env.YAHA_T_KEEP, 'original', 'existing environment wins');
  } finally {
    for (const key of keys) delete process.env[key];
    await rm(dir, { recursive: true, force: true });
  }
});

test('capture redaction covers configured apiKeyEnv names, not just the defaults', async () => {
  process.env.YAHA_T_CUSTOM_KEY = 'sk-custom-secret';
  try {
    let captured = '';
    const sink = createSinkCapture({
      connect: async () => ({ capture: async ({ content }) => { captured = content; return { eventId: 'e' }; }, close: async () => {} }),
    });
    const facts = {
      plan: { summary: 's', tasks: [] },
      execution: { results: [{ taskId: 't', worker: 'glm', status: 'completed', summary: 'leaked sk-custom-secret here' }] },
      verify: { checks: [] },
    };
    const result = await sink.execute({
      read: ns => facts[ns], run: { id: 'r', graph: 'coding', task: 't' }, signal: null, emit: () => {},
      config: { wiki: { repository: '/w' }, llm: { apiKeyEnv: 'YAHA_T_CUSTOM_KEY' }, pi: {} },
    });
    assert.equal(result.outputs.capture.captured, true);
    assert.doesNotMatch(captured, /sk-custom-secret/);
    assert.match(captured, /\[REDACTED\]/);
  } finally {
    delete process.env.YAHA_T_CUSTOM_KEY;
  }
});
