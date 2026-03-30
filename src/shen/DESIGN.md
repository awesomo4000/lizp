# Shen Kλ Kernel in Zig

## Goal

Implement the Shen Kλ kernel in Zig so we can bootstrap the full Shen
language — including its sequent calculus type system and Prolog engine —
on top of our Zig runtime.

## Why

Shen's type system is programmable via sequent calculus. Type checking
rules are defined in the language itself and compile to Prolog. This
gives us dependent types, refinement types, effect tracking — whatever
we define — checked at the source level. Combined with lizp's comptime
compilation and mitolisp's runtime, we get a verified lisp stack.

## Architecture

```
shen standard library (shen source, ~15K lines)
    |
    | loaded as Kλ s-expressions
    v
prolog engine (shen source, bootstraps on kernel)
    |
    v
sequent calculus type checker (shen source)
    |
    v
Kλ kernel (THIS — Zig, ~2000 lines target)
    |
    v
Zig runtime (allocator, values, eval loop)
```

We implement the bottom. Everything above loads as Shen/Kλ source.

## Kλ Primitives (57 total)

### Special Forms (not functions — eval handles these directly)
- `defun` — global function definition
- `lambda` — anonymous function (single param)
- `let` — local binding
- `if` — conditional
- `and` — short-circuit and
- `or` — short-circuit or
- `cond` — multi-branch conditional
- `freeze` — thunk (zero-arg lambda)
- `trap-error` — exception handling

### Functions

**Symbols (3)**: `intern`, `set`, `value`
**Errors (2)**: `simple-error`, `error-to-string`
**Equality (1)**: `=`
**Eval (1)**: `eval-kl`
**Type hint (1)**: `type`

**Numbers (8)**: `number?`, `+`, `-`, `*`, `/`, `>`, `<`, `>=`, `<=`
**Strings (7)**: `string?`, `pos`, `tlstr`, `cn`, `str`, `string->n`, `n->string`
**Cons (4)**: `cons?`, `cons`, `hd`, `tl`
**Vectors (3)**: `absvector`, `address->`, `<-address`
**Streams (4)**: `write-byte`, `read-byte`, `open`, `close`
**Time (1)**: `get-time`

**Globals (8)**: `*stinput*`, `*stoutput*`, `*language*`, `*implementation*`,
`*release*`, `*os*`, `*port*`, `*porters*`

## Implementation Plan

### Phase 1: Value types and environment
- Value tagged union: nil, boolean, integer (i64), float (f64), string,
  symbol, cons, vector, closure, native-fn, stream, error
- Number promotion: int op int → int, mixed → float,
  int / int → int if divisible else float (matches shen-c)
- Symbol interning (reuse pattern from mitolisp)
- Environment: global symbol table + lexical scope chain
- Arena allocator

### Phase 2: Reader
- S-expression reader for Kλ source
- Simpler than full Shen reader — Kλ is a simplified subset

### Phase 3: Eval loop
- Special forms: defun, lambda, let, if, and, or, cond, freeze, trap-error
- Function application with tail call optimization
- Partial application / currying

### Phase 4: Primitives
- All 46 primitive functions
- Stream I/O (file + stdin/stdout)

### Phase 5: Bootstrap
- Load Kλ source files from Shen distribution
- The Shen type checker, prolog engine, and standard library boot themselves

### Phase 6: Integration
- Wire into lizp's build system
- `zig build shen` to build the Shen binary
- `zig build test-shen` to run Shen's test suite

## Key Design Decisions

**Tail call optimization**: mandatory. Shen relies on it heavily.
Without TCO the bootstrap will stack overflow.

**Currying**: every function is curried. `(+ 1)` returns a partial
application. "Currying on demand" — don't pre-curry, curry at the
call site when too few args are provided.

**Symbols**: interned. Symbol comparison is integer comparison.

**Vectors**: mutable fixed-size arrays. This is Shen's only mutable
data structure. Everything else is immutable.

**Error handling**: trap-error/simple-error. Maps to Zig's error
handling or a caught-exception pattern in the eval loop.

## References

- Kλ spec: https://github.com/Shen-Language/wiki/wiki/KLambda
- Porting guide: https://github.com/Shen-Language/shen-sources/blob/master/doc/porting.md
- Shen sources: https://github.com/Shen-Language/shen-sources
- Shen license: BSD
