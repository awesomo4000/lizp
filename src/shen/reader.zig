const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;
const Vm = types.Vm;

// ============================================================
// Kλ S-Expression Reader
//
// Parses Kλ source text into Value trees.
// Kλ is simpler than full Shen — no reader macros, no
// backquote. Just atoms, lists, and strings.
// ============================================================

pub const Reader = struct {
    input: []const u8,
    pos: usize,
    vm: *Vm,

    pub fn init(input: []const u8, vm: *Vm) Reader {
        return .{
            .input = input,
            .pos = 0,
            .vm = vm,
        };
    }

    pub const ReadError = error{
        EndOfInput,
        UnexpectedClose,
        UnterminatedList,
        UnterminatedString,
        EmptyAtom,
        OutOfMemory,
    };

    pub fn read(self: *Reader) ReadError!Value {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.EndOfInput;

        return switch (self.input[self.pos]) {
            '(' => self.readList(),
            ')' => error.UnexpectedClose,
            '"' => self.readString(),
            else => self.readAtom(),
        };
    }

    /// Read all top-level expressions from input
    pub fn readAll(self: *Reader) ![]Value {
        var exprs = std.ArrayListUnmanaged(Value){};
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) break;
            const expr = try self.read();
            try exprs.append(self.vm.allocator, expr);
        }
        return exprs.toOwnedSlice(self.vm.allocator);
    }

    fn readList(self: *Reader) ReadError!Value {
        self.pos += 1; // skip (
        var items = std.ArrayListUnmanaged(Value){};

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnterminatedList;
            if (self.input[self.pos] == ')') {
                self.pos += 1;
                // Build cons list from items
                var result: Value = .nil;
                var i = items.items.len;
                while (i > 0) {
                    i -= 1;
                    result = try self.vm.makeCons(items.items[i], result);
                }
                items.deinit(self.vm.allocator);
                return result;
            }
            const val = try self.read();
            try items.append(self.vm.allocator, val);
        }
    }

    fn readString(self: *Reader) !Value {
        self.pos += 1; // skip opening "
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '"') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return error.UnterminatedString;
        const s = self.input[start..self.pos];
        self.pos += 1; // skip closing "
        return self.vm.makeString(s);
    }

    fn readAtom(self: *Reader) !Value {
        const start = self.pos;
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r', '(', ')' => break,
                else => self.pos += 1,
            }
        }
        const token = self.input[start..self.pos];
        if (token.len == 0) return error.EmptyAtom;

        // Booleans
        if (std.mem.eql(u8, token, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, token, "false")) return Value{ .boolean = false };

        // Try integer
        if (parseInt(token)) |n| return Value{ .integer = n };

        // Try float
        if (parseFloat(token)) |f| return Value{ .float = f };

        // Symbol
        return self.vm.internSym(token);
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '\\' => {
                    // Kλ uses \* ... *\ for comments
                    if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '*') {
                        self.pos += 2;
                        while (self.pos + 1 < self.input.len) {
                            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '\\') {
                                self.pos += 2;
                                break;
                            }
                            self.pos += 1;
                        }
                    } else break;
                },
                else => break,
            }
        }
    }
};

fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        if (s.len == 1) return null;
        neg = true;
        i = 1;
    } else if (s[0] == '+') {
        if (s.len == 1) return null;
        i = 1;
    }
    var n: i64 = 0;
    var any_digit = false;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        any_digit = true;
        n = n * 10 + @as(i64, s[i] - '0');
    }
    if (!any_digit) return null;
    return if (neg) -n else n;
}

fn parseFloat(s: []const u8) ?f64 {
    // Must contain a dot to be a float
    var has_dot = false;
    for (s) |c| {
        if (c == '.') {
            has_dot = true;
            break;
        }
    }
    if (!has_dot) return null;

    return std.fmt.parseFloat(f64, s) catch null;
}
