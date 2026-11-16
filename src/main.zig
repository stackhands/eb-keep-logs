//! eb-keep-logs: keep the logs of EasyBuild builds that a build pipeline
//! would otherwise lose, and keep the pipeline's log tree bounded.
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const env = common.env;
const logs = common.logs;
const cli = common.cli;
const localtime = @import("localtime.zig");
const scan = @import("scan.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
pub const version = "0.2.1";

const usage_text =
    \\eb-keep-logs: keep the logs of EasyBuild builds that a build pipeline would
    \\otherwise lose, and keep the pipeline's log tree bounded.
    \\
    \\  eb-keep-logs failed STATUS NAME LOGDIR [TMP_LOGDIR]
    \\      After `eb` returned STATUS for easyconfig NAME: when STATUS is not 0,
    \\      copy the EasyBuild log, the failing command's output and a meson
    \\      testlog next to LOGDIR/NAME.stdout.log, closed to others and listed
    \\      in LOGDIR/.licensed-logs. TMP_LOGDIR is the --tmp-logdir eb ran with;
    \\      without it, the newest log in EasyBuild's default place is used,
    \\      unless it is another build's.
    \\  eb-keep-logs rotate ROOT --compress-after DAYS [--delete-after DAYS]
    \\      In the run directories directly under ROOT (named YYYYMMDD_HHMMSS),
    \\      gzip the logs of runs older than DAYS; with --delete-after, remove
    \\      whole runs older than that. Permissions and .licensed-logs follow.
    \\  eb-keep-logs --help | --version
    \\
;

/// Largest log read whole for scanning; a larger log is copied but not
/// scanned for the command output or meson paths.
const scan_limit: usize = 1 << 30;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    cli.err(tool ++ ": " ++ fmt ++ "\n", args);
}

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,

    fn getenv(c: Ctx, name: []const u8) ?[]const u8 {
        return c.env.get(name);
    }
};

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const LastLog = union(enum) {
    /// The last line `eb --last-log` printed.
    path: []u8,
    no_eb,
    /// The status `eb --last-log` exited with.
    failed: u32,
    /// It printed nothing or could not be run.
    none,
};

/// What `eb --last-log` names. EasyBuild 5 prints through rich, which wraps
/// the path at 80 columns when stdout is not a terminal; the basic output
/// style prints it on one line. An EasyBuild without output styles refuses
/// EASYBUILD_OUTPUT_STYLE, so a failed call is made again without it.
fn lastLog(c: Ctx, tmp_logdir: ?[]const u8) LastLog {
    const path_env = c.getenv("PATH") orelse "";
    const eb = (proc.which(c.gpa, "eb", path_env) catch return .none) orelse return .no_eb;
    defer c.gpa.free(eb);
    var argv_buf: [3][]const u8 = undefined;
    argv_buf[0] = "eb";
    argv_buf[1] = "--last-log";
    var argc: usize = 2;
    var opt: ?[]u8 = null;
    defer if (opt) |o| c.gpa.free(o);
    if (tmp_logdir) |d| {
        opt = c.gpa.print("--tmp-logdir={s}", .{d}) catch return .none;
        argv_buf[2] = opt.?;
        argc = 3;
    }
    var child = env.Builder.fromEnv(c.gpa, env.Env.fromEnvp(c.envp)) catch return .none;
    defer child.deinit();
    child.set("EASYBUILD_OUTPUT_STYLE", "basic") catch return .none;
    var envp = child.envp() catch return .none;
    var r = proc.run(c.gpa, eb, argv_buf[0..argc], envp, .{}) catch return .none;
    if (r.term.code() != 0) {
        r.deinit(c.gpa);
        child.unset("EASYBUILD_OUTPUT_STYLE");
        envp = child.envp() catch return .none;
        r = proc.run(c.gpa, eb, argv_buf[0..argc], envp, .{}) catch return .none;
    }
    defer r.deinit(c.gpa);
    if (r.term.code() != 0) return .{ .failed = r.term.code() };
    var s: []const u8 = r.stdout;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    const line = s[if (std.mem.findScalarLast(u8, s, '\n')) |i| i + 1 else 0..];
    if (line.len == 0) return .none;
    return .{ .path = c.gpa.dupe(u8, line) catch return .none };
}

