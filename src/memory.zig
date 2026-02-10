const std = @import("std");

pub const RAM_SIZE = 65536;

// PICO-8 memory map
pub const ADDR_SPRITE = 0x0000; // sprite sheet (shared with map lower half)
pub const ADDR_SHARED = 0x1000; // shared sprite/map region
pub const ADDR_MAP = 0x2000; // map (upper half)
pub const ADDR_FLAGS = 0x3000; // sprite flags
pub const ADDR_MUSIC = 0x3100; // music patterns
pub const ADDR_SFX = 0x3200; // sound effects
pub const ADDR_GENERAL = 0x4300; // user data
pub const ADDR_CART_DATA = 0x5E00; // persistent cart data (256 bytes, 64 fixed-point values)
pub const ADDR_DRAW_STATE = 0x5F00; // draw state
pub const ADDR_HW_STATE = 0x5F40; // hardware state
pub const ADDR_GPIO = 0x5F80; // GPIO pins
pub const ADDR_SCREEN = 0x6000; // screen (64 bytes per row, 2 pixels per byte)
pub const ADDR_SCREEN_END = 0x8000;

// Draw state addresses
pub const ADDR_DRAW_PAL = 0x5F00; // draw palette (16 bytes)
pub const ADDR_SCREEN_PAL = 0x5F10; // screen palette (16 bytes)
pub const ADDR_CLIP_LEFT = 0x5F20;
pub const ADDR_CLIP_TOP = 0x5F21;
pub const ADDR_CLIP_RIGHT = 0x5F22;
pub const ADDR_CLIP_BOTTOM = 0x5F23;
pub const ADDR_COLOR = 0x5F25;
pub const ADDR_CURSOR_X = 0x5F26;
pub const ADDR_CURSOR_Y = 0x5F27;
pub const ADDR_CAMERA_X = 0x5F28; // 16-bit signed
pub const ADDR_CAMERA_Y = 0x5F2A; // 16-bit signed
pub const ADDR_DEVKIT = 0x5F2D;
pub const ADDR_FILL_PAT = 0x5F31; // fill pattern (4 bytes: 2 pattern + 2 color)
pub const ADDR_PALT = 0x5F00; // transparency stored in high nibble of draw pal

// Input
pub const ADDR_INPUT_P0 = 0x5F4C;
pub const ADDR_INPUT_P1 = 0x5F4D;

