# Lizp

Lizp is a small embeddable Lisp written in Zig 0.16. It is intended to live
inside a larger Zig program as a REPL, command layer, configuration language,
or scripting layer.

Lizp is a tree-walking interpreter rather than a bytecode VM. It combines:

- a Clojure-shaped reader and lowering pass;
- proper tail calls through a trampoline;
- lexical closures and host-provided native procedures;
- Poolside generational handles;
- an explicitly rooted evaluation nursery;
- detached capability-attenuated environments;
- a sans-I/O semantic observation spine;
- one report-based evaluation boundary.

The evaluator does not own stdin, stdout, files, sockets, clocks, or a process
loop. The included CLI is a separate host program that imports the same Lizp
module embedding applications use.

## The evaluation contract

Lizp 0.3.3 has one canonical evaluation entry point:

```zig
pub fn evaluate(
    runtime: *Runtime,
    request: EvaluationRequest,
) HostError!EvaluationReport;
```

A request can evaluate source, an already constructed form, or a call from Zig:

```zig
pub const EvaluationRequest = union(enum) {
    source: struct {
        bytes: []const u8,
        environment: ?EnvironmentRef = null,
        source_name: ?[]const u8 = null,
    },

    form: struct {
        value: Value,
        environment: ?EnvironmentRef = null,
    },

    call: struct {
        function: Value,
        arguments: []const Value,
    },
};
```

Ordinary Lisp outcomes are returned as data:

```zig
pub const EvaluationOutcome = union(enum) {
    returned: Value,
    condition: Condition,
    cancelled,
    paused,
};
```

For example:

```zig
const report = try runtime.evaluate(.{
    .source = .{ .bytes = "(+ 20 22)" },
});

switch (report.outcome) {
    .returned => |value| {
        std.debug.assert(runtime.asInteger(value).? == 42);
    },

    .condition => |condition| {
        std.debug.print(
            "{s}/{s}: {s}\n",
            .{
                @tagName(condition.phase),
                @tagName(condition.code),
                condition.message(),
            },
        );
    },

    .cancelled => {},
    .paused => {},
}
```

Invalid syntax, an invalid expansion, an undefined symbol, a type mismatch,
division by zero, and a native-domain rejection are conditions. They are not
translated into Zig errors.

The Zig error channel is deliberately narrow:

```zig
pub const HostError = std.mem.Allocator.Error || error{
    OutOfCapacity,
    NativeHostFailure,
    RuntimeBusy,
    RuntimeInvariantFailure,
};
```

A host error means Lizp could not reliably complete the host/runtime contract,
not that the submitted Lisp program was wrong. After every ordinary condition,
cancellation, or pause, the runtime is coherent and may immediately evaluate
another request. Allocation-failure paths are also tested for runtime reuse once
memory is available again.

## Structured conditions

Conditions are allocation-independent fixed-size values containing:

```text
condition ID
condition code
phase: read / expand / evaluate / native / runtime
logical observation context
immutable source byte span
optional lowering/expansion origin
inline diagnostic message
```

The fixed inline message means malformed Lisp can still be described without
allocating diagnostic storage. Read, expansion, evaluation, and native-domain
conditions retain the source occurrence active when the condition arose.

A condition is not an ordinary Lisp `Value`. It is an ordinary host-facing
evaluation outcome. A future Lisp condition/handler facility may deliberately
turn conditions into language data, but accidental error-shaped return values
are not confused with failed evaluation.

## Source identity and expansion provenance

Every source request is copied into an immutable runtime-owned source record.
The returned `EvaluationReport.source` identifies that exact revision; changing
the caller's original buffer cannot change later diagnostics.

The reader assigns a byte span to every executable syntax occurrence. Runtime
values remain ordinary Lizp values, while internal syntax wrappers carry:

```text
source ID
start byte offset
exclusive end byte offset
optional expansion-origin ID
```

The host can inspect those facts without any I/O policy in the core:

```zig
const source_view = runtime.sourceView(span.source).?;
const excerpt = runtime.sourceExcerpt(span).?;
const location = runtime.sourceLocation(span).?;

// Locations use one-based lines and byte columns.
```

Clojure-shaped lowering records an origin chain. For example, an invalid
`recur` can point at the exact `recur` form while its origin identifies the
`recur` lowering step and its parent identifies the enclosing `loop` lowering
step. Generated core forms inherit the surface form's span; original child
forms retain their own precise locations.

Source records and expansion-origin records currently live for the lifetime of
the `Runtime`. This gives reports, definitions, and retained syntax stable
identities; later session/history policy can decide when old source revisions
may be released.

## What works

Values:

- integers, booleans, symbols, strings, pairs, proper and dotted lists;
- evaluated immutable flat vectors;
- lexical closures and registered native Zig procedures.

Clojure-shaped surface forms:

- `def`, `defn`, `fn`, `do`;
- vector-binding `let`;
- `loop` and checked `recur`;
- vector parameter lists and `&` rest parameters;
- commas as optional whitespace.

