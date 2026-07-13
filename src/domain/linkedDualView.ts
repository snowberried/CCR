import type { VideoDisplayState } from "./videoDisplay.js";
import {
  imageToViewport,
  viewportToImage,
  type Point,
  type ViewTransform,
} from "./viewTransform.js";

export type PaneId = "a" | "b";

export type ViewerTool = "pan" | "zoom" | "select" | "arrow" | "text" | "ellipse" | "rectangle";

export type PaneState = {
  viewTransform: ViewTransform | null;
  display: VideoDisplayState;
  tool: ViewerTool;
  comparingOriginal: boolean;
};

export type PaneStates = Record<PaneId, PaneState>;

export type LinkedCrosshair = {
  imagePoint: Point;
  targetViewportPoint: Point;
};

export type LinkedPaneFrame = {
  frameIndex: number;
  fingerprint: string;
  pixels: unknown;
};

export function otherPane(paneId: PaneId): PaneId {
  return paneId === "a" ? "b" : "a";
}

export function clonePaneState(state: PaneState): PaneState {
  return structuredClone({ ...state, comparingOriginal: false });
}

export function updatePaneState(states: PaneStates, paneId: PaneId, next: PaneState): PaneStates {
  if (states[paneId] === next) return states;
  return { ...states, [paneId]: next };
}

export function linkedPaneFramesMatch(a: LinkedPaneFrame | null, b: LinkedPaneFrame | null): boolean {
  return Boolean(
    a && b &&
    a.frameIndex === b.frameIndex &&
    a.fingerprint === b.fingerprint &&
    a.pixels === b.pixels,
  );
}

export function mapLinkedCrosshair(input: {
  sourceTransform: ViewTransform;
  targetTransform: ViewTransform;
  sourceViewportPoint: Point;
  framesMatch: boolean;
  rendererReady: boolean;
}): LinkedCrosshair | null {
  if (!input.framesMatch || !input.rendererReady) return null;
  const imagePoint = viewportToImage(input.sourceTransform, input.sourceViewportPoint);
  if (
    imagePoint.x < 0 || imagePoint.x > input.sourceTransform.imageSize.width ||
    imagePoint.y < 0 || imagePoint.y > input.sourceTransform.imageSize.height
  ) return null;
  const targetViewportPoint = imageToViewport(input.targetTransform, imagePoint);
  if (
    targetViewportPoint.x < 0 || targetViewportPoint.x > input.targetTransform.viewportSize.width ||
    targetViewportPoint.y < 0 || targetViewportPoint.y > input.targetTransform.viewportSize.height
  ) return null;
  return { imagePoint, targetViewportPoint };
}
