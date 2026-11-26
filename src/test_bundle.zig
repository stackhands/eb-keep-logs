//! `test-bundle`: record a comparable flaky-test evidence bundle.
//! `test-compare`: summarize differing fields across such bundles.
const std = @import("std");
const common = @import("zig_common");
const cli = common.cli;
const cli_parse = @import("cli_parse.zig");
const fsx = common.fsx;
const sys = common.sys;

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
const read_limit: usize = 64 * 1024 * 1024;

pub const bundle_schema_version: u32 = 1;
pub const compare_schema_version: u32 = 1;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

fn readFile(gpa: Allocator, path: []const u8) ?[]u8 {
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

fn normalizeText(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var wrote_any = false;
    while (i < text.len) {
        const line_start = i;
        while (i < text.len and text[i] != '\n' and text[i] != '\r') : (i += 1) {}
        var line = text[line_start..i];
        line = std.mem.trimEnd(u8, line, " \t");
        try out.appendSlice(gpa, line);
        wrote_any = wrote_any or line.len > 0;
        if (i < text.len) {
            if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            i += 1;
            try out.append(gpa, '\n');
            wrote_any = true;
        }
    }
    if (!wrote_any) return try out.toOwnedSlice(gpa);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
    return try out.toOwnedSlice(gpa);
}

fn sha256Hex(gpa: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return try gpa.dupe(u8, &out);
}

const InputRecord = struct {
    path: []const u8,
    sha256: []const u8,
};

const ModuleRecord = struct {
    name: []const u8,
    path: []const u8,
};

const StreamRecord = struct {
    normalized: []const u8,
    sha256: []const u8,
};

const SchedulerRecord = struct {
    allocation: []const u8,
    binding: []const u8,
};

const HardwareRecord = struct {
    cpu: []const u8,
    gpu: []const u8,
};

const SeedRecord = struct {
    value: []const u8,
    sha256: []const u8,
};

const BundleRecord = struct {
    schema_version: u32 = bundle_schema_version,
    kind: []const u8 = "test-bundle",
    test_id: []const u8,
    suite_revision: []const u8,
    eessi_target: []const u8,
    stdout: StreamRecord,
    stderr: StreamRecord,
    inputs: []const InputRecord,
    input_hash_sha256: []const u8,
    seed: SeedRecord,
    modules: []const ModuleRecord,
    scheduler: SchedulerRecord,
    hardware: HardwareRecord,
};

fn lessModule(_: void, a: ModuleRecord, b: ModuleRecord) bool {
    if (std.mem.lessThan(u8, a.name, b.name)) return true;
    if (std.mem.lessThan(u8, b.name, a.name)) return false;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessInput(_: void, a: InputRecord, b: InputRecord) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn parseModule(gpa: Allocator, raw: []const u8) !ModuleRecord {
    if (!modulePairOk(raw)) die("test-bundle needs --module NAME=PATH", .{});
    const sep = std.mem.indexOfScalar(u8, raw, '=').?;
    const name = std.mem.trim(u8, raw[0..sep], " \t");
    const path = std.mem.trim(u8, raw[sep + 1 ..], " \t");
    return .{
        .name = try gpa.dupe(u8, name),
        .path = try gpa.dupe(u8, path),
    };
}

fn modulePairOk(raw: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, raw, '=') orelse return false;
    const name = std.mem.trim(u8, raw[0..sep], " \t");
    const path = std.mem.trim(u8, raw[sep + 1 ..], " \t");
    return name.len != 0 and path.len != 0;
}

fn validModule(gpa: Allocator, raw: []const u8) Allocator.Error!cli_parse.ValidationResult {
    if (!modulePairOk(raw)) return .{ .err = try gpa.dupe(u8, "module") };
    return .ok;
}

const bundle_cli = cli_parse.make(.{
    .prog = "test-bundle",
    .options = &.{
        cli_parse.req("test-id"),
        cli_parse.req("suite-revision"),
        cli_parse.req("eessi-target"),
        cli_parse.req("stdout"),
        cli_parse.req("stderr"),
        cli_parse.req("allocation"),
        cli_parse.req("binding"),
        cli_parse.req("cpu"),
        cli_parse.req("gpu"),
        cli_parse.strict("seed"),
        cli_parse.strict("out"),
        cli_parse.append("input"),
        cli_parse.checked(cli_parse.append("module"), validModule),
    },
    .missing = &.{
        .{ .name = "input", .msg = "test-bundle needs --input PATH" },
        .{ .name = "module", .msg = "test-bundle needs --module NAME=PATH" },
    },
});

const compare_cli = cli_parse.make(.{
    .prog = "test-compare",
    .options = &.{cli_parse.flag("json")},
    .positionals = &.{cli_parse.zeroOrMore("FILE")},
});

fn combinedInputHash(gpa: Allocator, inputs: []const InputRecord) ![]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (inputs) |input| {
        hash.update(input.path);
        hash.update("\x00");
        hash.update(input.sha256);
        hash.update("\n");
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{digest}) catch unreachable;
    return try gpa.dupe(u8, &out);
}

