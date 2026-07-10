import { rm } from "node:fs/promises";
import path from "node:path";

const repoRoot = path.resolve(process.cwd());

for (const directoryName of ["dist", "dist-electron"]) {
  const target = path.resolve(repoRoot, directoryName);
  if (path.dirname(target) !== repoRoot) {
    throw new Error(`UNSAFE_BUILD_OUTPUT: ${directoryName}`);
  }
  await rm(target, { recursive: true, force: true });
}
