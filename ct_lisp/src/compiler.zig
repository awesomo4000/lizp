const std = @import("std");
const lisp = @import("lisp.zig");
const Value = lisp.Value;

// ============================================================
// Comptime Lisp Compiler
//
// Compiles a subset of lisp into real Zig functions.
// No interpretation at runtime. The lisp is the source language.
// Zig native code is the target. Comptime is the compiler.
//
// Supported forms:
//   integers, +, -, *, /, mod, =, <, >, <=, >=, if, let, do
//
// Recursive functions use a struct wrapper (RecSelf) to break
// Zig's type cycle, allowing self-calls in compiled output.
//
// All compiled functions operate on i64 for simplicity.
// ============================================================

// The compiled output: a function from args to i64
pub const CompiledFn = *const fn (args: []const i64) i64;

// Struct wrapper that breaks the type cycle for recursive functions.
// A recursive function takes (RecSelf, []const i64) -> i64 and
// calls self.call(self, ...) to recurse.
pub const RecSelf = struct {
    call: *const fn (RecSelf, []const i64) i64,
};
const RecCompiledFn = *const fn (RecSelf, []const i64) i64;

// ============================================================
// Non-recursive compiler
// ============================================================

pub fn compile(comptime source: []const u8) CompiledFn {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    return compileExpr(expr, &.{});
}

pub fn compileWithArity(comptime source: []const u8, comptime param_names: []const []const u8) CompiledFn {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    return compileExpr(expr, param_names);
}

fn compileExpr(comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    return switch (expr) {
        .integer => |n| compileConst(n),
        .boolean => |b| compileConst(if (b) 1 else 0),
        .symbol => |name| compileVarRef(name, env),
        .cons => compileForm(expr, env),
        else => @compileError("cannot compile: " ++ lisp.printValue(expr)),
    };
}

fn compileConst(comptime n: i64) CompiledFn {
    return &struct {
        fn f(_: []const i64) i64 {
            return n;
        }
    }.f;
}

fn compileVarRef(comptime name: []const u8, comptime env: []const []const u8) CompiledFn {
    const idx = envIndex(name, env);
    return &struct {
        fn f(args: []const i64) i64 {
            return args[idx];
        }
    }.f;
}

fn envIndex(comptime name: []const u8, comptime env: []const []const u8) usize {
    for (env, 0..) |n, i| {
        if (eql(n, name)) return i;
    }
    @compileError("unbound variable in compiled code: " ++ name);
}

fn compileForm(comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const head = lisp.car(expr);

    if (head == .symbol) {
        const name = head.symbol;

        if (eql(name, "+")) return compileBinOp(.add, expr, env);
        if (eql(name, "-")) return compileBinOp(.sub, expr, env);
        if (eql(name, "*")) return compileBinOp(.mul, expr, env);
        if (eql(name, "/")) return compileBinOp(.div, expr, env);
        if (eql(name, "mod")) return compileBinOp(.mod, expr, env);
        if (eql(name, "=")) return compileBinOp(.eq, expr, env);
        if (eql(name, "<")) return compileBinOp(.lt, expr, env);
        if (eql(name, ">")) return compileBinOp(.gt, expr, env);
        if (eql(name, "<=")) return compileBinOp(.le, expr, env);
        if (eql(name, ">=")) return compileBinOp(.ge, expr, env);
        if (eql(name, "if")) return compileIf(expr, env);
        if (eql(name, "let")) return compileLet(expr, env);
        if (eql(name, "do")) return compileDo(lisp.cdr(expr), env);
    }

    @compileError("cannot compile form: " ++ lisp.printValue(expr));
}

const BinOp = enum { add, sub, mul, div, mod, eq, lt, gt, le, ge };

