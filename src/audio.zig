const std = @import("std");
const zlua = @import("zlua");
const api = @import("api.zig");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const SAMPLE_RATE = 22050;
const SAMPLES_PER_TICK = 183; // 22050 / 120.49 ≈ 183 samples per note at speed 1
const NUM_CHANNELS = 4;
const MAX_FREQ = 65.41 * 38.055; // noteToFreq(63) ≈ 2489 Hz

const Waveform = enum(u3) {
    triangle = 0,
    tilted_saw = 1,
    saw = 2,
    square = 3,
    pulse = 4,
    organ = 5,
    noise = 6,
    phaser = 7,
};

const Channel = struct {
    sfx_id: i8 = -1,
    note_index: u8 = 0,
    sub_tick: f32 = 0,
    phase: f64 = 0,
    volume: f32 = 0,
    base_volume: f32 = 0,
    frequency: f64 = 0,
    base_frequency: f64 = 0,
    prev_frequency: f64 = 0,
    waveform: Waveform = .triangle,
    effect: u3 = 0,
    custom: bool = false, // using SFX instrument
    note_progress: f32 = 0, // 0..1 progress through current note
    finished: bool = true,
    // Per-channel noise state (filtered random noise)
    noise_sample: f32 = 0,
    noise_prev_sample: f32 = 0,
    // Custom instrument (child SFX) state
    inst_sfx_id: u3 = 0, // instrument SFX 0-7
    inst_note_index: u8 = 0,
    inst_sub_tick: f32 = 0,
    inst_phase: f64 = 0,
    prev_pitch: u6 = 0, // for retrigger detection
    prev_vol: u3 = 0,
};

const MusicState = struct {
    pattern: i16 = -1,
    tick: u32 = 0,
    channel_mask: u8 = 0xF,
    loop_back: i16 = -1, // pattern to loop back to (set by loop start flag)
};

