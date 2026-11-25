//! eb-keep-logs: keep the logs of EasyBuild builds that a build pipeline
//! would otherwise lose, and keep the pipeline's log tree bounded.
const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const common = @import("zig_common");
const atomic = common.atomic;
const sys = common.sys;
const fsx = common.fsx;
const proc = common.proc;
const logs = common.logs;
const cli = common.cli;
const localtime = @import("localtime.zig");
const scan = @import("scan.zig");
const why = @import("why.zig");
const loads = @import("loads.zig");
const xalt_runs = @import("runs.zig");
const pending = @import("pending.zig");
const used_cmd = @import("used.zig");
const usage_cmd = @import("usage.zig");
const test_bundle = @import("test_bundle.zig");
const lifecycle = @import("lifecycle.zig");
const syslog = common.syslog;
/// The name events are sent under: the program in the syslog header and in
/// journald, and the name in the structured-data identifier.
const syslog_identity: syslog.Identity = .{ .app = "eb-keep-logs", .sd_name = "ebKeepLogs" };
const metrics = @import("metrics.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
/// The version `--version` prints after the tool's name. `.version` in
/// build.zig.zon names the same one, and a release changes both.
pub const version = "0.3.1";

/// What `-h`, `--help` and no arguments print. The shell script's `usage`
/// prints the same text: tests/differential.sh compares the two.
const usage_text =
    \\eb-keep-logs: keep the logs of EasyBuild builds that a build pipeline would
    \\otherwise lose, and keep the pipeline's log tree bounded.
    \\
    \\  eb-keep-logs failed [--syslog TARGET] [--metrics-file PATH] STATUS NAME LOGDIR [TMP_LOGDIR]
    \\      After `eb` returned STATUS for easyconfig NAME: when STATUS is not 0,
    \\      copy the EasyBuild session log `eb --last-log` names, the failing
    \\      command's output and a meson testlog next to LOGDIR/NAME.stdout.log,
    \\      closed to others and listed in LOGDIR/.licensed-logs. TMP_LOGDIR is
    \\      the --tmp-logdir eb ran with; without it, the newest log in
    \\      EasyBuild's default place is used, unless it is another build's.
    \\      NAME.stdout.log and a TMP_LOGDIR below LOGDIR are closed to others too.
    \\      --syslog TARGET, --syslog=TARGET
    \\          Emit an RFC 5424 or native systemd-journald event when logs are
    \\          kept or none are found. Default: EB_KEEP_LOGS_SYSLOG, else none.
    \\      --metrics-file PATH, --metrics-file=PATH
    \\          Atomically update Prometheus counters for kept logs and bytes.
    \\          Default: none.
    \\  eb-keep-logs rotate ROOT --compress-after DAYS [--delete-after DAYS]
    \\                           [--dry-run] [--lock-timeout SECONDS]
    \\                           [--syslog TARGET] [--metrics-file PATH]
    \\      In the run directories directly under ROOT (named YYYYMMDD_HHMMSS),
    \\      gzip the *.log and *.txt files of old runs and remove older runs
    \\      whole, leaving alone a run that is still written into. A run's age is
    \\      in days from the local midnight of the date in its name. Permissions
    \\      and .licensed-logs follow. One rotate of ROOT runs at a time, holding
    \\      ROOT/.eb-keep-logs-rotate.lock. Options and ROOT come in any order.
    \\      --compress-after DAYS, --compress-after=DAYS
    \\          Gzip the files of runs at least DAYS old. Required; there is no
    \\          default.
    \\      --delete-after DAYS, --delete-after=DAYS
    \\          Remove whole runs at least DAYS old; DAYS must be larger than
    \\          that of --compress-after. Default: none; no run is removed. An
    \\          empty value is the default.
    \\      --dry-run
    \\          Print each file that would be compressed and run that would be
    \\          deleted, but change nothing, create no lock, emit no event and
    \\          write no metrics.
    \\      --lock-timeout SECONDS, --lock-timeout=SECONDS
    \\          While another rotate holds the lock, wait up to SECONDS for it,
    \\          then give up and exit 75. Default: 600; 0 does not wait. An empty
    \\          value is the default.
    \\      --syslog TARGET, --syslog=TARGET
    \\          Emit an RFC 5424 or native systemd-journald event with the
    \\          compressed and deleted counts. Default: EB_KEEP_LOGS_SYSLOG,
    \\          else none.
    \\      --metrics-file PATH, --metrics-file=PATH
    \\          Atomically record when this rotation completed, unless --dry-run
    \\          is given. Default: none.
    \\  eb-keep-logs why [RUN | --latest] [--target TARGET] [--package PACKAGE]
    \\                   [--since DATE] [--until DATE] [--root ROOT] [--json]
    \\      Say why the builds of a run failed: for each failed easyconfig, its
    \\      package and easyconfig, the EasyBuild step it failed in, EasyBuild's
    \\      message, and the line of its kept log that shows the error: the first
    \\      compiler or linker error, else EasyBuild's own error line, with the
    \\      line number and three lines either side. Logs rotate compressed are
    \\      read as they are. Zig build only. RUN and the options come in any
    \\      order.
    \\      RUN
    \\          A run directory, as a path or as a name under ROOT.
    \\      --latest
    \\          The newest run under ROOT, or the newest with a directory
    \\          TARGET. The default when no RUN is given.
    \\      --target TARGET, --target=TARGET
    \\          Only the builds in the run's directory TARGET. Default: those in
    \\          the run's own directory and in every directory in it.
    \\      --package PACKAGE, --package=PACKAGE
    \\          Only builds matching PACKAGE (an easyconfig name without .eb,
    \\          a prefix up to a dash, or NAME/VERSION). Default: all builds.
    \\      --since DATE, --since=DATE
    \\          Only consider runs at or after DATE when picking --latest.
    \\          DATE is YYYY-MM-DD, YYYYMMDD, or YYYYMMDD_HHMMSS.
    \\          Default: none.
    \\      --until DATE, --until=DATE
    \\          Only consider runs at or before DATE when picking --latest.
    \\          DATE is YYYY-MM-DD, YYYYMMDD, or YYYYMMDD_HHMMSS.
    \\          Default: none.
    \\      --root ROOT, --root=ROOT
    \\          The directory that holds the runs. Default: the current
    \\          directory.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\  eb-keep-logs history PACKAGE [--target TARGET] [--since DATE]
    \\                       [--until DATE] [--failed] [--root ROOT] [--json]
    \\      Say how each kept build of PACKAGE went, oldest run first: success,
    \\      failed or unknown, and how long EasyBuild took, from its output.
    \\      PACKAGE is an easyconfig's name or its start up to a dash, as hello
    \\      or hello-2.12.1 for hello-2.12.1-GCCcore-14.2.0, or a module name, as
    \\      hello/2.12.1; hello also takes hello-world-1.0. Zig build only.
    \\      PACKAGE and the options come in any order.
    \\      --target TARGET, --target=TARGET
    \\          Only the builds in each run's directory TARGET. Default: those in
    \\          each run's own directory and in every directory in it.
    \\      --since DATE, --since=DATE
    \\          Only read runs at or after DATE (YYYY-MM-DD, YYYYMMDD, or
    \\          YYYYMMDD_HHMMSS). Default: none.
    \\      --until DATE, --until=DATE
    \\          Only read runs at or before DATE (YYYY-MM-DD, YYYYMMDD, or
    \\          YYYYMMDD_HHMMSS). Default: none.
    \\      --failed
    \\          Only list failed builds.
    \\      --root ROOT, --root=ROOT
    \\          The directory that holds the runs. Default: the current
    \\          directory.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\  eb-keep-logs failures [--package PACKAGE] [--target TARGET]
    \\                        [--since DATE] [--until DATE] [--root ROOT] [--json]
    \\      List failed builds across runs under --root, oldest run first.
    \\      Each row gives the run, target, failed step, duration and build
    \\      name. Zig build only. Options come in any order.
    \\      --package PACKAGE, --package=PACKAGE
    \\          Only failed builds matching PACKAGE (an easyconfig name
    \\          without .eb, a prefix up to a dash, or NAME/VERSION). Default:
    \\          all packages.
    \\      --target TARGET, --target=TARGET
    \\          Only the builds in each run's directory TARGET. Default: those
    \\          in each run's own directory and in every directory in it.
    \\      --since DATE, --since=DATE
    \\          Only read runs at or after DATE (YYYY-MM-DD, YYYYMMDD, or
    \\          YYYYMMDD_HHMMSS). Default: none.
    \\      --until DATE, --until=DATE
    \\          Only read runs at or before DATE (YYYY-MM-DD, YYYYMMDD, or
    \\          YYYYMMDD_HHMMSS). Default: none.
    \\      --root ROOT, --root=ROOT
    \\          The directory that holds the runs. Default: the current
    \\          directory.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\  eb-keep-logs loads --module NAME [--json] FILE
    \\      Print who loaded NAME, from Lmod's ModuleUsageTracking lines in FILE.
    \\      Each record is user=USER module=NAME path=PATH host=HOST time=TIME,
    \\      in any order, and a syslog prefix is left in place. Each load is
    \\      one line, user=USER host=HOST time=TIME path=PATH, in the file's
    \\      order. A file with no load of NAME prints no load of NAME. Zig
    \\      build only.
    \\      --module NAME, --module=NAME
    \\          The module's full name, as Lmod recorded it, such as
    \\          GROMACS/2024.1. Required.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\      FILE
    \\          The log that holds the records. A line that is not one is
    \\          skipped.
    \\  eb-keep-logs used --prefix PREFIX [--json] [--require-none] FILE...
    \\      Print paths under PREFIX that appear in XALT or Lmod records in
    \\      FILE. A run record lists userT.exec_path (kind run) and each libA
    \\      path under PREFIX (kind run-lib) even when exec_path is outside.
    \\      A link record lists resultT.exec_path and each linkA path (kind
    \\      link). A package record lists package_path (kind pkg). An Lmod
    \\      tracking line lists path when it is under PREFIX (kind module-load).
    \\      Each line is path=PATH kind=KIND last=TIME count=N; last is the
    \\      newest time seen for that path. With no hit, nothing under PREFIX.
    \\      --json prints one JSON document with schema_version 1. --require-none
    \\      exits 2 when any hit is listed. Zig build only.
    \\      --prefix PREFIX, --prefix=PREFIX
    \\          The install tree to check. Required; a newline in it is refused.
    \\      --json
    \\          Print one line of JSON instead.
    \\      --require-none
    \\          Exit 2 when any path under PREFIX was found.
    \\      FILE
    \\          One or more files of concatenated XALT JSON objects and/or Lmod
    \\          ModuleUsageTracking lines. Required.
    \\  eb-keep-logs usage --software DIR --modules DIR [--since EPOCH]
    \\                     [--unused | --active] [--json] FILE...
    \\      Compare installed DIR/Name/Version software with XALT and Lmod
    \\      records. XALT paths below the software directory and Lmod module
    \\      loads below the modules directory count as hits. By default, print
    \\      every installed Name/Version with its state, hit count and newest
    \\      time. --unused and --active print only Name/Version lines;
    \\      --active output is accepted by eb-stack stack gap --site. --since
    \\      ignores records older than EPOCH and records without a time.
    \\      --json prints one JSON document with schema_version 1. Zig build
    \\      only.
    \\      --software DIR, --software=DIR
    \\          The software install tree, with Name/Version directories.
    \\          Required.
    \\      --modules DIR, --modules=DIR
    \\          The module tree that Lmod record paths must be below. Required.
    \\      --since EPOCH, --since=EPOCH
    \\          Count records at or after this non-negative epoch time.
    \\          Default: all record times.
    \\      --unused
    \\          List installed Name/Version entries with no hit.
    \\      --active
    \\          List installed Name/Version entries with at least one hit.
    \\      --json
    \\          Print one line of JSON instead.
    \\      FILE
    \\          One or more files of concatenated XALT JSON objects and/or Lmod
    \\          ModuleUsageTracking lines. Required.
    \\  eb-keep-logs runs --exec PATH [--json] FILE
    \\      Print who ran PATH, from XALT run records in FILE. A run record is a
    \\      JSON object whose userT holds user, exec_path and, when present,
    \\      syshost and start_time. A link record is not a run and is skipped.
    \\      PATH matches exec_path in full or as its last component. Each run is
    \\      one line, user=USER host=HOST time=TIME path=PATH, in the file's
    \\      order. A file with no run of PATH prints no run of PATH. Zig build
    \\      only. It does not record runs.
    \\      --exec PATH, --exec=PATH
    \\          The executable, as a full path or its last component. Required.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\      FILE
    \\          One or more JSON objects. An object that is not a run record is
    \\          skipped.
    \\  eb-keep-logs pending [--json] FILE
    \\      Print what an EasyBuild dry-run or missing-modules report still has
    \\      to build. A dry-run line is "* [ ] PATH (module: NAME)", and [F] and
    \\      [R] count as still to build; [x] is already installed and is not
    \\      printed. --terse prints "x PATH" or "- PATH". A missing-modules line
    \\      is "* NAME (FILE.eb)", or with --terse one easyconfig path on each
    \\      line. Each is one line, build NAME or missing NAME, in the file's
    \\      order. A report with nothing left prints nothing to build. Zig build
    \\      only. It does not run eb, and it does not resolve dependencies.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\      FILE
    \\          The report, as eb --dry-run or eb --missing-modules printed it.
    \\          Required.
    \\  eb-keep-logs test-bundle --test-id ID --suite-revision REV --eessi-target TARGET
    \\                           ... --stdout FILE --stderr FILE [--input FILE ...]
    \\                           ... [--module NAME=PATH ...] --seed SEED
    \\                           ... --allocation TEXT --binding TEXT --cpu TEXT --gpu TEXT
    \\                           [--out FILE]
    \\      Write one flaky-test evidence bundle as JSON schema_version 1, with a
    \\      stable test identity (ID), normalized stdout and stderr, input and
    \\      seed hashes, full module list and module paths, EESSI target,
    \\      scheduler allocation and binding, CPU and GPU facts, and test-suite
    \\      revision. Without --out, print it on stdout. Zig build only.
    \\      --test-id ID, --test-id=ID
    \\          Stable test identity. Required.
    \\      --suite-revision REV, --suite-revision=REV
    \\          Test-suite revision. Required.
    \\      --eessi-target TARGET, --eessi-target=TARGET
    \\          EESSI target of the run. Required.
    \\      --stdout FILE, --stdout=FILE
    \\          Captured stdout, normalized and hashed. Required.
    \\      --stderr FILE, --stderr=FILE
    \\          Captured stderr, normalized and hashed. Required.
    \\      --input FILE, --input=FILE
    \\          Input file to hash. Optional; may be repeated. Default: none.
    \\      --module NAME=PATH, --module=NAME=PATH
    \\          Loaded module and its modulefile path. Optional; may be
    \\          repeated. Default: none.
    \\      --seed SEED, --seed=SEED
    \\          Seed value to hash. Required.
    \\      --allocation TEXT, --allocation=TEXT
    \\          Scheduler allocation summary. Required.
    \\      --binding TEXT, --binding=TEXT
    \\          Scheduler binding summary. Required.
    \\      --cpu TEXT, --cpu=TEXT
    \\          CPU facts. Required.
    \\      --gpu TEXT, --gpu=TEXT
    \\          GPU facts, or none. Required.
    \\      --out FILE, --out=FILE
    \\          Write JSON to FILE. Default: stdout.
    \\  eb-keep-logs test-compare [--json] BUNDLE...
    \\      Summarize which evidence fields differ across two or more
    \\      test-bundle JSON files, without deciding pass or fail. --json prints
    \\      schema_version 1. Zig build only.
    \\      --json
    \\          Print one line of JSON instead of text. Default: text.
    \\      BUNDLE
    \\          Two or more test-bundle JSON files. Required.
    \\  eb-keep-logs lifecycle --policy FILE [--modulerc-out FILE]
    \\                         [--easyconfigs DIR ...] [--easystack FILE ...]
    \\                         [--eb-stack PATH] [--rebuild-set FILE]
    \\                         [--now EPOCH] [--json] FILE
    \\      Generate a reversible lifecycle plan and Lmod .modulerc.lua
    \\      warnings/forbids from usage --json output and a TOML policy. Never
    \\      deletes software or modulefiles. Requires a minimum observation
    \\      window and checks installed dependents via eb-stack rebuild-set
    \\      before allowing candidate-remove. Zig build only.
    \\      --policy FILE, --policy=FILE
    \\          TOML lifecycle policy file. Required.
    \\      --modulerc-out FILE, --modulerc-out=FILE
    \\          Write the generated Lmod .modulerc.lua warnings and forbids
    \\          durably to FILE. Default: none; no file is written.
    \\      --easyconfigs DIR, --easyconfigs=DIR
    \\          Easyconfig tree passed to eb-stack rebuild-set to identify
    \\          dependents of candidate removals. Repeatable. Default: none.
    \\      --easystack FILE, --easystack=FILE
    \\          Deployed easystack YAML passed to eb-stack rebuild-set.
    \\          Repeatable. Default: none.
    \\      --eb-stack PATH, --eb-stack=PATH
    \\          Path to the eb-stack executable. Default: eb-stack on PATH.
    \\      --rebuild-set FILE, --rebuild-set=FILE
    \\          Precomputed eb-stack rebuild-set.json report instead of
    \\          running eb-stack. Default: none.
    \\      --now EPOCH, --now=EPOCH
    \\          Reference epoch time in seconds for idle age and observation
    \\          window checks. Default: the environment time override, else
    \\          the current time.
    \\      --json
    \\          Print one line of JSON instead, with schema_version 1.
    \\      FILE
    \\          JSON output produced by eb-keep-logs usage --json (with
    \\          selection "all"). Required.
    \\  eb-keep-logs -h | --help
    \\      Print this help on stdout and exit 0.
    \\  eb-keep-logs --version
    \\      Print the version line on stdout and exit 0.
    \\
    \\Environment:
    \\  PATH                 Where failed looks up eb.
    \\  EASYBUILD_TMPDIR     failed copies a command's output only from below it;
    \\                       unset or empty, it copies none.
    \\  EB_KEEP_LOGS_NOW     The time rotate and lifecycle take as now, in seconds
    \\                       since the epoch; unset or empty, the current time.
    \\  EB_PIPELINE_LOG_DIR  rotate leaves alone the run that holds this path.
    \\  EB_KEEP_LOGS_SYSLOG  Default --syslog target (journald, syslog, unix:///...,
    \\                       journal+unix:///..., udp://host:port, tcp://host:port).
    \\  EB_KEEP_LOGS_SYSLOG_PEN
    \\                       IANA Private Enterprise Number for RFC 5424 SD-ID
    \\                       ebKeepLogs@<PEN>. Default: 32473 (RFC 5398 placeholder).
    \\  TZ, TZDIR            The time zone of the local midnights, and the
    \\                       directory of zone files.
    \\
    \\Exit status:
    \\  0   -h, --help or --version, or a failed, rotate, why, history, failures, loads, runs, used, usage, pending, test-bundle, test-compare or lifecycle that
    \\      accepted its arguments, whatever it could keep, compress, remove or
    \\      read: what it could not do is reported on stderr. used with
    \\      --require-none also exits 2 when any path was listed.
    \\  2   The invocation was refused, with eb-keep-logs: MESSAGE on stderr; or
    \\      no command was given, and this help is on stdout.
    \\  75  rotate waited --lock-timeout seconds for the lock another rotate
    \\      held, then gave up and changed nothing; run it again later.
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

/// The errno's own name: `EIO` for `EIO`. `{t}` on the Zig error prints
/// `Unexpected` for every errno this program does not give its own error,
/// which hides the failure the kernel reported. Every name Linux has is a
/// static string; an errno it does not name prints as its number. Read
/// `sys.last_errno` before another call replaces it.
fn errnoName(e: linux.E) []const u8 {
    if (e == .SUCCESS) return "no errno";
    const info = @typeInfo(linux.E).@"enum";
    @setEvalBranchQuota(info.field_names.len * 1000);
    inline for (info.field_names, info.field_values) |name, value| {
        if (@backingInt(e) == value) return "E" ++ name;
    }
    const S = struct {
        threadlocal var buf: [std.fmt.count("errno {d}", .{std.math.maxInt(u16)})]u8 = undefined;
    };
    return std.mem.print(&S.buf, "errno {d}", .{@as(u16, @backingInt(e))}) catch unreachable;
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

/// Whether the character locale asks grep to treat its input as UTF-8.
/// Empty locale variables fall through as setlocale(3) specifies.
fn utf8Locale(c: Ctx) bool {
    const locale = for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (c.getenv(name)) |value| if (value.len > 0) break value;
    } else "C";
    return std.ascii.findIgnoreCase(locale, "UTF-8") != null or
        std.ascii.findIgnoreCase(locale, "UTF8") != null;
}

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

/// What `eb --last-log` names. EasyBuild 5.3 and later fold that path at
/// the terminal width, 80 columns on a pipe, unless given
/// --output-style=basic (EasyBuild 4.5 and later); an older eb refuses the
/// option and does not fold, so it is asked again without it when that
/// fails or prints nothing.
fn lastLog(c: Ctx, tmp_logdir: ?[]const u8) LastLog {
    const path_env = c.getenv("PATH") orelse "";
    const eb = (proc.which(c.gpa, "eb", path_env) catch return .none) orelse return .no_eb;
    defer c.gpa.free(eb);
    var argv_buf: [4][]const u8 = undefined;
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
    argv_buf[argc] = "--output-style=basic";
    const basic: ?proc.Result = proc.run(c.gpa, eb, argv_buf[0 .. argc + 1], c.envp, .{}) catch |err| switch (err) {
        // Asking again would wait as long to keep nothing.
        error.TimedOut => return .none,
        else => null,
    };
    if (basic) |r| {
        defer r.deinit(c.gpa);
        if (r.term.code() == 0) if (lastLine(r.stdout)) |line|
            return .{ .path = c.gpa.dupe(u8, line) catch return .none };
    }
    const r = proc.run(c.gpa, eb, argv_buf[0..argc], c.envp, .{}) catch return .none;
    defer r.deinit(c.gpa);
    if (r.term.code() != 0) return .{ .failed = r.term.code() };
    const line = lastLine(r.stdout) orelse return .none;
    return .{ .path = c.gpa.dupe(u8, line) catch return .none };
}

/// The last line of `out` without its newline, or null when it is empty.
fn lastLine(out: []const u8) ?[]const u8 {
    var s = out;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    const line = s[if (std.mem.findScalarLast(u8, s, '\n')) |i| i + 1 else 0..];
    return if (line.len == 0) null else line;
}

/// Whether `text`, as .licensed-logs holds it, has `path` as a whole line.
fn listed(text: []const u8, path: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, path)) return true;
    return false;
}

