export const SHORTCUT_STORAGE_KEY = "ccr.shortcuts.v1";

export const SHORTCUT_ACTIONS = [
  "openVideo",
  "previousFrame",
  "nextFrame",
  "fastPreviousFrame",
  "fastNextFrame",
  "firstFrame",
  "lastFrame",
  "zoomIn",
  "zoomOut",
  "fitView",
  "toggleFullscreen",
  "resetDisplay",
  "toggleInvert",
  "compareOriginal",
] as const;

export type ShortcutAction = typeof SHORTCUT_ACTIONS[number];
export type ShortcutCategory = "file" | "frame" | "view" | "display";

export type ShortcutBinding = {
  code: string;
  ctrl: boolean;
  shift: boolean;
  alt: boolean;
};

export type ShortcutPreferences = Record<ShortcutAction, ShortcutBinding | null>;

export type ShortcutKeyInput = {
  code: string;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  metaKey?: boolean;
};

export type ShortcutStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
};

export type ShortcutDefinition = {
  action: ShortcutAction;
  category: ShortcutCategory;
  label: string;
};

const binding = (
  code: string,
  modifiers: Partial<Pick<ShortcutBinding, "ctrl" | "shift" | "alt">> = {},
): ShortcutBinding => ({
  code,
  ctrl: modifiers.ctrl ?? false,
  shift: modifiers.shift ?? false,
  alt: modifiers.alt ?? false,
});

export const SHORTCUT_DEFINITIONS: readonly ShortcutDefinition[] = [
  { action: "openVideo", category: "file", label: "파일 열기" },
  { action: "previousFrame", category: "frame", label: "이전 프레임" },
  { action: "nextFrame", category: "frame", label: "다음 프레임" },
  { action: "fastPreviousFrame", category: "frame", label: "빠른 이전" },
  { action: "fastNextFrame", category: "frame", label: "빠른 다음" },
  { action: "firstFrame", category: "frame", label: "첫 프레임" },
  { action: "lastFrame", category: "frame", label: "마지막 프레임" },
  { action: "zoomIn", category: "view", label: "확대" },
  { action: "zoomOut", category: "view", label: "축소" },
  { action: "fitView", category: "view", label: "화면 맞춤" },
  { action: "toggleFullscreen", category: "view", label: "전체 화면" },
  { action: "resetDisplay", category: "display", label: "화면 보정 원본 보기" },
  { action: "toggleInvert", category: "display", label: "반전" },
  { action: "compareOriginal", category: "display", label: "누르는 동안 원본 비교" },
] as const;

export const SHORTCUT_CATEGORY_LABELS: Record<ShortcutCategory, string> = {
  file: "파일",
  frame: "프레임",
  view: "화면",
  display: "표시 보정",
};

export const DEFAULT_SHORTCUT_PREFERENCES: ShortcutPreferences = {
  openVideo: binding("KeyO", { ctrl: true }),
  previousFrame: binding("ArrowLeft"),
  nextFrame: binding("ArrowRight"),
  fastPreviousFrame: binding("ArrowDown"),
  fastNextFrame: binding("ArrowUp"),
  firstFrame: binding("Home"),
  lastFrame: binding("End"),
  zoomIn: binding("Equal", { shift: true }),
  zoomOut: binding("Minus"),
  fitView: binding("Digit0"),
  toggleFullscreen: binding("KeyF"),
  resetDisplay: binding("KeyR"),
  toggleInvert: binding("KeyI"),
  compareOriginal: binding("KeyO"),
};

export const FIXED_SHORTCUTS = [
  { label: "창 닫기·동작 취소", bindings: ["Esc"] },
  { label: "주석 실행 취소", bindings: ["Ctrl+Z"] },
  { label: "주석 다시 실행", bindings: ["Ctrl+Y", "Ctrl+Shift+Z"] },
  { label: "선택 주석 삭제", bindings: ["Delete", "Backspace"] },
  { label: "프레임·확대/축소", bindings: ["휠", "Ctrl+휠"] },
  { label: "입력창 적용·취소", bindings: ["Enter", "Esc"] },
] as const;

const fixedKeyboardBindings = [
  { binding: binding("KeyZ", { ctrl: true }), label: "주석 실행 취소(Ctrl+Z)" },
  { binding: binding("KeyY", { ctrl: true }), label: "주석 다시 실행(Ctrl+Y)" },
  { binding: binding("KeyZ", { ctrl: true, shift: true }), label: "주석 다시 실행(Ctrl+Shift+Z)" },
] as const;

const reservedCodes = new Set([
  "Tab",
  "Enter",
  "NumpadEnter",
  "Space",
  "Escape",
  "Delete",
  "Backspace",
]);

const modifierCodes = new Set([
  "ControlLeft",
  "ControlRight",
  "ShiftLeft",
  "ShiftRight",
  "AltLeft",
  "AltRight",
  "MetaLeft",
  "MetaRight",
]);

function sameBinding(left: ShortcutBinding, right: ShortcutBinding): boolean {
  return left.code === right.code && left.ctrl === right.ctrl && left.shift === right.shift && left.alt === right.alt;
}

function isBoolean(value: unknown): value is boolean {
  return typeof value === "boolean";
}

function isShortcutBinding(value: unknown): value is ShortcutBinding {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<ShortcutBinding>;
  return typeof candidate.code === "string" && candidate.code.length > 0 &&
    isBoolean(candidate.ctrl) && isBoolean(candidate.shift) && isBoolean(candidate.alt);
}

