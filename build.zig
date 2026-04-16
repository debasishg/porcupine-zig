const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Exposes standard `-Doptimize=...` / `--release=fast` knobs.
    // For a serious benchmark run: `zig build test -Doptimize=ReleaseFast`.
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------
    // Module: reusable porcupine library entry.
    // -------------------------------------------------------------------
    const porcupine_mod = b.addModule("porcupine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -------------------------------------------------------------------
    // Static library artifact (useful for C-ABI consumers / docs).
    // -------------------------------------------------------------------
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "porcupine",
        .root_module = porcupine_mod,
    });
    b.installArtifact(lib);

    // -------------------------------------------------------------------
    // Unit tests: run `zig build test`.
    //
    // Split into a compile step and a run step so `test` can be a
    // parallel composite of the library's internal tests plus the
    // integration tests under `tests/`.
    // -------------------------------------------------------------------
    const test_step = b.step("test", "Run unit and integration tests");

    const unit_tests = b.addTest(.{
        .root_module = porcupine_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests_mod.addImport("porcupine", porcupine_mod);
    const integration_tests = b.addTest(.{
        .root_module = integration_tests_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    // -------------------------------------------------------------------
    // Benchmarks: run `zig build bench`.
    // -------------------------------------------------------------------
    const bench_step = b.step("bench", "Run micro-benchmarks");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("porcupine", porcupine_mod);
    const bench_exe = b.addExecutable(.{
        .name = "porcupine-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    bench_step.dependOn(&run_bench.step);
}
