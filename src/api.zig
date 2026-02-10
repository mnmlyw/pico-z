const std = @import("std");
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const palette = @import("palette.zig");
const gfx = @import("gfx.zig");
const input_mod = @import("input.zig");
const math_api = @import("math_api.zig");
const audio_mod = @import("audio.zig");

pub const SCREEN_W = 128;
pub const SCREEN_H = 128;

pub const PicoState = struct {
    memory: *Memory,
    pixel_buffer: *[SCREEN_W * SCREEN_H]u32,
    input: *input_mod.Input,
    audio: ?*audio_mod.Audio,
    frame_count: u32 = 0,
    start_time: i64 = 0,

    // Line drawing state
    line_x: i32 = 0,
    line_y: i32 = 0,
    line_valid: bool = false,

    // Cartdata
    cart_data_id: ?[]const u8 = null,
    allocator: std.mem.Allocator,
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
    const n = optInt(lua, 2, 1);
    if (n == 1) {
        lua.pushNumber(@floatFromInt(pico.memory.peek(addr)));
        return 1;
    }
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        lua.pushNumber(@floatFromInt(pico.memory.peek(addr +% i)));
    }
    return @intCast(n);
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
    const val: u16 = @intFromFloat(luaToNum(lua, 2));
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
    const fixed: i32 = @intFromFloat(val * 65536.0);
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
    pico.memory.reload(dst, src, len);
    return 0;
}

fn api_cstore(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const dst = luaToU16Opt(lua, 1, 0);
    const src = luaToU16Opt(lua, 2, 0);
    const len = luaToU16Opt(lua, 3, 0x4300);
    // Copy from RAM to ROM (opposite of reload)
    for (0..len) |i| {
        pico.memory.rom[dst +% @as(u16, @intCast(i))] = pico.memory.ram[src +% @as(u16, @intCast(i))];
    }
    return 0;
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
        7 => lua.pushNumber(30), // FPS
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
        32...34 => lua.pushNumber(0), // mouse x, y, buttons
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
        56 => {
            // Same as 26 (newer API alias)
            if (pico.audio) |audio| {
                lua.pushNumber(@floatFromInt(audio.music_state.tick));
            } else lua.pushNumber(0);
        },
        else => lua.pushNumber(0),
    }
    return 1;
}

fn api_time(lua: *zlua.Lua) c_int {
    const pico = getPico(lua);
    const now = std.time.milliTimestamp();
    const elapsed = @as(f64, @floatFromInt(now - pico.start_time)) / 1000.0;
    lua.pushNumber(elapsed);
    return 1;
}

fn api_printh(lua: *zlua.Lua) c_int {
    _ = getPico(lua);
    const msg = lua.toString(1) catch "?";
    std.debug.print("{s}\n", .{msg});
    return 0;
}

fn api_cartdata(lua: *zlua.Lua) c_int {
    _ = getPico(lua);
    // stub: accept but ignore
    return 0;
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
        const fixed: i32 = @intFromFloat(val * 65536.0);
        pico.memory.poke32(addr, @bitCast(fixed));
    }
    return 0;
}

fn api_menuitem(_: *zlua.Lua) c_int {
    return 0;
}

fn api_extcmd(_: *zlua.Lua) c_int {
    return 0;
}

// Helper functions
pub fn luaToNum(lua: *zlua.Lua, idx: i32) f64 {
    return lua.toNumber(idx) catch 0;
}

pub fn luaToInt(lua: *zlua.Lua, idx: i32) i32 {
    const n = lua.toNumber(idx) catch 0;
    return @intFromFloat(n);
}

pub fn luaToU16(lua: *zlua.Lua, idx: i32) u16 {
    const n = lua.toNumber(idx) catch 0;
    const i: i32 = @intFromFloat(n);
    return @truncate(@as(u32, @bitCast(i)));
}

pub fn luaToU16Opt(lua: *zlua.Lua, idx: i32, default: u16) u16 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToU16(lua, idx);
}

pub fn luaToU8(lua: *zlua.Lua, idx: i32) u8 {
    const n = lua.toNumber(idx) catch 0;
    const i: i32 = @intFromFloat(n);
    return @truncate(@as(u32, @bitCast(i)));
}

pub fn optInt(lua: *zlua.Lua, idx: i32, default: i32) i32 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToInt(lua, idx);
}

pub fn optNum(lua: *zlua.Lua, idx: i32, default: f64) f64 {
    if (lua.isNoneOrNil(idx)) return default;
    return luaToNum(lua, idx);
}

