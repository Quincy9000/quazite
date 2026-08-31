pub fn System(comptime World: type) type {
    return struct {
        name: []const u8,
        /// Whether this system's update runs while the world is paused. Almost nothing
        /// should: the menu that lifts the pause, the keys that save and load, and the
        /// odd stopwatch. Everything else stops where it stands.
        always: bool = false,
        onStart: ?Run = null,
        onUpdate: ?Run = null,
        onDraw: ?Run = null,
        onCleanup: ?Run = null,
        /// Writing what this system owns into a save, and reading it back. A system that
        /// owns entities takes its own out of the world before reading them in.
        onSave: ?Keep = null,
        onLoad: ?Keep = null,

        const Self = @This();

        pub const Run = *const fn (*World) void;
        pub const Keep = *const fn (*World, *World.Store) void;

        pub fn start(system: *const Self, world: *World) void {
            if (system.onStart) |run| run(world);
        }

        pub fn update(system: *const Self, world: *World) void {
            if (system.onUpdate) |run| run(world);
        }

        pub fn draw(system: *const Self, world: *World) void {
            if (system.onDraw) |run| run(world);
        }

        pub fn cleanup(system: *const Self, world: *World) void {
            if (system.onCleanup) |run| run(world);
        }

        pub fn save(system: *const Self, world: *World, store: *World.Store) void {
            if (system.onSave) |run| run(world, store);
        }

        pub fn load(system: *const Self, world: *World, store: *World.Store) void {
            if (system.onLoad) |run| run(world, store);
        }
    };
}
