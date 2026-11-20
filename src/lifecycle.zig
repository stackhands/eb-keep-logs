//! `lifecycle`: generate a reversible module lifecycle plan and Lmod
//! `.modulerc.lua` warnings/forbids from `eb-keep-logs usage --json` output.
//!
//! Reads a TOML policy, checks the minimum observation window, and calls
//! `eb-stack rebuild-set` for candidate removals so modules with installed
//! dependents are never cleared for removal. Never deletes anything.
const std = @import("std");
const linux = std.os.linux;
const common = @import("zig_common");
const sys = common.sys;
const fsx = common.fsx;
const atomic = common.atomic;
const proc = common.proc;
const cli = common.cli;
const localtime = @import("localtime.zig");

const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";
/// The `schema_version` of what `--json` prints.
pub const schema_version: u32 = 1;
const read_limit: usize = 64 * 1024 * 1024;

/// Lifecycle classification assigned to each installed module.
pub const Action = enum {
    keep,
    warn,
    @"forbid-after",
    @"candidate-remove",

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .keep => "keep",
            .warn => "warn",
            .@"forbid-after" => "forbid-after",
            .@"candidate-remove" => "candidate-remove",
        };
    }
};

/// Parsed lifecycle policy from TOML.
pub const Policy = struct {
    min_observation_days: u64,
    warn_after_days: u64,
    forbid_after_days: u64,
    remove_after_days: u64,
    forbid_grace_days: u64 = 30,
    min_hits: u64 = 1,
    keep: []const []const u8 = &.{},
    warn_message: ?[]const u8 = null,
    forbid_message: ?[]const u8 = null,
};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cli.die(tool, fmt, args);
}

fn readRegularAll(gpa: Allocator, path: []const u8, label: []const u8) []u8 {
    const opened = fsx.openRegular(fsx.cwd, path, true) catch |err|
        die("cannot read {s} {s}: {s}", .{ label, path, @errorName(err) });
    defer sys.close(opened.fd);
    return fsx.readAll(gpa, opened.fd, read_limit) catch |err|
        die("cannot read {s} {s}: {s}", .{ label, path, @errorName(err) });
}

fn parseFiniteNonNeg(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    const v = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(v) or v < 0) return null;
    return v;
}

/// Match `text` against `pattern` where `*` matches any byte sequence and `?`
/// matches any single byte.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

fn matchesKeep(patterns: []const []const u8, module: []const u8) bool {
    for (patterns) |pat| {
        if (globMatch(pat, module)) return true;
    }
    return false;
}

pub const PolicyError = Allocator.Error || error{BadPolicy};

const TomlParser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    err_msg: []const u8 = "invalid TOML policy",

    fn fail(self: *TomlParser, comptime fmt: []const u8, args: anytype) PolicyError {
        self.err_msg = self.arena.print(fmt, args) catch "invalid TOML policy";
        return error.BadPolicy;
    }

    fn skipHorizontalWs(self: *TomlParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) : (self.pos += 1) {}
    }

    fn skipWsAndComments(self: *TomlParser) PolicyError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {
                    if (self.src[self.pos] == 0) return self.fail("NUL byte in policy", .{});
                }
            } else {
                break;
            }
        }
    }

    fn skipLineTail(self: *TomlParser) PolicyError!void {
        self.skipHorizontalWs();
        if (self.pos < self.src.len and self.src[self.pos] == '#') {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
        }
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\r') self.pos += 1;
            if (self.pos < self.src.len) {
                if (self.src[self.pos] != '\n') return self.fail("unexpected trailing characters in policy", .{});
                self.pos += 1;
            }
        }
    }

    fn parseKey(self: *TomlParser) PolicyError![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos == start) return self.fail("expected key in policy", .{});
        return self.src[start..self.pos];
    }

    fn parseString(self: *TomlParser) PolicyError![]const u8 {
        if (self.pos >= self.src.len) return self.fail("expected string in policy", .{});
        const quote = self.src[self.pos];
        if (quote != '"' and quote != '\'') return self.fail("expected string in policy", .{});
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == 0) return self.fail("NUL byte in policy string", .{});
            if (c == '\n' or c == '\r') return self.fail("unterminated string in policy", .{});
            if (c == quote) {
                self.pos += 1;
                return try out.toOwnedSlice(self.arena);
            }
            if (quote == '"' and c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return self.fail("unterminated escape in policy", .{});
                const esc = self.src[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try out.append(self.arena, '"'),
                    '\\' => try out.append(self.arena, '\\'),
                    'n' => try out.append(self.arena, '\n'),
                    'r' => try out.append(self.arena, '\r'),
                    't' => try out.append(self.arena, '\t'),
                    else => return self.fail("unsupported string escape '\\{c}' in policy", .{esc}),
                }
            } else {
                try out.append(self.arena, c);
                self.pos += 1;
            }
        }
        return self.fail("unterminated string in policy", .{});
    }

    fn parseUInt(self: *TomlParser) PolicyError!u64 {
        const start = self.pos;
        var digits: std.ArrayList(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c)) {
                try digits.append(self.arena, c);
                self.pos += 1;
            } else if (c == '_' and digits.items.len > 0 and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos == start or digits.items.len == 0) return self.fail("expected non-negative integer in policy", .{});
        if (digits.items.len > 1 and digits.items[0] == '0') return self.fail("leading zero in integer in policy", .{});
        return std.fmt.parseInt(u64, digits.items, 10) catch return self.fail("integer overflow in policy", .{});
    }

    fn parseStringArray(self: *TomlParser) PolicyError![]const []const u8 {
        if (self.pos >= self.src.len or self.src[self.pos] != '[') return self.fail("expected '[' in policy", .{});
        self.pos += 1;
        var items: std.ArrayList([]const u8) = .empty;
        while (true) {
            try self.skipWsAndComments();
            if (self.pos >= self.src.len) return self.fail("unterminated array in policy", .{});
            if (self.src[self.pos] == ']') {
                self.pos += 1;
                return try items.toOwnedSlice(self.arena);
            }
            const s = try self.parseString();
            if (s.len == 0) return self.fail("policy keep entry must not be empty", .{});
            try items.append(self.arena, s);
            try self.skipWsAndComments();
            if (self.pos >= self.src.len) return self.fail("unterminated array in policy", .{});
            if (self.src[self.pos] == ',') {
                self.pos += 1;
            } else if (self.src[self.pos] == ']') {
                self.pos += 1;
                return try items.toOwnedSlice(self.arena);
            } else {
                return self.fail("expected ',' or ']' in policy array", .{});
            }
        }
    }
};

