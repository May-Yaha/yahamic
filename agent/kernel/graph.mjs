// Graph engine: static topology is the constitution (pattern 2), probabilistic
// decisions only fill declared slots (pattern 1 dissolved into decision nodes),
// and every data flow crosses the blackboard (pattern 4).
//
// Load-time guardrails that reconcile "graph vs probabilistic planning":
//   * cycles are legal ONLY as explicit backedges with a counter guard — the
//     graph rejects any hidden loop before a single node runs;
//   * a decision node must declare its outputs; plugins cannot invent edges;
//   * removing all backedges must leave a DAG (checked with Kahn's algorithm).

export class GraphError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'GraphError';
    this.code = code;
  }
}

const NODE_ID = /^[a-zA-Z0-9_-]{1,64}$/;
const NS = /^[a-z][a-z0-9-]{0,63}$/;
const NODE_TYPES = ['source', 'decision', 'action', 'sink'];

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function positiveInt(value, field) {
  if (!Number.isSafeInteger(value) || value < 1) throw new GraphError(`${field} must be a positive integer.`, 'GRAPH_INVALID_FIELD');
  return value;
}

/** A predicate is { ns, path, equals } or { all: [...] } / { any: [...] } of predicates. */
function validWhen(w, producers) {
  if (!isPlainObject(w)) return false;
  for (const key of ['all', 'any']) {
    if (key in w) return Array.isArray(w[key]) && w[key].length > 0 && w[key].every(item => validWhen(item, producers));
  }
  return NS.test(String(w.ns)) && producers.has(w.ns)
    && Array.isArray(w.path) && w.path.length > 0 && w.path.every(p => typeof p === 'string')
    && 'equals' in w;
}

