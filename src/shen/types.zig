const std = @import("std");

// ============================================================
// Shen Kλ Kernel — Value Types
//
// Tagged union for all Kλ values.
// Two-generation allocator: nursery (reset per top-level eval)
// and tenured (long-lived globals, defuns, interned strings).
// Numbers are dual i64/f64 with promotion on mixed ops.
// Symbols are interned for O(1) comparison.
// ============================================================

pub const Value = union(enum) {
    nil, // empty list
    boolean: bool,
    integer: i64,
    float: f64,
    symbol: u32, // index into InternPool
    string: []const u8,
    cons: *Cell,
    vector: *Vector,
    closure: *Closure,
    native_fn: *const anyopaque, // actually *const NativeFn, cast at call site
    stream: *Stream,
    err: *ShenError,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn isNumber(self: Value) bool {
        return self == .integer or self == .float;
    }

    pub fn toFloat(self: Value) f64 {
        return switch (self) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => unreachable,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);

        // Cross-type number equality: 1 == 1.0
        if (a.isNumber() and b.isNumber()) {
            return a.toFloat() == b.toFloat();
        }

        if (tag_a != tag_b) return false;

        return switch (a) {
            .nil => true,
            .boolean => |v| v == b.boolean,
            .integer => |v| v == b.integer,
            .float => |v| v == b.float,
            .symbol => |v| v == b.symbol,
            .string => |v| std.mem.eql(u8, v, b.string),
            .cons => |c| c.car.eql(b.cons.car) and c.cdr.eql(b.cons.cdr),
            .vector => |v| v == b.vector, // identity
            .closure => |v| v == b.closure, // identity
            .native_fn => |v| v == b.native_fn, // identity
            .stream => |v| v == b.stream, // identity
            .err => |v| v == b.err, // identity
        };
    }
};

pub const Cell = struct {
    car: Value,
    cdr: Value,
};

pub const Vector = struct {
    data: []Value, // mutable, fixed-size
};

pub const Closure = struct {
    params: []const u32, // interned param symbols
    body: Value, // s-expression
    env: *Env, // captured lexical scope
    name: ?u32, // for defun'd functions (for TCO)
    arity: u16, // total params expected
    applied: []const Value, // partial application args so far
};

// NativeFn signature. Stored as *const anyopaque in Value to break
// the Value -> NativeFn -> Value dependency cycle.
pub const NativeFnSig = *const fn (args: []const Value, vm_ptr: *anyopaque) anyerror!Value;

pub fn callNative(func_ptr: *const anyopaque, args: []const Value, vm_ptr: *anyopaque) anyerror!Value {
    const f: NativeFnSig = @ptrCast(func_ptr);
    return f(args, vm_ptr);
}

pub const Stream = struct {
    file: std.fs.File,
    mode: enum { in, out },
};

pub const ShenError = struct {
    message: []const u8,
};

// --- Environment ---

pub const Binding = struct {
    sym: u32,
    val: Value,
};

pub const Env = struct {
    bindings: std.ArrayListUnmanaged(Binding),
    parent: ?*Env,

    pub fn init(parent: ?*Env) Env {
        return .{
            .bindings = .{},
            .parent = parent,
        };
    }

    pub fn lookup(self: *const Env, sym: u32) ?Value {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bindings.items[i].sym == sym) {
                return self.bindings.items[i].val;
            }
        }
        if (self.parent) |p| return p.lookup(sym);
        return null;
    }

    pub fn bind(self: *Env, allocator: std.mem.Allocator, sym: u32, val: Value) !void {
        try self.bindings.append(allocator, .{ .sym = sym, .val = val });
    }
};

// --- Symbol Interning ---

