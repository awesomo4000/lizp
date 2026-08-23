const std = @import("std");
const testing = std.testing;
const lisp = @import("lisp.zig");
const compiler = @import("compiler.zig");
const macros = @import("macros.zig");
const bridge = @import("bridge.zig");

// ============================================================
// Interpreter tests
// ============================================================

// --- Arithmetic ---

test "integer addition" {
    try testing.expectEqualStrings("3", comptime lisp.run("(+ 1 2)"));
}

test "nested arithmetic" {
    try testing.expectEqualStrings("30", comptime lisp.run("(* (+ 2 3) (- 10 4))"));
}

test "subtraction" {
    try testing.expectEqualStrings("-5", comptime lisp.run("(- 3 8)"));
}

test "division" {
    try testing.expectEqualStrings("4", comptime lisp.run("(/ 12 3)"));
}

test "modulo" {
    try testing.expectEqualStrings("1", comptime lisp.run("(mod 7 3)"));
}

// --- Booleans and comparisons ---

test "equality true" {
    try testing.expectEqualStrings("true", comptime lisp.run("(= 5 5)"));
}

test "equality false" {
    try testing.expectEqualStrings("false", comptime lisp.run("(= 5 6)"));
}

test "less than" {
    try testing.expectEqualStrings("true", comptime lisp.run("(< 3 5)"));
}

test "greater than" {
    try testing.expectEqualStrings("false", comptime lisp.run("(> 3 5)"));
}

test "not" {
    try testing.expectEqualStrings("true", comptime lisp.run("(not false)"));
    try testing.expectEqualStrings("false", comptime lisp.run("(not true)"));
}

// --- Conditionals ---

test "if true branch" {
    try testing.expectEqualStrings("300", comptime lisp.run("(if (> 10 5) (+ 100 200) 0)"));
}

test "if false branch" {
    try testing.expectEqualStrings("0", comptime lisp.run("(if (< 10 5) (+ 100 200) 0)"));
}

// --- Let bindings ---

test "simple let" {
    try testing.expectEqualStrings("30", comptime lisp.run("(let [x 10 y 20] (+ x y))"));
}

test "let with shadowing" {
    try testing.expectEqualStrings("5", comptime lisp.run("(let [x 3 x 5] x)"));
}

test "nested let" {
    try testing.expectEqualStrings("34", comptime lisp.run(
        \\(let [square (fn [x] (* x x))]
        \\  (+ (square 5) (square 3)))
    ));
}

// --- Lambda and closures ---

test "immediate lambda application" {
    try testing.expectEqualStrings("49", comptime lisp.run("((fn [x] (* x x)) 7)"));
}

test "closure captures environment" {
    try testing.expectEqualStrings("15", comptime lisp.run(
        \\(let [add5 (fn [x] (+ x 5))]
        \\  (add5 10))
    ));
}

// --- Recursion via U-combinator ---

test "factorial via self-passing" {
    try testing.expectEqualStrings("3628800", comptime lisp.run(
        \\(let [factorial (fn [self n]
        \\                  (if (= n 0) 1
        \\                    (* n (self self (- n 1)))))]
        \\  (factorial factorial 10))
    ));
}

test "fibonacci via self-passing" {
    try testing.expectEqualStrings("610", comptime lisp.run(
        \\(let [fib (fn [self n]
        \\            (if (< n 2) n
        \\              (+ (self self (- n 1))
        \\                 (self self (- n 2)))))]
        \\  (fib fib 15))
    ));
}

// --- Lists ---

test "cons car cdr" {
    try testing.expectEqualStrings("1", comptime lisp.run("(car (cons 1 2))"));
    try testing.expectEqualStrings("2", comptime lisp.run("(cdr (cons 1 2))"));
}

test "list construction" {
    try testing.expectEqualStrings("(1 2 3)", comptime lisp.run("(list 1 2 3)"));
}

test "nil?" {
    try testing.expectEqualStrings("true", comptime lisp.run("(nil? nil)"));
    try testing.expectEqualStrings("false", comptime lisp.run("(nil? 1)"));
}

