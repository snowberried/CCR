import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const androidRoot = resolve(toolDir, "..");
const repoRoot = resolve(androidRoot, "..");
const manifest = readFileSync(resolve(androidRoot, "app/src/main/AndroidManifest.xml"), "utf8");
const build = readFileSync(resolve(androidRoot, "app/build.gradle.kts"), "utf8");
const session = readFileSync(
  resolve(androidRoot, "app/src/main/java/com/snowberried/ctcinereviewer/media/ExactFrameSession.kt"),
  "utf8",
);
const provider = readFileSync(
  resolve(androidRoot, "app/src/debug/java/com/snowberried/ctcinereviewer/gate/ReadOnlyFixtureProvider.kt"),
  "utf8",
);
const signingExample = readFileSync(resolve(androidRoot, "signing.properties.example"), "utf8");
const gitignore = readFileSync(resolve(repoRoot, ".gitignore"), "utf8");

function requireContract(condition, message) {
  if (!condition) throw new Error(`Android source contract failed: ${message}`);
}

for (const permission of ["INTERNET", "READ_MEDIA_VIDEO", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE"]) {
  requireContract(!manifest.includes(permission), `forbidden manifest permission ${permission}`);
}
for (const dependency of ["firebase", "analytics", "okhttp", "retrofit", "ktor-client", "sentry"]) {
  requireContract(!build.toLowerCase().includes(dependency), `external transmission dependency ${dependency}`);
}
requireContract(session.includes('openFileDescriptor(uri, "r")'), "source URI is not opened explicitly read-only");
requireContract(!/openFileDescriptor\([^\n]+,\s*"(?:w|rw|rwt|wa)"/.test(session), "write-capable source open mode");
requireContract(provider.includes("ParcelFileDescriptor.MODE_READ_ONLY"), "fixture provider is not read-only");
requireContract(provider.includes('if (mode != "r")'), "fixture provider does not reject write modes");
requireContract(/versionCode\s*=\s*2\b/.test(build), "versionCode is not 2");
requireContract(/versionName\s*=\s*"0\.1\.1"/.test(build), "versionName is not 0.1.1");
requireContract(build.includes('applicationIdSuffix = ".internal"'), "internal application ID suffix is missing");
requireContract(build.includes('create("internalRelease")'), "internalRelease signing config is missing");
for (const name of [
  "CCR_ANDROID_INTERNAL_KEYSTORE_PATH",
  "CCR_ANDROID_INTERNAL_KEYSTORE_PASSWORD",
  "CCR_ANDROID_INTERNAL_KEY_ALIAS",
  "CCR_ANDROID_INTERNAL_KEY_PASSWORD",
]) {
  requireContract(build.includes(name), `internal signing environment boundary ${name}`);
}
requireContract(!build.includes("CCR_ANDROID_KEYSTORE_"), "legacy generic signing environment boundary remains");
requireContract(signingExample.includes("internalStoreFile="), "internal signing example is missing");
requireContract(gitignore.split(/\r?\n/).includes("*.jks"), "recursive JKS ignore is missing");
requireContract(gitignore.split(/\r?\n/).includes("*.keystore"), "recursive keystore ignore is missing");
requireContract(gitignore.split(/\r?\n/).includes("signing.properties"), "recursive signing properties ignore is missing");
console.log("verified Android 0.1.1 identity, read-only privacy, and internal signing source contract");
