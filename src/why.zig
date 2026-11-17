//! `why`: read the logs a run kept, plain or as `rotate` compressed them,
//! and say why its builds failed: for each, the EasyBuild step it failed
//! in, EasyBuild's message, and the line of its log that shows the error,
//! with the lines around it. `history`: how each kept build of a package
//! went, run by run, from EasyBuild's output.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";

/// Largest log read, after decompression, as `failed` scans at most.
const read_limit: usize = 1 << 30;
/// Lines shown either side of the error line.
const context_lines = 3;
/// Longest line shown, in bytes.
const line_limit = 400;
/// Most lines of one EasyBuild message read after its first.
const entry_lines = 200;
/// The `schema_version` of what `--json` prints. Dropping or renaming a
/// field, or changing what one means, takes a new version; adding a field
/// does not.
pub const schema_version = 1;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

/// EasyBuild 5's steps: the name its session log, its failure messages and
/// `--stop` use (easybuild/tools/hooks.py), and the description it
/// announces the step with on the terminal, `== DESCRIPTION...`
/// (`EasyBlock.get_steps`, easybuild/framework/easyblock.py).
const steps = [_]struct { name: []const u8, said: []const u8 }{
    .{ .name = "fetch", .said = "fetching files and verifying checksums" },
    .{ .name = "ready", .said = "creating build dir, resetting environment" },
    .{ .name = "extract", .said = "unpacking" },
    .{ .name = "patch", .said = "patching" },
    .{ .name = "prepare", .said = "preparing" },
    .{ .name = "configure", .said = "configuring" },
    .{ .name = "build", .said = "building" },
    .{ .name = "test", .said = "testing" },
    .{ .name = "install", .said = "installing" },
    .{ .name = "extensions", .said = "taking care of extensions" },
    .{ .name = "postiter", .said = "restore after iterating" },
    .{ .name = "postproc", .said = "postprocessing" },
    .{ .name = "sanitycheck", .said = "sanity checking" },
    .{ .name = "cleanup", .said = "cleaning up" },
    .{ .name = "module", .said = "creating module" },
    .{ .name = "permissions", .said = "permissions" },
    .{ .name = "package", .said = "packaging" },
    .{ .name = "testcases", .said = "running test cases" },
};

/// Why a log could not be read: the system's error, no memory, 1 GiB or
/// more of text, or a `.gz` that is not gzip or is damaged.
pub const ReadError = sys.Error || Allocator.Error || error{ StreamTooLong, BadGzip };

/// The text of the regular file `dir/name`, through gzip when the name ends
/// in `.gz`. A symbolic link is not followed.
pub fn readLog(gpa: Allocator, dir: fsx.fd_t, name: []const u8) ReadError![]u8 {
    const f = try fsx.openRegular(dir, name, false);
    defer sys.close(f.fd);
    const raw = try fsx.readAll(gpa, f.fd, read_limit);
    if (!std.mem.endsWith(u8, name, ".gz")) return raw;
    defer gpa.free(raw);
    return gunzip(gpa, raw);
}

/// The bytes the gzip data `raw` holds, its members one after another as
/// `gzip -d` gives them; `read_limit` or more of them is an error. The
/// inflater only reads a member's CRC-32 and size, so they are checked
/// here.
pub fn gunzip(gpa: Allocator, raw: []const u8) (Allocator.Error || error{ StreamTooLong, BadGzip })![]u8 {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var in: std.Io.Reader = .fixed(raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (true) {
        var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
        const start = out.items.len;
        d.reader.appendRemaining(gpa, &out, .limited(read_limit - start)) catch |err| switch (err) {
            error.ReadFailed => return error.BadGzip,
            else => |e| return e,
        };
        const m = d.container_metadata.gzip;
        const member = out.items[start..];
        if (m.crc != std.hash.Crc32.hash(member) or m.count != @as(u32, @truncate(member.len)))
            return error.BadGzip;
        if (in.bufferedLen() == 0) return out.toOwnedSlice(gpa);
    }
}

/// A line of a log: its text without the newline, its number from 1, and
/// the offset of its first byte.
const Line = struct { text: []const u8, no: usize, start: usize };

const Lines = struct {
    text: []const u8,
    pos: usize = 0,
    no: usize = 0,

    fn next(it: *Lines) ?Line {
        if (it.pos >= it.text.len) return null;
        const start = it.pos;
        const end = std.mem.findScalarPos(u8, it.text, start, '\n') orelse it.text.len;
        it.pos = end + 1;
        it.no += 1;
        return .{ .text = std.mem.trimEnd(u8, it.text[start..end], "\r"), .no = it.no, .start = start };
    }
};

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `line` is a compiler's or a linker's error, the line a failed
/// build command's output names its cause in:
/// - a C or C++ compiler's error at a source line, as GCC and Clang print
///   it, `FILE:LINE: error: ...` or `FILE:LINE:COLUMN: fatal error: ...`,
///   or as nvcc does, `FILE(LINE): error: ...`;
/// - a linker's `undefined reference to SYMBOL` or `cannot find -lNAME`,
///   as GNU ld prints them, or `undefined symbol: SYMBOL`, as lld and mold
///   do.
/// A compiler's error without a source line, such as an unknown option, is
/// not one.
pub fn isCompilerOrLinkerError(line: []const u8) bool {
    for ([_][]const u8{ "undefined reference to ", "undefined symbol: ", "cannot find -l" }) |s| {
        if (std.mem.find(u8, line, s) != null) return true;
    }
    for ([_][]const u8{ ": error:", ": fatal error:" }) |s| {
        var pos: usize = 0;
        while (std.mem.findPos(u8, line, pos, s)) |at| : (pos = at + 1) {
            if (endsInSourceLine(line[0..at])) return true;
        }
    }
    return false;
}

/// Whether `s` ends in a place in a source file: `FILE:LINE`,
/// `FILE:LINE:COLUMN` or `FILE(LINE)`.
fn endsInSourceLine(s: []const u8) bool {
    if (std.mem.endsWith(u8, s, ")")) {
        const open = std.mem.findScalarLast(u8, s, '(') orelse return false;
        return open > 0 and isNumber(s[open + 1 .. s.len - 1]);
    }
    var file = s;
    var numbers: usize = 0;
    while (numbers < 2) : (numbers += 1) {
        const colon = std.mem.findScalarLast(u8, file, ':') orelse break;
        if (!isNumber(file[colon + 1 ..])) break;
        file = file[0..colon];
    }
    return numbers > 0 and file.len > 0;
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const space = " \t\r\n\x0b\x0c";

/// `line` without its ANSI escape sequences, as EasyBuild's coloured output
/// on a terminal has them.
fn visible(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, line, 0x1b) == null) return line;
    var out: std.ArrayList(u8) = try .initCapacity(arena, line.len);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len and (std.ascii.isDigit(line[j]) or line[j] == ';')) j += 1;
            if (j < line.len and std.ascii.isAlphabetic(line[j])) {
                i = j + 1;
                continue;
            }
        }
        out.appendAssumeCapacity(line[i]);
        i += 1;
    }
    return out.items;
}

