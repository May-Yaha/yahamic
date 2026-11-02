import { spawn } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';

// Ported verbatim from yahaagent/src/process.mjs (MIT, same author).
// The PROCESS_* error-code contract below is the kernel-wide cancellation
// vocabulary: PROCESS_CANCELLED is never a retryable failure.

const OUTPUT_LIMIT_BYTES = 8 * 1024 * 1024;
const STREAM_TAIL_BYTES = 64 * 1024;
const KILL_GRACE_MS = 250;
const MAX_TIMEOUT_MS = 2_147_483_647;
const FAILURE_TAIL_BYTES = 4096;

// 子进程只拿到这份白名单环境：凭证一律不下发（verify / doctor 用）。
const ENV_ALLOWLIST = [
  'PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'USER', 'SHELL', 'TERM', 'DEVELOPER_DIR',
  'CODEX_HOME', // doctor 的 `codex login status` 要读到同一份登录目录（路径，不是凭证）
  'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
];

export function allowlistedEnv(source = process.env) {
  return Object.fromEntries(ENV_ALLOWLIST.filter(name => source[name] !== undefined).map(name => [name, source[name]]));
}

// Detached children own their process group and would outlive us; kill every
// live group synchronously when this process exits (exit handlers cannot wait).
const liveGroups = new Set();
let exitHookInstalled = false;
function trackGroup(pid) {
  if (!exitHookInstalled) {
    exitHookInstalled = true;
    process.on('exit', () => {
      for (const group of liveGroups) {
        try { process.kill(-group, 'SIGKILL'); } catch { /* already gone */ }
      }
    });
  }
  liveGroups.add(pid);
}

function tailText(buffer) {
  return buffer.subarray(-FAILURE_TAIL_BYTES).toString('utf8');
}

function appendTail(tail, chunk) {
  if (chunk.length >= STREAM_TAIL_BYTES) return Buffer.from(chunk.subarray(-STREAM_TAIL_BYTES));
  const combined = Buffer.concat([tail, chunk]);
  return combined.length <= STREAM_TAIL_BYTES ? combined : Buffer.from(combined.subarray(-STREAM_TAIL_BYTES));
}

function processError(message, code, details = {}) {
  return Object.assign(new Error(message), { code, ...details });
}

export function throwIfCancelled(signal) {
  if (signal?.aborted) throw processError('Operation was cancelled.', 'PROCESS_CANCELLED', { signal: 'ABORT' });
}

