const std = @import("std");
const builtin = @import("builtin");
const reflect = @import("reflect.zig");

pub const Options = struct {
    /// Slots per independently allocated chunk. Slot addresses never move.
    chunk_len: usize = 512,
    /// Tests can use a small counter to exercise generation exhaustion.
    generation_bits: u16 = 32,
    /// Source locations increase slot size substantially, so default to Debug.
    track_provenance: bool = builtin.mode == .Debug,
};

pub fn Pool(comptime T: type) type {
    return PoolWithOptions(T, .{});
}

pub fn PoolWithOptions(comptime T: type, comptime options: Options) type {
    return PoolImpl(T, T, options);
}

/// Creates a pool whose handles are branded with `Tag`. Use distinct tags when
/// a program has multiple pools of the same value type and wants the compiler
/// to reject accidentally mixing their handles.
pub fn TaggedPool(comptime T: type, comptime Tag: type) type {
    return TaggedPoolWithOptions(T, Tag, .{});
}

pub fn TaggedPoolWithOptions(comptime T: type, comptime Tag: type, comptime options: Options) type {
    return PoolImpl(T, Tag, options);
}

fn PoolImpl(comptime T: type, comptime Tag: type, comptime options: Options) type {
    comptime {
        if (options.chunk_len == 0) @compileError("poolside chunk_len must be greater than zero");
        if (options.generation_bits < 2 or options.generation_bits > 64) {
            @compileError("poolside generation_bits must be between 2 and 64");
        }
    }

    const GenerationType = std.meta.Int(.unsigned, options.generation_bits);

    return struct {
        const Self = @This();
        const none_index = std.math.maxInt(u32);
        const Provenance = if (options.track_provenance) ?std.builtin.SourceLocation else void;

        pub const Value = T;
        pub const PoolTag = Tag;
        pub const Generation = GenerationType;
        pub const config = options;
        pub const CreateError = std.mem.Allocator.Error || error{OutOfCapacity};

        pub const Handle = packed struct {
            index: u32,
            generation: Generation,

            pub const none: Handle = .{ .index = none_index, .generation = 0 };

            pub fn isNone(handle: Handle) bool {
                return handle.index == none_index;
            }

            pub fn eql(a: Handle, b: Handle) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const Slot = struct {
            generation: Generation,
            free_next: u32,
            born_at: Provenance,
            killed_at: Provenance,
            value: T,
        };

        const Chunk = [options.chunk_len]Slot;

        allocator: std.mem.Allocator,
        chunks: std.ArrayList(*Chunk) = .empty,
        slot_count: u32 = 0,
        free_head: u32 = none_index,
        live_count: u32 = 0,
        retired_count: u32 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Deinitializes every live payload before releasing pool storage.
        pub fn deinit(self: *Self) void {
            var index: u32 = 0;
            while (index < self.slot_count) : (index += 1) {
                const current = self.slot(index);
                if (isLiveGeneration(current.generation)) {
                    deinitValue(&current.value, self.allocator);
                }
            }
            for (self.chunks.items) |chunk| self.allocator.destroy(chunk);
            self.chunks.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn create(self: *Self, value: T) CreateError!Handle {
            return self.createImpl(value, null);
        }

        pub fn createAt(self: *Self, value: T, source: std.builtin.SourceLocation) CreateError!Handle {
            return self.createImpl(value, source);
        }

        fn createImpl(self: *Self, value: T, source: ?std.builtin.SourceLocation) CreateError!Handle {
            if (self.free_head != none_index) {
                const index = self.free_head;
                const current = self.slot(index);
                self.free_head = current.free_next;
                std.debug.assert(current.generation != 0);
                std.debug.assert(!isLiveGeneration(current.generation));
                current.generation +%= 1;
                std.debug.assert(isLiveGeneration(current.generation));
                current.value = value;
                if (options.track_provenance) current.born_at = source;
                self.live_count += 1;
                return .{ .index = index, .generation = current.generation };
            }
            return self.createFresh(value, source);
        }

        fn createFresh(self: *Self, value: T, source: ?std.builtin.SourceLocation) CreateError!Handle {
            if (self.slot_count == none_index) return error.OutOfCapacity;

            const index = self.slot_count;
            const index_usize: usize = @intCast(index);
            const chunk_index = index_usize / options.chunk_len;
            if (chunk_index == self.chunks.items.len) {
                const chunk = try self.allocator.create(Chunk);
                errdefer self.allocator.destroy(chunk);
                try self.chunks.append(self.allocator, chunk);
            }

            self.slot_count += 1;
            self.live_count += 1;
            self.slot(index).* = .{
                .generation = 1,
                .free_next = none_index,
                .born_at = if (options.track_provenance) source else {},
                .killed_at = if (options.track_provenance) null else {},
                .value = value,
            };
            return .{ .index = index, .generation = 1 };
        }

        /// Destroys a live handle. Stale, forged, and already-dead handles are
        /// harmless no-ops. A generation that wraps to zero retires its slot.
        pub fn destroy(self: *Self, handle: Handle) bool {
            return self.destroyImpl(handle, null);
        }

        pub fn destroyAt(self: *Self, handle: Handle, source: std.builtin.SourceLocation) bool {
            return self.destroyImpl(handle, source);
        }

        fn destroyImpl(self: *Self, handle: Handle, source: ?std.builtin.SourceLocation) bool {
            const current = self.liveSlot(handle) orelse return false;
            deinitValue(&current.value, self.allocator);
            current.value = undefined;
            current.generation +%= 1;
            self.live_count -= 1;
            if (options.track_provenance) current.killed_at = source;

            if (current.generation == 0) {
                current.free_next = none_index;
                self.retired_count += 1;
            } else {
                std.debug.assert(!isLiveGeneration(current.generation));
                current.free_next = self.free_head;
                self.free_head = handle.index;
            }
            return true;
        }

        pub fn contains(self: *const Self, handle: Handle) bool {
            return self.liveSlotConst(handle) != null;
        }

        pub fn get(self: *Self, handle: Handle) ?*T {
            const current = self.liveSlot(handle) orelse return null;
            return &current.value;
        }

        pub fn getConst(self: *const Self, handle: Handle) ?*const T {
            const current = self.liveSlotConst(handle) orelse return null;
            return &current.value;
        }

        pub fn expect(self: *Self, handle: Handle) *T {
            return self.get(handle) orelse self.stale(handle);
        }

        pub fn expectConst(self: *const Self, handle: Handle) *const T {
            return self.getConst(handle) orelse self.stale(handle);
        }

        pub const ProvenanceInfo = struct {
            current_generation: Generation,
            live: bool,
            born_at: ?std.builtin.SourceLocation,
            killed_at: ?std.builtin.SourceLocation,
        };

        /// Returns diagnostics for the handle's slot when provenance is
        /// enabled. For a stale handle, the metadata describes the slot's
        /// current occupant and most recently recorded destruction.
        pub fn provenance(self: *const Self, handle: Handle) ?ProvenanceInfo {
            if (!options.track_provenance or handle.isNone() or handle.index >= self.slot_count) return null;
            const current = self.slotConst(handle.index);
            return .{
                .current_generation = current.generation,
                .live = isLiveGeneration(current.generation),
                .born_at = current.born_at,
                .killed_at = current.killed_at,
            };
        }

        fn stale(self: *const Self, handle: Handle) noreturn {
            if (options.track_provenance and !handle.isNone() and handle.index < self.slot_count) {
                const current = self.slotConst(handle.index);
                if (current.killed_at) |source| {
                    std.debug.panic(
                        "stale poolside handle {d}/{d}; last destroyed at {s}:{d}:{d} in {s}",
                        .{ handle.index, handle.generation, source.file, source.line, source.column, source.fn_name },
                    );
                }
            }
            std.debug.panic("stale poolside handle {d}/{d}", .{ handle.index, handle.generation });
        }

        /// Destroys all live values, invalidates their handles, and retains
        /// allocated chunks. Exhausted generations are retired, not recycled.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.clearImpl(null);
        }

        pub fn clearRetainingCapacityAt(self: *Self, source: std.builtin.SourceLocation) void {
            self.clearImpl(source);
        }

        fn clearImpl(self: *Self, source: ?std.builtin.SourceLocation) void {
            self.free_head = none_index;
            self.live_count = 0;
            self.retired_count = 0;

            var index = self.slot_count;
            while (index > 0) {
                index -= 1;
                const current = self.slot(index);
                if (isLiveGeneration(current.generation)) {
                    deinitValue(&current.value, self.allocator);
                    current.value = undefined;
                    current.generation +%= 1;
                    if (options.track_provenance) current.killed_at = source;
                }
                if (current.generation == 0) {
                    current.free_next = none_index;
                    self.retired_count += 1;
                } else {
                    current.free_next = self.free_head;
                    self.free_head = index;
                }
            }
        }

        pub const Entry = struct {
            handle: Handle,
            value: *T,
        };

        pub const Iterator = struct {
            pool: *Self,
            next_index: u32 = 0,

            pub fn next(iter: *Iterator) ?Entry {
                while (iter.next_index < iter.pool.slot_count) {
                    const index = iter.next_index;
                    iter.next_index += 1;
                    const current = iter.pool.slot(index);
                    if (isLiveGeneration(current.generation)) {
                        return .{
                            .handle = .{ .index = index, .generation = current.generation },
                            .value = &current.value,
                        };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }

        pub const ConstEntry = struct {
            handle: Handle,
            value: *const T,
        };

        pub const ConstIterator = struct {
            pool: *const Self,
            next_index: u32 = 0,

            pub fn next(iter: *ConstIterator) ?ConstEntry {
                while (iter.next_index < iter.pool.slot_count) {
                    const index = iter.next_index;
                    iter.next_index += 1;
                    const current = iter.pool.slotConst(index);
                    if (isLiveGeneration(current.generation)) {
                        return .{
                            .handle = .{ .index = index, .generation = current.generation },
                            .value = &current.value,
                        };
                    }
                }
                return null;
            }
        };

        pub fn constIterator(self: *const Self) ConstIterator {
            return .{ .pool = self };
        }

        /// Returns live handles not reachable from `roots` by recursively
        /// walking handle-valued fields inside `T`.
        pub fn findUnreachable(
            self: *const Self,
            scratch: std.mem.Allocator,
            roots: []const Handle,
        ) std.mem.Allocator.Error![]Handle {
            const seen = try scratch.alloc(bool, @intCast(self.slot_count));
            defer scratch.free(seen);
            @memset(seen, false);

            var stack: std.ArrayList(Handle) = .empty;
            defer stack.deinit(scratch);
            try stack.ensureTotalCapacity(scratch, @intCast(self.live_count));

            const Mark = struct {
                pool: *const Self,
                seen: []bool,
                stack: *std.ArrayList(Handle),

                fn push(mark: *@This(), handle: Handle) void {
                    if (!mark.pool.contains(handle)) return;
                    if (mark.seen[handle.index]) return;
                    mark.seen[handle.index] = true;
                    mark.stack.appendAssumeCapacity(handle);
                }
            };
            var mark = Mark{ .pool = self, .seen = seen, .stack = &stack };
            for (roots) |root| mark.push(root);
            while (stack.pop()) |handle| {
                reflect.visitHandles(Handle, T, self.getConst(handle).?, &mark, Mark.push);
            }

            var result: std.ArrayList(Handle) = .empty;
            errdefer result.deinit(scratch);
            try result.ensureTotalCapacity(scratch, @intCast(self.live_count));
            var index: u32 = 0;
            while (index < self.slot_count) : (index += 1) {
                const current = self.slotConst(index);
                if (isLiveGeneration(current.generation) and !seen[index]) {
                    result.appendAssumeCapacity(.{ .index = index, .generation = current.generation });
                }
            }
            return result.toOwnedSlice(scratch);
        }

        pub fn liveCount(self: *const Self) u32 {
            return self.live_count;
        }

        pub fn slotCount(self: *const Self) u32 {
            return self.slot_count;
        }

        pub fn retiredCount(self: *const Self) u32 {
            return self.retired_count;
        }

        fn slot(self: *Self, index: u32) *Slot {
            const i: usize = @intCast(index);
            return &self.chunks.items[i / options.chunk_len][i % options.chunk_len];
        }

        fn slotConst(self: *const Self, index: u32) *const Slot {
            const i: usize = @intCast(index);
            return &self.chunks.items[i / options.chunk_len][i % options.chunk_len];
        }

        fn liveSlot(self: *Self, handle: Handle) ?*Slot {
            if (handle.isNone() or handle.index >= self.slot_count) return null;
            const current = self.slot(handle.index);
            if (!isLiveGeneration(current.generation) or current.generation != handle.generation) return null;
            return current;
        }

        fn liveSlotConst(self: *const Self, handle: Handle) ?*const Slot {
            if (handle.isNone() or handle.index >= self.slot_count) return null;
            const current = self.slotConst(handle.index);
            if (!isLiveGeneration(current.generation) or current.generation != handle.generation) return null;
            return current;
        }

        fn isLiveGeneration(generation: Generation) bool {
            return generation & 1 == 1;
        }

        fn deinitValue(value: *T, allocator: std.mem.Allocator) void {
            switch (comptime deinitStyle(T)) {
                .none => {},
                .self_only => value.deinit(),
                .allocator => value.deinit(allocator),
            }
        }
    };
}

const DeinitStyle = enum { none, self_only, allocator };

fn deinitStyle(comptime T: type) DeinitStyle {
    const has_deinit = switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
    if (!has_deinit) return .none;

    const signature = @typeInfo(@TypeOf(T.deinit));
    const function = switch (signature) {
        .@"fn" => |info| info,
        else => invalidDeinit(T),
    };
    if (function.return_type == null or function.return_type.? != void) invalidDeinit(T);
    if (function.params.len != 1 and function.params.len != 2) invalidDeinit(T);
    if (function.params[0].type == null or function.params[0].type.? != *T) invalidDeinit(T);
    if (function.params.len == 1) return .self_only;
    if (function.params[1].type == null or function.params[1].type.? != std.mem.Allocator) invalidDeinit(T);
    return .allocator;
}

fn invalidDeinit(comptime T: type) noreturn {
    @compileError(std.fmt.comptimePrint(
        "{s}.deinit must be `fn (*{s}) void` or `fn (*{s}, std.mem.Allocator) void`",
        .{ @typeName(T), @typeName(T), @typeName(T) },
    ));
}

const ReachabilityPool = Pool(ReachabilityNode);
const ReachabilityHandle = ReachabilityPool.Handle;
const ReachabilityNode = struct {
    parent: ReachabilityHandle = ReachabilityHandle.none,
    children: std.ArrayList(ReachabilityHandle) = .empty,
    optional_edge: ?ReachabilityHandle = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
    }
};

test "create, mutate, destroy, and reuse reject stale handles" {
    const testing = std.testing;
    const P = Pool(u64);
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.create(10);
    try testing.expectEqual(@as(usize, 8), @sizeOf(P.Handle));
    try testing.expect(pool.contains(first));
    try testing.expectEqual(@as(u64, 10), pool.getConst(first).?.*);
    pool.expect(first).* = 20;
    try testing.expectEqual(@as(u64, 20), pool.expectConst(first).*);

    try testing.expect(pool.destroy(first));
    try testing.expect(!pool.destroy(first));
    try testing.expect(pool.get(first) == null);

    const second = try pool.create(30);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);
    try testing.expect(pool.get(first) == null);
    try testing.expectEqual(@as(u64, 30), pool.expect(second).*);
}

test "tagged pools give same-value pools distinct handle types" {
    const FirstTag = struct {};
    const SecondTag = struct {};
    const First = TaggedPool(u32, FirstTag);
    const Second = TaggedPool(u32, SecondTag);
    comptime std.debug.assert(First.Handle != Second.Handle);
}

test "explicit provenance records creation and destruction sites" {
    const testing = std.testing;
    const P = PoolWithOptions(u8, .{ .track_provenance = true });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const born = @src();
    const handle = try pool.createAt(1, born);
    const live_info = pool.provenance(handle).?;
    try testing.expect(live_info.live);
    try testing.expectEqual(born.line, live_info.born_at.?.line);

    const killed = @src();
    try testing.expect(pool.destroyAt(handle, killed));
    const dead_info = pool.provenance(handle).?;
    try testing.expect(!dead_info.live);
    try testing.expectEqual(killed.line, dead_info.killed_at.?.line);

    const cleared = try pool.createAt(2, @src());
    pool.clearRetainingCapacity();
    try testing.expect(pool.provenance(cleared).?.killed_at == null);

    const cleared_at = try pool.createAt(3, @src());
    const clear_source = @src();
    pool.clearRetainingCapacityAt(clear_source);
    try testing.expectEqual(clear_source.line, pool.provenance(cleared_at).?.killed_at.?.line);
}

test "disabled provenance configuration is compiled and returns null" {
    const testing = std.testing;
    const P = PoolWithOptions(u8, .{ .track_provenance = false });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const handle = try pool.createAt(1, @src());
    try testing.expect(pool.provenance(handle) == null);
    try testing.expect(pool.destroyAt(handle, @src()));
    try testing.expect(pool.provenance(handle) == null);
}

test "an even-generation forged handle cannot destroy a free slot" {
    const testing = std.testing;
    const P = PoolWithOptions(u8, .{ .generation_bits = 8 });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const handle = try pool.create(1);
    try testing.expect(pool.destroy(handle));
    const forged = P.Handle{ .index = handle.index, .generation = handle.generation +% 1 };
    try testing.expect(!pool.contains(forged));
    try testing.expect(!pool.destroy(forged));
    try testing.expectEqual(@as(u32, 0), pool.liveCount());
    try testing.expect(pool.get(P.Handle.none) == null);
    try testing.expect(!pool.destroy(.{ .index = 1000, .generation = 1 }));
}

test "generation exhaustion retires a slot before ABA aliasing" {
    const testing = std.testing;
    const P = PoolWithOptions(u8, .{ .chunk_len = 1, .generation_bits = 2 });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const generation_one = try pool.create(1);
    try testing.expect(pool.destroy(generation_one));
    const generation_three = try pool.create(2);
    try testing.expectEqual(generation_one.index, generation_three.index);
    try testing.expectEqual(@as(P.Generation, 3), generation_three.generation);
    try testing.expect(pool.destroy(generation_three));
    try testing.expectEqual(@as(u32, 1), pool.retiredCount());

    const fresh = try pool.create(3);
    try testing.expect(fresh.index != generation_one.index);
    try testing.expect(pool.get(generation_one) == null);
    try testing.expect(pool.get(generation_three) == null);
}

test "clear retires a generation that wraps" {
    const testing = std.testing;
    const P = PoolWithOptions(u8, .{ .chunk_len = 1, .generation_bits = 2 });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.create(1);
    try testing.expect(pool.destroy(first));
    const last_generation = try pool.create(2);
    pool.clearRetainingCapacity();
    try testing.expectEqual(@as(u32, 1), pool.retiredCount());
    try testing.expect(pool.get(last_generation) == null);
    const fresh = try pool.create(3);
    try testing.expect(fresh.index != last_generation.index);
}

test "slot addresses stay stable as the chunk table grows" {
    const testing = std.testing;
    const P = PoolWithOptions(u64, .{ .chunk_len = 2 });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.create(1234);
    const pointer = pool.get(first).?;
    for (0..100) |i| _ = try pool.create(i);
    try testing.expectEqual(@intFromPtr(pointer), @intFromPtr(pool.get(first).?));
    try testing.expectEqual(@as(u64, 1234), pointer.*);
}

test "iterator skips free and retired slots" {
    const testing = std.testing;
    const P = Pool(u32);
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const a = try pool.create(1);
    const b = try pool.create(2);
    _ = try pool.create(4);
    try testing.expect(pool.destroy(b));

    var sum: u32 = 0;
    var count: usize = 0;
    var iterator_ = pool.iterator();
    while (iterator_.next()) |entry| {
        try testing.expect(pool.contains(entry.handle));
        sum += entry.value.*;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u32, 5), sum);
    try testing.expect(pool.contains(a));

    const const_pool: *const P = &pool;
    var const_sum: u32 = 0;
    var const_count: usize = 0;
    var const_iterator = const_pool.constIterator();
    while (const_iterator.next()) |entry| {
        const_sum += entry.value.*;
        const_count += 1;
    }
    try testing.expectEqual(count, const_count);
    try testing.expectEqual(sum, const_sum);
}

test "clearRetainingCapacity invalidates handles and calls payload deinit" {
    const testing = std.testing;
    const Payload = struct {
        deinits: *usize,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = allocator;
            self.deinits.* += 1;
        }
    };
    const P = Pool(Payload);
    var count: usize = 0;
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    const a = try pool.create(.{ .deinits = &count });
    const b = try pool.create(.{ .deinits = &count });
    try testing.expect(pool.destroy(a));
    try testing.expectEqual(@as(usize, 1), count);
    pool.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(pool.get(b) == null);
    try testing.expectEqual(@as(u32, 0), pool.liveCount());

    _ = try pool.create(.{ .deinits = &count });
}