/// The step a line starts: EasyBuild's announcement of it on the terminal,
/// `== DESCRIPTION...`, or `Starting STEP step` in the session log. Any
/// other announcement, such as `== resolving dependencies ...`, starts
/// none.
fn stepStarted(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const line = try visible(arena, raw);
    if (std.mem.startsWith(u8, line, "== ")) for (steps) |s| {
        const rest = line[3..];
        if (std.mem.startsWith(u8, rest, s.said) and std.mem.startsWith(u8, rest[s.said.len..], "...")) return s.name;
    };
    const word = "Starting ";
    var pos: usize = 0;
    while (std.mem.findPos(u8, line, pos, word)) |at| : (pos = at + 1) {
        if (at > 0 and isWord(line[at - 1])) continue;
        const s = at + word.len;
        var e = s;
        while (e < line.len and isWord(line[e])) e += 1;
        if (e == s or !std.mem.startsWith(u8, line[e..], " step")) continue;
        if (e + 5 < line.len and isWord(line[e + 5])) continue;
        return line[s..e];
    }
    return null;
}

/// The step EasyBuild's failure message names, `... in STEP step for
/// NAME.eb`; the first, should it name more than one.
fn stepNamed(entry: []const u8) ?[]const u8 {
    var best: ?struct { at: usize, step: []const u8 } = null;
    for (steps) |s| {
        var buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, " in {s} step", .{s.name}) catch unreachable;
        const at = std.ascii.findIgnoreCase(entry, needle) orelse continue;
        if (best == null or at < best.?.at) best = .{ .at = at, .step = s.name };
    }
    return if (best) |b| b.step else null;
}

/// What follows `marker` in `line`, at its first occurrence.
fn after(line: []const u8, marker: []const u8) ?[]const u8 {
    const i = std.mem.find(u8, line, marker) orelse return null;
    return line[i + marker.len ..];
}

/// EasyBuild's message from offset `from` in `text` to the end of its entry,
/// the lines before the next that starts with `== `, with each run of white
/// space made one space. On the terminal EasyBuild wraps at 80 columns,
/// folding a longer word over whole lines; with `unwrap`, a line of 80 bytes
/// or more without white space is such a fold, and runs on into the next
/// line.
fn flatEntry(arena: Allocator, text: []const u8, from: usize, unwrap: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: Lines = .{ .text = text, .pos = from };
    var n: usize = 0;
    var fold = false;
    while (it.next()) |l| : (n += 1) {
        if (n > entry_lines or (n > 0 and std.mem.startsWith(u8, l.text, "== "))) break;
        var words = std.mem.tokenizeAny(u8, l.text, space);
        var first = true;
        while (words.next()) |w| : (first = false) {
            if (out.items.len > 0 and !(first and fold)) try out.append(arena, ' ');
            try out.appendSlice(arena, w);
        }
        fold = unwrap and l.text.len >= 80 and std.mem.findAny(u8, l.text, space) == null;
    }
    return out.items;
}

/// The seconds in the last `(took DURATION)` of `entry`, DURATION as
/// EasyBuild writes one: `< 1 sec`, `48 secs`, `2 mins 24 secs`,
/// `1 hour 0 mins 5 secs`.
pub fn tookSeconds(entry: []const u8) ?u64 {
    const at = std.mem.findLast(u8, entry, "(took ") orelse return null;
    const s = at + "(took ".len;
    const took = entry[s .. std.mem.findScalarPos(u8, entry, s, ')') orelse return null];
    if (std.mem.startsWith(u8, took, "<")) return 0;
    var total: u64 = 0;
    var words = std.mem.tokenizeScalar(u8, took, ' ');
    var any = false;
    while (words.next()) |num| {
        const n = std.fmt.parseInt(u64, num, 10) catch return null;
        const unit = words.next() orelse return null;
        const scale: u64 = if (std.mem.startsWith(u8, unit, "hour")) 3600 else if (std.mem.startsWith(u8, unit, "min")) 60 else if (std.mem.startsWith(u8, unit, "sec")) 1 else return null;
        total = std.math.add(u64, total, std.math.mul(u64, n, scale) catch return null) catch return null;
        any = true;
    }
    return if (any) total else null;
}

/// Which log a text is: EasyBuild's session log, or its output on the
/// terminal, kept as NAME.stdout.log.
pub const Source = enum { session, stdout };

/// What `analyze` reads in a log; slices point into the log's text or are
/// constants.
pub const Analysis = struct {
    /// `NAME/VERSION` from EasyBuild's `building and installing` line.
    package: ?[]const u8 = null,
    /// The path in EasyBuild's `processing EasyBuild easyconfig` line.
    easyconfig: ?[]const u8 = null,
    /// The EasyBuild step the build failed in, or the log ends in.
    step: ?[]const u8 = null,
    /// Whether the log records the failure.
    failed: bool = false,
    /// EasyBuild's own message for the failure, its first line.
    message: ?[]const u8 = null,
    /// The seconds EasyBuild says the installation took.
    duration_s: ?u64 = null,
    /// The line that shows the error.
    error_line: ?Line = null,
};

/// EasyBuild's message in a line that reports an error, or null when the
/// line reports none: `EasyBuild encountered an error: MESSAGE (at
/// FILE:LINE in FUNCTION)` in a session log, `ERROR: MESSAGE` on the
/// terminal.
fn reportOf(line: []const u8, source: Source) ?[]const u8 {
    switch (source) {
        .session => {
            const m = after(line, "EasyBuild encountered an error: ") orelse return null;
            if (std.mem.endsWith(u8, m, ")")) if (std.mem.findLast(u8, m, " (at ")) |i| return m[0..i];
            return m;
        },
        .stdout => return if (std.mem.startsWith(u8, line, "ERROR: ")) std.mem.trim(u8, line[7..], space) else null,
    }
}

const ended_marker = "installation ended unsuccessfully";

/// The message of an `Installation ended unsuccessfully: MESSAGE (took
/// DURATION)` entry that `flatEntry` gave from the marker on.
fn endedMessage(entry: []const u8) ?[]const u8 {
    var m = std.mem.trimStart(u8, entry[ended_marker.len..], ": ");
    if (std.mem.findLast(u8, m, " (took ")) |i| m = m[0..i];
    return if (m.len > 0) m else null;
}

/// What a log records about its build's failure. EasyBuild's own error line
/// is, in a session log, its first `EasyBuild encountered an error`; on the
/// terminal, where its first `ERROR:` may only say `Shell command failed!`,
/// the `FAILED: Installation ended unsuccessfully` entry, which carries the
/// message; failing either, the other. The step is the one that entry
/// names; else the last step the log shows starting before the failure, or
/// before its end when it records none. The error line is the first
/// compiler or linker error from that step's start to EasyBuild's error
/// line, as a failed command's output in a session log has one; without
/// one, EasyBuild's error line. A session log shows no error before its
/// first step, as what comes before is EasyBuild dumping its configuration.
pub fn analyze(arena: Allocator, text: []const u8, source: Source) Allocator.Error!Analysis {
    var a: Analysis = .{};
    var last_step: ?[]const u8 = null;
    var candidate: ?Line = null;
    var report: ?Line = null;
    var ended: ?Line = null;
    var ended_at: usize = 0;
    var it: Lines = .{ .text = text };
    while (it.next()) |l| {
        if (std.ascii.findIgnoreCase(l.text, ended_marker)) |i| {
            ended = l;
            ended_at = l.start + i;
            break;
        }
        if (report != null and source == .session) continue;
        if (try stepStarted(arena, l.text)) |s| {
            last_step = s;
            candidate = null;
        } else if (after(l.text, "building and installing ")) |rest| {
            a.package = std.mem.trimEnd(u8, std.mem.trim(u8, rest, space), ".");
        } else if (after(l.text, "processing EasyBuild easyconfig ")) |rest| {
            const p = std.mem.trim(u8, rest, space);
            if (p.len > 0) a.easyconfig = p;
        }
        if (report == null) if (reportOf(l.text, source)) |m| {
            report = l;
            a.message = m;
            continue;
        };
        if (candidate == null and (source == .stdout or last_step != null) and isCompilerOrLinkerError(l.text))
            candidate = l;
    }
    if (ended) |e| {
        const entry = try flatEntry(arena, text, ended_at, source == .stdout);
        a.step = stepNamed(entry);
        a.duration_s = tookSeconds(entry);
        if (report == null or source == .stdout) {
            report = e;
            a.message = endedMessage(entry);
        }
    }
    if (a.step == null) a.step = last_step;
    if (report) |r| {
        a.failed = true;
        a.error_line = if (candidate) |c| (if (c.no < r.no) c else r) else r;
    }
    return a;
}

