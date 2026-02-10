const std = @import("std");
const zlua = @import("zlua");
const api_mod = @import("api.zig");
const trig = @import("trigtables.zig");

const luaToNum = api_mod.luaToNum;
const luaToInt = api_mod.luaToInt;
const optNum = api_mod.optNum;
const optInt = api_mod.optInt;
const getPico = api_mod.getPico;

var rng_state: u64 = 0;

fn toFixed(v: f64) i32 {
    return @intFromFloat(v * 65536.0);
}

fn fromFixed(v: i32) f64 {
    return @as(f64, @floatFromInt(v)) / 65536.0;
}

// === Math ===

pub fn api_abs(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    lua.pushNumber(@abs(v));
    return 1;
}

pub fn api_flr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    lua.pushNumber(@floor(v));
    return 1;
}

pub fn api_ceil(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    lua.pushNumber(@ceil(v));
    return 1;
}

pub fn api_sqrt(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    lua.pushNumber(if (v >= 0) @sqrt(v) else 0);
    return 1;
}

// Bit-exact PICO-8 sin using z8lua lookup tables.
// Input is in turns (16.16 fixed-point internally).
fn sinHelper(x_bits: i32) f64 {
    // Reduce angle to 0x0 … 0x3fff range
    // sin(x) = -sin(x + 0.5), sin(x) = sin(~x) rather than sin(-x)
    const folded: i32 = if (x_bits & 0x4000 != 0) ~x_bits else x_bits;
    const a: u32 = @intCast((folded & 0x3fff) + 2);
    const idx: usize = @min(@as(usize, @intCast(a >> 2)), trig.sintable.len - 1);
    const linear: i32 = @intCast(a >> 2 << 4);
    const correction: i32 = @intCast(trig.sintable[idx]);
    const result_bits: i32 = linear + correction;
    const result: f64 = @as(f64, @floatFromInt(result_bits)) / 65536.0;
    // Sign: bit 15 set means positive (PICO-8 sin is inverted)
    return if (x_bits & 0x8000 != 0) result else -result;
}

pub fn api_sin(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    const bits = toFixed(v);
    lua.pushNumber(sinHelper(bits));
    return 1;
}

pub fn api_cos(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    // cos(x) = sin(x - 0.25) in turns
    const bits = toFixed(v) -% 0x4000;
    lua.pushNumber(sinHelper(bits));
    return 1;
}

pub fn api_atan2(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const dx = luaToNum(lua, 1);
    const dy = luaToNum(lua, 2);
    const x_bits: i32 = toFixed(dx);
    const y_bits: i32 = toFixed(dy);

    var bits: i32 = 0x4000;
    if (x_bits != 0) {
        const ax: i64 = if (y_bits < 0) -@as(i64, y_bits) else @as(i64, y_bits);
        const bx: i64 = if (x_bits < 0) -@as(i64, x_bits) else @as(i64, x_bits);
        const q: i64 = @divTrunc(ax << 16, bx);
        if (q > 0x10000) {
            const inv_q: u64 = @intCast(@divTrunc(@as(i64, 1) << 32, q));
            bits -= @as(i32, @intCast(trig.atantable[@intCast(inv_q >> 5)]));
        } else {
            bits = @as(i32, @intCast(trig.atantable[@intCast(@as(u64, @intCast(q)) >> 5)]));
        }
    }
    if (x_bits < 0) bits = 0x8000 - bits;
    if (y_bits > 0) bits = -bits & 0xffff;
    // Emulate PICO-8 bug with e.g. atan2(1, 0x8000)
    if (x_bits != 0 and y_bits == @as(i32, @bitCast(@as(u32, 0x80000000)))) bits = -bits & 0xffff;

    lua.pushNumber(@as(f64, @floatFromInt(bits)) / 65536.0);
    return 1;
}

pub fn api_max(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = luaToNum(lua, 1);
    const b = luaToNum(lua, 2);
    lua.pushNumber(@max(a, b));
    return 1;
}

pub fn api_min(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = luaToNum(lua, 1);
    const b = luaToNum(lua, 2);
    lua.pushNumber(@min(a, b));
    return 1;
}

pub fn api_mid(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = luaToNum(lua, 1);
    const b = luaToNum(lua, 2);
    const c = luaToNum(lua, 3);
    lua.pushNumber(@max(@min(a, b), @min(@max(a, b), c)));
    return 1;
}

