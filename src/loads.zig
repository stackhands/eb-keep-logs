//! `loads`: who loaded a module, from Lmod's ModuleUsageTracking lines.
//!
//! Lmod's load hook writes `user=USER jobid=ID module=NAME path=PATH
//! host=HOST time=TIME`; `jobid` is optional. A syslog line may carry a prefix.
//! The fields may arrive in any order. A value ends at whitespace, which
//! is how Lmod writes them.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
/// A module-usage log larger than this is refused rather than read part way.
const read_limit: usize = 64 * 1024 * 1024;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

pub const Record = struct {
    user: []const u8,
    jobid: ?[]const u8,
    module: []const u8,
    path: []const u8,
    host: []const u8,
    time: []const u8,
};

/// The value of `key=` in `line`, when `key` starts the line or follows
/// whitespace. A value is the bytes up to the next whitespace.
pub fn field(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (i != 0 and !std.ascii.isWhitespace(line[i - 1])) continue;
        if (!std.mem.startsWith(u8, line[i..], key)) continue;
        const eq = i + key.len;
        if (eq >= line.len or line[eq] != '=') continue;
        const start = eq + 1;
        var end = start;
        while (end < line.len and !std.ascii.isWhitespace(line[end])) : (end += 1) {}
        if (end == start) return null;
        return line[start..end];
    }
    return null;
}

/// One tracking record, or none when a field is missing.
pub fn parseRecord(line: []const u8) ?Record {
    return .{
        .user = field(line, "user") orelse return null,
        .jobid = field(line, "jobid"),
        .module = field(line, "module") orelse return null,
        .path = field(line, "path") orelse return null,
        .host = field(line, "host") orelse return null,
        .time = field(line, "time") orelse return null,
    };
}

const Filters = struct {
    user: ?[]const u8 = null,
    jobid: ?[]const u8 = null,
    since: ?f64 = null,
};

fn parseEpoch(text: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(value) or value < 0) return null;
    return value;
}

fn matchingLoads(
    gpa: Allocator,
    text: []const u8,
    module: []const u8,
    filters: Filters,
) Allocator.Error![]Record {
    var selected: std.ArrayList(Record) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const rec = parseRecord(line) orelse continue;
        if (!std.mem.eql(u8, rec.module, module)) continue;
        if (filters.user) |wanted| if (!std.mem.eql(u8, rec.user, wanted)) continue;
        if (filters.jobid) |wanted| {
            const jobid = rec.jobid orelse continue;
            if (!std.mem.eql(u8, jobid, wanted)) continue;
        }
        if (filters.since) |minimum| {
            const epoch = parseEpoch(rec.time) orelse continue;
            if (epoch < minimum) continue;
        }
        try selected.append(gpa, rec);
    }
    return try selected.toOwnedSlice(gpa);
}

fn formatLoadsText(gpa: Allocator, selected: []const Record, module: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (selected) |rec| {
        try out.print(gpa, "user={s}", .{rec.user});
        if (rec.jobid) |jobid| try out.print(gpa, " jobid={s}", .{jobid});
        try out.print(gpa, " host={s} time={s} path={s}\n", .{ rec.host, rec.time, rec.path });
    }
    if (selected.len == 0) try out.print(gpa, "no load of {s}\n", .{module});
    return try out.toOwnedSlice(gpa);
}

/// The loads of `module` in `text`, one line each, in file order.
pub fn formatLoads(gpa: Allocator, text: []const u8, module: []const u8) Allocator.Error![]u8 {
    const selected = try matchingLoads(gpa, text, module, .{});
    defer gpa.free(selected);
    return formatLoadsText(gpa, selected, module);
}

const JsonLoad = struct {
    user: []const u8,
    jobid: ?[]const u8,
    host: []const u8,
    time: []const u8,
    path: []const u8,
};

const JsonReport = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "loads",
    module: []const u8,
    loads: []const JsonLoad,
};

