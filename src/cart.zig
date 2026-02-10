const std = @import("std");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");

pub const Cart = struct {
    lua_code: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Cart) void {
        self.allocator.free(self.lua_code);
    }
};

pub fn loadP8File(allocator: std.mem.Allocator, path: []const u8, memory: *Memory) !Cart {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseP8(allocator, content, memory);
}

fn parseP8(allocator: std.mem.Allocator, content: []const u8, memory: *Memory) !Cart {
    var lua_lines: std.ArrayList(u8) = .empty;
    errdefer lua_lines.deinit(allocator);

    const Section = enum { none, lua, gfx, gff, map, sfx, music, label };
    var section: Section = .none;
    var section_line: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        // Check for section headers
        if (std.mem.startsWith(u8, line, "__lua__")) {
            section = .lua;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__gfx__")) {
            section = .gfx;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__gff__")) {
            section = .gff;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__map__")) {
            section = .map;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__sfx__")) {
            section = .sfx;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__music__")) {
            section = .music;
            section_line = 0;
            continue;
        } else if (std.mem.startsWith(u8, line, "__label__")) {
            section = .label;
            section_line = 0;
            continue;
        }

        switch (section) {
            .lua => {
                try lua_lines.appendSlice(allocator, line);
                try lua_lines.append(allocator, '\n');
            },
            .gfx => {
                if (section_line < 128) {
                    parseGfxLine(memory, line, section_line);
                }
                section_line += 1;
            },
            .gff => {
                if (section_line < 2) {
                    parseGffLine(memory, line, section_line);
                }
                section_line += 1;
            },
            .map => {
                if (section_line < 32) {
                    parseMapLine(memory, line, section_line);
                }
                section_line += 1;
            },
            .sfx => {
                if (section_line < 64) {
                    parseSfxLine(memory, line, section_line);
                }
                section_line += 1;
            },
            .music => {
                if (section_line < 64) {
                    parseMusicLine(memory, line, section_line);
                }
                section_line += 1;
            },
            .none, .label => {},
        }
    }

    return Cart{
        .lua_code = try lua_lines.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn hexVal(ch: u8) u4 {
    return switch (ch) {
        '0'...'9' => @intCast(ch - '0'),
        'a'...'f' => @intCast(ch - 'a' + 10),
        'A'...'F' => @intCast(ch - 'A' + 10),
        else => 0,
    };
}

fn parseGfxLine(memory: *Memory, line: []const u8, row: usize) void {
    // Each line has 128 hex chars, each pair represents two pixels (nibble-swapped)
    // File format: char at position x is the color for pixel x
    // But storage is 2 pixels per byte with low nibble = even pixel
    const y: u8 = @intCast(row);
    var x: u8 = 0;
    while (x < 128 and x < line.len) : (x += 1) {
        const color = hexVal(line[x]);
        memory.spriteSet(x, y, color);
    }
}

fn parseGffLine(memory: *Memory, line: []const u8, row: usize) void {
    // Each line: 256 hex chars = 128 bytes of sprite flags
    const base: u16 = mem_const.ADDR_FLAGS + @as(u16, @intCast(row)) * 128;
    var i: usize = 0;
    while (i + 1 < line.len and i / 2 < 128) : (i += 2) {
        const hi = hexVal(line[i]);
        const lo = hexVal(line[i + 1]);
        memory.ram[base + i / 2] = (@as(u8, hi) << 4) | lo;
    }
}

fn parseMapLine(memory: *Memory, line: []const u8, row: usize) void {
    // Each line: 256 hex chars = 128 bytes of map data
    const base: u16 = mem_const.ADDR_MAP + @as(u16, @intCast(row)) * 128;
    var i: usize = 0;
    while (i + 1 < line.len and i / 2 < 128) : (i += 2) {
        const hi = hexVal(line[i]);
        const lo = hexVal(line[i + 1]);
        memory.ram[base + i / 2] = (@as(u8, hi) << 4) | lo;
    }
}

fn parseSfxLine(memory: *Memory, line: []const u8, row: usize) void {
    // SFX format: each line is 168 hex chars
    // First 8 hex chars: editor mode, speed, loop start, loop end
    // Then 32 notes x 5 hex chars each = 160 hex chars
    // Each note: 5 hex digits packed into 2 bytes (32 bits total for note data)
    //   Hex digits: C2 C1 C0 W V E  where pitch=C, waveform=W, volume=V, effect=E
    //   But actually the 5 hex chars encode: pitch(6bit) waveform(3bit) volume(3bit) effect(3bit) custom(1bit)
    if (line.len < 8) return;

    const base: u16 = mem_const.ADDR_SFX + @as(u16, @intCast(row)) * 68;

    // First byte: editor mode (we skip this)
    const speed = (@as(u8, hexVal(line[2])) << 4) | hexVal(line[3]);
    const loop_start = (@as(u8, hexVal(line[4])) << 4) | hexVal(line[5]);
    const loop_end = (@as(u8, hexVal(line[6])) << 4) | hexVal(line[7]);

    // SFX header: bytes 0-1 = editor/speed, 2 = loop_start, 3 = loop_end
    memory.ram[base] = (@as(u8, hexVal(line[0])) << 4) | hexVal(line[1]);
    memory.ram[base + 1] = speed;
    memory.ram[base + 2] = loop_start;
    memory.ram[base + 3] = loop_end;

    // 32 notes, each 5 hex chars -> 2 bytes in memory
    // .p8 text format: d0 d1 d2 d3 d4 where:
    //   d0,d1 = pitch (0-63), d2 = waveform(bits0-2) + custom(bit3)
    //   d3 = volume (0-7), d4 = effect (0-7)
    // Memory format (16-bit LE):
    //   byte0: pitch[5:0] waveform[1:0]
    //   byte1: waveform[2] volume[2:0] effect[2:0] custom
    var note_i: usize = 0;
    while (note_i < 32) : (note_i += 1) {
        const offset = 8 + note_i * 5;
        if (offset + 5 > line.len) break;

        const d0: u8 = hexVal(line[offset + 0]);
        const d1: u8 = hexVal(line[offset + 1]);
        const d2: u8 = hexVal(line[offset + 2]);
        const d3: u8 = hexVal(line[offset + 3]);
        const d4: u8 = hexVal(line[offset + 4]);

        const pitch: u6 = @truncate((@as(u8, d0) << 4) | d1);
        const waveform: u3 = @truncate(d2 & 0x7);
        const custom: u1 = @truncate((d2 >> 3) & 0x1);
        const volume: u3 = @truncate(d3 & 0x7);
        const effect: u3 = @truncate(d4 & 0x7);

        const byte0: u8 = @as(u8, pitch) | (@as(u8, waveform & 0x3) << 6);
        const byte1: u8 = @as(u8, (waveform >> 2) & 0x1) | (@as(u8, volume) << 1) | (@as(u8, effect) << 4) | (@as(u8, custom) << 7);

        const note_addr = base + 4 + @as(u16, @intCast(note_i)) * 2;
        memory.ram[note_addr] = byte0;
        memory.ram[note_addr + 1] = byte1;
    }
}

// --- .p8.png support ---

pub fn loadP8PngFile(allocator: std.mem.Allocator, path: []const u8, memory: *Memory) !Cart {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(content);

    return parseP8Png(allocator, content, memory);
}

fn parseP8Png(allocator: std.mem.Allocator, data: []const u8, memory: *Memory) !Cart {
    // Decode PNG to raw RGBA pixels
    const pixels = try decodePng(allocator, data);
    defer allocator.free(pixels);

    // Extract PICO-8 bytes from RGBA via steganography
    // pico_byte = (A & 3) << 6 | (R & 3) << 4 | (G & 3) << 2 | (B & 3)
    const total_pixels = 160 * 205;
    var cart_data: [total_pixels]u8 = undefined;
    for (0..total_pixels) |i| {
        const r = pixels[i * 4 + 0];
        const g = pixels[i * 4 + 1];
        const b = pixels[i * 4 + 2];
        const a = pixels[i * 4 + 3];
        cart_data[i] = (a & 3) << 6 | (r & 3) << 4 | (g & 3) << 2 | (b & 3);
    }

    // Bytes 0x0000-0x42FF go directly into RAM (sprites, map, flags, music, sfx)
    const data_end = 0x4300;
    @memcpy(memory.ram[0..data_end], cart_data[0..data_end]);

    // Rearrange SFX data: PICO-8 native format has notes first (64 bytes) then
    // header (4 bytes), but our audio engine expects header first then notes.
    for (0..64) |sfx_i| {
        const base = mem_const.ADDR_SFX + @as(u16, @intCast(sfx_i)) * 68;
        // Save the 4-byte header from the end (native positions 64-67)
        const hdr: [4]u8 = .{
            memory.ram[base + 64],
            memory.ram[base + 65],
            memory.ram[base + 66],
            memory.ram[base + 67],
        };
        // Shift 64 bytes of note data forward by 4
        std.mem.copyBackwards(u8, memory.ram[base + 4 .. base + 68], memory.ram[base .. base + 64]);
        // Place header at the front
        memory.ram[base + 0] = hdr[0];
        memory.ram[base + 1] = hdr[1];
        memory.ram[base + 2] = hdr[2];
        memory.ram[base + 3] = hdr[3];
    }

    // Bytes 0x4300-0x7FFF contain Lua code (possibly compressed)
    const lua_region = cart_data[0x4300..0x8000];
    const lua_code = try decompressLua(allocator, lua_region);

    return Cart{
        .lua_code = lua_code,
        .allocator = allocator,
    };
}

fn decodePng(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Validate PNG signature
    const png_sig = "\x89PNG\r\n\x1a\n";
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], png_sig))
        return error.InvalidPng;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat_chunks: std.ArrayList([]const u8) = .empty;
    defer idat_chunks.deinit(allocator);

    while (pos + 12 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 ..][0..4];
        const chunk_data_start = pos + 8;
        const chunk_data_end = chunk_data_start + chunk_len;
        if (chunk_data_end + 4 > data.len) return error.InvalidPng;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len < 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[chunk_data_start..][0..4], .big);
            height = std.mem.readInt(u32, data[chunk_data_start + 4 ..][0..4], .big);
            const bit_depth = data[chunk_data_start + 8];
            const color_type = data[chunk_data_start + 9];
            if (width != 160 or height != 205 or bit_depth != 8 or color_type != 6)
                return error.UnsupportedPng;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat_chunks.append(allocator, data[chunk_data_start..chunk_data_end]);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos = chunk_data_end + 4; // skip CRC
    }

    if (width == 0 or idat_chunks.items.len == 0) return error.InvalidPng;

    // Concatenate all IDAT chunks
    var total_idat: usize = 0;
    for (idat_chunks.items) |chunk| total_idat += chunk.len;
    const idat_buf = try allocator.alloc(u8, total_idat);
    defer allocator.free(idat_buf);
    var offset: usize = 0;
    for (idat_chunks.items) |chunk| {
        @memcpy(idat_buf[offset..][0..chunk.len], chunk);
        offset += chunk.len;
    }

    // Decompress zlib data
    const bpp: usize = 4; // RGBA = 4 bytes per pixel
    const row_bytes = width * bpp;
    const flate = std.compress.flate;

    var reader: std.Io.Reader = .fixed(idat_buf);
    var decomp_buf: [flate.max_window_len]u8 = undefined;
    var decomp: flate.Decompress = .init(&reader, .zlib, &decomp_buf);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const raw_size = try decomp.reader.streamRemaining(&aw.writer);
    const raw = aw.written();

    if (raw_size != height * (1 + row_bytes)) return error.InvalidPng;

    // Unfilter scanlines
    const pixels = try allocator.alloc(u8, height * row_bytes);
    errdefer allocator.free(pixels);

    for (0..height) |y| {
        const filter_byte = raw[y * (1 + row_bytes)];
        const scanline = raw[y * (1 + row_bytes) + 1 ..][0..row_bytes];
        const out_row = pixels[y * row_bytes ..][0..row_bytes];
        const prev_row: ?[]const u8 = if (y > 0) pixels[(y - 1) * row_bytes ..][0..row_bytes] else null;

        for (0..row_bytes) |x| {
            const raw_byte = scanline[x];
            const a_val: u8 = if (x >= bpp) out_row[x - bpp] else 0; // left
            const b_val: u8 = if (prev_row) |pr| pr[x] else 0; // up
            const c_val: u8 = if (prev_row) |pr| (if (x >= bpp) pr[x - bpp] else 0) else 0; // upper-left

            out_row[x] = switch (filter_byte) {
                0 => raw_byte, // None
                1 => raw_byte +% a_val, // Sub
                2 => raw_byte +% b_val, // Up
                3 => raw_byte +% @as(u8, @intCast((@as(u16, a_val) + @as(u16, b_val)) / 2)), // Average
                4 => raw_byte +% paethPredictor(a_val, b_val, c_val), // Paeth
                else => return error.InvalidPng,
            };
        }
    }

    return pixels;
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + @as(i16, b) - @as(i16, c);
    const pa = @abs(p - @as(i16, a));
    const pb = @abs(p - @as(i16, b));
    const pc = @abs(p - @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn decompressLua(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    // Check compression format
    if (region.len >= 4 and region[0] == 0x00 and region[1] == 'p' and region[2] == 'x' and region[3] == 'a') {
        return decompressPxa(allocator, region);
    }
    if (region.len >= 4 and region[0] == ':' and region[1] == 'c' and region[2] == ':' and region[3] == 0x00) {
        return decompressOld(allocator, region);
    }
    // Plaintext Lua (null-terminated)
    const end = std.mem.indexOfScalar(u8, region, 0x00) orelse region.len;
    const lua = try allocator.alloc(u8, end);
    @memcpy(lua, region[0..end]);
    return lua;
}

const old_compress_char_table = "\n 0123456789abcdefghijklmnopqrstuvwxyz!#%(){}[]<>+=/*:;.,~_";

fn decompressOld(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    // Header: ':' 'c' ':' 0x00 + decompressed_len (BE u16) + 2 reserved bytes
    if (region.len < 8) return error.InvalidCompression;
    const decomp_len: usize = (@as(usize, region[4]) << 8) | region[5];

    var output = try allocator.alloc(u8, decomp_len);
    errdefer allocator.free(output);
    var out_pos: usize = 0;
    var i: usize = 8; // skip header

    while (out_pos < decomp_len and i < region.len) {
        const byte = region[i];
        i += 1;

        if (byte == 0x00) {
            // Literal escape: next byte is raw
            if (i >= region.len) break;
            output[out_pos] = region[i];
            out_pos += 1;
            i += 1;
        } else if (byte <= 0x3b) {
            // Table lookup (1-indexed into char table)
            output[out_pos] = old_compress_char_table[byte - 1];
            out_pos += 1;
        } else {
            // Back-reference: byte >= 0x3c
            if (i >= region.len) break;
            const next = region[i];
            i += 1;
            const ref_offset = @as(usize, byte - 0x3c) * 16 + (next & 0x0f);
            const length = @as(usize, next >> 4) + 2;
            if (ref_offset > out_pos) return error.InvalidCompression;
            for (0..length) |_| {
                if (out_pos >= decomp_len) break;
                output[out_pos] = output[out_pos - ref_offset];
                out_pos += 1;
            }
        }
    }

    // Trim if needed
    if (out_pos < decomp_len) {
        const trimmed = try allocator.alloc(u8, out_pos);
        @memcpy(trimmed, output[0..out_pos]);
        allocator.free(output);
        return trimmed;
    }

    return output;
}

const BitReader = struct {
    data: []const u8,
    pos: usize, // byte position
    bit_pos: u3, // bit within current byte (0=LSB)

    fn init(data: []const u8) BitReader {
        return .{ .data = data, .pos = 0, .bit_pos = 0 };
    }

    fn readBit(self: *BitReader) !u1 {
        if (self.pos >= self.data.len) return error.EndOfData;
        const bit: u1 = @truncate((self.data[self.pos] >> self.bit_pos) & 1);
        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.pos += 1;
        } else {
            self.bit_pos += 1;
        }
        return bit;
    }

    fn readBits(self: *BitReader, comptime n: u4) !std.meta.Int(.unsigned, n) {
        var result: std.meta.Int(.unsigned, n) = 0;
        inline for (0..n) |i| {
            const bit = try self.readBit();
            result |= @as(std.meta.Int(.unsigned, n), bit) << @intCast(i);
        }
        return result;
    }

    fn readByte(self: *BitReader) !u8 {
        // Optimized path for byte-aligned reads
        if (self.bit_pos == 0) {
            if (self.pos >= self.data.len) return error.EndOfData;
            const b = self.data[self.pos];
            self.pos += 1;
            return b;
        }
        return self.readBits(8);
    }
};

