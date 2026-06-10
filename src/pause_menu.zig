// PICO-8-style pause menu. Drawn as an overlay directly into the rendered
// ARGB frame buffer (the cart's screen memory is left untouched, so the frozen
// frame underneath is preserved without save/restore). Navigation and custom
// menuitem() callback invocation live here too so the native and web hosts can
// share the logic.

const std = @import("std");
const zlua = @import("zlua");
const api = @import("api.zig");
const font = @import("gfx_font.zig");
const palette = @import("palette.zig");

const SCREEN_W = api.SCREEN_W;
const SCREEN_H = api.SCREEN_H;

/// What the host loop should do after update().
pub const Action = enum { none, close, reset, shutdown };

const Kind = enum { cont, custom, reset };
const Entry = struct { kind: Kind, slot: u8 = 0 };

/// Build the ordered list of visible entries: Continue, the active custom
/// items, then Reset Cart.
fn buildEntries(pico: *const api.PicoState, buf: *[7]Entry) usize {
    var n: usize = 0;
    buf[n] = .{ .kind = .cont };
    n += 1;
    for (pico.menu_items, 0..) |item, i| {
        if (item.active) {
            buf[n] = .{ .kind = .custom, .slot = @intCast(i) };
            n += 1;
        }
    }
    buf[n] = .{ .kind = .reset };
    n += 1;
    return n;
}

fn entryLabel(pico: *const api.PicoState, e: Entry) []const u8 {
    return switch (e.kind) {
        .cont => "continue",
        .reset => "reset cart",
        .custom => pico.menu_items[e.slot].label(),
    };
}

/// Handle one frame of menu input. Uses edge-detected player-0 buttons so a
/// single press maps to a single action. Returns the action for the host.
pub fn update(pico: *api.PicoState, input: *const @import("input.zig").Input, lua: *zlua.Lua) Action {
    var buf: [7]Entry = undefined;
    const n = buildEntries(pico, &buf);
    if (pico.menu_sel >= n) pico.menu_sel = 0;

    const pressed = input.btn_state[0] & ~input.prev_state[0];
    const up = pressed & 0x04 != 0;
    const down = pressed & 0x08 != 0;
    const left = pressed & 0x01 != 0;
    const right = pressed & 0x02 != 0;
    const o = pressed & 0x10 != 0;
    const x = pressed & 0x20 != 0;

    if (up) pico.menu_sel = @intCast((@as(usize, pico.menu_sel) + n - 1) % n);
    if (down) pico.menu_sel = @intCast((@as(usize, pico.menu_sel) + 1) % n);

    const e = buf[pico.menu_sel];

    // Left/right adjust custom items in place and keep the menu open.
    if (e.kind == .custom and (left or right)) {
        _ = invokeCallback(pico, lua, e.slot, if (left) 1 else 2);
        return .none;
    }

    if (o or x) {
        switch (e.kind) {
            .cont => return .close,
            .reset => return .reset,
            .custom => {
                // Pass the activating button (O=0x10, X=0x20). A callback that
                // returns true keeps the menu open; otherwise it closes.
                const keep = invokeCallback(pico, lua, e.slot, if (x) 0x20 else 0x10);
                return if (keep) .none else .close;
            },
        }
    }
    return .none;
}

/// Invoke a custom item's Lua callback with the button bitmask. Returns whether
/// the menu should stay open (callback returned a truthy value).
fn invokeCallback(pico: *api.PicoState, lua: *zlua.Lua, slot: u8, mask: f64) bool {
    const item = &pico.menu_items[slot];
    if (item.cb_ref == -1) return false;
    _ = lua.rawGetIndex(zlua.registry_index, item.cb_ref);
    if (!lua.isFunction(-1)) {
        lua.pop(1);
        return false;
    }
    lua.pushNumber(mask);
    lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        lua.pop(1); // error object
        return false;
    };
    const keep = lua.toBoolean(-1);
    lua.pop(1);
    return keep;
}

// ── Rendering ──────────────────────────────────────────────────────────────

fn setPx(buf: *[SCREEN_W * SCREEN_H]u32, x: i32, y: i32, argb: u32) void {
    if (x < 0 or x >= SCREEN_W or y < 0 or y >= SCREEN_H) return;
    buf[@as(usize, @intCast(y)) * SCREEN_W + @as(usize, @intCast(x))] = argb;
}

fn fillRect(buf: *[SCREEN_W * SCREEN_H]u32, x: i32, y: i32, w: i32, h: i32, argb: u32) void {
    var yy: i32 = y;
    while (yy < y + h) : (yy += 1) {
        var xx: i32 = x;
        while (xx < x + w) : (xx += 1) setPx(buf, xx, yy, argb);
    }
}

fn drawChar(buf: *[SCREEN_W * SCREEN_H]u32, code: u8, x: i32, y: i32, argb: u32) void {
    var py: u3 = 0;
    while (py < 6) : (py += 1) {
        var px: u3 = 0;
        while (px < 4) : (px += 1) {
            if (font.getPixel(code, px, py)) setPx(buf, x + px, y + py, argb);
        }
    }
}

fn drawStr(buf: *[SCREEN_W * SCREEN_H]u32, s: []const u8, x: i32, y: i32, argb: u32) void {
    var cx: i32 = x;
    for (s) |ch| {
        drawChar(buf, ch, cx, y, argb);
        cx += 4;
    }
}

/// Draw the menu overlay into the rendered frame buffer.
pub fn render(pico: *const api.PicoState, buf: *[SCREEN_W * SCREEN_H]u32) void {
    var entries: [7]Entry = undefined;
    const n = buildEntries(pico, &entries);

    // Box dimensions from the widest label (4px per char).
    var max_chars: usize = 0;
    for (entries[0..n]) |e| max_chars = @max(max_chars, entryLabel(pico, e).len);
    const line_h: i32 = 8;
    const pad: i32 = 6;
    const inner_w: i32 = @intCast(max_chars * 4 + 4); // +4 for the selection marker
    const box_w: i32 = @min(inner_w + pad * 2, SCREEN_W - 8);
    const box_h: i32 = @as(i32, @intCast(n)) * line_h + pad * 2;
    const box_x: i32 = @divTrunc(SCREEN_W - box_w, 2);
    const box_y: i32 = @divTrunc(SCREEN_H - box_h, 2);

    const black = palette.colors[0];
    const white = palette.colors[7];

    // Black fill + white border.
    fillRect(buf, box_x, box_y, box_w, box_h, black);
    fillRect(buf, box_x, box_y, box_w, 1, white);
    fillRect(buf, box_x, box_y + box_h - 1, box_w, 1, white);
    fillRect(buf, box_x, box_y, 1, box_h, white);
    fillRect(buf, box_x + box_w - 1, box_y, 1, box_h, white);

    // Entries; the selected row is drawn as black text on a white bar.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const row_y: i32 = box_y + pad + @as(i32, @intCast(i)) * line_h;
        const label = entryLabel(pico, entries[i]);
        const text_x: i32 = box_x + pad + 4;
        if (i == pico.menu_sel) {
            fillRect(buf, box_x + 2, row_y - 1, box_w - 4, line_h, white);
            drawStr(buf, label, text_x, row_y, black);
        } else {
            drawStr(buf, label, text_x, row_y, white);
        }
    }
}
