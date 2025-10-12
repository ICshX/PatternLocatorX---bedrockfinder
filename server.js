// ============================================================
// PatternLocatorX - Global Web Server (Render + Local Ready)
// ============================================================
// © 2025 ICshX | MIT License
// Supports global usage tracking, safe process management,
// and cross-platform binary handling.
// ============================================================

const express = require("express");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const cors = require("cors");

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static("public"));

// ============================================================
// Executable detection & setup
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
// Global tracking
// ============================================================
let connectedUsers = 0;
let activeSearches = 0;
const globalClients = new Set();

// ============================================================
// Active search processes
// ============================================================
const activeProcesses = new Map();

// ============================================================
// Global status SSE endpoint (for world-wide users)
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
// SSE Endpoint for each search process
// ============================================================
app.get("/api/search/:id", (req, res) => {
  const searchId = req.params.id;
  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders();

  res.write(`data: ${JSON.stringify({ type: "connected", searchId })}\n\n`);

  if (!activeProcesses.has(searchId))
    activeProcesses.set(searchId, { clients: [] });
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
// Start search
// ============================================================
app.post("/api/search/start", (req, res) => {
  const { seed, range, startX, startZ, dimension, directions, pattern } = req.body;
  if (!seed) return res.status(400).json({ error: "Seed is required" });

  const searchId = Date.now().toString();
  const rangeVal = parseInt(range || "10000", 10);

  if (rangeVal > 10000) {
    return res
      .status(400)
      .json({ error: `❌ Range exceeds maximum (10000): ${rangeVal}` });
  }

  if (activeSearches >= 10) {
    return res
      .status(429)
      .json({ error: "Too many concurrent searches. Try again later." });
  }

  try {
    // Write pattern file
    let patternFile = null;
    if (pattern && pattern.trim()) {
      patternFile = path.join(PATTERN_DIR, `pattern_${searchId}.txt`);
      fs.writeFileSync(patternFile, pattern, "utf8");
      console.log(`[OK] Pattern file created: ${patternFile}`);
    }

    // Arguments for the executable
    const args = [seed, rangeVal.toString(), startX || "0", startZ || "0"];
    if (patternFile) args.push(patternFile);

    let dirs = directions;
    if (typeof dirs === "string") dirs = dirs.trim().split(/\s+/);
    if (!Array.isArray(dirs) || dirs.length === 0) dirs = ["all"];
    args.push(dirs.join(" "));
    args.push(dimension || "overworld");

    res.json({ searchId, status: "started" });
    console.log(`[INFO] Starting search ${searchId}`);

    activeSearches++;
    broadcastGlobalStatus();
    setTimeout(() => startZigProcess(searchId, args), 100);
  } catch (err) {
    console.error(`[ERROR] /api/search/start: ${err.stack || err.message}`);
    if (!res.headersSent) res.status(500).json({ error: err.message });
  }
});

// ============================================================
// Stop search
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
// Run the Zig executable
// ============================================================
function startZigProcess(searchId, args) {
  const info = activeProcesses.get(searchId) || { clients: [] };
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
    activeProcesses.set(searchId, info);

    child.stdout.on("data", (data) =>
      parseAndBroadcast(searchId, data.toString(), "info")
    );
    child.stderr.on("data", (data) =>
      parseAndBroadcast(searchId, data.toString(), "error")
    );

    child.on("close", (code) => {
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
      setTimeout(() => activeProcesses.delete(searchId), 3000);
    });
  } catch (error) {
    broadcast(searchId, {
      type: "error",
      message: `Failed to run EXE: ${error.message}`,
    });
  }
}

// ============================================================
// Parse and broadcast process output
// ============================================================
function parseAndBroadcast(searchId, output, defaultLevel = "info") {
  const lines = output.split("\n");
  for (const line of lines) {
    if (!line.trim()) continue;
    let level = defaultLevel;
    if (line.includes("FOUND!")) level = "success";
    else if (line.includes("error")) level = "error";
    else if (line.includes("Progress")) level = "progress";
    broadcast(searchId, { type: "log", level, message: line.trim() });
  }
}

// ============================================================
// Broadcast to all clients of one search
// ============================================================
function broadcast(searchId, data) {
  const info = activeProcesses.get(searchId);
  if (!info) return;
  const msg = `data: ${JSON.stringify(data)}\n\n`;
  for (const client of info.clients) {
    try {
      client.write(msg);
    } catch {}
  }
}

// ============================================================
// Health check
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
// Start server
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
// Graceful shutdown
// ============================================================
process.on("SIGTERM", () => {
  console.log("Gracefully shutting down...");
  activeProcesses.forEach((p) => p.child && p.child.kill());
  process.exit(0);
});