/** Validate and freeze a graph definition against the plugin registry. */
export function loadGraph(definition, registry) {
  if (!isPlainObject(definition)) throw new GraphError('Graph definition must be an object.', 'GRAPH_INVALID_SHAPE');
  if (typeof definition.id !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(definition.id)) {
    throw new GraphError('Graph id is invalid.', 'GRAPH_INVALID_ID');
  }
  if (!Array.isArray(definition.nodes) || definition.nodes.length === 0) {
    throw new GraphError('Graph needs at least one node.', 'GRAPH_EMPTY');
  }
  if (!Array.isArray(definition.edges)) throw new GraphError('Graph edges must be an array.', 'GRAPH_INVALID_EDGES');

  const counters = {};
  for (const [name, spec] of Object.entries(definition.counters ?? {})) {
    if (!NS.test(name) || !isPlainObject(spec)) throw new GraphError(`Counter ${name} is invalid.`, 'GRAPH_INVALID_COUNTER');
    counters[name] = { max: positiveInt(spec.max, `Counter ${name}.max`) };
  }

  const nodes = new Map();
  const producers = new Map(); // ns -> declaring node id
  for (const node of definition.nodes) {
    if (!isPlainObject(node) || typeof node.id !== 'string' || !NODE_ID.test(node.id)) {
      throw new GraphError('Node id is invalid.', 'GRAPH_INVALID_NODE');
    }
    if (nodes.has(node.id)) throw new GraphError(`Duplicate node id: ${node.id}`, 'GRAPH_DUPLICATE_NODE');
    if (!NODE_TYPES.includes(node.type)) throw new GraphError(`Node ${node.id} has an unknown type.`, 'GRAPH_INVALID_NODE_TYPE');
    if (typeof node.plugin !== 'string' || !registry.has(node.plugin)) {
      throw new GraphError(`Node ${node.id} references an unregistered plugin: ${node.plugin}`, 'GRAPH_UNKNOWN_PLUGIN');
    }
    const inputs = node.inputs ?? [];
    const reads = node.reads ?? [];
    const outputs = node.outputs ?? [];
    for (const list of [inputs, reads, outputs]) {
      if (!Array.isArray(list) || list.some(ns => typeof ns !== 'string' || !NS.test(ns))) {
        throw new GraphError(`Node ${node.id} has invalid namespace lists.`, 'GRAPH_INVALID_NS');
      }
    }
    if (node.type === 'source' && (inputs.length || reads.length)) {
      throw new GraphError(`Source node ${node.id} cannot declare inputs or reads.`, 'GRAPH_SOURCE_INPUTS');
    }
    if (new Set([...inputs, ...reads, ...outputs]).size !== inputs.length + reads.length + outputs.length) {
      throw new GraphError(`Node ${node.id} repeats a namespace.`, 'GRAPH_INVALID_NS');
    }
    if (outputs.length === 0 && node.type !== 'sink') {
      throw new GraphError(`Node ${node.id} must declare at least one output namespace.`, 'GRAPH_NO_OUTPUT');
    }
    for (const ns of outputs) {
      if (producers.has(ns)) throw new GraphError(`Namespace ${ns} is written by both ${producers.get(ns)} and ${node.id}.`, 'GRAPH_NS_CONFLICT');
      producers.set(ns, node.id);
    }
    if (node.timeoutMs !== undefined) {
      // Timeouts are plugin contracts (LLM/CLI/process all carry their own);
      // a graph-level number the kernel does not enforce would be a false promise.
      throw new GraphError(`Node ${node.id} declares timeoutMs, which the kernel does not enforce; configure the plugin instead.`, 'GRAPH_UNSUPPORTED_FIELD');
    }
    if (node.retries !== undefined) {
      if (!Number.isSafeInteger(node.retries) || node.retries < 0 || node.retries > 3) {
        throw new GraphError(`Node ${node.id}.retries must be 0-3.`, 'GRAPH_INVALID_FIELD');
      }
    }
    if (node.onError !== undefined && !['fallback', 'abort'].includes(node.onError)) {
      throw new GraphError(`Node ${node.id}.onError must be fallback or abort.`, 'GRAPH_INVALID_FIELD');
    }
    nodes.set(node.id, {
      id: node.id, type: node.type, plugin: node.plugin,
      params: node.params ?? {}, inputs, reads, outputs,
      timeoutMs: node.timeoutMs, retries: node.retries ?? 0,
      onError: node.onError ?? (node.type === 'sink' ? 'fallback' : 'abort'),
    });
  }
  for (const node of nodes.values()) {
    for (const ns of [...node.inputs, ...node.reads]) {
      if (!producers.has(ns)) {
        throw new GraphError(`Node ${node.id} references namespace ${ns} that no node declares as output.`, 'GRAPH_DANGLING_NS');
      }
    }
  }

  const edges = [];
  const seenEdges = new Set();
  const forwardIn = new Map([...nodes.keys()].map(id => [id, []]));
  const forwardOut = new Map([...nodes.keys()].map(id => [id, []]));
  const backedgeOut = new Map([...nodes.keys()].map(id => [id, []]));
  for (const edge of definition.edges) {
    if (!isPlainObject(edge) || typeof edge.from !== 'string' || typeof edge.to !== 'string'
      || !nodes.has(edge.from) || !nodes.has(edge.to)) {
      throw new GraphError('Edge references unknown nodes.', 'GRAPH_INVALID_EDGE');
    }
    const key = `${edge.from}->${edge.to}`;
    if (seenEdges.has(key)) throw new GraphError(`Duplicate edge: ${key}`, 'GRAPH_DUPLICATE_EDGE');
    seenEdges.add(key);
    if (edge.from === edge.to) throw new GraphError(`Self edge is not allowed: ${key}`, 'GRAPH_SELF_EDGE');
    if (edge.backedge) {
      if (!isPlainObject(edge.guard) || !NS.test(String(edge.guard.counter)) || !Object.hasOwn(counters, edge.guard.counter)) {
        throw new GraphError(`Backedge ${key} needs a guard referencing a declared counter.`, 'GRAPH_UNGUARDED_BACKEDGE');
      }
      positiveInt(edge.guard.max, `Backedge ${key} guard.max`);
      let when = null;
      if (edge.guard.when !== undefined) {
        if (!validWhen(edge.guard.when, producers)) {
          throw new GraphError(`Backedge ${key} has an invalid when predicate.`, 'GRAPH_INVALID_GUARD_WHEN');
        }
        when = edge.guard.when;
      }
      backedgeOut.get(edge.from).push({ to: edge.to, guard: edge.guard, when });
    } else {
      forwardOut.get(edge.from).push(edge.to);
      forwardIn.get(edge.to).push(edge.from);
    }
  }

  // Kahn over forward edges only: backedges are the sole legal cycle carriers.
  const pendingDeps = new Map([...forwardIn].map(([id, list]) => [id, list.length]));
  const queue = [...nodes.keys()].filter(id => pendingDeps.get(id) === 0);
  const order = [];
  while (queue.length) {
    const id = queue.shift();
    order.push(id);
    for (const next of forwardOut.get(id)) {
      pendingDeps.set(next, pendingDeps.get(next) - 1);
      if (pendingDeps.get(next) === 0) queue.push(next);
    }
  }
  if (order.length !== nodes.size) {
    throw new GraphError('Graph contains a cycle without an explicit guarded backedge.', 'GRAPH_HIDDEN_CYCLE');
  }

  // Optional declarative outcome: how the run settles once every node is done.
  let outcome = null;
  if (definition.outcome !== undefined) {
    const o = definition.outcome;
    if (!isPlainObject(o) || !validWhen(o.when, producers)
      || !['completed', 'blocked', 'needs_input'].includes(o.then)
      || !['completed', 'blocked', 'needs_input'].includes(o.otherwise)) {
      throw new GraphError('Graph outcome declaration is invalid.', 'GRAPH_INVALID_OUTCOME');
    }
    outcome = {
      when: o.when,
      then: o.then,
      otherwise: o.otherwise,
      otherwiseReason: typeof o.otherwiseReason === 'string' ? o.otherwiseReason : null,
    };
  }

  return Object.freeze({
    id: definition.id,
    counters,
    nodes,
    order,
    forwardIn,
    forwardOut,
    backedgeOut,
    limits: definition.limits ?? {},
    outcome,
  });
}