/// Record a kept file that may carry a licence number.
fn listKept(c: Ctx, logdir: fsx.fd_t, kept: fsx.fd_t) void {
    var rb: [sys.path_max]u8 = undefined;
    const abs = fsx.realpathFd(kept, &rb) catch |err| return warn("cannot resolve a kept file: {t}", .{err});
    fsx.appendLine(c.gpa, logdir, logs.licensed_list, abs) catch |err|
        warn("cannot list {s} in {s}: {t}", .{ abs, logs.licensed_list, err });
}

/// Copy `src` onto `dir/name` by writing a temporary file and renaming it.
/// A short write leaves an existing file as it was: the pinned library's
/// `fsx.copyTo` truncates the destination before the copy finishes, so a
/// full disk would destroy a log that was already kept.
fn copyDurable(dir: fsx.fd_t, name: []const u8, src: fsx.fd_t, src_stat: fsx.Stat) sys.Error!fsx.fd_t {
    const existing: ?fsx.Stat = fsx.statAt(dir, name, false) catch |err| switch (err) {
        error.NotFound => null,
        else => |e| return e,
    };
    if (existing) |st| {
        if (st.isLink()) return error.SymLink;
        if (st.isDir()) return error.IsDir;
        if (!st.isReg()) return error.InvalidArgument;
    }
    var rnd: [4]u8 = undefined;
    _ = try sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 });
    var tmp_buf: [sys.path_max]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, ".{s}.{d}.{x:0>8}.tmp", .{ std.fs.path.basename(name), linux.getpid(), std.mem.readInt(u32, &rnd, .little) }) catch return error.NameTooLong;
    const fd = try sys.openat(dir, tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, if (existing != null) 0o600 else @intCast(src_stat.mode & 0o777));
    var done = false;
    errdefer {
        sys.close(fd);
        if (!done) sys.unlinkat(dir, tmp, 0) catch {};
    }
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(src, &buf);
        if (n == 0) break;
        try sys.writeAll(fd, buf[0..n]);
    }
    if (existing) |st| {
        const now = try fsx.fstat(fd);
        if (now.uid != st.uid or now.gid != st.gid) {
            sys.fchown(fd, st.uid, st.gid) catch |err| switch (err) {
                error.AccessDenied => {},
                else => |e| return e,
            };
        }
        try sys.fchmod(fd, @intCast(st.perm()));
    }
    try sys.fsync(fd);
    try sys.renameat(dir, tmp, dir, name);
    done = true;
    try sys.fsync(dir);
    return fd;
}

/// Copy an open file into LOGDIR as `name`, set its mode to `closed_mode`
/// or, when that is null, take others' bits off the copy's own mode (chmod
/// o-rwx), and list it. False when the copy failed.
fn keep(c: Ctx, logdir: fsx.fd_t, logdir_s: []const u8, src: fsx.fd_t, src_stat: fsx.Stat, name: []const u8, comptime closed_mode: ?u32) bool {
    const fd = copyDurable(logdir, name, src, src_stat) catch |err| {
        warn("cannot keep {s}/{s}: {t}", .{ logdir_s, name, err });
        return false;
    };
    defer sys.close(fd);
    // As chmod o-rwx fails and leaves the mode when the file cannot be
    // read: a copy whose mode is unknown is not set to 000.
    const mode: ?u32 = if (closed_mode) |m| m else if (fsx.fstat(fd)) |st| st.perm() & ~@as(u32, 0o007) else |err| blk: {
        warn("cannot stat {s}/{s}: {t}", .{ logdir_s, name, err });
        break :blk null;
    };
    if (mode) |m| sys.fchmod(fd, @intCast(m)) catch |err| warn("cannot close {s}/{s} to others: {t}", .{ logdir_s, name, err });
    listKept(c, logdir, fd);
    return true;
}

fn rewind(fd: fsx.fd_t) void {
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
}

