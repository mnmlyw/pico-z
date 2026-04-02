const std = @import("std");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const cart_mod = @import("cart.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;
const api = @import("api.zig");
const gfx = @import("gfx.zig");
const input_mod = @import("input.zig");
const audio_mod = @import("audio.zig");

const SCREEN_W = 128;
const SCREEN_H = 128;

// Global state — initialized by web_init
var memory: Memory = undefined;
var input: input_mod.Input = undefined;
var pixel_buffer: [SCREEN_W * SCREEN_H]u32 = undefined;
var audio: audio_mod.Audio = undefined;
var pico: api.PicoState = undefined;
var lua_engine: LuaEngine = undefined;
var initialized = false;

const wasm_allocator = std.heap.wasm_allocator; // works for both freestanding and wasi wasm32

// ── Exported WASM API ──

/// Allocate memory for JS to write cart data into
export fn web_alloc(len: u32) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free previously allocated memory
export fn web_free(ptr: [*]u8, len: u32) void {
    wasm_allocator.free(ptr[0..len]);
}

/// Initialize emulator with cart data. Returns 0 on success, 1 on error.
export fn web_init(cart_ptr: [*]const u8, cart_len: u32) u32 {
    initialized = false;
    memory = Memory.init();
    memory.initDrawState();
    input = input_mod.Input{};
    @memset(&pixel_buffer, 0xFF000000);
    audio = audio_mod.Audio.init(&memory);

    pico = api.PicoState{
        .memory = &memory,
        .pixel_buffer = &pixel_buffer,
        .input = &input,
        .audio = &audio,
        .allocator = wasm_allocator,
    };

    lua_engine = LuaEngine.init(wasm_allocator, &pico) catch return 1;

    // Detect format and load cart
    const cart_data = cart_ptr[0..cart_len];
    var cart = loadCartData(cart_data) catch return 1;
    defer cart.deinit();

    memory.saveRom();
    api.prepareForCartLoad(&pico);

    lua_engine.loadCart(&cart, wasm_allocator) catch return 1;
    lua_engine.callInit();
    initialized = true;
    return 0;
}

/// Run one frame (update + draw + render to pixel buffer)
export fn web_update() void {
    if (!initialized) return;

    input.mouse_wheel = 0;
    input.update();
    memory.ram[0x5F4C] = input.btn_state[0];
    memory.ram[0x5F4D] = input.btn_state[1];

    lua_engine.callUpdate();
    lua_engine.callDraw();

    pico.frame_count += 1;
    pico.target_fps = if (lua_engine.use60fps()) 60 else 30;
    pico.elapsed_time += 1.0 / @as(f64, @floatFromInt(pico.target_fps));

    gfx.renderToARGB(&memory, &pixel_buffer);
}

/// Get pointer to the 128x128 ARGB pixel buffer for JS to read
export fn web_get_pixel_buffer() [*]u32 {
    return &pixel_buffer;
}

/// Set button state for a player (called from JS key events)
export fn web_set_buttons(player: u8, buttons: u8) void {
    if (player < 2) {
        input.btn_state[player] = buttons;
    }
}

/// Set mouse state (called from JS mouse events)
export fn web_set_mouse(x: i32, y: i32, buttons: u8, wheel: i32) void {
    input.mouse_x = x;
    input.mouse_y = y;
    input.mouse_buttons = buttons;
    input.mouse_wheel = wheel;
}

/// Generate audio samples into a buffer. Returns pointer to f32 sample buffer.
var audio_buf: [4096]f32 = undefined;
export fn web_generate_audio(sample_count: u32) [*]f32 {
    const count = @min(sample_count, audio_buf.len);
    for (0..count) |i| {
        audio_buf[i] = audio.generateSampleIndexed();
    }
    return &audio_buf;
}

/// Get target FPS (30 or 60)
export fn web_get_fps() u32 {
    return pico.target_fps;
}

/// Check if emulator has an error
export fn web_has_error() u32 {
    return if (lua_engine.had_error) 1 else 0;
}

/// Save state — returns pointer and length. JS should read and free.
var save_data: ?[]u8 = null;
export fn web_save_state() u32 {
    if (!initialized) return 0;
    const save_state = @import("save_state.zig");
    if (save_data) |old| wasm_allocator.free(old);
    save_data = save_state.serializeState(&pico, &lua_engine) catch return 0;
    return @intCast(save_data.?.len);
}

export fn web_get_save_ptr() ?[*]const u8 {
    if (save_data) |d| return d.ptr;
    return null;
}

export fn web_free_save() void {
    if (save_data) |d| {
        wasm_allocator.free(d);
        save_data = null;
    }
}

/// Load state from JS-provided bytes. Returns 0 on success.
export fn web_load_state(data_ptr: [*]const u8, data_len: u32) u32 {
    if (!initialized) return 1;
    const save_state = @import("save_state.zig");
    save_state.deserializeState(&pico, &lua_engine, data_ptr[0..data_len]) catch return 1;
    return 0;
}

// ── Internal helpers ──

fn loadCartData(data: []const u8) !cart_mod.Cart {
    // Check if it's a PNG by magic bytes
    if (data.len >= 8 and std.mem.eql(u8, data[0..4], &.{ 0x89, 0x50, 0x4E, 0x47 })) {
        return cart_mod.loadP8PngBytes(wasm_allocator, data, &memory);
    }
    // Otherwise treat as .p8 text
    return cart_mod.loadP8Bytes(wasm_allocator, data, &memory);
}