fn writeOutput(path: []const u8, body: []const u8) !void {
    const fd = try sys.openat(fsx.cwd, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, body);
}

pub fn cmdTestBundle(gpa: Allocator, args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = bundle_cli.take(gpa, args);
    defer parsed.deinit(gpa);
    const test_id = parsed.value("test-id").?;
    const suite_revision = parsed.value("suite-revision").?;
    const eessi_target = parsed.value("eessi-target").?;
    const seed = parsed.value("seed") orelse "";
    const allocation = parsed.value("allocation").?;
    const binding = parsed.value("binding").?;
    const cpu = parsed.value("cpu").?;
    const gpu = parsed.value("gpu").?;
    const stdout_path = parsed.value("stdout").?;
    const stderr_path = parsed.value("stderr").?;
    const out_path = parsed.value("out");
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(arena);
    for (parsed.values("input")) |value| inputs.append(arena, value) catch die("out of memory", .{});
    var modules: std.ArrayList(ModuleRecord) = .empty;
    defer modules.deinit(arena);
    for (parsed.values("module")) |value| {
        modules.append(arena, parseModule(arena, value) catch die("out of memory", .{})) catch die("out of memory", .{});
    }

    const stdout_raw = readFile(gpa, stdout_path) orelse return 2;
    defer gpa.free(stdout_raw);
    const stderr_raw = readFile(gpa, stderr_path) orelse return 2;
    defer gpa.free(stderr_raw);

    const stdout_norm = normalizeText(arena, stdout_raw) catch die("out of memory", .{});
    const stderr_norm = normalizeText(arena, stderr_raw) catch die("out of memory", .{});
    const stdout_hash = sha256Hex(arena, stdout_norm) catch die("out of memory", .{});
    const stderr_hash = sha256Hex(arena, stderr_norm) catch die("out of memory", .{});
    const seed_hash = sha256Hex(arena, seed) catch die("out of memory", .{});

    var input_records: std.ArrayList(InputRecord) = .empty;
    defer input_records.deinit(arena);
    for (inputs.items) |path| {
        const content = readFile(gpa, path) orelse return 2;
        defer gpa.free(content);
        input_records.append(arena, .{
            .path = arena.dupe(u8, path) catch die("out of memory", .{}),
            .sha256 = sha256Hex(arena, content) catch die("out of memory", .{}),
        }) catch die("out of memory", .{});
    }
    std.mem.sort(InputRecord, input_records.items, {}, lessInput);
    std.mem.sort(ModuleRecord, modules.items, {}, lessModule);
    const input_hash = combinedInputHash(arena, input_records.items) catch die("out of memory", .{});

    const bundle: BundleRecord = .{
        .test_id = test_id,
        .suite_revision = suite_revision,
        .eessi_target = eessi_target,
        .stdout = .{ .normalized = stdout_norm, .sha256 = stdout_hash },
        .stderr = .{ .normalized = stderr_norm, .sha256 = stderr_hash },
        .inputs = input_records.items,
        .input_hash_sha256 = input_hash,
        .seed = .{ .value = seed, .sha256 = seed_hash },
        .modules = modules.items,
        .scheduler = .{ .allocation = allocation, .binding = binding },
        .hardware = .{ .cpu = cpu, .gpu = gpu },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    std.json.Stringify.value(bundle, .{}, &out.writer) catch die("out of memory", .{});
    out.writer.writeAll("\n") catch die("out of memory", .{});

    const body = out.toOwnedSlice() catch die("out of memory", .{});
    if (out_path) |p| {
        writeOutput(p, body) catch |err|
            die("cannot write {s}: {t}", .{ p, err });
    } else {
        cli.out("{s}", .{body});
    }
    return 0;
}

const BundleCore = struct {
    label: []const u8,
    test_id: []const u8,
    suite_revision: []const u8,
    eessi_target: []const u8,
    stdout_hash: []const u8,
    stderr_hash: []const u8,
    input_hash: []const u8,
    seed_hash: []const u8,
    modules_key: []const u8,
    allocation: []const u8,
    binding: []const u8,
    cpu: []const u8,
    gpu: []const u8,
};

const FieldDiff = struct {
    field: []const u8,
    values: []const ValueGroup,
};

const ValueGroup = struct {
    value: []const u8,
    bundles: []const []const u8,
};

const CompareJson = struct {
    schema_version: u32 = compare_schema_version,
    kind: []const u8 = "test-compare",
    bundle_count: usize,
    differing_fields: []const FieldDiff,
};

fn getString(obj: std.json.ObjectMap, key: []const u8) error{BadBundle}![]const u8 {
    const v = obj.get(key) orelse return error.BadBundle;
    return switch (v) {
        .string => |s| s,
        else => error.BadBundle,
    };
}

fn modulesKey(gpa: Allocator, modules: std.json.Value) ![]u8 {
    const arr = switch (modules) {
        .array => |a| a,
        else => return error.BadBundle,
    };
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.BadBundle,
        };
        const name = try getString(obj, "name");
        const path = try getString(obj, "path");
        rows.append(gpa, try std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ name, path })) catch return error.OutOfMemory;
    }
    std.mem.sort([]const u8, rows.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (rows.items) |row| {
        const sep = std.mem.indexOfScalar(u8, row, 0) orelse continue;
        try out.print(gpa, "{s}={s}\n", .{ row[0..sep], row[sep + 1 ..] });
    }
    return try out.toOwnedSlice(gpa);
}

