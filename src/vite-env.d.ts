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
};

type CcrFrameResponse = {
  accepted: boolean;
  descriptor?: CcrFrameDescriptor;
  pixels?: Uint8Array;
  cache?: "hit" | "miss";
  requestMs?: number;
  cacheStatus?: CcrCacheStatus | null;
  error?: string;
};

type CcrOpenVideoResponse = {
  canceled: boolean;
  sessionId?: string;
  metadata?: {
    frameCount: number;
    width: number;
    height: number;
    codecName: string | null;
  };
  frame?: CcrFrameResponse;
  error?: string;
};

interface Window {
  ccr?: {
    getRuntimeStatus: () => Promise<{
      phase: string;
      ffmpegConfigured: boolean;
      sampleAnalysisReady: boolean;
    }>;
    openVideo: () => Promise<CcrOpenVideoResponse>;
    getFrame: (sessionId: string, frameIndex: number) => Promise<CcrFrameResponse>;
    cancelFrame: () => Promise<void>;
    closeVideo: () => Promise<void>;
  };
}
