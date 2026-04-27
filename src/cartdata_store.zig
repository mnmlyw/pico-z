const std = @import("std");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");
const fs_atomic = @import("fs_atomic.zig");

const CARTDATA_DIR = ".pico-z-cartdata";
pub const CARTDATA_BYTES = 256;

fn appendHexByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, b: u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, hex[(b >> 4) & 0x0f]);
    try out.append(allocator, hex[b & 0x0f]);
}

fn sanitizeId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (id) |c| {
        // Keep the mapping injective by never allowing '_' through verbatim.
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '.') {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
            try appendHexByte(&out, allocator, c);
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "default");
    }
    return out.toOwnedSlice(allocator);
}

pub fn pathForId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    const safe_id = try sanitizeId(allocator, id);
    defer allocator.free(safe_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}.dat", .{ CARTDATA_DIR, safe_id });
}

fn cartDataSlice(memory: *Memory) []u8 {
    return memory.ram[mem_const.ADDR_CART_DATA .. mem_const.ADDR_CART_DATA + CARTDATA_BYTES];
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, memory: *Memory, id: []const u8) !void {
    const path = try pathForId(allocator, id);
    defer allocator.free(path);

    const buf = std.Io.Dir.cwd().readFile(io, path, cartDataSlice(memory)) catch |err| switch (err) {
        error.FileNotFound => {
            @memset(cartDataSlice(memory), 0);
            return;
        },
        else => return err,
    };
    if (buf.len < CARTDATA_BYTES) {
        @memset(cartDataSlice(memory)[buf.len..], 0);
    }
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, memory: *Memory, id: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, CARTDATA_DIR);

    const path = try pathForId(allocator, id);
    defer allocator.free(path);

    // Use atomic replace so existing cartdata survives interrupted writes.
    try fs_atomic.writeFileAtomic(allocator, io, std.Io.Dir.cwd(), path, cartDataSlice(memory));
}

test "cartdata roundtrip" {
    var mem = Memory.init();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const id = "test_roundtrip";
    const path = try pathForId(allocator, id);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, CARTDATA_DIR);

    mem.poke32(mem_const.ADDR_CART_DATA + 0 * 4, 0x11223344);
    mem.poke32(mem_const.ADDR_CART_DATA + 63 * 4, 0xaabbccdd);
    try save(allocator, io, &mem, id);

    @memset(cartDataSlice(&mem), 0);
    try load(allocator, io, &mem, id);

    try std.testing.expectEqual(@as(u32, 0x11223344), mem.peek32(mem_const.ADDR_CART_DATA + 0 * 4));
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), mem.peek32(mem_const.ADDR_CART_DATA + 63 * 4));
}

test "cartdata load missing zeroes memory" {
    var mem = Memory.init();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const id = "missing_file_id";
    const path = try pathForId(allocator, id);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    @memset(cartDataSlice(&mem), 0xaa);
    try load(allocator, io, &mem, id);

    for (cartDataSlice(&mem)) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "cartdata ids with escape-like text do not collide" {
    const allocator = std.testing.allocator;
    const escaped_path = try pathForId(allocator, "/");
    defer allocator.free(escaped_path);
    const literal_path = try pathForId(allocator, "_2f");
    defer allocator.free(literal_path);

    try std.testing.expect(!std.mem.eql(u8, escaped_path, literal_path));
}