fn binOpFn(comptime op: BinOp) fn (i64, i64) i64 {
    return switch (op) {
        .add => struct { fn f(a: i64, b: i64) i64 { return a + b; } }.f,
        .sub => struct { fn f(a: i64, b: i64) i64 { return a - b; } }.f,
        .mul => struct { fn f(a: i64, b: i64) i64 { return a * b; } }.f,
        .div => struct { fn f(a: i64, b: i64) i64 { return @divTrunc(a, b); } }.f,
        .mod => struct { fn f(a: i64, b: i64) i64 { return @mod(a, b); } }.f,
        .eq => struct { fn f(a: i64, b: i64) i64 { return @intFromBool(a == b); } }.f,
        .lt => struct { fn f(a: i64, b: i64) i64 { return @intFromBool(a < b); } }.f,
        .gt => struct { fn f(a: i64, b: i64) i64 { return @intFromBool(a > b); } }.f,
        .le => struct { fn f(a: i64, b: i64) i64 { return @intFromBool(a <= b); } }.f,
        .ge => struct { fn f(a: i64, b: i64) i64 { return @intFromBool(a >= b); } }.f,
    };
}

fn compileBinOp(comptime op: BinOp, comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const lhs = compileExpr(lisp.cadr(expr), env);
    const rhs = compileExpr(lisp.caddr(expr), env);
    const op_fn = binOpFn(op);
    return &struct {
        fn f(args: []const i64) i64 {
            return op_fn(lhs(args), rhs(args));
        }
    }.f;
}

fn compileIf(comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const cond = compileExpr(lisp.cadr(expr), env);
    const then_branch = compileExpr(lisp.caddr(expr), env);
    const else_branch = compileExpr(lisp.cadddr(expr), env);
    return &struct {
        fn f(args: []const i64) i64 {
            return if (cond(args) != 0) then_branch(args) else else_branch(args);
        }
    }.f;
}

fn compileLet(comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const bindings = lisp.cadr(expr);
    const body = lisp.caddr(expr);
    return compileLetBindings(bindings, body, env);
}

fn compileLetBindings(
    comptime bindings: Value,
    comptime body: Value,
    comptime env: []const []const u8,
) CompiledFn {
    if (bindings == .nil) return compileExpr(body, env);

    const name = lisp.car(bindings).symbol;
    const val_expr = lisp.cadr(bindings);
    const rest = lisp.cdr(lisp.cdr(bindings));
    const val_fn = compileExpr(val_expr, env);
    const new_env = env ++ &[_][]const u8{name};
    const rest_fn = compileLetBindings(rest, body, new_env);
    const n = env.len;

    return &struct {
        fn f(args: []const i64) i64 {
            const bound_val = val_fn(args);
            var extended: [n + 1]i64 = undefined;
            @memcpy(extended[0..n], args[0..n]);
            extended[n] = bound_val;
            return rest_fn(&extended);
        }
    }.f;
}

fn compileDo(comptime exprs: Value, comptime env: []const []const u8) CompiledFn {
    if (exprs == .nil) return compileConst(0);
    const rest = lisp.cdr(exprs);
    if (rest == .nil) return compileExpr(lisp.car(exprs), env);
    const first = compileExpr(lisp.car(exprs), env);
    const remaining = compileDo(rest, env);
    return &struct {
        fn f(args: []const i64) i64 {
            _ = first(args);
            return remaining(args);
        }
    }.f;
}

// ============================================================
// Recursive compiler — threads RecSelf through every function
// ============================================================

fn compileRecExpr(comptime expr: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    return switch (expr) {
        .integer => |n| compileRecConst(n),
        .boolean => |b| compileRecConst(if (b) 1 else 0),
        .symbol => |name| compileRecVarRef(name, env, self_name),
        .cons => compileRecForm(expr, env, self_name),
        else => @compileError("cannot compile: " ++ lisp.printValue(expr)),
    };
}

fn compileRecConst(comptime n: i64) RecCompiledFn {
    return &struct {
        fn f(_: RecSelf, _: []const i64) i64 {
            return n;
        }
    }.f;
}

