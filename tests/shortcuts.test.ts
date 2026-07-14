import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_SHORTCUT_PREFERENCES,
  SHORTCUT_STORAGE_KEY,
  captureShortcutBinding,
  cloneShortcutPreferences,
  formatShortcutBinding,
  loadShortcutPreferences,
  matchShortcutAction,
  saveShortcutPreferences,
  shortcutPreferenceErrors,
  type ShortcutKeyInput,
} from "../src/ui/shortcuts";

const key = (
  code: string,
  modifiers: Partial<Omit<ShortcutKeyInput, "code">> = {},
): ShortcutKeyInput => ({
  code,
  ctrlKey: modifiers.ctrlKey ?? false,
  shiftKey: modifiers.shiftKey ?? false,
  altKey: modifiers.altKey ?? false,
  metaKey: modifiers.metaKey ?? false,
});

test("provides the documented default shortcuts and exact matching", () => {
  assert.equal(matchShortcutAction(key("KeyO", { ctrlKey: true }), DEFAULT_SHORTCUT_PREFERENCES), "openVideo");
  assert.equal(matchShortcutAction(key("ArrowLeft"), DEFAULT_SHORTCUT_PREFERENCES), "previousFrame");
  assert.equal(matchShortcutAction(key("ArrowRight"), DEFAULT_SHORTCUT_PREFERENCES), "nextFrame");
  assert.equal(matchShortcutAction(key("ArrowDown"), DEFAULT_SHORTCUT_PREFERENCES), "fastPreviousFrame");
  assert.equal(matchShortcutAction(key("ArrowUp"), DEFAULT_SHORTCUT_PREFERENCES), "fastNextFrame");
  assert.equal(matchShortcutAction(key("Home"), DEFAULT_SHORTCUT_PREFERENCES), "firstFrame");
  assert.equal(matchShortcutAction(key("End"), DEFAULT_SHORTCUT_PREFERENCES), "lastFrame");
  assert.equal(matchShortcutAction(key("Equal", { shiftKey: true }), DEFAULT_SHORTCUT_PREFERENCES), "zoomIn");
  assert.equal(matchShortcutAction(key("Minus"), DEFAULT_SHORTCUT_PREFERENCES), "zoomOut");
  assert.equal(matchShortcutAction(key("Digit0"), DEFAULT_SHORTCUT_PREFERENCES), "fitView");
  assert.equal(matchShortcutAction(key("KeyF"), DEFAULT_SHORTCUT_PREFERENCES), "toggleFullscreen");
  assert.equal(matchShortcutAction(key("KeyR"), DEFAULT_SHORTCUT_PREFERENCES), "resetDisplay");
  assert.equal(matchShortcutAction(key("KeyI"), DEFAULT_SHORTCUT_PREFERENCES), "toggleInvert");
  assert.equal(matchShortcutAction(key("KeyO"), DEFAULT_SHORTCUT_PREFERENCES), "compareOriginal");
});

test("removes historical auxiliary shortcut combinations", () => {
  assert.equal(matchShortcutAction(key("ArrowLeft", { shiftKey: true }), DEFAULT_SHORTCUT_PREFERENCES), null);
  assert.equal(matchShortcutAction(key("ArrowRight", { shiftKey: true }), DEFAULT_SHORTCUT_PREFERENCES), null);
  assert.equal(matchShortcutAction(key("Equal"), DEFAULT_SHORTCUT_PREFERENCES), null);
  assert.equal(matchShortcutAction(key("NumpadAdd"), DEFAULT_SHORTCUT_PREFERENCES), null);
  assert.equal(matchShortcutAction(key("NumpadSubtract"), DEFAULT_SHORTCUT_PREFERENCES), null);
  assert.equal(matchShortcutAction(key("Minus", { shiftKey: true }), DEFAULT_SHORTCUT_PREFERENCES), null);
});

