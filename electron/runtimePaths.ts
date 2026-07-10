import path from "node:path";

export type RuntimePathContext = {
  isPackaged: boolean;
  appPath: string;
  resourcesPath: string;
};

export function resolveRuntimeResourceRoot(context: RuntimePathContext): string {
  return context.isPackaged ? context.resourcesPath : context.appPath;
}

export function resolveFfmpegRuntimePaths(context: RuntimePathContext) {
  const binDirectory = path.join(resolveRuntimeResourceRoot(context), "tools", "ffmpeg", "bin");
  return {
    binDirectory,
    ffmpegPath: path.join(binDirectory, "ffmpeg.exe"),
    ffprobePath: path.join(binDirectory, "ffprobe.exe"),
  };
}
