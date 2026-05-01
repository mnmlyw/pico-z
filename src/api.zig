const std = @import("std");
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const palette = @import("palette.zig");
const gfx = @import("gfx.zig");
const input_mod = @import("input.zig");
const math_api = @import("math_api.zig");
const audio_mod = @import("audio.zig");
const cartdata_store = @import("cartdata_store.zig");

pub const SCREEN_W = 128;
pub const SCREEN_H = 128;

pub const PicoState = struct {
    memory: *Memory,
    pixel_buffer: *[SCREEN_W * SCREEN_H]u32,
    input: *input_mod.Input,
    audio: ?*audio_mod.Audio,
    frame_count: u32 = 0,
    elapsed_time: f64 = 0, // seconds since cart started (frame-counted)

    // Line drawing state
    line_x: i32 = 0,
    line_y: i32 = 0,
    line_valid: bool = false,

    // Cartdata
    cart_data_id: ?[]const u8 = null,
    cart_data_dirty: bool = false,
    allocator: std.mem.Allocator,
    io: std.Io,
    target_fps: u8 = 30,
    rng_state: u32 = 1,

    // Multi-cart loading
    pending_load: ?[256]u8 = null,
    pending_load_len: u8 = 0,

    // Cart directory for relative load() paths
    cart_dir: ?[]const u8 = null,

    // Parameter string from load()/run() — accessible via stat(6)
    param_str: [256]u8 = undefined,
    param_str_len: u8 = 0,

    // Keyboard scancode state for stat(28)
    key_states: ?[*c]const bool = null,
    key_states_count: c_int = 0,

    // Optional debug log sink — when set, printh() also appends here.
    // Used by the headless cart runner. Lines are appended verbatim, no framing.
    debug_log: ?*std.ArrayList(u8) = null,
};

pub fn getPico(lua: *zlua.Lua) *PicoState {
    return lua.toUserdata(PicoState, zlua.Lua.upvalueIndex(1)) catch unreachable;
}

fn wrapFn(comptime func: anytype) zlua.CFn {
    return struct {
        fn f(state: ?*zlua.LuaState) callconv(.c) c_int {
            const lua: *zlua.Lua = @ptrCast(state);
            return @call(.auto, func, .{lua});
        }
    }.f;
}