test "clear rebuilds a duplicate-free reusable free list" {
    const testing = std.testing;
    const P = PoolWithOptions(u16, .{ .chunk_len = 3 });
    var pool = P.init(testing.allocator);
    defer pool.deinit();

    var old: [20]P.Handle = undefined;
    for (&old, 0..) |*handle, i| handle.* = try pool.create(@intCast(i));
    for (old, 0..) |handle, i| {
        if (i % 3 == 0) try testing.expect(pool.destroy(handle));
    }
    pool.clearRetainingCapacity();

    var seen = [_]bool{false} ** old.len;
    for (0..old.len) |i| {
        const handle = try pool.create(@intCast(i));
        try testing.expect(handle.index < seen.len);
        try testing.expect(!seen[handle.index]);
        seen[handle.index] = true;
    }
    for (old) |handle| try testing.expect(pool.get(handle) == null);
    try testing.expectEqual(@as(u32, old.len), pool.liveCount());
    try testing.expectEqual(@as(u32, old.len), pool.slotCount());
}

test "pool deinit cleans up remaining live payloads" {
    const testing = std.testing;
    const Payload = struct {
        deinits: *usize,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = allocator;
            self.deinits.* += 1;
        }
    };
    var count: usize = 0;
    var pool = Pool(Payload).init(testing.allocator);
    _ = try pool.create(.{ .deinits = &count });
    _ = try pool.create(.{ .deinits = &count });
    pool.deinit();
    try testing.expectEqual(@as(usize, 2), count);
}

