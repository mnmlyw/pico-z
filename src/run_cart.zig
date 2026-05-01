// Headless cart runner — loads a .p8 / .p8.png cart, runs N frames with
// scripted input, captures screenshots and an event log for offline inspection.
//
// Usage:
//   run_cart <cart> [script]
//
// Script format (one command per line; # starts a comment).
//
// Top-level (no leading "<frame>:"):
//   frames <n>                          total frame count (default 600)
//   log <path>                          write event log to this file
//   screenshot every <n> to <prefix>    auto-capture every n frames as
//                                         <prefix>0001.bmp, <prefix>0002.bmp, ...
//
// Frame-keyed events (executed at start of frame, in order):
//   <frame>: press   <p0|p1>.<button>   button names: left,right,up,down,o|z,x
//   <frame>: release <p0|p1>.<button>
//   <frame>: hold    <p0|p1>.<button> for <n>
//   <frame>: screenshot <path.bmp>
//   <frame>: dump                        log a one-line snapshot of pico state
//   <frame>: eval <lua...>               run Lua, log return value(s)
//   <frame>: assert <lua expr>           log + abort run if expr is falsy
//   <frame>: quit
//
// If no script is supplied, runs 600 frames with no input and writes final.bmp.

const std = @import("std");
const Memory = @import("memory.zig").Memory;
const cart_mod = @import("cart.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;
const api = @import("api.zig");
const gfx = @import("gfx.zig");
const input_mod = @import("input.zig");
const preprocessor = @import("preprocessor.zig");
const audio_mod = @import("audio.zig");
const zlua = @import("zlua");

const SCREEN_W = 128;
const SCREEN_H = 128;

const Action = union(enum) {
    press: ButtonRef,
    release: ButtonRef,
    screenshot: []const u8,
    dump: void,
    dump_globals: void,
    dump_source: []const u8,
    eval: []const u8,
    assert_: []const u8,
    quit: void,
};

const ButtonRef = struct {
    player: u1,
    button: u3,
};

const Event = struct {
    frame: u32,
    action: Action,
};

const Script = struct {
    events: std.ArrayList(Event) = .empty,
    max_frames: u32 = 600,
    log_path: ?[]const u8 = null,
    auto_shot_every: u32 = 0,
    auto_shot_prefix: ?[]const u8 = null,
    audio_path: ?[]const u8 = null,

    fn deinit(self: *Script, allocator: std.mem.Allocator) void {
        for (self.events.items) |ev| switch (ev.action) {
            .screenshot => |s| allocator.free(s),
            .eval => |s| allocator.free(s),
            .assert_ => |s| allocator.free(s),
            .dump_source => |s| allocator.free(s),
            else => {},
        };
        self.events.deinit(allocator);
        if (self.log_path) |p| allocator.free(p);
        if (self.auto_shot_prefix) |p| allocator.free(p);
        if (self.audio_path) |p| allocator.free(p);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const cart_path = args.next() orelse {
        std.debug.print("usage: run_cart <cart.p8|.p8.png> [script.txt]\n", .{});
        return 2;
    };
    const script_path = args.next();

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer: [SCREEN_W * SCREEN_H]u32 = undefined;
    @memset(&pixel_buffer, 0xFF000000);

    // Event log buffer — printh and our own events both append here.
    var log_buf: std.ArrayList(u8) = .empty;
    defer log_buf.deinit(allocator);

    // Headless audio: synthesize samples per frame into a growing buffer that
    // we write as a WAV at the end (if requested).
    var audio = audio_mod.Audio.init(&memory);
    var audio_buf: std.ArrayList(f32) = .empty;
    defer audio_buf.deinit(allocator);

    var pico = api.PicoState{
        .memory = &memory,
        .pixel_buffer = &pixel_buffer,
        .input = &input,
        .audio = &audio,
        .allocator = allocator,
        .io = io,
        .debug_log = &log_buf,
    };
    defer if (pico.cart_data_id) |id| allocator.free(id);

    var lua_engine = try LuaEngine.init(allocator, &pico);
    defer lua_engine.deinit();

    var cart = if (std.mem.endsWith(u8, cart_path, ".p8.png"))
        try cart_mod.loadP8PngFile(allocator, io, cart_path, &memory)
    else
        try cart_mod.loadP8File(allocator, io, cart_path, &memory);
    defer cart.deinit();

    memory.saveRom();
    api.prepareForCartLoad(&pico);
    try lua_engine.loadCart(&cart, allocator);
    lua_engine.callInit();

    var script: Script = .{};
    defer script.deinit(allocator);

    if (script_path) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(text);
        try parseScript(allocator, text, &script);
    }

    std.mem.sort(Event, script.events.items, {}, struct {
        fn lt(_: void, a: Event, b: Event) bool {
            return a.frame < b.frame;
        }
    }.lt);

    try logLine(allocator, &log_buf, "# pico-z run_cart cart={s} max_frames={d}", .{ cart_path, script.max_frames });

    var ev_idx: usize = 0;
    var frame_idx: u32 = 0;
    var assert_failed: ?[]u8 = null;
    defer if (assert_failed) |s| allocator.free(s);

    while (frame_idx < script.max_frames) : (frame_idx += 1) {
        // Apply scheduled events
        while (ev_idx < script.events.items.len and script.events.items[ev_idx].frame == frame_idx) {
            const ev = script.events.items[ev_idx];
            switch (ev.action) {
                .press => |b| {
                    input.btn_state[b.player] |= (@as(u8, 1) << b.button);
                    try logLine(allocator, &log_buf, "f{d} press p{d}.{d}", .{ frame_idx, b.player, b.button });
                },
                .release => |b| {
                    input.btn_state[b.player] &= ~(@as(u8, 1) << b.button);
                    try logLine(allocator, &log_buf, "f{d} release p{d}.{d}", .{ frame_idx, b.player, b.button });
                },
                .screenshot => |out_path| {
                    gfx.renderToARGB(&memory, &pixel_buffer);
                    try writeBmp(io, out_path, &pixel_buffer);
                    try logLine(allocator, &log_buf, "f{d} screenshot {s}", .{ frame_idx, out_path });
                    std.debug.print("frame {d}: wrote {s}\n", .{ frame_idx, out_path });
                },
                .dump => {
                    try logLine(
                        allocator,
                        &log_buf,
                        "f{d} dump btn=p0:{x:0>2}/p1:{x:0>2} elapsed={d:.3}s rng=0x{x:0>8} fps={d}",
                        .{ frame_idx, input.btn_state[0], input.btn_state[1], pico.elapsed_time, pico.rng_state, pico.target_fps },
                    );
                },
                .dump_source => |out_prefix| {
                    // Write `<prefix>.lua` (raw) and `<prefix>.preprocessed.lua` (post-preprocess)
                    const raw_path = try std.fmt.allocPrint(allocator, "{s}.lua", .{out_prefix});
                    defer allocator.free(raw_path);
                    const pp_path = try std.fmt.allocPrint(allocator, "{s}.preprocessed.lua", .{out_prefix});
                    defer allocator.free(pp_path);
                    {
                        var f = try std.Io.Dir.cwd().createFile(io, raw_path, .{ .truncate = true });
                        defer f.close(io);
                        try f.writeStreamingAll(io, cart.lua_code);
                    }
                    const processed = try preprocessor.preprocess(allocator, cart.lua_code);
                    defer allocator.free(processed);
                    {
                        var f = try std.Io.Dir.cwd().createFile(io, pp_path, .{ .truncate = true });
                        defer f.close(io);
                        try f.writeStreamingAll(io, processed);
                    }
                    try logLine(allocator, &log_buf, "f{d} dump source -> {s}, {s}", .{ frame_idx, raw_path, pp_path });
                },
                .dump_globals => {
                    const globals = dumpGlobals(lua_engine.lua, allocator) catch |err| blk: {
                        const msg = std.fmt.allocPrint(allocator, "<error: {s}>", .{@errorName(err)}) catch break :blk @as([]u8, &.{});
                        break :blk msg;
                    };
                    defer allocator.free(globals);
                    try logLine(allocator, &log_buf, "f{d} globals: {s}", .{ frame_idx, globals });
                },
                .eval => |code| {
                    const result = evalLua(lua_engine.lua, code, allocator) catch |err| blk: {
                        const msg = std.fmt.allocPrint(allocator, "<error: {s}>", .{@errorName(err)}) catch break :blk @as([]u8, &.{});
                        break :blk msg;
                    };
                    defer allocator.free(result);
                    try logLine(allocator, &log_buf, "f{d} eval [{s}] -> {s}", .{ frame_idx, code, result });
                },
                .assert_ => |expr| {
                    const code_buf = try std.fmt.allocPrint(allocator, "return ({s})", .{expr});
                    defer allocator.free(code_buf);
                    const result = evalLua(lua_engine.lua, code_buf, allocator) catch |err| blk: {
                        const msg = std.fmt.allocPrint(allocator, "<error: {s}>", .{@errorName(err)}) catch break :blk @as([]u8, &.{});
                        break :blk msg;
                    };
                    defer allocator.free(result);
                    const ok = std.mem.eql(u8, result, "true") or std.mem.eql(u8, result, "1");
                    try logLine(allocator, &log_buf, "f{d} assert [{s}] -> {s} ({s})", .{ frame_idx, expr, result, if (ok) "ok" else "FAIL" });
                    if (!ok) {
                        assert_failed = try std.fmt.allocPrint(allocator, "assert failed at frame {d}: {s} -> {s}", .{ frame_idx, expr, result });
                        break;
                    }
                },
                .quit => {
                    try logLine(allocator, &log_buf, "f{d} quit", .{frame_idx});
                    std.debug.print("frame {d}: quit\n", .{frame_idx});
                    return try writeLogFile(io, &script, &log_buf);
                },
            }
            ev_idx += 1;
        }
        if (assert_failed != null) break;

        // Inline input.update() — advance held_frames and write back to RAM
        input.prev_state = input.btn_state;
        for (0..2) |p| {
            for (0..8) |b| {
                const mask: u8 = @as(u8, 1) << @intCast(b);
                if (input.btn_state[p] & mask != 0) {
                    input.held_frames[p][b] +|= 1;
                } else {
                    input.held_frames[p][b] = 0;
                }
            }
        }
        memory.ram[0x5F4C] = input.btn_state[0];
        memory.ram[0x5F4D] = input.btn_state[1];

        // Use the coroutine-aware tick so flip() inside fade animations
        // produces real intermediate frames instead of being a no-op.
        const tick_result = lua_engine.tickFrame();
        _ = tick_result; // headless: render whatever the cart left in screen mem

        if (lua_engine.had_error) {
            try logLine(allocator, &log_buf, "f{d} runtime error: {s}", .{ frame_idx, lua_engine.getErrorMsg() });
            std.debug.print("frame {d}: runtime error: {s}\n", .{ frame_idx, lua_engine.getErrorMsg() });
            _ = try writeLogFile(io, &script, &log_buf);
            return 1;
        }

        // Auto screenshots
        if (script.auto_shot_every > 0 and script.auto_shot_prefix != null) {
            if (frame_idx % script.auto_shot_every == 0) {
                gfx.renderToARGB(&memory, &pixel_buffer);
                var path_buf: [512]u8 = undefined;
                const path = try std.fmt.bufPrint(&path_buf, "{s}{d:0>4}.bmp", .{ script.auto_shot_prefix.?, frame_idx / script.auto_shot_every });
                try writeBmp(io, path, &pixel_buffer);
            }
        }

        pico.frame_count += 1;
        pico.target_fps = if (lua_engine.use60fps()) 60 else 30;
        pico.elapsed_time += 1.0 / @as(f64, @floatFromInt(pico.target_fps));

        // Synthesize this frame's audio. SAMPLE_RATE/target_fps isn't an
        // integer (22050/60 = 367.5), so we can't generate a fixed count
        // per frame without accumulating drift. Instead, target a running
        // total and emit however many samples are needed to hit it — this
        // keeps audio time exactly aligned with frame time.
        if (script.audio_path != null) {
            const target_total: usize = @intCast(@divTrunc(
                @as(u64, pico.frame_count) * @as(u64, audio_mod.SAMPLE_RATE),
                @as(u64, pico.target_fps),
            ));
            if (target_total > audio_buf.items.len) {
                const need = target_total - audio_buf.items.len;
                try audio_buf.ensureUnusedCapacity(allocator, need);
                var k: usize = 0;
                while (k < need) : (k += 1) {
                    audio_buf.appendAssumeCapacity(audio.generateSampleIndexed());
                }
            }
        }
    }

    if (assert_failed) |msg| {
        std.debug.print("{s}\n", .{msg});
        _ = try writeLogFile(io, &script, &log_buf);
        return 1;
    }

    if (script_path == null) {
        gfx.renderToARGB(&memory, &pixel_buffer);
        try writeBmp(io, "final.bmp", &pixel_buffer);
        std.debug.print("ran {d} frames; wrote final.bmp\n", .{frame_idx});
    } else {
        std.debug.print("ran {d} frames\n", .{frame_idx});
    }

    if (script.audio_path) |path| {
        try writeWav(io, path, audio_buf.items, audio_mod.SAMPLE_RATE);
        std.debug.print("wrote audio {s} ({d} samples @ {d}Hz)\n", .{ path, audio_buf.items.len, audio_mod.SAMPLE_RATE });
    }

    return try writeLogFile(io, &script, &log_buf);
}

fn writeLogFile(io: std.Io, script: *const Script, log_buf: *const std.ArrayList(u8)) !u8 {
    if (script.log_path) |path| {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, log_buf.items);
        std.debug.print("wrote log {s} ({d} bytes)\n", .{ path, log_buf.items.len });
    }
    return 0;
}