/// How a build went.
pub const Outcome = enum { success, failed, unknown };

/// How a build went, by its output, and the seconds EasyBuild says it took.
pub const Verdict = struct { outcome: Outcome = .unknown, duration_s: ?u64 = null };

/// How the EasyBuild run a log of its terminal output records went: the
/// last `COMPLETED: Installation ended successfully` or `FAILED:
/// Installation ended unsuccessfully` decides, with the duration in it; a
/// line starting with `ERROR:` after a success, or without either, is a
/// failure.
pub fn verdict(arena: Allocator, text: []const u8) Allocator.Error!Verdict {
    var v: Verdict = .{};
    var it: Lines = .{ .text = text };
    while (it.next()) |l| {
        if (std.mem.find(u8, l.text, "COMPLETED: Installation ended successfully")) |i| {
            v = .{ .outcome = .success, .duration_s = tookSeconds(try flatEntry(arena, text, l.start + i, true)) };
        } else if (std.mem.find(u8, l.text, "FAILED: Installation ended unsuccessfully")) |i| {
            v = .{ .outcome = .failed, .duration_s = tookSeconds(try flatEntry(arena, text, l.start + i, true)) };
        } else if (std.mem.startsWith(u8, l.text, "ERROR:") and v.outcome != .failed) {
            v = .{ .outcome = .failed };
        }
    }
    return v;
}

/// A line cut to `line_limit` bytes, at a character boundary.
fn clip(line: []const u8) []const u8 {
    if (line.len <= line_limit) return line;
    var end: usize = line_limit;
    while (end > 0 and line[end] & 0xC0 == 0x80) end -= 1;
    return line[0..end];
}

/// `s` with each byte that is not part of a UTF-8 character replaced by
/// U+FFFD, as JSON text is UTF-8.
fn utf8(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (n > 0 and i + n <= s.len) if (std.unicode.utf8Decode(s[i..][0..n])) |_| {
            try out.appendSlice(arena, s[i..][0..n]);
            i += n;
            continue;
        } else |_| {};
        try out.appendSlice(arena, "\u{FFFD}");
        i += 1;
    }
    return out.items;
}

/// A copy of `s` in `arena`, as `utf8` gives it.
fn own(arena: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    const x = s orelse return null;
    return if (std.unicode.utf8ValidateSlice(x)) try arena.dupe(u8, x) else try utf8(arena, x);
}

/// The line that shows a failure's error, with the lines either side of it.
const ErrorLine = struct {
    line: usize,
    text: []const u8,
    before: []const []const u8,
    after: []const []const u8,
};

/// `l` and up to `context_lines` lines either side of it, each clipped,
/// copied out of `text`.
fn errorLine(arena: Allocator, text: []const u8, l: Line) Allocator.Error!ErrorLine {
    var before: std.ArrayList([]const u8) = .empty;
    var s = l.start;
    while (before.items.len < context_lines and s > 0) {
        const begin = if (std.mem.findScalarLast(u8, text[0 .. s - 1], '\n')) |p| p + 1 else 0;
        try before.append(arena, (try own(arena, clip(std.mem.trimEnd(u8, text[begin .. s - 1], "\r")))).?);
        s = begin;
    }
    std.mem.reverse([]const u8, before.items);
    var rest: std.ArrayList([]const u8) = .empty;
    var it: Lines = .{ .text = text, .pos = l.start };
    _ = it.next();
    while (rest.items.len < context_lines) {
        const x = it.next() orelse break;
        try rest.append(arena, (try own(arena, clip(x.text))).?);
    }
    return .{
        .line = l.no,
        .text = (try own(arena, clip(l.text))).?,
        .before = before.items,
        .after = rest.items,
    };
}

/// A failed build, as `why` reports it and `--json` prints it. Its target
/// is null for a build in the run's own directory.
const Failure = struct {
    target: ?[]const u8,
    name: []const u8,
    package: ?[]const u8,
    easyconfig: ?[]const u8,
    step: ?[]const u8,
    message: ?[]const u8,
    duration_s: ?u64,
    log: ?[]const u8,
    @"error": ?ErrorLine,
};

const Counts = struct {
    success: usize = 0,
    failed: usize = 0,
    unknown: usize = 0,

    fn add(c: *Counts, o: Outcome) void {
        switch (o) {
            .success => c.success += 1,
            .failed => c.failed += 1,
            .unknown => c.unknown += 1,
        }
    }
};

const WhyReport = struct {
    schema_version: u32 = schema_version,
    kind: []const u8 = "why",
    run: []const u8,
    run_dir: []const u8,
    counts: Counts,
    failures: []const Failure,
};

const Kind = enum { stdout, session };

const log_names = [_]struct { []const u8, Kind }{
    .{ ".stdout.log", .stdout },        .{ ".stdout.log.gz", .stdout },
    .{ ".failed.ebout.log", .session }, .{ ".failed.ebout.log.gz", .session },
};

/// Which of a build's logs a file in a target directory is, and the
/// build's NAME.
fn logOf(file: []const u8) ?struct { Kind, []const u8 } {
    for (log_names) |n| {
        if (file.len > n[0].len and std.mem.endsWith(u8, file, n[0])) return .{ n[1], file[0 .. file.len - n[0].len] };
    }
    return null;
}

/// A build a target directory has logs of: EasyBuild's output, which every
/// build has, and the session log `failed` kept for a failed one.
const Build = struct {
    name: []const u8,
    stdout: ?[]const u8 = null,
    session: ?[]const u8 = null,

    fn lessThan(_: void, a: Build, b: Build) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// The builds in a target directory, by NAME. Of a plain log and its `.gz`,
/// the plain one counts: rotate removes it only once the `.gz` is whole.
fn buildsIn(gpa: Allocator, arena: Allocator, dir: fsx.fd_t, dir_s: []const u8) Allocator.Error![]const Build {
    var map: std.StringArrayHashMapUnmanaged(Build) = .empty;
    var it = try fsx.DirIter.init(gpa, dir);
    defer it.deinit(gpa);
    while (it.next() catch |err| {
        warn("cannot read {s}: {t}", .{ dir_s, err });
        return &.{};
    }) |e| {
        const kind, const name = logOf(e.name) orelse continue;
        if ((fsx.entryType(dir, e) catch continue) != fsx.DT.REG) continue;
        const gop = try map.getOrPut(arena, try arena.dupe(u8, name));
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = gop.key_ptr.* };
        const slot = switch (kind) {
            .stdout => &gop.value_ptr.stdout,
            .session => &gop.value_ptr.session,
        };
        if (slot.* == null or (std.mem.endsWith(u8, slot.*.?, ".gz") and !std.mem.endsWith(u8, e.name, ".gz")))
            slot.* = try arena.dupe(u8, e.name);
    }
    std.mem.sort(Build, map.values(), {}, Build.lessThan);
    return map.values();
}

