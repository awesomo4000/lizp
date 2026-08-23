//! Lizp: a small embeddable Lisp for Zig.
//!
//! The runtime uses Poolside generational handles for stable object storage and
//! supplies an explicit mark-sweep collector. An evaluation-local nursery is
//! also reclaimed at evaluator safe points so proper tail calls can run in
//! bounded space without collecting pre-existing host-held values.

const std = @import("std");
const poolside = @import("poolside");
pub const observation = @import("observation.zig");
pub const conditions = @import("condition.zig");
pub const source_info = @import("source.zig");

pub const Observer = observation.Observer;
pub const Event = observation.Event;
pub const EventData = observation.EventData;
pub const EventKind = observation.EventKind;
pub const EventMask = observation.EventMask;
pub const ObservationAction = observation.ObservationAction;
pub const EventId = observation.EventId;
pub const EvaluationId = observation.EvaluationId;
pub const ContextId = observation.ContextId;
pub const LaneId = observation.LaneId;
pub const SourceId = source_info.Id;
pub const SourceSpan = source_info.Span;
pub const SourcePoint = source_info.Point;
pub const SourceLocation = source_info.Location;
pub const SourceView = source_info.View;
pub const ExpansionOriginId = source_info.OriginId;
pub const ExpansionOrigin = source_info.ExpansionOrigin;
pub const FixedEventJournal = observation.FixedEventJournal;
pub const Condition = conditions.Condition;
pub const ConditionId = conditions.Id;
pub const ConditionCode = conditions.Code;
pub const ConditionPhase = conditions.Phase;
pub const ConditionSpec = conditions.Spec;

pub const version = "0.3.3";
pub const Symbol = u32;

pub const ObjectRef = packed struct {
    index: u32,
    generation: u32,

    pub const none: ObjectRef = .{
        .index = std.math.maxInt(u32),
        .generation = 0,
    };

    pub fn isNone(ref: ObjectRef) bool {
        return ref.index == std.math.maxInt(u32);
    }

    pub fn eql(a: ObjectRef, b: ObjectRef) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// A checked reference to a lexical environment stored in the Lizp heap.
/// Environment references retained across garbage collections must be supplied
/// in `GcRoots.environments`.
pub const EnvironmentRef = ObjectRef;

pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    symbol: Symbol,
    object: ObjectRef,
    native: u32,

    pub fn isFalsey(value: Value) bool {
        return switch (value) {
            .nil => true,
            .boolean => |b| !b,
            else => false,
        };
    }

    pub fn eqlShallow(a: Value, b: Value) bool {
        return switch (a) {
            .nil => switch (b) {
                .nil => true,
                else => false,
            },
            .boolean => |x| switch (b) {
                .boolean => |y| x == y,
                else => false,
            },
            .integer => |x| switch (b) {
                .integer => |y| x == y,
                else => false,
            },
            .symbol => |x| switch (b) {
                .symbol => |y| x == y,
                else => false,
            },
            .object => |x| switch (b) {
                .object => |y| x.eql(y),
                else => false,
            },
            .native => |x| switch (b) {
                .native => |y| x == y,
                else => false,
            },
        };
    }
};

/// Controls syntax that is recognized directly by the evaluator rather than
/// looked up as an ordinary binding. Removing a name from an environment does
/// not remove a special form; use this policy when that distinction matters.
pub const LanguagePolicy = struct {
    quote: bool = true,
    if_: bool = true,
    begin: bool = true,
    define: bool = true,
    set_bang: bool = true,
    lambda: bool = true,
    let_: bool = true,
    while_: bool = true,
    and_: bool = true,
    or_: bool = true,

    /// Disables mutation of existing bindings and the unbounded imperative
    /// loop form while retaining ordinary functional Lisp.
    pub const attenuated = LanguagePolicy{
        .set_bang = false,
        .while_ = false,
    };

    /// Suitable for expression evaluation: local `let` and lambdas work, but
    /// definitions, mutation, and imperative loops are unavailable.
    pub const expression_only = LanguagePolicy{
        .define = false,
        .set_bang = false,
        .while_ = false,
    };
};

/// Optional structural filtering for values copied between environments.
/// Environment attenuation itself is defined by which bindings the host
/// chooses to expose; native callbacks and granted closures are trusted
/// capabilities and may internally use any authority they were created with.
pub const GrantPolicy = enum {
    /// Reject closures and environment objects anywhere in the value graph.
    /// This can be useful as an auditing policy, but is not required for name
    /// attenuation and is not a native-code sandbox.
    no_captured_authority,

    /// Copy the value unchanged. This is the normal capability behavior: the
    /// host grants the operation represented by the value as a whole.
    preserve_captured_authority,
};

/// Describes a detached snapshot environment.
///
/// `source == null` selects the global environment. When `allow` is non-null,
/// only those visible names are copied. When `allow` is null, all visible names
/// are copied. `deny` is applied last in either mode. The result has no parent,
/// so missing names cannot fall through to globals and `set!` cannot mutate the
/// source environment.
pub const CapabilityEnvironmentOptions = struct {
    source: ?EnvironmentRef = null,
    allow: ?[]const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    grant_policy: GrantPolicy = .preserve_captured_authority,
    language: LanguagePolicy = .{},
};

/// Extra roots supplied by the embedding host at an explicit GC safe point.
pub const GcRoots = struct {
    values: []const Value = &.{},
    environments: []const EnvironmentRef = &.{},
};

pub const PairView = struct {
    car: Value,
    cdr: Value,
};

const Pair = struct {
    car: Value,
    cdr: Value,
};

const Closure = struct {
    params: Value,
    body: Value,
    environment: ObjectRef,
};

const Environment = struct {
    parent: ?ObjectRef,
    bindings: std.AutoHashMap(Symbol, Value),
    language: LanguagePolicy,

    fn init(
        allocator: std.mem.Allocator,
        parent: ?ObjectRef,
        language: LanguagePolicy,
    ) Environment {
        return .{
            .parent = parent,
            .bindings = std.AutoHashMap(Symbol, Value).init(allocator),
            .language = language,
        };
    }

    fn deinit(self: *Environment) void {
        self.bindings.deinit();
    }
};

const Syntax = struct {
    datum: Value,
    span: SourceSpan,
    origin: ?ExpansionOriginId = null,
};

const SourceRecord = struct {
    id: SourceId,
    name: []u8,
    bytes: []u8,

    fn deinit(self: *SourceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.bytes);
    }
};

const Object = union(enum) {
    pair: Pair,
    vector: []Value,
    string: []u8,
    closure: Closure,
    environment: Environment,
    syntax: Syntax,

    pub fn deinit(self: *Object, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |bytes| allocator.free(bytes),
            .vector => |items| allocator.free(items),
            .environment => |*environment| environment.deinit(),
            .syntax => {},
            else => {},
        }
    }
};

const Heap = poolside.PoolWithOptions(Object, .{
    .chunk_len = 512,
    .generation_bits = 32,
    .track_provenance = false,
});

pub const HostError = std.mem.Allocator.Error || error{
    OutOfCapacity,
    NativeHostFailure,
    RuntimeBusy,
    RuntimeInvariantFailure,
};

pub const NativeOutcome = union(enum) {
    returned: Value,
    condition: ConditionSpec,
};

pub const NativeFn = *const fn (
    context: ?*anyopaque,
    runtime: *Runtime,
    args: []const Value,
) HostError!NativeOutcome;

const CoreNativeFn = *const fn (
    context: ?*anyopaque,
    runtime: *Runtime,
    args: []const Value,
) anyerror!Value;

const NativeImplementation = union(enum) {
    core: CoreNativeFn,
    host: NativeFn,
};

const NativeEntry = struct {
    name: Symbol,
    context: ?*anyopaque,
    implementation: NativeImplementation,
};

const TailTarget = struct {
    form: Value,
    environment: ObjectRef,
    call_context: ?observation.ContextId = null,
};

const EvalOutcome = union(enum) {
    value: Value,
    tail: TailTarget,
};

const EvaluationScope = struct {
    id: observation.EvaluationId,
    outermost: bool,
    start_action: ObservationAction,
    value_root_checkpoint: usize,
    environment_root_checkpoint: usize,
    previous_evaluation: observation.EvaluationId,
    previous_context: observation.ContextId,
    previous_phase: ConditionPhase,
    previous_source: ?SourceId,
    previous_span: ?SourceSpan,
    previous_origin: ?ExpansionOriginId,
    previous_last_event: ?observation.EventId,
};

const RecurTarget = struct {
    symbol: Symbol,
    arity: usize,
};

const ExpandContext = struct {
    tail_position: bool,
    recur_target: ?RecurTarget = null,
    depth: usize = 0,
};

const ParameterInfo = struct {
    value: Value,
    fixed_arity: ?usize,
};

const CoreSymbols = struct {
    quote: Symbol,
    if_: Symbol,
    begin: Symbol,
    define: Symbol,
    set_bang: Symbol,
    lambda: Symbol,
    let_: Symbol,
    while_: Symbol,
    and_: Symbol,
    or_: Symbol,
};

const SurfaceSymbols = struct {
    fn_: Symbol,
    def: Symbol,
    defn: Symbol,
    do: Symbol,
    loop: Symbol,
    recur: Symbol,
};

const core_procedure_names = [_][]const u8{
    "+",        "-",          "*",   "/",    "=",      "<",      "<=",      ">",       ">=",
    "cons",     "car",        "cdr", "list", "null?",  "pair?",  "number?", "symbol?", "string?",
    "boolean?", "procedure?", "not", "eq?",  "length", "vector", "vector?", "count",   "nth",
};

pub const EvaluationRequest = union(enum) {
    source: struct {
        bytes: []const u8,
        environment: ?EnvironmentRef = null,
        source_name: ?[]const u8 = null,
    },
    form: struct {
        value: Value,
        environment: ?EnvironmentRef = null,
    },
    call: struct {
        function: Value,
        arguments: []const Value,
    },
};

pub const EvaluationOutcome = union(enum) {
    returned: Value,
    condition: Condition,
    cancelled,
    paused,
};

pub const EvaluationReport = struct {
    id: EvaluationId,
    source: ?SourceId,
    outcome: EvaluationOutcome,
    heap_live: u32,
};

