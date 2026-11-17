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

/// The runs of `exec` in `text`, one line each, in file order. No run is
/// the line `no run of PATH`.
pub fn formatRuns(gpa: Allocator, text: []const u8, exec: []const u8) (Allocator.Error || error{BadJson})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
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
        try out.appendSlice(gpa, "user=");
        try out.appendSlice(gpa, user);
        try out.appendSlice(gpa, " host=");
        if (user_t.getPtr("syshost")) |host| {
            if (host.* == .string) try out.appendSlice(gpa, host.string);
        }
        try out.appendSlice(gpa, " time=");
        if (user_t.getPtr("start_time")) |when| try appendScalar(&out, gpa, when.*);
        try out.appendSlice(gpa, " path=");
        try out.appendSlice(gpa, path);
        try out.append(gpa, '\n');
        n += 1;
    }
    if (n == 0) try out.print(gpa, "no run of {s}\n", .{exec});
    return try out.toOwnedSlice(gpa);
}

/// `runs --exec PATH FILE`.
pub fn cmdRuns(gpa: Allocator, args: []const []const u8) u8 {
    var exec: []const u8 = "";
    var path: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--exec") or std.mem.startsWith(u8, a, "--exec=")) {
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
    const body = formatRuns(gpa, text, exec) catch |err| switch (err) {
        error.BadJson => {
            warn("runs: {s} is not XALT run JSON", .{path});
            return 2;
        },
        error.OutOfMemory => die("out of memory", .{}),
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
