#!/usr/bin/env node
/**
 * RecorderPhone — overlay Flutter UI template into a Windows Flutter project (from WSL).
 *
 * Why:
 * - `ui_flutter/template/` is the source of truth for UI code.
 * - Your real runnable Flutter project lives in Windows at `recorderphone_ui/` (created by `flutter create`).
 * - If you can't (or don't want to) run PowerShell scripts, you can run this from WSL to keep UI in sync.
 *
 * Usage:
 *   node dev/overlay-ui-to-windows.mjs /mnt/c/src/RecorderPhone
 *   node dev/overlay-ui-to-windows.mjs /mnt/c/src/RecorderPhone --watch
 *
 * What it does:
 * - rsync `ui_flutter/template/lib/` -> `<dest>/recorderphone_ui/lib/` (with --delete)
 * - rsync `ui_flutter/template/assets/` -> `<dest>/recorderphone_ui/assets/` (with --delete)
 * - copy `ui_flutter/template/pubspec.yaml` -> `<dest>/recorderphone_ui/pubspec.yaml`
 *
 * Notes:
 * - This script does NOT run `flutter pub get` (run it on Windows when pubspec changes).
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const destRoot = args.find((a) => !a.startsWith("-"));
const watchMode = args.includes("--watch");

if (!destRoot) {
  // eslint-disable-next-line no-console
  console.error("Usage: node dev/overlay-ui-to-windows.mjs /mnt/c/src/RecorderPhone [--watch]");
  process.exit(2);
}

const SRC_ROOT = process.cwd();
const SRC_LIB = path.join(SRC_ROOT, "ui_flutter", "template", "lib");
const SRC_ASSETS = path.join(SRC_ROOT, "ui_flutter", "template", "assets");
const SRC_PUBSPEC = path.join(SRC_ROOT, "ui_flutter", "template", "pubspec.yaml");

const DEST_REPO = path.resolve(destRoot);
const DEST_UI = path.join(DEST_REPO, "recorderphone_ui");
const DEST_LIB = path.join(DEST_UI, "lib");
const DEST_ASSETS = path.join(DEST_UI, "assets");
const DEST_PUBSPEC = path.join(DEST_UI, "pubspec.yaml");

function assertExists(p, hint) {
  if (fs.existsSync(p)) return;
  // eslint-disable-next-line no-console
  console.error(`Missing: ${p}`);
  if (hint) {
    // eslint-disable-next-line no-console
    console.error(hint);
  }
  process.exit(2);
}

assertExists(SRC_LIB, "Run this from the RecorderPhone repo root (where ui_flutter/template exists).");
assertExists(SRC_ASSETS, "Missing ui_flutter/template/assets.");
assertExists(SRC_PUBSPEC, "Missing ui_flutter/template/pubspec.yaml.");
assertExists(
  DEST_UI,
  "Create your Windows Flutter project first (on Windows):\n  flutter create --platforms=windows recorderphone_ui"
);

async function ensureDest() {
  await fs.promises.mkdir(DEST_LIB, { recursive: true });
  await fs.promises.mkdir(DEST_ASSETS, { recursive: true });
}

function runRsync(from, to) {
  return new Promise((resolve, reject) => {
    const rsyncArgs = ["-a", "--delete", "--mkpath", `${from}/`, `${to}/`];
    const p = spawn("rsync", rsyncArgs, { stdio: "inherit" });
    p.on("error", reject);
    p.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`rsync_exit_${code}`));
    });
  });
}

async function copyPubspec() {
  await fs.promises.copyFile(SRC_PUBSPEC, DEST_PUBSPEC);
}

let overlaying = false;
let pending = false;
let debounceTimer = null;

async function overlayOnce(reason) {
  if (overlaying) {
    pending = true;
    return;
  }
  overlaying = true;
  pending = false;
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = null;
  }

  // eslint-disable-next-line no-console
  console.log(`\n[overlay-ui] ${new Date().toLocaleTimeString()}  reason=${reason}`);
  try {
    await ensureDest();
    await runRsync(SRC_LIB, DEST_LIB);
    await runRsync(SRC_ASSETS, DEST_ASSETS);
    await copyPubspec();
    // eslint-disable-next-line no-console
    console.log("[overlay-ui] done");
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error("[overlay-ui] failed:", String(e));
  } finally {
    overlaying = false;
  }

  if (pending) {
    await overlayOnce("pending_changes");
  }
}

function scheduleOverlay(reason) {
  if (overlaying) {
    pending = true;
    return;
  }
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    void overlayOnce(reason);
  }, 250);
}

/** @type {Map<string, fs.FSWatcher>} */
const watchers = new Map();

async function listDirsRecursively(rootDir) {
  /** @type {string[]} */
  const dirs = [];

  /** @type {string[]} */
  const stack = [rootDir];
  while (stack.length) {
    const cur = stack.pop();
    if (!cur) continue;
    dirs.push(cur);

    let entries;
    try {
      entries = await fs.promises.readdir(cur, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const ent of entries) {
      if (!ent.isDirectory()) continue;
      stack.push(path.join(cur, ent.name));
    }
  }

  return dirs;
}

function watchDir(dirPath) {
  if (watchers.has(dirPath)) return;
  try {
    const w = fs.watch(dirPath, { persistent: true }, (_eventType, filename) => {
      scheduleOverlay(filename ? `fswatch:${filename.toString()}` : "fswatch");
      if (filename) {
        const full = path.join(dirPath, filename.toString());
        fs.promises
          .stat(full)
          .then((st) => {
            if (st.isDirectory()) watchDir(full);
          })
          .catch(() => {});
      }
    });
    watchers.set(dirPath, w);
  } catch {
    // ignore
  }
}

async function installWatchers() {
  const dirs = await listDirsRecursively(SRC_LIB);
  for (const d of dirs) watchDir(d);
  const assetDirs = await listDirsRecursively(SRC_ASSETS);
  for (const d of assetDirs) watchDir(d);
  watchDir(path.dirname(SRC_PUBSPEC));
}

function closeWatchers() {
  for (const w of watchers.values()) {
    try {
      w.close();
    } catch {}
  }
  watchers.clear();
}

process.on("SIGINT", () => {
  // eslint-disable-next-line no-console
  console.log("\n[overlay-ui] stopping…");
  closeWatchers();
  process.exit(0);
});

// eslint-disable-next-line no-console
console.log(`[overlay-ui] source: ${path.relative(SRC_ROOT, SRC_LIB)}`);
// eslint-disable-next-line no-console
console.log(`[overlay-ui] dest:   ${DEST_LIB}`);

await overlayOnce("initial");

if (watchMode) {
  await installWatchers();
  // eslint-disable-next-line no-console
  console.log(`[overlay-ui] watching (${watchers.size} dirs). Ctrl+C to stop.`);
} else {
  // eslint-disable-next-line no-console
  console.log("[overlay-ui] tip: pass --watch to keep syncing changes.");
}
