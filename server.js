// ============================================================
// PatternLocatorX - Global Web Server (Optimized Non-Lag Version)
// ============================================================
// © 2025 ICshX | MIT License
// - Batched SSE output (anti-lag, 500ms flush)
// - Auto-timeout (60s)
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
// Middleware & Static
// ============================================================
app.use(cors());
app.use(express.json());
app.use(express.static("public"));

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
// Global SSE Endpoint (for worldwide live usage)
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
// SSE Endpoint for search updates
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
// Start Search Request
// ============================================================
app.post("/api/search/start", (req, res) => {
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

  try {
    // Pattern file creation
    let patternFile = null;
    if (pattern && pattern.trim()) {
      patternFile = path.join(PATTERN_DIR, `pattern_${searchId}.txt`);
      fs.writeFileSync(patternFile, pattern, "utf8");
      console.log(`[OK] Pattern file created: ${patternFile}`);
    }

    // Build arguments
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
// Start Zig Process with Timeout + Buffered SSE
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

    // flush buffer every 500ms to prevent lag
    info.flushInterval = setInterval(() => {
      if (!info.buffer || info.buffer.length === 0) return;
      const joined = info.buffer.splice(0, info.buffer.length).join("\n");
      broadcast(searchId, { type: "log", level: "info", message: joined });
    }, 500);

    // ⏱️ Auto-stop after 60s
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

    // stdout / stderr
    child.stdout.on("data", (data) =>
      bufferOutput(searchId, data.toString(), "info")
    );
    child.stderr.on("data", (data) =>
      bufferOutput(searchId, data.toString(), "error")
    );

    child.on("close", (code) => {
      clearTimeout(timeout);
      clearInterval(info.flushInterval);
      flushImmediate(searchId);
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
      if (patternFile && fs.existsSync(patternFile)) fs.unlink(patternFile, () => {});
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
// Buffered Output (anti-lag)
// ============================================================
function bufferOutput(searchId, data, level) {
  const info = activeProcesses.get(searchId);
  if (!info) return;
  const lines = data.split("\n").filter((l) => l.trim());
  for (const line of lines) {
    info.buffer.push(line);
    if (info.buffer.length > 100) info.buffer.shift(); // prevent runaway memory
  }
}

function flushImmediate(searchId) {
  const info = activeProcesses.get(searchId);
  if (!info || !info.buffer || info.buffer.length === 0) return;
  const joined = info.buffer.splice(0, info.buffer.length).join("\n");
  broadcast(searchId, { type: "log", level: "info", message: joined });
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
