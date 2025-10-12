//-----------------------------------------------
// Copyright (c) 2025 ICshX
// Licensed under the MIT License – see LICENSE
// Multi-threaded Version - Super Optimized
// Added optional start-point support (center X,Z) for searches
// Web version of PatternLocatorX
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
        for (self.data) |row| {
            allocator.free(row);
        }
        allocator.free(self.data);
    }
};

fn createPatternFromString(allocator: std.mem.Allocator, pattern_str: []const []const u8) !FlexiblePattern {
    var pattern_data: [][]u8 = try allocator.alloc([]u8, pattern_str.len);
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

// Directions array
const directions: [4][]const u8 = .{ "North", "East", "South", "West" };

// Height range struct
const HeightRange = struct {
    start_y: i32,
    end_y: i32,
};

// Function to get default height range depending on dimension
fn getHeightRange(dimension: []const u8) HeightRange {
    if (std.mem.eql(u8, dimension, "overworld")) {
        return HeightRange{ .start_y = -60, .end_y = -60 };
    } else if (std.mem.eql(u8, dimension, "netherfloor")) {
        return HeightRange{ .start_y = 4, .end_y = 4 };
    } else if (std.mem.eql(u8, dimension, "netherceiling")) {
        return HeightRange{ .start_y = 123, .end_y = 123 };
    } else {
        return HeightRange{ .start_y = -60, .end_y = -60 }; // fallback
    }
}

// Improved time formatting without scientific notation
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

// Thread task structure
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

// Thread worker function - optimized with block processing
fn searchWorker(task: ThreadTask) void {
    var finder = bedrock.PatternFinder{
        .gen = task.generator,
        .pattern = task.pattern,
    };

    // OPTIMIZATION: Process in blocks to reduce callback overhead
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

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    // Arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    std.debug.assert(args.skip());

    const seed_str = args.next() orelse {
        std.debug.print("Usage: bedrock_finder <seed> <range> [start_x start_z] [pattern_file] [dirs] [dimension]\n", .{});
        return error.NotEnoughArgs;
    };

    // Default + range parsing
    var range: i32 = 1000; // default
    if (args.next()) |range_str| {
        range = std.fmt.parseInt(i32, range_str, 10) catch 5000;
    }

    if (range > 2500) {
        std.debug.print("❌ Error: Range exceeds the maximum limit (2500). Provided: {}\n", .{range});
        return error.RangeTooLarge;
    }

    // optional: start_x, start_z, pattern_file, dirs, dimension
    var start_x_arg = args.next();
    var start_z_arg = args.next();
    const pattern_file_path = args.next();
    const dirs_arg = args.next() orelse "all";
    const dim_arg = args.next() orelse "overworld";

    const seed = try std.fmt.parseInt(i64, seed_str, 10);

    // Parse optional start point if both provided, else default to 0,0
    var center_x: i32 = 0;
    var center_z: i32 = 0;

    if (start_x_arg) |sx_str| {
        if (start_z_arg) |sz_str| {
            const parseInt = std.fmt.parseInt;
            const sx = parseInt(i32, sx_str, 10) catch 0;
            const sz = parseInt(i32, sz_str, 10) catch 0;
            center_x = sx;
            center_z = sz;
        }
    }

    // OPTIMIZATION: Intelligent thread count based on workload
    var num_threads = try Thread.getCpuCount();

    // Generator erstellen
    var generator: bedrock.GradientGenerator = undefined;
    if (std.mem.eql(u8, dim_arg, "overworld")) {
        generator = bedrock.GradientGenerator.overworldFloor(seed);
    } else if (std.mem.eql(u8, dim_arg, "netherfloor")) {
        generator = bedrock.GradientGenerator.netherFloor(seed);
    } else if (std.mem.eql(u8, dim_arg, "netherceiling")) {
        generator = bedrock.GradientGenerator.netherCeiling(seed);
    } else {
        std.debug.print("Unknown dimension: {s}\n", .{dim_arg});
        return error.InvalidDimension;
    }

    // Pattern laden
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

    // Determine search height range based on dimension
    const height_range = getHeightRange(dim_arg);

    // Convert directions argument to readable format
    const dirs_display = blk: {
        if (std.mem.eql(u8, dirs_arg, "all")) {
            break :blk "North, East, South, West";
        } else {
            var display_list = std.ArrayList(u8).init(allocator);

            for (dirs_arg) |c| {
                if (c == ' ' or c == ',') continue;
                if (display_list.items.len > 0) {
                    try display_list.appendSlice(", ");
                }
                switch (c) {
                    'N' => try display_list.appendSlice("North"),
                    'E' => try display_list.appendSlice("East"),
                    'S' => try display_list.appendSlice("South"),
                    'W' => try display_list.appendSlice("West"),
                    else => {},
                }
            }
            break :blk display_list.items;
        }
    };

    // Print header + pattern
    std.debug.print("\n===========================================\n", .{});
    std.debug.print("   PatternLocatorX - WEB-V1.1 BY ICsh \n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("Seed: {}\n", .{seed});
    std.debug.print("Search Range: -{} to +{}\n", .{ range, range });
    std.debug.print("Start point (center): {} {}\n", .{ center_x, center_z });
    std.debug.print("Dimension: {s}\n", .{dim_arg});
    std.debug.print("Directions: {s}\n", .{dirs_display});
    std.debug.print("Threads: {}\n", .{num_threads});
    std.debug.print("Search Height: {} to {}\n", .{ height_range.start_y, height_range.end_y });
    std.debug.print("Pattern size: {}x{}\n", .{ pattern.rows, pattern.cols });
    std.debug.print("Pattern (0=non-bedrock, 1=bedrock, empty=ignore):\n", .{});
    printFlexiblePattern(pattern);
    std.debug.print("===========================================\n\n", .{});

    // Start time for overall search
    const start_time = std.time.milliTimestamp();
    var total_found: u32 = 0;

    // Calculate total positions for all directions
    const range_size = @intCast(u64, range * 2 + 1);
    const positions_per_direction = range_size * range_size;
    var active_direction_count: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (shouldCheckDirection(dirs_arg, i)) active_direction_count += 1;
    }
    const total_positions = positions_per_direction * active_direction_count;

    // Compute absolute bounds centered around center_x, center_z
    const global_start_x = center_x - range;
    const global_end_x = center_x + range;
    const global_start_z = center_z - range;
    const global_end_z = center_z + range;

    var dir_idx: usize = 0;
    while (dir_idx < 4) : (dir_idx += 1) {
        if (!shouldCheckDirection(dirs_arg, dir_idx)) continue;

        const direction_start_time = std.time.milliTimestamp();

        const rotated = try rotateFlexiblePattern(allocator, pattern, dir_idx);
        defer rotated.deinit(allocator);

        const pattern_3d_struct = try createPattern3DFromFlexible(allocator, rotated);
        defer pattern_3d_struct.deinit(allocator);

        var ctx = SearchContext{
            .direction = directions[dir_idx],
            .rotation = dir_idx,
            .found_count = 0,
            .start_time = direction_start_time,
            .global_start_time = start_time,
            .direction_total = positions_per_direction,
            .global_total = total_positions,
            .global_completed = Atomic(u64).init(((dir_idx) * positions_per_direction)),
            .direction_number = dir_idx + 1,
            .mutex = Mutex{},
            .last_print_time = Atomic(i64).init(0),
        };

        std.debug.print("--------------------------------------------------------------\n", .{});
        std.debug.print("         Searching facing {s} ({} threads)...\n", .{ directions[dir_idx], num_threads });
        std.debug.print("--------------------------------------------------------------\n", .{});
        std.debug.print("\n", .{});

        // Split search area into chunks for threads
        const x_range_total = global_end_x - global_start_x + 1; // inclusive count
        const chunk_size = @intCast(i32, (@divTrunc(@intCast(i32, x_range_total), @intCast(i32, num_threads))));

        var threads = try allocator.alloc(Thread, num_threads);
        defer allocator.free(threads);

        var tasks = try allocator.alloc(ThreadTask, num_threads);
        defer allocator.free(tasks);

        // Create and start threads
        var t: usize = 0;
        while (t < num_threads) : (t += 1) {
            const start_x = global_start_x + @intCast(i32, t) * chunk_size;
            const end_x = if (t == num_threads - 1) global_end_x else start_x + chunk_size - 1;

            tasks[t] = ThreadTask{
                .start_x = start_x,
                .end_x = end_x,
                .start_z = global_start_z,
                .end_z = global_end_z,
                .height_range = height_range,
                .generator = generator,
                .pattern = pattern_3d_struct.pattern,
                .ctx = &ctx,
            };

            threads[t] = try Thread.spawn(.{}, searchWorker, .{tasks[t]});
        }

        // Wait for all threads to complete
        for (threads) |thread| {
            thread.join();
        }

        //const direction_end_time = std.time.milliTimestamp();
        //const direction_duration = @intToFloat(f64, direction_end_time - direction_start_time) / 1000.0;

        //Final progress display for this direction
        //std.debug.print("\r", .{});
        var j: usize = 0;
        while (j < 120) : (j += 1) {
            //std.debug.print(" ", .{});
        }
        //std.debug.print("\r[{s}] Progress: 100.0% | Time: ", .{directions[dir_idx]});
        //formatDuration(direction_duration);
        //std.debug.print(" | Found: {} patterns\n", .{ctx.found_count});

        total_found += ctx.found_count;
    }

    const end_time = std.time.milliTimestamp();
    const total_duration = @intToFloat(f64, end_time - start_time) / 1000.0;

    std.debug.print("===========================================\n", .{});
    std.debug.print("            SEARCH COMPLETE\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("Total patterns found: {}\n", .{total_found});
    std.debug.print("Total time elapsed: ", .{});
    formatDuration(total_duration);
    std.debug.print("\n", .{});
    std.debug.print("Positions searched: {}\n", .{total_positions});
    const positions_per_second = @intToFloat(f64, total_positions) / total_duration;
    std.debug.print("Speed: {d:.0} positions/second\n", .{positions_per_second});
    std.debug.print("Threads used: {}\n", .{num_threads});
    std.debug.print("===========================================\n", .{});
}

// ---------- helper structs & functions ----------

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

fn shouldCheckDirection(dirs_arg: []const u8, index: usize) bool {
    if (std.mem.eql(u8, dirs_arg, "all")) return true;

    var chars_to_check: []const u8 = &[_]u8{ 'N', 'E', 'S', 'W' };
    for (dirs_arg) |c| {
        if (c == ' ' or c == ',') continue;
        if (c == chars_to_check[index]) return true;
    }
    return false;
}

// Report progress for threads - optimized with minimal lock contention
fn reportProgressThreaded(ctx: *SearchContext, completed: u64, _total: u64) void {
    _ = ctx;
    _ = completed;
    _ = _total;

    // Disable progress output completely.
    // This function is kept to maintain compatibility
    // but it does not print anything.
}

// Report a found pattern
fn reportResult(ctx: *SearchContext, p: bedrock.Point) void {
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    ctx.found_count += 1;

    // Clear current line
    std.debug.print("\r", .{});
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("\r", .{});

    // Print result
    const out = std.io.getStdOut().writer();
    out.print(">>> FOUND!   {} {} {}   facing {s}\n", .{ p.x, p.y, p.z, ctx.direction }) catch @panic("failed to write to stdout");
}

// Rotate helper: 90° once
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

    return FlexiblePattern{
        .data = new_data,
        .rows = new_rows,
        .cols = new_cols,
    };
}

fn rotateFlexiblePattern(
    allocator: std.mem.Allocator,
    input_pattern: FlexiblePattern,
    times: usize,
) !FlexiblePattern {
    if (times == 0) {
        var new_data = try allocator.alloc([]u8, input_pattern.rows);
        for (new_data) |*row, i| {
            row.* = try allocator.alloc(u8, input_pattern.data[i].len);
            std.mem.copy(u8, row.*, input_pattern.data[i]);
        }
        return FlexiblePattern{
            .data = new_data,
            .rows = input_pattern.rows,
            .cols = input_pattern.cols,
        };
    }

    var current = try rotateOnce(allocator, input_pattern);
    var t: usize = 1;
    while (t < times) : (t += 1) {
        const rotated = try rotateOnce(allocator, current);
        current.deinit(allocator);
        current = rotated;
    }
    return current;
}

// 3D pattern structure
const Pattern3D = struct {
    bedrock_rows: [][]?bedrock.Block,
    row_slices: [][]const ?bedrock.Block,
    layer: [][]const []const ?bedrock.Block,
    pattern: []const []const []const ?bedrock.Block,

    fn deinit(self: Pattern3D, allocator: std.mem.Allocator) void {
        for (self.bedrock_rows) |row| {
            allocator.free(row);
        }
        allocator.free(self.bedrock_rows);
        allocator.free(self.row_slices);
        allocator.free(self.layer);
    }
};

fn createPattern3DFromFlexible(
    allocator: std.mem.Allocator,
    flex_pattern: FlexiblePattern,
) !Pattern3D {
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

// Print a flexible pattern to console
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
