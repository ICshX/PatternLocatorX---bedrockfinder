const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const cors = require('cors');

const app = express();
const PORT = 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// =====================
// Zig Configuration
// =====================
function findZigPath() {
    if (process.env.ZIG_PATH) return process.env.ZIG_PATH;

    const commonPaths = [
        'C:\\zig\\zig.exe',
        'C:\\Program Files\\zig\\zig.exe',
        path.join(process.env.USERPROFILE || '', 'zig', 'zig.exe'),
        path.join(__dirname, 'zig', 'zig.exe'),
        'zig'
    ];

    for (const zigPath of commonPaths) {
        try {
            if (fs.existsSync(zigPath)) return zigPath;
        } catch {}
    }
    return 'zig';
}

const ZIG_PATH = findZigPath();
const MAIN_ZIG_PATH = process.env.MAIN_ZIG_PATH || path.join(__dirname, 'main.zig');

// Directories
const PATTERN_DIR = path.join(__dirname, 'Pattern-log');
if (!fs.existsSync(PATTERN_DIR)) fs.mkdirSync(PATTERN_DIR, { recursive: true });

const ZIG_BUILD_DIR = path.join(__dirname, 'zig-build');
if (!fs.existsSync(ZIG_BUILD_DIR)) fs.mkdirSync(ZIG_BUILD_DIR, { recursive: true });

// Active processes
const activeProcesses = new Map();

// =====================
// SSE Endpoint
// =====================
app.get('/api/search/:id', (req, res) => {
    const searchId = req.params.id;
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.write(`data: ${JSON.stringify({ type: 'connected', searchId })}\n\n`);

    if (!activeProcesses.has(searchId)) activeProcesses.set(searchId, { clients: [] });
    activeProcesses.get(searchId).clients.push(res);

    req.on('close', () => {
        const processInfo = activeProcesses.get(searchId);
        if (processInfo) {
            processInfo.clients = processInfo.clients.filter(c => c !== res);
            if (processInfo.clients.length === 0 && processInfo.child) {
                processInfo.child.kill();
                activeProcesses.delete(searchId);
            }
        }
    });
});

// =====================
// Start Search
// =====================
app.post('/api/search/start', (req, res) => {
    const { seed, range, startX, startZ, dimension, directions, pattern } = req.body;
    if (!seed) return res.status(400).json({ error: 'Seed is required' });

    const searchId = Date.now().toString();

    try {
        // --- Pattern-Datei schreiben ---
        let patternFile = null;
        if (pattern && pattern.trim()) {
            patternFile = path.join(PATTERN_DIR, `pattern_${searchId}.txt`);
            fs.writeFileSync(patternFile, pattern, 'utf8');
            console.log(`[OK] Pattern-Datei geschrieben: ${patternFile}`);
        }

        // --- Argumente für Zig ---
        const args = ['run', MAIN_ZIG_PATH, '-O', 'ReleaseFast', '--'];
        args.push(seed);
        args.push(range || '10000');
        args.push(startX || '0');
        args.push(startZ || '0');

        if (patternFile) args.push(patternFile);

        // Directions robust
        let dirs = directions;
        if (typeof dirs === 'string') dirs = dirs.trim().split(/\s+/);
        if (!Array.isArray(dirs) || dirs.length === 0) dirs = ['all'];
        args.push(dirs.join(' '));

        args.push(dimension || 'overworld');

        // --- Sofort an Client ---
        res.json({ searchId, status: 'started' });
        console.log(`[INFO] Suche gestartet: ${searchId}`);

        setTimeout(() => startZigProcess(searchId, args, patternFile, ZIG_BUILD_DIR), 50);

    } catch (err) {
        console.error(`[ERROR] /api/search/start: ${err.stack || err.message}`);
        if (!res.headersSent) res.status(500).json({ error: err.message });
    }
});

// =====================
// Stop Search
// =====================
app.post('/api/search/stop/:id', (req, res) => {
    const searchId = req.params.id;
    const processInfo = activeProcesses.get(searchId);

    if (processInfo && processInfo.child) {
        processInfo.child.kill();
        broadcast(searchId, { type: 'stopped', message: 'Search stopped by user' });
        activeProcesses.delete(searchId);
        res.json({ status: 'stopped' });
    } else res.status(404).json({ error: 'Search not found' });
});

// =====================
// Start Zig Process
// =====================
function startZigProcess(searchId, args, patternFile, cwd) {
    const processInfo = activeProcesses.get(searchId) || { clients: [] };
    broadcast(searchId, { type: 'log', level: 'info', message: `Starting Zig search: ${ZIG_PATH} ${args.join(' ')}` });

    try {
        const child = spawn(ZIG_PATH, args, {
            cwd,
            stdio: ['ignore', 'pipe', 'pipe'],
            detached: false
        });

        processInfo.child = child;
        activeProcesses.set(searchId, processInfo);

        child.stdout.on('data', data => parseAndBroadcast(searchId, data.toString(), 'info'));
        child.stderr.on('data', data => parseAndBroadcast(searchId, data.toString(), 'error'));

        child.on('close', code => {
            broadcast(searchId, {
                type: 'complete',
                exitCode: code,
                message: code === 0 ? 'Search completed successfully' : `Search ended with code ${code}`
            });

            // ⚠ Pattern-Datei bleibt persistent!
            setTimeout(() => activeProcesses.delete(searchId), 5000);
        });

        child.on('error', error => {
            broadcast(searchId, {
                type: 'error',
                message: `Failed to start Zig process: ${error.message}`,
                suggestion: 'Make sure Zig is installed and the path is correct'
            });
        });

    } catch (error) {
        broadcast(searchId, { type: 'error', message: `Failed to spawn Zig: ${error.message}` });
    }
}

// =====================
// Parse Output and Broadcast
// =====================
function parseAndBroadcast(searchId, output, defaultLevel = 'info') {
    const lines = output.split('\n');
    for (const line of lines) {
        if (!line.trim()) continue;
        let level = defaultLevel;
        if (line.includes('FOUND!')) level = 'success';
        else if (line.includes('ERROR') || line.includes('error:')) level = 'error';
        else if (line.includes('WARNING') || line.includes('warning:')) level = 'warning';
        else if (line.includes('Progress:') || line.includes('%')) level = 'progress';
        else if (line.includes('===')) level = 'separator';
        broadcast(searchId, { type: 'log', level, message: line });
    }
}

// =====================
// Broadcast to all clients
// =====================
function broadcast(searchId, data) {
    const processInfo = activeProcesses.get(searchId);
    if (!processInfo) return;
    const message = `data: ${JSON.stringify(data)}\n\n`;
    processInfo.clients.forEach(client => {
        try { client.write(message); } catch {}
    });
}

// =====================
// Health Check
// =====================
app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        zigPath: ZIG_PATH,
        mainZigPath: MAIN_ZIG_PATH,
        activeSearches: activeProcesses.size
    });
});

// =====================
// Start Server
// =====================
app.listen(PORT, () => {
    console.log('===========================================');
    console.log('   PatternLocatorX Server');
    console.log('===========================================');
    console.log(`Server running on http://localhost:${PORT}`);
    console.log(`Zig path: ${ZIG_PATH}`);
    console.log(`Main.zig path: ${MAIN_ZIG_PATH}`);
    console.log('===========================================');
});

// =====================
// Graceful Shutdown
// =====================
process.on('SIGTERM', () => {
    console.log('Shutting down gracefully...');
    activeProcesses.forEach(proc => { if (proc.child) proc.child.kill(); });
    process.exit(0);
});