test "map via self-passing" {
    try testing.expectEqualStrings("(1 4 9 16 25)", comptime lisp.run(
        \\(let [map (fn [self f lst]
        \\            (if (nil? lst) nil
        \\              (cons (f (car lst))
        \\                    (self self f (cdr lst)))))]
        \\  (map map (fn [x] (* x x)) (list 1 2 3 4 5)))
    ));
}

// --- Quote ---

test "quote symbol" {
    try testing.expectEqualStrings("x", comptime lisp.run("(quote x)"));
}

test "quote list" {
    try testing.expectEqualStrings("(1 2 3)", comptime lisp.run("(quote (1 2 3))"));
}

test "quote shorthand" {
    try testing.expectEqualStrings("x", comptime lisp.run("'x"));
}

// --- Do blocks ---

test "do returns last" {
    try testing.expectEqualStrings("3", comptime lisp.run("(do 1 2 3)"));
}

// --- Keywords ---

test "keywords self-evaluate" {
    try testing.expectEqualStrings(":foo", comptime lisp.run(":foo"));
}

// ============================================================
// def / defn (runProgram)
// ============================================================

test "def binds value" {
    try testing.expectEqualStrings("42", comptime lisp.runProgram(
        \\(def x 42)
        \\x
    ));
}

test "def with expression" {
    try testing.expectEqualStrings("30", comptime lisp.runProgram(
        \\(def x (+ 10 20))
        \\x
    ));
}

test "multiple defs" {
    try testing.expectEqualStrings("30", comptime lisp.runProgram(
        \\(def x 10)
        \\(def y 20)
        \\(+ x y)
    ));
}

test "defn defines function" {
    try testing.expectEqualStrings("25", comptime lisp.runProgram(
        \\(defn square [x] (* x x))
        \\(square 5)
    ));
}

test "defn calling defn" {
    try testing.expectEqualStrings("91", comptime lisp.runProgram(
        \\(defn square [x] (* x x))
        \\(defn diff-sq [a b] (- (square a) (square b)))
        \\(diff-sq 10 3)
    ));
}

test "def used in defn" {
    try testing.expectEqualStrings("110", comptime lisp.runProgram(
        \\(def base 100)
        \\(defn add-to-base [x] (+ base x))
        \\(add-to-base 10)
    ));
}

// ============================================================
// Compiler tests (lisp -> native functions)
// ============================================================

test "compile constant" {
    const f = comptime compiler.Fn1("42", "x");
    try testing.expectEqual(@as(i64, 42), f(0));
}

test "compile variable" {
    const f = comptime compiler.Fn1("x", "x");
    try testing.expectEqual(@as(i64, 7), f(7));
}

test "compile arithmetic" {
    const f = comptime compiler.Fn1("(* x x)", "x");
    try testing.expectEqual(@as(i64, 49), f(7));
}

test "compile two args" {
    const f = comptime compiler.Fn2("(+ a b)", "a", "b");
    try testing.expectEqual(@as(i64, 15), f(7, 8));
}

test "compile if" {
    const f = comptime compiler.Fn1("(if (< x 0) (- 0 x) x)", "x");
    try testing.expectEqual(@as(i64, 42), f(-42));
    try testing.expectEqual(@as(i64, 7), f(7));
}

test "compile let" {
    const f = comptime compiler.Fn1("(let [y (* x x)] (+ y y))", "x");
    try testing.expectEqual(@as(i64, 98), f(7));
}

test "compile nested let" {
    const f = comptime compiler.Fn2(
        "(let [sum (+ a b) diff (- a b)] (* sum diff))",
        "a",
        "b",
    );
    try testing.expectEqual(@as(i64, 91), f(10, 3)); // (10+3)*(10-3) = 13*7
}

test "compile comparisons" {
    const eq = comptime compiler.Fn2("(= a b)", "a", "b");
    try testing.expectEqual(@as(i64, 1), eq(5, 5));
    try testing.expectEqual(@as(i64, 0), eq(5, 6));

    const lt = comptime compiler.Fn2("(< a b)", "a", "b");
    try testing.expectEqual(@as(i64, 1), lt(3, 5));
    try testing.expectEqual(@as(i64, 0), lt(5, 3));
}

