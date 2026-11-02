// Sink node: capture a redacted run digest into yahallmwiki's capture queue.
// Knowledge failures never erase coding results (yahaagent semantics): errors
// are journaled and the node still succeeds with captured=false.


import { redact } from '../kernel/config.mjs';
import { connectWiki } from './wiki-client.mjs';

// 默认名单 + 配置里实际使用的 apiKeyEnv（改了变量名也照样脱敏）。
const SECRETS = (config) => {
  const names = new Set(['ZHIPU_API_KEY', 'ZAI_CODING_CN_API_KEY', 'KIMI_API_KEY', 'TYPESAFE_API_KEY']);
  for (const section of [config?.llm, config?.router?.jev, ...Object.values(config?.pi ?? {})]) {
    if (typeof section?.apiKeyEnv === 'string' && section.apiKeyEnv) names.add(section.apiKeyEnv);
  }
  return [...names].map(name => process.env[name]).filter(Boolean);
};

export function createSinkCapture(params) {
  const connect = params.connect ?? ((config, options) => connectWiki(config, options));
  return {
    async execute({ read, run, config, signal, emit }) {
      const plan = read('plan');
      const execution = read('execution');
      const verify = read('verify');
      const digest = {
        task: run.task,
        graph: run.graph,
        summary: plan?.summary ?? null,
        tasks: (plan?.tasks ?? []).map(task => ({ id: task.id, title: task.title, kind: task.kind })),
        executions: (execution?.results ?? []).map(result => ({ taskId: result.taskId, worker: result.worker, status: result.status, summary: result.summary })),
        verification: (verify?.checks ?? []).map(check => ({ label: check.label, passed: check.passed })),
      };
      const wikiConfig = config.wiki;
      if (!wikiConfig || wikiConfig.enabled === false || !wikiConfig.repository || wikiConfig.capture === false) {
        return { outputs: { capture: { captured: false, reason: 'disabled' } } };
      }
      if ((execution?.results ?? []).length === 0) {
        return { outputs: { capture: { captured: false, reason: 'nothing to capture' } } };
      }
      let client;
      try {
        client = await connect({
          repository: wikiConfig.repository,
          home: wikiConfig.home,
          stateHome: wikiConfig.stateHome,
          timeoutMs: wikiConfig.timeoutMs ?? 15000,
        }, { signal });
        const content = SECRETS(config).reduce((value, secret) => redact(value, secret), JSON.stringify(digest, null, 2));
        const result = await client.capture({
          title: `yahamic-agent ${run.id}：${(plan?.summary ?? run.task).slice(0, 60)}`,
          content,
        });
        return { outputs: { capture: { captured: true, eventId: result.eventId } } };
      } catch (error) {
        if (error?.code === 'PROCESS_CANCELLED' || signal?.aborted) throw error;
        emit({ type: 'capture_failed', code: error?.code ?? null });
        return { outputs: { capture: { captured: false, reason: error?.code ?? 'WIKI_ERROR' } } };
      } finally {
        await client?.close();
      }
    },
  };
}
