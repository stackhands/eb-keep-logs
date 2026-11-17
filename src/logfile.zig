//! Read plain files and, when requested, `.gz` files through gzip.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;

const Allocator = std.mem.Allocator;

/// Why a file could not be read: the system's error, no memory, `limit`
/// or more bytes in the file or its decompressed text, or a `.gz` that is
/// not gzip or is damaged.
pub const ReadError = sys.Error || Allocator.Error || error{ StreamTooLong, BadGzip };

/// Read the regular file `dir/name`, refusing both the input and decompressed
/// text at `limit` bytes. When `gzip` is true, a name ending in `.gz` is
/// decompressed; other names are read as plain text. A symbolic link is not
/// followed.
pub fn read(gpa: Allocator, dir: fsx.fd_t, name: []const u8, limit: usize, gzip: bool) ReadError![]u8 {
    const f = try fsx.openRegular(dir, name, false);
    defer sys.close(f.fd);
    const raw = try fsx.readAll(gpa, f.fd, limit);
    if (!gzip or !std.mem.endsWith(u8, name, ".gz")) return raw;
    defer gpa.free(raw);
    return gunzip(gpa, raw, limit);
}

/// The bytes the gzip data `raw` holds, its members one after another as
/// `gzip -d` gives them; `limit` or more decompressed bytes is an error. The
/// inflater only reads a member's CRC-32 and size, so they are checked here.
pub fn gunzip(gpa: Allocator, raw: []const u8, limit: usize) (Allocator.Error || error{ StreamTooLong, BadGzip })![]u8 {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
        const start = out.items.len;
        d.reader.appendRemaining(gpa, &out, .limited(limit - start)) catch |err| switch (err) {
            error.ReadFailed => return error.BadGzip,
            else => |e| return e,
        };
        const metadata = d.container_metadata.gzip;
        const member = out.items[start..];
        if (metadata.crc != std.hash.Crc32.hash(member) or
            metadata.count != @as(u32, @truncate(member.len)))
            return error.BadGzip;
        if (in.bufferedLen() == 0) return out.toOwnedSlice(gpa);
    }
}

test "gunzip reads what gzip wrote, and refuses what it did not" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try plain.appendNTimes(gpa, 'a', 128 * 1024);
    var compressed: std.Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, window, .gzip, .best);
    try compressor.writer.writeAll(plain.items);
    try compressor.finish();

    const got = try gunzip(gpa, compressed.written(), 1 << 30);
    defer gpa.free(got);
    try testing.expectEqualStrings(plain.items, got);

    const twice = try std.mem.concat(gpa, u8, &.{ compressed.written(), compressed.written() });
    defer gpa.free(twice);
    const both = try gunzip(gpa, twice, 1 << 30);
    defer gpa.free(both);
    try testing.expectEqual(2 * plain.items.len, both.len);
    try testing.expectEqualStrings(plain.items, both[plain.items.len..]);

    var bad = try gpa.dupe(u8, compressed.written());
    defer gpa.free(bad);
    bad[bad.len - 6] ^= 0xff;
    try testing.expectError(error.BadGzip, gunzip(gpa, bad, 1 << 30));
    try testing.expectError(error.BadGzip, gunzip(gpa, compressed.written()[0 .. compressed.written().len / 2], 1 << 30));
    try testing.expectError(error.BadGzip, gunzip(gpa, "not gzip at all", 1 << 30));
}