/// Parse a lifecycle TOML policy document.
pub fn parsePolicy(arena: Allocator, text: []const u8, err_out: *[]const u8) PolicyError!Policy {
    var p: TomlParser = .{ .arena = arena, .src = text };
    var min_obs: ?u64 = null;
    var warn_days: ?u64 = null;
    var forbid_days: ?u64 = null;
    var remove_days: ?u64 = null;
    var grace_days: ?u64 = null;
    var min_hits: ?u64 = null;
    var keep: ?[]const []const u8 = null;
    var warn_msg: ?[]const u8 = null;
    var forbid_msg: ?[]const u8 = null;
    var seen_section = false;

    while (true) {
        p.skipWsAndComments() catch |err| {
            err_out.* = p.err_msg;
            return err;
        };
        if (p.pos >= p.src.len) break;
        if (p.src[p.pos] == '[') {
            p.pos += 1;
            p.skipHorizontalWs();
            const sec = p.parseKey() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
            p.skipHorizontalWs();
            if (p.pos >= p.src.len or p.src[p.pos] != ']') {
                err_out.* = "unterminated section header in policy";
                return error.BadPolicy;
            }
            p.pos += 1;
            p.skipLineTail() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
            if (!std.mem.eql(u8, sec, "policy") and !std.mem.eql(u8, sec, "lifecycle")) {
                err_out.* = arena.print("unknown policy section '[{s}]'", .{sec}) catch "unknown policy section";
                return error.BadPolicy;
            }
            if (seen_section) {
                err_out.* = "duplicate policy section header";
                return error.BadPolicy;
            }
            seen_section = true;
            continue;
        }
        const key = p.parseKey() catch |err| {
            err_out.* = p.err_msg;
            return err;
        };
        p.skipHorizontalWs();
        if (p.pos >= p.src.len or p.src[p.pos] != '=') {
            err_out.* = arena.print("expected '=' after policy key '{s}'", .{key}) catch "expected '=' in policy";
            return error.BadPolicy;
        }
        p.pos += 1;
        p.skipHorizontalWs();

        if (std.mem.eql(u8, key, "min_observation_days")) {
            if (min_obs != null) {
                err_out.* = "duplicate policy key 'min_observation_days'";
                return error.BadPolicy;
            }
            min_obs = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "warn_after_days")) {
            if (warn_days != null) {
                err_out.* = "duplicate policy key 'warn_after_days'";
                return error.BadPolicy;
            }
            warn_days = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "forbid_after_days")) {
            if (forbid_days != null) {
                err_out.* = "duplicate policy key 'forbid_after_days'";
                return error.BadPolicy;
            }
            forbid_days = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "remove_after_days")) {
            if (remove_days != null) {
                err_out.* = "duplicate policy key 'remove_after_days'";
                return error.BadPolicy;
            }
            remove_days = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "forbid_grace_days")) {
            if (grace_days != null) {
                err_out.* = "duplicate policy key 'forbid_grace_days'";
                return error.BadPolicy;
            }
            grace_days = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "min_hits")) {
            if (min_hits != null) {
                err_out.* = "duplicate policy key 'min_hits'";
                return error.BadPolicy;
            }
            min_hits = p.parseUInt() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "keep")) {
            if (keep != null) {
                err_out.* = "duplicate policy key 'keep'";
                return error.BadPolicy;
            }
            keep = p.parseStringArray() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "warn_message")) {
            if (warn_msg != null) {
                err_out.* = "duplicate policy key 'warn_message'";
                return error.BadPolicy;
            }
            warn_msg = p.parseString() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else if (std.mem.eql(u8, key, "forbid_message")) {
            if (forbid_msg != null) {
                err_out.* = "duplicate policy key 'forbid_message'";
                return error.BadPolicy;
            }
            forbid_msg = p.parseString() catch |err| {
                err_out.* = p.err_msg;
                return err;
            };
        } else {
            err_out.* = arena.print("unknown policy key '{s}'", .{key}) catch "unknown policy key";
            return error.BadPolicy;
        }

        p.skipLineTail() catch |err| {
            err_out.* = p.err_msg;
            return err;
        };
    }

    const mo = min_obs orelse {
        err_out.* = "policy needs min_observation_days";
        return error.BadPolicy;
    };
    const wd = warn_days orelse {
        err_out.* = "policy needs warn_after_days";
        return error.BadPolicy;
    };
    const fd = forbid_days orelse {
        err_out.* = "policy needs forbid_after_days";
        return error.BadPolicy;
    };
    const rd = remove_days orelse {
        err_out.* = "policy needs remove_after_days";
        return error.BadPolicy;
    };
    const mh = min_hits orelse 1;

    if (mo == 0) {
        err_out.* = "min_observation_days must be at least 1";
        return error.BadPolicy;
    }
    if (mh == 0) {
        err_out.* = "min_hits must be at least 1";
        return error.BadPolicy;
    }
    if (fd < wd) {
        err_out.* = "forbid_after_days must be at least warn_after_days";
        return error.BadPolicy;
    }
    if (rd < fd) {
        err_out.* = "remove_after_days must be at least forbid_after_days";
        return error.BadPolicy;
    }

    return .{
        .min_observation_days = mo,
        .warn_after_days = wd,
        .forbid_after_days = fd,
        .remove_after_days = rd,
        .forbid_grace_days = grace_days orelse 30,
        .min_hits = mh,
        .keep = keep orelse &.{},
        .warn_message = warn_msg,
        .forbid_message = forbid_msg,
    };
}

const UsagePackage = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    hits: u64,
    last: ?[]const u8,
    last_epoch: ?f64,
};

const UsageInput = struct {
    software: []const u8,
    modules: []const u8,
    since_text: ?[]const u8,
    since_epoch: ?f64,
    packages: []const UsagePackage,
};

fn requireObjectField(obj: std.json.ObjectMap, key: []const u8, label: []const u8) std.json.Value {
    return obj.get(key) orelse die("{s} is missing '{s}'", .{ label, key });
}

