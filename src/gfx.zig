const std = @import("std");
const zlua = @import("zlua");
const api_mod = @import("api.zig");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const palette = @import("palette.zig");
const font = @import("gfx_font.zig");

const getPico = api_mod.getPico;
const luaToNum = api_mod.luaToNum;
const luaToInt = api_mod.luaToInt;
const optInt = api_mod.optInt;
const optNum = api_mod.optNum;

fn getColor(memory: *Memory, lua: *zlua.Lua, idx: i32) u4 {
    if (lua.isNoneOrNil(idx)) {
        return @truncate(memory.ram[mem_const.ADDR_COLOR] & 0x0F);
    }
    const c: u8 = @truncate(@as(u32, @bitCast(luaToInt(lua, idx))) & 0xFF);
    memory.ram[mem_const.ADDR_COLOR] = c;
    return @truncate(c & 0x0F);
}

fn getDrawPal(memory: *Memory, col: u4) u4 {
    return @truncate(memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, col)] & 0x0F);
}

fn isTransparent(memory: *Memory, col: u4) bool {
    return memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, col)] & 0x10 != 0;
}

fn getScreenPal(memory: *Memory, col: u4) u4 {
    return @truncate(memory.ram[mem_const.ADDR_SCREEN_PAL + @as(u16, col)] & 0x0F);
}

fn getCamera(memory: *Memory) struct { x: i32, y: i32 } {
    const cx: i16 = @bitCast(memory.peek16(mem_const.ADDR_CAMERA_X));
    const cy: i16 = @bitCast(memory.peek16(mem_const.ADDR_CAMERA_Y));
    return .{ .x = cx, .y = cy };
}

fn getClip(memory: *Memory) struct { x0: i32, y0: i32, x1: i32, y1: i32 } {
    return .{
        .x0 = memory.ram[mem_const.ADDR_CLIP_LEFT],
        .y0 = memory.ram[mem_const.ADDR_CLIP_TOP],
        .x1 = memory.ram[mem_const.ADDR_CLIP_RIGHT],
        .y1 = memory.ram[mem_const.ADDR_CLIP_BOTTOM],
    };
}

fn getFillPattern(memory: *Memory) u16 {
    return memory.peek16(mem_const.ADDR_FILL_PAT);
}

fn putPixel(memory: *Memory, x: i32, y: i32, col: u4) void {
    const cam = getCamera(memory);
    const sx = x - cam.x;
    const sy = y - cam.y;
    putPixelRaw(memory, sx, sy, col);
}

fn putPixelRaw(memory: *Memory, sx: i32, sy: i32, col: u4) void {
    const clip = getClip(memory);
    if (sx < clip.x0 or sx >= clip.x1 or sy < clip.y0 or sy >= clip.y1) return;
    if (sx < 0 or sx >= 128 or sy < 0 or sy >= 128) return;

    // Fill pattern check
    const pat = getFillPattern(memory);
    if (pat != 0) {
        const px: u4 = @intCast(@as(u32, @bitCast(sx)) & 3);
        const py: u4 = @intCast(@as(u32, @bitCast(sy)) & 3);
        const bit_idx: u4 = py * 4 + px;
        if (pat & (@as(u16, 1) << bit_idx) != 0) {
            // Bit is set in fill pattern - check transparency flag
            const fill_trans = memory.ram[mem_const.ADDR_FILL_PAT + 2];
            if (fill_trans & 0x1 != 0) return; // transparent
            // Use secondary fill color (high nibble of color byte)
            const color_byte = memory.ram[mem_const.ADDR_COLOR];
            const secondary: u4 = @intCast(color_byte >> 4);
            const mapped = getDrawPal(memory, secondary);
            memory.screenSet(@intCast(@as(u32, @bitCast(sx)) & 0x7F), @intCast(@as(u32, @bitCast(sy)) & 0x7F), mapped);
            return;
        }
    }

    const mapped = getDrawPal(memory, col);
    memory.screenSet(@intCast(@as(u32, @bitCast(sx)) & 0x7F), @intCast(@as(u32, @bitCast(sy)) & 0x7F), mapped);
}

fn putPixelNoCam(memory: *Memory, sx: i32, sy: i32, col: u4) void {
    const clip = getClip(memory);
    if (sx < clip.x0 or sx >= clip.x1 or sy < clip.y0 or sy >= clip.y1) return;
    if (sx < 0 or sx >= 128 or sy < 0 or sy >= 128) return;
    const mapped = getDrawPal(memory, col);
    memory.screenSet(@intCast(@as(u32, @bitCast(sx)) & 0x7F), @intCast(@as(u32, @bitCast(sy)) & 0x7F), mapped);
}