/// The text of one of a build's logs, or null, with a message, when it
/// cannot be read.
fn readOrWarn(gpa: Allocator, dir: fsx.fd_t, dir_s: []const u8, name: []const u8) ?[]u8 {
    return readLog(gpa, dir, name) catch |err| {
        warn("cannot read {s}/{s}: {t}", .{ dir_s, name, err });
        return null;
    };
}

/// How a build went: EasyBuild's output says; when it does not, a kept
/// session log means it failed.
fn outcomeOf(gpa: Allocator, arena: Allocator, dir: fsx.fd_t, dir_s: []const u8, b: Build) Allocator.Error!Verdict {
    var v: Verdict = .{};
    if (b.stdout) |name| if (readOrWarn(gpa, dir, dir_s, name)) |text| {
        defer gpa.free(text);
        v = try verdict(arena, text);
    };
    if (v.outcome == .unknown and b.session != null) v.outcome = .failed;
    return v;
}

/// The failure a failed build's logs record: its kept session log when it
/// has one, else EasyBuild's output.
fn failureOf(gpa: Allocator, arena: Allocator, dir: fsx.fd_t, dir_s: []const u8, target: []const u8, b: Build, v: Verdict) Allocator.Error!Failure {
    const log_name = b.session orelse b.stdout.?;
    const source: Source = if (b.session != null) .session else .stdout;
    var f: Failure = .{
        .target = if (target.len == 0) null else try utf8(arena, target),
        .name = try utf8(arena, b.name),
        .package = null,
        .easyconfig = null,
        .step = null,
        .message = null,
        .duration_s = v.duration_s,
        .log = try utf8(arena, try std.fs.path.join(arena, &.{ dir_s, log_name })),
        .@"error" = null,
    };
    const text = readOrWarn(gpa, dir, dir_s, log_name) orelse return f;
    defer gpa.free(text);
    const a = try analyze(arena, text, source);
    f.package = try own(arena, a.package);
    f.easyconfig = try own(arena, a.easyconfig);
    f.step = try own(arena, a.step);
    f.message = try own(arena, if (a.message) |m| clip(m) else null);
    f.duration_s = a.duration_s orelse v.duration_s;
    if (a.error_line) |l| f.@"error" = try errorLine(arena, text, l);
    return f;
}

/// Whether a directory name is a run's, YYYYMMDD_HHMMSS.
fn isRunName(name: []const u8) bool {
    if (name.len != 15 or name[8] != '_') return false;
    for (name, 0..) |ch, i| if (i != 8 and !std.ascii.isDigit(ch)) return false;
    return true;
}

