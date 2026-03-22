#!/usr/bin/env node
/**
 * WorkTrace — WSL-friendly local ingest server (for browser extension dev)
 *
 * Endpoints:
 *  - GET  /health  -> { ok: true }
 *  - POST /event   -> accepts JSON event (see schemas/ingest-event.schema.json)
 *  - GET  /events  -> last N events (memory)
 *
 * Defaults:
 *  - HOST=127.0.0.1
 *  - PORT=17600
 *  - STORE_FILE=./data/ingest-events.ndjson (optional)
 *
 * Notes:
 *  - In WSL 2, services listening on PORT are usually reachable from Windows at http://localhost:PORT.
 */

import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const HOST = process.env.HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || "17600");
const STORE_FILE = process.env.STORE_FILE || "";
const MAX_EVENTS = Number(process.env.MAX_EVENTS || "200");

/** @type {any[]} */
const recent = [];

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type"
  });
  res.end(payload);
}

function text(res, status, body) {
  res.writeHead(status, {
    "content-type": "text/plain; charset=utf-8",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type"
  });
  res.end(body);
}

function isValidEvent(e) {
  if (!e || typeof e !== "object") return false;
  if (e.v !== 1) return false;
  if (typeof e.ts !== "string" || e.ts.length < 10) return false;
  if (e.source !== "browser_extension") return false;
  if (e.event !== "tab_active" && e.event !== "tab_audio_stop") return false;
  if (typeof e.domain !== "string" || e.domain.trim().length === 0) return false;
  return true;
}

function appendToFile(line) {
  if (!STORE_FILE) return;
  const filePath = path.resolve(process.cwd(), STORE_FILE);
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true });
  fs.appendFileSync(filePath, line + "\n", "utf8");
}

function addEvent(e) {
  recent.unshift(e);
  while (recent.length > MAX_EVENTS) recent.pop();
  appendToFile(JSON.stringify(e));

  const t = new Date(e.ts).toLocaleTimeString();
  const title = e.title ? ` — ${e.title}` : "";
  // Minimal console log for dev
  // eslint-disable-next-line no-console
  console.log(`[${t}] ${e.domain}${title}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      data += chunk;
      if (data.length > 1024 * 1024) {
        reject(new Error("body_too_large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);

  if (req.method === "OPTIONS") {
    res.writeHead(200, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "content-type",
      "access-control-max-age": "600"
    });
    res.end();
    return;
  }

  if (req.method === "GET" && url.pathname === "/health") {
    json(res, 200, { ok: true, service: "ingest_server", version: "0.1.32" });
    return;
  }

  if (req.method === "GET" && url.pathname === "/events") {
    json(res, 200, { ok: true, count: recent.length, events: recent });
    return;
  }

  if (req.method === "POST" && url.pathname === "/event") {
    try {
      const raw = await readBody(req);
      const e = JSON.parse(raw);
      if (!isValidEvent(e)) {
        json(res, 400, { ok: false, error: "invalid_event" });
        return;
      }
      addEvent(e);
      json(res, 200, { ok: true });
      return;
    } catch (err) {
      json(res, 400, { ok: false, error: "invalid_json" });
      return;
    }
  }

  text(res, 404, "not_found");
});

server.listen(PORT, HOST, () => {
  // eslint-disable-next-line no-console
  console.log(`WorkTrace ingest server listening on http://${HOST}:${PORT}`);
  if (STORE_FILE) {
    // eslint-disable-next-line no-console
    console.log(`Writing NDJSON to ${STORE_FILE}`);
  } else {
    // eslint-disable-next-line no-console
    console.log("Tip: set STORE_FILE=./data/ingest-events.ndjson to persist events.");
  }
});
