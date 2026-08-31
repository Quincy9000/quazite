//! The eye, in three dimensions; `camera2d.zig` is the flat one, and `config.view`
//! says which the game is made with. Shared by whatever steers it and the renderer,
//! which draws through it, so it lives apart from both. Here it is a free camera —
//! "move" flies it, "look" and the mouse turn it, "climb" lifts it, "sprint" hurries
//! it — so there is something to look about with before the game has a body of its
//! own to put the eye in. Which keys and sticks those are is `controls.zig`'s
//! business; nothing here knows.
//!
//! The mouse is this eye's while it is up: grabbed at the start, so it is a pure
//! turning, and let go at the end.

const std = @import("std");
const rl = @import("raylib.zig").c;
const input = @import("input.zig");
const Clock = @import("clock.zig").Clock;

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;

        const start = rl.Camera3D{
            .fovy = config.field_of_view,
            .position = config.camera_start,
            .target = config.camera_target,
            .up = .{ .x = 0, .y = 1, .z = 0 },
            .projection = rl.CAMERA_PERSPECTIVE,
        };

        pub var current = start;

        fn reset(_: *W) void {
            current = start;
        }

        /// Movement is forward, right and up in the eye's own frame, flattened to the ground:
        /// looking down does not fly one into it. The turn is in degrees.
        fn steer(w: *W) void {
            const step = w.resource(Clock).delta;

            const run = input.getAxis("move");
            const climb = input.getAxis("climb").y;
            var speed: f32 = config.fly_speed * step;
            if (input.isActionDown("sprint")) speed *= config.fly_sprint;

            // The mouse turns by how far it moved; the look axis by how long it is held over.
            // The mouse is a pointer, not an axis, so it is read as itself.
            const mouse = input.mouseDelta();
            const look = input.getAxis("look");
            const turn = rl.Vector2{
                .x = mouse.x * config.mouse_sensitivity + look.x * config.stick_sensitivity * step,
                .y = mouse.y * config.mouse_sensitivity - look.y * config.stick_sensitivity * step,
            };

            rl.UpdateCameraPro(
                &current,
                .{ .x = run.y * speed, .y = run.x * speed, .z = climb * speed },
                .{ .x = turn.x, .y = turn.y, .z = 0 },
                0,
            );
        }

        fn grab(_: *W) void {
            input.grabMouse();
        }

        fn free(_: *W) void {
            input.freeMouse();
        }

        /// Opens the world's pass: everything drawn until `end` is in the world, through
        /// this eye.
        pub fn begin(_: *W) void {
            rl.BeginMode3D(current);
        }

        /// Steps down from the world to the screen: everything after this draws in 2D.
        pub fn end(_: *W) void {
            rl.EndMode3D();
        }

        fn keep(_: *W, store: *W.Store) void {
            const out = store.writer("camera");
            out.put(rl.Vector3, current.position);
            out.put(rl.Vector3, current.target);
        }

        fn recall(_: *W, store: *W.Store) void {
            var in = store.reader("camera") orelse return;
            current.position = in.get(rl.Vector3);
            current.target = in.get(rl.Vector3);
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            try w.addSystem(allocator, .{ .name = "cursor", .onStart = grab, .onCleanup = free });
            try w.addSystem(allocator, .{ .name = "camera", .onStart = reset, .onUpdate = steer, .onSave = keep, .onLoad = recall });
        }
    };
}