test "compile three args" {
    const f = comptime compiler.Fn3("(+ a (+ b c))", "a", "b", "c");
    try testing.expectEqual(@as(i64, 60), f(10, 20, 30));
}

test "compiled function in loop" {
    const square = comptime compiler.Fn1("(* x x)", "x");
    var sum: i64 = 0;
    for (0..5) |i| {
        sum += square(@intCast(i));
    }
    // 0 + 1 + 4 + 9 + 16 = 30
    try testing.expectEqual(@as(i64, 30), sum);
}

// ============================================================
// Recursive compiled function tests
// ============================================================

test "compile recursive factorial" {
    const factorial = comptime compiler.RecFn1(
        "(if (= n 0) 1 (* n (self (- n 1))))",
        "self",
        "n",
    );
    try testing.expectEqual(@as(i64, 1), factorial(0));
    try testing.expectEqual(@as(i64, 1), factorial(1));
    try testing.expectEqual(@as(i64, 120), factorial(5));
    try testing.expectEqual(@as(i64, 3628800), factorial(10));
}

test "compile recursive fibonacci" {
    const fib = comptime compiler.RecFn1(
        "(if (< n 2) n (+ (self (- n 1)) (self (- n 2))))",
        "self",
        "n",
    );
    try testing.expectEqual(@as(i64, 0), fib(0));
    try testing.expectEqual(@as(i64, 1), fib(1));
    try testing.expectEqual(@as(i64, 55), fib(10));
    try testing.expectEqual(@as(i64, 610), fib(15));
}

test "compile recursive sum" {
    const sum_to = comptime compiler.RecFn1(
        "(if (= n 0) 0 (+ n (self (- n 1))))",
        "self",
        "n",
    );
    try testing.expectEqual(@as(i64, 0), sum_to(0));
    try testing.expectEqual(@as(i64, 55), sum_to(10));
    try testing.expectEqual(@as(i64, 5050), sum_to(100));
}

test "compile recursive gcd" {
    const gcd = comptime compiler.RecFn2(
        "(if (= b 0) a (self b (mod a b)))",
        "self",
        "a",
        "b",
    );
    try testing.expectEqual(@as(i64, 6), gcd(12, 18));
    try testing.expectEqual(@as(i64, 1), gcd(17, 13));
    try testing.expectEqual(@as(i64, 15), gcd(45, 30));
}

test "compile recursive with let" {
    const f = comptime compiler.RecFn1(
        "(if (= n 0) 0 (let [prev (self (- n 1))] (+ n prev)))",
        "self",
        "n",
    );
    // same as sum_to
    try testing.expectEqual(@as(i64, 55), f(10));
}

// ============================================================
// Macro tests
// ============================================================

test "when true" {
    try testing.expectEqualStrings("300", comptime macros.expandAndEval("(when (> 10 5) (+ 100 200))"));
}

test "when false" {
    try testing.expectEqualStrings("nil", comptime macros.expandAndEval("(when (< 10 5) (+ 100 200))"));
}

test "unless true" {
    try testing.expectEqualStrings("nil", comptime macros.expandAndEval("(unless (> 10 5) (+ 100 200))"));
}

test "unless false" {
    try testing.expectEqualStrings("300", comptime macros.expandAndEval("(unless (< 10 5) (+ 100 200))"));
}

test "cond" {
    try testing.expectEqualStrings("10", comptime macros.expandAndEval(
        \\(cond
        \\  [(= 1 2) 0]
        \\  [(= 1 1) 10]
        \\  [:else 20])
    ));
}

test "cond else" {
    try testing.expectEqualStrings("20", comptime macros.expandAndEval(
        \\(cond
        \\  [(= 1 2) 0]
        \\  [(= 1 3) 10]
        \\  [:else 20])
    ));
}

test "thread first" {
    // (-> 1 (+ 2) (* 3)) → (* (+ 1 2) 3) → 9
    try testing.expectEqualStrings("9", comptime macros.expandAndEval("(-> 1 (+ 2) (* 3))"));
}

test "thread last" {
    // (->> 1 (+ 2) (* 3)) → (* 3 (+ 2 1)) → 9
    try testing.expectEqualStrings("9", comptime macros.expandAndEval("(->> 1 (+ 2) (* 3))"));
}

