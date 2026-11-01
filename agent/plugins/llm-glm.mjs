// GLM decision-point transport: OpenAI-compatible chat completions against the
// Zhipu Coding Plan endpoint, following yahallmwiki's compatibility layer
// (max_tokens field, thinking.type=enabled; reasoning levels low/high/max).
// Cancellation mirrors jev.mjs: timeout races the request, abort wins always.

export class LlmError extends Error {
  constructor(message, code, status) {
    super(message);
    this.name = 'LlmError';
    this.code = code;
    if (status !== undefined) this.status = status;
  }
}

const THINKING_LEVELS = ['low', 'high', 'max'];

function cancelError() {
  return new LlmError('LLM request was cancelled.', 'PROCESS_CANCELLED');
}

/**
 * One non-streaming completion call. Returns { text, usage }; never retries.
 * config: { endpoint, model, apiKeyEnv, thinking?, maxOutputTokens?, timeoutMs? }
 */
export async function askLLM({ config, system, prompt, signal, fetchImpl = fetch }) {
  if (signal?.aborted) throw cancelError();
  if (typeof prompt !== 'string' || !prompt.trim()) throw new LlmError('LLM prompt must not be empty.', 'LLM_INVALID_INPUT');
  if (typeof fetchImpl !== 'function') throw new LlmError('fetchImpl must be a function.', 'LLM_INVALID_INPUT');
  const endpoint = `${String(config.endpoint).replace(/\/+$/, '')}/chat/completions`;
  const model = config.model ?? 'glm-5.3';
  const apiKeyEnv = config.apiKeyEnv ?? 'ZHIPU_API_KEY';
  const timeoutMs = Number.isSafeInteger(config.timeoutMs) && config.timeoutMs > 0 ? config.timeoutMs : 180_000;
  const thinking = THINKING_LEVELS.includes(config.thinking) ? config.thinking : 'high';
  const maxTokens = Number.isSafeInteger(config.maxOutputTokens) && config.maxOutputTokens > 0 ? config.maxOutputTokens : 8192;
  const apiKey = process.env[apiKeyEnv];
  if (!apiKey?.trim()) {
    throw new LlmError(`LLM API key is not configured in ${apiKeyEnv}.`, 'LLM_MISSING_KEY');
  }

  const body = JSON.stringify({
    model,
    messages: [
      ...(system ? [{ role: 'system', content: system }] : []),
      { role: 'user', content: prompt },
    ],
    max_tokens: maxTokens,
    thinking: { type: 'enabled', level: thinking },
    stream: false,
  });

  const controller = new AbortController();
  let timer;
  let rejectCancellation;
  const cancellation = new Promise((_, reject) => { rejectCancellation = reject; });
  function cancel() {
    const error = cancelError();
    error.signal = 'ABORT';
    rejectCancellation(error);
    controller.abort();
  }
  const onInterrupt = () => cancel();
  const onTerminate = () => cancel();
  const onAbort = () => cancel();
  process.on('SIGINT', onInterrupt);
  process.on('SIGTERM', onTerminate);
  signal?.addEventListener('abort', onAbort, { once: true });
  try {
    if (signal?.aborted) throw cancelError();
    return await Promise.race([
      cancellation,
      (async () => {
        const response = await fetchImpl(endpoint, {
          method: 'POST',
          headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
          body,
          signal: controller.signal,
          redirect: 'error',
        });
        if (!response.ok) {
          if (response.status === 401 || response.status === 403) {
            throw new LlmError('LLM authentication failed. Check the configured API key.', 'LLM_AUTH_ERROR', response.status);
          }
          throw new LlmError(`LLM request failed with HTTP ${response.status}.`, 'LLM_HTTP_ERROR', response.status);
        }
        let payload;
        try { payload = await response.json(); } catch {
          throw new LlmError('LLM returned invalid JSON.', 'LLM_INVALID_RESPONSE');
        }
        const choice = payload?.choices?.[0];
        const content = choice?.message?.content;
        if (typeof content !== 'string' || !content.trim()) {
          // Reasoning tokens can consume the whole budget, leaving content
          // empty with finish_reason=length — distinct from a malformed reply.
          if (choice?.finish_reason === 'length') {
            throw new LlmError('LLM 输出预算被推理消耗殆尽，没有正文返回；请调大 llm.maxOutputTokens 或降低 thinking 档位。', 'LLM_LENGTH_EXHAUSTED');
          }
          throw new LlmError('LLM returned no message content.', 'LLM_INVALID_RESPONSE');
        }
        const usage = payload?.usage && typeof payload.usage === 'object' ? {
          input: payload.usage.prompt_tokens ?? null,
          output: payload.usage.completion_tokens ?? null,
          reasoning: payload.usage.completion_tokens_details?.reasoning_tokens ?? null,
          totalTokens: payload.usage.total_tokens ?? null,
        } : null;
        return { text: content, usage };
      })(),
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          reject(new LlmError('LLM request timed out.', 'LLM_TIMEOUT'));
          controller.abort();
        }, timeoutMs);
      }),
    ]);
  } catch (error) {
    if (error instanceof LlmError) throw error;
    // Transport errors can echo headers or endpoints; never propagate them.
    throw new LlmError('LLM request failed due to a network error.', 'LLM_NETWORK_ERROR');
  } finally {
    clearTimeout(timer);
    process.removeListener('SIGINT', onInterrupt);
    process.removeListener('SIGTERM', onTerminate);
    signal?.removeEventListener('abort', onAbort);
  }
}
