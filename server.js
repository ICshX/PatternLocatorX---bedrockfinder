// ============================================================
// PatternLocatorX - Global Web Server (Optimized + Color-Aware)
// ============================================================
// © 2025 ICshX | MIT License
// - Large pattern-safe JSON body (50MB)
// - Batched SSE output (anti-lag, 500ms flush)
// - Auto-timeout (60s)
// - Smart color-level detection
// - Graceful stop + cleanup
// - Global usage tracking
// ============================================================

const express = require("express");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const cors = require("cors");

const app = express();
const PORT = process.env.PORT || 3000;

// ============================================================
// Middleware & Static (🚀 supports large patterns)
// ============================================================
app.use(cors());
app.use(express.json({ limit: "50mb" })); // large pattern-safe
app.use(express.urlencoded({ limit: "50mb", extended: true }));
app.use(express.static("public"));

// Optional: Reject absurdly large uploads (>50MB)
app.use((req, res, next) => {
  const len = parseInt(req.headers["content-length"] || "0", 10);
  if (len > 50 * 1024 * 1024) {
    return res.status(413).json({ error: "❌ Pattern too large (max 50MB)" });
  }
  next();
});

// ============================================================
// Executable Detection
// ============================================================
const exeName =
  process.platform === "win32" ? "patternlocatorx.exe" : "patternlocatorx";
const EXE_PATH = path.join(__dirname, exeName);

if (process.platform !== "win32") {
  try {
    fs.chmodSync(EXE_PATH, 0o755);
    console.log("✔ patternlocatorx marked as executable");
  } catch (err) {
    console.warn("⚠️ chmod failed:", err.message);
  }
}

// Pattern log directory
const PATTERN_DIR = path.join(__dirname, "Pattern-log");
if (!fs.existsSync(PATTERN_DIR)) fs.mkdirSync(PATTERN_DIR, { recursive: true });

// ============================================================
// Global Tracking
// ============================================================
let connectedUsers = 0;
let activeSearches = 0;
const globalClients = new Set();
const activeProcesses = new Map();

// ============================================================
// Global SSE Endpoint
// ============================================================
app.get("/global", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  connectedUsers++;
  globalClients.add(res);
  broadcastGlobalStatus();

  req.on("close", () => {
    connectedUsers--;
    globalClients.delete(res);
    broadcastGlobalStatus();
  });
});

function broadcastGlobalStatus() {
  const msg = `data: ${JSON.stringify({
    connectedUsers,
    activeSearches,
  })}\n\n`;
  for (const client of globalClients) {
    try {
      client.write(msg);
    } catch {}
  }
}

// ============================================================
// SSE Endpoint for per-search output
// ============================================================
app.get("/api/search/:id", (req, res) => {
  const searchId = req.params.id;
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  res.write(`data: ${JSON.stringify({ type: "connected", searchId })}\n\n`);

  if (!activeProcesses.has(searchId))
    activeProcesses.set(searchId, { clients: [], buffer: [] });
  activeProcesses.get(searchId).clients.push(res);

  req.on("close", () => {
    const info = activeProcesses.get(searchId);
    if (info) {
      info.clients = info.clients.filter((c) => c !== res);
      if (info.clients.length === 0 && info.child) {
        info.child.kill();
        activeProcesses.delete(searchId);
        activeSearches = Math.max(0, activeSearches - 1);
        broadcastGlobalStatus();
      }
    }
  });
});

// ============================================================
// Start Search
// ============================================================
app.post("/api/search/start", (req, res) => {
  try {
    const { seed, range, startX, startZ, dimension, directions, pattern } =
      req.body;

    if (!seed) return res.status(400).json({ error: "Seed is required" });

    const searchId = Date.now().toString();
    const rangeVal = parseInt(range || "1000", 10);

    if (rangeVal > 3000)
      return res
        .status(400)
        .json({ error: `❌ Range exceeds maximum (3000): ${rangeVal}` });

    if (activeSearches >= 10)
      return res
        .status(429)
        .json({ error: "Too many concurrent searches. Try again later." });

    // Handle pattern safely
    let patternFile = null;
    if (pattern && typeof pattern === "string" && pattern.trim()) {
      patternFile = path.join(PATTERN_DIR, `pattern_${searchId}.txt`);
      fs.writeFileSync(patternFile, pattern, "utf8");
      console.log(`[OK] Pattern file created: ${patternFile} (${pattern.length} bytes)`);
    } else {
      console.warn("[WARN] Empty or invalid pattern input");
    }

    // Build args
    const args = [seed, rangeVal.toString(), startX || "0", startZ || "0"];
    if (patternFile) args.push(patternFile);

    let dirs = directions;
    if (typeof dirs === "string") dirs = dirs.trim().split(/\s+/);
    if (!Array.isArray(dirs) || dirs.length === 0) dirs = ["all"];
    args.push(dirs.join(""));
    args.push(dimension || "overworld");

    res.json({ searchId, status: "started" });
    console.log(`[INFO] Starting search ${searchId}`);
    activeSearches++;
    broadcastGlobalStatus();

    setTimeout(() => startZigProcess(searchId, args, patternFile), 100);
  } catch (err) {
    console.error(`[ERROR] /api/search/start: ${err.stack || err.message}`);
    if (!res.headersSent) res.status(500).json({ error: err.message });
  }
});

