const std = @import("std");
const lizp = @import("lizp");

const Io = std.Io;
const max_script_bytes = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    var runtime = lizp.Runtime.init(allocator) catch |err| {
        try stderr.print("lizp: initialization failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    defer runtime.deinit();

    // Output is supplied by the embedding host. The CLI opts into a `print`
    // procedure without coupling the evaluator to stdout or std.Io.
    try runtime.registerNative("print", @ptrCast(stdout), nativePrint);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "-e")) {
        if (args.len != 3) {
            try stderr.writeAll("lizp: -e requires exactly one expression argument\n");
            try printUsage(stderr);
            try stderr.flush();
            std.process.exit(2);
        }
        const result = evaluateAndPrint(
            &runtime,
            stdout,
            stderr,
            args[2],
            "cli://expression",
        ) catch |err| {
            try printHostError(stderr, err);
            try stdout.flush();
            try stderr.flush();
            std.process.exit(1);
        };
        if (result == null) {
            try stdout.flush();
            try stderr.flush();
            std.process.exit(1);
        }
        try stdout.flush();
        try stderr.flush();
        return;
    }

    if (args.len == 2) {
        const source = Io.Dir.cwd().readFileAlloc(
            io,
            args[1],
            allocator,
            .limited(max_script_bytes),
        ) catch |err| {
            try stderr.print("lizp: cannot read '{s}': {s}\n", .{ args[1], @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        defer allocator.free(source);
        const result = evaluateAndPrint(
            &runtime,
            stdout,
            stderr,
            source,
            args[1],
        ) catch |err| {
            try printHostError(stderr, err);
            try stdout.flush();
            try stderr.flush();
            std.process.exit(1);
        };
        if (result == null) {
            try stdout.flush();
            try stderr.flush();
            std.process.exit(1);
        }
        try stdout.flush();
        try stderr.flush();
        return;
    }

    if (args.len > 2) {
        try stderr.writeAll("lizp: too many arguments\n");
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(2);
    }

    try repl(&runtime, io, allocator, stdout, stderr);
    try stdout.flush();
    try stderr.flush();
}

fn evaluateAndPrint(
    runtime: *lizp.Runtime,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    source: []const u8,
    source_name: ?[]const u8,
) lizp.HostError!?lizp.Value {
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = source,
            .source_name = source_name,
        },
    });

    return switch (report.outcome) {
        .returned => |value| blk: {
            runtime.writeValue(stdout, value) catch return error.NativeHostFailure;
            stdout.writeByte('\n') catch return error.NativeHostFailure;
            break :blk value;
        },
        .condition => |condition_value| blk: {
            printCondition(runtime, stderr, &condition_value) catch return error.NativeHostFailure;
            break :blk null;
        },
        .cancelled => blk: {
            stderr.writeAll("evaluation cancelled\n") catch return error.NativeHostFailure;
            break :blk null;
        },
        .paused => blk: {
            stderr.writeAll("evaluation paused\n") catch return error.NativeHostFailure;
            break :blk null;
        },
    };
}

fn printCondition(
    runtime: *const lizp.Runtime,
    writer: *Io.Writer,
    value: *const lizp.Condition,
) !void {
    if (value.span) |source_span| {
        if (runtime.sourceView(source_span.source)) |source_view| {
            if (runtime.sourceLocation(source_span)) |location| {
                try writer.print(
                    "{s}:{d}:{d}: {s} condition {s}: {s}\n",
                    .{
                        source_view.name,
                        location.start.line,
                        location.start.column,
                        @tagName(value.phase),
                        @tagName(value.code),
                        value.message(),
                    },
                );
                if (runtime.sourceExcerpt(source_span)) |excerpt| {
                    try writer.writeAll("  form: ");
                    const displayed = excerpt[0..@min(excerpt.len, 512)];
                    try writer.writeAll(displayed);
                    if (displayed.len != 0 and displayed[displayed.len - 1] != '\n') {
                        try writer.writeByte('\n');
                    }
                    if (displayed.len < excerpt.len) try writer.writeAll("  ...\n");
                }
                return;
            }
        }
    }
    try writer.print("{s} condition {s}: {s}\n", .{
        @tagName(value.phase),
        @tagName(value.code),
        value.message(),
    });
}

fn printHostError(writer: *Io.Writer, err: anyerror) !void {
    try writer.print("lizp host failure: {s}\n", .{@errorName(err)});
}

