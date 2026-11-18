//! `used`: paths under an install prefix that appear in XALT and Lmod records.
//!
//! XALT may store run records (`userT`, `libA`), link records (`resultT`,
//! `linkA`), and package records (`package_path`). Lmod's load hook writes
//! lines that `loads` already parses. This command does not record use and
//! does not open a database.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;
const loads = @import("loads.zig");
const runs = @import("runs.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
const read_limit: usize = 64 * 1024 * 1024;

pub const schema_version: u32 = 1;

pub const Kind = enum {
    run,
    @"run-lib",
    link,
    pkg,
    @"module-load",

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .run => "run",
            .@"run-lib" => "run-lib",
            .link => "link",
            .pkg => "pkg",
            .@"module-load" => "module-load",
        };
    }
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

/// `path` is under `prefix` when it equals it or is below it as a directory.
pub fn underPrefix(prefix: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    var pre = prefix;
    if (std.mem.endsWith(u8, pre, "/")) pre = pre[0 .. pre.len - 1];
    if (path.len <= pre.len) return false;
    if (!std.mem.startsWith(u8, path, pre)) return false;
    return path[pre.len] == '/';
}

fn parseTime(text: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, text) catch null;
}

fn parseEpoch(text: []const u8) ?f64 {
    const value = parseTime(text) orelse return null;
    if (!std.math.isFinite(value) or value < 0) return null;
    return value;
}

/// One path-bearing record parsed from XALT JSON or an Lmod tracking line.
/// `module` is set only for an Lmod record. Numeric JSON times have an empty
/// `time` (as `used` has always printed) and a populated `epoch`.
pub const Hit = struct {
    kind: Kind,
    path: []const u8,
    module: ?[]const u8 = null,
    time: []const u8 = "",
    epoch: ?f64 = null,
};

const Entry = struct {
    count: u32 = 0,
    last_time: []const u8 = "",
    last_num: ?f64 = null,
};

const Key = struct {
    kind: Kind,
    path: []const u8,

    pub fn hash(self: Key) u64 {
        return std.hash.Wyhash.hash(0, self.path) ^ @as(u64, @backingInt(self.kind));
    }

    pub fn eql(self: Key, other: Key) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.path, other.path);
    }
};

const Table = std.HashMap(Key, Entry, struct {
    pub fn hash(_: @This(), k: Key) u64 {
        return k.hash();
    }

    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.eql(b);
    }
}, std.hash_map.default_max_load_percentage);

fn noteHit(gpa: Allocator, table: *Table, kind: Kind, path: []const u8, time: []const u8) !void {
    const owned_path = try gpa.dupe(u8, path);
    const key = Key{ .kind = kind, .path = owned_path };
    const gop = try table.getOrPut(key);
    if (gop.found_existing) gpa.free(owned_path);
    var ent = gop.value_ptr;
    if (!gop.found_existing) ent.* = .{};
    ent.count += 1;
    if (time.len == 0) return;
    const n = parseTime(time) orelse return;
    if (ent.last_num) |prev| {
        if (n <= prev) return;
    }
    ent.last_num = n;
    ent.last_time = try gpa.dupe(u8, time);
}

fn pathFromPair(pair: std.json.Value) ?[]const u8 {
    return switch (pair) {
        .array => |arr| if (arr.items.len > 0) switch (arr.items[0]) {
            .string => |s| s,
            else => null,
        } else null,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.getPtr(name) orelse return null;
    return switch (v.*) {
        .string => |s| s,
        else => null,
    };
}

fn timeFromUserT(user_t: std.json.ObjectMap) []const u8 {
    if (user_t.getPtr("start_time")) |when| return switch (when.*) {
        .string => |s| s,
        .number_string => |s| s,
        .float, .integer => "",
        else => "",
    };
    if (user_t.getPtr("currentEpoch")) |when| return switch (when.*) {
        .string => |s| s,
        else => "",
    };
    return "";
}

fn timeFromResultT(result_t: std.json.ObjectMap) []const u8 {
    if (stringField(result_t, "build_epoch")) |s| return s;
    return "";
}

fn epochFromValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .string, .number_string => |s| parseEpoch(s),
        .integer => |n| if (n >= 0) @floatFromInt(n) else null,
        .float => |n| if (std.math.isFinite(n) and n >= 0) n else null,
        else => null,
    };
}

