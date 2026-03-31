const std = @import("std");
const testing = std.testing;
const zlua = @import("zlua");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const api = @import("api.zig");
const audio_mod = @import("audio.zig");
const input_mod = @import("input.zig");
const LuaEngine = @import("lua_engine.zig").LuaEngine;
const main_mod = @import("main.zig");
const save_state = @import("save_state.zig");
const c = audio_mod.sdl;

fn makePassthroughStream() !*c.SDL_AudioStream {
    const spec: c.SDL_AudioSpec = .{
        .format = c.SDL_AUDIO_S16,
        .channels = 1,
        .freq = 22050,
    };
    return c.SDL_CreateAudioStream(&spec, &spec) orelse error.SDLAudioStreamCreateFailed;
}

fn makeTestPico(memory: *Memory, input: *input_mod.Input, pixel_buffer: *[api.SCREEN_W * api.SCREEN_H]u32) api.PicoState {
    return .{
        .memory = memory,
        .pixel_buffer = pixel_buffer,
        .input = input,
        .audio = null,
        .allocator = testing.allocator,
    };
}

fn initTestLuaEngine(pico: *api.PicoState, source: []const u8) !LuaEngine {
    var lua_engine = try LuaEngine.init(testing.allocator, pico);
    errdefer lua_engine.deinit();
    lua_engine.processed_source = try testing.allocator.dupe(u8, source);
    try lua_engine.reinit();
    return lua_engine;
}

fn runLua(lua: *zlua.Lua, code: []const u8) !void {
    try lua.loadBuffer(code, "test_chunk", .text);
    try lua.protectedCall(.{ .args = 0, .results = 0 });
}

fn evalLuaNumber(lua: *zlua.Lua, code: []const u8) !f64 {
    try lua.loadBuffer(code, "eval_chunk", .text);
    try lua.protectedCall(.{ .args = 0, .results = 1 });
    defer lua.pop(1);
    return try lua.toNumber(-1);
}

fn writeTextFile(path: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

fn writeGfxCart(path: []const u8, first_byte: u8) !void {
    var line = [_]u8{'0'} ** 128;
    line[0] = hexDigit(first_byte & 0x0f);
    line[1] = hexDigit(first_byte >> 4);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "__gfx__\n");
    try buf.appendSlice(testing.allocator, &line);
    try buf.appendSlice(testing.allocator, "\n");
    try writeTextFile(path, buf.items);
}

fn saveStateScriptLenOffset() usize {
    const input_size = @sizeOf([2]u8) + @sizeOf([2]u8) + @sizeOf([2][8]u16);
    const pico_field_size = @sizeOf(u32) + @sizeOf(f64) + @sizeOf(i32) + @sizeOf(i32) + @sizeOf(u8) + @sizeOf(u32);
    return 4 + 1 + mem_const.RAM_SIZE + mem_const.RAM_SIZE + save_state.audioStateSize() + input_size + pico_field_size;
}

fn overwriteSaveScript(data: []u8, replacement: []const u8) !void {
    const len_offset = saveStateScriptLenOffset();
    var len_bytes: [4]u8 = undefined;
    @memcpy(&len_bytes, data[len_offset..][0..4]);
    const script_len: usize = std.mem.bytesToValue(u32, &len_bytes);
    if (replacement.len > script_len) return error.ReplacementTooLong;

    const script = data[len_offset + 4 .. len_offset + 4 + script_len];
    @memset(script, ' ');
    @memcpy(script[0..replacement.len], replacement);
}

// ── Audio: resetState ──

test "resetState clears channels, music, and noise seed" {
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);

    // Set up some non-default state
    audio.channels[0].sfx_id = 5;
    audio.channels[0].finished = false;
    audio.channels[0].note_index = 10;
    audio.channels[0].loop_released = true;
    audio.channels[1].sfx_id = 3;
    audio.channels[1].finished = false;
    audio.music_state.pattern = 7;
    audio.music_state.playing = true;
    audio.music_state.tick = 100;
    audio.music_state.total_patterns = 5;
    audio.music_state.fade_out = true;
    audio.music_state.fade_samples = 1000;
    audio.music_state.fade_progress = 500;
    audio.noise_seed = 0xDEADBEEF;

    audio.resetState();

    // All channels should be default
    for (0..4) |i| {
        try testing.expectEqual(@as(i8, -1), audio.channels[i].sfx_id);
        try testing.expect(audio.channels[i].finished);
        try testing.expectEqual(@as(u8, 0), audio.channels[i].note_index);
        try testing.expect(!audio.channels[i].loop_released);
    }
    // Music state should be default
    try testing.expectEqual(@as(i16, -1), audio.music_state.pattern);
    try testing.expect(!audio.music_state.playing);
    try testing.expectEqual(@as(u32, 0), audio.music_state.tick);
    try testing.expectEqual(@as(u32, 0), audio.music_state.total_patterns);
    try testing.expect(!audio.music_state.fade_out);
    try testing.expectEqual(@as(u32, 0), audio.music_state.fade_samples);
    try testing.expectEqual(@as(u32, 0), audio.music_state.fade_progress);
    // Noise seed should be reset
    try testing.expectEqual(@as(u32, 1), audio.noise_seed);
}

test "resetState clears queued SDL stream data" {
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);
    const stream = try makePassthroughStream();
    defer c.SDL_DestroyAudioStream(stream);
    audio.stream = stream;

    const queued_samples = [_]i16{ 11, -22, 33, -44 };
    try testing.expect(c.SDL_PutAudioStreamData(stream, &queued_samples, @intCast(@sizeOf(@TypeOf(queued_samples)))));
    try testing.expect(c.SDL_GetAudioStreamQueued(stream) > 0);

    audio.resetState();

    try testing.expectEqual(@as(c_int, 0), c.SDL_GetAudioStreamQueued(stream));
}

// ── Audio: sfx(-2) does not mutate RAM ──

test "sfx(-2) sets loop_released flag without mutating RAM" {
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);

    // Set up SFX 0 with a loop: loop_start=4, loop_end=8
    const sfx_base: u16 = mem_const.ADDR_SFX;
    memory.ram[sfx_base + 1] = 4; // speed
    memory.ram[sfx_base + 2] = 4; // loop_start
    memory.ram[sfx_base + 3] = 8; // loop_end

    // Play SFX 0 on channel 0
    audio.playSfx(0, 0, 0);
    try testing.expect(!audio.channels[0].finished);
    try testing.expect(!audio.channels[0].loop_released);

    // Release loop via sfx(-2)
    audio.playSfx(-2, 0, 0);

    // RAM should be untouched
    try testing.expectEqual(@as(u8, 8), memory.ram[sfx_base + 3]);
    // But channel flag should be set
    try testing.expect(audio.channels[0].loop_released);
}

// ── Audio: music(-1) stops channels ──