fn cmdFailed(c: Ctx, args: []const [:0]const u8) u8 {
    if (args.len < 3) die("failed needs STATUS NAME LOGDIR [TMP_LOGDIR]", .{});
    const status = args[0];
    const name = args[1];
    const logdir_s = args[2];
    const explicit: ?[]const u8 = if (args.len >= 4 and args[3].len > 0) args[3] else null;
    if (!allDigits(status)) die("STATUS must be a number, not '{s}'", .{status});
    const logdir = fsx.openDir(fsx.cwd, logdir_s, true) catch die("LOGDIR {s} is not a directory", .{logdir_s});
    defer sys.close(logdir);
    if (std.mem.indexOfNone(u8, status, "0") == null) return 0;

    const src_path: ?[]u8 = switch (lastLog(c, explicit)) {
        .path => |p| p,
        .no_eb => {
            cli.out("No EasyBuild log to keep for {s}: eb is not on PATH.\n", .{name});
            return 0;
        },
        .failed => |code| {
            cli.out("No EasyBuild log to keep for {s}: eb --last-log exited {d}.\n", .{ name, code });
            return 0;
        },
        .none => null,
    };
    defer if (src_path) |p| c.gpa.free(p);
    const src = if (src_path) |p| fsx.openRegular(fsx.cwd, p, true) catch null else null;
    if (src == null) {
        cli.out("No EasyBuild log to keep for {s}.\n", .{name});
        return 0;
    }
    defer sys.close(src.?.fd);

    const src_text: ?[]u8 = fsx.readAll(c.gpa, src.?.fd, scan_limit) catch |err| blk: {
        warn("cannot scan {s}: {t}", .{ src_path.?, err });
        break :blk null;
    };
    defer if (src_text) |t| c.gpa.free(t);
    // Without TMP_LOGDIR, `eb --last-log` names the newest log in
    // EasyBuild's default place, which can be a later build's. Nothing is
    // taken from that log; the build's own stdout log still names its
    // failing command.
    if (explicit == null) if (src_text) |t| if (scan.otherBuild(t, name)) {
        cli.out("No EasyBuild log to keep for {s}: {s} is another build's log.\n", .{ name, src_path.? });
        keepCommandOutput(c, logdir, logdir_s, name, null);
        return 0;
    };

    rewind(src.?.fd);
    const ebout = c.gpa.print("{s}.failed.ebout.log", .{name}) catch return 0;
    defer c.gpa.free(ebout);
    if (keep(c, logdir, logdir_s, src.?.fd, src.?.stat, ebout, null))
        cli.out("Failed build log: {s}/{s}\n", .{ logdir_s, ebout });

    keepCommandOutput(c, logdir, logdir_s, name, src_text);

    // A meson test step prints only the last 100 lines of a failing test;
    // the full output is meson-logs/testlog.txt in the build directory.
    if (src_text) |t| if (scan.lastMesonDir(t)) |dir| {
        const testlog = c.gpa.print("{s}/meson-logs/testlog.txt", .{dir}) catch return 0;
        defer c.gpa.free(testlog);
        if (fsx.openRegular(fsx.cwd, testlog, true)) |tl| {
            defer sys.close(tl.fd);
            const dest = c.gpa.print("{s}.failed.meson-testlog.txt", .{name}) catch return 0;
            defer c.gpa.free(dest);
            if (keep(c, logdir, logdir_s, tl.fd, tl.stat, dest, null))
                cli.out("Failed meson test log: {s}/{s}\n", .{ logdir_s, dest });
        } else |_| {}
    };
    return 0;
}