/// Record a kept file that may carry a licence number, once: a retried
/// build keeps the same files again.
fn listKept(c: Ctx, logdir: fsx.fd_t, kept: fsx.fd_t) void {
    var rb: [sys.path_max]u8 = undefined;
    const abs = fsx.realpathFd(kept, &rb) catch |err| return warn("cannot resolve a kept file: {t}", .{err});
    if (fsx.openRegular(logdir, logs.licensed_list, false)) |f| {
        defer sys.close(f.fd);
        const text: ?[]u8 = fsx.readAll(c.gpa, f.fd, scan_limit) catch null;
        defer if (text) |t| c.gpa.free(t);
        if (text) |t| if (listed(t, abs)) return;
    } else |_| {}
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
/// o-rwx), and list it. Return the written byte count, or null when the copy
/// failed.
fn keep(c: Ctx, logdir: fsx.fd_t, logdir_s: []const u8, src: fsx.fd_t, src_stat: fsx.Stat, name: []const u8, comptime closed_mode: ?u32) ?u64 {
    const fd = copyDurable(logdir, name, src, src_stat) catch |err| {
        warn("cannot keep {s}/{s}: {t}", .{ logdir_s, name, err });
        return null;
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
    return @intCast((fsx.fstat(fd) catch return 0).size);
}

fn rewind(fd: fsx.fd_t) void {
    _ = linux.lseek(fd, 0, linux.SEEK.SET);
}

/// A directory argument as messages join it to a name with "/": without
/// trailing slashes, so "logs/" gives "logs/NAME" and "/" gives "/NAME".
fn joinable(dir: []const u8) []const u8 {
    return std.mem.trimEnd(u8, dir, "/");
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// Whether the resolved `path` lies below the resolved directory `dir`.
fn below(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return path.len > 1;
    return path.len > dir.len + 1 and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

/// Take others' bits off an open file or directory (chmod o-rwx).
fn closeFd(fd: fsx.fd_t, path: []const u8) void {
    const st = fsx.fstat(fd) catch |err| return warn("cannot stat {s}: {t}", .{ path, err });
    sys.fchmod(fd, @intCast(st.perm() & ~@as(u32, 0o007))) catch |err|
        warn("cannot close {s} to others: {t}", .{ path, err });
}

/// The failed lines the kept copies hold are also in the build's own
/// NAME.stdout.log and in the logs EasyBuild writes to TMP_LOGDIR. Close
/// both to others, TMP_LOGDIR with the regular files directly in it, not
/// through a symbolic link; TMP_LOGDIR only when it lies below LOGDIR, as
/// the layout `failed` documents puts it.
fn closeBuildLogs(c: Ctx, logdir: fsx.fd_t, logdir_s: []const u8, name: []const u8, tmp_logdir: ?[]const u8) void {
    const stdout_name = c.gpa.print("{s}.stdout.log", .{name}) catch return;
    defer c.gpa.free(stdout_name);
    if (fsx.openRegular(logdir, stdout_name, false)) |f| {
        defer sys.close(f.fd);
        const path = c.gpa.print("{s}/{s}", .{ logdir_s, stdout_name }) catch return;
        defer c.gpa.free(path);
        closeFd(f.fd, path);
    } else |_| {}
    const t = tmp_logdir orelse return;
    const d = fsx.openDir(fsx.cwd, t, false) catch return;
    defer sys.close(d);
    var lb: [sys.path_max]u8 = undefined;
    var tb: [sys.path_max]u8 = undefined;
    const l = fsx.realpathFd(logdir, &lb) catch return;
    const r = fsx.realpathFd(d, &tb) catch return;
    if (!below(r, l)) return;
    closeFd(d, t);
    var it = fsx.DirIter.init(c.gpa, d) catch return;
    defer it.deinit(c.gpa);
    while (it.next() catch return) |e| {
        if ((fsx.entryType(d, e) catch continue) != fsx.DT.REG) continue;
        const f = fsx.openRegular(d, e.name, false) catch continue;
        defer sys.close(f.fd);
        const path = c.gpa.print("{s}/{s}", .{ std.mem.trimEnd(u8, t, "/"), e.name }) catch return;
        defer c.gpa.free(path);
        closeFd(f.fd, path);
    }
}

fn resolveSyslog(c: Ctx, cli_syslog: ?[]const u8) ?syslog.Target {
    const pen_raw = c.getenv("EB_KEEP_LOGS_SYSLOG_PEN") orelse "";
    const pen = if (pen_raw.len > 0)
        (syslog.parsePen(pen_raw) orelse die("EB_KEEP_LOGS_SYSLOG_PEN must be a positive integer, not '{s}'", .{pen_raw}))
    else
        syslog.default_pen;
    const raw = cli_syslog orelse (c.getenv("EB_KEEP_LOGS_SYSLOG") orelse "");
    if (raw.len == 0) return null;
    var target = syslog.parseTarget(raw) orelse die("invalid syslog target '{s}'", .{raw});
    target.pen = pen;
    return target;
}

fn emitFailedSyslog(
    c: Ctx,
    target: ?syslog.Target,
    status: []const u8,
    name: []const u8,
    logdir_s: []const u8,
    ebout_kept: bool,
    cmd_kept: usize,
    meson_kept: bool,
    reason: []const u8,
) void {
    const t = target orelse return;
    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const kept: usize = (if (ebout_kept) @as(usize, 1) else 0) + cmd_kept + (if (meson_kept) @as(usize, 1) else 0);
    const msgid: []const u8 = if (kept > 0) "EB_KEEP_FAILED" else "EB_KEEP_NONE";
    const kept_s = a.print("{d}", .{kept}) catch "0";
    const licensed_s = kept_s;
    const ebout_s: []const u8 = if (ebout_kept) "1" else "0";
    const cmdout_s: []const u8 = if (cmd_kept > 0) "1" else "0";
    const meson_s: []const u8 = if (meson_kept) "1" else "0";
    const job = c.getenv("SLURM_JOB_ID") orelse "";
    const step = c.getenv("SLURM_STEP_ID") orelse "";

    var params: std.ArrayList(syslog.Param) = .empty;
    params.appendSlice(a, &.{
        .{ .key = "cmd", .value = "failed" },
        .{ .key = "status", .value = status },
        .{ .key = "name", .value = name },
        .{ .key = "logdir", .value = logdir_s },
        .{ .key = "kept", .value = kept_s },
        .{ .key = "licensed", .value = licensed_s },
        .{ .key = "ebout", .value = ebout_s },
        .{ .key = "cmdout", .value = cmdout_s },
        .{ .key = "meson", .value = meson_s },
        .{ .key = "reason", .value = reason },
    }) catch return;
    if (job.len > 0) params.append(a, .{ .key = "job", .value = job }) catch return;
    if (step.len > 0) params.append(a, .{ .key = "step", .value = step }) catch return;

    var jfields: std.ArrayList(syslog.JournalField) = .empty;
    jfields.appendSlice(a, &.{
        .{ .key = "EB_KEEP_CMD", .value = "failed" },
        .{ .key = "EB_KEEP_STATUS", .value = status },
        .{ .key = "EB_KEEP_NAME", .value = name },
        .{ .key = "EB_KEEP_LOGDIR", .value = logdir_s },
        .{ .key = "EB_KEEP_KEPT", .value = kept_s },
        .{ .key = "EB_KEEP_LICENSED", .value = licensed_s },
        .{ .key = "EB_KEEP_EBOUT", .value = ebout_s },
        .{ .key = "EB_KEEP_CMDOUT", .value = cmdout_s },
        .{ .key = "EB_KEEP_MESON", .value = meson_s },
        .{ .key = "EB_KEEP_REASON", .value = reason },
        .{ .key = "SLURM_JOB_ID", .value = job },
        .{ .key = "SLURM_STEP_ID", .value = step },
    }) catch return;

    const msg = if (kept > 0)
        (a.print("eb-keep-logs failed: kept {d} file{s} for {s} (status {s})", .{ kept, plural(kept), name, status }) catch return)
    else
        (a.print("eb-keep-logs failed: no EasyBuild log kept for {s} ({s})", .{ name, reason }) catch return);

    if (!syslog.emitFor(a, syslog_identity, t, 4, msgid, params.items, jfields.items, msg)) {
        warn("cannot emit syslog event", .{});
    }
}

fn emitRotateSyslog(
    c: Ctx,
    target: ?syslog.Target,
    root_p: []const u8,
    compressed: usize,
    deleted: usize,
    msg: []const u8,
) void {
    const t = target orelse return;
    var arena_state = std.heap.ArenaAllocator.init(c.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const comp_s = a.print("{d}", .{compressed}) catch "0";
    const del_s = a.print("{d}", .{deleted}) catch "0";
    const params = [_]syslog.Param{
        .{ .key = "cmd", .value = "rotate" },
        .{ .key = "root", .value = root_p },
        .{ .key = "compressed", .value = comp_s },
        .{ .key = "deleted", .value = del_s },
    };
    const jfields = [_]syslog.JournalField{
        .{ .key = "EB_KEEP_CMD", .value = "rotate" },
        .{ .key = "EB_ROTATE_ROOT", .value = root_p },
        .{ .key = "EB_ROTATE_COMPRESSED", .value = comp_s },
        .{ .key = "EB_ROTATE_DELETED", .value = del_s },
    };
    if (!syslog.emitFor(a, syslog_identity, t, 6, "EB_ROTATE_DONE", &params, &jfields, msg)) {
        warn("cannot emit syslog event", .{});
    }
}

fn updateMetrics(c: Ctx, path: ?[]const u8, logs_kept: usize, bytes_kept: u64, record_completion: bool) void {
    const p = path orelse return;
    metrics.update(c.gpa, p, @intCast(logs_kept), bytes_kept, record_completion) catch |err|
        warn("cannot update metrics file {s}: {t}", .{ p, err });
}

const KeepStats = struct {
    logs: usize = 0,
    bytes: u64 = 0,

    fn add(s: *KeepStats, bytes: ?u64) void {
        if (bytes) |n| {
            s.logs += 1;
            s.bytes += n;
        }
    }
};

fn cmdFailed(c: Ctx, args: []const [:0]const u8) u8 {
    var pos: std.ArrayList([]const u8) = .empty;
    defer pos.deinit(c.gpa);
    var syslog_v: ?[]const u8 = null;
    var metrics_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--syslog")) {
            if (i + 1 >= args.len) die("--syslog needs a target", .{});
            i += 1;
            syslog_v = args[i];
        } else if (std.mem.startsWith(u8, a, "--syslog=")) {
            syslog_v = a["--syslog=".len..];
        } else if (std.mem.eql(u8, a, "--metrics-file")) {
            if (i + 1 >= args.len) die("--metrics-file needs a path", .{});
            i += 1;
            metrics_file = args[i];
        } else if (std.mem.startsWith(u8, a, "--metrics-file=")) {
            metrics_file = a["--metrics-file=".len..];
        } else {
            pos.append(c.gpa, a) catch return 2;
        }
    }
    if (pos.items.len < 3) die("failed needs STATUS NAME LOGDIR [TMP_LOGDIR]", .{});
    const status = pos.items[0];
    const name = pos.items[1];
    const explicit: ?[]const u8 = if (pos.items.len >= 4 and pos.items[3].len > 0) pos.items[3] else null;
    if (!allDigits(status)) die("STATUS must be a number, not '{s}'", .{status});
    const logdir = fsx.openDir(fsx.cwd, pos.items[2], true) catch die("LOGDIR {s} is not a directory", .{pos.items[2]});
    defer sys.close(logdir);
    if (metrics_file) |p| if (p.len == 0) die("--metrics-file needs a path", .{});
    var kept: KeepStats = .{};
    defer updateMetrics(c, metrics_file, kept.logs, kept.bytes, false);
    const syslog_target = resolveSyslog(c, syslog_v);
    const logdir_s = joinable(pos.items[2]);
    if (std.mem.indexOfNone(u8, status, "0") == null) return 0;
    closeBuildLogs(c, logdir, logdir_s, name, explicit);

    const src_path: ?[]u8 = switch (lastLog(c, explicit)) {
        .path => |p| p,
        .no_eb => {
            cli.out("No EasyBuild log to keep for {s}: eb is not on PATH.\n", .{name});
            emitFailedSyslog(c, syslog_target, status, name, logdir_s, false, 0, false, "no-eb");
            return 0;
        },
        .failed => |code| {
            cli.out("No EasyBuild log to keep for {s}: eb --last-log exited {d}.\n", .{ name, code });
            emitFailedSyslog(c, syslog_target, status, name, logdir_s, false, 0, false, "last-log-failed");
            return 0;
        },
        .none => null,
    };
    defer if (src_path) |p| c.gpa.free(p);
    const src = if (src_path) |p| fsx.openRegular(fsx.cwd, p, true) catch null else null;
    if (src == null) {
        cli.out("No EasyBuild log to keep for {s}.\n", .{name});
        emitFailedSyslog(c, syslog_target, status, name, logdir_s, false, 0, false, "no-log");
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
        const cmd_kept = keepCommandOutput(c, logdir, logdir_s, name, null);
        kept.logs += cmd_kept.logs;
        kept.bytes += cmd_kept.bytes;
        emitFailedSyslog(c, syslog_target, status, name, logdir_s, false, cmd_kept.logs, false, if (cmd_kept.logs > 0) "kept" else "other-build");
        return 0;
    };

    rewind(src.?.fd);
    const ebout = c.gpa.print("{s}.failed.ebout.log", .{name}) catch return 0;
    defer c.gpa.free(ebout);
    const ebout_bytes = keep(c, logdir, logdir_s, src.?.fd, src.?.stat, ebout, null);
    kept.add(ebout_bytes);
    const ebout_kept = ebout_bytes != null;
    if (ebout_kept)
        cli.out("Failed build log: {s}/{s}\n", .{ logdir_s, ebout });

    const cmd_kept = keepCommandOutput(c, logdir, logdir_s, name, src_text);
    kept.logs += cmd_kept.logs;
    kept.bytes += cmd_kept.bytes;

    // A meson test step prints only the last 100 lines of a failing test;
    // the full output is meson-logs/testlog.txt in the build directory. A
    // testlog whose tests all passed is not the failure.
    var meson_kept = false;
    if (src_text) |t| if (scan.lastMesonDir(t, utf8Locale(c))) |dir| blk: {
        const testlog = c.gpa.print("{s}/meson-logs/testlog.txt", .{dir}) catch break :blk;
        defer c.gpa.free(testlog);
        if (fsx.openRegular(fsx.cwd, testlog, true)) |tl| {
            defer sys.close(tl.fd);
            const tl_text: ?[]u8 = fsx.readAll(c.gpa, tl.fd, scan_limit) catch |err| err_blk: {
                warn("cannot scan {s}: {t}", .{ testlog, err });
                break :err_blk null;
            };
            defer if (tl_text) |x| c.gpa.free(x);
            if (tl_text) |x| if (scan.mesonPassed(x)) break :blk;
            rewind(tl.fd);
            const dest = c.gpa.print("{s}.failed.meson-testlog.txt", .{name}) catch break :blk;
            defer c.gpa.free(dest);
            const meson_bytes = keep(c, logdir, logdir_s, tl.fd, tl.stat, dest, null);
            if (meson_bytes != null) {
                cli.out("Failed meson test log: {s}/{s}\n", .{ logdir_s, dest });
                meson_kept = true;
                kept.add(meson_bytes);
            }
        } else |_| {}
    };
    emitFailedSyslog(c, syslog_target, status, name, logdir_s, ebout_kept, cmd_kept.logs, meson_kept, if (ebout_kept or cmd_kept.logs > 0 or meson_kept) "kept" else "no-log");
    return 0;
}

/// The failing command's own output holds the diagnostic beyond EasyBuild's
/// printed tail. Only the final command's text streams are kept, and from
/// the session log only when that command did not complete successfully;
/// only from inside EASYBUILD_TMPDIR, not through a symbolic link, and owned
/// by this user. A stream is compared with EASYBUILD_TMPDIR with both
/// resolved, as EasyBuild names the stream through EASYBUILD_TMPDIR as it was
/// given.
fn keepCommandOutput(c: Ctx, logdir: fsx.fd_t, logdir_s: []const u8, name: []const u8, src_text: ?[]const u8) KeepStats {
    var kept: KeepStats = .{};
    var out_txt: ?[]const u8 = null;
    var stdout_text: ?[]u8 = null;
    defer if (stdout_text) |t| c.gpa.free(t);
    const stdout_name = c.gpa.print("{s}.stdout.log", .{name}) catch return kept;
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
        out_txt = scan.failedCommandOutput(t);
    };
    const command_out = out_txt orelse return kept;
    const tmpdir = c.getenv("EASYBUILD_TMPDIR") orelse "";
    if (tmpdir.len == 0) {
        cli.out("Failed command output not kept: EASYBUILD_TMPDIR is not set.\n", .{});
        return kept;
    }
    const root = command_out[0 .. command_out.len - "/out.txt".len];
    var tb: [sys.path_max]u8 = undefined;
    const tmp_real: ?[]const u8 = fsx.realpath(fsx.cwd, tmpdir, &tb) catch null;
    const prefix: ?[]u8 = if (tmp_real) |t|
        c.gpa.print("{s}/", .{if (t[t.len - 1] == '/') t[0 .. t.len - 1] else t}) catch return kept
    else
        null;
    defer if (prefix) |p| c.gpa.free(p);

    for ([_][]const u8{ "out", "err" }) |stream| {
        const path = c.gpa.print("{s}/{s}.txt", .{ root, stream }) catch return kept;
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
        const dest = c.gpa.print("{s}.failed.command-{s}.txt", .{ name, stream }) catch return kept;
        defer c.gpa.free(dest);
        const bytes = keep(c, logdir, logdir_s, f.fd, f.stat, dest, 0o600);
        if (bytes != null) {
            cli.out("Failed command output: {s}/{s}\n", .{ logdir_s, dest });
            kept.add(bytes);
        }
    }
    return kept;
}

fn parseDays(opt: []const u8, v: ?[]const u8) u64 {
    const s = v orelse die("{s} needs a number of days", .{opt});
    if (!allDigits(s)) die("{s} needs a number of days", .{opt});
    return std.fmt.parseInt(u64, s, 10) catch die("{s} needs a number of days", .{opt});
}

/// The lock file every rotate of a tree holds, directly in its ROOT.
const rotate_lock = ".eb-keep-logs-rotate.lock";
/// How long rotate waits for the lock without --lock-timeout, in seconds.
const default_lock_timeout: u64 = 600;
/// The longest wait --lock-timeout sets, over 31 years: the shell script's
/// flock(1) cannot set a timer for 10^19 seconds.
const max_lock_timeout: u64 = 999_999_999;
/// The exit status when another rotate holds the lock past --lock-timeout,
/// EX_TEMPFAIL: run it again later.
const lock_busy_exit: u8 = 75;

fn parseSeconds(v: []const u8) u64 {
    if (!allDigits(v)) die("--lock-timeout needs a number of seconds", .{});
    return @min(std.fmt.parseInt(u64, v, 10) catch max_lock_timeout, max_lock_timeout);
}

fn monotonicNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn realtimeSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Reached at each of rotate's named points where a crash could land, so a
/// `-Dtest-ops` artifact can be told, through `EB_KEEP_LOGS_TEST_KILL_AT`,
/// to send itself a signal there and let a later invocation show what that
/// left behind. `EB_KEEP_LOGS_TEST_KILL_SIG` names the signal, KILL, TERM or
/// INT; unset or any other value means KILL. In any other build this reads
/// no environment and costs nothing: `atomic.replaceable` is false, so the
/// body below does not exist.
fn testKillAt(c: Ctx, step: []const u8) void {
    if (comptime !atomic.replaceable) return;
    const want = c.getenv("EB_KEEP_LOGS_TEST_KILL_AT") orelse return;
    if (!std.mem.eql(u8, want, step)) return;
    const sig_name = c.getenv("EB_KEEP_LOGS_TEST_KILL_SIG") orelse "";
    const sig: linux.SIG = if (std.mem.eql(u8, sig_name, "TERM"))
        .TERM
    else if (std.mem.eql(u8, sig_name, "INT"))
        .INT
    else
        .KILL;
    _ = linux.kill(linux.getpid(), sig);
}

/// Open `root/.eb-keep-logs-rotate.lock`, created when missing; for reading
/// when it cannot be opened for writing, by a user who may not write ROOT.
/// A symbolic link or a file that is not a regular one is refused.
fn openLock(root: fsx.fd_t) sys.Error!fsx.fd_t {
    const fd = sys.openat(root, rotate_lock, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0o666) catch |err| switch (err) {
        error.AccessDenied, error.ReadOnly => sys.openat(root, rotate_lock, .{ .NOFOLLOW = true, .NONBLOCK = true }, 0) catch return err,
        else => return err,
    };
    errdefer sys.close(fd);
    if (!(try fsx.fstat(fd)).isReg()) return error.InvalidArgument;
    return fd;
}

/// Take an exclusive flock(2) on `fd`, waiting up to `timeout_s` seconds for
/// another holder to let go; 0 tries once. The lock lasts until `fd` is
/// closed, or the process exits. Not the pinned library's
/// `state.lockExclusive`, which gives every failure but EAGAIN as Unexpected.
fn waitLock(fd: fsx.fd_t, timeout_s: u64) (sys.Error || error{TimedOut})!void {
    const deadline = monotonicNs() + @as(i128, timeout_s) * std.time.ns_per_s;
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        if (linux.errno(rc) != .AGAIN) {
            if (try sys.result(rc) != null) return;
            continue;
        }
        const left = deadline - monotonicNs();
        if (left <= 0) return error.TimedOut;
        var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(@min(left, 20 * std.time.ns_per_ms)) };
        _ = linux.nanosleep(&ts, null);
    }
}

