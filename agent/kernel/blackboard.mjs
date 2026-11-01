// Blackboard: the shared state every node reads from and writes to (pattern 4).
// Nodes never pass arguments to each other point-to-point; the blackboard is
// the only data plane. Guards (backedge budgets) are counters on this board.

const JOURNAL_LIMIT = 500;
const NS_PATTERN = /^[a-z][a-z0-9-]{0,63}$/;

export class BlackboardError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'BlackboardError';
    this.code = code;
  }
}

function clone(value) {
  return value === undefined ? undefined : structuredClone(value);
}

export function createBlackboard({ run, counters = {}, journalLimit = JOURNAL_LIMIT, onPersist } = {}) {
  if (!run || typeof run.id !== 'string' || !run.id.trim() || typeof run.graph !== 'string' || !run.graph.trim()) {
    throw new BlackboardError('Blackboard requires run identity.', 'BLACKBOARD_INVALID_RUN');
  }
  if (typeof journalLimit !== 'number' || !Number.isSafeInteger(journalLimit) || journalLimit < 1) {
    throw new BlackboardError('Blackboard journal limit must be a positive integer.', 'BLACKBOARD_INVALID_JOURNAL_LIMIT');
  }
  const state = {
    run: { status: 'running', startedAt: new Date().toISOString(), ...clone(run) },
    facts: {},
    counters: {},
    journal: [],
  };
  const declared = new Map();
  for (const [name, spec] of Object.entries(counters)) {
    if (!NS_PATTERN.test(name)) throw new BlackboardError(`Counter name is invalid: ${name}`, 'BLACKBOARD_INVALID_COUNTER');
    if (!spec || !Number.isSafeInteger(spec.max) || spec.max < 1) {
      throw new BlackboardError(`Counter ${name} needs a positive integer max.`, 'BLACKBOARD_INVALID_COUNTER');
    }
    declared.set(name, spec.max);
    state.counters[name] = 0;
  }
  const subscribers = new Set();

  function journal(event) {
    state.journal.push({ ts: new Date().toISOString(), ...event });
    if (state.journal.length > journalLimit) state.journal.splice(0, state.journal.length - journalLimit);
  }

  function persist() {
    state.run.updatedAt = new Date().toISOString();
    for (const subscriber of subscribers) {
      try { subscriber(snapshot()); } catch { /* Observers must not break the run. */ }
    }
    // Snapshot writes are synchronous (tmp+rename): an interrupt at any point
    // must leave the last completed node visible on disk.
    if (onPersist) {
      try { onPersist(snapshot()); } catch { /* A failed checkpoint must not kill the run. */ }
    }
  }

  function snapshot() {
    return clone(state);
  }

  return {
    snapshot,
    restore(saved) {
      if (!saved || saved.run?.id !== state.run.id) {
        throw new BlackboardError('Snapshot does not match this run.', 'BLACKBOARD_RESTORE_MISMATCH');
      }
      state.run = clone(saved.run);
      state.facts = clone(saved.facts) ?? {};
      state.counters = clone(saved.counters) ?? {};
      state.journal = clone(saved.journal) ?? [];
    },
    subscribe(subscriber) {
      subscribers.add(subscriber);
      return () => subscribers.delete(subscriber);
    },
    read(ns) {
      if (ns !== undefined && typeof ns !== 'string') throw new BlackboardError('Namespace must be a string.', 'BLACKBOARD_INVALID_INPUT');
      return ns === undefined ? clone(state.facts) : clone(state.facts[ns]);
    },
    write(ns, value, { node } = {}) {
      if (!NS_PATTERN.test(String(ns))) throw new BlackboardError(`Namespace is invalid: ${ns}`, 'BLACKBOARD_INVALID_NS');
      state.facts[ns] = clone(value);
      journal({ node: node ?? null, event: 'write', ns });
      persist();
    },
    setStatus(status) {
      if (!['running', 'completed', 'needs_input', 'blocked', 'interrupted'].includes(status)) {
        throw new BlackboardError('Unknown run status.', 'BLACKBOARD_INVALID_STATUS');
      }
      state.run.status = status;
      persist();
    },
    counter(name) {
      return state.counters[name] ?? null;
    },
    /** Guard evaluation for backedges: passes while the counter stays below max. */
    guardPasses(name, max) {
      if (!declared.has(name) || !Number.isSafeInteger(max) || max < 1) {
        throw new BlackboardError(`Guard references an undeclared counter: ${name}`, 'BLACKBOARD_UNKNOWN_COUNTER');
      }
      return state.counters[name] < max;
    },
    /** Plugin-side budget tick: fails closed once the declared max is reached. */
    async tick(name, { node } = {}) {
      if (!declared.has(name)) {
        throw new BlackboardError(`Tick references an undeclared counter: ${name}`, 'BLACKBOARD_UNKNOWN_COUNTER');
      }
      state.counters[name] += 1;
      journal({ node: node ?? null, event: 'tick', counter: name, value: state.counters[name] });
      persist();
      if (state.counters[name] > declared.get(name)) {
        throw new BlackboardError(`Counter ${name} exceeded its budget of ${declared.get(name)}.`, 'BLACKBOARD_COUNTER_EXCEEDED');
      }
    },
    /** Kernel-side increment when a guarded backedge is taken; returns false at budget. */
    consume(name, { node } = {}) {
      if (!declared.has(name)) {
        throw new BlackboardError(`Consume references an undeclared counter: ${name}`, 'BLACKBOARD_UNKNOWN_COUNTER');
      }
      if (state.counters[name] >= declared.get(name)) return false;
      state.counters[name] += 1;
      journal({ node: node ?? null, event: 'consume', counter: name, value: state.counters[name] });
      persist();
      return true;
    },
  };
}