pub const Audio = struct {
    channels: [NUM_CHANNELS]Channel = .{Channel{}} ** NUM_CHANNELS,
    music_state: MusicState = MusicState{},
    memory: *Memory,
    stream: ?*c.SDL_AudioStream = null,
    noise_seed: u32 = 1,

    pub fn init(memory: *Memory) Audio {
        return Audio{
            .memory = memory,
        };
    }

    /// Must be called after the Audio struct is at its final address (not moved)
    pub fn openDevice(self: *Audio) void {
        var spec: c.SDL_AudioSpec = .{
            .format = c.SDL_AUDIO_S16,
            .channels = 1,
            .freq = SAMPLE_RATE,
        };

        self.stream = c.SDL_OpenAudioDeviceStream(
            c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            audioCallback,
            @ptrCast(self),
        );
        if (self.stream) |s| {
            _ = c.SDL_ResumeAudioStreamDevice(s);
        }
    }

    pub fn deinit(self: *Audio) void {
        if (self.stream) |s| {
            c.SDL_DestroyAudioStream(s);
        }
    }

    pub fn playSfx(self: *Audio, sfx_id: i32, channel_req: i32, offset: i32) void {
        self.lockStream();
        defer self.unlockStream();

        if (sfx_id == -1) {
            // SFX(-1): stop sound on channel, or all channels if no channel specified
            if (channel_req >= 0 and channel_req < NUM_CHANNELS) {
                self.stopChannel(@intCast(channel_req));
            } else {
                for (0..NUM_CHANNELS) |i| self.stopChannel(i);
                self.music_state.pattern = -1;
            }
            return;
        }
        if (sfx_id == -2) {
            // SFX(-2): release looping sounds so they finish naturally
            if (channel_req >= 0 and channel_req < NUM_CHANNELS) {
                self.releaseLoop(@intCast(channel_req));
            } else {
                for (0..NUM_CHANNELS) |i| {
                    self.releaseLoop(i);
                }
            }
            return;
        }
        if (sfx_id < 0 or sfx_id >= 64) return;

        // Find channel
        var ch: usize = undefined;
        if (channel_req >= 0 and channel_req < NUM_CHANNELS) {
            ch = @intCast(channel_req);
        } else {
            // Auto-assign: find free or oldest channel
            ch = 0;
            for (0..NUM_CHANNELS) |i| {
                if (self.channels[i].finished) {
                    ch = i;
                    break;
                }
            }
        }

        self.channels[ch] = Channel{
            .sfx_id = @intCast(sfx_id),
            .note_index = if (offset >= 0) @intCast(offset) else 0,
            .sub_tick = 0,
            .phase = 0,
            .finished = false,
        };

        // Read first note
        self.readNote(ch);
    }

    pub fn playMusic(self: *Audio, pattern: i32, _: i32, mask: i32) void {
        self.lockStream();
        defer self.unlockStream();

        if (pattern < 0) {
            self.music_state.pattern = -1;
            return;
        }

        self.music_state = MusicState{
            .pattern = @intCast(pattern),
            .tick = 0,
            .channel_mask = if (mask > 0) @intCast(mask) else 0xF,
        };

        // Start SFX for each channel in the pattern
        self.startMusicPattern();
    }

    fn startMusicPattern(self: *Audio) void {
        if (self.music_state.pattern < 0 or self.music_state.pattern >= 64) return;

        const base: u16 = mem_const.ADDR_MUSIC + @as(u16, @intCast(self.music_state.pattern)) * 4;

        // Check if this is a loop start marker
        if (self.memory.ram[base] & 0x80 != 0) {
            self.music_state.loop_back = self.music_state.pattern;
        }

        for (0..4) |ch_i| {
            if (self.music_state.channel_mask & (@as(u8, 1) << @intCast(ch_i)) == 0) continue;
            const byte = self.memory.ram[base + ch_i];
            if (byte & 0x40 != 0) continue; // channel disabled flag
            self.channels[ch_i] = Channel{
                .sfx_id = @intCast(byte & 0x3F),
                .note_index = 0,
                .sub_tick = 0,
                .phase = 0,
                .finished = false,
            };
            self.readNote(ch_i);
        }
    }

    fn stopChannel(self: *Audio, ch: usize) void {
        self.channels[ch].sfx_id = -1;
        self.channels[ch].finished = true;
    }

    fn releaseLoop(self: *Audio, ch: usize) void {
        if (self.channels[ch].sfx_id < 0) return;
        // Clear loop end so SFX plays through to note 32 and stops
        const sfx_base: u16 = mem_const.ADDR_SFX + @as(u16, @intCast(self.channels[ch].sfx_id)) * 68;
        self.memory.ram[sfx_base + 3] = 0; // loop_end = 0 means no loop
    }

    fn readNote(self: *Audio, ch: usize) void {
        const sfx_id = self.channels[ch].sfx_id;
        if (sfx_id < 0) return;

        const base: u16 = mem_const.ADDR_SFX + @as(u16, @intCast(sfx_id)) * 68;
        const note_addr = base + 4 + @as(u16, self.channels[ch].note_index) * 2;
        const lo = self.memory.ram[note_addr];
        const hi = self.memory.ram[note_addr + 1];
        const val16: u16 = @as(u16, lo) | (@as(u16, hi) << 8);

        // PICO-8 note binary layout (16 bits):
        // bits 0-5: pitch, bits 6-8: waveform, bits 9-11: volume,
        // bits 12-14: effect, bit 15: custom instrument flag
        const pitch: u6 = @truncate(val16 & 0x3F);
        const waveform: u3 = @truncate((val16 >> 6) & 0x7);
        const volume: u3 = @truncate((val16 >> 9) & 0x7);
        const effect: u3 = @truncate((val16 >> 12) & 0x7);
        const custom: bool = (val16 >> 15) & 1 != 0;

        const freq = noteToFreq(pitch);
        const vol = @as(f32, @floatFromInt(volume)) / 7.0;
        self.channels[ch].prev_frequency = self.channels[ch].base_frequency;
        self.channels[ch].base_volume = vol;
        self.channels[ch].volume = vol;
        self.channels[ch].effect = effect;
        self.channels[ch].base_frequency = freq;
        self.channels[ch].frequency = freq;
        self.channels[ch].note_progress = 0;
        self.channels[ch].custom = custom;

        if (custom) {
            self.channels[ch].inst_sfx_id = waveform;
            // Retrigger: reset child when pitch changes, prev volume was 0, or effect 3
            const should_retrigger = (pitch != self.channels[ch].prev_pitch) or
                (self.channels[ch].prev_vol == 0) or
                (effect == 3);
            if (should_retrigger) {
                self.channels[ch].inst_note_index = 0;
                self.channels[ch].inst_sub_tick = 0;
                self.channels[ch].inst_phase = 0;
            }
            self.channels[ch].waveform = .triangle; // placeholder, child note sets actual waveform
        } else {
            self.channels[ch].waveform = @enumFromInt(waveform);
        }

        self.channels[ch].prev_pitch = pitch;
        self.channels[ch].prev_vol = volume;
    }

    fn readNoteRaw(self: *Audio, sfx_id: u8, note_index: u8) struct { pitch: u6, waveform: u3, volume: u3, effect: u3 } {
        const base: u16 = mem_const.ADDR_SFX + @as(u16, sfx_id) * 68;
        const note_addr = base + 4 + @as(u16, note_index) * 2;
        const lo = self.memory.ram[note_addr];
        const hi = self.memory.ram[note_addr + 1];
        const val16: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
        return .{
            .pitch = @truncate(val16 & 0x3F),
            .waveform = @truncate((val16 >> 6) & 0x7),
            .volume = @truncate((val16 >> 9) & 0x7),
            .effect = @truncate((val16 >> 12) & 0x7),
        };
    }

    fn noteToFreq(note: u6) f64 {
        // PICO-8: note 0 = C-0 (about 65.41 Hz), each semitone up
        // Standard: freq = 65.41 * 2^(note/12)
        const n: f64 = @floatFromInt(note);
        return 65.41 * std.math.pow(f64, 2.0, n / 12.0);
    }

    fn generateSampleIndexed(self: *Audio) f32 {
        var mix: f32 = 0;

        for (0..NUM_CHANNELS) |i| {
            var ch = &self.channels[i];
            if (ch.finished or ch.sfx_id < 0) continue;

            const sfx_base: u16 = mem_const.ADDR_SFX + @as(u16, @intCast(ch.sfx_id)) * 68;

            // Apply effects
            var freq = ch.base_frequency;
            var vol = ch.base_volume;
            const t = ch.note_progress; // 0..1

            switch (ch.effect) {
                0 => {}, // none
                1 => { // slide - interpolate from previous note frequency
                    freq = ch.prev_frequency + (ch.base_frequency - ch.prev_frequency) * @as(f64, t);
                },
                2 => { // vibrato - sine oscillation ±0.5 semitones, ~7.5 cycles per note
                    const lfo = @sin(@as(f64, t) * std.math.tau * 7.5);
                    freq = ch.base_frequency * (1.0 + lfo * 0.025);
                },
                3 => { // drop - linear sweep to 0
                    freq = ch.base_frequency * @as(f64, 1.0 - t);
                },
                4 => { // fade in
                    vol = ch.base_volume * t;
                },
                5 => { // fade out
                    vol = ch.base_volume * (1.0 - t);
                },
                6 => { // arp fast - cycle through 4 adjacent SFX notes, 8× per note
                    const note_group: u8 = ch.note_index & 0xFC;
                    const lfo_phase: f32 = @floatCast(@mod(@as(f64, t) * 8.0, 1.0));
                    const lfo_step: u8 = @min(@as(u8, @intFromFloat(lfo_phase * 4.0)), 3);
                    const target: u8 = note_group + lfo_step;
                    if (target < 32) {
                        const addr = sfx_base + 4 + @as(u16, target) * 2;
                        const lo2 = self.memory.ram[addr];
                        const hi2 = self.memory.ram[addr + 1];
                        const pitch2: u6 = @truncate((@as(u32, lo2) | (@as(u32, hi2) << 8)) & 0x3F);
                        freq = noteToFreq(pitch2);
                    }
                },
                7 => { // arp slow - cycle through 4 adjacent SFX notes, 4× per note
                    const note_group: u8 = ch.note_index & 0xFC;
                    const lfo_phase: f32 = @floatCast(@mod(@as(f64, t) * 4.0, 1.0));
                    const lfo_step: u8 = @min(@as(u8, @intFromFloat(lfo_phase * 4.0)), 3);
                    const target: u8 = note_group + lfo_step;
                    if (target < 32) {
                        const addr = sfx_base + 4 + @as(u16, target) * 2;
                        const lo2 = self.memory.ram[addr];
                        const hi2 = self.memory.ram[addr + 1];
                        const pitch2: u6 = @truncate((@as(u32, lo2) | (@as(u32, hi2) << 8)) & 0x3F);
                        freq = noteToFreq(pitch2);
                    }
                },
            }

            ch.frequency = freq;
            ch.volume = vol;

            var sample: f32 = undefined;

            if (ch.custom) {
                // Custom instrument: use child SFX for waveform/pitch/volume
                const inst_base: u16 = mem_const.ADDR_SFX + @as(u16, ch.inst_sfx_id) * 68;
                const child_note = self.readNoteRaw(ch.inst_sfx_id, ch.inst_note_index);
                const child_wf: Waveform = @enumFromInt(child_note.waveform);
                const child_vol = @as(f32, @floatFromInt(child_note.volume)) / 7.0;

                // Pitch: parent is offset relative to C-2 (note 24)
                const freq_shift = freq / noteToFreq(24);
                const child_freq = noteToFreq(child_note.pitch) * freq_shift;

                // Volume: multiply parent × child
                const combined_vol = vol * child_vol;

                // Generate sample from child waveform
                sample = if (child_wf == .noise) blk: {
                    const scale: f32 = @floatCast(child_freq / MAX_FREQ);
                    const prev_s = ch.noise_sample;
                    self.noise_seed ^= self.noise_seed << 13;
                    self.noise_seed ^= self.noise_seed >> 17;
                    self.noise_seed ^= self.noise_seed << 5;
                    const rand: f32 = @as(f32, @floatFromInt(@as(i32, @bitCast(self.noise_seed)))) / 2147483648.0;
                    ch.noise_prev_sample = ch.noise_sample;
                    ch.noise_sample = (ch.noise_prev_sample + scale * rand) / (1.0 + scale);
                    break :blk std.math.clamp(
                        (prev_s + ch.noise_sample) * 4.0 / 3.0 * (1.75 - scale),
                        -1.0,
                        1.0,
                    ) * 0.7;
                } else oscillate(child_wf, ch.inst_phase);

                mix += sample * combined_vol * 0.25;
                ch.inst_phase += child_freq / @as(f64, SAMPLE_RATE);

                // Advance child instrument at its own speed
                const inst_speed = self.memory.ram[inst_base + 1];
                const inst_samples_per_note: f32 = @floatFromInt(@as(u32, @max(@as(u32, inst_speed), 1)) * SAMPLES_PER_TICK);
                ch.inst_sub_tick += 1;
                if (ch.inst_sub_tick >= inst_samples_per_note) {
                    ch.inst_sub_tick = 0;
                    ch.inst_note_index += 1;
                    // Handle instrument SFX looping
                    const inst_loop_end = self.memory.ram[inst_base + 3];
                    const inst_loop_start = self.memory.ram[inst_base + 2];
                    if (ch.inst_note_index >= 32) {
                        if (inst_loop_end > 0 and inst_loop_start < inst_loop_end) {
                            ch.inst_note_index = inst_loop_start;
                        } else {
                            ch.inst_note_index = 31; // hold last note
                        }
                    } else if (inst_loop_end > 0 and ch.inst_note_index >= inst_loop_end) {
                        ch.inst_note_index = inst_loop_start;
                    }
                }
            } else {
                // Normal: use built-in oscillator
                sample = if (ch.waveform == .noise) blk: {
                    const scale: f32 = @floatCast(freq / MAX_FREQ);
                    const prev_s = ch.noise_sample;
                    self.noise_seed ^= self.noise_seed << 13;
                    self.noise_seed ^= self.noise_seed >> 17;
                    self.noise_seed ^= self.noise_seed << 5;
                    const rand: f32 = @as(f32, @floatFromInt(@as(i32, @bitCast(self.noise_seed)))) / 2147483648.0;
                    ch.noise_prev_sample = ch.noise_sample;
                    ch.noise_sample = (ch.noise_prev_sample + scale * rand) / (1.0 + scale);
                    break :blk std.math.clamp(
                        (prev_s + ch.noise_sample) * 4.0 / 3.0 * (1.75 - scale),
                        -1.0,
                        1.0,
                    ) * 0.7;
                } else oscillate(ch.waveform, ch.phase);
                mix += sample * ch.volume * 0.25;
            }

            // Phase accumulates freely (no wrapping at 1.0) for organ/phaser detuning
            ch.phase += ch.frequency / @as(f64, SAMPLE_RATE);

            // Note timing: 183 samples per tick (PICO-8 runs at ~120.49 Hz note rate)
            const speed = self.memory.ram[sfx_base + 1];
            const samples_per_note: f32 = @floatFromInt(@as(u32, @max(@as(u32, speed), 1)) * SAMPLES_PER_TICK);

            ch.sub_tick += 1;
            ch.note_progress = ch.sub_tick / samples_per_note;

            if (ch.sub_tick >= samples_per_note) {
                ch.sub_tick = 0;
                ch.note_index += 1;

                const loop_end = self.memory.ram[sfx_base + 3];
                const loop_start = self.memory.ram[sfx_base + 2];

                if (ch.note_index >= 32) {
                    ch.finished = true;
                    self.advanceMusic();
                } else if (loop_end > 0 and ch.note_index >= loop_end) {
                    if (loop_start < loop_end) {
                        ch.note_index = loop_start;
                    } else {
                        ch.finished = true;
                        self.advanceMusic();
                    }
                }

                if (!ch.finished) {
                    self.readNote(i);
                }
            }
        }

        return std.math.clamp(mix, -1.0, 1.0);
    }

    fn advanceMusic(self: *Audio) void {
        if (self.music_state.pattern < 0) return;

        // Check if ALL music channels are finished
        for (0..4) |ch_i| {
            if (self.music_state.channel_mask & (@as(u8, 1) << @intCast(ch_i)) == 0) continue;
            if (!self.channels[ch_i].finished) return; // still playing
        }

        // Check pattern flags: bit7 of byte1 = loop back, bit7 of byte2 = stop
        const base: u16 = mem_const.ADDR_MUSIC + @as(u16, @intCast(self.music_state.pattern)) * 4;
        const loop_back = self.memory.ram[base + 1] & 0x80 != 0;
        const stop = self.memory.ram[base + 2] & 0x80 != 0;

        if (stop) {
            self.music_state.pattern = -1;
            return;
        }

        if (loop_back and self.music_state.loop_back >= 0) {
            self.music_state.pattern = self.music_state.loop_back;
        } else {
            self.music_state.pattern += 1;
            if (self.music_state.pattern >= 64) {
                self.music_state.pattern = -1;
                return;
            }
        }

        self.startMusicPattern();
    }

    pub fn lockStream(self: *Audio) void {
        if (self.stream) |s| _ = c.SDL_LockAudioStream(s);
    }

    pub fn unlockStream(self: *Audio) void {
        if (self.stream) |s| _ = c.SDL_UnlockAudioStream(s);
    }
};