pub const RuntimeOptions = struct {
    max_eval_depth: usize = 2048,
    /// Number of heap allocations between evaluation-nursery collections at
    /// outermost tail-call safe points. Zero disables mid-evaluation nursery
    /// collection; a final nursery collection still runs when evaluation ends.
    evaluation_gc_interval: usize = 256,
    install_core: bool = true,
    /// Optional sans-I/O semantic observer. A null observer adds no event
    /// allocation and no callback traffic.
    observer: ?Observer = null,
    observation_lane: observation.LaneId = .main,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    heap: Heap,
    symbols: std.StringHashMap(Symbol),
    symbol_names: std.ArrayList([]u8) = .empty,
    natives: std.ArrayList(NativeEntry) = .empty,
    sources: std.ArrayList(SourceRecord) = .empty,
    expansion_origins: std.ArrayList(ExpansionOrigin) = .empty,
    core_native_count: usize = 0,
    global_environment: ObjectRef = ObjectRef.none,
    core: CoreSymbols = undefined,
    surface: SurfaceSymbols = undefined,
    gensym_counter: u64 = 0,
    max_eval_depth: usize,
    evaluation_gc_interval: usize,
    active_evaluations: usize = 0,
    evaluation_allocations_since_gc: usize = 0,
    evaluation_allocations: std.ArrayList(ObjectRef) = .empty,
    evaluation_root_values: std.ArrayList(Value) = .empty,
    evaluation_root_environments: std.ArrayList(ObjectRef) = .empty,
    nursery_collections: usize = 0,
    observer: ?Observer = null,
    observation_lane: observation.LaneId = .main,
    next_event_ordinal: u64 = 1,
    next_evaluation_ordinal: u64 = 1,
    next_context_ordinal: u64 = 1,
    next_condition_ordinal: u64 = 1,
    current_evaluation: observation.EvaluationId = .none,
    current_context: observation.ContextId = .none,
    current_phase: ConditionPhase = .runtime,
    current_source: ?SourceId = null,
    current_span: ?SourceSpan = null,
    current_origin: ?ExpansionOriginId = null,
    last_event_id: ?observation.EventId = null,
    pending_condition: ?Condition = null,

    pub fn init(allocator: std.mem.Allocator) !Runtime {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
        var runtime = Runtime{
            .allocator = allocator,
            .heap = Heap.init(allocator),
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .max_eval_depth = options.max_eval_depth,
            .evaluation_gc_interval = options.evaluation_gc_interval,
            .observer = options.observer,
            .observation_lane = options.observation_lane,
        };
        errdefer runtime.deinit();

        runtime.global_environment = try runtime.newEnvironment(null);
        runtime.core = .{
            .quote = try runtime.intern("quote"),
            .if_ = try runtime.intern("if"),
            .begin = try runtime.intern("begin"),
            .define = try runtime.intern("define"),
            .set_bang = try runtime.intern("set!"),
            .lambda = try runtime.intern("lambda"),
            .let_ = try runtime.intern("let"),
            .while_ = try runtime.intern("while"),
            .and_ = try runtime.intern("and"),
            .or_ = try runtime.intern("or"),
        };
        runtime.surface = .{
            .fn_ = try runtime.intern("fn"),
            .def = try runtime.intern("def"),
            .defn = try runtime.intern("defn"),
            .do = try runtime.intern("do"),
            .loop = try runtime.intern("loop"),
            .recur = try runtime.intern("recur"),
        };
        if (options.install_core) {
            try runtime.installCore();
            runtime.core_native_count = runtime.natives.items.len;
        }
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.heap.deinit();
        self.symbols.deinit();
        for (self.symbol_names.items) |name| self.allocator.free(name);
        self.symbol_names.deinit(self.allocator);
        self.natives.deinit(self.allocator);
        for (self.sources.items) |*source_record| source_record.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.expansion_origins.deinit(self.allocator);
        self.evaluation_allocations.deinit(self.allocator);
        self.evaluation_root_values.deinit(self.allocator);
        self.evaluation_root_environments.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the most recently raised condition, if it has not been replaced
    /// by a later evaluation. Evaluation reports contain their own copy and do
    /// not depend on this storage remaining current.
    fn lastCondition(self: *const Runtime) ?*const Condition {
        return if (self.pending_condition) |*condition_value| condition_value else null;
    }

    fn clearCondition(self: *Runtime) void {
        self.pending_condition = null;
    }

    fn fail(
        self: *Runtime,
        err: anyerror,
        comptime format: []const u8,
        args: anytype,
    ) anyerror {
        return self.failAt(
            err,
            self.current_span,
            self.current_origin,
            format,
            args,
        );
    }

    fn failAt(
        self: *Runtime,
        err: anyerror,
        span: ?SourceSpan,
        origin: ?ExpansionOriginId,
        comptime format: []const u8,
        args: anytype,
    ) anyerror {
        const value = Condition.initFormat(
            self.nextConditionId(),
            conditionCodeFromError(err),
            self.current_phase,
            @intFromEnum(self.current_context),
            span,
            origin,
            format,
            args,
        );
        self.pending_condition = value;
        _ = self.publishAtLocation(
            self.current_context,
            span,
            origin,
            .{
                .condition_raised = .{
                    .condition = value.id,
                    .code = value.code,
                    .phase = value.phase,
                },
            },
        );
        return err;
    }

    fn raiseNativeCondition(self: *Runtime, spec: ConditionSpec) anyerror {
        const value = Condition.initMessage(
            self.nextConditionId(),
            spec.code,
            .native,
            @intFromEnum(self.current_context),
            self.current_span,
            self.current_origin,
            spec.message,
        );
        self.pending_condition = value;
        _ = self.publishAtLocation(
            self.current_context,
            value.span,
            value.origin,
            .{
                .condition_raised = .{
                    .condition = value.id,
                    .code = value.code,
                    .phase = value.phase,
                },
            },
        );
        return error.NativeConditionRaised;
    }

    /// Installs or removes the observer used for subsequent semantic events.
    /// The caller owns the observer context and must keep it alive while
    /// installed. Changing observers is a host operation and is rejected while
    /// an evaluation is active.
    pub fn setObserver(self: *Runtime, observer: ?Observer) HostError!void {
        if (self.active_evaluations != 0) return error.RuntimeBusy;
        self.observer = observer;
    }

    /// Correlation identifiers for native callbacks and host-side tracing.
    pub fn observationEvaluation(self: *const Runtime) EvaluationId {
        return self.current_evaluation;
    }

    pub fn observationContext(self: *const Runtime) ContextId {
        return self.current_context;
    }

    pub fn observationEvent(self: *const Runtime) ?EventId {
        return self.last_event_id;
    }

    fn publish(self: *Runtime, data: observation.EventData) ObservationAction {
        return self.publishAt(self.current_context, data);
    }

    fn publishAt(
        self: *Runtime,
        context: observation.ContextId,
        data: observation.EventData,
    ) ObservationAction {
        return self.publishAtLocation(
            context,
            self.current_span,
            self.current_origin,
            data,
        );
    }

    fn publishAtLocation(
        self: *Runtime,
        context: observation.ContextId,
        span: ?SourceSpan,
        origin: ?ExpansionOriginId,
        data: observation.EventData,
    ) ObservationAction {
        const observer = self.observer orelse return .continue_;
        const kind = std.meta.activeTag(data);
        if (!observer.mask.contains(kind)) return .continue_;

        const id = observation.EventId{
            .lane = self.observation_lane,
            .ordinal = self.takeOrdinal(&self.next_event_ordinal),
        };
        const event = observation.Event{
            .header = .{
                .id = id,
                .evaluation = self.current_evaluation,
                .context = context,
                .cause = self.last_event_id,
                .span = span,
                .origin = origin,
            },
            .data = data,
        };
        self.last_event_id = id;
        return observer.on_event(observer.context, event);
    }

    fn publishSafe(self: *Runtime, data: observation.EventData) anyerror!void {
        return self.enforceObservationAction(self.publish(data));
    }

    fn publishSafeAt(
        self: *Runtime,
        context: observation.ContextId,
        data: observation.EventData,
    ) anyerror!void {
        return self.enforceObservationAction(self.publishAt(context, data));
    }

    fn enforceObservationAction(
        _: *Runtime,
        action: ObservationAction,
    ) anyerror!void {
        return switch (action) {
            .continue_ => {},
            .cancel => error.ObservationCancelled,
            .pause => error.ObservationPaused,
        };
    }

    fn takeOrdinal(_: *Runtime, counter: *u64) u64 {
        const result = counter.*;
        counter.* +%= 1;
        if (counter.* == 0) counter.* = 1;
        return result;
    }

    fn nextEvaluationId(self: *Runtime) observation.EvaluationId {
        return @enumFromInt(self.takeOrdinal(&self.next_evaluation_ordinal));
    }

    fn nextConditionId(self: *Runtime) ConditionId {
        return @enumFromInt(self.takeOrdinal(&self.next_condition_ordinal));
    }

    fn nextContextId(self: *Runtime) observation.ContextId {
        if (self.observer == null) return .none;
        return @enumFromInt(self.takeOrdinal(&self.next_context_ordinal));
    }

    fn entityId(reference: ObjectRef) observation.EntityId {
        return .{
            .index = reference.index,
            .generation = reference.generation,
        };
    }

    fn valueKind(value: Value) observation.ValueKind {
        return switch (value) {
            .nil => .nil,
            .boolean => .boolean,
            .integer => .integer,
            .symbol => .symbol,
            .object => .object,
            .native => .native,
        };
    }

    fn objectKind(object: Object) observation.ObjectKind {
        return switch (object) {
            .pair => .pair,
            .vector => .vector,
            .string => .string,
            .closure => .closure,
            .environment => .environment,
            .syntax => .syntax,
        };
    }

    pub fn intern(self: *Runtime, name: []const u8) !Symbol {
        if (self.symbols.get(name)) |symbol| return symbol;
        if (self.symbol_names.items.len >= std.math.maxInt(Symbol)) {
            return self.fail(error.TooManySymbols, "symbol table is full", .{});
        }

        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const symbol: Symbol = @intCast(self.symbol_names.items.len);
        try self.symbol_names.append(self.allocator, owned);
        errdefer _ = self.symbol_names.pop();
        try self.symbols.put(owned, symbol);
        return symbol;
    }

    pub fn symbolName(self: *const Runtime, symbol: Symbol) ?[]const u8 {
        if (symbol >= self.symbol_names.items.len) return null;
        return self.symbol_names.items[symbol];
    }

    fn registerSource(
        self: *Runtime,
        name: ?[]const u8,
        bytes: []const u8,
    ) HostError!SourceId {
        if (bytes.len > std.math.maxInt(u32)) return error.OutOfCapacity;
        if (self.sources.items.len >= std.math.maxInt(u64) - 1) return error.OutOfCapacity;

        const id: SourceId = @enumFromInt(self.sources.items.len + 1);
        const owned_name = if (name) |provided|
            try self.allocator.dupe(u8, provided)
        else
            try std.fmt.allocPrint(self.allocator, "source://{d}", .{@intFromEnum(id)});
        errdefer self.allocator.free(owned_name);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);

        try self.sources.append(self.allocator, .{
            .id = id,
            .name = owned_name,
            .bytes = owned_bytes,
        });
        return id;
    }

    /// Returns borrowed immutable source metadata. The name and byte slices
    /// remain valid until Runtime.deinit().
    pub fn sourceView(self: *const Runtime, id: SourceId) ?SourceView {
        const ordinal = @intFromEnum(id);
        if (ordinal == 0) return null;
        const index = ordinal - 1;
        if (index >= self.sources.items.len) return null;
        const record = self.sources.items[index];
        return .{ .id = record.id, .name = record.name, .bytes = record.bytes };
    }

    /// Number of immutable source revisions retained by this Runtime.
    pub fn sourceCount(self: *const Runtime) usize {
        return self.sources.items.len;
    }

    /// Returns the exact borrowed byte range identified by `span`.
    pub fn sourceExcerpt(self: *const Runtime, span: SourceSpan) ?[]const u8 {
        const view = self.sourceView(span.source) orelse return null;
        if (span.start > span.end) return null;
        if (span.end > view.bytes.len) return null;
        return view.bytes[span.start..span.end];
    }

    /// Converts byte offsets to one-based line and byte-column coordinates.
    /// Display-width and Unicode grapheme policy intentionally belong to UI
    /// libraries rather than the sans-I/O core.
    pub fn sourceLocation(self: *const Runtime, span: SourceSpan) ?SourceLocation {
        const view = self.sourceView(span.source) orelse return null;
        if (span.start > span.end) return null;
        if (span.end > view.bytes.len) return null;
        return .{
            .start = sourcePointAt(view.bytes, span.start),
            .end = sourcePointAt(view.bytes, span.end),
        };
    }

    fn registerExpansionOrigin(
        self: *Runtime,
        expander: Symbol,
        call_site: SourceSpan,
        parent: ?ExpansionOriginId,
    ) HostError!ExpansionOriginId {
        if (self.expansion_origins.items.len >= std.math.maxInt(u64) - 1) {
            return error.OutOfCapacity;
        }
        const id: ExpansionOriginId = @enumFromInt(self.expansion_origins.items.len + 1);
        try self.expansion_origins.append(self.allocator, .{
            .id = id,
            .expander = expander,
            .call_site = call_site,
            .parent = parent,
        });
        return id;
    }

    /// Returns one immutable surface-lowering provenance record.
    pub fn expansionOrigin(self: *const Runtime, id: ExpansionOriginId) ?ExpansionOrigin {
        const ordinal = @intFromEnum(id);
        if (ordinal == 0) return null;
        const index = ordinal - 1;
        if (index >= self.expansion_origins.items.len) return null;
        return self.expansion_origins.items[index];
    }

    /// Number of lowering provenance records retained by this Runtime.
    pub fn expansionOriginCount(self: *const Runtime) usize {
        return self.expansion_origins.items.len;
    }

    pub fn registerNative(
        self: *Runtime,
        name: []const u8,
        context: ?*anyopaque,
        function: NativeFn,
    ) !void {
        try self.registerNativeImplementation(
            name,
            context,
            .{ .host = function },
        );
    }

    fn registerCoreNative(
        self: *Runtime,
        name: []const u8,
        function: CoreNativeFn,
    ) !void {
        try self.registerNativeImplementation(
            name,
            null,
            .{ .core = function },
        );
    }

    fn registerNativeImplementation(
        self: *Runtime,
        name: []const u8,
        context: ?*anyopaque,
        implementation: NativeImplementation,
    ) !void {
        if (self.natives.items.len >= std.math.maxInt(u32)) {
            return self.fail(error.TooManyNatives, "native function table is full", .{});
        }
        const symbol = try self.intern(name);
        const index: u32 = @intCast(self.natives.items.len);
        try self.natives.append(self.allocator, .{
            .name = symbol,
            .context = context,
            .implementation = implementation,
        });
        errdefer _ = self.natives.pop();
        try self.defineInEnvironment(self.global_environment, symbol, .{ .native = index });
    }

    pub fn defineGlobal(self: *Runtime, name: []const u8, value: Value) !void {
        const symbol = try self.intern(name);
        try self.defineInEnvironment(self.global_environment, symbol, value);
    }

    pub fn getGlobal(self: *const Runtime, name: []const u8) ?Value {
        const symbol = self.symbols.get(name) orelse return null;
        const object = self.getObjectConst(self.global_environment) orelse return null;
        return switch (object.*) {
            .environment => |*environment| environment.bindings.get(symbol),
            else => null,
        };
    }

    pub fn globalEnvironment(self: *const Runtime) ObjectRef {
        return self.global_environment;
    }

    /// Creates an empty parentless environment with an explicit language
    /// policy. It has no access to globals until the host adds bindings.
    pub fn createEnvironment(
        self: *Runtime,
        language: LanguagePolicy,
    ) !EnvironmentRef {
        return self.newEnvironmentWithPolicy(null, language);
    }

    /// Creates a lexical child. Missing names can fall through to `parent`, and
    /// `set!` may update an ancestor. Detached attenuated environments should
    /// normally use `createCapabilityEnvironment` instead.
    pub fn createChildEnvironment(
        self: *Runtime,
        parent: EnvironmentRef,
    ) anyerror!EnvironmentRef {
        _ = try self.expectEnvironmentConst(parent);
        return self.newEnvironment(parent);
    }

    /// Creates a parentless snapshot containing only the selected bindings.
    /// The default is an empty allowlist; copying everything requires the
    /// explicit `.allow = null` form.
    pub fn createCapabilityEnvironment(
        self: *Runtime,
        options: CapabilityEnvironmentOptions,
    ) anyerror!EnvironmentRef {
        const source = options.source orelse self.global_environment;
        _ = try self.expectEnvironmentConst(source);

        const destination = try self.newEnvironmentWithPolicy(null, options.language);
        errdefer std.debug.assert(self.heap.destroy(toHeapHandle(destination)));

        if (options.allow) |allowed_names| {
            for (allowed_names) |name| {
                if (nameInList(name, options.deny)) continue;
                const symbol = self.symbols.get(name) orelse {
                    return self.fail(error.UndefinedSymbol, "capability name is not defined: {s}", .{name});
                };
                const value = (try self.lookupOptional(source, symbol)) orelse {
                    return self.fail(error.UndefinedSymbol, "capability name is not visible: {s}", .{name});
                };
                try self.validateCapabilityGrant(name, value, options.grant_policy);
                try self.defineInEnvironment(destination, symbol, value);
            }
            return destination;
        }

        // Denylist mode copies the first visible binding for each symbol from
        // the source chain. It is convenient, but an allowlist is safer when
        // the source may gain new capabilities in the future.
        var seen = std.AutoHashMap(Symbol, void).init(self.allocator);
        defer seen.deinit();

        var current: ?EnvironmentRef = source;
        while (current) |reference| {
            const environment = try self.expectEnvironmentConst(reference);
            var iterator = environment.bindings.iterator();
            while (iterator.next()) |entry| {
                const symbol = entry.key_ptr.*;
                if (seen.contains(symbol)) continue;
                try seen.put(symbol, {});

                const name = self.symbolName(symbol) orelse continue;
                if (nameInList(name, options.deny)) continue;
                const value = entry.value_ptr.*;
                try self.validateCapabilityGrant(name, value, options.grant_policy);
                try self.defineInEnvironment(destination, symbol, value);
            }
            current = environment.parent;
        }
        return destination;
    }

    /// Adds or replaces a binding in exactly this environment. The host is
    /// making an explicit grant, so arbitrary values—including closures—are
    /// accepted here.
    pub fn defineIn(
        self: *Runtime,
        environment: EnvironmentRef,
        name: []const u8,
        value: Value,
    ) anyerror!void {
        const symbol = try self.intern(name);
        try self.defineInEnvironment(environment, symbol, value);
    }

    /// Copies one visible binding from the global environment unchanged. The
    /// host is explicitly granting the capability represented by that value.
    pub fn grantGlobal(
        self: *Runtime,
        environment: EnvironmentRef,
        name: []const u8,
    ) anyerror!void {
        return self.grantGlobalWithPolicy(environment, name, .preserve_captured_authority);
    }

    pub fn grantGlobalWithPolicy(
        self: *Runtime,
        environment: EnvironmentRef,
        name: []const u8,
        policy: GrantPolicy,
    ) anyerror!void {
        const symbol = self.symbols.get(name) orelse {
            return self.fail(error.UndefinedSymbol, "global capability is not defined: {s}", .{name});
        };
        const value = (try self.lookupOptional(self.global_environment, symbol)) orelse {
            return self.fail(error.UndefinedSymbol, "global capability is not visible: {s}", .{name});
        };
        try self.validateCapabilityGrant(name, value, policy);
        try self.defineInEnvironment(environment, symbol, value);
    }

    /// Grants Lizp's pure built-in procedures. Special forms are controlled by
    /// the environment's `LanguagePolicy`, not by bindings.
    pub fn grantCoreProcedures(self: *Runtime, environment: EnvironmentRef) anyerror!void {
        if (self.core_native_count == 0) {
            return self.fail(error.CoreNotInstalled, "Lizp core procedures were not installed", .{});
        }
        std.debug.assert(self.core_native_count == core_procedure_names.len);
        for (self.natives.items[0..self.core_native_count], 0..) |native, index| {
            try self.defineInEnvironment(environment, native.name, .{ .native = @intCast(index) });
        }
    }

    /// Removes a binding from exactly this environment. Ancestors are not
    /// modified. This revokes lookup by this name, but not aliases that Lisp
    /// code may already have saved elsewhere.
    pub fn removeFrom(
        self: *Runtime,
        environment: EnvironmentRef,
        name: []const u8,
    ) anyerror!bool {
        const symbol = self.symbols.get(name) orelse return false;
        const object = try self.expectEnvironment(environment);
        return object.bindings.remove(symbol);
    }

    /// Returns the first visible binding in an environment chain.
    pub fn getIn(
        self: *Runtime,
        environment: EnvironmentRef,
        name: []const u8,
    ) anyerror!?Value {
        const symbol = self.symbols.get(name) orelse return null;
        return self.lookupOptional(environment, symbol);
    }

    pub fn makeString(self: *Runtime, bytes: []const u8) !Value {
        const owned = try self.allocator.dupe(u8, bytes);
        return self.makeStringOwned(owned);
    }

    fn makeStringOwned(self: *Runtime, owned: []u8) !Value {
        var object = Object{ .string = owned };
        errdefer object.deinit(self.allocator);
        return .{ .object = try self.allocateObject(object) };
    }

    pub fn cons(self: *Runtime, car: Value, cdr: Value) !Value {
        return .{ .object = try self.allocateObject(.{
            .pair = .{ .car = car, .cdr = cdr },
        }) };
    }

    pub fn list(self: *Runtime, items: []const Value) !Value {
        var result: Value = .nil;
        var index = items.len;
        while (index > 0) {
            index -= 1;
            result = try self.cons(items[index], result);
        }
        return result;
    }

    pub fn makeVector(self: *Runtime, items: []const Value) !Value {
        const owned = try self.allocator.dupe(Value, items);
        var object = Object{ .vector = owned };
        errdefer object.deinit(self.allocator);
        return .{ .object = try self.allocateObject(object) };
    }

    fn syntaxConst(self: *const Runtime, value: Value) ?*const Syntax {
        const reference = switch (value) {
            .object => |reference| reference,
            else => return null,
        };
        const object = self.getObjectConst(reference) orelse return null;
        return switch (object.*) {
            .syntax => |*syntax| syntax,
            else => null,
        };
    }

    fn unwrapSyntaxNoFail(self: *const Runtime, value: Value) Value {
        var current = value;
        var depth: usize = 0;
        while (self.syntaxConst(current)) |syntax| {
            current = syntax.datum;
            depth += 1;
            if (depth > 64) break;
        }
        return current;
    }

    fn unwrapSyntax(self: *Runtime, value: Value) anyerror!Value {
        var current = value;
        var depth: usize = 0;
        while (true) {
            const reference = switch (current) {
                .object => |reference| reference,
                else => return current,
            };
            const object = self.getObjectConst(reference) orelse {
                return self.fail(
                    error.StaleObject,
                    "attempted to inspect stale syntax object {d}/{d}",
                    .{ reference.index, reference.generation },
                );
            };
            switch (object.*) {
                .syntax => |syntax| current = syntax.datum,
                else => return current,
            }
            depth += 1;
            if (depth > 64) {
                return self.fail(error.InvalidSyntax, "syntax wrapper depth exceeded 64", .{});
            }
        }
    }

    fn makeSyntax(
        self: *Runtime,
        datum: Value,
        span: SourceSpan,
        origin: ?ExpansionOriginId,
    ) !Value {
        std.debug.assert(self.syntaxConst(datum) == null);
        return .{ .object = try self.allocateObject(.{
            .syntax = .{ .datum = datum, .span = span, .origin = origin },
        }) };
    }

    fn syntaxToDatum(self: *Runtime, value: Value) anyerror!Value {
        return self.syntaxToDatumDepth(value, 0);
    }

    fn syntaxToDatumDepth(
        self: *Runtime,
        value: Value,
        depth: usize,
    ) anyerror!Value {
        if (depth > self.max_eval_depth) {
            return self.fail(
                error.EvalDepthExceeded,
                "quoted syntax depth exceeded {d}",
                .{self.max_eval_depth},
            );
        }
        const raw = try self.unwrapSyntax(value);
        const reference = switch (raw) {
            .object => |reference| reference,
            else => return raw,
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(
                error.StaleObject,
                "attempted to quote stale object {d}/{d}",
                .{ reference.index, reference.generation },
            );
        };
        return switch (object.*) {
            .pair => |pair| self.cons(
                try self.syntaxToDatumDepth(pair.car, depth + 1),
                try self.syntaxToDatumDepth(pair.cdr, depth + 1),
            ),
            .vector => |items| blk: {
                const converted = try self.allocator.alloc(Value, items.len);
                defer self.allocator.free(converted);
                for (items, 0..) |item, index| {
                    converted[index] = try self.syntaxToDatumDepth(item, depth + 1);
                }
                break :blk self.makeVector(converted);
            },
            .syntax => unreachable,
            else => raw,
        };
    }

    /// Adds source/origin wrappers to generated expansion output while leaving
    /// already source-located child forms untouched. Pair spines remain raw so
    /// ordinary Lisp list representation is unchanged.
    fn annotateGeneratedForm(
        self: *Runtime,
        value: Value,
        span: SourceSpan,
        origin: ?ExpansionOriginId,
    ) anyerror!Value {
        if (self.syntaxConst(value) != null) return value;
        const reference = switch (value) {
            .object => |reference| reference,
            else => return self.makeSyntax(value, span, origin),
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(
                error.StaleObject,
                "attempted to annotate stale generated object {d}/{d}",
                .{ reference.index, reference.generation },
            );
        };
        const datum = switch (object.*) {
            .pair => |pair| try self.cons(
                try self.annotateGeneratedForm(pair.car, span, origin),
                try self.annotateGeneratedTail(pair.cdr, span, origin),
            ),
            .vector => |items| blk: {
                const annotated = try self.allocator.alloc(Value, items.len);
                defer self.allocator.free(annotated);
                for (items, 0..) |item, index| {
                    annotated[index] = try self.annotateGeneratedForm(item, span, origin);
                }
                break :blk try self.makeVector(annotated);
            },
            .syntax => unreachable,
            else => value,
        };
        return self.makeSyntax(datum, span, origin);
    }

    fn annotateGeneratedTail(
        self: *Runtime,
        value: Value,
        span: SourceSpan,
        origin: ?ExpansionOriginId,
    ) anyerror!Value {
        if (self.syntaxConst(value) != null) return value;
        const raw = try self.unwrapSyntax(value);
        if (raw == .nil) return .nil;
        const reference = switch (raw) {
            .object => |reference| reference,
            else => return self.annotateGeneratedForm(raw, span, origin),
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(
                error.StaleObject,
                "attempted to annotate stale generated list tail {d}/{d}",
                .{ reference.index, reference.generation },
            );
        };
        return switch (object.*) {
            .pair => |pair| self.cons(
                try self.annotateGeneratedForm(pair.car, span, origin),
                try self.annotateGeneratedTail(pair.cdr, span, origin),
            ),
            else => self.annotateGeneratedForm(raw, span, origin),
        };
    }

    pub fn isAlive(self: *const Runtime, value: Value) bool {
        return switch (value) {
            .object => |ref| self.heap.contains(toHeapHandle(ref)),
            else => true,
        };
    }

    pub fn heapLiveCount(self: *const Runtime) u32 {
        return self.heap.liveCount();
    }

    pub fn asInteger(self: *const Runtime, value: Value) ?i64 {
        return switch (self.unwrapSyntaxNoFail(value)) {
            .integer => |integer| integer,
            else => null,
        };
    }

    /// Returns borrowed string bytes. The slice remains valid until the value
    /// is collected or the runtime is deinitialized.
    pub fn asString(self: *const Runtime, value: Value) ?[]const u8 {
        const reference = switch (self.unwrapSyntaxNoFail(value)) {
            .object => |reference| reference,
            else => return null,
        };
        const object = self.getObjectConst(reference) orelse return null;
        return switch (object.*) {
            .string => |bytes| bytes,
            else => null,
        };
    }

    pub fn asSymbolName(self: *const Runtime, value: Value) ?[]const u8 {
        return switch (self.unwrapSyntaxNoFail(value)) {
            .symbol => |symbol| self.symbolName(symbol),
            else => null,
        };
    }

    fn symbolOf(self: *const Runtime, value: Value) ?Symbol {
        return switch (self.unwrapSyntaxNoFail(value)) {
            .symbol => |symbol| symbol,
            else => null,
        };
    }

    fn isNilDatum(self: *const Runtime, value: Value) bool {
        return self.unwrapSyntaxNoFail(value) == .nil;
    }

    pub fn asPair(self: *const Runtime, value: Value) ?PairView {
        const reference = switch (self.unwrapSyntaxNoFail(value)) {
            .object => |reference| reference,
            else => return null,
        };
        const object = self.getObjectConst(reference) orelse return null;
        return switch (object.*) {
            .pair => |pair| .{ .car = pair.car, .cdr = pair.cdr },
            else => null,
        };
    }

    /// Returns a borrowed view of a vector. The slice remains valid until the
    /// vector is collected or the runtime is deinitialized.
    pub fn asVector(self: *const Runtime, value: Value) ?[]const Value {
        const reference = switch (self.unwrapSyntaxNoFail(value)) {
            .object => |reference| reference,
            else => return null,
        };
        const object = self.getObjectConst(reference) orelse return null;
        return switch (object.*) {
            .vector => |items| items,
            else => null,
        };
    }

    fn expectInteger(self: *Runtime, value: Value) anyerror!i64 {
        return self.asInteger(value) orelse
            self.fail(error.TypeMismatch, "expected integer, got {s}", .{@tagName(value)});
    }

    fn expectString(self: *Runtime, value: Value) anyerror![]const u8 {
        return self.asString(value) orelse
            self.fail(error.TypeMismatch, "expected string, got {s}", .{@tagName(value)});
    }

    fn beginEvaluation(
        self: *Runtime,
        origin: observation.EvaluationOrigin,
        environment: ObjectRef,
        source_id: ?SourceId,
    ) EvaluationScope {
        const outermost = self.active_evaluations == 0;
        const previous_evaluation = self.current_evaluation;
        const previous_context = self.current_context;
        const previous_phase = self.current_phase;
        const previous_source = self.current_source;
        const previous_span = self.current_span;
        const previous_origin = self.current_origin;
        const previous_last_event = self.last_event_id;

        if (outermost) {
            std.debug.assert(self.evaluation_allocations.items.len == 0);
            self.evaluation_allocations_since_gc = 0;
            self.current_evaluation = self.nextEvaluationId();
            self.current_context = self.nextContextId();
            self.current_phase = .runtime;
            self.current_source = source_id;
            self.current_span = null;
            self.current_origin = null;
            self.last_event_id = null;
        }
        self.active_evaluations += 1;

        const start_action = if (outermost)
            self.publish(.{
                .evaluation_started = .{
                    .origin = origin,
                    .environment = entityId(environment),
                    .source = source_id,
                },
            })
        else
            ObservationAction.continue_;

        return .{
            .id = self.current_evaluation,
            .outermost = outermost,
            .start_action = start_action,
            .value_root_checkpoint = self.evaluation_root_values.items.len,
            .environment_root_checkpoint = self.evaluation_root_environments.items.len,
            .previous_evaluation = previous_evaluation,
            .previous_context = previous_context,
            .previous_phase = previous_phase,
            .previous_source = previous_source,
            .previous_span = previous_span,
            .previous_origin = previous_origin,
            .previous_last_event = previous_last_event,
        };
    }

    fn finishEvaluation(
        self: *Runtime,
        scope: EvaluationScope,
        status: observation.EvaluationStatus,
        result: ?Value,
    ) void {
        if (!scope.outermost) return;
        _ = self.publish(.{
            .evaluation_finished = .{
                .status = status,
                .result = if (result) |value| valueKind(value) else null,
                .heap_live = self.heap.liveCount(),
            },
        });
    }

    fn endEvaluation(self: *Runtime, scope: EvaluationScope) void {
        self.evaluation_root_values.shrinkRetainingCapacity(scope.value_root_checkpoint);
        self.evaluation_root_environments.shrinkRetainingCapacity(scope.environment_root_checkpoint);
        std.debug.assert(self.active_evaluations > 0);
        self.active_evaluations -= 1;
        if (scope.outermost) {
            self.evaluation_allocations.clearRetainingCapacity();
            self.evaluation_allocations_since_gc = 0;
            self.current_evaluation = scope.previous_evaluation;
            self.current_context = scope.previous_context;
            self.current_phase = scope.previous_phase;
            self.current_source = scope.previous_source;
            self.current_span = scope.previous_span;
            self.current_origin = scope.previous_origin;
            self.last_event_id = scope.previous_last_event;
        }
    }

    fn addEvaluationValueRoot(self: *Runtime, value: Value) !void {
        try self.evaluation_root_values.append(self.allocator, value);
    }

    fn addEvaluationEnvironmentRoot(self: *Runtime, environment: ObjectRef) !void {
        try self.evaluation_root_environments.append(self.allocator, environment);
    }

    /// Lowers Clojure-shaped surface forms into Lizp's small evaluator core.
    /// Expansion does not evaluate code or mutate lexical environments.
    fn expand(self: *Runtime, value: Value) anyerror!Value {
        return self.expandForm(value, .{ .tail_position = true });
    }

    fn expandForm(self: *Runtime, value: Value, context: ExpandContext) anyerror!Value {
        if (context.depth > self.max_eval_depth) {
            return self.fail(
                error.ExpansionDepthExceeded,
                "expansion depth exceeded {d}",
                .{self.max_eval_depth},
            );
        }

        if (self.syntaxConst(value)) |syntax| {
            const previous_span = self.current_span;
            const previous_origin = self.current_origin;
            self.current_span = syntax.span;
            defer {
                self.current_span = previous_span;
                self.current_origin = previous_origin;
            }

            const expander = try self.expanderFor(syntax.datum);
            const inherited_origin = syntax.origin orelse previous_origin;
            const origin = if (expander) |symbol|
                try self.registerExpansionOrigin(
                    symbol,
                    syntax.span,
                    inherited_origin,
                )
            else
                syntax.origin;
            // Original child syntax remains source-authored, but expansion
            // nested inside a surrounding surface form still needs that
            // surface form as its provenance parent.
            self.current_origin = if (expander != null) origin else inherited_origin;

            const expanded = try self.expandDatum(syntax.datum, context);
            if (expander != null) {
                return self.annotateGeneratedForm(expanded, syntax.span, origin);
            }
            if (Value.eqlShallow(expanded, syntax.datum) and origin == syntax.origin) {
                return value;
            }
            return self.makeSyntax(expanded, syntax.span, syntax.origin);
        }

        return self.expandDatum(value, context);
    }

    fn expandDatum(
        self: *Runtime,
        value: Value,
        context: ExpandContext,
    ) anyerror!Value {
        const reference = switch (value) {
            .object => |reference| reference,
            else => return value,
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(
                error.StaleObject,
                "attempted to expand stale object {d}/{d}",
                .{ reference.index, reference.generation },
            );
        };
        return switch (object.*) {
            .pair => self.expandListForm(value, context),
            .vector => |items| self.expandVectorForm(items, context),
            .syntax => unreachable,
            else => value,
        };
    }

    fn expanderFor(self: *Runtime, value: Value) anyerror!?Symbol {
        const raw = try self.unwrapSyntax(value);
        const reference = switch (raw) {
            .object => |reference| reference,
            else => return null,
        };
        const object = self.getObjectConst(reference) orelse return null;
        const pair = switch (object.*) {
            .pair => |pair| pair,
            else => return null,
        };
        const head = try self.unwrapSyntax(pair.car);
        const symbol = switch (head) {
            .symbol => |symbol| symbol,
            else => return null,
        };
        if (symbol == self.surface.fn_ or
            symbol == self.surface.def or
            symbol == self.surface.defn or
            symbol == self.surface.do or
            symbol == self.surface.loop or
            symbol == self.surface.recur)
        {
            return symbol;
        }
        if (symbol == self.core.let_) {
            const rest = try self.unwrapSyntax(pair.cdr);
            const first = self.asPair(rest) orelse return null;
            if (self.asVector(first.car) != null) return symbol;
        }
        return null;
    }

    fn expandVectorForm(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        const expanded = try self.expandSlice(
            items,
            false,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded);
        return self.makeVector(expanded);
    }

    fn expandListForm(
        self: *Runtime,
        form: Value,
        context: ExpandContext,
    ) anyerror!Value {
        const items = try self.listToOwnedSlice(form);
        defer self.allocator.free(items);
        if (items.len == 0) return form;

        const head_symbol = self.symbolOf(items[0]);
        if (head_symbol) |symbol| {
            if (symbol == self.core.quote) return form;
            if (symbol == self.surface.fn_) return self.expandFn(items, context);
            if (symbol == self.surface.def) return self.expandDef(items, context);
            if (symbol == self.surface.defn) return self.expandDefn(items, context);
            if (symbol == self.surface.do) return self.expandBegin(items[1..], context);
            if (symbol == self.surface.loop) return self.expandLoop(items, context);
            if (symbol == self.surface.recur) return self.expandRecur(items, context);

            if (symbol == self.core.if_) return self.expandIf(items, context);
            if (symbol == self.core.begin) return self.expandBegin(items[1..], context);
            if (symbol == self.core.define) return self.expandDefine(items, context);
            if (symbol == self.core.set_bang) return self.expandSet(items, context);
            if (symbol == self.core.lambda) return self.expandLambda(items, context);
            if (symbol == self.core.let_) return self.expandLet(items, context);
            if (symbol == self.core.while_) return self.expandWhile(items, context);
            if (symbol == self.core.and_) return self.expandBooleanSequence(self.core.and_, items[1..], context);
            if (symbol == self.core.or_) return self.expandBooleanSequence(self.core.or_, items[1..], context);
        }

        const expanded = try self.expandSlice(
            items,
            false,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded);
        return self.list(expanded);
    }

    fn expandIf(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len != 3 and items.len != 4) {
            return self.fail(
                error.ArityMismatch,
                "if expects two or three arguments, got {d}",
                .{items.len - 1},
            );
        }
        var expanded: [4]Value = undefined;
        expanded[0] = .{ .symbol = self.core.if_ };
        expanded[1] = try self.expandForm(items[1], .{
            .tail_position = false,
            .recur_target = context.recur_target,
            .depth = context.depth + 1,
        });
        expanded[2] = try self.expandForm(items[2], .{
            .tail_position = context.tail_position,
            .recur_target = context.recur_target,
            .depth = context.depth + 1,
        });
        if (items.len == 4) {
            expanded[3] = try self.expandForm(items[3], .{
                .tail_position = context.tail_position,
                .recur_target = context.recur_target,
                .depth = context.depth + 1,
            });
        }
        return self.list(expanded[0..items.len]);
    }

    fn expandBegin(
        self: *Runtime,
        forms: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        const expanded = try self.expandSlice(
            forms,
            context.tail_position,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded);
        return self.makeListWithHead(.{ .symbol = self.core.begin }, expanded);
    }

    fn expandDef(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len != 3 or self.symbolOf(items[1]) == null) {
            return self.fail(error.InvalidSyntax, "def expects a symbol and one value expression", .{});
        }
        const value = try self.expandForm(items[2], .{
            .tail_position = false,
            .recur_target = context.recur_target,
            .depth = context.depth + 1,
        });
        return self.list(&.{
            .{ .symbol = self.core.define },
            items[1],
            value,
        });
    }

    fn expandDefn(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 4) {
            return self.fail(error.InvalidSyntax, "defn expects a name, parameter vector, and body", .{});
        }
        const name = self.symbolOf(items[1]) orelse
            return self.fail(error.InvalidSyntax, "defn expects a symbol name", .{});
        const parameters = try self.normalizeParameters(items[2]);
        const target = if (parameters.fixed_arity) |arity|
            RecurTarget{ .symbol = name, .arity = arity }
        else
            null;
        const body = try self.expandSlice(items[3..], true, target, context.depth);
        defer self.allocator.free(body);
        return self.makeFunctionDefine(name, parameters.value, body);
    }

    fn expandDefine(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "define requires a target and value or body", .{});
        }
        switch (try self.unwrapSyntax(items[1])) {
            .symbol => {
                if (items.len != 3) {
                    return self.fail(error.InvalidSyntax, "variable define accepts exactly one value expression", .{});
                }
                const value = try self.expandForm(items[2], .{
                    .tail_position = false,
                    .recur_target = context.recur_target,
                    .depth = context.depth + 1,
                });
                return self.list(&.{
                    .{ .symbol = self.core.define },
                    items[1],
                    value,
                });
            },
            .object => {
                const signature = (try self.expectPairConst(items[1])).*;
                const name = self.symbolOf(signature.car) orelse
                    return self.fail(error.InvalidSyntax, "function name in define must be a symbol", .{});
                const parameters = try self.normalizeParameters(signature.cdr);
                const target = if (parameters.fixed_arity) |arity|
                    RecurTarget{ .symbol = name, .arity = arity }
                else
                    null;
                const body = try self.expandSlice(items[2..], true, target, context.depth);
                defer self.allocator.free(body);
                return self.makeFunctionDefine(name, parameters.value, body);
            },
            else => return self.fail(error.InvalidSyntax, "define target must be a symbol or function signature", .{}),
        }
    }

    fn expandLambda(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "lambda requires parameters and a body", .{});
        }
        const parameters = try self.normalizeParameters(items[1]);
        const body = try self.expandSlice(items[2..], true, null, context.depth);
        defer self.allocator.free(body);
        return self.makeLambda(parameters.value, body);
    }

    fn expandFn(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "fn requires a parameter vector and body", .{});
        }

        if (self.symbolOf(items[1])) |name| {
            if (items.len < 4) {
                return self.fail(error.InvalidSyntax, "named fn requires a name, parameter vector, and body", .{});
            }
            const parameters = try self.normalizeParameters(items[2]);
            const target = if (parameters.fixed_arity) |arity|
                RecurTarget{ .symbol = name, .arity = arity }
            else
                null;
            const body = try self.expandSlice(items[3..], true, target, context.depth);
            defer self.allocator.free(body);
            const define_form = try self.makeFunctionDefine(name, parameters.value, body);
            const wrapper = try self.makeLambda(.nil, &.{ define_form, .{ .symbol = name } });
            return self.list(&.{wrapper});
        }

        const parameters = try self.normalizeParameters(items[1]);
        const body = try self.expandSlice(items[2..], true, null, context.depth);
        defer self.allocator.free(body);
        return self.makeLambda(parameters.value, body);
    }

    fn expandSet(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len != 3 or self.symbolOf(items[1]) == null) {
            return self.fail(error.InvalidSyntax, "set! expects a symbol and one value expression", .{});
        }
        const value = try self.expandForm(items[2], .{
            .tail_position = false,
            .recur_target = context.recur_target,
            .depth = context.depth + 1,
        });
        return self.list(&.{
            .{ .symbol = self.core.set_bang },
            items[1],
            value,
        });
    }

    fn expandLet(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "let requires bindings and a body", .{});
        }
        if (self.asVector(items[1])) |bindings| {
            return self.expandSequentialLet(bindings, items[2..], context);
        }

        const raw_bindings = try self.listToOwnedSlice(items[1]);
        defer self.allocator.free(raw_bindings);
        var expanded_bindings: std.ArrayList(Value) = .empty;
        defer expanded_bindings.deinit(self.allocator);
        try expanded_bindings.ensureTotalCapacity(self.allocator, raw_bindings.len);
        for (raw_bindings) |raw_binding| {
            const binding = try self.listToOwnedSlice(raw_binding);
            defer self.allocator.free(binding);
            if (binding.len != 2 or self.symbolOf(binding[0]) == null) {
                return self.fail(error.InvalidSyntax, "each let binding must have a symbol and expression", .{});
            }
            const value = try self.expandForm(binding[1], .{
                .tail_position = false,
                .recur_target = context.recur_target,
                .depth = context.depth + 1,
            });
            expanded_bindings.appendAssumeCapacity(try self.list(&.{ binding[0], value }));
        }
        const bindings_form = try self.list(expanded_bindings.items);
        const body = try self.expandSlice(
            items[2..],
            context.tail_position,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(body);
        var arguments: std.ArrayList(Value) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.append(self.allocator, bindings_form);
        try arguments.appendSlice(self.allocator, body);
        return self.makeListWithHead(.{ .symbol = self.core.let_ }, arguments.items);
    }

    fn expandSequentialLet(
        self: *Runtime,
        bindings: []const Value,
        body_forms: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (bindings.len % 2 != 0) {
            return self.fail(error.InvalidSyntax, "let binding vector must contain name/value pairs", .{});
        }
        if (body_forms.len == 0) {
            return self.fail(error.InvalidSyntax, "let requires at least one body form", .{});
        }

        const expanded_body = try self.expandSlice(
            body_forms,
            context.tail_position,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded_body);
        var result = try self.sequenceExpression(expanded_body);

        var pair_index = bindings.len / 2;
        while (pair_index > 0) {
            pair_index -= 1;
            const name = bindings[pair_index * 2];
            if (self.symbolOf(name) == null) {
                return self.fail(error.InvalidSyntax, "let binding name must be a symbol", .{});
            }
            const initializer = try self.expandForm(bindings[pair_index * 2 + 1], .{
                .tail_position = false,
                .recur_target = context.recur_target,
                .depth = context.depth + 1,
            });
            const binding = try self.list(&.{ name, initializer });
            const binding_list = try self.list(&.{binding});
            result = try self.list(&.{
                .{ .symbol = self.core.let_ },
                binding_list,
                result,
            });
        }
        return result;
    }

    fn expandLoop(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "loop requires a binding vector and body", .{});
        }
        const bindings = self.asVector(items[1]) orelse
            return self.fail(error.InvalidSyntax, "loop requires a binding vector", .{});
        if (bindings.len % 2 != 0) {
            return self.fail(error.InvalidSyntax, "loop binding vector must contain name/value pairs", .{});
        }

        const arity = bindings.len / 2;
        var names = try self.allocator.alloc(Value, arity);
        defer self.allocator.free(names);
        var initializers = try self.allocator.alloc(Value, arity);
        defer self.allocator.free(initializers);
        for (0..arity) |index| {
            const name = self.symbolOf(bindings[index * 2]) orelse
                return self.fail(error.InvalidSyntax, "loop binding name must be a symbol", .{});
            names[index] = .{ .symbol = name };
            initializers[index] = try self.expandForm(bindings[index * 2 + 1], .{
                .tail_position = false,
                .recur_target = context.recur_target,
                .depth = context.depth + 1,
            });
        }

        const target_symbol = try self.freshInternalSymbol("loop");
        const target = RecurTarget{ .symbol = target_symbol, .arity = arity };
        const body = try self.expandSlice(items[2..], true, target, context.depth);
        defer self.allocator.free(body);
        const parameters = try self.list(names);
        const define_form = try self.makeFunctionDefine(target_symbol, parameters, body);

        var initial_call_items: std.ArrayList(Value) = .empty;
        defer initial_call_items.deinit(self.allocator);
        try initial_call_items.append(self.allocator, .{ .symbol = target_symbol });
        try initial_call_items.appendSlice(self.allocator, names);
        var initial_expression = try self.list(initial_call_items.items);

        var index = arity;
        while (index > 0) {
            index -= 1;
            const binding = try self.list(&.{ names[index], initializers[index] });
            const binding_list = try self.list(&.{binding});
            initial_expression = try self.list(&.{
                .{ .symbol = self.core.let_ },
                binding_list,
                initial_expression,
            });
        }

        const wrapper = try self.makeLambda(.nil, &.{ define_form, initial_expression });
        return self.list(&.{wrapper});
    }

    fn expandRecur(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        const target = context.recur_target orelse
            return self.fail(error.InvalidSyntax, "recur is only valid inside a fixed-arity loop or named function", .{});
        if (!context.tail_position) {
            return self.fail(error.InvalidSyntax, "recur must appear in tail position", .{});
        }
        if (items.len - 1 != target.arity) {
            return self.fail(
                error.ArityMismatch,
                "recur expects {d} arguments, got {d}",
                .{ target.arity, items.len - 1 },
            );
        }
        const arguments = try self.expandSlice(
            items[1..],
            false,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(arguments);
        return self.makeListWithHead(.{ .symbol = target.symbol }, arguments);
    }

    fn expandWhile(
        self: *Runtime,
        items: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        if (items.len < 3) {
            return self.fail(error.InvalidSyntax, "while requires a condition and body", .{});
        }
        const expanded = try self.expandSlice(
            items[1..],
            false,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded);
        return self.makeListWithHead(.{ .symbol = self.core.while_ }, expanded);
    }

    fn expandBooleanSequence(
        self: *Runtime,
        symbol: Symbol,
        forms: []const Value,
        context: ExpandContext,
    ) anyerror!Value {
        const expanded = try self.expandSlice(
            forms,
            context.tail_position,
            context.recur_target,
            context.depth,
        );
        defer self.allocator.free(expanded);
        return self.makeListWithHead(.{ .symbol = symbol }, expanded);
    }

    fn expandSlice(
        self: *Runtime,
        forms: []const Value,
        tail_for_last: bool,
        recur_target: ?RecurTarget,
        depth: usize,
    ) anyerror![]Value {
        const expanded = try self.allocator.alloc(Value, forms.len);
        errdefer self.allocator.free(expanded);
        for (forms, 0..) |form, index| {
            expanded[index] = try self.expandForm(form, .{
                .tail_position = tail_for_last and index + 1 == forms.len,
                .recur_target = recur_target,
                .depth = depth + 1,
            });
        }
        return expanded;
    }

    fn normalizeParameters(self: *Runtime, raw: Value) anyerror!ParameterInfo {
        if (self.asVector(raw)) |items| {
            var rest_index: ?usize = null;
            var normalized = try self.allocator.alloc(Value, items.len);
            defer self.allocator.free(normalized);
            for (items, 0..) |item, index| {
                const symbol = self.symbolOf(item) orelse
                    return self.fail(error.InvalidSyntax, "fn parameter must be a symbol", .{});
                normalized[index] = .{ .symbol = symbol };
                if (std.mem.eql(u8, self.symbolName(symbol) orelse "", "&")) {
                    if (rest_index != null or index + 2 != items.len) {
                        return self.fail(
                            error.InvalidSyntax,
                            "& must appear once immediately before the final rest parameter",
                            .{},
                        );
                    }
                    rest_index = index;
                }
            }

            if (rest_index) |index| {
                const rest_symbol = normalized[index + 1].symbol;
                var parameters: Value = .{ .symbol = rest_symbol };
                var fixed = index;
                while (fixed > 0) {
                    fixed -= 1;
                    parameters = try self.cons(normalized[fixed], parameters);
                }
                return .{ .value = parameters, .fixed_arity = null };
            }

            return .{
                .value = try self.list(normalized),
                .fixed_arity = items.len,
            };
        }

        try self.validateParameters(raw);
        var count: usize = 0;
        var cursor = raw;
        while (true) {
            switch (try self.unwrapSyntax(cursor)) {
                .nil => return .{ .value = try self.syntaxToDatum(raw), .fixed_arity = count },
                .symbol => return .{ .value = try self.syntaxToDatum(raw), .fixed_arity = null },
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    count += 1;
                    cursor = pair.cdr;
                },
            }
        }
    }

    fn makeListWithHead(
        self: *Runtime,
        head: Value,
        rest: []const Value,
    ) !Value {
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(self.allocator);
        try items.ensureTotalCapacity(self.allocator, rest.len + 1);
        items.appendAssumeCapacity(head);
        items.appendSliceAssumeCapacity(rest);
        return self.list(items.items);
    }

    fn makeLambda(
        self: *Runtime,
        parameters: Value,
        body: []const Value,
    ) !Value {
        var arguments: std.ArrayList(Value) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.ensureTotalCapacity(self.allocator, body.len + 1);
        arguments.appendAssumeCapacity(parameters);
        arguments.appendSliceAssumeCapacity(body);
        return self.makeListWithHead(.{ .symbol = self.core.lambda }, arguments.items);
    }

    fn makeFunctionDefine(
        self: *Runtime,
        name: Symbol,
        parameters: Value,
        body: []const Value,
    ) !Value {
        const signature = try self.cons(.{ .symbol = name }, parameters);
        var arguments: std.ArrayList(Value) = .empty;
        defer arguments.deinit(self.allocator);
        try arguments.ensureTotalCapacity(self.allocator, body.len + 1);
        arguments.appendAssumeCapacity(signature);
        arguments.appendSliceAssumeCapacity(body);
        return self.makeListWithHead(.{ .symbol = self.core.define }, arguments.items);
    }

    fn sequenceExpression(self: *Runtime, forms: []const Value) !Value {
        std.debug.assert(forms.len != 0);
        if (forms.len == 1) return forms[0];
        return self.makeListWithHead(.{ .symbol = self.core.begin }, forms);
    }

    fn freshInternalSymbol(self: *Runtime, prefix: []const u8) !Symbol {
        const name = try std.fmt.allocPrint(
            self.allocator,
            "__lizp${s}${d}",
            .{ prefix, self.gensym_counter },
        );
        defer self.allocator.free(name);
        self.gensym_counter +%= 1;
        return self.intern(name);
    }

    /// The sole evaluation boundary. Language failures, invalid source,
    /// cancellation, and debugger pause are ordinary report outcomes. Zig
    /// errors are reserved for host/runtime failures that prevent Lizp from
    /// producing a trustworthy report.
    pub fn evaluate(
        self: *Runtime,
        request: EvaluationRequest,
    ) HostError!EvaluationReport {
        if (self.active_evaluations != 0) return error.RuntimeBusy;
        self.clearCondition();

        const origin: observation.EvaluationOrigin = switch (request) {
            .source => .source,
            .form => .value,
            .call => .host_call,
        };
        const environment: ObjectRef = switch (request) {
            .source => |source_request| source_request.environment orelse self.global_environment,
            .form => |form_request| form_request.environment orelse self.global_environment,
            .call => ObjectRef.none,
        };
        const source_id: ?SourceId = switch (request) {
            .source => |source_request| try self.registerSource(
                source_request.source_name,
                source_request.bytes,
            ),
            .form, .call => null,
        };

        const scope = self.beginEvaluation(origin, environment, source_id);
        defer self.endEvaluation(scope);

        switch (scope.start_action) {
            .continue_ => {},
            .cancel => {
                self.finishEvaluation(scope, .cancelled, null);
                return self.makeReport(scope.id, .cancelled);
            },
            .pause => {
                self.finishEvaluation(scope, .paused, null);
                return self.makeReport(scope.id, .paused);
            },
        }

        const result = self.executeRequest(request, source_id, scope) catch |err| {
            self.cleanupFailedEvaluation(scope, environment);

            if (self.pending_condition) |condition_value| {
                self.finishEvaluation(scope, .condition, null);
                return self.makeReport(
                    scope.id,
                    .{ .condition = condition_value },
                );
            }

            switch (err) {
                error.ObservationCancelled => {
                    self.finishEvaluation(scope, .cancelled, null);
                    return self.makeReport(scope.id, .cancelled);
                },
                error.ObservationPaused => {
                    self.finishEvaluation(scope, .paused, null);
                    return self.makeReport(scope.id, .paused);
                },
                error.OutOfMemory => {
                    self.finishEvaluation(scope, .host_failure, null);
                    return error.OutOfMemory;
                },
                error.OutOfCapacity => {
                    self.finishEvaluation(scope, .host_failure, null);
                    return error.OutOfCapacity;
                },
                error.NativeHostFailure => {
                    self.finishEvaluation(scope, .host_failure, null);
                    return error.NativeHostFailure;
                },
                error.RuntimeBusy => {
                    self.finishEvaluation(scope, .host_failure, null);
                    return error.RuntimeBusy;
                },
                else => {
                    self.finishEvaluation(scope, .host_failure, null);
                    return error.RuntimeInvariantFailure;
                },
            }
        };

        self.finishEvaluation(scope, .returned, result);
        return self.makeReport(scope.id, .{ .returned = result });
    }

    fn makeReport(
        self: *const Runtime,
        id: EvaluationId,
        outcome: EvaluationOutcome,
    ) EvaluationReport {
        return .{
            .id = id,
            .source = self.current_source,
            .outcome = outcome,
            .heap_live = self.heap.liveCount(),
        };
    }

    fn executeRequest(
        self: *Runtime,
        request: EvaluationRequest,
        source_id: ?SourceId,
        scope: EvaluationScope,
    ) anyerror!Value {
        return switch (request) {
            .source => |source_request| self.executeSource(
                source_id orelse return error.RuntimeInvariantFailure,
                source_request.environment orelse self.global_environment,
                scope,
            ),
            .form => |form_request| self.executeForm(
                form_request.value,
                form_request.environment orelse self.global_environment,
                scope,
            ),
            .call => |call_request| self.executeCall(
                call_request.function,
                call_request.arguments,
                scope,
            ),
        };
    }

    fn executeSource(
        self: *Runtime,
        source_id: SourceId,
        environment: EnvironmentRef,
        scope: EvaluationScope,
    ) anyerror!Value {
        self.current_phase = .read;
        _ = try self.expectEnvironmentConst(environment);
        self.current_span = null;
        self.current_origin = null;

        const source_view = self.sourceView(source_id).?;
        var parser = Parser{
            .runtime = self,
            .source = source_view.bytes,
            .source_id = source_id,
        };
        var forms: std.ArrayList(Value) = .empty;
        defer forms.deinit(self.allocator);
        while (true) {
            parser.skipIgnored();
            if (parser.atEnd()) break;
            try forms.append(self.allocator, try parser.parseValue());
        }

        self.current_phase = .expand;
        var expanded_forms: std.ArrayList(Value) = .empty;
        defer expanded_forms.deinit(self.allocator);
        try expanded_forms.ensureTotalCapacity(self.allocator, forms.items.len);
        for (forms.items) |form| {
            expanded_forms.appendAssumeCapacity(try self.expand(form));
        }

        // A safe point reached while executing an earlier top-level form must
        // not collect a later expanded form that has not run yet.
        for (expanded_forms.items) |form| try self.addEvaluationValueRoot(form);

        self.current_phase = .evaluate;
        var result: Value = .nil;
        for (expanded_forms.items) |form| {
            result = try self.evalAt(form, environment, 0);
        }
        if (scope.outermost) {
            self.evaluation_root_values.shrinkRetainingCapacity(scope.value_root_checkpoint);
            self.evaluation_root_environments.shrinkRetainingCapacity(scope.environment_root_checkpoint);
            _ = try self.collectEvaluationNursery(.{
                .values = &.{result},
                .environments = &.{environment},
            });
        }
        return result;
    }

    fn executeForm(
        self: *Runtime,
        value: Value,
        environment: ObjectRef,
        scope: EvaluationScope,
    ) anyerror!Value {
        self.current_phase = .expand;
        _ = try self.expectEnvironmentConst(environment);
        const expanded = try self.expand(value);
        try self.addEvaluationValueRoot(expanded);
        try self.addEvaluationEnvironmentRoot(environment);

        self.current_phase = .evaluate;
        const result = try self.evalAt(expanded, environment, 0);
        if (scope.outermost) {
            self.evaluation_root_values.shrinkRetainingCapacity(scope.value_root_checkpoint);
            self.evaluation_root_environments.shrinkRetainingCapacity(scope.environment_root_checkpoint);
            _ = try self.collectEvaluationNursery(.{
                .values = &.{result},
                .environments = &.{environment},
            });
        }
        return result;
    }

    fn executeCall(
        self: *Runtime,
        function: Value,
        args: []const Value,
        scope: EvaluationScope,
    ) anyerror!Value {
        self.current_phase = .evaluate;
        try self.addEvaluationValueRoot(function);
        for (args) |arg| try self.addEvaluationValueRoot(arg);

        const result = try self.resolveOutcome(
            try self.apply(function, args, 0, null),
            0,
        );
        if (scope.outermost) {
            _ = try self.collectEvaluationNursery(.{ .values = &.{result} });
        }
        return result;
    }

    fn cleanupFailedEvaluation(
        self: *Runtime,
        scope: EvaluationScope,
        environment: ObjectRef,
    ) void {
        if (!scope.outermost) return;
        self.evaluation_root_values.shrinkRetainingCapacity(scope.value_root_checkpoint);
        self.evaluation_root_environments.shrinkRetainingCapacity(scope.environment_root_checkpoint);
        if (environment.isNone()) {
            _ = self.collectEvaluationNursery(.{}) catch {};
        } else {
            _ = self.collectEvaluationNursery(.{
                .environments = &.{environment},
            }) catch {};
        }
    }

    fn evalAt(
        self: *Runtime,
        initial_value: Value,
        initial_environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        if (self.observer == null) {
            return self.evalAtUnobserved(initial_value, initial_environment, depth);
        }
        return self.evalAtObserved(
            initial_value,
            initial_environment,
            depth,
            null,
        );
    }

    fn evalAtWithCallContext(
        self: *Runtime,
        initial_value: Value,
        initial_environment: ObjectRef,
        depth: usize,
        initial_call_context: ?observation.ContextId,
    ) anyerror!Value {
        if (self.observer == null) {
            std.debug.assert(initial_call_context == null);
            return self.evalAtUnobserved(initial_value, initial_environment, depth);
        }
        return self.evalAtObserved(
            initial_value,
            initial_environment,
            depth,
            initial_call_context,
        );
    }

    fn evalAtUnobserved(
        self: *Runtime,
        initial_value: Value,
        initial_environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        if (depth > self.max_eval_depth) {
            return self.fail(error.EvalDepthExceeded, "evaluation depth exceeded {d}", .{self.max_eval_depth});
        }

        const value_root = self.evaluation_root_values.items.len;
        const environment_root = self.evaluation_root_environments.items.len;
        try self.addEvaluationValueRoot(initial_value);
        errdefer self.evaluation_root_values.shrinkRetainingCapacity(value_root);
        try self.addEvaluationEnvironmentRoot(initial_environment);
        defer {
            self.evaluation_root_values.shrinkRetainingCapacity(value_root);
            self.evaluation_root_environments.shrinkRetainingCapacity(environment_root);
        }

        const can_collect = self.active_evaluations == 1;
        var value = initial_value;
        var environment = initial_environment;
        while (true) {
            self.evaluation_root_values.items[value_root] = value;
            self.evaluation_root_environments.items[environment_root] = environment;
            switch (try self.evalOne(value, environment, depth, null)) {
                .value => |result| return result,
                .tail => |next| {
                    value = next.form;
                    environment = next.environment;
                    self.evaluation_root_values.items[value_root] = value;
                    self.evaluation_root_environments.items[environment_root] = environment;
                    if (can_collect and self.shouldCollectEvaluationNursery()) {
                        _ = try self.collectEvaluationNursery(.{
                            .values = &.{value},
                            .environments = &.{environment},
                        });
                    }
                },
            }
        }
    }

    fn evalAtObserved(
        self: *Runtime,
        initial_value: Value,
        initial_environment: ObjectRef,
        depth: usize,
        initial_call_context: ?observation.ContextId,
    ) anyerror!Value {
        if (depth > self.max_eval_depth) {
            return self.fail(error.EvalDepthExceeded, "evaluation depth exceeded {d}", .{self.max_eval_depth});
        }

        const value_root = self.evaluation_root_values.items.len;
        const environment_root = self.evaluation_root_environments.items.len;
        try self.addEvaluationValueRoot(initial_value);
        errdefer self.evaluation_root_values.shrinkRetainingCapacity(value_root);
        try self.addEvaluationEnvironmentRoot(initial_environment);
        defer {
            self.evaluation_root_values.shrinkRetainingCapacity(value_root);
            self.evaluation_root_environments.shrinkRetainingCapacity(environment_root);
        }

        const previous_context = self.current_context;
        defer self.current_context = previous_context;
        var active_call_context = initial_call_context;
        if (active_call_context) |context| self.current_context = context;

        const can_collect = self.active_evaluations == 1;

        var value = initial_value;
        var environment = initial_environment;
        while (true) {
            self.evaluation_root_values.items[value_root] = value;
            self.evaluation_root_environments.items[environment_root] = environment;
            switch (try self.evalOne(value, environment, depth, active_call_context)) {
                .value => |result| {
                    if (active_call_context) |context| {
                        _ = self.publishAt(context, .{
                            .call_returned = .{ .result = valueKind(result) },
                        });
                    }
                    return result;
                },
                .tail => |next| {
                    value = next.form;
                    environment = next.environment;
                    if (next.call_context) |context| {
                        active_call_context = context;
                        self.current_context = context;
                    }
                    self.evaluation_root_values.items[value_root] = value;
                    self.evaluation_root_environments.items[environment_root] = environment;
                    if (can_collect and self.shouldCollectEvaluationNursery()) {
                        _ = try self.collectEvaluationNursery(.{
                            .values = &.{value},
                            .environments = &.{environment},
                        });
                    }
                },
            }
        }
    }

    fn resolveOutcome(self: *Runtime, outcome: EvalOutcome, depth: usize) anyerror!Value {
        return switch (outcome) {
            .value => |value| value,
            .tail => |next| self.evalAtWithCallContext(
                next.form,
                next.environment,
                depth,
                next.call_context,
            ),
        };
    }

    fn evalOne(
        self: *Runtime,
        value: Value,
        environment: ObjectRef,
        depth: usize,
        tail_owner: ?observation.ContextId,
    ) anyerror!EvalOutcome {
        if (self.syntaxConst(value)) |syntax| {
            const previous_span = self.current_span;
            const previous_origin = self.current_origin;
            self.current_span = syntax.span;
            self.current_origin = syntax.origin;
            defer {
                self.current_span = previous_span;
                self.current_origin = previous_origin;
            }
            return self.evalOne(syntax.datum, environment, depth, tail_owner);
        }

        if (depth > self.max_eval_depth) {
            return self.fail(error.EvalDepthExceeded, "evaluation depth exceeded {d}", .{self.max_eval_depth});
        }

        return switch (value) {
            .symbol => |symbol| .{ .value = try self.lookup(environment, symbol) },
            .object => |ref| blk: {
                const object = self.getObjectConst(ref) orelse {
                    return self.fail(error.StaleObject, "attempted to evaluate stale object {d}/{d}", .{ ref.index, ref.generation });
                };
                break :blk switch (object.*) {
                    .pair => self.evalPair(value, environment, depth + 1, tail_owner),
                    .vector => .{ .value = try self.evalVector(value, environment, depth + 1) },
                    .syntax => unreachable,
                    else => .{ .value = value },
                };
            },
            else => .{ .value = value },
        };
    }

    fn evalVector(
        self: *Runtime,
        value: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        const items = try self.expectVectorConst(value);
        const root_checkpoint = self.evaluation_root_values.items.len;
        defer self.evaluation_root_values.shrinkRetainingCapacity(root_checkpoint);
        var evaluated: std.ArrayList(Value) = .empty;
        defer evaluated.deinit(self.allocator);
        try evaluated.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            const result = try self.evalAt(item, environment, depth + 1);
            evaluated.appendAssumeCapacity(result);
            try self.addEvaluationValueRoot(result);
        }
        return self.makeVector(evaluated.items);
    }

    fn evalPair(
        self: *Runtime,
        expression: Value,
        environment: ObjectRef,
        depth: usize,
        tail_owner: ?observation.ContextId,
    ) anyerror!EvalOutcome {
        const expression_pair = (try self.expectPairConst(expression)).*;
        const expression_head = try self.unwrapSyntax(expression_pair.car);
        if (expression_head == .symbol) {
            const symbol = expression_head.symbol;
            const language = (try self.expectEnvironmentConst(environment)).language;
            if (symbol == self.core.quote) {
                try self.requireSpecialForm(language.quote, "quote");
                return .{ .value = try self.evalQuote(expression_pair.cdr) };
            }
            if (symbol == self.core.if_) {
                try self.requireSpecialForm(language.if_, "if");
                return self.evalIf(expression_pair.cdr, environment, depth);
            }
            if (symbol == self.core.begin) {
                try self.requireSpecialForm(language.begin, "begin");
                return self.evalSequence(expression_pair.cdr, environment, depth);
            }
            if (symbol == self.core.define) {
                try self.requireSpecialForm(language.define, "define");
                return .{ .value = try self.evalDefine(expression_pair.cdr, environment, depth) };
            }
            if (symbol == self.core.set_bang) {
                try self.requireSpecialForm(language.set_bang, "set!");
                return .{ .value = try self.evalSet(expression_pair.cdr, environment, depth) };
            }
            if (symbol == self.core.lambda) {
                try self.requireSpecialForm(language.lambda, "lambda");
                return .{ .value = try self.evalLambda(expression_pair.cdr, environment) };
            }
            if (symbol == self.core.let_) {
                try self.requireSpecialForm(language.let_, "let");
                return self.evalLet(expression_pair.cdr, environment, depth);
            }
            if (symbol == self.core.while_) {
                try self.requireSpecialForm(language.while_, "while");
                return .{ .value = try self.evalWhile(expression_pair.cdr, environment, depth) };
            }
            if (symbol == self.core.and_) {
                try self.requireSpecialForm(language.and_, "and");
                return self.evalAnd(expression_pair.cdr, environment, depth);
            }
            if (symbol == self.core.or_) {
                try self.requireSpecialForm(language.or_, "or");
                return self.evalOr(expression_pair.cdr, environment, depth);
            }
        }

        const root_checkpoint = self.evaluation_root_values.items.len;
        defer self.evaluation_root_values.shrinkRetainingCapacity(root_checkpoint);

        const function = try self.evalAt(expression_pair.car, environment, depth + 1);
        try self.addEvaluationValueRoot(function);
        var arguments: std.ArrayList(Value) = .empty;
        defer arguments.deinit(self.allocator);
        var cursor = expression_pair.cdr;
        while (true) {
            switch (cursor) {
                .nil => break,
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    const argument = try self.evalAt(pair.car, environment, depth + 1);
                    try arguments.append(self.allocator, argument);
                    try self.addEvaluationValueRoot(argument);
                    cursor = pair.cdr;
                },
            }
        }
        return self.apply(function, arguments.items, depth + 1, tail_owner);
    }

    fn requireSpecialForm(
        self: *Runtime,
        allowed: bool,
        name: []const u8,
    ) anyerror!void {
        if (!allowed) {
            return self.fail(error.ForbiddenSpecialForm, "special form is disabled: {s}", .{name});
        }
    }

    fn evalQuote(self: *Runtime, arguments: Value) anyerror!Value {
        const values = try self.listToOwnedSlice(arguments);
        defer self.allocator.free(values);
        if (values.len != 1) {
            return self.fail(error.ArityMismatch, "quote expects exactly one argument, got {d}", .{values.len});
        }
        return self.syntaxToDatum(values[0]);
    }

    fn evalIf(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!EvalOutcome {
        const values = try self.listToOwnedSlice(arguments);
        defer self.allocator.free(values);
        if (values.len != 2 and values.len != 3) {
            return self.fail(error.ArityMismatch, "if expects two or three arguments, got {d}", .{values.len});
        }
        const condition = try self.evalAt(values[0], environment, depth + 1);
        if (!condition.isFalsey()) return .{ .tail = .{ .form = values[1], .environment = environment } };
        if (values.len == 3) return .{ .tail = .{ .form = values[2], .environment = environment } };
        return .{ .value = .nil };
    }

    fn evalSequence(
        self: *Runtime,
        forms: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!EvalOutcome {
        var cursor = forms;
        while (true) {
            switch (cursor) {
                .nil => return .{ .value = .nil },
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    if (pair.cdr == .nil) {
                        return .{ .tail = .{ .form = pair.car, .environment = environment } };
                    }
                    _ = try self.evalAt(pair.car, environment, depth + 1);
                    cursor = pair.cdr;
                },
            }
        }
    }

    fn evalSequenceValue(
        self: *Runtime,
        forms: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        return self.resolveOutcome(try self.evalSequence(forms, environment, depth), depth);
    }

    fn evalDefine(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        const first = try self.requireListPart(arguments, "define requires a name and value");
        switch (try self.unwrapSyntax(first.head)) {
            .symbol => |symbol| {
                const rest = try self.requireListPart(first.tail, "define requires a value expression");
                if (rest.tail != .nil) {
                    return self.fail(error.InvalidSyntax, "variable define accepts exactly one value expression", .{});
                }
                const value = try self.evalAt(rest.head, environment, depth + 1);
                const replaced = (try self.expectEnvironmentConst(environment)).bindings.contains(symbol);
                try self.defineInEnvironment(environment, symbol, value);
                self.publishDefinition(environment, symbol, replaced, value);
                return value;
            },
            .object => {
                const signature = (try self.expectPairConst(first.head)).*;
                const name = self.symbolOf(signature.car) orelse
                    return self.fail(error.InvalidSyntax, "function name in define must be a symbol", .{});
                if (first.tail == .nil) {
                    return self.fail(error.InvalidSyntax, "function define requires a body", .{});
                }
                try self.validateParameters(signature.cdr);
                const closure = try self.makeClosure(signature.cdr, first.tail, environment);
                const replaced = (try self.expectEnvironmentConst(environment)).bindings.contains(name);
                try self.defineInEnvironment(environment, name, closure);
                self.publishDefinition(environment, name, replaced, closure);
                return closure;
            },
            else => return self.fail(error.InvalidSyntax, "define target must be a symbol or function signature", .{}),
        }
    }

    fn evalSet(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        const values = try self.listToOwnedSlice(arguments);
        defer self.allocator.free(values);
        if (values.len != 2) {
            return self.fail(error.ArityMismatch, "set! expects exactly two arguments, got {d}", .{values.len});
        }
        const symbol = self.symbolOf(values[0]) orelse
            return self.fail(error.InvalidSyntax, "set! target must be a symbol", .{});
        const value = try self.evalAt(values[1], environment, depth + 1);
        try self.setExisting(environment, symbol, value);
        return value;
    }

    fn evalLambda(self: *Runtime, arguments: Value, environment: ObjectRef) anyerror!Value {
        const first = try self.requireListPart(arguments, "lambda requires a parameter list and body");
        if (first.tail == .nil) {
            return self.fail(error.InvalidSyntax, "lambda requires at least one body form", .{});
        }
        try self.validateParameters(first.head);
        return self.makeClosure(first.head, first.tail, environment);
    }

    fn evalLet(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!EvalOutcome {
        const first = try self.requireListPart(arguments, "let requires bindings and a body");
        if (first.tail == .nil) {
            return self.fail(error.InvalidSyntax, "let requires at least one body form", .{});
        }

        var names: std.ArrayList(Symbol) = .empty;
        defer names.deinit(self.allocator);
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(self.allocator);
        const root_checkpoint = self.evaluation_root_values.items.len;
        defer self.evaluation_root_values.shrinkRetainingCapacity(root_checkpoint);

        var bindings = first.head;
        while (true) {
            switch (bindings) {
                .nil => break,
                else => {
                    const binding_list = (try self.expectPairConst(bindings)).*;
                    const binding = try self.listToOwnedSlice(binding_list.car);
                    defer self.allocator.free(binding);
                    if (binding.len != 2) {
                        return self.fail(error.InvalidSyntax, "each let binding must have a name and expression", .{});
                    }
                    const name = self.symbolOf(binding[0]) orelse
                        return self.fail(error.InvalidSyntax, "let binding name must be a symbol", .{});
                    try names.append(self.allocator, name);
                    const value = try self.evalAt(binding[1], environment, depth + 1);
                    try values.append(self.allocator, value);
                    try self.addEvaluationValueRoot(value);
                    bindings = binding_list.cdr;
                },
            }
        }

        const child = try self.newEnvironment(environment);
        for (names.items, values.items) |name, value| {
            try self.defineInEnvironment(child, name, value);
        }
        return self.evalSequence(first.tail, child, depth + 1);
    }

    fn evalWhile(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!Value {
        const first = try self.requireListPart(arguments, "while requires a condition and body");
        if (first.tail == .nil) {
            return self.fail(error.ArityMismatch, "while requires at least one body expression", .{});
        }

        var result: Value = .nil;
        const result_root = self.evaluation_root_values.items.len;
        try self.addEvaluationValueRoot(result);
        defer self.evaluation_root_values.shrinkRetainingCapacity(result_root);
        while (true) {
            self.evaluation_root_values.items[result_root] = result;
            const condition = try self.evalAt(first.head, environment, depth + 1);
            if (condition.isFalsey()) return result;
            result = try self.evalSequenceValue(first.tail, environment, depth + 1);
        }
    }

    fn evalAnd(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!EvalOutcome {
        var result: Value = .{ .boolean = true };
        var cursor = arguments;
        while (true) {
            switch (cursor) {
                .nil => return .{ .value = result },
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    if (pair.cdr == .nil) {
                        return .{ .tail = .{ .form = pair.car, .environment = environment } };
                    }
                    result = try self.evalAt(pair.car, environment, depth + 1);
                    if (result.isFalsey()) return .{ .value = result };
                    cursor = pair.cdr;
                },
            }
        }
    }

    fn evalOr(
        self: *Runtime,
        arguments: Value,
        environment: ObjectRef,
        depth: usize,
    ) anyerror!EvalOutcome {
        var cursor = arguments;
        while (true) {
            switch (cursor) {
                .nil => return .{ .value = .{ .boolean = false } },
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    if (pair.cdr == .nil) {
                        return .{ .tail = .{ .form = pair.car, .environment = environment } };
                    }
                    const result = try self.evalAt(pair.car, environment, depth + 1);
                    if (!result.isFalsey()) return .{ .value = result };
                    cursor = pair.cdr;
                },
            }
        }
    }

    fn makeClosure(
        self: *Runtime,
        params: Value,
        body: Value,
        environment: ObjectRef,
    ) !Value {
        return .{ .object = try self.allocateObject(.{
            .closure = .{
                .params = params,
                .body = body,
                .environment = environment,
            },
        }) };
    }

    fn invokeNative(
        self: *Runtime,
        native: NativeEntry,
        args: []const Value,
    ) anyerror!Value {
        return switch (native.implementation) {
            .core => |function| function(native.context, self, args),
            .host => |function| blk: {
                const previous_phase = self.current_phase;
                self.current_phase = .native;
                defer self.current_phase = previous_phase;

                const outcome = try function(native.context, self, args);
                break :blk switch (outcome) {
                    .returned => |value| value,
                    .condition => |spec| return self.raiseNativeCondition(spec),
                };
            },
        };
    }

    fn apply(
        self: *Runtime,
        function: Value,
        args: []const Value,
        depth: usize,
        tail_owner: ?observation.ContextId,
    ) anyerror!EvalOutcome {
        if (self.observer == null) {
            std.debug.assert(tail_owner == null);
            return self.applyUnobserved(function, args, depth);
        }
        return self.applyObserved(function, args, depth, tail_owner);
    }

    fn applyUnobserved(
        self: *Runtime,
        function: Value,
        args: []const Value,
        depth: usize,
    ) anyerror!EvalOutcome {
        return switch (function) {
            .native => |index| blk: {
                if (index >= self.natives.items.len) {
                    return self.fail(error.NotCallable, "invalid native function index {d}", .{index});
                }
                const native = self.natives.items[index];
                break :blk .{ .value = try self.invokeNative(native, args) };
            },
            .object => |ref| blk: {
                const object = self.getObjectConst(ref) orelse {
                    return self.fail(error.StaleObject, "attempted to call stale object {d}/{d}", .{ ref.index, ref.generation });
                };
                const closure = switch (object.*) {
                    .closure => |closure| closure,
                    else => return self.fail(error.NotCallable, "object is not callable", .{}),
                };
                const call_environment = try self.newEnvironment(closure.environment);
                try self.bindArguments(call_environment, closure.params, args);
                break :blk self.evalSequence(closure.body, call_environment, depth + 1);
            },
            else => self.fail(error.NotCallable, "value of type {s} is not callable", .{@tagName(function)}),
        };
    }

    fn applyObserved(
        self: *Runtime,
        function: Value,
        args: []const Value,
        depth: usize,
        tail_owner: ?observation.ContextId,
    ) anyerror!EvalOutcome {
        return switch (function) {
            .native => |index| blk: {
                if (index >= self.natives.items.len) {
                    return self.fail(error.NotCallable, "invalid native function index {d}", .{index});
                }
                const native = self.natives.items[index];
                const parent = self.current_context;
                const context = self.nextContextId();
                try self.publishSafeAt(context, .{
                    .native_entered = .{
                        .parent = parent,
                        .native_index = index,
                        .name = native.name,
                        .argument_count = countU32(args.len),
                    },
                });

                const previous_context = self.current_context;
                self.current_context = context;
                defer self.current_context = previous_context;
                const result = try self.invokeNative(native, args);
                _ = self.publishAt(context, .{
                    .native_returned = .{
                        .native_index = index,
                        .name = native.name,
                        .result = valueKind(result),
                    },
                });
                break :blk .{ .value = result };
            },
            .object => |ref| blk: {
                const object = self.getObjectConst(ref) orelse {
                    return self.fail(error.StaleObject, "attempted to call stale object {d}/{d}", .{ ref.index, ref.generation });
                };
                const closure = switch (object.*) {
                    .closure => |closure| closure,
                    else => return self.fail(error.NotCallable, "object is not callable", .{}),
                };

                const parent = self.current_context;
                const context = self.nextContextId();
                if (tail_owner) |from| {
                    try self.publishSafeAt(from, .{
                        .tail_called = .{ .from = from, .to = context },
                    });
                }
                try self.publishSafeAt(context, .{
                    .call_entered = .{
                        .parent = parent,
                        .callee = entityId(ref),
                        .argument_count = countU32(args.len),
                    },
                });

                const previous_context = self.current_context;
                self.current_context = context;
                defer self.current_context = previous_context;

                const call_environment = try self.newEnvironment(closure.environment);
                try self.bindArguments(call_environment, closure.params, args);
                const outcome = try self.evalSequence(
                    closure.body,
                    call_environment,
                    depth + 1,
                );
                break :blk switch (outcome) {
                    .value => |result| value_outcome: {
                        _ = self.publishAt(context, .{
                            .call_returned = .{ .result = valueKind(result) },
                        });
                        break :value_outcome .{ .value = result };
                    },
                    .tail => |next| .{ .tail = .{
                        .form = next.form,
                        .environment = next.environment,
                        .call_context = context,
                    } },
                };
            },
            else => self.fail(error.NotCallable, "value of type {s} is not callable", .{@tagName(function)}),
        };
    }

    fn countU32(count: usize) u32 {
        return std.math.cast(u32, count) orelse std.math.maxInt(u32);
    }

    fn bindArguments(
        self: *Runtime,
        environment: ObjectRef,
        parameters: Value,
        args: []const Value,
    ) anyerror!void {
        var parameter_cursor = parameters;
        var index: usize = 0;
        while (true) {
            switch (try self.unwrapSyntax(parameter_cursor)) {
                .nil => {
                    if (index != args.len) {
                        return self.fail(error.ArityMismatch, "expected {d} arguments, got {d}", .{ index, args.len });
                    }
                    return;
                },
                .symbol => |rest_symbol| {
                    const rest = try self.list(args[index..]);
                    try self.defineInEnvironment(environment, rest_symbol, rest);
                    return;
                },
                else => {
                    const parameter_pair = (try self.expectPairConst(parameter_cursor)).*;
                    const symbol = self.symbolOf(parameter_pair.car) orelse
                        return self.fail(error.InvalidSyntax, "lambda parameter must be a symbol", .{});
                    if (index >= args.len) {
                        return self.fail(error.ArityMismatch, "not enough arguments", .{});
                    }
                    try self.defineInEnvironment(environment, symbol, args[index]);
                    index += 1;
                    parameter_cursor = parameter_pair.cdr;
                },
            }
        }
    }

    fn validateParameters(self: *Runtime, parameters: Value) anyerror!void {
        var cursor = parameters;
        while (true) {
            switch (try self.unwrapSyntax(cursor)) {
                .nil, .symbol => return,
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    if (self.symbolOf(pair.car) == null) {
                        return self.fail(error.InvalidSyntax, "lambda parameter must be a symbol", .{});
                    }
                    cursor = pair.cdr;
                },
            }
        }
    }

    const ListPart = struct {
        head: Value,
        tail: Value,
    };

    fn requireListPart(self: *Runtime, value: Value, message: []const u8) anyerror!ListPart {
        if (self.isNilDatum(value)) return self.fail(error.InvalidSyntax, "{s}", .{message});
        const pair = (try self.expectPairConst(value)).*;
        return .{ .head = pair.car, .tail = pair.cdr };
    }

    fn listToOwnedSlice(self: *Runtime, value: Value) anyerror![]Value {
        return self.copyList(self.allocator, value);
    }

    /// Copies a proper Lisp list into host-owned storage. The caller frees the
    /// returned slice with `allocator`.
    pub fn copyList(
        self: *Runtime,
        allocator: std.mem.Allocator,
        value: Value,
    ) anyerror![]Value {
        var result: std.ArrayList(Value) = .empty;
        errdefer result.deinit(allocator);
        var cursor = value;
        while (true) {
            switch (try self.unwrapSyntax(cursor)) {
                .nil => return result.toOwnedSlice(allocator),
                else => {
                    const pair = (try self.expectPairConst(cursor)).*;
                    try result.append(allocator, pair.car);
                    cursor = pair.cdr;
                },
            }
        }
    }

    fn lookupOptional(self: *Runtime, start: ObjectRef, symbol: Symbol) anyerror!?Value {
        var current: ?ObjectRef = start;
        while (current) |reference| {
            const environment = try self.expectEnvironmentConst(reference);
            if (environment.bindings.get(symbol)) |value| return value;
            current = environment.parent;
        }
        return null;
    }

    fn lookup(self: *Runtime, start: ObjectRef, symbol: Symbol) anyerror!Value {
        if (try self.lookupOptional(start, symbol)) |value| return value;
        return self.fail(
            error.UndefinedSymbol,
            "undefined symbol: {s}",
            .{self.symbolName(symbol) orelse "<invalid-symbol>"},
        );
    }

    fn validateCapabilityGrant(
        self: *Runtime,
        name: []const u8,
        value: Value,
        policy: GrantPolicy,
    ) anyerror!void {
        if (policy == .preserve_captured_authority) return;

        const seen = try self.allocator.alloc(bool, @intCast(self.heap.slotCount()));
        defer self.allocator.free(seen);
        @memset(seen, false);

        var stack: std.ArrayList(Value) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, value);

        while (stack.pop()) |current| {
            const reference = switch (current) {
                .object => |reference| reference,
                else => continue,
            };
            const object = self.getObjectConst(reference) orelse {
                return self.fail(
                    error.StaleObject,
                    "capability {s} contains stale object {d}/{d}",
                    .{ name, reference.index, reference.generation },
                );
            };
            if (seen[reference.index]) continue;
            seen[reference.index] = true;

            switch (object.*) {
                .string => {},
                .vector => |items| {
                    for (items) |item| try stack.append(self.allocator, item);
                },
                .pair => |pair| {
                    try stack.append(self.allocator, pair.car);
                    try stack.append(self.allocator, pair.cdr);
                },
                .syntax => |syntax| try stack.append(self.allocator, syntax.datum),
                .closure, .environment => {
                    return self.fail(
                        error.UnsafeCapabilityGrant,
                        "capability {s} contains a closure or environment with captured authority",
                        .{name},
                    );
                },
            }
        }
    }

    fn defineInEnvironment(
        self: *Runtime,
        reference: ObjectRef,
        symbol: Symbol,
        value: Value,
    ) anyerror!void {
        const environment = try self.expectEnvironment(reference);
        try environment.bindings.put(symbol, value);
    }

    fn publishDefinition(
        self: *Runtime,
        environment: ObjectRef,
        symbol: Symbol,
        replaced: bool,
        value: Value,
    ) void {
        _ = self.publish(.{
            .definition_committed = .{
                .environment = entityId(environment),
                .symbol = symbol,
                .replaced = replaced,
                .value = valueKind(value),
            },
        });
    }

    fn setExisting(
        self: *Runtime,
        start: ObjectRef,
        symbol: Symbol,
        value: Value,
    ) anyerror!void {
        var current: ?ObjectRef = start;
        while (current) |reference| {
            const environment = try self.expectEnvironment(reference);
            if (environment.bindings.getPtr(symbol)) |slot| {
                slot.* = value;
                return;
            }
            current = environment.parent;
        }
        return self.fail(
            error.UndefinedSymbol,
            "cannot set undefined symbol: {s}",
            .{self.symbolName(symbol) orelse "<invalid-symbol>"},
        );
    }

    fn newEnvironment(self: *Runtime, parent: ?ObjectRef) !ObjectRef {
        const language = if (parent) |reference|
            (try self.expectEnvironmentConst(reference)).language
        else
            LanguagePolicy{};
        return self.newEnvironmentWithPolicy(parent, language);
    }

    fn newEnvironmentWithPolicy(
        self: *Runtime,
        parent: ?ObjectRef,
        language: LanguagePolicy,
    ) !ObjectRef {
        var object = Object{
            .environment = Environment.init(self.allocator, parent, language),
        };
        errdefer object.deinit(self.allocator);
        return self.allocateObject(object);
    }

    fn allocateObject(self: *Runtime, object: Object) !ObjectRef {
        const observe_allocation = if (self.observer) |observer|
            observer.mask.contains(.object_allocated)
        else
            false;
        const kind = if (observe_allocation) objectKind(object) else undefined;

        const handle = try self.heap.create(object);
        const reference = fromHeapHandle(handle);
        if (self.active_evaluations != 0) {
            errdefer std.debug.assert(self.heap.destroy(handle));
            try self.evaluation_allocations.append(self.allocator, reference);
            self.evaluation_allocations_since_gc += 1;
        }
        if (observe_allocation) {
            _ = self.publish(.{
                .object_allocated = .{
                    .object = entityId(reference),
                    .kind = kind,
                },
            });
        }
        return reference;
    }

    fn getObject(self: *Runtime, reference: ObjectRef) ?*Object {
        return self.heap.get(toHeapHandle(reference));
    }

    fn getObjectConst(self: *const Runtime, reference: ObjectRef) ?*const Object {
        return self.heap.getConst(toHeapHandle(reference));
    }

    fn expectPairConst(self: *Runtime, value: Value) anyerror!*const Pair {
        const raw = try self.unwrapSyntax(value);
        const reference = switch (raw) {
            .object => |reference| reference,
            else => return self.fail(error.TypeMismatch, "expected pair, got {s}", .{@tagName(raw)}),
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(error.StaleObject, "stale object {d}/{d}", .{ reference.index, reference.generation });
        };
        return switch (object.*) {
            .pair => |*pair| pair,
            else => self.fail(error.TypeMismatch, "expected pair object", .{}),
        };
    }

    fn expectVectorConst(self: *Runtime, value: Value) anyerror![]const Value {
        const raw = try self.unwrapSyntax(value);
        const reference = switch (raw) {
            .object => |reference| reference,
            else => return self.fail(error.TypeMismatch, "expected vector, got {s}", .{@tagName(raw)}),
        };
        const object = self.getObjectConst(reference) orelse {
            return self.fail(error.StaleObject, "stale object {d}/{d}", .{ reference.index, reference.generation });
        };
        return switch (object.*) {
            .vector => |items| items,
            else => self.fail(error.TypeMismatch, "expected vector object", .{}),
        };
    }

    fn expectEnvironment(self: *Runtime, reference: ObjectRef) anyerror!*Environment {
        const object = self.getObject(reference) orelse {
            return self.fail(error.StaleObject, "stale environment {d}/{d}", .{ reference.index, reference.generation });
        };
        return switch (object.*) {
            .environment => |*environment| environment,
            else => self.fail(error.TypeMismatch, "object is not an environment", .{}),
        };
    }

    fn expectEnvironmentConst(self: *Runtime, reference: ObjectRef) anyerror!*const Environment {
        const object = self.getObjectConst(reference) orelse {
            return self.fail(error.StaleObject, "stale environment {d}/{d}", .{ reference.index, reference.generation });
        };
        return switch (object.*) {
            .environment => |*environment| environment,
            else => self.fail(error.TypeMismatch, "object is not an environment", .{}),
        };
    }

    pub fn collectGarbage(self: *Runtime, extra_roots: []const Value) anyerror!usize {
        return self.collectGarbageWithRoots(.{ .values = extra_roots });
    }

    pub fn collectGarbageWithRoots(self: *Runtime, roots: GcRoots) anyerror!usize {
        if (self.active_evaluations != 0) {
            return self.fail(
                error.CollectionDuringEvaluation,
                "garbage collection is only safe between evaluations",
                .{},
            );
        }

        const before = self.heap.liveCount();
        try self.publishSafe(.{
            .gc_started = .{
                .kind = .full,
                .heap_live_before = before,
                .candidates = before,
            },
        });

        const seen = try self.markReachable(roots, false);
        defer self.allocator.free(seen);

        var dead: std.ArrayList(Heap.Handle) = .empty;
        defer dead.deinit(self.allocator);
        var iterator = self.heap.iterator();
        while (iterator.next()) |entry| {
            if (!seen[entry.handle.index]) try dead.append(self.allocator, entry.handle);
        }
        for (dead.items) |handle| {
            const reference = fromHeapHandle(handle);
            const object = self.heap.getConst(handle).?;
            _ = self.publish(.{
                .object_reclaimed = .{
                    .object = entityId(reference),
                    .kind = objectKind(object.*),
                },
            });
            std.debug.assert(self.heap.destroy(handle));
        }
        const after = self.heap.liveCount();
        _ = self.publish(.{
            .gc_finished = .{
                .kind = .full,
                .heap_live_before = before,
                .heap_live_after = after,
                .reclaimed = countU32(dead.items.len),
            },
        });
        return dead.items.len;
    }

    fn shouldCollectEvaluationNursery(self: *const Runtime) bool {
        return self.evaluation_gc_interval != 0 and
            self.evaluation_allocations_since_gc >= self.evaluation_gc_interval and
            self.evaluation_allocations.items.len != 0;
    }

    /// Reclaims only objects allocated by the current outermost evaluation.
    /// Pre-existing heap objects are never swept implicitly, which keeps host
    /// values compatible with Lizp's explicit full-GC root contract.
    fn collectEvaluationNursery(self: *Runtime, roots: GcRoots) !usize {
        std.debug.assert(self.active_evaluations != 0);
        if (self.evaluation_allocations.items.len == 0) {
            self.evaluation_allocations_since_gc = 0;
            return 0;
        }

        const before = self.heap.liveCount();
        try self.publishSafe(.{
            .gc_started = .{
                .kind = .nursery,
                .heap_live_before = before,
                .candidates = countU32(self.evaluation_allocations.items.len),
            },
        });

        const seen = try self.markReachable(roots, true);
        defer self.allocator.free(seen);

        var retained: usize = 0;
        var reclaimed: usize = 0;
        for (self.evaluation_allocations.items) |reference| {
            const handle = toHeapHandle(reference);
            if (!self.heap.contains(handle)) continue;
            if (reference.index < seen.len and seen[reference.index]) {
                self.evaluation_allocations.items[retained] = reference;
                retained += 1;
            } else {
                const object = self.heap.getConst(handle).?;
                _ = self.publish(.{
                    .object_reclaimed = .{
                        .object = entityId(reference),
                        .kind = objectKind(object.*),
                    },
                });
                std.debug.assert(self.heap.destroy(handle));
                reclaimed += 1;
            }
        }
        self.evaluation_allocations.shrinkRetainingCapacity(retained);
        self.evaluation_allocations_since_gc = 0;
        self.nursery_collections += 1;
        const after = self.heap.liveCount();
        _ = self.publish(.{
            .gc_finished = .{
                .kind = .nursery,
                .heap_live_before = before,
                .heap_live_after = after,
                .reclaimed = countU32(reclaimed),
            },
        });
        return reclaimed;
    }

    fn markReachable(
        self: *Runtime,
        roots: GcRoots,
        include_evaluation_roots: bool,
    ) ![]bool {
        const slot_count: usize = @intCast(self.heap.slotCount());
        const seen = try self.allocator.alloc(bool, slot_count);
        errdefer self.allocator.free(seen);
        @memset(seen, false);

        var stack: std.ArrayList(ObjectRef) = .empty;
        defer stack.deinit(self.allocator);

        const Marker = struct {
            runtime: *Runtime,
            seen: []bool,
            stack: *std.ArrayList(ObjectRef),

            fn pushRef(marker: *@This(), reference: ObjectRef) !void {
                if (reference.isNone()) return;
                if (reference.index >= marker.seen.len) return;
                if (!marker.runtime.heap.contains(toHeapHandle(reference))) return;
                if (marker.seen[reference.index]) return;
                marker.seen[reference.index] = true;
                try marker.stack.append(marker.runtime.allocator, reference);
            }

            fn pushValue(marker: *@This(), value: Value) !void {
                switch (value) {
                    .object => |reference| try marker.pushRef(reference),
                    else => {},
                }
            }
        };

        var marker = Marker{
            .runtime = self,
            .seen = seen,
            .stack = &stack,
        };
        try marker.pushRef(self.global_environment);
        if (include_evaluation_roots) {
            for (self.evaluation_root_environments.items) |environment| try marker.pushRef(environment);
            for (self.evaluation_root_values.items) |value| try marker.pushValue(value);
        }
        for (roots.environments) |environment| try marker.pushRef(environment);
        for (roots.values) |root| try marker.pushValue(root);

        while (stack.pop()) |reference| {
            const object = self.getObjectConst(reference) orelse continue;
            switch (object.*) {
                .pair => |pair| {
                    try marker.pushValue(pair.car);
                    try marker.pushValue(pair.cdr);
                },
                .vector => |items| {
                    for (items) |item| try marker.pushValue(item);
                },
                .closure => |closure| {
                    try marker.pushValue(closure.params);
                    try marker.pushValue(closure.body);
                    try marker.pushRef(closure.environment);
                },
                .environment => |*environment| {
                    if (environment.parent) |parent| try marker.pushRef(parent);
                    var iterator = environment.bindings.valueIterator();
                    while (iterator.next()) |value| try marker.pushValue(value.*);
                },
                .syntax => |syntax| try marker.pushValue(syntax.datum),
                .string => {},
            }
        }

        return seen;
    }

    pub fn nurseryCollectionCount(self: *const Runtime) usize {
        return self.nursery_collections;
    }

    pub fn writeValue(self: *const Runtime, writer: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
        return self.writeValueDepth(writer, value, 0);
    }

    fn writeValueDepth(self: *const Runtime, writer: *std.Io.Writer, value: Value, depth: usize) std.Io.Writer.Error!void {
        if (depth > 64) {
            try writer.writeAll("#<depth-limit>");
            return;
        }
        switch (value) {
            .nil => try writer.writeAll("nil"),
            .boolean => |boolean| try writer.writeAll(if (boolean) "#t" else "#f"),
            .integer => |integer| try writer.print("{d}", .{integer}),
            .symbol => |symbol| try writer.writeAll(self.symbolName(symbol) orelse "#<invalid-symbol>"),
            .native => |index| {
                if (index < self.natives.items.len) {
                    const name = self.symbolName(self.natives.items[index].name) orelse "?";
                    try writer.print("#<native:{s}>", .{name});
                } else {
                    try writer.print("#<native:{d}>", .{index});
                }
            },
            .object => |reference| {
                const object = self.getObjectConst(reference) orelse {
                    try writer.print("#<stale:{d}/{d}>", .{ reference.index, reference.generation });
                    return;
                };
                switch (object.*) {
                    .string => |bytes| try writeEscapedString(writer, bytes),
                    .vector => |items| try self.writeVector(writer, items, depth + 1),
                    .closure => try writer.writeAll("#<closure>"),
                    .environment => try writer.writeAll("#<environment>"),
                    .syntax => |syntax| try self.writeValueDepth(writer, syntax.datum, depth + 1),
                    .pair => try self.writePair(writer, value, depth + 1),
                }
            },
        }
    }

    fn writePair(self: *const Runtime, writer: *std.Io.Writer, pair_value: Value, depth: usize) std.Io.Writer.Error!void {
        try writer.writeAll("(");
        var cursor = pair_value;
        var count: usize = 0;
        while (true) {
            if (count >= 256) {
                try writer.writeAll(" ...");
                break;
            }
            const reference = switch (cursor) {
                .object => |reference| reference,
                else => unreachable,
            };
            const object = self.getObjectConst(reference) orelse {
                try writer.writeAll("#<stale>");
                break;
            };
            const pair = switch (object.*) {
                .pair => |pair| pair,
                else => unreachable,
            };
            if (count != 0) try writer.writeAll(" ");
            try self.writeValueDepth(writer, pair.car, depth + 1);
            count += 1;
            switch (pair.cdr) {
                .nil => break,
                .object => |next_reference| {
                    const next = self.getObjectConst(next_reference);
                    if (next != null and next.?.* == .pair) {
                        cursor = pair.cdr;
                        continue;
                    }
                    try writer.writeAll(" . ");
                    try self.writeValueDepth(writer, pair.cdr, depth + 1);
                    break;
                },
                else => {
                    try writer.writeAll(" . ");
                    try self.writeValueDepth(writer, pair.cdr, depth + 1);
                    break;
                },
            }
        }
        try writer.writeAll(")");
    }

    fn writeVector(
        self: *const Runtime,
        writer: *std.Io.Writer,
        items: []const Value,
        depth: usize,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[");
        for (items, 0..) |item, index| {
            if (index != 0) try writer.writeAll(" ");
            try self.writeValueDepth(writer, item, depth + 1);
        }
        try writer.writeAll("]");
    }

    pub fn formatAlloc(self: *const Runtime, value: Value) anyerror![]u8 {
        var output = std.Io.Writer.Allocating.init(self.allocator);
        errdefer output.deinit();
        try self.writeValue(&output.writer, value);
        return output.toOwnedSlice();
    }

    fn installCore(self: *Runtime) !void {
        try self.registerCoreNative("+", nativeAdd);
        try self.registerCoreNative("-", nativeSubtract);
        try self.registerCoreNative("*", nativeMultiply);
        try self.registerCoreNative("/", nativeDivide);
        try self.registerCoreNative("=", nativeNumberEqual);
        try self.registerCoreNative("<", nativeLessThan);
        try self.registerCoreNative("<=", nativeLessEqual);
        try self.registerCoreNative(">", nativeGreaterThan);
        try self.registerCoreNative(">=", nativeGreaterEqual);
        try self.registerCoreNative("cons", nativeCons);
        try self.registerCoreNative("car", nativeCar);
        try self.registerCoreNative("cdr", nativeCdr);
        try self.registerCoreNative("list", nativeList);
        try self.registerCoreNative("null?", nativeIsNull);
        try self.registerCoreNative("pair?", nativeIsPair);
        try self.registerCoreNative("number?", nativeIsNumber);
        try self.registerCoreNative("symbol?", nativeIsSymbol);
        try self.registerCoreNative("string?", nativeIsString);
        try self.registerCoreNative("boolean?", nativeIsBoolean);
        try self.registerCoreNative("procedure?", nativeIsProcedure);
        try self.registerCoreNative("not", nativeNot);
        try self.registerCoreNative("eq?", nativeEq);
        try self.registerCoreNative("length", nativeLength);
        try self.registerCoreNative("vector", nativeVector);
        try self.registerCoreNative("vector?", nativeIsVector);
        try self.registerCoreNative("count", nativeCount);
        try self.registerCoreNative("nth", nativeNth);
    }
};

