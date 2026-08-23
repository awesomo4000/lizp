const std = @import("std");
const lisp = @import("lisp.zig");
const Value = lisp.Value;

// ============================================================
// Macros for Comptime Lisp
//
// A macro is a function: s-expression → s-expression
// Macro expansion happens BEFORE eval.
//
// (when (> x 5) (print "big") (print "number"))
// → (if (> x 5) (do (print "big") (print "number")) nil)
// ============================================================

pub const MacroTable = struct {
    entries: []const MacroEntry,

    pub fn lookup(self: *const MacroTable, name: []const u8) ?MacroEntry {
        for (self.entries) |e| {
            if (eql(e.name, name)) return e;
        }
        return null;
    }

    pub fn extend(self: *const MacroTable, entry: MacroEntry) MacroTable {
        return .{ .entries = self.entries ++ &[_]MacroEntry{entry} };
    }
};

pub const MacroEntry = struct {
    name: []const u8,
    builtin: *const fn (form: Value, macros: *const MacroTable) Value,
};

pub const empty_macros = MacroTable{ .entries = &.{} };

// --- Macro expansion ---

pub fn macroExpand(expr: Value, macros: *const MacroTable) Value {
    if (expr != .cons) return expr;

    const head = lisp.car(expr);

    // Don't expand inside quote
    if (head == .symbol and eql(head.symbol, "quote")) {
        return expr;
    }

    // Check if head is a macro
    if (head == .symbol) {
        if (macros.lookup(head.symbol)) |macro| {
            const expanded = macro.builtin(expr, macros);
            return macroExpand(expanded, macros);
        }
    }

    // Not a macro call — expand children
    return expandChildren(expr, macros);
}

fn expandChildren(expr: Value, macros: *const MacroTable) Value {
    if (expr == .nil) return expr;
    if (expr != .cons) return expr;

    const expanded_car = macroExpand(lisp.car(expr), macros);
    const expanded_cdr = expandChildren(lisp.cdr(expr), macros);
    return lisp.mkCons(expanded_car, expanded_cdr);
}

// --- Built-in macros ---

const NIL = Value{ .nil = {} };

// (when test body1 body2 ...) → (if test (do body1 body2 ...) nil)
fn macroWhen(form: Value, _: *const MacroTable) Value {
    const test_expr = lisp.cadr(form);
    const body = lisp.cdr(lisp.cdr(form));
    return lisp.mkCons(
        lisp.mkSym("if"),
        lisp.mkCons(
            test_expr,
            lisp.mkCons(
                lisp.mkCons(lisp.mkSym("do"), body),
                lisp.mkCons(NIL, NIL),
            ),
        ),
    );
}

// (unless test body1 body2 ...) → (if test nil (do body1 body2 ...))
fn macroUnless(form: Value, _: *const MacroTable) Value {
    const test_expr = lisp.cadr(form);
    const body = lisp.cdr(lisp.cdr(form));
    return lisp.mkCons(
        lisp.mkSym("if"),
        lisp.mkCons(
            test_expr,
            lisp.mkCons(
                NIL,
                lisp.mkCons(
                    lisp.mkCons(lisp.mkSym("do"), body),
                    NIL,
                ),
            ),
        ),
    );
}

// (cond [test1 expr1] [test2 expr2] ... [:else exprN])
// → (if test1 expr1 (if test2 expr2 (... exprN)))
fn macroCond(form: Value, macros: *const MacroTable) Value {
    return expandClauses(lisp.cdr(form), macros);
}

fn expandClauses(clauses: Value, _: *const MacroTable) Value {
    if (clauses == .nil) return NIL;

    const clause = lisp.car(clauses);
    const test_expr = lisp.car(clause);
    const body_expr = lisp.cadr(clause);
    const rest = lisp.cdr(clauses);

    // :else clause — just return the body
    if (test_expr == .symbol and eql(test_expr.symbol, ":else")) {
        return body_expr;
    }

    return lisp.mkCons(
        lisp.mkSym("if"),
        lisp.mkCons(
            test_expr,
            lisp.mkCons(
                body_expr,
                lisp.mkCons(
                    expandClauses(rest, &standard_macros),
                    NIL,
                ),
            ),
        ),
    );
}