fn epochFromUserT(user_t: std.json.ObjectMap) ?f64 {
    if (user_t.getPtr("start_time")) |when| return epochFromValue(when.*);
    if (user_t.getPtr("currentEpoch")) |when| return epochFromValue(when.*);
    return null;
}

fn epochFromResultT(result_t: std.json.ObjectMap) ?f64 {
    if (result_t.getPtr("build_epoch")) |when| return epochFromValue(when.*);
    return null;
}

fn appendHit(gpa: Allocator, hits: *std.ArrayList(Hit), hit: Hit) !void {
    var owned = hit;
    owned.path = try gpa.dupe(u8, hit.path);
    if (hit.module) |module| owned.module = try gpa.dupe(u8, module);
    if (hit.time.len > 0) owned.time = try gpa.dupe(u8, hit.time);
    try hits.append(gpa, owned);
}

fn walkLibArray(gpa: Allocator, hits: *std.ArrayList(Hit), arr: std.json.Array, kind: Kind, time: []const u8, epoch: ?f64) !void {
    for (arr.items) |item| {
        const path = pathFromPair(item) orelse continue;
        try appendHit(gpa, hits, .{ .kind = kind, .path = path, .time = time, .epoch = epoch });
    }
}

fn processObject(gpa: Allocator, hits: *std.ArrayList(Hit), root: std.json.ObjectMap) !void {
    if (stringField(root, "package_path")) |path| {
        try appendHit(gpa, hits, .{ .kind = .pkg, .path = path });
    }

    const user_t = root.getPtr("userT");
    const result_t = root.getPtr("resultT");

    if (user_t) |ut_val| {
        switch (ut_val.*) {
            .object => |user_t_obj| {
                const time = timeFromUserT(user_t_obj);
                const epoch = epochFromUserT(user_t_obj);
                if (stringField(user_t_obj, "exec_path")) |path| {
                    try appendHit(gpa, hits, .{ .kind = .run, .path = path, .time = time, .epoch = epoch });
                }
                if (root.getPtr("libA")) |lib_a| {
                    if (lib_a.* == .array) {
                        try walkLibArray(gpa, hits, lib_a.array, .@"run-lib", time, epoch);
                    }
                }
            },
            else => {},
        }
    }

    if (result_t) |rt_val| {
        switch (rt_val.*) {
            .object => |result_t_obj| {
                const time = timeFromResultT(result_t_obj);
                const epoch = epochFromResultT(result_t_obj);
                if (stringField(result_t_obj, "exec_path")) |path| {
                    try appendHit(gpa, hits, .{ .kind = .link, .path = path, .time = time, .epoch = epoch });
                }
                if (root.getPtr("linkA")) |link_a| {
                    if (link_a.* == .array) {
                        try walkLibArray(gpa, hits, link_a.array, .link, time, epoch);
                    }
                }
            },
            else => {},
        }
    }
}

fn processLmodLine(gpa: Allocator, hits: *std.ArrayList(Hit), line: []const u8) !bool {
    const rec = loads.parseRecord(line) orelse return false;
    try appendHit(gpa, hits, .{
        .kind = .@"module-load",
        .path = rec.path,
        .module = rec.module,
        .time = rec.time,
        .epoch = parseEpoch(rec.time),
    });
    return true;
}