/// Days since a run directory's name, YYYYMMDD_HHMMSS, at its local
/// midnight; null when the name is not a run directory. The name, not the
/// mtime: compressing the run's logs moves the mtime of the directory they
/// are in, where a chmod changes only the ctime.
fn runAgeDays(zone: *const localtime.Zone, name: []const u8, now: i64) ?i64 {
    if (name.len != 15 or name[8] != '_') return null;
    if (!allDigits(name[0..8]) or !allDigits(name[9..15])) return null;
    const y = std.fmt.parseInt(i64, name[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, name[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, name[6..8], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > localtime.daysInMonth(y, m)) return null;
    const start = zone.fromLocal(localtime.daysFromCivil(y, m, d) * 86400) orelse return null;
    // now and start are each bounded on their own (EB_KEEP_LOGS_NOW takes any
    // i64; a run's year is 4 digits, so start spans at most a few thousand
    // years around the epoch), but the two together can still carry the
    // difference past what i64 holds. Saturate rather than let that wrap or
    // panic: a now so far below start that the true age would not fit is
    // every bit as far from old enough to compress or delete as i64's own
    // minimum, and the same the other way around for a now far above start.
    return @divTrunc(now -| start, 86400);
}

const Renames = std.StringHashMapUnmanaged([]const u8);

/// Directories a rotate walk holds open at once, the deepest ones on the
/// path it is in. Below this depth the shallowest of them is closed, and
/// opened again when the walk climbs back to it.
const walk_window = 8;

/// One directory on the path a walk is in.
const WalkDir = struct {
    /// -1 while the window is below it.
    fd: fsx.fd_t,
    dev: u64,
    ino: u64,
    /// The length of the walk's path up to and including this directory.
    path_len: usize,
    /// Its subdirectories, in the order it listed them, and how many of
    /// those the walk has entered.
    subdirs: []const []const u8,
    next: usize = 0,
};

/// Visit every directory under `root`, `root` first, depth first and
/// without following symbolic links: `visitor.visit(fd, path, files)` gets
/// each one's descriptor, its path for messages and the names of its *.log
/// and *.txt regular files. Each directory is opened from the one that
/// holds it with `O_NOFOLLOW`, so a directory swapped for a link is
/// refused. At most `walk_window` of them are open at once, whatever the
/// depth. One the window has left is opened again through ".." of the
/// child the walk climbs back from, and only when ".." is still the same
/// directory; when it is not, because the tree moved under the walk, it is
/// opened again from `root`, one component at a time. While nothing moves,
/// each directory is listed once and opened at most twice, so the walk's
/// cost grows with the size of the tree, not with its depth times its size.
fn walkTree(gpa: Allocator, arena: Allocator, root: fsx.fd_t, visitor: anytype) void {
    var rb: [sys.path_max]u8 = undefined;
    const top = fsx.realpathFd(root, &rb) catch |err| return warn("cannot resolve a run directory: {t}", .{err});
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    path.appendSlice(gpa, top) catch return;
    var stack: std.ArrayList(WalkDir) = .empty;
    defer {
        // The root is the caller's.
        if (stack.items.len > 1) for (stack.items[1..]) |d| if (d.fd != -1) sys.close(d.fd);
        stack.deinit(gpa);
    }
    const subdirs = listDir(gpa, arena, root, path.items, visitor) orelse return;
    stack.append(gpa, .{ .fd = root, .dev = 0, .ino = 0, .path_len = path.items.len, .subdirs = subdirs }) catch return;
    while (stack.items.len > 0) {
        const at = &stack.items[stack.items.len - 1];
        if (at.fd != -1 and at.next < at.subdirs.len) {
            const name = at.subdirs[at.next];
            at.next += 1;
            path.append(gpa, '/') catch return;
            path.appendSlice(gpa, name) catch return;
            const fd = fsx.openDir(at.fd, name, false) catch |err| {
                warn("cannot open {s}: {t}", .{ path.items, err });
                path.shrinkRetainingCapacity(at.path_len);
                continue;
            };
            const id = fsx.fstat(fd) catch |err| {
                sys.close(fd);
                warn("cannot open {s}: {t}", .{ path.items, err });
                path.shrinkRetainingCapacity(at.path_len);
                continue;
            };
            const inner = listDir(gpa, arena, fd, path.items, visitor) orelse {
                sys.close(fd);
                return;
            };
            stack.append(gpa, .{ .fd = fd, .dev = id.dev, .ino = id.ino, .path_len = path.items.len, .subdirs = inner }) catch {
                sys.close(fd);
                return;
            };
            if (stack.items.len - 1 > walk_window) {
                const left = &stack.items[stack.items.len - 1 - walk_window];
                sys.close(left.fd);
                left.fd = -1;
            }
            continue;
        }
        const done = stack.pop().?;
        if (stack.items.len == 0) break;
        const up = &stack.items[stack.items.len - 1];
        path.shrinkRetainingCapacity(up.path_len);
        if (up.fd == -1) up.fd = reopenDir(root, top.len, path.items, up.*, done.fd);
        if (done.fd != -1) sys.close(done.fd);
        if (up.fd == -1) warn("cannot return to {s}: it moved during the walk", .{path.items});
    }
}

/// List the directory `fd`, whose path is `here`, hand its log files to
/// `visitor` and return its subdirectories. A read that fails partway is
/// warned, and what it read before that still counts. Null when memory
/// runs out.
fn listDir(gpa: Allocator, arena: Allocator, fd: fsx.fd_t, here: []const u8, visitor: anytype) ?[]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var subdirs: std.ArrayList([]const u8) = .empty;
    {
        var it = fsx.DirIter.init(gpa, fd) catch return null;
        defer it.deinit(gpa);
        while (it.next() catch |err| blk: {
            warn("cannot read {s}: {t}", .{ here, err });
            break :blk null;
        }) |e| {
            const t = fsx.entryType(fd, e) catch continue;
            if (t == fsx.DT.DIR) {
                subdirs.append(arena, arena.dupe(u8, e.name) catch return null) catch return null;
            } else if (t == fsx.DT.REG and (std.mem.endsWith(u8, e.name, ".log") or std.mem.endsWith(u8, e.name, ".txt"))) {
                files.append(arena, arena.dupe(u8, e.name) catch return null) catch return null;
            }
        }
    }
    visitor.visit(fd, here, files.items);
    return subdirs.items;
}

/// Open again `up`, the directory at `path`, `root_len` bytes of which are
/// `root`'s own: through ".." of `child`, a directory the walk entered from
/// it, when that is still `up`; otherwise from `root`, one component at a
/// time with `O_NOFOLLOW`, when that reaches `up`. -1 when neither does.
fn reopenDir(root: fsx.fd_t, root_len: usize, path: []const u8, up: WalkDir, child: fsx.fd_t) fsx.fd_t {
    if (child != -1) if (fsx.openDir(child, "..", false)) |fd| {
        if (sameDir(fd, up)) return fd;
        sys.close(fd);
    } else |_| {};
    var fd = fsx.openDir(root, ".", false) catch return -1;
    var it = std.mem.tokenizeScalar(u8, path[root_len..], '/');
    while (it.next()) |name| {
        const next = fsx.openDir(fd, name, false) catch {
            sys.close(fd);
            return -1;
        };
        sys.close(fd);
        fd = next;
    }
    if (sameDir(fd, up)) return fd;
    sys.close(fd);
    return -1;
}

fn sameDir(fd: fsx.fd_t, d: WalkDir) bool {
    const st = fsx.fstat(fd) catch return false;
    return st.dev == d.dev and st.ino == d.ino;
}

/// gzip every *.log and *.txt regular file under `dir`, at any depth,
/// without following symbolic links. `dir`'s own `.licensed-logs`, if it
/// names a compressed file, follows that file right after it is
/// compressed, as the shell script's own loop does, so a crash before
/// the next file's compression leaves no more than that one file's own
/// line to ever go stale.
fn compressTree(c: Ctx, arena: Allocator, dir: fsx.fd_t, count: *usize) void {
    const Compress = struct {
        c: Ctx,
        arena: Allocator,
        count: *usize,

        fn visit(v: @This(), fd: fsx.fd_t, here: []const u8, files: []const []const u8) void {
            for (files) |n| {
                testKillAt(v.c, "mid-copy");
                var step: logs.GzipStep = undefined;
                logs.gzipInPlaceAtStep(v.c.gpa, v.c.io, fd, n, &step) catch |err| switch (step) {
                    .archive => {
                        warn("cannot compress {s}/{s}: {t}", .{ here, n, err });
                        continue;
                    },
                    // The archive is in place and the original gone; only the
                    // directory sync that makes that durable failed.
                    .directory_sync => warn("cannot sync {s}/{s}.gz: {s}", .{ here, n, errnoName(sys.last_errno) }),
                };
                v.count.* += 1;
                const from = v.arena.print("{s}/{s}", .{ here, n }) catch return;
                const to = v.arena.print("{s}.gz", .{from}) catch return;
                var renames: Renames = .empty;
                renames.put(v.arena, from, to) catch return;
                followLists(v.c, fd, &renames);
                testKillAt(v.c, "after-rename");
            }
        }
    };
    walkTree(c.gpa, arena, dir, Compress{ .c = c, .arena = arena, .count = count });
}

/// Collect every *.log and *.txt regular file under `dir` that a rotation
/// would compress (single link and no existing `.gz`), without following
/// symbolic links or changing anything.
fn previewTree(c: Ctx, arena: Allocator, dir: fsx.fd_t, paths: *std.ArrayList([]const u8)) void {
    const Preview = struct {
        arena: Allocator,
        paths: *std.ArrayList([]const u8),

        fn visit(v: @This(), fd: fsx.fd_t, here: []const u8, files: []const []const u8) void {
            for (files) |n| {
                const st = fsx.statAt(fd, n, false) catch continue;
                if (!st.isReg() or st.nlink > 1) continue;
                const gz = v.arena.print("{s}.gz", .{n}) catch return;
                if (fsx.statAt(fd, gz, false)) |_| continue else |err| switch (err) {
                    error.NotFound => {},
                    else => continue,
                }
                const path = v.arena.print("{s}/{s}", .{ here, n }) catch return;
                v.paths.append(v.arena, path) catch return;
            }
        }
    };
    walkTree(c.gpa, arena, dir, Preview{ .arena = arena, .paths = paths });
}

/// Rewrite `dir`'s own `.licensed-logs`, if it has one, so it names the
/// compressed files. `renames` only ever carries a file that lived
/// directly in `dir`, since a `.licensed-logs` only ever names files
/// that live beside it, so `dir`'s own entry, with no need to look under
/// its subdirectories, is the only one a rename there could change. The
/// new list is written beside the old one, synced, renamed over it and
/// its directory synced, as copyDurable does, so a reader or a crash
/// finds one list or the other.
fn followLists(c: Ctx, dir: fsx.fd_t, renames: *const Renames) void {
    var it = fsx.DirIter.init(c.gpa, dir) catch return;
    defer it.deinit(c.gpa);
    while (it.next() catch return) |e| {
        const t = fsx.entryType(dir, e) catch continue;
        if (t == fsx.DT.REG and std.mem.eql(u8, e.name, logs.licensed_list)) {
            const f = fsx.openRegular(dir, e.name, false) catch continue;
            defer sys.close(f.fd);
            const text = fsx.readAll(c.gpa, f.fd, 64 << 20) catch |err| {
                warn("cannot read a {s}: {t}", .{ logs.licensed_list, err });
                continue;
            };
            defer c.gpa.free(text);
            const new = (logs.renameInList(c.gpa, text, renames) catch continue) orelse continue;
            defer c.gpa.free(new);
            fsx.replaceContents(c.gpa, dir, e.name, new) catch |err| {
                warn("cannot update a {s}: {t}", .{ logs.licensed_list, err });
                continue;
            };
            sys.fsync(dir) catch warn("cannot sync a {s}: {s}", .{ logs.licensed_list, errnoName(sys.last_errno) });
        }
    }
}

/// The runs directly under `root` that this rotate writes into: the run
/// holding its standard output or error when either is a file and, as srun
/// passes the output on over a pipe, the run holding EB_PIPELINE_LOG_DIR, the
/// log directory eb-pipeline exports. Such a run is still going.
fn ownRuns(c: Ctx, arena: Allocator, root: fsx.fd_t) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var rb: [sys.path_max]u8 = undefined;
    const real = fsx.realpathFd(root, &rb) catch return &.{};
    const here = arena.dupe(u8, if (std.mem.eql(u8, real, "/")) "" else real) catch return &.{};
    for ([_]fsx.fd_t{ 1, 2 }) |fd| {
        const st = fsx.fstat(fd) catch continue;
        if (!st.isReg() or st.nlink == 0) continue;
        addRunOf(arena, &names, here, fsx.realpathFd(fd, &rb) catch continue);
    }
    if (c.getenv("EB_PIPELINE_LOG_DIR")) |d| if (d.len > 0) {
        if (fsx.realpath(fsx.cwd, d, &rb)) |p| addRunOf(arena, &names, here, p) else |_| {}
    };
    return names.items;
}