/// The runs directly under `root`, oldest first.
fn runsIn(gpa: Allocator, arena: Allocator, root: fsx.fd_t, root_s: []const u8) Allocator.Error![]const []const u8 {
    var runs: std.ArrayList([]const u8) = .empty;
    var it = try fsx.DirIter.init(gpa, root);
    defer it.deinit(gpa);
    while (it.next() catch |err| die("cannot read ROOT {s}: {t}", .{ root_s, err })) |e| {
        if (!isRunName(e.name)) continue;
        if ((fsx.entryType(root, e) catch continue) != fsx.DT.DIR) continue;
        try runs.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, runs.items, {}, lessThan);
    return runs.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The directories a run keeps builds in: its own, as "", as `failed`
/// given the run as LOGDIR keeps them, then its target directories, by
/// name, as eb-pipeline's runs have them.
fn targetsIn(gpa: Allocator, arena: Allocator, run: fsx.fd_t, run_s: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(arena, "");
    var it = try fsx.DirIter.init(gpa, run);
    defer it.deinit(gpa);
    while (it.next() catch |err| die("cannot read RUN {s}: {t}", .{ run_s, err })) |e| {
        if (e.name[0] == '.') continue;
        if ((fsx.entryType(run, e) catch continue) != fsx.DT.DIR) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

/// A run's directory of builds `t`, the run's own when `t` is empty, with
/// its path; null, with a message, when it cannot be opened.
fn openBuilds(arena: Allocator, run: fsx.fd_t, run_s: []const u8, t: []const u8) Allocator.Error!?struct { fsx.fd_t, []const u8 } {
    const dir_s = if (t.len == 0) run_s else try std.fs.path.join(arena, &.{ run_s, t });
    const dir = fsx.openDir(run, if (t.len == 0) "." else t, false) catch |err| {
        warn("cannot open {s}: {t}", .{ dir_s, err });
        return null;
    };
    return .{ dir, dir_s };
}

/// Whether `dir/name` is a directory, not through a symbolic link.
fn isDirAt(dir: fsx.fd_t, name: []const u8) bool {
    const st = fsx.statAt(dir, name, false) catch return false;
    return st.isDir();
}

/// The value of option `name` at `args[i.*]`, given as `NAME VALUE`, which
/// moves `i` past the value, or as `NAME=VALUE`; null when `args[i.*]` is
/// not the option. A missing or empty value is refused.
fn optionValue(args: []const [:0]const u8, i: *usize, comptime name: []const u8, comptime what: []const u8) ?[]const u8 {
    const a = args[i.*];
    const v: []const u8 = if (std.mem.eql(u8, a, name)) blk: {
        if (i.* + 1 >= args.len) die(name ++ " needs " ++ what, .{});
        i.* += 1;
        break :blk args[i.*];
    } else if (std.mem.startsWith(u8, a, name ++ "=")) a[name.len + 1 ..] else return null;
    if (v.len == 0) die(name ++ " needs " ++ what, .{});
    return v;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// A duration as `48s`, `2m24s` or `1h00m05s`.
fn writeDuration(w: *std.Io.Writer, s: u64) std.Io.Writer.Error!void {
    if (s < 60) return w.print("{d}s", .{s});
    if (s < 3600) return w.print("{d}m{d:0>2}s", .{ s / 60, s % 60 });
    try w.print("{d}h{d:0>2}m{d:0>2}s", .{ s / 3600, s / 60 % 60, s % 60 });
}

fn writeFailure(w: *std.Io.Writer, f: Failure) std.Io.Writer.Error!void {
    try w.writeAll("\n");
    if (f.target) |t| try w.print("{s}/", .{t});
    try w.print("{s} failed", .{f.name});
    if (f.step) |s| try w.print(" in the {s} step", .{s}) else try w.writeAll(" before its first step");
    if (f.duration_s) |d| {
        try w.writeAll(", after ");
        try writeDuration(w, d);
    }
    try w.writeAll("\n");
    if (f.package) |p| try w.print("  package:    {s}\n", .{p});
    if (f.easyconfig) |e| try w.print("  easyconfig: {s}\n", .{e});
    if (f.message) |m| try w.print("  EasyBuild:  {s}\n", .{m});
    const e = f.@"error" orelse {
        if (f.log) |l| try w.print("  log:        {s} (no error recorded)\n", .{l});
        return;
    };
    try w.print("  log:        {s}:{d}\n", .{ f.log.?, e.line });
    var buf: [24]u8 = undefined;
    const width = (std.fmt.bufPrint(&buf, "{d}", .{e.line + e.after.len}) catch unreachable).len;
    for (e.before, 0..) |t, i| try writeContext(w, "      ", e.line - e.before.len + i, width, t);
    try writeContext(w, "    > ", e.line, width, e.text);
    for (e.after, 0..) |t, i| try writeContext(w, "      ", e.line + 1 + i, width, t);
}

fn writeContext(w: *std.Io.Writer, mark: []const u8, no: usize, width: usize, text: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}{d:>[2]} |", .{ mark, no, width });
    if (text.len > 0) try w.print(" {s}", .{text});
    try w.writeAll("\n");
}

fn writeWhy(w: *std.Io.Writer, r: WhyReport) std.Io.Writer.Error!void {
    const total = r.counts.success + r.counts.failed + r.counts.unknown;
    try w.print("{s}: {d} failed build{s} of {d}\n", .{ r.run_dir, r.counts.failed, plural(r.counts.failed), total });
    for (r.failures) |f| try writeFailure(w, f);
}

fn writeJson(w: *std.Io.Writer, r: anytype) std.Io.Writer.Error!void {
    try std.json.Stringify.value(r, .{}, w);
    try w.writeAll("\n");
}

/// Print `r` on stdout, as text or as one line of JSON.
fn emit(gpa: Allocator, r: anytype, as_json: bool, comptime writeText: fn (*std.Io.Writer, @TypeOf(r)) std.Io.Writer.Error!void) void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = if (as_json) writeJson(&out.writer, r) else writeText(&out.writer, r);
    res catch die("out of memory", .{});
    cli.put(1, out.written());
}

const why_help =
    \\eb-keep-logs why [RUN | --latest] [--target TARGET] [--root ROOT] [--json]
    \\
    \\Say why the builds of one run failed, from the logs it kept.
    \\With no RUN, the newest run under --root is read. --root defaults to
    \\the current directory. A run is a directory named YYYYMMDD_HHMMSS.
    \\--target reads only that directory of the run. --json prints one document.
    \\
;

const history_help =
    \\eb-keep-logs history PACKAGE [--target TARGET] [--root ROOT] [--json]
    \\
    \\PACKAGE is the easyconfig's name without .eb, or NAME/VERSION.
    \\--root defaults to the current directory. A run is a directory named YYYYMMDD_HHMMSS.
    \\--target reads only that directory of each run. --json prints one document.
    \\
;

fn wantsHelp(args: []const [:0]const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return true;
    }
    return false;
}

/// `why [RUN | --latest] [--target TARGET] [--root ROOT] [--json]`: print
/// why the builds of a run failed, from the logs it kept. Returns 0 once
/// its arguments are accepted, whatever it could read; a refused
/// invocation exits 2. `-h` and `--help` print what to pass and return 0.
pub fn cmdWhy(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (wantsHelp(args)) {
        cli.put(1, why_help);
        return 0;
    }
    var run_arg: ?[]const u8 = null;
    var latest = false;
    var target: ?[]const u8 = null;
    var root_arg: ?[]const u8 = null;
    var as_json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--latest")) {
            latest = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (optionValue(args, &i, "--target", "a target")) |v| {
            target = v;
        } else if (optionValue(args, &i, "--root", "a directory")) |v| {
            root_arg = v;
        } else if (a.len > 0 and a[0] == '-') {
            die("unknown option {s}", .{a});
        } else {
            if (run_arg != null) die("why takes one RUN", .{});
            run_arg = a;
        }
    }
    if (run_arg != null and latest) die("why takes RUN or --latest, not both", .{});
    if (run_arg) |r| if (r.len == 0) die("RUN must not be empty", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const oom = "out of memory";

    const root_s = root_arg orelse ".";
    const root = fsx.openDir(fsx.cwd, root_s, true) catch die("ROOT {s} is not a directory", .{root_s});
    defer sys.close(root);
    const run_name: []const u8 = run_arg orelse blk: {
        const runs = runsIn(gpa, arena, root, root_s) catch die(oom, .{});
        var k = runs.len;
        while (k > 0) {
            k -= 1;
            const t = target orelse break :blk runs[k];
            const p = std.fs.path.join(arena, &.{ runs[k], t }) catch die(oom, .{});
            if (isDirAt(root, p)) break :blk runs[k];
        }
        if (target) |t| die("no run under {s} has a target {s}", .{ root_s, t });
        die("no run under {s}", .{root_s});
    };
    const run_s = if (root_arg == null or std.fs.path.isAbsolute(run_name)) run_name else std.fs.path.join(arena, &.{ root_s, run_name }) catch die(oom, .{});
    const run = fsx.openDir(root, run_name, true) catch die("RUN {s} is not a directory", .{run_s});
    defer sys.close(run);
    var rb: [sys.path_max]u8 = undefined;
    const run_base = std.fs.path.basename(fsx.realpathFd(run, &rb) catch run_s);

    const targets: []const []const u8 = if (target) |t| blk: {
        if (!isDirAt(run, t)) die("TARGET {s} is not a directory in {s}", .{ t, run_s });
        break :blk arena.dupe([]const u8, &.{t}) catch die(oom, .{});
    } else targetsIn(gpa, arena, run, run_s) catch die(oom, .{});

    var counts: Counts = .{};
    var failures: std.ArrayList(Failure) = .empty;
    for (targets) |t| {
        const dir, const dir_s = (openBuilds(arena, run, run_s, t) catch die(oom, .{})) orelse continue;
        defer sys.close(dir);
        const builds = buildsIn(gpa, arena, dir, dir_s) catch die(oom, .{});
        for (builds) |b| {
            const v = outcomeOf(gpa, arena, dir, dir_s, b) catch die(oom, .{});
            counts.add(v.outcome);
            if (v.outcome != .failed) continue;
            const f = failureOf(gpa, arena, dir, dir_s, t, b, v) catch die(oom, .{});
            failures.append(arena, f) catch die(oom, .{});
        }
    }
    const report: WhyReport = .{
        .run = utf8(arena, run_base) catch die(oom, .{}),
        .run_dir = utf8(arena, run_s) catch die(oom, .{}),
        .counts = counts,
        .failures = failures.items,
    };
    emit(gpa, report, as_json, writeWhy);
    return 0;
}

/// A build of a package, as history lists it; its target is null for a
/// build in the run's own directory.
const Kept = struct {
    run: []const u8,
    target: ?[]const u8,
    name: []const u8,
    outcome: Outcome,
    duration_s: ?u64,
    log: []const u8,
};

const HistoryReport = struct {
    schema_version: u32 = schema_version,
    kind: []const u8 = "history",
    package: []const u8,
    root: []const u8,
    counts: Counts,
    builds: []const Kept,
};

/// Whether build NAME is one of PACKAGE's: NAME is PACKAGE, or starts with
/// PACKAGE and a dash, as `hello-2.12.1-GCCcore-14.2.0` does for hello and
/// for hello-2.12.1.
fn isBuildOf(name: []const u8, package: []const u8) bool {
    return std.mem.startsWith(u8, name, package) and (name.len == package.len or name[package.len] == '-');
}

fn durationText(buf: *[24]u8, d: ?u64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeDuration(&w, d orelse return "-") catch unreachable;
    return w.buffered();
}

fn writeRow(w: *std.Io.Writer, cells: [5][]const u8, widths: [4]usize) std.Io.Writer.Error!void {
    for (cells[0..4], widths) |c, n| try w.print("{s:<[1]}  ", .{ c, n });
    try w.print("{s}\n", .{cells[4]});
}

fn writeHistory(w: *std.Io.Writer, r: HistoryReport) std.Io.Writer.Error!void {
    const total = r.builds.len;
    try w.print("{s}: {d} build{s} under {s}", .{ r.package, total, plural(total), r.root });
    if (total > 0) try w.print(": {d} succeeded, {d} failed", .{ r.counts.success, r.counts.failed });
    if (r.counts.unknown > 0) try w.print(", {d} unknown", .{r.counts.unknown});
    try w.writeAll("\n");
    if (total == 0) return;
    const header = [5][]const u8{ "RUN", "TARGET", "OUTCOME", "DURATION", "NAME" };
    var widths: [4]usize = undefined;
    for (header[0..4], &widths) |h, *n| n.* = h.len;
    var buf: [24]u8 = undefined;
    for (r.builds) |b| {
        const target: []const u8 = b.target orelse "-";
        widths[0] = @max(widths[0], b.run.len);
        widths[1] = @max(widths[1], target.len);
        widths[2] = @max(widths[2], @tagName(b.outcome).len);
        widths[3] = @max(widths[3], durationText(&buf, b.duration_s).len);
    }
    try w.writeAll("\n");
    try writeRow(w, header, widths);
    for (r.builds) |b| try writeRow(w, .{ b.run, b.target orelse "-", @tagName(b.outcome), durationText(&buf, b.duration_s), b.name }, widths);
}

/// `history PACKAGE [--target TARGET] [--root ROOT] [--json]`: print how
/// each build of PACKAGE kept under ROOT went, oldest run first. Returns 0
/// once its arguments are accepted, whatever it could read; a refused
/// invocation exits 2.
pub fn cmdHistory(gpa: Allocator, args: []const [:0]const u8) u8 {
    if (wantsHelp(args)) {
        cli.put(1, history_help);
        return 0;
    }
    var package_arg: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var root_arg: ?[]const u8 = null;
    var as_json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            as_json = true;
        } else if (optionValue(args, &i, "--target", "a target")) |v| {
            target = v;
        } else if (optionValue(args, &i, "--root", "a directory")) |v| {
            root_arg = v;
        } else if (a.len > 0 and a[0] == '-') {
            die("unknown option {s}", .{a});
        } else {
            if (package_arg != null) die("history takes one PACKAGE", .{});
            package_arg = a;
        }
    }
    const package_s = package_arg orelse die("history needs PACKAGE", .{});
    if (package_s.len == 0) die("PACKAGE must not be empty", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const oom = "out of memory";
    // A module name, NAME/VERSION, is the easyconfig's NAME-VERSION.
    const package = arena.dupe(u8, package_s) catch die(oom, .{});
    std.mem.replaceScalar(u8, package, '/', '-');

    const root_s = root_arg orelse ".";
    const root = fsx.openDir(fsx.cwd, root_s, true) catch die("ROOT {s} is not a directory", .{root_s});
    defer sys.close(root);
    var counts: Counts = .{};
    var kept: std.ArrayList(Kept) = .empty;
    const runs = runsIn(gpa, arena, root, root_s) catch die(oom, .{});
    for (runs) |r| {
        const run_s = std.fs.path.join(arena, &.{ root_s, r }) catch die(oom, .{});
        const run = fsx.openDir(root, r, false) catch |err| {
            warn("cannot open {s}: {t}", .{ run_s, err });
            continue;
        };
        defer sys.close(run);
        const targets: []const []const u8 = if (target) |t|
            (if (isDirAt(run, t)) arena.dupe([]const u8, &.{t}) catch die(oom, .{}) else &.{})
        else
            targetsIn(gpa, arena, run, run_s) catch die(oom, .{});
        for (targets) |t| {
            const dir, const dir_s = (openBuilds(arena, run, run_s, t) catch die(oom, .{})) orelse continue;
            defer sys.close(dir);
            const builds = buildsIn(gpa, arena, dir, dir_s) catch die(oom, .{});
            for (builds) |b| {
                if (!isBuildOf(b.name, package)) continue;
                const v = outcomeOf(gpa, arena, dir, dir_s, b) catch die(oom, .{});
                counts.add(v.outcome);
                const log = std.fs.path.join(arena, &.{ dir_s, b.stdout orelse b.session.? }) catch die(oom, .{});
                kept.append(arena, .{
                    .run = r,
                    .target = if (t.len == 0) null else utf8(arena, t) catch die(oom, .{}),
                    .name = utf8(arena, b.name) catch die(oom, .{}),
                    .outcome = v.outcome,
                    .duration_s = v.duration_s,
                    .log = utf8(arena, log) catch die(oom, .{}),
                }) catch die(oom, .{});
            }
        }
    }
    const report: HistoryReport = .{
        .package = utf8(arena, package_s) catch die(oom, .{}),
        .root = utf8(arena, root_s) catch die(oom, .{}),
        .counts = counts,
        .builds = kept.items,
    };
    emit(gpa, report, as_json, writeHistory);
    return 0;
}

