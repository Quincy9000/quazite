//! The game: which plugins make the world, in what order, and the frame. The window,
//! the restart key, the stopwatch over the systems and the render pass are here
//! because they are the frame's own rather than any one thing's in it.

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
        const camera = @import("camera.zig").Module(Spec);
        const camera2d = @import("camera2d.zig").Module(Spec);
        const clock = @import("clock.zig").Module(Spec);
        const audio = @import("audio.zig").Module(Spec);
        const tween = @import("tween.zig").Module(Spec);
        const mesh = @import("mesh.zig").Module(Spec);
        const lighting = @import("lighting.zig").Module(Spec);
        const effects = @import("effects.zig").Module(Spec);
        const saves = @import("saves.zig").Module(Spec);
        const E = core.E;

        const zero = 0;
        const half = 2;

        var restarting = false;

        /// Set to leave the frame loop and close the window: a game with a menu of
        /// its own says when, since one that takes the exit key for itself has no
        /// other way out.
        pub var leaving = false;

        // ---- the window ----

        fn openWindow(_: *W) void {
            // Asked for before the window exists, which is the only time it can be: the
            // edges of everything smoothed by the samples, not the shader.
            const flags: c_uint = rl.FLAG_MSAA_4X_HINT |
                @as(c_uint, if (config.vsync) rl.FLAG_VSYNC_HINT else 0) |
                @as(c_uint, if (config.window_resizable) rl.FLAG_WINDOW_RESIZABLE else 0);
            rl.SetConfigFlags(flags);
            rl.InitWindow(config.window_width, config.window_height, config.game_title);
            if (config.window_resizable) rl.SetWindowMinSize(config.window_min_width, config.window_min_height);
            rl.rlSetClipPlanes(config.near_plane, config.far_plane);
            if (config.frame_cap > 0) rl.SetTargetFPS(config.frame_cap);
            // Escape closes the window. A game with a menu of its own takes the key back with
            // KEY_NULL and leaves through the menu instead.
            rl.SetExitKey(config.exit_key);
        }

        fn centerWindow(_: *W) void {
            if (rl.GetMonitorCount() > zero) {
                const width = rl.GetMonitorWidth(zero);
                const height = rl.GetMonitorHeight(zero);
                rl.SetWindowMonitor(zero);
                rl.SetWindowPosition(@divFloor(width, half) - config.window_width / half, @divFloor(height, half) - config.window_height / half);
            }
        }

        fn closeWindow(_: *W) void {
            rl.CloseWindow();
        }

        /// The devices read once, first thing, so every name asked this frame is answered
        /// from the same reading.
        fn pollInput(_: *W) void {
            input.poll();
        }

        fn requestRestart(_: *W) void {
            if (input.isActionPressed("restart")) restarting = true;
        }

        // ---- the stopwatch ----

        var profiling = false;

        fn now() f64 {
            return rl.GetTime();
        }

        /// P sets the stopwatch over the systems and shows the dearest of them; P again puts
        /// it away, and nothing is timed.
        fn profileKey(_: *W) void {
            if (!input.isActionPressed("profile")) return;
            profiling = !profiling;
            W.clock = if (profiling) now else null;
        }

        /// The eight systems the frame is going on, dearest first, in milliseconds.
        fn drawProfile(w: *W) void {
            if (!profiling) return;
            const Row = struct { name: []const u8, ms: f64 };
            var top: [8]Row = undefined;
            var shown: usize = zero;
            for (w.systems.items, w.spent.items) |system, seconds| {
                const row = Row{ .name = system.name, .ms = seconds * 1000 };
                // Kept sorted: insert where it belongs, dropping off the end.
                var at = shown;
                while (at > zero and top[at - 1].ms < row.ms) : (at -= 1) {
                    if (at < top.len) top[at] = top[at - 1];
                }
                if (at < top.len) {
                    top[at] = row;
                    if (shown < top.len) shown += 1;
                }
            }
            var total: f64 = 0;
            for (w.spent.items) |seconds| total += seconds * 1000;

            const size: c_int = config.hud_text_size;
            const right = rl.GetScreenWidth() - config.hud_margin;
            var line_top: c_int = config.hud_margin;
            var text: [64]u8 = undefined;
            const head = std.fmt.bufPrintZ(&text, "updates {d:.2} ms", .{total}) catch "";
            rl.DrawText(head.ptr, right - rl.MeasureText(head.ptr, size), line_top, size, rl.RAYWHITE);
            line_top += size + 4;
            for (top[zero..shown]) |row| {
                const line = std.fmt.bufPrintZ(&text, "{s}  {d:.2}", .{ row.name, row.ms }) catch "";
                rl.DrawText(line.ptr, right - rl.MeasureText(line.ptr, size), line_top, size, rl.RAYWHITE);
                line_top += size + 4;
            }
        }

        /// Leaving the frame loop means one of two things: the player wants out — the window's
        /// own close, or the exit key — or wants the world rebuilt. Either way the loop has to
        /// end so the cleanup hooks can run.
        fn running() bool {
            return !restarting and !leaving and !rl.WindowShouldClose();
        }

        // ---- the frame ----

        fn beginFrame(_: *W) void {
            rl.BeginDrawing();
            rl.ClearBackground(config.sky);
        }

        fn drawGround(_: *W) void {
            rl.DrawGrid(config.grid_lines, config.grid_step);
        }

        /// The flat floor: a grid of cells about the origin, the two axes through it brighter
        /// so the eye can tell where it is.
        fn drawGround2d(_: *W) void {
            const cell: f32 = config.grid_cell;
            const half_lines: i32 = config.grid_lines / 2;
            const reach = cell * @as(f32, @floatFromInt(half_lines));
            var i: i32 = -half_lines;
            while (i <= half_lines) : (i += 1) {
                const at = @as(f32, @floatFromInt(i)) * cell;
                const color = if (i == 0) config.hud_dim else config.grid_color;
                rl.DrawLineV(.{ .x = at, .y = -reach }, .{ .x = at, .y = reach }, color);
                rl.DrawLineV(.{ .x = -reach, .y = at }, .{ .x = reach, .y = at }, color);
            }
        }

        fn drawHud(w: *W) void {
            const size: c_int = config.hud_text_size;
            var text: [96]u8 = undefined;
            const line = std.fmt.bufPrintZ(&text, "{d} fps   {d} entities   {d:.1} s   {s}", .{
                rl.GetFPS(),
                w.entities.len,
                w.resource(Clock).elapsed,
                @as([]const u8, if (input.padPlugged()) "pad" else "keyboard"),
            }) catch "";
            rl.DrawText(line.ptr, config.hud_margin, config.hud_margin, size, rl.RAYWHITE);
            const hint: [:0]const u8 = switch (config.view) {
                .three => if (input.padPlugged())
                    "sticks  fly + look   bumpers  down / up"
                else
                    "wasd + mouse  fly + look   space / ctrl  up / down   f5  save   f9  load   r  restart   p  profile   esc  quit",
                .two => if (input.padPlugged())
                    "stick  pan   bumpers  zoom"
                else
                    "wasd  pan   wheel / - =  zoom   right drag  haul   f5  save   f9  load   r  restart   p  profile   esc  quit",
            };
            if (config.hud_hint) rl.DrawText(hint.ptr, config.hud_margin, rl.GetScreenHeight() - config.hud_margin - size, size, config.hud_dim);
        }

        fn endFrame(_: *W) void {
            rl.EndDrawing();
        }

        // ---- the plugins ----

        fn windowPlugin(w: *W, allocator: std.mem.Allocator) !void {
            try w.addSystem(allocator, .{ .name = "window", .onStart = openWindow, .onCleanup = closeWindow });
            try w.addSystem(allocator, .{ .name = "center window", .onStart = centerWindow });
        }

        /// The frame's own keys, which answer whether or not the world is held.
        fn keysPlugin(w: *W, allocator: std.mem.Allocator) !void {
            try w.addSystem(allocator, .{ .name = "input", .always = true, .onUpdate = pollInput });
            try w.addSystem(allocator, .{ .name = "restart key", .always = true, .onUpdate = requestRestart });
            try w.addSystem(allocator, .{ .name = "profile key", .always = true, .onUpdate = profileKey });
        }

        /// The whole frame, as draw systems: "begin frame" opens the window target, "begin
        /// scene" the world's pass through whichever eye the view has, everything between it
        /// and "end scene" renders in the world, "end scene" drops to the screen for the
        /// readout, and "end frame" presents. Order here is paint order — later systems draw
        /// over earlier ones. A game's own draws go between "draw ground" and "end scene".
        fn renderPlugin(w: *W, allocator: std.mem.Allocator) !void {
            try w.addSystem(allocator, .{ .name = "begin frame", .onDraw = beginFrame });
            // The scene goes into a texture when there are effects to run over it.
            try w.addSystem(allocator, .{ .name = "begin effects", .onDraw = effects.begin });
            switch (config.view) {
                .three => {
                    // The world once from the sun, for the shadows, and once from the eye, lit.
                    try w.addSystem(allocator, .{ .name = "shadow pass", .onDraw = lighting.shadowPass });
                    try w.addSystem(allocator, .{ .name = "begin scene", .onDraw = camera.begin });
                    try w.addSystem(allocator, .{ .name = "begin lighting", .onDraw = lighting.begin });
                    try w.addSystem(allocator, .{ .name = "draw models", .onDraw = mesh.drawModels });
                    try w.addSystem(allocator, .{ .name = "draw scene", .onDraw = drawScene });
                    try w.addSystem(allocator, .{ .name = "end lighting", .onDraw = lighting.end });
                    // Unlit: lines have no faces to light.
                    try w.addSystem(allocator, .{ .name = "draw ground", .onDraw = drawGround });
                    try w.addSystem(allocator, .{ .name = "draw unlit", .onDraw = drawUnlitScene });
                    try w.addSystem(allocator, .{ .name = "end scene", .onDraw = camera.end });
                },
                .two => {
                    try w.addSystem(allocator, .{ .name = "begin scene", .onDraw = camera2d.begin });
                    try w.addSystem(allocator, .{ .name = "draw ground", .onDraw = drawGround2d });
                    try w.addSystem(allocator, .{ .name = "draw models", .onDraw = mesh.drawModels });
                    try w.addSystem(allocator, .{ .name = "draw scene", .onDraw = drawScene });
                    try w.addSystem(allocator, .{ .name = "draw unlit", .onDraw = drawUnlitScene });
                    try w.addSystem(allocator, .{ .name = "end scene", .onDraw = camera2d.end });
                },
            }
            try w.addSystem(allocator, .{ .name = "apply effects", .onDraw = effects.apply });
            try w.addSystem(allocator, .{ .name = "hud", .onDraw = drawHud });
            try w.addSystem(allocator, .{ .name = "draw profile", .onDraw = drawProfile });
            try w.addSystem(allocator, .{ .name = "draw save notice", .onDraw = saves.draw });
            try w.addSystem(allocator, .{ .name = "draw screen", .onDraw = drawScreen });
            try w.addSystem(allocator, .{ .name = "end frame", .onDraw = endFrame });
        }

        /// The frame's own draws a game adds: inside the scene, after the models, and
        /// on the screen, over the readout.
        var scene_draws: std.ArrayList(W.System.Run) = .empty;
        var unlit_draws: std.ArrayList(W.System.Run) = .empty;
        var screen_draws: std.ArrayList(W.System.Run) = .empty;

        fn drawScene(w: *W) void {
            for (scene_draws.items) |draw| draw(w);
        }

        fn drawUnlitScene(w: *W) void {
            for (unlit_draws.items) |draw| draw(w);
        }

        fn drawScreen(w: *W) void {
            for (screen_draws.items) |draw| draw(w);
        }

        pub const Game = struct {
            engine: E,

            /// The standard plugins, in order: the window, the input, the clock, the
            /// tweens, the sound, the meshes, the light (in 3D), the effects, the eye.
            /// A game's own come after, with `add`; the saves and the render pass go
            /// on last, when the game is run.
            pub fn init() !Game {
                var game = Game{ .engine = .init(gpa) };
                try game.engine.addPlugin(windowPlugin);
                // First of the updaters: everything after it asks the input by name.
                try game.engine.addPlugin(keysPlugin);
                // Before anything that moves: the frame's step is read from it, not the window.
                try game.engine.addPlugin(clock.plugin);
                try game.engine.addPlugin(tween.plugin);
                try game.engine.addPlugin(audio.plugin);
                // Before anything that builds a mesh: the meshes live in the window's context.
                try game.engine.addPlugin(mesh.plugin);
                // After the meshes, whose material it lends a shader to. Light is a 3D thing.
                if (config.view == .three) try game.engine.addPlugin(lighting.plugin);
                try game.engine.addPlugin(effects.plugin);
                // The eye the view calls for; the other is never made — or neither, for
                // a game that steers its own and sets `camera.current` itself.
                if (!config.own_camera) try game.engine.addPlugin(switch (config.view) {
                    .three => camera.plugin,
                    .two => camera2d.plugin,
                });
                return game;
            }

            /// A plugin of the game's own, run after the standard ones each frame.
            pub fn add(game: *Game, plugin: W.Plugin) !void {
                try game.engine.addPlugin(plugin);
            }

            /// A draw inside the scene: through the eye, lit, after the models.
            pub fn drawInScene(_: *Game, draw: W.System.Run) !void {
                try scene_draws.append(gpa, draw);
            }

            /// A draw inside the scene but out of the light: wire frames, gizmos, ghosts
            /// — lines and markers that want no shading. After the lit draws.
            pub fn drawUnlit(_: *Game, draw: W.System.Run) !void {
                try unlit_draws.append(gpa, draw);
            }

            /// A draw on the screen, over the readout.
            pub fn drawOnScreen(_: *Game, draw: W.System.Run) !void {
                try screen_draws.append(gpa, draw);
            }

            pub fn run(game: *Game) void {
                // Last of the updaters: a load lands late in the frame, so everything that
                // ran before it this frame ran on the old world and the draw sees the new one.
                game.engine.addPlugin(saves.plugin) catch @panic("out of memory");
                game.engine.addPlugin(renderPlugin) catch @panic("out of memory");
                game.engine.start() catch @panic("out of memory");
                // Every start picks up the save, if there is one, so the game goes on from
                // where it left off. A restart goes back to the last save the same way.
                saves.pickUp(&game.engine.world);
                while (true) {
                    game.engine.run(running);
                    if (!restarting) break;
                    restarting = false;
                    game.engine.restart() catch @panic("out of memory");
                    saves.pickUp(&game.engine.world);
                }
            }

            pub fn deinit(game: *Game) void {
                game.engine.deinit();
                scene_draws.deinit(gpa);
                unlit_draws.deinit(gpa);
                screen_draws.deinit(gpa);
                scene_draws = .empty;
                unlit_draws = .empty;
                screen_draws = .empty;
            }
        };
    };
}
