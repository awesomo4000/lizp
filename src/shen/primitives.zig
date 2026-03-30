const std = @import("std");
const types = @import("types.zig");
const eval_mod = @import("eval.zig");
const printer = @import("printer.zig");
const Value = types.Value;
const Vm = types.Vm;
const Env = types.Env;

// ============================================================
// Kλ Primitives
//
// NativeFn takes *anyopaque to break the Value->Vm type cycle.
// Each function casts to *Vm via Vm.fromOpaque.
// ============================================================

fn arg(args: []const Value, n: usize) Value {
    return if (n < args.len) args[n] else .nil;
}

fn vm(ptr: *anyopaque) *Vm {
    return Vm.fromOpaque(ptr);
}

// --- Arithmetic ---

fn add(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .integer and b == .integer) return Value{ .integer = a.integer + b.integer };
    if (a.isNumber() and b.isNumber()) return Value{ .float = a.toFloat() + b.toFloat() };
    return error.TypeError;
}

fn sub(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .integer and b == .integer) return Value{ .integer = a.integer - b.integer };
    if (a.isNumber() and b.isNumber()) return Value{ .float = a.toFloat() - b.toFloat() };
    return error.TypeError;
}

fn mul(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .integer and b == .integer) return Value{ .integer = a.integer * b.integer };
    if (a.isNumber() and b.isNumber()) return Value{ .float = a.toFloat() * b.toFloat() };
    return error.TypeError;
}

fn div(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a == .integer and b == .integer) {
        if (b.integer == 0) return error.TypeError;
        if (@mod(a.integer, b.integer) == 0)
            return Value{ .integer = @divTrunc(a.integer, b.integer) };
        return Value{ .float = @as(f64, @floatFromInt(a.integer)) / @as(f64, @floatFromInt(b.integer)) };
    }
    if (a.isNumber() and b.isNumber()) return Value{ .float = a.toFloat() / b.toFloat() };
    return error.TypeError;
}

fn gt(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a.isNumber() and b.isNumber()) return Value{ .boolean = a.toFloat() > b.toFloat() };
    return error.TypeError;
}

fn lt(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a.isNumber() and b.isNumber()) return Value{ .boolean = a.toFloat() < b.toFloat() };
    return error.TypeError;
}

fn gte(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a.isNumber() and b.isNumber()) return Value{ .boolean = a.toFloat() >= b.toFloat() };
    return error.TypeError;
}

fn lte(args: []const Value, _: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a.isNumber() and b.isNumber()) return Value{ .boolean = a.toFloat() <= b.toFloat() };
    return error.TypeError;
}

fn numberP(args: []const Value, _: *anyopaque) anyerror!Value {
    return Value{ .boolean = arg(args, 0).isNumber() };
}

// --- Equality ---

fn eqlFn(args: []const Value, _: *anyopaque) anyerror!Value {
    return Value{ .boolean = arg(args, 0).eql(arg(args, 1)) };
}

// --- Cons ---

fn cons(args: []const Value, p: *anyopaque) anyerror!Value {
    return vm(p).makeCons(arg(args, 0), arg(args, 1));
}

fn hd(args: []const Value, _: *anyopaque) anyerror!Value {
    const v = arg(args, 0);
    if (v == .cons) return v.cons.car;
    return error.TypeError;
}

fn tl(args: []const Value, _: *anyopaque) anyerror!Value {
    const v = arg(args, 0);
    if (v == .cons) return v.cons.cdr;
    return error.TypeError;
}

fn consP(args: []const Value, _: *anyopaque) anyerror!Value {
    return Value{ .boolean = arg(args, 0) == .cons };
}

// --- Strings ---

fn stringP(args: []const Value, _: *anyopaque) anyerror!Value {
    return Value{ .boolean = arg(args, 0) == .string };
}

fn pos(args: []const Value, p: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    const n = arg(args, 1);
    if (s != .string or n != .integer) return error.TypeError;
    const idx: usize = @intCast(n.integer);
    if (idx >= s.string.len) return error.TypeError;
    return vm(p).makeString(s.string[idx .. idx + 1]);
}

fn tlstr(args: []const Value, p: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    if (s != .string) return error.TypeError;
    if (s.string.len == 0) return error.TypeError;
    return vm(p).makeString(s.string[1..]);
}

fn cn(args: []const Value, p: *anyopaque) anyerror!Value {
    const a = arg(args, 0);
    const b = arg(args, 1);
    if (a != .string or b != .string) return error.TypeError;
    const m = vm(p);
    const result = try m.allocator.alloc(u8, a.string.len + b.string.len);
    @memcpy(result[0..a.string.len], a.string);
    @memcpy(result[a.string.len..], b.string);
    return Value{ .string = result };
}

