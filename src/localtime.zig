//! Local time as the C library sees it, enough to turn a calendar date into
//! the epoch second of its local midnight, as `date -d YYYYMMDD +%s` does.
//!
//! The zone comes from TZ much as glibc reads it: unset means
//! /etc/localtime; empty means UTC; otherwise the value, without a leading
//! ':', names a TZif file, under TZDIR (/usr/share/zoneinfo when TZDIR is
//! unset or empty) unless it is an absolute path, or, when it names no
//! file, is a POSIX TZ rule string, read and applied as glibc's tzset.c
//! reads and applies it where TZDIR has no posixrules file, a malformed one
//! included. A zone that cannot be read is UTC. TZif files use their
//! transitions, then the POSIX rule in their footer for times after the
//! last transition.
const std = @import("std");
const common = @import("zig_common");
const fsx = common.fsx;
const sys = common.sys;

const Allocator = std.mem.Allocator;

/// The day of the year on which a POSIX TZ rule starts or ends daylight
/// saving time: `Jn`, `n` or `Mm.w.d`. It holds what glibc holds, so a rule
/// glibc stopped reading keeps what was read of it, a number not read being
/// 0, and a rule not read at all is `julian0` 0.
pub const Rule = union(enum) {
    /// Day of year 1..365, February 29 never counted.
    julian1: u16,
    /// Day of year 0..365, February 29 counted.
    julian0: u16,
    /// Weekday `d` (0 = Sunday) of week `w` (5 = the last) of month `m`.
    mwd: struct { m: u16, w: u16, d: u16 },
};

/// A POSIX TZ rule string, such as `CET-1CEST,M3.5.0,M10.5.0/3`, as
/// `parsePosix` reads it.
pub const Posix = struct {
    /// Seconds east of UTC.
    std_off: i32,
    /// Daylight saving time, null when nothing follows standard time: `off`
    /// in seconds east of UTC, and the days it starts and ends with their
    /// times in seconds from that day's local midnight, `start_time` in
    /// standard time and `end_time` in daylight time.
    dst: ?struct {
        off: i32,
        start: Rule,
        start_time: i32,
        end: Rule,
        end_time: i32,
    } = null,
};

/// A time zone: the transitions of a TZif file and the POSIX rule after
/// them, or a POSIX rule alone. The default value is UTC.
pub const Zone = struct {
    /// UTC seconds at which the offset changes, in ascending order.
    transitions: []const i64 = &.{},
    /// Seconds east of UTC from the transition at the same index on.
    offsets: []const i32 = &.{},
    /// Offset before the first transition.
    first_off: i32 = 0,
    /// The rule from the last transition on, or for all times when there
    /// are none; without it the last transition's offset stays in force.
    footer: ?Posix = null,
    /// Holds what was read from a TZif file; `deinit` frees it.
    arena: ?std.heap.ArenaAllocator = null,

    /// Free what was read from a TZif file; a zone without one holds
    /// nothing to free.
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

/// A calendar date in the proleptic Gregorian calendar.
pub const CivilDate = struct {
    year: i64,
    month: u8,
    day: u8,
};

/// Calendar date `days` days after 1970-01-01 in the proleptic Gregorian
/// calendar (Howard Hinnant's civil_from_days).
pub fn civilFromDays(days: i64) CivilDate {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i64 = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = y, .month = m, .day = d };
}

/// Days from 1970-01-01 to `y_in`-`m`-`d` in the proleptic Gregorian
/// calendar, negative before it (Howard Hinnant's days_from_civil). `m` is
/// 1..12; neither it nor `d` is checked.
pub fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Whether `y` is a leap year in the proleptic Gregorian calendar.
pub fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// Days in month `m` of year `y`; `m` must be 1..12.
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

