const std = @import("std");
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const api = @import("api.zig");
const audio_mod = @import("audio.zig");
const input_mod = @import("input.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;
const fs_atomic = @import("fs_atomic.zig");

const MAGIC = [4]u8{ 'P', 'Z', 'S', 'V' };
const VERSION: u8 = 7;

/// Byte buffer backed by unmanaged ArrayList
pub const ByteBuf = std.ArrayList(u8);

pub fn bufAppend(buf: *ByteBuf, alloc: std.mem.Allocator, data: []const u8) !void {
    try buf.appendSlice(alloc, data);
}

pub fn bufAppendByte(buf: *ByteBuf, alloc: std.mem.Allocator, byte: u8) !void {
    try buf.append(alloc, byte);
}

fn bufAppendZeros(buf: *ByteBuf, alloc: std.mem.Allocator, count: usize) !void {
    try buf.ensureUnusedCapacity(alloc, count);
    for (0..count) |_| {
        buf.appendAssumeCapacity(0);
    }
}

/// Read cursor over a byte slice
pub const ReadCursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn readNoEof(self: *ReadCursor, out: []u8) !void {
        if (self.pos + out.len > self.data.len) return error.EndOfStream;
        @memcpy(out, self.data[self.pos..][0..out.len]);
        self.pos += out.len;
    }

    fn readByte(self: *ReadCursor) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn skip(self: *ReadCursor, len: usize) !void {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        self.pos += len;
    }
};

/// Serialize save state to a byte buffer (no file I/O).
pub fn serializeState(pico: *api.PicoState, lua_engine: *LuaEngine) ![]u8 {
    const alloc = pico.allocator;
    var buf: ByteBuf = .empty;
    errdefer buf.deinit(alloc);

    try bufAppend(&buf, alloc, &MAGIC);
    try bufAppendByte(&buf, alloc, VERSION);
    try bufAppend(&buf, alloc, &pico.memory.ram);
    try bufAppend(&buf, alloc, &pico.memory.rom);

    if (pico.audio) |audio| {
        audio.lockStream();
        defer audio.unlockStream();
        try writeAudioState(&buf, alloc, audio);
    } else {
        try bufAppendZeros(&buf, alloc, audioStateSize());
    }

    try writeInputState(&buf, alloc, pico.input);
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.frame_count));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.elapsed_time));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.line_x));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.line_y));
    try bufAppendByte(&buf, alloc, if (pico.line_valid) 1 else 0);
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.rng_state));
    try serializeLuaGlobals(&buf, alloc, lua_engine.lua);

    return buf.toOwnedSlice(alloc);
}

pub fn saveState(pico: *api.PicoState, lua_engine: *LuaEngine, cart_path: []const u8) !void {
    const alloc = pico.allocator;
    const save_path = try getSavePath(alloc, cart_path);
    defer alloc.free(save_path);

    const data = try serializeState(pico, lua_engine);
    defer alloc.free(data);

    try fs_atomic.writeFileAtomic(alloc, std.fs.cwd(), save_path, data);
    std.log.info("save state written to {s}", .{save_path});
}

/// Deserialize save state from a byte buffer (no file I/O).
pub fn deserializeState(pico: *api.PicoState, lua_engine: *LuaEngine, data: []const u8) !void {
    var cursor = ReadCursor{ .data = data };
    return loadStateFromCursor(pico, lua_engine, &cursor);
}

pub fn loadState(pico: *api.PicoState, lua_engine: *LuaEngine, cart_path: []const u8) !void {
    const alloc = pico.allocator;
    const save_path = try getSavePath(alloc, cart_path);
    defer alloc.free(save_path);

    const file = std.fs.cwd().openFile(save_path, .{}) catch |err| {
        std.log.warn("no save state found: {s}", .{save_path});
        return err;
    };
    defer file.close();
    const data = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
    defer alloc.free(data);

    var cursor = ReadCursor{ .data = data };
    return loadStateFromCursor(pico, lua_engine, &cursor);
}