/// Parse every XALT and Lmod hit in `text` once, without filtering paths.
pub fn parseHits(gpa: Allocator, text: []const u8) (Allocator.Error || error{BadJson})![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    var at: usize = 0;
    var has_non_ws = false;
    var saw_record = false;
    while (true) {
        while (at < text.len and std.ascii.isWhitespace(text[at])) : (at += 1) {}
        if (at >= text.len) break;
        has_non_ws = true;
        if (text[at] == '{') {
            const item = (try runs.nextObject(text, at)) orelse break;
            at = item.end;
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, item.slice, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadJson,
            };
            defer parsed.deinit();
            const root = switch (parsed.value) {
                .object => |obj| obj,
                else => continue,
            };
            saw_record = true;
            try processObject(gpa, &hits, root);
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[at..end], "\r");
        if (try processLmodLine(gpa, &hits, line)) saw_record = true;
        at = if (end < text.len) end + 1 else end;
    }
    if (has_non_ws and !saw_record) return error.BadJson;
    return try hits.toOwnedSlice(gpa);
}

pub fn scanText(gpa: Allocator, table: *Table, prefix: []const u8, text: []const u8) (Allocator.Error || error{BadJson})!void {
    const hits = try parseHits(gpa, text);
    for (hits) |hit| {
        if (!underPrefix(prefix, hit.path)) continue;
        try noteHit(gpa, table, hit.kind, hit.path, hit.time);
    }
}

const Row = struct {
    kind: Kind,
    path: []const u8,
    entry: Entry,
};

fn cmpRow(context: void, a: Row, b: Row) bool {
    _ = context;
    const c = std.mem.order(u8, a.path, b.path);
    if (c != .eq) return c == .lt;
    return @backingInt(a.kind) < @backingInt(b.kind);
}

pub fn formatText(gpa: Allocator, prefix: []const u8, table: *Table) ![]u8 {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var it = table.iterator();
    while (it.next()) |kv| {
        try rows.append(gpa, .{ .kind = kv.key_ptr.kind, .path = kv.key_ptr.path, .entry = kv.value_ptr.* });
    }
    std.mem.sort(Row, rows.items, {}, cmpRow);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (rows.items.len == 0) {
        try out.print(gpa, "nothing under {s}\n", .{prefix});
        return try out.toOwnedSlice(gpa);
    }
    for (rows.items) |row| {
        try out.print(gpa, "path={s} kind={s} last={s} count={d}\n", .{
            row.path,
            row.kind.name(),
            row.entry.last_time,
            row.entry.count,
        });
    }
    return try out.toOwnedSlice(gpa);
}

const JsonUse = struct {
    kind: []const u8,
    path: []const u8,
    last: []const u8,
    count: u32,
};

const JsonReport = struct {
    schema_version: u32 = schema_version,
    prefix: []const u8,
    uses: []const JsonUse,
};