pub fn registerAll(lua: *zlua.Lua, pico: *PicoState) void {
    // Push pico state as light userdata for upvalue
    lua.pushLightUserdata(@ptrCast(pico));

    // Register all API functions as globals with the pico state upvalue
    const funcs = .{
        // Graphics
        .{ "cls", wrapFn(gfx.api_cls) },
        .{ "pset", wrapFn(gfx.api_pset) },
        .{ "pget", wrapFn(gfx.api_pget) },
        .{ "line", wrapFn(gfx.api_line) },
        .{ "rect", wrapFn(gfx.api_rect) },
        .{ "rectfill", wrapFn(gfx.api_rectfill) },
        .{ "rrect", wrapFn(gfx.api_rrect) },
        .{ "rrectfill", wrapFn(gfx.api_rrectfill) },
        .{ "circ", wrapFn(gfx.api_circ) },
        .{ "circfill", wrapFn(gfx.api_circfill) },
        .{ "oval", wrapFn(gfx.api_oval) },
        .{ "ovalfill", wrapFn(gfx.api_ovalfill) },
        .{ "spr", wrapFn(gfx.api_spr) },
        .{ "sspr", wrapFn(gfx.api_sspr) },
        .{ "map", wrapFn(gfx.api_map) },
        .{ "mget", wrapFn(gfx.api_mget) },
        .{ "mset", wrapFn(gfx.api_mset) },
        .{ "sget", wrapFn(gfx.api_sget) },
        .{ "sset", wrapFn(gfx.api_sset) },
        .{ "fget", wrapFn(gfx.api_fget) },
        .{ "fset", wrapFn(gfx.api_fset) },
        .{ "print", wrapFn(gfx.api_print) },
        .{ "cursor", wrapFn(gfx.api_cursor) },
        .{ "color", wrapFn(gfx.api_color) },
        .{ "camera", wrapFn(gfx.api_camera) },
        .{ "clip", wrapFn(gfx.api_clip) },
        .{ "pal", wrapFn(gfx.api_pal) },
        .{ "palt", wrapFn(gfx.api_palt) },
        .{ "fillp", wrapFn(gfx.api_fillp) },
        .{ "tline", wrapFn(gfx.api_tline) },
        // Input
        .{ "btn", wrapFn(input_mod.api_btn) },
        .{ "btnp", wrapFn(input_mod.api_btnp) },
        // Math
        .{ "abs", wrapFn(math_api.api_abs) },
        .{ "flr", wrapFn(math_api.api_flr) },
        .{ "ceil", wrapFn(math_api.api_ceil) },
        .{ "sqrt", wrapFn(math_api.api_sqrt) },
        .{ "sin", wrapFn(math_api.api_sin) },
        .{ "cos", wrapFn(math_api.api_cos) },
        .{ "atan2", wrapFn(math_api.api_atan2) },
        .{ "max", wrapFn(math_api.api_max) },
        .{ "min", wrapFn(math_api.api_min) },
        .{ "mid", wrapFn(math_api.api_mid) },
        .{ "rnd", wrapFn(math_api.api_rnd) },
        .{ "srand", wrapFn(math_api.api_srand) },
        .{ "sgn", wrapFn(math_api.api_sgn) },
        .{ "band", wrapFn(math_api.api_band) },
        .{ "bor", wrapFn(math_api.api_bor) },
        .{ "bxor", wrapFn(math_api.api_bxor) },
        .{ "bnot", wrapFn(math_api.api_bnot) },
        .{ "shl", wrapFn(math_api.api_shl) },
        .{ "shr", wrapFn(math_api.api_shr) },
        .{ "lshr", wrapFn(math_api.api_lshr) },
        .{ "rotl", wrapFn(math_api.api_rotl) },
        .{ "rotr", wrapFn(math_api.api_rotr) },
        .{ "tostr", wrapFn(math_api.api_tostr) },
        .{ "tonum", wrapFn(math_api.api_tonum) },
        // Table
        .{ "add", wrapFn(math_api.api_add) },
        .{ "del", wrapFn(math_api.api_del) },
        .{ "deli", wrapFn(math_api.api_deli) },
        .{ "count", wrapFn(math_api.api_count) },
        .{ "foreach", wrapFn(math_api.api_foreach) },
        .{ "all", wrapFn(math_api.api_all) },
        .{ "pack", wrapFn(math_api.api_pack) },
        .{ "unpack", wrapFn(math_api.api_unpack) },
        // String
        .{ "sub", wrapFn(math_api.api_sub) },
        .{ "chr", wrapFn(math_api.api_chr) },
        .{ "ord", wrapFn(math_api.api_ord) },
        .{ "split", wrapFn(math_api.api_split) },
        // Coroutines
        .{ "cocreate", wrapFn(math_api.api_cocreate) },
        .{ "coresume", wrapFn(math_api.api_coresume) },
        .{ "costatus", wrapFn(math_api.api_costatus) },
        .{ "yield", wrapFn(math_api.api_yield) },
        // Memory
        .{ "peek", wrapFn(api_peek) },
        .{ "poke", wrapFn(api_poke) },
        .{ "peek2", wrapFn(api_peek2) },
        .{ "poke2", wrapFn(api_poke2) },
        .{ "peek4", wrapFn(api_peek4) },
        .{ "poke4", wrapFn(api_poke4) },
        .{ "memcpy", wrapFn(api_memcpy) },
        .{ "memset", wrapFn(api_memset) },
        .{ "reload", wrapFn(api_reload) },
        .{ "cstore", wrapFn(api_cstore) },
        // Audio
        .{ "sfx", wrapFn(audio_mod.api_sfx) },
        .{ "music", wrapFn(audio_mod.api_music) },
        // System
        .{ "stat", wrapFn(api_stat) },
        .{ "time", wrapFn(api_time) },
        .{ "t", wrapFn(api_time) },
        .{ "printh", wrapFn(api_printh) },
        .{ "cartdata", wrapFn(api_cartdata) },
        .{ "dget", wrapFn(api_dget) },
        .{ "dset", wrapFn(api_dset) },
        .{ "menuitem", wrapFn(api_menuitem) },
        .{ "extcmd", wrapFn(api_extcmd) },
        .{ "load", wrapFn(api_load) },
        .{ "run", wrapFn(api_run) },
        .{ "stop", wrapFn(api_stop) },
        .{ "flip", wrapFn(api_flip) },
        .{ "reset", wrapFn(api_reset) },
        .{ "serial", wrapFn(api_serial) },
    };

    inline for (funcs) |f| {
        lua.pushValue(-1); // duplicate pico userdata
        lua.pushClosure(f[1], 1);
        lua.setGlobal(f[0]);
    }

    lua.pop(1); // pop original pico userdata

    // Override type() to handle PICO-8 specifics
    registerTypeOverride(lua);
    // Override pairs/ipairs for nil tolerance
    registerPairsOverride(lua);
    // Enable str[i] character indexing
    registerStringIndex(lua);
}