/// Add the name of the directory directly under `root` that holds `path`.
fn addRunOf(arena: Allocator, names: *std.ArrayList([]const u8), root: []const u8, path: []const u8) void {
    if (path.len <= root.len + 1 or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return;
    const rest = path[root.len + 1 ..];
    const name = rest[0 .. std.mem.findScalar(u8, rest, '/') orelse rest.len];
    names.append(arena, arena.dupe(u8, name) catch return) catch return;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The runs directly under `root` that a process in `procfs` has a file in
/// open for writing, of the processes whose descriptors this one may read: a
/// build that is still going, whichever run it writes into. A link PID/fd/N
/// has its owner's write bit when N is open for writing; for a file removed
/// since, the link names the path it had, with " (deleted)" added.
fn writtenRuns(gpa: Allocator, arena: Allocator, procfs: []const u8, root: fsx.fd_t) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var rb: [sys.path_max]u8 = undefined;
    const real = fsx.realpathFd(root, &rb) catch return &.{};
    const here = arena.dupe(u8, if (std.mem.eql(u8, real, "/")) "" else real) catch return &.{};
    const pd = fsx.openDir(fsx.cwd, procfs, false) catch return &.{};
    defer sys.close(pd);
    var it = fsx.DirIter.init(gpa, pd) catch return &.{};
    defer it.deinit(gpa);
    while (it.next() catch null) |p| {
        if (!allDigits(p.name)) continue;
        var fb: [32]u8 = undefined;
        const fd_dir = std.fmt.bufPrint(&fb, "{s}/fd", .{p.name}) catch continue;
        const fds = fsx.openDir(pd, fd_dir, false) catch continue;
        defer sys.close(fds);
        var fit = fsx.DirIter.init(gpa, fds) catch continue;
        defer fit.deinit(gpa);
        while (fit.next() catch null) |f| {
            const st = fsx.statAt(fds, f.name, false) catch continue;
            if (st.mode & 0o200 == 0) continue;
            addRunOf(arena, &names, here, readLinkAt(fds, f.name, &rb) catch continue);
        }
    }
    return names.items;
}

/// The target of the symbolic link `name` in `dir`.
fn readLinkAt(dir: fsx.fd_t, name: []const u8, out: *[sys.path_max]u8) sys.Error![]const u8 {
    var zb: [sys.path_max:0]u8 = undefined;
    const n = try sys.call(linux.readlinkat, .{ dir, (try sys.z(&zb, name)).ptr, out, out.len });
    return out[0..n];
}

fn cmdRotate(c: Ctx, args: []const [:0]const u8) u8 {
    var root_s: ?[]const u8 = null;
    var compress_v: ?[]const u8 = null;
    var delete_v: ?[]const u8 = null;
    var lock_v: []const u8 = "";
    var syslog_v: ?[]const u8 = null;
    var metrics_file: ?[]const u8 = null;
    var dry_run = false;
    var have_compress = false;
    var have_delete = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--lock-timeout")) {
            if (i + 1 >= args.len) die("--lock-timeout needs a number of seconds", .{});
            i += 1;
            lock_v = args[i];
        } else if (std.mem.startsWith(u8, a, "--lock-timeout=")) {
            lock_v = a["--lock-timeout=".len..];
        } else if (std.mem.eql(u8, a, "--syslog")) {
            if (i + 1 >= args.len) die("--syslog needs a target", .{});
            i += 1;
            syslog_v = args[i];
        } else if (std.mem.startsWith(u8, a, "--syslog=")) {
            syslog_v = a["--syslog=".len..];
        } else if (std.mem.eql(u8, a, "--metrics-file")) {
            if (i + 1 >= args.len) die("--metrics-file needs a path", .{});
            i += 1;
            metrics_file = args[i];
        } else if (std.mem.startsWith(u8, a, "--metrics-file=")) {
            metrics_file = a["--metrics-file=".len..];
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--compress-after") or std.mem.eql(u8, a, "--delete-after")) {
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
    if (metrics_file) |p| if (p.len == 0) die("--metrics-file needs a path", .{});
    const root = fsx.openDir(fsx.cwd, root_p, true) catch die("ROOT {s} is not a directory", .{root_p});
    defer sys.close(root);
    const compress_after = parseDays("--compress-after", if (have_compress) compress_v else null);
    var delete_after: ?u64 = null;
    if (have_delete and delete_v.?.len > 0) {
        delete_after = parseDays("--delete-after", delete_v);
        if (delete_after.? <= compress_after) die("--delete-after must be later than --compress-after", .{});
    }
    const lock_timeout = if (lock_v.len > 0) parseSeconds(lock_v) else default_lock_timeout;
    const syslog_target = resolveSyslog(c, syslog_v);

    const now_s = c.getenv("EB_KEEP_LOGS_NOW") orelse "";
    const fixed_now: ?i64 = if (now_s.len > 0)
        std.fmt.parseInt(i64, now_s, 10) catch die("EB_KEEP_LOGS_NOW must be seconds since the epoch, not '{s}'", .{now_s})
    else
        null;
    var lock: ?fsx.fd_t = null;
    if (!dry_run) {
        lock = openLock(root) catch |err| die("cannot lock {s}/{s}: {t}", .{ joinable(root_p), rotate_lock, err });
        waitLock(lock.?, lock_timeout) catch |err| switch (err) {
            error.TimedOut => {
                sys.close(lock.?);
                cli.err(tool ++ ": another rotate holds the lock {s}/{s}; gave up after {d} s (--lock-timeout)\n", .{ joinable(root_p), rotate_lock, lock_timeout });
                return lock_busy_exit;
            },
            // The file system cannot lock: Lustre without -o flock, NFS without
            // a lock manager, or NFS for a file open only for reading.
            else => warn("cannot lock {s}/{s}: {t}; rotating without the lock", .{ joinable(root_p), rotate_lock, err }),
        };
    }
    defer if (lock) |fd| sys.close(fd);
    testKillAt(c, "after-lock");
    const now: i64 = fixed_now orelse realtimeSeconds();
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

    const own = ownRuns(c, arena, root);
    const written = writtenRuns(c.gpa, arena, "/proc", root);
    var compressed: usize = 0;
    var deleted: usize = 0;
    for (runs.items) |run| {
        const age = runAgeDays(&zone, run, now) orelse continue;
        // A later rotate takes a run that is still written into, by this
        // rotate or by a build that is still going.
        if (contains(own, run) or contains(written, run)) continue;
        if (delete_after) |d| if (age >= @as(i64, @intCast(@min(d, std.math.maxInt(i64))))) {
            if (dry_run) {
                cli.out("delete {s}/{s}\n", .{ joinable(root_p), run });
                deleted += 1;
                continue;
            }
            fsx.deleteTree(c.gpa, root, run) catch |err| {
                warn("cannot delete {s}/{s}: {t}", .{ joinable(root_p), run, err });
                continue;
            };
            deleted += 1;
            continue;
        };
        if (age < @as(i64, @intCast(@min(compress_after, std.math.maxInt(i64))))) continue;
        const dir = fsx.openDir(root, run, false) catch |err| {
            warn("cannot open {s}/{s}: {t}", .{ joinable(root_p), run, err });
            continue;
        };
        defer sys.close(dir);
        if (dry_run) {
            var paths: std.ArrayList([]const u8) = .empty;
            previewTree(c, arena, dir, &paths);
            std.mem.sort([]const u8, paths.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (paths.items) |path| {
                cli.out("compress {s}\n", .{path});
                compressed += 1;
            }
            continue;
        }
        var n: usize = 0;
        compressTree(c, arena, dir, &n);
        compressed += n;
    }
    const summary = if (dry_run)
        arena.print("eb-keep-logs rotate dry-run: {d} file{s} would be compressed, {d} run{s} would be deleted under {s}", .{ compressed, plural(compressed), deleted, plural(deleted), root_p }) catch "eb-keep-logs rotate dry-run"
    else
        arena.print("eb-keep-logs rotate: {d} file{s} compressed, {d} run{s} deleted under {s}", .{ compressed, plural(compressed), deleted, plural(deleted), root_p }) catch "eb-keep-logs rotate";
    cli.out("{s}\n", .{summary});
    if (!dry_run) {
        emitRotateSyslog(c, syslog_target, root_p, compressed, deleted, summary);
        // Run ages use the snapshot above. The metric chooses its completion time
        // while holding the metrics lock, after all rotation work and event
        // emission have completed.
        testKillAt(c, "before-metrics-write");
        updateMetrics(c, metrics_file, 0, 0, true);
    }
    return 0;
}

/// The command line. `failed`, `rotate`, `why` and `history` run those
/// commands; `--help` or `-h` prints the usage and `--version` the version
/// line, both returning 0. No command prints the usage and returns 2, and
/// an unknown one is refused with 2.
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
    if (std.mem.eql(u8, cmd, "why")) return why.cmdWhy(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "history")) return why.cmdHistory(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "failures")) return why.cmdFailures(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "loads")) return loads.cmdLoads(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "runs")) return xalt_runs.cmdRuns(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "used")) return used_cmd.cmdUsed(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "usage")) return usage_cmd.cmdUsage(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "pending")) return pending.cmdPending(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "test-bundle")) return test_bundle.cmdTestBundle(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "test-compare")) return test_bundle.cmdTestCompare(gpa, args[2..]);
    if (std.mem.eql(u8, cmd, "lifecycle")) return lifecycle.cmdLifecycle(c.gpa, c.env, c.envp, args[2..]);
    if (cmd.len == 0) {
        cli.put(1, usage_text);
        return cli.usage_exit;
    }
    die("unknown command '{s}' (failed, rotate, why, history, failures, loads, runs, used, usage, pending, test-bundle, test-compare, lifecycle, --help)", .{cmd});
}