fn logLine(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var stack: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&stack, fmt ++ "\n", args) catch {
        // Line too long — fall back to allocPrint
        const big = try std.fmt.allocPrint(allocator, fmt ++ "\n", args);
        defer allocator.free(big);
        try buf.appendSlice(allocator, big);
        return;
    };
    try buf.appendSlice(allocator, line);
}

// Run Lua code, return a string representation of its first return value (or "nil").
// The code is wrapped if it doesn't already start with a statement keyword: a bare
// expression "x.y" becomes "return x.y".
fn evalLua(lua: *zlua.Lua, code: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const trimmed = std.mem.trim(u8, code, " \t");
    const wrapped: []const u8 = if (looksLikeExpr(trimmed))
        try std.fmt.allocPrint(allocator, "return {s}", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(wrapped);

    const top = lua.getTop();
    defer lua.setTop(top);

    lua.loadBuffer(wrapped, "eval", .text) catch {
        const err = lua.toString(-1) catch "?";
        return try allocator.dupe(u8, err);
    };
    lua.protectedCall(.{ .results = 1 }) catch {
        const err = lua.toString(-1) catch "?";
        return try allocator.dupe(u8, err);
    };

    return try luaValueToString(lua, -1, allocator);
}

// Best-effort heuristic: if the snippet starts with a keyword that can begin a
// statement, run it as a chunk; otherwise treat it as an expression with `return`.
fn looksLikeExpr(code: []const u8) bool {
    const stmt_starters = [_][]const u8{
        "local ", "if ",   "for ", "while ", "do ",   "return ",
        "print(", "printh(", "function ", "repeat ", "break", "goto ",
    };
    for (stmt_starters) |s| {
        if (std.mem.startsWith(u8, code, s)) return false;
    }
    // Multi-statement (contains ';' or starts with assignment) — treat as chunk
    if (std.mem.indexOfScalar(u8, code, ';') != null) return false;
    // Assignment heuristic: `name =` (but NOT `==`)
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        if (code[i] == '=') {
            if (i + 1 < code.len and code[i + 1] == '=') return true;
            // Look for non-comparison '=' — rough heuristic
            if (i > 0 and code[i - 1] != '<' and code[i - 1] != '>' and code[i - 1] != '~' and code[i - 1] != '!') {
                return false;
            }
        }
    }
    return true;
}