pub fn prepareForCartLoad(pico: *PicoState) void {
    if (pico.audio) |audio| {
        audio.resetState();
    }
    pico.rng_state = 1;
    pico.elapsed_time = 0;
    pico.frame_count = 0;
    pico.line_x = 0;
    pico.line_y = 0;
    pico.line_valid = false;
}

pub fn flushCartdata(pico: *PicoState) void {
    flushCartdataWith(pico, cartdata_store.save);
}

pub fn flushCartdataWith(pico: *PicoState, save_fn: anytype) void {
    if (!pico.cart_data_dirty) return;
    if (pico.cart_data_id) |id| {
        save_fn(pico.allocator, pico.io, pico.memory, id) catch |err| {
            std.log.warn("cartdata save failed for {s}: {}", .{ id, err });
            return;
        };
    }
    pico.cart_data_dirty = false;
}

fn registerTypeOverride(lua: *zlua.Lua) void {
    // PICO-8: type() with no args returns nothing instead of error
    lua.pushClosure(wrapFn(pico8_type), 0);
    lua.setGlobal("type");
}

fn pico8_type(lua: *zlua.Lua) i32 {
    if (lua.isNone(1)) return 0;
    const type_name = lua.typeName(lua.typeOf(1));
    _ = lua.pushString(type_name);
    return 1;
}

fn registerPairsOverride(lua: *zlua.Lua) void {
    // PICO-8: pairs(nil) returns an empty function instead of error
    lua.pushClosure(wrapFn(pico8_pairs), 0);
    lua.setGlobal("pairs");

    // Same for ipairs
    lua.pushClosure(wrapFn(pico8_ipairs), 0);
    lua.setGlobal("ipairs");
}

fn pico8_pairs(lua: *zlua.Lua) i32 {
    if (lua.isNil(1) or lua.isNone(1)) {
        // Return empty iterator
        lua.pushClosure(wrapFn(emptyIterator), 0);
        return 1;
    }
    // Call standard next-based iteration
    _ = lua.getGlobal("next") catch return 0;
    lua.pushValue(1);
    lua.pushNil();
    return 3;
}

fn pico8_ipairs(lua: *zlua.Lua) i32 {
    if (lua.isNil(1) or lua.isNone(1)) {
        lua.pushClosure(wrapFn(emptyIterator), 0);
        return 1;
    }
    // Standard ipairs: return iterator, table, 0
    lua.pushClosure(wrapFn(ipairsIterator), 0);
    lua.pushValue(1);
    lua.pushNumber(0);
    return 3;
}

