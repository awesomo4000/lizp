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
    vm.resetNursery();
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
    const env = try vm.allocator.create(Env);
    env.* = Env.init(null);
    var loaded: usize = 0;
    var timer = std.time.Timer.start() catch unreachable;

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
            _ = eval_mod.eval(expr, env, vm) catch |err| {
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

    const load_ms = timer.read() / 1_000_000;
    std.debug.print("\nLoaded {d}/{d} files in {d}ms.\n", .{ loaded, boot_order.len, load_ms });

    // Initialize environment
    std.debug.print("Initializing...", .{});
    timer.reset();

    // Populate shen.*system* from all defined functions (before init reads it)
    {
        var sys_list: Value = .nil;
        var it = vm.functions.iterator();
        while (it.next()) |entry| {
            sys_list = vm.makeCons(Value{ .symbol = entry.key_ptr.* }, sys_list) catch .nil;
        }
        const sys_sym = vm.pool.intern("shen.*system*") catch unreachable;
        vm.globals.put(vm.allocator, sys_sym, sys_list) catch {};
    }

    // Run boot-init.kl (environment setup, lambda forms, fn patch)
    {
        var init_path_buf: [512]u8 = undefined;
        const init_path = std.fmt.bufPrint(&init_path_buf, "{s}/boot-init.kl", .{kl_dir}) catch "src/shen/kl/boot-init.kl";
        const init_file = std.fs.cwd().openFile(init_path, .{}) catch |err| {
            std.debug.print(" SKIP boot-init.kl: {s}\n", .{@errorName(err)});
            return;
        };
        defer init_file.close();
        const init_content = init_file.readToEndAlloc(vm.allocator, 1 * 1024 * 1024) catch return;
        evalSrc(init_content, env, vm);
    }

    const init_ms = timer.read() / 1_000_000;
    std.debug.print(" done ({d}ms).\n", .{init_ms});

    std.debug.print("Shen ready.\n\n", .{});

    // Boot complete — all defun/set values are either tenured (via promote)
    // or in nursery but referenced by tenured structures. We can't safely
    // reset nursery here because property vectors may hold nursery pointers.
    // The REPL will reset nursery after each line.

    // Drop into REPL
    repl_with_env(vm, env);
}

fn evalSrc(src: []const u8, env: *Env, vm: *Vm) void {
    var rd = Reader.init(src, vm);
    const exprs = rd.readAll() catch |err| {
        std.debug.print("boot-init read error: {s}\n", .{@errorName(err)});
        return;
    };
    for (exprs) |expr| {
        _ = eval_mod.eval(expr, env, vm) catch |err| {
            const msg = if (err == error.ShenError) vm.last_error else @errorName(err);
            std.debug.print("boot-init eval error: {s}\n", .{msg});
        };
    }
}

fn repl_with_env(vm: *Vm, env: *Env) void {
    const stdin = std.fs.File.stdin();

    // Look up Shen's eval function for macro expansion + shen->kl
    const eval_sym = vm.pool.intern("eval") catch unreachable;
    const shen_eval = vm.functions.get(eval_sym);

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
            // Route through Shen's eval (macroexpand -> shen->kl -> eval-kl)
            if (shen_eval) |f| {
                result = eval_mod.apply(f, &[_]Value{expr}, vm) catch |err| {
                    const msg = if (err == error.ShenError) vm.last_error else @errorName(err);
                    std.debug.print("error: {s}\n", .{msg});
                    continue;
                };
            } else {
                // Fallback to raw KL eval if Shen's eval not available
                result = eval_mod.eval(expr, env, vm) catch |err| {
                    std.debug.print("error: {s}\n", .{@errorName(err)});
                    continue;
                };
            }
        }

        // Promote result to tenured before printing, then reset nursery
        result = vm.promote(result) catch result;
        const s = printer_mod.valueToString(vm, result) catch |err| {
            std.debug.print("print error: {s}\n", .{@errorName(err)});
            vm.resetNursery();
            continue;
        };
        std.debug.print("{s}\n", .{s});
        vm.resetNursery();
    }
}

