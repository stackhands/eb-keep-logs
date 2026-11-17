//! `usage`: installed software with, or without, XALT and Lmod usage hits.
const std = @import("std");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const cli = common.cli;
const used = @import("used.zig");

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
    const root = fsx.openDir(fsx.cwd, software, false) catch
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
        const name_dir = fsx.openDir(root, name_entry.name, false) catch continue;
        {
            defer sys.close(name_dir);
            var versions = fsx.DirIter.init(gpa, name_dir) catch continue;
            defer versions.deinit(gpa);
            while (versions.next() catch |err|
                die("cannot read SOFTWARE {s}/{s}: {t}", .{ software, name_entry.name, err })) |version_entry|
            {
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
    modules: []const u8,
    since: ?f64,
    hits: []const used.Hit,
) !void {
    for (hits) |hit| {
        if (since) |minimum| {
            const epoch = hit.epoch orelse continue;
            if (epoch < minimum) continue;
        }
        const module = if (hit.kind == .@"module-load") blk: {
            if (!used.underPrefix(modules, hit.path)) continue;
            break :blk hit.module orelse continue;
        } else (try moduleFromSoftware(arena, software, hit.path)) orelse continue;
        const pkg = table.getPtr(module) orelse continue;
        note(pkg, hit);
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
        if (selection != .all) {
            try out.print(gpa, "{s}\n", .{pkg.module});
        } else if (pkg.hits == 0) {
            try out.print(gpa, "unused {s}\n", .{pkg.module});
        } else {
            try out.print(gpa, "active {s} hits={d} last={s}\n", .{ pkg.module, pkg.hits, pkg.last });
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
    var packages: std.ArrayList(JsonPackage) = .empty;
    defer packages.deinit(gpa);
    for (selected_rows) |row| {
        const pkg = row.package;
        try packages.append(gpa, .{
            .name = pkg.name,
            .version = pkg.version,
            .module = pkg.module,
            .active = pkg.hits > 0,
            .hits = pkg.hits,
            .last = if (pkg.last.len > 0) pkg.last else null,
        });
    }
    const report: JsonReport = .{
        .software = software,
        .modules = modules,
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

/// `usage --software DIR --modules DIR [--since EPOCH]
/// [--unused | --active] [--json] FILE...`.
pub fn cmdUsage(gpa: Allocator, args: []const []const u8) u8 {
    var software: []const u8 = "";
    var modules: []const u8 = "";
    var since_text: ?[]const u8 = null;
    var since: ?f64 = null;
    var selection: Selection = .all;
    var json_out = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--software") or std.mem.startsWith(u8, arg, "--software=")) {
            software = optionValue(args, &i, arg, "--software", "usage needs --software");
        } else if (std.mem.eql(u8, arg, "--modules") or std.mem.startsWith(u8, arg, "--modules=")) {
            modules = optionValue(args, &i, arg, "--modules", "usage needs --modules");
        } else if (std.mem.eql(u8, arg, "--since") or std.mem.startsWith(u8, arg, "--since=")) {
            const value = optionValue(args, &i, arg, "--since", "--since needs an epoch");
            const parsed = std.fmt.parseFloat(f64, value) catch die("--since needs an epoch", .{});
            if (!std.math.isFinite(parsed) or parsed < 0) die("--since needs an epoch", .{});
            since_text = value;
            since = parsed;
        } else if (std.mem.eql(u8, arg, "--unused")) {
            if (selection == .active) die("usage takes --unused or --active, not both", .{});
            selection = .unused;
        } else if (std.mem.eql(u8, arg, "--active")) {
            if (selection == .unused) die("usage takes --unused or --active, not both", .{});
            selection = .active;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            die("usage does not know '{s}'", .{arg});
        } else {
            files.append(gpa, arg) catch die("out of memory", .{});
        }
    }
    if (software.len == 0) die("usage needs --software", .{});
    if (modules.len == 0) die("usage needs --modules", .{});
    if (files.items.len == 0) die("usage needs a record file", .{});
    if (std.mem.indexOfScalar(u8, software, '\n') != null or
        std.mem.indexOfScalar(u8, modules, '\n') != null)
        die("usage directory must not contain a newline", .{});

    const module_dir = fsx.openDir(fsx.cwd, modules, false) catch
        die("MODULES {s} is not a directory", .{modules});
    sys.close(module_dir);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table = inventory(gpa, arena, software) catch die("out of memory", .{});
    defer table.deinit(arena);

    for (files.items) |path| {
        const text = readLog(gpa, path) orelse return 2;
        defer gpa.free(text);
        const hits = used.parseHits(arena, text) catch |err| switch (err) {
            error.BadJson => {
                warn("usage: {s} is not XALT run JSON", .{path});
                return 2;
            },
            error.OutOfMemory => die("out of memory", .{}),
        };
        applyHits(arena, &table, software, modules, since, hits) catch die("out of memory", .{});
    }

    const selected_rows = rows(arena, &table, selection) catch die("out of memory", .{});
    const body = if (json_out)
        formatJson(arena, software, modules, since_text, selection, selected_rows) catch die("out of memory", .{})
    else
        formatText(arena, selected_rows, selection) catch die("out of memory", .{});
    cli.out("{s}", .{body});
    return 0;
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
