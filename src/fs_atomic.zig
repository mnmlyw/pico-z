const std = @import("std");

pub fn writeFileAtomic(allocator: std.mem.Allocator, dir: std.fs.Dir, final_path: []const u8, data: []const u8) !void {
    var attempt: u32 = 0;
    while (attempt < 32) : (attempt += 1) {
        const tmp_path = try std.fmt.allocPrint(
            allocator,
            "{s}.tmp.{x:0>16}.{d}",
            .{ final_path, std.crypto.random.int(u64), attempt },
        );
        defer allocator.free(tmp_path);

        var tmp_file = dir.createFile(tmp_path, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer dir.deleteFile(tmp_path) catch {};

        try tmp_file.writeAll(data);
        try tmp_file.sync();
        tmp_file.close();

        dir.rename(tmp_path, final_path) catch |err| switch (err) {
            // Some platforms do not allow replace-on-rename.
            error.PathAlreadyExists => {
                dir.deleteFile(final_path) catch |delete_err| switch (delete_err) {
                    error.FileNotFound => {},
                    else => return delete_err,
                };
                try dir.rename(tmp_path, final_path);
            },
            else => return err,
        };

        return;
    }

    return error.AtomicWriteTempNameCollision;
}