const LuaStringifyError = std.mem.Allocator.Error;

fn luaValueToString(lua: *zlua.Lua, idx: i32, allocator: std.mem.Allocator) LuaStringifyError![]u8 {
    const t = lua.typeOf(idx);
    return switch (t) {
        .nil => try allocator.dupe(u8, "nil"),
        .boolean => try allocator.dupe(u8, if (lua.toBoolean(idx)) "true" else "false"),
        .number => blk: {
            const n = lua.toNumber(idx) catch break :blk try allocator.dupe(u8, "?");
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{n});
        },
        .string => blk: {
            const s = lua.toString(idx) catch break :blk try allocator.dupe(u8, "?");
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{s});
        },
        .table => try tableToString(lua, idx, allocator),
        .function => try allocator.dupe(u8, "<function>"),
        .userdata, .light_userdata => try allocator.dupe(u8, "<userdata>"),
        .thread => try allocator.dupe(u8, "<thread>"),
        else => try allocator.dupe(u8, "<?>"),
    };
}

fn tableToString(lua: *zlua.Lua, idx: i32, allocator: std.mem.Allocator) LuaStringifyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{");

    const abs_idx: i32 = if (idx < 0) lua.getTop() + idx + 1 else idx;
    lua.pushNil();
    var first = true;
    var count: usize = 0;
    while (lua.next(abs_idx)) {
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        count += 1;
        if (count > 16) {
            try out.appendSlice(allocator, "...");
            lua.pop(2);
            break;
        }
        // key at -2, value at -1
        const k_str = try luaValueToString(lua, -2, allocator);
        defer allocator.free(k_str);
        const v_str = try luaValueToString(lua, -1, allocator);
        defer allocator.free(v_str);
        try out.appendSlice(allocator, k_str);
        try out.appendSlice(allocator, "=");
        try out.appendSlice(allocator, v_str);
        lua.pop(1); // pop value, leave key for next iter
    }
    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

// List of names registered by api.registerAll + Lua stdlib globals — filtered out
// so dump_globals only shows what the cart itself defined.
const API_NAMES = std.StaticStringMap(void).initComptime(.{
    .{"cls"},      .{"pset"},     .{"pget"},      .{"line"},     .{"rect"},     .{"rectfill"}, .{"rrect"},
    .{"rrectfill"}, .{"circ"},    .{"circfill"},  .{"oval"},     .{"ovalfill"}, .{"spr"},      .{"sspr"},
    .{"map"},      .{"mget"},     .{"mset"},      .{"sget"},     .{"sset"},     .{"fget"},     .{"fset"},
    .{"print"},    .{"cursor"},   .{"color"},     .{"camera"},   .{"clip"},     .{"pal"},      .{"palt"},
    .{"fillp"},    .{"tline"},    .{"btn"},       .{"btnp"},     .{"abs"},      .{"flr"},      .{"ceil"},
    .{"sqrt"},     .{"sin"},      .{"cos"},       .{"atan2"},    .{"max"},      .{"min"},      .{"mid"},
    .{"rnd"},      .{"srand"},    .{"sgn"},       .{"band"},     .{"bor"},      .{"bxor"},     .{"bnot"},
    .{"shl"},      .{"shr"},      .{"lshr"},      .{"rotl"},     .{"rotr"},     .{"tostr"},    .{"tonum"},
    .{"add"},      .{"del"},      .{"deli"},      .{"count"},    .{"foreach"},  .{"all"},      .{"pack"},
    .{"unpack"},   .{"sub"},      .{"chr"},       .{"ord"},      .{"split"},    .{"cocreate"}, .{"coresume"},
    .{"costatus"}, .{"yield"},    .{"peek"},      .{"poke"},     .{"peek2"},    .{"poke2"},    .{"peek4"},
    .{"poke4"},    .{"memcpy"},   .{"memset"},    .{"reload"},   .{"cstore"},   .{"sfx"},      .{"music"},
    .{"stat"},     .{"time"},     .{"t"},         .{"printh"},   .{"cartdata"}, .{"dget"},     .{"dset"},
    .{"menuitem"}, .{"extcmd"},   .{"load"},      .{"run"},      .{"stop"},     .{"flip"},     .{"reset"},
    .{"serial"},
    // Lifecycle hooks — caller already inspects with `eval type(_init)` etc.
    .{"_init"}, .{"_update"}, .{"_update60"}, .{"_draw"},
    // Lua 5.2 stdlib globals
    .{"_G"}, .{"_ENV"}, .{"_VERSION"},
    .{"assert"}, .{"collectgarbage"}, .{"dofile"}, .{"error"}, .{"getmetatable"}, .{"ipairs"},
    .{"loadfile"}, .{"loadstring"}, .{"next"}, .{"pairs"}, .{"pcall"}, .{"rawequal"},
    .{"rawget"}, .{"rawlen"}, .{"rawset"}, .{"select"}, .{"setmetatable"}, .{"tostring"},
    .{"tonumber"}, .{"type"}, .{"xpcall"},
    .{"string"}, .{"table"}, .{"math"}, .{"io"}, .{"os"}, .{"package"}, .{"coroutine"}, .{"debug"}, .{"bit32"},
});

// Walk _G and emit "name=value" for each user-defined global (skipping API + stdlib).
// Functions show as "<function>"; tables are summarized.
fn dumpGlobals(lua: *zlua.Lua, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const top = lua.getTop();
    defer lua.setTop(top);

    lua.pushGlobalTable();
    const globals_idx = lua.getTop();

    lua.pushNil();
    var first = true;
    while (lua.next(globals_idx)) {
        // key at -2, value at -1
        if (lua.typeOf(-2) != .string) {
            lua.pop(1);
            continue;
        }
        const key = lua.toString(-2) catch {
            lua.pop(1);
            continue;
        };
        if (API_NAMES.has(key)) {
            lua.pop(1);
            continue;
        }
        // Skip our own internal helpers (anything starting with __pz_)
        if (std.mem.startsWith(u8, key, "__pz_")) {
            lua.pop(1);
            continue;
        }
        if (!first) try out.appendSlice(allocator, ", ");
        first = false;
        const v_str = try luaValueToString(lua, -1, allocator);
        defer allocator.free(v_str);
        try out.appendSlice(allocator, key);
        try out.appendSlice(allocator, "=");
        try out.appendSlice(allocator, v_str);
        lua.pop(1);
    }
    if (first) try out.appendSlice(allocator, "<none>");
    return out.toOwnedSlice(allocator);
}

fn buttonFromName(name: []const u8) ?u3 {
    if (std.mem.eql(u8, name, "left")) return 0;
    if (std.mem.eql(u8, name, "right")) return 1;
    if (std.mem.eql(u8, name, "up")) return 2;
    if (std.mem.eql(u8, name, "down")) return 3;
    if (std.mem.eql(u8, name, "o") or std.mem.eql(u8, name, "z")) return 4;
    if (std.mem.eql(u8, name, "x")) return 5;
    return null;
}

fn parseButtonRef(spec: []const u8) ?ButtonRef {
    const dot = std.mem.indexOfScalar(u8, spec, '.') orelse return null;
    const player_part = spec[0..dot];
    const btn_part = spec[dot + 1 ..];
    const player: u1 = if (std.mem.eql(u8, player_part, "p0")) 0 else if (std.mem.eql(u8, player_part, "p1")) 1 else return null;
    const button = buttonFromName(btn_part) orelse return null;
    return .{ .player = player, .button = button };
}

fn parseScript(
    allocator: std.mem.Allocator,
    text: []const u8,
    script: *Script,
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: u32 = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Top-level directives
        if (std.mem.startsWith(u8, line, "frames ")) {
            script.max_frames = std.fmt.parseInt(u32, std.mem.trim(u8, line[7..], " \t"), 10) catch {
                std.debug.print("script line {d}: invalid frame count\n", .{lineno});
                return error.ScriptParseError;
            };
            continue;
        }
        if (std.mem.startsWith(u8, line, "log ")) {
            const path = std.mem.trim(u8, line[4..], " \t");
            script.log_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.startsWith(u8, line, "audio ")) {
            const path = std.mem.trim(u8, line[6..], " \t");
            script.audio_path = try allocator.dupe(u8, path);
            continue;
        }
        if (std.mem.startsWith(u8, line, "screenshot every ")) {
            // "screenshot every 30 to frame_"
            const rest = std.mem.trim(u8, line[17..], " \t");
            const to_idx = std.mem.indexOf(u8, rest, " to ") orelse {
                std.debug.print("script line {d}: expected 'screenshot every N to PREFIX'\n", .{lineno});
                return error.ScriptParseError;
            };
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..to_idx], " \t"), 10) catch {
                std.debug.print("script line {d}: invalid N in screenshot every\n", .{lineno});
                return error.ScriptParseError;
            };
            const prefix = std.mem.trim(u8, rest[to_idx + 4 ..], " \t");
            script.auto_shot_every = n;
            script.auto_shot_prefix = try allocator.dupe(u8, prefix);
            continue;
        }

        // Frame-keyed events: "<frame>: <command...>"
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            std.debug.print("script line {d}: missing ':' in '{s}'\n", .{ lineno, line });
            return error.ScriptParseError;
        };
        const frame_str = std.mem.trim(u8, line[0..colon], " \t");
        const cmd = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const frame = std.fmt.parseInt(u32, frame_str, 10) catch {
            std.debug.print("script line {d}: bad frame '{s}'\n", .{ lineno, frame_str });
            return error.ScriptParseError;
        };

        if (std.mem.startsWith(u8, cmd, "press ")) {
            const b = parseButtonRef(std.mem.trim(u8, cmd[6..], " \t")) orelse {
                std.debug.print("script line {d}: bad button '{s}'\n", .{ lineno, cmd });
                return error.ScriptParseError;
            };
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .press = b } });
        } else if (std.mem.startsWith(u8, cmd, "release ")) {
            const b = parseButtonRef(std.mem.trim(u8, cmd[8..], " \t")) orelse return error.ScriptParseError;
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .release = b } });
        } else if (std.mem.startsWith(u8, cmd, "hold ")) {
            const rest = std.mem.trim(u8, cmd[5..], " \t");
            const for_idx = std.mem.indexOf(u8, rest, " for ") orelse return error.ScriptParseError;
            const b = parseButtonRef(rest[0..for_idx]) orelse return error.ScriptParseError;
            const dur = std.fmt.parseInt(u32, std.mem.trim(u8, rest[for_idx + 5 ..], " \t"), 10) catch return error.ScriptParseError;
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .press = b } });
            try script.events.append(allocator, .{ .frame = frame + dur, .action = .{ .release = b } });
        } else if (std.mem.startsWith(u8, cmd, "screenshot ")) {
            const path = std.mem.trim(u8, cmd[11..], " \t");
            const owned = try allocator.dupe(u8, path);
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .screenshot = owned } });
        } else if (std.mem.eql(u8, cmd, "dump")) {
            try script.events.append(allocator, .{ .frame = frame, .action = .dump });
        } else if (std.mem.eql(u8, cmd, "dump globals")) {
            try script.events.append(allocator, .{ .frame = frame, .action = .dump_globals });
        } else if (std.mem.startsWith(u8, cmd, "dump source ")) {
            const prefix = std.mem.trim(u8, cmd[12..], " \t");
            const owned = try allocator.dupe(u8, prefix);
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .dump_source = owned } });
        } else if (std.mem.startsWith(u8, cmd, "eval ")) {
            const code = std.mem.trim(u8, cmd[5..], " \t");
            const owned = try allocator.dupe(u8, code);
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .eval = owned } });
        } else if (std.mem.startsWith(u8, cmd, "assert ")) {
            const expr = std.mem.trim(u8, cmd[7..], " \t");
            const owned = try allocator.dupe(u8, expr);
            try script.events.append(allocator, .{ .frame = frame, .action = .{ .assert_ = owned } });
        } else if (std.mem.eql(u8, cmd, "quit")) {
            try script.events.append(allocator, .{ .frame = frame, .action = .quit });
        } else {
            std.debug.print("script line {d}: unknown command '{s}'\n", .{ lineno, cmd });
            return error.ScriptParseError;
        }
    }
}