fn emptyIterator(_: *zlua.Lua) i32 {
    return 0;
}

fn ipairsIterator(lua: *zlua.Lua) i32 {
    const i_f = lua.toNumber(2) catch 0;
    const i: i32 = @intFromFloat(i_f);
    const next_i = i + 1;
    lua.pushNumber(@floatFromInt(next_i));
    _ = lua.rawGetIndex(1, @intCast(next_i));
    if (lua.isNil(-1)) return 1;
    return 2;
}

fn registerStringIndex(lua: *zlua.Lua) void {
    // PICO-8: str[i] returns character at position i (1-based)
    // Set up string metatable __index to support this
    _ = lua.pushString("");
    _ = lua.getMetatable(-1) catch return; // doesn't exist? shouldn't happen
    // Stack: "" metatable
    // Save original __index (the string library table)
    _ = lua.getField(-1, "__index");
    // Stack: "" metatable string_lib
    // Create a new __index function that checks for numeric keys
    lua.pushValue(-1); // push string_lib as upvalue
    lua.pushClosure(wrapFn(stringIndexHandler), 1);
    lua.setField(-3, "__index");
    lua.pop(3); // pop string_lib, metatable, ""
}

fn stringIndexHandler(lua: *zlua.Lua) i32 {
    // Called with (str, key)
    // If key is a number, return character at that position
    if (lua.isNumber(2)) {
        const s = lua.toString(1) catch {
            lua.pushNil();
            return 1;
        };
        const idx_f = lua.toNumber(2) catch 0;
        const idx: i32 = @intFromFloat(idx_f);
        if (idx >= 1 and idx <= @as(i32, @intCast(s.len))) {
            _ = lua.pushString(s[@intCast(idx - 1)..@intCast(idx)]);
        } else {
            lua.pushNil();
        }
        return 1;
    }
    // Otherwise, look up in the string library (upvalue 1)
    lua.pushValue(2); // push key
    _ = lua.getTable(zlua.Lua.upvalueIndex(1));
    return 1;
}

// Memory API implementations
fn api_peek(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const n = @max(optInt(lua, 2, 1), 1);
    if (n == 1) {
        lua.pushNumber(@floatFromInt(pico.memory.peek(addr)));
        return 1;
    }
    // Cap at 8192 per PICO-8, but also ensure Lua stack has space
    const count: u16 = @intCast(@min(n, 8192));
    lua.checkStack(count) catch return 0;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        lua.pushNumber(@floatFromInt(pico.memory.peek(addr +% i)));
    }
    return @intCast(count);
}

fn api_poke(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const top = lua.getTop();
    if (top >= 2) {
        var i: i32 = 2;
        var offset: u16 = 0;
        while (i <= top) : (i += 1) {
            const val = luaToU8(lua, i);
            pico.memory.poke(addr +% offset, val);
            offset += 1;
        }
    }
    return 0;
}

fn api_peek2(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const val = pico.memory.peek16(addr);
    lua.pushNumber(@floatFromInt(val));
    return 1;
}

fn api_poke2(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const val: u16 = @truncate(@as(u32, @bitCast(safeFloatToI32(luaToNum(lua, 2)))));
    pico.memory.poke16(addr, val);
    return 0;
}

fn api_peek4(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const raw = pico.memory.peek32(addr);
    // 16:16 fixed point -> float
    const fixed: i32 = @bitCast(raw);
    lua.pushNumber(@as(f64, @floatFromInt(fixed)) / 65536.0);
    return 1;
}

fn api_poke4(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const addr = luaToU16(lua, 1);
    const val = luaToNum(lua, 2);
    // Clamp to i32 range to prevent overflow panic on large values
    const scaled = val * 65536.0;
    const fixed: i32 = if (scaled >= 2147483647.0) @as(i32, 2147483647) else if (scaled <= -2147483648.0) @as(i32, -2147483648) else @intFromFloat(scaled);
    pico.memory.poke32(addr, @bitCast(fixed));
    return 0;
}

