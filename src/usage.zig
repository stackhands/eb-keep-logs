//! `usage`: installed software with, or without, XALT and Lmod usage hits.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;
const cli_parse = @import("cli_parse.zig");
const used = @import("used.zig");
const utf8_text = @import("utf8_text.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
const read_limit: usize = 64 * 1024 * 1024;

const Selection = enum {
    all,
    unused,
    active,

    fn name(self: Selection) []const u8 {
        return switch (self) {
            .all => "all",
            .unused => "unused",
            .active => "active",
        };
    }
};

const Package = struct {
    module: []const u8,
    name: []const u8,
    version: []const u8,
    hits: u64 = 0,
    last: []const u8 = "",
    last_epoch: ?f64 = null,
};

const Table = std.StringHashMapUnmanaged(Package);

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

fn inventory(gpa: Allocator, arena: Allocator, software: []const u8) !Table {
    const root = fsx.openDir(fsx.cwd, software, true) catch
        die("SOFTWARE {s} is not a directory", .{software});
    defer sys.close(root);
    var table: Table = .empty;
    var names = fsx.DirIter.init(gpa, root) catch
        die("cannot read SOFTWARE {s}", .{software});
    defer names.deinit(gpa);
    while (names.next() catch |err|
        die("cannot read SOFTWARE {s}: {t}", .{ software, err })) |name_entry|
    {
        if (name_entry.name.len == 0 or name_entry.name[0] == '.') continue;
        if ((fsx.entryType(root, name_entry) catch continue) != fsx.DT.DIR) continue;
        const name_dir = fsx.openDir(root, name_entry.name, false) catch |err| {
            warn("cannot open SOFTWARE {s}/{s}: {t}", .{ software, name_entry.name, err });
            continue;
        };
        {
            defer sys.close(name_dir);
            var versions = fsx.DirIter.init(gpa, name_dir) catch |err| {
                warn("cannot read SOFTWARE {s}/{s}: {t}", .{ software, name_entry.name, err });
                continue;
            };
            defer versions.deinit(gpa);
            while (versions.next() catch |err| {
                warn("cannot read SOFTWARE {s}/{s}: {t}", .{ software, name_entry.name, err });
                break;
            }) |version_entry| {
                if (version_entry.name.len == 0 or version_entry.name[0] == '.') continue;
                if ((fsx.entryType(name_dir, version_entry) catch continue) != fsx.DT.DIR) continue;
                const name = try arena.dupe(u8, name_entry.name);
                const version = try arena.dupe(u8, version_entry.name);
                const module = try arena.print("{s}/{s}", .{ name, version });
                try table.put(arena, module, .{
                    .module = module,
                    .name = name,
                    .version = version,
                });
            }
        }
    }
    return table;
}

fn moduleFromSoftware(arena: Allocator, software: []const u8, path: []const u8) !?[]const u8 {
    if (!used.underPrefix(software, path)) return null;
    const root = std.mem.trimEnd(u8, software, "/");
    var rel = path[root.len..];
    while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    const first = std.mem.indexOfScalar(u8, rel, '/') orelse return null;
    if (first == 0) return null;
    const rest = rel[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (second == 0) return null;
    return try arena.print("{s}/{s}", .{ rel[0..first], rest[0..second] });
}

fn note(pkg: *Package, hit: used.Hit) void {
    pkg.hits += 1;
    const epoch = hit.epoch orelse return;
    if (pkg.last_epoch) |last| if (epoch <= last) return;
    pkg.last_epoch = epoch;
    pkg.last = hit.time;
}

fn applyHits(
    arena: Allocator,
    table: *Table,
    software: []const u8,
    software_real: []const u8,
    modules: []const u8,
    modules_real: []const u8,
    since: ?f64,
    hits: []const used.Hit,
) !void {
    for (hits) |hit| {
        if (since) |minimum| {
            const epoch = hit.epoch orelse continue;
            if (epoch < minimum) continue;
        }
        if (hit.kind == .@"module-load") {
            if (!used.underPrefix(modules, hit.path) and
                !used.underPrefix(modules_real, hit.path)) continue;
            const module = hit.module orelse continue;
            const pkg = table.getPtr(module) orelse continue;
            note(pkg, hit);
            continue;
        }
        if (try moduleFromSoftware(arena, software, hit.path)) |module| {
            if (table.getPtr(module)) |pkg| {
                note(pkg, hit);
                continue;
            }
        }
        if (!std.mem.eql(u8, software, software_real)) {
            if (try moduleFromSoftware(arena, software_real, hit.path)) |module| {
                if (table.getPtr(module)) |pkg| note(pkg, hit);
            }
        }
    }
}

const Row = struct {
    package: Package,
};

fn lessThan(_: void, a: Row, b: Row) bool {
    return std.mem.lessThan(u8, a.package.module, b.package.module);
}

fn selected(selection: Selection, pkg: Package) bool {
    return switch (selection) {
        .all => true,
        .unused => pkg.hits == 0,
        .active => pkg.hits > 0,
    };
}

fn rows(gpa: Allocator, table: *Table, selection: Selection) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    var it = table.valueIterator();
    while (it.next()) |pkg| {
        if (selected(selection, pkg.*)) try out.append(gpa, .{ .package = pkg.* });
    }
    std.mem.sort(Row, out.items, {}, lessThan);
    return try out.toOwnedSlice(gpa);
}

fn formatText(gpa: Allocator, selected_rows: []const Row, selection: Selection) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (selected_rows) |row| {
        const pkg = row.package;
        const module = utf8_text.text(pkg.module);
        if (selection != .all) {
            try out.print(gpa, "{f}\n", .{module});
        } else if (pkg.hits == 0) {
            try out.print(gpa, "unused {f}\n", .{module});
        } else {
            try out.print(gpa, "active {f} hits={d} last={f}\n", .{ module, pkg.hits, utf8_text.text(pkg.last) });
        }
    }
    return try out.toOwnedSlice(gpa);
}