pub const InternPool = struct {
    strings: std.ArrayListUnmanaged([]const u8),
    lookup_map: std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InternPool {
        return .{
            .strings = .{},
            .lookup_map = .{},
            .allocator = allocator,
        };
    }

    pub fn intern(self: *InternPool, name: []const u8) !u32 {
        if (self.lookup_map.get(name)) |idx| return idx;

        const owned = try self.allocator.dupe(u8, name);
        const idx: u32 = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, owned);
        try self.lookup_map.put(self.allocator, owned, idx);
        return idx;
    }

    pub fn getName(self: *const InternPool, idx: u32) []const u8 {
        return self.strings.items[idx];
    }

    pub fn deinit(self: *InternPool) void {
        for (self.strings.items) |s| self.allocator.free(s);
        self.strings.deinit(self.allocator);
        self.lookup_map.deinit(self.allocator);
    }
};

// --- VM State ---
// Central state passed to all primitives and the eval loop.

pub const Vm = struct {
    allocator: std.mem.Allocator, // tenured — long-lived allocations
    nursery_arena: *std.heap.ArenaAllocator, // heap-allocated to avoid self-ref move
    nursery: std.mem.Allocator, // fast bump allocator for temporaries
    pool: InternPool,

    // Global symbol table (set/value)
    globals: std.AutoHashMapUnmanaged(u32, Value),

    // Global function table (defun)
    functions: std.AutoHashMapUnmanaged(u32, Value),

    // Pre-interned symbols for special forms
    sym_defun: u32,
    sym_lambda: u32,
    sym_let: u32,
    sym_freeze: u32,
    sym_if: u32,
    sym_and: u32,
    sym_or: u32,
    sym_cond: u32,
    sym_trap_error: u32,
    sym_true: u32,
    sym_false: u32,

    // Pre-interned symbols for hot primitives (inlined in eval)
    sym_cons: u32,
    sym_hd: u32,
    sym_tl: u32,
    sym_consp: u32,
    sym_eq: u32,
    sym_add: u32,
    sym_sub: u32,
    sym_mul: u32,
    sym_gt: u32,
    sym_lt: u32,
    sym_numberp: u32,
    sym_stringp: u32,
    sym_symbolp: u32,
    sym_not: u32,
    sym_value: u32,
    sym_set: u32,
    sym_do: u32,

    gensym_counter: u64 = 0,
    last_error: []const u8 = "error",

    // Track all vectors for nursery promotion at reset time
    vectors: std.ArrayListUnmanaged(*Vector) = .{},

    pub fn init(allocator: std.mem.Allocator) !Vm {
        var pool = InternPool.init(allocator);
        const s_defun = try pool.intern("defun");
        const s_lambda = try pool.intern("lambda");
        const s_let = try pool.intern("let");
        const s_freeze = try pool.intern("freeze");
        const s_if = try pool.intern("if");
        const s_and = try pool.intern("and");
        const s_or = try pool.intern("or");
        const s_cond = try pool.intern("cond");
        const s_trap_error = try pool.intern("trap-error");
        const s_true = try pool.intern("true");
        const s_false = try pool.intern("false");
        const s_cons = try pool.intern("cons");
        const s_hd = try pool.intern("hd");
        const s_tl = try pool.intern("tl");
        const s_consp = try pool.intern("cons?");
        const s_eq = try pool.intern("=");
        const s_add = try pool.intern("+");
        const s_sub = try pool.intern("-");
        const s_mul = try pool.intern("*");
        const s_gt = try pool.intern(">");
        const s_lt = try pool.intern("<");
        const s_numberp = try pool.intern("number?");
        const s_stringp = try pool.intern("string?");
        const s_symbolp = try pool.intern("symbol?");
        const s_not = try pool.intern("not");
        const s_value = try pool.intern("value");
        const s_set = try pool.intern("set");
        const s_do = try pool.intern("do");
        const nursery_arena = try allocator.create(std.heap.ArenaAllocator);
        nursery_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return .{
            .allocator = allocator,
            .nursery_arena = nursery_arena,
            .nursery = nursery_arena.allocator(),
            .pool = pool,
            .globals = .{},
            .functions = .{},
            .sym_defun = s_defun,
            .sym_lambda = s_lambda,
            .sym_let = s_let,
            .sym_freeze = s_freeze,
            .sym_if = s_if,
            .sym_and = s_and,
            .sym_or = s_or,
            .sym_cond = s_cond,
            .sym_trap_error = s_trap_error,
            .sym_true = s_true,
            .sym_false = s_false,
            .sym_cons = s_cons,
            .sym_hd = s_hd,
            .sym_tl = s_tl,
            .sym_consp = s_consp,
            .sym_eq = s_eq,
            .sym_add = s_add,
            .sym_sub = s_sub,
            .sym_mul = s_mul,
            .sym_gt = s_gt,
            .sym_lt = s_lt,
            .sym_numberp = s_numberp,
            .sym_stringp = s_stringp,
            .sym_symbolp = s_symbolp,
            .sym_not = s_not,
            .sym_value = s_value,
            .sym_set = s_set,
            .sym_do = s_do,
        };
    }

    pub fn makeCons(self: *Vm, car: Value, cdr: Value) !Value {
        const cell = try self.nursery.create(Cell);
        cell.* = .{ .car = car, .cdr = cdr };
        return Value{ .cons = cell };
    }

    pub fn makeString(self: *Vm, s: []const u8) !Value {
        const owned = try self.nursery.dupe(u8, s);
        return Value{ .string = owned };
    }

    pub fn asOpaque(self: *Vm) *anyopaque {
        return @ptrCast(self);
    }

    pub fn fromOpaque(ptr: *anyopaque) *Vm {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn makeClosure(self: *Vm, params: []const u32, body: Value, env: *Env, name: ?u32) !Value {
        const cls = try self.nursery.create(Closure);
        cls.* = .{
            .params = params,
            .body = body,
            .env = env,
            .name = name,
            .arity = @intCast(params.len),
            .applied = &.{},
        };
        return Value{ .closure = cls };
    }

    pub fn makePartial(self: *Vm, base: *Closure, args: []const Value) !Value {
        const new_applied = try self.nursery.alloc(Value, base.applied.len + args.len);
        @memcpy(new_applied[0..base.applied.len], base.applied);
        @memcpy(new_applied[base.applied.len..], args);

        const cls = try self.nursery.create(Closure);
        cls.* = .{
            .params = base.params,
            .body = base.body,
            .env = base.env,
            .name = base.name,
            .arity = base.arity,
            .applied = new_applied,
        };
        return Value{ .closure = cls };
    }

    pub fn makeError(self: *Vm, msg: []const u8) !Value {
        const e = try self.nursery.create(ShenError);
        const owned = try self.nursery.dupe(u8, msg);
        e.* = .{ .message = owned };
        return Value{ .err = e };
    }

    pub fn internSym(self: *Vm, name: []const u8) !Value {
        const idx = try self.pool.intern(name);
        return Value{ .symbol = idx };
    }

    /// Check if a pointer falls within the nursery arena's memory.
    /// Uses the arena's internal state to walk page buffers.
    fn isNurseryPtr(self: *Vm, ptr: [*]const u8) bool {
        const addr = @intFromPtr(ptr);
        // Walk the arena's buffer list via its opaque state
        // ArenaAllocator.state.buffer_list is a linked list of pages
        // Each page: prev ptr + data length, content follows
        const state_ptr: [*]const usize = @ptrCast(@alignCast(&self.nursery_arena.state));
        var node_addr = state_ptr[0]; // buffer_list pointer
        while (node_addr != 0) {
            const node: [*]const usize = @ptrFromInt(node_addr);
            const prev = node[0]; // prev pointer
            const data_len = node[1]; // data field (total buffer size)
            const buf_start = node_addr;
            const buf_end = buf_start + data_len;
            if (addr >= buf_start and addr < buf_end) return true;
            node_addr = prev;
        }
        return false;
    }

    /// Deep-copy a value from nursery to tenured allocator.
    /// Scalars (nil, bool, int, float, symbol) are returned as-is.
    /// Values already in tenured are returned as-is.
    /// Heap types (cons, closure, string, vector, err) in nursery are copied.
    pub fn promote(self: *Vm, val: Value) error{OutOfMemory}!Value {
        return switch (val) {
            .nil, .boolean, .integer, .float, .symbol, .native_fn, .stream => val,
            .string => |s| {
                if (!self.isNurseryPtr(s.ptr)) return val;
                return Value{ .string = try self.allocator.dupe(u8, s) };
            },
            .cons => |c| {
                if (!self.isNurseryPtr(@ptrCast(c))) return val;
                const new_cell = try self.allocator.create(Cell);
                new_cell.* = .{
                    .car = try self.promote(c.car),
                    .cdr = try self.promote(c.cdr),
                };
                return Value{ .cons = new_cell };
            },
            .closure => |cls| {
                if (!self.isNurseryPtr(@ptrCast(cls))) return val;
                const new_cls = try self.allocator.create(Closure);
                const new_params = try self.allocator.dupe(u32, cls.params);
                const new_applied = try self.allocator.alloc(Value, cls.applied.len);
                for (cls.applied, 0..) |a, i| {
                    new_applied[i] = try self.promote(a);
                }
                const new_env = try self.promoteEnv(cls.env);
                new_cls.* = .{
                    .params = new_params,
                    .body = try self.promote(cls.body),
                    .env = new_env,
                    .name = cls.name,
                    .arity = cls.arity,
                    .applied = new_applied,
                };
                return Value{ .closure = new_cls };
            },
            .vector => |v| {
                // Vectors are always created in tenured, just promote contents
                if (!self.isNurseryPtr(@ptrCast(v))) return val;
                const new_data = try self.allocator.alloc(Value, v.data.len);
                for (v.data, 0..) |item, i| {
                    new_data[i] = try self.promote(item);
                }
                const new_vec = try self.allocator.create(Vector);
                new_vec.* = .{ .data = new_data };
                return Value{ .vector = new_vec };
            },
            .err => |e| {
                if (!self.isNurseryPtr(@ptrCast(e))) return val;
                const new_e = try self.allocator.create(ShenError);
                new_e.* = .{ .message = try self.allocator.dupe(u8, e.message) };
                return Value{ .err = new_e };
            },
        };
    }

    /// Deep-copy an env chain to tenured.
    fn promoteEnv(self: *Vm, env: *Env) error{OutOfMemory}!*Env {
        if (!self.isNurseryPtr(@ptrCast(env))) return env;
        const new_env = try self.allocator.create(Env);
        new_env.* = Env.init(if (env.parent) |p| try self.promoteEnv(p) else null);
        for (env.bindings.items) |b| {
            try new_env.bindings.append(self.allocator, .{
                .sym = b.sym,
                .val = try self.promote(b.val),
            });
        }
        return new_env;
    }

    /// Reset nursery — call after each top-level eval.
    /// The return value from eval must be promoted first.
    /// Also promotes all vector contents since vectors are tenured but may hold nursery values.
    pub fn resetNursery(self: *Vm) void {
        // Promote all vector contents to tenured before wiping nursery
        for (self.vectors.items) |vec| {
            for (vec.data) |*slot| {
                slot.* = self.promote(slot.*) catch slot.*;
            }
        }
        // Also promote all global values
        var git = self.globals.valueIterator();
        while (git.next()) |val_ptr| {
            val_ptr.* = self.promote(val_ptr.*) catch val_ptr.*;
        }
        // And all function values
        var fit = self.functions.valueIterator();
        while (fit.next()) |val_ptr| {
            val_ptr.* = self.promote(val_ptr.*) catch val_ptr.*;
        }
        _ = self.nursery_arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Vm) void {
        self.nursery_arena.deinit();
        self.allocator.destroy(self.nursery_arena);
        self.pool.deinit();
        self.globals.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.vectors.deinit(self.allocator);
    }
};
