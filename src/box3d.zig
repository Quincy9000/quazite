//! One shared @cImport, for the same reason raylib.zig exists: calling @cImport in two
//! files produces two unrelated sets of types. Only compiled in when the build says so:
//! nothing else in the game touches it, so a game without physics never sees it.

comptime {
    if (!@import("build_options").physics) @compileError(
        "box3d is not built in: set physics = true in build.zig (or build with -Dphysics=true) to use physics.zig",
    );
}

pub const c = @cImport({
    @cInclude("box3d/box3d.h");
});