test "music(-1) stops music channels" {
    var memory = Memory.init();
    memory.initDrawState();
    var audio = audio_mod.Audio.init(&memory);

    // Set up a minimal music pattern: pattern 0, channel 0 plays SFX 0
    const music_base: u16 = mem_const.ADDR_MUSIC;
    memory.ram[music_base] = 0; // ch0: sfx 0, enabled
    memory.ram[music_base + 1] = 0x40; // ch1: disabled
    memory.ram[music_base + 2] = 0x40; // ch2: disabled
    memory.ram[music_base + 3] = 0x40; // ch3: disabled

    // Set up SFX 0 with some notes
    const sfx_base: u16 = mem_const.ADDR_SFX;
    memory.ram[sfx_base + 1] = 1; // speed=1
    // Note 0: pitch=24, waveform=0, vol=5
    memory.ram[sfx_base + 4] = 24; // pitch in low 6 bits
    memory.ram[sfx_base + 5] = 0x0A; // vol=5 in bits 1-3

    audio.playMusic(0, 0, 0);
    try testing.expect(audio.music_state.playing);
    try testing.expect(!audio.channels[0].finished);

    // Stop music
    audio.playMusic(-1, 0, 0);
    try testing.expect(!audio.music_state.playing);
    try testing.expectEqual(@as(i16, -1), audio.music_state.pattern);
    // Channel should be stopped
    try testing.expect(audio.channels[0].finished);
}

// ── Audio: music tick advances ──

test "music tick advances during sample generation" {
    var memory = Memory.init();
    memory.initDrawState();
    var audio = audio_mod.Audio.init(&memory);

    // Set up pattern 0 with SFX 0 on channel 0
    const music_base: u16 = mem_const.ADDR_MUSIC;
    memory.ram[music_base] = 0;
    memory.ram[music_base + 1] = 0x40;
    memory.ram[music_base + 2] = 0x40;
    memory.ram[music_base + 3] = 0x40;

    // SFX 0: speed=1, 32 notes
    const sfx_base: u16 = mem_const.ADDR_SFX;
    memory.ram[sfx_base + 1] = 1; // speed=1
    // Set note 0 with some pitch/vol
    memory.ram[sfx_base + 4] = 24;
    memory.ram[sfx_base + 5] = 0x0A;

    audio.playMusic(0, 0, 0);
    try testing.expectEqual(@as(u32, 0), audio.music_state.tick);

    // Generate enough samples to advance at least one note
    // At speed=1, one note = 183 samples
    for (0..200) |_| {
        _ = audio.generateSampleIndexed();
    }

    try testing.expect(audio.music_state.tick > 0);
}

// ── Audio callback: fills full request ──

test "audio stream callback supplies exact number of requested samples" {
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);
    const stream = try makePassthroughStream();
    defer c.SDL_DestroyAudioStream(stream);

    try testing.expect(c.SDL_SetAudioStreamGetCallback(stream, audio_mod.audioStreamCallback, &audio));

    const num_samples = 8192; // larger than the 4096 internal callback buffer
    var buf: [num_samples]i16 = undefined;
    const want_bytes: c_int = @intCast(@sizeOf(@TypeOf(buf)));
    const got_bytes = c.SDL_GetAudioStreamData(stream, &buf, want_bytes);

    try testing.expectEqual(want_bytes, got_bytes);
}

// ── Save state: audio round-trip ──

test "audio state serialization round-trip preserves all fields" {
    const alloc = testing.allocator;
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);

    // Set up non-default audio state
    audio.channels[0].sfx_id = 3;
    audio.channels[0].note_index = 7;
    audio.channels[0].sub_tick = 42.5;
    audio.channels[0].phase = 1.234;
    audio.channels[0].volume = 0.8;
    audio.channels[0].base_volume = 0.9;
    audio.channels[0].frequency = 440.0;
    audio.channels[0].base_frequency = 440.0;
    audio.channels[0].prev_frequency = 330.0;
    audio.channels[0].waveform = .saw;
    audio.channels[0].effect = 2;
    audio.channels[0].custom = true;
    audio.channels[0].note_progress = 0.6;
    audio.channels[0].finished = false;
    audio.channels[0].noise_sample = 0.1;
    audio.channels[0].noise_prev_sample = -0.2;
    audio.channels[0].inst_sfx_id = 1;
    audio.channels[0].inst_note_index = 3;
    audio.channels[0].inst_sub_tick = 10.0;
    audio.channels[0].inst_phase = 5.678;
    audio.channels[0].prev_pitch = 24;
    audio.channels[0].prev_vol = 5;
    audio.channels[0].loop_released = true;

    audio.channels[2].sfx_id = 7;
    audio.channels[2].finished = false;
    audio.channels[2].loop_released = true;

    audio.music_state.pattern = 12;
    audio.music_state.tick = 456;
    audio.music_state.channel_mask = 0x5;
    audio.music_state.loop_back = 4;
    audio.music_state.playing = true;
    audio.music_state.total_patterns = 99;
    audio.music_state.fade_samples = 2000;
    audio.music_state.fade_progress = 750;
    audio.music_state.fade_out = true;

    audio.noise_seed = 0x12345678;

    // Serialize
    var buf: save_state.ByteBuf = .empty;
    defer buf.deinit(alloc);
    try save_state.writeAudioState(&buf, alloc, &audio);

    // Verify size matches declared size
    try testing.expectEqual(save_state.audioStateSize(), buf.items.len);

    // Deserialize into a fresh audio
    var audio2 = audio_mod.Audio.init(&memory);
    var cursor = save_state.ReadCursor{ .data = buf.items };
    try save_state.readAudioState(&cursor, &audio2);

    // Verify all fields match
    try testing.expectEqual(audio.channels[0].sfx_id, audio2.channels[0].sfx_id);
    try testing.expectEqual(audio.channels[0].note_index, audio2.channels[0].note_index);
    try testing.expectEqual(audio.channels[0].sub_tick, audio2.channels[0].sub_tick);
    try testing.expectEqual(audio.channels[0].phase, audio2.channels[0].phase);
    try testing.expectEqual(audio.channels[0].volume, audio2.channels[0].volume);
    try testing.expectEqual(audio.channels[0].base_volume, audio2.channels[0].base_volume);
    try testing.expectEqual(audio.channels[0].frequency, audio2.channels[0].frequency);
    try testing.expectEqual(audio.channels[0].base_frequency, audio2.channels[0].base_frequency);
    try testing.expectEqual(audio.channels[0].prev_frequency, audio2.channels[0].prev_frequency);
    try testing.expectEqual(audio.channels[0].waveform, audio2.channels[0].waveform);
    try testing.expectEqual(audio.channels[0].effect, audio2.channels[0].effect);
    try testing.expectEqual(audio.channels[0].custom, audio2.channels[0].custom);
    try testing.expectEqual(audio.channels[0].note_progress, audio2.channels[0].note_progress);
    try testing.expectEqual(audio.channels[0].finished, audio2.channels[0].finished);
    try testing.expectEqual(audio.channels[0].noise_sample, audio2.channels[0].noise_sample);
    try testing.expectEqual(audio.channels[0].noise_prev_sample, audio2.channels[0].noise_prev_sample);
    try testing.expectEqual(audio.channels[0].inst_sfx_id, audio2.channels[0].inst_sfx_id);
    try testing.expectEqual(audio.channels[0].inst_note_index, audio2.channels[0].inst_note_index);
    try testing.expectEqual(audio.channels[0].inst_sub_tick, audio2.channels[0].inst_sub_tick);
    try testing.expectEqual(audio.channels[0].inst_phase, audio2.channels[0].inst_phase);
    try testing.expectEqual(audio.channels[0].prev_pitch, audio2.channels[0].prev_pitch);
    try testing.expectEqual(audio.channels[0].prev_vol, audio2.channels[0].prev_vol);
    try testing.expectEqual(audio.channels[0].loop_released, audio2.channels[0].loop_released);

    // Channel 2
    try testing.expectEqual(audio.channels[2].sfx_id, audio2.channels[2].sfx_id);
    try testing.expectEqual(audio.channels[2].loop_released, audio2.channels[2].loop_released);

    // Music state
    try testing.expectEqual(audio.music_state.pattern, audio2.music_state.pattern);
    try testing.expectEqual(audio.music_state.tick, audio2.music_state.tick);
    try testing.expectEqual(audio.music_state.channel_mask, audio2.music_state.channel_mask);
    try testing.expectEqual(audio.music_state.loop_back, audio2.music_state.loop_back);
    try testing.expectEqual(audio.music_state.playing, audio2.music_state.playing);
    try testing.expectEqual(audio.music_state.total_patterns, audio2.music_state.total_patterns);
    try testing.expectEqual(audio.music_state.fade_samples, audio2.music_state.fade_samples);
    try testing.expectEqual(audio.music_state.fade_progress, audio2.music_state.fade_progress);
    try testing.expectEqual(audio.music_state.fade_out, audio2.music_state.fade_out);

    // Noise seed
    try testing.expectEqual(audio.noise_seed, audio2.noise_seed);

    // Cursor should be exactly at end
    try testing.expectEqual(buf.items.len, cursor.pos);
}