/// The failing command's own output holds the diagnostic beyond EasyBuild's
/// printed tail. Only the final command's text streams are kept, only from
/// inside EASYBUILD_TMPDIR, not through a symbolic link, and owned by this
/// user. A stream is compared with EASYBUILD_TMPDIR with both resolved, as
/// EasyBuild names the stream through EASYBUILD_TMPDIR as it was given.
fn keepCommandOutput(c: Ctx, logdir: fsx.fd_t, logdir_s: []const u8, name: []const u8, src_text: ?[]const u8) void {
    var out_txt: ?[]const u8 = null;
    var stdout_text: ?[]u8 = null;
    defer if (stdout_text) |t| c.gpa.free(t);
    const stdout_name = c.gpa.print("{s}.stdout.log", .{name}) catch return;
    defer c.gpa.free(stdout_name);
    if (fsx.openRegular(logdir, stdout_name, true)) |f| {
        defer sys.close(f.fd);
        stdout_text = fsx.readAll(c.gpa, f.fd, scan_limit) catch |err| blk: {
            warn("cannot scan {s}/{s}: {t}", .{ logdir_s, stdout_name, err });
            break :blk null;
        };
        if (stdout_text) |t| out_txt = scan.lastCommandOutput(t);
    } else |_| {}
    if (out_txt == null) if (src_text) |t| {
        out_txt = scan.lastCommandOutput(t);
    };
    const command_out = out_txt orelse return;
    const tmpdir = c.getenv("EASYBUILD_TMPDIR") orelse "";
    if (tmpdir.len == 0) {
        cli.out("Failed command output not kept: EASYBUILD_TMPDIR is not set.\n", .{});
        return;
    }
    const root = command_out[0 .. command_out.len - "/out.txt".len];
    var tb: [sys.path_max]u8 = undefined;
    const tmp_real: ?[]const u8 = fsx.realpath(fsx.cwd, tmpdir, &tb) catch null;
    const prefix: ?[]u8 = if (tmp_real) |t|
        c.gpa.print("{s}/", .{if (t[t.len - 1] == '/') t[0 .. t.len - 1] else t}) catch return
    else
        null;
    defer if (prefix) |p| c.gpa.free(p);

    for ([_][]const u8{ "out", "err" }) |stream| {
        const path = c.gpa.print("{s}/{s}.txt", .{ root, stream }) catch return;
        defer c.gpa.free(path);
        const f = fsx.openRegular(fsx.cwd, path, false) catch continue;
        defer sys.close(f.fd);
        var rb: [sys.path_max]u8 = undefined;
        const resolved = fsx.realpathFd(f.fd, &rb) catch continue;
        if (prefix == null or !std.mem.startsWith(u8, resolved, prefix.?)) {
            cli.out("Failed command output not kept: {s} is not under EASYBUILD_TMPDIR.\n", .{path});
            continue;
        }
        if (f.stat.uid != sys.getuid()) {
            cli.out("Failed command output not kept: {s} belongs to another user.\n", .{path});
            continue;
        }
        const dest = c.gpa.print("{s}.failed.command-{s}.txt", .{ name, stream }) catch return;
        defer c.gpa.free(dest);
        if (keep(c, logdir, logdir_s, f.fd, f.stat, dest, 0o600))
            cli.out("Failed command output: {s}/{s}\n", .{ logdir_s, dest });
    }
}

fn parseDays(opt: []const u8, v: ?[]const u8) u64 {
    const s = v orelse die("{s} needs a number of days", .{opt});
    if (!allDigits(s)) die("{s} needs a number of days", .{opt});
    return std.fmt.parseInt(u64, s, 10) catch die("{s} needs a number of days", .{opt});
}