pub fn renderToARGB(memory: *Memory, pixel_buffer: *[128 * 128]u32) void {
    for (0..128) |y| {
        for (0..128) |x| {
            const col = memory.screenGet(@intCast(x), @intCast(y));
            const screen_col = getScreenPal(memory, col);
            // Map to extended palette if high bit set
            const pal_idx: usize = screen_col;
            pixel_buffer[y * 128 + x] = palette.colors[pal_idx];
        }
    }
}

// === API Functions ===

pub fn api_cls(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const col = getColor(pico.memory, lua, 1);
    // Fill screen memory directly
    const byte = @as(u8, col) | (@as(u8, col) << 4);
    @memset(pico.memory.ram[mem_const.ADDR_SCREEN..mem_const.ADDR_SCREEN_END], byte);
    // Reset cursor
    pico.memory.ram[mem_const.ADDR_CURSOR_X] = 0;
    pico.memory.ram[mem_const.ADDR_CURSOR_Y] = 0;
    // Reset clip to full screen
    pico.memory.ram[mem_const.ADDR_CLIP_LEFT] = 0;
    pico.memory.ram[mem_const.ADDR_CLIP_TOP] = 0;
    pico.memory.ram[mem_const.ADDR_CLIP_RIGHT] = 128;
    pico.memory.ram[mem_const.ADDR_CLIP_BOTTOM] = 128;
    return 0;
}

pub fn api_pset(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    const col = getColor(pico.memory, lua, 3);
    putPixel(pico.memory, x, y, col);
    return 0;
}

pub fn api_pget(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    if (x < 0 or x >= 128 or y < 0 or y >= 128) {
        lua.pushNumber(0);
        return 1;
    }
    const col = pico.memory.screenGet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))));
    lua.pushNumber(@floatFromInt(col));
    return 1;
}

pub fn api_line(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);

    if (lua.isNoneOrNil(1)) {
        // line() with no args: reset line drawing state
        pico.line_valid = false;
        return 0;
    }

    if (lua.isNoneOrNil(3)) {
        // line(x1, y1, [col]): draw from last endpoint to (x1,y1)
        const x1 = luaToInt(lua, 1);
        const y1 = luaToInt(lua, 2);
        const col = getColor(pico.memory, lua, 3);
        if (pico.line_valid) {
            drawLine(pico.memory, pico.line_x, pico.line_y, x1, y1, col);
        }
        pico.line_x = x1;
        pico.line_y = y1;
        pico.line_valid = true;
        return 0;
    }

    // line(x0, y0, x1, y1, [col])
    const x0 = luaToInt(lua, 1);
    const y0 = luaToInt(lua, 2);
    const x1 = luaToInt(lua, 3);
    const y1 = luaToInt(lua, 4);
    const col = getColor(pico.memory, lua, 5);
    drawLine(pico.memory, x0, y0, x1, y1, col);
    pico.line_x = x1;
    pico.line_y = y1;
    pico.line_valid = true;
    return 0;
}

fn drawLine(memory: *Memory, x0: i32, y0: i32, x1: i32, y1: i32, col: u4) void {
    var dx = if (x1 > x0) x1 - x0 else x0 - x1;
    var dy = if (y1 > y0) y1 - y0 else y0 - y1;
    _ = &dx;
    _ = &dy;
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;
    var cx = x0;
    var cy = y0;

    while (true) {
        putPixel(memory, cx, cy, col);
        if (cx == x1 and cy == y1) break;
        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            cx += sx;
        }
        if (e2 < dx) {
            err += dx;
            cy += sy;
        }
    }
}

pub fn api_rect(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x0 = luaToInt(lua, 1);
    const y0 = luaToInt(lua, 2);
    const x1 = luaToInt(lua, 3);
    const y1 = luaToInt(lua, 4);
    const col = getColor(pico.memory, lua, 5);
    drawLine(pico.memory, x0, y0, x1, y0, col);
    drawLine(pico.memory, x1, y0, x1, y1, col);
    drawLine(pico.memory, x1, y1, x0, y1, col);
    drawLine(pico.memory, x0, y1, x0, y0, col);
    return 0;
}

