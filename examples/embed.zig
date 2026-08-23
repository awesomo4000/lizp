const std = @import("std");
const lizp = @import("lizp");

const Host = struct {
    offset: i64,
};

fn hostAdd(
    context: ?*anyopaque,
    runtime: *lizp.Runtime,
    args: []const lizp.Value,
) lizp.HostError!lizp.NativeOutcome {
    if (args.len != 1) {
        return .{ .condition = .{
            .code = .arity_mismatch,
            .message = "host-add expects one argument",
        } };
    }
    const host: *Host = @ptrCast(@alignCast(context.?));
    const input = runtime.asInteger(args[0]) orelse {
        return .{ .condition = .{
            .code = .type_mismatch,
            .message = "host-add expects an integer",
        } };
    };
    const result = std.math.add(i64, input, host.offset) catch {
        return .{ .condition = .{
            .code = .integer_overflow,
            .message = "integer overflow in host-add",
        } };
    };
    return .{ .returned = .{ .integer = result } };
}

fn requireReturned(report: lizp.EvaluationReport) !lizp.Value {
    return switch (report.outcome) {
        .returned => |value| value,
        .condition => |value| {
            std.debug.print("condition: {s}\n", .{value.message()});
            return error.UnexpectedCondition;
        },
        .cancelled => error.UnexpectedCancellation,
        .paused => error.UnexpectedPause,
    };
}

pub fn main(init: std.process.Init) !void {
    var host = Host{ .offset = 1000 };
    var runtime = try lizp.Runtime.init(init.gpa);
    defer runtime.deinit();

    try runtime.registerNative("host-add", &host, hostAdd);

    _ = try requireReturned(try runtime.evaluate(.{
        .source = .{ .bytes = "(define (twice f x) (f (f x)))" },
    }));
    const twice = runtime.getGlobal("twice").?;
    const host_add = runtime.getGlobal("host-add").?;
    const result = try requireReturned(try runtime.evaluate(.{
        .call = .{
            .function = twice,
            .arguments = &.{ host_add, .{ .integer = 5 } },
        },
    }));

    var buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_file.interface;
    try stdout.writeAll("Zig received: ");
    try runtime.writeValue(stdout, result);
    try stdout.writeByte('\n');
    try stdout.flush();
}
