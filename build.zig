const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const exe = b.addExecutable(.{
        .name = "nkt",
        .root_source_file = .{ .path = "src/new_main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("time", time);
    exe.addModule("farbe", farbe);
    exe.addModule("chrono", chrono);

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
        .root_source_file = .{ .path = "src/new_main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.addModule("time", time);
    unit_tests.addModule("farbe", farbe);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    b.installArtifact(unit_tests);
}
