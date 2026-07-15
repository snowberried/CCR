/// <reference types="vite/client" />

type CcrCacheMemoryPreference = "auto" | 2 | 4 | 6 | 8;

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
  seekDecodedFrames?: number;
  prefetchDecodeCount?: number;
  prefetchedFrames?: number;
  prefetchInFlight?: boolean;
  analysisReady?: boolean;
  backgroundCacheMs?: number | null;
  fullProbeMs?: number | null;
  backgroundError?: string | null;
  prefetchError?: string | null;
  cacheMode?: "full" | "lru" | "fallback";
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
  source: "metadata-bt601-limited" | "candidate-bt601-limited" | "rgba-fallback";
  webglAllowed: boolean;
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
  sourceBaseName?: string;
  qaSampleIndex?: number;
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
    productCache?: boolean;
    blockFrames?: number;
    colorSource?: string;
    colorReason?: string;
    cacheMode?: "full" | "lru" | "fallback";
    cacheMemoryPreference?: CcrCacheMemoryPreference;
  };
  frame?: CcrFrameResponse;
  error?: string;
};

interface Window {
  ccr?: {
    getRuntimeStatus: () => Promise<{
      phase: string;
      decoderMode: "i420-cache" | "rgba-rollback";
      ffmpegConfigured: boolean;
      totalMemoryBytes: number;
    }>;
    checkForUpdates: () => Promise<{
      currentVersion: string;
      latestVersion: string;
      status: "current" | "available" | "ahead";
    }>;
    installUpdate: () => Promise<{
      started: boolean;
      latestVersion: string;
    }>;
    onUpdateProgress: (callback: (value: {
      stage: "downloading" | "installing" | "error";
      percent?: number;
    }) => void) => () => void;
    getFullscreen: () => Promise<boolean>;
    setFullscreen: (value: boolean) => Promise<boolean>;
    toggleFullscreen: () => Promise<boolean>;
    onFullscreenChanged: (callback: (value: boolean) => void) => () => void;
    openVideo: (cacheMemoryPreference: CcrCacheMemoryPreference) => Promise<CcrOpenVideoResponse>;
    savePng: (bytes: Uint8Array, defaultFileName: string) => Promise<{
      canceled: boolean;
      saved: boolean;
      fileName?: string;
      byteLength?: number;
      error?: string;
    }>;
    copyPng: (bytes: Uint8Array) => Promise<{
      copied: boolean;
      width?: number;
      height?: number;
      byteLength?: number;
      error?: string;
    }>;
    openDroppedVideo: (file: File, cacheMemoryPreference: CcrCacheMemoryPreference) => Promise<CcrOpenVideoResponse>;
    openQaVideo?: (sampleIndex: number) => Promise<CcrOpenVideoResponse>;
    getFrame: (sessionId: string, frameIndex: number, displayFormat?: "i420" | "rgba") => Promise<CcrFrameResponse>;
    ackFirstFrame?: (sessionId: string) => Promise<void>;
    onCacheMetadata?: (callback: (value: {
      sessionId: string;
      metadata: CcrOpenVideoResponse["metadata"];
      cacheStatus: CcrCacheStatus;
    }) => void) => () => void;
    cancelFrame: () => Promise<void>;
    closeVideo: () => Promise<void>;
  };
}
