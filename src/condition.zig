//! Structured, allocation-free evaluation conditions.
//!
//! Conditions are ordinary evaluation outcomes, not Zig errors. The fixed
//! inline message keeps reporting available even when the runtime cannot
//! allocate additional diagnostic storage.

const std = @import("std");
const source = @import("source.zig");

pub const Id = enum(u64) {
    none = 0,
    _,
};

pub const Phase = enum {
    read,
    expand,
    evaluate,
    native,
    runtime,
};

pub const Code = enum {
    unexpected_end_of_input,
    unexpected_token,
    unterminated_string,
    invalid_escape,
    invalid_number,
    improper_list,
    invalid_syntax,
    undefined_symbol,
    type_mismatch,
    arity_mismatch,
    not_callable,
    stale_object,
    division_by_zero,
    integer_overflow,
    index_out_of_bounds,
    eval_depth_exceeded,
    expansion_depth_exceeded,
    collection_during_evaluation,
    forbidden_special_form,
    unsafe_capability_grant,
    core_not_installed,
    too_many_symbols,
    too_many_natives,
    native_condition,
    resource_exhausted,
    internal,
};

pub const message_capacity = 256;

pub const Condition = struct {
    id: Id,
    code: Code,
    phase: Phase,
    context: u64,
    span: ?source.Span = null,
    origin: ?source.OriginId = null,
    message_len: u16,
    message_bytes: [message_capacity]u8,

    pub fn initFormat(
        id: Id,
        code: Code,
        phase: Phase,
        context: u64,
        span: ?source.Span,
        origin: ?source.OriginId,
        comptime format: []const u8,
        args: anytype,
    ) Condition {
        var result = Condition{
            .id = id,
            .code = code,
            .phase = phase,
            .context = context,
            .span = span,
            .origin = origin,
            .message_len = 0,
            .message_bytes = undefined,
        };
        const rendered = std.fmt.bufPrint(&result.message_bytes, format, args) catch {
            const fallback = "condition message exceeded inline capacity";
            @memcpy(result.message_bytes[0..fallback.len], fallback);
            result.message_len = fallback.len;
            return result;
        };
        result.message_len = @intCast(rendered.len);
        return result;
    }

    pub fn initMessage(
        id: Id,
        code: Code,
        phase: Phase,
        context: u64,
        span: ?source.Span,
        origin: ?source.OriginId,
        source_message: []const u8,
    ) Condition {
        var result = Condition{
            .id = id,
            .code = code,
            .phase = phase,
            .context = context,
            .span = span,
            .origin = origin,
            .message_len = 0,
            .message_bytes = undefined,
        };
        const length = @min(source_message.len, result.message_bytes.len);
        @memcpy(result.message_bytes[0..length], source_message[0..length]);
        result.message_len = @intCast(length);
        return result;
    }

    pub fn message(self: *const Condition) []const u8 {
        return self.message_bytes[0..self.message_len];
    }
};

pub const Spec = struct {
    code: Code = .native_condition,
    message: []const u8,
};

test "conditions format without allocation" {
    const testing = std.testing;
    const value = Condition.initFormat(
        @enumFromInt(1),
        .type_mismatch,
        .evaluate,
        7,
        null,
        null,
        "expected {s}, got {s}",
        .{ "integer", "string" },
    );
    try testing.expectEqualStrings("expected integer, got string", value.message());
}