// ── Save state: audioStateSize matches actual serialized size ──

test "audioStateSize matches actual written bytes for default state" {
    const alloc = testing.allocator;
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);

    var buf: save_state.ByteBuf = .empty;
    defer buf.deinit(alloc);
    try save_state.writeAudioState(&buf, alloc, &audio);

    try testing.expectEqual(save_state.audioStateSize(), buf.items.len);
}

test "flushCartdata keeps dirty flag until save succeeds" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    pico.cart_data_id = "test-cartdata";
    pico.cart_data_dirty = true;

    const Stub = struct {
        fn fail(_: std.mem.Allocator, _: *Memory, _: []const u8) !void {
            return error.WriteFailed;
        }

        fn ok(_: std.mem.Allocator, _: *Memory, _: []const u8) !void {}
    };

    api.flushCartdataWith(&pico, Stub.fail);
    try testing.expect(pico.cart_data_dirty);

    api.flushCartdataWith(&pico, Stub.ok);
    try testing.expect(!pico.cart_data_dirty);
}

test "prepareForCartLoad resets cart runtime state" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    pico.rng_state = 0xdeadbeef;
    pico.frame_count = 42;
    pico.elapsed_time = 3.5;
    pico.line_x = 9;
    pico.line_y = 10;
    pico.line_valid = true;

    api.prepareForCartLoad(&pico);

    try testing.expectEqual(@as(u32, 1), pico.rng_state);
    try testing.expectEqual(@as(u32, 0), pico.frame_count);
    try testing.expectEqual(@as(f64, 0), pico.elapsed_time);
    try testing.expectEqual(@as(i32, 0), pico.line_x);
    try testing.expectEqual(@as(i32, 0), pico.line_y);
    try testing.expect(!pico.line_valid);
}

test "save-state load leaves runtime untouched on corrupted Lua globals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "saved_value=7\n");
    defer lua_engine.deinit();

    pico.memory.ram[0x1234] = 0x56;
    pico.input.btn_state[0] = 0x12;
    pico.input.held_frames[0][0] = 5;
    pico.frame_count = 111;
    pico.elapsed_time = 2.22;
    pico.line_x = 3;
    pico.line_y = 4;
    pico.line_valid = true;
    pico.rng_state = 12345;
    try save_state.saveState(&pico, &lua_engine, "cart.p8");

    const save_path = "cart.sav";
    var data = try std.fs.cwd().readFileAlloc(testing.allocator, save_path, 1024 * 1024);
    defer testing.allocator.free(data);
    const save_file = try std.fs.cwd().createFile(save_path, .{ .truncate = true });
    defer save_file.close();
    try save_file.writeAll(data[0 .. data.len - 1]);

    pico.memory.ram[0x1234] = 0xaa;
    pico.input.btn_state[0] = 0x34;
    pico.input.held_frames[0][0] = 9;
    pico.frame_count = 999;
    pico.elapsed_time = 8.88;
    pico.line_x = 9;
    pico.line_y = 10;
    pico.line_valid = false;
    pico.rng_state = 54321;
    try runLua(lua_engine.lua, "saved_value=99");

    try testing.expectError(error.InvalidSaveState, save_state.loadState(&pico, &lua_engine, "cart.p8"));
    try testing.expectEqual(@as(u8, 0xaa), pico.memory.ram[0x1234]);
    try testing.expectEqual(@as(u8, 0x34), pico.input.btn_state[0]);
    try testing.expectEqual(@as(u16, 9), pico.input.held_frames[0][0]);
    try testing.expectEqual(@as(u32, 999), pico.frame_count);
    try testing.expectEqual(@as(f64, 8.88), pico.elapsed_time);
    try testing.expectEqual(@as(i32, 9), pico.line_x);
    try testing.expectEqual(@as(i32, 10), pico.line_y);
    try testing.expect(!pico.line_valid);
    try testing.expectEqual(@as(u32, 54321), pico.rng_state);
    try testing.expectEqual(@as(f64, 99), try evalLuaNumber(lua_engine.lua, "return saved_value"));
}

test "save-state creation fails when Lua globals cannot serialize" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "saved_value=1\n");
    defer lua_engine.deinit();

    try runLua(lua_engine.lua, "table.concat = 1");

    try testing.expectError(error.LuaSerializerExecError, save_state.saveState(&pico, &lua_engine, "cart.p8"));
    try testing.expectError(error.FileNotFound, std.fs.cwd().access("cart.sav", .{}));
}

test "save-state load leaves runtime untouched on Lua restore parse error" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "saved_value=7\n");
    defer lua_engine.deinit();

    pico.memory.ram[0x1234] = 0x56;
    pico.memory.rom[0x234] = 0x78;
    pico.elapsed_time = 2.22;
    try save_state.saveState(&pico, &lua_engine, "cart.p8");

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, "cart.sav", 1024 * 1024);
    defer testing.allocator.free(data);
    try overwriteSaveScript(data, "@");
    const save_file = try std.fs.cwd().createFile("cart.sav", .{ .truncate = true });
    defer save_file.close();
    try save_file.writeAll(data);

    pico.memory.ram[0x1234] = 0xaa;
    pico.memory.rom[0x234] = 0xbb;
    pico.elapsed_time = 8.88;
    try runLua(lua_engine.lua, "saved_value=99");

    try testing.expectError(error.LuaRestoreParseError, save_state.loadState(&pico, &lua_engine, "cart.p8"));
    try testing.expectEqual(@as(u8, 0xaa), pico.memory.ram[0x1234]);
    try testing.expectEqual(@as(u8, 0xbb), pico.memory.rom[0x234]);
    try testing.expectEqual(@as(f64, 8.88), pico.elapsed_time);
    try testing.expectEqual(@as(f64, 99), try evalLuaNumber(lua_engine.lua, "return saved_value"));
}

test "save-state round-trip restores high rom and elapsed time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "saved_value=1\n");
    defer lua_engine.deinit();

    pico.memory.rom[0x5000] = 0x55;
    pico.elapsed_time = 12.5;
    try save_state.saveState(&pico, &lua_engine, "cart.p8");

    pico.memory.rom[0x5000] = 0xaa;
    pico.elapsed_time = 1.25;

    try save_state.loadState(&pico, &lua_engine, "cart.p8");

    try testing.expectEqual(@as(u8, 0x55), pico.memory.rom[0x5000]);
    try testing.expectEqual(@as(f64, 12.5), pico.elapsed_time);
    try testing.expectEqual(@as(f64, 12.5), try evalLuaNumber(lua_engine.lua, "return time()"));
}