fn conditionCodeFromError(err: anyerror) ConditionCode {
    return switch (err) {
        error.UnexpectedEndOfInput => .unexpected_end_of_input,
        error.UnexpectedToken => .unexpected_token,
        error.UnterminatedString => .unterminated_string,
        error.InvalidEscape => .invalid_escape,
        error.InvalidNumber => .invalid_number,
        error.ImproperList => .improper_list,
        error.InvalidSyntax => .invalid_syntax,
        error.UndefinedSymbol => .undefined_symbol,
        error.TypeMismatch => .type_mismatch,
        error.ArityMismatch => .arity_mismatch,
        error.NotCallable => .not_callable,
        error.StaleObject => .stale_object,
        error.DivisionByZero => .division_by_zero,
        error.IntegerOverflow => .integer_overflow,
        error.IndexOutOfBounds => .index_out_of_bounds,
        error.EvalDepthExceeded => .eval_depth_exceeded,
        error.ExpansionDepthExceeded => .expansion_depth_exceeded,
        error.CollectionDuringEvaluation => .collection_during_evaluation,
        error.ForbiddenSpecialForm => .forbidden_special_form,
        error.UnsafeCapabilityGrant => .unsafe_capability_grant,
        error.CoreNotInstalled => .core_not_installed,
        error.TooManySymbols => .too_many_symbols,
        error.TooManyNatives => .too_many_natives,
        error.NativeConditionRaised => .native_condition,
        else => .internal,
    };
}

