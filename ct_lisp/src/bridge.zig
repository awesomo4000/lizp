const std = @import("std");
const lisp = @import("lisp.zig");
const Value = lisp.Value;

// ============================================================
// Lisp → Zig FFI Bridge
//
// Evaluate lisp expressions at comptime, use results to
// synthesize Zig types, structs, tagged unions, and dispatch
// tables. The lisp is the specification language. Zig is the
// target machine.
// ============================================================

// --- Type synthesis from s-expressions ---

pub fn synthesizeType(comptime spec: Value) type {
    if (spec == .symbol) {
        return primitiveType(spec.symbol);
    }
    if (spec == .cons) {
        const head = lisp.car(spec);
        if (head == .symbol) {
            const name = head.symbol;
            if (eql(name, "struct")) return synthesizeStruct(spec);
            if (eql(name, "union")) return synthesizeUnion(spec);
            if (eql(name, "enum")) return synthesizeEnum(spec);
            if (eql(name, "array")) return synthesizeArray(spec);
            if (eql(name, "optional")) return ?synthesizeType(lisp.cadr(spec));
            if (eql(name, "ptr")) return *const synthesizeType(lisp.cadr(spec));
        }
    }
    @compileError("cannot synthesize type from: " ++ lisp.printValue(spec));
}

pub fn primitiveType(comptime name: []const u8) type {
    if (eql(name, "int")) return i64;
    if (eql(name, "i8")) return i8;
    if (eql(name, "i16")) return i16;
    if (eql(name, "i32")) return i32;
    if (eql(name, "i64")) return i64;
    if (eql(name, "u8")) return u8;
    if (eql(name, "u16")) return u16;
    if (eql(name, "u32")) return u32;
    if (eql(name, "u64")) return u64;
    if (eql(name, "bool")) return bool;
    if (eql(name, "void")) return void;
    if (eql(name, "string")) return []const u8;
    if (eql(name, "f32")) return f32;
    if (eql(name, "f64")) return f64;
    @compileError("unknown primitive type: " ++ name);
}