pub fn api_rnd(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const max_val = optNum(lua, 1, 1.0);

    // If argument is a table, return random element
    if (lua.typeOf(1) == .table) {
        const len = lua.rawLen(1);
        if (len == 0) {
            lua.pushNil();
            return 1;
        }
        const idx = @mod(xorshift(), len) + 1;
        _ = lua.rawGetIndex(1, @intCast(idx));
        return 1;
    }

    const r = @as(f64, @floatFromInt(xorshift())) / 4294967296.0;
    lua.pushNumber(r * max_val);
    return 1;
}

fn xorshift() u32 {
    if (rng_state == 0) rng_state = 0x12345678;
    var s = @as(u32, @truncate(rng_state));
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    rng_state = s;
    return s;
}

pub fn api_srand(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    rng_state = @bitCast(@as(i64, @intFromFloat(v * 65536.0)));
    if (rng_state == 0) rng_state = 1;
    return 0;
}

pub fn api_sgn(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const v = luaToNum(lua, 1);
    lua.pushNumber(if (v < 0) @as(f64, -1.0) else @as(f64, 1.0));
    return 1;
}

// === Bitwise (float64 <-> 16:16 fixed-point i32) ===

pub fn api_band(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    const b = toFixed(luaToNum(lua, 2));
    lua.pushNumber(fromFixed(a & b));
    return 1;
}

pub fn api_bor(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    const b = toFixed(luaToNum(lua, 2));
    lua.pushNumber(fromFixed(a | b));
    return 1;
}

pub fn api_bxor(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    const b = toFixed(luaToNum(lua, 2));
    lua.pushNumber(fromFixed(a ^ b));
    return 1;
}

pub fn api_bnot(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    lua.pushNumber(fromFixed(~a));
    return 1;
}

pub fn api_shl(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    const b = luaToInt(lua, 2);
    if (b >= 0) {
        const shift: u5 = @intCast(@min(b, 31));
        lua.pushNumber(fromFixed(a << shift));
    } else {
        const shift: u5 = @intCast(@min(-b, 31));
        lua.pushNumber(fromFixed(a >> shift));
    }
    return 1;
}

pub fn api_shr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a = toFixed(luaToNum(lua, 1));
    const b = luaToInt(lua, 2);
    if (b >= 0) {
        const shift: u5 = @intCast(@min(b, 31));
        lua.pushNumber(fromFixed(a >> shift));
    } else {
        const shift: u5 = @intCast(@min(-b, 31));
        lua.pushNumber(fromFixed(a << shift));
    }
    return 1;
}

pub fn api_lshr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a: u32 = @bitCast(toFixed(luaToNum(lua, 1)));
    const b = luaToInt(lua, 2);
    const clamped: u32 = @intCast(@max(@min(b, 31), 0));
    const shift: u5 = @intCast(clamped);
    lua.pushNumber(fromFixed(@bitCast(a >> shift)));
    return 1;
}

pub fn api_rotl(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a: u32 = @bitCast(toFixed(luaToNum(lua, 1)));
    const b = luaToInt(lua, 2);
    const shift: u5 = @intCast(@as(u32, @bitCast(@mod(b, 32))));
    lua.pushNumber(fromFixed(@bitCast(std.math.rotl(u32, a, shift))));
    return 1;
}

pub fn api_rotr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const a: u32 = @bitCast(toFixed(luaToNum(lua, 1)));
    const b = luaToInt(lua, 2);
    const shift: u5 = @intCast(@as(u32, @bitCast(@mod(b, 32))));
    lua.pushNumber(fromFixed(@bitCast(std.math.rotr(u32, a, shift))));
    return 1;
}

// === String/Type ===

