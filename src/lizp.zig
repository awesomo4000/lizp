pub const lisp = @import("lisp.zig");
pub const compiler = @import("compiler.zig");

// Re-export the main entry points for convenience
pub const run = lisp.run;
pub const runProgram = lisp.runProgram;
pub const read = lisp.read;
pub const eval = lisp.eval;
pub const printValue = lisp.printValue;
pub const base_env = lisp.base_env;
pub const Value = lisp.Value;

pub const compile = compiler.compile;
pub const Fn1 = compiler.Fn1;
pub const Fn2 = compiler.Fn2;
pub const Fn3 = compiler.Fn3;
pub const RecFn1 = compiler.RecFn1;
pub const RecFn2 = compiler.RecFn2;

pub const macros = @import("macros.zig");
pub const expandAndEval = macros.expandAndEval;
pub const expandAndShow = macros.expandAndShow;

pub const bridge = @import("bridge.zig");
pub const synthesizeType = bridge.synthesizeType;
pub const synthesizeProtocol = bridge.synthesizeProtocol;
pub const assertLisp = bridge.assertLisp;
pub const assertLispEq = bridge.assertLispEq;
pub const VecFromLisp = bridge.VecFromLisp;
