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

    // A second binary, under zig_common's own -Dtest-ops (atomic.replaceable),
    // so EB_KEEP_LOGS_TEST_KILL_AT can make it die by SIGKILL at a named step
    // of rotate and a test can see what that left behind. Never the
    // installed binary: a release build never depends on zig_common with
    // -Dtest-ops set.
    const test_common = b.dependency("zig_common", .{ .target = target, .optimize = optimize, .@"test-ops" = true });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zig_common", .module = test_common.module("zig_common") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const test_ops_exe = b.addExecutable(.{ .name = "eb-keep-logs-test-ops", .root_module = test_mod, .linkage = .static });
    const crash_safety = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_crash_safety.sh" });
    crash_safety.addArtifactArg(test_ops_exe);
    crash_safety.setCwd(b.path("."));
    crash_safety.expectExitCode(0);
    crash_safety.has_side_effects = true;
    b.step("crash-safety", "Run the signal and crash safety suite").dependOn(&crash_safety.step);

    // The shell suite, run against this binary.
    // It and the case run below run in the build root: their script
    // paths are relative, and zig build may be started in a subdirectory.
    // Both run every time, as the cache sees neither their scripts nor the
    // date and tzdata of the host, which the suite compares with.
    const suite = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_eb_keep_logs.sh" });
    suite.addArtifactArg(exe);
    suite.setCwd(b.path("."));
    suite.expectExitCode(0);
    suite.has_side_effects = true;
    // Fixed invocations, against the expected output under tests/golden/cases.
    const diff = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_cases.sh" });
    diff.addArtifactArg(exe);
    diff.setCwd(b.path("."));
    diff.expectExitCode(0);
    diff.has_side_effects = true;
    // why on the kept logs
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
    const used_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_used.sh" });
    used_test.addArtifactArg(exe);
    used_test.setCwd(b.path("."));
    used_test.expectExitCode(0);
    used_test.has_side_effects = true;
    const usage_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_usage.sh" });
    usage_test.addArtifactArg(exe);
    usage_test.setCwd(b.path("."));
    usage_test.expectExitCode(0);
    usage_test.has_side_effects = true;
    const pending_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_pending.sh" });
    pending_test.addArtifactArg(exe);
    pending_test.setCwd(b.path("."));
    pending_test.expectExitCode(0);
    pending_test.has_side_effects = true;
    const json_schema_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_json_schemas.sh" });
    json_schema_test.addArtifactArg(exe);
    json_schema_test.setCwd(b.path("."));
    json_schema_test.expectExitCode(0);
    json_schema_test.has_side_effects = true;
    const test_bundle_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_test_bundle.sh" });
    test_bundle_test.addArtifactArg(exe);
    test_bundle_test.setCwd(b.path("."));
    test_bundle_test.expectExitCode(0);
    test_bundle_test.has_side_effects = true;
    const lifecycle_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_lifecycle.sh" });
    lifecycle_test.addArtifactArg(exe);
    lifecycle_test.setCwd(b.path("."));
    lifecycle_test.expectExitCode(0);
    lifecycle_test.has_side_effects = true;
    const stable_output_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_output_stability.sh" });
    stable_output_test.addArtifactArg(exe);
    stable_output_test.setCwd(b.path("."));
    stable_output_test.expectExitCode(0);
    stable_output_test.has_side_effects = true;
    const failures_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_failures.sh" });
    failures_test.addArtifactArg(exe);
    failures_test.setCwd(b.path("."));
    failures_test.expectExitCode(0);
    failures_test.has_side_effects = true;
    const metrics_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_metrics.sh" });
    metrics_test.addArtifactArg(exe);
    metrics_test.setCwd(b.path("."));
    metrics_test.expectExitCode(0);
    metrics_test.has_side_effects = true;
    // Fails loudly rather than skipping where strace is missing.
    const fsync_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_rotate_fsync_durability.sh" });
    fsync_test.addArtifactArg(exe);
    fsync_test.setCwd(b.path("."));
    fsync_test.expectExitCode(0);
    fsync_test.has_side_effects = true;
    const report_utf8_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_report_utf8_safety.sh" });
    report_utf8_test.addArtifactArg(exe);
    report_utf8_test.setCwd(b.path("."));
    report_utf8_test.expectExitCode(0);
    report_utf8_test.has_side_effects = true;
    const modulerc_safety_test = b.addSystemCommand(&.{ "bash", "-c", "TOOL_BIN=\"$0\" exec bash tests/test_lifecycle_modulerc_safety.sh" });
    modulerc_safety_test.addArtifactArg(exe);
    modulerc_safety_test.setCwd(b.path("."));
    modulerc_safety_test.expectExitCode(0);
    modulerc_safety_test.has_side_effects = true;

    const test_step = b.step("test", "Run the unit tests, the command-line suites and the expected-output cases");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&suite.step);
    test_step.dependOn(&diff.step);
    test_step.dependOn(&why.step);
    test_step.dependOn(&which.step);
    test_step.dependOn(&loads_test.step);
    test_step.dependOn(&runs_test.step);
    test_step.dependOn(&used_test.step);
    test_step.dependOn(&usage_test.step);
    test_step.dependOn(&pending_test.step);
    test_step.dependOn(&json_schema_test.step);
    test_step.dependOn(&test_bundle_test.step);
    test_step.dependOn(&lifecycle_test.step);
    test_step.dependOn(&stable_output_test.step);
    test_step.dependOn(&failures_test.step);
    test_step.dependOn(&metrics_test.step);
    test_step.dependOn(&crash_safety.step);
    test_step.dependOn(&fsync_test.step);
    test_step.dependOn(&report_utf8_test.step);
    test_step.dependOn(&modulerc_safety_test.step);
}