fn decompressPxa(allocator: std.mem.Allocator, region: []const u8) ![]u8 {
    // Header: 00 'p' 'x' 'a' + decompressed_len (BE u16) + compressed_len (BE u16)
    if (region.len < 8) return error.InvalidPxa;
    const decomp_len = std.mem.readInt(u16, region[4..6], .big);
    // compressed data starts at offset 8
    const compressed = region[8..];

    // Initialize move-to-front table
    var mtf: [256]u8 = undefined;
    for (0..256) |i| mtf[i] = @intCast(i);

    var output = try allocator.alloc(u8, decomp_len);
    errdefer allocator.free(output);
    var out_pos: usize = 0;

    var reader = BitReader.init(compressed);

    while (out_pos < decomp_len) {
        const block_type = reader.readBit() catch break;

        if (block_type == 1) {
            // CHR: unary-coded index into MTF table
            var idx: usize = 0;
            while (true) {
                const bit = reader.readBit() catch break;
                if (bit == 1) break;
                idx += 1;
            }
            if (idx >= 256) return error.InvalidPxa;

            const ch = mtf[idx];
            // Move to front
            var j: usize = idx;
            while (j > 0) : (j -= 1) {
                mtf[j] = mtf[j - 1];
            }
            mtf[0] = ch;

            if (out_pos < decomp_len) {
                output[out_pos] = ch;
                out_pos += 1;
            }
        } else {
            // REF: offset + length
            // Offset encoding: read 2 bits to determine size
            const offset_type = try reader.readBits(2);
            var ref_offset: usize = 0;

            switch (offset_type) {
                // 2-bit prefix determines offset bit width
                0b01 => { // 5-bit offset (1-32)
                    ref_offset = @as(usize, try reader.readBits(5)) + 1;
                },
                0b00 => { // 10-bit offset (1-1024)
                    ref_offset = @as(usize, try reader.readBits(10)) + 1;
                },
                0b10 => { // 15-bit offset (1-32768)
                    ref_offset = @as(usize, try reader.readBits(15)) + 1;
                },
                0b11 => { // 5-bit offset (same as 0b01)
                    ref_offset = @as(usize, try reader.readBits(5)) + 1;
                },
            }

            // Special case: 10-bit offset with value 1 → raw literal block
            if (offset_type == 0b00 and ref_offset == 1) {
                // Read raw bytes until 0x00
                while (out_pos < decomp_len) {
                    const byte = try reader.readByte();
                    if (byte == 0x00) break;
                    output[out_pos] = byte;
                    out_pos += 1;
                }
                continue;
            }

            // Length: chain-coded, 3-bit chunks, min 3
            var length: usize = 3;
            while (true) {
                const chunk = try reader.readBits(3);
                length += chunk;
                if (chunk != 7) break;
            }

            // Copy from back-reference
            if (ref_offset > out_pos) return error.InvalidPxa;
            for (0..length) |_| {
                if (out_pos >= decomp_len) break;
                output[out_pos] = output[out_pos - ref_offset];
                out_pos += 1;
            }
        }
    }

    // Trim to actual output if less was produced
    if (out_pos < decomp_len) {
        const trimmed = try allocator.alloc(u8, out_pos);
        @memcpy(trimmed, output[0..out_pos]);
        allocator.free(output);
        return trimmed;
    }

    return output;
}

