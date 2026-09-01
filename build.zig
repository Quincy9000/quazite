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
    furnish(b, module, target, optimize, physics, options);

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
    furnish(b, tests.root_module, target, optimize, physics, options);
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
    optimize: std.builtin.OptimizeMode,
    physics: bool,
    options: *std.Build.Step.Options,
) void {
    // raylib, built from source for whatever target we are on rather than taken from
    // the system or from a prebuilt binary dropped in by hand. Its own build.zig links
    // what the platform needs — opengl32, gdi32 and winmm on windows, X11 or wayland
    // on linux — so nothing here has to name them, and a cross build gets a raylib
    // built for where it is going. raylib.h, raymath.h and rlgl.h come with the
    // library, so the headers always match the code they describe.
    const raylib = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    module.linkLibrary(raylib.artifact("raylib"));

    // raylib's C is compiled without the undefined-behaviour sanitizer, which zig
    // would otherwise switch on for it in debug and ReleaseSafe.
    //
    // Not because upstream C is noisy in general: because of one bug, which makes a
    // debug build abort on ordinary hardware. GLFW takes any /dev/input/event* that
    // advertises an absolute axis to be a joystick, and a great many keyboards — QMK
    // and ZMK boards, and shop-bought ones with a volume knob — put that axis on the
    // same node as the keys. GLFW then reads key presses off it as if they were
    // gamepad buttons:
    //
    //     js->linjs.keyMap[code - BTN_MISC]
    //
    // BTN_MISC is 256 and a letter key is well under it, so the index is negative, and
    // the sanitizer stops the program on the spot. It happens to land inside the
    // 4096-byte `path` field that was zeroed when the device was opened, so the value
    // read is 0 and button 0 is what gets set: harmless, and why a release build has
    // always got away with it while `zig build run` died on every keystroke.
    //
    // linux_joystick.c is #included into raylib's amalgamated rglfw.c, so it cannot be
    // patched or swapped from out here, and no build flag turns the linux joystick
    // backend off. Switching the sanitizer off for raylib alone is the smallest thing
    // that works, and our own zig keeps every check it had.
    raylib.artifact("raylib").root_module.sanitize_c = .off;

    // box3d's headers, reached as "box3d/x.h".
    module.addIncludePath(b.path("include/"));
    module.addOptions("build_options", options);
    if (physics) addBox3dSources(b, module);
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
