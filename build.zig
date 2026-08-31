const std = @import("std");

/// Box3D, taken or left. On, its C is compiled in and `physics` can be used; off, none
/// of it is built or linked and a game pays nothing for it. A game turns it on from
/// its own build.zig — `b.dependency("world", .{ .physics = true })` — or with
/// `-Dphysics=true` here.
const physics_default = false;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const physics = b.option(bool, "physics", "compile box3d in, for the physics module") orelse physics_default;

    // What the code can ask about the build: `@import("build_options").physics`.
    const options = b.addOptions();
    options.addOption(bool, "physics", physics);

    // The library: `@import("world")` in a game that depends on this package.
    const module = b.addModule("world", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    furnish(b, module, target, physics, options);

    // Every test block reachable from src/tests.zig, built the way the library is.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    furnish(b, tests.root_module, target, physics, options);
    const test_step = b.step("test", "run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `zig build new -- <name>`: a game made from the template, next door to this
    // package unless `--at <dir>` says where. The template's files are baked into the
    // tool at build time.
    const tool = b.addExecutable(.{
        .name = "world-new",
        .root_module = b.createModule(.{
            .root_source_file = b.path("new.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const make = b.addRunArtifact(tool);
    make.addArg("--world");
    make.addArg(b.pathFromRoot("."));
    if (b.args) |args| make.addArgs(args);
    const new_step = b.step("new", "make a new game from the template: zig build new -- <name> [--at <dir>]");
    new_step.dependOn(&make.step);
}

/// Everything the framework's code needs around it: the headers, the build options,
/// box3d's C when it is on, and raylib. A game that imports the module gets the same,
/// carried along with it.
fn furnish(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    physics: bool,
    options: *std.Build.Step.Options,
) void {
    // raylib.h, raymath.h, rlgl.h and box3d's headers all live here.
    module.addIncludePath(b.path("include/"));
    module.addOptions("build_options", options);
    if (physics) addBox3dSources(b, module);

    if (target.result.os.tag == .windows) {
        // A mingw build of raylib, dropped into vendors/ (which is ignored by git).
        module.addObjectFile(b.path("vendors/libraylib.a"));
        module.linkSystemLibrary("winmm", .{});
        module.linkSystemLibrary("opengl32", .{});
        module.linkSystemLibrary("gdi32", .{});
        module.linkSystemLibrary("shell32", .{});
        module.linkSystemLibrary("user32", .{});
    } else {
        // Elsewhere raylib is the system's own: the distribution's shared library.
        module.linkSystemLibrary("raylib", .{});
    }
}

/// Box3D built from source rather than linked as a prebuilt library, so both halves
/// are built for whatever target we are on. The public headers are reached as
/// "box3d/x.h" from `include/`; the private ones sit beside the sources and resolve
/// relative to the file including them.
fn addBox3dSources(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{
        .root = b.path("include/box3d/src"),
        .files = box3d_sources,
        .flags = &.{"-std=c17"},
    });
}

const box3d_sources: []const []const u8 = &.{
    "aabb.c",
    "arena_allocator.c",
    "bitset.c",
    "block_allocator.c",
    "body.c",
    "broad_phase.c",
    "capsule.c",
    "compound.c",
    "constraint_graph.c",
    "contact.c",
    "contact_solver.c",
    "convex_manifold.c",
    "core.c",
    "distance.c",
    "distance_joint.c",
    "dynamic_tree.c",
    "height_field.c",
    "hull.c",
    "id_pool.c",
    "island.c",
    "joint.c",
    "manifold.c",
    "math_functions.c",
    "mesh.c",
    "mesh_contact.c",
    "motor_joint.c",
    "mover.c",
    "name_cache.c",
    "parallel_for.c",
    "parallel_joint.c",
    "physics_world.c",
    "prismatic_joint.c",
    "recording.c",
    "recording_replay.c",
    "revolute_joint.c",
    "scheduler.c",
    "sensor.c",
    "shape.c",
    "simd.c",
    "solver.c",
    "solver_set.c",
    "sphere.c",
    "spherical_joint.c",
    "table.c",
    "timer.c",
    "triangle_manifold.c",
    "types.c",
    "weld_joint.c",
    "wheel_joint.c",
    "world_snapshot.c",
};