fn api_memcpy(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const dst = luaToU16(lua, 1);
    const src = luaToU16(lua, 2);
    const len = luaToU16(lua, 3);
    pico.memory.memcpy(dst, src, len);
    return 0;
}

fn api_memset(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const dst = luaToU16(lua, 1);
    const val = luaToU8(lua, 2);
    const len = luaToU16(lua, 3);
    pico.memory.memset(dst, val, len);
    return 0;
}

fn api_reload(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const dst = luaToU16Opt(lua, 1, 0);
    const src = luaToU16Opt(lua, 2, 0);
    const len = luaToU16Opt(lua, 3, 0x4300);

    // reload(dst, src, len, filename) — load from another cart file
    if (lua.toString(4)) |filename| {
        if (loadExternalCartRom(pico, filename)) |ext_rom| {
            defer pico.allocator.free(ext_rom);
            for (0..len) |i| {
                const s = src +% @as(u16, @intCast(i));
                const d = dst +% @as(u16, @intCast(i));
                pico.memory.ram[d] = if (s < ext_rom.len) ext_rom[s] else 0;
            }
        } else |_| {}
    } else |_| {
        pico.memory.reload(dst, src, len);
    }
    return 0;
}

fn api_cstore(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const dst = luaToU16Opt(lua, 1, 0);
    const src = luaToU16Opt(lua, 2, 0);
    const len = luaToU16Opt(lua, 3, 0x4300);

    if (lua.toString(4)) |_| {
        // cstore to external file — not supported (would need to write cart files)
    } else |_| {
        // Copy from RAM to ROM (opposite of reload)
        for (0..len) |i| {
            pico.memory.rom[dst +% @as(u16, @intCast(i))] = pico.memory.ram[src +% @as(u16, @intCast(i))];
        }
    }
    return 0;
}

fn loadExternalCartRom(pico: *PicoState, filename: []const u8) ![]u8 {
    const cart_mod = @import("cart.zig");
    // Resolve relative to current cart directory
    const path = if (pico.cart_dir) |dir|
        try std.fs.path.join(pico.allocator, &.{ dir, filename })
    else
        try pico.allocator.dupe(u8, filename);
    defer pico.allocator.free(path);

    var temp_mem = Memory.init();
    var cart = if (std.mem.endsWith(u8, path, ".p8.png"))
        try cart_mod.loadP8PngFile(pico.allocator, pico.io, path, &temp_mem)
    else
        try cart_mod.loadP8File(pico.allocator, pico.io, path, &temp_mem);
    defer cart.deinit();

    // Return copy of the loaded ROM data (first 0x4300 bytes)
    const rom = try pico.allocator.alloc(u8, 0x4300);
    @memcpy(rom, temp_mem.ram[0..0x4300]);
    return rom;
}

