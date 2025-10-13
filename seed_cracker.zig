//-----------------------------------------------
// Copyright (c) 2025 ICshX - Seed Cracker Edition
// Licensed under the MIT License – see LICENSE
// Bruteforce seed from coordinates + bedrock pattern
//-----------------------------------------------
const std = @import("std");
const bedrock = @import("bedrock.zig");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;

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

    return FlexiblePattern{
        .data = pattern_data,
        .rows = pattern_str.len,
        .cols = max_cols,
    };
}

const HeightRange = struct {
    start_y: i32,
    end_y: i32,
};

fn getHeightRange(dimension: []const u8) HeightRange {
    if (std.mem.eql(u8, dimension, "overworld")) {
        return HeightRange{ .start_y = -64, .end_y = -59 };
    } else if (std.mem.eql(u8, dimension, "netherfloor")) {
        return HeightRange{ .start_y = 0, .end_y = 5 };
    } else if (std.mem.eql(u8, dimension, "netherceiling")) {
        return HeightRange{ .start_y = 122, .end_y = 127 };
    } else {
        return HeightRange{ .start_y = -64, .end_y = -59 };
    }
}

fn formatDuration(seconds: f64) void {
    if (seconds < 1.0) {
        const ms = @floatToInt(u32, seconds * 1000.0);
        std.debug.print("{}ms", .{ms});
    } else if (seconds < 60.0) {
        const secs = @floatToInt(u32, seconds);
        const ms = @floatToInt(u32, (seconds - @intToFloat(f64, secs)) * 100.0);
        if (ms > 0) {
            std.debug.print("{}.{}s", .{ secs, ms });
        } else {
            std.debug.print("{}s", .{secs});
        }
    } else if (seconds < 3600.0) {
        const minutes = @floatToInt(u32, seconds / 60.0);
        const secs = @floatToInt(u32, seconds - @intToFloat(f64, minutes * 60));
        std.debug.print("{}m {}s", .{ minutes, secs });
    } else {
        const hours = @floatToInt(u32, seconds / 3600.0);
        const remaining_minutes = @floatToInt(u32, (seconds - @intToFloat(f64, hours * 3600)) / 60.0);
        const remaining_seconds = @floatToInt(u32, seconds - @intToFloat(f64, hours * 3600) - @intToFloat(f64, remaining_minutes * 60));
        std.debug.print("{}h {}m {}s", .{ hours, remaining_minutes, remaining_seconds });
    }
}

const CrackContext = struct {
    found_seeds: std.ArrayList(i64),
    mutex: Mutex,
    seeds_checked: Atomic(u64),
    start_time: i64,
    last_print_time: Atomic(i64),
    total_seeds: u64,
};

const CrackTask = struct {
    start_seed: i64,
    end_seed: i64,
    coord_x: i32,
    coord_z: i32,
    pattern_3d: []const []const []const ?bedrock.Block,
    dimension: []const u8,
    ctx: *CrackContext,
};

