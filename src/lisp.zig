const std = @import("std");

// ============================================================
// Comptime Lisp - An s-expression evaluator that runs entirely
// during Zig compilation. No runtime. The compiler is the VM.
// ============================================================

// --- Value representation ---
// We use a simple tagged union. All data lives in comptime memory.

pub const Value = union(enum) {
    nil,
    integer: i64,
    boolean: bool,
    symbol: []const u8,
    cons: Cons,
    lambda: Lambda,
    builtin: Builtin,
};

pub const Cons = struct {
    car: *const Value,
    cdr: *const Value,
};

pub const Lambda = struct {
    params: *const Value, // list of symbols
    body: *const Value,
    env: *const Env,
};

pub const Builtin = struct {
    name: []const u8,
    func: *const fn (args: *const Value, env: *const Env) Value,
};

// --- Environment ---

pub const Env = struct {
    bindings: []const Binding,
    parent: ?*const Env,
};

pub const Binding = struct {
    name: []const u8,
    val: Value,
};

fn envLookup(env: *const Env, name: []const u8) Value {
    for (env.bindings) |b| {
        if (strEql(b.name, name)) return b.val;
    }
    if (env.parent) |p| return envLookup(p, name);
    @compileError("unbound symbol: " ++ name);
}

fn envExtend(parent: *const Env, bindings: []const Binding) Env {
    return Env{ .bindings = bindings, .parent = parent };
}

// --- Helpers ---

const NIL = Value{ .nil = {} };
const TRUE = Value{ .boolean = true };
const FALSE = Value{ .boolean = false };

pub fn mkInt(n: i64) Value {
    return Value{ .integer = n };
}

pub fn mkSym(name: []const u8) Value {
    return Value{ .symbol = name };
}

pub fn mkCons(car_val: Value, cdr_val: Value) Value {
    return Value{ .cons = .{
        .car = &car_val,
        .cdr = &cdr_val,
    } };
}

pub fn car(v: Value) Value {
    return switch (v) {
        .cons => |c| c.car.*,
        else => unreachable,
    };
}

pub fn cdr(v: Value) Value {
    return switch (v) {
        .cons => |c| c.cdr.*,
        .nil => NIL,
        else => unreachable,
    };
}

pub fn cadr(v: Value) Value {
    return car(cdr(v));
}

pub fn caddr(v: Value) Value {
    return car(cdr(cdr(v)));
}

pub fn cadddr(v: Value) Value {
    return car(cdr(cdr(cdr(v))));
}

pub fn isNil(v: Value) bool {
    return v == .nil;
}

pub fn isTruthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .boolean => |b| b,
        .integer => |n| n != 0,
        else => true,
    };
}

pub fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn listLen(v: Value) usize {
    var count: usize = 0;
    var cur = v;
    while (cur == .cons) {
        count += 1;
        cur = cur.cons.cdr.*;
    }
    return count;
}

// --- Reader (S-expression parser) ---

pub fn read(input: []const u8) Value {
    const result = readExpr(input, 0);
    return result.val;
}

const ReadResult = struct {
    val: Value,
    pos: usize,
};

fn skipWhitespace(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len) {
        switch (input[pos]) {
            ' ', '\t', '\n', '\r', ',' => pos += 1,
            ';' => {
                // skip comment to end of line
                while (pos < input.len and input[pos] != '\n') : (pos += 1) {}
            },
            else => break,
        }
    }
    return pos;
}

fn readExpr(input: []const u8, start: usize) ReadResult {
    const pos = skipWhitespace(input, start);
    if (pos >= input.len) @compileError("unexpected end of input");

    return switch (input[pos]) {
        '(', '[', '{' => readList(input, pos),
        ')', ']', '}' => @compileError("unexpected closing delimiter"),
        '\'' => readQuote(input, pos),
        '"' => readString(input, pos),
        else => readAtom(input, pos),
    };
}

