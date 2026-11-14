//! Local time as the C library sees it, enough to turn a calendar date into
//! the epoch second of its local midnight, as `date -d YYYYMMDD +%s` does.
//!
//! The zone comes from TZ the way glibc reads it: unset means
//! /etc/localtime; empty means UTC; a leading ':' or any value naming a TZif
//! file under TZDIR (default /usr/share/zoneinfo) or an absolute path is
//! that file; anything else is a POSIX TZ rule string. A zone that cannot be
//! read or parsed is UTC. TZif files use their transitions, then the POSIX
//! rule in their footer for times after the last transition.
const std = @import("std");
const common = @import("zig_common");
const fsx = common.fsx;
const sys = common.sys;

const Allocator = std.mem.Allocator;

pub const Rule = union(enum) {
    /// Day of year 1..365, February 29 never counted.
    julian1: u16,
    /// Day of year 0..365, February 29 counted.
    julian0: u16,
    /// Month 1..12, week 1..5 (5 = last), weekday 0..6 (0 = Sunday).
    mwd: struct { m: u8, w: u8, d: u8 },
};

pub const Posix = struct {
    /// Seconds east of UTC.
    std_off: i32,
    dst: ?struct {
        off: i32,
        start: Rule,
        start_time: i32,
        end: Rule,
        end_time: i32,
    } = null,
};

pub const Zone = struct {
    transitions: []const i64 = &.{},
    offsets: []const i32 = &.{},
    /// Offset before the first transition.
    first_off: i32 = 0,
    footer: ?Posix = null,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(z: *Zone) void {
        if (z.arena) |*a| a.deinit();
    }

    /// Seconds east of UTC in force at UTC time `t`.
    pub fn offsetAt(z: *const Zone, t: i64) i32 {
        const n = z.transitions.len;
        if (n == 0 or t >= z.transitions[n - 1]) {
            if (z.footer) |p| return posixOffset(p, t);
            if (n == 0) return z.first_off;
        }
        if (t < z.transitions[0]) return z.first_off;
        var lo: usize = 0;
        var hi: usize = n;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (z.transitions[mid] <= t) lo = mid else hi = mid;
        }
        return z.offsets[lo];
    }

    /// The UTC second of local time `local` (seconds since the epoch as if
    /// the zone were UTC). Null when that local time does not exist (a gap
    /// at a DST change), as mktime-based tools refuse it.
    pub fn fromLocal(z: *const Zone, local: i64) ?i64 {
        var guess = local - z.offsetAt(local);
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const off = z.offsetAt(guess);
            const u = local - off;
            if (u + z.offsetAt(u) == local) return u;
            guess = u;
        }
        return null;
    }
};

// Calendar arithmetic (Howard Hinnant's days_from_civil).
pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

pub fn daysInMonth(y: i64, m: u8) u8 {
    const t = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m == 2 and isLeap(y)) 29 else t[m - 1];
}

fn yearOf(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    return yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
}

/// Day number (days since the epoch) on which `r` falls in year `y`.
fn ruleDay(r: Rule, y: i64) i64 {
    const jan1 = daysFromCivil(y, 1, 1);
    switch (r) {
        .julian1 => |n| {
            var d: i64 = n - 1;
            if (isLeap(y) and n >= 60) d += 1;
            return jan1 + d;
        },
        .julian0 => |n| return jan1 + n,
        .mwd => |x| {
            const first = daysFromCivil(y, x.m, 1);
            const wd_first = @mod(first + 4, 7); // 1970-01-01 was a Thursday
            var day = first + @mod(@as(i64, x.d) - wd_first, 7) + (@as(i64, x.w) - 1) * 7;
            const last = first + daysInMonth(y, x.m) - 1;
            while (day > last) day -= 7;
            return day;
        },
    }
}

pub fn posixOffset(p: Posix, t: i64) i32 {
    const dst = p.dst orelse return p.std_off;
    const y = yearOf(@divFloor(t + p.std_off, 86400));
    // Start is given in standard time, end in daylight time.
    const start = ruleDay(dst.start, y) * 86400 + dst.start_time - p.std_off;
    const end = ruleDay(dst.end, y) * 86400 + dst.end_time - dst.off;
    const in_dst = if (start < end) (t >= start and t < end) else !(t >= end and t < start);
    return if (in_dst) dst.off else p.std_off;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn name(p: *Parser) !void {
        if (p.peek() == '<') {
            const close = std.mem.findScalarPos(u8, p.s, p.i, '>') orelse return error.Bad;
            if (close - p.i - 1 < 3) return error.Bad;
            p.i = close + 1;
            return;
        }
        const start = p.i;
        while (p.peek()) |c| : (p.i += 1) if (!std.ascii.isAlphabetic(c)) break;
        if (p.i - start < 3) return error.Bad;
    }

    fn num(p: *Parser, max: i64) !i64 {
        const start = p.i;
        while (p.peek()) |c| : (p.i += 1) if (!std.ascii.isDigit(c)) break;
        if (p.i == start or p.i - start > 3) return error.Bad;
        const v = std.fmt.parseInt(i64, p.s[start..p.i], 10) catch return error.Bad;
        if (v > max) return error.Bad;
        return v;
    }

    /// [+-]hh[:mm[:ss]] in seconds.
    fn hms(p: *Parser, max_h: i64) !i64 {
        var sign: i64 = 1;
        if (p.peek() == '+') p.i += 1 else if (p.peek() == '-') {
            sign = -1;
            p.i += 1;
        }
        var v = (try p.num(max_h)) * 3600;
        if (p.peek() == ':') {
            p.i += 1;
            v += (try p.num(59)) * 60;
            if (p.peek() == ':') {
                p.i += 1;
                v += try p.num(59);
            }
        }
        return sign * v;
    }

    fn rule(p: *Parser) !Rule {
        if (p.peek() == 'J') {
            p.i += 1;
            const n = try p.num(365);
            if (n < 1) return error.Bad;
            return .{ .julian1 = @intCast(n) };
        }
        if (p.peek() == 'M') {
            p.i += 1;
            const m = try p.num(12);
            if (p.peek() != '.') return error.Bad;
            p.i += 1;
            const w = try p.num(5);
            if (p.peek() != '.') return error.Bad;
            p.i += 1;
            const d = try p.num(6);
            if (m < 1 or w < 1) return error.Bad;
            return .{ .mwd = .{ .m = @intCast(m), .w = @intCast(w), .d = @intCast(d) } };
        }
        return .{ .julian0 = @intCast(try p.num(365)) };
    }

    fn ruleTime(p: *Parser) !i32 {
        if (p.peek() != '/') return 2 * 3600;
        p.i += 1;
        return @intCast(try p.hms(167));
    }
};