pub fn formatJson(gpa: Allocator, prefix: []const u8, table: *Table) ![]u8 {
    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    var it = table.iterator();
    while (it.next()) |kv| {
        try rows.append(gpa, .{ .kind = kv.key_ptr.kind, .path = kv.key_ptr.path, .entry = kv.value_ptr.* });
    }
    std.mem.sort(Row, rows.items, {}, cmpRow);
    var uses: std.ArrayList(JsonUse) = .empty;
    defer uses.deinit(gpa);
    for (rows.items) |row| {
        try uses.append(gpa, .{
            .kind = row.kind.name(),
            .path = row.path,
            .last = row.entry.last_time,
            .count = row.entry.count,
        });
    }
    const report: JsonReport = .{ .prefix = prefix, .uses = uses.items };
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

/// `used --prefix PREFIX [--json] [--require-none] FILE...`.
pub fn cmdUsed(gpa: Allocator, args: []const []const u8) u8 {
    var prefix: []const u8 = "";
    var json_out = false;
    var require_none = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--prefix") or std.mem.startsWith(u8, a, "--prefix=")) {
            const v = if (std.mem.startsWith(u8, a, "--prefix="))
                a["--prefix=".len..]
            else blk: {
                i += 1;
                if (i >= args.len) die("used needs --prefix", .{});
                break :blk args[i];
            };
            if (v.len == 0 or v[0] == '-') die("used needs --prefix", .{});
            prefix = v;
        } else if (std.mem.eql(u8, a, "--json")) {
            json_out = true;
        } else if (std.mem.eql(u8, a, "--require-none")) {
            require_none = true;
        } else if (a.len > 0 and a[0] == '-') {
            die("used does not know '{s}'", .{a});
        } else {
            files.append(gpa, a) catch die("out of memory", .{});
        }
    }
    if (prefix.len == 0) die("used needs --prefix", .{});
    if (std.mem.indexOfScalar(u8, prefix, '\n') != null) die("used needs --prefix", .{});
    if (files.items.len == 0) die("used needs a record file", .{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var table = Table.init(a);
    defer table.deinit();

    for (files.items) |path| {
        const text = readLog(gpa, path) orelse return 2;
        defer gpa.free(text);
        scanText(a, &table, prefix, text) catch |err| switch (err) {
            error.BadJson => {
                warn("used: {s} is not XALT run JSON", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
    }

    const hits = table.count();
    const body = if (json_out)
        formatJson(a, prefix, &table) catch die("out of memory", .{})
    else
        formatText(a, prefix, &table) catch die("out of memory", .{});
    cli.out("{s}", .{body});

    if (require_none and hits > 0) return 2;
    return 0;
}

test "under a prefix, and a neighbour path is not" {
    const p = "/opt/install";
    try std.testing.expect(underPrefix(p, "/opt/install"));
    try std.testing.expect(underPrefix(p, "/opt/install/bin/gmx"));
    try std.testing.expect(!underPrefix(p, "/opt/install-other/bin/gmx"));
    try std.testing.expect(!underPrefix(p, "/opt/other"));
}

test "a link record in the runs fixture is a link use" {
    const text =
        \\{"userT":{"user":"faheymr","exec_path":"/lustre/medusa/faheymr/hello_world","syshost":"darter","start_time":"1428766963"}}
        \\{"resultT": { "exec_path": "/lustre/medusa/faheymr/hello_world", "build_user": "faheymr", "build_epoch": "1428766000" }}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = Table.init(a);
    defer table.deinit();
    try scanText(a, &table, "/lustre/medusa/faheymr", text);
    const ent = table.get(.{ .kind = .link, .path = "/lustre/medusa/faheymr/hello_world" }) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 1), ent.count);
}

test "libA under the prefix is run-lib even when exec_path is outside" {
    const text =
        \\{"userT":{"user":"ada","exec_path":"/usr/bin/python","syshost":"n1","start_time":"10"},"libA":[["/opt/pkg/lib/libfoo.so","0"]]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = Table.init(a);
    defer table.deinit();
    try scanText(a, &table, "/opt/pkg", text);
    try std.testing.expect(table.contains(.{ .kind = .@"run-lib", .path = "/opt/pkg/lib/libfoo.so" }));
    try std.testing.expect(!table.contains(.{ .kind = .run, .path = "/usr/bin/python" }));
}

test "module-load lines aggregate by path" {
    const text =
        \\user=alice module=GROMACS/1.0 path=/opt/pkg/modules/GROMACS/1.0 host=h1 time=1
        \\user=bob module=GROMACS/1.0 path=/opt/pkg/modules/GROMACS/1.0 host=h2 time=3
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = Table.init(a);
    defer table.deinit();
    try scanText(a, &table, "/opt/pkg", text);
    const ent = table.get(.{ .kind = .@"module-load", .path = "/opt/pkg/modules/GROMACS/1.0" }).?;
    try std.testing.expectEqual(@as(u32, 2), ent.count);
    try std.testing.expectEqualStrings("3", ent.last_time);
}

test "truncated JSON is refused" {
    const text = "{\"userT\":{\"exec_path\":\"/opt/a\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = Table.init(a);
    defer table.deinit();
    try std.testing.expectError(error.BadJson, scanText(a, &table, "/opt", text));
}

test "userT null preserves resultT hits and non-JSON text is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hits = try parseHits(
        a,
        "{\"userT\":null,\"resultT\":{\"exec_path\":\"/opt/a/bin/x\",\"build_epoch\":\"200\"}}",
    );
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(Kind.link, hits[0].kind);
    try std.testing.expectError(error.BadJson, parseHits(a, "not json or lmod\n"));
}
