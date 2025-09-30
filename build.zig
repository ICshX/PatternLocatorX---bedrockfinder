//-----------------------------------------------
// Original: Copyright (c) 2022 silver
// Modifications: Copyright (c) 2025 ICshX
// Licensed under the MIT License – see LICENSE
//-----------------------------------------------
const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("PatternLocatorX", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wasm = b.addSharedLibrary("PatternLocatorX", "src/web.zig", .unversioned);
    wasm.setTarget(try std.zig.CrossTarget.parse(.{
        .arch_os_abi = "wasm32-freestanding",
    }));
    wasm.setBuildMode(mode);
    wasm.use_stage1 = true;
    wasm.override_dest_dir = .{ .custom = "web" };
    wasm.single_threaded = true;

    const web = b.addInstallDirectory(.{
        .source_dir = "web",
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    web.step.dependOn(&b.addInstallArtifact(wasm).step);

    const web_step = b.step("web", "Build web UI");
    web_step.dependOn(&web.step);
}