pub fn api_rectfill(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    var x0 = luaToInt(lua, 1);
    var y0 = luaToInt(lua, 2);
    var x1 = luaToInt(lua, 3);
    var y1 = luaToInt(lua, 4);
    const col = getColor(pico.memory, lua, 5);
    if (x0 > x1) std.mem.swap(i32, &x0, &x1);
    if (y0 > y1) std.mem.swap(i32, &y0, &y1);
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            putPixel(pico.memory, x, y, col);
        }
    }
    return 0;
}

pub fn api_circ(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const cx = luaToInt(lua, 1);
    const cy = luaToInt(lua, 2);
    const r = optInt(lua, 3, 4);
    const col = getColor(pico.memory, lua, 4);
    drawCirc(pico.memory, cx, cy, r, col, false);
    return 0;
}

pub fn api_circfill(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const cx = luaToInt(lua, 1);
    const cy = luaToInt(lua, 2);
    const r = optInt(lua, 3, 4);
    const col = getColor(pico.memory, lua, 4);
    drawCirc(pico.memory, cx, cy, r, col, true);
    return 0;
}

fn drawCirc(memory: *Memory, cx: i32, cy: i32, r: i32, col: u4, fill: bool) void {
    if (r < 0) return;
    if (r == 0) {
        putPixel(memory, cx, cy, col);
        return;
    }

    var x: i32 = r;
    var y: i32 = 0;
    var d: i32 = 1 - r;

    while (x >= y) {
        if (fill) {
            drawLine(memory, cx - x, cy + y, cx + x, cy + y, col);
            drawLine(memory, cx - x, cy - y, cx + x, cy - y, col);
            drawLine(memory, cx - y, cy + x, cx + y, cy + x, col);
            drawLine(memory, cx - y, cy - x, cx + y, cy - x, col);
        } else {
            putPixel(memory, cx + x, cy + y, col);
            putPixel(memory, cx - x, cy + y, col);
            putPixel(memory, cx + x, cy - y, col);
            putPixel(memory, cx - x, cy - y, col);
            putPixel(memory, cx + y, cy + x, col);
            putPixel(memory, cx - y, cy + x, col);
            putPixel(memory, cx + y, cy - x, col);
            putPixel(memory, cx - y, cy - x, col);
        }
        y += 1;
        if (d < 0) {
            d += 2 * y + 1;
        } else {
            x -= 1;
            d += 2 * (y - x) + 1;
        }
    }
}

pub fn api_oval(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x0 = luaToInt(lua, 1);
    const y0 = luaToInt(lua, 2);
    const x1 = luaToInt(lua, 3);
    const y1 = luaToInt(lua, 4);
    const col = getColor(pico.memory, lua, 5);
    drawOval(pico.memory, x0, y0, x1, y1, col, false);
    return 0;
}

pub fn api_ovalfill(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x0 = luaToInt(lua, 1);
    const y0 = luaToInt(lua, 2);
    const x1 = luaToInt(lua, 3);
    const y1 = luaToInt(lua, 4);
    const col = getColor(pico.memory, lua, 5);
    drawOval(pico.memory, x0, y0, x1, y1, col, true);
    return 0;
}

fn drawOval(memory: *Memory, x0: i32, y0: i32, x1: i32, y1: i32, col: u4, fill: bool) void {
    const cx_2 = x0 + x1; // doubled center
    const cy_2 = y0 + y1;
    const rx = if (x1 > x0) x1 - x0 else x0 - x1;
    const ry = if (y1 > y0) y1 - y0 else y0 - y1;
    if (rx == 0 and ry == 0) {
        putPixel(memory, x0, y0, col);
        return;
    }

    const a: i64 = @as(i64, rx) * rx;
    const b: i64 = @as(i64, ry) * ry;

    var x: i32 = rx;
    var y: i32 = 0;
    var dx: i64 = (1 - 2 * @as(i64, rx)) * b;
    var dy: i64 = a;
    var err: i64 = 0;

    while (b * @as(i64, x) * x + a * @as(i64, y) * y <= a * b) {
        if (fill) {
            const lx = @divTrunc(cx_2 - 2 * x, 2);
            const rx2 = @divTrunc(cx_2 + 2 * x, 2);
            const ty = @divTrunc(cy_2 - 2 * y, 2);
            const by = @divTrunc(cy_2 + 2 * y, 2);
            var xi = lx;
            while (xi <= rx2) : (xi += 1) {
                putPixel(memory, xi, ty, col);
                putPixel(memory, xi, by, col);
            }
        } else {
            putPixel(memory, @intCast(@divTrunc(cx_2 + 2 * x, 2)), @intCast(@divTrunc(cy_2 + 2 * y, 2)), col);
            putPixel(memory, @intCast(@divTrunc(cx_2 - 2 * x, 2)), @intCast(@divTrunc(cy_2 + 2 * y, 2)), col);
            putPixel(memory, @intCast(@divTrunc(cx_2 + 2 * x, 2)), @intCast(@divTrunc(cy_2 - 2 * y, 2)), col);
            putPixel(memory, @intCast(@divTrunc(cx_2 - 2 * x, 2)), @intCast(@divTrunc(cy_2 - 2 * y, 2)), col);
        }

        y += 1;
        err += dy;
        dy += 2 * a;
        if (2 * err + dx > 0) {
            x -= 1;
            err += dx;
            dx += 2 * b;
        }
    }
}

