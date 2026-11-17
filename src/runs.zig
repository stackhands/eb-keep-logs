//! `runs`: who ran an executable, from XALT run records.
//!
//! A run record is one JSON object. `userT` holds `user`, `exec_path`, and
//! when XALT wrote them `syshost` and `start_time`. A link record has
//! `resultT` and no `userT`; it is not a run. The file may hold several
//! objects, one after another. This does not record runs and does not open
//! a database.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;

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

/// `query` is the whole `exec_path`, or only its last component.
pub fn execMatches(path: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, path, query)) return true;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    return std.mem.eql(u8, path[slash + 1 ..], query);
}

pub const Object = struct { slice: []const u8, end: usize };

/// The next concatenated JSON object in `text`.
pub fn nextObject(text: []const u8, start: usize) error{BadJson}!?Object {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    if (i >= text.len) return null;
    if (text[i] != '{') return error.BadJson;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    const begin = i;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            if (c == '\\') {
                escape = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return .{ .slice = text[begin .. i + 1], .end = i + 1 };
        }
    }
    return error.BadJson;
}

fn appendScalar(out: *std.ArrayList(u8), gpa: Allocator, value: std.json.Value) Allocator.Error!void {
    switch (value) {
        .string => |s| try out.appendSlice(gpa, s),
        .number_string => |s| try out.appendSlice(gpa, s),
        .integer => |n| try out.print(gpa, "{d}", .{n}),
        .float => |n| try out.print(gpa, "{d}", .{n}),
        else => {},
    }
}

fn scalarText(buf: *std.ArrayList(u8), gpa: Allocator, value: std.json.Value) Allocator.Error![]const u8 {
    const start = buf.items.len;
    try appendScalar(buf, gpa, value);
    return buf.items[start..];
}

const JsonRun = struct {
    user: []const u8,
    host: []const u8,
    time: []const u8,
    path: []const u8,
};

const JsonReport = struct {
    schema_version: u32 = schema_version,
    kind: []const u8 = "runs",
    exec: []const u8,
    runs: []const JsonRun,
};

fn collectRuns(gpa: Allocator, text: []const u8, exec: []const u8) (Allocator.Error || error{BadJson})![]JsonRun {
    var runs: std.ArrayList(JsonRun) = .empty;
    errdefer runs.deinit(gpa);
    var scratch: std.ArrayList(u8) = .empty;
    errdefer scratch.deinit(gpa);
    var at: usize = 0;
    while (try nextObject(text, at)) |item| {
        at = item.end;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, item.slice, .{}) catch return error.BadJson;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => continue,
        };
        const user_t_value = root.getPtr("userT") orelse continue;
        const user_t = switch (user_t_value.*) {
            .object => |obj| obj,
            else => continue,
        };
        const user_value = user_t.getPtr("user") orelse continue;
        const path_value = user_t.getPtr("exec_path") orelse continue;
        const user = switch (user_value.*) {
            .string => |s| s,
            else => continue,
        };
        const path = switch (path_value.*) {
            .string => |s| s,
            else => continue,
        };
        if (!execMatches(path, exec)) continue;
        const host = blk: {
            if (user_t.getPtr("syshost")) |h| {
                if (h.* == .string) break :blk try gpa.dupe(u8, h.string);
            }
            break :blk try gpa.dupe(u8, "");
        };
        const when = blk: {
            if (user_t.getPtr("start_time")) |t| {
                const slice = try scalarText(&scratch, gpa, t.*);
                break :blk try gpa.dupe(u8, slice);
            }
            break :blk try gpa.dupe(u8, "");
        };
        try runs.append(gpa, .{
            .user = try gpa.dupe(u8, user),
            .host = host,
            .time = when,
            .path = try gpa.dupe(u8, path),
        });
    }
    return try runs.toOwnedSlice(gpa);
}

pub fn formatJson(gpa: Allocator, exec: []const u8, items: []const JsonRun) ![]u8 {
    const report: JsonReport = .{ .exec = exec, .runs = items };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

/// The runs of `exec` in `text`, one line each, in file order. No run is
/// the line `no run of PATH`.
pub fn formatRuns(gpa: Allocator, text: []const u8, exec: []const u8) (Allocator.Error || error{BadJson})![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try collectRuns(arena.allocator(), text, exec);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (items) |row| {
        try out.appendSlice(gpa, "user=");
        try out.appendSlice(gpa, row.user);
        try out.appendSlice(gpa, " host=");
        try out.appendSlice(gpa, row.host);
        try out.appendSlice(gpa, " time=");
        try out.appendSlice(gpa, row.time);
        try out.appendSlice(gpa, " path=");
        try out.appendSlice(gpa, row.path);
        try out.append(gpa, '\n');
    }
    if (items.len == 0) try out.print(gpa, "no run of {s}\n", .{exec});
    return try out.toOwnedSlice(gpa);
}

/// `runs --exec PATH [--json] FILE`.
pub fn cmdRuns(gpa: Allocator, args: []const []const u8) u8 {
    var exec: []const u8 = "";
    var json_out = false;
    var path: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            json_out = true;
        } else if (std.mem.eql(u8, a, "--exec") or std.mem.startsWith(u8, a, "--exec=")) {
            const v = if (std.mem.startsWith(u8, a, "--exec="))
                a["--exec=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) die("runs needs --exec", .{});
                break :blk args[i];
            };
            if (v.len == 0 or v[0] == '-') die("runs needs --exec", .{});
            exec = v;
        } else if (a.len > 0 and a[0] == '-') {
            die("runs does not know '{s}'", .{a});
        } else if (path.len == 0) {
            path = a;
        } else {
            die("runs does not know '{s}'", .{a});
        }
    }
    if (exec.len == 0) die("runs needs --exec", .{});
    if (path.len == 0) die("runs needs a record file", .{});
    const text = readLog(gpa, path) orelse return 2;
    defer gpa.free(text);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scan = arena.allocator();
    const body = if (json_out) blk: {
        const items = collectRuns(scan, text, exec) catch |err| switch (err) {
            error.BadJson => {
                warn("runs: {s} is not XALT run JSON", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
        break :blk formatJson(gpa, exec, items) catch die("out of memory", .{});
    } else blk: {
        break :blk formatRuns(gpa, text, exec) catch |err| switch (err) {
            error.BadJson => {
                warn("runs: {s} is not XALT run JSON", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
    };
    defer gpa.free(body);
    cli.out("{s}", .{body});
    return 0;
}

test "a full path and its last component match, and a longer name does not" {
    try std.testing.expect(execMatches("/opt/site/bin/gmx", "/opt/site/bin/gmx"));
    try std.testing.expect(execMatches("/opt/site/bin/gmx", "gmx"));
    try std.testing.expect(!execMatches("/opt/site/bin/gmx", "gm"));
    try std.testing.expect(!execMatches("/opt/site/bin/gmx", "bin/gmx"));
}

test "a link record is not a run, and runs stay in file order" {
    const text =
        \\{"userT":{"user":"ada","exec_path":"/opt/site/bin/gmx","syshost":"login01","start_time":"1428767000.5"}}
        \\{"resultT":{"exec_path":"/opt/site/bin/gmx","build_user":"ada"}}
        \\{"userT":{"user":"bea","exec_path":"/other/gmx","syshost":"n2","start_time":3}}
    ;
    const got = try formatRuns(std.testing.allocator, text, "gmx");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "user=ada host=login01 time=1428767000.5 path=/opt/site/bin/gmx\nuser=bea host=n2 time=3 path=/other/gmx\n",
        got,
    );
    const none = try formatRuns(std.testing.allocator, text, "missing");
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("no run of missing\n", none);
}
