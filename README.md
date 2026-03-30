# lizp

A lisp that runs entirely inside Zig's comptime evaluator. S-expressions go in at build time, native code comes out. No runtime interpreter.

> Lisp turtles all the way down until there's a ziguana.

## What it does

**Comptime evaluation** — evaluate lisp expressions during compilation:

```zig
const lizp = @import("lizp");

// Evaluated at build time, result is a comptime string
const answer = lizp.run("(+ 1 2)"); // "3"
```

**Native function compilation** — compile lisp expressions into real Zig function pointers:

```zig
const square = lizp.Fn1("(* x x)", "x");
// square is fn(i64) i64 — a real native function, no interpretation

square(7) // 49
```

The lisp doesn't exist in the final binary. It runs during `zig build`, generates native code, and vanishes.

## Language

The interpreter supports:

- S-expression reader: `()` `[]` `{}`, comments `;`, quote `'`
- Values: integers, booleans, symbols, keywords, cons cells, closures, nil
- Special forms: `quote`, `if`, `do`, `fn`, `let`
- Builtins: `+ - * / mod = < > cons car cdr list nil? not`
- Closures with lexical capture
- Recursion via self-passing (U-combinator)
- Multi-expression programs via `runProgram` (with `def` and `defn`)

The compiler supports a subset for native codegen:

- Integer constants, variable references
- Arithmetic: `+ - * / mod`
- Comparisons: `= < > <= >=`
- Conditionals: `if`
- Let bindings, `do` blocks
- Recursive functions via struct wrapper: `RecFn1`, `RecFn2`
- Type-safe wrappers: `Fn1`, `Fn2`, `Fn3`

## Build

Requires Zig 0.15.2.

```bash
zig build run    # build and run the example
zig build test   # run tests
```

## Usage as a module

```zig
const lizp = @import("lizp");

// Comptime eval
const result = lizp.run("(let [x 10 y 20] (+ x y))"); // "30"

// Multi-expression programs with def/defn
const result2 = lizp.runProgram(
    \\(def base 100)
    \\(defn add-to-base [x] (+ base x))
    \\(add-to-base 10)
); // "110"

// Compile to native
const abs_ = lizp.Fn1("(if (< x 0) (- 0 x) x)", "x");
const diff_sq = lizp.Fn2("(* (+ a b) (- a b))", "a", "b");

// Recursive native functions
const factorial = lizp.RecFn1(
    "(if (= n 0) 1 (* n (self (- n 1))))",
    "self", "n",
);
factorial(12) // 479001600 — pure machine code, no interpreter
```
