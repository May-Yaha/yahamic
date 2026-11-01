#!/usr/bin/env node
// yaha-agent CLI: run / status / doctor / demo / mcp.

import fs from 'node:fs';
import path from 'node:path';
import { loadDotEnv, loadConfig, RUNS_DIR } from '../kernel/config.mjs';
import { doctor } from '../doctor.mjs';
import { runTask, listGraphs, loadGraphFile } from '../runtime.mjs';
import { createAgentRegistry, createDemoRegistry } from '../plugins/index.mjs';

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token.startsWith('--')) {
      const key = token.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) args[key] = true;
      else { args[key] = next; i++; }
    } else args._.push(token);
  }
  return args;
}

function usage() {
  return `yaha-agent — yahamic 的 coding agent 微内核(静态图 + 概率决策点 + 黑板)

用法：
  yaha-agent run --task "修复 mac 端重连问题" [--graph coding] [--config path]
      执行一次图工作流;进度实时打印,结束后输出 report 路径与终态。
  yaha-agent status [--run <runId> | --last]
      查看运行状态与黑板摘要。
  yaha-agent doctor
      本机检查(配置、凭证、命令、wiki);不发模型请求。
  yaha-agent demo
      离线演示:同一张 coding 图,全部节点换 fixture,零模型调用。
  yaha-agent mcp
      启动 MCP server(stdio),供 Agent 宿主调用。
`;
}

function printEvent(event) {
  const mark = { node_started: '▶', node_finished: '·', node_failed: '✗', node_fallback: '⚠', backedge_taken: '↺', node_requeued: '↻', run_finished: '=' }[event.type] ?? '·';
  const detail = {
    node_started: `${event.node} (${event.plugin})`,
    node_finished: `${event.node}`,
    node_failed: `${event.node} code=${event.code}`,
    node_fallback: `${event.node} code=${event.code}(降级继续)`,
    backedge_taken: `${event.from} → ${event.to}(${event.counter}=${event.value})`,
    node_requeued: `${event.node ?? '(级联)'}`,
    run_finished: `status=${event.status}`,
    task_started: `task ${event.taskId} → ${event.worker}`,
    task_finished: `task ${event.taskId} ✓`,
    task_failed: `task ${event.taskId} ✗ (${event.code})`,
    verify_started: `验证 ${event.label}`,
    verify_finished: `验证 ${event.label} ${event.passed ? '✓' : '✗'}`,
    route_degraded: `路由降级(${event.provider}:${event.code}),使用默认候选`,
  }[event.type];
  if (detail !== undefined) console.log(`${mark} ${event.type.padEnd(16)} ${detail}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] ?? 'help';
  loadDotEnv();

  if (command === 'help' || args.help) {
    console.log(usage());
    return 0;
  }

  if (command === 'doctor') {
    const result = await doctor({ configPath: args.config });
    for (const check of result.checks) {
      const icon = check.status === 'ok' ? '✓' : check.status === 'warn' ? '⚠' : '✗';
      console.log(`${icon} ${check.name}${check.detail ? ` — ${check.detail}` : ''}`);
    }
    console.log(result.summary);
    return result.ok ? 0 : 1;
  }

  if (command === 'demo') {
    const task = typeof args.task === 'string' ? args.task : '演示:给 README 加一行说明';
    const config = loadConfig(args.config);
    const registry = createDemoRegistry();
    console.log(`[simulation] demo 使用 fixture 插件,零模型调用;graph=coding, task=${task}\n`);
    const { report } = await runTask({ task, config, registry, emit: printEvent });
    console.log(`\n${report.facts?.report?.text ?? '(无报告)'}`);
    console.log(`\n终态:${report.status}${report.dir ?? ''}`);
    return report.status === 'completed' ? 0 : 1;
  }

  if (command === 'run') {
    if (typeof args.task !== 'string' || !args.task.trim()) {
      console.error('缺少 --task。示例:yaha-agent run --task "修复 mac 端重连问题"');
      return 2;
    }
    const graphName = typeof args.graph === 'string' ? args.graph : 'coding';
    const config = loadConfig(args.config);
    const registry = createAgentRegistry();
    const controller = new AbortController();
    const onSignal = () => controller.abort();
    process.once('SIGINT', onSignal);
    process.once('SIGTERM', onSignal);
    try {
      const { report } = await runTask({ task: args.task, graphName, config, registry, signal: controller.signal, emit: printEvent, concurrency: 2 });
      console.log(`\n${report.facts?.report?.text ?? ''}`);
      if (report.questions?.length) {
        console.log('\n需要澄清:');
        for (const question of report.questions) console.log(`  ? ${question}`);
      }
      if (report.reason) console.log(`\n原因:${report.reason}`);
      console.log(`\n终态:${report.status}  运行目录:${path.join(RUNS_DIR, report.runId)}`);
      return report.status === 'completed' ? 0 : 1;
    } finally {
      process.removeListener('SIGINT', onSignal);
      process.removeListener('SIGTERM', onSignal);
    }
  }

  if (command === 'status') {
    let runId = args.run;
    if (runId === true || runId === undefined) {
      if (!args.last) { console.error('需要 --run <runId> 或 --last'); return 2; }
      const entries = fs.existsSync(RUNS_DIR) ? fs.readdirSync(RUNS_DIR).sort() : [];
      if (!entries.length) { console.error('没有历史运行。'); return 1; }
      runId = entries[entries.length - 1];
    }
    const dir = path.join(RUNS_DIR, runId);
    const reportFile = path.join(dir, 'report.json');
    if (fs.existsSync(reportFile)) {
      const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
      console.log(`run ${report.runId} [${report.graph}] ${report.status}`);
      console.log(`任务:${report.task}`);
      console.log(report.facts?.report?.text ?? '');
      if (report.reason) console.log(`原因:${report.reason}`);
      return 0;
    }
    const boardFile = path.join(dir, 'blackboard.json');
    if (fs.existsSync(boardFile)) {
      const board = JSON.parse(fs.readFileSync(boardFile, 'utf8'));
      console.log(`run ${runId} [${board.run.status}] 任务:${board.run.task}`);
      console.log(`facts:${Object.keys(board.facts).join(', ') || '(空)'}  counters:${JSON.stringify(board.counters)}`);
      console.log('(尚无最终 report;若进程已退出,该运行为 interrupted)');
      return 0;
    }
    console.error(`找不到运行:${runId}`);
    return 1;
  }

  if (command === 'graphs') {
    const config = loadConfig(args.config);
    const registry = createAgentRegistry();
    for (const name of listGraphs()) {
      const graph = loadGraphFile(name, registry);
      console.log(`${name}: ${graph.nodes.size} 节点 / ${graph.order.join(' → ')}`);
    }
    return 0;
  }

  if (command === 'mcp') {
    await import('../mcp-server.mjs').then(module => module.serve());
    return 0;
  }

  console.error(`未知命令:${command}\n`);
  console.error(usage());
  return 2;
}

main().then(code => process.exit(code)).catch(error => {
  console.error(`${error?.code ?? 'ERROR'}: ${error instanceof Error ? error.message : error}`);
  process.exit(1);
});