test "rng state round-trips through save state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "restored_marker=1\n");
    defer lua_engine.deinit();

    try runLua(lua_engine.lua, "srand(123)");
    _ = try evalLuaNumber(lua_engine.lua, "return rnd()");
    try save_state.saveState(&pico, &lua_engine, "cart.p8");
    const expected_next = try evalLuaNumber(lua_engine.lua, "return rnd()");

    try runLua(lua_engine.lua, "srand(999)");
    pico.rng_state = 999;

    try save_state.loadState(&pico, &lua_engine, "cart.p8");
    const actual_next = try evalLuaNumber(lua_engine.lua, "return rnd()");

    try testing.expectEqual(expected_next, actual_next);
}

test "cartdata retries after transient attach failure" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    try std.fs.cwd().makePath(".pico-z-cartdata");
    try std.fs.cwd().makeDir(".pico-z-cartdata/retry.dat");

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    defer if (pico.cart_data_id) |id| testing.allocator.free(id);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();

    @memset(memory.ram[mem_const.ADDR_CART_DATA .. mem_const.ADDR_CART_DATA + 256], 0xaa);
    try runLua(lua_engine.lua, "cartdata('retry')");
    try testing.expect(pico.cart_data_id == null);
    try testing.expectEqual(@as(u8, 0xaa), memory.ram[mem_const.ADDR_CART_DATA]);

    try std.fs.cwd().deleteDir(".pico-z-cartdata/retry.dat");
    const file = try std.fs.cwd().createFile(".pico-z-cartdata/retry.dat", .{});
    defer file.close();
    var bytes = [_]u8{0} ** 256;
    bytes[0] = 0x44;
    bytes[1] = 0x33;
    bytes[2] = 0x22;
    bytes[3] = 0x11;
    try file.writeAll(&bytes);

    try runLua(lua_engine.lua, "cartdata('retry')");
    try testing.expect(pico.cart_data_id != null);
    try testing.expectEqualStrings("retry", pico.cart_data_id.?);
    try testing.expectEqual(@as(u32, 0x11223344), memory.peek32(mem_const.ADDR_CART_DATA));
}

test "loadCart flushes dirty cartdata before reload and reattaches it in _init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    try writeTextFile(
        "reload_cart.p8",
        \\__lua__
        \\function _init()
        \\  cartdata("reload_id")
        \\end
        \\
    );

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    defer if (pico.cart_data_id) |id| testing.allocator.free(id);
    pico.cart_data_id = try testing.allocator.dupe(u8, "reload_id");
    pico.cart_data_dirty = true;
    pico.memory.poke32(mem_const.ADDR_CART_DATA, 0x11223344);
    pico.line_x = 5;
    pico.line_y = 6;
    pico.line_valid = true;

    var lua_engine = try LuaEngine.init(testing.allocator, &pico);
    defer lua_engine.deinit();

    try main_mod.loadCart(&pico, &lua_engine, testing.allocator, "reload_cart.p8");

    try testing.expect(pico.cart_data_id != null);
    try testing.expectEqualStrings("reload_id", pico.cart_data_id.?);
    try testing.expectEqual(@as(u32, 0x11223344), pico.memory.peek32(mem_const.ADDR_CART_DATA));
    try testing.expect(!pico.cart_data_dirty);
    try testing.expectEqual(@as(i32, 0), pico.line_x);
    try testing.expectEqual(@as(i32, 0), pico.line_y);
    try testing.expect(!pico.line_valid);
}

test "loadCart preserves stat(6) params for cart startup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    try writeTextFile(
        "param_cart.p8",
        \\__lua__
        \\function _init()
        \\  boot_arg = stat(6)
        \\end
        \\
    );

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    @memcpy(pico.param_str[0..4], "argz");
    pico.param_str_len = 4;

    var lua_engine = try LuaEngine.init(testing.allocator, &pico);
    defer lua_engine.deinit();

    try main_mod.loadCart(&pico, &lua_engine, testing.allocator, "param_cart.p8");

    try runLua(lua_engine.lua, "assert(boot_arg == 'argz') assert(stat(6) == 'argz')");
    try testing.expectEqual(@as(u8, 4), pico.param_str_len);
}

test "loadCart resolves relative reloads against the new cart directory during startup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    try std.fs.cwd().makePath("old");
    try std.fs.cwd().makePath("new");
    try writeGfxCart("old/data.p8", 0x43);
    try writeGfxCart("new/data.p8", 0x21);
    try writeTextFile(
        "new/main.p8",
        \\__lua__
        \\reload(0,0,1,"data.p8")
        \\loaded_top = peek(0)
        \\function _init()
        \\  reload(1,0,1,"data.p8")
        \\  loaded_init = peek(1)
        \\end
        \\
    );

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    pico.cart_dir = "old";

    var lua_engine = try LuaEngine.init(testing.allocator, &pico);
    defer lua_engine.deinit();

    try main_mod.loadCart(&pico, &lua_engine, testing.allocator, "new/main.p8");

    try testing.expectEqualStrings("new", pico.cart_dir.?);
    try testing.expectEqual(@as(u8, 0x21), pico.memory.peek(0));
    try testing.expectEqual(@as(u8, 0x21), pico.memory.peek(1));
    try runLua(lua_engine.lua, "assert(loaded_top == 0x21) assert(loaded_init == 0x21)");
}

test "loadCart aborts before replacing memory when cartdata flush fails" {
    const old_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = old_log_level;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    try writeTextFile(
        "blocked_reload.p8",
        \\__lua__
        \\function _init()
        \\end
        \\
    );
    try writeTextFile(".pico-z-cartdata", "not a directory");

    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    defer if (pico.cart_data_id) |id| testing.allocator.free(id);
    pico.cart_data_id = try testing.allocator.dupe(u8, "reload_id");
    pico.cart_data_dirty = true;
    pico.memory.poke32(mem_const.ADDR_CART_DATA, 0x55667788);
    pico.memory.ram[0x1234] = 0xaa;

    var lua_engine = try LuaEngine.init(testing.allocator, &pico);
    defer lua_engine.deinit();

    try testing.expectError(error.CartdataSaveFailed, main_mod.loadCart(&pico, &lua_engine, testing.allocator, "blocked_reload.p8"));
    try testing.expect(pico.cart_data_id != null);
    try testing.expectEqualStrings("reload_id", pico.cart_data_id.?);
    try testing.expect(pico.cart_data_dirty);
    try testing.expectEqual(@as(u8, 0xaa), pico.memory.ram[0x1234]);
    try testing.expectEqual(@as(u32, 0x55667788), pico.memory.peek32(mem_const.ADDR_CART_DATA));
}

test "mouse wheel deltas accumulate within a frame" {
    var input = input_mod.Input{};

    input.addMouseWheelDelta(1);
    input.addMouseWheelDelta(2);
    input.addMouseWheelDelta(-1);

    try testing.expectEqual(@as(i32, 2), input.mouse_wheel);
}

test "runtime errors mentioning cart_run are not treated as control flow" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "_update=function() error('cart_run boom') end\n");
    defer lua_engine.deinit();

    lua_engine.callUpdateWithLogging(false);

    try testing.expect(lua_engine.had_error);
    try testing.expect(pico.pending_load == null);
    try testing.expect(std.mem.indexOf(u8, lua_engine.getErrorMsg(), "cart_run boom") != null);
}