fn loadStateFromCursor(pico: *api.PicoState, lua_engine: *LuaEngine, cursor: *ReadCursor) !void {
    const alloc = pico.allocator;

    // Header
    var magic: [4]u8 = undefined;
    try cursor.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidSaveState;
    const version = try cursor.readByte();
    if (version != VERSION) return error.UnsupportedVersion;

    // Stage the host/runtime state first so failed Lua restore doesn't
    // leave the process in a hybrid partially-restored state.
    var staged_ram: [mem_const.RAM_SIZE]u8 = undefined;
    try cursor.readNoEof(&staged_ram);
    var staged_rom: [mem_const.RAM_SIZE]u8 = undefined;
    try cursor.readNoEof(&staged_rom);

    var staged_audio: ?audio_mod.Audio = null;
    if (pico.audio != null) {
        var audio = audio_mod.Audio.init(pico.memory);
        try readAudioState(cursor, &audio);
        staged_audio = audio;
    } else {
        try cursor.skip(audioStateSize());
    }

    var staged_input = pico.input.*;
    try readInputState(cursor, &staged_input);

    var staged_frame_count: u32 = undefined;
    var staged_elapsed_time: f64 = undefined;
    var staged_line_x: i32 = undefined;
    var staged_line_y: i32 = undefined;
    var staged_rng_state: u32 = undefined;
    try cursor.readNoEof(std.mem.asBytes(&staged_frame_count));
    try cursor.readNoEof(std.mem.asBytes(&staged_elapsed_time));
    try cursor.readNoEof(std.mem.asBytes(&staged_line_x));
    try cursor.readNoEof(std.mem.asBytes(&staged_line_y));
    const staged_line_valid = (try cursor.readByte()) != 0;
    try cursor.readNoEof(std.mem.asBytes(&staged_rng_state));

    const saved_ram = pico.memory.ram;
    const saved_rom = pico.memory.rom;
    const saved_input = pico.input.*;
    const saved_frame_count = pico.frame_count;
    const saved_elapsed_time = pico.elapsed_time;
    const saved_line_x = pico.line_x;
    const saved_line_y = pico.line_y;
    const saved_line_valid = pico.line_valid;
    const saved_rng_state = pico.rng_state;
    const saved_audio_ptr = pico.audio;
    var saved_audio: ?audio_mod.Audio = null;
    if (saved_audio_ptr) |audio| {
        audio.lockStream();
        saved_audio = audio.*;
        clearAudioStream(audio);
        if (staged_audio) |*staged| {
            applyAudioRuntime(audio, staged);
        }
    }
    defer if (saved_audio_ptr) |audio| {
        audio.unlockStream();
    };

    var restore_host = true;
    defer if (restore_host) {
        pico.memory.ram = saved_ram;
        pico.memory.rom = saved_rom;
        pico.input.* = saved_input;
        pico.frame_count = saved_frame_count;
        pico.elapsed_time = saved_elapsed_time;
        pico.line_x = saved_line_x;
        pico.line_y = saved_line_y;
        pico.line_valid = saved_line_valid;
        pico.rng_state = saved_rng_state;
        pico.audio = saved_audio_ptr;
        if (saved_audio_ptr) |audio| {
            clearAudioStream(audio);
            if (saved_audio) |saved| {
                audio.* = saved;
            }
        }
    };

    pico.memory.ram = staged_ram;
    pico.memory.rom = staged_rom;
    pico.input.* = staged_input;
    pico.frame_count = staged_frame_count;
    pico.elapsed_time = staged_elapsed_time;
    pico.line_x = staged_line_x;
    pico.line_y = staged_line_y;
    pico.line_valid = staged_line_valid;
    pico.rng_state = staged_rng_state;
    pico.audio = null;

    var staged_engine = try LuaEngine.init(alloc, pico);
    errdefer staged_engine.deinit();
    if (lua_engine.processed_source) |source| {
        staged_engine.processed_source = try alloc.dupe(u8, source);
    }
    try staged_engine.reinit();
    try deserializeLuaGlobals(cursor, staged_engine.lua);

    pico.audio = saved_audio_ptr;
    if (saved_audio_ptr) |audio| {
        clearAudioStream(audio);
        if (staged_audio) |*staged| {
            applyAudioRuntime(audio, staged);
        }
    }

    lua_engine.deinit();
    lua_engine.* = staged_engine;
    restore_host = false;
    std.log.info("save state loaded", .{});
}

fn applyAudioRuntime(dst: *audio_mod.Audio, src: *const audio_mod.Audio) void {
    dst.channels = src.channels;
    dst.music_state = src.music_state;
    dst.noise_seed = src.noise_seed;
}

fn clearAudioStream(audio: *audio_mod.Audio) void {
    const builtin = @import("builtin");
    const is_native = (builtin.os.tag != .freestanding and builtin.os.tag != .wasi);
    if (is_native) {
        if (audio.stream) |stream| _ = audio_mod.sdl.SDL_ClearAudioStream(stream);
    }
}

// --- Audio serialization ---

