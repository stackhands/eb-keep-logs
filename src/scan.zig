//! The searches eb-keep-logs runs over a log, written out instead of taken
//! from a regular expression engine. Each path search returns the last
//! match, as the shell version's `grep -o ... | tail -n 1` does.
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

/// What `lastCommandOutput` finds in a session log, unless the lines after
/// it record that command ending well: EasyBuild logs "... completed
/// successfully" or "... FAILED (exit code N)" when a command ends, and
/// nothing when the build died while it ran.
pub fn failedCommandOutput(text: []const u8) ?[]const u8 {
    const path = lastCommandOutput(text) orelse return null;
    const end = @intFromPtr(path.ptr) - @intFromPtr(text.ptr) + path.len;
    const nl = std.mem.findScalarPos(u8, text, end, '\n') orelse return path;
    const after = text[nl + 1 ..];
    const ok = std.mem.find(u8, after, " completed successfully") orelse return path;
    if (std.mem.find(u8, after[0..ok], " FAILED (exit code ") != null) return path;
    return null;
}

/// Whether a meson testlog's summary shows every test passing: an "Ok:"
/// line, and no "Fail:", "Unexpected Pass:" or "Timeout:" line counting
/// more than 0.
pub fn mesonPassed(text: []const u8) bool {
    var summary = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Ok:")) summary = true;
        for ([_][]const u8{ "Fail:", "Unexpected Pass:", "Timeout:" }) |label| {
            if (!std.mem.startsWith(u8, line, label)) continue;
            var i = label.len;
            while (i < line.len and isSpace(line[i])) i += 1;
            if (i < line.len and line[i] >= '1' and line[i] <= '9') return false;
        }
    }
    return summary;
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

/// Whether an EasyBuild log is another build's than easyconfig `name`'s: it
/// shows EasyBuild processing an easyconfig ("processing EasyBuild
/// easyconfig PATH") and never names `name`.eb, which a build's own log does
/// on its command line. As `grep -q` and `grep -qF` in the shell version.
pub fn otherBuild(text: []const u8, name: []const u8) bool {
    if (std.mem.find(u8, text, "processing EasyBuild easyconfig ") == null) return false;
    var pos: usize = 0;
    while (std.mem.findPos(u8, text, pos, name)) |at| : (pos = at + 1) {
        if (std.mem.startsWith(u8, text[at + name.len ..], ".eb")) return false;
    }
    return true;
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

test "otherBuild" {
    const ring = "== processing EasyBuild easyconfig /ec/ring-1.0.eb\n";
    try std.testing.expect(otherBuild(ring, "calc-1.0"));
    try std.testing.expect(!otherBuild(ring, "ring-1.0"));
    // Named on the command line, before a dependency failed.
    try std.testing.expect(!otherBuild("Command line: /ec/calc-1.0.eb --robot\n" ++ ring, "calc-1.0"));
    // A log that processed no easyconfig cannot tell.
    try std.testing.expect(!otherBuild("compile error\n", "calc-1.0"));
    // A longer name that starts with this one is another easyconfig.
    try std.testing.expect(otherBuild("== processing EasyBuild easyconfig /ec/calc-1.0-x.eb\n", "calc-1.0"));
}

test "failedCommandOutput" {
    const cmd = "\toutput will be logged to /e/run-shell-cmd-output/make-1/out.txt\n";
    const ok = "== run.py:650 INFO Shell command completed successfully\n";
    const failed = "== run.py:652 WARNING Shell command FAILED (exit code 2)\n";
    try std.testing.expectEqualStrings("/e/run-shell-cmd-output/make-1/out.txt", failedCommandOutput(cmd ++ failed ++ ok).?);
    try std.testing.expect(failedCommandOutput(cmd ++ ok ++ failed) == null);
    try std.testing.expect(failedCommandOutput(cmd ++ "x\n" ++ ok) == null);
    // No outcome: the build died while the command ran.
    try std.testing.expectEqualStrings("/e/run-shell-cmd-output/make-1/out.txt", failedCommandOutput(cmd ++ "x\n").?);
    try std.testing.expect(failedCommandOutput(cmd[0 .. cmd.len - 1]) != null);
    // Only the lines after the command's own line count.
    try std.testing.expect(failedCommandOutput("== Shell command completed successfully " ++ cmd) != null);
    try std.testing.expect(failedCommandOutput(ok) == null);
}

test "mesonPassed" {
    try std.testing.expect(mesonPassed("x\n\nOk:                1   \nFail:              0   \n"));
    try std.testing.expect(!mesonPassed("Ok:                0   \nFail:              1   \n"));
    try std.testing.expect(!mesonPassed("Ok: 3\nFail: 0\nTimeout:  2\n"));
    try std.testing.expect(!mesonPassed("Ok: 3\nUnexpected Pass:\t1\r\n"));
    try std.testing.expect(mesonPassed("Ok: 3\nExpected Fail: 1\nSkipped: 4\n"));
    // No summary: meson did not finish.
    try std.testing.expect(!mesonPassed("---- tests::the_one stdout ----\n"));
    try std.testing.expect(!mesonPassed(""));
}

test "lastMesonDir" {
    try std.testing.expectEqualStrings("/b", lastMesonDir("meson test -C\n  /a --x\nmeson test -C /b\n").?);
    try std.testing.expect(lastMesonDir("meson test -C/a") == null);
    try std.testing.expect(lastMesonDir("meson test -C   ") == null);
}