fn requireStringField(obj: std.json.ObjectMap, key: []const u8, label: []const u8) []const u8 {
    return switch (requireObjectField(obj, key, label)) {
        .string => |s| s,
        else => die("{s} '{s}' must be a string", .{ label, key }),
    };
}

fn parseUsageJson(arena: Allocator, path: []const u8, text: []const u8) UsageInput {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch
        die("{s} is not valid JSON", .{path});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => die("{s} must be a JSON object", .{path}),
    };
    const ver = switch (requireObjectField(root, "schema_version", path)) {
        .integer => |n| n,
        else => die("{s} schema_version must be 1", .{path}),
    };
    if (ver != 1) die("{s} schema_version must be 1", .{path});
    const kind = requireStringField(root, "kind", path);
    if (!std.mem.eql(u8, kind, "usage")) die("{s} kind must be \"usage\"", .{path});

    const selection = requireStringField(root, "selection", path);
    if (!std.mem.eql(u8, selection, "all"))
        die("lifecycle requires usage JSON with selection \"all\", got \"{s}\"", .{selection});

    const software = requireStringField(root, "software", path);
    const modules = requireStringField(root, "modules", path);

    var since_text: ?[]const u8 = null;
    var since_epoch: ?f64 = null;
    switch (requireObjectField(root, "since", path)) {
        .null => {},
        .string => |s| {
            since_epoch = parseFiniteNonNeg(s) orelse die("{s} has invalid since '{s}'", .{ path, s });
            since_text = s;
        },
        else => die("{s} 'since' must be a string or null", .{path}),
    }

    const pkgs_val = requireObjectField(root, "packages", path);
    const pkgs_arr = switch (pkgs_val) {
        .array => |arr| arr,
        else => die("{s} 'packages' must be an array", .{path}),
    };

    var out: std.ArrayList(UsagePackage) = .empty;
    for (pkgs_arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => die("{s} package entry must be an object", .{path}),
        };
        const name = requireStringField(obj, "name", path);
        const version = requireStringField(obj, "version", path);
        const module = requireStringField(obj, "module", path);
        if (name.len == 0 or version.len == 0 or module.len == 0)
            die("{s} package entry has empty name, version or module", .{path});
        switch (requireObjectField(obj, "active", path)) {
            .bool => {},
            else => die("{s} package 'active' must be a boolean", .{path}),
        }
        const hits_i = switch (requireObjectField(obj, "hits", path)) {
            .integer => |n| n,
            else => die("{s} package 'hits' must be an integer", .{path}),
        };
        if (hits_i < 0) die("{s} package 'hits' must be non-negative", .{path});
        var last_text: ?[]const u8 = null;
        var last_epoch: ?f64 = null;
        switch (requireObjectField(obj, "last", path)) {
            .null => {},
            .string => |s| if (s.len > 0) {
                last_epoch = parseFiniteNonNeg(s) orelse die("{s} package '{s}' has invalid last '{s}'", .{ path, module, s });
                last_text = s;
            },
            else => die("{s} package 'last' must be a string or null", .{path}),
        }
        out.append(arena, .{
            .name = name,
            .version = version,
            .module = module,
            .hits = @intCast(hits_i),
            .last = last_text,
            .last_epoch = last_epoch,
        }) catch die("out of memory", .{});
    }

    return .{
        .software = software,
        .modules = modules,
        .since_text = since_text,
        .since_epoch = since_epoch,
        .packages = out.items,
    };
}

const Entry = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    easyconfig: []const u8,
    action: Action,
    hits: u64,
    last: ?[]const u8,
    idle_days: ?u64,
    forbid_after: ?[]const u8 = null,
    dependents: []const []const u8 = &.{},
    blocked_reason: ?[]const u8 = null,
    reason: []const u8,
    pending_candidate: bool = false,
};

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.module, b.module);
}

fn formatUtcDate(arena: Allocator, epoch_sec: i64) Allocator.Error![]const u8 {
    const days = @divFloor(epoch_sec, 86400);
    const d = localtime.civilFromDays(days);
    if (d.year >= 0) {
        return try arena.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(d.year)), d.month, d.day });
    }
    return try arena.print("{d}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
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

const RebuildInfo = struct {
    changed: std.StringHashMapUnmanaged(void) = .empty,
    missing: std.StringHashMapUnmanaged(void) = .empty,
    dependents: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
};

fn addDependent(arena: Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)), ec: []const u8, dep: []const u8) !void {
    const gop = try map.getOrPut(arena, ec);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing, dep)) return;
    }
    try gop.value_ptr.append(arena, try arena.dupe(u8, dep));
}

fn parseRebuildSetJson(arena: Allocator, path: []const u8, text: []const u8) RebuildInfo {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch
        die("rebuild-set file {s} is not valid JSON", .{path});
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => die("rebuild-set file {s} must be a JSON object", .{path}),
    };
    _ = switch (requireObjectField(root, "schema_version", path)) {
        .integer => {},
        else => die("rebuild-set file {s} schema_version must be an integer", .{path}),
    };

    var info: RebuildInfo = .{};

    const changed_arr = switch (requireObjectField(root, "changed", path)) {
        .array => |a| a,
        else => die("rebuild-set file {s} 'changed' must be an array", .{path}),
    };
    for (changed_arr.items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => die("rebuild-set file {s} 'changed' entries must be strings", .{path}),
        };
        info.changed.put(arena, s, {}) catch die("out of memory", .{});
    }

    const missing_arr = switch (requireObjectField(root, "missing", path)) {
        .array => |a| a,
        else => die("rebuild-set file {s} 'missing' must be an array", .{path}),
    };
    for (missing_arr.items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => die("rebuild-set file {s} 'missing' entries must be strings", .{path}),
        };
        info.missing.put(arena, s, {}) catch die("out of memory", .{});
    }

    const rows_arr = switch (requireObjectField(root, "rows", path)) {
        .array => |a| a,
        else => die("rebuild-set file {s} 'rows' must be an array", .{path}),
    };
    for (rows_arr.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => die("rebuild-set file {s} row must be an object", .{path}),
        };
        const row_changed = requireStringField(row, "changed", path);
        const dependent = requireStringField(row, "dependent", path);
        const edge_kind = requireStringField(row, "edge_kind", path);
        if (std.mem.eql(u8, edge_kind, "changed")) continue;

        var parts = std.mem.splitSequence(u8, row_changed, ", ");
        while (parts.next()) |ec| {
            if (ec.len == 0) continue;
            addDependent(arena, &info.dependents, ec, dependent) catch die("out of memory", .{});
        }
    }

    return info;
}

