//! world: a small game framework over raylib. An ECS with plugins, systems, generational
//! entity ids and typed resources; saves; input by name; meshes, lighting, effects,
//! audio, noise, tweens; and box3d physics when it is built in.
//!
//! A game is a spec — its entity type and its config — handed to `Framework` once:
//!
//!     const world = @import("world");
//!     const rl = world.rl;
//!
//!     const Spec = struct {
//!         pub const Entity = struct {
//!             position: rl.Vector3,
//!             model: ?world.mesh.Model = null,
//!             lamp: ?world.lighting.Lamp = null,
//!             pub fn transient(comptime T: type) bool { _ = T; return false; }
//!         };
//!         pub const config: world.Config = .{ .game_title = "mine" };
//!     };
//!     const fw = world.Framework(Spec);
//!
//!     pub fn main() !void {
//!         var game = try fw.Game.init();
//!         defer game.deinit();
//!         try game.add(myPlugin);
//!         game.run();
//!     }
//!
//! The component types a game puts on its entity live at the top of each module —
//! `world.mesh.Model`, `world.physics.RigidBody` — and never depend on the spec. The
//! runtime side — plugins, resources, draw hooks — is `fw.mesh`, `fw.physics`, and so
//! on, specialised to the game's world; the types are reachable there too.

const std = @import("std");

pub const rl = @import("raylib.zig").c;

pub const Config = @import("config.zig").Config;
pub const View = @import("config.zig").View;

// ---- the engine, generic over any entity ----

pub const Engine = @import("engine.zig").Engine;
pub const World = @import("world.zig").World;
pub const typeId = @import("world.zig").typeId;
pub const System = @import("system.zig").System;
pub const Store = @import("store.zig").Store;

// ---- the toolkit that needs no spec ----

pub const input = @import("input.zig");
pub const hud = @import("hud.zig");
pub const noise = @import("noise.zig");
pub const polygon = @import("polygon.zig");
pub const tween = @import("tween.zig");

// ---- the modules: their types at the top, their `Module(Spec)` for the rest ----

pub const clock = @import("clock.zig");
pub const audio = @import("audio.zig");
pub const mesh = @import("mesh.zig");
pub const lighting = @import("lighting.zig");
pub const effects = @import("effects.zig");
pub const physics = @import("physics.zig");
pub const camera = @import("camera.zig");
pub const camera2d = @import("camera2d.zig");
pub const saves = @import("saves.zig");

/// Everything specialised to one game: its world type, and every module's plugins,
/// resources and draw hooks over it.
pub fn Framework(comptime Spec: type) type {
    return struct {
        pub const core = @import("core.zig").Core(Spec);
        pub const Entity = core.Entity;
        pub const config = core.config;
        pub const gpa = core.gpa;
        pub const E = core.E;
        pub const W = core.W;
        pub const Field = core.Field;
        pub const fieldsOf = core.fieldsOf;
        pub const purge = core.purge;
        pub const keepAll = core.keepAll;
        pub const recallAll = core.recallAll;

        pub const clock = @import("clock.zig").Module(Spec);
        pub const camera = @import("camera.zig").Module(Spec);
        pub const camera2d = @import("camera2d.zig").Module(Spec);
        pub const saves = @import("saves.zig").Module(Spec);
        pub const audio = @import("audio.zig").Module(Spec);
        pub const tween = @import("tween.zig").Module(Spec);
        pub const mesh = @import("mesh.zig").Module(Spec);
        pub const lighting = @import("lighting.zig").Module(Spec);
        pub const effects = @import("effects.zig").Module(Spec);
        /// Only with physics built in: `-Dphysics=true`, or `.physics = true` on the
        /// dependency. Touching it otherwise says so at compile time.
        pub const physics = @import("physics.zig").Module(Spec);
        pub const game = @import("game.zig").Module(Spec);
        pub const Game = game.Game;
    };
}
