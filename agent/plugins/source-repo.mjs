// Source plugin: read the yahamic workspace into the blackboard (repo ns).
// Read-only: directory tree, README digest and key manifests. Never executes
// build tools; verification belongs to the verifier plugin.

import fs from 'node:fs';
import path from 'node:path';

const SKIP_DIRS = new Set(['.git', 'node_modules', '.build', 'build', 'managed_components', 'dependencies.lock', '.runs', 'dist', '.pi', '.yahaagent', '.claude']);

function tree(root, maxEntries) {
  const lines = [];
  const walk = (dir, prefix, depth) => {
    if (lines.length >= maxEntries || depth > 3) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => (b.isDirectory() - a.isDirectory()) || a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (lines.length >= maxEntries) { lines.push(`${prefix}…`); return; }
      if (SKIP_DIRS.has(entry.name) || entry.name.startsWith('.tmp')) continue;
      lines.push(`${prefix}${entry.name}${entry.isDirectory() ? '/' : ''}`);
      if (entry.isDirectory()) walk(path.join(dir, entry.name), `${prefix}  `, depth + 1);
    }
  };
  walk(root, '', 0);
  return lines;
}

function head(file, maxLines) {
  try {
    return fs.readFileSync(file, 'utf8').split(/\r?\n/).slice(0, maxLines).join('\n');
  } catch {
    return null;
  }
}

export function createSourceRepo(params) {
  const maxTreeEntries = Number.isSafeInteger(params.maxTreeEntries) && params.maxTreeEntries > 0 ? params.maxTreeEntries : 120;
  const maxReadmeLines = Number.isSafeInteger(params.maxReadmeLines) && params.maxReadmeLines > 0 ? params.maxReadmeLines : 120;
  return {
    async execute({ node, run, config }) {
      const workspace = config.workspace;
      const manifestCandidates = ['mac/Package.swift', 'firmware/CMakeLists.txt', 'package.json'];
      return {
        outputs: {
          repo: {
            workspace,
            task: run.task,
            tree: tree(workspace, maxTreeEntries),
            readme: head(path.join(workspace, 'README.md'), maxReadmeLines),
            manifests: Object.fromEntries(manifestCandidates
              .map(rel => [rel, head(path.join(workspace, rel), 40)])
              .filter(([, content]) => content !== null)),
            scannedBy: node.id,
          },
        },
      };
    },
  };
}