pub fn api_tostr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const flags = optInt(lua, 2, 0);

    if (lua.isNone(1)) {
        _ = lua.pushString("");
        return 1;
    }

    if (lua.isNil(1)) {
        _ = lua.pushString("[nil]");
        return 1;
    }

    if (lua.isBoolean(1)) {
        const b = lua.toBoolean(1);
        _ = lua.pushString(if (b) "true" else "false");
        return 1;
    }

    if (lua.isNumber(1)) {
        const n = lua.toNumber(1) catch 0;
        if (flags == 0x3) {
            // Hex + shift: raw hex integer without dot
            const fixed: u32 = @bitCast(toFixed(n));
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "0x{x:0>8}", .{fixed}) catch "0x00000000";
            _ = lua.pushString(s);
        } else if (flags & 0x2 != 0) {
            // Shift left 16 bits and display as signed integer
            const fixed: i32 = toFixed(n);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{fixed}) catch "0";
            _ = lua.pushString(s);
        } else if (flags & 0x1 != 0) {
            // Hex format: "0xHHHH.LLLL" (16.16 fixed-point with dot)
            const fixed: u32 = @bitCast(toFixed(n));
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "0x{x:0>4}.{x:0>4}", .{ fixed >> 16, fixed & 0xFFFF }) catch "0x0000.0000";
            _ = lua.pushString(s);
        } else {
            var buf: [32]u8 = undefined;
            const s = formatPicoNum(n, &buf);
            _ = lua.pushString(s);
        }
        return 1;
    }

    // Default: convert via Lua's tostring
    const s = lua.toString(1) catch "[?]";
    _ = lua.pushString(s);
    return 1;
}

fn formatPicoNum(n: f64, buf: []u8) []const u8 {
    if (n == @floor(n) and @abs(n) < 32768) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i32, @intFromFloat(n))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d:.4}", .{n}) catch "0";
}

pub fn api_tonum(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const flags = optInt(lua, 2, 0);

    if (lua.isNumber(1)) {
        if (flags & 0x2 != 0) {
            // Format flag 0x2: treat as 16.16 fixed-point and shift left 16
            const n = lua.toNumber(1) catch 0;
            const fixed: i32 = @intFromFloat(n * 65536.0);
            lua.pushNumber(@as(f64, @floatFromInt(fixed)) / 65536.0);
        } else {
            lua.pushValue(1);
        }
        return 1;
    }
    if (lua.isBoolean(1)) {
        if (flags & 0x4 != 0) {
            // Format flag 0x4: convert booleans to numbers
            lua.pushNumber(if (lua.toBoolean(1)) 1.0 else 0.0);
        } else {
            lua.pushNil();
        }
        return 1;
    }
    if (lua.isString(1)) {
        const s = lua.toString(1) catch {
            if (flags & 0x4 != 0) {
                lua.pushNumber(0);
            } else {
                lua.pushNil();
            }
            return 1;
        };

        // Flag 0x1: read as hex without prefix (non-hex chars treated as 0)
        if (flags & 0x1 != 0) {
            var val: u32 = 0;
            for (s) |ch| {
                val = val *% 16 +% switch (ch) {
                    '0'...'9' => @as(u32, ch - '0'),
                    'a'...'f' => @as(u32, ch - 'a' + 10),
                    'A'...'F' => @as(u32, ch - 'A' + 10),
                    else => 0,
                };
            }
            if (flags & 0x2 != 0) {
                // 0x3: treat as 16.16 fixed-point
                const fixed: i32 = @bitCast(val);
                lua.pushNumber(@as(f64, @floatFromInt(fixed)) / 65536.0);
            } else {
                lua.pushNumber(@floatFromInt(val));
            }
            return 1;
        }

        // Flag 0x2: read as signed integer, shift right 16
        if (flags & 0x2 != 0) {
            const v = std.fmt.parseInt(i32, s, 10) catch {
                if (flags & 0x4 != 0) {
                    lua.pushNumber(0);
                } else {
                    lua.pushNil();
                }
                return 1;
            };
            lua.pushNumber(@as(f64, @floatFromInt(v)) / 65536.0);
            return 1;
        }

        // Try hex with optional dot (16.16 fixed-point: "0xHHHH.LLLL")
        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            // Find dot separator
            var dot_pos: ?usize = null;
            for (s[2..], 2..) |ch, idx| {
                if (ch == '.') {
                    dot_pos = idx;
                    break;
                }
            }
            if (dot_pos) |dp| {
                // Parse as 16.16: integer part . fractional part (both hex)
                const int_part = std.fmt.parseInt(i32, s[2..dp], 16) catch {
                    if (flags & 0x4 != 0) { lua.pushNumber(0); } else { lua.pushNil(); }
                    return 1;
                };
                const frac_str = s[dp + 1 ..];
                const frac_part = std.fmt.parseInt(u32, frac_str, 16) catch {
                    if (flags & 0x4 != 0) { lua.pushNumber(0); } else { lua.pushNil(); }
                    return 1;
                };
                // Scale frac_part to 16 bits based on number of hex digits
                const shift: u5 = @intCast(@min(4 - @min(frac_str.len, 4), 4) * 4);
                const frac_scaled = frac_part << shift;
                const fixed: i32 = (int_part << 16) | @as(i32, @intCast(frac_scaled & 0xFFFF));
                lua.pushNumber(@as(f64, @floatFromInt(fixed)) / 65536.0);
            } else {
                const v = std.fmt.parseInt(i64, s[2..], 16) catch {
                    if (flags & 0x4 != 0) { lua.pushNumber(0); } else { lua.pushNil(); }
                    return 1;
                };
                lua.pushNumber(@floatFromInt(v));
            }
            return 1;
        }
        // Try binary
        if (s.len > 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B')) {
            const v = std.fmt.parseInt(i64, s[2..], 2) catch {
                if (flags & 0x4 != 0) { lua.pushNumber(0); } else { lua.pushNil(); }
                return 1;
            };
            lua.pushNumber(@floatFromInt(v));
            return 1;
        }
        const v = std.fmt.parseFloat(f64, s) catch {
            if (flags & 0x4 != 0) { lua.pushNumber(0); } else { lua.pushNil(); }
            return 1;
        };
        lua.pushNumber(v);
        return 1;
    }
    if (flags & 0x4 != 0) {
        lua.pushNumber(0);
    } else {
        lua.pushNil();
    }
    return 1;
}