test "and all true" {
    try testing.expectEqualStrings("true", comptime macros.expandAndEval("(and (> 10 5) (< 3 7))"));
}

test "and short circuit" {
    try testing.expectEqualStrings("false", comptime macros.expandAndEval("(and (> 1 5) (< 3 7))"));
}

test "or first true" {
    try testing.expectEqualStrings("true", comptime macros.expandAndEval("(or (> 10 5) (< 3 7))"));
}

test "or fallthrough" {
    try testing.expectEqualStrings("true", comptime macros.expandAndEval("(or (> 1 5) (< 3 7))"));
}

test "or all false" {
    try testing.expectEqualStrings("false", comptime macros.expandAndEval("(or (> 1 5) (< 7 3))"));
}

test "expand shows expansion" {
    try testing.expectEqualStrings(
        "(if (> 10 5) (do (+ 100 200)) nil)",
        comptime macros.expandAndShow("(when (> 10 5) (+ 100 200))"),
    );
}

test "nested macros" {
    // (when (and (> 10 5) (< 3 7)) (+ 100 200))
    try testing.expectEqualStrings("300", comptime macros.expandAndEval(
        "(when (and (> 10 5) (< 3 7)) (+ 100 200))",
    ));
}

// ============================================================
// Bridge tests
// ============================================================

test "synthesize struct" {
    const User = comptime bridge.synthesizeType(lisp.read(
        "(struct (field name string) (field age int) (field active bool))",
    ));
    try testing.expectEqual(@as(usize, 3), @typeInfo(User).@"struct".fields.len);
}

test "synthesize enum" {
    const Color = comptime bridge.synthesizeType(lisp.read(
        "(enum red green blue)",
    ));
    const info = @typeInfo(Color).@"enum";
    try testing.expectEqual(@as(usize, 3), info.fields.len);
}

test "synthesize union" {
    const Shape = comptime bridge.synthesizeType(lisp.read(
        "(union (variant circle f64) (variant rect i64))",
    ));
    const info = @typeInfo(Shape).@"union";
    try testing.expectEqual(@as(usize, 2), info.fields.len);
}

test "synthesize array" {
    const Arr = comptime bridge.synthesizeType(lisp.read("(array 4 i32)"));
    try testing.expectEqual(@as(usize, 4), @typeInfo(Arr).array.len);
    try testing.expect(@typeInfo(Arr).array.child == i32);
}

test "synthesize optional" {
    const Opt = comptime bridge.synthesizeType(lisp.read("(optional int)"));
    try testing.expect(@typeInfo(Opt).optional.child == i64);
}

test "verify type assertions" {
    const User = comptime bridge.synthesizeType(lisp.read(
        "(struct (field name string) (field age int))",
    ));
    comptime bridge.verifyType(User, lisp.read(
        "((has name string) (has age int) (field-count 2))",
    ));
}

test "synthesize protocol" {
    const Msg = comptime bridge.synthesizeProtocol(lisp.read(
        "(protocol (message Ping (field seq int)) (message Pong (field seq int) (field data string)))",
    ));
    const info = @typeInfo(Msg).@"union";
    try testing.expectEqual(@as(usize, 2), info.fields.len);
}

test "effect set" {
    const Effects = comptime bridge.EffectSet(lisp.read("(:io :net :fs)"));
    try testing.expect(comptime bridge.hasEffect(Effects, ":io"));
    try testing.expect(comptime bridge.hasEffect(Effects, ":net"));
    try testing.expect(!comptime bridge.isPure(Effects));

    const After = comptime bridge.removeEffect(
        bridge.removeEffect(
            bridge.removeEffect(Effects, ":io"),
            ":net",
        ),
        ":fs",
    );
    try testing.expect(comptime bridge.isPure(After));
}

test "dependent type VecFromLisp" {
    const V = comptime bridge.VecFromLisp("(* 3 3)", "f64");
    try testing.expectEqual(@as(usize, 9), V.len);
    try testing.expect(V.ElemType == f64);
}

test "assertLisp" {
    comptime bridge.assertLisp("(= (+ 2 3) 5)");
    comptime bridge.assertLispEq("(* 6 7)", "42");
}