fn resolveExecutable(gpa: Allocator, explicit: ?[]const u8, path_env: []const u8) []u8 {
    if (explicit) |raw| {
        if (std.mem.indexOfScalar(u8, raw, '/') != null) {
            var rb: [sys.path_max]u8 = undefined;
            const resolved = fsx.realpath(fsx.cwd, raw, &rb) catch |err|
                die("cannot resolve --eb-stack {s}: {t}", .{ raw, err });
            return gpa.dupe(u8, resolved) catch die("out of memory", .{});
        }
        return (proc.which(gpa, raw, path_env) catch die("out of memory", .{})) orelse
            die("cannot find '{s}' on PATH", .{raw});
    }
    return (proc.which(gpa, "eb-stack", path_env) catch die("out of memory", .{})) orelse
        die("cannot find eb-stack on PATH; pass --eb-stack or --rebuild-set", .{});
}

fn runEbStackRebuildSet(
    gpa: Allocator,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    eb_stack_exe: []const u8,
    easyconfigs: []const []const u8,
    easystacks: []const []const u8,
    packages: []const UsagePackage,
    candidates: []const []const u8,
) RebuildInfo {
    const tmp_root = blk: {
        const v = env.get("TMPDIR") orelse "";
        break :blk if (v.len > 0) std.mem.trimEnd(u8, v, "/") else "/tmp";
    };
    var rnd: [4]u8 = undefined;
    _ = sys.call(linux.getrandom, .{ &rnd, rnd.len, 0 }) catch die("getrandom failed", .{});
    const work_dir = arena.print("{s}/eb-keep-logs-lifecycle-{d}-{x:0>8}", .{
        if (tmp_root.len > 0) tmp_root else "/tmp",
        linux.getpid(),
        std.mem.readInt(u32, &rnd, .little),
    }) catch die("out of memory", .{});

    var zb: [sys.path_max:0]u8 = undefined;
    _ = sys.call(linux.mkdirat, .{ fsx.cwd, (sys.z(&zb, work_dir) catch die("path too long", .{})).ptr, 0o700 }) catch |err|
        die("cannot create temporary directory {s}: {t}", .{ work_dir, err });
    defer fsx.deleteTree(gpa, fsx.cwd, work_dir) catch {};

    const work_fd = fsx.openDir(fsx.cwd, work_dir, false) catch |err|
        die("cannot open temporary directory {s}: {t}", .{ work_dir, err });
    defer sys.close(work_fd);

    const out_dir = arena.print("{s}/out", .{work_dir}) catch die("out of memory", .{});
    _ = sys.call(linux.mkdirat, .{ work_fd, "out", 0o700 }) catch |err|
        die("cannot create {s}/out: {t}", .{ work_dir, err });

    const installed_path = arena.print("{s}/installed.txt", .{work_dir}) catch die("out of memory", .{});
    {
        var inst_buf: std.ArrayList(u8) = .empty;
        for (packages) |pkg| {
            inst_buf.print(arena, "{s}\n", .{pkg.module}) catch die("out of memory", .{});
        }
        const fd = sys.openat(work_fd, "installed.txt", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600) catch |err|
            die("cannot write {s}: {t}", .{ installed_path, err });
        defer sys.close(fd);
        sys.writeAll(fd, inst_buf.items) catch |err| die("cannot write {s}: {t}", .{ installed_path, err });
    }

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ eb_stack_exe, "rebuild-set" }) catch die("out of memory", .{});

    if (candidates.len <= 32) {
        for (candidates) |ec| {
            argv.appendSlice(arena, &.{ "--changed", ec }) catch die("out of memory", .{});
        }
    } else {
        const changed_path = arena.print("{s}/changed.txt", .{work_dir}) catch die("out of memory", .{});
        var chg_buf: std.ArrayList(u8) = .empty;
        for (candidates) |ec| {
            chg_buf.print(arena, "{s}\n", .{ec}) catch die("out of memory", .{});
        }
        const fd = sys.openat(work_fd, "changed.txt", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600) catch |err|
            die("cannot write {s}: {t}", .{ changed_path, err });
        defer sys.close(fd);
        sys.writeAll(fd, chg_buf.items) catch |err| die("cannot write {s}: {t}", .{ changed_path, err });
        argv.appendSlice(arena, &.{ "--changed", changed_path }) catch die("out of memory", .{});
    }

    for (easyconfigs) |ec_dir| {
        argv.appendSlice(arena, &.{ "--easyconfigs", ec_dir }) catch die("out of memory", .{});
    }
    for (easystacks) |es| {
        argv.appendSlice(arena, &.{ "--easystack", es }) catch die("out of memory", .{});
    }
    argv.appendSlice(arena, &.{
        "--installed", installed_path,
        "--out-dir",   out_dir,
    }) catch die("out of memory", .{});

    const res = proc.run(gpa, eb_stack_exe, argv.items, envp, .{
        .stdout_limit = 1 << 20,
        .stderr_limit = 64 * 1024,
    }) catch |err| die("cannot run eb-stack rebuild-set: {s}", .{@errorName(err)});
    defer res.deinit(gpa);

    if (res.term.code() != 0) {
        const stderr_trimmed = std.mem.trimEnd(u8, res.stderr, "\r\n");
        if (stderr_trimmed.len > 0) {
            die("eb-stack rebuild-set failed (exit {d}): {s}", .{ res.term.code(), stderr_trimmed });
        }
        die("eb-stack rebuild-set failed (exit {d})", .{res.term.code()});
    }

    const report_path = arena.print("{s}/rebuild-set.json", .{out_dir}) catch die("out of memory", .{});
    const report_text = readRegularAll(gpa, report_path, "rebuild-set output");
    defer gpa.free(report_text);
    return parseRebuildSetJson(arena, report_path, report_text);
}