fn audioCallback(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional_amount: c_int, _: c_int) callconv(.c) void {
    const audio: *Audio = @ptrCast(@alignCast(userdata));
    const num_samples: usize = @intCast(@divExact(additional_amount, 2));
    var buf: [4096]i16 = undefined;
    const count = @min(num_samples, buf.len);
    for (0..count) |s| {
        const sample = audio.generateSampleIndexed();
        buf[s] = @intFromFloat(sample * 28000.0);
    }
    _ = c.SDL_PutAudioStreamData(stream, &buf, @intCast(count * 2));
}

fn oscillate(waveform: Waveform, phase: f64) f32 {
    return switch (waveform) {
        .triangle => blk: {
            const p: f32 = @floatCast(@mod(phase, 1.0));
            break :blk (if (p < 0.5) p * 4.0 - 1.0 else 3.0 - p * 4.0) * 0.7;
        },
        .tilted_saw => blk: {
            const t: f32 = @floatCast(@mod(phase, 1.0));
            break :blk (if (t < 0.875) t * 16.0 / 7.0 - 1.0 else (1.0 - t) * 16.0 - 1.0) * 0.7;
        },
        .saw => blk: {
            const p: f32 = @floatCast(@mod(phase, 1.0));
            break :blk (p - 0.5) * 0.9;
        },
        .square => blk: {
            const p: f32 = @floatCast(@mod(phase, 1.0));
            break :blk if (p < 0.5) @as(f32, 1.0 / 3.0) else @as(f32, -1.0 / 3.0);
        },
        .pulse => blk: {
            const p: f32 = @floatCast(@mod(phase, 1.0));
            break :blk if (p < 0.3125) @as(f32, 1.0 / 3.0) else @as(f32, -1.0 / 3.0);
        },
        .organ => blk: {
            // Two triangle harmonics: 2× and 1× note frequency
            const x = phase * 4.0;
            const t1: f32 = @floatCast(@abs(@mod(x, 2.0) - 1.0));
            const t2: f32 = @floatCast(@abs(@mod(x * 0.5, 2.0) - 1.0));
            break :blk (t1 - 0.5 + (t2 - 0.5) / 2.0 - 0.1) * 0.7;
        },
        .noise => 0, // handled in generateSampleIndexed
        .phaser => blk: {
            // Two slightly detuned triangle waves for phaser effect
            const x = phase * 2.0;
            const t1: f32 = @floatCast(@abs(@mod(x, 2.0) - 1.0));
            const t2: f32 = @floatCast(@abs(@mod(x * 127.0 / 128.0, 2.0) - 1.0));
            break :blk t1 - 0.5 + (t2 - 0.5) / 2.0 - 0.25;
        },
    };
}

pub fn api_sfx(lua: *zlua.Lua) i32 {
    const pico = api.getPico(lua);
    if (pico.audio) |audio| {
        const sfx_id = api.optInt(lua, 1, -1);
        const channel = api.optInt(lua, 2, -1);
        const offset = api.optInt(lua, 3, 0);
        audio.playSfx(sfx_id, channel, offset);
    }
    return 0;
}

pub fn api_music(lua: *zlua.Lua) i32 {
    const pico = api.getPico(lua);
    if (pico.audio) |audio| {
        const pattern = api.optInt(lua, 1, -1);
        const fade = api.optInt(lua, 2, 0);
        const mask = api.optInt(lua, 3, 0);
        audio.playMusic(pattern, fade, mask);
    }
    return 0;
}