const JsonPackage = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    active: bool,
    hits: u64,
    last: ?[]const u8,
};

const JsonReport = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "usage",
    software: []const u8,
    modules: []const u8,
    since: ?[]const u8,
    selection: []const u8,
    packages: []const JsonPackage,
};

fn formatJson(
    gpa: Allocator,
    software: []const u8,
    modules: []const u8,
    since: ?[]const u8,
    selection: Selection,
    selected_rows: []const Row,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var packages: std.ArrayList(JsonPackage) = .empty;
    defer packages.deinit(gpa);
    for (selected_rows) |row| {
        const pkg = row.package;
        try packages.append(gpa, .{
            .name = try utf8_text.utf8(arena, pkg.name),
            .version = try utf8_text.utf8(arena, pkg.version),
            .module = try utf8_text.utf8(arena, pkg.module),
            .active = pkg.hits > 0,
            .hits = pkg.hits,
            .last = if (pkg.last.len > 0) try utf8_text.utf8(arena, pkg.last) else null,
        });
    }
    const report: JsonReport = .{
        .software = try utf8_text.utf8(arena, software),
        .modules = try utf8_text.utf8(arena, modules),
        .since = since,
        .selection = selection.name(),
        .packages = packages.items,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

fn finiteEpoch(gpa: Allocator, raw: []const u8) Allocator.Error!cli_parse.ValidationResult {
    const number = std.fmt.parseFloat(f64, raw) catch return .{ .err = try gpa.dupe(u8, "epoch") };
    if (!std.math.isFinite(number) or number < 0) return .{ .err = try gpa.dupe(u8, "epoch") };
    return .ok;
}

const usage_cli = cli_parse.make(.{
    .prog = "usage",
    .mutex = "usage takes --unused or --active, not both",
    .options = &.{
        cli_parse.req("software"),
        cli_parse.req("modules"),
        cli_parse.checked(cli_parse.strict("since"), finiteEpoch),
        cli_parse.flag("unused"),
        cli_parse.flag("active"),
        cli_parse.flag("json"),
    },
    .mutually_exclusive = &.{
        .{ .options = &.{ "unused", "active" } },
    },
    .positionals = &.{cli_parse.oneOrMore("FILE")},
    .missing = &.{
        .{ .name = "since", .msg = "--since needs an epoch" },
        .{ .name = "FILE", .msg = "usage needs a record file" },
    },
});

/// `usage --software DIR --modules DIR [--since EPOCH]
/// [--unused | --active] [--json] FILE...`.
pub fn cmdUsage(gpa: Allocator, args: []const []const u8) u8 {
    var parsed = usage_cli.take(gpa, args);
    defer parsed.deinit(gpa);
    const software = parsed.value("software").?;
    const modules = parsed.value("modules").?;
    const since_text = parsed.value("since");
    const since: ?f64 = if (since_text) |value|
        std.fmt.parseFloat(f64, value) catch die("--since needs an epoch", .{})
    else
        null;
    const selection: Selection = if (parsed.seen("unused")) .unused else if (parsed.seen("active")) .active else .all;
    const json_out = parsed.seen("json");
    const files = parsed.positionals;
    if (std.mem.indexOfScalar(u8, software, '\n') != null or
        std.mem.indexOfScalar(u8, modules, '\n') != null)
        die("usage directory must not contain a newline", .{});

    const module_dir = fsx.openDir(fsx.cwd, modules, true) catch
        die("MODULES {s} is not a directory", .{modules});
    defer sys.close(module_dir);
    var modules_real_buf: [sys.path_max]u8 = undefined;
    const modules_real = fsx.realpathFd(module_dir, &modules_real_buf) catch
        die("MODULES {s} is not a directory", .{modules});
    var software_real_buf: [sys.path_max]u8 = undefined;
    const software_real = fsx.realpath(fsx.cwd, software, &software_real_buf) catch
        die("SOFTWARE {s} is not a directory", .{software});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table = inventory(gpa, arena, software) catch die("out of memory", .{});
    defer table.deinit(arena);

    for (files) |path| {
        const text = readLog(gpa, path) orelse return 2;
        defer gpa.free(text);
        const hits = used.parseHits(arena, text) catch |err| switch (err) {
            error.BadJson => {
                warn("usage: {s} is not XALT run JSON or Lmod usage log", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
        applyHits(
            arena,
            &table,
            software,
            software_real,
            modules,
            modules_real,
            since,
            hits,
        ) catch die("out of memory", .{});
    }

    const selected_rows = rows(arena, &table, selection) catch die("out of memory", .{});
    const body = if (json_out)
        formatJson(arena, software, modules, since_text, selection, selected_rows) catch die("out of memory", .{})
    else
        formatText(arena, selected_rows, selection) catch die("out of memory", .{});
    cli.out("{s}", .{body});
    return 0;
}

test "software paths name their installed module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "GROMACS/2026.1-foss-2026a",
        (try moduleFromSoftware(
            arena,
            "/opt/software",
            "/opt/software/GROMACS/2026.1-foss-2026a/bin/gmx",
        )).?,
    );
    try std.testing.expect((try moduleFromSoftware(
        arena,
        "/opt/software",
        "/opt/software-other/GROMACS/1/bin/gmx",
    )) == null);
}

test "a modules directory with a bad byte matches the Lmod records under it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table: Table = .empty;
    try table.put(arena, "pkg/1.0", .{ .module = "pkg/1.0", .name = "pkg", .version = "1.0" });
    const hits = try used.parseHits(arena, "user=alice module=pkg/1.0 path=/opt/mod\xffules/pkg/1.0.lua host=h1 time=5\n");
    try applyHits(arena, &table, "/opt/software", "/opt/software", "/opt/mod\xffules", "/opt/mod\xffules", null, hits);
    try std.testing.expectEqual(@as(u64, 1), table.get("pkg/1.0").?.hits);
    const selected_rows = try rows(arena, &table, .all);
    try std.testing.expectEqualStrings("active pkg/1.0 hits=1 last=5\n", try formatText(arena, selected_rows, .all));
}

test "installed names that differ only in a bad byte stay two entries, replaced where printed" {
    const linux = std.os.linux;
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/usage-badname-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    try common.atomic.makedirs(base);

    const software = try std.fmt.allocPrint(gpa, "{s}/software", .{base});
    defer gpa.free(software);
    try common.atomic.makedirs(software);

    const software_dir = try fsx.openDir(fsx.cwd, software, false);
    defer sys.close(software_dir);
    var zb: [sys.path_max:0]u8 = undefined;
    for ([_][]const u8{ "pkg\xfe", "pkg\xff" }) |name| {
        _ = try sys.call(linux.mkdirat, .{ software_dir, (try sys.z(&zb, name)).ptr, @as(linux.mode_t, 0o755) });
        const name_dir = try fsx.openDir(software_dir, name, false);
        defer sys.close(name_dir);
        _ = try sys.call(linux.mkdirat, .{ name_dir, (try sys.z(&zb, "1.0")).ptr, @as(linux.mode_t, 0o755) });
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table = try inventory(gpa, arena, software);
    defer table.deinit(arena);
    try std.testing.expectEqual(@as(u32, 2), table.count());
    try std.testing.expect(table.contains("pkg\xfe/1.0"));
    try std.testing.expect(table.contains("pkg\xff/1.0"));

    const hits = try used.parseHits(arena, "user=alice module=pkg\xff/1.0 path=/opt/modules/pkg/1.0.lua host=h1 time=5\n");
    try applyHits(arena, &table, software, software, "/opt/modules", "/opt/modules", null, hits);
    try std.testing.expectEqual(@as(u64, 0), table.get("pkg\xfe/1.0").?.hits);
    try std.testing.expectEqual(@as(u64, 1), table.get("pkg\xff/1.0").?.hits);

    const selected_rows = try rows(arena, &table, .all);
    const text = try formatText(arena, selected_rows, .all);
    try std.testing.expectEqualStrings("unused pkg\u{FFFD}/1.0\nactive pkg\u{FFFD}/1.0 hits=1 last=5\n", text);
    const json = try formatJson(arena, software, "/opt/modules", null, .all, selected_rows);
    try std.testing.expect(std.unicode.utf8ValidateSlice(json));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"pkg\u{FFFD}\",\"version\":\"1.0\",\"module\":\"pkg\u{FFFD}/1.0\"") != null);
}