test {
    _ = localtime;
    _ = scan;
    _ = why;
    _ = loads;
    _ = xalt_runs;
    _ = pending;
    _ = used_cmd;
    _ = usage_cmd;
    _ = test_bundle;
    _ = lifecycle;
    _ = syslog;
    _ = metrics;
    _ = walk_tests;
}

/// How long either side of a forked test waits for the other before it
/// gives up: the parent kills the child, and the child exits.
const handshake_ms: i32 = 30_000;

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Wait on `fd` for input, until `timeout_ms` from now. False on a timeout
/// or an error. `pidfd`, when it is not -1, also ends the wait: the child it
/// names has exited. A signal that interrupts the wait does not extend it.
fn waitReadable(fd: i32, pidfd: i32, timeout_ms: i32) bool {
    var fds = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 },
    };
    const n: usize = if (pidfd == -1) 1 else 2;
    const deadline = monotonicMs() + timeout_ms;
    while (true) {
        const left = @max(deadline - monotonicMs(), 0);
        const rc = linux.poll(&fds, n, @intCast(left));
        switch (linux.errno(rc)) {
            .SUCCESS => return rc > 0 and fds[0].revents != 0,
            .INTR => if (left == 0) return false,
            else => return false,
        }
    }
}

/// Reap the child `pidfd` names, waiting at most `handshake_ms` for it to
/// exit, and kill it if it has not. Null when it had to be killed.
fn reapChild(pid: linux.pid_t, pidfd: i32) ?u32 {
    defer _ = linux.close(pidfd);
    var status: i32 = 0;
    if (!waitReadable(pidfd, -1, handshake_ms)) {
        _ = linux.pidfd_send_signal(pidfd, .KILL, null, 0);
        _ = waitReadable(pidfd, -1, handshake_ms);
        _ = linux.waitpid(pid, &status, linux.W.NOHANG);
        return null;
    }
    _ = linux.waitpid(pid, &status, linux.W.NOHANG);
    return @bitCast(status);
}

