#!/bin/bash
# Shen kernel correctness tests and benchmarks
# Usage: ./test-shen.sh [--bench]
set -e

SHEN=zig-out/bin/shen
KL=src/shen/kl
PASS=0
FAIL=0
ERRORS=""

# Build ReleaseFast if --bench, else default
if [ "$1" = "--bench" ]; then
    echo "Building ReleaseFast..."
    PATH="$PATH:$HOME/.zvm/bin:$HOME/.zvm/self/" zig build shen -Doptimize=ReleaseFast 2>/dev/null
else
    echo "Building..."
    PATH="$PATH:$HOME/.zvm/bin:$HOME/.zvm/self/" zig build shen 2>/dev/null
fi

run_eval() {
    local desc="$1" input="$2" expected="$3"
    result=$(printf '%b\nquit\n' "$input" | timeout 15 $SHEN boot $KL 2>&1 | grep 'shen>> .' | tail -1 | sed 's/shen>> //')
    if [ "$result" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS="$ERRORS\n  FAIL: $desc\n    expected: $expected\n    got:      $result"
    fi
}

echo ""
echo "=== Shen Kernel Tests ==="
echo ""

# --- Arithmetic ---
run_eval "integer add"        "(+ 1 2)"           "3"
run_eval "integer sub"        "(- 10 3)"          "7"
run_eval "integer mul"        "(* 6 7)"           "42"
run_eval "integer div"        "(/ 10 2)"          "5"
run_eval "float div"          "(/ 1 3)"           "0.3333333333333333"
run_eval "comparison >"       "(> 3 2)"           "true"
run_eval "comparison <"       "(< 3 2)"           "false"

# --- Lists ---
run_eval "cons"               "(cons 1 ())"       "(1)"
run_eval "hd"                 "(hd (cons 1 (cons 2 ())))" "1"
run_eval "tl"                 "(tl (cons 1 (cons 2 ())))" "(2)"
run_eval "cons?"              "(cons? (cons 1 ()))" "true"
run_eval "list syntax"        "[1 2 3]"           "(1 2 3)"
run_eval "list bar"           "[1 | [2 3]]"       "(1 2 3)"

# --- Strings ---
run_eval "string concat"      '(cn "hello" " world")' '"hello world"'
run_eval "string?"            '(string? "hi")'    "true"
run_eval "pos"                '(pos "hello" 1)'   '"e"'
run_eval "tlstr"              '(tlstr "hello")'   '"ello"'

# --- Symbols & globals ---
run_eval "symbol self-eval"   "hello"             "hello"
run_eval "set/value"          "(set *x* 42)\n(value *x*)" "42"
run_eval "intern"             '(intern "hello")'  "hello"

# --- Functions ---
run_eval "defun + call"       "(defun sq (x) (* x x))\n(sq 7)" "49"
run_eval "lambda"             "((lambda x (+ x 1)) 5)" "6"
run_eval "partial apply"      "(let F ((lambda x (+ x)) 1) (F 2))" "3"
run_eval "higher order"       "((lambda F (F 3)) (lambda X (* X X)))" "9"

# --- Control flow ---
run_eval "if true"            "(if true 1 2)"     "1"
run_eval "if false"           "(if false 1 2)"    "2"
run_eval "cond"               "(cond ((= 1 2) no) (true yes))" "yes"
run_eval "and short-circuit"  "(and false (/ 1 0))" "false"
run_eval "or short-circuit"   "(or true (/ 1 0))" "true"
run_eval "trap-error"         "(trap-error (/ 1 0) (lambda E caught))" "caught"

# --- Shen features (via Shen eval) ---
run_eval "define"             "(define double X -> (+ X X))\n(double 21)" "42"
run_eval "define pattern"     "(define fact 0 -> 1 N -> (* N (fact (- N 1))))\n(fact 10)" "3628800"
run_eval "declare"            "(define sq X -> (* X X))\n(declare sq (number --> number))" "sq"
run_eval "tc+"                "(tc +)\n(+ 1 2)" "3"

# --- Type checker ---
run_eval "typecheck number"   "(shen.typecheck 42 number)" "number"
run_eval "typecheck string"   '(shen.typecheck "hi" string)' "string"
run_eval "typecheck bool"     "(shen.typecheck true boolean)" "boolean"
run_eval "typecheck list"     "(shen.typecheck (cons 1 ()) (list number))" "(list number)"
run_eval "typecheck lambda"   "(shen.typecheck (lambda x (+ x 1)) (number --> number))" "(number --> number)"
run_eval "typecheck tuple"    '(shen.typecheck (@p 1 "hi") (number * string))' "(number * string)"
run_eval "typecheck reject"   '(shen.typecheck 42 string)' "false"

# --- Datatype ---
run_eval "datatype define"    "(datatype mynum X : number; ________ X : mynum;)" "mynum#type"
run_eval "datatype check"     "(datatype mynum2 X : number; ________ X : mynum2;)\n(shen.typecheck 42 mynum2)" "mynum2"
run_eval "datatype reject"    '(datatype mynum3 X : number; ________ X : mynum3;)\n(shen.typecheck "no" mynum3)' "false"

# --- Prolog ---
# Einstein needs test files and fn/defcc fix
# if [ -f src/shen/tests/einsteins-riddle.shen ]; then
#     run_eval "einstein" "(load \"src/shen/tests/einsteins-riddle.shen\")\n(prolog? (riddle))" "german"
# fi

echo ""
echo "=== Results ==="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ $FAIL -gt 0 ]; then
    printf "$ERRORS\n"
fi

# --- Benchmarks ---
if [ "$1" = "--bench" ]; then
    echo ""
    echo "=== Benchmarks ==="
    echo ""

    # Boot time via hyperfine (proper statistical measurement)
    hyperfine --warmup 1 --runs 5 \
        "printf 'quit\n' | $SHEN boot $KL 2>/dev/null"

    # RSS
    echo -n "Boot RSS:      "
    /usr/bin/time -f '%M KB' sh -c "printf 'quit\n' | $SHEN boot $KL 2>/dev/null" 2>&1 | tail -1

    # Compute benchmarks: individual runs with timeout, Shen-level CPU timing
    echo ""
    echo "--- Compute (CPU time via get-time) ---"

    run_bench() {
        local name="$1" setup="$2" expr="$3"
        local result
        result=$(printf '%s\n%s\nquit\n' "$setup" \
            "(let T0 (get-time run) _ $expr T1 (get-time run) (cn \"BENCH \" (str (- T1 T0))))" \
            | timeout 30 $SHEN boot $KL 2>/dev/null | grep '^shen>> BENCH' | sed 's/^shen>> BENCH //')
        if [ -n "$result" ]; then
            printf '  %-14s %ss\n' "$name" "$result"
        else
            printf '  %-14s TIMEOUT\n' "$name"
        fi
    }

    run_bench "fib(25)" \
        "(define fib 0 -> 0 1 -> 1 N -> (+ (fib (- N 1)) (fib (- N 2))))" \
        "(fib 25)"

    run_bench "append 10k" \
        "(define range-h 0 Acc -> Acc N Acc -> (range-h (- N 1) (cons N Acc)))
(define range N -> (range-h N []))" \
        "(length (append (range 5000) (range 5000)))"

    run_bench "typecheck" \
        "" \
        "(shen.typecheck (lambda x (+ x 1)) (number --> number))"

    echo ""
fi

exit $FAIL