fn parseBundle(gpa: Allocator, label: []const u8, text: []const u8) !BundleCore {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.BadBundle;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const version = switch (root.get("schema_version") orelse return error.BadBundle) {
        .integer => |n| n,
        else => return error.BadBundle,
    };
    if (version != bundle_schema_version) return error.BadBundle;
    const kind = try getString(root, "kind");
    if (!std.mem.eql(u8, kind, "test-bundle")) return error.BadBundle;
    const test_id = try getString(root, "test_id");
    const suite_revision = try getString(root, "suite_revision");
    const eessi_target = try getString(root, "eessi_target");
    const input_hash = try getString(root, "input_hash_sha256");

    const stdout_obj = switch (root.get("stdout") orelse return error.BadBundle) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const stderr_obj = switch (root.get("stderr") orelse return error.BadBundle) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const seed_obj = switch (root.get("seed") orelse return error.BadBundle) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const scheduler_obj = switch (root.get("scheduler") orelse return error.BadBundle) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const hardware_obj = switch (root.get("hardware") orelse return error.BadBundle) {
        .object => |o| o,
        else => return error.BadBundle,
    };
    const modules_obj = root.get("modules") orelse return error.BadBundle;
    const key = try modulesKey(gpa, modules_obj);

    return .{
        .label = try gpa.dupe(u8, label),
        .test_id = try gpa.dupe(u8, test_id),
        .suite_revision = try gpa.dupe(u8, suite_revision),
        .eessi_target = try gpa.dupe(u8, eessi_target),
        .stdout_hash = try gpa.dupe(u8, try getString(stdout_obj, "sha256")),
        .stderr_hash = try gpa.dupe(u8, try getString(stderr_obj, "sha256")),
        .input_hash = try gpa.dupe(u8, input_hash),
        .seed_hash = try gpa.dupe(u8, try getString(seed_obj, "sha256")),
        .modules_key = key,
        .allocation = try gpa.dupe(u8, try getString(scheduler_obj, "allocation")),
        .binding = try gpa.dupe(u8, try getString(scheduler_obj, "binding")),
        .cpu = try gpa.dupe(u8, try getString(hardware_obj, "cpu")),
        .gpu = try gpa.dupe(u8, try getString(hardware_obj, "gpu")),
    };
}

