const std = @import("std");

const zx = @import("zx");

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 提供markdown解析支持
    const markz_dep = b.dependency("markz", .{ .target = target, .optimize = optimize });

    // --- ZX App Executable ---
    const app_exe = b.addExecutable(.{
        .name = "ziex_app",
        .root_module = b.createModule(.{ .root_source_file = b.path("app/main.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "markz", .module = markz_dep.module("markz") },
        } }),
    });

    // --- ZX setup: wires dependencies and adds `zx`/`dev` build steps ---
    _ = try zx.init(b, app_exe, .{});
}