fn repl(
    runtime: *lizp.Runtime,
    io: Io,
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const interactive = Io.File.stdin().isTty(io) catch false;

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_file.interface;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    var submission_number: u64 = 1;

    if (interactive) {
        try stdout.print("Lizp {s} — Zig-embeddable Lisp\n", .{lizp.version});
        try stdout.writeAll("Type :help for REPL commands. The last result is bound to _.\n");
    }

    while (true) {
        if (interactive) {
            try stdout.writeAll(if (source.items.len == 0) "lizp> " else " ...> ");
            try stdout.flush();
        }

        const raw_line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (source.items.len != 0) {
                    var name_buffer: [64]u8 = undefined;
                    const source_name = std.fmt.bufPrint(
                        &name_buffer,
                        "repl://submission/{d}",
                        .{submission_number},
                    ) catch "repl://submission";
                    _ = evaluateAndPrint(
                        runtime,
                        stdout,
                        stderr,
                        source.items,
                        source_name,
                    ) catch |host_err| {
                        try printHostError(stderr, host_err);
                    };
                }
                if (interactive) try stdout.writeByte('\n');
                return;
            },
            error.StreamTooLong => {
                _ = stdin.discardDelimiterInclusive('\n') catch {};
                try stderr.writeAll("error: input line exceeds 64 KiB\n");
                continue;
            },
            else => return err,
        };
        stdin.toss(@min(1, stdin.bufferedLen()));
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        const command = std.mem.trim(u8, line, " \t");

        if (source.items.len == 0 and command.len == 0) continue;
        if (source.items.len == 0 and std.mem.eql(u8, command, ":quit")) return;
        if (source.items.len == 0 and std.mem.eql(u8, command, ":help")) {
            try stdout.writeAll(
                ":help  show this help\n" ++
                    ":gc    collect unreachable objects\n" ++
                    ":quit  exit\n",
            );
            continue;
        }
        if (source.items.len == 0 and std.mem.eql(u8, command, ":gc")) {
            const collected = try runtime.collectGarbage(&.{});
            try stdout.print("collected {d} objects; {d} live\n", .{ collected, runtime.heapLiveCount() });
            continue;
        }

        try source.appendSlice(allocator, line);
        try source.append(allocator, '\n');
        if (!formLooksComplete(source.items)) continue;

        var name_buffer: [64]u8 = undefined;
        const source_name = std.fmt.bufPrint(
            &name_buffer,
            "repl://submission/{d}",
            .{submission_number},
        ) catch "repl://submission";
        submission_number +%= 1;
        if (submission_number == 0) submission_number = 1;
        const maybe_result = evaluateAndPrint(
            runtime,
            stdout,
            stderr,
            source.items,
            source_name,
        ) catch |host_err| {
            try printHostError(stderr, host_err);
            source.clearRetainingCapacity();
            continue;
        };
        source.clearRetainingCapacity();

        if (maybe_result) |result| {
            try runtime.defineGlobal("_", result);
            _ = runtime.collectGarbage(&.{result}) catch |err| {
                try stderr.print("gc host failure: {s}\n", .{@errorName(err)});
                continue;
            };
        } else {
            _ = runtime.collectGarbage(&.{}) catch |err| {
                try stderr.print("gc host failure: {s}\n", .{@errorName(err)});
            };
        }
    }
}

fn nativePrint(
    context: ?*anyopaque,
    runtime: *lizp.Runtime,
    args: []const lizp.Value,
) lizp.HostError!lizp.NativeOutcome {
    const writer: *Io.Writer = @ptrCast(@alignCast(context.?));
    for (args, 0..) |arg, index| {
        if (index != 0) writer.writeByte(' ') catch return error.NativeHostFailure;
        runtime.writeValue(writer, arg) catch return error.NativeHostFailure;
    }
    writer.writeByte('\n') catch return error.NativeHostFailure;
    writer.flush() catch return error.NativeHostFailure;
    return .{ .returned = if (args.len == 0) .nil else args[args.len - 1] };
}

fn formLooksComplete(source: []const u8) bool {
    var depth: isize = 0;
    var in_string = false;
    var escaped = false;
    var comment = false;
    for (source) |byte| {
        if (comment) {
            if (byte == '\n') comment = false;
            continue;
        }
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            ';' => comment = true,
            '"' => in_string = true,
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            else => {},
        }
    }
    return !in_string and depth <= 0;
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  lizp                 Start the REPL, or read expressions from stdin
        \\  lizp -e EXPR         Evaluate an expression
        \\  lizp FILE            Evaluate a script file
        \\  lizp --help          Show this help
        \\
    );
}
