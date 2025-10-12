//-----------------------------------------------
// Copyright (c) 2025 ICshX
// Licensed under the MIT License – see LICENSE
// Multi-threaded Version - Optimized + Output Throttled
// Added output batching (10 lines per flush) to prevent lag
//-----------------------------------------------
const std = @import("std");
const bedrock = @import("bedrock.zig");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;

// Pattern struct for flexible sizes
const FlexiblePattern = struct {
    data: [][]u8,
    rows: usize,
    cols: usize,

    fn get(self: FlexiblePattern, row: usize, col: usize) u8 {
        if (row >= self.rows) return 2;
        if (col >= self.data[row].len) return 2;
        return self.data[row][col];
    }

    fn deinit(self: FlexiblePattern, allocator: std.mem.Allocator) void {
        for (self.data) |row| allocator.free(row);
        allocator.free(self.data);
    }
};

// Create pattern from string lines
fn createPatternFromString(allocator: std.mem.Allocator, pattern_str: []const []const u8) !FlexiblePattern {
    var pattern_data = try allocator.alloc([]u8, pattern_str.len);
    var max_cols: usize = 0;

    for (pattern_str) |row_str, i| {
        pattern_data[i] = try allocator.alloc(u8, row_str.len);
        max_cols = @max(max_cols, row_str.len);
        for (row_str) |char, j| {
            pattern_data[i][j] = switch (char) {
                '0' => 0,
                '1' => 1,
                ' ', '.' => 2,
                else => 2,
            };
        }
    }

    return FlexiblePattern{ .data = pattern_data, .rows = pattern_str.len, .cols = max_cols };
}

const directions = [_][]const u8{ "North", "East", "South", "West" };

const HeightRange = struct {
    start_y: i32,
    end_y: i32,
};

fn getHeightRange(dimension: []const u8) HeightRange {
    if (std.mem.eql(u8, dimension, "overworld"))
        return .{ .start_y = -60, .end_y = -60 };
    if (std.mem.eql(u8, dimension, "netherfloor"))
        return .{ .start_y = 4, .end_y = 4 };
    if (std.mem.eql(u8, dimension, "netherceiling"))
        return .{ .start_y = 123, .end_y = 123 };
    return .{ .start_y = -60, .end_y = -60 };
}

fn formatDuration(seconds: f64) void {
    if (seconds < 1.0)
        std.debug.print("{}ms", .{@floatToInt(u32, seconds * 1000.0)})
    else if (seconds < 60.0)
        std.debug.print("{}s", .{@floatToInt(u32, seconds)})
    else
        std.debug.print("{}m", .{@floatToInt(u32, seconds / 60.0)});
}

// ============================================================
// Slow output buffer (anti-lag batching system)
// ============================================================
const OUTPUT_BATCH = 10;
const OUTPUT_DELAY_MS = 50;
var output_counter: Atomic(u32) = Atomic(u32).init(0);

fn slowPrint(out: anytype, msg: []const u8) void {
    out.print("{s}\n", .{msg}) catch {};
    const count = output_counter.fetchAdd(1, .SeqCst);
    if ((count % OUTPUT_BATCH) == 0) {
        std.time.sleep(OUTPUT_DELAY_MS * std.time.ns_per_ms);
    }
}

// ============================================================
const ThreadTask = struct {
    start_x: i32,
    end_x: i32,
    start_z: i32,
    end_z: i32,
    height_range: HeightRange,
    generator: bedrock.GradientGenerator,
    pattern: []const []const []const ?bedrock.Block,
    ctx: *SearchContext,
};

