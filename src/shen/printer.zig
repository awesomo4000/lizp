const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;
const Vm = types.Vm;

// ============================================================
// Kλ Printer — Value → string
// ============================================================

pub fn printValue(vm: *const Vm, val: Value, buf: *std.ArrayListUnmanaged(u8)) !void {
    const alloc = vm.allocator;
    switch (val) {
        .nil => try buf.appendSlice(alloc, "()"),
        .boolean => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "?";
            try buf.appendSlice(alloc, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch "?";
            try buf.appendSlice(alloc, s);
        },
        .symbol => |idx| try buf.appendSlice(alloc, vm.pool.getName(idx)),
        .string => |s| {
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, s);
            try buf.append(alloc, '"');
        },
        .cons => {
            try buf.append(alloc, '(');
            var cur = val;
            var first = true;
            while (cur == .cons) {
                if (!first) try buf.append(alloc, ' ');
                first = false;
                try printValue(vm, cur.cons.car, buf);
                cur = cur.cons.cdr;
            }
            if (cur != .nil) {
                try buf.appendSlice(alloc, " . ");
                try printValue(vm, cur, buf);
            }
            try buf.append(alloc, ')');
        },
        .vector => try buf.appendSlice(alloc, "<vector>"),
        .closure => try buf.appendSlice(alloc, "<function>"),
        .native_fn => try buf.appendSlice(alloc, "<native>"),
        .stream => try buf.appendSlice(alloc, "<stream>"),
        .err => |e| {
            try buf.appendSlice(alloc, "error: ");
            try buf.appendSlice(alloc, e.message);
        },
    }
}

pub fn valueToString(vm: *const Vm, val: Value) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    try printValue(vm, val, &buf);
    return buf.toOwnedSlice(vm.allocator);
}
