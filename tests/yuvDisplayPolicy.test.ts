import assert from "node:assert/strict";
import test from "node:test";
import { selectYuvDisplayPolicy } from "../src/domain/yuvDisplayPolicy";

const base = {
  codecName: "h264",
  pixelFormat: "yuv420p",
  colorRange: null,
  colorSpace: null,
  colorPrimaries: null,
  colorTransfer: null,
};

test("allows only the approved metadata-free H264 yuv420p profile", () => {
  assert.equal(selectYuvDisplayPolicy(base).mode, "candidate-bt601-limited");
  assert.equal(selectYuvDisplayPolicy({ ...base, codecName: "hevc" }).mode, "rgba-fallback");
  assert.equal(selectYuvDisplayPolicy({ ...base, pixelFormat: "yuv444p" }).mode, "rgba-fallback");
});

test("allows explicit BT.601 limited and falls back for unsafe color policies", () => {
  const explicit601 = {
    ...base,
    colorRange: "tv",
    colorSpace: "smpte170m",
    colorPrimaries: "smpte170m",
    colorTransfer: "smpte170m",
  };
  assert.equal(selectYuvDisplayPolicy(explicit601).mode, "bt601-limited");
  assert.equal(selectYuvDisplayPolicy({ ...explicit601, colorRange: "pc" }).mode, "rgba-fallback");
  assert.equal(selectYuvDisplayPolicy({ ...explicit601, colorSpace: "bt709" }).mode, "rgba-fallback");
  assert.equal(selectYuvDisplayPolicy({ ...explicit601, colorPrimaries: "bt709" }).mode, "rgba-fallback");
});