test "payload deinit may omit the allocator parameter" {
    const testing = std.testing;
    const Payload = struct {
        deinits: *usize,

        pub fn deinit(self: *@This()) void {
            self.deinits.* += 1;
        }
    };
    var count: usize = 0;
    var pool = Pool(Payload).init(testing.allocator);
    defer pool.deinit();
    const handle = try pool.create(.{ .deinits = &count });
    try testing.expect(pool.destroy(handle));
    try testing.expectEqual(@as(usize, 1), count);
}

test "findUnreachable follows nested handles and ignores stale edges" {
    const testing = std.testing;
    var pool = ReachabilityPool.init(testing.allocator);
    defer pool.deinit();
    const root = try pool.create(.{});
    const child = try pool.create(.{ .parent = root });
    const grandchild = try pool.create(.{ .parent = child });
    const stale = try pool.create(.{});
    try testing.expect(pool.destroy(stale));
    pool.expect(root).optional_edge = stale;
    try pool.expect(root).children.append(testing.allocator, child);
    try pool.expect(child).children.append(testing.allocator, grandchild);

    var leaked = try pool.findUnreachable(testing.allocator, &.{root});
    try testing.expectEqual(@as(usize, 0), leaked.len);
    testing.allocator.free(leaked);

    pool.expect(root).children.clearRetainingCapacity();
    leaked = try pool.findUnreachable(testing.allocator, &.{root});
    defer testing.allocator.free(leaked);
    try testing.expectEqual(@as(usize, 2), leaked.len);
}

