// =====================
// PatternLocatorX Web Server (Render-ready)
// =====================
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

// Directories
const PATTERN_DIR = path.join(__dirname, "Pattern-log");
if (!fs.existsSync(PATTERN_DIR)) fs.mkdirSync(PATTERN_DIR, { recursive: true });

// Path to prebuilt Zig executable
const EXE_PATH = path.join(__dirname, "patternlocatorx.exe");

// Active processes (searchId → { child, clients })
const activeProcesses = new Map();

// =====================
// SSE Endpoint
// =====================
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
      }
    }
  });
});

// =====================
// Start Search
// =====================
app.post("/api/search/start", (req, res) => {
  const { seed, range, startX, startZ, dimension, directions, pattern } = req.body;
  if (!seed) return res.status(400).json({ error: "Seed is required" });

  const searchId = Date.now().toString();

  try {
    // Write pattern file (if given)
    let patternFile = null;
    if (pattern && pattern.trim()) {
      patternFile = path.join(PATTERN_DIR, `pattern_${searchId}.txt`);
      fs.writeFileSync(patternFile, pattern, "utf8");
      console.log(`[OK] Pattern file created: ${patternFile}`);
    }

    // --- Arguments for .exe ---
    const args = [seed, range || "10000", startX || "0", startZ || "0"];
    if (patternFile) args.push(patternFile);

    // Directions
    let dirs = directions;
    if (typeof dirs === "string") dirs = dirs.trim().split(/\s+/);
    if (!Array.isArray(dirs) || dirs.length === 0) dirs = ["all"];
    args.push(dirs.join(" "));

    args.push(dimension || "overworld");

    // Respond immediately to client
    res.json({ searchId, status: "started" });
    console.log(`[INFO] Search started (${searchId})`);

    setTimeout(() => startZigProcess(searchId, args), 50);
  } catch (err) {
    console.error(`[ERROR] /api/search/start: ${err.stack || err.message}`);
    if (!res.headersSent) res.status(500).json({ error: err.message });
  }
});

// =====================
// Stop Search
// =====================
app.post("/api/search/stop/:id", (req, res) => {
  const searchId = req.params.id;
  const info = activeProcesses.get(searchId);
  if (info && info.child) {
    info.child.kill();
    broadcast(searchId, { type: "stopped", message: "Search stopped by user" });
    activeProcesses.delete(searchId);
    res.json({ status: "stopped" });
  } else res.status(404).json({ error: "Search not found" });
});

// =====================
// Start process (.exe)
// =====================
function startZigProcess(searchId, args) {
  const info = activeProcesses.get(searchId) || { clients: [] };
  broadcast(searchId, { type: "log", level: "info", message: `Launching: ${EXE_PATH} ${args.join(" ")}` });

  try {
    const child = spawn(EXE_PATH, args, {
      cwd: __dirname,
      stdio: ["ignore", "pipe", "pipe"],
    });

    info.child = child;
    activeProcesses.set(searchId, info);

    child.stdout.on("data", (data) => parseAndBroadcast(searchId, data.toString(), "info"));
    child.stderr.on("data", (data) => parseAndBroadcast(searchId, data.toString(), "error"));

    child.on("close", (code) => {
      broadcast(searchId, {
        type: "complete",
        exitCode: code,
        message: code === 0 ? "Search completed successfully" : `Exited with code ${code}`,
      });
      setTimeout(() => activeProcesses.delete(searchId), 3000);
    });
  } catch (error) {
    broadcast(searchId, { type: "error", message: `Failed to run EXE: ${error.message}` });
  }
}

// =====================
// Parse Output & Broadcast
// =====================
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

// =====================
// Broadcast to all clients
// =====================
function broadcast(searchId, data) {
  const info = activeProcesses.get(searchId);
  if (!info) return;
  const msg = `data: ${JSON.stringify(data)}\n\n`;
  for (const client of info.clients) {
    try { client.write(msg); } catch {}
  }
}

// =====================
// Health check
// =====================
app.get("/api/health", (req, res) => {
  res.json({
    status: "ok",
    exeExists: fs.existsSync(EXE_PATH),
    active: activeProcesses.size,
  });
});

// =====================
// Start server
// =====================
app.listen(PORT, () => {
  console.log("===========================================");
  console.log("   PatternLocatorX - Render Web Server");
  console.log("===========================================");
  console.log(`Server running on port ${PORT}`);
  console.log(`Executable: ${EXE_PATH}`);
  console.log("===========================================");
});

// =====================
// Graceful shutdown
// =====================
process.on("SIGTERM", () => {
  console.log("Gracefully shutting down...");
  activeProcesses.forEach((p) => p.child && p.child.kill());
  process.exit(0);
});
