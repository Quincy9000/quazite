//! A game made with the world framework: its entity, its config, its controls, and
//! whatever plugins it adds. This one is the template — a grid, a camera, a light,
//! and nothing in the world yet.

const std = @import("std");
const world = @import("world");
const rl = world.rl;
const controls = @import("controls.zig");

/// What the framework is told about this game, once.
pub const Spec = struct {
    pub const Entity = struct {
        // Ordered by alignment, widest first: the entity table sorts its columns that way
        // at compile time, and a list already in order costs it almost nothing to sort.
        position: rl.Vector3,
        size: ?rl.Vector3 = null,
        /// Drawn with a mesh from `Meshes`, where `position` is.
        model: ?world.mesh.Model = null,
        /// A light given off from `position`.
        lamp: ?world.lighting.Lamp = null,
        color: ?rl.Color = null,

        /// What a save cannot carry: a mesh on the GPU, a body in a physics world, a
        /// heap object the world holds one of. Name those types here as the game grows
        /// them — `T == world.physics.BodyId` once there are bodies.
        pub fn transient(comptime T: type) bool {
            _ = T;
            return false;
        }
    };

    pub const config: world.Config = .{
        .game_title = "my super awesome game",
        .view = .three,
    };
};

pub const fw = world.Framework(Spec);
pub const W = fw.W;

pub fn main() !void {
    var game = try fw.Game.init();
    defer game.deinit();
    // Once, here, and not on start: a restart makes the world again, not the game.
    controls.bind();
    // The game's own plugins go here: `try game.add(mine.plugin);`
    game.run();
}

test {
    _ = controls;
}