Original small-Lisp forms remain available:

- `quote`, `if`, `begin`, `define`, `set!`, `lambda`;
- list-binding `let`, `while`, `and`, and `or`.

Core procedures include arithmetic and comparisons, `cons`, `car`, `cdr`,
`list`, `length`, `eq?`, predicates, and `vector`, `vector?`, `count`, and
`nth`.

## Proper tail calls without a VM

```clojure
(defn sum-to [n]
  (loop [i n
         total 0]
    (if (= i 0)
      total
      (recur (- i 1)
             (+ total i)))))

(sum-to 100000)
```

This returns:

```text
5000050000
```

It does not grow the Zig call stack, and obsolete call environments are
reclaimed while it runs.

Ordinary tail calls are optimized too:

```clojure
(defn even? [n]
  (if (= n 0)
    true
    (odd? (- n 1))))

(defn odd? [n]
  (if (= n 0)
    false
    (even? (- n 1))))

(even? 100000)
```

The evaluator returns either a completed value or a new `(form, environment)`
tail target. Tail-position branches, final sequence forms, closure bodies,
`let` bodies, and ordinary tail calls become another iteration of one Zig loop.

`loop`/`recur` lowers to a hidden local recursive function. Expansion verifies
that `recur`:

- has an enclosing fixed-arity recursion point;
- occurs in tail position;
- supplies the correct number of arguments.

All forms in one source request are read and expanded before the first is
evaluated. An invalid later expansion cannot leave an earlier definition
committed.

## Native Zig procedures

Native callbacks make the same distinction as the evaluator:

```zig
pub const NativeOutcome = union(enum) {
    returned: Value,
    condition: ConditionSpec,
};

pub const NativeFn = *const fn (
    context: ?*anyopaque,
    runtime: *Runtime,
    args: []const Value,
) HostError!NativeOutcome;
```

Example:

```zig
const Host = struct {
    offset: i64,
};

fn hostAdd(
    context: ?*anyopaque,
    runtime: *lizp.Runtime,
    args: []const lizp.Value,
) lizp.HostError!lizp.NativeOutcome {
    if (args.len != 1) {
        return .{ .condition = .{
            .code = .arity_mismatch,
            .message = "host-add expects one argument",
        } };
    }

    const input = runtime.asInteger(args[0]) orelse {
        return .{ .condition = .{
            .code = .type_mismatch,
            .message = "host-add expects an integer",
        } };
    };

    const host: *Host = @ptrCast(@alignCast(context.?));
    const result = std.math.add(i64, input, host.offset) catch {
        return .{ .condition = .{
            .code = .integer_overflow,
            .message = "integer overflow in host-add",
        } };
    };

    return .{ .returned = .{ .integer = result } };
}
```

A callback returns a condition for a normal rejected operation. It returns
`error.NativeHostFailure` only when trusted native machinery cannot maintain its
host contract.

Native callbacks are trusted code and can do anything the containing process can
do. Attenuated environments decide whether Lisp can resolve a native value;
they do not sandbox the callback implementation.

## Calling Lisp from Zig

```zig
_ = switch ((try runtime.evaluate(.{
    .source = .{ .bytes = "(defn triple [x] (* x 3))" },
})).outcome) {
    .returned => |value| value,
    else => return error.UnexpectedEvaluationOutcome,
};

const triple = runtime.getGlobal("triple").?;
const report = try runtime.evaluate(.{
    .call = .{
        .function = triple,
        .arguments = &.{.{ .integer = 14 }},
    },
});

const result = switch (report.outcome) {
    .returned => |value| value,
    else => return error.UnexpectedEvaluationOutcome,
};
std.debug.assert(runtime.asInteger(result).? == 42);
```

`asString`, `asSymbolName`, `asPair`, `asVector`, and `copyList` provide
borrowed or explicitly copied host views.

## Capability-attenuated environments

The host can create a detached environment containing selected bindings:

```zig
const environment = try runtime.createCapabilityEnvironment(.{
    .allow = &.{
        "+",
        "list",
        "read-setting",
    },
    .language = .attenuated,
});

const report = try runtime.evaluate(.{
    .source = .{
        .bytes = "(list (+ 20 22) (read-setting \"theme\"))",
        .environment = environment,
    },
});
```

The environment has no parent link to the unrestricted global environment.
Missing names cannot fall through to ambient globals, and globals registered
later do not appear automatically.

A closure is itself a capability. If the host grants one, it retains the
lexical implementation authority it captured. That is intentional. Native
callbacks likewise remain trusted native code.

For a REPL, the usual arrangement is:

```text
detached host-selected base environment
                ↑ parent
private mutable REPL session environment
```

The base contains granted operations. The child contains the session’s
`def`/`defn` values and recursive functions.

Special forms are controlled separately through `LanguagePolicy` because they
are syntax, not bindings:

- `.attenuated` disables `set!` and `while` but permits local definitions;
- `.expression_only` additionally disables `define`, `def`, and `defn`.

