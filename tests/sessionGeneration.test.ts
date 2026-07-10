import assert from "node:assert/strict";
import test from "node:test";
import { SessionGenerationGuard } from "../src/application/SessionGenerationGuard";

test("rejects file A after file B becomes current", () => {
  const guard = new SessionGenerationGuard();
  const fileA = guard.begin();
  const fileB = guard.begin();
  assert.equal(guard.isCurrent(fileA), false);
  assert.equal(guard.isCurrent(fileB), true);
  guard.invalidate();
  assert.equal(guard.isCurrent(fileB), false);
});
