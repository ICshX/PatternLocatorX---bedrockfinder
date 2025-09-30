//-----------------------------------------------
// Original: Copyright (c) 2025 ICshX
//-----------------------------------------------
const std = @import("std");
const bedrock = @import("bedrock.zig");

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
            std.debug.print("{}.{}s", .{secs, ms});
        } else {
            std.debug.print("{}s", .{secs});
        }
    } else if (seconds < 3600.0) {
        const minutes = @floatToInt(u32, seconds / 60.0);
        const secs = @floatToInt(u32, seconds - @intToFloat(f64, minutes * 60));
        std.debug.print("{}m {}s", .{minutes, secs});
    } else {
        const hours = @floatToInt(u32, seconds / 3600.0);
        const remaining_minutes = @floatToInt(u32, (seconds - @intToFloat(f64, hours * 3600)) / 60.0);
        const remaining_seconds = @floatToInt(u32, seconds - @intToFloat(f64, hours * 3600) - @intToFloat(f64, remaining_minutes * 60));
        std.debug.print("{}h {}m {}s", .{hours, remaining_minutes, remaining_seconds});
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
        std.debug.print("Usage: bedrock_finder <seed> <range> [pattern_file] [dirs] [dimension]\n", .{});
        return error.NotEnoughArgs;
    };
    const range_str = args.next() orelse {
        std.debug.print("Usage: bedrock_finder <seed> <range> [pattern_file] [dirs] [dimension]\n", .{});
        return error.NotEnoughArgs;
    };

    // optional: pattern_file, dirs, dimension (handle order)
    const pattern_file_path = args.next();
    const dirs_arg = args.next() orelse "all";
    const dim_arg = args.next() orelse "overworld";

    const seed = try std.fmt.parseInt(i64, seed_str, 10);
    const range = try std.fmt.parseInt(i32, range_str, 10);

    // Danach Generator erstellen
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

    // Load pattern: either from file or default
    var pattern: FlexiblePattern = undefined;
    if (pattern_file_path) |pf| {
        var contents = try std.fs.cwd().readFileAlloc(allocator, pf, 10 * 1024 * 1024); // 10 MB Limit
        defer allocator.free(contents);

        var lines_list = std.ArrayList([]const u8).init(allocator);
        defer lines_list.deinit();

        var start: usize = 0;
        var i: usize = 0;
        while (i <= contents.len) : (i += 1) {
            if (i == contents.len or contents[i] == '\n') {
                var line = contents[start..i];
                // Trim CR if present
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    line = line[0..line.len - 1];
                }
                // Skip empty lines
                if (line.len > 0) try lines_list.append(line);
                start = i + 1;
            }
        }

        // create pattern from the lines
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

    // Print header + pattern
    std.debug.print("\n===========================================\n", .{});
    std.debug.print("       PatternLocatorX-V5 BY ICsh\n", .{});
    std.debug.print("===========================================\n", .{});
    std.debug.print("Seed: {}\n", .{seed});
    std.debug.print("Search Range: -{} to +{}\n", .{range, range});
    std.debug.print("Search Height: {} to {}\n", .{height_range.start_y, height_range.end_y});
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
    const total_positions = positions_per_direction * 4; // 4 directions
    var global_completed: u64 = 0;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (!shouldCheckDirection(dirs_arg, i)) continue;

        const direction_start_time = std.time.milliTimestamp();

        const rotated = try rotateFlexiblePattern(allocator, pattern, i);
        defer rotated.deinit(allocator);

        const pattern_3d_struct = try createPattern3DFromFlexible(allocator, rotated);
        defer pattern_3d_struct.deinit(allocator);

        var finder = bedrock.PatternFinder{
            .gen = generator,
            .pattern = pattern_3d_struct.pattern,
        };

        var ctx = SearchContext{
            .direction = directions[i],
            .rotation = i,
            .found_count = 0,
            .start_time = direction_start_time,
            .global_start_time = start_time,
            .direction_total = positions_per_direction,
            .global_total = total_positions,
            .global_completed = &global_completed,
            .direction_number = i + 1,
        };

        std.debug.print("--------------------------------------------------------------\n", .{});
        std.debug.print("                 Searching facing {s}...\n", .{directions[i]});
        std.debug.print("--------------------------------------------------------------\n", .{});
        std.debug.print("\n", .{});

        finder.search(
            .{ .x = -range, .y = height_range.start_y, .z = -range },
            .{ .x = range, .y = height_range.end_y, .z = range },
            &ctx,
            reportResult,
            reportProgress,
        );

        const direction_end_time = std.time.milliTimestamp();
        const direction_duration = @intToFloat(f64, direction_end_time - direction_start_time) / 1000.0;

        // Final progress display for this direction
        std.debug.print("\r", .{});
        var j: usize = 0;
        while (j < 120) : (j += 1) {
            std.debug.print(" ", .{});
        }
        std.debug.print("\r[{s}] Progress: 100.0% | Time: ", .{directions[i]});
        formatDuration(direction_duration);
        std.debug.print(" | Found: {} patterns\n", .{ctx.found_count});

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
    global_completed: *u64,
    direction_number: usize,
};

