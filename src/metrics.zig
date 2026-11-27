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

/// The value of a sample named `name`, or null when `line` is some other
/// sample. A label set may sit between the name and the value. Quoted text
/// uses the Prometheus escapes `\\`, `\n` and `\"`, and a `}` inside quotes
/// does not end the set. Prometheus puts one integer timestamp after the
/// value, and a tab separates the fields the same way a space does. A line
/// that starts with `name` and is not that sample is invalid.
fn parseSample(line_in: []const u8, comptime name: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, line_in, name)) return null;
    const line = std.mem.trimEnd(u8, line_in, "\r");
    if (line.len <= name.len) return error.InvalidMetrics;
    const next = line[name.len];
    if (next != '{' and next != ' ' and next != '\t') return error.InvalidMetrics;
    var scan: SampleScan = .{ .line = line, .i = name.len };
    scan.skipWs();
    if (scan.i < scan.line.len and scan.line[scan.i] == '{') {
        try scan.skipLabelSet();
        scan.skipWs();
    }
    if (scan.i >= scan.line.len) return error.InvalidMetrics;
    const value_at = scan.i;
    while (scan.i < scan.line.len and scan.line[scan.i] != ' ' and scan.line[scan.i] != '\t') scan.i += 1;
    const value = scan.line[value_at..scan.i];
    if (value.len == 0) return error.InvalidMetrics;
    scan.skipWs();
    if (scan.i < scan.line.len) {
        const ts_at = scan.i;
        while (scan.i < scan.line.len and scan.line[scan.i] != ' ' and scan.line[scan.i] != '\t') scan.i += 1;
        const ts = scan.line[ts_at..scan.i];
        scan.skipWs();
        if (scan.i < scan.line.len or ts.len == 0) return error.InvalidMetrics;
        _ = std.fmt.parseInt(i64, ts, 10) catch return error.InvalidMetrics;
    }
    return value;
}

const SampleScan = struct {
    line: []const u8,
    i: usize,
    storage: [4096]u8 = undefined,
    used: usize = 0,
    seen: [64][]const u8 = undefined,
    seen_n: usize = 0,

    fn skipWs(self: *SampleScan) void {
        while (self.i < self.line.len and (self.line[self.i] == ' ' or self.line[self.i] == '\t')) self.i += 1;
    }

    fn push(self: *SampleScan, byte: u8) !void {
        if (self.used >= self.storage.len) return error.InvalidMetrics;
        self.storage[self.used] = byte;
        self.used += 1;
    }

    /// Unescape a Prometheus quoted string. `self.i` is on the opening quote
    /// and finishes just after the closing quote.
    fn readQuoted(self: *SampleScan) ![]const u8 {
        if (self.i >= self.line.len or self.line[self.i] != '"') return error.InvalidMetrics;
        self.i += 1;
        const start = self.used;
        while (self.i < self.line.len) {
            const c = self.line[self.i];
            self.i += 1;
            if (c == '"') return self.storage[start..self.used];
            if (c == '\\') {
                if (self.i >= self.line.len) return error.InvalidMetrics;
                const e = self.line[self.i];
                self.i += 1;
                switch (e) {
                    '\\', '"' => try self.push(e),
                    'n' => try self.push('\n'),
                    else => return error.InvalidMetrics,
                }
            } else try self.push(c);
        }
        return error.InvalidMetrics;
    }

    fn readName(self: *SampleScan) ![]const u8 {
        if (self.i >= self.line.len) return error.InvalidMetrics;
        if (self.line[self.i] == '"') return self.readQuoted();
        if (!labelNameStart(self.line[self.i])) return error.InvalidMetrics;
        const start = self.i;
        self.i += 1;
        while (self.i < self.line.len and labelNameCont(self.line[self.i])) self.i += 1;
        return self.line[start..self.i];
    }

    fn remember(self: *SampleScan, label_name: []const u8) !void {
        if (!legacyLabelName(label_name)) return error.InvalidMetrics;
        for (self.seen[0..self.seen_n]) |prev| {
            if (std.mem.eql(u8, prev, label_name)) return error.InvalidMetrics;
        }
        if (self.seen_n >= self.seen.len) return error.InvalidMetrics;
        self.seen[self.seen_n] = label_name;
        self.seen_n += 1;
    }

    fn skipLabelSet(self: *SampleScan) !void {
        if (self.i >= self.line.len or self.line[self.i] != '{') return error.InvalidMetrics;
        self.i += 1;
        self.skipWs();
        if (self.i < self.line.len and self.line[self.i] == '}') {
            self.i += 1;
            return;
        }
        while (true) {
            const label_name = try self.readName();
            try self.remember(label_name);
            self.skipWs();
            if (self.i >= self.line.len or self.line[self.i] != '=') return error.InvalidMetrics;
            self.i += 1;
            self.skipWs();
            const value = try self.readQuoted();
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidMetrics;
            self.skipWs();
            if (self.i >= self.line.len) return error.InvalidMetrics;
            if (self.line[self.i] == '}') {
                self.i += 1;
                return;
            }
            if (self.line[self.i] != ',') return error.InvalidMetrics;
            self.i += 1;
            self.skipWs();
            if (self.i < self.line.len and self.line[self.i] == '}') {
                self.i += 1;
                return;
            }
        }
    }
};

