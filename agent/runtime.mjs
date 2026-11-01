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

export async function runTask({ task, graphName = 'coding', config, registry, signal, emit, concurrency }) {
  const graph = loadGraphFile(graphName, registry);
  const run = createRun({ graph, registry, config, workspace: config.workspace, task, runDir: RUNS_DIR, signal, emit, concurrency });
  const report = await run.start();
  return { run, report };
}