fn sourcePointAt(bytes: []const u8, offset: u32) SourcePoint {
    var line: u32 = 1;
    var column: u32 = 1;
    const limit: usize = @min(@as(usize, offset), bytes.len);
    for (bytes[0..limit]) |byte| {
        if (byte == '\n') {
            line +|= 1;
            column = 1;
        } else {
            column +|= 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn toHeapHandle(reference: ObjectRef) Heap.Handle {
    return .{
        .index = reference.index,
        .generation = reference.generation,
    };
}

fn fromHeapHandle(handle: Heap.Handle) ObjectRef {
    return .{
        .index = handle.index,
        .generation = handle.generation,
    };
}

const Parser = struct {
    runtime: *Runtime,
    source: []const u8,
    source_id: SourceId,
    position: usize = 0,

    fn atEnd(parser: *const Parser) bool {
        return parser.position >= parser.source.len;
    }

    fn span(parser: *const Parser, start: usize, end: usize) SourceSpan {
        return .{
            .source = parser.source_id,
            .start = @intCast(@min(start, parser.source.len)),
            .end = @intCast(@min(end, parser.source.len)),
        };
    }

    fn skipIgnored(parser: *Parser) void {
        while (!parser.atEnd()) {
            if (parser.position == 0 and std.mem.startsWith(u8, parser.source, "#!")) {
                while (!parser.atEnd() and parser.source[parser.position] != '\n') {
                    parser.position += 1;
                }
                continue;
            }
            const byte = parser.source[parser.position];
            if (std.ascii.isWhitespace(byte) or byte == ',') {
                parser.position += 1;
                continue;
            }
            if (byte == ';') {
                while (!parser.atEnd() and parser.source[parser.position] != '\n') {
                    parser.position += 1;
                }
                continue;
            }
            break;
        }
    }

    fn parseValue(parser: *Parser) anyerror!Value {
        parser.skipIgnored();
        const start = parser.position;
        if (parser.atEnd()) {
            return parser.parseFailAt(
                error.UnexpectedEndOfInput,
                parser.span(start, start),
                "expected expression",
                .{},
            );
        }

        const datum = switch (parser.source[parser.position]) {
            '(' => try parser.parseList(),
            '[' => try parser.parseVector(),
            ')' => return parser.parseFailAt(
                error.UnexpectedToken,
                parser.span(start, start + 1),
                "unexpected ')'",
                .{},
            ),
            ']' => return parser.parseFailAt(
                error.UnexpectedToken,
                parser.span(start, start + 1),
                "unexpected ']'",
                .{},
            ),
            '\'' => try parser.parseQuote(),
            '"' => try parser.parseString(),
            else => try parser.parseAtom(),
        };
        return parser.runtime.makeSyntax(
            datum,
            parser.span(start, parser.position),
            null,
        );
    }

    fn parseQuote(parser: *Parser) anyerror!Value {
        const quote_start = parser.position;
        parser.position += 1;
        const quoted = try parser.parseValue();
        const quote_symbol = try parser.runtime.makeSyntax(
            .{ .symbol = parser.runtime.core.quote },
            parser.span(quote_start, quote_start + 1),
            null,
        );
        return parser.runtime.list(&.{ quote_symbol, quoted });
    }

    fn parseList(parser: *Parser) anyerror!Value {
        const opening = parser.position;
        parser.position += 1;
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(parser.runtime.allocator);
        var tail: Value = .nil;

        while (true) {
            parser.skipIgnored();
            if (parser.atEnd()) {
                return parser.parseFailAt(
                    error.UnexpectedEndOfInput,
                    parser.span(opening, parser.source.len),
                    "unterminated list",
                    .{},
                );
            }
            if (parser.source[parser.position] == ')') {
                parser.position += 1;
                break;
            }
            if (parser.source[parser.position] == '.' and parser.dotIsStandalone()) {
                const dot = parser.position;
                if (items.items.len == 0) {
                    return parser.parseFailAt(
                        error.InvalidSyntax,
                        parser.span(dot, dot + 1),
                        "dot cannot begin a list",
                        .{},
                    );
                }
                parser.position += 1;
                tail = try parser.parseValue();
                parser.skipIgnored();
                if (parser.atEnd() or parser.source[parser.position] != ')') {
                    return parser.parseFailAt(
                        error.InvalidSyntax,
                        parser.span(dot, parser.position),
                        "dotted list must end after its tail",
                        .{},
                    );
                }
                parser.position += 1;
                break;
            }
            try items.append(parser.runtime.allocator, try parser.parseValue());
        }

        var result = tail;
        var index = items.items.len;
        while (index > 0) {
            index -= 1;
            result = try parser.runtime.cons(items.items[index], result);
        }
        return result;
    }

    fn parseVector(parser: *Parser) anyerror!Value {
        const opening = parser.position;
        parser.position += 1;
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(parser.runtime.allocator);

        while (true) {
            parser.skipIgnored();
            if (parser.atEnd()) {
                return parser.parseFailAt(
                    error.UnexpectedEndOfInput,
                    parser.span(opening, parser.source.len),
                    "unterminated vector",
                    .{},
                );
            }
            if (parser.source[parser.position] == ']') {
                parser.position += 1;
                return parser.runtime.makeVector(items.items);
            }
            try items.append(parser.runtime.allocator, try parser.parseValue());
        }
    }

    fn parseString(parser: *Parser) anyerror!Value {
        const opening = parser.position;
        parser.position += 1;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(parser.runtime.allocator);
        while (!parser.atEnd()) {
            const byte = parser.source[parser.position];
            parser.position += 1;
            if (byte == '"') {
                const owned = try bytes.toOwnedSlice(parser.runtime.allocator);
                return parser.runtime.makeStringOwned(owned);
            }
            if (byte != '\\') {
                try bytes.append(parser.runtime.allocator, byte);
                continue;
            }
            if (parser.atEnd()) {
                return parser.parseFailAt(
                    error.UnterminatedString,
                    parser.span(opening, parser.position),
                    "escape at end of string",
                    .{},
                );
            }
            const escaped_at = parser.position;
            const escaped = parser.source[parser.position];
            parser.position += 1;
            try bytes.append(parser.runtime.allocator, switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                else => return parser.parseFailAt(
                    error.InvalidEscape,
                    parser.span(escaped_at - 1, escaped_at + 1),
                    "unknown string escape '\\{c}'",
                    .{escaped},
                ),
            });
        }
        return parser.parseFailAt(
            error.UnterminatedString,
            parser.span(opening, parser.source.len),
            "unterminated string literal",
            .{},
        );
    }

    fn parseAtom(parser: *Parser) anyerror!Value {
        const start = parser.position;
        while (!parser.atEnd() and !isDelimiter(parser.source[parser.position])) {
            parser.position += 1;
        }
        if (parser.position == start) {
            return parser.parseFailAt(
                error.UnexpectedToken,
                parser.span(start, start + 1),
                "expected atom",
                .{},
            );
        }
        const token = parser.source[start..parser.position];
        if (std.mem.eql(u8, token, "nil")) return .nil;
        if (std.mem.eql(u8, token, "#t") or std.mem.eql(u8, token, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, token, "#f") or std.mem.eql(u8, token, "false")) return .{ .boolean = false };
        if (looksLikeInteger(token)) {
            const integer = std.fmt.parseInt(i64, token, 10) catch {
                return parser.parseFailAt(
                    error.InvalidNumber,
                    parser.span(start, parser.position),
                    "invalid integer '{s}'",
                    .{token},
                );
            };
            return .{ .integer = integer };
        }
        return .{ .symbol = try parser.runtime.intern(token) };
    }

    fn dotIsStandalone(parser: *const Parser) bool {
        const next = parser.position + 1;
        return next >= parser.source.len or isDelimiter(parser.source[next]);
    }

    fn parseFailAt(
        parser: *Parser,
        err: anyerror,
        source_span: SourceSpan,
        comptime format: []const u8,
        args: anytype,
    ) anyerror {
        var detail_bytes: [192]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_bytes, format, args) catch
            "parse diagnostic exceeded inline capacity";
        return parser.runtime.failAt(
            err,
            source_span,
            null,
            "parse error at byte {d}: {s}",
            .{ source_span.start, detail },
        );
    }
};

fn isDelimiter(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == ',' or
        byte == '(' or byte == ')' or byte == '[' or byte == ']' or
        byte == '\'' or byte == '"' or byte == ';';
}

fn nameInList(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn looksLikeInteger(token: []const u8) bool {
    if (token.len == 0) return false;
    var index: usize = 0;
    if (token[0] == '+' or token[0] == '-') {
        index = 1;
        if (index == token.len) return false;
    }
    while (index < token.len) : (index += 1) {
        if (!std.ascii.isDigit(token[index])) return false;
    }
    return true;
}

fn writeEscapedString(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("\"");
    for (bytes) |byte| {
        switch (byte) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeAll("\"");
}

fn requireArity(runtime: *Runtime, args: []const Value, expected: usize, name: []const u8) anyerror!void {
    if (args.len != expected) {
        return runtime.fail(error.ArityMismatch, "{s} expects {d} arguments, got {d}", .{ name, expected, args.len });
    }
}

fn requireAtLeast(runtime: *Runtime, args: []const Value, minimum: usize, name: []const u8) anyerror!void {
    if (args.len < minimum) {
        return runtime.fail(error.ArityMismatch, "{s} expects at least {d} arguments, got {d}", .{ name, minimum, args.len });
    }
}

fn nativeAdd(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    var result: i64 = 0;
    for (args) |arg| {
        result = std.math.add(i64, result, try runtime.expectInteger(arg)) catch {
            return runtime.fail(error.IntegerOverflow, "integer overflow in +", .{});
        };
    }
    return .{ .integer = result };
}

fn nativeSubtract(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireAtLeast(runtime, args, 1, "-");
    var result = try runtime.expectInteger(args[0]);
    if (args.len == 1) {
        result = std.math.negate(result) catch return runtime.fail(error.IntegerOverflow, "integer overflow in unary -", .{});
    } else {
        for (args[1..]) |arg| {
            result = std.math.sub(i64, result, try runtime.expectInteger(arg)) catch {
                return runtime.fail(error.IntegerOverflow, "integer overflow in -", .{});
            };
        }
    }
    return .{ .integer = result };
}

fn nativeMultiply(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    var result: i64 = 1;
    for (args) |arg| {
        result = std.math.mul(i64, result, try runtime.expectInteger(arg)) catch {
            return runtime.fail(error.IntegerOverflow, "integer overflow in *", .{});
        };
    }
    return .{ .integer = result };
}

fn nativeDivide(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireAtLeast(runtime, args, 2, "/");
    var result = try runtime.expectInteger(args[0]);
    for (args[1..]) |arg| {
        const denominator = try runtime.expectInteger(arg);
        if (denominator == 0) return runtime.fail(error.DivisionByZero, "division by zero", .{});
        result = std.math.divTrunc(i64, result, denominator) catch {
            return runtime.fail(error.IntegerOverflow, "integer overflow in /", .{});
        };
    }
    return .{ .integer = result };
}

const Comparison = enum { lt, le, gt, ge };

fn compareIntegers(runtime: *Runtime, args: []const Value, operation: Comparison, name: []const u8) anyerror!Value {
    try requireAtLeast(runtime, args, 2, name);
    var previous = try runtime.expectInteger(args[0]);
    for (args[1..]) |arg| {
        const next = try runtime.expectInteger(arg);
        const okay = switch (operation) {
            .lt => previous < next,
            .le => previous <= next,
            .gt => previous > next,
            .ge => previous >= next,
        };
        if (!okay) return .{ .boolean = false };
        previous = next;
    }
    return .{ .boolean = true };
}

fn nativeNumberEqual(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireAtLeast(runtime, args, 2, "=");
    const first = try runtime.expectInteger(args[0]);
    for (args[1..]) |arg| {
        if (try runtime.expectInteger(arg) != first) return .{ .boolean = false };
    }
    return .{ .boolean = true };
}

fn nativeLessThan(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return compareIntegers(runtime, args, .lt, "<");
}

fn nativeLessEqual(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return compareIntegers(runtime, args, .le, "<=");
}

fn nativeGreaterThan(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return compareIntegers(runtime, args, .gt, ">");
}

fn nativeGreaterEqual(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return compareIntegers(runtime, args, .ge, ">=");
}

fn nativeCons(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 2, "cons");
    return runtime.cons(args[0], args[1]);
}

fn nativeCar(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "car");
    return (try runtime.expectPairConst(args[0])).car;
}

fn nativeCdr(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "cdr");
    return (try runtime.expectPairConst(args[0])).cdr;
}

