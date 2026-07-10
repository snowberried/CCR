/// <reference types="vite/client" />

type CcrFrameDescriptor = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  width: number;
  height: number;
  pixelFormat: "rgba";
  byteLength: number;
  fingerprint: string;
};

type CcrCacheStatus = {
  startFrameIndex: number | null;
  endFrameIndex: number | null;
  frameCount: number;
  byteLength: number;
  hits: number;
  misses: number;
  direction: "forward" | "reverse" | "balanced";
  budgetBytes: number;
  bytesPerFrame: number;
  frameCapacity: number;
  reusedFrames: number;
  decodedFrames: number;
};

type CcrFrameDiagnostics = {
  session: string;
  generation: number;
  requestId: number;
};

type CcrFrameResponse = {
  accepted: boolean;
  descriptor?: CcrFrameDescriptor;
  pixels?: Uint8Array;
  cache?: "hit" | "miss";
  requestMs?: number;
  cacheStatus?: CcrCacheStatus | null;
  diagnostics?: CcrFrameDiagnostics;
  error?: string;
};

type CcrOpenVideoResponse = {
  canceled: boolean;
  sessionId?: string;
  generation?: number;
  metadata?: {
    frameCount: number;
    width: number;
    height: number;
    codecName: string | null;
    fps: number | null;
    durationSeconds: number | null;
    rotationDegrees: number | null;
    probeMs: number;
    cachePolicy: {
      bytesPerFrame: number;
      budgetBytes: number;
      minimumTargetFrames: number;
      maximumFrames: number;
      frameCapacity: number;
      belowMinimumTarget: boolean;
    };
  };
  frame?: CcrFrameResponse;
  error?: string;
};

interface Window {
  ccr?: {
    getRuntimeStatus: () => Promise<{
      phase: string;
      ffmpegConfigured: boolean;
    }>;
    openVideo: () => Promise<CcrOpenVideoResponse>;
    openDroppedVideo: (file: File) => Promise<CcrOpenVideoResponse>;
    getFrame: (sessionId: string, frameIndex: number) => Promise<CcrFrameResponse>;
    cancelFrame: () => Promise<void>;
    closeVideo: () => Promise<void>;
  };
}