fn escapeLua(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(arena, "\\\\"),
            '"' => try out.appendSlice(arena, "\\\""),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => if (c < 0x20 or c == 0x7f) {
                try out.print(arena, "\\{d:0>3}", .{c});
            } else {
                try out.append(arena, c);
            },
        }
    }
    return try out.toOwnedSlice(arena);
}

fn renderTemplate(arena: Allocator, tmpl: []const u8, module: []const u8, after: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tmpl.len) {
        if (std.mem.startsWith(u8, tmpl[i..], "{module}")) {
            try out.appendSlice(arena, module);
            i += "{module}".len;
        } else if (std.mem.startsWith(u8, tmpl[i..], "{after}")) {
            try out.appendSlice(arena, after);
            i += "{after}".len;
        } else {
            try out.append(arena, tmpl[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(arena);
}

fn formatModulerc(arena: Allocator, policy: Policy, entries: []const Entry) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "-- Generated by eb-keep-logs lifecycle. Review before installing as .modulerc.lua.\n");
    try out.appendSlice(arena, "-- No software or modulefiles were modified or removed.\n");

    for (entries) |ent| {
        switch (ent.action) {
            .keep => {},
            .warn => {
                try out.print(arena, "\n-- warn: {s} ({s})\n", .{ ent.module, ent.reason });
                if (ent.forbid_after) |after| {
                    const name_q = try escapeLua(arena, ent.module);
                    const after_q = try escapeLua(arena, after);
                    const nearly_raw = if (policy.warn_message) |tmpl|
                        try renderTemplate(arena, tmpl, ent.module, after)
                    else
                        try arena.print("{s} has had no recorded usage recently and is scheduled to be forbidden after {s}.", .{ ent.module, after });
                    const msg_raw = if (policy.forbid_message) |tmpl|
                        try renderTemplate(arena, tmpl, ent.module, after)
                    else
                        try arena.print("{s} is forbidden due to inactivity.", .{ent.module});
                    try out.print(arena, "forbid{{\n  name = \"{s}\",\n  after = \"{s}\",\n  nearly_message = \"{s}\",\n  message = \"{s}\",\n}}\n", .{
                        name_q,
                        after_q,
                        try escapeLua(arena, nearly_raw),
                        try escapeLua(arena, msg_raw),
                    });
                }
            },
            .@"forbid-after" => {
                const after = ent.forbid_after orelse "";
                try out.print(arena, "\n-- forbid-after: {s} ({s})\n", .{ ent.module, ent.reason });
                const name_q = try escapeLua(arena, ent.module);
                const after_q = try escapeLua(arena, after);
                const nearly_raw = if (policy.warn_message) |tmpl|
                    try renderTemplate(arena, tmpl, ent.module, after)
                else
                    try arena.print("{s} is deprecated and will be forbidden after {s}.", .{ ent.module, after });
                const msg_raw = if (policy.forbid_message) |tmpl|
                    try renderTemplate(arena, tmpl, ent.module, after)
                else
                    try arena.print("{s} is forbidden due to inactivity.", .{ent.module});
                try out.print(arena, "forbid{{\n  name = \"{s}\",\n  after = \"{s}\",\n  nearly_message = \"{s}\",\n  message = \"{s}\",\n}}\n", .{
                    name_q,
                    after_q,
                    try escapeLua(arena, nearly_raw),
                    try escapeLua(arena, msg_raw),
                });
            },
            .@"candidate-remove" => {
                try out.print(arena, "\n-- candidate-remove: {s} ({s})\n", .{ ent.module, ent.reason });
                const name_q = try escapeLua(arena, ent.module);
                const msg_raw = if (policy.forbid_message) |tmpl|
                    try renderTemplate(arena, tmpl, ent.module, "")
                else
                    try arena.print("{s} is marked for removal; contact support if you still need it.", .{ent.module});
                try out.print(arena, "hide_version(\"{s}\")\n", .{name_q});
                try out.print(arena, "forbid{{\n  name = \"{s}\",\n  message = \"{s}\",\n}}\n", .{
                    name_q,
                    try escapeLua(arena, msg_raw),
                });
            },
        }
    }
    return try out.toOwnedSlice(arena);
}

fn writeFileDurable(path: []const u8, bytes: []const u8) void {
    var why: atomic.Why = .{};
    atomic.atomicWrite(std.heap.page_allocator, path, bytes, .{}, &why) catch |err| switch (err) {
        error.Refused => die("{s}", .{why.msg}),
        error.OutOfMemory => die("out of memory", .{}),
        else => |e| die("cannot write {s}: {t}", .{ path, e }),
    };
}

const Counts = struct {
    keep: usize = 0,
    warn: usize = 0,
    @"forbid-after": usize = 0,
    @"candidate-remove": usize = 0,
};

fn formatText(arena: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |ent| {
        try out.print(arena, "{s} {s} hits={d} ", .{ ent.action.name(), ent.module, ent.hits });
        if (ent.idle_days) |d| {
            try out.print(arena, "idle_days={d}", .{d});
        } else {
            try out.appendSlice(arena, "idle_days=unknown");
        }
        if (ent.forbid_after) |after| {
            try out.print(arena, " forbid_after={s}", .{after});
        }
        if (ent.dependents.len > 0) {
            try out.appendSlice(arena, " dependents=");
            for (ent.dependents, 0..) |dep, idx| {
                if (idx > 0) try out.append(arena, ',');
                try out.appendSlice(arena, dep);
            }
        }
        try out.print(arena, " reason=\"{s}\"\n", .{ent.reason});
    }
    return try out.toOwnedSlice(arena);
}

const JsonEntry = struct {
    name: []const u8,
    version: []const u8,
    module: []const u8,
    easyconfig: []const u8,
    action: []const u8,
    hits: u64,
    last: ?[]const u8,
    idle_days: ?u64,
    forbid_after: ?[]const u8,
    dependents: []const []const u8,
    blocked_reason: ?[]const u8,
    reason: []const u8,
};

const JsonReport = struct {
    schema_version: u32 = schema_version,
    kind: []const u8 = "lifecycle",
    software: []const u8,
    modules: []const u8,
    policy: []const u8,
    now: []const u8,
    since: ?[]const u8,
    observed_days: ?u64,
    min_observation_days: u64,
    observation_satisfied: bool,
    dependents_checked: bool,
    counts: Counts,
    entries: []const JsonEntry,
    modulerc_lua: []const u8,
};

fn formatJson(
    gpa: Allocator,
    arena: Allocator,
    usage_in: UsageInput,
    policy_path: []const u8,
    now_text: []const u8,
    observed_days: ?u64,
    policy: Policy,
    observation_satisfied: bool,
    dependents_checked: bool,
    counts: Counts,
    entries: []const Entry,
    modulerc_lua: []const u8,
) ![]u8 {
    var json_entries: std.ArrayList(JsonEntry) = .empty;
    for (entries) |ent| {
        try json_entries.append(arena, .{
            .name = ent.name,
            .version = ent.version,
            .module = ent.module,
            .easyconfig = ent.easyconfig,
            .action = ent.action.name(),
            .hits = ent.hits,
            .last = ent.last,
            .idle_days = ent.idle_days,
            .forbid_after = ent.forbid_after,
            .dependents = ent.dependents,
            .blocked_reason = ent.blocked_reason,
            .reason = ent.reason,
        });
    }
    const report: JsonReport = .{
        .software = usage_in.software,
        .modules = usage_in.modules,
        .policy = policy_path,
        .now = now_text,
        .since = usage_in.since_text,
        .observed_days = observed_days,
        .min_observation_days = policy.min_observation_days,
        .observation_satisfied = observation_satisfied,
        .dependents_checked = dependents_checked,
        .counts = counts,
        .entries = json_entries.items,
        .modulerc_lua = modulerc_lua,
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

/// `lifecycle --policy FILE [--modulerc-out FILE] [--easyconfigs DIR ...]
/// [--easystack FILE ...] [--eb-stack PATH] [--rebuild-set FILE]
/// [--now EPOCH] [--json] FILE`.
pub fn cmdLifecycle(
    gpa: Allocator,
    env: *const std.process.Environ.Map,
    envp: proc.Envp,
    args: []const []const u8,
) u8 {
    var policy_path: []const u8 = "";
    var modulerc_out: ?[]const u8 = null;
    var eb_stack_opt: ?[]const u8 = null;
    var rebuild_set_opt: ?[]const u8 = null;
    var now_opt: ?[]const u8 = null;
    var json_out = false;
    var usage_path: []const u8 = "";

    var easyconfigs: std.ArrayList([]const u8) = .empty;
    defer easyconfigs.deinit(gpa);
    var easystacks: std.ArrayList([]const u8) = .empty;
    defer easystacks.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--policy") or std.mem.startsWith(u8, arg, "--policy=")) {
            policy_path = optionValue(args, &i, arg, "--policy", "lifecycle needs --policy");
        } else if (std.mem.eql(u8, arg, "--modulerc-out") or std.mem.startsWith(u8, arg, "--modulerc-out=")) {
            modulerc_out = optionValue(args, &i, arg, "--modulerc-out", "--modulerc-out needs a path");
        } else if (std.mem.eql(u8, arg, "--easyconfigs") or std.mem.startsWith(u8, arg, "--easyconfigs=")) {
            const v = optionValue(args, &i, arg, "--easyconfigs", "--easyconfigs needs a directory");
            easyconfigs.append(gpa, v) catch die("out of memory", .{});
        } else if (std.mem.eql(u8, arg, "--easystack") or std.mem.startsWith(u8, arg, "--easystack=")) {
            const v = optionValue(args, &i, arg, "--easystack", "--easystack needs a file");
            easystacks.append(gpa, v) catch die("out of memory", .{});
        } else if (std.mem.eql(u8, arg, "--eb-stack") or std.mem.startsWith(u8, arg, "--eb-stack=")) {
            eb_stack_opt = optionValue(args, &i, arg, "--eb-stack", "--eb-stack needs a path");
        } else if (std.mem.eql(u8, arg, "--rebuild-set") or std.mem.startsWith(u8, arg, "--rebuild-set=")) {
            rebuild_set_opt = optionValue(args, &i, arg, "--rebuild-set", "--rebuild-set needs a file");
        } else if (std.mem.eql(u8, arg, "--now") or std.mem.startsWith(u8, arg, "--now=")) {
            now_opt = optionValue(args, &i, arg, "--now", "--now needs an epoch");
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            die("lifecycle does not know '{s}'", .{arg});
        } else if (usage_path.len == 0) {
            usage_path = arg;
        } else {
            die("lifecycle does not know '{s}'", .{arg});
        }
    }

    if (policy_path.len == 0) die("lifecycle needs --policy", .{});
    if (usage_path.len == 0) die("lifecycle needs a usage JSON file", .{});
    if (rebuild_set_opt != null and easyconfigs.items.len > 0)
        die("lifecycle takes --easyconfigs or --rebuild-set, not both", .{});
    if (easystacks.items.len > 0 and easyconfigs.items.len == 0)
        die("--easystack requires --easyconfigs", .{});
    if (modulerc_out) |out_p| {
        if (std.mem.indexOfScalar(u8, out_p, '\n') != null or std.mem.indexOfScalar(u8, out_p, 0) != null)
            die("--modulerc-out must not contain a newline", .{});
    }
    for (easyconfigs.items) |ec_dir| {
        const d = fsx.openDir(fsx.cwd, ec_dir, true) catch
            die("easyconfigs directory {s} is not a directory", .{ec_dir});
        sys.close(d);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now_raw: []const u8 = if (now_opt) |n| n else (env.get("EB_KEEP_LOGS_NOW") orelse "");
    const now_epoch: f64 = if (now_raw.len > 0)
        (parseFiniteNonNeg(now_raw) orelse die("reference epoch must be a non-negative number, not '{s}'", .{now_raw}))
    else blk: {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        break :blk @floatFromInt(ts.sec);
    };
    const now_text: []const u8 = if (now_raw.len > 0)
        now_raw
    else
        (arena.print("{d}", .{@as(i64, @intFromFloat(@floor(now_epoch)))}) catch die("out of memory", .{}));

    const policy_text = readRegularAll(gpa, policy_path, "policy");
    defer gpa.free(policy_text);
    var policy_err: []const u8 = "";
    const policy = parsePolicy(arena, policy_text, &policy_err) catch |err| switch (err) {
        error.BadPolicy => die("{s}: {s}", .{ policy_path, policy_err }),
        error.OutOfMemory => die("out of memory", .{}),
    };

    const usage_text = readRegularAll(gpa, usage_path, "usage report");
    defer gpa.free(usage_text);
    const usage_in = parseUsageJson(arena, usage_path, usage_text);

    const observed_days: ?u64 = if (usage_in.since_epoch) |s|
        (if (now_epoch >= s) @as(u64, @intFromFloat(@floor((now_epoch - s) / 86400.0))) else 0)
    else
        null;
    const observation_satisfied = if (observed_days) |d| d >= policy.min_observation_days else false;

    var entries: std.ArrayList(Entry) = .empty;
    var candidates: std.ArrayList([]const u8) = .empty;

    for (usage_in.packages) |pkg| {
        const easyconfig = arena.print("{s}-{s}.eb", .{ pkg.name, pkg.version }) catch die("out of memory", .{});
        const idle_days: ?u64 = if (pkg.last_epoch) |le|
            (if (now_epoch >= le) @as(u64, @intFromFloat(@floor((now_epoch - le) / 86400.0))) else 0)
        else if (pkg.hits >= policy.min_hits)
            null
        else
            observed_days;

        var ent: Entry = .{
            .name = pkg.name,
            .version = pkg.version,
            .module = pkg.module,
            .easyconfig = easyconfig,
            .action = .keep,
            .hits = pkg.hits,
            .last = pkg.last,
            .idle_days = idle_days,
            .reason = "",
        };

        if (matchesKeep(policy.keep, pkg.module)) {
            ent.action = .keep;
            ent.reason = "protected by policy keep rule";
        } else if (pkg.hits >= policy.min_hits and pkg.last_epoch == null) {
            ent.action = .keep;
            ent.reason = "active hit has no timestamp";
        } else if (idle_days == null) {
            ent.action = .keep;
            ent.reason = "observation window unknown (usage --since not set)";
        } else {
            const d = idle_days.?;
            if (d < policy.warn_after_days) {
                ent.action = .keep;
                ent.reason = arena.print("idle {d}d < warn_after_days {d}", .{ d, policy.warn_after_days }) catch die("out of memory", .{});
            } else if (d < policy.forbid_after_days) {
                ent.action = .warn;
                ent.reason = arena.print("idle {d}d >= warn_after_days {d}", .{ d, policy.warn_after_days }) catch die("out of memory", .{});
            } else if (d < policy.remove_after_days) {
                ent.action = .@"forbid-after";
                ent.reason = arena.print("idle {d}d >= forbid_after_days {d}", .{ d, policy.forbid_after_days }) catch die("out of memory", .{});
            } else if (!observation_satisfied) {
                ent.action = .@"forbid-after";
                ent.blocked_reason = if (observed_days) |od|
                    (arena.print("observation window {d}d < min_observation_days {d}", .{ od, policy.min_observation_days }) catch die("out of memory", .{}))
                else
                    "observation window unknown (usage --since not set)";
                ent.reason = ent.blocked_reason.?;
            } else {
                ent.action = .@"candidate-remove";
                ent.pending_candidate = true;
                candidates.append(arena, easyconfig) catch die("out of memory", .{});
            }
        }
        entries.append(arena, ent) catch die("out of memory", .{});
    }

    std.mem.sort(Entry, entries.items, {}, lessEntry);

    var dependents_checked = false;
    var rebuild_info: RebuildInfo = .{};

    if (rebuild_set_opt) |rs_path| {
        const rs_text = readRegularAll(gpa, rs_path, "rebuild-set");
        defer gpa.free(rs_text);
        rebuild_info = parseRebuildSetJson(arena, rs_path, rs_text);
        dependents_checked = true;
    } else if (candidates.items.len > 0 and easyconfigs.items.len > 0) {
        const path_env = env.get("PATH") orelse "";
        const eb_stack_exe = resolveExecutable(gpa, eb_stack_opt, path_env);
        defer gpa.free(eb_stack_exe);
        rebuild_info = runEbStackRebuildSet(
            gpa,
            arena,
            env,
            envp,
            eb_stack_exe,
            easyconfigs.items,
            easystacks.items,
            usage_in.packages,
            candidates.items,
        );
        dependents_checked = true;
    }

    const now_sec: i64 = @intFromFloat(@floor(now_epoch));
    for (entries.items) |*ent| {
        if (ent.pending_candidate) {
            if (!dependents_checked) {
                ent.action = .@"forbid-after";
                ent.blocked_reason = "dependent modules not checked (pass --easyconfigs or --rebuild-set)";
                ent.reason = ent.blocked_reason.?;
            } else if (!rebuild_info.changed.contains(ent.easyconfig)) {
                ent.action = .@"forbid-after";
                ent.blocked_reason = "candidate easyconfig absent from rebuild-set.json";
                ent.reason = ent.blocked_reason.?;
            } else if (rebuild_info.missing.contains(ent.easyconfig)) {
                ent.action = .@"forbid-after";
                ent.blocked_reason = "easyconfig missing from eb-stack graph";
                ent.reason = ent.blocked_reason.?;
            } else if (rebuild_info.dependents.getPtr(ent.easyconfig)) |deps_list| {
                var filtered: std.ArrayList([]const u8) = .empty;
                for (deps_list.items) |dep| {
                    if (!std.mem.eql(u8, dep, ent.module)) {
                        filtered.append(arena, dep) catch die("out of memory", .{});
                    }
                }
                if (filtered.items.len > 0) {
                    std.mem.sort([]const u8, filtered.items, {}, struct {
                        fn lt(_: void, a: []const u8, b: []const u8) bool {
                            return std.mem.lessThan(u8, a, b);
                        }
                    }.lt);
                    ent.dependents = filtered.items;
                    var joined: std.ArrayList(u8) = .empty;
                    for (filtered.items, 0..) |dep, idx| {
                        if (idx > 0) joined.appendSlice(arena, ", ") catch die("out of memory", .{});
                        joined.appendSlice(arena, dep) catch die("out of memory", .{});
                    }
                    ent.action = .warn;
                    ent.blocked_reason = arena.print("has installed dependents: {s}", .{joined.items}) catch die("out of memory", .{});
                    ent.reason = ent.blocked_reason.?;
                } else {
                    ent.action = .@"candidate-remove";
                    ent.reason = arena.print("idle {d}d >= remove_after_days {d}; 0 dependents", .{
                        ent.idle_days.?,
                        policy.remove_after_days,
                    }) catch die("out of memory", .{});
                }
            } else {
                ent.action = .@"candidate-remove";
                ent.reason = arena.print("idle {d}d >= remove_after_days {d}; 0 dependents", .{
                    ent.idle_days.?,
                    policy.remove_after_days,
                }) catch die("out of memory", .{});
            }
        }

        if (ent.action == .warn and ent.blocked_reason == null) {
            const d = ent.idle_days.?;
            const until_forbid = (policy.forbid_after_days - d) + policy.forbid_grace_days;
            const target_sec = now_sec + @as(i64, @intCast(until_forbid)) * 86400;
            ent.forbid_after = formatUtcDate(arena, target_sec) catch die("out of memory", .{});
        } else if (ent.action == .@"forbid-after") {
            const target_sec = now_sec + @as(i64, @intCast(policy.forbid_grace_days)) * 86400;
            ent.forbid_after = formatUtcDate(arena, target_sec) catch die("out of memory", .{});
        }
    }

    var counts: Counts = .{};
    for (entries.items) |ent| {
        switch (ent.action) {
            .keep => counts.keep += 1,
            .warn => counts.warn += 1,
            .@"forbid-after" => counts.@"forbid-after" += 1,
            .@"candidate-remove" => counts.@"candidate-remove" += 1,
        }
    }

    const modulerc_lua = formatModulerc(arena, policy, entries.items) catch die("out of memory", .{});
    if (modulerc_out) |out_p| {
        writeFileDurable(out_p, modulerc_lua);
    }

    const body = if (json_out)
        formatJson(
            gpa,
            arena,
            usage_in,
            policy_path,
            now_text,
            observed_days,
            policy,
            observation_satisfied,
            dependents_checked,
            counts,
            entries.items,
            modulerc_lua,
        ) catch die("out of memory", .{})
    else
        formatText(arena, entries.items) catch die("out of memory", .{});
    defer if (json_out) gpa.free(body);

    cli.out("{s}", .{body});
    return 0;
}

test "parsePolicy reads thresholds, optional fields and keep globs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err_msg: []const u8 = "";
    const text =
        \\[policy]
        \\min_observation_days = 90
        \\warn_after_days = 60
        \\forbid_after_days = 180
        \\remove_after_days = 365
        \\forbid_grace_days = 14
        \\min_hits = 2
        \\keep = [
        \\  "GCCcore/*",
        \\  "OpenMPI/5.0*",
        \\]
        \\warn_message = "Module {module} will be forbidden on {after}."
    ;
    const pol = try parsePolicy(arena, text, &err_msg);
    try std.testing.expectEqual(@as(u64, 90), pol.min_observation_days);
    try std.testing.expectEqual(@as(u64, 60), pol.warn_after_days);
    try std.testing.expectEqual(@as(u64, 180), pol.forbid_after_days);
    try std.testing.expectEqual(@as(u64, 365), pol.remove_after_days);
    try std.testing.expectEqual(@as(u64, 14), pol.forbid_grace_days);
    try std.testing.expectEqual(@as(u64, 2), pol.min_hits);
    try std.testing.expectEqual(@as(usize, 2), pol.keep.len);
    try std.testing.expect(matchesKeep(pol.keep, "GCCcore/15.2.0"));
    try std.testing.expect(!matchesKeep(pol.keep, "GROMACS/2026.1"));
}

test "parsePolicy refuses bad order or unknown keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err_msg: []const u8 = "";

    const bad_order =
        \\min_observation_days = 90
        \\warn_after_days = 200
        \\forbid_after_days = 100
        \\remove_after_days = 365
    ;
    try std.testing.expectError(error.BadPolicy, parsePolicy(arena, bad_order, &err_msg));

    const unknown_key =
        \\min_observation_days = 90
        \\warn_after_days = 60
        \\forbid_after_days = 180
        \\remove_after_days = 365
        \\bogus = 1
    ;
    try std.testing.expectError(error.BadPolicy, parsePolicy(arena, unknown_key, &err_msg));
}