pub fn api_spr(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const n = luaToInt(lua, 1);
    const x = luaToInt(lua, 2);
    const y = luaToInt(lua, 3);
    const w = optNum(lua, 4, 1.0);
    const h = optNum(lua, 5, 1.0);
    const flip_x = if (lua.isNoneOrNil(6)) false else lua.toBoolean(6);
    const flip_y = if (lua.isNoneOrNil(7)) false else lua.toBoolean(7);

    const pw: i32 = @intFromFloat(w * 8);
    const ph: i32 = @intFromFloat(h * 8);
    const sx = @mod(n, 16) * 8;
    const sy = @divTrunc(n, 16) * 8;

    drawSprite(pico.memory, sx, sy, x, y, pw, ph, flip_x, flip_y);
    return 0;
}

fn drawSprite(memory: *Memory, sx: i32, sy: i32, dx: i32, dy: i32, w: i32, h: i32, flip_x: bool, flip_y: bool) void {
    const cam = getCamera(memory);
    var py: i32 = 0;
    while (py < h) : (py += 1) {
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const src_x = sx + (if (flip_x) w - 1 - px else px);
            const src_y = sy + (if (flip_y) h - 1 - py else py);
            if (src_x < 0 or src_x >= 128 or src_y < 0 or src_y >= 128) continue;
            const col = memory.spriteGet(@intCast(@as(u32, @bitCast(src_x))), @intCast(@as(u32, @bitCast(src_y))));
            if (isTransparent(memory, col)) continue;
            putPixelRaw(memory, dx + px - cam.x, dy + py - cam.y, col);
        }
    }
}

pub fn api_sspr(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const sx = luaToInt(lua, 1);
    const sy = luaToInt(lua, 2);
    const sw = luaToInt(lua, 3);
    const sh = luaToInt(lua, 4);
    const dx = luaToInt(lua, 5);
    const dy = luaToInt(lua, 6);
    const dw = optInt(lua, 7, sw);
    const dh = optInt(lua, 8, sh);
    const flip_x = if (lua.isNoneOrNil(9)) false else lua.toBoolean(9);
    const flip_y = if (lua.isNoneOrNil(10)) false else lua.toBoolean(10);

    const cam = getCamera(pico.memory);
    if (dw <= 0 or dh <= 0 or sw <= 0 or sh <= 0) return 0;

    var py: i32 = 0;
    while (py < dh) : (py += 1) {
        var px: i32 = 0;
        while (px < dw) : (px += 1) {
            var src_x = sx + @divTrunc((if (flip_x) dw - 1 - px else px) * sw, dw);
            var src_y = sy + @divTrunc((if (flip_y) dh - 1 - py else py) * sh, dh);
            _ = &src_x;
            _ = &src_y;
            if (src_x < 0 or src_x >= 128 or src_y < 0 or src_y >= 128) continue;
            const col = pico.memory.spriteGet(@intCast(@as(u32, @bitCast(src_x))), @intCast(@as(u32, @bitCast(src_y))));
            if (isTransparent(pico.memory, col)) continue;
            putPixelRaw(pico.memory, dx + px - cam.x, dy + py - cam.y, col);
        }
    }
    return 0;
}

