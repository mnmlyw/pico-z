const std = @import("std");
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const cart_mod = @import("cart.zig");
const api = @import("api.zig");
const preprocessor = @import("preprocessor.zig");

pub const LuaEngine = struct {
    lua: *zlua.Lua,
    has_init: bool = false,
    has_update: bool = false,
    has_update60: bool = false,
    has_draw: bool = false,
    had_error: bool = false,
    error_msg: [512]u8 = undefined,
    error_len: usize = 0,
    allocator: std.mem.Allocator,
    pico: *api.PicoState,
    processed_source: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, pico: *api.PicoState) !LuaEngine {
        const lua = try zlua.Lua.init(allocator);
        lua.openLibs();

        api.registerAll(lua, pico);

        return LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .pico = pico,
        };
    }

    pub fn deinit(self: *LuaEngine) void {
        if (self.processed_source) |src| self.allocator.free(src);
        self.lua.deinit();
    }

    pub fn loadCart(self: *LuaEngine, cart: *const cart_mod.Cart, allocator: std.mem.Allocator) !void {
        // Preprocess PICO-8 Lua to standard Lua 5.2
        const processed = try preprocessor.preprocess(allocator, cart.lua_code);

        // Store processed source for reinit (free old one if any)
        if (self.processed_source) |old| allocator.free(old);
        self.processed_source = processed;

        // Load and execute the processed code
        self.lua.loadBuffer(processed, "cart", .text) catch {
            self.captureError();
            std.log.err("lua load error: {s}", .{self.getErrorMsg()});
            return;
        };
        self.lua.protectedCall(.{ .results = zlua.mult_return }) catch {
            self.captureError();
            std.log.err("lua exec error: {s}", .{self.getErrorMsg()});
            return;
        };

        // Detect lifecycle functions
        self.has_init = self.hasGlobal("_init");
        self.has_update60 = self.hasGlobal("_update60");
        self.has_update = self.hasGlobal("_update");
        self.has_draw = self.hasGlobal("_draw");
    }

    pub fn callInit(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.has_init) {
            self.callGlobal("_init");
        }
    }

    pub fn callUpdate(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.has_update60) {
            self.callGlobal("_update60");
        } else if (self.has_update) {
            self.callGlobal("_update");
        }
    }

    pub fn callDraw(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.has_draw) {
            self.callGlobal("_draw");
        }
    }

    fn callGlobal(self: *LuaEngine, name: [:0]const u8) void {
        _ = self.lua.getGlobal(name) catch {
            self.captureError();
            return;
        };
        self.lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
            self.captureError();
            std.log.err("lua runtime error in {s}: {s}", .{ name, self.getErrorMsg() });
            return;
        };
    }

    fn hasGlobal(self: *LuaEngine, name: [:0]const u8) bool {
        const typ = self.lua.getGlobal(name) catch return false;
        defer self.lua.pop(1);
        return typ == .function;
    }

    fn captureError(self: *LuaEngine) void {
        self.had_error = true;
        if (self.lua.toString(-1)) |msg| {
            const len = @min(msg.len, self.error_msg.len);
            @memcpy(self.error_msg[0..len], msg[0..len]);
            self.error_len = len;
            self.lua.pop(1);
        } else |_| {
            const msg = "unknown error";
            @memcpy(self.error_msg[0..msg.len], msg);
            self.error_len = msg.len;
        }
    }

    pub fn getErrorMsg(self: *const LuaEngine) []const u8 {
        return self.error_msg[0..self.error_len];
    }

    pub fn use60fps(self: *const LuaEngine) bool {
        return self.has_update60;
    }

    /// Destroy and recreate the Lua VM, re-execute cart source (without calling _init).
    /// Used by save state load to recreate all functions before restoring globals.
    pub fn reinit(self: *LuaEngine) !void {
        self.lua.deinit();
        self.lua = try zlua.Lua.init(self.allocator);
        self.lua.openLibs();
        api.registerAll(self.lua, self.pico);

        self.had_error = false;
        self.error_len = 0;

        if (self.processed_source) |source| {
            self.lua.loadBuffer(source, "cart", .text) catch {
                self.captureError();
                std.log.err("lua load error on reinit: {s}", .{self.getErrorMsg()});
                return;
            };
            self.lua.protectedCall(.{ .results = zlua.mult_return }) catch {
                self.captureError();
                std.log.err("lua exec error on reinit: {s}", .{self.getErrorMsg()});
                return;
            };

            self.has_init = self.hasGlobal("_init");
            self.has_update60 = self.hasGlobal("_update60");
            self.has_update = self.hasGlobal("_update");
            self.has_draw = self.hasGlobal("_draw");
        }
    }
};
