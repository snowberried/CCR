import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(toolDir, "..", "..");
const manifestPath = resolve(repoRoot, "android/validation/runtime-inputs-v2.json");
const runtimeSourceSha = "189e6e1edb8419f0c2be449e6ab9fd9b54bf5b1e";
const includePaths = [
  "android/app/src/main",
  "android/app/src/debug",
  "android/app/build.gradle.kts",
  "android/build.gradle.kts",
  "android/settings.gradle.kts",
  "android/gradle.properties",
  "android/gradle/wrapper/gradle-wrapper.properties",
];

function git(args, encoding = null) {
  const result = spawnSync("git", args, {
    cwd: repoRoot,
    encoding,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const detail = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : result.stderr;
    throw new Error(`git ${args.join(" ")} failed: ${detail?.trim() ?? "unknown error"}`);
  }
  return result.stdout;
}

function listFiles(revision) {
  const raw = git(["ls-tree", "-r", "--name-only", "-z", revision, "--", ...includePaths]);
  return raw
    .toString("utf8")
    .split("\0")
    .filter(Boolean)
    .sort((left, right) => Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")));
}

function snapshot(revision) {
  const files = listFiles(revision).map((path) => {
    const bytes = git(["show", `${revision}:${path}`]);
    return {
      path,
      byteSize: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
  });
  const tree = createHash("sha256");
  tree.update("CCR_RUNTIME_INPUTS_V1\0");
  for (const file of files) {
    tree.update(`${file.path}\0${file.byteSize}\0${file.sha256}\n`);
  }
  return { files, runtimeInputsTreeSha256: tree.digest("hex") };
}

function assert(condition, message) {
  if (!condition) throw new Error(`runtime inputs verification failed: ${message}`);
}

function assertNoRuntimeWorkingTreeChanges() {
  for (const args of [
    ["diff", "--quiet", "--", ...includePaths],
    ["diff", "--cached", "--quiet", "--", ...includePaths],
  ]) {
    const result = spawnSync("git", args, { cwd: repoRoot });
    assert(result.status === 0, `tracked runtime input differs in worktree: git ${args.join(" ")}`);
  }
  const untracked = git(["ls-files", "--others", "--exclude-standard", "-z", "--", ...includePaths])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  assert(untracked.length === 0, `untracked runtime input: ${untracked.join(", ")}`);
}

const runtime = snapshot(runtimeSourceSha);
const generated = {
  schemaVersion: 1,
  manifestKind: "ccr-android-runtime-inputs",
  runtimeSourceSha,
  treeAlgorithm: "sha256(CCR_RUNTIME_INPUTS_V1\\0 + sorted(path\\0byteSize\\0fileSha256\\n))",
  includePaths,
  runtimeInputsTreeSha256: runtime.runtimeInputsTreeSha256,
  files: runtime.files,
};

if (process.argv.includes("--write")) {
  writeFileSync(manifestPath, `${JSON.stringify(generated, null, 2)}\n`, "utf8");
  console.log(`wrote ${manifestPath}`);
  console.log(generated.runtimeInputsTreeSha256);
  process.exit(0);
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
assert(manifest.schemaVersion === 1, "schemaVersion");
assert(manifest.manifestKind === generated.manifestKind, "manifestKind");
assert(manifest.runtimeSourceSha === runtimeSourceSha, "runtimeSourceSha");
assert(JSON.stringify(manifest.includePaths) === JSON.stringify(includePaths), "includePaths");
assert(manifest.runtimeInputsTreeSha256 === generated.runtimeInputsTreeSha256, "tree SHA");
assert(JSON.stringify(manifest.files) === JSON.stringify(generated.files), "file inventory");

const head = snapshot("HEAD");
assert(JSON.stringify(head.files) === JSON.stringify(runtime.files), "HEAD changes frozen runtime inputs");
assertNoRuntimeWorkingTreeChanges();

console.log(`verified ${runtime.files.length} frozen runtime inputs`);
console.log(`runtimeInputsTreeSha256=${runtime.runtimeInputsTreeSha256}`);
