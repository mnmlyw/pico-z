const std = @import("std");

pub fn writeFileAtomic(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, final_path: []const u8, data: []const u8) !void {
    var attempt: u32 = 0;
    while (attempt < 32) : (attempt += 1) {
        var rand_bytes: [8]u8 = undefined;
        io.random(&rand_bytes);
        const rand = std.mem.readInt(u64, &rand_bytes, .little);
        const tmp_path = try std.fmt.allocPrint(
            allocator,
            "{s}.tmp.{x:0>16}.{d}",
            .{ final_path, rand, attempt },
        );
        defer allocator.free(tmp_path);

        var tmp_file = dir.createFile(io, tmp_path, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer dir.deleteFile(io, tmp_path) catch {};

        try tmp_file.writeStreamingAll(io, data);
        try tmp_file.sync(io);
        tmp_file.close(io);

        try dir.rename(tmp_path, dir, final_path, io);
        return;
    }

    return error.AtomicWriteTempNameCollision;
}
