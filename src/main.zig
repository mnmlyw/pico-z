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
const cartdata_store = @import("cartdata_store.zig");

const SCREEN_W = 128;
const SCREEN_H = 128;
const WINDOW_SCALE = 4;
const WINDOW_W = SCREEN_W * WINDOW_SCALE;
const WINDOW_H = SCREEN_H * WINDOW_SCALE;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Get cart path from args
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
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
    _ = c.SDL_StartTextInput(window);

    // Init PICO-8 subsystems
    var memory = Memory.init();
    var input = input_mod.Input{};
    input.initControllers();
    defer input.deinitControllers();
    var pixel_buffer: [SCREEN_W * SCREEN_H]u32 = undefined;
    @memset(&pixel_buffer, 0xFF000000); // black

    // Save/load indicator state
    var indicator_end_time: std.Io.Timestamp = .zero;

    var audio = audio_mod.Audio.init(&memory);
    defer audio.deinit();
    audio.openDevice();

    var pico = api.PicoState{
        .memory = &memory,
        .pixel_buffer = &pixel_buffer,
        .input = &input,
        .audio = &audio,
        .allocator = allocator,
        .io = io,
    };
    defer if (pico.cart_data_id) |id| allocator.free(id);

    memory.initDrawState();

    // Load cart if provided
    var lua_engine = try LuaEngine.init(allocator, &pico);
    defer lua_engine.deinit();

    var current_cart_path: ?[]const u8 = cart_path;
    var owned_cart_path: ?[]u8 = null;
    defer if (owned_cart_path) |p| allocator.free(p);

    if (cart_path) |path| {
        pico.param_str_len = 0;
        loadCart(&pico, &lua_engine, allocator, path) catch |err| {
            std.log.err("failed to load cart: {}", .{err});
        };
    }

    // Main loop
    var running = true;
    var frame_overran = false;

    while (running) {
        const frame_start = std.Io.Timestamp.now(io, .awake);

        // Reset per-frame input state before polling new events
        input.mouse_wheel = 0;

        // Poll events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                if (event.key.key == c.SDLK_ESCAPE) running = false;
                if (event.key.key == c.SDLK_P) {
                    if (current_cart_path) |path| {
                        if (save_state.saveState(&pico, &lua_engine, path)) |_| {
                            indicator_end_time = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(2));
                        } else |err| {
                            std.log.err("save state failed: {}", .{err});
                        }
                    }
                }
                if (event.key.key == c.SDLK_L) {
                    if (current_cart_path) |path| {
                        if (save_state.loadState(&pico, &lua_engine, path)) |_| {
                            indicator_end_time = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(2));
                        } else |err| {
                            std.log.err("load state failed: {}", .{err});
                        }
                    }
                }
                if (event.key.key == c.SDLK_R) {
                    if (current_cart_path) |path| {
                        pico.param_str_len = 0;
                        loadCart(&pico, &lua_engine, allocator, path) catch |err| {
                            std.log.err("cart reload failed: {}", .{err});
                        };
                        indicator_end_time = std.Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(2));
                    }
                }
            }
            if (event.type == c.SDL_EVENT_DROP_FILE) {
                if (event.drop.data) |data| {
                    const path = std.mem.span(data);
                    const new_path = allocator.dupe(u8, path) catch {
                        std.log.err("failed to store dropped cart path", .{});
                        continue;
                    };
                    pico.param_str_len = 0;
                    if (loadCart(&pico, &lua_engine, allocator, new_path)) |_| {
                        if (owned_cart_path) |p| allocator.free(p);
                        owned_cart_path = new_path;
                        current_cart_path = new_path;
                    } else |err| {
                        allocator.free(new_path);
                        std.log.err("failed to load dropped cart: {}", .{err});
                    }
                }
            }
            if (event.type == c.SDL_EVENT_GAMEPAD_ADDED or event.type == c.SDL_EVENT_GAMEPAD_REMOVED) {
                input.deinitControllers();
                input.initControllers();
            }
            if (event.type == c.SDL_EVENT_MOUSE_MOTION) {
                var lx: f32 = event.motion.x;
                var ly: f32 = event.motion.y;
                _ = c.SDL_RenderCoordinatesFromWindow(renderer, lx, ly, &lx, &ly);
                input.mouse_x = @intFromFloat(lx);
                input.mouse_y = @intFromFloat(ly);
            }
            if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN or event.type == c.SDL_EVENT_MOUSE_BUTTON_UP) {
                const bit: u8 = switch (event.button.button) {
                    c.SDL_BUTTON_LEFT => 1,
                    c.SDL_BUTTON_RIGHT => 2,
                    c.SDL_BUTTON_MIDDLE => 4,
                    else => 0,
                };
                if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                    input.mouse_buttons |= bit;
                } else {
                    input.mouse_buttons &= ~bit;
                }
            }
            if (event.type == c.SDL_EVENT_MOUSE_WHEEL) {
                input.addMouseWheelDelta(event.wheel.y);
            }
            if (event.type == c.SDL_EVENT_TEXT_INPUT) {
                if (event.text.text[0] != 0) {
                    input.pushKeyChar(event.text.text[0]);
                }
            }
        }

        // Update input and sync to PICO-8 memory
        input.update();
        memory.ram[0x5F4C] = input.btn_state[0];
        memory.ram[0x5F4D] = input.btn_state[1];
        var numkeys: c_int = 0;
        pico.key_states = c.SDL_GetKeyboardState(&numkeys);
        pico.key_states_count = numkeys;

        // Run cart — at 30fps, if previous frame overran, call _update twice
        // (only when not in mid-flip, to avoid skipping flip-paced animation).
        if (frame_overran and !lua_engine.use60fps() and lua_engine.tick_co == null) {
            lua_engine.callUpdate();
        }
        // Coroutine-driven tick: flip() inside the cart yields back here so
        // we can render the in-progress fade/animation correctly.
        _ = lua_engine.tickFrame();

        // Handle multi-cart load() requests
        if (pico.pending_load != null) {
            const name_buf = pico.pending_load.?;
            const name_len = pico.pending_load_len;
            pico.pending_load = null;
            pico.pending_load_len = 0;

            if (name_len == 0) {
                // run() — reload current cart
                if (current_cart_path) |path| {
                    loadCart(&pico, &lua_engine, allocator, path) catch |err| {
                        std.log.err("run() reload failed: {}", .{err});
                    };
                }
            } else {
                // load("name") — load new cart
                const name = name_buf[0..name_len];

                // Resolve path relative to current cart directory
                const load_path = if (pico.cart_dir) |dir|
                    std.fs.path.join(allocator, &.{ dir, name }) catch null
                else
                    null;
                const path = load_path orelse allocator.dupe(u8, name) catch null;

                if (path) |p| {
                    if (loadCart(&pico, &lua_engine, allocator, p)) |_| {
                        if (owned_cart_path) |old| allocator.free(old);
                        owned_cart_path = p;
                        current_cart_path = p;
                    } else |err| {
                        allocator.free(p);
                        std.log.err("load() failed for {s}: {}", .{ name, err });
                    }
                }
            }
        }

        // Flush dirty cartdata once per frame
        api.flushCartdata(&pico);

        // Error display
        if (lua_engine.had_error) {
            displayError(&memory, lua_engine.getErrorMsg());
        }

        // Render screen buffer to ARGB
        gfx.renderToARGB(&memory, &pixel_buffer);

        // Draw save/load indicator: 2px screen border cycling through 16 colors
        if (frame_start.nanoseconds < indicator_end_time.nanoseconds) {
            const palette = @import("palette.zig");
            const elapsed_ns: u64 = @intCast(frame_start.durationTo(indicator_end_time).nanoseconds);
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

        // Frame timing — update fps first so elapsed_time uses the correct rate
        pico.target_fps = if (lua_engine.use60fps()) 60 else 30;
        pico.elapsed_time += 1.0 / @as(f64, @floatFromInt(pico.target_fps));
        const frame_time_ns: u64 = 1_000_000_000 / @as(u64, pico.target_fps);
        const frame_end = std.Io.Timestamp.now(io, .awake);
        const elapsed: u64 = @intCast(frame_start.durationTo(frame_end).nanoseconds);
        frame_overran = elapsed > frame_time_ns;
        if (!frame_overran) {
            io.sleep(.fromNanoseconds(@intCast(frame_time_ns - elapsed)), .awake) catch {};
        }
    }
}