// 16-bit PCM mono WAV. Audio synth produces f32 in [-1, 1]; clip and scale.
fn writeWav(io: std.Io, path: []const u8, samples: []const f32, sample_rate: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    const num_samples: u32 = @intCast(samples.len);
    const byte_rate: u32 = sample_rate * 2; // mono, 16-bit = 2 bytes/sample
    const data_size: u32 = num_samples * 2;
    const file_size: u32 = 36 + data_size;

    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], file_size, .little);
    @memcpy(hdr[8..12], "WAVE");
    @memcpy(hdr[12..16], "fmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], 1, .little); // mono
    std.mem.writeInt(u32, hdr[24..28], sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], byte_rate, .little);
    std.mem.writeInt(u16, hdr[32..34], 2, .little); // block align
    std.mem.writeInt(u16, hdr[34..36], 16, .little); // bits per sample
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], data_size, .little);
    try file.writeStreamingAll(io, &hdr);

    var pcm: [2048]u8 = undefined;
    var written: usize = 0;
    while (written < samples.len) {
        const remaining: usize = samples.len - written;
        const max_per_chunk: usize = 1024;
        const chunk: usize = if (remaining < max_per_chunk) remaining else max_per_chunk;
        var i: usize = 0;
        while (i < chunk) : (i += 1) {
            const f = std.math.clamp(samples[written + i], -1.0, 1.0);
            const v: i16 = @intFromFloat(f * 32767.0);
            std.mem.writeInt(i16, pcm[i * 2 ..][0..2], v, .little);
        }
        try file.writeStreamingAll(io, pcm[0 .. chunk * 2]);
        written += chunk;
    }
}