test "globMatch handles stars and question marks" {
    try std.testing.expect(globMatch("GCCcore/*", "GCCcore/15.2.0"));
    try std.testing.expect(!globMatch("GCCcore/*", "GCC/15.2.0"));
    try std.testing.expect(globMatch("Foo/1.?-*", "Foo/1.0-foss"));
    try std.testing.expect(!globMatch("Foo/1.?-*", "Foo/10.0-foss"));
}

test "formatModulerc escapes Lua strings and emits warn, forbid and hide_version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pol: Policy = .{
        .min_observation_days = 90,
        .warn_after_days = 60,
        .forbid_after_days = 180,
        .remove_after_days = 365,
    };
    const entries = [_]Entry{
        .{
            .name = "KeepMe",
            .version = "1.0",
            .module = "KeepMe/1.0",
            .easyconfig = "KeepMe-1.0.eb",
            .action = .keep,
            .hits = 10,
            .last = "1700000000",
            .idle_days = 1,
            .reason = "idle 1d < warn_after_days 60",
        },
        .{
            .name = "OldSim",
            .version = "2.1",
            .module = "OldSim/2.1",
            .easyconfig = "OldSim-2.1.eb",
            .action = .@"forbid-after",
            .hits = 1,
            .last = "1700000000",
            .idle_days = 200,
            .forbid_after = "2026-12-17",
            .reason = "idle 200d >= forbid_after_days 180",
        },
        .{
            .name = "DeadPkg",
            .version = "0.9",
            .module = "DeadPkg/0.9",
            .easyconfig = "DeadPkg-0.9.eb",
            .action = .@"candidate-remove",
            .hits = 0,
            .last = null,
            .idle_days = 400,
            .reason = "idle 400d >= remove_after_days 365; 0 dependents",
        },
    };
    const lua = try formatModulerc(arena, pol, &entries);
    try std.testing.expect(std.mem.indexOf(u8, lua, "KeepMe/1.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, lua, "name = \"OldSim/2.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lua, "after = \"2026-12-17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lua, "hide_version(\"DeadPkg/0.9\")") != null);
}
