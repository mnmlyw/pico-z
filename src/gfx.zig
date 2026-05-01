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
    const mode = memory.ram[0x5F2C];
    for (0..128) |y| {
        for (0..128) |x| {
            // Apply screen mode transformations
            var sx = x;
            var sy = y;
            switch (mode) {
                1 => sx = x / 2, // horizontal stretch 64→128
                2 => sy = y / 2, // vertical stretch 64→128
                3 => { sx = x / 2; sy = y / 2; }, // zoom 64x64→128x128
                5 => sx = 127 - x, // mirror horizontal
                6 => sy = 127 - y, // mirror vertical
                7 => { sx = 127 - x; sy = 127 - y; }, // mirror both
                else => {},
            }
            const col = memory.screenGet(@intCast(sx), @intCast(sy));
            const screen_col = getScreenPal(memory, col);
            pixel_buffer[y * 128 + x] = palette.colors[screen_col];
        }
    }
}

// === API Functions ===

pub fn api_cls(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    // PICO-8 spec: cls(col) defaults to 0, NOT the current draw color.
    // (Carts often leave ADDR_COLOR set to whatever they last drew with —
    // using that as the cls default would produce a wrong background, e.g.
    // a yellow gameplay floor when the cart finished drawing in yellow.)
    const col: u4 = if (lua.isNoneOrNil(1))
        0
    else
        @truncate(@as(u32, @bitCast(luaToInt(lua, 1))) & 0x0F);
    // Fill screen memory directly — honor 0x5F55 in case the cart has
    // redirected the screen base.
    const byte = @as(u8, col) | (@as(u8, col) << 4);
    const base = pico.memory.screenBase();
    @memset(pico.memory.ram[base..base +% 0x2000], byte);
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
        lua.pushNumber(@floatFromInt(pico.memory.ram[0x5F5B]));
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

    if (lua.isNoneOrNil(4)) {
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

pub fn api_rrect(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    var x0 = luaToInt(lua, 1);
    var y0 = luaToInt(lua, 2);
    var x1 = luaToInt(lua, 3);
    var y1 = luaToInt(lua, 4);
    var r = optInt(lua, 5, 1);
    const col = getColor(pico.memory, lua, 6);
    if (x0 > x1) std.mem.swap(i32, &x0, &x1);
    if (y0 > y1) std.mem.swap(i32, &y0, &y1);
    const max_r = @min(@divTrunc(x1 - x0, 2), @divTrunc(y1 - y0, 2));
    r = @min(r, max_r);
    if (r <= 0) {
        drawLine(pico.memory, x0, y0, x1, y0, col);
        drawLine(pico.memory, x1, y0, x1, y1, col);
        drawLine(pico.memory, x1, y1, x0, y1, col);
        drawLine(pico.memory, x0, y1, x0, y0, col);
        return 0;
    }
    // Straight edges
    drawLine(pico.memory, x0 + r, y0, x1 - r, y0, col); // top
    drawLine(pico.memory, x0 + r, y1, x1 - r, y1, col); // bottom
    drawLine(pico.memory, x0, y0 + r, x0, y1 - r, col); // left
    drawLine(pico.memory, x1, y0 + r, x1, y1 - r, col); // right
    // Corner arcs using Bresenham circle
    drawCornerArc(pico.memory, x0 + r, y0 + r, r, col, 0); // top-left
    drawCornerArc(pico.memory, x1 - r, y0 + r, r, col, 1); // top-right
    drawCornerArc(pico.memory, x1 - r, y1 - r, r, col, 2); // bottom-right
    drawCornerArc(pico.memory, x0 + r, y1 - r, r, col, 3); // bottom-left
    return 0;
}

pub fn api_rrectfill(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    var x0 = luaToInt(lua, 1);
    var y0 = luaToInt(lua, 2);
    var x1 = luaToInt(lua, 3);
    var y1 = luaToInt(lua, 4);
    var r = optInt(lua, 5, 1);
    const col = getColor(pico.memory, lua, 6);
    if (x0 > x1) std.mem.swap(i32, &x0, &x1);
    if (y0 > y1) std.mem.swap(i32, &y0, &y1);
    const max_r = @min(@divTrunc(x1 - x0, 2), @divTrunc(y1 - y0, 2));
    r = @min(r, max_r);
    if (r <= 0) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) putPixel(pico.memory, x, y, col);
        }
        return 0;
    }
    // Fill center rectangle
    var y = y0 + r;
    while (y <= y1 - r) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) putPixel(pico.memory, x, y, col);
    }
    // Fill top/bottom bands with rounded corners using Bresenham
    var cx: i32 = 0;
    var cy: i32 = r;
    var d: i32 = 3 - 2 * r;
    while (cx <= cy) {
        // Top band: rows y0+(r-cy) to y0+(r-1), width narrows
        fillRrectCornerRow(pico.memory, x0 + r, x1 - r, y0 + r - cy, cx, col);
        fillRrectCornerRow(pico.memory, x0 + r, x1 - r, y0 + r - cx, cy, col);
        // Bottom band
        fillRrectCornerRow(pico.memory, x0 + r, x1 - r, y1 - r + cy, cx, col);
        fillRrectCornerRow(pico.memory, x0 + r, x1 - r, y1 - r + cx, cy, col);
        if (d > 0) {
            cy -= 1;
            d += 4 * (cx - cy) + 10;
        } else {
            d += 4 * cx + 6;
        }
        cx += 1;
    }
    return 0;
}

