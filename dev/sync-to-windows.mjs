#!/usr/bin/env node
/**
 * RecorderPhone — WSL -> Windows autosync helper
 *
 * Goal:
 * - Edit in WSL, but run/build Windows-only tooling (Flutter Windows / Visual Studio toolchain / Rust MSVC) against a mirror on /mnt/c/...
 *
 * Usage:
 *   node dev/sync-to-windows.mjs /mnt/c/src/RecorderPhone
 *
 * Notes:
 * - Runs an initial rsync, then watches the repo and debounces subsequent rsync runs.
 * - Excludes build artifacts by default (.git, node_modules, windows bin/obj, etc.)
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const dest = args[0];
if (!dest || dest.startsWith("-")) {
  // eslint-disable-next-line no-console
  console.error("Usage: node dev/sync-to-windows.mjs /mnt/c/src/RecorderPhone");
  process.exit(2);
}

const SRC_ROOT = process.cwd();
const DEST_ROOT = path.resolve(dest);

const EXCLUDED_DIR_NAMES = new Set([
  ".git",
  ".vs",
  ".idea",
  ".vscode",
  "node_modules",
  "target",
  "bin",
  "obj",
  "build",
  "data",
  // Local Windows packaging output (do not delete when mirroring).
  "dist"
]);

const EXCLUDE_GLOBS = [
  ".git/",
  ".vs/",
  ".idea/",
  ".vscode/",
  "**/node_modules/",
  "target/",
  "windows/**/bin/",
  "windows/**/obj/",
  // Local-only Flutter working copy created on Windows side.
  // It is derived from `ui_flutter/template/` and should not be deleted by mirroring.
  "recorderphone_ui/",
  "data/",
  // Local Windows packaging output (do not delete when mirroring).
  "dist/"
];

function isExcludedDir(dirName) {
  return EXCLUDED_DIR_NAMES.has(dirName);
}

async function ensureDest() {
  await fs.promises.mkdir(DEST_ROOT, { recursive: true });
}

function runRsync() {
  return new Promise((resolve, reject) => {
    const rsyncArgs = [
      "-a",
      "--delete",
      "--mkpath",
      ...EXCLUDE_GLOBS.flatMap((g) => ["--exclude", g]),
      `${SRC_ROOT}/`,
      `${DEST_ROOT}/`
    ];

    const p = spawn("rsync", rsyncArgs, { stdio: "inherit" });
    p.on("error", reject);
    p.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`rsync_exit_${code}`));
    });
  });
}

/** @returns {Promise<string[]>} */
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
      if (isExcludedDir(ent.name)) continue;
      stack.push(path.join(cur, ent.name));
    }
  }

  return dirs;
}

let syncing = false;
let pending = false;
let debounceTimer = null;

async function syncOnce(reason) {
  if (syncing) {
    pending = true;
    return;
  }

  syncing = true;
  pending = false;
  if (debounceTimer) {
    clearTimeout(debounceTimer);
    debounceTimer = null;
  }

  // eslint-disable-next-line no-console
  console.log(`\n[sync] ${new Date().toLocaleTimeString()}  reason=${reason}`);
  try {
    await ensureDest();
    await runRsync();
    // eslint-disable-next-line no-console
    console.log("[sync] done");
  } catch (e) {
    // eslint-disable-next-line no-console
    console.error("[sync] failed:", String(e));
  } finally {
    syncing = false;
  }

  if (pending) {
    await syncOnce("pending_changes");
  }
}

function scheduleSync(reason) {
  if (syncing) {
    pending = true;
    return;
  }
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    void syncOnce(reason);
  }, 250);
}

/** @type {Map<string, fs.FSWatcher>} */
const watchers = new Map();

function watchDir(dirPath) {
  if (watchers.has(dirPath)) return;
  try {
    const w = fs.watch(dirPath, { persistent: true }, (_eventType, filename) => {
      // Fast path: schedule sync; and if a new directory appears, rescan watchers.
      scheduleSync(filename ? `fswatch:${filename.toString()}` : "fswatch");
      if (filename) {
        const full = path.join(dirPath, filename.toString());
        fs.promises
          .stat(full)
          .then((st) => {
            if (st.isDirectory()) {
              // New folder created; add watcher.
              watchDir(full);
            }
          })
          .catch(() => {});
      }
    });
    watchers.set(dirPath, w);
  } catch {
    // Ignore directories that cannot be watched (permissions/race)
  }
}

async function installWatchers() {
  const dirs = await listDirsRecursively(SRC_ROOT);
  for (const d of dirs) watchDir(d);
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
  console.log("\n[watch] stopping…");
  closeWatchers();
  process.exit(0);
});

// eslint-disable-next-line no-console
console.log(`[watch] source: ${SRC_ROOT}`);
// eslint-disable-next-line no-console
console.log(`[watch] dest:   ${DEST_ROOT}`);
// eslint-disable-next-line no-console
console.log("[watch] initial sync…");
await syncOnce("initial");
await installWatchers();
// eslint-disable-next-line no-console
console.log(`[watch] watching (${watchers.size} dirs). Ctrl+C to stop.`);