/// The SIGALRMs of the interval timer the test below starts, counted, with
/// the timer stopped at the last one.
const alarms = struct {
    const last: u32 = 400;
    var count: u32 = 0;

    fn handle(_: linux.SIG) callconv(.c) void {
        if (@atomicRmw(u32, &count, .Add, 1, .monotonic) + 1 == last) every(0);
    }

    /// Deliver SIGALRM every `us` microseconds; 0 stops it.
    fn every(us: i64) void {
        const Itimerval = extern struct { interval: linux.timeval, value: linux.timeval };
        const t: Itimerval = .{ .interval = .{ .sec = 0, .usec = us }, .value = .{ .sec = 0, .usec = us } };
        _ = linux.syscall3(.setitimer, @intCast(@backingInt(linux.ITIMER.REAL)), @intFromPtr(&t), 0);
    }
};

test "waitReadable gives up at its deadline while signals keep interrupting it" {
    var never: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&never, .{ .CLOEXEC = true })));
    defer _ = linux.close(never[0]);
    defer _ = linux.close(never[1]);
    const rc = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    if (rc == 0) {
        const act: linux.Sigaction = .{
            .handler = .{ .handler = alarms.handle },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(.ALRM, &act, null);
        alarms.every(5_000);
        const ready = waitReadable(never[0], -1, 100);
        // The timer still runs when a wait that keeps its deadline ends; a
        // wait that starts over after each signal outlasts the last one.
        linux.exit(if (ready) 2 else if (@atomicLoad(u32, &alarms.count, .monotonic) < alarms.last) 0 else 1);
    }
    const pid: linux.pid_t = @intCast(rc);
    const pidfd_rc = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd_rc) != .SUCCESS) {
        _ = linux.kill(pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return error.TestUnexpectedResult;
    }
    const raw = reapChild(pid, @intCast(pidfd_rc)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(linux.W.IFEXITED(raw));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(raw));
}

/// Pauses the first `mid-copy` until the test has archived one log and
/// planted a FIFO at another's archive name. `testKillAt` is the event and
/// a pipe is the wake-up, so the two rotates meet without a sleep. The
/// wait is bounded: past `handshake_ms` the child exits on its own.
const raced_rotate = struct {
    var event_fd: i32 = -1;
    var wake_fd: i32 = -1;
    var armed: bool = false;

    fn handle(_: linux.SIG) callconv(.c) void {
        if (!armed) return;
        armed = false;
        var b: [1]u8 = .{1};
        _ = linux.write(event_fd, &b, 1);
        if (!waitReadable(wake_fd, -1, handshake_ms)) linux.exit_group(90);
        _ = linux.read(wake_fd, &b, 1);
    }
};

test "errnoName names the errno the kernel gave and nothing else" {
    try std.testing.expectEqualStrings("EIO", errnoName(.IO));
    try std.testing.expectEqualStrings("ENOSPC", errnoName(.NOSPC));
    try std.testing.expectEqualStrings("errno 4095", errnoName(@fromBackingInt(4095)));
    try std.testing.expectEqualStrings("errno 65535", errnoName(@fromBackingInt(65535)));
    try std.testing.expectEqualStrings("no errno", errnoName(.SUCCESS));
}

test "a log another rotate already archived is not counted again" {
    const gpa = std.testing.allocator;
    const base = try testDir(gpa, "raced");
    defer gpa.free(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);
    const kept: usize = 10;
    var i: usize = 0;
    while (i < kept) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d:0>2}.log", .{i}) catch unreachable;
        const fd = try sys.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
        try sys.writeAll(fd, "k\n");
        sys.close(fd);
    }
    const stolen = try sys.openat(dir, "stolen.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
    try sys.writeAll(stolen, "stolen\n");
    sys.close(stolen);
    const node = try sys.openat(dir, "node.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
    try sys.writeAll(node, "node\n");
    sys.close(node);

    var ev: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&ev, .{ .CLOEXEC = true })));
    defer _ = linux.close(ev[0]);
    var wake: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&wake, .{ .CLOEXEC = true })));
    defer _ = linux.close(wake[1]);
    var err_pipe: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&err_pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(err_pipe[0]);
    const rc = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    if (rc == 0) {
        _ = linux.close(ev[0]);
        _ = linux.close(wake[1]);
        _ = linux.close(err_pipe[0]);
        _ = linux.dup3(err_pipe[1], 2, 0);
        _ = linux.close(err_pipe[1]);
        raced_rotate.event_fd = ev[1];
        raced_rotate.wake_fd = wake[0];
        raced_rotate.armed = true;
        var mask = linux.sigemptyset();
        linux.sigaddset(&mask, .TERM);
        const act: linux.Sigaction = .{
            .handler = .{ .handler = raced_rotate.handle },
            .mask = mask,
            .flags = linux.SA.RESTART,
        };
        _ = linux.sigaction(.TERM, &act, null);
        var blocked = linux.sigemptyset();
        linux.sigaddset(&blocked, .TERM);
        _ = linux.sigprocmask(linux.SIG.UNBLOCK, &blocked, null);

        const own = fsx.openDir(dir, ".", false) catch linux.exit(2);
        const page = std.heap.page_allocator;
        var env_map = std.process.Environ.Map.init(page);
        env_map.put("EB_KEEP_LOGS_TEST_KILL_AT", "mid-copy") catch linux.exit(4);
        env_map.put("EB_KEEP_LOGS_TEST_KILL_SIG", "TERM") catch linux.exit(4);
        var threaded = std.Io.Threaded.init(page, .{});
        var arena_state = std.heap.ArenaAllocator.init(page);
        const ctx: Ctx = .{ .gpa = page, .io = threaded.io(), .env = &env_map, .envp = undefined };
        var count: usize = 0;
        compressTree(ctx, arena_state.allocator(), own, &count);
        linux.exit(@intCast(count));
    }
    const pid: linux.pid_t = @intCast(rc);
    _ = linux.close(ev[1]);
    _ = linux.close(wake[0]);
    _ = linux.close(err_pipe[1]);
    const pidfd_rc = linux.pidfd_open(pid, 0);
    if (linux.errno(pidfd_rc) != .SUCCESS) {
        _ = linux.kill(pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return error.TestUnexpectedResult;
    }
    const pidfd: i32 = @intCast(pidfd_rc);
    var reaped = false;
    defer if (!reaped) {
        _ = linux.pidfd_send_signal(pidfd, .KILL, null, 0);
        _ = reapChild(pid, pidfd);
    };
    // The child is now either paused at its first mid-copy, or gone.
    var poke: [1]u8 = undefined;
    if (!waitReadable(ev[0], pidfd, handshake_ms) or linux.read(ev[0], &poke, 1) != 1) {
        return error.TestUnexpectedResult;
    }

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    try logs.gzipInPlace(gpa, threaded.io(), dir, "stolen.log");
    try sys.unlinkat(dir, "node.log", 0);
    _ = try sys.call(linux.mknodat, .{ dir, "node.log.gz", @as(linux.mode_t, linux.S.IFIFO | 0o600), @as(linux.dev_t, 0) });
    var token: [1]u8 = .{1};
    _ = linux.write(wake[1], &token, 1);

    reaped = true;
    const raw = reapChild(pid, pidfd) orelse return error.TestUnexpectedResult;
    try std.testing.expect(linux.W.IFEXITED(raw));
    try std.testing.expectEqual(@as(u8, 10), linux.W.EXITSTATUS(raw));
    var err_buf: [4096]u8 = undefined;
    var err_len: usize = 0;
    // The child is reaped and held the only other write end, so this read
    // ends at end of file.
    while (err_len < err_buf.len) {
        const n = linux.read(err_pipe[0], err_buf[err_len..].ptr, err_buf.len - err_len);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        err_len += n;
    }
    const err_text = err_buf[0..err_len];
    try std.testing.expect(std.mem.indexOf(u8, err_text, "cannot sync") == null);
    var real_buf: [sys.path_max]u8 = undefined;
    const real = try fsx.realpathFd(dir, &real_buf);
    var want_buf: [sys.path_max + 64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, err_text, "cannot compress "));
    for ([_][]const u8{ "stolen.log", "node.log" }) |name| {
        const want = try std.fmt.bufPrint(&want_buf, "eb-keep-logs: cannot compress {s}/{s}: NotFound\n", .{ real, name });
        try std.testing.expect(std.mem.indexOf(u8, err_text, want) != null);
    }
    try std.testing.expect((try fsx.statAt(dir, "stolen.log.gz", false)).isReg());
    try std.testing.expectError(error.NotFound, fsx.statAt(dir, "stolen.log", false));
    const node_gz = try fsx.statAt(dir, "node.log.gz", false);
    try std.testing.expect(node_gz.mode & linux.S.IFMT == linux.S.IFIFO);
    try std.testing.expectError(error.NotFound, fsx.statAt(dir, "node.log", false));
    i = 0;
    while (i < kept) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const gz = std.fmt.bufPrint(&name_buf, "f{d:0>2}.log.gz", .{i}) catch unreachable;
        try std.testing.expect((try fsx.statAt(dir, gz, false)).isReg());
    }
}