/// Days before each month and in the year, in a common and a leap year.
const mon_yday = [2][13]u16{
    .{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
    .{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
};

/// The UTC second at which rule `r`, `secs` after local midnight in a zone
/// `off` seconds east of UTC, falls in year `y`, worked out as glibc's
/// compute_change does: counted from 1970-01-01 in every year up to 1970,
/// with the weekday of a month's first day from Zeller's congruence in C's
/// truncating division.
fn change(r: Rule, secs: i32, off: i32, y: i64) i64 {
    var t: i64 = if (y > 1970) daysFromCivil(y, 1, 1) * 86400 else 0;
    switch (r) {
        .julian1 => |d| {
            t += (@as(i64, d) - 1) * 86400;
            if (d >= 60 and isLeap(y)) t += 86400;
        },
        .julian0 => |d| t += @as(i64, d) * 86400,
        // For a month outside 1..12 glibc reads past its month table, which
        // C leaves undefined; here the rule falls on 1 January.
        .mwd => |x| if (x.m >= 1 and x.m <= 12) {
            const days = mon_yday[@intFromBool(isLeap(y))];
            const len: i64 = days[x.m] - days[x.m - 1];
            t += @as(i64, days[x.m - 1]) * 86400;
            const m1: i64 = @rem(@as(i64, x.m) + 9, 12) + 1;
            const yy0 = if (x.m <= 2) y - 1 else y;
            const yy1 = @divTrunc(yy0, 100);
            const yy2 = @rem(yy0, 100);
            var dow = @rem(@divTrunc(26 * m1 - 2, 10) + 1 + yy2 + @divTrunc(yy2, 4) + @divTrunc(yy1, 4) - 2 * yy1, 7);
            if (dow < 0) dow += 7;
            var d = @as(i64, x.d) - dow;
            if (d < 0) d += 7;
            var i: u16 = 1;
            while (i < x.w and d + 7 < len) : (i += 1) d += 7;
            t += d * 86400;
        },
    }
    return t - off + secs;
}

/// Seconds east of UTC that rule `p` puts in force at UTC time `t`, as
/// glibc's __tz_compute works it out from the changes in `t`'s year in UTC:
/// the daylight offset from the start of daylight saving time to its end,
/// or, when the end comes first, as in the southern hemisphere, until the
/// end and from the start; the standard offset otherwise, and always when
/// the two fall on the same second.
pub fn posixOffset(p: Posix, t: i64) i32 {
    const dst = p.dst orelse return p.std_off;
    const y = yearOf(@divFloor(t, 86400));
    const start = change(dst.start, dst.start_time, p.std_off, y);
    const end = change(dst.end, dst.end_time, dst.off, y);
    const in_dst = if (start > end) t < end or t >= start else t >= start and t < end;
    return if (in_dst) dst.off else p.std_off;
}

/// What C's `sscanf` stores for one `%hu` at `s[i.*..]`: white space, an
/// optional sign and decimal digits, the number read as `strtoul` reads it
/// and cut to 16 bits. Null, with `i` unmoved, when no digit follows.
fn scanHu(s: []const u8, i: *usize) ?u16 {
    var j = i.*;
    while (j < s.len and std.ascii.isWhitespace(s[j])) j += 1;
    const neg = j < s.len and s[j] == '-';
    if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
    const start = j;
    var v: u64 = 0;
    var over = false;
    while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {
        const m = @mulWithOverflow(v, 10);
        const a = @addWithOverflow(m[0], s[j] - '0');
        over = over or m[1] != 0 or a[1] != 0;
        v = a[0];
    }
    if (j == start) return null;
    i.* = j;
    // strtoul gives ULONG_MAX for a number out of range, and negates the rest.
    return if (over) std.math.maxInt(u16) else @truncate(if (neg) 0 -% v else v);
}

/// What C's `sscanf(s, "%hu%n:%hu%n:%hu%n", ...)` reads from `s[i..]`: the
/// `n` numbers, up to three apart by `:`, it read with `scanHu`, and where
/// it stopped after the last of them.
const Hms = struct {
    v: [3]u16 = .{ 0, 0, 0 },
    n: u2 = 0,
    end: usize,

    fn scan(s: []const u8, i: usize) Hms {
        var h: Hms = .{ .end = i };
        var j = i;
        while (h.n < 3) : (h.n += 1) {
            if (h.n > 0) {
                if (j >= s.len or s[j] != ':') break;
                j += 1;
            }
            h.v[h.n] = scanHu(s, &j) orelse break;
            h.end = j;
        }
        return h;
    }
};

/// glibc 2.39's TZ parser, one method per function of its tzset.c.
const Parser = struct {
    s: []const u8,
    i: usize = 0,

    /// The byte at `k`, 0 past the end, where a C string has its NUL.
    fn at(p: *const Parser, k: usize) u8 {
        return if (k < p.s.len) p.s[k] else 0;
    }

    /// parse_tzname: three or more letters, or three or more letters,
    /// digits, `+` and `-` in `<>`.
    fn name(p: *Parser) bool {
        var j = p.i;
        while (std.ascii.isAlphabetic(p.at(j))) j += 1;
        if (j - p.i < 3) {
            if (p.at(p.i) != '<') return false;
            j = p.i + 1;
            while (std.ascii.isAlphanumeric(p.at(j)) or p.at(j) == '+' or p.at(j) == '-') j += 1;
            if (p.at(j) != '>' or j - p.i - 1 < 3) return false;
            j += 1;
        }
        p.i = j;
        return true;
    }

    /// parse_offset: `[+-]` and `Hms.scan`, in seconds west of UTC with the
    /// hours capped at 24 and the minutes and seconds at 59. Null when no
    /// number follows the sign, which is still taken.
    fn offset(p: *Parser) ?i32 {
        var sign: i32 = -1;
        if (p.at(p.i) == '-' or p.at(p.i) == '+') {
            if (p.at(p.i) == '-') sign = 1;
            p.i += 1;
        }
        const h = Hms.scan(p.s, p.i);
        p.i = h.end;
        if (h.n == 0) return null;
        return sign * (@as(i32, @min(h.v[0], 24)) * 3600 + @as(i32, @min(h.v[1], 59)) * 60 + @min(h.v[2], 59));
    }

    /// parse_rule: `[,]date[/time]` into `r` and `secs`. The date is `Jn`,
    /// `n`, `Mm.w.d`, or `default` at the end of the string; the time is
    /// `[-]` and `Hms.scan`, with 2 for hours not read and no caps, 02:00
    /// without `/`. False, `i` unmoved, when the date cannot be read, when
    /// anything but `/`, `,` or the end follows it, or the end follows `/`;
    /// `r` and `secs` keep what was read.
    fn rule(p: *Parser, r: *Rule, secs: *i32, default: Rule) bool {
        var j = p.i;
        if (p.at(j) == ',') j += 1;
        const c = p.at(j);
        if (c == 'J' or std.ascii.isDigit(c)) {
            r.* = if (c == 'J') .{ .julian1 = 0 } else .{ .julian0 = 0 };
            if (c == 'J') {
                j += 1;
                if (!std.ascii.isDigit(p.at(j))) return false;
            }
            const start = j;
            while (std.ascii.isDigit(p.at(j))) j += 1;
            const d = std.fmt.parseInt(u16, p.s[start..j], 10) catch return false;
            if (d > 365 or (c == 'J' and d == 0)) return false;
            r.* = if (c == 'J') .{ .julian1 = d } else .{ .julian0 = d };
        } else if (c == 'M') {
            var v: [3]u16 = .{ 0, 0, 0 };
            var n: usize = 0;
            j += 1;
            while (n < 3) : (n += 1) {
                if (n > 0) {
                    if (p.at(j) != '.') break;
                    j += 1;
                }
                v[n] = scanHu(p.s, &j) orelse break;
            }
            r.* = .{ .mwd = .{ .m = v[0], .w = v[1], .d = v[2] } };
            if (n < 3 or v[0] < 1 or v[0] > 12 or v[1] < 1 or v[1] > 5 or v[2] > 6) return false;
        } else if (c == 0) {
            r.* = default;
        } else return false;
        switch (p.at(j)) {
            0, ',' => secs.* = 2 * 3600,
            '/' => {
                j += 1;
                if (p.at(j) == 0) return false;
                const neg = p.at(j) == '-';
                if (neg) j += 1;
                const h = Hms.scan(p.s, j);
                j = h.end;
                const v = @as(i32, if (h.n > 0) h.v[0] else 2) * 3600 + @as(i32, h.v[1]) * 60 + h.v[2];
                secs.* = if (neg) -v else v;
            },
            else => return false,
        }
        p.i = j;
        return true;
    }
};

/// Parse a POSIX TZ rule string, `std offset[dst[offset][,start[/time],end[/time]]]`,
/// as glibc 2.39 reads it: as far as it can, keeping what it read and
/// ignoring the rest. A name is three or more letters, or three or more
/// letters, digits, `+` and `-` in `<>`; an offset is `[+-]hh[:mm[:ss]]`
/// west of UTC, read as C's `%hu` reads numbers, with hours capped at 24
/// and minutes and seconds at 59. Without its offset, daylight time is one
/// hour ahead of standard time; text after standard time that is not a
/// name gives daylight time an offset of 0 and is read for rules. Without
/// rules daylight time runs from the second Sunday in March to the first
/// Sunday in November, as in glibc where TZDIR has no posixrules file, and
/// a rule without a time changes at 02:00. A rule that cannot be read keeps
/// what was read of it, and after such a start rule the end rule is not
/// read. `error.Bad` when standard time cannot be read, which glibc takes as
/// UTC.
pub fn parsePosix(s: []const u8) !Posix {
    var p: Parser = .{ .s = s };
    if (!p.name()) return error.Bad;
    if (p.at(p.i) != '+' and p.at(p.i) != '-' and !std.ascii.isDigit(p.at(p.i))) return error.Bad;
    const std_off = p.offset() orelse return error.Bad;
    if (p.at(p.i) == 0) return .{ .std_off = std_off };
    var dst_off: i32 = 0;
    if (p.name()) dst_off = p.offset() orelse std_off + 3600;
    var start: Rule = .{ .julian0 = 0 };
    var start_time: i32 = 0;
    var end: Rule = .{ .julian0 = 0 };
    var end_time: i32 = 0;
    if (p.rule(&start, &start_time, .{ .mwd = .{ .m = 3, .w = 2, .d = 0 } }))
        _ = p.rule(&end, &end_time, .{ .mwd = .{ .m = 11, .w = 1, .d = 0 } });
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

/// The zone named by `tz` (the value of TZ, or null when unset), with zone
/// files under `tzdir` (the value of TZDIR; /usr/share/zoneinfo when null
/// or empty).
pub fn load(gpa: Allocator, tz: ?[]const u8, tzdir: ?[]const u8) Zone {
    const value = tz orelse return loadFile(gpa, "/etc/localtime") catch .{};
    const name = if (value.len > 0 and value[0] == ':') value[1..] else value;
    if (name.len == 0) return .{};
    const tzdir_s = tzdir orelse "";
    const dir = if (tzdir_s.len > 0) tzdir_s else "/usr/share/zoneinfo";
    const path = if (name[0] == '/') gpa.dupe(u8, name) catch return .{} else std.fs.path.join(gpa, &.{ dir, name }) catch return .{};
    defer gpa.free(path);
    if (loadFile(gpa, path)) |zone| return zone else |_| {}
    const p = parsePosix(name) catch return .{};
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

test "a rule string is read and applied as glibc reads and applies it" {
    const gpa = std.testing.allocator;
    // TZ, a date, and what `TZ=... date -d DATE +%s` prints with glibc 2.39,
    // null where it refuses the date.
    const rows = [_]struct { tz: []const u8, y: i64, m: u8, d: u8, want: ?i64 }{
        // Text after the rules is not read.
        .{ .tz = "CET-1CEST,M3.5.0,M10.5.0/3x", .y = 2026, .m = 11, .d = 1, .want = 1793487600 },
        // Without an end rule, daylight time ends on the first Sunday in
        // November at 02:00.
        .{ .tz = "CET-1CEST,M3.5.0", .y = 2026, .m = 11, .d = 1, .want = 1793484000 },
        // A rule cut short after its date keeps the date, at 00:00.
        .{ .tz = "CET-1CEST,M3.5.0,M10.5.0x", .y = 2026, .m = 10, .d = 25, .want = 1792882800 },
        // A time that is no number is 02:00, and the end rule cannot start
        // at the x: it stays 1 January at 00:00, and daylight time lasts to
        // the year's end.
        .{ .tz = "CET-1CEST,M3.5.0/x,M10.5.0/3", .y = 2026, .m = 11, .d = 1, .want = 1793484000 },
        // Without a daylight name, daylight time is UTC.
        .{ .tz = "CET-1,M3.5.0,M10.5.0/3", .y = 2026, .m = 7, .d = 1, .want = 1782864000 },
        .{ .tz = "CET-1,M3.5.0,M10.5.0/3", .y = 2026, .m = 11, .d = 1, .want = 1793487600 },
        // With no rules read either, daylight time runs from 1 January at
        // 00:00 standard time to the year's end, skipping that midnight.
        .{ .tz = "EST5x", .y = 2026, .m = 7, .d = 1, .want = 1782864000 },
        .{ .tz = "EST5x", .y = 2026, .m = 1, .d = 1, .want = null },
        // Hours are capped at 24, after white space and a sign as %hu takes
        // them, -1 being 65535.
        .{ .tz = "CET-25", .y = 2026, .m = 7, .d = 1, .want = 1782777600 },
        .{ .tz = "CET- 1", .y = 2026, .m = 7, .d = 1, .want = 1782860400 },
        .{ .tz = "CET+-1", .y = 2026, .m = 7, .d = 1, .want = 1782950400 },
        // A space is not part of a name in <>, so the zone is UTC.
        .{ .tz = "<A B>-1", .y = 2026, .m = 7, .d = 1, .want = 1782864000 },
        // J0 is no day: reading stops there, and the changes fall before
        // the year starts.
        .{ .tz = "CET-1CEST,J0,J300", .y = 2026, .m = 7, .d = 1, .want = 1782860400 },
        // Up to 1970 the changes fall in 1970: no daylight time in 1960, or
        // all of it where daylight time spans the new year.
        .{ .tz = "CET-1CEST,M3.5.0,M10.5.0/3", .y = 1960, .m = 7, .d = 1, .want = -299898000 },
        .{ .tz = "AEST-10AEDT,M10.1.0,M4.1.0/3", .y = 1960, .m = 7, .d = 1, .want = -299934000 },
        // The changes are those of the year in UTC: this midnight is in 2026
        // there, after daylight time ended on 31 December.
        .{ .tz = "XXX-10YYY,J1/0,J365/0", .y = 2027, .m = 1, .d = 1, .want = 1798725600 },
    };
    for (rows) |r| {
        var z = load(gpa, r.tz, null);
        defer z.deinit();
        try std.testing.expectEqual(r.want, z.fromLocal(daysFromCivil(r.y, r.m, r.d) * 86400));
    }
}

test "a local midnight inside a DST gap does not exist" {
    // America/Santiago moves 00:00 to 01:00 on the first Sunday of September.
    const z: Zone = .{ .footer = try parsePosix("<-04>4<-03>,M9.1.6/24,M4.1.6/24") };
    try std.testing.expectEqual(@as(?i64, null), z.fromLocal(daysFromCivil(2026, 9, 6) * 86400));
}
