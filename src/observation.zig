//! Sans-I/O observation primitives for Lizp.
//!
//! This module contains only structured event data, masks, the observer
//! callback contract, and a fixed-capacity in-memory journal. It performs no
//! I/O and the journal performs no heap allocation.

const std = @import("std");
const source = @import("source.zig");
const condition = @import("condition.zig");

pub const LaneId = enum(u32) {
    main = 0,
    _,
};

pub const EvaluationId = enum(u64) {
    none = 0,
    _,
};

pub const ContextId = enum(u64) {
    none = 0,
    _,
};

pub const EventId = struct {
    lane: LaneId,
    ordinal: u64,

    pub fn eql(a: EventId, b: EventId) bool {
        return a.lane == b.lane and a.ordinal == b.ordinal;
    }
};

/// A stable generational identity for a Lizp heap object. It deliberately
/// mirrors the public ObjectRef representation without exposing a pointer.
pub const EntityId = packed struct {
    index: u32,
    generation: u32,

    pub const none: EntityId = .{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    pub fn isNone(id: EntityId) bool {
        return id.index == std.math.maxInt(u32);
    }
};

pub const SourceId = source.Id;
/// Immutable byte range in a Runtime-owned source record.
pub const SourceSpan = source.Span;
pub const ExpansionOriginId = source.OriginId;

pub const ValueKind = enum {
    nil,
    boolean,
    integer,
    symbol,
    object,
    native,
};

pub const EvaluationOrigin = enum {
    source,
    value,
    host_call,
};

pub const EvaluationStatus = enum {
    returned,
    condition,
    cancelled,
    paused,
    host_failure,
};

pub const GcKind = enum {
    nursery,
    full,
};

pub const ObjectKind = enum {
    pair,
    vector,
    string,
    closure,
    environment,
    syntax,
};

pub const EventKind = enum(u8) {
    evaluation_started,
    evaluation_finished,
    call_entered,
    call_returned,
    tail_called,
    native_entered,
    native_returned,
    condition_raised,
    gc_started,
    gc_finished,
    definition_committed,
    object_allocated,
    object_reclaimed,
};

const event_kind_count = @typeInfo(EventKind).@"enum".fields.len;
const all_event_bits: u64 = if (event_kind_count == 64)
    std.math.maxInt(u64)
else
    (@as(u64, 1) << event_kind_count) - 1;

pub const EventMask = struct {
    bits: u64,

    pub fn all() EventMask {
        return .{ .bits = all_event_bits };
    }

    pub fn none() EventMask {
        return .{ .bits = 0 };
    }

    /// The normal semantic stream. Per-object allocation traffic is opt-in.
    pub fn standard() EventMask {
        var result = EventMask.all();
        result.remove(.object_allocated);
        result.remove(.object_reclaimed);
        return result;
    }

    pub fn fromKinds(kinds: []const EventKind) EventMask {
        var result = EventMask.none();
        for (kinds) |kind| result.insert(kind);
        return result;
    }

    pub fn insert(self: *EventMask, kind: EventKind) void {
        self.bits |= bitFor(kind);
    }

    pub fn remove(self: *EventMask, kind: EventKind) void {
        self.bits &= ~bitFor(kind);
    }

    pub fn contains(self: EventMask, kind: EventKind) bool {
        return self.bits & bitFor(kind) != 0;
    }

    fn bitFor(kind: EventKind) u64 {
        return @as(u64, 1) << @intCast(@intFromEnum(kind));
    }
};

pub const EventHeader = struct {
    id: EventId,
    evaluation: EvaluationId,
    context: ContextId,
    cause: ?EventId = null,
    span: ?SourceSpan = null,
    origin: ?ExpansionOriginId = null,
};

pub const EvaluationStarted = struct {
    origin: EvaluationOrigin,
    environment: EntityId,
    source: ?SourceId,
};

pub const EvaluationFinished = struct {
    status: EvaluationStatus,
    result: ?ValueKind,
    heap_live: u32,
};

pub const CallEntered = struct {
    parent: ContextId,
    callee: EntityId,
    argument_count: u32,
};

pub const CallReturned = struct {
    result: ValueKind,
};

pub const TailCalled = struct {
    from: ContextId,
    to: ContextId,
};

pub const NativeEntered = struct {
    parent: ContextId,
    native_index: u32,
    name: u32,
    argument_count: u32,
};

pub const NativeReturned = struct {
    native_index: u32,
    name: u32,
    result: ValueKind,
};

pub const ConditionRaised = struct {
    condition: condition.Id,
    code: condition.Code,
    phase: condition.Phase,
};

pub const GcStarted = struct {
    kind: GcKind,
    heap_live_before: u32,
    candidates: u32,
};

pub const GcFinished = struct {
    kind: GcKind,
    heap_live_before: u32,
    heap_live_after: u32,
    reclaimed: u32,
};

pub const DefinitionCommitted = struct {
    environment: EntityId,
    symbol: u32,
    replaced: bool,
    value: ValueKind,
};

pub const ObjectEvent = struct {
    object: EntityId,
    kind: ObjectKind,
};

pub const EventData = union(EventKind) {
    evaluation_started: EvaluationStarted,
    evaluation_finished: EvaluationFinished,
    call_entered: CallEntered,
    call_returned: CallReturned,
    tail_called: TailCalled,
    native_entered: NativeEntered,
    native_returned: NativeReturned,
    condition_raised: ConditionRaised,
    gc_started: GcStarted,
    gc_finished: GcFinished,
    definition_committed: DefinitionCommitted,
    object_allocated: ObjectEvent,
    object_reclaimed: ObjectEvent,
};

pub const Event = struct {
    header: EventHeader,
    data: EventData,

    pub fn kind(self: Event) EventKind {
        return std.meta.activeTag(self.data);
    }
};

pub const ObservationAction = enum {
    continue_,
    cancel,
    /// Reserved for a resumable debugger. Lizp currently reports this as a paused
    /// evaluation but does not yet expose a resumption object.
    pause,
};

pub const EventCallback = *const fn (
    context: ?*anyopaque,
    event: Event,
) ObservationAction;

/// Observers are synchronous, trusted, and must not re-enter or mutate the
/// Runtime that is currently emitting an event. They should copy only the
/// metadata they need; event payloads do not pin Lizp heap objects.
pub const Observer = struct {
    context: ?*anyopaque = null,
    mask: EventMask = EventMask.standard(),
    on_event: EventCallback,
};

/// A no-allocation ring journal suitable for tests, embedded diagnostics, and
/// as the first consumer of the observation spine.
pub fn FixedEventJournal(comptime capacity: usize) type {
    comptime {
        if (capacity == 0) @compileError("FixedEventJournal capacity must be greater than zero");
    }

    return struct {
        const Self = @This();

        events: [capacity]Event = undefined,
        start: usize = 0,
        len: usize = 0,
        dropped: u64 = 0,
        action: ObservationAction = .continue_,

        pub fn observer(self: *Self, mask: EventMask) Observer {
            return .{
                .context = self,
                .mask = mask,
                .on_event = receive,
            };
        }

        pub fn observerAll(self: *Self) Observer {
            return self.observer(EventMask.all());
        }

        pub fn clear(self: *Self) void {
            self.start = 0;
            self.len = 0;
            self.dropped = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn droppedCount(self: *const Self) u64 {
            return self.dropped;
        }

        pub fn at(self: *const Self, logical_index: usize) ?Event {
            if (logical_index >= self.len) return null;
            return self.events[(self.start + logical_index) % capacity];
        }

        pub fn setAction(self: *Self, action: ObservationAction) void {
            self.action = action;
        }

        fn receive(context: ?*anyopaque, event: Event) ObservationAction {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.append(event);
            return self.action;
        }

        fn append(self: *Self, event: Event) void {
            if (self.len < capacity) {
                const index = (self.start + self.len) % capacity;
                self.events[index] = event;
                self.len += 1;
                return;
            }

            self.events[self.start] = event;
            self.start = (self.start + 1) % capacity;
            self.dropped +%= 1;
        }
    };
}

test "fixed journal preserves order and reports overwritten events" {
    const Journal = FixedEventJournal(2);
    var journal = Journal{};
    const observer = journal.observerAll();

    const base = EventHeader{
        .id = .{ .lane = .main, .ordinal = 1 },
        .evaluation = .none,
        .context = .none,
    };
    _ = observer.on_event(observer.context, .{
        .header = base,
        .data = .{ .condition_raised = .{ .condition = @enumFromInt(1), .code = .internal, .phase = .runtime } },
    });
    var second = base;
    second.id.ordinal = 2;
    _ = observer.on_event(observer.context, .{
        .header = second,
        .data = .{ .condition_raised = .{ .condition = @enumFromInt(2), .code = .internal, .phase = .runtime } },
    });
    var third = base;
    third.id.ordinal = 3;
    _ = observer.on_event(observer.context, .{
        .header = third,
        .data = .{ .condition_raised = .{ .condition = @enumFromInt(3), .code = .internal, .phase = .runtime } },
    });

    try std.testing.expectEqual(@as(usize, 2), journal.count());
    try std.testing.expectEqual(@as(u64, 1), journal.droppedCount());
    try std.testing.expectEqual(@as(u64, 2), journal.at(0).?.header.id.ordinal);
    try std.testing.expectEqual(@as(u64, 3), journal.at(1).?.header.id.ordinal);
}
