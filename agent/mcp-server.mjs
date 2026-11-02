// Thin MCP server exposing the microkernel to agent hosts (ZCode, Claude
// Code, Codex): start a run, poll status, read the blackboard, list graphs.
// One in-flight run at a time — the workspace lock is a graph-level promise.

import fs from 'node:fs';
import path from 'node:path';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { loadDotEnv, loadConfig, RUNS_DIR } from './kernel/config.mjs';
import { loadGraphFile, listGraphs, acquireRunLock } from './runtime.mjs';
import { createRun, isRunId } from './kernel/run.mjs';
import { createAgentRegistry, createDemoRegistry } from './plugins/index.mjs';

export function createAgentServer({ registry = createAgentRegistry(), runsDir = RUNS_DIR } = {}) {
  const server = new McpServer({ name: 'yahamic-agent', version: '0.1.0' });
  let inFlight = null;

  server.registerTool('yaha_agent_graphs', {
    description: '列出可用的图工作流(静态拓扑与节点)。',
    inputSchema: {},
  }, async () => ({
    content: [{ type: 'text', text: JSON.stringify({ graphs: listGraphs() }) }],
  }));

  server.registerTool('yaha_agent_run_task', {
    description: '在 yahamic 工作区执行一次编码图工作流(召回→规划→路由→执行→验证→沉淀)。默认立即返回 runId 供轮询;传 waitMs 则最多等待该毫秒数,期间完成会直接返回终态与报告,超时仍返回 runId。同时只能有一个运行。',
    inputSchema: {
      task: z.string().min(1).describe('编码任务描述,例如:修复 mac 端设备重连问题'),
      graph: z.string().optional().describe('图名,默认 coding'),
      demo: z.boolean().optional().describe('true 时用 fixture 插件离线演示,零模型调用'),
      waitMs: z.number().int().min(0).max(300000).optional().describe('同步等待窗口:demo/短任务建议 30000,真实编码任务建议 0(轮询)'),
    },
  }, async ({ task, graph, demo, waitMs }) => {
    if (inFlight) {
      return { isError: true, content: [{ type: 'text', text: `已有运行进行中:${inFlight.runId ?? inFlight.status};请先轮询其完成。` }] };
    }
    loadDotEnv();
    let config;
    try {
      config = loadConfig();
    } catch (error) {
      return { isError: true, content: [{ type: 'text', text: `配置错误:${error.message}` }] };
    }
    const activeRegistry = demo ? createDemoRegistry() : registry;
    let release;
    try {
      // Cross-process: a CLI `run` (or another MCP host) may hold the workspace.
      release = acquireRunLock(runsDir);
    } catch (error) {
      return { isError: true, content: [{ type: 'text', text: `无法启动运行:${error.message}` }] };
    }
    const controller = new AbortController();
    const entry = { runId: null, status: 'starting', controller };
    inFlight = entry;
    try {
      const graphDef = loadGraphFile(graph ?? 'coding', activeRegistry);
      const run = createRun({
        graph: graphDef, registry: activeRegistry, config,
        workspace: config.workspace, task, runDir: runsDir,
        signal: controller.signal, concurrency: 2,
        emit: event => { entry.status = event.type === 'run_finished' ? event.status : 'running'; },
      });
      entry.runId = run.id;
      entry.status = 'running';
      entry.promise = run.start().then(report => {
        entry.status = report.status;
        return report;
      }).catch(error => {
        entry.status = 'blocked';
        entry.error = error instanceof Error ? error.message : String(error);
      }).finally(() => { release(); if (inFlight === entry) inFlight = null; });
    } catch (error) {
      release();
      inFlight = null;
      return { isError: true, content: [{ type: 'text', text: `无法启动运行:${error.message}` }] };
    }
    // Optional synchronous wait window: short/demo runs finish in one call.
    if (Number.isSafeInteger(waitMs) && waitMs > 0) {
      const report = await Promise.race([
        entry.promise,
        new Promise(resolve => setTimeout(resolve, waitMs)),
      ]);
      if (report) {
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              accepted: true, runId: entry.runId, status: report.status,
              questions: report.questions ?? [],
              reason: report.reason ?? null,
              report: report.facts?.report?.text ?? null,
              note: '运行已结束;细节用 yaha_agent_blackboard 按 ns 读取。',
            }, null, 2),
          }],
        };
      }
    }
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({ accepted: true, runId: entry.runId, status: entry.status, note: '轮询 yaha_agent_run_status 获取进度与终态。' }),
      }],
    };
  });

  server.registerTool('yaha_agent_cancel', {
    description: '取消当前进行中的运行(中止子进程组,终态 interrupted)。',
    inputSchema: {},
  }, async () => {
    if (!inFlight) return { isError: true, content: [{ type: 'text', text: '没有进行中的运行。' }] };
    inFlight.controller.abort();
    return { content: [{ type: 'text', text: JSON.stringify({ cancelled: true, runId: inFlight.runId }) }] };
  });

  // Host went away (stdio closed): nobody can poll the result, so stop working.
  server.server.onclose = () => inFlight?.controller.abort();

  server.registerTool('yaha_agent_run_status', {
    description: '查询运行状态;输入 runId 可查看事件摘要,latest 查看当前/最近运行。',
    inputSchema: { runId: z.string().optional(), latest: z.boolean().optional() },
  }, async ({ runId, latest }) => {
    let id = runId ?? null;
    if (!id && latest) {
      if (inFlight) id = inFlight.runId;
      if (!id) {
        const entries = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).filter(isRunId).sort() : [];
        id = entries[entries.length - 1] ?? null;
      }
    }
    if (!id) return { isError: true, content: [{ type: 'text', text: '缺少 runId,且没有历史运行。' }] };
    if (!isRunId(id)) return { isError: true, content: [{ type: 'text', text: `runId 格式无效:${id}` }] };
    const reportFile = path.join(runsDir, id, 'report.json');
    if (fs.existsSync(reportFile)) {
      const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
      return { content: [{ type: 'text', text: JSON.stringify({ runId: id, status: report.status, reason: report.reason, questions: report.questions, summary: report.facts?.report?.text ?? null }) }] };
    }
    const boardFile = path.join(runsDir, id, 'blackboard.json');
    if (fs.existsSync(boardFile)) {
      const board = JSON.parse(fs.readFileSync(boardFile, 'utf8'));
      return { content: [{ type: 'text', text: JSON.stringify({ runId: id, status: board.run.status, facts: Object.keys(board.facts), counters: board.counters, note: '尚未产出最终 report。' }) }] };
    }
    return { isError: true, content: [{ type: 'text', text: `找不到运行:${id}` }] };
  });

  server.registerTool('yaha_agent_blackboard', {
    description: '读取某次运行的黑板(全部 facts 或指定命名空间,如 plan/assignments/execution/verify/report)。',
    inputSchema: { runId: z.string(), ns: z.string().optional() },
  }, async ({ runId, ns }) => {
    if (!isRunId(runId)) return { isError: true, content: [{ type: 'text', text: `runId 格式无效:${runId}` }] };
    for (const file of ['blackboard.json', 'report.json']) {
      const candidate = path.join(runsDir, runId, file);
      if (!fs.existsSync(candidate)) continue;
      const payload = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      const facts = payload.facts ?? {};
      if (ns && !Object.hasOwn(facts, ns)) {
        return { isError: true, content: [{ type: 'text', text: `命名空间不存在:${ns}(可用:${Object.keys(facts).join(', ') || '无'})` }] };
      }
      return { content: [{ type: 'text', text: JSON.stringify(ns ? facts[ns] : facts, null, 2) }] };
    }
    return { isError: true, content: [{ type: 'text', text: `找不到运行:${runId}` }] };
  });

  return { server, get inFlight() { return inFlight; } };
}

export async function serve() {
  const { server } = createAgentServer();
  const transport = new StdioServerTransport();
  // Turn host signals into a normal exit so process.mjs's exit hook kills child groups.
  for (const [name, code] of [['SIGINT', 130], ['SIGTERM', 143]]) process.once(name, () => process.exit(code));
  await server.connect(transport);
}

// Hosts (Codex/Claude Code/ZCode) launch this file directly over stdio.
import { pathToFileURL } from 'node:url';
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  serve().catch(error => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
