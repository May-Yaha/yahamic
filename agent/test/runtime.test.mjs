import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { acquireRunLock } from '../runtime.mjs';

const PROCESS_MJS = pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'kernel', 'process.mjs')).href;

test('run lock: wx + pid, live owner blocks, dead owner is stale and replaced, release is ours only', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-lock-'));
  const file = path.join(dir, '.lock');
  try {
    const release = acquireRunLock(dir);
    assert.equal(fs.readFileSync(file, 'utf8'), String(process.pid));
    assert.throws(() => acquireRunLock(dir), { code: 'RUN_LOCKED' });
    release();
    release(); // idempotent
    assert.equal(fs.existsSync(file), false);

    const dead = spawnSync(process.execPath, ['-e', '']).pid; // exited: ESRCH
    fs.writeFileSync(file, String(dead));
    const again = acquireRunLock(dir);
    assert.equal(fs.readFileSync(file, 'utf8'), String(process.pid), 'stale lock replaced');
    fs.writeFileSync(file, '999999999'); // someone else's lock now: never deleted by our release
    again();
    assert.equal(fs.existsSync(file), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('process exit kills detached child process groups', { skip: process.platform === 'win32' }, () => {
  const script = `
    import { runProcess } from ${JSON.stringify(PROCESS_MJS)};
    runProcess({
      command: process.execPath,
      args: ['-e', 'console.log(process.pid); setInterval(() => {}, 1000)'],
      outputMode: 'stream',
      onLine: line => { console.log(line); process.exit(0); },
    }).catch(() => {});
  `;
  const pid = Number.parseInt(execFileSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8', timeout: 10_000 }), 10);
  assert.ok(pid > 0);
  let alive = true;
  for (let i = 0; i < 50 && alive; i++) {
    try { process.kill(pid, 0); spawnSync('sleep', ['0.02']); } catch (error) { alive = error.code !== 'ESRCH'; }
  }
  assert.equal(alive, false, 'grandchild was killed with its group');
});