const testing = std.testing;

test "isCompilerOrLinkerError: a compiler's error at a source line, a linker's error" {
    for ([_][]const u8{
        "src/hello.c:149:18: error: 'site_greeting' undeclared (first use in this function)",
        "hello.c:12: error: expected ';' before '}' token",
        "src/x.c:1:10: fatal error: greet.h: No such file or directory",
        "kernel.cu(12): error: identifier \"x\" is undefined",
        "hello.c:(.text.startup+0x4a): undefined reference to `site_greeting'",
        "/usr/bin/ld: cannot find -lgreet: No such file or directory",
        "ld.lld: error: undefined symbol: site_greeting",
    }) |l| try testing.expect(isCompilerOrLinkerError(l));
    for ([_][]const u8{
        "configure: error: C compiler cannot create executables",
        "collect2: error: ld returned 1 exit status",
        "cc1: error: bad value 'nosuchcpu' for '-march=' switch",
        "src/hello.c:149:18: warning: unused variable 'x'",
        "make: *** [Makefile:1899: all] Error 2",
        "Hunk #1 FAILED at 65.",
        "FAIL: tests/hello-1",
        "== 2026-11-17 04:09:25,758 build_log.py:233 ERROR EasyBuild encountered an error: shell command 'make ...' failed",
        ":12: error: no file before the line",
        "x.c(): error: no line",
    }) |l| try testing.expect(!isCompilerOrLinkerError(l));
}