test("matches Ctrl, Shift, Alt, and physical key code exactly", () => {
  const preferences = cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  preferences.openVideo = { code: "KeyP", ctrl: true, shift: true, alt: true };
  assert.equal(matchShortcutAction(key("KeyP", { ctrlKey: true, shiftKey: true, altKey: true }), preferences), "openVideo");
  assert.equal(matchShortcutAction(key("KeyP", { ctrlKey: true, shiftKey: true }), preferences), null);
  assert.equal(matchShortcutAction(key("KeyO", { ctrlKey: true }), preferences), null);
  assert.equal(matchShortcutAction(key("KeyP", { ctrlKey: true, shiftKey: true, altKey: true, metaKey: true }), preferences), null);
});

test("allows disabled bindings and formats visible labels", () => {
  const preferences = cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  preferences.toggleFullscreen = null;
  assert.deepEqual(shortcutPreferenceErrors(preferences), {});
  assert.equal(matchShortcutAction(key("KeyF"), preferences), null);
  assert.equal(formatShortcutBinding(preferences.toggleFullscreen), "사용 안 함");
  assert.equal(formatShortcutBinding(DEFAULT_SHORTCUT_PREFERENCES.zoomIn), "+");
  assert.equal(formatShortcutBinding(DEFAULT_SHORTCUT_PREFERENCES.fastNextFrame), "↑");
});

test("rejects reserved, fixed, modifier-only, Windows, and Alt+F4 bindings", () => {
  for (const input of [
    key("Tab"),
    key("Enter"),
    key("Space"),
    key("Escape"),
    key("Delete"),
    key("Backspace"),
    key("ControlLeft", { ctrlKey: true }),
    key("F4", { altKey: true }),
    key("KeyA", { metaKey: true }),
    key("KeyZ", { ctrlKey: true }),
    key("KeyY", { ctrlKey: true }),
    key("KeyZ", { ctrlKey: true, shiftKey: true }),
  ]) {
    assert.ok("error" in captureShortcutBinding(input));
  }
});

test("marks duplicate configurable bindings and blocks persistence", () => {
  const preferences = cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  preferences.nextFrame = { ...preferences.previousFrame! };
  const errors = shortcutPreferenceErrors(preferences);
  assert.match(errors.previousFrame ?? "", /중복/);
  assert.match(errors.nextFrame ?? "", /중복/);
  const storage = { getItem: () => null, setItem: () => undefined };
  assert.equal(saveShortcutPreferences(storage, preferences), false);
});

test("saves and restores a complete valid preference set", () => {
  const values = new Map<string, string>();
  const storage = {
    getItem: (storageKey: string) => values.get(storageKey) ?? null,
    setItem: (storageKey: string, value: string) => { values.set(storageKey, value); },
  };
  const preferences = cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  preferences.previousFrame = { code: "KeyA", ctrl: false, shift: false, alt: false };
  preferences.compareOriginal = null;
  assert.equal(saveShortcutPreferences(storage, preferences), true);
  assert.ok(values.has(SHORTCUT_STORAGE_KEY));
  assert.deepEqual(loadShortcutPreferences(storage), preferences);
});

test("recovers the full default set from missing, corrupt, or incomplete storage", () => {
  const values = new Map<string, string>();
  const storage = {
    getItem: (storageKey: string) => values.get(storageKey) ?? null,
    setItem: (storageKey: string, value: string) => { values.set(storageKey, value); },
  };
  assert.deepEqual(loadShortcutPreferences(storage), DEFAULT_SHORTCUT_PREFERENCES);
  values.set(SHORTCUT_STORAGE_KEY, "not-json");
  assert.deepEqual(loadShortcutPreferences(storage), DEFAULT_SHORTCUT_PREFERENCES);
  values.set(SHORTCUT_STORAGE_KEY, JSON.stringify({ openVideo: null }));
  assert.deepEqual(loadShortcutPreferences(storage), DEFAULT_SHORTCUT_PREFERENCES);
  const duplicate = cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES);
  duplicate.nextFrame = { ...duplicate.previousFrame! };
  values.set(SHORTCUT_STORAGE_KEY, JSON.stringify(duplicate));
  assert.deepEqual(loadShortcutPreferences(storage), DEFAULT_SHORTCUT_PREFERENCES);
});
