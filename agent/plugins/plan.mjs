// Decision point: turn the task + recalled context into a validated task plan.
// Plan validation (id/dependency/cycle rules + stable topological sort) is
// ported from yahaagent/src/plan.mjs; the prompt is rewritten for yahamic.

import { askLLM } from './llm-glm.mjs';
import { runCodex } from './coder-clis.mjs';
import { parseDecision } from '../kernel/result.mjs';

export const TASK_KINDS = ['simple', 'complex', 'ui', 'hard'];

function strings(value, nonempty = false) {
  return Array.isArray(value) && (!nonempty || value.length > 0) && value.every(x => typeof x === 'string' && x.trim());
}

export function validatePlan(plan, maxTasks = 12) {
  if (!plan || plan.version !== 1 || typeof plan.summary !== 'string' || !strings(plan.questions) || !Array.isArray(plan.tasks)) {
    throw new Error('计划格式无效，需要 version、summary、questions、tasks。');
  }
  if (plan.tasks.length > maxTasks || (plan.tasks.length === 0 && plan.questions.length === 0)) {
    throw new Error(`任务数量必须为 1–${maxTasks}；需要澄清的计划可暂时无任务。`);
  }
  if (Object.keys(plan).some(k => !['version', 'summary', 'questions', 'tasks'].includes(k))) throw new Error('计划包含未定义字段。');
  const ids = new Set();
  for (const task of plan.tasks) {
    if (!task || typeof task.id !== 'string' || !/^[a-zA-Z0-9_-]{1,64}$/.test(task.id) || ids.has(task.id) ||
        typeof task.title !== 'string' || !task.title.trim() || typeof task.description !== 'string' || !task.description.trim() ||
        !TASK_KINDS.includes(task.kind) || !strings(task.dependsOn) || !strings(task.acceptance, true)) {
      throw new Error('任务字段无效、ID 重复或缺少验收条件。');
    }
    ids.add(task.id);
    if (Object.keys(task).some(k => !['id', 'title', 'description', 'kind', 'dependsOn', 'acceptance'].includes(k))) throw new Error('任务包含未定义字段。');
  }
  for (const task of plan.tasks) {
    if (task.dependsOn.some(id => !ids.has(id) || id === task.id) || new Set(task.dependsOn).size !== task.dependsOn.length) {
      throw new Error(`任务 ${task.id} 的依赖无效。`);
    }
  }
  const sorted = [], done = new Set();
  while (sorted.length < plan.tasks.length) {
    const next = plan.tasks.find(t => !done.has(t.id) && t.dependsOn.every(id => done.has(id)));
    if (!next) throw new Error('计划包含循环依赖。');
    sorted.push(next); done.add(next.id);
  }
  return { ...plan, tasks: sorted };
}

function planPrompt({ task, repo, wiki, maxTasks, maxCodexExecutions }) {
  const wikiDigest = wiki?.pages?.length
    ? wiki.pages.map(page => `# ${page.title} (${page.status})\n${page.content.slice(0, 2000)}`).join('\n\n')
    : '(无相关 wiki 命中)';
  const repoTree = repo?.tree?.length ? repo.tree.join('\n') : '(目录不可用)';
  return `你是 yahamic 项目的编码规划器。yahamic 是一个 Mac mini 无线麦克风项目：firmware/ 为 ESP32-S3 固件（ESP-IDF，C++），apps/ 为各端应用：apps/macos/ 为 Swift 包（YahaDesk 菜单栏 App，SwiftUI；设备与 Mac 走 BLE GATT 直连），apps/ios/ 为 iOS App，apps/shared/ 为两端共用的 Swift 包（DeskProtocol、DeskShared）。只读规划，不修改文件。

用户任务：${task}

仓库结构（摘要）：
${repoTree}

相关知识（来自个人知识库，可能过时，注意 status）：
${wikiDigest}

输出一个 JSON 对象（可带 \`\`\`json 围栏）：{"version":1,"summary":"一句话计划","questions":[],"tasks":[{"id":"kebab-id","title":"标题","description":"具体做什么、改哪些文件","kind":"simple|complex|ui|hard","dependsOn":["前置任务id"],"acceptance":["可检查的验收条件"]}]}
最多 ${maxTasks} 个任务。kind 分工：simple=局部小改/文档/测试，complex=跨文件功能，ui=SwiftUI 界面，hard=疑难/高风险（音频链路、并发、驱动）。本次最多 ${maxCodexExecutions} 个 hard（Codex 执行）。固件任务注意 ESP-IDF 约束；Mac 端验证用 swift build。
缺少关键信息时 tasks 留空、把具体问题写进 questions，不要猜。acceptance 必须可检查。`;
}

export function createPlan(params) {
  const provider = ['glm', 'codex'].includes(params.provider) ? params.provider : 'glm';
  const llmImpl = params.llmImpl ?? askLLM;
  const codexImpl = params.codexImpl ?? runCodex;
  return {
    async execute({ read, run, config, signal, tick, emit }) {
      const maxTasks = config.limits.maxTasks;
      const maxCodex = config.limits.maxCodexExecutions;
      const task = run.task;
      const prompt = planPrompt({ task, repo: read('repo'), wiki: read('wiki'), maxTasks, maxCodexExecutions: maxCodex });
      let text;
      if (provider === 'codex') {
        const result = await codexImpl({ prompt, workspace: config.workspace, config: config.codex, mode: 'plan', signal });
        text = result.text;
      } else {
        await tick('llm-calls');
        const result = await llmImpl({ config: config.llm, system: '你是严谨的编码规划器，只输出符合协议的 JSON。', prompt, signal });
        text = result.text;
      }
      const plan = parseDecision(text, value => validatePlan(value, maxTasks));
      if (plan.questions.length > 0 && plan.tasks.length === 0) {
        emit({ type: 'plan_needs_input', node: 'plan' });
        return { outputs: { plan: { summary: plan.summary, tasks: [] } }, terminal: { status: 'needs_input', questions: plan.questions, reason: plan.summary } };
      }
      const hardCount = plan.tasks.filter(t => t.kind === 'hard').length;
      if (hardCount > maxCodex) {
        return { outputs: { plan: { summary: plan.summary, tasks: [] } }, terminal: { status: 'blocked', reason: `计划包含 ${hardCount} 个 hard 任务，超过 Codex 执行预算 ${maxCodex}。` } };
      }
      return { outputs: { plan: { summary: plan.summary, tasks: plan.tasks } } };
    },
  };
}