fn api_stat(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const n = optInt(lua, 1, 0);
    switch (n) {
        0 => lua.pushNumber(64), // memory usage (fake)
        1 => lua.pushNumber(0.5), // CPU usage (fake)
        4 => {
            _ = lua.pushString(""); // clipboard
        },
        5 => _ = lua.pushString("0.2.3"), // PICO-8 version string
        6 => {
            if (pico.param_str_len > 0)
                _ = lua.pushString(pico.param_str[0..pico.param_str_len])
            else
                _ = lua.pushString("");
        },
        7 => lua.pushNumber(@floatFromInt(pico.target_fps)),
        16...19 => {
            // Current note for SFX channel 0-3
            if (pico.audio) |audio| {
                const ch = &audio.channels[@intCast(n - 16)];
                if (!ch.finished and ch.sfx_id >= 0) {
                    lua.pushNumber(@floatFromInt(ch.note_index));
                } else {
                    lua.pushNumber(0);
                }
            } else lua.pushNumber(0);
        },
        20...23 => {
            // Currently playing SFX on channel 0-3 (-1 if none)
            if (pico.audio) |audio| {
                const ch = &audio.channels[@intCast(n - 20)];
                if (!ch.finished and ch.sfx_id >= 0) {
                    lua.pushNumber(@floatFromInt(ch.sfx_id));
                } else {
                    lua.pushNumber(-1);
                }
            } else lua.pushNumber(-1);
        },
        24 => {
            // Currently playing music pattern (-1 if none)
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.pattern));
            } else lua.pushNumber(-1);
        },
        26 => {
            // Ticks played on current music pattern
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.tick));
            } else lua.pushNumber(0);
        },
        28 => {
            // Keyboard scancode check: stat(28, scancode)
            const scancode = optInt(lua, 2, -1);
            if (scancode >= 0 and scancode < pico.key_states_count and pico.key_states != null) {
                const states = pico.key_states.?;
                lua.pushBoolean(states[@intCast(scancode)]);
            } else {
                lua.pushBoolean(false);
            }
        },
        30 => {
            // Keyboard: key event available
            lua.pushBoolean(pico.input.key_chars_len > 0);
        },
        31 => {
            // Keyboard: next key character
            if (pico.input.key_chars_len > 0) {
                _ = lua.pushString(pico.input.key_chars[0..1]);
                // Shift buffer
                var i: usize = 0;
                while (i < pico.input.key_chars_len - 1) : (i += 1) {
                    pico.input.key_chars[i] = pico.input.key_chars[i + 1];
                }
                pico.input.key_chars_len -= 1;
            } else {
                _ = lua.pushString("");
            }
        },
        32 => {
            if (pico.memory.ram[0x5F2D] & 1 != 0)
                lua.pushNumber(@floatFromInt(pico.input.mouse_x))
            else
                lua.pushNumber(0);
        },
        33 => {
            if (pico.memory.ram[0x5F2D] & 1 != 0)
                lua.pushNumber(@floatFromInt(pico.input.mouse_y))
            else
                lua.pushNumber(0);
        },
        34 => {
            if (pico.memory.ram[0x5F2D] & 1 != 0)
                lua.pushNumber(@floatFromInt(pico.input.mouse_buttons))
            else
                lua.pushNumber(0);
        },
        36 => {
            if (pico.memory.ram[0x5F2D] & 1 != 0)
                lua.pushNumber(@floatFromInt(pico.input.mouse_wheel))
            else
                lua.pushNumber(0);
        },
        46...49 => {
            // Same as 16..19 (newer API alias)
            if (pico.audio) |audio| {
                const ch = &audio.channels[@intCast(n - 46)];
                if (!ch.finished and ch.sfx_id >= 0) {
                    lua.pushNumber(@floatFromInt(ch.note_index));
                } else {
                    lua.pushNumber(0);
                }
            } else lua.pushNumber(0);
        },
        50...53 => {
            // Same as 20..23 (newer API alias)
            if (pico.audio) |audio| {
                const ch = &audio.channels[@intCast(n - 50)];
                if (!ch.finished and ch.sfx_id >= 0) {
                    lua.pushNumber(@floatFromInt(ch.sfx_id));
                } else {
                    lua.pushNumber(-1);
                }
            } else lua.pushNumber(-1);
        },
        54 => {
            // Same as 24 (newer API alias)
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.pattern));
            } else lua.pushNumber(-1);
        },
        55 => {
            // Total patterns played
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.total_patterns));
            } else lua.pushNumber(0);
        },
        56 => {
            // Same as 26 (newer API alias)
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.tick));
            } else lua.pushNumber(0);
        },
        57 => {
            // Music playing bool
            if (pico.audio) |audio| {
                lua.pushBoolean(audio.music_state.playing);
            } else lua.pushBoolean(false);
        },
        80...85 => {
            // UTC time: year, month, day, hour, minute, second
            const c_time = @cImport({ @cInclude("time.h"); });
            const ts = c_time.time(null);
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
            const day_seconds = epoch.getDaySeconds();
            const year_day = epoch.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            switch (n) {
                80 => lua.pushNumber(@floatFromInt(year_day.year)),
                81 => lua.pushNumber(@floatFromInt(@intFromEnum(month_day.month))),
                82 => lua.pushNumber(@floatFromInt(month_day.day_index + 1)),
                83 => lua.pushNumber(@floatFromInt(day_seconds.getHoursIntoDay())),
                84 => lua.pushNumber(@floatFromInt(day_seconds.getMinutesIntoHour())),
                85 => lua.pushNumber(@floatFromInt(day_seconds.getSecondsIntoMinute())),
                else => lua.pushNumber(0),
            }
        },
        90...95 => {
            // Local time via C localtime
            const c_api = @cImport({ @cInclude("time.h"); });
            var ts = c_api.time(null);
            const tm = c_api.localtime(&ts);
            if (tm) |t| {
                switch (n) {
                    90 => lua.pushNumber(@floatFromInt(@as(i32, t.*.tm_year) + 1900)),
                    91 => lua.pushNumber(@floatFromInt(@as(i32, t.*.tm_mon) + 1)),
                    92 => lua.pushNumber(@floatFromInt(t.*.tm_mday)),
                    93 => lua.pushNumber(@floatFromInt(t.*.tm_hour)),
                    94 => lua.pushNumber(@floatFromInt(t.*.tm_min)),
                    95 => lua.pushNumber(@floatFromInt(t.*.tm_sec)),
                    else => lua.pushNumber(0),
                }
            } else lua.pushNumber(0);
        },
        else => lua.pushNumber(0),
    }
    return 1;
}

