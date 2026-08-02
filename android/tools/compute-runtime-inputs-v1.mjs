import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(toolDir, "..", "..");
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

function resolveCommit(revision) {
  const value = git(["rev-parse", `${revision}^{commit}`], "utf8").trim().toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(value)) throw new Error("runtime source commit is invalid");
  return value;
}

function listFiles(revision) {
  return git(["ls-tree", "-r", "--name-only", "-z", revision, "--", ...includePaths])
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

function assertCleanRuntimeInputs() {
  for (const args of [
    ["diff", "--quiet", "--", ...includePaths],
    ["diff", "--cached", "--quiet", "--", ...includePaths],
  ]) {
    const result = spawnSync("git", args, { cwd: repoRoot });
    if (result.status !== 0) throw new Error(`tracked runtime input differs: git ${args.join(" ")}`);
  }
  const untracked = git(["ls-files", "--others", "--exclude-standard", "-z", "--", ...includePaths])
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  if (untracked.length > 0) throw new Error(`untracked runtime input: ${untracked.join(", ")}`);
}

const runtimeSourceSha = resolveCommit(process.argv[2] ?? "HEAD");
const headSha = resolveCommit("HEAD");
if (runtimeSourceSha === headSha) assertCleanRuntimeInputs();
const runtime = snapshot(runtimeSourceSha);
if (runtime.files.length === 0) throw new Error("runtime input set is empty");

console.log(JSON.stringify({
  schemaVersion: 1,
  manifestKind: "ccr-android-runtime-inputs",
  runtimeSourceSha,
  treeAlgorithm: "sha256(CCR_RUNTIME_INPUTS_V1\\0 + sorted(path\\0byteSize\\0fileSha256\\n))",
  includePaths,
  fileCount: runtime.files.length,
  runtimeInputsTreeSha256: runtime.runtimeInputsTreeSha256,
}));