fn readList(input: []const u8, start: usize) ReadResult {
    const open = input[start];
    const expected_close: u8 = switch (open) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => unreachable,
    };
    var pos = start + 1;
    var items: []const Value = &.{};

    while (true) {
        pos = skipWhitespace(input, pos);
        if (pos >= input.len) @compileError("unterminated list");
        if (input[pos] == expected_close) {
            // build cons list from items
            var result = NIL;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                result = mkCons(items[i], result);
            }
            return .{ .val = result, .pos = pos + 1 };
        }
        const r = readExpr(input, pos);
        items = items ++ &[_]Value{r.val};
        pos = r.pos;
    }
}

fn readQuote(input: []const u8, start: usize) ReadResult {
    const r = readExpr(input, start + 1);
    return .{
        .val = mkCons(mkSym("quote"), mkCons(r.val, NIL)),
        .pos = r.pos,
    };
}

fn readString(input: []const u8, start: usize) ReadResult {
    var pos = start + 1;
    var str: []const u8 = "";
    while (pos < input.len and input[pos] != '"') {
        str = str ++ &[_]u8{input[pos]};
        pos += 1;
    }
    if (pos >= input.len) @compileError("unterminated string");
    return .{ .val = Value{ .symbol = str }, .pos = pos + 1 }; // TODO: proper string type
}

fn readAtom(input: []const u8, start: usize) ReadResult {
    var pos = start;
    while (pos < input.len) {
        switch (input[pos]) {
            ' ', '\t', '\n', '\r', ',', '(', ')', '[', ']', '{', '}', ';' => break,
            else => pos += 1,
        }
    }
    const token = input[start..pos];

    // nil
    if (strEql(token, "nil")) return .{ .val = NIL, .pos = pos };

    // booleans
    if (strEql(token, "true")) return .{ .val = TRUE, .pos = pos };
    if (strEql(token, "false")) return .{ .val = FALSE, .pos = pos };

    // try integer
    if (tryParseInt(token)) |n| {
        return .{ .val = mkInt(n), .pos = pos };
    }

    // symbol (including keywords with :)
    return .{ .val = mkSym(token), .pos = pos };
}

fn tryParseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        if (s.len == 1) return null;
        neg = true;
        i = 1;
    }
    var n: i64 = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        n = n * 10 + @as(i64, s[i] - '0');
    }
    return if (neg) -n else n;
}

// --- Eval ---

pub fn eval(expr: Value, env: *const Env) Value {
    return switch (expr) {
        .nil, .integer, .boolean => expr,
        .symbol => |name| {
            if (name[0] == ':') return expr; // keywords self-evaluate
            return envLookup(env, name);
        },
        .cons => evalList(expr, env),
        .lambda, .builtin => expr,
    };
}

fn evalList(expr: Value, env: *const Env) Value {
    const head_expr = car(expr);
    const args_expr = cdr(expr);

    // check for special forms
    if (head_expr == .symbol) {
        const name = head_expr.symbol;

        if (strEql(name, "quote")) {
            return car(args_expr);
        }

        if (strEql(name, "if")) {
            const test_val = eval(car(args_expr), env);
            return if (isTruthy(test_val))
                eval(cadr(args_expr), env)
            else
                eval(caddr(args_expr), env);
        }

        if (strEql(name, "do")) {
            return evalDo(args_expr, env);
        }

        if (strEql(name, "fn")) {
            const params = car(args_expr);
            const body = cadr(args_expr);
            return Value{ .lambda = .{
                .params = &params,
                .body = &body,
                .env = env,
            } };
        }

        if (strEql(name, "let")) {
            return evalLet(args_expr, env);
        }

        if (strEql(name, "def")) {
            @compileError("def not supported in comptime eval (no mutation)");
        }

        if (strEql(name, "defn")) {
            @compileError("defn not supported in comptime eval (no mutation)");
        }
    }

    // function application
    const func = eval(head_expr, env);
    const evaled_args = evalArgs(args_expr, env);

    return apply(func, evaled_args, env);
}

fn evalDo(exprs: Value, env: *const Env) Value {
    if (exprs == .nil) return NIL;
    const val = eval(car(exprs), env);
    const rest = cdr(exprs);
    if (rest == .nil) return val;
    return evalDo(rest, env);
}

