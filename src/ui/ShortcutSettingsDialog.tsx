import { useMemo, useState, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent } from "react";
import {
  DEFAULT_SHORTCUT_PREFERENCES,
  FIXED_SHORTCUTS,
  SHORTCUT_CATEGORY_LABELS,
  SHORTCUT_DEFINITIONS,
  captureShortcutBinding,
  cloneShortcutPreferences,
  formatShortcutBinding,
  shortcutPreferenceErrors,
  type ShortcutAction,
  type ShortcutCategory,
  type ShortcutPreferences,
} from "./shortcuts";

type ShortcutSettingsDialogProps = {
  preferences: ShortcutPreferences;
  onCancel(): void;
  onSave(preferences: ShortcutPreferences): boolean;
};

const categories: ShortcutCategory[] = ["file", "frame", "view", "display"];

export function ShortcutSettingsDialog({ preferences, onCancel, onSave }: ShortcutSettingsDialogProps) {
  const [draft, setDraft] = useState(() => cloneShortcutPreferences(preferences));
  const [capturing, setCapturing] = useState<ShortcutAction | null>(null);
  const [captureError, setCaptureError] = useState<{ action: ShortcutAction; message: string } | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const errors = useMemo(() => shortcutPreferenceErrors(draft), [draft]);
  const hasErrors = Object.keys(errors).length > 0;

  const updateBinding = (action: ShortcutAction, value: ShortcutPreferences[ShortcutAction]) => {
    setDraft((current) => ({ ...current, [action]: value ? { ...value } : null }));
    setCaptureError(null);
    setSaveError(null);
  };

  const onDialogKeyDown = (event: ReactKeyboardEvent<HTMLElement>) => {
    if (capturing) {
      event.preventDefault();
      event.stopPropagation();
      if (event.code === "Escape") {
        setCapturing(null);
        setCaptureError(null);
        return;
      }
      const result = captureShortcutBinding(event.nativeEvent);
      if ("error" in result) {
        setCaptureError({ action: capturing, message: result.error });
        return;
      }
      updateBinding(capturing, result.binding);
      setCapturing(null);
      return;
    }
    if (event.code === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      onCancel();
    }
  };

  const cancelFromBackdrop = (event: MouseEvent<HTMLDivElement>) => {
    if (event.target === event.currentTarget) onCancel();
  };

  return (
    <div className="settings-backdrop shortcut-settings-backdrop" onMouseDown={cancelFromBackdrop}>
      <section
        className="shortcut-settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="shortcut-settings-title"
        onKeyDownCapture={onDialogKeyDown}
      >
        <header className="settings-dialog-header shortcut-settings-header">
          <div>
            <h2 id="shortcut-settings-title">단축키 설정</h2>
            <p>단축키 버튼을 누른 뒤 새 조합을 입력하세요. 변경 내용은 저장할 때 적용됩니다.</p>
          </div>
          <button type="button" aria-label="단축키 설정 닫기" onClick={onCancel}>×</button>
        </header>

        <div className="shortcut-settings-content">
          <div className="shortcut-settings-toolbar">
            <p>{capturing ? "새 단축키를 입력하세요. Esc를 누르면 입력만 취소됩니다." : "기능마다 단축키 하나를 지정하거나 해제할 수 있습니다."}</p>
            <button
              type="button"
              onClick={() => {
                setDraft(cloneShortcutPreferences(DEFAULT_SHORTCUT_PREFERENCES));
                setCapturing(null);
                setCaptureError(null);
                setSaveError(null);
              }}
            >모두 기본값</button>
          </div>

          {categories.map((category) => (
            <section className="shortcut-category" key={category} aria-labelledby={`shortcut-category-${category}`}>
              <h3 id={`shortcut-category-${category}`}>{SHORTCUT_CATEGORY_LABELS[category]}</h3>
              <div className="shortcut-category-rows">
                {SHORTCUT_DEFINITIONS.filter((definition) => definition.category === category).map((definition) => {
                  const rowError = errors[definition.action] ??
                    (captureError?.action === definition.action ? captureError.message : null);
                  const isCapturing = capturing === definition.action;
                  return (
                    <div className={`shortcut-row${rowError ? " has-error" : ""}`} key={definition.action}>
                      <div className="shortcut-row-label">
                        <strong>{definition.label}</strong>
                        {rowError && <span role="alert">{rowError}</span>}
                      </div>
                      <button
                        type="button"
                        className={`shortcut-capture-button${isCapturing ? " is-capturing" : ""}`}
                        aria-label={`${definition.label} 단축키 ${isCapturing ? "입력 중" : "변경"}`}
                        aria-pressed={isCapturing}
                        onClick={() => {
                          setCapturing(definition.action);
                          setCaptureError(null);
                          setSaveError(null);
                        }}
                      >{isCapturing ? "키를 누르세요…" : formatShortcutBinding(draft[definition.action])}</button>
                      <button
                        type="button"
                        className="shortcut-secondary-button"
                        aria-label={`${definition.label} 단축키 해제`}
                        onClick={() => {
                          updateBinding(definition.action, null);
                          if (capturing === definition.action) setCapturing(null);
                        }}
                        disabled={draft[definition.action] === null}
                      >해제</button>
                      <button
                        type="button"
                        className="shortcut-secondary-button"
                        aria-label={`${definition.label} 단축키 기본값`}
                        onClick={() => {
                          updateBinding(definition.action, DEFAULT_SHORTCUT_PREFERENCES[definition.action]);
                          if (capturing === definition.action) setCapturing(null);
                        }}
                      >기본값</button>
                    </div>
                  );
                })}
              </div>
            </section>
          ))}

          <section className="shortcut-category fixed-shortcut-category" aria-labelledby="fixed-shortcuts-title">
            <h3 id="fixed-shortcuts-title">고정 단축키</h3>
            <p>주석 편집과 기본 입력 동작은 변경할 수 없습니다.</p>
            <div className="fixed-shortcut-list">
              {FIXED_SHORTCUTS.map((item) => (
                <div key={item.label}>
                  <strong>{item.label}</strong>
                  <span>{item.bindings.join(", ")}</span>
                </div>
              ))}
            </div>
          </section>
        </div>

        <footer className="shortcut-settings-footer">
          <div>
            {hasErrors && <p role="alert">겹치거나 사용할 수 없는 단축키를 수정하세요.</p>}
            {saveError && <p role="alert">{saveError}</p>}
          </div>
          <button type="button" className="shortcut-cancel-button" onClick={onCancel}>취소</button>
          <button
            type="button"
            className="shortcut-save-button"
            disabled={hasErrors || capturing !== null}
            onClick={() => {
              if (hasErrors || capturing) return;
              if (!onSave(cloneShortcutPreferences(draft))) {
                setSaveError("단축키 설정을 저장하지 못했습니다.");
              }
            }}
          >저장</button>
        </footer>
      </section>
    </div>
  );
}