fn parseMusicLine(memory: *Memory, line: []const u8, row: usize) void {
    // Music format: "FF AABBCCDD" where FF = pattern flags, AA-DD = 4 channel SFX IDs
    // Flags: bit 0 = loop start, bit 1 = loop back (end), bit 2 = stop
    // Each channel byte in memory: bits 0-5 = SFX ID (0-63), bit 6 = channel disabled, bit 7 = unused
    if (line.len < 11) return;

    const base: u16 = mem_const.ADDR_MUSIC + @as(u16, @intCast(row)) * 4;
    const flags = (@as(u8, hexVal(line[0])) << 4) | hexVal(line[1]);

    // Store flags in a separate location: use the high bits of channel 0's byte
    // Actually, PICO-8 stores the flags alongside the pattern data.
    // The memory layout at 0x3100: 4 bytes per pattern, 64 patterns
    // Each byte = SFX ID (0-5) | disabled flag (bit 6)
    // Pattern flags are stored separately: bit 7 of bytes 0,1,2 encode the 3 flag bits
    // byte0 bit7 = loop start (flag bit 0)
    // byte1 bit7 = loop back/end (flag bit 1)
    // byte2 bit7 = stop (flag bit 2)

    var ch: usize = 0;
    while (ch < 4) : (ch += 1) {
        const offset = 3 + ch * 2;
        if (offset + 1 >= line.len) break;
        const sfx_id = (@as(u8, hexVal(line[offset])) << 4) | hexVal(line[offset + 1]);
        // SFX ID 0x41+ means channel is disabled (0x41 = muted channel with sfx 1)
        // In .p8 text, values >= 0x40 indicate disabled channel
        const disabled: u8 = if (sfx_id >= 0x40) 0x40 else 0;
        memory.ram[base + ch] = (sfx_id & 0x3F) | disabled;
    }

    // Store pattern-level flags in bit 7 of first 3 channel bytes
    if (flags & 0x1 != 0) memory.ram[base + 0] |= 0x80; // loop start
    if (flags & 0x2 != 0) memory.ram[base + 1] |= 0x80; // loop back
    if (flags & 0x4 != 0) memory.ram[base + 2] |= 0x80; // stop
}
