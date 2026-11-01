// yahallmwiki MCP client, ported from yahaagent/src/adapters/wiki.mjs (MIT,
// same author). Connects only to the repository's standard MCP server and
// never launches its worker; see that project for the protocol rationale.

import path from 'node:path';
import fs from 'node:fs/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const REQUIRED_TOOLS = ['yahallmwiki_search', 'yahallmwiki_read', 'yahallmwiki_capture'];
const MESSAGES = {
  WIKI_INVALID_CONFIG: 'Wiki connection configuration is invalid.',
  WIKI_UNAVAILABLE: 'Wiki repository, built MCP server, or content/state directories are unavailable.',
  WIKI_INVALID_PATH: 'Wiki page must be an existing Markdown file inside the knowledge directory.',
  WIKI_INVALID_INPUT: 'Wiki request input is invalid.',
  WIKI_INVALID_RESPONSE: 'Wiki MCP returned an invalid response.',
  WIKI_TOOL_ERROR: 'Wiki MCP could not complete the requested operation.',
  WIKI_CONNECTION_ERROR: 'Wiki MCP connection failed.',
  WIKI_TIMEOUT: 'Wiki MCP operation timed out.',
  WIKI_CLOSED: 'Wiki MCP connection is closed.',
  PROCESS_CANCELLED: 'Wiki MCP operation was cancelled.',
};

export class WikiError extends Error {
  constructor(code) {
    super(MESSAGES[code]);
    this.name = 'WikiError';
    this.code = code;
  }
}

function serverEnvironment(config) {
  const env = {};
  for (const key of ['PATH', 'HOME', 'TMPDIR', 'TEMP', 'TMP', 'LANG', 'LC_ALL']) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  return {
    ...env,
    YAHALLMWIKI_HOME: config.home,
    YAHALLMWIKI_STATE_HOME: config.stateHome,
    YAHALLMWIKI_DISABLE_DOTENV: '1',
    YAHALLMWIKI_AUTO_COMMIT: '0',
  };
}

async function validateConfiguration(config) {
  if (!config || !['repository', 'home', 'stateHome'].every((key) => typeof config[key] === 'string' && path.isAbsolute(config[key]))
    || !Number.isSafeInteger(config.timeoutMs) || config.timeoutMs < 1 || config.timeoutMs > 2_147_483_647) {
    throw new WikiError('WIKI_INVALID_CONFIG');
  }
  const server = path.join(config.repository, 'dist', 'mcp.js');
  const root = path.join(config.home, 'knowledge');
  try {
    const entries = await Promise.all([config.repository, config.home, config.stateHome, root, server].map((file) => fs.stat(file)));
    if (!entries.slice(0, 4).every((entry) => entry.isDirectory()) || !entries[4].isFile()) throw new Error();
    return { server, root: await fs.realpath(root) };
  } catch {
    throw new WikiError('WIKI_UNAVAILABLE');
  }
}

async function pagePath(file, root, home) {
  if (typeof file !== 'string' || !file || /[\\\x00-\x1f\x7f]/.test(file)
    || path.isAbsolute(file) || path.win32.isAbsolute(file) || file.split('/').includes('..')
    || path.extname(file) !== '.md') throw new WikiError('WIKI_INVALID_PATH');
  const normalized = path.posix.normalize(file);
  try {
    const target = await fs.realpath(path.join(home, 'knowledge', normalized));
    if (!target.startsWith(root + path.sep) || !(await fs.stat(target)).isFile()) throw new Error();
    return normalized;
  } catch {
    throw new WikiError('WIKI_INVALID_PATH');
  }
}

function responseText(result) {
  if (result?.isError === true) throw new WikiError('WIKI_TOOL_ERROR');
  if (!Array.isArray(result?.content) || result.content.length !== 1
    || result.content[0]?.type !== 'text' || typeof result.content[0].text !== 'string') {
    throw new WikiError('WIKI_INVALID_RESPONSE');
  }
  return result.content[0].text;
}