fn synthesizeStruct(comptime spec: Value) type {
    const fields_list = lisp.cdr(spec);
    var field_count: usize = 0;

    var counter = fields_list;
    while (counter != .nil) : (counter = lisp.cdr(counter)) {
        field_count += 1;
    }

    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    var i: usize = 0;
    var cur = fields_list;
    while (cur != .nil) : ({
        cur = lisp.cdr(cur);
        i += 1;
    }) {
        const field_spec = lisp.car(cur);
        const fname = lisp.cadr(field_spec).symbol;
        const ftype_spec = lisp.car(lisp.cdr(lisp.cdr(field_spec)));
        field_names[i] = fname;
        field_types[i] = synthesizeType(ftype_spec);
        field_attrs[i] = .{ .@"align" = 1 };
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn synthesizeEnum(comptime spec: Value) type {
    const variants_list = lisp.cdr(spec);
    var count: usize = 0;

    var counter = variants_list;
    while (counter != .nil) : (counter = lisp.cdr(counter)) {
        count += 1;
    }

    const Tag = std.math.IntFittingRange(0, if (count == 0) 0 else count - 1);
    var field_names: [count][]const u8 = undefined;
    var field_values: [count]Tag = undefined;
    var i: usize = 0;
    var cur = variants_list;
    while (cur != .nil) : ({
        cur = lisp.cdr(cur);
        i += 1;
    }) {
        field_names[i] = lisp.car(cur).symbol;
        field_values[i] = @intCast(i);
    }

    return @Enum(Tag, .exhaustive, &field_names, &field_values);
}

fn synthesizeUnion(comptime spec: Value) type {
    const variants_list = lisp.cdr(spec);
    var count: usize = 0;

    var counter = variants_list;
    while (counter != .nil) : (counter = lisp.cdr(counter)) {
        count += 1;
    }

    var field_names: [count][]const u8 = undefined;
    var field_types: [count]type = undefined;
    var field_attrs: [count]std.builtin.Type.UnionField.Attributes = undefined;
    const TagInt = std.math.IntFittingRange(0, if (count == 0) 0 else count - 1);
    var tag_values: [count]TagInt = undefined;
    var i: usize = 0;
    var cur = variants_list;
    while (cur != .nil) : ({
        cur = lisp.cdr(cur);
        i += 1;
    }) {
        const variant = lisp.car(cur);
        field_names[i] = lisp.cadr(variant).symbol;
        field_types[i] = synthesizeType(lisp.car(lisp.cdr(lisp.cdr(variant))));
        field_attrs[i] = .{ .@"align" = 1 };
        tag_values[i] = @intCast(i);
    }

    const TagEnum = @Enum(TagInt, .exhaustive, &field_names, &tag_values);
    return @Union(.auto, TagEnum, &field_names, &field_types, &field_attrs);
}

fn synthesizeArray(comptime spec: Value) type {
    const size_val = lisp.cadr(spec);
    const elem_spec = lisp.car(lisp.cdr(lisp.cdr(spec)));
    const size: usize = @intCast(size_val.integer);
    return [size]synthesizeType(elem_spec);
}

// --- Verification / Assertions ---

pub fn verifyType(comptime T: type, comptime assertions: Value) void {
    var cur = assertions;
    while (cur != .nil) : (cur = lisp.cdr(cur)) {
        const assertion = lisp.car(cur);
        const verb = lisp.car(assertion).symbol;

        if (eql(verb, "has")) {
            const fname = lisp.cadr(assertion).symbol;
            const expected_type_name = lisp.car(lisp.cdr(lisp.cdr(assertion))).symbol;
            verifyHasField(T, fname, expected_type_name);
        } else if (eql(verb, "no-field")) {
            const fname = lisp.cadr(assertion).symbol;
            verifyNoField(T, fname);
        } else if (eql(verb, "field-count")) {
            const expected = lisp.cadr(assertion).integer;
            verifyFieldCount(T, @intCast(expected));
        } else {
            @compileError("unknown assertion: " ++ verb);
        }
    }
}

fn verifyHasField(comptime T: type, comptime name: []const u8, comptime expected_type: []const u8) void {
    const fields = @typeInfo(T).@"struct".fields;
    for (fields) |f| {
        if (eql(f.name, name)) {
            if (f.type != primitiveType(expected_type)) {
                @compileError("field '" ++ name ++ "' has wrong type");
            }
            return;
        }
    }
    @compileError("missing required field: " ++ name);
}

fn verifyNoField(comptime T: type, comptime name: []const u8) void {
    const fields = @typeInfo(T).@"struct".fields;
    for (fields) |f| {
        if (eql(f.name, name)) {
            @compileError("forbidden field present: " ++ name);
        }
    }
}

fn verifyFieldCount(comptime T: type, comptime expected: usize) void {
    const actual = @typeInfo(T).@"struct".fields.len;
    if (actual != expected) {
        @compileError("expected " ++ lisp.printValue(Value{ .integer = @intCast(expected) }) ++
            " fields, got " ++ lisp.printValue(Value{ .integer = @intCast(actual) }));
    }
}

// --- Protocol synthesis ---

pub fn synthesizeProtocol(comptime spec: Value) type {
    const messages = lisp.cdr(spec);
    var count: usize = 0;

    var counter = messages;
    while (counter != .nil) : (counter = lisp.cdr(counter)) {
        count += 1;
    }

    var field_names: [count][]const u8 = undefined;
    var field_types: [count]type = undefined;
    var field_attrs: [count]std.builtin.Type.UnionField.Attributes = undefined;
    const TagInt = std.math.IntFittingRange(0, if (count == 0) 0 else count - 1);
    var tag_values: [count]TagInt = undefined;

    var i: usize = 0;
    var cur = messages;
    while (cur != .nil) : ({
        cur = lisp.cdr(cur);
        i += 1;
    }) {
        const msg = lisp.car(cur);
        const msg_name = lisp.cadr(msg).symbol;
        const fields_list = lisp.cdr(lisp.cdr(msg));
        const struct_spec = Value{ .cons = .{
            .car = &Value{ .symbol = "struct" },
            .cdr = &fields_list,
        } };
        const MsgType = synthesizeType(struct_spec);

        field_names[i] = msg_name;
        field_types[i] = MsgType;
        field_attrs[i] = .{ .@"align" = 1 };
        tag_values[i] = @intCast(i);
    }

    const TagEnum = @Enum(TagInt, .exhaustive, &field_names, &tag_values);
    return @Union(.auto, TagEnum, &field_names, &field_types, &field_attrs);
}

// --- Effect tracking via phantom types ---

pub fn EffectSet(comptime effects: Value) type {
    var count: usize = 0;
    var counter = effects;
    while (counter != .nil) : (counter = lisp.cdr(counter)) {
        count += 1;
    }

    var field_names: [count][]const u8 = undefined;
    var field_types: [count]type = undefined;
    var field_attrs: [count]std.builtin.Type.StructField.Attributes = undefined;
    var i: usize = 0;
    var cur = effects;
    while (cur != .nil) : ({
        cur = lisp.cdr(cur);
        i += 1;
    }) {
        const eff_name = lisp.car(cur).symbol;
        field_names[i] = eff_name;
        field_types[i] = void;
        field_attrs[i] = .{ .@"align" = 1 };
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

pub fn hasEffect(comptime T: type, comptime name: []const u8) bool {
    const fields = @typeInfo(T).@"struct".fields;
    for (fields) |f| {
        if (eql(f.name, name)) return true;
    }
    return false;
}

pub fn removeEffect(comptime T: type, comptime name: []const u8) type {
    const fields = @typeInfo(T).@"struct".fields;
    var new_count: usize = 0;
    for (fields) |f| {
        if (!eql(f.name, name)) new_count += 1;
    }
    var field_names: [new_count][]const u8 = undefined;
    var field_types: [new_count]type = undefined;
    var field_attrs: [new_count]std.builtin.Type.StructField.Attributes = undefined;
    var j: usize = 0;
    for (fields) |f| {
        if (!eql(f.name, name)) {
            field_names[j] = f.name;
            field_types[j] = f.type;
            field_attrs[j] = .{
                .@"comptime" = f.is_comptime,
                .@"align" = f.alignment,
                .default_value_ptr = f.default_value_ptr,
            };
            j += 1;
        }
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

pub fn isPure(comptime T: type) bool {
    return @typeInfo(T).@"struct".fields.len == 0;
}

// --- Dependent type style: value-indexed types ---

pub fn Vec(comptime n: usize, comptime T: type) type {
    return struct {
        data: [n]T,
        pub const len = n;
        pub const ElemType = T;
    };
}

pub fn VecFromLisp(comptime size_expr: []const u8, comptime elem_type: []const u8) type {
    const size_val = lisp.run(size_expr);
    const n = parseComptimeInt(size_val);
    return Vec(n, primitiveType(elem_type));
}

fn parseComptimeInt(comptime s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') @compileError("not a number: " ++ s);
        n = n * 10 + (c - '0');
    }
    return n;
}

// --- Contract checking ---

pub fn assertLisp(comptime expr: []const u8) void {
    const result = lisp.run(expr);
    if (!eql(result, "true")) {
        @compileError("assertion failed: " ++ expr ++ " => " ++ result);
    }
}

pub fn assertLispEq(comptime expr: []const u8, comptime expected: []const u8) void {
    const result = lisp.run(expr);
    if (!eql(result, expected)) {
        @compileError("expected " ++ expected ++ ", got " ++ result ++ " from: " ++ expr);
    }
}

// --- Helpers ---

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