/** Stream mode keeps bounded tails; capture mode retains the existing total-output limit. */
export function runProcess({ command, args = [], cwd, input = '', env = process.env, timeoutMs = 600_000, onLine, onStderrLine, signal, outputMode = 'capture' }) {
  try { throwIfCancelled(signal); } catch (error) { return Promise.reject(error); }
  if (typeof command !== 'string' || !command || !Array.isArray(args) || args.some(arg => typeof arg !== 'string')) {
    return Promise.reject(processError('Invalid process command.', 'PROCESS_INVALID_ARGUMENT'));
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > MAX_TIMEOUT_MS) {
    return Promise.reject(processError('Process timeout must be a positive supported integer.', 'PROCESS_INVALID_ARGUMENT'));
  }
  if (!['capture', 'stream'].includes(outputMode)) return Promise.reject(processError('Invalid process output mode.', 'PROCESS_INVALID_ARGUMENT'));

  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const streaming = outputMode === 'stream';
    const grouped = process.platform !== 'win32';
    let child;
    try {
      child = spawn(command, args, { cwd, env, shell: false, detached: grouped, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (error) {
      reject(processError('Could not start process.', 'PROCESS_SPAWN_FAILED', { causeCode: error.code }));
      return;
    }
    if (grouped && child.pid) trackGroup(child.pid);

    const stdout = [];
    const stderr = [];
    let stdoutTail = Buffer.alloc(0);
    let stderrTail = Buffer.alloc(0);
    const lineState = callback => ({ callback, decoder: new StringDecoder('utf8'), pending: '', bytes: 0 });
    const stdoutLines = lineState(onLine);
    const stderrLines = lineState(onStderrLine);
    let outputBytes = 0;
    let failure;
    let closed = false;
    let settled = false;
    let killPending = false;
    let exitCode = null;
    let exitSignal = null;

    function finish() {
      if (!closed || killPending || settled) return;
      settled = true;
      clearTimeout(timeout);
      process.removeListener('SIGINT', onInterrupt);
      process.removeListener('SIGTERM', onTerminate);
      signal?.removeEventListener('abort', onAbort);
      if (failure) {
        reject(failure);
      } else if (exitCode !== 0) {
        reject(processError('Process exited unsuccessfully.', 'PROCESS_EXIT_FAILED', {
          exitCode, signal: exitSignal,
          stdout: tailText(streaming ? stdoutTail : Buffer.concat(stdout)),
          stderr: tailText(streaming ? stderrTail : Buffer.concat(stderr)),
        }));
      } else {
        resolve({ stdout: (streaming ? stdoutTail : Buffer.concat(stdout)).toString('utf8'), stderr: (streaming ? stderrTail : Buffer.concat(stderr)).toString('utf8'), exitCode });
      }
    }

    function onInterrupt() {
      stop(processError('Process was cancelled.', 'PROCESS_CANCELLED', { signal: 'SIGINT' }));
    }

    function onTerminate() {
      stop(processError('Process was cancelled.', 'PROCESS_CANCELLED', { signal: 'SIGTERM' }));
    }

    function onAbort() {
      stop(processError('Process was cancelled.', 'PROCESS_CANCELLED', { signal: 'ABORT' }));
    }

    function signalTree(signal) {
      if (!child.pid) return;
      try {
        if (grouped) process.kill(-child.pid, signal);
        else child.kill(signal);
      } catch {
        // ESRCH means the process group has already exited.
      }
    }

    function stop(error) {
      if (failure) return;
      failure = error;
      if (!child.pid) return;
      killPending = true;
      signalTree('SIGTERM');
      // Keep this timer even if the direct child closes: descendants may still be alive.
      setTimeout(() => {
        signalTree('SIGKILL');
        killPending = false;
        finish();
      }, KILL_GRACE_MS);
    }

    function emitLine(line, callback) {
      if (!callback || failure) return;
      try {
        callback(line.endsWith('\r') ? line.slice(0, -1) : line);
      } catch {
        stop(processError('Process output handler failed.', 'PROCESS_CALLBACK_FAILED'));
      }
    }

    function receive(chunk, target, isStdout) {
      if (failure) return;
      const lines = isStdout ? stdoutLines : stderrLines;
      if (streaming) {
        // Count raw bytes before decoding, including split UTF-8 characters. A
        // stream may be arbitrarily long, but one unterminated JSONL event may not.
        // Stderr keeps its original tail-only behavior unless a caller opts in.
        if (isStdout || onStderrLine) {
          let start = 0;
          let end;
          while ((end = chunk.indexOf(10, start)) !== -1) {
            if (lines.bytes + end - start > OUTPUT_LIMIT_BYTES) {
              stop(processError('Process output line exceeded the limit.', 'PROCESS_OUTPUT_LIMIT'));
              return;
            }
            lines.bytes = 0;
            start = end + 1;
          }
          lines.bytes += chunk.length - start;
          if (lines.bytes > OUTPUT_LIMIT_BYTES) {
            stop(processError('Process output line exceeded the limit.', 'PROCESS_OUTPUT_LIMIT'));
            return;
          }
        }
        if (isStdout) stdoutTail = appendTail(stdoutTail, chunk);
        else stderrTail = appendTail(stderrTail, chunk);
      } else {
        outputBytes += chunk.length;
        if (outputBytes > OUTPUT_LIMIT_BYTES) {
          stop(processError('Process output exceeded the limit.', 'PROCESS_OUTPUT_LIMIT'));
          return;
        }
        target.push(chunk);
      }
      if (lines.callback) {
        lines.pending += lines.decoder.write(chunk);
        let end;
        while (!failure && (end = lines.pending.indexOf('\n')) !== -1) {
          const line = lines.pending.slice(0, end);
          lines.pending = lines.pending.slice(end + 1);
          emitLine(line, lines.callback);
        }
      }
    }

    const timeout = setTimeout(() => stop(processError('Process timed out.', 'PROCESS_TIMEOUT', { timeoutMs, durationMs: Date.now() - startedAt })), timeoutMs);
    process.on('SIGINT', onInterrupt);
    process.on('SIGTERM', onTerminate);
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) onAbort();
    child.stdout.on('data', chunk => receive(chunk, stdout, true));
    child.stderr.on('data', chunk => receive(chunk, stderr, false));
    child.on('error', error => stop(processError('Could not start process.', 'PROCESS_SPAWN_FAILED', { causeCode: error.code })));
    child.stdin.on('error', error => {
      if (error.code !== 'EPIPE') stop(processError('Could not send process input.', 'PROCESS_INPUT_FAILED'));
    });
    child.on('close', (code, signal) => {
      closed = true;
      liveGroups.delete(child.pid);
      exitCode = code;
      exitSignal = signal;
      for (const lines of [stdoutLines, stderrLines]) {
        if (!failure && lines.callback) {
          lines.pending += lines.decoder.end();
          if (lines.pending) emitLine(lines.pending, lines.callback);
        }
      }
      finish();
    });
    try {
      child.stdin.end(input);
    } catch {
      stop(processError('Could not send process input.', 'PROCESS_INPUT_FAILED'));
    }
  });
}
