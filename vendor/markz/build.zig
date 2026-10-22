const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =========================================================================
    // markz Library Module
    // =========================================================================
    const markz_module = b.addModule("markz", .{
        .root_source_file = b.path("src/markz.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =========================================================================
    // Unit Tests
    // =========================================================================
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/markz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run markz tests");
    test_step.dependOn(&run_tests.step);

    // =========================================================================
    // CommonMark Spec Conformance Tests
    // =========================================================================
    const spec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/commonmark_spec.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    spec_tests.root_module.addImport("markz", markz_module);

    const run_spec_tests = b.addRunArtifact(spec_tests);
    const spec_test_step = b.step("test-spec", "Run CommonMark spec conformance tests");
    spec_test_step.dependOn(&run_spec_tests.step);

    // =========================================================================
    // Benchmarks
    // =========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addAnonymousImport("spec.json", .{
        .root_source_file = b.path("test/spec.json"),
    });
    bench_mod.addImport("markz", markz_module);
    const bench_exe = b.addExecutable(.{
        .name = "markz-bench",
        .root_module = bench_mod,
    });

    const run_bench = b.addRunArtifact(bench_exe);
    // Zig 0.17: `b.args` was removed; pass `zig build bench -- <args>` through.
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // =========================================================================
    // CLI (for comparison benchmarks)
    // =========================================================================
    const markz_fast = b.addModule("markz-fast", .{
        .root_source_file = b.path("src/markz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("bench/cli.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cli_mod.addImport("markz", markz_fast);
    const cli_exe = b.addExecutable(.{
        .name = "markz-cli",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
}
