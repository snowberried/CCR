import assert from "node:assert/strict";
import test from "node:test";
import { compareAppVersions } from "../src/domain/appVersion";

test("compares semantic release versions", () => {
  assert.equal(compareAppVersions("0.5.2", "v0.5.0"), 1);
  assert.equal(compareAppVersions("0.5.0", "v0.5.2"), -1);
  assert.equal(compareAppVersions("v0.5", "0.5.0"), 0);
});
