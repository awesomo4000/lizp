const std = @import("std");
const types = @import("types.zig");
const reader_mod = @import("reader.zig");
const eval_mod = @import("eval.zig");
const printer_mod = @import("printer.zig");
const primitives = @import("primitives.zig");
const Value = types.Value;
const Vm = types.Vm;
const Env = types.Env;
const Reader = reader_mod.Reader;

fn stdout() std.fs.File {
    return std.fs.File.stdout();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var vm = try Vm.init(allocator);
    defer vm.deinit();

    try primitives.registerPrimitives(&vm);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "eval")) {
        if (args.len < 3) {
            std.debug.print("Usage: shen eval '<expression>'\n", .{});
            return;
        }
        try evalString(args[2], &vm);
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            std.debug.print("Usage: shen run <file.kl>\n", .{});
            return;
        }
        try runFile(args[2], &vm);
    } else if (std.mem.eql(u8, cmd, "boot")) {
        const kl_dir = if (args.len >= 3) args[2] else "src/shen/kl";
        try boot(kl_dir, &vm);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        try repl(&vm);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\shen-zig: Shen Kλ kernel
        \\
        \\Usage:
        \\  shen eval '<expression>'    Evaluate a Kλ expression
        \\  shen run <file.kl>          Load and evaluate a Kλ file
        \\  shen boot [kl-dir]          Bootstrap Shen from KL files
        \\  shen repl                   Interactive REPL
        \\
    , .{});
}

fn evalString(input: []const u8, vm: *Vm) !void {
    var env = Env.init(null);
    var rd = Reader.init(input, vm);
    const exprs = rd.readAll() catch |err| {
        std.debug.print("read error: {s}\n", .{@errorName(err)});
        return;
    };

    var result: Value = .nil;
    for (exprs) |expr| {
        result = eval_mod.eval(expr, &env, vm) catch |err| {
            std.debug.print("eval error: {s}\n", .{@errorName(err)});
            return;
        };
    }

    const s = try printer_mod.valueToString(vm, result);
    std.debug.print("{s}\n", .{s});
}

fn runFile(path: []const u8, vm: *Vm) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(vm.allocator, 10 * 1024 * 1024);
    try evalString(content, vm);
}

const boot_order = [_][]const u8{
    "init.kl",
    "toplevel.kl",
    "core.kl",
    "sys.kl",
    "dict.kl",
    "declarations.kl",
    "writer.kl",
    "reader.kl",
    "macros.kl",
    "prolog.kl",
    "yacc.kl",
    "sequent.kl",
    "t-star.kl",
    "track.kl",
    "load.kl",
    "types.kl",
    "extension-features.kl",
    "extension-expand-dynamic.kl",
    "extension-launcher.kl",
    "stlib.kl",
};

fn boot(kl_dir: []const u8, vm: *Vm) !void {
    var env = Env.init(null);
    var loaded: usize = 0;

    for (boot_order) |filename| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ kl_dir, filename }) catch continue;

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("SKIP {s}: {s}\n", .{ filename, @errorName(err) });
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(vm.allocator, 10 * 1024 * 1024) catch |err| {
            std.debug.print("SKIP {s}: {s}\n", .{ filename, @errorName(err) });
            continue;
        };

        std.debug.print("Loading {s} ...", .{filename});

        var rd = Reader.init(content, vm);
        const exprs = rd.readAll() catch |err| {
            std.debug.print(" READ ERROR: {s}\n", .{@errorName(err)});
            continue;
        };

        var ok = true;
        for (exprs) |expr| {
            _ = eval_mod.eval(expr, &env, vm) catch |err| {
                std.debug.print(" EVAL ERROR: {s}\n", .{@errorName(err)});
                ok = false;
                break;
            };
        }

        if (ok) {
            loaded += 1;
            std.debug.print(" ok\n", .{});
        }
    }

    std.debug.print("\nLoaded {d}/{d} files.\n", .{ loaded, boot_order.len });

    std.debug.print("Shen ready.\n\n", .{});

    // Drop into REPL
    repl_with_env(vm, &env);
}

fn repl_with_env(vm: *Vm, env: *Env) void {
    const stdin = std.fs.File.stdin();

    while (true) {
        std.debug.print("shen>> ", .{});

        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const n = stdin.read(buf[len .. len + 1]) catch break;
            if (n == 0) return;
            if (buf[len] == '\n') break;
            len += 1;
        }
        const line = buf[0..len];
        if (line.len == 0) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "quit")) break;

        var rd = Reader.init(line, vm);
        const exprs = rd.readAll() catch |err| {
            std.debug.print("read error: {s}\n", .{@errorName(err)});
            continue;
        };

        var result: Value = .nil;
        for (exprs) |expr| {
            result = eval_mod.eval(expr, env, vm) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
        }

        const s = printer_mod.valueToString(vm, result) catch |err| {
            std.debug.print("print error: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("{s}\n", .{s});
    }
}

fn repl(vm: *Vm) !void {
    var env = Env.init(null);
    const stdin = std.fs.File.stdin();

    std.debug.print("shen-zig 0.1\n", .{});

    while (true) {
        std.debug.print(">> ", .{});

        // Read a line manually
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        while (len < buf.len) {
            const n = stdin.read(buf[len .. len + 1]) catch break;
            if (n == 0) return; // EOF
            if (buf[len] == '\n') break;
            len += 1;
        }
        const line = buf[0..len];

        if (line.len == 0) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "quit")) break;

        var rd = Reader.init(line, vm);
        const exprs = rd.readAll() catch |err| {
            std.debug.print("read error: {s}\n", .{@errorName(err)});
            continue;
        };

        var result: Value = .nil;
        for (exprs) |expr| {
            result = eval_mod.eval(expr, &env, vm) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
                continue;
            };
        }

        const s = printer_mod.valueToString(vm, result) catch |err| {
            std.debug.print("print error: {s}\n", .{@errorName(err)});
            continue;
        };
        std.debug.print("{s}\n", .{s});
    }
}
