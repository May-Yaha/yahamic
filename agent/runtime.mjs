// Runtime assembly: graph loading + one-shot task execution shared by the CLI
// and the MCP server. A run lock prevents two agents from mutating the same
// workspace concurrently (same rule as yahaagent's workspace lock).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadGraph } from './kernel/graph.mjs';
import { createRun } from './kernel/run.mjs';
import { RUNS_DIR } from './kernel/config.mjs';

const GRAPHS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'graphs');

export function listGraphs() {
  return fs.readdirSync(GRAPHS_DIR).filter(file => file.endsWith('.json')).map(file => path.basename(file, '.json'));
}

export function loadGraphFile(name, registry) {
  if (!/^[a-z0-9-]+$/.test(name)) {
    throw Object.assign(new Error(`Graph name is invalid: ${name}`), { code: 'GRAPH_NOT_FOUND' });
  }
  const file = path.join(GRAPHS_DIR, `${name}.json`);
  if (!fs.existsSync(file)) {
    throw Object.assign(new Error(`Graph not found: ${name} (available: ${listGraphs().join(', ')})`), { code: 'GRAPH_NOT_FOUND' });
  }
  return loadGraph(JSON.parse(fs.readFileSync(file, 'utf8')), registry);
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM'; // exists, just not ours
  }
}

/**
 * Cross-process workspace lock: `<runsDir>/.lock` holds the owner pid, created
 * with 'wx'. A lock whose pid is dead (ESRCH) or unreadable is stale and is
 * replaced once. Returns an idempotent release that only removes our own lock.
 */
export function acquireRunLock(runsDir = RUNS_DIR) {
  fs.mkdirSync(runsDir, { recursive: true });
  const file = path.join(runsDir, '.lock');
  for (let attempt = 0; ; attempt++) {
    try {
      fs.writeFileSync(file, String(process.pid), { flag: 'wx' });
      break;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      let owner = NaN;
      try { owner = Number.parseInt(fs.readFileSync(file, 'utf8'), 10); } catch { /* vanished: retry */ }
      if (Number.isSafeInteger(owner) && owner > 0 && pidAlive(owner)) {
        throw Object.assign(new Error(`Another run holds the workspace lock (pid ${owner}): ${file}`), { code: 'RUN_LOCKED', pid: owner });
      }
      if (attempt > 0) {
        throw Object.assign(new Error(`Could not replace stale lock: ${file}`), { code: 'RUN_LOCKED' });
      }
      // ponytail: stale check + rm + wx is not atomic; two racers on the same
      // dead lock both retry and 'wx' lets exactly one win. Fine for one user.
      fs.rmSync(file, { force: true });
    }
  }
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    process.removeListener('exit', release);
    try {
      if (fs.readFileSync(file, 'utf8') === String(process.pid)) fs.rmSync(file, { force: true });
    } catch { /* already gone */ }
  };
  process.once('exit', release);
  return release;
}

export async function runTask({ task, graphName = 'coding', config, registry, signal, emit, concurrency }) {
  const graph = loadGraphFile(graphName, registry);
  const run = createRun({ graph, registry, config, workspace: config.workspace, task, runDir: RUNS_DIR, signal, emit, concurrency });
  const report = await run.start();
  return { run, report };
}
