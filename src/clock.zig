//! The world's own time, as a resource: `w.resource(Clock)` from anywhere, no import
//! of this file needed. Ticked first thing every frame, so everything after reads the
//! frame's step from it rather than asking the window — one number, the same for
//! every system in the frame.
//!
//! `delta` is the world's step: nought while the world is held, so a paused world is
//! a still one and not a crowd marching on the spot. `real` is the wall's, held or
//! not, for what goes on regardless — a notice fading, a menu's own motion. Put in
//! fresh every time the world is built, so a restart starts at nought without anyone
//! resetting anything; `elapsed` and `frame` are kept in the save.

const std = @import("std");
const rl = @import("raylib.zig").c;

pub const Clock = struct {
    /// Seconds the world has run. Time held still is not in it.
    elapsed: f32 = 0,
    /// Frames the world has run.
    frame: u64 = 0,
    /// Seconds this frame moved the world by: what everything that moves multiplies
    /// its speed by. Nought while the world is held.
    delta: f32 = 0,
    /// Seconds this frame took on the wall, held or not.
    real: f32 = 0,
};

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;

        fn tick(w: *W) void {
            const clock = w.resource(Clock);
            clock.real = rl.GetFrameTime();
            clock.delta = if (W.paused) 0 else clock.real;
            clock.elapsed += clock.delta;
            if (!W.paused) clock.frame += 1;
        }

        fn keep(w: *W, store: *W.Store) void {
            const clock = w.resource(Clock);
            const out = store.writer("clock");
            out.put(f32, clock.elapsed);
            out.put(u64, clock.frame);
        }

        fn recall(w: *W, store: *W.Store) void {
            var in = store.reader("clock") orelse return;
            const clock = w.resource(Clock);
            clock.elapsed = in.get(f32);
            clock.frame = in.get(u64);
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Clock{});
            // Runs held or not: the wall keeps going, and a held world's step is nought, not
            // whatever the last frame's was.
            try w.addSystem(allocator, .{ .name = "clock", .always = true, .onUpdate = tick, .onSave = keep, .onLoad = recall });
        }
    };
}
