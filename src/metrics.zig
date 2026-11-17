//! Prometheus textfile metrics, updated atomically beside their destination.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const fsx = common.fsx;
const sys = common.sys;

const Allocator = std.mem.Allocator;

const State = struct {
    logs_kept: u64 = 0,
    bytes_kept: u64 = 0,
    last_prune: i64 = 0,
};

const logs_name = "eb_keep_logs_logs_kept_total";
const bytes_name = "eb_keep_logs_bytes_kept_total";
const prune_name = "eb_keep_logs_last_prune_timestamp_seconds";

fn parseSample(line: []const u8, comptime name: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    if (line.len <= name.len or line[name.len] != ' ') return error.InvalidMetrics;
    const value = std.mem.trim(u8, line[name.len + 1 ..], " \t\r");
    if (value.len == 0) return error.InvalidMetrics;
    return value;
}

fn parse(text: []const u8) !State {
    var state: State = .{};
    var have_logs = false;
    var have_bytes = false;
    var have_prune = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (try parseSample(line, logs_name)) |value| {
            if (have_logs) return error.InvalidMetrics;
            state.logs_kept = std.fmt.parseInt(u64, value, 10) catch return error.InvalidMetrics;
            have_logs = true;
        } else if (try parseSample(line, bytes_name)) |value| {
            if (have_bytes) return error.InvalidMetrics;
            state.bytes_kept = std.fmt.parseInt(u64, value, 10) catch return error.InvalidMetrics;
            have_bytes = true;
        } else if (try parseSample(line, prune_name)) |value| {
            if (have_prune) return error.InvalidMetrics;
            state.last_prune = std.fmt.parseInt(i64, value, 10) catch return error.InvalidMetrics;
            if (state.last_prune < 0) return error.InvalidMetrics;
            have_prune = true;
        }
    }
    return state;
}

fn render(gpa: Allocator, state: State) ![]u8 {
    return gpa.print(
        \\# HELP eb_keep_logs_logs_kept_total Log files kept by eb-keep-logs.
        \\# TYPE eb_keep_logs_logs_kept_total counter
        \\eb_keep_logs_logs_kept_total {d}
        \\# HELP eb_keep_logs_bytes_kept_total Bytes written to kept log files by eb-keep-logs.
        \\# TYPE eb_keep_logs_bytes_kept_total counter
        \\eb_keep_logs_bytes_kept_total {d}
        \\# HELP eb_keep_logs_last_prune_timestamp_seconds Unix timestamp of the last completed eb-keep-logs rotation.
        \\# TYPE eb_keep_logs_last_prune_timestamp_seconds gauge
        \\eb_keep_logs_last_prune_timestamp_seconds {d}
        \\
    , .{ state.logs_kept, state.bytes_kept, state.last_prune });
}

fn lock(fd: fsx.fd_t) !void {
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX);
        if (linux.errno(rc) == .INTR) continue;
        _ = try sys.result(rc);
        return;
    }
}

fn realtimeSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn keepLatestCompletion(state: *State, timestamp: i64) !void {
    if (timestamp < 0) return error.InvalidTimestamp;
    state.last_prune = @max(state.last_prune, timestamp);
}