pub fn api_map(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const cel_x = optInt(lua, 1, 0);
    const cel_y = optInt(lua, 2, 0);
    const sx = optInt(lua, 3, 0);
    const sy = optInt(lua, 4, 0);
    const cel_w = optInt(lua, 5, 128);
    const cel_h = optInt(lua, 6, 64);
    const layer = optInt(lua, 7, 0);

    var cy: i32 = 0;
    while (cy < cel_h) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < cel_w) : (cx += 1) {
            const mx = cel_x + cx;
            const my = cel_y + cy;
            if (mx < 0 or mx >= 128 or my < 0 or my >= 64) continue;
            const tile = pico.memory.mapGet(@intCast(@as(u32, @bitCast(mx))), @intCast(@as(u32, @bitCast(my))));
            // Tile 0 is empty by default; draw it only if 0x5F36 bit 3 is set
            if (tile == 0 and (pico.memory.ram[0x5F36] & 0x8) == 0) continue;
            if (layer != 0) {
                const flags = pico.memory.ram[mem_const.ADDR_FLAGS + @as(u16, tile)];
                if (flags & @as(u8, @bitCast(@as(i8, @truncate(layer)))) == 0) continue;
            }
            const tile_sx = @as(i32, @intCast(tile % 16)) * 8;
            const tile_sy = @as(i32, @intCast(tile / 16)) * 8;
            drawSprite(pico.memory, tile_sx, tile_sy, sx + cx * 8, sy + cy * 8, 8, 8, false, false);
        }
    }
    return 0;
}

pub fn api_mget(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    if (x < 0 or x >= 128 or y < 0 or y >= 64) {
        lua.pushNumber(0);
    } else {
        lua.pushNumber(@floatFromInt(pico.memory.mapGet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))))));
    }
    return 1;
}

pub fn api_mset(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    const v = luaToInt(lua, 3);
    if (x >= 0 and x < 128 and y >= 0 and y < 64) {
        pico.memory.mapSet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))), @truncate(@as(u32, @bitCast(v))));
    }
    return 0;
}

pub fn api_sget(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    if (x < 0 or x >= 128 or y < 0 or y >= 128) {
        lua.pushNumber(0);
    } else {
        lua.pushNumber(@floatFromInt(pico.memory.spriteGet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))))));
    }
    return 1;
}

pub fn api_sset(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    const col = getColor(pico.memory, lua, 3);
    if (x >= 0 and x < 128 and y >= 0 and y < 128) {
        pico.memory.spriteSet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))), col);
    }
    return 0;
}

pub fn api_fget(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const n = luaToInt(lua, 1);
    if (n < 0 or n >= 256) {
        lua.pushNumber(0);
        return 1;
    }
    const flags = pico.memory.ram[mem_const.ADDR_FLAGS + @as(u16, @intCast(n))];
    if (lua.isNoneOrNil(2)) {
        lua.pushNumber(@floatFromInt(flags));
    } else {
        const bit: u3 = @intCast(@as(u32, @bitCast(luaToInt(lua, 2))) & 7);
        lua.pushBoolean(flags & (@as(u8, 1) << bit) != 0);
    }
    return 1;
}

pub fn api_fset(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const n = luaToInt(lua, 1);
    if (n < 0 or n >= 256) return 0;
    const addr = mem_const.ADDR_FLAGS + @as(u16, @intCast(n));

    if (lua.isNoneOrNil(3)) {
        // fset(n, flags)
        pico.memory.ram[addr] = @truncate(@as(u32, @bitCast(luaToInt(lua, 2))));
    } else {
        // fset(n, bit, val)
        const bit: u3 = @intCast(@as(u32, @bitCast(luaToInt(lua, 2))) & 7);
        const val = lua.toBoolean(3);
        if (val) {
            pico.memory.ram[addr] |= @as(u8, 1) << bit;
        } else {
            pico.memory.ram[addr] &= ~(@as(u8, 1) << bit);
        }
    }
    return 0;
}

pub fn api_print(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const text = lua.toString(1) catch {
        // Try number
        if (lua.isNumber(1)) {
            const n = lua.toNumber(1) catch return 0;
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return 0;
            return printText(pico, lua, s);
        }
        const bool_s: []const u8 = if (lua.toBoolean(1)) "true" else "false";
        return printText(pico, lua, bool_s);
    };

    return printText(pico, lua, text);
}