fn labelNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn labelNameCont(c: u8) bool {
    return labelNameStart(c) or (c >= '0' and c <= '9');
}

fn legacyLabelName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "__name__")) return false;
    if (!labelNameStart(name[0])) return false;
    for (name[1..]) |c| if (!labelNameCont(c)) return false;
    return true;
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

fn lock(fd: fsx.fd_t) sys.Error!void {
    common.state.lockExclusive(fd, null) catch |err| switch (err) {
        error.TimedOut => unreachable,
        else => |e| return e,
    };
}

fn clockFile(path: []const u8) ?i64 {
    const fd = sys.openat(fsx.cwd, path, .{}, 0) catch return null;
    defer sys.close(fd);
    var buf: [64]u8 = undefined;
    const n = sys.read(fd, &buf) catch return null;
    if (n == 0) return null;
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// The value of `name` in `/proc/self/environ`, copied into `buf`. The
/// binary does not link libc, so this is the getenv the product can make.
fn envFile(name: []const u8, buf: []u8) ?[]const u8 {
    const opened = fsx.openRegular(fsx.cwd, "/proc/self/environ", false) catch return null;
    defer sys.close(opened.fd);
    var chunk: [4096]u8 = undefined;
    var held: usize = 0;
    var at_entry = true;
    var copying = false;
    var ncopy: usize = 0;
    while (true) {
        const n = sys.read(opened.fd, &chunk) catch return null;
        if (n == 0) return null;
        for (chunk[0..n]) |b| {
            if (copying) {
                if (b == 0) return buf[0..ncopy];
                if (ncopy == buf.len) return null;
                buf[ncopy] = b;
                ncopy += 1;
                continue;
            }
            if (at_entry and held < name.len and b == name[held]) {
                held += 1;
                if (held == name.len) {
                    if (b == '=') copying = true else at_entry = false;
                }
                continue;
            }
            held = 0;
            at_entry = b == 0;
        }
    }
}

/// `EB_KEEP_LOGS_CLOCK` is a file holding the stamp, so a test can freeze it
/// and then jump it while a rotate waits on the metrics lock. Unset, the
/// stamp is `CLOCK_REALTIME`.
fn realtimeSeconds() i64 {
    var path_buf: [sys.path_max]u8 = undefined;
    if (envFile("EB_KEEP_LOGS_CLOCK=", &path_buf)) |path| {
        if (clockFile(path)) |stamp| return stamp;
    }
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

test "parse reads a counter beside an escaped label set" {
    const labeled = "eb_keep_logs_logs_kept_total{path=\"say \\\"hi\\\"\",raw=\"x}y\",bs=\"a\\\\\"} 4 1700000000000\n" ++
        "eb_keep_logs_bytes_kept_total{msg=\"line\\nnext\"}\t20\n" ++
        "eb_keep_logs_last_prune_timestamp_seconds{ when = \"x\" , } 9\n";
    try std.testing.expectEqual(State{
        .logs_kept = 4,
        .bytes_kept = 20,
        .last_prune = 9,
    }, try parse(labeled));
    try std.testing.expectEqual(@as(u64, 4), (try parse("eb_keep_logs_logs_kept_total{} 4\n")).logs_kept);
    try std.testing.expectEqual(@as(u64, 4), (try parse("eb_keep_logs_logs_kept_total{path=\"z\"}4\n")).logs_kept);
    try std.testing.expectEqual(@as(u64, 4), (try parse("eb_keep_logs_logs_kept_total{path=\"caf\xc3\xa9\"} 4\n")).logs_kept);
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total{path=\"a\\q\"} 4\n"));
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total{a=\"1\",a=\"2\"} 4\n"));
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total{\"a\"=\"1\",a=\"2\"} 4\n"));
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total{path=\"\xff\"} 4\n"));
    try std.testing.expectError(error.InvalidMetrics, parse("eb_keep_logs_logs_kept_total{__name__=\"x\"} 4\n"));
    try std.testing.expectError(error.InvalidMetrics, parse(
        "eb_keep_logs_logs_kept_total 1\neb_keep_logs_logs_kept_total{a=\"b\"} 2\n",
    ));
}