fn str(args: []const Value, p: *anyopaque) anyerror!Value {
    const v = arg(args, 0);
    if (v == .string) return Value{ .string = v.string };
    const m = vm(p);
    const s = try printer.valueToString(m, v);
    return Value{ .string = s };
}

fn stringToN(args: []const Value, _: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    if (s != .string or s.string.len == 0) return error.TypeError;
    return Value{ .integer = @intCast(s.string[0]) };
}

fn nToString(args: []const Value, p: *anyopaque) anyerror!Value {
    const n = arg(args, 0);
    if (n != .integer) return error.TypeError;
    const buf = try vm(p).allocator.alloc(u8, 1);
    buf[0] = @intCast(n.integer);
    return Value{ .string = buf };
}

// --- Symbols ---

fn intern_(args: []const Value, p: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    if (s != .string) return error.TypeError;
    return vm(p).internSym(s.string);
}

fn set(args: []const Value, p: *anyopaque) anyerror!Value {
    const sym = arg(args, 0);
    const val = arg(args, 1);
    if (sym != .symbol) return error.TypeError;
    const m = vm(p);
    try m.globals.put(m.allocator, sym.symbol, val);
    return val;
}

fn valueFn(args: []const Value, p: *anyopaque) anyerror!Value {
    const sym = arg(args, 0);
    if (sym != .symbol) return error.TypeError;
    return vm(p).globals.get(sym.symbol) orelse error.UnboundSymbol;
}

// --- Vectors ---

fn absvector(args: []const Value, p: *anyopaque) anyerror!Value {
    const n = arg(args, 0);
    if (n != .integer) return error.TypeError;
    const m = vm(p);
    const size: usize = @intCast(n.integer);
    const data = try m.allocator.alloc(Value, size);
    @memset(data, Value{ .symbol = m.sym_false });
    const vec = try m.allocator.create(types.Vector);
    vec.* = .{ .data = data };
    return Value{ .vector = vec };
}

fn addressSet(args: []const Value, _: *anyopaque) anyerror!Value {
    const v = arg(args, 0);
    const n = arg(args, 1);
    const val = arg(args, 2);
    if (v != .vector or n != .integer) return error.TypeError;
    const idx: usize = @intCast(n.integer);
    if (idx >= v.vector.data.len) return error.TypeError;
    v.vector.data[idx] = val;
    return v;
}

fn addressGet(args: []const Value, _: *anyopaque) anyerror!Value {
    const v = arg(args, 0);
    const n = arg(args, 1);
    if (v != .vector or n != .integer) return error.TypeError;
    const idx: usize = @intCast(n.integer);
    if (idx >= v.vector.data.len) return error.TypeError;
    return v.vector.data[idx];
}

// --- Errors ---

fn simpleError(args: []const Value, _: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    if (s != .string) return error.TypeError;
    return error.ShenError;
}

fn errorToString(args: []const Value, _: *anyopaque) anyerror!Value {
    const e = arg(args, 0);
    if (e != .err) return error.TypeError;
    return Value{ .string = e.err.message };
}

// --- Eval ---

fn evalKl(args: []const Value, p: *anyopaque) anyerror!Value {
    var env = Env.init(null);
    return eval_mod.eval(arg(args, 0), &env, vm(p));
}

// --- Streams ---

fn writeByte(args: []const Value, _: *anyopaque) anyerror!Value {
    const n = arg(args, 0);
    const s = arg(args, 1);
    if (n != .integer) return error.TypeError;
    const byte = [1]u8{@intCast(n.integer)};
    if (s == .stream) {
        try s.stream.file.writeAll(&byte);
    } else {
        try std.fs.File.stdout().writeAll(&byte);
    }
    return n;
}

fn readByte(args: []const Value, _: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    var buf: [1]u8 = undefined;
    if (s == .stream) {
        const n = s.stream.file.read(&buf) catch return Value{ .integer = -1 };
        return if (n == 0) Value{ .integer = -1 } else Value{ .integer = @intCast(buf[0]) };
    }
    const n = std.fs.File.stdin().read(&buf) catch return Value{ .integer = -1 };
    return if (n == 0) Value{ .integer = -1 } else Value{ .integer = @intCast(buf[0]) };
}

