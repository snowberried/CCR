import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { resolveFfmpegRuntimePaths, resolveRuntimeResourceRoot } from "../electron/runtimePaths.js";

test("development resolves FFmpeg below the app path", () => {
  const context = {
    isPackaged: false,
    appPath: path.resolve("development-app"),
    resourcesPath: path.resolve("packaged-resources"),
  };

  assert.equal(resolveRuntimeResourceRoot(context), context.appPath);
  assert.equal(
    resolveFfmpegRuntimePaths(context).ffmpegPath,
    path.join(context.appPath, "tools", "ffmpeg", "bin", "ffmpeg.exe"),
  );
});

test("packaged app resolves FFmpeg below process.resourcesPath", () => {
  const context = {
    isPackaged: true,
    appPath: path.resolve("resources", "app.asar"),
    resourcesPath: path.resolve("installed-app", "resources"),
  };

  const result = resolveFfmpegRuntimePaths(context);
  assert.equal(resolveRuntimeResourceRoot(context), context.resourcesPath);
  assert.equal(result.ffprobePath, path.join(context.resourcesPath, "tools", "ffmpeg", "bin", "ffprobe.exe"));
});
