// Run lifecycle: identity, budget, checkpoints, terminal state machine.
// Statuses mirror yahaagent's proven set: completed / needs_input / blocked /
// interrupted (checks_passed is expressed as completed with verify evidence).

import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { createBlackboard } from './blackboard.mjs';
import { runGraph } from './graph.mjs';

function atomicWrite(file, data) {
  const temp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temp, data);
  fs.renameSync(temp, file);
}

function runId() {
  const now = new Date();
  const stamp = now.toISOString().replace(/[-:T]/g, '').slice(0, 14);
  return `${stamp}-${randomUUID().slice(0, 8)}`;
}

/**
 * Create and (optionally) execute one run of a validated graph.
 * The blackboard snapshot is persisted after every change when runDir is set,
 * so an interrupted run can always be inspected and reported on.
 */
export function createRun({ graph, registry, config, workspace, task, runDir, concurrency, signal, emit = () => {}, now = Date.now }) {
  if (typeof task !== 'string' || !task.trim()) {
    throw Object.assign(new Error('A run requires a nonempty task.'), { code: 'RUN_INVALID_TASK' });
  }
  const id = runId();
  const dir = runDir ? path.join(runDir, id) : null;
  const boardFile = dir ? path.join(dir, 'blackboard.json') : null;
  const reportFile = dir ? path.join(dir, 'report.json') : null;

  const blackboard = createBlackboard({
    run: { id, graph: graph.id, task },
    counters: graph.counters,
    onPersist: dir ? (snapshot) => {
      fs.mkdirSync(dir, { recursive: true });
      atomicWrite(boardFile, JSON.stringify(snapshot, null, 2) + '\n');
    } : undefined,
  });

  async function start() {
    const startedAt = now();
    const wallClockMs = Number.isSafeInteger(graph.limits.wallClockMs) && graph.limits.wallClockMs > 0 ? graph.limits.wallClockMs : null;
    let outcome;
    try {
      outcome = await runGraph({
        graph, registry, blackboard, signal, emit, concurrency,
        ctx: { config, workspace, runDir: dir },
      });
    } catch (error) {
      if (error?.code === 'PROCESS_CANCELLED' || signal?.aborted) {
        outcome = { status: 'interrupted', reason: 'Run was cancelled; blackboard state is preserved.' };
      } else {
        outcome = { status: 'blocked', reason: error?.message ?? String(error) };
      }
    }
    if (wallClockMs !== null && now() - startedAt > wallClockMs && outcome.status === 'completed') {
      outcome = { status: 'blocked', reason: `Wall-clock budget of ${wallClockMs} ms exceeded.` };
    }
    blackboard.setStatus(outcome.status);
    const report = {
      runId: id, graph: graph.id, task, status: outcome.status,
      questions: outcome.questions ?? [],
      reason: outcome.reason ?? null,
      finishedAt: new Date().toISOString(),
      facts: blackboard.read(),
      counters: Object.fromEntries(Object.entries(graph.counters).map(([name]) => [name, blackboard.counter(name)])),
    };
    if (dir) {
      await fsp.mkdir(dir, { recursive: true });
      atomicWrite(reportFile, JSON.stringify(report, null, 2) + '\n');
    }
    emit({ type: 'run_finished', runId: id, status: outcome.status });
    return report;
  }

  return { id, blackboard, start, dir };
}