/// The walk tests and their helpers, in a container nothing in the product
/// binary refers to, so `walkSeed`'s read of EB_KEEP_LOGS_WALK_SEED never
/// reaches product code: `zig build` never analyzes a declaration no
/// reachable path leads to.
const walk_tests = struct {
    /// The fixtures' seed: from the environment when it names one, a random
    /// value otherwise, printed so a failing run can be replayed.
    fn walkSeed(gpa: Allocator) u64 {
        if (fsx.openRegular(fsx.cwd, "/proc/self/environ", false)) |opened| {
            defer sys.close(opened.fd);
            if (fsx.readAll(gpa, opened.fd, 1 << 20)) |block| {
                defer gpa.free(block);
                var it = std.mem.splitScalar(u8, block, 0);
                while (it.next()) |entry| {
                    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                    if (!std.mem.eql(u8, entry[0..eq], "EB_KEEP_LOGS_WALK_SEED")) continue;
                    if (std.fmt.parseInt(u64, entry[eq + 1 ..], 0)) |n| return n else |_| break;
                }
            } else |_| {}
        } else |_| {}
        var rnd: [8]u8 = undefined;
        _ = sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 }) catch return 0;
        return std.mem.readInt(u64, &rnd, .little);
    }

    const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
    const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

    /// A forked child that stops at every call of one system call until the
    /// test answers it, through a seccomp listener the test takes from it.
    const Child = struct {
        pid: linux.pid_t,
        pidfd: i32,
        listener: i32,

        /// Fork. The child holds at most `nofile` descriptors when that is
        /// set, stops at every `nr` call from then on, and exits with what
        /// `body.run()` returns.
        fn start(nr: linux.SYS, nofile: ?u64, body: anytype) !Child {
            var pipe_fd: [2]i32 = undefined;
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe_fd, .{ .CLOEXEC = true })));
            defer _ = linux.close(pipe_fd[0]);
            const rc = linux.fork();
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
            if (rc == 0) {
                _ = linux.close(pipe_fd[0]);
                if (nofile) |n| {
                    const lim: linux.rlimit = .{ .cur = n, .max = n };
                    if (linux.errno(linux.prlimit(0, .NOFILE, &lim, null)) != .SUCCESS) linux.exit(100);
                }
                const filters = [_]SockFilter{
                    .{ .code = linux.BPF.LD | linux.BPF.W | linux.BPF.ABS, .jt = 0, .jf = 0, .k = 0 },
                    .{ .code = linux.BPF.JMP | linux.BPF.JEQ | linux.BPF.K, .jt = 0, .jf = 1, .k = @intCast(@backingInt(nr)) },
                    .{ .code = linux.BPF.RET | linux.BPF.K, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.USER_NOTIF },
                    .{ .code = linux.BPF.RET | linux.BPF.K, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW },
                };
                const prog = SockFprog{ .len = filters.len, .filter = &filters };
                if (linux.errno(linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) linux.exit(101);
                const listener = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.NEW_LISTENER, &prog);
                if (linux.errno(listener) != .SUCCESS) linux.exit(102);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, @intCast(listener), .little);
                _ = linux.write(pipe_fd[1], &bytes, 4);
                _ = linux.close(pipe_fd[1]);
                linux.exit(body.run());
            }
            _ = linux.close(pipe_fd[1]);
            const pid: linux.pid_t = @intCast(rc);
            const pidfd_rc = linux.pidfd_open(pid, 0);
            if (linux.errno(pidfd_rc) != .SUCCESS) {
                _ = linux.kill(pid, .KILL);
                var status: i32 = 0;
                _ = linux.waitpid(pid, &status, 0);
                return error.TestUnexpectedResult;
            }
            const pidfd: i32 = @intCast(pidfd_rc);
            var bytes: [4]u8 = undefined;
            if (!waitReadable(pipe_fd[0], pidfd, handshake_ms) or linux.read(pipe_fd[0], &bytes, 4) != 4) {
                _ = reapChild(pid, pidfd);
                return error.TestUnexpectedResult;
            }
            const got = linux.pidfd_getfd(pidfd, std.mem.readInt(i32, &bytes, .little), 0);
            if (linux.errno(got) != .SUCCESS) {
                _ = reapChild(pid, pidfd);
                return error.TestUnexpectedResult;
            }
            return .{ .pid = pid, .pidfd = pidfd, .listener = @intCast(got) };
        }

        /// Answer each stopped call with `answer.call(pid, data)`, the errno
        /// to fail it with or `.SUCCESS` to let it run, until the child
        /// exits, and reap it. Null when it had not exited `handshake_ms`
        /// after the start and was killed.
        fn finish(ch: Child, answer: anytype) ?u32 {
            defer _ = linux.close(ch.listener);
            var fds = [2]linux.pollfd{
                .{ .fd = ch.pidfd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = ch.listener, .events = linux.POLL.IN, .revents = 0 },
            };
            const deadline = monotonicMs() + handshake_ms;
            while (true) {
                const left = deadline - monotonicMs();
                if (left <= 0) break;
                const pr = linux.poll(&fds, fds.len, @intCast(left));
                if (linux.errno(pr) == .INTR) continue;
                if (linux.errno(pr) != .SUCCESS) break;
                if (fds[0].revents != 0) return reapChild(ch.pid, ch.pidfd);
                if (fds[1].revents == 0) continue;
                var note: linux.SECCOMP.notif = std.mem.zeroes(linux.SECCOMP.notif);
                const rr = linux.ioctl(ch.listener, linux.SECCOMP.IOCTL_NOTIF.RECV, @intFromPtr(&note));
                if (linux.errno(rr) == .NOENT) continue;
                if (linux.errno(rr) != .SUCCESS) {
                    fds[1].fd = -1;
                    continue;
                }
                const e: linux.E = answer.call(@intCast(note.pid), &note.data);
                var resp: linux.SECCOMP.notif_resp = .{
                    .id = note.id,
                    .val = 0,
                    .@"error" = if (e == .SUCCESS) 0 else -@as(i32, @intCast(@backingInt(e))),
                    .flags = if (e == .SUCCESS) linux.SECCOMP.USER_NOTIF_FLAG_CONTINUE else 0,
                };
                _ = linux.ioctl(ch.listener, linux.SECCOMP.IOCTL_NOTIF.SEND, @intFromPtr(&resp));
            }
            _ = linux.pidfd_send_signal(ch.pidfd, .KILL, null, 0);
            _ = reapChild(ch.pid, ch.pidfd);
            return null;
        }
    };

    /// Runs a rotate's dry-run and then its compress over `root` in the
    /// child, and exits 0 when each found `want` files, 1 when the dry-run
    /// did not and 2 when the compress did not.
    const Rotate = struct {
        root: fsx.fd_t,
        want: usize,
        /// When set, the child's warnings go to this descriptor instead of
        /// to the test's own standard error.
        warnings: ?fsx.fd_t = null,

        fn run(r: Rotate) u8 {
            if (r.warnings) |fd| _ = linux.dup3(fd, 2, 0);
            const page = std.heap.page_allocator;
            var arena_state = std.heap.ArenaAllocator.init(page);
            const arena = arena_state.allocator();
            var env_map = std.process.Environ.Map.init(page);
            var threaded = std.Io.Threaded.init(page, .{});
            const ctx: Ctx = .{ .gpa = page, .io = threaded.io(), .env = &env_map, .envp = undefined };
            var paths: std.ArrayList([]const u8) = .empty;
            previewTree(ctx, arena, r.root, &paths);
            if (paths.items.len != r.want) return 1;
            var count: usize = 0;
            compressTree(ctx, arena, r.root, &count);
            return if (count == r.want) 0 else 2;
        }
    };

    /// Lets every call run and counts them.
    const Count = struct {
        n: usize = 0,
        fn call(c: *Count, _: linux.pid_t, _: *const linux.SECCOMP.data) linux.E {
            c.n += 1;
            return .SUCCESS;
        }
    };

    fn makeDir(dir: fsx.fd_t, name: []const u8) !fsx.fd_t {
        var zb: [sys.path_max:0]u8 = undefined;
        _ = try sys.call(linux.mkdirat, .{ dir, (try sys.z(&zb, name)).ptr, @as(linux.mode_t, 0o755) });
        return fsx.openDir(dir, name, false);
    }

    fn makeLog(dir: fsx.fd_t, name: []const u8) !void {
        const fd = try sys.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
        defer sys.close(fd);
        try sys.writeAll(fd, "log\n");
    }

    /// A chain of `depth` directories under `dir`, with `x.log` at the
    /// bottom. `level.make(fd, i)` makes and names the next directory of the
    /// chain in level `i`, after anything else it puts there. The path of
    /// the bottom directory relative to `dir`, which the caller frees.
    fn makeChain(gpa: Allocator, dir: fsx.fd_t, depth: usize, level: anytype) ![]u8 {
        var rel: std.ArrayList(u8) = .empty;
        errdefer rel.deinit(gpa);
        var fd = try fsx.openDir(dir, ".", false);
        defer sys.close(fd);
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            const name = try level.make(fd, i);
            if (rel.items.len > 0) try rel.append(gpa, '/');
            try rel.appendSlice(gpa, name);
            const next = try fsx.openDir(fd, name, false);
            sys.close(fd);
            fd = next;
        }
        try makeLog(fd, "x.log");
        return rel.toOwnedSlice(gpa);
    }

    /// The path of `name` in the directory `rel` under it.
    fn joined(buf: []u8, rel: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ rel, name });
    }

    const deep_levels: usize = 300;

    /// Each level of the chain has a side directory with one log beside the
    /// next directory of the chain, so a directory the window has left still
    /// has a subdirectory to enter when the walk climbs back to it.
    const Comb = struct {
        rand: std.Random,
        buf: [1]u8 = undefined,

        fn make(c: *Comb, fd: fsx.fd_t, _: usize) ![]const u8 {
            const side = try makeDir(fd, "~side");
            defer sys.close(side);
            try makeLog(side, "s.log");
            c.buf[0] = 'a' + c.rand.uintLessThan(u8, 26);
            sys.close(try makeDir(fd, &c.buf));
            return &c.buf;
        }
    };

    test "the rotate walks cross a deep tree under a tight descriptor limit, opening each directory a bounded number of times" {
        const gpa = std.testing.allocator;
        const seed = walkSeed(gpa);
        std.debug.print("\ndeep walk seed: {d} (override with EB_KEEP_LOGS_WALK_SEED)\n", .{seed});
        var prng = std.Random.DefaultPrng.init(seed);
        const base = try testDir(gpa, "deep");
        defer gpa.free(base);
        defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        const root = try fsx.openDir(fsx.cwd, base, false);
        defer sys.close(root);
        var comb: Comb = .{ .rand = prng.random() };
        const bottom = try makeChain(gpa, root, deep_levels, &comb);
        defer gpa.free(bottom);

        const files = deep_levels + 1;
        const dirs = 2 * deep_levels + 1;
        const child = try Child.start(.openat, 32, Rotate{ .root = root, .want = files });
        var opens: Count = .{};
        const raw = child.finish(&opens) orelse return error.TestUnexpectedResult;
        try std.testing.expect(linux.W.IFEXITED(raw));
        try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(raw));
        var pb: [sys.path_max]u8 = undefined;
        try std.testing.expect((try fsx.statAt(root, try joined(&pb, bottom, "x.log.gz"), false)).isReg());
        var level: usize = 0;
        var cut: usize = 0;
        while (level < deep_levels) : (level += 1) {
            const side = if (level == 0) "~side/s.log.gz" else try std.fmt.bufPrint(&pb, "{s}/~side/s.log.gz", .{bottom[0..cut]});
            try std.testing.expect((try fsx.statAt(root, side, false)).isReg());
            cut = if (level == 0) 1 else cut + 2;
        }
        // Every directory opened once, a directory the window left opened
        // once more, and each log opened and written once: well under four
        // opens a node. Opening each directory from the root instead costs
        // the sum of the depths, about one per node per level.
        if (opens.n > 4 * (dirs + files)) {
            std.debug.print("{d} opens for {d} directories and {d} logs\n", .{ opens.n, dirs, files });
            return error.TestUnexpectedResult;
        }
    }

    const turn_level: usize = 5;
    const moved_depth: usize = 40;

    /// Level `turn_level` of the chain holds three directories, and the walk
    /// enters them in the order that level lists them: the first carries the
    /// chain on, the second holds a log the walk must still reach when it
    /// climbs back, and the third is swapped for a link out of the run
    /// during the walk. Every other level holds the chain's next directory.
    const Fork = struct {
        listed: [3][1]u8 = undefined,

        fn make(f: *Fork, fd: fsx.fd_t, i: usize) ![]const u8 {
            if (i != turn_level) {
                sys.close(try makeDir(fd, "c"));
                return "c";
            }
            for ("pqr") |ch| sys.close(try makeDir(fd, &.{ch}));
            var it = try fsx.DirIter.init(std.testing.allocator, fd);
            defer it.deinit(std.testing.allocator);
            var k: usize = 0;
            while (try it.next()) |e| : (k += 1) f.listed[k] = .{e.name[0]};
            const second = try fsx.openDir(fd, &f.listed[1], false);
            defer sys.close(second);
            try makeLog(second, "q.log");
            return &f.listed[0];
        }
    };

    /// When the walk opens the bottom log, moves the first directory of
    /// level `turn_level` out of the run into `moved`, and swaps the third
    /// for a link to `elsewhere`.
    const Tamper = struct {
        turn: fsx.fd_t,
        moved: fsx.fd_t,
        fork: *const Fork,
        elsewhere: [:0]const u8,
        done: bool = false,

        fn call(t: *Tamper, pid: linux.pid_t, d: *const linux.SECCOMP.data) linux.E {
            if (t.done) return .SUCCESS;
            var buf: [8]u8 = undefined;
            const local = [_]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
            const remote = [_]std.posix.iovec_const{.{ .base = @ptrFromInt(d.arg1), .len = buf.len }};
            const n = linux.process_vm_readv(pid, &local, &remote, 0);
            if (linux.errno(n) != .SUCCESS) return .SUCCESS;
            if (!std.mem.eql(u8, std.mem.sliceTo(buf[0..n], 0), "x.log")) return .SUCCESS;
            t.done = true;
            const first = &t.fork.listed[0];
            const third = &t.fork.listed[2];
            sys.renameat(t.turn, first, t.moved, first) catch return .SUCCESS;
            sys.renameat(t.turn, third, t.turn, "held") catch return .SUCCESS;
            var zb: [2:0]u8 = .{ third[0], 0 };
            _ = linux.symlinkat(t.elsewhere.ptr, t.turn, &zb);
            return .SUCCESS;
        }
    };

    test "a directory moved out of the run or swapped for a link during a deep walk is not followed" {
        const gpa = std.testing.allocator;
        const base = try testDir(gpa, "moved");
        defer gpa.free(base);
        defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        const top = try fsx.openDir(fsx.cwd, base, false);
        defer sys.close(top);
        const run = try makeDir(top, "run");
        defer sys.close(run);
        const moved = try makeDir(top, "moved");
        defer sys.close(moved);
        const elsewhere = try makeDir(top, "elsewhere");
        defer sys.close(elsewhere);
        try makeLog(elsewhere, "e.log");
        var fork: Fork = .{};
        const bottom = try makeChain(gpa, run, moved_depth, &fork);
        defer gpa.free(bottom);
        const turn_rel = bottom[0 .. 2 * turn_level - 1];
        const turn = try fsx.openDir(run, turn_rel, false);
        defer sys.close(turn);
        // What a walk that climbed out through the moved directory's new
        // parent would reach under the names it still had to enter.
        for (fork.listed[1..]) |*n| {
            const decoy = try makeDir(moved, n);
            defer sys.close(decoy);
            try makeLog(decoy, "q.log");
        }
        var eb: [sys.path_max]u8 = undefined;
        const elsewhere_path = try std.fmt.bufPrintSentinel(&eb, "{s}/elsewhere", .{base}, 0);
        const warnings = try sys.openat(top, "warnings", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
        defer sys.close(warnings);

        const child = try Child.start(.openat, 32, Rotate{ .root = run, .want = 2, .warnings = warnings });
        var tamper: Tamper = .{ .turn = turn, .moved = moved, .fork = &fork, .elsewhere = elsewhere_path };
        const raw = child.finish(&tamper) orelse return error.TestUnexpectedResult;
        _ = linux.lseek(warnings, 0, linux.SEEK.SET);
        const said = try fsx.readAll(gpa, warnings, 1 << 16);
        defer gpa.free(said);
        try std.testing.expect(tamper.done);
        try std.testing.expect(linux.W.IFEXITED(raw));
        try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(raw));
        var pb: [sys.path_max]u8 = undefined;
        try std.testing.expect((try fsx.statAt(turn, try joined(&pb, &fork.listed[1], "q.log.gz"), false)).isReg());
        try std.testing.expect((try fsx.statAt(turn, &fork.listed[2], false)).isLink());
        for (fork.listed[1..]) |*n| {
            try std.testing.expect((try fsx.statAt(moved, try joined(&pb, n, "q.log"), false)).isReg());
            try std.testing.expectError(error.NotFound, fsx.statAt(moved, try joined(&pb, n, "q.log.gz"), false));
        }
        try std.testing.expect((try fsx.statAt(elsewhere, "e.log", false)).isReg());
        try std.testing.expectError(error.NotFound, fsx.statAt(elsewhere, "e.log.gz", false));
        try std.testing.expect(std.mem.indexOf(u8, said, "cannot open") != null);
    }

    /// Fails the second read of a directory whose path ends in `/sealed`
    /// with EACCES, and counts the reads of it.
    const Seal = struct {
        seen: usize = 0,

        fn call(s: *Seal, pid: linux.pid_t, d: *const linux.SECCOMP.data) linux.E {
            var link_buf: [64]u8 = undefined;
            const link = std.fmt.bufPrintSentinel(&link_buf, "/proc/{d}/fd/{d}", .{ pid, d.arg0 }, 0) catch return .SUCCESS;
            var path_buf: [sys.path_max]u8 = undefined;
            const n = linux.readlink(link.ptr, &path_buf, path_buf.len);
            if (linux.errno(n) != .SUCCESS or !std.mem.endsWith(u8, path_buf[0..n], "/sealed")) return .SUCCESS;
            s.seen += 1;
            return if (s.seen % 2 == 0) .ACCES else .SUCCESS;
        }
    };

    test "a directory that cannot be read does not stop the rest of the walk" {
        const gpa = std.testing.allocator;
        const base = try testDir(gpa, "unread");
        defer gpa.free(base);
        defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        const root = try fsx.openDir(fsx.cwd, base, false);
        defer sys.close(root);
        const sealed = try makeDir(root, "sealed");
        defer sys.close(sealed);
        const good = try makeDir(sealed, "good");
        defer sys.close(good);
        try makeLog(good, "a.log");
        const also = try makeDir(root, "also");
        defer sys.close(also);
        try makeLog(also, "b.log");

        const child = try Child.start(.getdents64, null, Rotate{ .root = root, .want = 2 });
        var seal: Seal = .{};
        const raw = child.finish(&seal) orelse return error.TestUnexpectedResult;
        try std.testing.expect(linux.W.IFEXITED(raw));
        try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(raw));
        try std.testing.expectEqual(@as(usize, 4), seal.seen);
        try std.testing.expect((try fsx.statAt(root, "sealed/good/a.log.gz", false)).isReg());
        try std.testing.expectError(error.NotFound, fsx.statAt(root, "sealed/good/a.log", false));
        try std.testing.expect((try fsx.statAt(root, "also/b.log.gz", false)).isReg());
        try std.testing.expectError(error.NotFound, fsx.statAt(root, "also/b.log", false));
    }

    /// Runs only the compress walk over `root` and exits with its count,
    /// its warnings going to `warnings`.
    const CompressOnly = struct {
        root: fsx.fd_t,
        warnings: fsx.fd_t,

        fn run(r: CompressOnly) u8 {
            _ = linux.dup3(r.warnings, 2, 0);
            const page = std.heap.page_allocator;
            var arena_state = std.heap.ArenaAllocator.init(page);
            var env_map = std.process.Environ.Map.init(page);
            var threaded = std.Io.Threaded.init(page, .{});
            const ctx: Ctx = .{ .gpa = page, .io = threaded.io(), .env = &env_map, .envp = undefined };
            var count: usize = 0;
            compressTree(ctx, arena_state.allocator(), r.root, &count);
            return @intCast(count);
        }
    };

    /// At the child's first fsync, its archive's own, compresses `a.log`
    /// in the test's own process, as another rotate would, and then fails
    /// the child's fsync with EIO.
    const StealThenFail = struct {
        dir: fsx.fd_t,
        done: bool = false,

        fn call(t: *StealThenFail, _: linux.pid_t, _: *const linux.SECCOMP.data) linux.E {
            if (t.done) return .SUCCESS;
            t.done = true;
            var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            logs.gzipInPlace(std.heap.page_allocator, threaded.io(), t.dir, "a.log") catch return .SUCCESS;
            return .IO;
        }
    };

    test "a compress that fails before its directory sync is not counted, whatever another rotate left" {
        const gpa = std.testing.allocator;
        const base = try testDir(gpa, "steal");
        defer gpa.free(base);
        defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
        const dir = try fsx.openDir(fsx.cwd, base, false);
        defer sys.close(dir);
        try makeLog(dir, "a.log");
        const warnings = try sys.openat(dir, "warnings", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
        defer sys.close(warnings);

        const child = try Child.start(.fsync, null, CompressOnly{ .root = dir, .warnings = warnings });
        var answer: StealThenFail = .{ .dir = dir };
        const raw = child.finish(&answer) orelse return error.TestUnexpectedResult;
        _ = linux.lseek(warnings, 0, linux.SEEK.SET);
        const said = try fsx.readAll(gpa, warnings, 1 << 16);
        defer gpa.free(said);
        try std.testing.expect(answer.done);
        // What the child's failed compress finds is the original gone and
        // a regular archive at its name, which is what a failed directory
        // sync leaves too.
        try std.testing.expectError(error.NotFound, fsx.statAt(dir, "a.log", false));
        try std.testing.expect((try fsx.statAt(dir, "a.log.gz", false)).isReg());
        try std.testing.expect(linux.W.IFEXITED(raw));
        try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(raw));
        try std.testing.expect(std.mem.indexOf(u8, said, "cannot compress") != null);
        try std.testing.expect(std.mem.indexOf(u8, said, "cannot sync") == null);
    }
};

