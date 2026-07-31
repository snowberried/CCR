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
  return { files, runtimeInputsTreeSha256: hashTree(files) };
}

function hashTree(files) {
  const tree = createHash("sha256");
  tree.update("CCR_RUNTIME_INPUTS_V1\0");
  for (const file of files) {
    tree.update(`${file.path}\0${file.byteSize}\0${file.sha256}\n`);
  }
  return tree.digest("hex");
}

function assert(condition, message) {
  if (!condition) throw new Error(`runtime inputs verification failed: ${message}`);
}

if (process.argv.includes("--write")) {
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
  writeFileSync(manifestPath, `${JSON.stringify(generated, null, 2)}\n`, "utf8");
  console.log(`wrote ${manifestPath}`);
  console.log(generated.runtimeInputsTreeSha256);
  process.exit(0);
}

const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
assert(manifest.schemaVersion === 1, "schemaVersion");
assert(manifest.manifestKind === "ccr-android-runtime-inputs", "manifestKind");
assert(manifest.runtimeSourceSha === runtimeSourceSha, "runtimeSourceSha");
assert(JSON.stringify(manifest.includePaths) === JSON.stringify(includePaths), "includePaths");
assert(Array.isArray(manifest.files) && manifest.files.length > 0, "file inventory");
const sortedManifestFiles = [...manifest.files].sort((left, right) =>
  Buffer.compare(Buffer.from(left.path, "utf8"), Buffer.from(right.path, "utf8")),
);
assert(JSON.stringify(manifest.files) === JSON.stringify(sortedManifestFiles), "file inventory order");
assert(
  manifest.files.every(
    (file) =>
      typeof file.path === "string" &&
      Number.isSafeInteger(file.byteSize) &&
      file.byteSize >= 0 &&
      /^[a-f0-9]{64}$/.test(file.sha256),
  ),
  "file inventory shape",
);
assert(new Set(manifest.files.map((file) => file.path)).size === manifest.files.length, "duplicate path");
assert(manifest.runtimeInputsTreeSha256 === hashTree(manifest.files), "tree SHA");

const historical = snapshot(runtimeSourceSha);
assert(JSON.stringify(historical.files) === JSON.stringify(manifest.files), "historical runtime snapshot");

console.log(`verified ${manifest.files.length} frozen runtime inputs`);
console.log(`runtimeInputsTreeSha256=${manifest.runtimeInputsTreeSha256}`);