fn formatLoadsJson(
    gpa: Allocator,
    selected: []const Record,
    module: []const u8,
) ![]u8 {
    var rows: std.ArrayList(JsonLoad) = .empty;
    defer rows.deinit(gpa);
    for (selected) |rec| try rows.append(gpa, .{
        .user = rec.user,
        .jobid = rec.jobid,
        .host = rec.host,
        .time = rec.time,
        .path = rec.path,
    });
    const report: JsonReport = .{ .module = module, .loads = rows.items };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
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

/// `loads --module NAME [--user USER] [--jobid ID] [--since EPOCH] [--json] FILE`.
pub fn cmdLoads(gpa: Allocator, args: []const []const u8) u8 {
    var module: []const u8 = "";
    var user: ?[]const u8 = null;
    var jobid: ?[]const u8 = null;
    var since: ?f64 = null;
    var json_out = false;
    var path: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--module") or std.mem.startsWith(u8, a, "--module=")) {
            module = optionValue(args, &i, a, "--module", "loads needs --module");
        } else if (std.mem.eql(u8, a, "--user") or std.mem.startsWith(u8, a, "--user=")) {
            user = optionValue(args, &i, a, "--user", "--user needs a name");
        } else if (std.mem.eql(u8, a, "--jobid") or std.mem.startsWith(u8, a, "--jobid=")) {
            jobid = optionValue(args, &i, a, "--jobid", "--jobid needs an identifier");
        } else if (std.mem.eql(u8, a, "--since") or std.mem.startsWith(u8, a, "--since=")) {
            const value = optionValue(args, &i, a, "--since", "--since needs an epoch");
            const parsed = std.fmt.parseFloat(f64, value) catch die("--since needs an epoch", .{});
            if (!std.math.isFinite(parsed) or parsed < 0) die("--since needs an epoch", .{});
            since = parsed;
        } else if (std.mem.eql(u8, a, "--json")) {
            json_out = true;
        } else if (a.len > 0 and a[0] == '-') {
            die("loads does not know '{s}'", .{a});
        } else if (path.len == 0) {
            path = a;
        } else {
            die("loads does not know '{s}'", .{a});
        }
    }
    if (module.len == 0) die("loads needs --module", .{});
    if (path.len == 0) die("loads needs a log file", .{});
    const text = readLog(gpa, path) orelse return 2;
    defer gpa.free(text);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const selected = matchingLoads(arena, text, module, .{
        .user = user,
        .jobid = jobid,
        .since = since,
    }) catch die("out of memory", .{});
    const body = if (json_out)
        formatLoadsJson(arena, selected, module) catch die("out of memory", .{})
    else
        formatLoadsText(arena, selected, module) catch die("out of memory", .{});
    cli.out("{s}", .{body});
    return 0;
}

test "a tracking record keeps a syslog prefix and any field order" {
    const line = "Nov 17 12:00:01 login01 ModuleUsageTracking: time=1731840001.250000 host=login01 path=/cvmfs/g.lua module=GROMACS/2024.1 user=alice";
    const rec = parseRecord(line).?;
    try std.testing.expectEqualStrings("alice", rec.user);
    try std.testing.expect(rec.jobid == null);
    try std.testing.expectEqualStrings("GROMACS/2024.1", rec.module);
    try std.testing.expectEqualStrings("/cvmfs/g.lua", rec.path);
    try std.testing.expectEqualStrings("login01", rec.host);
    try std.testing.expectEqualStrings("1731840001.250000", rec.time);
    try std.testing.expect(parseRecord("user=a module=M path=/p time=1") == null);
}

test "loads of one module keep file order and a gap is named" {
    const text =
        \\user=alice jobid=42 module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1
        \\user=bob module=GCC/13.2.0 path=/cvmfs/gcc.lua host=login02 time=2
        \\not a record
        \\user=cara module=GROMACS/2024.1 path=/other.lua host=login01 time=3
    ;
    const got = try formatLoads(std.testing.allocator, text, "GROMACS/2024.1");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "user=alice jobid=42 host=login01 time=1 path=/cvmfs/g.lua\nuser=cara host=login01 time=3 path=/other.lua\n",
        got,
    );
    const none = try formatLoads(std.testing.allocator, text, "Missing/1.0");
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("no load of Missing/1.0\n", none);
}
