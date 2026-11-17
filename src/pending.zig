//! `pending`: what an EasyBuild dry-run or missing-modules report still builds.
//!
//! EasyBuild already resolved the dependencies. This reads the report it
//! printed. It does not run eb, and it does not resolve anything itself.
//!
//! A dry-run line is `* [ ] PATH (module: NAME)`, and `[F]` and `[R]` still
//! build. `[x]` is already installed. `--terse` prints `x PATH` or `- PATH`.
//! A missing-modules line is `* NAME (FILE.eb)`, or with `--terse` one
//! easyconfig path per line.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
const read_limit: usize = 64 * 1024 * 1024;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

fn readLog(gpa: Allocator, path: []const u8) ?[]u8 {
    const opened = fsx.openRegular(fsx.cwd, path, false) catch |err| {
        warn("cannot read {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
    defer sys.close(opened.fd);
    return fsx.readAll(gpa, opened.fd, read_limit) catch |err| {
        warn("cannot read {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

const Mark = struct { build: bool, name: []const u8 };

fn moduleLine(line: []const u8) ?Mark {
    const key = "(module:";
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    var name = std.mem.trim(u8, line[at + key.len ..], " \t");
    if (std.mem.endsWith(u8, name, ")")) name = name[0 .. name.len - 1];
    name = std.mem.trim(u8, name, " \t");
    if (name.len == 0) return null;
    const build = std.mem.indexOf(u8, line, "[ ]") != null or
        std.mem.indexOf(u8, line, "[F]") != null or
        std.mem.indexOf(u8, line, "[R]") != null;
    const known = build or std.mem.indexOf(u8, line, "[x]") != null;
    if (!known) return null;
    return .{ .build = build, .name = name };
}

fn missingLine(line: []const u8) ?[]const u8 {
    const text = trim(line);
    if (!std.mem.startsWith(u8, text, "*")) return null;
    const rest = trim(text[1..]);
    if (std.mem.indexOf(u8, rest, "(module:") != null) return null;
    const open = std.mem.indexOf(u8, rest, " (") orelse return null;
    const name = rest[0..open];
    const tail = rest[open + 2 ..];
    if (name.len == 0 or !std.mem.endsWith(u8, tail, ".eb)")) return null;
    return name;
}

fn terseLine(line: []const u8) ?Mark {
    const text = trim(line);
    if (text.len < 4 or text[1] != ' ') return null;
    const status = text[0];
    if (status != 'x' and status != '-' and status != 'F' and status != 'R') return null;
    const path = text[2..];
    if (!std.mem.endsWith(u8, path, ".eb")) return null;
    if (std.mem.indexOfScalar(u8, path, ' ') != null) return null;
    return .{ .build = status != 'x', .name = path };
}

fn barePath(line: []const u8) ?[]const u8 {
    const text = trim(line);
    if (text.len == 0 or std.mem.startsWith(u8, text, "==")) return null;
    if (std.mem.indexOfScalar(u8, text, ' ') != null) return null;
    if (!std.mem.endsWith(u8, text, ".eb")) return null;
    return text;
}

/// Lines still to build. `nothing to build` when the report has none.
/// `error.NotAReport` when the text is neither shape.
pub fn formatPending(gpa: Allocator, text: []const u8) (Allocator.Error || error{NotAReport})![]u8 {
    var modules: usize = 0;
    var terse: usize = 0;
    var missing: usize = 0;
    var bare: usize = 0;
    var other: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or std.mem.startsWith(u8, line, "==")) continue;
        if (moduleLine(line) != null) {
            modules += 1;
        } else if (terseLine(line) != null) {
            terse += 1;
        } else if (missingLine(line) != null) {
            missing += 1;
        } else if (barePath(line) != null) {
            bare += 1;
        } else other += 1;
    }
    const mode: enum { module, terse, missing, bare } = if (modules > 0)
        .module
    else if (terse > 0)
        .terse
    else if (missing > 0)
        .missing
    else if (bare > 0 and other == 0)
        .bare
    else
        return error.NotAReport;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        switch (mode) {
            .module => if (moduleLine(line)) |mark| {
                if (!mark.build) continue;
                try out.print(gpa, "build {s}\n", .{mark.name});
                n += 1;
            },
            .terse => if (terseLine(line)) |mark| {
                if (!mark.build) continue;
                try out.print(gpa, "build {s}\n", .{mark.name});
                n += 1;
            },
            .missing => if (missingLine(line)) |name| {
                try out.print(gpa, "missing {s}\n", .{name});
                n += 1;
            },
            .bare => if (barePath(line)) |path| {
                try out.print(gpa, "missing {s}\n", .{path});
                n += 1;
            },
        }
    }
    if (n == 0) try out.appendSlice(gpa, "nothing to build\n");
    return try out.toOwnedSlice(gpa);
}

/// `pending FILE`.
pub fn cmdPending(gpa: Allocator, args: []const []const u8) u8 {
    var path: []const u8 = "";
    for (args) |a| {
        if (a.len > 0 and a[0] == '-') die("pending does not know '{s}'", .{a});
        if (path.len != 0) die("pending does not know '{s}'", .{a});
        path = a;
    }
    if (path.len == 0) die("pending needs a report", .{});
    const text = readLog(gpa, path) orelse return 2;
    defer gpa.free(text);
    const body = formatPending(gpa, text) catch |err| switch (err) {
        error.NotAReport => {
            warn("pending: {s} is not a dry-run or missing-modules report", .{path});
            return 2;
        },
        error.OutOfMemory => die("out of memory", .{}),
    };
    defer gpa.free(body);
    cli.out("{s}", .{body});
    return 0;
}

test "a dry-run keeps what would be built and skips what is installed" {
    const text =
        \\ * [x] $CFGS/z/zlib/zlib-1.2.12.eb (module: zlib/1.2.12)
        \\ * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: flex/2.6.4)
        \\ * [R] $CFGS/g/GCC/GCC-13.2.0.eb (module: GCC/13.2.0)
    ;
    const got = try formatPending(std.testing.allocator, text);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("build flex/2.6.4\nbuild GCC/13.2.0\n", got);
    const present = try formatPending(std.testing.allocator, " * [x] a.eb (module: zlib/1.2.12)\n");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("nothing to build\n", present);
}

test "a missing-modules report names the modules, and prose is not one" {
    const text =
        \\2 out of 2 required modules missing:
        \\
        \\* flex/2.6.4 (flex-2.6.4.eb)
    ;
    const got = try formatPending(std.testing.allocator, text);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("missing flex/2.6.4\n", got);
    try std.testing.expectError(error.NotAReport, formatPending(std.testing.allocator, "hello\n"));
}
