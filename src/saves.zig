//! The keys and the file. The engine does the work: on save every system writes what
//! it owns into the store under its own key, and on load every system reads its own
//! back — the store is only the bytes in between. This is the F5 and the F9 that move
//! those bytes to and from the disk, and the word on screen that says they did.

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

        var notice: [48:0]u8 = @splat(0);
        var notice_left: f32 = 0;

        pub fn save(w: *W) void {
            saveAs(w, config.save_path);
        }

        pub fn load(w: *W) void {
            loadFrom(w, config.save_path);
        }

        /// The same, to and from a path of the caller's choosing: for anything that
        /// keeps more than one file — an editor with levels, a game with slots.
        pub fn saveAs(w: *W, path: [*:0]const u8) void {
            var store: W.Store = .init(gpa);
            defer store.deinit();
            w.save(&store);

            const bytes = store.serialize() catch {
                say("could not build the save");
                return;
            };
            defer gpa.free(bytes);
            const written = rl.SaveFileData(path, bytes.ptr, @intCast(bytes.len));
            say(if (written) "saved" else "could not write the save");
        }

        pub fn loadFrom(w: *W, path: [*:0]const u8) void {
            var size: c_int = 0;
            const data = rl.LoadFileData(path, &size);
            if (data == null) {
                say("no save to load");
                return;
            }
            defer rl.UnloadFileData(data);

            var store = W.Store.parse(gpa, data[0..@intCast(size)]) catch |err| {
                say(switch (err) {
                    error.NotASave => "that is not a save",
                    error.OtherVersion => "save is from another build",
                    error.CutShort => "save is cut short",
                    error.OutOfMemory => "out of memory",
                });
                return;
            };
            defer store.deinit();
            w.load(&store);
            say("loaded");
        }

        /// Whether there is a save on the disk to pick up.
        pub fn exists() bool {
            return rl.FileExists(config.save_path);
        }

        /// The save gone, so the next start is a new world.
        pub fn discard() void {
            if (!rl.FileExists(config.save_path)) return;
            _ = rl.remove(config.save_path);
        }

        /// A fresh world becomes the saved one, if there is a save. Every start does this, so
        /// the game picks up where it left off — and a restart goes back to the last save
        /// rather than to a new world. No save, and the fresh world simply stands.
        pub fn pickUp(w: *W) void {
            if (!config.pick_up) return;
            if (!rl.FileExists(config.save_path)) return;
            load(w);
        }

        fn say(text: []const u8) void {
            notice = @splat(0);
            const len = @min(text.len, notice.len);
            @memcpy(notice[0..len], text[0..len]);
            notice_left = config.notice_time;
        }

        fn watch(w: *W) void {
            // The wall's seconds, not the world's: the word fades whether or not the world is held.
            notice_left = @max(notice_left - w.resource(Clock).real, 0);
            if (input.isActionPressed("save")) save(w);
            if (input.isActionPressed("load")) load(w);
        }

        /// A word at the top of the screen for a moment after a save or a load.
        pub fn draw(_: *W) void {
            if (notice_left <= 0) return;
            const wide = rl.MeasureText(&notice, config.hud_text_size);
            rl.DrawText(
                &notice,
                @divFloor(rl.GetScreenWidth() - wide, 2),
                config.hud_margin + 40,
                config.hud_text_size,
                rl.RAYWHITE,
            );
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            // Save and load answer while the world is held: a pause is when one saves.
            try w.addSystem(allocator, .{ .name = "saves", .always = true, .onUpdate = watch });
        }
    };
}