fn nativeList(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return runtime.list(args);
}

fn nativeIsNull(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "null?");
    return .{ .boolean = args[0] == .nil };
}

fn nativeIsPair(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "pair?");
    const result = switch (args[0]) {
        .object => |reference| if (runtime.getObjectConst(reference)) |object| object.* == .pair else false,
        else => false,
    };
    return .{ .boolean = result };
}

fn nativeIsNumber(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "number?");
    return .{ .boolean = args[0] == .integer };
}

fn nativeIsSymbol(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "symbol?");
    return .{ .boolean = args[0] == .symbol };
}

fn nativeIsString(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "string?");
    const result = switch (args[0]) {
        .object => |reference| if (runtime.getObjectConst(reference)) |object| object.* == .string else false,
        else => false,
    };
    return .{ .boolean = result };
}

fn nativeIsBoolean(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "boolean?");
    return .{ .boolean = args[0] == .boolean };
}

fn nativeIsProcedure(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "procedure?");
    const result = switch (args[0]) {
        .native => true,
        .object => |reference| if (runtime.getObjectConst(reference)) |object| object.* == .closure else false,
        else => false,
    };
    return .{ .boolean = result };
}

fn nativeNot(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "not");
    return .{ .boolean = args[0].isFalsey() };
}

fn nativeEq(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 2, "eq?");
    return .{ .boolean = args[0].eqlShallow(args[1]) };
}