fn onUsr1(_: linux.SIG) callconv(.c) void {}

test "lock retries EINTR while waiting and reports non-contention flock errors" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/eb-keep-logs-metrics-lock-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    try common.atomic.makedirs(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};

    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);
    const held = try sys.openat(dir, "L", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer sys.close(held);
    const waiter = try sys.openat(dir, "L", .{ .ACCMODE = .RDWR }, 0);
    defer sys.close(waiter);
    _ = try sys.call(linux.flock, .{ held, @as(i32, std.posix.LOCK.EX) });

    const handler: linux.Sigaction = .{ .handler = .{ .handler = &onUsr1 }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.USR1, &handler, &prev);
    defer _ = linux.sigaction(.USR1, &prev, null);

    var poke: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&poke, .{ .CLOEXEC = true })));
    defer {
        _ = linux.close(poke[0]);
        _ = linux.close(poke[1]);
    }

    const pid = linux.getpid();
    const tid = linux.gettid();
    const Releaser = struct {
        fn run(h: fsx.fd_t, target_pid: i32, target_tid: i32, poke_r: i32) void {
            const fl = linux.fcntl(poke_r, linux.F.GETFL, 0);
            _ = linux.fcntl(poke_r, linux.F.SETFL, fl | (1 << @bitOffsetOf(linux.O, "NONBLOCK")));
            while (true) {
                _ = linux.tgkill(target_pid, target_tid, .USR1);
                var b: [1]u8 = undefined;
                if (linux.read(poke_r, &b, 1) == 1) break;
            }
            _ = linux.flock(h, std.posix.LOCK.UN);
        }
    };
    const thread = try std.Thread.spawn(.{}, Releaser.run, .{ held, pid, tid, poke[0] });
    defer thread.join();

    // Record that blocking `flock` returned `EINTR` before the helper unlocks.
    var eintr = false;
    while (true) {
        const rc = linux.flock(waiter, @as(i32, std.posix.LOCK.EX));
        switch (linux.errno(rc)) {
            .SUCCESS => break,
            .INTR => {
                eintr = true;
                var b = [_]u8{1};
                _ = linux.write(poke[1], &b, 1);
            },
            else => break,
        }
    }
    defer _ = linux.flock(waiter, std.posix.LOCK.UN);
    try std.testing.expect(eintr);
    try std.testing.expectEqual(linux.E.AGAIN, linux.errno(linux.flock(held, std.posix.LOCK.EX | std.posix.LOCK.NB)));

    const opath = try sys.openat(fsx.cwd, "/", .{ .PATH = true }, 0);
    defer sys.close(opath);
    try std.testing.expectError(error.InvalidArgument, lock(opath));
    try std.testing.expectEqual(linux.E.BADF, sys.last_errno);
}
