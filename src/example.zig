const std = @import("std");
const lizp = @import("lizp");

// Comptime lisp evaluation
const answer = lizp.run("(+ 1 2)");
const fib_10 = lizp.run(
    \\(let [fib (fn [self n]
    \\            (if (< n 2) n
    \\              (+ (self self (- n 1))
    \\                 (self self (- n 2)))))]
    \\  (fib fib 10))
);

// Multi-expression program with def/defn
const program_result = lizp.lisp.runProgram(
    \\(def x 10)
    \\(def y 20)
    \\(defn add-em [a b] (+ a b))
    \\(add-em x y)
);

// Lisp-compiled native functions — no interpretation at runtime
const square = lizp.Fn1("(* x x)", "x");
const abs_ = lizp.Fn1("(if (< x 0) (- 0 x) x)", "x");
const diff_sq = lizp.Fn2("(* (+ a b) (- a b))", "a", "b");

// Recursive native functions — lisp all the way down, native all the way up
const factorial = lizp.RecFn1("(if (= n 0) 1 (* n (self (- n 1))))", "self", "n");
const fib = lizp.RecFn1("(if (< n 2) n (+ (self (- n 1)) (self (- n 2))))", "self", "n");

pub fn main() void {
    const print = std.debug.print;

    print("=== comptime eval ===\n", .{});
    print("(+ 1 2) = {s}\n", .{answer});
    print("(fib 10) = {s}\n", .{fib_10});
    print("def/defn program = {s}\n", .{program_result});

    print("\n=== native compiled functions ===\n", .{});
    print("square(7) = {d}\n", .{square(7)});
    print("abs(-42) = {d}\n", .{abs_(-42)});
    print("diff_sq(10, 3) = {d}\n", .{diff_sq(10, 3)});

    // sum of squares using a lisp-compiled function in a loop
    var sum: i64 = 0;
    for (0..10) |i| {
        sum += square(@intCast(i));
    }
    print("sum_of_squares(0..10) = {d}\n", .{sum});

    print("\n=== recursive native functions ===\n", .{});
    print("factorial(12) = {d}\n", .{factorial(12)});
    print("fib(25) = {d}\n", .{fib(25)});
}
