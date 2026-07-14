import { app, BrowserWindow, ipcMain } from "electron";
import electronUpdater from "electron-updater";
import https from "node:https";
import { compareAppVersions } from "../src/domain/appVersion.js";

const LATEST_RELEASE_URL = "https://api.github.com/repos/snowberried/CCR/releases/latest";
const MAX_RESPONSE_BYTES = 64 * 1024;
const { autoUpdater } = electronUpdater;

type UpdateProgress = {
  stage: "downloading" | "installing" | "error";
  percent?: number;
};

type LatestRelease = {
  tag_name?: unknown;
};

function fetchLatestRelease(): Promise<LatestRelease> {
  return new Promise((resolve, reject) => {
    const request = https.get(LATEST_RELEASE_URL, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": `CT-Cine-Reviewer/${app.getVersion()}`,
        "X-GitHub-Api-Version": "2022-11-28",
      },
    }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`UPDATE_HTTP_${response.statusCode ?? "UNKNOWN"}`));
        return;
      }

      const chunks: Buffer[] = [];
      let byteLength = 0;
      response.on("data", (chunk: Buffer) => {
        byteLength += chunk.length;
        if (byteLength > MAX_RESPONSE_BYTES) {
          request.destroy(new Error("UPDATE_RESPONSE_TOO_LARGE"));
          return;
        }
        chunks.push(chunk);
      });
      response.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")) as LatestRelease);
        } catch {
          reject(new Error("UPDATE_INVALID_RESPONSE"));
        }
      });
    });

    request.setTimeout(10_000, () => request.destroy(new Error("UPDATE_TIMEOUT")));
    request.on("error", reject);
  });
}

function sendProgress(progress: UpdateProgress): void {
  for (const window of BrowserWindow.getAllWindows()) {
    if (!window.isDestroyed()) window.webContents.send("update:progress", progress);
  }
}

export function registerUpdateIpc(): void {
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = false;
  let installInProgress = false;

  autoUpdater.on("error", () => {
    installInProgress = false;
    sendProgress({ stage: "error" });
  });
  autoUpdater.on("download-progress", (progress) => {
    sendProgress({
      stage: "downloading",
      percent: Math.max(0, Math.min(100, progress.percent)),
    });
  });

  ipcMain.handle("update:check", async () => {
    const currentVersion = app.getVersion();
    const release = await fetchLatestRelease();
    if (typeof release.tag_name !== "string" || !/^v?\d+(?:\.\d+){1,2}$/.test(release.tag_name)) {
      throw new Error("UPDATE_INVALID_VERSION");
    }

    const latestVersion = release.tag_name.replace(/^v/i, "");
    const comparison = compareAppVersions(currentVersion, latestVersion);
    return {
      currentVersion,
      latestVersion,
      status: comparison < 0 ? "available" : comparison > 0 ? "ahead" : "current",
    };
  });

  ipcMain.handle("update:install", async () => {
    if (!app.isPackaged) throw new Error("UPDATE_INSTALL_PACKAGED_ONLY");
    if (installInProgress) throw new Error("UPDATE_INSTALL_IN_PROGRESS");

    installInProgress = true;
    try {
      const currentVersion = app.getVersion();
      const release = await fetchLatestRelease();
      if (typeof release.tag_name !== "string" || !/^v?\d+(?:\.\d+){1,2}$/.test(release.tag_name)) {
        throw new Error("UPDATE_INVALID_VERSION");
      }
      const latestVersion = release.tag_name.replace(/^v/i, "");
      if (compareAppVersions(currentVersion, latestVersion) >= 0) {
        throw new Error("UPDATE_NOT_AVAILABLE");
      }

      const checked = await autoUpdater.checkForUpdates();
      const metadataVersion = checked?.updateInfo.version.replace(/^v/i, "");
      if (!checked?.isUpdateAvailable || !metadataVersion || metadataVersion !== latestVersion) {
        throw new Error("UPDATE_METADATA_VERSION_MISMATCH");
      }

      await autoUpdater.downloadUpdate();
      sendProgress({ stage: "installing", percent: 100 });
      setTimeout(() => autoUpdater.quitAndInstall(true, true), 200);
      return { started: true, latestVersion };
    } catch (error) {
      installInProgress = false;
      sendProgress({ stage: "error" });
      throw error;
    }
  });
}
