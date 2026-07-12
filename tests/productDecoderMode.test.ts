import assert from "node:assert/strict";
import test from "node:test";
import { selectProductDecoderMode } from "../src/application/productDecoderMode";

test("uses I420 cache by default and keeps an explicit RGBA rollback", () => {
  assert.equal(selectProductDecoderMode(undefined), "i420-cache");
  assert.equal(selectProductDecoderMode("0"), "i420-cache");
  assert.equal(selectProductDecoderMode("1"), "rgba-rollback");
});
