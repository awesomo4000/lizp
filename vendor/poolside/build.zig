const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const poolside = b.addModule("poolside", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = poolside });
    // `poolside` is generic, so an installed static archive would contain no
    // usable symbols. Compiling the tests gives the default build meaningful
    // coverage without installing an empty artifact.
    b.getInstallStep().dependOn(&tests.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the poolside test suite");
    test_step.dependOn(&run_tests.step);

    const poolside_bench = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/deref.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "poolside", .module = poolside_bench }},
    });
    const bench = b.addExecutable(.{
        .name = "poolside-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run ReleaseFast microbenchmarks");
    bench_step.dependOn(&run_bench.step);
}
