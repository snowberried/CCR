import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";

export type ProcessRunErrorCode =
  | "PROCESS_START_FAILED"
  | "PROCESS_EXIT_FAILED"
  | "PROCESS_TIMEOUT"
  | "PROCESS_CANCELLED"
  | "PROCESS_OUTPUT_LIMIT";

export class ProcessRunError extends Error {
  constructor(
    public readonly code: ProcessRunErrorCode,
    public readonly exitCode: number | null = null,
  ) {
    super(code);
    this.name = "ProcessRunError";
  }
}

export type ProcessRunRequest = {
  executablePath: string;
  args: readonly string[];
  timeoutMs: number;
  maxOutputBytes: number;
  signal?: AbortSignal;
};

export type ProcessRunResult = {
  stdout: string;
  elapsedMs: number;
};

export type ProcessRunner = (request: ProcessRunRequest) => Promise<ProcessRunResult>;

export const runProcess: ProcessRunner = (request) =>
  new Promise((resolve, reject) => {
    if (request.signal?.aborted) {
      reject(new ProcessRunError("PROCESS_CANCELLED"));
      return;
    }

    const startedAt = performance.now();
    const stdoutChunks: Buffer[] = [];
    let outputBytes = 0;
    let forcedError: ProcessRunError | null = null;
    let settled = false;

    const child = spawn(request.executablePath, [...request.args], {
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const cleanup = () => {
      clearTimeout(timeout);
      request.signal?.removeEventListener("abort", onAbort);
    };

    const rejectOnce = (error: ProcessRunError) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(error);
    };

    const stop = (error: ProcessRunError) => {
      if (forcedError || settled) {
        return;
      }
      forcedError = error;
      child.kill();
    };

    const onData = (chunk: Buffer, keep: boolean) => {
      outputBytes += chunk.byteLength;
      if (outputBytes > request.maxOutputBytes) {
        stop(new ProcessRunError("PROCESS_OUTPUT_LIMIT"));
        return;
      }
      if (keep) {
        stdoutChunks.push(chunk);
      }
    };

    const onAbort = () => stop(new ProcessRunError("PROCESS_CANCELLED"));
    request.signal?.addEventListener("abort", onAbort, { once: true });

    const timeout = setTimeout(
      () => stop(new ProcessRunError("PROCESS_TIMEOUT")),
      request.timeoutMs,
    );

    child.stdout.on("data", (chunk: Buffer) => onData(chunk, true));
    child.stderr.on("data", (chunk: Buffer) => onData(chunk, false));

    child.once("error", () => {
      rejectOnce(forcedError ?? new ProcessRunError("PROCESS_START_FAILED"));
    });

    child.once("close", (exitCode) => {
      if (settled) {
        return;
      }
      if (forcedError) {
        rejectOnce(forcedError);
        return;
      }
      if (exitCode !== 0) {
        rejectOnce(new ProcessRunError("PROCESS_EXIT_FAILED", exitCode));
        return;
      }

      settled = true;
      cleanup();
      resolve({
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        elapsedMs: performance.now() - startedAt,
      });
    });
  });