// === Table ===

pub fn api_add(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) return 0;
    const len = lua.rawLen(1);

    if (lua.isNoneOrNil(3)) {
        // add(t, v) - append
        lua.pushValue(2);
        lua.rawSetIndex(1, @intCast(len + 1));
    } else {
        // add(t, v, i) - insert at position
        const pos = luaToInt(lua, 3);
        if (pos < 1) return 0;
        // Shift elements up
        var i: i32 = @intCast(len);
        while (i >= pos) : (i -= 1) {
            _ = lua.rawGetIndex(1, @intCast(i));
            lua.rawSetIndex(1, @intCast(i + 1));
        }
        lua.pushValue(2);
        lua.rawSetIndex(1, @intCast(pos));
    }
    lua.pushValue(2);
    return 1;
}

pub fn api_del(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) return 0;
    const len: i32 = @intCast(lua.rawLen(1));

    // Find value
    var idx: i32 = 1;
    while (idx <= len) : (idx += 1) {
        _ = lua.rawGetIndex(1, @intCast(idx));
        lua.pushValue(2);
        if (lua.compare(-2, -1, .eq)) {
            lua.pop(2);
            // Remove and shift down
            _ = lua.rawGetIndex(1, @intCast(idx));
            var i = idx;
            while (i < len) : (i += 1) {
                _ = lua.rawGetIndex(1, @intCast(i + 1));
                lua.rawSetIndex(1, @intCast(i));
            }
            lua.pushNil();
            lua.rawSetIndex(1, @intCast(len));
            return 1; // return removed element (already on stack)
        }
        lua.pop(2);
    }
    return 0;
}

pub fn api_deli(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) return 0;
    const len: i32 = @intCast(lua.rawLen(1));
    const idx = if (lua.isNoneOrNil(2)) len else luaToInt(lua, 2);
    if (idx < 1 or idx > len) return 0;

    _ = lua.rawGetIndex(1, @intCast(idx)); // return value
    var i = idx;
    while (i < len) : (i += 1) {
        _ = lua.rawGetIndex(1, @intCast(i + 1));
        lua.rawSetIndex(1, @intCast(i));
    }
    lua.pushNil();
    lua.rawSetIndex(1, @intCast(len));
    return 1;
}

pub fn api_count(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) {
        lua.pushNumber(0);
        return 1;
    }

    if (lua.isNoneOrNil(2)) {
        lua.pushNumber(@floatFromInt(lua.rawLen(1)));
    } else {
        // Count occurrences of value
        const len: i32 = @intCast(lua.rawLen(1));
        var cnt: i32 = 0;
        var i: i32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(1, @intCast(i));
            lua.pushValue(2);
            if (lua.compare(-2, -1, .eq)) cnt += 1;
            lua.pop(2);
        }
        lua.pushNumber(@floatFromInt(cnt));
    }
    return 1;
}

