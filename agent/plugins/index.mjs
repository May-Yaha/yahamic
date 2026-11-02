// Plugin registration: real plugins by default, fixture overrides for demo
// and tests (createOverrideRegistry layers fixtures on top of the same ids,
// so the graph definition never changes between demo and production).

import { createRegistry } from '../kernel/plugins.mjs';
import { createSourceRepo } from './source-repo.mjs';
import { createSourceWiki } from './source-wiki.mjs';
import { createPlan } from './plan.mjs';
import { createRouter } from './router.mjs';
import { createCoder } from './coder.mjs';
import { createVerifier } from './verifier.mjs';
import { createSinkCapture } from './sink-capture.mjs';
import { createSinkReport } from './sink-report.mjs';
import { fixturePlugins } from './fixtures.mjs';

export function createOverrideRegistry(base, overrides = {}) {
  return {
    register: base.register,
    has: (id) => base.has(id) || Object.hasOwn(overrides, id),
    ids: () => [...new Set([...base.ids(), ...Object.keys(overrides)])],
    create(id, params, ctx) {
      if (Object.hasOwn(overrides, id)) {
        const override = overrides[id];
        // Accept either a factory (params) => instance or a ready instance —
        // tests usually want to inject preconfigured fixtures directly.
        const instance = typeof override === 'function' ? override(params, ctx) : override;
        if (!instance || typeof instance.execute !== 'function') {
          throw Object.assign(new Error(`Override plugin ${id} must provide { execute() }.`), { code: 'PLUGIN_INVALID_INSTANCE' });
        }
        return instance;
      }
      return base.create(id, params, ctx);
    },
  };
}

export function createAgentRegistry() {
  const registry = createRegistry();
  registry.register('source-repo', createSourceRepo);
  registry.register('source-wiki', createSourceWiki);
  registry.register('plan', createPlan);
  registry.register('router', createRouter);
  registry.register('coder', createCoder);
  registry.register('verifier', createVerifier);
  registry.register('sink-capture', createSinkCapture);
  registry.register('sink-report', createSinkReport);
  return registry;
}

export function createDemoRegistry(overrides = {}) {
  return createOverrideRegistry(createAgentRegistry(), { ...fixturePlugins(), ...overrides });
}