fn appendFieldDiff(
    gpa: Allocator,
    arena: Allocator,
    diffs: *std.ArrayList(FieldDiff),
    bundles: []const BundleCore,
    comptime name: []const u8,
    comptime valueOf: fn (BundleCore) []const u8,
) !void {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(gpa);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(gpa);
    var labels: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    defer {
        for (labels.items) |*x| x.deinit(gpa);
        labels.deinit(gpa);
    }
    for (bundles) |bundle| {
        const value = valueOf(bundle);
        const got = try seen.getOrPut(gpa, value);
        if (!got.found_existing) {
            got.value_ptr.* = values.items.len;
            try values.append(gpa, value);
            const group: std.ArrayList([]const u8) = .empty;
            try labels.append(gpa, group);
        }
        try labels.items[got.value_ptr.*].append(gpa, bundle.label);
    }
    if (values.items.len <= 1) return;
    var groups: std.ArrayList(ValueGroup) = .empty;
    for (values.items, 0..) |value, idx| {
        try groups.append(arena, .{
            .value = try arena.dupe(u8, value),
            .bundles = try labels.items[idx].toOwnedSlice(arena),
        });
    }
    try diffs.append(arena, .{
        .field = name,
        .values = try groups.toOwnedSlice(arena),
    });
}

fn valueTestId(b: BundleCore) []const u8 {
    return b.test_id;
}
fn valueSuiteRevision(b: BundleCore) []const u8 {
    return b.suite_revision;
}
fn valueEessiTarget(b: BundleCore) []const u8 {
    return b.eessi_target;
}
fn valueStdoutHash(b: BundleCore) []const u8 {
    return b.stdout_hash;
}
fn valueStderrHash(b: BundleCore) []const u8 {
    return b.stderr_hash;
}
fn valueInputHash(b: BundleCore) []const u8 {
    return b.input_hash;
}
fn valueSeedHash(b: BundleCore) []const u8 {
    return b.seed_hash;
}
fn valueModules(b: BundleCore) []const u8 {
    return b.modules_key;
}
fn valueAllocation(b: BundleCore) []const u8 {
    return b.allocation;
}
fn valueBinding(b: BundleCore) []const u8 {
    return b.binding;
}
fn valueCpu(b: BundleCore) []const u8 {
    return b.cpu;
}
fn valueGpu(b: BundleCore) []const u8 {
    return b.gpu;
}

