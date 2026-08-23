const std = @import("std");
const lizp = @import("lizp");

pub fn main(init: std.process.Init) !void {
    const Journal = lizp.FixedEventJournal(128);
    var journal = Journal{};

    var runtime = try lizp.Runtime.initWithOptions(init.gpa, .{
        .observer = journal.observer(lizp.EventMask.standard()),
        .evaluation_gc_interval = 64,
    });
    defer runtime.deinit();

    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = "(do (defn sum-to [n acc] " ++
                "      (if (= n 0) acc (sum-to (- n 1) (+ acc n)))) " ++
                "    (sum-to 10 0))",
            .source_name = "example://observation",
        },
    });
    const result = switch (report.outcome) {
        .returned => |value| value,
        else => return error.UnexpectedEvaluationOutcome,
    };

    var buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_file.interface;

    try stdout.print("result: ", .{});
    try runtime.writeValue(stdout, result);
    try stdout.writeByte('\n');
    try stdout.print("events retained: {d}, overwritten: {d}\n", .{
        journal.count(),
        journal.droppedCount(),
    });

    for (0..journal.count()) |index| {
        const event = journal.at(index).?;
        try stdout.print("{d: >3}  {s: <22} eval={d} ctx={d}", .{
            event.header.id.ordinal,
            @tagName(event.kind()),
            @intFromEnum(event.header.evaluation),
            @intFromEnum(event.header.context),
        });
        if (event.header.span) |source_span| {
            const view = runtime.sourceView(source_span.source).?;
            const location = runtime.sourceLocation(source_span).?;
            try stdout.print("  {s}:{d}:{d}", .{
                view.name,
                location.start.line,
                location.start.column,
            });
        }
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}
