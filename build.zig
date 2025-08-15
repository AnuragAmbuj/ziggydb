const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Named module "ziggydb" — module root is the directory of root_source_file (src/)
    const ziggydb_mod = b.addModule("ziggydb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Optional executable (CLI) that can @import("ziggydb")
    const exe = b.addExecutable(.{
        .name = "ziggydb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggydb", .module = ziggydb_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // SINGLE test target: root is src/all_tests.zig (NOT src/root.zig)
    const all_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggydb", .module = ziggydb_mod },
            },
        }),
    });
    b.step("test", "Run all tests").dependOn(&all_tests.step);
}