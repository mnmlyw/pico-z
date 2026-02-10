const std = @import("std");
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const api = @import("api.zig");
const audio_mod = @import("audio.zig");
const input_mod = @import("input.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;

const MAGIC = [4]u8{ 'P', 'Z', 'S', 'V' };
const VERSION: u8 = 2;

/// Byte buffer backed by unmanaged ArrayList
const ByteBuf = std.ArrayList(u8);

fn bufAppend(buf: *ByteBuf, alloc: std.mem.Allocator, data: []const u8) !void {
    try buf.appendSlice(alloc, data);
}

fn bufAppendByte(buf: *ByteBuf, alloc: std.mem.Allocator, byte: u8) !void {
    try buf.append(alloc, byte);
}

fn bufAppendZeros(buf: *ByteBuf, alloc: std.mem.Allocator, count: usize) !void {
    try buf.ensureUnusedCapacity(alloc, count);
    for (0..count) |_| {
        buf.appendAssumeCapacity(0);
    }
}

/// Read cursor over a byte slice
const ReadCursor = struct {
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

pub fn saveState(pico: *api.PicoState, lua_engine: *LuaEngine, cart_path: []const u8) !void {
    const alloc = pico.allocator;
    const save_path = try getSavePath(alloc, cart_path);
    defer alloc.free(save_path);

    var buf: ByteBuf = .empty;
    defer buf.deinit(alloc);

    // Header
    try bufAppend(&buf, alloc, &MAGIC);
    try bufAppendByte(&buf, alloc, VERSION);

    // 1. RAM
    try bufAppend(&buf, alloc, &pico.memory.ram);

    // 2. Audio state
    if (pico.audio) |audio| {
        audio.lockStream();
        defer audio.unlockStream();
        try writeAudioState(&buf, alloc, audio);
    } else {
        try bufAppendZeros(&buf, alloc, audioStateSize());
    }

    // 3. Input state
    try writeInputState(&buf, alloc, pico.input);

    // 4. Pico fields
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.frame_count));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.start_time));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.line_x));
    try bufAppend(&buf, alloc, std.mem.asBytes(&pico.line_y));
    try bufAppendByte(&buf, alloc, if (pico.line_valid) 1 else 0);

    // 5. Lua globals (as Lua script)
    try serializeLuaGlobals(&buf, alloc, lua_engine.lua);

    // Write to file
    const file = try std.fs.cwd().createFile(save_path, .{});
    defer file.close();
    try file.writeAll(buf.items);

    std.log.info("save state written to {s}", .{save_path});
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

    // Header
    var magic: [4]u8 = undefined;
    try cursor.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidSaveState;
    const version = try cursor.readByte();
    if (version != 2) return error.UnsupportedVersion;

    // 1. RAM
    try cursor.readNoEof(&pico.memory.ram);

    // 2. Audio state
    if (pico.audio) |audio| {
        audio.lockStream();
        defer audio.unlockStream();
        try readAudioState(&cursor, audio);
    } else {
        try cursor.skip(audioStateSize());
    }

    // 3. Input state
    try readInputState(&cursor, pico.input);

    // 4. Pico fields
    try cursor.readNoEof(std.mem.asBytes(&pico.frame_count));
    try cursor.readNoEof(std.mem.asBytes(&pico.start_time));
    try cursor.readNoEof(std.mem.asBytes(&pico.line_x));
    try cursor.readNoEof(std.mem.asBytes(&pico.line_y));
    pico.line_valid = (try cursor.readByte()) != 0;

    // 5. Reinit Lua VM then restore globals via Lua script
    try lua_engine.reinit();
    deserializeLuaGlobals(&cursor, lua_engine.lua);

    std.log.info("save state loaded from {s}", .{save_path});
}

// --- Audio serialization ---

fn audioStateSize() usize {
    // Per channel: i8+u8+f32+f64+f32+f32+f64+f64+f64+u8+u8+u8+f32+u8+f32+f32+u8+u8+f32+f64+u8+u8 = 78
    // Music: i16+u32+u8+i16 = 9, noise_seed: u32 = 4
    return 4 * 78 + 9 + 4;
}

fn writeAudioState(buf: *ByteBuf, alloc: std.mem.Allocator, a: *audio_mod.Audio) !void {
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
    }
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.pattern));
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.tick));
    try bufAppendByte(buf, alloc, a.music_state.channel_mask);
    try bufAppend(buf, alloc, std.mem.asBytes(&a.music_state.loop_back));
    try bufAppend(buf, alloc, std.mem.asBytes(&a.noise_seed));
}

fn readAudioState(cursor: *ReadCursor, a: *audio_mod.Audio) !void {
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
    }
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.pattern));
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.tick));
    a.music_state.channel_mask = try cursor.readByte();
    try cursor.readNoEof(std.mem.asBytes(&a.music_state.loop_back));
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
// - Tables with function members use field-by-field updates (preserves functions)
// - Nested table references to known globals emit the global name (preserves references)
// - Functions are skipped entirely (re-created by reinit cart source execution)

const lua_fixup =
    \\if type(init_object)=="function" and type(objects)=="table" then
    \\  local saved={}
    \\  for i=1,#objects do saved[i]=objects[i] end
    \\  objects={}
    \\  for i=1,#saved do
    \\    local o=saved[i]
    \\    if o.type then
    \\      local n=init_object(o.type,o.x or 0,o.y or 0)
    \\      if n then
    \\        for k,v in pairs(o) do
    \\          if type(v)~="function" then n[k]=v end
    \\        end
    \\      end
    \\    end
    \\  end
    \\end