// ============================================================
// Stop Search
// ============================================================
app.post("/api/search/stop/:id", (req, res) => {
  const searchId = req.params.id;
  const info = activeProcesses.get(searchId);
  if (info && info.child) {
    info.child.kill();
    broadcast(searchId, { type: "stopped", message: "Search stopped by user" });
    activeProcesses.delete(searchId);
    activeSearches = Math.max(0, activeSearches - 1);
    broadcastGlobalStatus();
    return res.json({ status: "stopped" });
  }
  res.status(404).json({ error: "Search not found" });
});

// ============================================================
// Zig Process with Batched SSE + Color Detection
// ============================================================
function startZigProcess(searchId, args, patternFile) {
  const info = activeProcesses.get(searchId) || { clients: [], buffer: [] };

  broadcast(searchId, {
    type: "log",
    level: "info",
    message: `Launching: ${EXE_PATH} ${args.join(" ")}`,
  });

  try {
    const child = spawn(EXE_PATH, args, {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });

    info.child = child;
    info.buffer = [];
    activeProcesses.set(searchId, info);

    // Flush buffer every 500ms
    info.flushInterval = setInterval(() => flushBuffer(searchId), 500);

    // Auto-timeout 60s
    const timeout = setTimeout(() => {
      if (activeProcesses.has(searchId)) {
        broadcast(searchId, {
          type: "stopped",
          message: "⏰ Search timed out after 60s",
        });
        child.kill();
        clearInterval(info.flushInterval);
        activeProcesses.delete(searchId);
        activeSearches = Math.max(0, activeSearches - 1);
        broadcastGlobalStatus();
      }
    }, 60000);

    // stdout / stderr handling
    child.stdout.on("data", (data) => bufferOutput(searchId, data.toString()));
    child.stderr.on("data", (data) =>
      bufferOutput(searchId, data.toString(), true)
    );

    child.on("close", (code) => {
      clearTimeout(timeout);
      clearInterval(info.flushInterval);
      flushBuffer(searchId);
      broadcast(searchId, {
        type: "complete",
        exitCode: code,
        message:
          code === 0
            ? "✅ Search completed successfully"
            : `⚠️ Exited with code ${code}`,
      });
      activeSearches = Math.max(0, activeSearches - 1);
      broadcastGlobalStatus();
      if (patternFile && fs.existsSync(patternFile))
        fs.unlink(patternFile, () => {});
      setTimeout(() => activeProcesses.delete(searchId), 3000);
    });
  } catch (err) {
    broadcast(searchId, {
      type: "error",
      message: `Failed to run EXE: ${err.message}`,
    });
  }
}

// ============================================================
// Buffer & Flush (smart log color detection)
// ============================================================
function bufferOutput(searchId, data, isError = false) {
  const info = activeProcesses.get(searchId);
  if (!info) return;
  const lines = data.split("\n").filter((l) => l.trim());
  for (const line of lines) {
    info.buffer.push({
      msg: line.trim(),
      level: detectLevel(line, isError),
    });
    if (info.buffer.length > 200) info.buffer.shift();
  }
}

function flushBuffer(searchId) {
  const info = activeProcesses.get(searchId);
  if (!info || !info.buffer || info.buffer.length === 0) return;
  const logs = info.buffer.splice(0, info.buffer.length);
  for (const l of logs) {
    broadcast(searchId, { type: "log", level: l.level, message: l.msg });
  }
}

function detectLevel(line, isError) {
  const lower = line.toLowerCase();
  if (isError || lower.includes("error") || lower.includes("fail")) return "error";
  if (lower.includes("found") || lower.includes("success")) return "success";
  if (lower.includes("progress") || lower.includes("%")) return "warning";
  if (lower.includes("start") || lower.includes("launch")) return "info";
  if (lower.includes("complete") || lower.includes("done")) return "success";
  return "info";
}

// ============================================================
// SSE Broadcast Helper
// ============================================================
function broadcast(searchId, data) {
  const info = activeProcesses.get(searchId);
  if (!info) return;
  const msg = `data: ${JSON.stringify(data)}\n\n`;
  for (const client of info.clients || []) {
    try {
      client.write(msg);
    } catch {}
  }
}

// ============================================================
// Health Check
// ============================================================
app.get("/api/health", (req, res) => {
  res.json({
    status: "ok",
    exeExists: fs.existsSync(EXE_PATH),
    active: activeProcesses.size,
    users: connectedUsers,
    searches: activeSearches,
  });
});

// ============================================================
// Start Server
// ============================================================
app.listen(PORT, () => {
  console.log("===========================================");
  console.log("   🌍 PatternLocatorX - Global Web Server");
  console.log("===========================================");
  console.log(`Server running on port ${PORT}`);
  console.log(`Executable: ${EXE_PATH}`);
  console.log("===========================================");
});

// ============================================================
// Graceful Shutdown
// ============================================================
function shutdown() {
  console.log("Gracefully shutting down...");
  activeProcesses.forEach((p) => {
    clearInterval(p.flushInterval);
    if (p.child) {
      try {
        p.child.kill();
      } catch {}
    }
  });
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
