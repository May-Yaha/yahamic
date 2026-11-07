import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createAgentServer } from '../mcp-server.mjs';
import { createDemoRegistry } from '../plugins/index.mjs';

async function connect(runsDir) {
  const { server } = createAgentServer({ registry: createDemoRegistry(), runsDir });
  const client = new Client({ name: 'test-client', version: '0.0.1' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return { client, server };
}

test('mcp server lists graphs and runs a demo task end to end', async () => {
  const runsDir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-mcp-'));
  try {
    const { client } = await connect(runsDir);
    const tools = await client.listTools();
    assert.deepEqual(tools.tools.map(t => t.name).sort(), [
      'yaha_agent_blackboard', 'yaha_agent_cancel', 'yaha_agent_graphs', 'yaha_agent_run_status', 'yaha_agent_run_task',
    ]);

    const graphs = await client.callTool({ name: 'yaha_agent_graphs', arguments: {} });
    assert.match(JSON.parse(graphs.content[0].text).graphs.join(), /coding/);

    const started = await client.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'mcp demo', demo: true } });
    const { runId } = JSON.parse(started.content[0].text);
    assert.match(runId, /^\d{14}-/);

    let status;
    for (let i = 0; i < 100; i++) {
      const response = await client.callTool({ name: 'yaha_agent_run_status', arguments: { runId } });
      status = JSON.parse(response.content[0].text);
      if (status.status === 'completed' || status.status === 'blocked') break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(status.status, 'completed');

    const board = await client.callTool({ name: 'yaha_agent_blackboard', arguments: { runId, ns: 'plan' } });
    const plan = JSON.parse(board.content[0].text);
    assert.ok(Array.isArray(plan.tasks) && plan.tasks.length >= 1);
    assert.ok(fs.existsSync(path.join(runsDir, runId, 'report.json')));
  } finally {
    await rm(runsDir, { recursive: true, force: true });
  }
});

test('run_task rejects a second concurrent run and status reports unknown ids', async () => {
  const runsDir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-mcp-'));
  try {
    const { client } = await connect(runsDir);
    const missing = await client.callTool({ name: 'yaha_agent_run_status', arguments: { runId: '20990101000000-none' } });
    assert.equal(missing.isError, true);

    const slow = createDemoRegistry();
    // Hold one run open by pausing the coder fixture with a long await.
    const { createOverrideRegistry } = await import('../plugins/index.mjs');
    const held = createOverrideRegistry(slow, {
      coder: () => ({ async execute() { await new Promise(resolve => setTimeout(resolve, 400)); return { outputs: { execution: { results: [], usage: [] } } }; } }),
    });
    const { server } = createAgentServer({ registry: held, runsDir });
    const client2 = new Client({ name: 'test-client-2', version: '0.0.1' });
    const [c2, s2] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(s2), client2.connect(c2)]);
    const first = await client2.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'held' } });
    assert.equal(JSON.parse(first.content[0].text).accepted, true);
    const second = await client2.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'concurrent' } });
    assert.equal(second.isError, true);
    await new Promise(resolve => setTimeout(resolve, 500));
  } finally {
    await rm(runsDir, { recursive: true, force: true });
  }
});

// A coder that holds the run open until cancelled, like a real executor would.
async function heldServer(runsDir) {
  const { createOverrideRegistry } = await import('../plugins/index.mjs');
  const registry = createOverrideRegistry(createDemoRegistry(), {
    coder: () => ({
      execute: ({ signal }) => new Promise((_, reject) => {
        signal.addEventListener('abort', () => reject(Object.assign(new Error('cancelled'), { code: 'PROCESS_CANCELLED' })), { once: true });
      }),
    }),
  });
  const agent = createAgentServer({ registry, runsDir });
  const client = new Client({ name: 'held', version: '0.0.1' });
  const [c, s] = InMemoryTransport.createLinkedPair();
  await Promise.all([agent.server.connect(s), client.connect(c)]);
  return { agent, client };
}

async function settled(agent) {
  for (let i = 0; i < 100 && agent.inFlight; i++) await new Promise(resolve => setTimeout(resolve, 20));
  return agent.inFlight;
}

test('cancel tool and transport close abort the in-flight run; lock and runId are enforced', async () => {
  const runsDir = await mkdtemp(path.join(tmpdir(), 'yaha-agent-mcp-'));
  try {
    const { agent, client } = await heldServer(runsDir);
    const traversal = await client.callTool({ name: 'yaha_agent_blackboard', arguments: { runId: '../../etc' } });
    assert.equal(traversal.isError, true);
    assert.match(traversal.content[0].text, /格式无效/);
    assert.equal((await client.callTool({ name: 'yaha_agent_cancel', arguments: {} })).isError, true);

    const { runId } = JSON.parse((await client.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'held' } })).content[0].text);
    assert.equal(fs.readFileSync(path.join(runsDir, '.lock'), 'utf8'), String(process.pid));
    const cancelled = JSON.parse((await client.callTool({ name: 'yaha_agent_cancel', arguments: {} })).content[0].text);
    assert.deepEqual(cancelled, { cancelled: true, runId });
    assert.equal(await settled(agent), null);
    const status = JSON.parse((await client.callTool({ name: 'yaha_agent_run_status', arguments: { latest: true } })).content[0].text);
    assert.equal(status.runId, runId, '.lock is not mistaken for the latest run');
    assert.equal(status.status, 'interrupted');
    assert.equal(fs.existsSync(path.join(runsDir, '.lock')), false, 'lock released on finish');

    // A live foreign lock (our own pid stands in for another process) blocks a new run.
    fs.writeFileSync(path.join(runsDir, '.lock'), String(process.pid));
    assert.equal((await client.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'locked' } })).isError, true);
    fs.rmSync(path.join(runsDir, '.lock'));

    await client.callTool({ name: 'yaha_agent_run_task', arguments: { task: 'orphaned' } });
    assert.ok(agent.inFlight);
    await client.close();
    assert.equal(await settled(agent), null, 'closing the transport aborts the run');
  } finally {
    await rm(runsDir, { recursive: true, force: true });
  }
});