fn nativeLength(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "length");
    var length: i64 = 0;
    var cursor = args[0];
    while (true) {
        switch (cursor) {
            .nil => return .{ .integer = length },
            else => {
                const pair = (try runtime.expectPairConst(cursor)).*;
                length = std.math.add(i64, length, 1) catch return runtime.fail(error.IntegerOverflow, "list length overflow", .{});
                cursor = pair.cdr;
            },
        }
    }
}

fn nativeVector(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    return runtime.makeVector(args);
}

fn nativeIsVector(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "vector?");
    return .{ .boolean = runtime.asVector(args[0]) != null };
}

fn nativeCount(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 1, "count");
    if (args[0] == .nil) return .{ .integer = 0 };
    if (runtime.asVector(args[0])) |items| {
        return .{ .integer = std.math.cast(i64, items.len) orelse
            return runtime.fail(error.IntegerOverflow, "vector count exceeds i64", .{}) };
    }
    if (runtime.asString(args[0])) |bytes| {
        return .{ .integer = std.math.cast(i64, bytes.len) orelse
            return runtime.fail(error.IntegerOverflow, "string count exceeds i64", .{}) };
    }
    return nativeLength(null, runtime, args);
}

fn nativeNth(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
    try requireArity(runtime, args, 2, "nth");
    const signed_index = try runtime.expectInteger(args[1]);
    if (signed_index < 0) {
        return runtime.fail(error.IndexOutOfBounds, "nth index must be non-negative", .{});
    }
    const index = std.math.cast(usize, signed_index) orelse
        return runtime.fail(error.IndexOutOfBounds, "nth index is too large", .{});

    if (runtime.asVector(args[0])) |items| {
        if (index >= items.len) {
            return runtime.fail(error.IndexOutOfBounds, "nth index {d} is outside vector of length {d}", .{ index, items.len });
        }
        return items[index];
    }

    var cursor = args[0];
    var current: usize = 0;
    while (cursor != .nil) : (current += 1) {
        const pair = (try runtime.expectPairConst(cursor)).*;
        if (current == index) return pair.car;
        cursor = pair.cdr;
    }
    return runtime.fail(error.IndexOutOfBounds, "nth index {d} is outside list of length {d}", .{ index, current });
}

fn testEval(runtime: *Runtime, source: []const u8) anyerror!Value {
    const report = try runtime.evaluate(.{
        .source = .{ .bytes = source },
    });
    return testReturned(report);
}

fn testEvalIn(
    runtime: *Runtime,
    source: []const u8,
    environment: EnvironmentRef,
) anyerror!Value {
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = source,
            .environment = environment,
        },
    });
    return testReturned(report);
}