pub fn audioStateSize() usize {
    // Per channel: i8+u8+f32+f64+f32+f32+f64+f64+f64+u8+u8+u8+f32+u8+f32+f32+u8+u8+f32+f64+u8+u8+u8 = 79
    // Music: i16(2)+u32(4)+u8(1)+i16(2)+u8(1)+u32(4)+u32(4)+u8(1)+u32(4) = 23, noise_seed: u32 = 4
    return 4 * 79 + 23 + 4;
}

pub fn writeAudioState(buf: *ByteBuf, alloc: std.mem.Allocator, a: *audio_mod.Audio) !void {
    for (0..4) |i| {
        const ch = &a.channels[i];
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.sfx_id));
        try bufAppendByte(buf, alloc, ch.note_index);
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.sub_tick));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.phase));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.volume));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.base_volume));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.frequency));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.base_frequency));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.prev_frequency));
        try bufAppendByte(buf, alloc, @intFromEnum(ch.waveform));
        try bufAppendByte(buf, alloc, ch.effect);
        try bufAppendByte(buf, alloc, if (ch.custom) 1 else 0);
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.note_progress));
        try bufAppendByte(buf, alloc, if (ch.finished) 1 else 0);
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.noise_sample));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.noise_prev_sample));
        try bufAppendByte(buf, alloc, ch.inst_sfx_id);
        try bufAppendByte(buf, alloc, ch.inst_note_index);
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.inst_sub_tick));
        try bufAppend(buf, alloc, std.mem.asBytes(&ch.inst_phase));
        try bufAppendByte(buf, alloc, ch.prev_pitch);
        try bufAppendByte(buf, alloc, ch.prev_vol);
        try bufAppendByte(buf, alloc, if (ch.loop_released) 1 else 0);
    }
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.pattern));
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.tick));
    try bufAppendByte(buf, alloc, a.music_state.channel_mask);
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.loop_back));
    try bufAppendByte(buf, alloc, if (a.music_state.playing) 1 else 0);
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.total_patterns));
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.fade_samples));
    try bufAppendByte(buf, alloc, if (a.music_state.fade_out) 1 else 0);
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.fade_progress));
    try bufAppend(buf, alloc, std.mem.asBytes(&a.noise_seed));
}

pub fn readAudioState(cursor: *ReadCursor, a: *audio_mod.Audio) !void {
    for (0..4) |i| {
        var ch = &a.channels[i];
        try cursor.readNoEof(std.mem.asBytes(&ch.sfx_id));
        ch.note_index = try cursor.readByte();
        try cursor.readNoEof(std.mem.asBytes(&ch.sub_tick));
        try cursor.readNoEof(std.mem.asBytes(&ch.phase));
        try cursor.readNoEof(std.mem.asBytes(&ch.volume));
        try cursor.readNoEof(std.mem.asBytes(&ch.base_volume));
        try cursor.readNoEof(std.mem.asBytes(&ch.frequency));
        try cursor.readNoEof(std.mem.asBytes(&ch.base_frequency));
        try cursor.readNoEof(std.mem.asBytes(&ch.prev_frequency));
        ch.waveform = @enumFromInt(@as(u3, @truncate(try cursor.readByte())));
        ch.effect = @truncate(try cursor.readByte());
        ch.custom = (try cursor.readByte()) != 0;
        try cursor.readNoEof(std.mem.asBytes(&ch.note_progress));
        ch.finished = (try cursor.readByte()) != 0;
        try cursor.readNoEof(std.mem.asBytes(&ch.noise_sample));
        try cursor.readNoEof(std.mem.asBytes(&ch.noise_prev_sample));
        ch.inst_sfx_id = @truncate(try cursor.readByte());
        ch.inst_note_index = try cursor.readByte();
        try cursor.readNoEof(std.mem.asBytes(&ch.inst_sub_tick));
        try cursor.readNoEof(std.mem.asBytes(&ch.inst_phase));
        ch.prev_pitch = @truncate(try cursor.readByte());
        ch.prev_vol = @truncate(try cursor.readByte());
        ch.loop_released = (try cursor.readByte()) != 0;
    }
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.pattern));
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.tick));
    a.music_state.channel_mask = try cursor.readByte();
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.loop_back));
    a.music_state.playing = (try cursor.readByte()) != 0;
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.total_patterns));
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.fade_samples));
    a.music_state.fade_out = (try cursor.readByte()) != 0;
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.fade_progress));
    try cursor.readNoEof(std.mem.asBytes(&a.noise_seed));
}

// --- Input serialization ---