// (-> x (f a) (g b c)) → (g (f x a) b c)
fn macroThread(form: Value, _: *const MacroTable) Value {
    const init = lisp.cadr(form);
    const steps = lisp.cdr(lisp.cdr(form));
    return threadSteps(init, steps);
}

fn threadSteps(val: Value, steps: Value) Value {
    if (steps == .nil) return val;

    const step = lisp.car(steps);
    const rest = lisp.cdr(steps);

    const threaded = if (step == .cons) blk: {
        const func = lisp.car(step);
        const args = lisp.cdr(step);
        break :blk lisp.mkCons(func, lisp.mkCons(val, args));
    } else blk: {
        break :blk lisp.mkCons(step, lisp.mkCons(val, NIL));
    };

    return threadSteps(threaded, rest);
}

// (->> x (f a) (g b c)) → (g b c (f a x))
fn macroThreadLast(form: Value, _: *const MacroTable) Value {
    const init = lisp.cadr(form);
    const steps = lisp.cdr(lisp.cdr(form));
    return threadLastSteps(init, steps);
}

fn threadLastSteps(val: Value, steps: Value) Value {
    if (steps == .nil) return val;

    const step = lisp.car(steps);
    const rest = lisp.cdr(steps);

    const threaded = if (step == .cons) blk: {
        break :blk appendToList(step, val);
    } else blk: {
        break :blk lisp.mkCons(step, lisp.mkCons(val, NIL));
    };

    return threadLastSteps(threaded, rest);
}

fn appendToList(lst: Value, val: Value) Value {
    if (lst == .nil) return lisp.mkCons(val, NIL);
    return lisp.mkCons(lisp.car(lst), appendToList(lisp.cdr(lst), val));
}

// (and a b c) → (if a (if b c false) false)
fn macroAnd(form: Value, _: *const MacroTable) Value {
    return expandAnd(lisp.cdr(form));
}

fn expandAnd(exprs: Value) Value {
    if (exprs == .nil) return Value{ .boolean = true };
    const rest = lisp.cdr(exprs);
    if (rest == .nil) return lisp.car(exprs);
    return lisp.mkCons(
        lisp.mkSym("if"),
        lisp.mkCons(
            lisp.car(exprs),
            lisp.mkCons(
                expandAnd(rest),
                lisp.mkCons(Value{ .boolean = false }, NIL),
            ),
        ),
    );
}

// (or a b c) → (if a a (if b b c))
fn macroOr(form: Value, _: *const MacroTable) Value {
    return expandOr(lisp.cdr(form));
}

fn expandOr(exprs: Value) Value {
    if (exprs == .nil) return Value{ .boolean = false };
    const rest = lisp.cdr(exprs);
    if (rest == .nil) return lisp.car(exprs);
    return lisp.mkCons(
        lisp.mkSym("if"),
        lisp.mkCons(
            lisp.car(exprs),
            lisp.mkCons(
                lisp.car(exprs),
                lisp.mkCons(expandOr(rest), NIL),
            ),
        ),
    );
}

// --- Standard macro table ---

pub const standard_macros = MacroTable{
    .entries = &[_]MacroEntry{
        .{ .name = "when", .builtin = &macroWhen },
        .{ .name = "unless", .builtin = &macroUnless },
        .{ .name = "cond", .builtin = &macroCond },
        .{ .name = "->", .builtin = &macroThread },
        .{ .name = "->>", .builtin = &macroThreadLast },
        .{ .name = "and", .builtin = &macroAnd },
        .{ .name = "or", .builtin = &macroOr },
    },
};

// --- Integration: expand then eval ---

pub fn expandAndEval(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    const expanded = macroExpand(expr, &standard_macros);
    const result = lisp.eval(expanded, lisp.base_env);
    return lisp.printValue(result);
}

pub fn expandAndShow(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(1000000);
    const expr = lisp.read(source);
    const expanded = macroExpand(expr, &standard_macros);
    return lisp.printValue(expanded);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
