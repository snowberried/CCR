/// <reference types="vite/client" />

type CcrFrameDescriptor = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  width: number;
  height: number;
  pixelFormat: "rgba" | "i420";
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
  blockCount?: number;
  readyFrameCount?: number;
  evictions?: number;
  backgroundComplete?: boolean;
  backgroundDecodedFrames?: number;
  backgroundDecodeCount?: number;
  seekDecodeCount?: number;
  analysisReady?: boolean;
  backgroundCacheMs?: number | null;
  fullProbeMs?: number | null;
};

type CcrI420Layout = {
  y: { offset: number; stride: number };
  u: { offset: number; stride: number };
  v: { offset: number; stride: number };
  byteLength: number;
};

type CcrVideoColorSpace = {
  fullRange: boolean;
  matrix: "bt709" | "smpte170m";
  primaries: "bt709" | "smpte170m";
  transfer: "bt709" | "smpte170m";
  source: "metadata" | "candidate-bt601-limited";
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
  layout?: CcrI420Layout;
  colorSpace?: CcrVideoColorSpace;
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
    cachePolicy?: {
      bytesPerFrame: number;
      budgetBytes: number;
      minimumTargetFrames: number;
      maximumFrames: number;
      frameCapacity: number;
      belowMinimumTarget: boolean;
    };
    analysisReady?: boolean;
    spike22?: boolean;
    blockFrames?: number;
    colorSource?: string;
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
    getFrame: (sessionId: string, frameIndex: number, displayFormat?: "i420" | "rgba") => Promise<CcrFrameResponse>;
    ackFirstFrame?: (sessionId: string) => Promise<void>;
    onSpikeMetadata?: (callback: (value: {
      sessionId: string;
      metadata: CcrOpenVideoResponse["metadata"];
      cacheStatus: CcrCacheStatus;
    }) => void) => () => void;
    cancelFrame: () => Promise<void>;
    closeVideo: () => Promise<void>;
  };
}
