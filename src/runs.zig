//! `runs`: who ran an executable, from XALT run records.
//!
//! A run record is one JSON object. `userT` holds `user`, `exec_path`, and
//! when XALT wrote them `syshost` and `start_time`. A link record has
//! `resultT` and no `userT`; it is not a run. The file may hold several
//! objects, one after another, or XALT V:3 syslog chunks. This does not record
//! runs and does not open a database.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;
const used = @import("used.zig");

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

const Filters = struct {
    user: ?[]const u8 = null,
    since: ?f64 = null,
};

fn matchingRuns(
    gpa: Allocator,
    text: []const u8,
    exec: []const u8,
    filters: Filters,
) (Allocator.Error || error{BadJson})![]used.Hit {
    const hits = try used.parseHits(gpa, text);
    var selected: std.ArrayList(used.Hit) = .empty;
    for (hits) |hit| {
        if (hit.kind != .run or !execMatches(hit.path, exec)) continue;
        const user = hit.user orelse continue;
        if (filters.user) |wanted| if (!std.mem.eql(u8, user, wanted)) continue;
        if (filters.since) |minimum| {
            const epoch = hit.epoch orelse continue;
            if (epoch < minimum) continue;
        }
        try selected.append(gpa, hit);
    }
    return try selected.toOwnedSlice(gpa);
}

fn formatRunsText(gpa: Allocator, selected: []const used.Hit, exec: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (selected) |hit| {
        try out.print(gpa, "user={s} host={s} time={s} path={s}\n", .{
            hit.user.?,
            hit.host orelse "",
            hit.time,
            hit.path,
        });
    }
    if (selected.len == 0) try out.print(gpa, "no run of {s}\n", .{exec});
    return try out.toOwnedSlice(gpa);
}

const JsonRun = struct {
    user: []const u8,
    host: []const u8,
    time: []const u8,
    path: []const u8,
};

const JsonReport = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "runs",
    exec: []const u8,
    runs: []const JsonRun,
};

fn formatRunsJson(
    gpa: Allocator,
    selected: []const used.Hit,
    exec: []const u8,
) ![]u8 {
    var rows: std.ArrayList(JsonRun) = .empty;
    defer rows.deinit(gpa);
    for (selected) |hit| try rows.append(gpa, .{
        .user = hit.user.?,
        .host = hit.host orelse "",
        .time = hit.time,
        .path = hit.path,
    });
    const report: JsonReport = .{ .exec = exec, .runs = rows.items };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

/// The runs of `exec` in `text`, one line each, in file order.
pub fn formatRuns(gpa: Allocator, text: []const u8, exec: []const u8) (Allocator.Error || error{BadJson})![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const selected = try matchingRuns(arena_state.allocator(), text, exec, .{});
    return formatRunsText(gpa, selected, exec);
}

fn optionValue(
    args: []const []const u8,
    i: *usize,
    arg: []const u8,
    comptime option: []const u8,
    comptime message: []const u8,
) []const u8 {
    const value = if (std.mem.startsWith(u8, arg, option ++ "="))
        arg[option.len + 1 ..]
    else blk: {
        i.* += 1;
        if (i.* >= args.len) die(message, .{});
        break :blk args[i.*];
    };
    if (value.len == 0 or value[0] == '-') die(message, .{});
    return value;
}

/// `runs --exec PATH [--user USER] [--since EPOCH] [--json] FILE`.
pub fn cmdRuns(gpa: Allocator, args: []const []const u8) u8 {
    var exec: []const u8 = "";
    var user: ?[]const u8 = null;
    var since: ?f64 = null;
    var json_out = false;
    var path: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--exec") or std.mem.startsWith(u8, a, "--exec=")) {
            exec = optionValue(args, &i, a, "--exec", "runs needs --exec");
        } else if (std.mem.eql(u8, a, "--user") or std.mem.startsWith(u8, a, "--user=")) {
            user = optionValue(args, &i, a, "--user", "--user needs a name");
        } else if (std.mem.eql(u8, a, "--since") or std.mem.startsWith(u8, a, "--since=")) {
            const value = optionValue(args, &i, a, "--since", "--since needs an epoch");
            const parsed = std.fmt.parseFloat(f64, value) catch die("--since needs an epoch", .{});
            if (!std.math.isFinite(parsed) or parsed < 0) die("--since needs an epoch", .{});
            since = parsed;
        } else if (std.mem.eql(u8, a, "--json")) {
            json_out = true;
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
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const selected = matchingRuns(arena, text, exec, .{ .user = user, .since = since }) catch |err| switch (err) {
        error.BadJson => {
            warn("runs: {s} is not XALT run JSON", .{path});
            return 2;
        },
        error.OutOfMemory => die("out of memory", .{}),
    };
    const body = if (json_out)
        formatRunsJson(arena, selected, exec) catch die("out of memory", .{})
    else
        formatRunsText(arena, selected, exec) catch die("out of memory", .{});
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
