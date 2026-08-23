const std = @import("std");
const poolside = @import("poolside");

const Node = struct { a: u64, b: u64 };
const P = poolside.PoolWithOptions(Node, .{ .track_provenance = false });

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn nsPerOp(elapsed: i96, operations: usize) f64 {
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(operations));
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;
    const count: usize = 200_000;
    const repetitions = 7;

    const pointers = try allocator.alloc(*Node, count);
    defer allocator.free(pointers);
    var initialized_pointers: usize = 0;
    defer for (pointers[0..initialized_pointers]) |pointer| allocator.destroy(pointer);
    for (pointers, 0..) |*pointer, i| {
        pointer.* = try allocator.create(Node);
        pointer.*.* = .{ .a = i, .b = i * 3 };
        initialized_pointers += 1;
    }

    const dense = try allocator.alloc(Node, count);
    defer allocator.free(dense);
    for (dense, 0..) |*node, i| node.* = .{ .a = i, .b = i * 3 };

    var pool = P.init(allocator);
    defer pool.deinit();
    const handles = try allocator.alloc(P.Handle, count);
    defer allocator.free(handles);
    for (handles, 0..) |*handle, i| {
        handle.* = try pool.create(.{ .a = i, .b = i * 3 });
    }

    const order = try allocator.alloc(u32, count);
    defer allocator.free(order);
    for (order, 0..) |*index, i| index.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(0x504f4f4c);
    prng.random().shuffle(u32, order);

    var pointer_best = std.math.inf(f64);
    var dense_best = std.math.inf(f64);
    var handle_best = std.math.inf(f64);
    var iteration_best = std.math.inf(f64);
    var sink: u64 = 0;
    for (0..repetitions) |_| {
        var start = now(io);
        for (order) |index| sink +%= pointers[index].a;
        pointer_best = @min(pointer_best, nsPerOp(now(io) - start, count));

        start = now(io);
        for (order) |index| sink +%= dense[index].a;
        dense_best = @min(dense_best, nsPerOp(now(io) - start, count));

        start = now(io);
        for (order) |index| sink +%= pool.expect(handles[index]).a;
        handle_best = @min(handle_best, nsPerOp(now(io) - start, count));

        start = now(io);
        var iterator_ = pool.iterator();
        while (iterator_.next()) |entry| sink +%= entry.value.a;
        iteration_best = @min(iteration_best, nsPerOp(now(io) - start, count));
    }
    std.mem.doNotOptimizeAway(sink);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("poolside ReleaseFast microbenchmark ({d} objects)\n", .{count});
    try stdout.print("  random allocated *T    {d:.2} ns/op\n", .{pointer_best});
    try stdout.print("  random dense index     {d:.2} ns/op\n", .{dense_best});
    try stdout.print("  random checked handle  {d:.2} ns/op ({d:.2}x dense)\n", .{ handle_best, handle_best / dense_best });
    try stdout.print("  dense pool iteration   {d:.2} ns/op\n", .{iteration_best});
    try stdout.flush();
}
