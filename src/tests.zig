//! `zig build test` runs every test block reachable from here, over a spec of the
//! tests' own. Physics is in only when box3d is: `zig build test -Dphysics=true`.

const std = @import("std");
const options = @import("build_options");
const world = @import("root.zig");
const rl = world.rl;

/// The entity the tests run over: everything the framework's components can go on.
pub const Spec = struct {
    pub const Entity = struct {
        position: rl.Vector3,
        model: ?world.mesh.Model = null,
        lamp: ?world.lighting.Lamp = null,
        crate: if (options.physics) ?world.physics.RigidBody else ?u8 = null,

        pub fn transient(comptime T: type) bool {
            return options.physics and T == world.physics.BodyId;
        }
    };
    pub const config: world.Config = .{ .game_title = "tests" };
};

const fw = world.Framework(Spec);

comptime {
    _ = @import("world.zig");
    _ = @import("store.zig");
    _ = @import("input.zig");
    _ = @import("noise.zig");
    _ = @import("polygon.zig");
    _ = @import("tween.zig");
    _ = @import("mesh.zig");
    _ = fw.clock;
    _ = fw.audio;
    if (options.physics) _ = fw.physics;
}