/** Connect only to the repository's standard MCP server; never launch its worker. */
export async function connectWiki(config, { signal } = {}) {
  if (signal?.aborted) throw new WikiError('PROCESS_CANCELLED');
  const { server, root } = await validateConfiguration(config);
  if (signal?.aborted) throw new WikiError('PROCESS_CANCELLED');
  const client = new Client({ name: 'yahamic-agent', version: '0.1.0' });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [server],
    cwd: config.repository,
    env: serverEnvironment(config),
    stderr: 'ignore',
    maxBufferSize: 2 * 1024 * 1024,
  });
  let closed = false;
  let closing;
  const closeTransport = transport.close.bind(transport);
  transport.close = () => {
    closed = true;
    closing ??= closeTransport();
    return closing;
  };
  const close = async () => {
    closed = true;
    try { await client.close(); } catch { /* Never expose transport diagnostics. */ }
    try { await transport.close(); } catch { /* Cleanup remains idempotent. */ }
  };

  async function operation(action) {
    if (signal?.aborted) { await close(); throw new WikiError('PROCESS_CANCELLED'); }
    if (closed) throw new WikiError('WIKI_CLOSED');
    const controller = new AbortController();
    let timer;
    let rejectInterruption;
    const interrupted = new Promise((_, reject) => { rejectInterruption = reject; });
    const cancel = (signal) => {
      const error = new WikiError('PROCESS_CANCELLED');
      error.signal = signal;
      rejectInterruption(error);
      controller.abort();
    };
    const onInterrupt = () => cancel('SIGINT');
    const onTerminate = () => cancel('SIGTERM');
    const onAbort = () => cancel('ABORT');
    process.on('SIGINT', onInterrupt);
    process.on('SIGTERM', onTerminate);
    signal?.addEventListener('abort', onAbort, { once: true });
    try {
      if (signal?.aborted) throw new WikiError('PROCESS_CANCELLED');
      timer = setTimeout(() => {
        rejectInterruption(new WikiError('WIKI_TIMEOUT'));
        controller.abort();
      }, config.timeoutMs);
      return await Promise.race([
        interrupted,
        action({ signal: controller.signal, timeout: config.timeoutMs, maxTotalTimeout: config.timeoutMs }),
      ]);
    } catch (error) {
      await close();
      if (error instanceof WikiError) throw error;
      throw new WikiError('WIKI_CONNECTION_ERROR');
    } finally {
      clearTimeout(timer);
      process.removeListener('SIGINT', onInterrupt);
      process.removeListener('SIGTERM', onTerminate);
      signal?.removeEventListener('abort', onAbort);
    }
  }

  await operation((options) => client.connect(transport, options));
  const tools = await operation(async (options) => {
    const listing = await client.listTools({}, options);
    const names = listing.tools.map((tool) => tool.name);
    if (!REQUIRED_TOOLS.every((name) => names.includes(name)) || listing.nextCursor) {
      throw new WikiError('WIKI_INVALID_RESPONSE');
    }
    return names;
  });
  const call = async (name, args, options) => responseText(await client.callTool({ name, arguments: args }, undefined, options));

  return {
    tools,
    close,
    async search(query) {
      if (typeof query !== 'string' || !query.trim()) throw new WikiError('WIKI_INVALID_INPUT');
      return operation(async (options) => {
        const text = await call('yahallmwiki_search', { query }, options);
        if (text === 'No matching knowledge pages.') return [];
        if (!text.trim()) throw new WikiError('WIKI_INVALID_RESPONSE');
        const results = [];
        for (const line of text.split('\n')) {
          const fields = line.split(' | ');
          if (fields.length < 4 || !fields[1] || !fields[2]) throw new WikiError('WIKI_INVALID_RESPONSE');
          let file;
          try { file = await pagePath(fields[0], root, config.home); }
          catch (error) {
            if (error.code === 'WIKI_INVALID_PATH') continue;
            throw error;
          }
          results.push({ file, title: fields[1], status: fields[2], snippet: fields.slice(3).join(' | ') });
        }
        return results;
      });
    },
    async read(file) {
      if (signal?.aborted) { await close(); throw new WikiError('PROCESS_CANCELLED'); }
      const normalized = await pagePath(file, root, config.home);
      return operation((options) => call('yahallmwiki_read', { file: normalized }, options));
    },
    async capture({ title, content } = {}) {
      if (typeof title !== 'string' || !title.trim() || typeof content !== 'string' || !content.trim()) {
        throw new WikiError('WIKI_INVALID_INPUT');
      }
      return operation(async (options) => {
        const text = await call('yahallmwiki_capture', { title, content, source: 'cli' }, options);
        let result;
        try { result = JSON.parse(text); } catch { throw new WikiError('WIKI_INVALID_RESPONSE'); }
        if (!result || typeof result.eventId !== 'string' || !result.eventId.trim() || result.queued !== true
          || Object.keys(result).some((key) => !['eventId', 'queued'].includes(key))) {
          throw new WikiError('WIKI_INVALID_RESPONSE');
        }
        return { eventId: result.eventId, queued: true };
      });
    },
  };
}
