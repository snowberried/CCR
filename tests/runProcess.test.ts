import assert from "node:assert/strict";
import test from "node:test";
import { ProcessRunError, runProcess } from "../electron/adapters/process/runProcess";

const baseRequest = {
  executablePath: process.execPath,
  timeoutMs: 2_000,
  maxOutputBytes: 1_024 * 1_024,
};

test("captures stdout from an argument-array process without a shell", async () => {
  const result = await runProcess({
    ...baseRequest,
    args: ["-e", "process.stdout.write('ok')"],
  });

  assert.equal(result.stdout, "ok");
  assert.ok(result.elapsedMs >= 0);
});

test("maps a non-zero exit code", async () => {
  await assert.rejects(
    runProcess({ ...baseRequest, args: ["-e", "process.exit(7)"] }),
    (error) =>
      error instanceof ProcessRunError &&
      error.code === "PROCESS_EXIT_FAILED" &&
      error.exitCode === 7,
  );
});

test("terminates a process after timeout", async () => {
  await assert.rejects(
    runProcess({
      ...baseRequest,
      args: ["-e", "setTimeout(() => {}, 1000)"],
      timeoutMs: 30,
    }),
    (error) => error instanceof ProcessRunError && error.code === "PROCESS_TIMEOUT",
  );
});

test("terminates a process when aborted", async () => {
  const controller = new AbortController();
  const promise = runProcess({
    ...baseRequest,
    args: ["-e", "setTimeout(() => {}, 1000)"],
    signal: controller.signal,
  });
  setTimeout(() => controller.abort(), 30);

  await assert.rejects(
    promise,
    (error) => error instanceof ProcessRunError && error.code === "PROCESS_CANCELLED",
  );
});

test("terminates a process when combined output exceeds the limit", async () => {
  await assert.rejects(
    runProcess({
      ...baseRequest,
      args: ["-e", "process.stdout.write('x'.repeat(2048))"],
      maxOutputBytes: 128,
    }),
    (error) => error instanceof ProcessRunError && error.code === "PROCESS_OUTPUT_LIMIT",
  );
});