fn api_time(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    lua.pushNumber(pico.elapsed_time);
    return 1;
}

fn api_printh(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const msg = lua.toString(1) catch "?";
    std.debug.print("{s}\n", .{msg});
    if (pico.debug_log) |log| {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "f{d} printh: {s}\n", .{ pico.frame_count, msg }) catch return 0;
        log.appendSlice(pico.allocator, line) catch {};
    }
    return 0;
}

fn api_cartdata(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const id = lua.toString(1) catch return 0;

    // PICO-8 allows selecting a single cartdata id; re-calling with same id succeeds.
    if (pico.cart_data_id) |existing| {
        if (std.mem.eql(u8, existing, id)) {
            lua.pushBoolean(true);
            return 1;
        }
        return 0;
    }

    const owned_id = pico.allocator.dupe(u8, id) catch return 0;
    cartdata_store.load(pico.allocator, pico.io, pico.memory, owned_id) catch |err| {
        // Transient I/O error — don't commit the ID so retry is possible
        std.log.warn("cartdata load failed for {s}: {}", .{ owned_id, err });
        pico.allocator.free(owned_id);
        return 0;
    };
    pico.cart_data_id = owned_id;
    lua.pushBoolean(true);
    return 1;
}

fn api_dget(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const idx = optInt(lua, 1, 0);
    if (idx >= 0 and idx < 64) {
        const addr: u16 = mem_const.ADDR_CART_DATA + @as(u16, @intCast(idx)) * 4;
        const raw = pico.memory.peek32(addr);
        const fixed: i32 = @bitCast(raw);
        lua.pushNumber(@as(f64, @floatFromInt(fixed)) / 65536.0);
    } else {
        lua.pushNumber(0);
    }
    return 1;
}

fn api_dset(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const idx = optInt(lua, 1, 0);
    const val = luaToNum(lua, 2);
    if (idx >= 0 and idx < 64) {
        const addr: u16 = mem_const.ADDR_CART_DATA + @as(u16, @intCast(idx)) * 4;
        const fixed: i32 = safeFloatToI32(val * 65536.0);
        pico.memory.poke32(addr, @bitCast(fixed));
        if (pico.cart_data_id != null) {
            pico.cart_data_dirty = true;
        }
    }
    return 0;
}