fn crackWorker(task: CrackTask) void {
    const height_range = getHeightRange(task.dimension);

    var seed = task.start_seed;
    while (seed <= task.end_seed) : (seed += 1) {
        var generator: bedrock.GradientGenerator = undefined;

        if (std.mem.eql(u8, task.dimension, "overworld")) {
            generator = bedrock.GradientGenerator.overworldFloor(seed);
        } else if (std.mem.eql(u8, task.dimension, "netherfloor")) {
            generator = bedrock.GradientGenerator.netherFloor(seed);
        } else if (std.mem.eql(u8, task.dimension, "netherceiling")) {
            generator = bedrock.GradientGenerator.netherCeiling(seed);
        } else {
            continue;
        }

        // Check all Y levels in the height range
        var check_y = height_range.start_y;
        while (check_y <= height_range.end_y) : (check_y += 1) {
            var matches = true;

            for (task.pattern_3d) |layer, py| {
                for (layer) |row, pz| {
                    for (row) |block_opt, px| {
                        const x = task.coord_x + @intCast(i32, px);
                        const y = check_y + @intCast(i32, py);
                        const z = task.coord_z + @intCast(i32, pz);

                        const block_at = generator.at(x, y, z);

                        if (block_opt) |block| {
                            if (block != block_at) {
                                matches = false;
                                break;
                            }
                        } else {
                            if (block_at == bedrock.Block.bedrock) {
                                matches = false;
                                break;
                            }
                        }
                    }
                    if (!matches) break;
                }
                if (!matches) break;
            }

            if (matches) {
                task.ctx.mutex.lock();
                defer task.ctx.mutex.unlock();
                task.ctx.found_seeds.append(seed) catch {};

                std.debug.print("\r", .{});
                var i: usize = 0;
                while (i < 120) : (i += 1) std.debug.print(" ", .{});
                std.debug.print("\r", .{});
                std.debug.print(">>> FOUND SEED: {} (at Y={})\n", .{ seed, check_y });
                break; // Found at this seed, no need to check other Y levels
            }
        }

        const checked = task.ctx.seeds_checked.fetchAdd(1, .Monotonic) + 1;

        // Progress update every second
        if (@rem(seed, 10000) == 0) {
            const current_time = std.time.milliTimestamp();
            const last_print = task.ctx.last_print_time.load(.Monotonic);

            if (current_time - last_print >= 1000) {
                const old_val = task.ctx.last_print_time.tryCompareAndSwap(last_print, current_time, .Monotonic, .Monotonic);
                if (old_val == null or old_val.? == last_print) {
                    const elapsed = @intToFloat(f64, current_time - task.ctx.start_time) / 1000.0;
                    const percent = (@intToFloat(f64, checked) / @intToFloat(f64, task.ctx.total_seeds)) * 100.0;

                    std.debug.print("\r", .{});
                    var j: usize = 0;
                    while (j < 120) : (j += 1) std.debug.print(" ", .{});
                    std.debug.print("\r", .{});

                    const seeds_per_sec = @intToFloat(f64, checked) / elapsed;
                    std.debug.print("Progress: {d:.2}% | Seeds/s: {d:.0} | Checked: {} | Time: ", .{ percent, seeds_per_sec, checked });
                    formatDuration(elapsed);

                    if (seeds_per_sec > 0) {
                        const remaining = @intToFloat(f64, task.ctx.total_seeds - checked);
                        const eta = remaining / seeds_per_sec;
                        std.debug.print(" | ETA: ", .{});
                        formatDuration(eta);
                    }
                }
            }
        }
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    std.debug.assert(args.skip());

    const coord_x_str = args.next() orelse {
        std.debug.print("Usage: seed_cracker <coord_x> <coord_z> [pattern_file] [dimension]\n", .{});
        return error.NotEnoughArgs;
    };
    const coord_z_str = args.next() orelse {
        std.debug.print("Usage: seed_cracker <coord_x> <coord_z> [pattern_file] [dimension]\n", .{});
        return error.NotEnoughArgs;
    };

    const pattern_file_path = args.next();
    const dim_arg = args.next() orelse "overworld";

    const coord_x = try std.fmt.parseInt(i32, coord_x_str, 10);
    const coord_z = try std.fmt.parseInt(i32, coord_z_str, 10);
    const seed_start: i64 = -2147483648;
    const seed_end: i64 = 2147483647;

    const num_threads = try Thread.getCpuCount();

    // Load pattern
    var pattern: FlexiblePattern = undefined;
    if (pattern_file_path) |pf| {
        var contents = try std.fs.cwd().readFileAlloc(allocator, pf, 10 * 1024 * 1024);
        defer allocator.free(contents);

        var lines_list = std.ArrayList([]const u8).init(allocator);
        defer lines_list.deinit();

        var start: usize = 0;
        var i: usize = 0;
        while (i <= contents.len) : (i += 1) {
            if (i == contents.len or contents[i] == '\n') {
                var line = contents[start..i];
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0 .. line.len - 1];
                }
                if (line.len > 0) try lines_list.append(line);
                start = i + 1;
            }
        }

        pattern = try createPatternFromString(allocator, lines_list.items[0..lines_list.items.len]);
    } else {
        const default_pattern = [_][]const u8{
            "101",
            "010",
            "101",
        };
        pattern = try createPatternFromString(allocator, &default_pattern);
    }
    defer pattern.deinit(allocator);

    // Create 3D pattern
    const pattern_3d_struct = try createPattern3DFromFlexible(allocator, pattern);
    defer pattern_3d_struct.deinit(allocator);

    std.debug.print("\n===========================================\n", .{});
    std.debug.print("      Seed Cracker BY ICshX (MT)\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("Coordinates: X={}, Z={}\n", .{ coord_x, coord_z });
    std.debug.print("  (This will be the TOP-LEFT corner of pattern)\n", .{});
    std.debug.print("Dimension: {s}\n", .{dim_arg});
    std.debug.print("Seed Range: ALL (32-bit)\n", .{});
    std.debug.print("Threads: {}\n", .{num_threads});
    std.debug.print("Pattern size: {}x{}\n", .{ pattern.rows, pattern.cols });
    std.debug.print("Pattern (0=non-bedrock, 1=bedrock, empty=ignore):\n", .{});
    printFlexiblePattern(pattern);
    std.debug.print("===========================================\n\n", .{});

    const start_time = std.time.milliTimestamp();
    const total_seeds = @intCast(u64, seed_end - seed_start + 1);

    var ctx = CrackContext{
        .found_seeds = std.ArrayList(i64).init(allocator),
        .mutex = Mutex{},
        .seeds_checked = Atomic(u64).init(0),
        .start_time = start_time,
        .last_print_time = Atomic(i64).init(0),
        .total_seeds = total_seeds,
    };
    defer ctx.found_seeds.deinit();

    // Split work among threads
    const seeds_per_thread = @divTrunc(total_seeds, num_threads);

    var threads = try allocator.alloc(Thread, num_threads);
    defer allocator.free(threads);

    var tasks = try allocator.alloc(CrackTask, num_threads);
    defer allocator.free(tasks);

    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        const thread_start = seed_start + @intCast(i64, t * seeds_per_thread);
        const thread_end = if (t == num_threads - 1) seed_end else thread_start + @intCast(i64, seeds_per_thread - 1);

        tasks[t] = CrackTask{
            .start_seed = thread_start,
            .end_seed = thread_end,
            .coord_x = coord_x,
            .coord_z = coord_z,
            .pattern_3d = pattern_3d_struct.pattern,
            .dimension = dim_arg,
            .ctx = &ctx,
        };

        threads[t] = try Thread.spawn(.{}, crackWorker, .{tasks[t]});
    }

    for (threads) |thread| {
        thread.join();
    }

    const end_time = std.time.milliTimestamp();
    const total_duration = @intToFloat(f64, end_time - start_time) / 1000.0;

    std.debug.print("\r", .{});
    var i: usize = 0;
    while (i < 120) : (i += 1) std.debug.print(" ", .{});
    std.debug.print("\r", .{});

    std.debug.print("===========================================\n", .{});
    std.debug.print("          CRACKING COMPLETE\n", .{});
    std.debug.print("===========================================\n", .{});

    if (ctx.found_seeds.items.len > 0) {
        std.debug.print("Found {} matching seed(s):\n\n", .{ctx.found_seeds.items.len});
        for (ctx.found_seeds.items) |seed| {
            std.debug.print("  *** SEED: {} ***\n", .{seed});
        }
    } else {
        std.debug.print("No matching seeds found.\n", .{});
    }

    std.debug.print("\n", .{});
    std.debug.print("Total time: ", .{});
    formatDuration(total_duration);
    std.debug.print("\n", .{});
    const seeds_per_sec = @intToFloat(f64, total_seeds) / total_duration;
    std.debug.print("Speed: {d:.0} seeds/second\n", .{seeds_per_sec});
    std.debug.print("===========================================\n", .{});

    std.debug.print("\nPress Enter to exit...", .{});
    var buf: [1]u8 = undefined;
    _ = std.io.getStdIn().read(&buf) catch {};
}

