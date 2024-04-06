const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    const time = b.dependency("time", .{
        .target = target,
        .optimize = optimize,
    }).module("zig-datetime");
    const farbe = b.dependency("farbe", .{
        .target = target,
        .optimize = optimize,
    }).module("farbe");
    const chrono = b.dependency("chrono", .{
        .target = target,
        .optimize = optimize,
    }).module("chrono");
    const clippy = b.dependency("clippy", .{
        .target = target,
        .optimize = optimize,
    }).module("clippy");
    const termui = b.dependency("termui", .{
        .target = target,
        .optimize = optimize,
    }).module("termui");
    const fuzzig = b.dependency("fuzzig", .{
        .target = target,
        .optimize = optimize,
    }).module("fuzzig");

    const exe = b.addExecutable(.{
        .name = "nkt",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("time", time);
    exe.root_module.addImport("farbe", farbe);
    exe.root_module.addImport("chrono", chrono);
    exe.root_module.addImport("clippy", clippy);
    exe.root_module.addImport("termui", termui);
    exe.root_module.addImport("fuzzig", fuzzig);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .name = "test-nkt",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("time", time);
    unit_tests.root_module.addImport("farbe", farbe);
    unit_tests.root_module.addImport("chrono", chrono);
    unit_tests.root_module.addImport("clippy", clippy);
    unit_tests.root_module.addImport("termui", termui);
    unit_tests.root_module.addImport("fuzzig", fuzzig);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const kcov = b.addSystemCommand(&.{ "kcov", "--include-path", ".", "kcov-out" });
    kcov.addArtifactArg(unit_tests);

    const test_step = b.step("test", "Run unit tests");

    if (coverage) {
        test_step.dependOn(&kcov.step);
    } else {
        test_step.dependOn(&run_unit_tests.step);
    }
}
