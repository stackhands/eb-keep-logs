//! Rewriting raw bytes that are not valid UTF-8, for a report that goes to
//! stdout as plain text or as `--json`: both promise UTF-8 text, and a raw
//! byte from a module name, a record path, or a dry-run line is not it.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// `s` with each byte that is not part of a UTF-8 character replaced by
/// U+FFFD. `s` itself, with no copy, when it is already valid.
pub fn utf8(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.Io.Writer.Allocating = .init(arena);
    write(s, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// `s` for a `{f}` placeholder, written as `utf8` would return it, with
/// nothing allocated.
pub fn text(s: []const u8) std.fmt.Alt([]const u8, write) {
    return .{ .data = s };
}

fn write(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len) if (std.unicode.utf8Decode(s[i..][0..n])) |_| {
            try w.writeAll(s[i..][0..n]);
            i += n;
            continue;
        } else |_| {};
        try w.writeAll("\u{FFFD}");
        i += 1;
    }
}

test "a bad byte is replaced one at a time, and valid text is untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{e9}", try utf8(a, "a\xffb\u{e9}"));
    try std.testing.expectEqualStrings("\u{FFFD}(\u{FFFD}\u{FFFD}\u{FFFD}", try utf8(a, "\xc3(\xed\xa0\x80"));
    const valid = "caf\u{e9}";
    try std.testing.expectEqual(valid.ptr, (try utf8(a, valid)).ptr);
}

test "text writes what utf8 returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "a\xffb\u{e9}", "\xc3(\xed\xa0\x80", "caf\u{e9}", "" }) |s| {
        try std.testing.expectEqualStrings(try utf8(a, s), try std.fmt.allocPrint(a, "{f}", .{text(s)}));
    }
}