test "randomized operations agree with a simple generation model" {
    const testing = std.testing;
    const P = PoolWithOptions(u32, .{ .chunk_len = 7, .generation_bits = 8 });
    const Model = struct { generation: P.Generation, value: u32, live: bool };
    var pool = P.init(testing.allocator);
    defer pool.deinit();
    var model: std.ArrayList(Model) = .empty;
    defer model.deinit(testing.allocator);
    var history: std.ArrayList(P.Handle) = .empty;
    defer history.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(0x504f4f4c53494445);
    const random = prng.random();

    // Force the independent model through retirement before random traffic.
    // With u8 generations, the 128th destruction wraps the first slot to zero.
    var churn = try pool.create(0xffff_0000);
    try history.append(testing.allocator, churn);
    try model.append(testing.allocator, .{
        .generation = churn.generation,
        .value = 0xffff_0000,
        .live = true,
    });
    for (0..128) |iteration| {
        try testing.expect(pool.destroy(churn));
        model.items[churn.index].live = false;
        const value: u32 = 0xffff_0000 + @as(u32, @intCast(iteration));
        churn = try pool.create(value);
        try history.append(testing.allocator, churn);
        while (model.items.len <= churn.index) {
            try model.append(testing.allocator, .{ .generation = 0, .value = 0, .live = false });
        }
        model.items[churn.index] = .{
            .generation = churn.generation,
            .value = value,
            .live = true,
        };
    }
    try testing.expect(pool.retiredCount() > 0);

    for (0..20_000) |step| {
        const should_create = history.items.len == 0 or random.uintLessThan(u8, 100) < 45;
        if (should_create) {
            const value: u32 = @intCast(step);
            const handle = try pool.create(value);
            try history.append(testing.allocator, handle);
            while (model.items.len <= handle.index) {
                try model.append(testing.allocator, .{ .generation = 0, .value = 0, .live = false });
            }
            model.items[handle.index] = .{ .generation = handle.generation, .value = value, .live = true };
        } else {
            const handle = history.items[random.uintLessThan(usize, history.items.len)];
            const expected = handle.index < model.items.len and
                model.items[handle.index].live and
                model.items[handle.index].generation == handle.generation;
            if (random.boolean()) {
                try testing.expectEqual(expected, pool.destroy(handle));
                if (expected) model.items[handle.index].live = false;
            } else {
                const actual = pool.get(handle);
                try testing.expectEqual(expected, actual != null);
                if (expected) try testing.expectEqual(model.items[handle.index].value, actual.?.*);
            }
        }

        var expected_live: u32 = 0;
        for (model.items) |entry| expected_live += @intFromBool(entry.live);
        try testing.expectEqual(expected_live, pool.liveCount());
    }
    try testing.expect(pool.retiredCount() > 0);
}

fn allocationFailureWork(allocator: std.mem.Allocator) !void {
    const P = PoolWithOptions(u32, .{ .chunk_len = 3 });
    var pool = P.init(allocator);
    defer pool.deinit();
    var roots: [4]P.Handle = undefined;
    for (0..40) |i| {
        const handle = try pool.create(@intCast(i));
        if (i < roots.len) roots[i] = handle;
    }
    const leaked = try pool.findUnreachable(allocator, &roots);
    defer allocator.free(leaked);
}

test "all allocation failures unwind without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailureWork,
        .{},
    );
}