test "stepStarted and stepNamed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const none: ?[]const u8 = null;
    try testing.expectEqualStrings("sanitycheck", (try stepStarted(arena, "== 2026-11-17 04:17:53,833 easyblock.py:5068 INFO Starting sanitycheck step")).?);
    try testing.expectEqual(none, try stepStarted(arena, "Starting  step"));
    try testing.expectEqual(none, try stepStarted(arena, "Restarting build step"));
    try testing.expectEqual(none, try stepStarted(arena, "Starting build steps"));
    try testing.expectEqualStrings("fetch", (try stepStarted(arena, "== fetching files and verifying checksums...")).?);
    try testing.expectEqualStrings("sanitycheck", (try stepStarted(arena, "\x1b[1m== sanity checking...\x1b[0m")).?);
    try testing.expectEqualStrings("postiter", (try stepStarted(arena, "== restore after iterating...")).?);
    try testing.expectEqualStrings("test", (try stepStarted(arena, "== testing...")).?);
    try testing.expectEqualStrings("testcases", (try stepStarted(arena, "== running test cases...")).?);
    try testing.expectEqual(none, try stepStarted(arena, "== resolving dependencies ..."));
    try testing.expectEqual(none, try stepStarted(arena, "== building and installing hello/2.12.1-GCCcore-14.2.0..."));
    try testing.expectEqual(none, try stepStarted(arena, "== configuring [skipped]"));
    try testing.expectEqual(none, try stepStarted(arena, "== ... (took 2 mins 11 secs)"));
    try testing.expectEqualStrings("build", stepNamed("shell command 'make ...' failed with exit code 2 in build step for x.eb").?);
    try testing.expectEqualStrings("test", stepNamed("x in test step, y in install step").?);
    try testing.expectEqual(@as(?[]const u8, null), stepNamed("Checksum verification for x failed."));
}

test "tookSeconds reads EasyBuild's durations" {
    try testing.expectEqual(@as(?u64, 0), tookSeconds("x (took < 1 sec)"));
    try testing.expectEqual(@as(?u64, 48), tookSeconds("x (took 48 secs)"));
    try testing.expectEqual(@as(?u64, 144), tookSeconds("x (took 2 mins 24 secs)"));
    try testing.expectEqual(@as(?u64, 60), tookSeconds("x (took 1 min 0 secs)"));
    try testing.expectEqual(@as(?u64, 3605), tookSeconds("x (took 1 hour 0 mins 5 secs)"));
    try testing.expectEqual(@as(?u64, 7), tookSeconds("(took 9 secs) then (took 7 secs)"));
    try testing.expectEqual(@as(?u64, null), tookSeconds("x (took a while)"));
    try testing.expectEqual(@as(?u64, null), tookSeconds("x (took 3"));
    try testing.expectEqual(@as(?u64, null), tookSeconds("x"));
}

test "analyze: a compile error inside the failed command's output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const log =
        \\== 2026-11-17 04:06:19,242 build_log.py:330 INFO processing EasyBuild easyconfig /ec/hello-2.12.1.eb
        \\== 2026-11-17 04:06:19,250 build_log.py:330 INFO building and installing hello/2.12.1...
        \\== 2026-11-17 04:07:13,523 easyblock.py:5068 INFO Starting configure step
        \\conftest.c:1:10: fatal error: an earlier step's
        \\== 2026-11-17 04:09:25,312 easyblock.py:5068 INFO Starting build step
        \\== 2026-11-17 04:09:25,709 run.py:652 WARNING Shell command FAILED (exit code 2)
        \\Output (stdout + stderr):
        \\src/hello.c:149:18: error: 'site_greeting' undeclared
        \\collect2: error: ld returned 1 exit status
        \\== 2026-11-17 04:09:25,758 build_log.py:233 ERROR EasyBuild encountered an error: shell command 'make ...' failed with exit code 2 in build step for hello-2.12.1.eb (at easybuild/framework/easyblock.py:5266 in run_all_steps)
        \\== 2026-11-17 04:09:25,759 build_log.py:330 INFO FAILED: Installation ended unsuccessfully: shell command 'make ...' failed with exit code 2 in build step for hello-2.12.1.eb (took 3 mins 6 secs)
        \\
    ;
    const a = try analyze(arena_state.allocator(), log, .session);
    try testing.expectEqualStrings("hello/2.12.1", a.package.?);
    try testing.expectEqualStrings("/ec/hello-2.12.1.eb", a.easyconfig.?);
    try testing.expectEqualStrings("build", a.step.?);
    try testing.expect(a.failed);
    try testing.expectEqualStrings("shell command 'make ...' failed with exit code 2 in build step for hello-2.12.1.eb", a.message.?);
    try testing.expectEqual(@as(?u64, 186), a.duration_s);
    try testing.expectEqual(@as(usize, 8), a.error_line.?.no);
}

test "analyze: without a compiler or linker error, EasyBuild's error line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const log =
        \\== 2026-11-17 03:58:44,474 easyblock.py:5068 INFO Starting fetch step
        \\== 2026-11-17 03:59:32,688 build_log.py:465 WARNING Failed to download recent config.guess to /s/config.guess
        \\== 2026-11-17 03:59:32,778 build_log.py:233 ERROR EasyBuild encountered an error: Checksum verification for /s/hello-2.12.1.tar.gz using cf04 failed. (at easybuild/framework/easyblock.py:2747 in checksum_step)
        \\== 2026-11-17 03:59:32,779 build_log.py:330 INFO FAILED: Installation ended unsuccessfully: Checksum verification for /s/hello-2.12.1.tar.gz using cf04 failed. (took 48 secs)
    ;
    const a = try analyze(arena_state.allocator(), log, .session);
    try testing.expectEqualStrings("fetch", a.step.?);
    try testing.expectEqualStrings("Checksum verification for /s/hello-2.12.1.tar.gz using cf04 failed.", a.message.?);
    try testing.expectEqual(@as(usize, 3), a.error_line.?.no);
    try testing.expectEqual(@as(?u64, 48), a.duration_s);
}

test "analyze: a test failure, a robot failure, a log that ends in a step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tests =
        \\== 2026-11-17 04:14:58,628 easyblock.py:5068 INFO Starting test step
        \\== 2026-11-17 04:14:59,165 run.py:652 WARNING Shell command FAILED (exit code 2)
        \\PASS: tests/atexit-1
        \\FAIL: tests/hello-1
        \\# FAIL:  1
        \\make: *** [Makefile:2997: check] Error 2
        \\== 2026-11-17 04:14:59,217 build_log.py:233 ERROR EasyBuild encountered an error: shell command 'make ...' failed in test step for hello-2.12.1.eb (at easybuild/framework/easyblock.py:2829 in report_test_failure)
    ;
    var a = try analyze(arena, tests, .session);
    try testing.expectEqualStrings("test", a.step.?);
    try testing.expectEqual(@as(usize, 7), a.error_line.?.no);
    try testing.expectEqual(@as(?u64, null), a.duration_s);

    const robot =
        \\== 2026-11-17 04:01:20,687 pyheaderconfigobj.py:259 DEBUG pyheader parsed cfg: {'copyright': Copyright (c) 2001 Python Software Foundation.
        \\All Rights Reserved., 'msg': 'x.c:1: error: in a dump'}
        \\== 2026-11-17 04:01:21,521 build_log.py:330 INFO resolving dependencies ...
        \\== 2026-11-17 04:01:22,080 build_log.py:233 ERROR EasyBuild encountered an error: Missing dependencies: libgreet/1.0 (no easyconfig file or existing module found) (at easybuild/tools/robot.py:352 in raise_error_missing_deps)
    ;
    a = try analyze(arena, robot, .session);
    try testing.expectEqual(@as(?[]const u8, null), a.step);
    try testing.expectEqualStrings("Missing dependencies: libgreet/1.0 (no easyconfig file or existing module found)", a.message.?);
    try testing.expectEqual(@as(usize, 4), a.error_line.?.no);

    a = try analyze(arena, "== 2026-11-17 04:09:25,312 easyblock.py:5068 INFO Starting build step\ngcc -c x.c\n", .session);
    try testing.expectEqualStrings("build", a.step.?);
    try testing.expect(!a.failed);
    try testing.expectEqual(@as(?Line, null), a.error_line);
}

