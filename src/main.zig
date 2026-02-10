const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const Memory = @import("memory.zig").Memory;
const cart_mod = @import("cart.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;
const api = @import("api.zig");
const gfx = @import("gfx.zig");
const input_mod = @import("input.zig");
const audio_mod = @import("audio.zig");
const save_state = @import("save_state.zig");

const SCREEN_W = 128;
const SCREEN_H = 128;
const WINDOW_SCALE = 4;
const WINDOW_W = SCREEN_W * WINDOW_SCALE;
const WINDOW_H = SCREEN_H * WINDOW_SCALE;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get cart path from args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name
    const cart_path = args.next();

    // Init SDL
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD)) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "PICO-Z",
        WINDOW_W,
        WINDOW_H,
        c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreateFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
        return error.RendererCreateFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderLogicalPresentation(renderer, SCREEN_W, SCREEN_H, c.SDL_LOGICAL_PRESENTATION_LETTERBOX);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        SCREEN_W,
        SCREEN_H,
    ) orelse {
        std.log.err("SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
        return error.TextureCreateFailed;
    };
    defer c.SDL_DestroyTexture(texture);
    _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);

    // Init PICO-8 subsystems
    var memory = Memory.init();
    var input = input_mod.Input{};
    input.initControllers();
    defer input.deinitControllers();
    var pixel_buffer: [SCREEN_W * SCREEN_H]u32 = undefined;
    @memset(&pixel_buffer, 0xFF000000); // black

    // Save/load indicator state
    var indicator_end_time: i128 = 0;

    var audio = audio_mod.Audio.init(&memory);
    defer audio.deinit();
    audio.openDevice();

    var pico = api.PicoState{
        .memory = &memory,
        .pixel_buffer = &pixel_buffer,
        .input = &input,
        .audio = &audio,
        .start_time = std.time.milliTimestamp(),
        .allocator = allocator,
    };

    memory.initDrawState();

    // Load cart if provided
    var lua_engine = try LuaEngine.init(allocator, &pico);
    defer lua_engine.deinit();

    var current_cart_path: ?[]const u8 = cart_path;
    var owned_cart_path: ?[]u8 = null;
    defer if (owned_cart_path) |p| allocator.free(p);

    if (cart_path) |path| {
        loadCart(&lua_engine, &memory, allocator, path) catch |err| {
            std.log.err("failed to load cart: {}", .{err});
        };
    }

    // Main loop
    const target_fps: u32 = if (lua_engine.use60fps()) 60 else 30;
    const frame_time_ns: u64 = 1_000_000_000 / target_fps;
    var running = true;

    while (running) {
        const frame_start = std.time.nanoTimestamp();

        // Poll events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                if (event.key.key == c.SDLK_ESCAPE) running = false;
                if (event.key.key == c.SDLK_P) {
                    if (current_cart_path) |path| {
                        save_state.saveState(&pico, &lua_engine, path) catch |err| {
                            std.log.err("save state failed: {}", .{err});
                        };
                        indicator_end_time = std.time.nanoTimestamp() + 2_000_000_000;
                    }
                }
                if (event.key.key == c.SDLK_L) {
                    if (current_cart_path) |path| {
                        save_state.loadState(&pico, &lua_engine, path) catch |err| {
                            std.log.err("load state failed: {}", .{err});
                        };
                        indicator_end_time = std.time.nanoTimestamp() + 2_000_000_000;
                    }
                }
            }
            if (event.type == c.SDL_EVENT_DROP_FILE) {
                if (event.drop.data) |data| {
                    const path = std.mem.span(data);
                    if (owned_cart_path) |p| allocator.free(p);
                    owned_cart_path = allocator.dupe(u8, path) catch null;
                    current_cart_path = owned_cart_path;
                    if (owned_cart_path) |p| {
                        memory.initDrawState();
                        loadCart(&lua_engine, &memory, allocator, p) catch |err| {
                            std.log.err("failed to load dropped cart: {}", .{err});
                        };
                    }
                }
            }
            if (event.type == c.SDL_EVENT_GAMEPAD_ADDED or event.type == c.SDL_EVENT_GAMEPAD_REMOVED) {
                input.deinitControllers();
                input.initControllers();
            }
        }

        // Update input and sync to PICO-8 memory
        input.update();
        memory.ram[0x5F4C] = input.btn_state[0];
        memory.ram[0x5F4D] = input.btn_state[1];

        // Run cart
        lua_engine.callUpdate();
        lua_engine.callDraw();

        // Error display
        if (lua_engine.had_error) {
            displayError(&memory, lua_engine.getErrorMsg());
        }

        // Render screen buffer to ARGB
        gfx.renderToARGB(&memory, &pixel_buffer);

        // Draw save/load indicator: 2px screen border cycling through 16 colors
        if (frame_start < indicator_end_time) {
            const palette = @import("palette.zig");
            const elapsed_ns: u64 = @intCast(indicator_end_time - frame_start);
            const color_idx: u5 = @intCast((elapsed_ns / 50_000_000) % 16);
            const color = palette.colors[color_idx];
            for (0..SCREEN_H) |y| {
                for (0..SCREEN_W) |x| {
                    if (x < 2 or x >= SCREEN_W - 2 or y < 2 or y >= SCREEN_H - 2) {
                        pixel_buffer[y * SCREEN_W + x] = color;
                    }
                }
            }
        }

        // Upload to GPU
        _ = c.SDL_UpdateTexture(texture, null, &pixel_buffer, SCREEN_W * @sizeOf(u32));
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, texture, null, null);
        _ = c.SDL_RenderPresent(renderer);

        pico.frame_count += 1;

        // Frame timing
        const frame_end = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(frame_end - frame_start);
        if (elapsed < frame_time_ns) {
            std.Thread.sleep(frame_time_ns - elapsed);
        }
    }
}

