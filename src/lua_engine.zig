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
    error_msg: [2048]u8 = undefined,
    error_len: usize = 0,
    allocator: std.mem.Allocator,
    pico: *api.PicoState,
    processed_source: ?[]const u8 = null,
    // When the cart called flip() and the per-frame coroutine yielded, this
    // holds the coroutine so we can resume it next tick. Null = next tick
    // starts a fresh coroutine.
    tick_co: ?*zlua.Lua = null,
    // Registry ref to keep the active tick coroutine GC-anchored.
    tick_co_ref: c_int = -1,

    pub fn init(allocator: std.mem.Allocator, pico: *api.PicoState) !LuaEngine {
        const lua = try zlua.Lua.init(allocator);
        lua.openLibs();
        sandboxGlobals(lua);

        api.registerAll(lua, pico);
        setupEnvFallback(lua);

        // Install a Lua-defined per-frame tick body. Defined as a Lua function
        // (not a C closure) so flip() inside the cart can yield through it —
        // Lua 5.2 forbids yielding across non-yieldable C frames.
        const tick_src =
            \\function __pz_tick()
            \\  if type(_update60) == "function" then _update60()
            \\  elseif type(_update) == "function" then _update() end
            \\  if type(_draw) == "function" then _draw() end
            \\end
        ;
        lua.loadBuffer(tick_src, "__pz_tick", .text) catch return error.LuaLoadError;
        lua.protectedCall(.{}) catch return error.LuaExecError;

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
        // _init may install lifecycle hooks dynamically (e.g. start_title sets
        // _update60 = update_title), so re-detect after running it.
        self.refreshLifecycleFlags();
    }

    pub fn callUpdate(self: *LuaEngine) void {
        self.callUpdateWithLogging(true);
    }

    pub fn callUpdateWithLogging(self: *LuaEngine, log_runtime_errors: bool) void {
        if (self.had_error) return;
        if (self.hasGlobal("_update60")) {
            self.callGlobal("_update60", log_runtime_errors);
        } else if (self.hasGlobal("_update")) {
            self.callGlobal("_update", log_runtime_errors);
        }
    }

    pub fn callDraw(self: *LuaEngine) void {
        if (self.had_error) return;
        if (self.hasGlobal("_draw")) {
            self.callGlobal("_draw", true);
        }
    }

    /// Result of a single coroutine-driven frame tick.
    pub const TickResult = enum { done, yielded, errored };

    /// Run one frame of cart code (update + draw) inside a Lua coroutine.
    /// If the cart calls flip(), the coroutine yields and we return .yielded
    /// — the caller should render the current screen and call tickFrame()
    /// again next frame to resume from where the cart left off. When the
    /// frame's full update + draw completes, returns .done.
    pub fn tickFrame(self: *LuaEngine) TickResult {
        if (self.had_error) return .errored;

        // Resume an in-progress coroutine if one is live (cart yielded last tick).
        if (self.tick_co) |co| {
            return self.resumeTick(co, 0);
        }

        // Start a fresh coroutine. The thread is created from `self.lua`'s
        // pool and shares the global state. We anchor it in the registry so
        // it survives GC while we hold it across yields.
        const co = self.lua.newThread();
        self.tick_co_ref = self.lua.ref(zlua.registry_index) catch {
            self.captureError();
            return .errored;
        };

        // Push __pz_tick (a pure-Lua function) onto co's stack. Because it's
        // Lua, not C, the inner flip()→yield can travel up through it.
        const t = co.getGlobal("__pz_tick") catch zlua.LuaType.nil;
        if (t != zlua.LuaType.function) {
            co.pop(1);
            self.releaseTickCo();
            return .done; // no tick body installed (shouldn't happen post-init)
        }
        return self.resumeTick(co, 0);
    }

    fn resumeTick(self: *LuaEngine, co: *zlua.Lua, num_args: i32) TickResult {
        const status = co.resumeThread(self.lua, num_args) catch {
            // Capture error from the coroutine's stack
            if (co.toString(-1)) |msg| {
                const len = @min(msg.len, self.error_msg.len);
                @memcpy(self.error_msg[0..len], msg[0..len]);
                self.error_len = len;
            } else |_| {
                const m = "coroutine error";
                @memcpy(self.error_msg[0..m.len], m);
                self.error_len = m.len;
            }
            self.had_error = true;
            self.releaseTickCo();
            std.log.err("lua runtime error in tick: {s}", .{self.getErrorMsg()});
            return .errored;
        };
        switch (status) {
            .yield => {
                self.tick_co = co;
                return .yielded;
            },
            .ok => {
                self.releaseTickCo();
                return .done;
            },
        }
    }

    fn releaseTickCo(self: *LuaEngine) void {
        self.tick_co = null;
        if (self.tick_co_ref >= 0) {
            self.lua.unref(zlua.registry_index, self.tick_co_ref);
            self.tick_co_ref = -1;
        }
    }

    fn refreshLifecycleFlags(self: *LuaEngine) void {
        self.has_update60 = self.hasGlobal("_update60");
        self.has_update = self.hasGlobal("_update");
        self.has_draw = self.hasGlobal("_draw");
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

        // Try to append traceback for debugging
        _ = self.lua.getGlobal("__pz_tb") catch {};
        if (self.lua.isFunction(-1)) {
            self.lua.pushValue(-2); // push error message
            self.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
                self.lua.pop(1);
            };
            // Replace original error with traceback version
            self.lua.remove(-2);
        } else {
            self.lua.pop(1);
        }

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
        // Save debug.traceback as __pz_tb before removing debug
        _ = lua.getGlobal("debug") catch {};
        const field_type = lua.getField(-1, "traceback");
        _ = field_type;
        lua.setGlobal("__pz_tb");
        lua.pop(1); // pop debug table

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

    /// Emulate z8lua's _ENV fallback: when a table without a metatable is
    /// returned by all()/foreach()/pairs(), set __index=_G so global lookups
    /// (like circ, circfill) still work when the table is used as _ENV.
    fn setupEnvFallback(lua: *zlua.Lua) void {
        const script =
            \\do
            \\  local mt={__index=_G}
            \\  local rawall=all
            \\  local rawforeach=foreach
            \\  local sm=setmetatable
            \\  local gm=getmetatable
            \\  local tp=type
            \\  local function wrap(v)
            \\    if tp(v)=="table" and not gm(v) then sm(v,mt) end
            \\    return v
            \\  end
            \\  all=function(t)
            \\    local it=rawall(t)
            \\    return function() return wrap(it()) end
            \\  end
            \\  foreach=function(t,f)
            \\    return rawforeach(t,function(v) return f(wrap(v)) end)
            \\  end
            \\end
        ;
        lua.loadBuffer(script, "__pz_env", .text) catch return;
        lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
            lua.pop(1);
        };
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
        setupEnvFallback(self.lua);

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