fn openStream(args: []const Value, p: *anyopaque) anyerror!Value {
    const path = arg(args, 0);
    const mode = arg(args, 1);
    if (path != .string or mode != .symbol) return error.TypeError;
    const m = vm(p);
    const mode_name = m.pool.getName(mode.symbol);

    const s = try m.allocator.create(types.Stream);
    if (std.mem.eql(u8, mode_name, "in")) {
        s.file = try std.fs.cwd().openFile(path.string, .{});
        s.mode = .in;
    } else if (std.mem.eql(u8, mode_name, "out")) {
        s.file = try std.fs.cwd().createFile(path.string, .{});
        s.mode = .out;
    } else return error.TypeError;

    return Value{ .stream = s };
}

fn closeStream(args: []const Value, _: *anyopaque) anyerror!Value {
    const s = arg(args, 0);
    if (s != .stream) return error.TypeError;
    s.stream.file.close();
    return .nil;
}

// --- Time ---

fn getTime(args: []const Value, p: *anyopaque) anyerror!Value {
    const mode = arg(args, 0);
    if (mode != .symbol) return error.TypeError;
    const name = vm(p).pool.getName(mode.symbol);
    if (std.mem.eql(u8, name, "unix") or std.mem.eql(u8, name, "run")) {
        return Value{ .integer = std.time.timestamp() };
    }
    return error.TypeError;
}

// --- Type hint (identity) ---

fn typeFn(args: []const Value, _: *anyopaque) anyerror!Value {
    return arg(args, 0);
}

// --- Registration ---

const PrimDef = struct {
    name: []const u8,
    func: *const anyopaque, // *const NativeFn stored opaque
};

fn native(comptime f: anytype) *const anyopaque {
    const ptr: types.NativeFnSig = f;
    return @ptrCast(ptr);
}

const primitives_table = [_]PrimDef{
    .{ .name = "+", .func = native(add) },
    .{ .name = "-", .func = native(sub) },
    .{ .name = "*", .func = native(mul) },
    .{ .name = "/", .func = native(div) },
    .{ .name = ">", .func = native(gt) },
    .{ .name = "<", .func = native(lt) },
    .{ .name = ">=", .func = native(gte) },
    .{ .name = "<=", .func = native(lte) },
    .{ .name = "number?", .func = native(numberP) },
    .{ .name = "=", .func = native(eqlFn) },
    .{ .name = "cons", .func = native(cons) },
    .{ .name = "hd", .func = native(hd) },
    .{ .name = "tl", .func = native(tl) },
    .{ .name = "cons?", .func = native(consP) },
    .{ .name = "string?", .func = native(stringP) },
    .{ .name = "pos", .func = native(pos) },
    .{ .name = "tlstr", .func = native(tlstr) },
    .{ .name = "cn", .func = native(cn) },
    .{ .name = "str", .func = native(str) },
    .{ .name = "string->n", .func = native(stringToN) },
    .{ .name = "n->string", .func = native(nToString) },
    .{ .name = "intern", .func = native(intern_) },
    .{ .name = "set", .func = native(set) },
    .{ .name = "value", .func = native(valueFn) },
    .{ .name = "absvector", .func = native(absvector) },
    .{ .name = "address->", .func = native(addressSet) },
    .{ .name = "<-address", .func = native(addressGet) },
    .{ .name = "simple-error", .func = native(simpleError) },
    .{ .name = "error-to-string", .func = native(errorToString) },
    .{ .name = "eval-kl", .func = native(evalKl) },
    .{ .name = "write-byte", .func = native(writeByte) },
    .{ .name = "read-byte", .func = native(readByte) },
    .{ .name = "open", .func = native(openStream) },
    .{ .name = "close", .func = native(closeStream) },
    .{ .name = "get-time", .func = native(getTime) },
    .{ .name = "type", .func = native(typeFn) },
};

pub fn registerPrimitives(m: *Vm) !void {
    for (primitives_table) |prim| {
        const sym = try m.pool.intern(prim.name);
        try m.functions.put(m.allocator, sym, Value{ .native_fn = prim.func });
    }

    try setGlobal(m, "*language*", Value{ .string = "Shen" });
    try setGlobal(m, "*implementation*", Value{ .string = "shen-zig" });
    try setGlobal(m, "*release*", Value{ .string = "0.1" });
    try setGlobal(m, "*os*", Value{ .string = "linux" });
    try setGlobal(m, "*port*", Value{ .string = "0.1" });
    try setGlobal(m, "*porters*", Value{ .string = "lizp project" });
    try setGlobal(m, "*stinput*", .nil);
    try setGlobal(m, "*stoutput*", .nil);
}

fn setGlobal(m: *Vm, name: []const u8, val: Value) !void {
    const sym = try m.pool.intern(name);
    try m.globals.put(m.allocator, sym, val);
}