fn api_menuitem(_: *zlua.Lua) c_int {
    return 0;
}

fn api_extcmd(_: *zlua.Lua) c_int {
    return 0;
}

fn api_load(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const name = lua.toString(1) catch return 0;
    if (name.len == 0 or name.len > 255) return 0;
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    pico.pending_load = buf;
    pico.pending_load_len = @intCast(name.len);
    // Store param_str (arg 3) for stat(6) — arg 2 is breadcrumb (ignored)
    if (lua.toString(3)) |ps| {
        const plen = @min(ps.len, pico.param_str.len);
        @memcpy(pico.param_str[0..plen], ps[0..plen]);
        pico.param_str_len = @intCast(plen);
    } else |_| {
        pico.param_str_len = 0;
    }
    // Raise error to abort current Lua execution; main loop handles the load
    _ = lua.raiseErrorStr("cart_load", .{});
    return 0;
}

fn api_run(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    // Signal a reload of the current cart
    pico.pending_load = [_]u8{0} ** 256;
    pico.pending_load_len = 0; // empty name = reload current
    pico.param_str_len = 0;
    _ = lua.raiseErrorStr("cart_run", .{});
    return 0;
}

fn api_stop(_: *zlua.Lua) c_int {
    // No-op — PICO-8 stop() halts and returns to editor, which we don't have
    return 0;
}

fn api_serial(lua: *zlua.Lua) c_int {
    _ = getPico(lua);
    // serial(channel, address, length)
    // Mostly used for GPIO/hardware — stub for desktop
    const channel = optInt(lua, 1, 0);
    _ = channel;
    lua.pushNumber(0);
    return 1;
}

fn api_flip(lua: *zlua.Lua) c_int {
    // PICO-8 flip() blocks for one frame and presents the buffer. We only honor
    // it when called from within a coroutine (yields to host). Carts also call
    // flip() from inside _update/_draw to drive inline scene-transition
    // animations (e.g. fade_in/fade_out) — there's no coroutine to yield to,
    // so we no-op. The cart's state still progresses; the visual animation is
    // just compressed into a single frame.
    _ = getPico(lua);
    // pushThread returns true on the main thread (NOT yieldable). Pop after.
    const is_main = lua.pushThread();
    lua.pop(1);
    if (!is_main) {
        return lua.yield(0);
    }
    return 0;
}

fn api_reset(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    // Reset draw state (0x5F00-0x5F3F) to defaults
    pico.memory.initDrawState();
    return 0;
}

// Helper functions
pub fn luaToNum(lua: *zlua.Lua, idx: i32) f64 {
    return lua.toNumber(idx) catch 0;
}

pub fn luaToInt(lua: *zlua.Lua, idx: i32) i32 {
    const n = lua.toNumber(idx) catch 0;
    return safeFloatToI32(n);
}

pub fn luaToU16(lua: *zlua.Lua, idx: i32) u16 {
    const i = luaToInt(lua, idx);
    return @truncate(@as(u32, @bitCast(i)));
}

pub fn luaToU16Opt(lua: *zlua.Lua, idx: i32, default: u16) u16 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToU16(lua, idx);
}

pub fn luaToU8(lua: *zlua.Lua, idx: i32) u8 {
    const i = luaToInt(lua, idx);
    return @truncate(@as(u32, @bitCast(i)));
}

/// Convert f64 to i32 safely, handling NaN/Inf/out-of-range by clamping.
pub fn safeFloatToI32(n: f64) i32 {
    if (n != n) return 0; // NaN
    if (n >= 2147483647.0) return 2147483647;
    if (n <= -2147483648.0) return -2147483648;
    return @intFromFloat(n);
}

pub fn optInt(lua: *zlua.Lua, idx: i32, default: i32) i32 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToInt(lua, idx);
}

pub fn optNum(lua: *zlua.Lua, idx: i32, default: f64) f64 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToNum(lua, idx);
}