/// Days since a run directory's name, YYYYMMDD_HHMMSS, at its local
/// midnight; null when the name is not a run directory. The name, not the
/// mtime: a later chmod moves the mtime.
fn runAgeDays(zone: *const localtime.Zone, name: []const u8, now: i64) ?i64 {
    if (name.len != 15 or name[8] != '_') return null;
    if (!allDigits(name[0..8]) or !allDigits(name[9..15])) return null;
    const y = std.fmt.parseInt(i64, name[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, name[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, name[6..8], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > localtime.daysInMonth(y, m)) return null;
    const start = zone.fromLocal(localtime.daysFromCivil(y, m, d) * 86400) orelse return null;
    return @divTrunc(now - start, 86400);
}

const Renames = std.StringHashMapUnmanaged([]const u8);

/// gzip every *.log and *.txt regular file under `dir`, at any depth,
/// without following symbolic links. Each compressed file's resolved path
/// and its .gz path go into `renames`.
fn compressTree(c: Ctx, arena: Allocator, dir: fsx.fd_t, renames: *Renames, count: *usize) void {
    var rb: [sys.path_max]u8 = undefined;
    const here = arena.dupe(u8, fsx.realpathFd(dir, &rb) catch |err| return warn("cannot resolve a run directory: {t}", .{err})) catch return;
    var it = fsx.DirIter.init(c.gpa, dir) catch return;
    defer it.deinit(c.gpa);
    var files: std.ArrayList([]const u8) = .empty;
    var subdirs: std.ArrayList([]const u8) = .empty;
    while (it.next() catch |err| return warn("cannot read {s}: {t}", .{ here, err })) |e| {
        const t = fsx.entryType(dir, e) catch continue;
        const n = arena.dupe(u8, e.name) catch return;
        if (t == fsx.DT.DIR) {
            subdirs.append(arena, n) catch return;
        } else if (t == fsx.DT.REG and (std.mem.endsWith(u8, n, ".log") or std.mem.endsWith(u8, n, ".txt"))) {
            files.append(arena, n) catch return;
        }
    }
    for (files.items) |n| {
        logs.gzipInPlace(c.gpa, c.io, dir, n) catch |err| {
            warn("cannot compress {s}/{s}: {t}", .{ here, n, err });
            continue;
        };
        count.* += 1;
        const from = arena.print("{s}/{s}", .{ here, n }) catch return;
        const to = arena.print("{s}.gz", .{from}) catch return;
        renames.put(arena, from, to) catch return;
    }
    for (subdirs.items) |n| {
        const sub = fsx.openDir(dir, n, false) catch |err| {
            warn("cannot open {s}/{s}: {t}", .{ here, n, err });
            continue;
        };
        defer sys.close(sub);
        compressTree(c, arena, sub, renames, count);
    }
}

/// Rewrite every .licensed-logs under `dir` so it names the compressed
/// files.
fn followLists(c: Ctx, dir: fsx.fd_t, renames: *const Renames) void {
    var it = fsx.DirIter.init(c.gpa, dir) catch return;
    defer it.deinit(c.gpa);
    while (it.next() catch return) |e| {
        const t = fsx.entryType(dir, e) catch continue;
        if (t == fsx.DT.DIR) {
            const sub = fsx.openDir(dir, e.name, false) catch continue;
            defer sys.close(sub);
            followLists(c, sub, renames);
        } else if (t == fsx.DT.REG and std.mem.eql(u8, e.name, logs.licensed_list)) {
            const f = fsx.openRegular(dir, e.name, false) catch continue;
            defer sys.close(f.fd);
            const text = fsx.readAll(c.gpa, f.fd, 64 << 20) catch |err| {
                warn("cannot read a {s}: {t}", .{ logs.licensed_list, err });
                continue;
            };
            defer c.gpa.free(text);
            const new = (logs.renameInList(c.gpa, text, renames) catch continue) orelse continue;
            defer c.gpa.free(new);
            fsx.replaceContents(c.gpa, dir, e.name, new) catch |err|
                warn("cannot update a {s}: {t}", .{ logs.licensed_list, err });
        }
    }
}

fn cmdRotate(c: Ctx, args: []const [:0]const u8) u8 {
    var root_s: ?[]const u8 = null;
    var compress_v: ?[]const u8 = null;
    var delete_v: ?[]const u8 = null;
    var have_compress = false;
    var have_delete = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--compress-after") or std.mem.eql(u8, a, "--delete-after")) {
            const v: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
            if (v == null) die("{s} needs a number of days", .{a});
            i += 1;
            if (a[2] == 'c') {
                compress_v = v;
                have_compress = true;
            } else {
                delete_v = v;
                have_delete = true;
            }
        } else if (std.mem.startsWith(u8, a, "--compress-after=")) {
            compress_v = a["--compress-after=".len..];
            have_compress = true;
        } else if (std.mem.startsWith(u8, a, "--delete-after=")) {
            delete_v = a["--delete-after=".len..];
            have_delete = true;
        } else if (a.len > 0 and a[0] == '-') {
            die("unknown option {s}", .{a});
        } else {
            if (root_s != null) die("rotate takes one ROOT", .{});
            root_s = a;
        }
    }
    const root_p = root_s orelse die("rotate needs ROOT", .{});
    if (root_p.len == 0) die("rotate needs ROOT", .{});
    const root = fsx.openDir(fsx.cwd, root_p, true) catch die("ROOT {s} is not a directory", .{root_p});
    defer sys.close(root);
    const compress_after = parseDays("--compress-after", if (have_compress) compress_v else null);
    var delete_after: ?u64 = null;
    if (have_delete and delete_v.?.len > 0) {
        delete_after = parseDays("--delete-after", delete_v);
        if (delete_after.? <= compress_after) die("--delete-after must be later than --compress-after", .{});
    }

    const now: i64 = if (c.getenv("EB_KEEP_LOGS_NOW")) |s|
        std.fmt.parseInt(i64, s, 10) catch die("EB_KEEP_LOGS_NOW must be seconds since the epoch, not '{s}'", .{s})
    else blk: {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        break :blk ts.sec;
    };
    var zone = localtime.load(c.gpa, c.getenv("TZ"), c.getenv("TZDIR"));
    defer zone.deinit();

    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runs: std.ArrayList([]const u8) = .empty;
    {
        var it = fsx.DirIter.init(c.gpa, root) catch die("cannot read ROOT {s}", .{root_p});
        defer it.deinit(c.gpa);
        while (it.next() catch |err| die("cannot read ROOT {s}: {t}", .{ root_p, err })) |e| {
            if (e.name[0] == '.') continue;
            if ((fsx.entryType(root, e) catch continue) != fsx.DT.DIR) continue;
            runs.append(arena, arena.dupe(u8, e.name) catch continue) catch continue;
        }
    }
    std.mem.sort([]const u8, runs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var compressed: usize = 0;
    var deleted: usize = 0;
    for (runs.items) |run| {
        const age = runAgeDays(&zone, run, now) orelse continue;
        if (delete_after) |d| if (age >= @as(i64, @intCast(@min(d, std.math.maxInt(i64))))) {
            fsx.deleteTree(c.gpa, root, run) catch |err| {
                warn("cannot delete {s}/{s}: {t}", .{ root_p, run, err });
                continue;
            };
            deleted += 1;
            continue;
        };
        if (age < @as(i64, @intCast(@min(compress_after, std.math.maxInt(i64))))) continue;
        const dir = fsx.openDir(root, run, false) catch |err| {
            warn("cannot open {s}/{s}: {t}", .{ root_p, run, err });
            continue;
        };
        defer sys.close(dir);
        var renames: Renames = .empty;
        var n: usize = 0;
        compressTree(c, arena, dir, &renames, &n);
        compressed += n;
        if (renames.count() > 0) followLists(c, dir, &renames);
    }
    cli.out("eb-keep-logs rotate: {d} files compressed, {d} runs deleted under {s}\n", .{ compressed, deleted, root_p });
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch die("cannot read the arguments", .{});
    const c: Ctx = .{
        .gpa = gpa,
        .io = init.io,
        .env = init.environ_map,
        .envp = init.minimal.environ.block.slice.ptr,
    };
    const cmd: []const u8 = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
        cli.put(1, usage_text);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        cli.put(1, comptime cli.versionLine(tool, version, build_options.commit));
        return 0;
    }
    if (std.mem.eql(u8, cmd, "failed")) return cmdFailed(c, args[2..]);
    if (std.mem.eql(u8, cmd, "rotate")) return cmdRotate(c, args[2..]);
    if (cmd.len == 0) {
        cli.put(1, usage_text);
        return cli.usage_exit;
    }
    die("unknown command '{s}' (failed, rotate, --help)", .{cmd});
}