function bindingProblem(value: ShortcutBinding): string | null {
  if (!value.code) return "올바른 단축키가 아닙니다.";
  if (modifierCodes.has(value.code)) return "보조 키만으로는 설정할 수 없습니다.";
  if (reservedCodes.has(value.code)) return "이 키는 고정 동작에 사용되어 설정할 수 없습니다.";
  if (value.alt && value.code === "F4") return "Alt+F4는 설정할 수 없습니다.";
  const fixed = fixedKeyboardBindings.find((candidate) => sameBinding(candidate.binding, value));
  return fixed ? `${fixed.label}와 겹칩니다.` : null;
}

export function cloneShortcutPreferences(preferences: ShortcutPreferences): ShortcutPreferences {
  return Object.fromEntries(SHORTCUT_ACTIONS.map((action) => [
    action,
    preferences[action] ? { ...preferences[action] } : null,
  ])) as ShortcutPreferences;
}

export function captureShortcutBinding(input: ShortcutKeyInput): { binding: ShortcutBinding } | { error: string } {
  if (input.metaKey || input.code === "MetaLeft" || input.code === "MetaRight") {
    return { error: "Windows 키는 단축키에 사용할 수 없습니다." };
  }
  const captured = binding(input.code, {
    ctrl: input.ctrlKey,
    shift: input.shiftKey,
    alt: input.altKey,
  });
  const problem = bindingProblem(captured);
  return problem ? { error: problem } : { binding: captured };
}

export function shortcutPreferenceErrors(preferences: ShortcutPreferences): Partial<Record<ShortcutAction, string>> {
  const errors: Partial<Record<ShortcutAction, string>> = {};
  const bindingActions = new Map<string, ShortcutAction[]>();
  for (const action of SHORTCUT_ACTIONS) {
    const value = preferences[action];
    if (value === null) continue;
    if (!isShortcutBinding(value)) {
      errors[action] = "올바른 단축키가 아닙니다.";
      continue;
    }
    const problem = bindingProblem(value);
    if (problem) errors[action] = problem;
    const signature = `${value.code}|${Number(value.ctrl)}|${Number(value.shift)}|${Number(value.alt)}`;
    bindingActions.set(signature, [...(bindingActions.get(signature) ?? []), action]);
  }
  for (const actions of bindingActions.values()) {
    if (actions.length < 2) continue;
    const duplicate = `${formatShortcutBinding(preferences[actions[0]])} 단축키가 중복되었습니다.`;
    for (const action of actions) errors[action] = duplicate;
  }
  return errors;
}

export function matchShortcutAction(input: ShortcutKeyInput, preferences: ShortcutPreferences): ShortcutAction | null {
  if (input.metaKey) return null;
  const candidate = binding(input.code, {
    ctrl: input.ctrlKey,
    shift: input.shiftKey,
    alt: input.altKey,
  });
  return SHORTCUT_ACTIONS.find((action) => {
    const configured = preferences[action];
    return configured !== null && sameBinding(configured, candidate);
  }) ?? null;
}

function keyLabel(value: ShortcutBinding): string {
  if (value.code === "Equal" && value.shift && !value.ctrl && !value.alt) return "+";
  if (value.code === "Minus") return "-";
  if (value.code === "Equal") return "=";
  if (value.code === "ArrowLeft") return "←";
  if (value.code === "ArrowRight") return "→";
  if (value.code === "ArrowUp") return "↑";
  if (value.code === "ArrowDown") return "↓";
  if (value.code === "Escape") return "Esc";
  if (value.code === "Space") return "Space";
  if (value.code.startsWith("Key")) return value.code.slice(3);
  if (value.code.startsWith("Digit")) return value.code.slice(5);
  if (value.code.startsWith("Numpad")) return `Num ${value.code.slice(6)}`;
  return value.code;
}

export function formatShortcutBinding(value: ShortcutBinding | null): string {
  if (!value) return "사용 안 함";
  if (value.code === "Equal" && value.shift && !value.ctrl && !value.alt) return "+";
  const parts: string[] = [];
  if (value.ctrl) parts.push("Ctrl");
  if (value.alt) parts.push("Alt");
  if (value.shift) parts.push("Shift");
  parts.push(keyLabel(value));
  return parts.join("+");
}

function validPreferences(value: unknown): value is ShortcutPreferences {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<Record<ShortcutAction, unknown>>;
  for (const action of SHORTCUT_ACTIONS) {
    if (!(action in candidate)) return false;
    if (candidate[action] !== null && !isShortcutBinding(candidate[action])) return false;
  }
  return Object.keys(shortcutPreferenceErrors(candidate as ShortcutPreferences)).length === 0;
}

export function loadShortcutPreferences(storage: ShortcutStorage | null | undefined): ShortcutPreferences {
  if (!storage) return cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  try {
    const serialized = storage.getItem(SHORTCUT_STORAGE_KEY);
    if (!serialized) return cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
    const parsed: unknown = JSON.parse(serialized);
    return validPreferences(parsed)
      ? cloneShortcutPreferences(parsed)
      : cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  } catch {
    return cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  }
}

export function saveShortcutPreferences(
  storage: ShortcutStorage | null | undefined,
  preferences: ShortcutPreferences,
): boolean {
  if (!storage || !validPreferences(preferences)) return false;
  try {
    storage.setItem(SHORTCUT_STORAGE_KEY, JSON.stringify(preferences));
    return true;
  } catch {
    return false;
  }
}