pub fn loadCart(pico: *api.PicoState, lua_engine: *LuaEngine, allocator: std.mem.Allocator, path: []const u8) !void {
    const memory = pico.memory;
    var next_memory = Memory.init();
    next_memory.initDrawState();
    const saved_cart_dir = pico.cart_dir;
    const next_cart_dir = std.fs.path.dirname(path);

    var cart = if (std.mem.endsWith(u8, path, ".p8.png"))
        try cart_mod.loadP8PngFile(allocator, pico.io, path, &next_memory)
    else
        try cart_mod.loadP8File(allocator, pico.io, path, &next_memory);
    defer cart.deinit();

    // Persist dirty cartdata before replacing RAM/ROM with a new cart.
    api.flushCartdata(pico);
    if (pico.cart_data_dirty) return error.CartdataSaveFailed;

    // Save old memory in case Lua loading fails
    const saved_memory = memory.*;

    memory.* = next_memory;
    memory.saveRom();
    pico.cart_dir = next_cart_dir;

    // Stop all audio from previous cart
    api.prepareForCartLoad(pico);

    // Clear cartdata attachment so the new cart can call cartdata() fresh
    const saved_cart_data_id = pico.cart_data_id;
    const saved_cart_data_dirty = pico.cart_data_dirty;
    pico.cart_data_id = null;
    pico.cart_data_dirty = false;

    // Reset VM without replaying old cart source (fixes stale execution)
    lua_engine.resetVM() catch |err| {
        memory.* = saved_memory;
        pico.cart_dir = saved_cart_dir;
        pico.cart_data_id = saved_cart_data_id;
        pico.cart_data_dirty = saved_cart_data_dirty;
        return err;
    };
    lua_engine.loadCart(&cart, allocator) catch |err| {
        // Lua failed — cold-restart old cart: zero RAM, restore ROM + cartdata
        @memset(&memory.ram, 0);
        @memcpy(&memory.rom, &saved_memory.rom);
        memory.reload(0, 0, 0x4300);
        // Preserve cartdata region from saved state
        const cd_start = @import("memory.zig").ADDR_CART_DATA;
        @memcpy(memory.ram[cd_start .. cd_start + 256], saved_memory.ram[cd_start .. cd_start + 256]);
        memory.initDrawState();
        pico.cart_dir = saved_cart_dir;
        pico.cart_data_id = saved_cart_data_id;
        pico.cart_data_dirty = saved_cart_data_dirty;
        lua_engine.reinit() catch {};
        lua_engine.callInit();
        return err;
    };

    // Success — free old cartdata ID (already cleared above, just free the allocation)
    if (saved_cart_data_id) |id| allocator.free(id);
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
    var py: u3 = 0;
    while (py < 6) : (py += 1) {
        var px: u3 = 0;
        while (px < 4) : (px += 1) {
            if (font.getPixel(ch, px, py)) {
                const sx = x + px;
                const sy = y + py;
                if (sx >= 0 and sx < 128 and sy >= 0 and sy < 128) {
                    memory.screenSet(@intCast(sx), @intCast(sy), col);
                }
            }
        }
    }
}