fn compileRecVarRef(comptime name: []const u8, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    if (eql(name, self_name)) @compileError("bare self reference '" ++ self_name ++ "' not allowed — use (" ++ self_name ++ " ...)");
    const idx = envIndex(name, env);
    return &struct {
        fn f(_: RecSelf, args: []const i64) i64 {
            return args[idx];
        }
    }.f;
}

fn compileRecForm(comptime expr: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    const head = lisp.car(expr);

    if (head == .symbol) {
        const name = head.symbol;

        // Self-call
        if (eql(name, self_name)) return compileRecSelfCall(lisp.cdr(expr), env, self_name);

        if (eql(name, "+")) return compileRecBinOp(.add, expr, env, self_name);
        if (eql(name, "-")) return compileRecBinOp(.sub, expr, env, self_name);
        if (eql(name, "*")) return compileRecBinOp(.mul, expr, env, self_name);
        if (eql(name, "/")) return compileRecBinOp(.div, expr, env, self_name);
        if (eql(name, "mod")) return compileRecBinOp(.mod, expr, env, self_name);
        if (eql(name, "=")) return compileRecBinOp(.eq, expr, env, self_name);
        if (eql(name, "<")) return compileRecBinOp(.lt, expr, env, self_name);
        if (eql(name, ">")) return compileRecBinOp(.gt, expr, env, self_name);
        if (eql(name, "<=")) return compileRecBinOp(.le, expr, env, self_name);
        if (eql(name, ">=")) return compileRecBinOp(.ge, expr, env, self_name);
        if (eql(name, "if")) return compileRecIf(expr, env, self_name);
        if (eql(name, "let")) return compileRecLet(expr, env, self_name);
        if (eql(name, "do")) return compileRecDo(lisp.cdr(expr), env, self_name);
    }

    @compileError("cannot compile form: " ++ lisp.printValue(expr));
}

fn compileRecSelfCall(comptime args_list: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    const arg_fns = compileRecArgList(args_list, env, self_name);
    const n = arg_fns.len;
    return &struct {
        fn f(self: RecSelf, args: []const i64) i64 {
            var call_args: [n]i64 = undefined;
            inline for (0..n) |i| {
                call_args[i] = arg_fns[i](self, args);
            }
            return self.call(self, &call_args);
        }
    }.f;
}

fn compileRecArgList(comptime args: Value, comptime env: []const []const u8, comptime self_name: []const u8) []const RecCompiledFn {
    if (args == .nil) return &.{};
    return &[_]RecCompiledFn{compileRecExpr(lisp.car(args), env, self_name)} ++
        compileRecArgList(lisp.cdr(args), env, self_name);
}

fn compileRecBinOp(comptime op: BinOp, comptime expr: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    const lhs = compileRecExpr(lisp.cadr(expr), env, self_name);
    const rhs = compileRecExpr(lisp.caddr(expr), env, self_name);
    const op_fn = binOpFn(op);
    return &struct {
        fn f(self: RecSelf, args: []const i64) i64 {
            return op_fn(lhs(self, args), rhs(self, args));
        }
    }.f;
}

fn compileRecIf(comptime expr: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    const cond = compileRecExpr(lisp.cadr(expr), env, self_name);
    const then_branch = compileRecExpr(lisp.caddr(expr), env, self_name);
    const else_branch = compileRecExpr(lisp.cadddr(expr), env, self_name);
    return &struct {
        fn f(self: RecSelf, args: []const i64) i64 {
            return if (cond(self, args) != 0) then_branch(self, args) else else_branch(self, args);
        }
    }.f;
}

fn compileRecLet(comptime expr: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    const bindings = lisp.cadr(expr);
    const body = lisp.caddr(expr);
    return compileRecLetBindings(bindings, body, env, self_name);
}

