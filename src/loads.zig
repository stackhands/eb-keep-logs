//! `loads`: who loaded a module, from Lmod's ModuleUsageTracking lines.
//!
//! Lmod's load hook writes `user=USER module=NAME path=PATH host=HOST
//! time=TIME`. A syslog line may carry a prefix in front of that record.
//! The fields may arrive in any order. A value ends at whitespace, which
//! is how Lmod writes them.
const std = @import("std");
const common = @import("zig_common");
const cli = common.cli;
const logfile = @import("logfile.zig");

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
        .module = field(line, "module") orelse return null,
        .path = field(line, "path") orelse return null,
        .host = field(line, "host") orelse return null,
        .time = field(line, "time") orelse return null,
    };
}

/// The loads of `module` in `text`, one line each, in file order. No load
/// is the line `no load of NAME`.
pub fn formatLoads(gpa: Allocator, text: []const u8, module: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const rec = parseRecord(line) orelse continue;
        if (!std.mem.eql(u8, rec.module, module)) continue;
        try out.print(gpa, "user={s} host={s} time={s} path={s}\n", .{ rec.user, rec.host, rec.time, rec.path });
        n += 1;
    }
    if (n == 0) try out.print(gpa, "no load of {s}\n", .{module});
    return try out.toOwnedSlice(gpa);
}

fn readLog(gpa: Allocator, path: []const u8, gzip: bool) ?[]u8 {
    return logfile.read(gpa, common.fsx.cwd, path, read_limit, gzip) catch |err| {
        warn("cannot read {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
}

/// `loads --module NAME [--gzip] FILE`.
pub fn cmdLoads(gpa: Allocator, args: []const []const u8) u8 {
    var module: []const u8 = "";
    var path: []const u8 = "";
    var gzip = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--module") or std.mem.startsWith(u8, a, "--module=")) {
            const v = if (std.mem.startsWith(u8, a, "--module="))
                a["--module=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) die("loads needs --module", .{});
                break :blk args[i];
            };
            if (v.len == 0 or v[0] == '-') die("loads needs --module", .{});
            module = v;
        } else if (std.mem.eql(u8, a, "--gzip")) {
            gzip = true;
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
    const text = readLog(gpa, path, gzip) orelse return 2;
    defer gpa.free(text);
    const body = formatLoads(gpa, text, module) catch die("out of memory", .{});
    defer gpa.free(body);
    cli.out("{s}", .{body});
    return 0;
}

test "a tracking record keeps a syslog prefix and any field order" {
    const line = "Nov 17 12:00:01 login01 ModuleUsageTracking: time=1731840001.250000 host=login01 path=/cvmfs/g.lua module=GROMACS/2024.1 user=alice";
    const rec = parseRecord(line).?;
    try std.testing.expectEqualStrings("alice", rec.user);
    try std.testing.expectEqualStrings("GROMACS/2024.1", rec.module);
    try std.testing.expectEqualStrings("/cvmfs/g.lua", rec.path);
    try std.testing.expectEqualStrings("login01", rec.host);
    try std.testing.expectEqualStrings("1731840001.250000", rec.time);
    try std.testing.expect(parseRecord("user=a module=M path=/p time=1") == null);
}

test "loads of one module keep file order and a gap is named" {
    const text =
        \\user=alice module=GROMACS/2024.1 path=/cvmfs/g.lua host=login01 time=1
        \\user=bob module=GCC/13.2.0 path=/cvmfs/gcc.lua host=login02 time=2
        \\not a record
        \\user=cara module=GROMACS/2024.1 path=/other.lua host=login01 time=3
    ;
    const got = try formatLoads(std.testing.allocator, text, "GROMACS/2024.1");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "user=alice host=login01 time=1 path=/cvmfs/g.lua\nuser=cara host=login01 time=3 path=/other.lua\n",
        got,
    );
    const none = try formatLoads(std.testing.allocator, text, "Missing/1.0");
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings("no load of Missing/1.0\n", none);
}