fn evalLet(args: Value, env: *const Env) Value {
    const bindings_list = car(args);
    const body = cadr(args);
    const new_env = evalLetBindings(bindings_list, env);
    return eval(body, &new_env);
}

fn evalLetBindings(bindings: Value, env: *const Env) Env {
    if (bindings == .nil) return env.*;
    const name = car(bindings);
    const val_expr = cadr(bindings);
    const rest = cdr(cdr(bindings));

    if (name != .symbol) @compileError("let binding name must be symbol");

    const val = eval(val_expr, env);
    const new_bindings = &[_]Binding{.{ .name = name.symbol, .val = val }};
    const extended = &Env{ .bindings = new_bindings, .parent = env };
    return evalLetBindings(rest, extended);
}

fn evalArgs(args: Value, env: *const Env) Value {
    if (args == .nil) return NIL;
    const val = eval(car(args), env);
    const rest = evalArgs(cdr(args), env);
    return mkCons(val, rest);
}

fn apply(func: Value, args: Value, env: *const Env) Value {
    _ = env;
    return switch (func) {
        .builtin => |b| b.func(&args, &Env{ .bindings = &.{}, .parent = null }),
        .lambda => |lam| {
            const new_env = bindParams(lam.params.*, args, lam.env);
            return eval(lam.body.*, &new_env);
        },
        else => @compileError("not callable: " ++ printValue(func)),
    };
}

fn bindParams(params: Value, args: Value, env: *const Env) Env {
    if (params == .nil) return env.*;
    if (params != .cons) @compileError("bad param list");
    if (args == .nil) @compileError("not enough arguments");

    const name = car(params);
    if (name != .symbol) @compileError("param must be symbol");

    const val = car(args);
    const new_bindings = &[_]Binding{.{ .name = name.symbol, .val = val }};
    const extended = &Env{ .bindings = new_bindings, .parent = env };
    return bindParams(cdr(params), cdr(args), extended);
}

// --- Printer ---

pub fn printValue(v: Value) []const u8 {
    return switch (v) {
        .nil => "nil",
        .integer => |n| intToStr(n),
        .boolean => |b| if (b) "true" else "false",
        .symbol => |s| s,
        .cons => printCons(v),
        .lambda => "(fn ...)",
        .builtin => |b| "(builtin " ++ b.name ++ ")",
    };
}

fn printCons(v: Value) []const u8 {
    var result: []const u8 = "(";
    var cur = v;
    var first = true;
    while (cur == .cons) {
        if (!first) result = result ++ " ";
        first = false;
        result = result ++ printValue(car(cur));
        cur = cdr(cur);
    }
    if (cur != .nil) {
        result = result ++ " . " ++ printValue(cur);
    }
    return result ++ ")";
}

fn intToStr(n: i64) []const u8 {
    if (n == 0) return "0";
    var buf: []const u8 = "";
    var val = if (n < 0) -n else n;
    while (val > 0) {
        const digit: u8 = @intCast(@mod(val, 10));
        buf = &[_]u8{'0' + digit} ++ buf;
        val = @divTrunc(val, 10);
    }
    if (n < 0) buf = "-" ++ buf;
    return buf;
}

// --- Built-in functions ---

fn builtinAdd(args: *const Value, _: *const Env) Value {
    const a = car(args.*).integer;
    const b = cadr(args.*).integer;
    return mkInt(a + b);
}

fn builtinSub(args: *const Value, _: *const Env) Value {
    const a = car(args.*).integer;
    const b = cadr(args.*).integer;
    return mkInt(a - b);
}

fn builtinMul(args: *const Value, _: *const Env) Value {
    const a = car(args.*).integer;
    const b = cadr(args.*).integer;
    return mkInt(a * b);
}

fn builtinDiv(args: *const Value, _: *const Env) Value {
    const a = car(args.*).integer;
    const b = cadr(args.*).integer;
    if (b == 0) unreachable;
    return mkInt(@divTrunc(a, b));
}

fn builtinMod(args: *const Value, _: *const Env) Value {
    const a = car(args.*).integer;
    const b = cadr(args.*).integer;
    return mkInt(@mod(a, b));
}

