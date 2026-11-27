//! CommandSpec scanning for the subcommands. Diagnostics stay the lines each command already prints.
const std = @import("std");
const common = @import("zig_common");

const argparse = common.argparse;
const cli = common.cli;
const Allocator = std.mem.Allocator;
const tool = "eb-keep-logs";

pub const ValidationResult = argparse.ValidationResult;
pub const ValidatorFn = argparse.ValidatorFn;

/// Exact names, no short clusters, any next token is a value, first scan error wins.
fn policy(unknown: argparse.UnknownMode, special: argparse.SpecialActionMode) argparse.Policy {
    return .{
        .allow_abbrev = false,
        .unknown = unknown,
        .double_dash = .ignore,
        .negative_numbers = .any,
        .short_clusters = false,
        .special_action = special,
        .flag_explicit_as_unknown = true,
        .unknown_before_required = true,
        .fail_fast = true,
    };
}
pub const exact = policy(.collect, .immediate_exit);
pub const prescan = policy(.collect, .prescan);
pub const as_positional = policy(.positional, .immediate_exit);

pub const Extra = enum { same, static, failures };
pub const Missing = struct { name: []const u8, msg: []const u8 };
pub const Build = struct {
    prog: []const u8,
    help: []const u8 = "",
    policy: argparse.Policy = exact,
    bare_unknown: bool = false,
    extra: Extra = .same,
    extra_msg: []const u8 = "",
    mutex: ?[]const u8 = null,
    missing: []const Missing = &.{},
    options: []const argparse.OptionSpec = &.{},
    positionals: []const argparse.PositionalSpec = &.{},
    mutually_exclusive: []const argparse.MutexGroup = &.{},
};
pub const Result = union(enum) { ok: argparse.Parsed, help };
pub const Cmd = struct {
    // spec outlives every Parsed this command returns. Parsed keeps the pointer.
    spec: argparse.CommandSpec,
    b: Build,

    pub fn take(self: *const Cmd, gpa: Allocator, args: anytype) argparse.Parsed {
        return switch (drive(gpa, &self.spec, args, &self.b)) {
            .ok => |parsed| parsed,
            .help => cli.die(tool, "internal parse error", .{}),
        };
    }
    pub fn takeOrHelp(self: *const Cmd, gpa: Allocator, args: anytype) Result {
        return drive(gpa, &self.spec, args, &self.b);
    }
};

pub fn make(b: Build) Cmd {
    return .{
        .b = b,
        .spec = .{
            .prog = b.prog,
            .usage = "",
            .help = b.help,
            .add_help = b.help.len != 0,
            .policy = b.policy,
            .options = b.options,
            .positionals = b.positionals,
            .mutually_exclusive = b.mutually_exclusive,
        },
    };
}

pub fn flag(comptime name: []const u8) argparse.OptionSpec {
    return .{ .name = name };
}
pub fn value(comptime name: []const u8) argparse.OptionSpec {
    return .{ .name = name, .kind = .value };
}
pub fn req(comptime n: []const u8) argparse.OptionSpec {
    return .{ .name = n, .kind = .value, .required = true, .allow_empty = false, .allow_dash_value = false };
}
pub fn strict(comptime n: []const u8) argparse.OptionSpec {
    return .{ .name = n, .kind = .value, .allow_empty = false, .allow_dash_value = false };
}
pub fn filled(comptime n: []const u8) argparse.OptionSpec {
    return .{ .name = n, .kind = .value, .allow_empty = false };
}
pub fn append(comptime n: []const u8) argparse.OptionSpec {
    return .{ .name = n, .kind = .append, .allow_empty = false, .allow_dash_value = false };
}
pub fn checked(spec: argparse.OptionSpec, validate: ValidatorFn) argparse.OptionSpec {
    var out = spec;
    out.validate = validate;
    return out;
}
pub fn one(comptime n: []const u8, skip_empty: bool) argparse.PositionalSpec {
    return .{ .name = n, .arity = .required_one, .ignore_empty = skip_empty };
}
pub fn optional(comptime n: []const u8) argparse.PositionalSpec {
    return .{ .name = n, .arity = .optional_one };
}
pub fn zeroOrMore(comptime n: []const u8) argparse.PositionalSpec {
    return .{ .name = n, .arity = .zero_or_more };
}
pub fn oneOrMore(comptime n: []const u8) argparse.PositionalSpec {
    return .{ .name = n, .arity = .one_or_more };
}

fn say(msg: []const u8) noreturn {
    cli.die(tool, "{s}", .{msg});
}
fn sayUnknown(spec: *const Build, tok: []const u8) noreturn {
    if (spec.bare_unknown) cli.die(tool, "unknown option {s}", .{tok});
    cli.die(tool, "{s} does not know '{s}'", .{ spec.prog, tok });
}
fn missingMsg(spec: *const Build, name: []const u8) noreturn {
    for (spec.missing) |row| if (std.mem.eql(u8, row.name, name)) say(row.msg);
    cli.die(tool, "{s} needs --{s}", .{ spec.prog, name });
}
fn refuse(err: argparse.UsageError, spec: *const Build) noreturn {
    switch (err.kind) {
        .unknown_option => |tok| sayUnknown(spec, tok),
        .extra_positional => |tok| switch (spec.extra) {
            .same => sayUnknown(spec, tok),
            .static => say(spec.extra_msg),
            .failures => cli.die(tool, "failures takes no positional argument, got '{s}'", .{tok}),
        },
        .missing_value, .missing_required => |name| missingMsg(spec, name),
        .invalid_value => |bad| missingMsg(spec, bad.name),
        .mutually_exclusive => say(spec.mutex orelse "internal parse error"),
        else => cli.die(tool, "internal parse error", .{}),
    }
}
fn drive(gpa: Allocator, spec: *const argparse.CommandSpec, args: anytype, build: *const Build) Result {
    const argv = gpa.alloc([]const u8, args.len) catch cli.die(tool, "out of memory", .{});
    defer gpa.free(argv);
    for (args, 0..) |arg, i| argv[i] = arg;
    const outcome = argparse.parse(gpa, spec, argv) catch cli.die(tool, "out of memory", .{});
    switch (outcome) {
        .ok => |parsed| return .{ .ok = parsed },
        .action_done => |done| {
            cli.put(1, done.stdout_text);
            return .help;
        },
        .usage_error => |err| refuse(err, build),
    }
}