fn loadCart(lua_engine: *LuaEngine, memory: *Memory, allocator: std.mem.Allocator, path: []const u8) !void {
    var cart = if (std.mem.endsWith(u8, path, ".p8.png"))
        try cart_mod.loadP8PngFile(allocator, path, memory)
    else
        try cart_mod.loadP8File(allocator, path, memory);
    defer cart.deinit();
    memory.saveRom();
    try lua_engine.reinit();
    try lua_engine.loadCart(&cart, allocator);
    lua_engine.callInit();
}

fn displayError(memory: *Memory, msg: []const u8) void {
    // Red background
    @memset(memory.ram[0x6000..0x8000], 0x88); // color 8 = red, both nibbles

    // Reset draw state for text
    memory.ram[0x5F25] = 7; // white color
    for (0..16) |i| {
        memory.ram[0x5F00 + i] = @intCast(i); // identity draw palette
        memory.ram[0x5F10 + i] = @intCast(i); // identity screen palette
    }

    // Draw error text at top
    const header = "runtime error";
    var x: i32 = 2;
    var y: i32 = 2;
    for (header) |ch| {
        drawCharDirect(memory, ch, x, y, 7);
        x += 4;
    }

    // Draw error message
    x = 2;
    y = 10;
    for (msg) |ch| {
        if (ch == '\n' or x > 124) {
            x = 2;
            y += 6;
            if (y > 122) break;
            if (ch == '\n') continue;
        }
        drawCharDirect(memory, ch, x, y, 7);
        x += 4;
    }
}

fn drawCharDirect(memory: *Memory, ch: u8, x: i32, y: i32, col: u4) void {
    const font = @import("gfx_font.zig");
    const code: u7 = if (ch > 127) 0 else @intCast(ch);
    var py: u3 = 0;
    while (py < 6) : (py += 1) {
        var px: u3 = 0;
        while (px < 4) : (px += 1) {
            if (font.getPixel(code, px, py)) {
                const sx = x + px;
                const sy = y + py;
                if (sx >= 0 and sx < 128 and sy >= 0 and sy < 128) {
                    memory.screenSet(@intCast(sx), @intCast(sy), col);
                }
            }
        }
    }
}