fn builtinEq(args: *const Value, _: *const Env) Value {
    const a = car(args.*);
    const b = cadr(args.*);
    return Value{ .boolean = valueEql(a, b) };
}

fn builtinLt(args: *const Value, _: *const Env) Value {
    return Value{ .boolean = car(args.*).integer < cadr(args.*).integer };
}

fn builtinGt(args: *const Value, _: *const Env) Value {
    return Value{ .boolean = car(args.*).integer > cadr(args.*).integer };
}

fn builtinCons(args: *const Value, _: *const Env) Value {
    return mkCons(car(args.*), cadr(args.*));
}

fn builtinCar(args: *const Value, _: *const Env) Value {
    return car(car(args.*));
}

fn builtinCdr(args: *const Value, _: *const Env) Value {
    return cdr(car(args.*));
}

fn builtinList(args: *const Value, _: *const Env) Value {
    return args.*;
}

fn builtinIsNil(args: *const Value, _: *const Env) Value {
    return Value{ .boolean = car(args.*) == .nil };
}

fn builtinNot(args: *const Value, _: *const Env) Value {
    return Value{ .boolean = !isTruthy(car(args.*)) };
}

fn valueEql(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .nil => true,
        .integer => a.integer == b.integer,
        .boolean => a.boolean == b.boolean,
        .symbol => strEql(a.symbol, b.symbol),
        .cons => valueEql(car(a), car(b)) and valueEql(cdr(a), cdr(b)),
        else => false,
    };
}

// --- Base environment ---

fn makeBuiltin(name: []const u8, func: *const fn (*const Value, *const Env) Value) Binding {
    return .{ .name = name, .val = Value{ .builtin = .{ .name = name, .func = func } } };
}

pub const base_env = Env{
    .bindings = &[_]Binding{
        makeBuiltin("+", &builtinAdd),
        makeBuiltin("-", &builtinSub),
        makeBuiltin("*", &builtinMul),
        makeBuiltin("/", &builtinDiv),
        makeBuiltin("mod", &builtinMod),
        makeBuiltin("=", &builtinEq),
        makeBuiltin("<", &builtinLt),
        makeBuiltin(">", &builtinGt),
        makeBuiltin("cons", &builtinCons),
        makeBuiltin("car", &builtinCar),
        makeBuiltin("cdr", &builtinCdr),
        makeBuiltin("list", &builtinList),
        makeBuiltin("nil?", &builtinIsNil),
        makeBuiltin("not", &builtinNot),
    },
    .parent = null,
};

// --- Top-level API ---

pub fn run(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(1000000);
    const expr = read(source);
    const result = eval(expr, &base_env);
    return printValue(result);
}

/// Evaluate multiple top-level expressions, threading an environment.
/// Returns the result of the last expression.
pub fn runProgram(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(1000000);
    var pos: usize = 0;
    var env = base_env;
    var last_result: []const u8 = "nil";

    while (true) {
        pos = skipWhitespace(source, pos);
        if (pos >= source.len) break;

        const r = readExpr(source, pos);
        pos = r.pos;

        // Handle def specially by extending env
        if (r.val == .cons) {
            const head = car(r.val);
            if (head == .symbol and strEql(head.symbol, "def")) {
                const name = cadr(r.val);
                const val_expr = caddr(r.val);
                const val = eval(val_expr, &env);
                const new_bindings = &[_]Binding{.{ .name = name.symbol, .val = val }};
                env = .{ .bindings = new_bindings, .parent = &env };
                last_result = printValue(val);
                continue;
            }
            // defn sugar
            if (head == .symbol and strEql(head.symbol, "defn")) {
                const name = cadr(r.val);
                const params = caddr(r.val);
                const body = cadddr(r.val);
                const lam = Value{ .lambda = .{
                    .params = &params,
                    .body = &body,
                    .env = &env,
                } };
                const new_bindings = &[_]Binding{.{ .name = name.symbol, .val = lam }};
                env = .{ .bindings = new_bindings, .parent = &env };
                last_result = name.symbol;
                continue;
            }
        }

        const result = eval(r.val, &env);
        last_result = printValue(result);
    }

    return last_result;
}
