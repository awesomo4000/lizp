const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;
const Cell = types.Cell;
const Closure = types.Closure;
const Env = types.Env;
const Vm = types.Vm;

// ============================================================
// Kλ Evaluator
//
// Tree-walking interpreter with tail call optimization.
// Handles all Kλ special forms and function application
// with automatic currying (partial application).
// ============================================================

pub const EvalError = error{
    UnboundSymbol,
    NotAFunction,
    TypeError,
    ArityError,
    BadSpecialForm,
    OutOfMemory,
    ShenError, // user-raised via simple-error
    EndOfInput,
    UnterminatedList,
    UnterminatedString,
    UnexpectedClose,
    EmptyAtom,
};

pub fn eval(expr: Value, env: *Env, vm: *Vm) anyerror!Value {
    var current = expr;
    var current_env = env;

    // TCO loop — tail calls restart here instead of recursing
    tco: while (true) {
        switch (current) {
            // Self-evaluating
            .nil, .boolean, .integer, .float, .string,
            .vector, .closure, .native_fn, .stream, .err,
            => return current,

            // Symbol lookup
            .symbol => |sym| {
                // true/false are self-evaluating symbols in Kλ
                if (sym == vm.sym_true) return Value{ .boolean = true };
                if (sym == vm.sym_false) return Value{ .boolean = false };

                // Lexical scope only — globals accessed via (value sym)
                if (current_env.lookup(sym)) |val| return val;

                // Symbols self-evaluate in Kλ if not bound
                return current;
            },

            // List — special form or function call
            .cons => |cell| {
                const head = cell.car;
                const tail = cell.cdr;

                // Special forms (head must be a symbol)
                if (head == .symbol) {
                    const sym = head.symbol;

                    if (sym == vm.sym_if) {
                        const test_val = try eval(listNth(tail, 0), current_env, vm);
                        if (test_val.isTruthy()) {
                            current = listNth(tail, 1);
                        } else {
                            current = listNth(tail, 2);
                        }
                        continue; // TCO
                    }

                    if (sym == vm.sym_and) {
                        const a = try eval(listNth(tail, 0), current_env, vm);
                        if (!a.isTruthy()) return Value{ .boolean = false };
                        current = listNth(tail, 1);
                        continue; // TCO
                    }

                    if (sym == vm.sym_or) {
                        const a = try eval(listNth(tail, 0), current_env, vm);
                        if (a.isTruthy()) return Value{ .boolean = true };
                        current = listNth(tail, 1);
                        continue; // TCO
                    }

                    if (sym == vm.sym_cond) {
                        var clauses = tail;
                        while (clauses == .cons) {
                            const clause = clauses.cons.car;
                            const test_expr = listNth(clause, 0);
                            const test_val = try eval(test_expr, current_env, vm);
                            if (test_val.isTruthy()) {
                                current = listNth(clause, 1);
                                continue :tco;
                            }
                            clauses = clauses.cons.cdr;
                        }
                        return error.BadSpecialForm;
                    }

                    if (sym == vm.sym_let) {
                        const name_sym = listNth(tail, 0).symbol;
                        const val_expr = listNth(tail, 1);
                        const body = listNth(tail, 2);
                        const val = try eval(val_expr, current_env, vm);
                        const new_env = try makeEnv(vm, current_env);
                        try new_env.bind(vm.allocator, name_sym, val);
                        current = body;
                        current_env = new_env;
                        continue; // TCO
                    }

                    if (sym == vm.sym_lambda) {
                        const param_sym = listNth(tail, 0).symbol;
                        const body = listNth(tail, 1);
                        const params = try vm.allocator.alloc(u32, 1);
                        params[0] = param_sym;
                        return vm.makeClosure(params, body, current_env, null);
                    }

                    if (sym == vm.sym_freeze) {
                        const body = listNth(tail, 0);
                        return vm.makeClosure(&.{}, body, current_env, null);
                    }

                    if (sym == vm.sym_defun) {
                        const name_sym = listNth(tail, 0).symbol;
                        const params_list = listNth(tail, 1);
                        const body = listNth(tail, 2);
                        const params = try listToSymArray(params_list, vm);
                        const func = try vm.makeClosure(params, body, current_env, name_sym);
                        try vm.functions.put(vm.allocator, name_sym, func);
                        return func;
                    }

                    if (sym == vm.sym_trap_error) {
                        const body = listNth(tail, 0);
                        const handler = listNth(tail, 1);
                        const result = eval(body, current_env, vm);
                        if (result) |val| {
                            return val;
                        } else |err| {
                            const msg = if (err == error.ShenError)
                                vm.last_error
                            else
                                @errorName(err);
                            const err_val = try vm.makeError(msg);
                            const evaled_handler = try eval(handler, current_env, vm);
                            return apply(evaled_handler, &[_]Value{err_val}, vm);
                        }
                    }
                }

                // Function application
                const func = try eval(head, current_env, vm);
                const args = try evalList(tail, current_env, vm);

                // TCO: if applying a closure in tail position, reuse the loop
                if (func == .closure) {
                    const cls = func.closure;
                    const total_args = cls.applied.len + args.len;

                    if (total_args < cls.arity) {
                        // Partial application
                        return vm.makePartial(cls, args);
                    }

                    if (total_args == cls.arity) {
                        current_env = try bindClosureArgs(cls, args, vm);
                        current = cls.body;
                        continue; // TCO
                    }

                    // Over-application: apply fully, then apply remaining args
                    const needed = cls.arity - cls.applied.len;
                    const new_env = try bindClosureArgs(cls, args[0..needed], vm);
                    const intermediate = try eval(cls.body, new_env, vm);
                    return apply(intermediate, args[needed..], vm);
                }

                if (func == .native_fn) {
                    return types.callNative(func.native_fn, args, vm.asOpaque());
                }

                // Symbol might name a global function
                if (func == .symbol) {
                    if (vm.functions.get(func.symbol)) |f| {
                        if (f == .closure) {
                            const cls = f.closure;
                            if (cls.applied.len + args.len == cls.arity) {
                                current_env = try bindClosureArgs(cls, args, vm);
                                current = cls.body;
                                continue :tco;
                            }
                        }
                        return apply(f, args, vm);
                    }
                }

                return error.NotAFunction;
            },
        }
    }
}