pub fn api_foreach(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) return 0;
    var i: i32 = 1;
    while (true) {
        const len: i32 = @intCast(lua.rawLen(1));
        if (i > len) break;
        lua.pushValue(2); // function
        _ = lua.rawGetIndex(1, @intCast(i));
        lua.protectedCall(.{ .args = 1, .results = 0 }) catch break;
        // Only advance index if no deletion occurred during the callback
        if (@as(i32, @intCast(lua.rawLen(1))) >= len) i += 1;
    }
    return 0;
}

pub fn api_all(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    // Return an iterator function
    lua.pushValue(1); // table (upvalue 1)
    lua.pushNumber(0); // index (upvalue 2)
    lua.pushNumber(@floatFromInt(@as(i32, @intCast(lua.rawLen(1))))); // prev_len (upvalue 3)
    lua.pushClosure(struct {
        fn f(state: ?*zlua.LuaState) callconv(.c) i32 {
            const l: *zlua.Lua = @ptrCast(state);
            const idx_f = l.toNumber(zlua.Lua.upvalueIndex(2)) catch 0;
            const prev_len_f = l.toNumber(zlua.Lua.upvalueIndex(3)) catch 0;
            var idx: i32 = @intFromFloat(idx_f);
            const prev_len: i32 = @intFromFloat(prev_len_f);
            const table_idx = zlua.Lua.upvalueIndex(1);
            const len: i32 = @intCast(l.rawLen(table_idx));
            // Only advance index if no deletion occurred since last call
            if (len >= prev_len) {
                idx += 1;
            }
            if (idx > len) {
                l.pushNil();
                return 1;
            }
            l.pushNumber(@floatFromInt(idx));
            l.replace(zlua.Lua.upvalueIndex(2));
            l.pushNumber(@floatFromInt(len));
            l.replace(zlua.Lua.upvalueIndex(3));
            _ = l.rawGetIndex(table_idx, @intCast(idx));
            return 1;
        }
    }.f, 3);
    return 1;
}

pub fn api_pack(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const n = lua.getTop();
    lua.createTable(@intCast(n), 1);
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        lua.pushValue(i);
        lua.rawSetIndex(-2, @intCast(i));
    }
    lua.pushNumber(@floatFromInt(n));
    lua.setField(-2, "n");
    return 1;
}

pub fn api_unpack(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    if (!lua.isTable(1)) return 0;
    const start = optInt(lua, 2, 1);
    const end_val = if (lua.isNoneOrNil(3)) @as(i32, @intCast(lua.rawLen(1))) else luaToInt(lua, 3);
    var i = start;
    var count: i32 = 0;
    while (i <= end_val) : (i += 1) {
        _ = lua.rawGetIndex(1, @intCast(i));
        count += 1;
    }
    return count;
}

// === String ===

pub fn api_sub(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const s = lua.toString(1) catch {
        _ = lua.pushString("");
        return 1;
    };
    const start_raw = optInt(lua, 2, 1);
    const end_raw = optInt(lua, 3, @as(i32, @intCast(s.len)));

    const len: i32 = @intCast(s.len);
    var start = if (start_raw < 0) @max(len + start_raw + 1, 1) else @max(start_raw, 1);
    var end_val = if (end_raw < 0) len + end_raw + 1 else @min(end_raw, len);
    _ = &start;
    _ = &end_val;

    if (start > end_val or start > len) {
        _ = lua.pushString("");
        return 1;
    }

    const si: usize = @intCast(start - 1);
    const ei: usize = @intCast(end_val);
    _ = lua.pushString(s[si..ei]);
    return 1;
}

pub fn api_chr(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const nargs = lua.getTop();
    if (nargs <= 1) {
        const n = luaToInt(lua, 1);
        if (n >= 0 and n <= 255) {
            const buf = [_]u8{@intCast(@as(u32, @bitCast(n)))};
            _ = lua.pushString(&buf);
        } else {
            _ = lua.pushString("");
        }
        return 1;
    }
    // Multi-arg: chr(n1, n2, ...) -> concatenated string
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var i: i32 = 1;
    while (i <= nargs and len < 256) : (i += 1) {
        const n = luaToInt(lua, i);
        if (n >= 0 and n <= 255) {
            buf[len] = @intCast(@as(u32, @bitCast(n)));
            len += 1;
        }
    }
    _ = lua.pushString(buf[0..len]);
    return 1;
}