fn fillRrectCornerRow(memory: *Memory, left_cx: i32, right_cx: i32, y: i32, dx: i32, col: u4) void {
    var x = left_cx - dx;
    while (x <= right_cx + dx) : (x += 1) {
        putPixel(memory, x, y, col);
    }
}

fn drawCornerArc(memory: *Memory, cx: i32, cy: i32, r: i32, col: u4, quadrant: u2) void {
    var x: i32 = 0;
    var y: i32 = r;
    var d: i32 = 3 - 2 * r;
    while (x <= y) {
        switch (quadrant) {
            0 => { // top-left
                putPixel(memory, cx - x, cy - y, col);
                putPixel(memory, cx - y, cy - x, col);
            },
            1 => { // top-right
                putPixel(memory, cx + x, cy - y, col);
                putPixel(memory, cx + y, cy - x, col);
            },
            2 => { // bottom-right
                putPixel(memory, cx + x, cy + y, col);
                putPixel(memory, cx + y, cy + x, col);
            },
            3 => { // bottom-left
                putPixel(memory, cx - x, cy + y, col);
                putPixel(memory, cx - y, cy + x, col);
            },
        }
        if (d > 0) {
            y -= 1;
            d += 4 * (x - y) + 10;
        } else {
            d += 4 * x + 6;
        }
        x += 1;
    }
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

    const cam = getCamera(memory);
    const acx = cx - cam.x;
    const acy = cy - cam.y;

    // Check for inverted fill mode (poke(0x5f34, 0x2))
    const invert = fill and (memory.ram[0x5F34] & 0x2 != 0);

    if (r == 0) {
        if (invert) {
            invertFillCirc(memory, acx, acy, 0, col);
        } else {
            putPixelRaw(memory, acx, acy, col);
        }
        return;
    }

    if (invert) {
        invertFillCirc(memory, acx, acy, r, col);
        return;
    }

    var x: i32 = r;
    var y: i32 = 0;
    var d: i32 = 1 - r;

    while (x >= y) {
        if (fill) {
            hline(memory, acx - x, acx + x, acy + y, col);
            hline(memory, acx - x, acx + x, acy - y, col);
            hline(memory, acx - y, acx + y, acy + x, col);
            hline(memory, acx - y, acx + y, acy - x, col);
        } else {
            putPixelRaw(memory, acx + x, acy + y, col);
            putPixelRaw(memory, acx - x, acy + y, col);
            putPixelRaw(memory, acx + x, acy - y, col);
            putPixelRaw(memory, acx - x, acy - y, col);
            putPixelRaw(memory, acx + y, acy + x, col);
            putPixelRaw(memory, acx - y, acy + x, col);
            putPixelRaw(memory, acx + y, acy - x, col);
            putPixelRaw(memory, acx - y, acy - x, col);
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

/// Fast horizontal line fill (screen-space, no camera).
fn hline(memory: *Memory, x0: i32, x1: i32, y: i32, col: u4) void {
    var sx = x0;
    while (sx <= x1) : (sx += 1) {
        putPixelRaw(memory, sx, y, col);
    }
}

/// Fill everything OUTSIDE a circle (inverted circfill for peephole effects).
fn invertFillCirc(memory: *Memory, cx: i32, cy: i32, r: i32, col: u4) void {
    const clip = getClip(memory);

    var sy: i32 = clip.y0;
    while (sy < clip.y1) : (sy += 1) {
        const dy = sy - cy;
        if (dy < -r or dy > r) {
            // Scanline entirely outside circle — fill whole line
            hline(memory, clip.x0, clip.x1 - 1, sy, col);
        } else {
            // Scanline intersects circle — fill left and right of circle
            const dy2 = dy * dy;
            const r2 = r * r;
            const dx = std.math.sqrt(@as(f64, @floatFromInt(r2 - dy2)));
            const left = cx - @as(i32, @intFromFloat(dx));
            const right = cx + @as(i32, @intFromFloat(dx));
            if (clip.x0 < left) hline(memory, clip.x0, left - 1, sy, col);
            if (right + 1 < clip.x1) hline(memory, right + 1, clip.x1 - 1, sy, col);
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
    // Semi-axes: half the bounding box dimensions
    const rx = @divTrunc(if (x1 > x0) x1 - x0 else x0 - x1, 2);
    const ry = @divTrunc(if (y1 > y0) y1 - y0 else y0 - y1, 2);
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

    const pw: i32 = api_mod.safeFloatToI32(w * 8);
    const ph: i32 = api_mod.safeFloatToI32(h * 8);
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

    // Snapshot the source rectangle first. When sprite source and screen
    // destination overlap (e.g. bigprint's "scale up the just-drawn text"
    // trick that pokes 0x5F54=0x60), iterating in place would overwrite
    // source pixels before we've read them. PICO-8 reads atomically via its
    // own buffer, so we mimic that here.
    if (sw > 256 or sh > 256) return 0; // sanity bound
    var src_buf: [256 * 256]u4 = undefined;
    {
        var sj: i32 = 0;
        while (sj < sh) : (sj += 1) {
            var si: i32 = 0;
            while (si < sw) : (si += 1) {
                const ax = sx + si;
                const ay = sy + sj;
                const idx: usize = @intCast(sj * sw + si);
                if (ax < 0 or ax >= 128 or ay < 0 or ay >= 128) {
                    src_buf[idx] = 0;
                } else {
                    src_buf[idx] = pico.memory.spriteGet(@intCast(@as(u32, @bitCast(ax))), @intCast(@as(u32, @bitCast(ay))));
                }
            }
        }
    }

    var py: i32 = 0;
    while (py < dh) : (py += 1) {
        var px: i32 = 0;
        while (px < dw) : (px += 1) {
            const sx_off = @divTrunc((if (flip_x) dw - 1 - px else px) * sw, dw);
            const sy_off = @divTrunc((if (flip_y) dh - 1 - py else py) * sh, dh);
            if (sx_off < 0 or sx_off >= sw or sy_off < 0 or sy_off >= sh) continue;
            const buf_idx: usize = @intCast(sy_off * sw + sx_off);
            const col = src_buf[buf_idx];
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

    const map_w: i32 = if (pico.memory.ram[0x5F57] == 0) 128 else @as(i32, pico.memory.ram[0x5F57]);
    var cy: i32 = 0;
    while (cy < cel_h) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < cel_w) : (cx += 1) {
            const mx = cel_x + cx;
            const my = cel_y + cy;
            if (mx < 0 or mx >= map_w or my < 0 or my >= 64) continue;
            const tile = mapGetWide(pico.memory, mx, my);
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
    const map_w: i32 = if (pico.memory.ram[0x5F57] == 0) 128 else @as(i32, pico.memory.ram[0x5F57]);
    if (x < 0 or x >= map_w or y < 0 or y >= 64) {
        lua.pushNumber(@floatFromInt(pico.memory.ram[0x5F5A]));
    } else {
        lua.pushNumber(@floatFromInt(mapGetWide(pico.memory, x, y)));
    }
    return 1;
}

pub fn api_mset(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    const v = luaToInt(lua, 3);
    const map_w: i32 = if (pico.memory.ram[0x5F57] == 0) 128 else @as(i32, pico.memory.ram[0x5F57]);
    if (x >= 0 and x < map_w and y >= 0 and y < 64) {
        mapSetWide(pico.memory, x, y, @truncate(@as(u32, @bitCast(v))));
    }
    return 0;
}

/// Map access respecting 0x5F57 custom map width (0=128 default)
fn mapGetWide(memory: *Memory, x: i32, y: i32) u8 {
    const map_w: i32 = if (memory.ram[0x5F57] == 0) 128 else @as(i32, memory.ram[0x5F57]);
    if (x < 0 or x >= map_w or y < 0 or y >= 64) return 0;
    // Default layout: rows 0-31 at 0x2000, rows 32-63 at 0x1000 (shared with sprites)
    if (x < 128) {
        return memory.mapGet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))));
    }
    // Extended map (x >= 128): only accessible if map_w > 128
    // Uses memory beyond normal map region — compute address directly
    const addr: u16 = @intCast(@as(u32, @bitCast(y)) * @as(u32, @intCast(map_w)) + @as(u32, @bitCast(x)));
    const base: u16 = @intCast(memory.ram[0x5F56]);
    const map_base = @as(u16, base) * 256;
    return memory.ram[map_base +% addr];
}

fn mapSetWide(memory: *Memory, x: i32, y: i32, val: u8) void {
    const map_w: i32 = if (memory.ram[0x5F57] == 0) 128 else @as(i32, memory.ram[0x5F57]);
    if (x < 0 or x >= map_w or y < 0 or y >= 64) return;
    if (x < 128) {
        memory.mapSet(@intCast(@as(u32, @bitCast(x))), @intCast(@as(u32, @bitCast(y))), val);
        return;
    }
    const addr: u16 = @intCast(@as(u32, @bitCast(y)) * @as(u32, @intCast(map_w)) + @as(u32, @bitCast(x)));
    const base: u16 = @intCast(memory.ram[0x5F56]);
    const map_base = @as(u16, base) * 256;
    memory.ram[map_base +% addr] = val;
}

pub fn api_sget(lua: *zlua.Lua) i32 {
    const pico = getPico(lua);
    const x = luaToInt(lua, 1);
    const y = luaToInt(lua, 2);
    if (x < 0 or x >= 128 or y < 0 or y >= 128) {
        lua.pushNumber(@floatFromInt(pico.memory.ram[0x5F59]));
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

fn parseHexColor(c: u8) u4 {
    return @truncate(if (c >= '0' and c <= '9')
        c - '0'
    else if (c >= 'a' and c <= 'f')
        c - 'a' + 10
    else if (c >= 'A' and c <= 'F')
        c - 'A' + 10
    else
        c & 0x0f);
}

fn drawText(memory: *Memory, text: []const u8, start_x: i32, start_y: i32, col: u4) i32 {
    const cam = getCamera(memory);
    var x = start_x - cam.x;
    var y = start_y - cam.y;
    var color = col;
    var char_w: i32 = 4;
    var char_h: i32 = 6;
    var home_x: i32 = x;
    var home_y: i32 = y;
    var tab_w: i32 = 16;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        i += 1;
        switch (ch) {
            0x01 => { // \* repeat next char N times
                if (i + 1 < text.len) {
                    const count = text[i];
                    const rch = text[i + 1];
                    i += 2;
                    for (0..count) |_| {
                        drawChar(memory, rch, x, y, color);
                        x += char_w;
                    }
                }
            },
            0x02 => { // \# draw char at x,y offset
                if (i + 2 < text.len) {
                    const ox: i32 = @as(i32, @as(i8, @bitCast(text[i])));
                    const oy: i32 = @as(i32, @as(i8, @bitCast(text[i + 1])));
                    const dch = text[i + 2];
                    i += 3;
                    drawChar(memory, dch, x + ox, y + oy, color);
                }
            },
            0x03 => { // \- move cursor horizontally
                if (i < text.len) {
                    x += @as(i32, @as(i8, @bitCast(text[i])));
                    i += 1;
                }
            },
            0x04 => { // \| move cursor vertically
                if (i < text.len) {
                    y += @as(i32, @as(i8, @bitCast(text[i])));
                    i += 1;
                }
            },
            0x05 => { // \+ move cursor to x,y
                if (i + 1 < text.len) {
                    x = start_x - cam.x + @as(i32, text[i]);
                    y = start_y - cam.y + @as(i32, text[i + 1]);
                    i += 2;
                }
            },
            0x06 => { // \^ special commands
                if (i < text.len) {
                    const cmd = text[i];
                    i += 1;
                    switch (cmd) {
                        'w', '-' + 128 => char_w = if (char_w == 8) 4 else 8, // wide mode toggle (\^w / \^-w)
                        't' => char_h = if (char_h == 12) 6 else 12, // tall mode toggle
                        '=' => {}, // stripey mode (cosmetic, skip)
                        'p' => { // pinball = wide + tall + stripey
                            char_w = 8;
                            char_h = 12;
                        },
                        'i' => {}, // invert (skip for now)
                        'b' => {}, // border toggle (skip)
                        '#' => {}, // solid background toggle (skip)
                        'c' => { // \^c N — clear screen to color N, reset cursor
                            if (i < text.len) {
                                const clear_col: u4 = parseHexColor(text[i]);
                                i += 1;
                                const byte = @as(u8, clear_col) | (@as(u8, clear_col) << 4);
                                const sbase = memory.screenBase();
                                @memset(memory.ram[sbase..sbase +% 0x2000], byte);
                                x = start_x - cam.x;
                                y = start_y - cam.y;
                            }
                        },
                        'd' => { // \^d N — set delay per character (we skip the delay but consume param)
                            if (i < text.len) i += 1;
                        },
                        'g' => { // move cursor to home position
                            x = home_x;
                            y = home_y;
                        },
                        'h' => { // set current position as home
                            home_x = x;
                            home_y = y;
                        },
                        'j' => { // \^j X Y — jump cursor by x,y pixels
                            if (i + 1 < text.len) {
                                x += @as(i32, @as(i8, @bitCast(text[i])));
                                y += @as(i32, @as(i8, @bitCast(text[i + 1])));
                                i += 2;
                            }
                        },
                        'r' => { // \^r N — set right wrap boundary at N*4 pixels
                            if (i < text.len) i += 1; // consume but don't implement wrapping
                        },
                        's' => { // \^s N — set tab stop width
                            if (i < text.len) {
                                tab_w = @max(@as(i32, text[i]), 1);
                                i += 1;
                            }
                        },
                        'x' => { // \^x N — set character width
                            if (i < text.len) {
                                char_w = @as(i32, text[i]);
                                i += 1;
                            }
                        },
                        'y' => { // \^y N — set character height
                            if (i < text.len) {
                                char_h = @as(i32, text[i]);
                                i += 1;
                            }
                        },
                        '1'...'9' => {}, // skip frames (animation delay, ignore)
                        else => {},
                    }
                }
            },
            0x00 => break, // \0 terminate string
            0x08 => x -= char_w, // \b backspace
            0x09 => x = @divTrunc(x, tab_w) * tab_w + tab_w, // \t tab
            0x0a => { // \n newline
                x = start_x - cam.x;
                y += char_h;
            },
            0x0c => { // \f set foreground color (next byte is hex char '0'-'f')
                if (i < text.len) {
                    color = parseHexColor(text[i]);
                    i += 1;
                }
            },
            0x0d => x = start_x - cam.x, // \r carriage return
            0x0e => char_w = 8, // switch to wide font
            0x0f => char_w = 4, // switch to normal font
            else => {
                drawChar(memory, ch, x, y, color);
                x += char_w;
            },
        }
    }
    return x + cam.x;
}

fn drawChar(memory: *Memory, code: u8, x: i32, y: i32, col: u4) void {
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

    // palt(bitfield): single number sets all 16 transparency flags
    if (lua.isNoneOrNil(2)) {
        const bits: u16 = @truncate(@as(u32, @bitCast(luaToInt(lua, 1))));
        for (0..16) |i| {
            if (bits & (@as(u16, 1) << @intCast(i)) != 0) {
                pico.memory.ram[mem_const.ADDR_DRAW_PAL + i] |= 0x10;
            } else {
                pico.memory.ram[mem_const.ADDR_DRAW_PAL + i] &= 0x0F;
            }
        }
        return 0;
    }

    // palt(col, trans): set single color transparency
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

        const map_w: i32 = if (pico.memory.ram[0x5F57] == 0) 128 else @as(i32, pico.memory.ram[0x5F57]);
        if (tile_x >= 0 and tile_x < map_w and tile_y >= 0 and tile_y < 64) {
            const tile = mapGetWide(pico.memory, tile_x, tile_y);
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
    const int_val: u32 = @bitCast(api_mod.safeFloatToI32(p));
    const pat: u16 = @truncate(int_val);
    pico.memory.poke16(mem_const.ADDR_FILL_PAT, pat);
    // Bit 16 (0b.1) set = use transparency for pattern holes; unset = use secondary color
    const fill_trans: u8 = if (int_val & 0x10000 != 0) 1 else 0;
    pico.memory.ram[mem_const.ADDR_FILL_PAT + 2] = fill_trans;
    return 0;
}
