export type FramePoint = {
  frameIndex: number;
  pts: string | null;
  ptsSeconds: number | null;
  durationSeconds: number | null;
  keyframe: boolean;
};

export type FrameSequenceIssue =
  | {
      code: "FRAME_INDEX_GAP";
      frameIndex: number;
      expectedFrameIndex: number;
    }
  | {
      code: "PTS_MISSING";
      frameIndex: number;
    }
  | {
      code: "PTS_INVALID";
      frameIndex: number;
    }
  | {
      code: "PTS_DUPLICATE";
      frameIndex: number;
      previousFrameIndex: number;
    }
  | {
      code: "PTS_BACKWARD";
      frameIndex: number;
      previousFrameIndex: number;
    };

export type FrameSequenceValidation = {
  frameCount: number;
  contiguousFrameIndex: boolean;
  completePts: boolean;
  validPts: boolean;
  monotonicPts: boolean;
  duplicatePts: boolean;
  issues: readonly FrameSequenceIssue[];
};

export function validateFrameSequence(frames: readonly FramePoint[]): FrameSequenceValidation {
  const issues: FrameSequenceIssue[] = [];
  let contiguousFrameIndex = true;
  let completePts = true;
  let validPts = true;
  let monotonicPts = true;
  let duplicatePts = false;
  let previousPts: bigint | null = null;
  let previousPtsFrameIndex: number | null = null;
  const seenPts = new Map<string, number>();

  frames.forEach((frame, expectedIndex) => {
    if (frame.frameIndex !== expectedIndex) {
      contiguousFrameIndex = false;
      issues.push({
        code: "FRAME_INDEX_GAP",
        frameIndex: frame.frameIndex,
        expectedFrameIndex: expectedIndex,
      });
    }

    if (frame.pts === null || frame.ptsSeconds === null) {
      completePts = false;
      issues.push({ code: "PTS_MISSING", frameIndex: frame.frameIndex });
      return;
    }

    if (!/^-?\d+$/.test(frame.pts) || !Number.isFinite(frame.ptsSeconds)) {
      validPts = false;
      issues.push({ code: "PTS_INVALID", frameIndex: frame.frameIndex });
      return;
    }

    const pts = BigInt(frame.pts);
    const canonicalPts = pts.toString();
    const duplicateFrameIndex = seenPts.get(canonicalPts);

    if (duplicateFrameIndex !== undefined) {
      duplicatePts = true;
      issues.push({
        code: "PTS_DUPLICATE",
        frameIndex: frame.frameIndex,
        previousFrameIndex: duplicateFrameIndex,
      });
    }

    if (previousPts !== null && pts < previousPts) {
      monotonicPts = false;
      issues.push({
        code: "PTS_BACKWARD",
        frameIndex: frame.frameIndex,
        previousFrameIndex: previousPtsFrameIndex as number,
      });
    }

    seenPts.set(canonicalPts, frame.frameIndex);
    previousPts = pts;
    previousPtsFrameIndex = frame.frameIndex;
  });

  return {
    frameCount: frames.length,
    contiguousFrameIndex,
    completePts,
    validPts,
    monotonicPts,
    duplicatePts,
    issues,
  };
}