pub const Memory = struct {
    ram: [RAM_SIZE]u8,
    rom: [RAM_SIZE]u8, // ROM copy for reload()

    pub fn init() Memory {
        var m: Memory = undefined;
        @memset(&m.ram, 0);
        @memset(&m.rom, 0);
        return m;
    }

    pub fn initDrawState(self: *Memory) void {
        // Identity draw palette
        for (0..16) |i| {
            self.ram[ADDR_DRAW_PAL + i] = @intCast(i);
        }
        // Identity screen palette
        for (0..16) |i| {
            self.ram[ADDR_SCREEN_PAL + i] = @intCast(i);
        }
        // Clip to full screen
        self.ram[ADDR_CLIP_LEFT] = 0;
        self.ram[ADDR_CLIP_TOP] = 0;
        self.ram[ADDR_CLIP_RIGHT] = 128;
        self.ram[ADDR_CLIP_BOTTOM] = 128;
        // Default color = 6 (light grey)
        self.ram[ADDR_COLOR] = 6;
        // Camera 0
        self.poke16(ADDR_CAMERA_X, 0);
        self.poke16(ADDR_CAMERA_Y, 0);
        // Cursor at 0,0
        self.ram[ADDR_CURSOR_X] = 0;
        self.ram[ADDR_CURSOR_Y] = 0;
        // Fill pattern = 0 (solid)
        self.poke16(ADDR_FILL_PAT, 0);
        self.poke16(ADDR_FILL_PAT + 2, 0);
        // Set transparency on color 0
        self.ram[ADDR_DRAW_PAL + 0] |= 0x10; // high nibble = transparent
    }

    pub fn saveRom(self: *Memory) void {
        @memcpy(&self.rom, &self.ram);
    }

    // 8-bit peek/poke
    pub fn peek(self: *const Memory, addr: u16) u8 {
        return self.ram[addr];
    }

    pub fn poke(self: *Memory, addr: u16, val: u8) void {
        self.ram[addr] = val;
    }

    // 16-bit little-endian
    pub fn peek16(self: *const Memory, addr: u16) u16 {
        return @as(u16, self.ram[addr]) | (@as(u16, self.ram[addr +% 1]) << 8);
    }

    pub fn poke16(self: *Memory, addr: u16, val: u16) void {
        self.ram[addr] = @truncate(val);
        self.ram[addr +% 1] = @truncate(val >> 8);
    }

    // 32-bit little-endian
    pub fn peek32(self: *const Memory, addr: u16) u32 {
        return @as(u32, self.ram[addr]) |
            (@as(u32, self.ram[addr +% 1]) << 8) |
            (@as(u32, self.ram[addr +% 2]) << 16) |
            (@as(u32, self.ram[addr +% 3]) << 24);
    }

    pub fn poke32(self: *Memory, addr: u16, val: u32) void {
        self.ram[addr] = @truncate(val);
        self.ram[addr +% 1] = @truncate(val >> 8);
        self.ram[addr +% 2] = @truncate(val >> 16);
        self.ram[addr +% 3] = @truncate(val >> 24);
    }

    // Screen pixel access (2 pixels per byte, 4-bit color)
    pub fn screenGet(self: *const Memory, x: u7, y: u7) u4 {
        const addr: u16 = ADDR_SCREEN + @as(u16, y) * 64 + @as(u16, x) / 2;
        const byte = self.ram[addr];
        if (x & 1 == 0) {
            return @truncate(byte & 0x0F);
        } else {
            return @truncate(byte >> 4);
        }
    }

    pub fn screenSet(self: *Memory, x: u7, y: u7, color: u4) void {
        const addr: u16 = ADDR_SCREEN + @as(u16, y) * 64 + @as(u16, x) / 2;
        if (x & 1 == 0) {
            self.ram[addr] = (self.ram[addr] & 0xF0) | @as(u8, color);
        } else {
            self.ram[addr] = (self.ram[addr] & 0x0F) | (@as(u8, color) << 4);
        }
    }

    // Sprite sheet pixel access (same layout as screen, at address 0x0000)
    pub fn spriteGet(self: *const Memory, x: u8, y: u8) u4 {
        if (x >= 128 or y >= 128) return 0;
        const addr: u16 = ADDR_SPRITE + @as(u16, y) * 64 + @as(u16, x) / 2;
        const byte = self.ram[addr];
        if (x & 1 == 0) {
            return @truncate(byte & 0x0F);
        } else {
            return @truncate(byte >> 4);
        }
    }

    pub fn spriteSet(self: *Memory, x: u8, y: u8, color: u4) void {
        if (x >= 128 or y >= 128) return;
        const addr: u16 = ADDR_SPRITE + @as(u16, y) * 64 + @as(u16, x) / 2;
        if (x & 1 == 0) {
            self.ram[addr] = (self.ram[addr] & 0xF0) | @as(u8, color);
        } else {
            self.ram[addr] = (self.ram[addr] & 0x0F) | (@as(u8, color) << 4);
        }
    }

    // Map access
    pub fn mapGet(self: *const Memory, x: u8, y: u8) u8 {
        if (x >= 128 or y >= 64) return 0;
        if (y < 32) {
            return self.ram[ADDR_MAP + @as(u16, y) * 128 + @as(u16, x)];
        } else {
            // Shared region: rows 32-63 map to sprite sheet 0x1000-0x1FFF
            return self.ram[ADDR_SHARED + @as(u16, y - 32) * 128 + @as(u16, x)];
        }
    }

    pub fn mapSet(self: *Memory, x: u8, y: u8, val: u8) void {
        if (x >= 128 or y >= 64) return;
        if (y < 32) {
            self.ram[ADDR_MAP + @as(u16, y) * 128 + @as(u16, x)] = val;
        } else {
            self.ram[ADDR_SHARED + @as(u16, y - 32) * 128 + @as(u16, x)] = val;
        }
    }

    pub fn memcpy(self: *Memory, dst: u16, src: u16, len: u16) void {
        if (len == 0) return;
        const d = dst;
        const s = src;
        if (d < s) {
            for (0..len) |i| {
                self.ram[d +% @as(u16, @intCast(i))] = self.ram[s +% @as(u16, @intCast(i))];
            }
        } else {
            var i: u16 = len;
            while (i > 0) {
                i -= 1;
                self.ram[d +% i] = self.ram[s +% i];
            }
        }
    }

    pub fn memset(self: *Memory, dst: u16, val: u8, len: u16) void {
        for (0..len) |i| {
            self.ram[dst +% @as(u16, @intCast(i))] = val;
        }
    }

    pub fn reload(self: *Memory, dst: u16, src: u16, len: u16) void {
        for (0..len) |i| {
            self.ram[dst +% @as(u16, @intCast(i))] = self.rom[src +% @as(u16, @intCast(i))];
        }
    }
};