test {
    _ = localtime;
    _ = scan;
}

test "a failed copy does not replace a log already kept" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/eb-keep-logs-copy-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    var zb: [sys.path_max:0]u8 = undefined;
    _ = linux.mkdirat(fsx.cwd, (try sys.z(&zb, base)).ptr, 0o700);
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer {
        fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        sys.close(dir);
    }
    const dst = try sys.openat(dir, "kept.log", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o640);
    try sys.writeAll(dst, "OLDDATA\n");
    sys.close(dst);
    const srcfd = try sys.openat(dir, "src", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try sys.writeAll(srcfd, "NEWDATA-IS-LONGER-THAN-THE-LIMIT\n");
    sys.close(srcfd);
    const opened = try fsx.openRegular(dir, "src", false);
    defer sys.close(opened.fd);

    var old: linux.rlimit = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, null, &old)));
    const lim: linux.rlimit = .{ .cur = 8, .max = old.max };
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .FSIZE, &lim, null)));
    const ign: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var prev: linux.Sigaction = undefined;
    _ = linux.sigaction(.XFSZ, &ign, &prev);
    if (copyDurable(dir, "kept.log", opened.fd, opened.stat)) |fd| sys.close(fd) else |_| {}
    _ = linux.sigaction(.XFSZ, &prev, null);
    _ = linux.prlimit(0, .FSIZE, &old, null);

    const got = try fsx.openRegular(dir, "kept.log", false);
    defer sys.close(got.fd);
    const text = try fsx.readAll(gpa, got.fd, 100);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("OLDDATA\n", text);
    try std.testing.expectEqual(@as(u32, 0o640), got.stat.perm());
}

test "runAgeDays" {
    const z: localtime.Zone = .{};
    const now = localtime.daysFromCivil(2026, 11, 13) * 86400;
    try std.testing.expectEqual(@as(?i64, 43), runAgeDays(&z, "20261001_120000", now));
    try std.testing.expectEqual(@as(?i64, null), runAgeDays(&z, "20261301_120000", now));
    try std.testing.expectEqual(@as(?i64, null), runAgeDays(&z, "20260230_120000", now));
    try std.testing.expectEqual(@as(?i64, null), runAgeDays(&z, "notarun", now));
    try std.testing.expectEqual(@as(?i64, 0), runAgeDays(&z, "20261113_235959", now + 3600));
}
