const std = @import("std");
const lizp = @import("lizp");

const Host = struct {
    theme: []const u8 = "dark",
    delete_attempts: usize = 0,
};

fn readSetting(
    context: ?*anyopaque,
    runtime: *lizp.Runtime,
    args: []const lizp.Value,
) lizp.HostError!lizp.NativeOutcome {
    if (args.len != 1) {
        return .{ .condition = .{
            .code = .arity_mismatch,
            .message = "read-setting expects one argument",
        } };
    }
    const key = runtime.asString(args[0]) orelse {
        return .{ .condition = .{
            .code = .type_mismatch,
            .message = "read-setting expects a string",
        } };
    };

    const host: *Host = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, key, "theme")) {
        return .{ .returned = try runtime.makeString(host.theme) };
    }
    return .{ .returned = .nil };
}

fn deleteFile(
    context: ?*anyopaque,
    _: *lizp.Runtime,
    _: []const lizp.Value,
) lizp.HostError!lizp.NativeOutcome {
    const host: *Host = @ptrCast(@alignCast(context.?));
    host.delete_attempts += 1;
    return .{ .returned = .nil };
}

fn requireReturned(report: lizp.EvaluationReport) !lizp.Value {
    return switch (report.outcome) {
        .returned => |value| value,
        else => error.UnexpectedEvaluationOutcome,
    };
}

pub fn main(init: std.process.Init) !void {
    var host = Host{};
    var runtime = try lizp.Runtime.init(init.gpa);
    defer runtime.deinit();

    try runtime.registerNative("read-setting", &host, readSetting);
    try runtime.registerNative("delete-file", &host, deleteFile);

    const environment = try runtime.createCapabilityEnvironment(.{
        .allow = &.{ "+", "list", "read-setting" },
        .language = .attenuated,
    });

    const result = try requireReturned(try runtime.evaluate(.{
        .source = .{
            .bytes = "(list (+ 20 22) (read-setting \"theme\"))",
            .environment = environment,
        },
    }));

    const denied = try runtime.evaluate(.{
        .source = .{
            .bytes = "(delete-file \"important.txt\")",
            .environment = environment,
        },
    });
    switch (denied.outcome) {
        .condition => |value| std.debug.assert(value.code == .undefined_symbol),
        else => return error.UnexpectedCapability,
    }
    std.debug.assert(host.delete_attempts == 0);

    var buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_file.interface;
    try stdout.writeAll("attenuated result: ");
    try runtime.writeValue(stdout, result);
    try stdout.writeByte('\n');
    try stdout.flush();
}
