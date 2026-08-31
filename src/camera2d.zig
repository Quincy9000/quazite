//! The eye, flat; `camera.zig` is the one in three dimensions, and `config.view` says
//! which the game is made with. Shared by whatever steers it and the renderer, which
//! draws through it, so it lives apart from both. Here it is a free camera over a
//! plane — "move" pans it, "zoom" and the wheel bring it closer, "sprint" hurries it,
//! and a right-drag hauls the world with the pointer — so there is something to look
//! about with before the game has a body of its own to follow. Which keys and sticks
//! those are is `controls.zig`'s business; nothing here knows.
//!
//! The pointer stays free: a flat game clicks on things. World units are pixels at
//! a zoom of one, and y runs down the screen, the way raylib's 2D does.

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

        pub var current = rl.Camera2D{
            .offset = .{ .x = 0, .y = 0 },
            .target = config.camera2d_start,
            .rotation = 0,
            .zoom = config.camera2d_zoom,
        };

        /// The middle of the window, where the target is drawn: taken afresh each frame so a
        /// resized window keeps the same spot in the middle.
        fn middle() rl.Vector2 {
            return .{
                .x = @as(f32, @floatFromInt(rl.GetScreenWidth())) / 2,
                .y = @as(f32, @floatFromInt(rl.GetScreenHeight())) / 2,
            };
        }

        fn reset(_: *W) void {
            current = .{
                .offset = middle(),
                .target = config.camera2d_start,
                .rotation = 0,
                .zoom = config.camera2d_zoom,
            };
        }

        fn steer(w: *W) void {
            const step = w.resource(Clock).delta;

            // The zoom first, so the pan is at the zoom the frame draws at. Each is a ratio:
            // a notch of the wheel is one step of `wheel_zoom`, a second on the axis is one
            // of `zoom_rate`, so zooming in and out again lands exactly where it started.
            var zoom = current.zoom;
            zoom *= std.math.pow(f32, config.wheel_zoom, input.wheel());
            zoom *= std.math.pow(f32, config.zoom_rate, input.getAxis("zoom").y * step);
            current.zoom = std.math.clamp(zoom, config.zoom_min, config.zoom_max);

            // The pan covers the same share of the screen a second whatever the zoom.
            var speed: f32 = config.pan_speed * step / current.zoom;
            if (input.isActionDown("sprint")) speed *= config.pan_sprint;
            const move = input.getAxis("move");
            current.target.x += move.x * speed;
            // Up on the stick is up the screen, which is minus y here.
            current.target.y -= move.y * speed;

            // Dragging hauls the world with the pointer: the world, not the eye, so it goes
            // the way the hand does.
            if (input.mouseDown(rl.MOUSE_BUTTON_RIGHT)) {
                const drag = input.mouseDelta();
                current.target.x -= drag.x / current.zoom;
                current.target.y -= drag.y / current.zoom;
            }

            current.offset = middle();
        }

        /// Opens the world's pass: everything drawn until `end` is in the world, through
        /// this eye — panned, zoomed, in world units.
        pub fn begin(_: *W) void {
            rl.BeginMode2D(current);
        }

        /// Back to the screen: everything after this draws in pixels, unmoved by the eye.
        pub fn end(_: *W) void {
            rl.EndMode2D();
        }

        /// Where in the world the pointer is: what a click lands on.
        pub fn underPointer() rl.Vector2 {
            return rl.GetScreenToWorld2D(input.mouse(), current);
        }

        /// Where on the screen a spot in the world is: for a label over a thing.
        pub fn onScreen(spot: rl.Vector2) rl.Vector2 {
            return rl.GetWorldToScreen2D(spot, current);
        }

        fn keep(_: *W, store: *W.Store) void {
            const out = store.writer("camera");
            out.put(rl.Vector2, current.target);
            out.put(f32, current.zoom);
        }

        fn recall(_: *W, store: *W.Store) void {
            var in = store.reader("camera") orelse return;
            current.target = in.get(rl.Vector2);
            current.zoom = std.math.clamp(in.get(f32), config.zoom_min, config.zoom_max);
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            try w.addSystem(allocator, .{ .name = "camera", .onStart = reset, .onUpdate = steer, .onSave = keep, .onLoad = recall });
        }
    };
}
