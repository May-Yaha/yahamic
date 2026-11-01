// Plugin registry: the kernel knows nothing about models, CLIs or tasks.
// A plugin is { id, create(params, ctx) -> { execute(execCtx) } }; everything
// domain-specific lives in plugins/.

export class PluginError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'PluginError';
    this.code = code;
  }
}

export function createRegistry() {
  const factories = new Map();

  function register(id, factory) {
    if (typeof id !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(id)) {
      throw new PluginError(`Plugin id is invalid: ${id}`, 'PLUGIN_INVALID_ID');
    }
    if (typeof factory !== 'function') {
      throw new PluginError(`Plugin factory must be a function: ${id}`, 'PLUGIN_INVALID_FACTORY');
    }
    if (factories.has(id)) throw new PluginError(`Plugin already registered: ${id}`, 'PLUGIN_DUPLICATE');
    factories.set(id, factory);
  }

  return {
    register,
    has: (id) => factories.has(id),
    ids: () => [...factories.keys()],
    create(id, params, ctx) {
      const factory = factories.get(id);
      if (!factory) throw new PluginError(`Unknown plugin: ${id}`, 'PLUGIN_UNKNOWN');
      const instance = factory(params ?? {}, ctx ?? {});
      if (!instance || typeof instance.execute !== 'function') {
        throw new PluginError(`Plugin ${id} must return an object with execute().`, 'PLUGIN_INVALID_INSTANCE');
      }
      return instance;
    },
  };
}