fn writeInputState(buf: *ByteBuf, alloc: std.mem.Allocator, input: *input_mod.Input) !void {
    try bufAppend(buf, alloc, &input.btn_state);
    try bufAppend(buf, alloc, &input.prev_state);
    try bufAppend(buf, alloc, std.mem.asBytes(&input.held_frames));
}

fn readInputState(cursor: *ReadCursor, input: *input_mod.Input) !void {
    try cursor.readNoEof(&input.btn_state);
    try cursor.readNoEof(&input.prev_state);
    try cursor.readNoEof(std.mem.asBytes(&input.held_frames));
}

// --- Lua global serialization via Lua script ---
//
// The serializer generates Lua code that restores globals when executed.
// Key features:
// - Function values serialize as path references to their global location
//   (e.g., types[1].update), resolved after reinit + _init()
// - Tables with metatables that are known globals get setmetatable() wrappers
// - Nested table references to known globals emit the global name
// - Anonymous closures not reachable from globals serialize as "nil"

const lua_serializer =
    \\local _sk={_G=1,_VERSION=1,coroutine=1,debug=1,io=1,math=1,os=1,
    \\package=1,string=1,table=1,bit32=1,assert=1,collectgarbage=1,
    \\dofile=1,error=1,getmetatable=1,ipairs=1,load=1,loadfile=1,
    \\module=1,next=1,pairs=1,pcall=1,rawequal=1,rawget=1,rawlen=1,
    \\rawset=1,require=1,select=1,setmetatable=1,tonumber=1,tostring=1,
    \\type=1,unpack=1,xpcall=1,
    \\cls=1,pset=1,pget=1,line=1,rect=1,rectfill=1,circ=1,circfill=1,
    \\oval=1,ovalfill=1,spr=1,sspr=1,map=1,mget=1,mset=1,sget=1,sset=1,
    \\fget=1,fset=1,print=1,cursor=1,color=1,camera=1,clip=1,pal=1,
    \\palt=1,fillp=1,tline=1,btn=1,btnp=1,
    \\abs=1,flr=1,ceil=1,sqrt=1,sin=1,cos=1,atan2=1,max=1,min=1,mid=1,
    \\rnd=1,srand=1,sgn=1,band=1,bor=1,bxor=1,bnot=1,shl=1,shr=1,
    \\lshr=1,rotl=1,rotr=1,tostr=1,tonum=1,
    \\add=1,del=1,deli=1,count=1,foreach=1,all=1,pack=1,
    \\sub=1,chr=1,ord=1,split=1,
    \\cocreate=1,coresume=1,costatus=1,yield=1,
    \\peek=1,poke=1,peek2=1,poke2=1,peek4=1,poke4=1,
    \\memcpy=1,memset=1,reload=1,cstore=1,
    \\sfx=1,music=1,stat=1,time=1,t=1,printh=1,
    \\cartdata=1,dget=1,dset=1,menuitem=1,extcmd=1,
    \\load=1,run=1,stop=1,flip=1,reset=1,rrect=1,rrectfill=1,serial=1}
    \\local _gn={}
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and type(v)=="table" and not _sk[k] then
    \\    _gn[v]=k
    \\    for k2,v2 in pairs(v) do
    \\      if type(k2)=="string" and type(v2)=="table" and not _gn[v2] then
    \\        _gn[v2]=k.."."..k2
    \\      end
    \\    end
    \\  end
    \\end
    \\local _fn={}
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and not _sk[k] then
    \\    if type(v)=="function" then
    \\      _fn[v]=k
    \\    elseif type(v)=="table" then
    \\      for k2,v2 in pairs(v) do
    \\        if type(v2)=="function" and not _fn[v2] then
    \\          if type(k2)=="string" then _fn[v2]=k.."."..k2
    \\          elseif type(k2)=="number" then _fn[v2]=k.."["..string.format("%.17g",k2).."]" end
    \\        end
    \\      end
    \\    end
    \\  end
    \\end
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and not _sk[k] and type(v)=="table" then
    \\    for k2,v2 in pairs(v) do
    \\      if type(v2)=="table" then
    \\        for k3,v3 in pairs(v2) do
    \\          if type(v3)=="function" and not _fn[v3] then
    \\            local p=k
    \\            if type(k2)=="string" then p=p.."."..k2
    \\            elseif type(k2)=="number" then p=p.."["..string.format("%.17g",k2).."]" end
    \\            if type(k3)=="string" then p=p.."."..k3
    \\            elseif type(k3)=="number" then p=p.."["..string.format("%.17g",k3).."]" end
    \\            _fn[v3]=p
    \\          end
    \\        end
    \\      end
    \\    end
    \\  end
    \\end
    \\local function _s(v,d,seen)
    \\  if v==nil then return"nil"
    \\  elseif type(v)=="number" then
    \\    if v~=v then return"0"
    \\    else return string.format("%.17g",v) end
    \\  elseif type(v)=="boolean" then return tostring(v)
    \\  elseif type(v)=="string" then return string.format("%q",v)
    \\  elseif type(v)=="function" then
    \\    local ref=_fn[v]
    \\    if ref then return ref else return"nil" end
    \\  elseif type(v)=="table" then
    \\    if seen[v] then return _gn[v] or"nil" end
    \\    seen[v]=true
    \\    local p={}
    \\    local n=0
    \\    for i=1,#v do n=i end
    \\    for i=1,n do p[#p+1]=_s(v[i],d+1,seen) end
    \\    for k2,v2 in pairs(v) do
    \\      local ia=type(k2)=="number" and k2>=1 and k2<=n and k2==flr(k2)
    \\      if not ia then
    \\        if type(k2)=="string" then
    \\          p[#p+1]=string.format("[%q]=",k2).._s(v2,d+1,seen)
    \\        elseif type(k2)=="number" then
    \\          p[#p+1]="["..string.format("%.17g",k2).."]="
    \\            .._s(v2,d+1,seen)
    \\        elseif type(k2)=="boolean" then
    \\          p[#p+1]="["..tostring(k2).."]="
    \\            .._s(v2,d+1,seen)
    \\        end
    \\      end
    \\    end
    \\    seen[v]=nil
    \\    local mt=getmetatable(v)
    \\    local r="{"..table.concat(p,",").."}"
    \\    if mt and _gn[mt] then r="setmetatable("..r..",".. _gn[mt]..")" end
    \\    return r
    \\  else return"nil" end
    \\end
    \\local _r={"local function _m(t,d) for k in pairs(t) do t[k]=nil end for k,v in pairs(d) do t[k]=v end local mt=getmetatable(d) if mt then setmetatable(t,mt) end return t end"}
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and not _sk[k] and type(v)~="function" then
    \\    local sv=_s(v,0,{})
    \\    if type(v)=="table" then
    \\      _r[#_r+1]=k.."=type("..k..")=='table' and _m("..k..","..sv..") or "..sv
    \\    else
    \\      _r[#_r+1]=k.."="..sv
    \\    end
    \\  end
    \\end
    \\return table.concat(_r,"\n")
;

fn serializeLuaGlobals(buf: *ByteBuf, alloc: std.mem.Allocator, lua: *zlua.Lua) !void {
    // Load and execute the serializer script
    lua.loadBuffer(lua_serializer, "__pz_ser", .text) catch |err| {
        std.log.warn("save: serializer load error: {}", .{err});
        return error.LuaSerializerLoadError;
    };
    lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.warn("save: serializer exec error: {s}", .{err_msg});
        lua.pop(1);
        return error.LuaSerializerExecError;
    };

    // Get result string
    const script = lua.toString(-1) catch {
        lua.pop(1);
        return error.LuaSerializerResultError;
    };

    // Write script length and data
    const script_len: u32 = @intCast(script.len);
    try bufAppend(buf, alloc, std.mem.asBytes(&script_len));
    try bufAppend(buf, alloc, script);

    lua.pop(1); // pop result
}

fn deserializeLuaGlobals(cursor: *ReadCursor, lua: *zlua.Lua) !void {
    var len_bytes: [4]u8 = undefined;
    try cursor.readNoEof(&len_bytes);
    const script_len: u32 = std.mem.bytesToValue(u32, &len_bytes);

    if (script_len == 0) return;
    if (cursor.pos + script_len > cursor.data.len) {
        return error.InvalidSaveState;
    }

    const script = cursor.data[cursor.pos..][0..script_len];
    cursor.pos += script_len;

    // Execute the restore script
    lua.loadBuffer(script, "save_restore", .text) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.warn("load: restore script parse error: {s}", .{err_msg});
        lua.pop(1);
        return error.LuaRestoreParseError;
    };
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.warn("load: restore script exec error: {s}", .{err_msg});
        lua.pop(1);
        return error.LuaRestoreExecError;
    };
}

fn getSavePath(alloc: std.mem.Allocator, cart_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, cart_path, ".p8")) {
        const base = cart_path[0 .. cart_path.len - 3];
        return std.fmt.allocPrint(alloc, "{s}.sav", .{base});
    }
    return std.fmt.allocPrint(alloc, "{s}.sav", .{cart_path});
}