fn printText(pico: *api_mod.PicoState, lua: *zlua.Lua, text: []const u8) i32 {
    var right_x: i32 = undefined;
    if (lua.isNoneOrNil(2)) {
        // print(str): use cursor position, default color
        const cx: i32 = pico.memory.ram[mem_const.ADDR_CURSOR_X];
        const cy: i32 = pico.memory.ram[mem_const.ADDR_CURSOR_Y];
        const col: u4 = @truncate(pico.memory.ram[mem_const.ADDR_COLOR] & 0x0F);
        right_x = drawText(pico.memory, text, cx, cy, col);
        pico.memory.ram[mem_const.ADDR_CURSOR_Y] = @truncate(@as(u32, @bitCast(cy + 6)) & 0xFF);
    } else if (lua.isNoneOrNil(3)) {
        // print(str, col): use cursor position with color
        const cx: i32 = pico.memory.ram[mem_const.ADDR_CURSOR_X];
        const cy: i32 = pico.memory.ram[mem_const.ADDR_CURSOR_Y];
        const col = getColor(pico.memory, lua, 2);
        right_x = drawText(pico.memory, text, cx, cy, col);
        pico.memory.ram[mem_const.ADDR_CURSOR_Y] = @truncate(@as(u32, @bitCast(cy + 6)) & 0xFF);
    } else {
        // print(str, x, y, [col])
        const x = luaToInt(lua, 2);
        const y = luaToInt(lua, 3);
        const col = getColor(pico.memory, lua, 4);
        right_x = drawText(pico.memory, text, x, y, col);
    }
    lua.pushNumber(@floatFromInt(right_x));
    return 1;
}

fn drawText(memory: *Memory, text: []const u8, start_x: i32, start_y: i32, col: u4) i32 {
    const cam = getCamera(memory);
    var x = start_x - cam.x;
    var y = start_y - cam.y;
    for (text) |ch| {
        if (ch == '\n') {
            x = start_x - cam.x;
            y += 6;
            continue;
        }
        const code: u7 = if (ch > 127) 0 else @intCast(ch);
        drawChar(memory, code, x, y, col);
        x += 4;
    }
    return x + cam.x;
}

fn drawChar(memory: *Memory, code: u7, x: i32, y: i32, col: u4) void {
    var py: u3 = 0;
    while (py < 6) : (py += 1) {
        var px: u3 = 0;
        while (px < 4) : (px += 1) {
            if (font.getPixel(code, px, py)) {
                putPixelNoCam(memory, x + px, y + py, col);
            }
        }
    }
}

pub fn api_cursor(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = optInt(lua, 1, 0);
    const y = optInt(lua, 2, 0);
    pico.memory.ram[mem_const.ADDR_CURSOR_X] = @truncate(@as(u32, @bitCast(x)));
    pico.memory.ram[mem_const.ADDR_CURSOR_Y] = @truncate(@as(u32, @bitCast(y)));
    if (!lua.isNoneOrNil(3)) {
        const col: u4 = @truncate(@as(u32, @bitCast(luaToInt(lua, 3))) & 0xF);
        pico.memory.ram[mem_const.ADDR_COLOR] = col;
    }
    return 0;
}

pub fn api_color(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const prev: u8 = pico.memory.ram[mem_const.ADDR_COLOR];
    const col = optInt(lua, 1, 6);
    pico.memory.ram[mem_const.ADDR_COLOR] = @truncate(@as(u32, @bitCast(col)) & 0xFF);
    lua.pushNumber(@floatFromInt(prev));
    return 1;
}

pub fn api_camera(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    // Return previous camera values
    const prev_x: i16 = @bitCast(pico.memory.peek16(mem_const.ADDR_CAMERA_X));
    const prev_y: i16 = @bitCast(pico.memory.peek16(mem_const.ADDR_CAMERA_Y));
    const x: i16 = @truncate(optInt(lua, 1, 0));
    const y: i16 = @truncate(optInt(lua, 2, 0));
    pico.memory.poke16(mem_const.ADDR_CAMERA_X, @bitCast(x));
    pico.memory.poke16(mem_const.ADDR_CAMERA_Y, @bitCast(y));
    lua.pushNumber(@floatFromInt(prev_x));
    lua.pushNumber(@floatFromInt(prev_y));
    return 2;
}