// 24-bit BMP, bottom-up. Width is 128 → row stride 384 (already 4-aligned).
fn writeBmp(io: std.Io, path: []const u8, pixel_buffer: *const [SCREEN_W * SCREEN_H]u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    const row_stride: u32 = SCREEN_W * 3;
    const pixel_bytes: u32 = row_stride * SCREEN_H;
    const file_size: u32 = 14 + 40 + pixel_bytes;

    var header: [54]u8 = undefined;
    // BITMAPFILEHEADER
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], file_size, .little);
    std.mem.writeInt(u32, header[6..10], 0, .little);
    std.mem.writeInt(u32, header[10..14], 54, .little);
    // BITMAPINFOHEADER
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], SCREEN_W, .little);
    std.mem.writeInt(i32, header[22..26], SCREEN_H, .little);
    std.mem.writeInt(u16, header[26..28], 1, .little); // planes
    std.mem.writeInt(u16, header[28..30], 24, .little); // bpp
    std.mem.writeInt(u32, header[30..34], 0, .little); // BI_RGB
    std.mem.writeInt(u32, header[34..38], pixel_bytes, .little);
    std.mem.writeInt(u32, header[38..42], 2835, .little); // 72 dpi
    std.mem.writeInt(u32, header[42..46], 2835, .little);
    std.mem.writeInt(u32, header[46..50], 0, .little);
    std.mem.writeInt(u32, header[50..54], 0, .little);
    try file.writeStreamingAll(io, &header);

    var row: [SCREEN_W * 3]u8 = undefined;
    var y: i32 = SCREEN_H - 1;
    while (y >= 0) : (y -= 1) {
        const row_start: usize = @intCast(@as(i32, @intCast(SCREEN_W)) * y);
        for (0..SCREEN_W) |x| {
            const argb = pixel_buffer[row_start + x];
            // BMP rows are stored BGR
            row[x * 3 + 0] = @intCast(argb & 0xff); // B
            row[x * 3 + 1] = @intCast((argb >> 8) & 0xff); // G
            row[x * 3 + 2] = @intCast((argb >> 16) & 0xff); // R
        }
        try file.writeStreamingAll(io, &row);
    }
}