test "load request captures path and param string without runtime error" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "_update=function() load('next.p8', nil, 'argz') end\n");
    defer lua_engine.deinit();

    lua_engine.callUpdate();

    try testing.expect(!lua_engine.had_error);
    try testing.expect(pico.pending_load != null);
    try testing.expectEqual(@as(u8, 7), pico.pending_load_len);
    try testing.expectEqualStrings("next.p8", pico.pending_load.?[0..@as(usize, pico.pending_load_len)]);
    try testing.expectEqualStrings("argz", pico.param_str[0..@as(usize, pico.param_str_len)]);
}

test "run request clears stale param string without runtime error" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    @memcpy(pico.param_str[0..5], "stale");
    pico.param_str_len = 5;
    var lua_engine = try initTestLuaEngine(&pico, "_update=function() run() end\n");
    defer lua_engine.deinit();

    lua_engine.callUpdate();

    try testing.expect(!lua_engine.had_error);
    try testing.expect(pico.pending_load != null);
    try testing.expectEqual(@as(u8, 0), pico.pending_load_len);
    try testing.expectEqual(@as(u8, 0), pico.param_str_len);
}

test "generateSampleIndexed returns clamped output" {
    var memory = Memory.init();
    var audio = audio_mod.Audio.init(&memory);
    const sample = audio.generateSampleIndexed();
    try testing.expectEqual(@as(f32, 0.0), sample);
}

// ══════════════════════════════════════════════════
// Memory
// ══════════════════════════════════════════════════

test "screenGet/screenSet nibble order: even=low, odd=high" {
    var memory = Memory.init();
    memory.screenSet(0, 0, 0xA); // even x → low nibble
    memory.screenSet(1, 0, 0x5); // odd x → high nibble
    try testing.expectEqual(@as(u4, 0xA), memory.screenGet(0, 0));
    try testing.expectEqual(@as(u4, 0x5), memory.screenGet(1, 0));
    // Raw byte should be 0x5A (high=5, low=A)
    try testing.expectEqual(@as(u8, 0x5A), memory.ram[mem_const.ADDR_SCREEN]);
}

test "spriteGet/spriteSet at boundary" {
    var memory = Memory.init();
    memory.spriteSet(127, 127, 0xF);
    try testing.expectEqual(@as(u4, 0xF), memory.spriteGet(127, 127));
    // Out of bounds returns 0
    try testing.expectEqual(@as(u4, 0), memory.spriteGet(128, 0));
}

test "mapGet shared region: rows 32-63 map to 0x1000" {
    var memory = Memory.init();
    memory.ram[mem_const.ADDR_SHARED + 5] = 0x42; // row 32, x=5
    try testing.expectEqual(@as(u8, 0x42), memory.mapGet(5, 32));
}

test "peek16/poke16 little-endian" {
    var memory = Memory.init();
    memory.poke16(0x100, 0xBEEF);
    try testing.expectEqual(@as(u8, 0xEF), memory.ram[0x100]); // low byte first
    try testing.expectEqual(@as(u8, 0xBE), memory.ram[0x101]);
    try testing.expectEqual(@as(u16, 0xBEEF), memory.peek16(0x100));
}

test "peek32/poke32 little-endian" {
    var memory = Memory.init();
    memory.poke32(0x200, 0xDEADBEEF);
    try testing.expectEqual(@as(u8, 0xEF), memory.ram[0x200]);
    try testing.expectEqual(@as(u8, 0xBE), memory.ram[0x201]);
    try testing.expectEqual(@as(u8, 0xAD), memory.ram[0x202]);
    try testing.expectEqual(@as(u8, 0xDE), memory.ram[0x203]);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), memory.peek32(0x200));
}

test "memcpy overlapping forward" {
    var memory = Memory.init();
    memory.ram[10] = 1;
    memory.ram[11] = 2;
    memory.ram[12] = 3;
    memory.memcpy(11, 10, 3); // dst > src, should copy backward
    try testing.expectEqual(@as(u8, 1), memory.ram[11]);
    try testing.expectEqual(@as(u8, 2), memory.ram[12]);
    try testing.expectEqual(@as(u8, 3), memory.ram[13]);
}

test "memcpy overlapping backward" {
    var memory = Memory.init();
    memory.ram[11] = 1;
    memory.ram[12] = 2;
    memory.ram[13] = 3;
    memory.memcpy(10, 11, 3); // dst < src, copy forward
    try testing.expectEqual(@as(u8, 1), memory.ram[10]);
    try testing.expectEqual(@as(u8, 2), memory.ram[11]);
    try testing.expectEqual(@as(u8, 3), memory.ram[12]);
}

test "reload copies ROM to RAM" {
    var memory = Memory.init();
    memory.rom[0x50] = 0xAA;
    memory.rom[0x51] = 0xBB;
    memory.ram[0x50] = 0;
    memory.reload(0x50, 0x50, 2);
    try testing.expectEqual(@as(u8, 0xAA), memory.ram[0x50]);
    try testing.expectEqual(@as(u8, 0xBB), memory.ram[0x51]);
}

test "initDrawState sets default palette and clip" {
    var memory = Memory.init();
    memory.initDrawState();
    // Identity draw palette
    for (0..16) |i| {
        try testing.expectEqual(@as(u8, @intCast(i)) | (if (i == 0) @as(u8, 0x10) else 0), memory.ram[mem_const.ADDR_DRAW_PAL + i]);
    }
    // Full clip rect
    try testing.expectEqual(@as(u8, 0), memory.ram[mem_const.ADDR_CLIP_LEFT]);
    try testing.expectEqual(@as(u8, 128), memory.ram[mem_const.ADDR_CLIP_RIGHT]);
    // Default color = 6
    try testing.expectEqual(@as(u8, 6), memory.ram[mem_const.ADDR_COLOR]);
}

// ══════════════════════════════════════════════════
// Math API (via Lua)
// ══════════════════════════════════════════════════

test "sgn(0) returns 1 (PICO-8 convention)" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 1.0), try evalLuaNumber(lua_engine.lua, "return sgn(0)"));
    try testing.expectEqual(@as(f64, -1.0), try evalLuaNumber(lua_engine.lua, "return sgn(-5)"));
    try testing.expectEqual(@as(f64, 1.0), try evalLuaNumber(lua_engine.lua, "return sgn(3)"));
}

test "sin/cos use turns not radians, sin is inverted" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // sin(0.25) should be -1 (inverted), cos(0) should be 1
    const sin_val = try evalLuaNumber(lua_engine.lua, "return sin(0.25)");
    try testing.expect(sin_val < -0.99 and sin_val > -1.01);
    const cos_val = try evalLuaNumber(lua_engine.lua, "return cos(0)");
    try testing.expect(cos_val > 0.99 and cos_val < 1.01);
}

test "max/min accept variable arguments" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return max(1,5,3)"));
    try testing.expectEqual(@as(f64, 1), try evalLuaNumber(lua_engine.lua, "return min(3,1,5)"));
}

test "mid returns middle value" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return mid(1,5,10)"));
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return mid(10,5,1)"));
}

test "rnd(table) returns a table element" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "srand(42)");
    const val = try evalLuaNumber(lua_engine.lua, "return rnd({10,20,30})");
    try testing.expect(val == 10 or val == 20 or val == 30);
}

