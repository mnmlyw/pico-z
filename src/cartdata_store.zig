const std = @import("std");
const Memory = @import("memory.zig").Memory;
const mem_const = @import("memory.zig");

const CARTDATA_DIR = ".pico-z-cartdata";
const CARTDATA_BYTES = 256;

fn appendHexByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, b: u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, hex[(b >> 4) & 0x0f]);
    try out.append(allocator, hex[b & 0x0f]);
}

fn sanitizeId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (id) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.') {
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

fn pathForId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    const safe_id = try sanitizeId(allocator, id);
    defer allocator.free(safe_id);
    return std.fmt.allocPrint(allocator, "{s}/{s}.dat", .{ CARTDATA_DIR, safe_id });
}

fn cartDataSlice(memory: *Memory) []u8 {
    return memory.ram[mem_const.ADDR_CART_DATA .. mem_const.ADDR_CART_DATA + CARTDATA_BYTES];
}

pub fn load(allocator: std.mem.Allocator, memory: *Memory, id: []const u8) !void {
    const path = try pathForId(allocator, id);
    defer allocator.free(path);

    @memset(cartDataSlice(memory), 0);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readAll(cartDataSlice(memory));
    if (bytes < CARTDATA_BYTES) {
        @memset(cartDataSlice(memory)[bytes..], 0);
    }
}

pub fn save(allocator: std.mem.Allocator, memory: *Memory, id: []const u8) !void {
    try std.fs.cwd().makePath(CARTDATA_DIR);

    const path = try pathForId(allocator, id);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(cartDataSlice(memory));
}

test "cartdata roundtrip" {
    var mem = Memory.init();
    const allocator = std.testing.allocator;
    const id = "test_roundtrip";
    const path = try pathForId(allocator, id);
    defer allocator.free(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    try std.fs.cwd().makePath(CARTDATA_DIR);

    mem.poke32(mem_const.ADDR_CART_DATA + 0 * 4, 0x11223344);
    mem.poke32(mem_const.ADDR_CART_DATA + 63 * 4, 0xaabbccdd);
    try save(allocator, &mem, id);

    @memset(cartDataSlice(&mem), 0);
    try load(allocator, &mem, id);

    try std.testing.expectEqual(@as(u32, 0x11223344), mem.peek32(mem_const.ADDR_CART_DATA + 0 * 4));
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), mem.peek32(mem_const.ADDR_CART_DATA + 63 * 4));
}

test "cartdata load missing zeroes memory" {
    var mem = Memory.init();
    const allocator = std.testing.allocator;
    const id = "missing_file_id";
    const path = try pathForId(allocator, id);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};

    @memset(cartDataSlice(&mem), 0xaa);
    try load(allocator, &mem, id);

    for (cartDataSlice(&mem)) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}
