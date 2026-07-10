import type { VideoProbeResult } from "../../domain/videoProbe.js";

export interface VideoProbeProvider<TSource> {
  probe(source: TSource): Promise<VideoProbeResult>;
}
