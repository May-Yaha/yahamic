// Decision protocol: probabilistic nodes (plan/route) and executor terminal
// states must pass strict parsing before the kernel accepts them. Ported from
// yahaagent/src/result.mjs; the single-JSON-fence rule is the core discipline:
// we never search prose for a success marker.

import { createHash } from 'node:crypto';

export const EXECUTION_RESULT_PROTOCOL = `执行终态协议：最后一条响应必须只有一个 JSON 对象，不要代码围栏、前言或追加文本。
合法格式示例：{"status":"completed","summary":"已完成的改动、实际验证和未完成事项","questions":[]}。
status 只能选择 completed、needs_input、blocked 中的一个值。只有任务已完成才用 completed，且 questions 必须为 []。
缺少用户决策用 needs_input，questions 列出具体问题并立即停止；无法继续用 blocked。
summary 必须是非空字符串，如实说明改动、验证和未完成事项；questions 必须是字符串数组。只允许 status、summary、questions 三个字段。`;

export function isExecutionResult(value) {
  return Boolean(value && typeof value === 'object' && !Array.isArray(value) &&
    ['completed', 'needs_input', 'blocked'].includes(value.status) &&
    typeof value.summary === 'string' && value.summary.trim() &&
    Array.isArray(value.questions) && value.questions.every(q => typeof q === 'string' && q.trim()) &&
    Object.keys(value).every(k => ['status', 'summary', 'questions'].includes(k)) &&
    (value.status !== 'needs_input' || value.questions.length > 0) &&
    (value.status !== 'completed' || value.questions.length === 0));
}

const JSON_FENCE = /^```(?:json)?\s*\n([\s\S]*?)\n```$/;

/** Accept a single JSON code fence, never search prose. Ported from yahaagent. */
export function parseJsonPayload(text) {
  return JSON.parse(String(text).trim().replace(JSON_FENCE, '$1'));
}

function decisionFailure(text, stage) {
  return Object.assign(
    new Error(stage === 'json_parse' ? '决策点未返回结构化 JSON，已保留现场。' : '决策内容不符合协议，已保留现场。'),
    {
      code: stage === 'json_parse' ? 'DECISION_NOT_JSON' : 'DECISION_INVALID',
      diagnostics: {
        stage,
        textLength: text.length,
        textSha256: createHash('sha256').update(text).digest('hex'),
      },
    },
  );
}

/** Parse a decision node's model output: strict fence-or-object JSON, then validator. */
export function parseDecision(text, validate) {
  let value;
  try {
    value = parseJsonPayload(text);
  } catch {
    throw decisionFailure(String(text), 'json_parse');
  }
  try {
    return validate(value);
  } catch (error) {
    const failure = decisionFailure(String(text), 'schema_validation');
    failure.diagnostics.reason = error instanceof Error ? error.message : String(error);
    throw failure;
  }
}

export function parseExecutionResult({ text, usage = null }) {
  const value = parseDecision(text, (candidate) => {
    if (!isExecutionResult(candidate)) throw new Error('invalid');
    return candidate;
  });
  return { status: value.status, text: value.summary, questions: value.questions, usage };
}