fn searchWorker(task: ThreadTask) void {
    var finder = bedrock.PatternFinder{ .gen = task.generator, .pattern = task.pattern };
    const BLOCK_SIZE = 512;
    var current_x = task.start_x;
    while (current_x <= task.end_x) : (current_x += BLOCK_SIZE) {
        const block_end_x = @min(current_x + BLOCK_SIZE - 1, task.end_x);
        finder.search(
            .{ .x = current_x, .y = task.height_range.start_y, .z = task.start_z },
            .{ .x = block_end_x, .y = task.height_range.end_y, .z = task.end_z },
            task.ctx,
            reportResult,
            reportProgressThreaded,
        );
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    std.debug.assert(args.skip());

    const seed_str = args.next() orelse {
        std.debug.print("Usage: bedrock_finder <seed> [range] ...\n", .{});
        return;
    };

    var range: i32 = 1000;
    if (args.next()) |r| range = std.fmt.parseInt(i32, r, 10) catch range;
    if (range > 2500) {
        std.debug.print("❌ Range too large: {}\n", .{range});
        return;
    }

    const start_x = std.fmt.parseInt(i32, args.next() orelse "0", 10) catch 0;
    const start_z = std.fmt.parseInt(i32, args.next() orelse "0", 10) catch 0;
    const pattern_path = args.next();
    const dirs = args.next() orelse "all";
    const dim = args.next() orelse "overworld";
    const seed = try std.fmt.parseInt(i64, seed_str, 10);

    const generator = if (std.mem.eql(u8, dim, "overworld"))
        bedrock.GradientGenerator.overworldFloor(seed)
    else if (std.mem.eql(u8, dim, "netherfloor"))
        bedrock.GradientGenerator.netherFloor(seed)
    else
        bedrock.GradientGenerator.netherCeiling(seed);

    var pattern: FlexiblePattern = undefined;
    if (pattern_path) |pf| {
        var file = try std.fs.cwd().readFileAlloc(allocator, pf, 1_000_000);
        defer allocator.free(file);
        var lines = std.mem.split(u8, file, "\n");
        var list = std.ArrayList([]const u8).init(allocator);
        defer list.deinit();
        while (lines.next()) |l| try list.append(l);
        pattern = try createPatternFromString(allocator, list.items);
    } else {
        const def = [_][]const u8{ "101", "010", "101" };
        pattern = try createPatternFromString(allocator, &def);
    }
    defer pattern.deinit(allocator);

    const height_range = getHeightRange(dim);

    const threads = std.os.cpu_count() catch 1;
    const start_time = std.time.milliTimestamp();
    var total_found: u32 = 0;

    std.debug.print("\n=== PatternLocatorX (Slow Mode x10) ===\n", .{});
    std.debug.print("Seed: {} | Range: {}\n", .{ seed, range });
    std.debug.print("Threads: {}\n", .{ threads });
    std.debug.print("Dimension: {s}\n", .{ dim });
    std.debug.print("=====================================\n", .{});

    const global_start_x = start_x - range;
    const global_end_x = start_x + range;
    const global_start_z = start_z - range;
    const global_end_z = start_z + range;

    const pattern3d = try createPattern3DFromFlexible(allocator, pattern);
    defer pattern3d.deinit(allocator);

    var ctx = SearchContext{
        .direction = "all",
        .rotation = 0,
        .found_count = 0,
        .start_time = start_time,
        .global_start_time = start_time,
        .direction_total = 0,
        .global_total = 0,
        .global_completed = Atomic(u64).init(0),
        .direction_number = 0,
        .mutex = Mutex{},
        .last_print_time = Atomic(i64).init(0),
    };

    var t: usize = 0;
    var handles = try allocator.alloc(Thread, threads);
    defer allocator.free(handles);
    const chunk = (global_end_x - global_start_x + 1) / @intCast(i32, threads);

    while (t < threads) : (t += 1) {
        const sx = global_start_x + @intCast(i32, t) * chunk;
        const ex = if (t == threads - 1) global_end_x else sx + chunk - 1;

        var task = ThreadTask{
            .start_x = sx,
            .end_x = ex,
            .start_z = global_start_z,
            .end_z = global_end_z,
            .height_range = height_range,
            .generator = generator,
            .pattern = pattern3d.pattern,
            .ctx = &ctx,
        };
        handles[t] = try Thread.spawn(.{}, searchWorker, .{ task });
    }

    for (handles) |h| h.join();

    const end_time = std.time.milliTimestamp();
    const total_duration = @intToFloat(f64, end_time - start_time) / 1000.0;

    std.debug.print("\n=====================================\n", .{});
    std.debug.print(" Search complete.\n", .{});
    std.debug.print(" Total found: {}\n", .{ ctx.found_count });
    std.debug.print(" Elapsed: ", .{});
    formatDuration(total_duration);
    std.debug.print("\n=====================================\n", .{});
}

// ============================================================
// Context & Helpers
// ============================================================
const SearchContext = struct {
    direction: []const u8,
    rotation: usize,
    found_count: u32,
    start_time: i64,
    global_start_time: i64,
    direction_total: u64,
    global_total: u64,
    global_completed: Atomic(u64),
    direction_number: usize,
    mutex: Mutex,
    last_print_time: Atomic(i64),
};

fn reportProgressThreaded(_: *SearchContext, _: u64, _: u64) void {}

fn reportResult(ctx: *SearchContext, p: bedrock.Point) void {
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.found_count += 1;

    const out = std.io.getStdOut().writer();
    var buffer: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buffer, ">>> FOUND! {d} {d} {d}", .{ p.x, p.y, p.z }) catch return;
    slowPrint(out, msg);
}

fn rotateOnce(allocator: std.mem.Allocator, input: FlexiblePattern) !FlexiblePattern {
    const new_rows = input.cols;
    const new_cols = input.rows;
    var new_data = try allocator.alloc([]u8, new_rows);
    for (new_data) |*row, i| {
        row.* = try allocator.alloc(u8, new_cols);
        var jj: usize = 0;
        while (jj < new_cols) : (jj += 1) {
            const old_row = input.rows - 1 - jj;
            const old_col = i;
            row.*[jj] = input.get(old_row, old_col);
        }
    }
    return FlexiblePattern{ .data = new_data, .rows = new_rows, .cols = new_cols };
}

const Pattern3D = struct {
    bedrock_rows: [][]?bedrock.Block,
    row_slices: [][]const ?bedrock.Block,
    layer: [][]const []const ?bedrock.Block,
    pattern: []const []const []const ?bedrock.Block,
    fn deinit(self: Pattern3D, allocator: std.mem.Allocator) void {
        for (self.bedrock_rows) |r| allocator.free(r);
        allocator.free(self.bedrock_rows);
        allocator.free(self.row_slices);
        allocator.free(self.layer);
    }
};

fn createPattern3DFromFlexible(allocator: std.mem.Allocator, flex: FlexiblePattern) !Pattern3D {
    var rows = try allocator.alloc([]?bedrock.Block, flex.rows);
    for (rows) |*row, i| {
        row.* = try allocator.alloc(?bedrock.Block, flex.cols);
        for (row.*) |*cell, j| {
            const val = flex.get(i, j);
            cell.* = if (val == 1) bedrock.Block.bedrock else null;
        }
    }

    var slices = try allocator.alloc([]const ?bedrock.Block, flex.rows);
    for (slices) |*slice, i| slice.* = rows[i];

    var layer = try allocator.alloc([]const []const ?bedrock.Block, 1);
    layer[0] = slices;

    return Pattern3D{
        .bedrock_rows = rows,
        .row_slices = slices,
        .layer = layer,
        .pattern = layer,
    };
}

fn printFlexiblePattern(flex: FlexiblePattern) void {
    for (flex.data) |row| {
        for (row) |v| if (v != 2) std.debug.print("{} ", .{v}) else std.debug.print("  ", .{});
        std.debug.print("\n", .{});
    }
}