/// Add one invocation's known values to a Prometheus textfile. The file is
/// replaced by a synced temporary file in the same directory, under a
/// sidecar lock, so concurrent writers do not lose counter increments. A
/// completion time is chosen while holding that lock and never moves back.
pub fn update(gpa: Allocator, path: []const u8, logs_kept: u64, bytes_kept: u64, record_completion: bool) !void {
    if (path.len == 0) return error.EmptyPath;
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.EmptyPath;
    const parent_path = std.fs.path.dirname(path) orelse ".";
    const dir = try fsx.openDir(fsx.cwd, parent_path, true);
    defer sys.close(dir);

    const lock_name = try gpa.print(".{s}.lock", .{base});
    defer gpa.free(lock_name);
    const lock_fd = try sys.openat(dir, lock_name, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
        .NOFOLLOW = true,
    }, 0o600);
    defer sys.close(lock_fd);
    if (!(try fsx.fstat(lock_fd)).isReg()) return error.InvalidArgument;
    try lock(lock_fd);

    var state: State = .{};
    var mode: u32 = 0o644;
    if (fsx.openRegular(dir, base, false)) |existing| {
        defer sys.close(existing.fd);
        mode = existing.stat.perm();
        const text = try fsx.readAll(gpa, existing.fd, 1 << 20);
        defer gpa.free(text);
        state = try parse(text);
    } else |err| switch (err) {
        error.NotFound => {},
        else => |e| return e,
    }
    state.logs_kept = std.math.add(u64, state.logs_kept, logs_kept) catch return error.Overflow;
    state.bytes_kept = std.math.add(u64, state.bytes_kept, bytes_kept) catch return error.Overflow;
    if (record_completion) try keepLatestCompletion(&state, realtimeSeconds());
    const text = try render(gpa, state);
    defer gpa.free(text);

    var random: [4]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &random, random.len, 0 });
    const tmp = try gpa.print(".{s}.{d}.{x:0>8}.tmp", .{ base, linux.getpid(), std.mem.readInt(u32, &random, .little) });
    defer gpa.free(tmp);
    const fd = try sys.openat(dir, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @intCast(mode));
    var renamed = false;
    defer {
        sys.close(fd);
        if (!renamed) sys.unlinkat(dir, tmp, 0) catch {};
    }
    // openat applies the process umask even when replacing an existing file.
    // Restore the exact previous mode (or 0644 for a new file), as the shell
    // implementation's chmod does, before publishing the temporary file.
    try sys.fchmod(fd, @intCast(mode));
    try sys.writeAll(fd, text);
    try sys.fsync(fd);
    try sys.renameat(dir, tmp, dir, base);
    renamed = true;
    try sys.fsync(dir);
}

test "parse and render metrics" {
    const gpa = std.testing.allocator;
    const text = try render(gpa, .{ .logs_kept = 3, .bytes_kept = 57, .last_prune = 1_700_000_000 });
    defer gpa.free(text);
    try std.testing.expectEqual(State{
        .logs_kept = 3,
        .bytes_kept = 57,
        .last_prune = 1_700_000_000,
    }, try parse(text));
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total NaN\n"));
    try std.testing.expectError(error.InvalidMetrics, parse(
        "eb_keep_logs_logs_kept_total 1\neb_keep_logs_logs_kept_total 2\n",
    ));
}

test "update preserves counters and replaces the whole file" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/eb-keep-logs-metrics-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    try common.atomic.makedirs(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const path = try std.fmt.allocPrint(gpa, "{s}/collector.prom", .{base});
    defer gpa.free(path);

    try update(gpa, path, 2, 19, false);
    const created = try fsx.openRegular(fsx.cwd, path, false);
    try std.testing.expectEqual(@as(u32, 0o644), created.stat.perm());
    try sys.fchmod(created.fd, 0o640);
    sys.close(created.fd);
    try update(gpa, path, 1, 5, false);
    const file = try fsx.openRegular(fsx.cwd, path, false);
    defer sys.close(file.fd);
    try std.testing.expectEqual(@as(u32, 0o640), file.stat.perm());
    const text = try fsx.readAll(gpa, file.fd, 1 << 20);
    defer gpa.free(text);
    try std.testing.expectEqual(State{ .logs_kept = 3, .bytes_kept = 24, .last_prune = 0 }, try parse(text));
}

test "completion timestamps never move backwards" {
    var state: State = .{ .last_prune = 1200 };
    try keepLatestCompletion(&state, 1234);
    try keepLatestCompletion(&state, 1210);
    try std.testing.expectEqual(@as(i64, 1234), state.last_prune);
    try std.testing.expectError(error.InvalidTimestamp, keepLatestCompletion(&state, -1));
}
