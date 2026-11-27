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
const utf8_text = @import("utf8_text.zig");
const cli_parse = @import("cli_parse.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
/// The `schema_version` of what `--json` prints.
pub const schema_version: u32 = 1;
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

const ReportMode = enum { module, terse, missing, bare };

const JsonEntry = struct {
    action: []const u8,
    name: []const u8,
};

const JsonReport = struct {
    schema_version: u32 = schema_version,
    kind: []const u8 = "pending",
    entries: []const JsonEntry,
};

fn reportMode(text: []const u8) error{NotAReport}!ReportMode {
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
    return if (modules > 0)
        .module
    else if (terse > 0)
        .terse
    else if (missing > 0)
        .missing
    else if (bare > 0 and other == 0)
        .bare
    else
        error.NotAReport;
}

fn collectEntries(gpa: Allocator, text: []const u8, mode: ReportMode) Allocator.Error![]JsonEntry {
    var entries: std.ArrayList(JsonEntry) = .empty;
    errdefer entries.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        switch (mode) {
            .module => if (moduleLine(line)) |mark| {
                if (!mark.build) continue;
                try entries.append(gpa, .{ .action = "build", .name = try utf8_text.utf8(gpa, mark.name) });
            },
            .terse => if (terseLine(line)) |mark| {
                if (!mark.build) continue;
                try entries.append(gpa, .{ .action = "build", .name = try utf8_text.utf8(gpa, mark.name) });
            },
            .missing => if (missingLine(line)) |name| {
                try entries.append(gpa, .{ .action = "missing", .name = try utf8_text.utf8(gpa, name) });
            },
            .bare => if (barePath(line)) |path| {
                try entries.append(gpa, .{ .action = "missing", .name = try utf8_text.utf8(gpa, path) });
            },
        }
    }
    return try entries.toOwnedSlice(gpa);
}

pub fn formatJson(gpa: Allocator, items: []const JsonEntry) ![]u8 {
    const report: JsonReport = .{ .entries = items };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

/// Lines still to build. `nothing to build` when the report has none.
/// `error.NotAReport` when the text is neither shape.
pub fn formatPending(gpa: Allocator, text: []const u8) (Allocator.Error || error{NotAReport})![]u8 {
    const mode = try reportMode(text);
    const items = try collectEntries(gpa, text, mode);
    defer gpa.free(items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (items) |e| try out.print(gpa, "{s} {s}\n", .{ e.action, e.name });
    if (items.len == 0) try out.appendSlice(gpa, "nothing to build\n");
    return try out.toOwnedSlice(gpa);
}

const pending_cli = cli_parse.make(.{
    .prog = "pending",
    .options = &.{cli_parse.flag("json")},
    .positionals = &.{cli_parse.one("FILE", true)},
    .missing = &.{
        .{ .name = "FILE", .msg = "pending needs a report" },
    },
});

/// `pending [--json] FILE`.
pub fn cmdPending(gpa: Allocator, args: []const []const u8) u8 {
    var parsed = pending_cli.take(gpa, args);
    defer parsed.deinit(gpa);
    const json_out = parsed.seen("json");
    const path = parsed.positional(0).?;
    const text = readLog(gpa, path) orelse return 2;
    defer gpa.free(text);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = if (json_out) blk: {
        const mode = reportMode(text) catch |err| switch (err) {
            error.NotAReport => {
                warn("pending: {s} is not a dry-run or missing-modules report", .{path});
                return 2;
            },
        };
        const items = collectEntries(arena, text, mode) catch die("out of memory", .{});
        break :blk formatJson(arena, items) catch die("out of memory", .{});
    } else blk: {
        break :blk formatPending(arena, text) catch |err| switch (err) {
            error.NotAReport => {
                warn("pending: {s} is not a dry-run or missing-modules report", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
    };
    cli.out("{s}", .{body});
    return 0;
}

test "a module name with a bad byte is replaced, not leaked raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = " * [ ] $CFGS/f/flex/flex-2.6.4.eb (module: fl\xffex/2.6.4)\n";
    const got = try formatPending(arena.allocator(), text);
    try std.testing.expectEqualStrings("build fl\u{FFFD}ex/2.6.4\n", got);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}
