export type FullscreenAction = "toggle" | "enter" | "exit";

export function targetFullscreen(current: boolean, action: FullscreenAction): boolean {
  if (action === "toggle") return !current;
  return action === "enter";
}