test "tostr flags: hex, shift, raw hex" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // tostr(nil) = "[nil]"
    try runLua(lua_engine.lua, "assert(tostr(nil) == '[nil]')");
    // tostr() with no args = ""
    try runLua(lua_engine.lua, "assert(tostr() == '')");
    // tostr with hex flag
    try runLua(lua_engine.lua, "assert(tostr(1, 0x1) == '0x0001.0000')");
}

test "tonum with flags" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // tonum("ff", 0x1) reads hex without prefix
    try testing.expectEqual(@as(f64, 255), try evalLuaNumber(lua_engine.lua, "return tonum('ff', 0x1)"));
    // tonum("bad", 0x4) returns 0 instead of nil
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return tonum('bad', 0x4)"));
}

test "bitwise operations on fixed-point" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 1), try evalLuaNumber(lua_engine.lua, "return band(3, 1)"));
    try testing.expectEqual(@as(f64, 3), try evalLuaNumber(lua_engine.lua, "return bor(1, 2)"));
    try testing.expectEqual(@as(f64, 3), try evalLuaNumber(lua_engine.lua, "return bxor(1, 2)"));
    try testing.expectEqual(@as(f64, 4), try evalLuaNumber(lua_engine.lua, "return shl(1, 2)"));
    try testing.expectEqual(@as(f64, 1), try evalLuaNumber(lua_engine.lua, "return shr(4, 2)"));
}

test "split with default separator and convert" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // split("1,2,3") with default comma separator and convert=true
    try runLua(lua_engine.lua, "local t=split('1,2,3') assert(#t==3) assert(t[1]==1) assert(t[3]==3)");
    // split with convert=false keeps strings
    try runLua(lua_engine.lua, "local t=split('a,b',',',false) assert(t[1]=='a')");
}

test "sub with negative indices" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "assert(sub('hello',1,3)=='hel')");
    try runLua(lua_engine.lua, "assert(sub('hello',-3)=='llo')");
}

test "chr and ord round-trip" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 65), try evalLuaNumber(lua_engine.lua, "return ord('A')"));
    try runLua(lua_engine.lua, "assert(chr(65)=='A')");
    // Multi-arg chr
    try runLua(lua_engine.lua, "assert(chr(65,66)=='AB')");
}

// ══════════════════════════════════════════════════
// Table API
// ══════════════════════════════════════════════════

test "add/del/deli/count" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\t={}
        \\add(t, 10) add(t, 20) add(t, 30)
        \\assert(count(t)==3)
        \\assert(del(t, 20)==20)
        \\assert(count(t)==2)
        \\assert(t[1]==10 and t[2]==30)
        \\assert(deli(t, 1)==10)
        \\assert(t[1]==30)
    );
}

test "all iterator handles deletion" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\t={1,2,3,4,5}
        \\local sum=0
        \\for v in all(t) do sum=sum+v end
        \\assert(sum==15)
    );
}

test "foreach iterates array" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\sum=0
        \\foreach({10,20,30}, function(v) sum=sum+v end)
        \\assert(sum==60)
    );
}

test "pack and unpack" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\local t = pack(1,2,3)
        \\assert(t.n==3)
        \\local a,b,c = unpack(t)
        \\assert(a==1 and b==2 and c==3)
    );
}

// ══════════════════════════════════════════════════
// Coroutines
// ══════════════════════════════════════════════════

test "cocreate/coresume/yield" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\co = cocreate(function() yield(1) yield(2) yield(3) end)
        \\local ok,v = coresume(co)
        \\assert(ok and v==1)
        \\assert(costatus(co)=="suspended")
        \\ok,v = coresume(co)
        \\assert(ok and v==2)
        \\ok,v = coresume(co)
        \\assert(ok and v==3)
        \\ok = coresume(co)
        \\assert(costatus(co)=="dead")
    );
}

// ══════════════════════════════════════════════════
// Graphics (via Lua)
// ══════════════════════════════════════════════════

test "cls resets clip rect and clears screen" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // Set a clip rect, then cls should reset it
    try runLua(lua_engine.lua, "clip(10,10,50,50) cls(7)");
    try testing.expectEqual(@as(u8, 0), memory.ram[mem_const.ADDR_CLIP_LEFT]);
    try testing.expectEqual(@as(u8, 128), memory.ram[mem_const.ADDR_CLIP_RIGHT]);
    // Screen should be filled with color 7
    try testing.expectEqual(@as(u4, 7), memory.screenGet(0, 0));
    try testing.expectEqual(@as(u4, 7), memory.screenGet(64, 64));
}

test "pset/pget with camera offset" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "cls() camera(-10,-10) pset(10,10,5)");
    // With camera(-10,-10), pset(10,10) draws at screen pixel (20,20)
    try testing.expectEqual(@as(u4, 5), memory.screenGet(20, 20));
    // pget reads raw screen pixels (no camera offset)
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return pget(20,20)"));
}

test "print returns right-x position" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // "hi" is 2 chars * 4px wide = 8px, starting at x=0
    const right_x = try evalLuaNumber(lua_engine.lua, "return print('hi', 0, 0, 7)");
    try testing.expectEqual(@as(f64, 8), right_x);
}

test "camera returns previous values" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "camera(10, 20)");
    try runLua(lua_engine.lua, "px, py = camera(30, 40)");
    try testing.expectEqual(@as(f64, 10), try evalLuaNumber(lua_engine.lua, "return px"));
    try testing.expectEqual(@as(f64, 20), try evalLuaNumber(lua_engine.lua, "return py"));
}

test "color returns previous value" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // Default color is 6
    try testing.expectEqual(@as(f64, 6), try evalLuaNumber(lua_engine.lua, "return color(9)"));
    try testing.expectEqual(@as(f64, 9), try evalLuaNumber(lua_engine.lua, "return color(1)"));
}

test "pal reset also clears fillp" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // Use decimal value instead of binary literal (Lua 5.2 doesn't support 0b)
    try runLua(lua_engine.lua, "fillp(21845) pal()"); // 21845 = 0x5555
    try testing.expectEqual(@as(u16, 0), memory.peek16(mem_const.ADDR_FILL_PAT));
}

test "palt bitfield sets all 16 colors" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // Set colors 0 and 2 transparent (bit 0 and bit 2 = 5)
    try runLua(lua_engine.lua, "palt(5)");
    try testing.expect(memory.ram[mem_const.ADDR_DRAW_PAL + 0] & 0x10 != 0);
    try testing.expect(memory.ram[mem_const.ADDR_DRAW_PAL + 1] & 0x10 == 0);
    try testing.expect(memory.ram[mem_const.ADDR_DRAW_PAL + 2] & 0x10 != 0);
}

test "fget/fset flag operations" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "fset(0, 5)"); // flags 0 and 2 (5 = 0b101)
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return fget(0)"));
    try runLua(lua_engine.lua, "assert(fget(0, 0)==true)");
    try runLua(lua_engine.lua, "assert(fget(0, 1)==false)");
    try runLua(lua_engine.lua, "assert(fget(0, 2)==true)");
}

// ══════════════════════════════════════════════════
// Input
// ══════════════════════════════════════════════════