pub fn cmdTestCompare(gpa: Allocator, args: []const []const u8) u8 {
    var parsed = compare_cli.take(gpa, args);
    defer parsed.deinit(gpa);
    const json_out = parsed.seen("json");
    const files = parsed.positionals;
    if (files.len < 2) die("test-compare needs at least two bundle files", .{});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bundles: std.ArrayList(BundleCore) = .empty;
    defer bundles.deinit(arena);
    for (files) |path| {
        const text = readFile(gpa, path) orelse return 2;
        defer gpa.free(text);
        const bundle = parseBundle(arena, path, text) catch {
            warn("test-compare: {s} is not a test-bundle schema_version {d} document", .{ path, bundle_schema_version });
            return 2;
        };
        bundles.append(arena, bundle) catch die("out of memory", .{});
    }

    var diffs: std.ArrayList(FieldDiff) = .empty;
    appendFieldDiff(arena, arena, &diffs, bundles.items, "test_id", valueTestId) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "suite_revision", valueSuiteRevision) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "eessi_target", valueEessiTarget) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "stdout_sha256", valueStdoutHash) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "stderr_sha256", valueStderrHash) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "input_hash_sha256", valueInputHash) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "seed_sha256", valueSeedHash) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "modules", valueModules) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "scheduler.allocation", valueAllocation) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "scheduler.binding", valueBinding) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "hardware.cpu", valueCpu) catch die("out of memory", .{});
    appendFieldDiff(arena, arena, &diffs, bundles.items, "hardware.gpu", valueGpu) catch die("out of memory", .{});

    if (json_out) {
        const doc: CompareJson = .{
            .bundle_count = bundles.items.len,
            .differing_fields = diffs.items,
        };
        var writer: std.Io.Writer.Allocating = .init(gpa);
        defer writer.deinit();
        std.json.Stringify.value(doc, .{}, &writer.writer) catch die("out of memory", .{});
        writer.writer.writeAll("\n") catch die("out of memory", .{});
        const body = writer.toOwnedSlice() catch die("out of memory", .{});
        defer gpa.free(body);
        cli.out("{s}", .{body});
        return 0;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.print(gpa, "Compared {d} bundles.\n", .{bundles.items.len}) catch die("out of memory", .{});
    if (diffs.items.len == 0) {
        out.appendSlice(gpa, "No differing fields.\n") catch die("out of memory", .{});
    } else {
        out.appendSlice(gpa, "Differing fields:\n") catch die("out of memory", .{});
        for (diffs.items) |diff| {
            out.print(gpa, "- {s}\n", .{diff.field}) catch die("out of memory", .{});
            for (diff.values) |value_group| {
                out.print(gpa, "    value={s}\n", .{value_group.value}) catch die("out of memory", .{});
                for (value_group.bundles) |label| {
                    out.print(gpa, "      {s}\n", .{label}) catch die("out of memory", .{});
                }
            }
        }
    }
    const body = out.toOwnedSlice(gpa) catch die("out of memory", .{});
    defer gpa.free(body);
    cli.out("{s}", .{body});
    return 0;
}

test "normalize text unifies line endings and trailing blanks" {
    const got = try normalizeText(std.testing.allocator, "a  \r\nb\t\rend");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a\nb\nend\n", got);
}

test "test-compare sees differing fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const one =
        \\{"schema_version":1,"kind":"test-bundle","test_id":"qe.suite.test1","suite_revision":"abc","eessi_target":"zen4","stdout":{"normalized":"ok\n","sha256":"1"},"stderr":{"normalized":"","sha256":"2"},"inputs":[],"input_hash_sha256":"3","seed":{"value":"7","sha256":"4"},"modules":[{"name":"A","path":"/a"}],"scheduler":{"allocation":"nodes=1","binding":"core"},"hardware":{"cpu":"cpu-a","gpu":"gpu-a"}}
    ;
    const two =
        \\{"schema_version":1,"kind":"test-bundle","test_id":"qe.suite.test1","suite_revision":"abc","eessi_target":"zen4","stdout":{"normalized":"ok\n","sha256":"9"},"stderr":{"normalized":"","sha256":"2"},"inputs":[],"input_hash_sha256":"3","seed":{"value":"7","sha256":"4"},"modules":[{"name":"A","path":"/a"}],"scheduler":{"allocation":"nodes=2","binding":"core"},"hardware":{"cpu":"cpu-a","gpu":"gpu-a"}}
    ;
    const b1 = try parseBundle(gpa, "one.json", one);
    const b2 = try parseBundle(gpa, "two.json", two);
    const arena = gpa;
    var diffs: std.ArrayList(FieldDiff) = .empty;
    try appendFieldDiff(gpa, arena, &diffs, &.{ b1, b2 }, "stdout_sha256", valueStdoutHash);
    try appendFieldDiff(gpa, arena, &diffs, &.{ b1, b2 }, "scheduler.allocation", valueAllocation);
    try std.testing.expectEqual(@as(usize, 2), diffs.items.len);
}
