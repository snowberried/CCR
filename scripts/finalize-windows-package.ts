import { createHash } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";

type ManifestEntry = {
  relativePath: string;
  size: number;
  sha256: string;
};

const repoRoot = process.cwd();
const releaseDirectory = path.join(repoRoot, "artifacts");
const unpackedDirectory = path.join(releaseDirectory, "win-unpacked");
const packageData = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8")) as {
  version: string;
};
const setupName = `CT-Cine-Reviewer-Setup-${packageData.version}.exe`;
const setupPath = path.join(releaseDirectory, setupName);
const blockmapPath = path.join(releaseDirectory, `${setupName}.blockmap`);
const updateMetadataPath = path.join(releaseDirectory, "latest.yml");
const verifyOnly = process.argv.includes("--verify-only");

const forbiddenMediaExtensions = new Set([".mp4", ".mov", ".avi", ".mkv", ".rgba"]);
const forbiddenPathParts = ["local-samples", "local-cache", "sample_a", "sample_b", "sample_c"];
const textScanExtensions = new Set([".asar", ".css", ".html", ".js", ".json", ".map", ".md", ".txt", ".yaml", ".yml"]);
const forbiddenText = ["C:\\AI_Assistant", "C:\\Users\\snowb", "local-samples", "local-cache"];

async function sha256(filePath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function sha512(filePath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha512");
    const stream = createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("base64")));
  });
}

async function collectFiles(directory: string): Promise<string[]> {
  const result: string[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      result.push(...await collectFiles(fullPath));
    } else if (entry.isFile()) {
      result.push(fullPath);
    }
  }
  return result;
}

function assertRequiredFiles(files: string[]): void {
  const required = [
    "CT Cine Reviewer.exe",
    "resources/app.asar",
    "resources/app-update.yml",
    "resources/tools/ffmpeg/bin/ffmpeg.exe",
    "resources/tools/ffmpeg/bin/ffprobe.exe",
    "resources/tools/ffmpeg/licenses/LICENSE.txt",
    "resources/tools/ffmpeg/VERSION.md",
    "resources/tools/ffmpeg/BUILDINFO.md",
    "resources/tools/ffmpeg/SHA256SUMS.txt",
  ];
  const available = new Set(files.map((filePath) => path.relative(unpackedDirectory, filePath).replaceAll("\\", "/")));
  for (const requiredPath of required) {
    if (!available.has(requiredPath)) {
      throw new Error(`PACKAGE_REQUIRED_FILE_MISSING: ${requiredPath}`);
    }
  }
}

async function inspectPrivacy(files: string[]): Promise<void> {
  for (const filePath of files) {
    const relativePath = path.relative(unpackedDirectory, filePath).replaceAll("\\", "/");
    const lowerPath = relativePath.toLowerCase();
    if (forbiddenMediaExtensions.has(path.extname(lowerPath))) {
      throw new Error(`PACKAGE_FORBIDDEN_MEDIA: ${relativePath}`);
    }
    if (forbiddenPathParts.some((part) => lowerPath.includes(part))) {
      throw new Error(`PACKAGE_FORBIDDEN_PATH: ${relativePath}`);
    }
    if (!textScanExtensions.has(path.extname(lowerPath))) {
      continue;
    }
    const contents = await readFile(filePath);
    const utf8 = contents.toString("utf8");
    const utf16 = contents.toString("utf16le");
    for (const needle of forbiddenText) {
      if (utf8.includes(needle) || utf16.includes(needle)) {
        throw new Error(`PACKAGE_FORBIDDEN_CONTENT: ${relativePath}`);
      }
    }
  }
}

if (!existsSync(unpackedDirectory) || !existsSync(setupPath)) {
  throw new Error("PACKAGE_OUTPUT_MISSING: run npm run package:win first");
}
if (!existsSync(blockmapPath) || !existsSync(updateMetadataPath)) {
  throw new Error("PACKAGE_UPDATE_METADATA_MISSING: blockmap and latest.yml are required");
}

const files = await collectFiles(unpackedDirectory);
assertRequiredFiles(files);
await inspectPrivacy(files);

const manifest: ManifestEntry[] = [];
for (const filePath of files.sort((a, b) => a.localeCompare(b))) {
  const fileStat = await stat(filePath);
  manifest.push({
    relativePath: path.relative(unpackedDirectory, filePath).replaceAll("\\", "/"),
    size: fileStat.size,
    sha256: await sha256(filePath),
  });
}

const setupHash = await sha256(setupPath);
const setupSha512 = await sha512(setupPath);
const setupStat = await stat(setupPath);
const blockmapStat = await stat(blockmapPath);
if (blockmapStat.size === 0) throw new Error("PACKAGE_UPDATE_BLOCKMAP_EMPTY");
const updateMetadata = await readFile(updateMetadataPath, "utf8");
if (
  !updateMetadata.includes(`version: ${packageData.version}`)
  || !updateMetadata.includes(setupName)
  || !updateMetadata.includes(setupSha512)
  || !updateMetadata.includes(`size: ${setupStat.size}`)
) {
  throw new Error("PACKAGE_UPDATE_METADATA_MISMATCH");
}
if (!verifyOnly) {
  await writeFile(path.join(releaseDirectory, `${setupName}.sha256`), `${setupHash}  ${setupName}\n`, "utf8");
  const manifestText = [
    "# CT Cine Reviewer win-unpacked package manifest",
    `# Version: ${packageData.version}`,
    "# SHA-256 | bytes | relative path",
    ...manifest.map((entry) => `${entry.sha256} | ${entry.size} | ${entry.relativePath}`),
    "",
  ].join("\n");
  await writeFile(path.join(releaseDirectory, "package-manifest.txt"), manifestText, "utf8");
  const effectiveConfig = [
    `appId: com.snowberried.ctcinereviewer`,
    `productName: CT Cine Reviewer`,
    `executableName: CT Cine Reviewer`,
    `version: ${packageData.version}`,
    `artifactName: ${setupName}`,
    `architecture: x64`,
    `target: nsis`,
    `installationScope: currentUser`,
    `oneClick: false`,
    `allowElevation: false`,
    `allowToChangeInstallationDirectory: false`,
    `desktopShortcut: created`,
    `startMenuShortcut: created`,
    `codeSigning: none`,
    `autoUpdate: user-triggered electron-updater`,
    `runtimeDownloads: none`,
    `resourcesRoot: process.resourcesPath`,
    "",
  ].join("\n");
  await writeFile(path.join(releaseDirectory, "builder-effective-config.yaml"), effectiveConfig, "utf8");
  for (const generatedUpdateFile of ["builder-debug.yml"]) {
    await rm(path.join(releaseDirectory, generatedUpdateFile), { force: true });
  }
} else {
  const recordedChecksum = await readFile(path.join(releaseDirectory, `${setupName}.sha256`), "utf8");
  if (!recordedChecksum.startsWith(setupHash)) {
    throw new Error("PACKAGE_SETUP_CHECKSUM_MISMATCH");
  }
}

console.log(JSON.stringify({
  setupName,
  setupSha256: setupHash,
  updateMetadata: "verified",
  unpackedFileCount: manifest.length,
  privacyInspection: "passed",
  mode: verifyOnly ? "verify-only" : "finalized",
}, null, 2));
