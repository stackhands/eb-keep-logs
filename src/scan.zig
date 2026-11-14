//! The two searches eb-keep-logs runs over a log, written out instead of
//! taken from a regular expression engine. Each returns the last match, as
//! the shell version's `grep -o ... | tail -n 1` does.
const std = @import("std");

/// The bytes POSIX [:space:] and PCRE \s match.
fn isSpace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

const marker = "/run-shell-cmd-output/";
const tail = "/out.txt";

/// End of a match of `marker [^/]+ tail` starting at `q`, or null.
fn endAt(tok: []const u8, q: usize) ?usize {
    if (!std.mem.startsWith(u8, tok[q..], marker)) return null;
    const seg_start = q + marker.len;
    const slash = std.mem.findScalarPos(u8, tok, seg_start, '/') orelse return null;
    if (slash == seg_start) return null;
    if (!std.mem.startsWith(u8, tok[slash..], tail)) return null;
    return slash + tail.len;
}

/// The last match of the ERE `/[^[:space:]]*/run-shell-cmd-output/[^/[:space:]]+/out\.txt`,
/// with grep -o's leftmost-longest, non-overlapping matching per line.
pub fn lastCommandOutput(text: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and isSpace(text[i])) i += 1;
        const start = i;
        while (i < text.len and !isSpace(text[i])) i += 1;
        const tok = text[start..i];
        if (std.mem.find(u8, tok, marker) == null) continue;
        var pos: usize = 0;
        while (pos < tok.len) {
            // Leftmost start: the first '/' at or after pos with a marker
            // strictly after it; longest end: the furthest marker match.
            var found: ?struct { p: usize, end: usize } = null;
            var p = pos;
            while (p < tok.len) : (p += 1) {
                if (tok[p] != '/') continue;
                var best: ?usize = null;
                var q = p + 1;
                while (std.mem.findPos(u8, tok, q, marker)) |qq| : (q = qq + 1) {
                    if (endAt(tok, qq)) |e| best = if (best) |b| @max(b, e) else e;
                }
                if (best) |e| {
                    found = .{ .p = p, .end = e };
                    break;
                }
            }
            const f = found orelse break;
            last = tok[f.p..f.end];
            pos = f.end;
        }
    }
    return last;
}

/// The last match of the PCRE `meson test -C\s+\K[^[:space:]]+` over the
/// whole log, newlines counting as spaces.
pub fn lastMesonDir(text: []const u8) ?[]const u8 {
    const needle = "meson test -C";
    var last: ?[]const u8 = null;
    var pos: usize = 0;
    while (std.mem.findPos(u8, text, pos, needle)) |at| {
        var i = at + needle.len;
        const ws = i;
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i == ws or i == text.len) {
            pos = at + 1;
            continue;
        }
        const s = i;
        while (i < text.len and !isSpace(text[i])) i += 1;
        last = text[s..i];
        pos = i;
    }
    return last;
}

test "lastCommandOutput" {
    const t = "x /tmp/eb/run-shell-cmd-output/make-ab12/out.txt y\n" ++
        "z=/tmp/eb/run-shell-cmd-output/cmake-cd34/out.txt\n";
    try std.testing.expectEqualStrings("/tmp/eb/run-shell-cmd-output/cmake-cd34/out.txt", lastCommandOutput(t).?);
    try std.testing.expect(lastCommandOutput("/run-shell-cmd-output/a/out.txt") == null);
    try std.testing.expect(lastCommandOutput("/x/run-shell-cmd-output//out.txt") == null);
    // Longest: the second marker extends the match.
    try std.testing.expectEqualStrings(
        "/a/run-shell-cmd-output/b/out.txt/run-shell-cmd-output/c/out.txt",
        lastCommandOutput("/a/run-shell-cmd-output/b/out.txt/run-shell-cmd-output/c/out.txt").?,
    );
}

test "lastMesonDir" {
    try std.testing.expectEqualStrings("/b", lastMesonDir("meson test -C\n  /a --x\nmeson test -C /b\n").?);
    try std.testing.expect(lastMesonDir("meson test -C/a") == null);
    try std.testing.expect(lastMesonDir("meson test -C   ") == null);
}
