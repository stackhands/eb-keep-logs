const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl, .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const commit = b.option([]const u8, "commit", "Commit the binary is built from") orelse "unknown";
    // Debug info carries absolute build paths; a release binary leaves it
    // out so two builds of one commit are byte-identical.
    const strip = b.option(bool, "strip", "Leave out debug info (default: on for release builds)") orelse (optimize != .debug);

    const options = b.addOptions();
    options.addOption([]const u8, "commit", commit);

    const common = b.dependency("zig_common", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zig_common", .module = common.module("zig_common") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const exe = b.addExecutable(.{ .name = "eb-keep-logs", .root_module = mod, .linkage = .static });
    b.installArtifact(exe);

    // The Zig autodoc site, into <prefix>/docs (pixi task autodoc). A compile
    // of its own: asking the installed one for docs would add -femit-docs to
    // every build of the binary.
    const doc_exe = b.addExecutable(.{ .name = "eb-keep-logs", .root_module = mod });
    const docs = b.addInstallDirectory(.{
        .source_dir = doc_exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate the API reference").dependOn(&docs.step);

    const unit = b.addTest(.{ .root_module = mod });
    b.step("unit", "Run the unit tests").dependOn(&b.addRunArtifact(unit).step);

    // The shell suite of the old implementation, run against this binary.
    // It and the differential run below run in the build root: their script
    // paths are relative, and zig build may be started in a subdirectory.
    // Both run every time, as the cache sees neither their scripts nor the
    // date and tzdata of the host, which the suite compares with.
    const suite = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_eb_keep_logs.sh" });
    suite.addArtifactArg(exe);
    suite.setCwd(b.path("."));
    suite.expectExitCode(0);
    suite.has_side_effects = true;
    // The same invocations through the shell implementation and this one.
    const diff = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/differential.sh" });
    diff.addArtifactArg(exe);
    diff.setCwd(b.path("."));
    diff.expectExitCode(0);
    diff.has_side_effects = true;
    // why, which the shell implementation does not have, on the kept logs
    // of real EasyBuild failures.
    const why = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_why.sh" });
    why.addArtifactArg(exe);
    why.setCwd(b.path("."));
    why.expectExitCode(0);
    why.has_side_effects = true;
    // The tutorial has to name which program has why. It does not need the binary.
    const which = b.addSystemCommand(&.{ "bash", "tests/test_tutorial_which.sh" });
    which.setCwd(b.path("."));
    which.expectExitCode(0);
    which.has_side_effects = true;
    const loads_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_loads.sh" });
    loads_test.addArtifactArg(exe);
    loads_test.setCwd(b.path("."));
    loads_test.expectExitCode(0);
    loads_test.has_side_effects = true;
    const runs_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_runs.sh" });
    runs_test.addArtifactArg(exe);
    runs_test.setCwd(b.path("."));
    runs_test.expectExitCode(0);
    runs_test.has_side_effects = true;

    const test_step = b.step("test", "Run the unit tests, the command-line suites and the differential run");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&suite.step);
    test_step.dependOn(&diff.step);
    test_step.dependOn(&why.step);
    test_step.dependOn(&which.step);
    test_step.dependOn(&loads_test.step);
    test_step.dependOn(&runs_test.step);
}
