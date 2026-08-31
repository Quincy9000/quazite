const std = @import("std");
const World = @import("world.zig").World;

pub fn Engine(comptime Entity: type) type {
    return struct {
        world: W = .{},
        /// Held onto so the world can be built again from nothing.
        plugins: std.ArrayList(W.Plugin) = .empty,
        gpa: std.mem.Allocator,

        const Self = @This();

        pub const W = World(Entity);
        pub const System = W.System;

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        /// Records a plugin. It is not registered until the world is started, so the
        /// same list can build the world as many times as it is asked to.
        pub fn addPlugin(engine: *Self, plugin: W.Plugin) !void {
            try engine.plugins.append(engine.gpa, plugin);
        }

        /// Registers every plugin into the world, then fires the startup hooks.
        pub fn start(engine: *Self) !void {
            for (engine.plugins.items) |plugin| try engine.world.addPlugin(engine.gpa, plugin);
            engine.world.start();
        }

        /// Runs the frame systems until `running` says stop.
        pub fn run(engine: *Self, running: *const fn () bool) void {
            while (running()) engine.world.run();
        }

        /// Takes the world down through every cleanup hook, discards it, and builds a new
        /// one from the same plugins. Nothing carries over: systems, entities and anything
        /// they own are all rebuilt by the same path a first start takes.
        pub fn restart(engine: *Self) !void {
            engine.stop();
            engine.world = .{};
            try engine.start();
        }

        pub fn deinit(engine: *Self) void {
            engine.stop();
            engine.plugins.deinit(engine.gpa);
        }

        fn stop(engine: *Self) void {
            engine.world.stop();
            engine.world.deinit(engine.gpa);
        }
    };
}
