const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The framework, and whether box3d comes with it.
    const world = b.dependency("world", .{
        .target = target,
        .optimize = optimize,
        .physics = false,
    });

    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Symbols stay in every build, so even a release crash names its line.
            .strip = false,
        }),
        .use_llvm = true,
    });
    exe.root_module.addImport("world", world.module("world"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "run the game");
    run_step.dependOn(&run.step);

    // `zig build test`: every test block reachable from src/main.zig.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    tests.root_module.addImport("world", world.module("world"));
    const test_step = b.step("test", "run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