test "analyze: EasyBuild's output, wrapped at 80 columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out =
        \\== building...
        \\
        \\ERROR: Shell command failed!
        \\== FAILED: Installation ended unsuccessfully: shell command 'make ...' failed
        \\with exit code 2 in build step for hello-2.12.1-GCCcore-14.2.0.eb (took 3 mins 6
        \\secs)
        \\== Results of the build can be found in the log file(s)
    ;
    var a = try analyze(arena_state.allocator(), out, .stdout);
    try testing.expectEqualStrings("build", a.step.?);
    try testing.expectEqualStrings("shell command 'make ...' failed with exit code 2 in build step for hello-2.12.1-GCCcore-14.2.0.eb", a.message.?);
    try testing.expectEqual(@as(?u64, 186), a.duration_s);
    try testing.expectEqual(@as(usize, 4), a.error_line.?.no);

    const sanity =
        \\== sanity checking...
        \\  >> file 'lib/libhello.a' found: FAILED
        \\== ... (took 4 secs)
        \\== FAILED: Installation ended unsuccessfully: Sanity check failed: no file found
        \\at 'lib/libhello.a' in 
        \\/home/alice/eessi/versions/2025.06/software/linux/x86_64/intel/sapphirerapids/so
        \\ftware/hello/2.12.1-GCCcore-13.3.0 (took 2 mins 54 secs)
        \\== Results of the build can be found in the log file(s) 
    ;
    a = try analyze(arena_state.allocator(), sanity, .stdout);
    try testing.expectEqualStrings("sanitycheck", a.step.?);
    try testing.expectEqualStrings("Sanity check failed: no file found at 'lib/libhello.a' in /home/alice/eessi/versions/2025.06/software/linux/x86_64/intel/sapphirerapids/software/hello/2.12.1-GCCcore-13.3.0", a.message.?);
    try testing.expectEqual(@as(?u64, 174), a.duration_s);
    try testing.expectEqual(@as(usize, 4), a.error_line.?.no);

    const robot =
        \\== resolving dependencies ...
        \\ERROR: Missing dependencies: libgreet/1.0 (no easyconfig file or existing module found)
        \\x.c:1: error: printed after the report
    ;
    a = try analyze(arena_state.allocator(), robot, .stdout);
    try testing.expect(a.failed);
    try testing.expectEqual(@as(?[]const u8, null), a.step);
    try testing.expectEqualStrings("Missing dependencies: libgreet/1.0 (no easyconfig file or existing module found)", a.message.?);
    try testing.expectEqual(@as(usize, 2), a.error_line.?.no);
}

test "verdict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var v = try verdict(arena, "== COMPLETED: Installation ended successfully (took 2 mins 52 secs)\n== Build succeeded for 1 out of 1\n");
    try testing.expectEqual(Outcome.success, v.outcome);
    try testing.expectEqual(@as(?u64, 172), v.duration_s);
    v = try verdict(arena, "== COMPLETED: Installation ended successfully (took 5 secs)\n== FAILED: Installation ended unsuccessfully: x failed in\nbuild step (took 1 min 1\nsecs)\nERROR: Installation of x.eb failed\n");
    try testing.expectEqual(Outcome.failed, v.outcome);
    try testing.expectEqual(@as(?u64, 61), v.duration_s);
    v = try verdict(arena, "== resolving dependencies ...\n\nERROR: Missing dependencies: libgreet/1.0\n");
    try testing.expectEqual(Outcome.failed, v.outcome);
    try testing.expectEqual(@as(?u64, null), v.duration_s);
    v = try verdict(arena, "== building...\n");
    try testing.expectEqual(Outcome.unknown, v.outcome);
}

test "gunzip reads what gzip wrote, and refuses what it did not" {
    const gpa = testing.allocator;
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    for (0..20000) |i| try plain.print(gpa, "== line {d} of a log that repeats itself\n", .{i % 700});
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer aw.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&aw.writer, window, .gzip, .best);
    try c.writer.writeAll(plain.items);
    try c.finish();
    const got = try gunzip(gpa, aw.written());
    defer gpa.free(got);
    try testing.expectEqualStrings(plain.items, got);

    const twice = try std.mem.concat(gpa, u8, &.{ aw.written(), aw.written() });
    defer gpa.free(twice);
    const both = try gunzip(gpa, twice);
    defer gpa.free(both);
    try testing.expectEqual(2 * plain.items.len, both.len);
    try testing.expectEqualStrings(plain.items, both[plain.items.len..]);

    var bad = try gpa.dupe(u8, aw.written());
    defer gpa.free(bad);
    bad[bad.len - 6] ^= 0xff;
    try testing.expectError(error.BadGzip, gunzip(gpa, bad));
    try testing.expectError(error.BadGzip, gunzip(gpa, aw.written()[0 .. aw.written().len / 2]));
    try testing.expectError(error.BadGzip, gunzip(gpa, "not gzip at all"));
}

test "clip and utf8" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var long: [601]u8 = undefined;
    long[0] = 'x';
    for (0..300) |i| @memcpy(long[1 + 2 * i ..][0..2], "\u{e9}");
    try testing.expectEqual(@as(usize, 400), clip(long[1..]).len);
    try testing.expectEqual(@as(usize, 399), clip(&long).len);
    try testing.expectEqualStrings("a\u{FFFD}b\u{e9}", try utf8(arena, "a\xffb\u{e9}"));
    try testing.expectEqualStrings("\u{FFFD}(\u{FFFD}\u{FFFD}\u{FFFD}", try utf8(arena, "\xc3(\xed\xa0\x80"));
}

test "logOf and isRunName" {
    const k, const n = logOf("hello-2.12.1-GCCcore-14.2.0.failed.ebout.log.gz").?;
    try testing.expectEqual(Kind.session, k);
    try testing.expectEqualStrings("hello-2.12.1-GCCcore-14.2.0", n);
    try testing.expectEqual(Kind.stdout, logOf("a.stdout.log").?[0]);
    try testing.expect(logOf(".stdout.log") == null);
    try testing.expect(logOf("a.keep-logs.log") == null);
    try testing.expect(isRunName("20261117_040615"));
    try testing.expect(!isRunName("20261117-040615"));
    try testing.expect(!isRunName("2026111_0406150"));
}

test "isBuildOf takes a name or its start up to a dash" {
    const name = "hello-2.12.1-GCCcore-14.2.0";
    try testing.expect(isBuildOf(name, "hello"));
    try testing.expect(isBuildOf(name, "hello-2.12.1"));
    try testing.expect(isBuildOf(name, name));
    try testing.expect(!isBuildOf(name, "hell"));
    try testing.expect(!isBuildOf(name, "hello-2.12"));
    try testing.expect(isBuildOf("hello-world-1.0", "hello"));
}