test "btnp respects custom repeat config from memory" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    // Set custom: initial=5, repeat=2
    memory.ram[0x5F5C] = 5;
    memory.ram[0x5F5D] = 2;
    // Simulate holding button 0 for 7 frames
    input.held_frames[0][0] = 7;
    // Should trigger: 7 >= 5, (7-5) % 2 == 0
    try testing.expect(input.btnp(0, 0, &memory));
    // Frame 6: (6-5) % 2 == 1, should not trigger
    input.held_frames[0][0] = 6;
    try testing.expect(!input.btnp(0, 0, &memory));
    // initial=255 means never repeat
    memory.ram[0x5F5C] = 255;
    input.held_frames[0][0] = 1000;
    try testing.expect(!input.btnp(0, 0, &memory));
}

test "btn no-args returns both players bitfield" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    pico.input.btn_state[0] = 0x05; // buttons 0 and 2
    pico.input.btn_state[1] = 0x03; // buttons 0 and 1
    // P0 bits 0-5, P1 bits 8-13
    const expected: f64 = 0x05 + 0x03 * 256;
    try testing.expectEqual(expected, try evalLuaNumber(lua_engine.lua, "return btn()"));
}

// ══════════════════════════════════════════════════
// Preprocessor
// ══════════════════════════════════════════════════

const preprocessor = @import("preprocessor.zig");

test "preprocessor: compound assignment" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a += 1\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "a = a + (1)") != null);
}

test "preprocessor: ^= is power assign, not bxor" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a ^= 2\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "a = a ^ (2)") != null);
}

test "preprocessor: ^^= is bxor assign" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a ^^= 2\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "a = bxor(a, 2)") != null);
}

test "preprocessor: != becomes ~=" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "if a != b then end\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "~=") != null);
    try testing.expect(std.mem.indexOf(u8, result, "!=") == null);
}

test "preprocessor: ? print shorthand" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "?\"hello\"\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "print(") != null);
}

test "preprocessor: short-if" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "if (x>0) y=1\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "then") != null);
    try testing.expect(std.mem.indexOf(u8, result, "end") != null);
}

test "preprocessor: integer division" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a = b\\c\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "flr(") != null);
}

test "preprocessor: bitwise operators" {
    const alloc = testing.allocator;
    {
        const result = try preprocessor.preprocess(alloc, "a = b >> c\n");
        defer alloc.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "shr(") != null);
    }
    {
        const result = try preprocessor.preprocess(alloc, "a = b << c\n");
        defer alloc.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "shl(") != null);
    }
    {
        const result = try preprocessor.preprocess(alloc, "a = b >>> c\n");
        defer alloc.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "lshr(") != null);
    }
}

test "preprocessor: peek shortcuts" {
    const alloc = testing.allocator;
    {
        const result = try preprocessor.preprocess(alloc, "a = @0x5000\n");
        defer alloc.free(result);
        try testing.expect(std.mem.indexOf(u8, result, "peek(") != null);
    }
}

test "preprocessor: peek2 with lshr" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a = (%src>>>16-b)\n");
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "peek2(") != null);
    try testing.expect(std.mem.indexOf(u8, result, "lshr(") != null);
}

test "preprocessor: binary literals" {
    const alloc = testing.allocator;
    const result = try preprocessor.preprocess(alloc, "a = 0b1010\n");
    defer alloc.free(result);
    // Binary literal should be converted to decimal
    try testing.expect(std.mem.indexOf(u8, result, "10") != null);
}

// ══════════════════════════════════════════════════
// Sandbox
// ══════════════════════════════════════════════════

test "stdlib sandboxing: blocked globals are nil" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "assert(io==nil)");
    try runLua(lua_engine.lua, "assert(os==nil)");
    try runLua(lua_engine.lua, "assert(debug==nil)");
    try runLua(lua_engine.lua, "assert(require==nil)");
    try runLua(lua_engine.lua, "assert(math==nil)");
    try runLua(lua_engine.lua, "assert(coroutine==nil)");
}

test "stdlib sandboxing: allowed globals still work" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "assert(type(string.find)=='function')");
    try runLua(lua_engine.lua, "assert(type(table.sort)=='function')");
    try runLua(lua_engine.lua, "assert(type(pcall)=='function')");
    try runLua(lua_engine.lua, "assert(type(setmetatable)=='function')");
    try runLua(lua_engine.lua, "assert(type(pairs)=='function')");
    try runLua(lua_engine.lua, "assert(type(ipairs)=='function')");
}

test "string indexing: str[i] returns character" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // String indexing is set up via registerAll; use local var to avoid Lua parse issues
    try runLua(lua_engine.lua, "local s='hello' assert(s[1]=='h') assert(s[5]=='o')");
}

test "pairs(nil) returns empty iterator" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "local n=0 for k,v in pairs(nil) do n=n+1 end assert(n==0)");
}

test "type() with no args returns nothing" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // type() with no args should return nothing (0 results), not error
    try runLua(lua_engine.lua, "assert(type() == nil)");
}

// ══════════════════════════════════════════════════
// Stat
// ══════════════════════════════════════════════════

test "stat(7) returns target fps" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    pico.target_fps = 60;
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 60), try evalLuaNumber(lua_engine.lua, "return stat(7)"));
}

test "stat(80-85) returns UTC time components" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    const year = try evalLuaNumber(lua_engine.lua, "return stat(80)");
    try testing.expect(year >= 2020 and year <= 2100);
    const month = try evalLuaNumber(lua_engine.lua, "return stat(81)");
    try testing.expect(month >= 1 and month <= 12);
    const day = try evalLuaNumber(lua_engine.lua, "return stat(82)");
    try testing.expect(day >= 1 and day <= 31);
}

// ══════════════════════════════════════════════════
// Peek/Poke
// ══════════════════════════════════════════════════

test "peek4/poke4 16:16 fixed-point round-trip" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "poke4(0x4300, 1.5)");
    try testing.expectEqual(@as(f64, 1.5), try evalLuaNumber(lua_engine.lua, "return peek4(0x4300)"));
    // Negative value
    try runLua(lua_engine.lua, "poke4(0x4304, -2.25)");
    try testing.expectEqual(@as(f64, -2.25), try evalLuaNumber(lua_engine.lua, "return peek4(0x4304)"));
}

test "peek multi-value returns" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "poke(0x4300, 11) poke(0x4301, 22) poke(0x4302, 33)");
    try runLua(lua_engine.lua, "a,b,c = peek(0x4300, 3) assert(a==11 and b==22 and c==33)");
}

// ══════════════════════════════════════════════════
// Audio: music fade
// ══════════════════════════════════════════════════

test "music fade-out gradually reduces volume then stops" {
    var memory = Memory.init();
    memory.initDrawState();
    var audio = audio_mod.Audio.init(&memory);

    // Set up pattern 0 with SFX 0
    memory.ram[mem_const.ADDR_MUSIC] = 0;
    memory.ram[mem_const.ADDR_MUSIC + 1] = 0x40;
    memory.ram[mem_const.ADDR_MUSIC + 2] = 0x40;
    memory.ram[mem_const.ADDR_MUSIC + 3] = 0x40;
    memory.ram[mem_const.ADDR_SFX + 1] = 1;
    memory.ram[mem_const.ADDR_SFX + 4] = 24;
    memory.ram[mem_const.ADDR_SFX + 5] = 0x0A;

    audio.playMusic(0, 0, 0);
    try testing.expect(audio.music_state.playing);

    // Start fade: 100ms at 22050 Hz = ~2205 samples
    audio.playMusic(-1, 100, 0);
    try testing.expect(audio.music_state.fade_out);
    try testing.expect(audio.music_state.playing);

    // Generate enough samples to complete the fade
    for (0..3000) |_| {
        _ = audio.generateSampleIndexed();
    }

    // After fade completes, music should be stopped
    try testing.expect(!audio.music_state.playing);
    try testing.expect(!audio.music_state.fade_out);
    try testing.expect(audio.channels[0].finished);
}

