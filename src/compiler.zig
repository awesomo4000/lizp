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
//   integers, +, -, *, /, mod, =, <, >, if, let, fn, do
//
// All compiled functions operate on i64 for simplicity.
// ============================================================

// The compiled output: a function from args to i64
pub const CompiledFn = *const fn (args: []const i64) i64;

// --- Compiler ---

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
        if (std.mem.eql(u8, n, name)) return i;
    }
    @compileError("unbound variable in compiled code: " ++ name);
}

fn compileForm(comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const head = lisp.car(expr);

    if (head == .symbol) {
        const name = head.symbol;

        // Arithmetic
        if (eql(name, "+")) return compileBinOp(.add, expr, env);
        if (eql(name, "-")) return compileBinOp(.sub, expr, env);
        if (eql(name, "*")) return compileBinOp(.mul, expr, env);
        if (eql(name, "/")) return compileBinOp(.div, expr, env);
        if (eql(name, "mod")) return compileBinOp(.mod, expr, env);

        // Comparison
        if (eql(name, "=")) return compileBinOp(.eq, expr, env);
        if (eql(name, "<")) return compileBinOp(.lt, expr, env);
        if (eql(name, ">")) return compileBinOp(.gt, expr, env);
        if (eql(name, "<=")) return compileBinOp(.le, expr, env);
        if (eql(name, ">=")) return compileBinOp(.ge, expr, env);

        // If
        if (eql(name, "if")) return compileIf(expr, env);

        // Let
        if (eql(name, "let")) return compileLet(expr, env);

        // Do
        if (eql(name, "do")) return compileDo(lisp.cdr(expr), env);
    }

    @compileError("cannot compile form: " ++ lisp.printValue(expr));
}

const BinOp = enum { add, sub, mul, div, mod, eq, lt, gt, le, ge };

fn compileBinOp(comptime op: BinOp, comptime expr: Value, comptime env: []const []const u8) CompiledFn {
    const lhs = compileExpr(lisp.cadr(expr), env);
    const rhs = compileExpr(lisp.caddr(expr), env);

    return switch (op) {
        .add => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return a + b; }
        }.do_op),
        .sub => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return a - b; }
        }.do_op),
        .mul => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return a * b; }
        }.do_op),
        .div => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @divTrunc(a, b); }
        }.do_op),
        .mod => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @mod(a, b); }
        }.do_op),
        .eq => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @intFromBool(a == b); }
        }.do_op),
        .lt => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @intFromBool(a < b); }
        }.do_op),
        .gt => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @intFromBool(a > b); }
        }.do_op),
        .le => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @intFromBool(a <= b); }
        }.do_op),
        .ge => makeBinFn(lhs, rhs, struct {
            fn do_op(a: i64, b: i64) i64 { return @intFromBool(a >= b); }
        }.do_op),
    };
}

fn makeBinFn(
    comptime lhs: CompiledFn,
    comptime rhs: CompiledFn,
    comptime op: fn (i64, i64) i64,
) CompiledFn {
    return &struct {
        fn f(args: []const i64) i64 {
            return op(lhs(args), rhs(args));
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
    // (let [name1 val1 name2 val2 ...] body)
    const bindings = lisp.cadr(expr);
    const body = lisp.caddr(expr);
    return compileLetBindings(bindings, body, env);
}

fn compileLetBindings(
    comptime bindings: Value,
    comptime body: Value,
    comptime env: []const []const u8,
) CompiledFn {
    if (bindings == .nil) {
        return compileExpr(body, env);
    }

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
    // Evaluate first for side effects (there are none, but keep semantics)
    const first = compileExpr(lisp.car(exprs), env);
    const remaining = compileDo(rest, env);
    return &struct {
        fn f(args: []const i64) i64 {
            _ = first(args);
            return remaining(args);
        }
    }.f;
}

// --- Public helpers for defining compiled functions ---

pub fn defineFunction(
    comptime source: []const u8,
    comptime params: []const []const u8,
) CompiledFn {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    return compileExpr(expr, params);
}

// Type-safe wrappers that give you real Zig function signatures

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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