const Pattern3D = struct {
    bedrock_rows: [][]?bedrock.Block,
    row_slices: [][]const ?bedrock.Block,
    layer: [][]const []const ?bedrock.Block,
    pattern: []const []const []const ?bedrock.Block,

    fn deinit(self: Pattern3D, allocator: std.mem.Allocator) void {
        for (self.bedrock_rows) |row| allocator.free(row);
        allocator.free(self.bedrock_rows);
        allocator.free(self.row_slices);
        allocator.free(self.layer);
    }
};

fn createPattern3DFromFlexible(allocator: std.mem.Allocator, flex_pattern: FlexiblePattern) !Pattern3D {
    var bedrock_rows = try allocator.alloc([]?bedrock.Block, flex_pattern.rows);
    for (bedrock_rows) |*row, i| {
        row.* = try allocator.alloc(?bedrock.Block, flex_pattern.cols);
        var j: usize = 0;
        while (j < flex_pattern.cols) : (j += 1) {
            const value = flex_pattern.get(i, j);
            row.*[j] = switch (value) {
                1 => bedrock.Block.bedrock,
                0 => null,
                else => null,
            };
        }
    }

    var row_slices = try allocator.alloc([]const ?bedrock.Block, flex_pattern.rows);
    var k: usize = 0;
    while (k < flex_pattern.rows) : (k += 1) row_slices[k] = bedrock_rows[k];

    var layer = try allocator.alloc([]const []const ?bedrock.Block, 1);
    layer[0] = row_slices;

    return Pattern3D{
        .bedrock_rows = bedrock_rows,
        .row_slices = row_slices,
        .layer = layer,
        .pattern = layer,
    };
}

fn printFlexiblePattern(flex_pattern: FlexiblePattern) void {
    var y: usize = 0;
    while (y < flex_pattern.rows) : (y += 1) {
        std.debug.print("  ", .{});
        var x: usize = 0;
        while (x < flex_pattern.cols) : (x += 1) {
            const value = flex_pattern.get(y, x);
            if (value == 2) {
                std.debug.print("  ", .{});
            } else {
                std.debug.print("{} ", .{value});
            }
        }
        std.debug.print("\n", .{});
    }
}