pub fn parsePosix(s: []const u8) !Posix {
    var p: Parser = .{ .s = s };
    try p.name();
    const std_off: i32 = @intCast(-(try p.hms(24)));
    if (p.peek() == null) return .{ .std_off = std_off };
    try p.name();
    var dst_off = std_off + 3600;
    if (p.peek() != null and p.peek() != ',') dst_off = @intCast(-(try p.hms(24)));
    var start: Rule = .{ .mwd = .{ .m = 3, .w = 2, .d = 0 } };
    var end: Rule = .{ .mwd = .{ .m = 11, .w = 1, .d = 0 } };
    var start_time: i32 = 2 * 3600;
    var end_time: i32 = 2 * 3600;
    if (p.peek() == ',') {
        p.i += 1;
        start = try p.rule();
        start_time = try p.ruleTime();
        if (p.peek() != ',') return error.Bad;
        p.i += 1;
        end = try p.rule();
        end_time = try p.ruleTime();
    }
    if (p.peek() != null) return error.Bad;
    return .{ .std_off = std_off, .dst = .{ .off = dst_off, .start = start, .start_time = start_time, .end = end, .end_time = end_time } };
}

fn loadFile(gpa: Allocator, path: []const u8) !Zone {
    const f = try fsx.openRegular(fsx.cwd, path, true);
    defer sys.close(f.fd);
    const bytes = try fsx.readAll(gpa, f.fd, 1 << 20);
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var reader: std.Io.Reader = .fixed(bytes);
    var tz = try std.tz.Tz.parse(a, &reader);
    _ = &tz;
    const trans = try a.alloc(i64, tz.transitions.len);
    const offs = try a.alloc(i32, tz.transitions.len);
    for (tz.transitions, 0..) |t, i| {
        trans[i] = t.ts;
        offs[i] = t.timetype.offset;
    }
    var first_off: i32 = 0;
    if (tz.timetypes.len > 0) first_off = tz.timetypes[0].offset;
    var footer: ?Posix = null;
    if (tz.footer) |ft| footer = parsePosix(ft) catch null;
    return .{ .transitions = trans, .offsets = offs, .first_off = first_off, .footer = footer, .arena = arena };
}

/// The zone named by `tz` (the value of TZ, or null when unset).
pub fn load(gpa: Allocator, tz: ?[]const u8, tzdir: ?[]const u8) Zone {
    const value = tz orelse return loadFile(gpa, "/etc/localtime") catch .{};
    if (value.len == 0) return .{};
    const name = if (value[0] == ':') value[1..] else value;
    const dir = tzdir orelse "/usr/share/zoneinfo";
    if (name.len > 0) {
        const path = if (name[0] == '/') gpa.dupe(u8, name) catch return .{} else std.fs.path.join(gpa, &.{ dir, name }) catch return .{};
        defer gpa.free(path);
        if (loadFile(gpa, path)) |zone| return zone else |_| {}
    }
    if (value[0] == ':') return .{};
    const p = parsePosix(value) catch return .{};
    return .{ .footer = p };
}

test "posix rules" {
    const ams = try parsePosix("CET-1CEST,M3.5.0,M10.5.0/3");
    const z: Zone = .{ .footer = ams };
    // 2026-11-13 00:00 local is 2026-11-12 23:00 UTC.
    try std.testing.expectEqual(@as(?i64, daysFromCivil(2026, 11, 13) * 86400 - 3600), z.fromLocal(daysFromCivil(2026, 11, 13) * 86400));
    // 2026-07-01 00:00 local is CEST.
    try std.testing.expectEqual(@as(?i64, daysFromCivil(2026, 7, 1) * 86400 - 7200), z.fromLocal(daysFromCivil(2026, 7, 1) * 86400));
    const chi: Zone = .{ .footer = try parsePosix("CST6CDT,M3.2.0,M11.1.0") };
    try std.testing.expectEqual(@as(?i64, daysFromCivil(2026, 11, 13) * 86400 + 6 * 3600), chi.fromLocal(daysFromCivil(2026, 11, 13) * 86400));
    const utc: Zone = .{};
    try std.testing.expectEqual(@as(?i64, 0), utc.fromLocal(0));
    try std.testing.expectError(error.Bad, parsePosix("X1"));
}

test "a local midnight inside a DST gap does not exist" {
    // America/Santiago moves 00:00 to 01:00 on the first Sunday of September.
    const z: Zone = .{ .footer = try parsePosix("<-04>4<-03>,M9.1.6/24,M4.1.6/24") };
    try std.testing.expectEqual(@as(?i64, null), z.fromLocal(daysFromCivil(2026, 9, 6) * 86400));
}