fn compileRecLetBindings(
    comptime bindings: Value,
    comptime body: Value,
    comptime env: []const []const u8,
    comptime self_name: []const u8,
) RecCompiledFn {
    if (bindings == .nil) return compileRecExpr(body, env, self_name);

    const name = lisp.car(bindings).symbol;
    const val_expr = lisp.cadr(bindings);
    const rest = lisp.cdr(lisp.cdr(bindings));
    const val_fn = compileRecExpr(val_expr, env, self_name);
    const new_env = env ++ &[_][]const u8{name};
    const rest_fn = compileRecLetBindings(rest, body, new_env, self_name);
    const n = env.len;

    return &struct {
        fn f(self: RecSelf, args: []const i64) i64 {
            const bound_val = val_fn(self, args);
            var extended: [n + 1]i64 = undefined;
            @memcpy(extended[0..n], args[0..n]);
            extended[n] = bound_val;
            return rest_fn(self, &extended);
        }
    }.f;
}

fn compileRecDo(comptime exprs: Value, comptime env: []const []const u8, comptime self_name: []const u8) RecCompiledFn {
    if (exprs == .nil) return compileRecConst(0);
    const rest = lisp.cdr(exprs);
    if (rest == .nil) return compileRecExpr(lisp.car(exprs), env, self_name);
    const first = compileRecExpr(lisp.car(exprs), env, self_name);
    const remaining = compileRecDo(rest, env, self_name);
    return &struct {
        fn f(self: RecSelf, args: []const i64) i64 {
            _ = first(self, args);
            return remaining(self, args);
        }
    }.f;
}

// ============================================================
// Public API
// ============================================================

pub fn defineFunction(
    comptime source: []const u8,
    comptime params: []const []const u8,
) CompiledFn {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    return compileExpr(expr, params);
}

fn defineRecFunction(
    comptime source: []const u8,
    comptime self_name: []const u8,
    comptime params: []const []const u8,
) RecCompiledFn {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    return compileRecExpr(expr, params, self_name);
}

// --- Non-recursive wrappers ---

pub fn Fn1(comptime source: []const u8, comptime param: []const u8) fn (i64) i64 {
    const compiled = defineFunction(source, &.{param});
    return struct {
        fn f(x: i64) i64 {
            return compiled(&.{x});
        }
    }.f;
}

pub fn Fn2(
    comptime source: []const u8,
    comptime p1: []const u8,
    comptime p2: []const u8,
) fn (i64, i64) i64 {
    const compiled = defineFunction(source, &.{ p1, p2 });
    return struct {
        fn f(a: i64, b: i64) i64 {
            return compiled(&.{ a, b });
        }
    }.f;
}

pub fn Fn3(
    comptime source: []const u8,
    comptime p1: []const u8,
    comptime p2: []const u8,
    comptime p3: []const u8,
) fn (i64, i64, i64) i64 {
    const compiled = defineFunction(source, &.{ p1, p2, p3 });
    return struct {
        fn f(a: i64, b: i64, c: i64) i64 {
            return compiled(&.{ a, b, c });
        }
    }.f;
}

// --- Recursive wrappers ---
// The self_name parameter is the symbol the body uses to recurse.

pub fn RecFn1(
    comptime source: []const u8,
    comptime self_name: []const u8,
    comptime param: []const u8,
) fn (i64) i64 {
    const body = defineRecFunction(source, self_name, &.{param});
    return struct {
        fn f(x: i64) i64 {
            const self = RecSelf{ .call = body };
            return self.call(self, &.{x});
        }
    }.f;
}

pub fn RecFn2(
    comptime source: []const u8,
    comptime self_name: []const u8,
    comptime p1: []const u8,
    comptime p2: []const u8,
) fn (i64, i64) i64 {
    const body = defineRecFunction(source, self_name, &.{ p1, p2 });
    return struct {
        fn f(a: i64, b: i64) i64 {
            const self = RecSelf{ .call = body };
            return self.call(self, &.{ a, b });
        }
    }.f;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