fn testCall(
    runtime: *Runtime,
    function: Value,
    arguments: []const Value,
) anyerror!Value {
    const report = try runtime.evaluate(.{
        .call = .{
            .function = function,
            .arguments = arguments,
        },
    });
    return testReturned(report);
}

fn testReturned(report: EvaluationReport) anyerror!Value {
    return switch (report.outcome) {
        .returned => |value| value,
        .condition => |condition_value| {
            std.debug.print(
                "unexpected Lizp condition {s}/{s}: {s}\n",
                .{
                    @tagName(condition_value.phase),
                    @tagName(condition_value.code),
                    condition_value.message(),
                },
            );
            return error.TestUnexpectedCondition;
        },
        .cancelled => error.TestUnexpectedCancellation,
        .paused => error.TestUnexpectedPause,
    };
}

fn testCondition(
    runtime: *Runtime,
    source: []const u8,
) anyerror!Condition {
    const report = try runtime.evaluate(.{
        .source = .{ .bytes = source },
    });
    return switch (report.outcome) {
        .condition => |condition_value| condition_value,
        else => error.TestExpectedCondition,
    };
}

fn testConditionIn(
    runtime: *Runtime,
    source: []const u8,
    environment: EnvironmentRef,
) anyerror!Condition {
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = source,
            .environment = environment,
        },
    });
    return switch (report.outcome) {
        .condition => |condition_value| condition_value,
        else => error.TestExpectedCondition,
    };
}

fn sourceProvenanceAllocationFailureWork(allocator: std.mem.Allocator) !void {
    var runtime = try Runtime.init(allocator);
    defer runtime.deinit();

    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = "(do (defn inc [x] (+ x 1)) (inc 41))",
            .source_name = "test://allocation-failures",
        },
    });
    const value = try testReturned(report);
    if (runtime.asInteger(value) != 42) return error.TestUnexpectedResult;
    const source_id = report.source orelse return error.TestUnexpectedResult;
    if (runtime.sourceView(source_id) == null) return error.TestUnexpectedResult;
}

test "source-aware evaluation unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        sourceProvenanceAllocationFailureWork,
        .{},
    );
}

test "language conditions are reports and the runtime remains reusable" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const failed = try runtime.evaluate(.{
        .source = .{
            .bytes = "(",
            .source_name = "test://invalid-source",
        },
    });
    const condition_value = switch (failed.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    try testing.expectEqual(ConditionCode.unexpected_end_of_input, condition_value.code);
    try testing.expectEqual(ConditionPhase.read, condition_value.phase);
    try testing.expectEqual(condition_value.id, runtime.lastCondition().?.id);

    const succeeded = try runtime.evaluate(.{
        .source = .{ .bytes = "(+ 20 22)" },
    });
    const value = try testReturned(succeeded);
    try testing.expectEqual(@as(i64, 42), value.integer);
    try testing.expect(runtime.lastCondition() == null);
    try testing.expect(failed.id != succeeded.id);
}

test "source reports retain immutable bytes and precise reader spans" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    var input = [_]u8{'('};
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = &input,
            .source_name = "test://reader-span",
        },
    });
    const condition_value = switch (report.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    const source_id = report.source orelse return error.TestUnexpectedResult;
    const source_span = condition_value.span orelse return error.TestUnexpectedResult;

    try testing.expectEqual(source_id, source_span.source);
    try testing.expectEqual(@as(u32, 0), source_span.start);
    try testing.expectEqual(@as(u32, 1), source_span.end);
    try testing.expectEqualStrings("(", runtime.sourceExcerpt(source_span).?);

    const location = runtime.sourceLocation(source_span).?;
    try testing.expectEqual(@as(u32, 1), location.start.line);
    try testing.expectEqual(@as(u32, 1), location.start.column);
    try testing.expectEqual(@as(u32, 1), location.end.line);
    try testing.expectEqual(@as(u32, 2), location.end.column);

    // Source records own immutable copies rather than borrowing request bytes.
    input[0] = ')';
    const view = runtime.sourceView(source_id).?;
    try testing.expectEqualStrings("test://reader-span", view.name);
    try testing.expectEqualStrings("(", view.bytes);
}

test "evaluation conditions point to the exact source occurrence" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const program =
        "(do\n" ++
        "  1\n" ++
        "  missing-name)\n";
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = program,
            .source_name = "test://missing-name",
        },
    });
    const condition_value = switch (report.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    const source_span = condition_value.span orelse return error.TestUnexpectedResult;

    try testing.expectEqual(ConditionPhase.evaluate, condition_value.phase);
    try testing.expectEqual(ConditionCode.undefined_symbol, condition_value.code);
    try testing.expectEqualStrings("missing-name", runtime.sourceExcerpt(source_span).?);
    const location = runtime.sourceLocation(source_span).?;
    try testing.expectEqual(@as(u32, 3), location.start.line);
    try testing.expectEqual(@as(u32, 3), location.start.column);
    try testing.expectEqual(@as(u32, 3), location.end.line);
    try testing.expectEqual(@as(u32, 15), location.end.column);
}

test "expansion conditions retain nested surface provenance" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const program =
        "(loop [x 2]\n" ++
        "  (+ 1 (recur (- x 1))))";
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = program,
            .source_name = "test://recur-origin",
        },
    });
    const condition_value = switch (report.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    const source_span = condition_value.span orelse return error.TestUnexpectedResult;
    const recur_origin_id = condition_value.origin orelse return error.TestUnexpectedResult;

    try testing.expectEqual(ConditionPhase.expand, condition_value.phase);
    try testing.expectEqual(ConditionCode.invalid_syntax, condition_value.code);
    try testing.expectEqualStrings("(recur (- x 1))", runtime.sourceExcerpt(source_span).?);

    const recur_origin = runtime.expansionOrigin(recur_origin_id).?;
    try testing.expectEqualStrings("recur", runtime.symbolName(recur_origin.expander).?);
    try testing.expectEqual(source_span, recur_origin.call_site);

    const loop_origin = runtime.expansionOrigin(
        recur_origin.parent orelse return error.TestUnexpectedResult,
    ).?;
    try testing.expectEqualStrings("loop", runtime.symbolName(loop_origin.expander).?);
    try testing.expectEqualStrings(program, runtime.sourceExcerpt(loop_origin.call_site).?);
    try testing.expect(loop_origin.parent == null);
}

test "call and native observation events carry original source spans" {
    const testing = std.testing;
    const Journal = FixedEventJournal(32);
    var journal = Journal{};
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(EventMask.fromKinds(&.{
            .call_entered,
            .native_entered,
        })),
    });
    defer runtime.deinit();

    const program =
        "(do\n" ++
        "  (defn inc [x]\n" ++
        "    (+ x 1))\n" ++
        "  (inc 41))";
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = program,
            .source_name = "test://event-spans",
        },
    });
    try testing.expectEqual(@as(i64, 42), (try testReturned(report)).integer);

    var saw_call = false;
    var saw_native = false;
    for (0..journal.count()) |index| {
        const event = journal.at(index).?;
        const source_span = event.header.span orelse continue;
        switch (event.data) {
            .call_entered => {
                saw_call = true;
                try testing.expectEqualStrings("(inc 41)", runtime.sourceExcerpt(source_span).?);
            },
            .native_entered => |native| {
                if (std.mem.eql(u8, runtime.symbolName(native.name).?, "+")) {
                    saw_native = true;
                    try testing.expectEqualStrings("(+ x 1)", runtime.sourceExcerpt(source_span).?);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_call);
    try testing.expect(saw_native);
}

test "retained closures keep definition-source spans across collection" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const definition = try runtime.evaluate(.{
        .source = .{
            .bytes = "(defn add-one [x]\n" ++
                "  (+ x 1))",
            .source_name = "test://definition-v1",
        },
    });
    _ = try testReturned(definition);
    const definition_source = definition.source orelse return error.TestUnexpectedResult;

    _ = try runtime.collectGarbage(&.{});

    const invocation = try runtime.evaluate(.{
        .source = .{
            .bytes = "(add-one \"not-an-integer\")",
            .source_name = "test://invocation",
        },
    });
    const condition_value = switch (invocation.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    const source_span = condition_value.span orelse return error.TestUnexpectedResult;

    try testing.expect(invocation.source.? != definition_source);
    try testing.expectEqual(definition_source, source_span.source);
    try testing.expectEqualStrings("(+ x 1)", runtime.sourceExcerpt(source_span).?);
    try testing.expectEqualStrings(
        "test://definition-v1",
        runtime.sourceView(source_span.source).?.name,
    );
}

test "tail-call events retain recur and loop expansion origins" {
    const testing = std.testing;
    const Journal = FixedEventJournal(32);
    var journal = Journal{};
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(EventMask.fromKinds(&.{.tail_called})),
        .evaluation_gc_interval = 2,
    });
    defer runtime.deinit();

    const program =
        "(loop [n 3]\n" ++
        "  (if (= n 0)\n" ++
        "    n\n" ++
        "    (recur (- n 1))))";
    const report = try runtime.evaluate(.{
        .source = .{
            .bytes = program,
            .source_name = "test://tail-origin",
        },
    });
    try testing.expectEqual(@as(i64, 0), (try testReturned(report)).integer);

    var recur_events: usize = 0;
    for (0..journal.count()) |index| {
        const event = journal.at(index).?;
        try testing.expectEqual(EventKind.tail_called, event.kind());
        const source_span = event.header.span orelse return error.TestUnexpectedResult;
        const origin = runtime.expansionOrigin(
            event.header.origin orelse return error.TestUnexpectedResult,
        ).?;
        const expander_name = runtime.symbolName(origin.expander).?;
        if (std.mem.eql(u8, expander_name, "recur")) {
            recur_events += 1;
            try testing.expectEqualStrings("(recur (- n 1))", runtime.sourceExcerpt(source_span).?);
            const loop_origin = runtime.expansionOrigin(
                origin.parent orelse return error.TestUnexpectedResult,
            ).?;
            try testing.expectEqualStrings("loop", runtime.symbolName(loop_origin.expander).?);
        } else {
            // The initial call into loop's hidden recursive function is also a
            // proper tail transfer and correctly points at the loop surface form.
            try testing.expectEqualStrings("loop", expander_name);
            try testing.expectEqualStrings(program, runtime.sourceExcerpt(source_span).?);
        }
    }
    try testing.expectEqual(@as(usize, 3), recur_events);
}

test "native domain conditions are reports and share observation identity" {
    const testing = std.testing;
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Runtime, _: []const Value) HostError!NativeOutcome {
            return .{ .condition = .{
                .code = .native_condition,
                .message = "record does not exist",
            } };
        }
    };

    const Journal = FixedEventJournal(16);
    var journal = Journal{};
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(EventMask.fromKinds(&.{
            .native_entered,
            .condition_raised,
            .evaluation_finished,
        })),
    });
    defer runtime.deinit();
    try runtime.registerNative("lookup-record", null, Native.call);

    const report = try runtime.evaluate(.{
        .source = .{ .bytes = "(lookup-record)" },
    });
    const condition_value = switch (report.outcome) {
        .condition => |value| value,
        else => return error.TestExpectedCondition,
    };
    try testing.expectEqual(ConditionPhase.native, condition_value.phase);
    try testing.expectEqual(ConditionCode.native_condition, condition_value.code);
    try testing.expectEqualStrings("record does not exist", condition_value.message());

    var saw_condition = false;
    var saw_finished = false;
    for (0..journal.count()) |index| {
        const event = journal.at(index).?;
        switch (event.data) {
            .condition_raised => |raised| {
                saw_condition = true;
                try testing.expectEqual(condition_value.id, raised.condition);
                try testing.expectEqual(condition_value.code, raised.code);
                try testing.expectEqual(condition_value.phase, raised.phase);
                try testing.expectEqual(condition_value.span, event.header.span);
                try testing.expectEqual(condition_value.origin, event.header.origin);
            },
            .evaluation_finished => |finished| {
                saw_finished = true;
                try testing.expectEqual(observation.EvaluationStatus.condition, finished.status);
            },
            else => {},
        }
    }
    try testing.expect(saw_condition);
    try testing.expect(saw_finished);

    const recovery = try runtime.evaluate(.{ .source = .{ .bytes = "(+ 1 2)" } });
    try testing.expectEqual(@as(i64, 3), (try testReturned(recovery)).integer);
}

test "native host failure remains a Zig error and does not poison the runtime" {
    const testing = std.testing;
    const Native = struct {
        fn call(_: ?*anyopaque, _: *Runtime, _: []const Value) HostError!NativeOutcome {
            return error.NativeHostFailure;
        }
    };

    const Journal = FixedEventJournal(4);
    var journal = Journal{};
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(EventMask.fromKinds(&.{.evaluation_finished})),
    });
    defer runtime.deinit();
    try runtime.registerNative("broken-host", null, Native.call);

    try testing.expectError(
        error.NativeHostFailure,
        runtime.evaluate(.{ .source = .{ .bytes = "(broken-host)" } }),
    );
    try testing.expect(runtime.lastCondition() == null);
    try testing.expectEqual(@as(usize, 1), journal.count());
    try testing.expectEqual(
        observation.EvaluationStatus.host_failure,
        journal.at(0).?.data.evaluation_finished.status,
    );

    journal.clear();
    const recovery = try runtime.evaluate(.{ .source = .{ .bytes = "(+ 40 2)" } });
    try testing.expectEqual(@as(i64, 42), (try testReturned(recovery)).integer);
}

test "allocator failure remains a host error and the runtime is reusable" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var runtime = try Runtime.init(failing.allocator());
    defer runtime.deinit();

    // Fail the next allocation made by reading/evaluating this request.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        runtime.evaluate(.{ .source = .{ .bytes = "(list 1 2 3 4)" } }),
    );
    try testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    const recovery = try runtime.evaluate(.{ .source = .{ .bytes = "(+ 20 22)" } });
    try testing.expectEqual(@as(i64, 42), (try testReturned(recovery)).integer);

    // Once allocation is available again, a full collection can reclaim any
    // temporary objects left behind by the failed transaction.
    _ = try runtime.collectGarbage(&.{});
}

test "observation journal records the semantic evaluation path" {
    const testing = std.testing;
    const Journal = FixedEventJournal(32);
    var journal = Journal{};
    const mask = EventMask.fromKinds(&.{
        .evaluation_started,
        .evaluation_finished,
        .definition_committed,
        .call_entered,
        .call_returned,
        .native_entered,
        .native_returned,
    });

    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(mask),
        .evaluation_gc_interval = 0,
    });
    defer runtime.deinit();

    const result = try testEval(
        &runtime,
        "(begin (define (inc x) (+ x 1)) (inc 41))",
    );
    try testing.expectEqual(@as(i64, 42), result.integer);
    const source_id: SourceId = @enumFromInt(runtime.sourceCount());

    const expected = [_]EventKind{
        .evaluation_started,
        .definition_committed,
        .call_entered,
        .native_entered,
        .native_returned,
        .call_returned,
        .evaluation_finished,
    };
    try testing.expectEqual(expected.len, journal.count());
    var located_events: usize = 0;
    for (expected, 0..) |kind, index| {
        const event = journal.at(index).?;
        try testing.expectEqual(kind, event.kind());
        try testing.expectEqual(@as(u64, index + 1), event.header.id.ordinal);
        if (index == 0) {
            try testing.expect(event.header.cause == null);
        } else {
            try testing.expect(event.header.cause.?.eql(journal.at(index - 1).?.header.id));
        }
        try testing.expect(event.header.evaluation != .none);
        if (event.header.span) |source_span| {
            located_events += 1;
            try testing.expectEqual(source_id, source_span.source);
            const excerpt = runtime.sourceExcerpt(source_span) orelse return error.TestUnexpectedResult;
            try testing.expect(excerpt.len != 0);
        }
    }
    try testing.expect(located_events >= 4);

    const root_context = journal.at(0).?.header.context;
    try testing.expectEqual(
        source_id,
        journal.at(0).?.data.evaluation_started.source.?,
    );
    const definition = journal.at(1).?;
    try testing.expectEqual(root_context, definition.header.context);
    try testing.expectEqualStrings(
        "inc",
        runtime.symbolName(definition.data.definition_committed.symbol).?,
    );
    try testing.expect(!definition.data.definition_committed.replaced);

    const call = journal.at(2).?;
    try testing.expectEqual(root_context, call.data.call_entered.parent);
    const call_context = call.header.context;
    try testing.expect(call_context != .none);

    const native_enter = journal.at(3).?;
    try testing.expectEqual(call_context, native_enter.data.native_entered.parent);
    try testing.expectEqualStrings(
        "+",
        runtime.symbolName(native_enter.data.native_entered.name).?,
    );
    try testing.expectEqual(native_enter.header.context, journal.at(4).?.header.context);
    try testing.expectEqual(call_context, journal.at(5).?.header.context);

    const finished = journal.at(6).?.data.evaluation_finished;
    try testing.expectEqual(observation.EvaluationStatus.returned, finished.status);
    try testing.expectEqual(observation.ValueKind.integer, finished.result.?);
}

test "tail-call observation replaces logical calls instead of growing a stack" {
    const testing = std.testing;
    const State = struct {
        active_calls: usize = 0,
        maximum_active_calls: usize = 0,
        entered: usize = 0,
        transferred: usize = 0,
        returned: usize = 0,

        fn observe(context: ?*anyopaque, event: Event) ObservationAction {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event.data) {
                .call_entered => {
                    self.entered += 1;
                    self.active_calls += 1;
                    self.maximum_active_calls = @max(
                        self.maximum_active_calls,
                        self.active_calls,
                    );
                },
                .tail_called => {
                    self.transferred += 1;
                    std.debug.assert(self.active_calls > 0);
                    self.active_calls -= 1;
                },
                .call_returned => {
                    self.returned += 1;
                    std.debug.assert(self.active_calls > 0);
                    self.active_calls -= 1;
                },
                else => {},
            }
            return .continue_;
        }
    };

    var state = State{};
    const observer = Observer{
        .context = &state,
        .mask = EventMask.fromKinds(&.{
            .call_entered,
            .tail_called,
            .call_returned,
        }),
        .on_event = State.observe,
    };
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = observer,
        .max_eval_depth = 64,
        .evaluation_gc_interval = 64,
    });
    defer runtime.deinit();

    const result = try testEval(
        &runtime,
        "(begin " ++
            "(define (count n) " ++
            "  (if (= n 0) n (count (- n 1)))) " ++
            "(count 10000))",
    );
    try testing.expectEqual(@as(i64, 0), result.integer);
    try testing.expectEqual(@as(usize, 10001), state.entered);
    try testing.expectEqual(@as(usize, 10000), state.transferred);
    try testing.expectEqual(@as(usize, 1), state.returned);
    try testing.expectEqual(@as(usize, 1), state.maximum_active_calls);
    try testing.expectEqual(@as(usize, 0), state.active_calls);
}

test "native callbacks can correlate host work with evaluation context" {
    const testing = std.testing;
    const Journal = FixedEventJournal(8);
    var journal = Journal{};
    const State = struct {
        evaluation: EvaluationId = .none,
        context: ContextId = .none,
        cause: ?EventId = null,

        fn call(
            pointer: ?*anyopaque,
            runtime: *Runtime,
            args: []const Value,
        ) HostError!NativeOutcome {
            if (args.len != 0) return .{ .condition = .{
                .code = .arity_mismatch,
                .message = "correlate expects no arguments",
            } };
            const self: *@This() = @ptrCast(@alignCast(pointer.?));
            self.evaluation = runtime.observationEvaluation();
            self.context = runtime.observationContext();
            self.cause = runtime.observationEvent();
            return .{ .returned = .{ .integer = 42 } };
        }
    };

    var state = State{};
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(EventMask.fromKinds(&.{
            .native_entered,
            .native_returned,
        })),
    });
    defer runtime.deinit();
    try runtime.registerNative("correlate", &state, State.call);

    const result = try testEval(&runtime, "(correlate)");
    try testing.expectEqual(@as(i64, 42), result.integer);
    try testing.expectEqual(@as(usize, 2), journal.count());
    const entered = journal.at(0).?;
    try testing.expectEqual(entered.header.evaluation, state.evaluation);
    try testing.expectEqual(entered.header.context, state.context);
    try testing.expect(state.cause.?.eql(entered.header.id));
}

test "conditions and failed evaluations are structured observation events" {
    const testing = std.testing;
    const Journal = FixedEventJournal(8);
    var journal = Journal{};
    const mask = EventMask.fromKinds(&.{
        .evaluation_started,
        .condition_raised,
        .evaluation_finished,
    });
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(mask),
    });
    defer runtime.deinit();

    const condition_value = try testCondition(&runtime, "missing");
    try testing.expectEqual(ConditionCode.undefined_symbol, condition_value.code);
    try testing.expectEqual(ConditionPhase.evaluate, condition_value.phase);
    try testing.expectEqualStrings("undefined symbol: missing", condition_value.message());
    try testing.expectEqual(@as(usize, 3), journal.count());
    try testing.expectEqual(EventKind.evaluation_started, journal.at(0).?.kind());
    try testing.expectEqual(EventKind.condition_raised, journal.at(1).?.kind());
    const raised = journal.at(1).?.data.condition_raised;
    try testing.expectEqual(condition_value.id, raised.condition);
    try testing.expectEqual(condition_value.code, raised.code);
    try testing.expectEqual(condition_value.phase, raised.phase);
    try testing.expectEqual(condition_value.span, journal.at(1).?.header.span);
    try testing.expectEqual(condition_value.origin, journal.at(1).?.header.origin);
    try testing.expectEqual(EventKind.evaluation_finished, journal.at(2).?.kind());
    try testing.expectEqual(
        observation.EvaluationStatus.condition,
        journal.at(2).?.data.evaluation_finished.status,
    );
}