pub fn api_ord(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const s = lua.toString(1) catch {
        lua.pushNumber(0);
        return 1;
    };
    const idx = optInt(lua, 2, 1);
    const num_results = optInt(lua, 3, 1);
    var count: i32 = 0;
    var i: i32 = 0;
    while (i < num_results) : (i += 1) {
        const pos = idx + i;
        if (pos >= 1 and pos <= @as(i32, @intCast(s.len))) {
            lua.pushNumber(@floatFromInt(s[@intCast(pos - 1)]));
            count += 1;
        } else {
            lua.pushNil();
            count += 1;
        }
    }
    return count;
}

pub fn api_split(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const s = lua.toString(1) catch {
        lua.createTable(0, 0);
        return 1;
    };

    const convert = if (lua.isNoneOrNil(3)) true else lua.toBoolean(3);

    lua.createTable(0, 0);
    var idx: i32 = 1;

    // When separator is a number n, split into n-character groups
    if (lua.isNumber(2)) {
        const n_raw = lua.toNumber(2) catch 1;
        const n: usize = if (n_raw < 1) 1 else @intFromFloat(n_raw);
        var pos: usize = 0;
        while (pos < s.len) {
            const end = @min(pos + n, s.len);
            const part = s[pos..end];
            if (convert) {
                const num = std.fmt.parseFloat(f64, part) catch {
                    _ = lua.pushString(part);
                    lua.rawSetIndex(-2, @intCast(idx));
                    idx += 1;
                    pos = end;
                    continue;
                };
                lua.pushNumber(num);
            } else {
                _ = lua.pushString(part);
            }
            lua.rawSetIndex(-2, @intCast(idx));
            idx += 1;
            pos = end;
        }
        return 1;
    }

    const sep_str = lua.toString(2) catch ",";

    if (sep_str.len == 0) {
        // Split into individual characters
        for (s) |ch| {
            _ = lua.pushString(&[_]u8{ch});
            lua.rawSetIndex(-2, @intCast(idx));
            idx += 1;
        }
        return 1;
    }

    var iter = std.mem.splitSequence(u8, s, sep_str);
    while (iter.next()) |part| {
        if (convert) {
            // Try to convert to number
            const num = std.fmt.parseFloat(f64, part) catch {
                _ = lua.pushString(part);
                lua.rawSetIndex(-2, @intCast(idx));
                idx += 1;
                continue;
            };
            lua.pushNumber(num);
        } else {
            _ = lua.pushString(part);
        }
        lua.rawSetIndex(-2, @intCast(idx));
        idx += 1;
    }
    return 1;
}

// === Coroutines ===

pub fn api_cocreate(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const thread = lua.newThread();
    lua.pushValue(1); // function
    lua.xMove(thread, 1); // move function to new thread
    return 1;
}

pub fn api_coresume(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const thread = lua.toThread(1) catch {
        lua.pushBoolean(false);
        return 1;
    };

    // Push arguments
    const nargs = lua.getTop() - 1;
    if (nargs > 0) {
        var i: i32 = 2;
        while (i <= lua.getTop()) : (i += 1) {
            lua.pushValue(i);
        }
        lua.xMove(thread, nargs);
    }

    _ = thread.resumeThread(lua, nargs) catch {
        lua.pushBoolean(false);
        if (thread.toString(-1)) |msg| {
            _ = lua.pushString(msg);
        } else |_| {
            _ = lua.pushString("error in coroutine");
        }
        return 2;
    };

    // Get results from thread
    const nresults = thread.getTop();
    lua.pushBoolean(true);
    if (nresults > 0) {
        thread.xMove(lua, nresults);
    }
    return nresults + 1;
}

pub fn api_costatus(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const thread = lua.toThread(1) catch {
        _ = lua.pushString("dead");
        return 1;
    };
    const status = thread.status();
    const s: [:0]const u8 = switch (status) {
        .ok => if (thread.getTop() > 0) "suspended" else "dead",
        .yield => "suspended",
        else => "dead",
    };
    _ = lua.pushString(s);
    return 1;
}

pub fn api_yield(lua: *zlua.Lua) i32 {
    _ = getPico(lua);
    const nargs = lua.getTop();
    return lua.yield(nargs);
}
