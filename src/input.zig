const std = @import("std");
const zlua = @import("zlua");
const api = @import("api.zig");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Input = struct {
    btn_state: [2]u8 = .{ 0, 0 }, // current state per player
    prev_state: [2]u8 = .{ 0, 0 }, // previous frame
    held_frames: [2][8]u16 = .{ .{0} ** 8, .{0} ** 8 }, // frames held
    controllers: [2]?*c.SDL_Gamepad = .{ null, null },

    pub fn initControllers(self: *Input) void {
        var num_gamepads: c_int = 0;
        const gamepad_ids = c.SDL_GetGamepads(&num_gamepads);
        if (gamepad_ids == null) return;
        defer c.SDL_free(gamepad_ids);
        var count: usize = 0;
        for (0..@intCast(num_gamepads)) |i| {
            if (count >= 2) break;
            self.controllers[count] = c.SDL_OpenGamepad(gamepad_ids[i]);
            if (self.controllers[count] != null) count += 1;
        }
    }

    pub fn deinitControllers(self: *Input) void {
        for (&self.controllers) |*ctrl| {
            if (ctrl.*) |gc| {
                c.SDL_CloseGamepad(gc);
                ctrl.* = null;
            }
        }
    }

    pub fn update(self: *Input) void {
        self.prev_state = self.btn_state;

        const keys = c.SDL_GetKeyboardState(null);

        // Player 0: arrows + Z/C/N (O button) + X/V/M (X button)
        self.btn_state[0] = 0;
        if (keys[c.SDL_SCANCODE_LEFT]) self.btn_state[0] |= 0x01;
        if (keys[c.SDL_SCANCODE_RIGHT]) self.btn_state[0] |= 0x02;
        if (keys[c.SDL_SCANCODE_UP]) self.btn_state[0] |= 0x04;
        if (keys[c.SDL_SCANCODE_DOWN]) self.btn_state[0] |= 0x08;
        if (keys[c.SDL_SCANCODE_Z] or keys[c.SDL_SCANCODE_C] or keys[c.SDL_SCANCODE_N]) self.btn_state[0] |= 0x10;
        if (keys[c.SDL_SCANCODE_X] or keys[c.SDL_SCANCODE_V] or keys[c.SDL_SCANCODE_M]) self.btn_state[0] |= 0x20;

        // Player 1: ESDF + Tab/Q (O) + W (X) -- less standard but common mapping
        self.btn_state[1] = 0;
        if (keys[c.SDL_SCANCODE_S]) self.btn_state[1] |= 0x01;
        if (keys[c.SDL_SCANCODE_F]) self.btn_state[1] |= 0x02;
        if (keys[c.SDL_SCANCODE_E]) self.btn_state[1] |= 0x04;
        if (keys[c.SDL_SCANCODE_D]) self.btn_state[1] |= 0x08;
        if (keys[c.SDL_SCANCODE_TAB] or keys[c.SDL_SCANCODE_Q]) self.btn_state[1] |= 0x10;
        if (keys[c.SDL_SCANCODE_W]) self.btn_state[1] |= 0x20;

        // Merge gamepad state
        for (0..2) |p| {
            if (self.controllers[p]) |gc| {
                const deadzone: i16 = 8000;
                const lx = c.SDL_GetGamepadAxis(gc, c.SDL_GAMEPAD_AXIS_LEFTX);
                const ly = c.SDL_GetGamepadAxis(gc, c.SDL_GAMEPAD_AXIS_LEFTY);
                if (lx < -deadzone) self.btn_state[p] |= 0x01; // left
                if (lx > deadzone) self.btn_state[p] |= 0x02; // right
                if (ly < -deadzone) self.btn_state[p] |= 0x04; // up
                if (ly > deadzone) self.btn_state[p] |= 0x08; // down
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_DPAD_LEFT)) self.btn_state[p] |= 0x01;
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT)) self.btn_state[p] |= 0x02;
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_DPAD_UP)) self.btn_state[p] |= 0x04;
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN)) self.btn_state[p] |= 0x08;
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_SOUTH)) self.btn_state[p] |= 0x10; // O
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_EAST)) self.btn_state[p] |= 0x20; // X
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_WEST)) self.btn_state[p] |= 0x10; // O alt
                if (c.SDL_GetGamepadButton(gc, c.SDL_GAMEPAD_BUTTON_NORTH)) self.btn_state[p] |= 0x20; // X alt
            }
        }

        // Update held frame counters
        for (0..2) |p| {
            for (0..8) |b| {
                const mask: u8 = @as(u8, 1) << @intCast(b);
                if (self.btn_state[p] & mask != 0) {
                    self.held_frames[p][b] +|= 1;
                } else {
                    self.held_frames[p][b] = 0;
                }
            }
        }
    }

    pub fn btn(self: *const Input, button: u3, player: u1) bool {
        return self.btn_state[player] & (@as(u8, 1) << button) != 0;
    }

    pub fn btnp(self: *const Input, button: u3, player: u1) bool {
        const held = self.held_frames[player][button];
        if (held == 1) return true; // just pressed
        if (held >= 15 and (held - 15) % 4 == 0) return true; // repeat
        return false;
    }
};

pub fn api_btn(lua: *zlua.Lua) c_int {
    const pico = api.getPico(lua);

    if (lua.isNoneOrNil(1)) {
        // Return bitfield for player 0
        lua.pushNumber(@floatFromInt(pico.input.btn_state[0]));
        return 1;
    }

    const button: u3 = @intCast(@as(u32, @bitCast(api.luaToInt(lua, 1))) & 7);
    const player: u1 = @intCast(@as(u32, @bitCast(api.optInt(lua, 2, 0))) & 1);
    lua.pushBoolean(pico.input.btn(button, player));
    return 1;
}

pub fn api_btnp(lua: *zlua.Lua) c_int {
    const pico = api.getPico(lua);

    if (lua.isNoneOrNil(1)) {
        // Return bitfield of just-pressed for player 0
        var bits: u8 = 0;
        for (0..8) |b| {
            if (pico.input.btnp(@intCast(b), 0)) bits |= @as(u8, 1) << @intCast(b);
        }
        lua.pushNumber(@floatFromInt(bits));
        return 1;
    }

    const button: u3 = @intCast(@as(u32, @bitCast(api.luaToInt(lua, 1))) & 7);
    const player: u1 = @intCast(@as(u32, @bitCast(api.optInt(lua, 2, 0))) & 1);
    lua.pushBoolean(pico.input.btnp(button, player));
    return 1;
}

