// Source plugin: recall yahallmwiki knowledge over MCP (wiki ns). Client-side
// conventions ported from yahaagent's wiki adapter: connect only to the
// repository's dist/mcp.js, disable its dotenv/auto-commit, never run workers.


import { connectWiki } from './wiki-client.mjs';

function phrases(task, maxQueries) {
  // The wiki search is case-insensitive substring matching; long sentences match
  // nothing, so split the task into short phrases instead of guessing tokens.
  const parts = String(task)
    .split(/[，。；、,.;:\s()（）\[\]【】"'`?!]+/)
    .map(part => part.trim())
    .filter(part => part.length >= 2 && part.length <= 24);
  return [...new Set(parts)].slice(0, maxQueries);
}

export function createSourceWiki(params, ctx) {
  const connect = params.connect ?? ((config, options) => connectWiki(config, options));
  return {
    async execute({ run, config, signal, emit }) {
      const wikiConfig = config.wiki;
      if (!wikiConfig || wikiConfig.enabled === false || !wikiConfig.repository) {
        return { outputs: { wiki: { queries: [], hits: [], reason: 'disabled' } } };
      }
      const maxQueries = Number.isSafeInteger(wikiConfig.maxQueries) && wikiConfig.maxQueries > 0 ? wikiConfig.maxQueries : 4;
      const maxPages = Number.isSafeInteger(wikiConfig.maxPages) && wikiConfig.maxPages >= 0 ? wikiConfig.maxPages : 3;
      const maxContextChars = Number.isSafeInteger(wikiConfig.maxContextChars) && wikiConfig.maxContextChars > 0 ? wikiConfig.maxContextChars : 8000;
      const queries = (Array.isArray(wikiConfig.queries) && wikiConfig.queries.length
        ? wikiConfig.queries.slice(0, maxQueries)
        : phrases(run.task, maxQueries));
      // loadConfig resolves repository/home/stateHome to absolute paths.
      const client = await connect({
        repository: wikiConfig.repository,
        home: wikiConfig.home,
        stateHome: wikiConfig.stateHome,
        timeoutMs: wikiConfig.timeoutMs ?? 15000,
      }, { signal });
      try {
        const hits = [];
        const seen = new Set();
        for (const query of queries) {
          for (const hit of await client.search(query)) {
            if (seen.has(hit.file)) continue;
            seen.add(hit.file);
            hits.push({ query, ...hit });
          }
        }
        let budget = maxContextChars;
        const pages = [];
        for (const hit of hits) {
          if (pages.length >= maxPages || budget <= 0) break;
          try {
            const content = await client.read(hit.file);
            const clipped = content.length > budget ? content.slice(0, budget) : content;
            budget -= clipped.length;
            pages.push({ file: hit.file, title: hit.title, status: hit.status, content: clipped });
          } catch (error) {
            emit({ type: 'wiki_read_skipped', file: hit.file, code: error?.code ?? null });
          }
        }
        return { outputs: { wiki: { queries, hits: hits.slice(0, 12), pages } } };
      } finally {
        await client.close();
      }
    },
  };
}
