pub const lisp = @import("lisp.zig");
pub const compiler = @import("compiler.zig");

// Re-export the main entry points for convenience
pub const run = lisp.run;
pub const read = lisp.read;
pub const eval = lisp.eval;
pub const printValue = lisp.printValue;
pub const base_env = lisp.base_env;
pub const Value = lisp.Value;

pub const compile = compiler.compile;
pub const Fn1 = compiler.Fn1;
pub const Fn2 = compiler.Fn2;
pub const Fn3 = compiler.Fn3;