Removing a binding prevents future lookup by that name. It does not revoke an
alias already saved by Lisp. Hard revocation belongs inside a native wrapper,
for example by checking a Poolside generational capability handle on each call.

## Sans-I/O observation spine

An optional observer receives structured semantic facts. The core does not
format, store, or transport them:

```zig
const Journal = lizp.FixedEventJournal(256);
var journal = Journal{};

var runtime = try lizp.Runtime.initWithOptions(allocator, .{
    .observer = journal.observer(lizp.EventMask.standard()),
});
defer runtime.deinit();

const report = try runtime.evaluate(.{
    .source = .{ .bytes = "(do (defn inc [x] (+ x 1)) (inc 41))" },
});

for (0..journal.count()) |index| {
    const event = journal.at(index).?;
    _ = event;
}
```

The standard event stream includes:

- evaluation start and finish;
- closure entry, return, and tail-call replacement;
- native callback entry and return;
- structured condition occurrence;
- nursery and full-GC start/finish statistics;
- committed Lisp definitions.

Per-object allocation and reclamation are opt-in because they can be high
volume.

Every event carries a lane-local event ID, evaluation ID, logical context ID,
causal predecessor, optional source span, and optional expansion-origin ID.
Call, native, condition, definition, and tail-transfer events can therefore be
correlated with the exact source form that caused them. Tail recursion
replaces its logical call context rather than growing a fake debugger stack.
Native callbacks can use `observationEvaluation()`, `observationContext()`, and
`observationEvent()` to correlate host work with the Lisp operation that caused
it.

Evaluation finish status distinguishes:

```text
returned
condition
cancelled
paused
host_failure
```

A condition event and the final condition report carry the same condition ID.
A host failure produces `host_failure` without manufacturing a Lisp condition.

`FixedEventJournal(N)` is a no-allocation ring buffer. Debuggers, profilers,
agent protocols, heap views, and concurrency analyzers can remain libraries over
the same event contract.

Observers may request `continue_`, `cancel`, or `pause` at semantic safe points.
`pause` is currently a terminal evaluation outcome, not yet a resumable
suspension. Observer callbacks are synchronous and must not re-enter the runtime.

## Memory and collection

Heap references are checked Poolside generational handles. A stale reference
fails validation rather than aliasing a later object that reused the same slot.

### Evaluation nursery

Objects created while source is read, expanded, and evaluated are recorded in
an evaluation allocation set. At configurable tail-call safe points Lizp marks
from:

- the global environment;
- every active evaluator form and environment;
- partially evaluated function arguments and vector elements;
- current `let` values and imperative-loop results.

It destroys only unreachable objects born in the current evaluation.
Pre-existing heap values are never swept implicitly, so an ordinary host-held
`Value` cannot disappear merely because a script made a tail call.

```zig
var runtime = try lizp.Runtime.initWithOptions(allocator, .{
    .max_eval_depth = 256,
    .evaluation_gc_interval = 128,
});
```

An interval of zero disables mid-evaluation nursery passes. A final nursery pass
still runs when the outer source evaluation returns.

### Explicit full collection

The host can collect the complete heap between evaluations:

```zig
const reclaimed = try runtime.collectGarbage(&.{host_held_value});
```

Detached environments retained by the host must be explicit roots:

```zig
_ = try runtime.collectGarbageWithRoots(.{
    .values = &.{host_held_value},
    .environments = &.{session_environment},
});
```

Full collection during evaluation is rejected. Observation and inspection do
not implicitly retain heap values; a future debugger pin API will make retention
explicit.

## Build and run

Poolside is vendored, so the source tree builds without fetching dependencies.

```sh
zig build
zig build test
zig build run
zig build run -- -e '(do (defn square [x] (* x x)) (square 12))'
zig build run -- examples/tco.lizp
zig build embed-example
zig build capability-example
zig build observe-example
```

The CLI supports files, `-e`, multiline input, `:gc`, `:help`, and `:quit`. It
installs its own host-provided `(print ...)` procedure. The evaluator core has no
stdout or filesystem authority.

## Clojure-shaped, not Clojure-compatible

Lizp borrows useful structural ideas from Clojure; it is not an implementation
of Clojure.

Current differences and omissions include:

- `()` and `nil` are the same empty-list value;
- no maps, sets, keywords, metadata, namespaces, Vars, multimethods, or STM;
- no user-defined macro system or syntax quote yet;
- no destructuring or multi-arity functions yet;
- vectors are immutable flat arrays rather than persistent tree structures;
- non-tail recursion still uses recursive Zig evaluator calls and is bounded by
  `max_eval_depth`;
- no evaluation fuel counter or hard per-session heap quota yet;
- pause is not yet resumable;
- source revisions and expansion origins are retained until runtime teardown;
- no postmortem frame/local-variable retention or source-level breakpoints yet.

The lowering boundary is intentional. Forms such as `when`, `cond`, `->`,
`->>`, destructuring, and eventually macros can be added without enlarging the
small evaluator core.
