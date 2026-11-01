import test from 'node:test';
import assert from 'node:assert/strict';
import { askLLM, LlmError } from '../plugins/llm-glm.mjs';

function okFetch(payload) {
  return async (url, options) => {
    captured.request = { url, options };
    return { ok: true, status: 200, json: async () => payload };
  };
}
let captured = {};

const config = {
  endpoint: 'https://open.bigmodel.cn/api/coding/paas/v4',
  model: 'glm-5.3',
  apiKeyEnv: 'ZHIPU_API_KEY',
  thinking: 'high',
  maxOutputTokens: 1024,
  timeoutMs: 5000,
};

test('askLLM posts the coding-plan compatibility shape and maps usage', async () => {
  process.env.ZHIPU_API_KEY = 'test-key';
  captured = {};
  const result = await askLLM({
    config,
    system: 'sys',
    prompt: 'p',
    fetchImpl: okFetch({ choices: [{ message: { content: '```json\n{"ok":1}\n```' } }], usage: { prompt_tokens: 3, completion_tokens: 5, total_tokens: 8, completion_tokens_details: { reasoning_tokens: 4 } } }),
  });
  const body = JSON.parse(captured.request.options.body);
  assert.equal(captured.request.url, 'https://open.bigmodel.cn/api/coding/paas/v4/chat/completions');
  assert.equal(body.model, 'glm-5.3');
  assert.equal(body.max_tokens, 1024);
  assert.deepEqual(body.thinking, { type: 'enabled', level: 'high' });
  assert.equal(body.messages.length, 2);
  assert.equal(captured.request.options.headers.Authorization, 'Bearer test-key');
  assert.deepEqual(result.usage, { input: 3, output: 5, reasoning: 4, totalTokens: 8 });
  assert.match(result.text, /"ok":1/);
});

test('askLLM classifies auth failures and hides transport detail', async () => {
  process.env.ZHIPU_API_KEY = 'test-key';
  await assert.rejects(
    () => askLLM({ config, prompt: 'p', fetchImpl: async () => ({ ok: false, status: 401, json: async () => ({}) }) }),
    error => error instanceof LlmError && error.code === 'LLM_AUTH_ERROR',
  );
  await assert.rejects(
    () => askLLM({ config, prompt: 'p', fetchImpl: async () => { throw new Error('ECONNRESET leak'); } }),
    error => error.code === 'LLM_NETWORK_ERROR' && !/ECONNRESET/.test(error.message),
  );
  delete process.env.ZHIPU_API_KEY;
  await assert.rejects(
    () => askLLM({ config, prompt: 'p', fetchImpl: okFetch({}) }),
    error => error.code === 'LLM_MISSING_KEY',
  );
  process.env.ZHIPU_API_KEY = 'test-key';
});

test('askLLM rejects invalid responses and honours cancellation', async () => {
  process.env.ZHIPU_API_KEY = 'test-key';
  await assert.rejects(
    () => askLLM({ config, prompt: 'p', fetchImpl: okFetch({ choices: [] }) }),
    error => error.code === 'LLM_INVALID_RESPONSE',
  );
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    () => askLLM({ config, prompt: 'p', signal: controller.signal, fetchImpl: okFetch({}) }),
    error => error.code === 'PROCESS_CANCELLED',
  );
});