test "a failed copy does not replace a log already kept" {
    const gpa = std.testing.allocator;
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/eb-keep-logs-copy-{d}", .{ here, linux.getpid() });
    defer gpa.free(base);
    // The test runs where `zig build` was started, which has no .zig-cache
    // when the cache is elsewhere, as with ZIG_LOCAL_CACHE_DIR.
    try common.atomic.makedirs(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);
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

/// A directory of the test's own under the .zig-cache where `zig build` was
/// started, made when missing; the caller removes it and frees the path.
fn testDir(gpa: Allocator, name: []const u8) ![]u8 {
    var cwd_buf: [sys.path_max]u8 = undefined;
    const here = try fsx.realpath(fsx.cwd, ".", &cwd_buf);
    const base = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/eb-keep-logs-{s}-{d}", .{ here, name, linux.getpid() });
    errdefer gpa.free(base);
    try common.atomic.makedirs(base);
    return base;
}

test "the rotate lock: one holder at a time" {
    const gpa = std.testing.allocator;
    const base = try testDir(gpa, "lock");
    defer gpa.free(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const dir = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(dir);

    const held = try openLock(dir);
    try waitLock(held, 0);
    const other = try openLock(dir);
    defer sys.close(other);
    try std.testing.expectError(error.TimedOut, waitLock(other, 0));
    sys.close(held);
    try waitLock(other, 0);
    try std.testing.expect((try fsx.statAt(dir, rotate_lock, false)).isReg());

    try sys.unlinkat(dir, rotate_lock, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("elsewhere", dir, rotate_lock)));
    try std.testing.expectError(error.SymLink, openLock(dir));
    try sys.unlinkat(dir, rotate_lock, 0);
    _ = try sys.call(linux.mkdirat, .{ dir, rotate_lock, 0o755 });
    try std.testing.expectError(error.IsDir, openLock(dir));
}

test "writtenRuns: the runs a process has a file in open for writing" {
    const gpa = std.testing.allocator;
    const base = try testDir(gpa, "written");
    defer gpa.free(base);
    defer fsx.deleteTree(gpa, fsx.cwd, base) catch {};
    const root = try fsx.openDir(fsx.cwd, base, false);
    defer sys.close(root);
    for ([_][:0]const u8{ "20261113_235000", "20261001_120000", "20261002_120000" }) |run|
        _ = try sys.call(linux.mkdirat, .{ root, run.ptr, 0o755 });

    const writing = try sys.openat(root, "20261113_235000/build.log", .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, 0o644);
    defer sys.close(writing);
    const reading = try sys.openat(root, "20261001_120000/old.log", .{ .CREAT = true }, 0o644);
    defer sys.close(reading);
    const removed = try sys.openat(root, "20261002_120000/gone.log", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);
    defer sys.close(removed);
    try sys.unlinkat(root, "20261002_120000/gone.log", 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = writtenRuns(gpa, arena, "/proc", root);
    try std.testing.expect(contains(names, "20261113_235000"));
    try std.testing.expect(!contains(names, "20261001_120000"));
    try std.testing.expect(contains(names, "20261002_120000"));
    try std.testing.expectEqual(@as(usize, 0), writtenRuns(gpa, arena, "/nonexistent", root).len);
}

test "parseSeconds" {
    try std.testing.expectEqual(@as(u64, 0), parseSeconds("0"));
    try std.testing.expectEqual(@as(u64, 7), parseSeconds("007"));
    try std.testing.expectEqual(max_lock_timeout, parseSeconds("999999999"));
    try std.testing.expectEqual(max_lock_timeout, parseSeconds("1000000000"));
    try std.testing.expectEqual(max_lock_timeout, parseSeconds("123456789012345678901234567890"));
}

test "usage_text gives the lock timeout's default and the exit statuses" {
    const fmt = std.fmt.comptimePrint;
    try std.testing.expect(std.mem.indexOf(u8, usage_text, fmt("Default: {d};", .{default_lock_timeout})) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, fmt("give up and exit {d}.", .{lock_busy_exit})) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, fmt("\n  {d}   The invocation was refused", .{cli.usage_exit})) != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, fmt("\n  {d}  rotate waited --lock-timeout", .{lock_busy_exit})) != null);
}

test "listed" {
    try std.testing.expect(listed("/l/a.log\n/l/b.log\n", "/l/b.log"));
    try std.testing.expect(listed("/l/a.log", "/l/a.log"));
    try std.testing.expect(!listed("/l/a.log.gz\n", "/l/a.log"));
    try std.testing.expect(!listed("/l/a\n", "/l/a.log"));
    try std.testing.expect(!listed("", "/l/a.log"));
}

test "joinable and plural" {
    try std.testing.expectEqualStrings("logs", joinable("logs//"));
    try std.testing.expectEqualStrings("/srv/logs", joinable("/srv/logs"));
    try std.testing.expectEqualStrings("", joinable("/"));
    try std.testing.expectEqualStrings("", plural(1));
    try std.testing.expectEqualStrings("s", plural(0));
    try std.testing.expectEqualStrings("s", plural(2));
}

test "below" {
    try std.testing.expect(below("/srv/logs/run/easybuild-logs/Foo", "/srv/logs/run"));
    try std.testing.expect(!below("/srv/logs/run", "/srv/logs/run"));
    try std.testing.expect(!below("/srv/logs/run2/x", "/srv/logs/run"));
    try std.testing.expect(!below("/srv/logs", "/srv/logs/run"));
    try std.testing.expect(below("/x", "/"));
    try std.testing.expect(!below("/", "/"));
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

test "runAgeDays saturates rather than panics when EB_KEEP_LOGS_NOW is far enough from a run's local midnight to overflow i64" {
    const z: localtime.Zone = .{};
    // A now of i64's minimum is always below a run's local midnight (year
    // 0001 at the earliest), so the difference saturates at i64's minimum,
    // dividing down into a hugely negative, never old enough age.
    try std.testing.expectEqual(
        @as(?i64, @divTrunc(std.math.minInt(i64), 86400)),
        runAgeDays(&z, "20200101_000000", std.math.minInt(i64)),
    );
    // A now of i64's maximum is always above a run's local midnight, so the
    // difference saturates at i64's maximum, dividing down into a hugely
    // positive, long since old enough age.
    try std.testing.expectEqual(
        @as(?i64, @divTrunc(std.math.maxInt(i64), 86400)),
        runAgeDays(&z, "00010101_000000", std.math.maxInt(i64)),
    );
}

test "addRunOf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    addRunOf(arena, &names, "/logs", "/logs/20261113_235000/site-zen4/rotate.log");
    addRunOf(arena, &names, "/logs", "/logs/20261110_120000");
    addRunOf(arena, &names, "/logs", "/logs");
    addRunOf(arena, &names, "/logs", "/logs/");
    addRunOf(arena, &names, "/logs", "/logs2/20261113_235000/rotate.log");
    addRunOf(arena, &names, "", "/20261101_120000/rotate.log");
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("20261113_235000", names.items[0]);
    try std.testing.expectEqualStrings("20261110_120000", names.items[1]);
    try std.testing.expectEqualStrings("20261101_120000", names.items[2]);
}

test "lastLine" {
    try std.testing.expectEqualStrings("/b.log", lastLine("note\n/b.log\n").?);
    try std.testing.expectEqualStrings("/b.log", lastLine("/b.log").?);
    try std.testing.expectEqual(@as(?[]const u8, null), lastLine(""));
    try std.testing.expectEqual(@as(?[]const u8, null), lastLine("\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), lastLine("/b.log\n\n"));
}