const IDLE = 'idle';
const RUNNING = 'running';
const DONE = 'done';
const FALLBACK = 'fallback';

function isCancelError(error) {
  return error?.code === 'PROCESS_CANCELLED';
}

function whenHolds(blackboard, when) {
  if (Array.isArray(when.all)) return when.all.every(item => whenHolds(blackboard, item));
  if (Array.isArray(when.any)) return when.any.some(item => whenHolds(blackboard, item));
  let value = blackboard.read(when.ns);
  for (const key of when.path) {
    if (value === null || typeof value !== 'object') return false;
    value = value[key];
  }
  return JSON.stringify(value) === JSON.stringify(when.equals);
}

/**
 * Execute a validated graph. The scheduler owns control flow: plugins only
 * return outputs (written to declared namespaces) or a terminal decision.
 */
export async function runGraph({ graph, registry, blackboard, ctx = {}, concurrency = 1, signal, emit = () => {} }) {
  if (concurrency < 1 || !Number.isSafeInteger(concurrency)) {
    throw new GraphError('Concurrency must be a positive integer.', 'GRAPH_INVALID_CONCURRENCY');
  }
  const states = new Map([...graph.nodes.keys()].map(id => [id, IDLE]));
  const attempts = new Map([...graph.nodes.keys()].map(id => [id, 0]));
  const pendingRequeue = [];
  let terminal = null;
  let failure = null;

  const execCtx = (node) => ({
    node: { id: node.id, type: node.type },
    run: blackboard.snapshot().run,
    read: (ns) => blackboard.read(ns),
    tick: (name) => blackboard.tick(name, { node: node.id }),
    counter: (name) => blackboard.counter(name),
    signal,
    emit,
    ...ctx,
  });

  function forwardReady(id) {
    return graph.forwardIn.get(id).every(dep => states.get(dep) === DONE || states.get(dep) === FALLBACK);
  }

  function downstream(id, visited = new Set()) {
    for (const next of graph.forwardOut.get(id)) {
      if (!visited.has(next)) { visited.add(next); downstream(next, visited); }
    }
    return visited;
  }

  function applyRequeue(sourceId) {
    const reset = new Set([sourceId, ...downstream(sourceId)]);
    for (const id of reset) {
      const state = states.get(id);
      if (state === RUNNING) continue; // concurrency > 1: retry when it settles.
      states.set(id, IDLE);
      attempts.set(id, 0);
    }
    return [...reset].some(id => states.get(id) === IDLE);
  }

  function settleFromGraph() {
    const anyFailed = [...states.values()].includes('failed');
    if (anyFailed || failure) return { status: 'blocked', reason: failure?.message ?? 'A node failed without a fallback.' };
    if (graph.outcome) {
      if (whenHolds(blackboard, graph.outcome.when)) return { status: graph.outcome.then };
      return { status: graph.outcome.otherwise, reason: graph.outcome.otherwiseReason ?? null };
    }
    return { status: 'completed' };
  }

  async function runNode(node) {
    states.set(node.id, RUNNING);
    emit({ type: 'node_started', node: node.id, plugin: node.plugin, attempt: attempts.get(node.id) + 1 });
    try {
      // A throwing factory is a node failure like any other: retries/fallback apply.
      const instance = registry.create(node.plugin, node.params, { ...ctx, node: { id: node.id, type: node.type } });
      const result = await instance.execute(execCtx(node));
      if (result?.terminal) {
        if (!['needs_input', 'blocked'].includes(result.terminal.status)) {
          throw new GraphError(`Node ${node.id} returned an invalid terminal status.`, 'GRAPH_INVALID_TERMINAL');
        }
        terminal = {
          status: result.terminal.status,
          questions: Array.isArray(result.terminal.questions) ? result.terminal.questions : [],
          reason: typeof result.terminal.reason === 'string' ? result.terminal.reason : null,
          node: node.id,
        };
      }
      for (const [ns, value] of Object.entries(result?.outputs ?? {})) {
        if (!node.outputs.includes(ns)) {
          throw new GraphError(`Node ${node.id} wrote undeclared namespace ${ns}.`, 'GRAPH_UNDECLARED_OUTPUT');
        }
        blackboard.write(ns, value, { node: node.id });
      }
      states.set(node.id, DONE);
      emit({ type: 'node_finished', node: node.id });
    } catch (error) {
      if (isCancelError(error) || signal?.aborted) throw error;
      attempts.set(node.id, attempts.get(node.id) + 1);
      const canRetry = attempts.get(node.id) <= node.retries;
      emit({ type: canRetry ? 'node_retry' : 'node_failed', node: node.id, code: error?.code ?? null, attempt: attempts.get(node.id) });
      if (canRetry) {
        states.set(node.id, IDLE);
        return;
      }
      if (node.onError === 'fallback') {
        states.set(node.id, FALLBACK);
        emit({ type: 'node_fallback', node: node.id, code: error?.code ?? null });
        return;
      }
      states.set(node.id, 'failed');
      failure = error;
    }
  }

  try {
    while (true) {
      if (signal?.aborted) throw Object.assign(new Error('Run was cancelled.'), { code: 'PROCESS_CANCELLED' });
      if (terminal) break;

      // Deferred requeues (only relevant when concurrency > 1).
      while (pendingRequeue.length && ![...states.values()].includes(RUNNING)) {
        if (applyRequeue(pendingRequeue.shift())) emit({ type: 'node_requeued', node: null });
      }

      const ready = [...graph.nodes.keys()].filter(id => states.get(id) === IDLE && forwardReady(id));
      const running = [...states.values()].filter(s => s === RUNNING).length;

      if (ready.length === 0 && running === 0 && pendingRequeue.length === 0) break;

      const batch = ready.slice(0, Math.max(0, concurrency - running));
      if (batch.length === 0) {
        // Only deferred requeues remain; loop to drain them.
        if (pendingRequeue.length) continue;
        await new Promise(resolve => setImmediate(resolve));
        continue;
      }

      // allSettled: on cancel, wait for every sibling to stop before reporting
      // interrupted, so no node keeps writing to the blackboard afterwards.
      const settled = await Promise.allSettled(batch.map(id => runNode(graph.nodes.get(id))));
      const rejected = settled.find(result => result.status === 'rejected');
      if (rejected) throw rejected.reason;

      // Evaluate guarded backedges from freshly finished nodes. A backedge
      // fires only when its declared condition (when) holds AND the counter
      // budget remains: the budget caps the loop, the condition opens it.
      for (const id of batch) {
        if (states.get(id) !== DONE) continue;
        for (const { to, guard, when } of graph.backedgeOut.get(id)) {
          if (when && !whenHolds(blackboard, when)) continue;
          if (!blackboard.guardPasses(guard.counter, guard.max)) continue;
          if (!blackboard.consume(guard.counter, { node: id })) continue;
          emit({ type: 'backedge_taken', from: id, to, counter: guard.counter, value: blackboard.counter(guard.counter) });
          if ([...states.values()].includes(RUNNING)) pendingRequeue.push(to);
          else if (applyRequeue(to)) emit({ type: 'node_requeued', node: to });
        }
      }
    }
  } catch (error) {
    if (isCancelError(error) || signal?.aborted) {
      return { status: 'interrupted', reason: 'Run was cancelled; blackboard state is preserved.' };
    }
    throw error;
  }

  if (terminal) return { status: terminal.status, questions: terminal.questions, reason: terminal.reason, node: terminal.node };
  return settleFromGraph();
}