/// Apply a function to arguments — iterative to avoid stack growth
pub fn apply(func: Value, args: []const Value, vm: *Vm) anyerror!Value {
    var current_func = func;
    var current_args = args;

    while (true) {
        switch (current_func) {
            .native_fn => |native| return types.callNative(native, current_args, vm.asOpaque()),
            .closure => |cls| {
                const total = cls.applied.len + current_args.len;
                if (total < cls.arity) {
                    return vm.makePartial(cls, current_args);
                }
                if (total == cls.arity) {
                    const new_env = try bindClosureArgs(cls, current_args, vm);
                    return eval(cls.body, new_env, vm);
                }
                // Over-apply: apply fully, then loop with remaining args
                const needed = cls.arity - cls.applied.len;
                const new_env = try bindClosureArgs(cls, current_args[0..needed], vm);
                current_func = try eval(cls.body, new_env, vm);
                current_args = current_args[needed..];
                continue; // trampoline — don't recurse
            },
            .symbol => {
                if (vm.functions.get(current_func.symbol)) |f| {
                    current_func = f;
                    continue; // resolve and retry
                }
                return error.NotAFunction;
            },
            else => return error.NotAFunction,
        }
    }
}

// --- Helpers ---

fn listNth(list: Value, n: usize) Value {
    var cur = list;
    var i: usize = 0;
    while (cur == .cons) {
        if (i == n) return cur.cons.car;
        cur = cur.cons.cdr;
        i += 1;
    }
    return .nil;
}

fn evalList(list: Value, env: *Env, vm: *Vm) anyerror![]const Value {
    var items = std.ArrayListUnmanaged(Value){};
    var cur = list;
    while (cur == .cons) {
        const val = try eval(cur.cons.car, env, vm);
        try items.append(vm.allocator, val);
        cur = cur.cons.cdr;
    }
    return items.toOwnedSlice(vm.allocator);
}

fn listToSymArray(list: Value, vm: *Vm) ![]const u32 {
    var items = std.ArrayListUnmanaged(u32){};
    var cur = list;
    while (cur == .cons) {
        if (cur.cons.car != .symbol) return error.BadSpecialForm;
        try items.append(vm.allocator, cur.cons.car.symbol);
        cur = cur.cons.cdr;
    }
    return items.toOwnedSlice(vm.allocator);
}

fn makeEnv(vm: *Vm, parent: *Env) !*Env {
    const e = try vm.allocator.create(Env);
    e.* = Env.init(parent);
    return e;
}

/// Bind closure params to applied + new args, return the new env.
fn bindClosureArgs(cls: *const Closure, args: []const Value, vm: *Vm) !*Env {
    const new_env = try makeEnv(vm, cls.env);
    var i: usize = 0;
    for (cls.params) |param| {
        const val = if (i < cls.applied.len)
            cls.applied[i]
        else
            args[i - cls.applied.len];
        try new_env.bind(vm.allocator, param, val);
        i += 1;
    }
    return new_env;
}
