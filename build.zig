const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const poolside_dep = b.dependency("poolside", .{
        .target = target,
        .optimize = optimize,
    });

    const lizp = b.addModule("lizp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "poolside", .module = poolside_dep.module("poolside") }},
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lizp", .module = lizp }},
    });
    const exe = b.addExecutable(.{
        .name = "lizp",
        .root_module = cli_module,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the Lizp interpreter");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = lizp });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the Lizp test suite");
    test_step.dependOn(&run_tests.step);

    const embed_module = b.createModule(.{
        .root_source_file = b.path("examples/embed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lizp", .module = lizp }},
    });
    const embed = b.addExecutable(.{
        .name = "lizp-embed-example",
        .root_module = embed_module,
    });
    const run_embed = b.addRunArtifact(embed);
    const embed_step = b.step("embed-example", "Run the native Zig embedding example");
    embed_step.dependOn(&run_embed.step);

    const capability_module = b.createModule(.{
        .root_source_file = b.path("examples/capabilities.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lizp", .module = lizp }},
    });
    const capability_example = b.addExecutable(.{
        .name = "lizp-capability-example",
        .root_module = capability_module,
    });
    const run_capability_example = b.addRunArtifact(capability_example);
    const capability_step = b.step(
        "capability-example",
        "Run the capability-attenuated environment example",
    );
    capability_step.dependOn(&run_capability_example.step);

    const observe_module = b.createModule(.{
        .root_source_file = b.path("examples/observe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lizp", .module = lizp }},
    });
    const observe_example = b.addExecutable(.{
        .name = "lizp-observation-example",
        .root_module = observe_module,
    });
    const run_observe_example = b.addRunArtifact(observe_example);
    const observe_step = b.step(
        "observe-example",
        "Run the sans-I/O observation journal example",
    );
    observe_step.dependOn(&run_observe_example.step);
}