pub fn api_clip(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    // Return previous clip rect
    const prev_x: i32 = pico.memory.ram[mem_const.ADDR_CLIP_LEFT];
    const prev_y: i32 = pico.memory.ram[mem_const.ADDR_CLIP_TOP];
    const prev_w: i32 = @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_RIGHT]) - prev_x;
    const prev_h: i32 = @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_BOTTOM]) - prev_y;

    if (lua.isNoneOrNil(1)) {
        pico.memory.ram[mem_const.ADDR_CLIP_LEFT] = 0;
        pico.memory.ram[mem_const.ADDR_CLIP_TOP] = 0;
        pico.memory.ram[mem_const.ADDR_CLIP_RIGHT] = 128;
        pico.memory.ram[mem_const.ADDR_CLIP_BOTTOM] = 128;
    } else {
        var x = @max(luaToInt(lua, 1), 0);
        var y = @max(luaToInt(lua, 2), 0);
        var x1 = @min(x + luaToInt(lua, 3), 128);
        var y1 = @min(y + luaToInt(lua, 4), 128);
        // clip_previous: intersect with existing clip rect
        const clip_prev = if (lua.isNoneOrNil(5)) false else lua.toBoolean(5);
        if (clip_prev) {
            x = @max(x, @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_LEFT]));
            y = @max(y, @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_TOP]));
            x1 = @min(x1, @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_RIGHT]));
            y1 = @min(y1, @as(i32, pico.memory.ram[mem_const.ADDR_CLIP_BOTTOM]));
        }
        pico.memory.ram[mem_const.ADDR_CLIP_LEFT] = @intCast(@as(u32, @intCast(x)));
        pico.memory.ram[mem_const.ADDR_CLIP_TOP] = @intCast(@as(u32, @intCast(y)));
        pico.memory.ram[mem_const.ADDR_CLIP_RIGHT] = @intCast(@as(u32, @intCast(x1)));
        pico.memory.ram[mem_const.ADDR_CLIP_BOTTOM] = @intCast(@as(u32, @intCast(y1)));
    }
    lua.pushNumber(@floatFromInt(prev_x));
    lua.pushNumber(@floatFromInt(prev_y));
    lua.pushNumber(@floatFromInt(prev_w));
    lua.pushNumber(@floatFromInt(prev_h));
    return 4;
}

pub fn api_pal(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    if (lua.isNoneOrNil(1)) {
        // Reset palettes
        for (0..16) |i| {
            pico.memory.ram[mem_const.ADDR_DRAW_PAL + i] = @intCast(i);
            pico.memory.ram[mem_const.ADDR_SCREEN_PAL + i] = @intCast(i);
        }
        // Re-set transparency on color 0
        pico.memory.ram[mem_const.ADDR_DRAW_PAL] |= 0x10;
        // Reset fill pattern
        pico.memory.poke16(mem_const.ADDR_FILL_PAT, 0);
        pico.memory.ram[mem_const.ADDR_FILL_PAT + 2] = 0;
        return 0;
    }

    // pal(tbl, [p]): table form
    if (lua.typeOf(1) == .table) {
        const p = optInt(lua, 2, 0);
        var i: i32 = 0;
        while (i < 16) : (i += 1) {
            _ = lua.rawGetIndex(1, @intCast(i));
            if (!lua.isNil(-1)) {
                const val: u4 = @truncate(@as(u32, @bitCast(luaToInt(lua, -1))) & 0xF);
                const ci: u16 = @intCast(i);
                if (p == 1) {
                    pico.memory.ram[mem_const.ADDR_SCREEN_PAL + ci] = val;
                } else {
                    const trans = pico.memory.ram[mem_const.ADDR_DRAW_PAL + ci] & 0x10;
                    pico.memory.ram[mem_const.ADDR_DRAW_PAL + ci] = val | trans;
                }
            }
            lua.pop(1);
        }
        return 0;
    }

    const c0: u4 = @truncate(@as(u32, @bitCast(luaToInt(lua, 1))) & 0xF);
    const c1: u4 = @truncate(@as(u32, @bitCast(luaToInt(lua, 2))) & 0xF);
    const p = optInt(lua, 3, 0);

    if (p == 1) {
        // Screen palette
        pico.memory.ram[mem_const.ADDR_SCREEN_PAL + @as(u16, c0)] = c1;
    } else {
        // Draw palette
        const trans = pico.memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, c0)] & 0x10;
        pico.memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, c0)] = c1 | trans;
    }
    return 0;
}

pub fn api_palt(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    if (lua.isNoneOrNil(1)) {
        // Reset: only color 0 is transparent
        for (0..16) |i| {
            pico.memory.ram[mem_const.ADDR_DRAW_PAL + i] &= 0x0F;
        }
        pico.memory.ram[mem_const.ADDR_DRAW_PAL] |= 0x10;
        return 0;
    }

    const col: u4 = @truncate(@as(u32, @bitCast(luaToInt(lua, 1))) & 0xF);
    const trans = lua.toBoolean(2);
    if (trans) {
        pico.memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, col)] |= 0x10;
    } else {
        pico.memory.ram[mem_const.ADDR_DRAW_PAL + @as(u16, col)] &= 0x0F;
    }
    return 0;
}