test "GC observation reports coherent before and after counts" {
    const testing = std.testing;
    const Journal = FixedEventJournal(8);
    var journal = Journal{};
    const mask = EventMask.fromKinds(&.{ .gc_started, .gc_finished });
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(mask),
    });
    defer runtime.deinit();

    _ = try testEval(&runtime, "(list 1 2 3 4)");
    journal.clear();
    const reclaimed = try runtime.collectGarbage(&.{});
    try testing.expect(reclaimed > 0);
    try testing.expectEqual(@as(usize, 2), journal.count());

    const started = journal.at(0).?.data.gc_started;
    const finished = journal.at(1).?.data.gc_finished;
    try testing.expectEqual(observation.GcKind.full, started.kind);
    try testing.expectEqual(observation.GcKind.full, finished.kind);
    try testing.expectEqual(started.heap_live_before, finished.heap_live_before);
    try testing.expectEqual(@as(u32, @intCast(reclaimed)), finished.reclaimed);
    try testing.expectEqual(
        started.heap_live_before - finished.reclaimed,
        finished.heap_live_after,
    );
}

test "per-object observation is opt-in and generationally correlated" {
    const testing = std.testing;
    const Journal = FixedEventJournal(8);
    var journal = Journal{};
    const mask = EventMask.fromKinds(&.{
        .object_allocated,
        .object_reclaimed,
    });
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(mask),
    });
    defer runtime.deinit();

    // Ignore the global environment allocation performed by Runtime.init.
    journal.clear();
    _ = try testEval(&runtime, "\"hello\"");
    var allocated: ?observation.ObjectEvent = null;
    for (0..journal.count()) |index| {
        switch (journal.at(index).?.data) {
            .object_allocated => |event| {
                if (event.kind == .string) allocated = event;
            },
            else => {},
        }
    }
    try testing.expect(allocated != null);

    journal.clear();
    _ = try runtime.collectGarbage(&.{});
    var reclaimed: ?observation.ObjectEvent = null;
    for (0..journal.count()) |index| {
        switch (journal.at(index).?.data) {
            .object_reclaimed => |event| {
                if (event.kind == .string) reclaimed = event;
            },
            else => {},
        }
    }
    try testing.expect(reclaimed != null);
    try testing.expectEqual(allocated.?.object, reclaimed.?.object);
}

test "invalid expansion commits no definition event" {
    const testing = std.testing;
    const Journal = FixedEventJournal(16);
    var journal = Journal{};
    const mask = EventMask.fromKinds(&.{
        .definition_committed,
        .condition_raised,
        .evaluation_finished,
    });
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observer(mask),
    });
    defer runtime.deinit();

    const condition_value = try testCondition(
        &runtime,
        "(define committed 99) " ++
            "(loop [x 2] (+ 1 (recur (- x 1))))",
    );
    try testing.expectEqual(ConditionCode.invalid_syntax, condition_value.code);
    try testing.expectEqual(ConditionPhase.expand, condition_value.phase);
    try testing.expect(runtime.getGlobal("committed") == null);
    for (0..journal.count()) |index| {
        try testing.expect(journal.at(index).?.kind() != .definition_committed);
    }
}

test "observer actions cancel at semantic safe points" {
    const testing = std.testing;
    const Journal = FixedEventJournal(4);
    var journal = Journal{};
    journal.setAction(.cancel);
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .observer = journal.observerAll(),
    });
    defer runtime.deinit();

    // Ignore initialization events and cancel the next evaluation start.
    journal.clear();
    const report = try runtime.evaluate(.{ .source = .{ .bytes = "(+ 1 2)" } });
    try testing.expect(report.outcome == .cancelled);
    try testing.expectEqual(@as(usize, 2), journal.count());
    try testing.expectEqual(EventKind.evaluation_started, journal.at(0).?.kind());
    try testing.expectEqual(EventKind.evaluation_finished, journal.at(1).?.kind());
    try testing.expectEqual(
        observation.EvaluationStatus.cancelled,
        journal.at(1).?.data.evaluation_finished.status,
    );
}

test "observer configuration is immutable during evaluation" {
    const testing = std.testing;
    const Native = struct {
        fn call(_: ?*anyopaque, runtime: *Runtime, args: []const Value) HostError!NativeOutcome {
            if (args.len != 0) return .{ .condition = .{
                .code = .arity_mismatch,
                .message = "change-observer expects no arguments",
            } };
            try runtime.setObserver(null);
            return .{ .returned = .nil };
        }
    };

    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.registerNative("change-observer", null, Native.call);
    try testing.expectError(
        error.RuntimeBusy,
        runtime.evaluate(.{ .source = .{ .bytes = "(change-observer)" } }),
    );
}

test "disabled observation emits no callbacks and preserves evaluation" {
    const testing = std.testing;
    const Probe = struct {
        calls: usize = 0,

        fn observe(context: ?*anyopaque, _: Event) ObservationAction {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .continue_;
        }
    };

    var probe = Probe{};
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.setObserver(null);

    const result = try testEval(&runtime, "(+ 20 22)");
    try testing.expectEqual(@as(i64, 42), result.integer);
    try testing.expectEqual(@as(usize, 0), probe.calls);

    // Installing the same no-allocation callback after the fact begins
    // observation without changing language behavior.
    try runtime.setObserver(.{
        .context = &probe,
        .mask = EventMask.standard(),
        .on_event = Probe.observe,
    });
    const second = try testEval(&runtime, "(+ 20 22)");
    try testing.expectEqual(@as(i64, 42), second.integer);
    try testing.expect(probe.calls > 0);
}

test "script shebang is ignored" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const result = try testEval(&runtime, "#!/usr/bin/env lizp\n(+ 1 2)");
    try testing.expectEqual(@as(i64, 3), result.integer);
}

test "arithmetic, definitions, closures, and recursion" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const result = try testEval(&runtime,
        \\(begin
        \\  (define (fact n)
        \\    (if (= n 0) 1 (* n (fact (- n 1)))))
        \\  (define make-adder (lambda (x) (lambda (y) (+ x y))))
        \\  (define add7 (make-adder 7))
        \\  (+ (fact 6) (add7 15)))
    );
    try testing.expectEqual(@as(i64, 742), result.integer);
}

test "tail recursion is stack safe and evaluation frames are nursery collected" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
        .evaluation_gc_interval = 32,
    });
    defer runtime.deinit();

    const before = runtime.heapLiveCount();
    const result = try testEval(&runtime,
        \\(begin
        \\  (define (count n acc)
        \\    (if (= n 0)
        \\      acc
        \\      (count (- n 1) (+ acc 1))))
        \\  (count 20000 0))
    );
    try testing.expectEqual(@as(i64, 20000), result.integer);
    try testing.expect(runtime.nurseryCollectionCount() > 100);
    try testing.expect(runtime.heapLiveCount() < before + 256);
}

test "mutual tail recursion does not consume evaluation depth" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
        .evaluation_gc_interval = 64,
    });
    defer runtime.deinit();

    const result = try testEval(&runtime,
        \\(begin
        \\  (define (even? n) (if (= n 0) true (odd? (- n 1))))
        \\  (define (odd? n) (if (= n 0) false (even? (- n 1))))
        \\  (even? 20001))
    );
    try testing.expectEqual(false, result.boolean);
}

test "quote, dotted lists, let, and variadic parameters" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const dotted = try testEval(&runtime, "'(1 2 . 3)");
    const rendered = try runtime.formatAlloc(dotted);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("(1 2 . 3)", rendered);

    const result = try testEval(
        &runtime,
        "(let ((x 10) (y 20)) ((lambda (head . rest) (+ head (length rest))) x y 30))",
    );
    try testing.expectEqual(@as(i64, 12), result.integer);
}

test "vectors are evaluated values and support Clojure-style commas" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const vector = try testEval(&runtime, "[1, (+ 1 1), 3]");
    const items = runtime.asVector(vector).?;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i64, 2), items[1].integer);
    try testing.expectEqual(@as(i64, 3), (try testEval(&runtime, "(count [10 20 30])")).integer);
    try testing.expectEqual(@as(i64, 20), (try testEval(&runtime, "(nth [10 20 30] 1)")).integer);

    const quoted = try testEval(&runtime, "'[x (+ 1 2)]");
    const rendered = try runtime.formatAlloc(quoted);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("[x (+ 1 2)]", rendered);
}

test "Clojure-shaped defn do let loop and recur lower into the core" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
        .evaluation_gc_interval = 32,
    });
    defer runtime.deinit();

    const result = try testEval(&runtime,
        \\(do
        \\  (defn sum-to [n]
        \\    (loop [i n, total 0]
        \\      (if (= i 0)
        \\        total
        \\        (recur (- i 1) (+ total i)))))
        \\  (let [base 40
        \\        next (+ base 1)]
        \\    (+ next (sum-to 100))))
    );
    try testing.expectEqual(@as(i64, 5091), result.integer);
}

test "named fn and defn recur are tail safe" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 24,
        .evaluation_gc_interval = 64,
    });
    defer runtime.deinit();

    const result = try testEval(&runtime,
        \\(do
        \\  (def countdown
        \\    (fn countdown [n]
        \\      (if (= n 0) 40 (recur (- n 1)))))
        \\  (defn add-two-after [n]
        \\    (if (= n 0) 2 (recur (- n 1))))
        \\  (+ (countdown 10000) (add-two-after 10000)))
    );
    try testing.expectEqual(@as(i64, 42), result.integer);
}

test "Clojure-style ampersand parameters lower to Lizp rest parameters" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const result = try testEval(
        &runtime,
        "(do (defn rest-count [head & rest] (count rest)) (rest-count 1 2 3 4))",
    );
    try testing.expectEqual(@as(i64, 3), result.integer);
}

test "recur is validated before any form is evaluated" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const non_tail = try testCondition(&runtime,
        \\(def committed 99)
        \\(loop [x 2]
        \\  (+ 1 (recur (- x 1))))
    );
    try testing.expectEqual(ConditionCode.invalid_syntax, non_tail.code);
    try testing.expectEqual(ConditionPhase.expand, non_tail.phase);
    try testing.expect(runtime.getGlobal("committed") == null);
    try testing.expectEqualStrings("recur must appear in tail position", non_tail.message());

    const wrong_arity = try testCondition(
        &runtime,
        "(loop [x 1, y 2] (recur 0))",
    );
    try testing.expectEqual(ConditionCode.arity_mismatch, wrong_arity.code);
    try testing.expectEqual(ConditionPhase.expand, wrong_arity.phase);
}

test "non-tail recursion still obeys the evaluation-depth limit" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
    });
    defer runtime.deinit();

    const condition_value = try testCondition(&runtime,
        \\(do
        \\  (defn sum [n]
        \\    (if (= n 0) 0 (+ n (sum (- n 1)))))
        \\  (sum 1000))
    );
    try testing.expectEqual(ConditionCode.eval_depth_exceeded, condition_value.code);
    try testing.expectEqual(ConditionPhase.evaluate, condition_value.phase);
}

test "nested loop evaluation roots caller temporaries and captured results" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
        .evaluation_gc_interval = 32,
    });
    defer runtime.deinit();

    const before = runtime.heapLiveCount();
    const result = try testEval(&runtime,
        \\(def held
        \\  (loop [i 0]
        \\    (if (= i 10000)
        \\      (fn [] i)
        \\      (recur (+ i 1)))))
        \\(held)
    );
    try testing.expectEqual(@as(i64, 10000), result.integer);
    try testing.expect(runtime.nurseryCollectionCount() > 100);
    try testing.expect(runtime.heapLiveCount() < before + 512);
}

test "repeated source evaluation reclaims parsed and expanded syntax trees" {
    const testing = std.testing;
    var runtime = try Runtime.initWithOptions(testing.allocator, .{
        .max_eval_depth = 32,
        .evaluation_gc_interval = 16,
    });
    defer runtime.deinit();

    const baseline = runtime.heapLiveCount();
    for (0..40) |_| {
        const result = try testEval(
            &runtime,
            "(loop [i 2000, total 0] " ++
                "(if (= i 0) total (recur (- i 1) (+ total i))))",
        );
        try testing.expectEqual(@as(i64, 2_001_000), result.integer);
    }

    // The global environment and core state remain, but per-call source ASTs
    // and loop frames do not accumulate across evaluations.
    try testing.expect(runtime.heapLiveCount() <= baseline + 8);
}

test "while supports imperative host-style scripting loops" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const result = try testEval(&runtime,
        \\(let ((i 0) (sum 0))
        \\  (while (< i 10)
        \\    (set! sum (+ sum i))
        \\    (set! i (+ i 1)))
        \\  sum)
    );
    try testing.expectEqual(@as(i64, 45), result.integer);
}

test "incomplete multi-form input has no evaluation side effects" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const incomplete = try testCondition(
        &runtime,
        "(define committed 99) (+ committed",
    );
    try testing.expectEqual(ConditionCode.unexpected_end_of_input, incomplete.code);
    try testing.expectEqual(ConditionPhase.read, incomplete.phase);

    const missing = try testCondition(&runtime, "committed");
    try testing.expectEqual(ConditionCode.undefined_symbol, missing.code);
}

test "native Zig functions can carry context" {
    const testing = std.testing;
    const Context = struct { increment: i64 };
    const Native = struct {
        fn call(context: ?*anyopaque, runtime: *Runtime, args: []const Value) HostError!NativeOutcome {
            if (args.len != 1) return .{ .condition = .{
                .code = .arity_mismatch,
                .message = "add-context expects one argument",
            } };
            const input = runtime.asInteger(args[0]) orelse return .{ .condition = .{
                .code = .type_mismatch,
                .message = "add-context expects an integer",
            } };
            const typed: *Context = @ptrCast(@alignCast(context.?));
            return .{ .returned = .{ .integer = input + typed.increment } };
        }
    };

    var context = Context{ .increment = 9 };
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.registerNative("add-context", &context, Native.call);
    const result = try testEval(&runtime, "(add-context 33)");
    try testing.expectEqual(@as(i64, 42), result.integer);
}

test "Zig can call Lisp closures and inspect returned lists" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    _ = try testEval(&runtime, "(define (describe x) (list (* x 3) \"ok\"))");
    const function = runtime.getGlobal("describe").?;
    const result = try testCall(&runtime, function, &.{.{ .integer = 14 }});
    const items = try runtime.copyList(testing.allocator, result);
    defer testing.allocator.free(items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(i64, 42), runtime.asInteger(items[0]).?);
    try testing.expectEqualStrings("ok", runtime.asString(items[1]).?);
}

test "collector keeps roots and reclaims unreachable objects" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const temporary = try testEval(&runtime, "(list 1 2 3 4)");
    const before = runtime.heapLiveCount();
    _ = try runtime.collectGarbage(&.{temporary});
    try testing.expect(runtime.isAlive(temporary));
    const collected = try runtime.collectGarbage(&.{});
    try testing.expect(collected > 0);
    try testing.expect(!runtime.isAlive(temporary));
    try testing.expect(runtime.heapLiveCount() < before);
}

test "evaluation nursery reclaims unreachable environment-closure cycles" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const before = runtime.heapLiveCount();
    _ = try testEval(
        &runtime,
        "((lambda () (define (local-loop n) (if (= n 0) nil (local-loop (- n 1)))) nil))",
    );
    try testing.expectEqual(before, runtime.heapLiveCount());
}

test "collection is rejected while a native callback is active" {
    const testing = std.testing;
    const Native = struct {
        fn call(_: ?*anyopaque, runtime: *Runtime, args: []const Value) anyerror!Value {
            try requireArity(runtime, args, 0, "unsafe-gc");
            _ = try runtime.collectGarbage(&.{});
            return .nil;
        }
    };

    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();
    try runtime.registerCoreNative("unsafe-gc", Native.call);

    const condition_value = try testCondition(&runtime, "(unsafe-gc)");
    try testing.expectEqual(ConditionCode.collection_during_evaluation, condition_value.code);
    try testing.expectEqualStrings(
        "garbage collection is only safe between evaluations",
        condition_value.message(),
    );
}

test "collector preserves closure code and captured environment" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    _ = try testEval(
        &runtime,
        "(begin (define saved ((lambda (x) (lambda (y) (+ x y))) 40)) nil)",
    );
    _ = try runtime.collectGarbage(&.{});
    const result = try testEval(&runtime, "(saved 2)");
    try testing.expectEqual(@as(i64, 42), result.integer);
}

test "capability allowlists are detached persistent snapshots" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    try runtime.defineGlobal("public-value", .{ .integer = 41 });
    try runtime.defineGlobal("secret-value", .{ .integer = 9001 });

    const capability_environment = try runtime.createCapabilityEnvironment(.{
        .allow = &.{ "+", "public-value" },
    });

    const answer = try testEvalIn(
        &runtime,
        "(+ public-value 1)",
        capability_environment,
    );
    try testing.expectEqual(@as(i64, 42), answer.integer);
    try testing.expectEqual(
        ConditionCode.undefined_symbol,
        (try testConditionIn(&runtime, "secret-value", capability_environment)).code,
    );

    // Definitions persist inside the isolated environment, but do not leak to
    // globals. Likewise, set! can only update the detached snapshot.
    _ = try testEvalIn(&runtime, "(define local-value 7)", capability_environment);
    try testing.expectEqual(
        @as(i64, 7),
        (try testEvalIn(&runtime, "local-value", capability_environment)).integer,
    );
    try testing.expect(runtime.getGlobal("local-value") == null);

    _ = try testEvalIn(&runtime, "(set! public-value 5)", capability_environment);
    try testing.expectEqual(@as(i64, 5), (try runtime.getIn(capability_environment, "public-value")).?.integer);
    try testing.expectEqual(@as(i64, 41), runtime.getGlobal("public-value").?.integer);

    // It is a snapshot: capabilities registered later do not appear.
    try runtime.defineGlobal("late-capability", .{ .integer = 123 });
    try testing.expectEqual(
        ConditionCode.undefined_symbol,
        (try testConditionIn(&runtime, "late-capability", capability_environment)).code,
    );
}

test "denylist snapshots and explicit revocation remove names" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    try runtime.defineGlobal("public-value", .{ .integer = 41 });
    try runtime.defineGlobal("secret-value", .{ .integer = 99 });

    const capability_environment = try runtime.createCapabilityEnvironment(.{
        .allow = null,
        .deny = &.{"secret-value"},
    });
    try testing.expectEqual(
        @as(i64, 42),
        (try testEvalIn(&runtime, "(+ public-value 1)", capability_environment)).integer,
    );
    try testing.expectEqual(
        ConditionCode.undefined_symbol,
        (try testConditionIn(&runtime, "secret-value", capability_environment)).code,
    );

    try testing.expect(try runtime.removeFrom(capability_environment, "+"));
    try testing.expectEqual(
        ConditionCode.undefined_symbol,
        (try testConditionIn(&runtime, "(+ 1 2)", capability_environment)).code,
    );
}

test "granted closures retain their trusted implementation authority" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    _ = try testEval(
        &runtime,
        "(begin " ++
            "(define hidden 40) " ++
            "(define (privileged x) (+ hidden x)) " ++
            "(define privileged-bundle (list privileged)) " ++
            "nil)",
    );

    // The closure itself is the granted capability. Its implementation may
    // reach `hidden` and `+` through its original lexical environment even
    // though neither name is directly visible in the detached snapshot.
    const trusted_environment = try runtime.createCapabilityEnvironment(.{
        .allow = &.{"privileged"},
    });
    const answer = try testEvalIn(&runtime, "(privileged 2)", trusted_environment);
    try testing.expectEqual(@as(i64, 42), answer.integer);

    // A host may optionally reject captured environments as a structural
    // auditing rule. This is deliberately opt-in and does not constrain
    // native callbacks.
    try testing.expectError(
        error.UnsafeCapabilityGrant,
        runtime.createCapabilityEnvironment(.{
            .allow = &.{"privileged"},
            .grant_policy = .no_captured_authority,
        }),
    );
    try testing.expectError(
        error.UnsafeCapabilityGrant,
        runtime.createCapabilityEnvironment(.{
            .allow = &.{"privileged-bundle"},
            .grant_policy = .no_captured_authority,
        }),
    );
}

test "language policies attenuate special forms independently of bindings" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    // Rebinding a familiar global name must not affect the original pure core
    // procedures granted by this API.
    try runtime.defineGlobal("+", .{ .integer = 1234 });
    const environment = try runtime.createEnvironment(.expression_only);
    try runtime.grantCoreProcedures(environment);

    const answer = try testEvalIn(
        &runtime,
        "(let ((x 40)) (+ x 2))",
        environment,
    );
    try testing.expectEqual(@as(i64, 42), answer.integer);

    try testing.expectEqual(
        ConditionCode.forbidden_special_form,
        (try testConditionIn(&runtime, "(define x 1)", environment)).code,
    );
    try testing.expectEqual(
        ConditionCode.forbidden_special_form,
        (try testConditionIn(&runtime, "(let ((x 1)) (set! x 2))", environment)).code,
    );
    try testing.expectEqual(
        ConditionCode.forbidden_special_form,
        (try testConditionIn(&runtime, "(while #f 1)", environment)).code,
    );
}

test "capability environments can be explicit garbage-collection roots" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const environment = try runtime.createEnvironment(.{});
    try runtime.grantCoreProcedures(environment);
    _ = try testEvalIn(
        &runtime,
        "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))",
        environment,
    );

    _ = try runtime.collectGarbageWithRoots(.{
        .environments = &.{environment},
    });
    const answer = try testEvalIn(&runtime, "(fact 7)", environment);
    try testing.expectEqual(@as(i64, 5040), answer.integer);

    _ = try runtime.collectGarbageWithRoots(.{});
    try testing.expectError(error.StaleObject, runtime.getIn(environment, "fact"));
}

test "closures defined inside an attenuated environment recurse locally" {
    const testing = std.testing;
    var runtime = try Runtime.init(testing.allocator);
    defer runtime.deinit();

    const environment = try runtime.createCapabilityEnvironment(.{
        .allow = &.{ "=", "-", "*" },
        .language = .attenuated,
    });
    const result = try testEvalIn(&runtime,
        \\(begin
        \\  (define (fact n)
        \\    (if (= n 0) 1 (* n (fact (- n 1)))))
        \\  (fact 8))
    , environment);
    try testing.expectEqual(@as(i64, 40320), result.integer);
    try testing.expect(runtime.getGlobal("fact") == null);
}