fn shouldCheckDirection(dirs_arg: []const u8, index: usize) bool {
    if (std.mem.eql(u8, dirs_arg, "all")) return true;

    var chars_to_check: []const u8 = &[_]u8{ 'N', 'E', 'S', 'W' };
    for (dirs_arg) |c| {
        if (c == ' ' or c == ',') continue; // Leerzeichen oder Komma ignorieren
        if (c == chars_to_check[index]) return true;
    }
    return false;
}

// Report progress for the search (now takes a pointer)
fn reportProgress(ctx: *SearchContext, completed: u64, _total: u64) void {
    _ = _total;

    ctx.*.global_completed.* = ((ctx.*.direction_number - 1) * ctx.*.direction_total) + completed;

    if (completed % 10000 == 0 or completed == ctx.*.direction_total) {
        const actual_completed = @min(completed, ctx.*.direction_total);
        const percent = (@intToFloat(f64, actual_completed) / @intToFloat(f64, ctx.*.direction_total)) * 100.0;
        const current_time = std.time.milliTimestamp();
        const elapsed = @intToFloat(f64, current_time - ctx.*.start_time) / 1000.0;

        // Progress bar
        const bar_width: usize = 20;
        const filled = @floatToInt(usize, (percent / 100.0) * @intToFloat(f64, bar_width));

        // Clear line
        std.debug.print("\r", .{});
        var i: usize = 0;
        while (i < 120) : (i += 1) std.debug.print(" ", .{});
        std.debug.print("\r", .{});

        std.debug.print("[{s}] [", .{ctx.*.direction});
        var j: usize = 0;
        while (j < bar_width) : (j += 1) {
            if (j < filled) std.debug.print("=", .{}) else std.debug.print(" ", .{});
        }
        std.debug.print("] ", .{});
        std.debug.print("{d:.1}% | Time: ", .{percent});
        formatDuration(elapsed);

        // Calculate ETA, only if elapsed > 0
        if (elapsed > 0.0 and actual_completed < ctx.*.direction_total) {
            const rate = @intToFloat(f64, actual_completed) / elapsed;
            const remaining = @intToFloat(f64, ctx.*.direction_total - actual_completed);
            const eta_seconds = remaining / rate;
            std.debug.print(" | ETA: ", .{});
            formatDuration(eta_seconds);
        }

        // At 100% completion also show ETA = 0
        if (actual_completed == ctx.*.direction_total) {
            std.debug.print(" | ETA: 0s", .{});
        }
    }
}

// Report a found pattern (takes pointer)
fn reportResult(ctx: *SearchContext, p: bedrock.Point) void {
    ctx.*.found_count += 1;

    // Clear current line
    std.debug.print("\r", .{});
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        std.debug.print(" ", .{});
    }
    std.debug.print("\r", .{});

    // Print result
    const out = std.io.getStdOut().writer();
    out.print(">>> FOUND! X:{}, Y:{}, Z:{} facing {s}\n", .{
        p.x,
        p.y,
        p.z,
        ctx.*.direction
    }) catch @panic("failed to write to stdout");
}

// Rotate helper: 90° once (no leaks)
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
