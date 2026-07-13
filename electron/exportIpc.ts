import { BrowserWindow, clipboard, dialog, ipcMain, nativeImage, screen, type SaveDialogOptions } from "electron";
import { access, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

const PNG_SIGNATURE = [137, 80, 78, 71, 13, 10, 26, 10];
const MAX_EXPORT_BYTES = 512 * 1024 * 1024;

function pngBytes(input: unknown): Uint8Array | null {
  if (!(input instanceof Uint8Array) || input.byteLength < PNG_SIGNATURE.length || input.byteLength > MAX_EXPORT_BYTES) return null;
  return PNG_SIGNATURE.every((value, index) => input[index] === value) ? input : null;
}

function safeDefaultName(input: unknown): string {
  if (typeof input !== "string") return "ct-cine_f0001.png";
  const name = path.basename(input).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/[. ]+$/g, "");
  return name.toLowerCase().endsWith(".png") && name.length <= 180 ? name : "ct-cine_f0001.png";
}

export function registerExportIpc(): void {
  ipcMain.handle("export:savePng", async (event, input: unknown) => {
    const request = typeof input === "object" && input !== null ? input as { bytes?: unknown; defaultFileName?: unknown } : {};
    const bytes = pngBytes(request.bytes);
    if (!bytes) return { canceled: false as const, saved: false as const, error: "EXPORT_PNG_INVALID" };
    const owner = BrowserWindow.fromWebContents(event.sender) ?? undefined;
    const options: SaveDialogOptions = {
      title: "PNG 프레임 저장",
      defaultPath: safeDefaultName(request.defaultFileName),
      filters: [{ name: "PNG image", extensions: ["png"] }],
      properties: ["showOverwriteConfirmation"],
    };
    const selection = owner ? await dialog.showSaveDialog(owner, options) : await dialog.showSaveDialog(options);
    if (selection.canceled || !selection.filePath) return { canceled: true as const, saved: false as const };
    let existed = true;
    try {
      await access(selection.filePath);
    } catch {
      existed = false;
    }
    try {
      await writeFile(selection.filePath, bytes);
      return { canceled: false as const, saved: true as const, fileName: path.basename(selection.filePath), byteLength: bytes.byteLength };
    } catch {
      if (!existed) await unlink(selection.filePath).catch(() => undefined);
      return { canceled: false as const, saved: false as const, error: "EXPORT_SAVE_FAILED" };
    }
  });

  ipcMain.handle("export:copyPng", (_event, input: unknown) => {
    const request = typeof input === "object" && input !== null ? input as { bytes?: unknown } : {};
    const bytes = pngBytes(request.bytes);
    if (!bytes) return { copied: false as const, error: "EXPORT_PNG_INVALID" };
    try {
      const decoded = nativeImage.createFromBuffer(Buffer.from(bytes));
      if (decoded.isEmpty()) return { copied: false as const, error: "EXPORT_CLIPBOARD_IMAGE_INVALID" };
      const size = decoded.getSize(1);
      const image = nativeImage.createFromBitmap(decoded.toBitmap({ scaleFactor: 1 }), { ...size, scaleFactor: 1 });
      const owner = BrowserWindow.fromWebContents(_event.sender);
      const scaleFactor = owner
        ? screen.getDisplayMatching(owner.getBounds()).scaleFactor
        : screen.getPrimaryDisplay().scaleFactor;
      const clipboardImage = scaleFactor === 1 ? image : image.resize({
        width: Math.round(size.width * scaleFactor),
        height: Math.round(size.height * scaleFactor),
        quality: "best",
      });
      clipboard.writeImage(clipboardImage);
      return { copied: true as const, width: size.width, height: size.height, byteLength: bytes.byteLength };
    } catch {
      return { copied: false as const, error: "EXPORT_CLIPBOARD_FAILED" };
    }
  });
}