// ══════════════════════════════════════════════════
// Cartdata store sanitization
// ══════════════════════════════════════════════════

const cartdata_store = @import("cartdata_store.zig");

test "cartdata sanitization is injective" {
    const alloc = testing.allocator;
    // "/" and "_2f" must produce different filenames
    const path1 = try cartdata_store.pathForId(alloc, "/");
    defer alloc.free(path1);
    const path2 = try cartdata_store.pathForId(alloc, "_2f");
    defer alloc.free(path2);
    try testing.expect(!std.mem.eql(u8, path1, path2));
}

test "cartdata empty id produces default filename" {
    const alloc = testing.allocator;
    const path = try cartdata_store.pathForId(alloc, "");
    defer alloc.free(path);
    try testing.expect(std.mem.indexOf(u8, path, "default") != null);
}

// ══════════════════════════════════════════════════
// Coverage: cstore, dget/dset, peek2/poke2, atan2, math
// ══════════════════════════════════════════════════

test "peek2/poke2 round-trip via Lua" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "poke2(0x4300, 0x1234)");
    try testing.expectEqual(@as(f64, 0x1234), try evalLuaNumber(lua_engine.lua, "return peek2(0x4300)"));
    // Verify little-endian byte order
    try testing.expectEqual(@as(f64, 0x34), try evalLuaNumber(lua_engine.lua, "return peek(0x4300)"));
    try testing.expectEqual(@as(f64, 0x12), try evalLuaNumber(lua_engine.lua, "return peek(0x4301)"));
}

test "cstore copies RAM to ROM and reload restores it" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // Write to RAM, cstore to ROM, change RAM, reload from ROM
    try runLua(lua_engine.lua,
        \\poke(0x4300, 0xAA)
        \\poke(0x4301, 0xBB)
        \\cstore(0x4300, 0x4300, 2)
        \\poke(0x4300, 0)
        \\poke(0x4301, 0)
        \\reload(0x4300, 0x4300, 2)
    );
    try testing.expectEqual(@as(f64, 0xAA), try evalLuaNumber(lua_engine.lua, "return peek(0x4300)"));
    try testing.expectEqual(@as(f64, 0xBB), try evalLuaNumber(lua_engine.lua, "return peek(0x4301)"));
}

test "dget/dset round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch unreachable;

    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    defer if (pico.cart_data_id) |id| testing.allocator.free(id);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();

    try runLua(lua_engine.lua, "cartdata('dget_test')");
    try runLua(lua_engine.lua, "dset(0, 42.5) dset(63, -7.25)");
    try testing.expectEqual(@as(f64, 42.5), try evalLuaNumber(lua_engine.lua, "return dget(0)"));
    try testing.expectEqual(@as(f64, -7.25), try evalLuaNumber(lua_engine.lua, "return dget(63)"));
    // Out of range returns 0
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return dget(64)"));
}

test "atan2 returns turns in 0-1 range" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // atan2 returns a value in 0-1 (turns)
    const a = try evalLuaNumber(lua_engine.lua, "return atan2(1, 0)");
    try testing.expect(a >= 0 and a <= 1);
    const b = try evalLuaNumber(lua_engine.lua, "return atan2(0, -1)");
    try testing.expect(b >= 0 and b <= 1);
    const d = try evalLuaNumber(lua_engine.lua, "return atan2(-1, -1)");
    try testing.expect(d >= 0 and d <= 1);
    // Different inputs produce different angles
    try testing.expect(a != b);
}

test "abs, ceil, sqrt" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, 5), try evalLuaNumber(lua_engine.lua, "return abs(-5)"));
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return abs(0)"));
    try testing.expectEqual(@as(f64, 3), try evalLuaNumber(lua_engine.lua, "return ceil(2.1)"));
    try testing.expectEqual(@as(f64, 2), try evalLuaNumber(lua_engine.lua, "return ceil(2)"));
    try testing.expectEqual(@as(f64, -2), try evalLuaNumber(lua_engine.lua, "return ceil(-2.9)"));
    try testing.expectEqual(@as(f64, 4), try evalLuaNumber(lua_engine.lua, "return sqrt(16)"));
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return sqrt(0)"));
}

test "bnot, rotl, rotr" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    // bnot(0) = -1 (all bits set in 16:16 = 0xFFFF.FFFF = -0x0.0001)
    const bnot_val = try evalLuaNumber(lua_engine.lua, "return bnot(0)");
    try testing.expect(bnot_val < 0);
    // rotl and rotr are inverses
    try runLua(lua_engine.lua, "assert(rotr(rotl(5, 3), 3) == 5)");
}

test "rectfill draws filled rectangle" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "cls(0) rectfill(10,10,20,20,7)");
    // Center pixel should be filled
    try testing.expectEqual(@as(u4, 7), memory.screenGet(15, 15));
    // Outside should be 0
    try testing.expectEqual(@as(u4, 0), memory.screenGet(9, 15));
    try testing.expectEqual(@as(u4, 0), memory.screenGet(21, 15));
}

test "circfill draws filled circle" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "cls(0) circfill(64,64,10,7)");
    // Center should be filled
    try testing.expectEqual(@as(u4, 7), memory.screenGet(64, 64));
    // Just inside radius
    try testing.expectEqual(@as(u4, 7), memory.screenGet(70, 64));
    // Well outside radius
    try testing.expectEqual(@as(u4, 0), memory.screenGet(80, 64));
}

test "sget reads sprite sheet pixels" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "sset(5, 5, 9)");
    try testing.expectEqual(@as(f64, 9), try evalLuaNumber(lua_engine.lua, "return sget(5, 5)"));
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return sget(0, 0)"));
}

test "mget/mset map tile access" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua, "mset(10, 5, 42)");
    try testing.expectEqual(@as(f64, 42), try evalLuaNumber(lua_engine.lua, "return mget(10, 5)"));
    try testing.expectEqual(@as(f64, 0), try evalLuaNumber(lua_engine.lua, "return mget(0, 0)"));
}

test "memcpy and memset via Lua" {
    var memory = Memory.init();
    memory.initDrawState();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try runLua(lua_engine.lua,
        \\memset(0x4300, 0xAA, 4)
        \\memcpy(0x4304, 0x4300, 4)
    );
    try testing.expectEqual(@as(f64, 0xAA), try evalLuaNumber(lua_engine.lua, "return peek(0x4304)"));
    try testing.expectEqual(@as(f64, 0xAA), try evalLuaNumber(lua_engine.lua, "return peek(0x4307)"));
}

test "flr on negative numbers" {
    var memory = Memory.init();
    var input = input_mod.Input{};
    var pixel_buffer = [_]u32{0} ** (api.SCREEN_W * api.SCREEN_H);
    var pico = makeTestPico(&memory, &input, &pixel_buffer);
    var lua_engine = try initTestLuaEngine(&pico, "");
    defer lua_engine.deinit();
    try testing.expectEqual(@as(f64, -3), try evalLuaNumber(lua_engine.lua, "return flr(-2.5)"));
    try testing.expectEqual(@as(f64, 2), try evalLuaNumber(lua_engine.lua, "return flr(2.9)"));
}