;

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
    \\cartdata=1,dget=1,dset=1,menuitem=1,extcmd=1}
    \\local _gn={}
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and type(v)=="table" and not _sk[k] then
    \\    _gn[v]=k
    \\  end
    \\end
    \\local function _s(v,d,seen)
    \\  if v==nil then return"nil"
    \\  elseif type(v)=="number" then
    \\    if v~=v then return"0"
    \\    else return string.format("%.17g",v) end
    \\  elseif type(v)=="boolean" then return tostring(v)
    \\  elseif type(v)=="string" then return string.format("%q",v)
    \\  elseif type(v)=="table" then
    \\    if d>0 and _gn[v] then return _gn[v] end
    \\    if seen[v] then return"nil" end
    \\    seen[v]=true
    \\    local p={}
    \\    local n=0
    \\    for i=1,#v do n=i end
    \\    for i=1,n do
    \\      if type(v[i])~="function" then p[#p+1]=_s(v[i],d+1,seen)
    \\      else p[#p+1]="nil" end
    \\    end
    \\    for k2,v2 in pairs(v) do
    \\      if type(v2)~="function" then
    \\        local ia=type(k2)=="number" and k2>=1 and k2<=n and k2==math.floor(k2)
    \\        if not ia then
    \\          if type(k2)=="string" then
    \\            p[#p+1]=string.format("[%q]=",k2).._s(v2,d+1,seen)
    \\          elseif type(k2)=="number" then
    \\            p[#p+1]="["..string.format("%.17g",k2).."]="
    \\              .._s(v2,d+1,seen)
    \\          elseif type(k2)=="boolean" then
    \\            p[#p+1]="["..tostring(k2).."]="
    \\              .._s(v2,d+1,seen)
    \\          end
    \\        end
    \\      end
    \\    end
    \\    seen[v]=nil
    \\    return"{"..table.concat(p,",").."}"
    \\  else return"nil" end
    \\end
    \\local _r={}
    \\for k,v in pairs(_G) do
    \\  if type(k)=="string" and not _sk[k] and type(v)~="function" then
    \\    if type(v)=="table" then
    \\      local hf=false
    \\      for _,v2 in pairs(v) do
    \\        if type(v2)=="function" then hf=true break end
    \\      end
    \\      if hf then
    \\        for k2,v2 in pairs(v) do
    \\          if type(v2)~="function" then
    \\            local seen={}
    \\            if type(k2)=="string" then
    \\              _r[#_r+1]=k..string.format("[%q]=",k2).._s(v2,1,seen)
    \\            elseif type(k2)=="number" then
    \\              _r[#_r+1]=k.."["..string.format("%.17g",k2).."]="
    \\                .._s(v2,1,seen)
    \\            end
    \\          end
    \\        end
    \\      else
    \\        _r[#_r+1]=k.."=".._s(v,0,{})
    \\      end
    \\    else
    \\      _r[#_r+1]=k.."=".._s(v,0,{})
    \\    end
    \\  end
    \\end
    \\return table.concat(_r,"\n")
;

fn serializeLuaGlobals(buf: *ByteBuf, alloc: std.mem.Allocator, lua: *zlua.Lua) !void {
    // Load and execute the serializer script
    lua.loadBuffer(lua_serializer, "__pz_ser", .text) catch |err| {
        std.log.err("save: serializer load error: {}", .{err});
        const zero: u32 = 0;
        try bufAppend(buf, alloc, std.mem.asBytes(&zero));
        return;
    };
    lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        // Pop error message
        lua.pop(1);
        std.log.err("save: serializer exec error", .{});
        const zero: u32 = 0;
        try bufAppend(buf, alloc, std.mem.asBytes(&zero));
        return;
    };

    // Get result string
    const script = lua.toString(-1) catch {
        lua.pop(1);
        const zero: u32 = 0;
        try bufAppend(buf, alloc, std.mem.asBytes(&zero));
        return;
    };

    // Write script length and data
    const script_len: u32 = @intCast(script.len);
    try bufAppend(buf, alloc, std.mem.asBytes(&script_len));
    try bufAppend(buf, alloc, script);

    lua.pop(1); // pop result
}

fn deserializeLuaGlobals(cursor: *ReadCursor, lua: *zlua.Lua) void {
    var len_bytes: [4]u8 = undefined;
    cursor.readNoEof(&len_bytes) catch return;
    const script_len: u32 = std.mem.bytesToValue(u32, &len_bytes);

    if (script_len == 0) return;
    if (cursor.pos + script_len > cursor.data.len) {
        std.log.err("load: script extends past end of data", .{});
        return;
    }

    const script = cursor.data[cursor.pos..][0..script_len];
    cursor.pos += script_len;

    // Execute the restore script
    lua.loadBuffer(script, "save_restore", .text) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.err("load: restore script parse error: {s}", .{err_msg});
        lua.pop(1);
        return;
    };
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.err("load: restore script exec error: {s}", .{err_msg});
        lua.pop(1);
        return;
    };
    // Fixup: re-create closure methods on object instances
    // Many PICO-8 games (Celeste etc.) attach closure methods (move, collide, etc.)
    // to objects via init_object. These closures can't be serialized, so we
    // re-create them by calling init_object and copying saved data fields over.
    lua.loadBuffer(lua_fixup, "__pz_fixup", .text) catch {
        lua.pop(1);
        return;
    };
    lua.protectedCall(.{ .args = 0, .results = 0 }) catch {
        const err_msg = lua.toString(-1) catch "?";
        std.log.err("load: fixup script error: {s}", .{err_msg});
        lua.pop(1);
        return;
    };
}

fn getSavePath(alloc: std.mem.Allocator, cart_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, cart_path, ".p8")) {
        const base = cart_path[0 .. cart_path.len - 3];
        return std.fmt.allocPrint(alloc, "{s}.sav", .{base});
    }
    return std.fmt.allocPrint(alloc, "{s}.sav", .{cart_path});
}
