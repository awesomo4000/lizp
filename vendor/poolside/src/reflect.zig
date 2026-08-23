const std = @import("std");

/// Visits every value whose type is exactly `Handle` inside `value`.
///
/// Struct fields, tagged unions, successful error-union payloads, optionals,
/// arrays, vectors, and slices are traversed recursively. Single-item and
/// many-item pointers are deliberately not followed: the walker cannot know
/// whether they are valid or owned.
pub fn visitHandles(
    comptime Handle: type,
    comptime T: type,
    value: *const T,
    context: anytype,
    comptime visit: fn (@TypeOf(context), Handle) void,
) void {
    if (T == Handle) {
        visit(context, value.*);
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (info.layout == .@"packed") {
                    // Taking the address of a packed field produces a bit
                    // pointer, which cannot be passed as `*const field.type`.
                    const field_value = @field(value.*, field.name);
                    visitHandles(Handle, field.type, &field_value, context, visit);
                } else {
                    visitHandles(Handle, field.type, &@field(value, field.name), context, visit);
                }
            }
        },
        .optional => |info| {
            if (value.*) |*payload| {
                visitHandles(Handle, info.child, payload, context, visit);
            }
        },
        .array => |info| {
            for (value) |*element| {
                visitHandles(Handle, info.child, element, context, visit);
            }
        },
        .vector => |info| {
            for (0..info.len) |i| {
                const element = value.*[i];
                visitHandles(Handle, info.child, &element, context, visit);
            }
        },
        .pointer => |info| {
            if (info.size == .slice) {
                for (value.*) |*element| {
                    visitHandles(Handle, info.child, element, context, visit);
                }
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse return;
            const active = std.meta.activeTag(value.*);
            inline for (info.fields) |field| {
                if (active == @field(Tag, field.name)) {
                    visitHandles(Handle, field.type, &@field(value, field.name), context, visit);
                    return;
                }
            }
        },
        .error_union => |info| {
            if (value.*) |*payload| {
                visitHandles(Handle, info.payload, payload, context, visit);
            } else |_| {}
        },
        else => {},
    }
}

test "visitHandles traverses nested containers but not single pointers" {
    const testing = std.testing;
    const Handle = packed struct { index: u32, generation: u32 };
    const Choice = union(enum) { handle: Handle, number: u32 };
    const Nested = struct {
        direct: Handle,
        maybe: ?Handle,
        array: [2]Handle,
        choice: Choice,
        pointer: *const Handle,
    };
    const ignored = Handle{ .index = 99, .generation = 1 };
    const value = Nested{
        .direct = .{ .index = 1, .generation = 1 },
        .maybe = .{ .index = 2, .generation = 1 },
        .array = .{
            .{ .index = 3, .generation = 1 },
            .{ .index = 4, .generation = 1 },
        },
        .choice = .{ .handle = .{ .index = 5, .generation = 1 } },
        .pointer = &ignored,
    };

    const Collector = struct {
        count: usize = 0,
        sum: u32 = 0,

        fn add(self: *@This(), handle: Handle) void {
            self.count += 1;
            self.sum += handle.index;
        }
    };
    var collector = Collector{};
    visitHandles(Handle, Nested, &value, &collector, Collector.add);
    try testing.expectEqual(@as(usize, 5), collector.count);
    try testing.expectEqual(@as(u32, 15), collector.sum);
}

test "visitHandles copies packed fields before traversing them" {
    const testing = std.testing;
    const Handle = packed struct { index: u32, generation: u32 };
    const Compact = packed struct {
        prefix: u8,
        handle: Handle,
    };
    const value = Compact{
        .prefix = 7,
        .handle = .{ .index = 42, .generation = 1 },
    };
    const Collector = struct {
        count: usize = 0,
        index: u32 = 0,

        fn add(self: *@This(), handle: Handle) void {
            self.count += 1;
            self.index = handle.index;
        }
    };
    var collector = Collector{};
    visitHandles(Handle, Compact, &value, &collector, Collector.add);
    try testing.expectEqual(@as(usize, 1), collector.count);
    try testing.expectEqual(@as(u32, 42), collector.index);
}

test "visitHandles traverses successful error union payloads" {
    const testing = std.testing;
    const Handle = packed struct { index: u32, generation: u32 };
    const Value = struct { edge: anyerror!Handle };
    const success = Value{ .edge = Handle{ .index = 9, .generation = 1 } };
    const failure = Value{ .edge = error.Missing };
    const Collector = struct {
        count: usize = 0,

        fn add(self: *@This(), handle: Handle) void {
            _ = handle;
            self.count += 1;
        }
    };

    var collector = Collector{};
    visitHandles(Handle, Value, &success, &collector, Collector.add);
    try testing.expectEqual(@as(usize, 1), collector.count);
    visitHandles(Handle, Value, &failure, &collector, Collector.add);
    try testing.expectEqual(@as(usize, 1), collector.count);
}

test "visitHandles deliberately does not traverse hash map storage" {
    const testing = std.testing;
    const Handle = packed struct { index: u32, generation: u32 };
    var map = std.AutoHashMap(Handle, Handle).init(testing.allocator);
    defer map.deinit();
    try map.put(
        .{ .index = 1, .generation = 1 },
        .{ .index = 2, .generation = 1 },
    );
    const Collector = struct {
        count: usize = 0,

        fn add(self: *@This(), handle: Handle) void {
            _ = handle;
            self.count += 1;
        }
    };
    var collector = Collector{};
    visitHandles(Handle, @TypeOf(map), &map, &collector, Collector.add);
    try testing.expectEqual(@as(usize, 0), collector.count);
}
