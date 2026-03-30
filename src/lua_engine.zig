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
        sandboxGlobals(lua);

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
        errdefer allocator.free(processed);

        // Load and execute the processed code — don't replace source until success
        self.lua.loadBuffer(processed, "cart", .text) catch {
            self.captureError();
            std.log.err("lua load error: {s}", .{self.getErrorMsg()});
            return error.LuaLoadError;
        };
        self.lua.protectedCall(.{ .results = zlua.mult_return }) catch {
            self.captureError();
            std.log.err("lua exec error: {s}", .{self.getErrorMsg()});
            return error.LuaExecError;
        };

        // Success — now commit the new source
        if (self.processed_source) |old| allocator.free(old);
        self.processed_source = processed;

        // Detect lifecycle functions
        self.has_init = self.hasGlobal("_init");
        self.has_update60 = self.hasGlobal("_update60");
        self.has_update = self.hasGlobal("_update");
        self.has_draw = self.hasGlobal("_draw");
    }

    pub fn callInit(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.has_init) {
            self.callGlobal("_init", true);
        }
    }

    pub fn callUpdate(self: *LuaEngine) void {
        self.callUpdateWithLogging(true);
    }

    pub fn callUpdateWithLogging(self: *LuaEngine, log_runtime_errors: bool) void {
        if (self.had_error) return;
        if (self.has_update60) {
            self.callGlobal("_update60", log_runtime_errors);
        } else if (self.has_update) {
            self.callGlobal("_update", log_runtime_errors);
        }
    }

    pub fn callDraw(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.has_draw) {
            self.callGlobal("_draw", true);
        }
    }

    fn callGlobal(self: *LuaEngine, name: [:0]const u8, log_runtime_errors: bool) void {
        _ = self.lua.getGlobal(name) catch {
            self.captureError();
            return;
        };
        self.lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
            // Check if this is a cart load/run signal (not a real error)
            // Only suppress if a pending load was actually requested
            if (self.pico.pending_load != null) {
                self.lua.pop(1);
                return; // Not a real error — main loop will handle the load
            }
            self.captureError();
            if (log_runtime_errors) {
                std.log.err("lua runtime error in {s}: {s}", .{ name, self.getErrorMsg() });
            }
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

    /// Remove standard Lua libraries/globals that PICO-8 doesn't expose.
    fn sandboxGlobals(lua: *zlua.Lua) void {
        const blocked = [_][:0]const u8{
            "io",
            "os",
            "debug",
            "package",
            "require",
            "module",
            "dofile",
            "loadfile",
            "load",
            "collectgarbage",
            "coroutine",
            "math",
        };
        for (blocked) |name| {
            lua.pushNil();
            lua.setGlobal(name);
        }
    }

    /// Destroy and recreate the Lua VM without executing any cart source.
    /// Used before loading a new cart to get a clean VM state.
    pub fn resetVM(self: *LuaEngine) !void {
        const new_lua = try zlua.Lua.init(self.allocator);
        self.lua.deinit();
        self.lua = new_lua;
        self.lua.openLibs();
        sandboxGlobals(self.lua);
        api.registerAll(self.lua, self.pico);

        self.had_error = false;
        self.error_len = 0;
        self.has_init = false;
        self.has_update = false;
        self.has_update60 = false;
        self.has_draw = false;
    }

    /// Destroy and recreate the Lua VM, re-execute cart source (without calling _init).
    /// Used by save state load to recreate all functions before restoring globals.
    pub fn reinit(self: *LuaEngine) !void {
        try self.resetVM();

        if (self.processed_source) |source| {
            self.lua.loadBuffer(source, "cart", .text) catch {
                self.captureError();
                std.log.err("lua load error on reinit: {s}", .{self.getErrorMsg()});
                return error.LuaLoadError;
            };
            self.lua.protectedCall(.{ .results = zlua.mult_return }) catch {
                self.captureError();
                std.log.err("lua exec error on reinit: {s}", .{self.getErrorMsg()});
                return error.LuaExecError;
            };

            self.has_init = self.hasGlobal("_init");
            self.has_update60 = self.hasGlobal("_update60");
            self.has_update = self.hasGlobal("_update");
            self.has_draw = self.hasGlobal("_draw");
        }
    }
};