pub fn api_tline(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);

    // TLINE(n) with single arg: set precision register
    if (lua.isNoneOrNil(2)) {
        const precision = luaToInt(lua, 1);
        pico.memory.ram[0x5F37] = @truncate(@as(u32, @bitCast(precision)));
        return 0;
    }

    const x0 = luaToInt(lua, 1);
    const y0 = luaToInt(lua, 2);
    const x1 = luaToInt(lua, 3);
    const y1 = luaToInt(lua, 4);
    const mx_start = optNum(lua, 5, 0);
    const my_start = optNum(lua, 6, 0);
    const mdx = optNum(lua, 7, 0.125);
    const mdy = optNum(lua, 8, 0);
    const layer = optInt(lua, 9, 0);

    // Calculate map coordinate masks from 0x5F38, 0x5F39
    const mask_w_raw = pico.memory.ram[0x5F38];
    const mask_h_raw = pico.memory.ram[0x5F39];
    const mask_w: f64 = if (mask_w_raw == 0) 256.0 else @floatFromInt(mask_w_raw);
    const mask_h: f64 = if (mask_h_raw == 0) 256.0 else @floatFromInt(mask_h_raw);

    // Map offsets from 0x5F3A, 0x5F3B
    const offset_x: f64 = @floatFromInt(pico.memory.ram[0x5F3A]);
    const offset_y: f64 = @floatFromInt(pico.memory.ram[0x5F3B]);

    // Check tile 0 skip
    const draw_tile0 = (pico.memory.ram[0x5F36] & 0x8) != 0;

    // Bresenham-style: iterate over screen pixels
    const dx = if (x1 > x0) x1 - x0 else x0 - x1;
    const dy = if (y1 > y0) y1 - y0 else y0 - y1;
    const sx_step: i32 = if (x0 < x1) 1 else -1;
    const sy_step: i32 = if (y0 < y1) 1 else -1;
    var err = dx - dy;
    var cx = x0;
    var cy = y0;
    var mx = mx_start;
    var my = my_start;
    const cam = getCamera(pico.memory);

    while (true) {
        // Sample from map
        const wrapped_mx = @mod(mx + offset_x, mask_w);
        const wrapped_my = @mod(my + offset_y, mask_h);

        const tile_x: i32 = @intFromFloat(@floor(wrapped_mx));
        const tile_y: i32 = @intFromFloat(@floor(wrapped_my));
        const sub_x: u3 = @intCast(@as(u32, @intFromFloat(@floor(@mod(wrapped_mx, 1.0) * 8.0))) & 7);
        const sub_y: u3 = @intCast(@as(u32, @intFromFloat(@floor(@mod(wrapped_my, 1.0) * 8.0))) & 7);

        if (tile_x >= 0 and tile_x < 128 and tile_y >= 0 and tile_y < 64) {
            const tile = pico.memory.mapGet(@intCast(@as(u32, @bitCast(tile_x))), @intCast(@as(u32, @bitCast(tile_y))));
            const should_draw = if (tile == 0) draw_tile0 else true;

            if (should_draw) {
                var draw = true;
                if (layer != 0) {
                    const flags = pico.memory.ram[mem_const.ADDR_FLAGS + @as(u16, tile)];
                    if (flags & @as(u8, @bitCast(@as(i8, @truncate(layer)))) == 0) draw = false;
                }
                if (draw) {
                    const spr_x: u8 = @intCast((@as(u16, tile) % 16) * 8 + sub_x);
                    const spr_y: u8 = @intCast((@as(u16, tile) / 16) * 8 + sub_y);
                    const col = pico.memory.spriteGet(spr_x, spr_y);
                    if (!isTransparent(pico.memory, col)) {
                        putPixelRaw(pico.memory, cx - cam.x, cy - cam.y, col);
                    }
                }
            }
        }

        if (cx == x1 and cy == y1) break;
        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            cx += sx_step;
        }
        if (e2 < dx) {
            err += dx;
            cy += sy_step;
        }
        mx += mdx;
        my += mdy;
    }

    return 0;
}

pub fn api_fillp(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const p = optNum(lua, 1, 0);
    const int_val: u32 = @bitCast(@as(i32, @intFromFloat(p)));
    const pat: u16 = @truncate(int_val);
    pico.memory.poke16(mem_const.ADDR_FILL_PAT, pat);
    // Bit 16 (0b.1) set = use transparency for pattern holes; unset = use secondary color
    const fill_trans: u8 = if (int_val & 0x10000 != 0) 1 else 0;
    pico.memory.ram[mem_const.ADDR_FILL_PAT + 2] = fill_trans;
    return 0;
}
