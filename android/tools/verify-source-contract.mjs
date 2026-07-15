import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolDir = dirname(fileURLToPath(import.meta.url));
const androidRoot = resolve(toolDir, "..");
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
console.log("verified Android read-only and no-external-transmission source contract");
