//! Sound, as a resource: `w.resource(Audio)` from anywhere. Clips are short sounds
//! loaded whole and played by path — loaded the first time they are asked for and
//! kept after — and music is one stream at a time, looping, fed a little each frame.
//! The device opens when the world starts and closes when it stops, with everything
//! loaded let go of first.
//!
//!     w.resource(Audio).play("assets/pop.wav");
//!     w.resource(Audio).playMusic("assets/theme.ogg");
//!
//! Playing goes on whether or not the world is held: a pause menu that wants quiet
//! calls `pauseMusic` and `resumeMusic` itself. A clip played again while it is still
//! going starts over; `playOver` lets it go on and starts another over the top.

const std = @import("std");
const rl = @import("raylib.zig").c;

pub const Audio = struct {
    gpa: std.mem.Allocator,
    /// Every clip loaded or added, by the path or name it was asked for.
    clips: std.StringHashMapUnmanaged(rl.Sound) = .empty,
    /// Copies of clips playing over the top of themselves, sharing the originals'
    /// data. Let go of at the end, with the originals.
    overs: std.ArrayList(rl.Sound) = .empty,
    /// The one stream, while there is one.
    music: ?rl.Music = null,
    /// What a stream starts at.
    music_volume: f32 = 0.8,

    /// How a clip is played: how loud, how fast, and where between the ears — minus
    /// one is the left, nought the middle, one the right.
    pub const Mix = struct {
        volume: f32 = 1,
        pitch: f32 = 1,
        pan: f32 = 0,
    };

    // ---- clips ----

    /// A clip by path, loaded the first time it is asked for and kept. Null if the
    /// file is not there, cannot be read, or the device is not up.
    pub fn clip(audio: *Audio, path: [:0]const u8) ?*rl.Sound {
        if (audio.clips.getPtr(path)) |found| return found;
        const loaded = rl.LoadSound(path.ptr);
        if (!rl.IsSoundValid(loaded)) return null;
        audio.add(path, loaded) catch {
            rl.UnloadSound(loaded);
            return null;
        };
        return audio.clips.getPtr(path);
    }

    /// Keeps a clip made elsewhere — from a wave, say — under a name, to be played by
    /// it and let go of with the rest. A name already taken has its clip let go of
    /// first.
    pub fn add(audio: *Audio, name: []const u8, sound: rl.Sound) !void {
        if (audio.clips.getPtr(name)) |old| {
            rl.UnloadSound(old.*);
            old.* = sound;
            return;
        }
        const owned = try audio.gpa.dupe(u8, name);
        errdefer audio.gpa.free(owned);
        try audio.clips.put(audio.gpa, owned, sound);
    }

    /// Lets one clip go, by name. Whether there was one.
    pub fn remove(audio: *Audio, name: []const u8) bool {
        const entry = audio.clips.fetchRemove(name) orelse return false;
        rl.UnloadSound(entry.value);
        audio.gpa.free(entry.key);
        return true;
    }

    /// Plays a clip from the start, as it is. Whether it played: false is a clip that
    /// could not be loaded.
    pub fn play(audio: *Audio, path: [:0]const u8) bool {
        return audio.playMixed(path, .{});
    }

    /// Plays a clip from the start at a volume, a pitch and a pan. The mix stays on
    /// the clip until it is set again.
    pub fn playMixed(audio: *Audio, path: [:0]const u8, mix: Mix) bool {
        const sound = audio.clip(path) orelse return false;
        tune(sound.*, mix);
        rl.PlaySound(sound.*);
        return true;
    }

    /// Plays a clip over the top of itself, if it is already going: a burst of the
    /// same sound, each left to finish. The copy shares the clip's data and is let go
    /// of at the end.
    pub fn playOver(audio: *Audio, path: [:0]const u8, mix: Mix) bool {
        const sound = audio.clip(path) orelse return false;
        if (!rl.IsSoundPlaying(sound.*)) {
            tune(sound.*, mix);
            rl.PlaySound(sound.*);
            return true;
        }
        // A copy that has stopped is reused before a new one is made.
        for (audio.overs.items) |over| {
            if (rl.IsSoundPlaying(over)) continue;
            tune(over, mix);
            rl.PlaySound(over);
            return true;
        }
        const over = rl.LoadSoundAlias(sound.*);
        audio.overs.append(audio.gpa, over) catch {
            rl.UnloadSoundAlias(over);
            return false;
        };
        tune(over, mix);
        rl.PlaySound(over);
        return true;
    }

    fn tune(sound: rl.Sound, mix: Mix) void {
        rl.SetSoundVolume(sound, mix.volume);
        rl.SetSoundPitch(sound, mix.pitch);
        rl.SetSoundPan(sound, mix.pan);
    }

    pub fn stop(audio: *Audio, path: [:0]const u8) void {
        const sound = audio.clips.getPtr(path) orelse return;
        rl.StopSound(sound.*);
    }

    pub fn playing(audio: *Audio, path: [:0]const u8) bool {
        const sound = audio.clips.getPtr(path) orelse return false;
        return rl.IsSoundPlaying(sound.*);
    }

    // ---- music ----

    /// Starts a stream from the top, looping, in place of whatever was playing. Whether
    /// it started: false is a file that could not be opened, and the old music stays.
    pub fn playMusic(audio: *Audio, path: [:0]const u8) bool {
        const stream = rl.LoadMusicStream(path.ptr);
        if (!rl.IsMusicValid(stream)) return false;
        audio.stopMusic();
        var looping = stream;
        looping.looping = true;
        rl.SetMusicVolume(looping, audio.music_volume);
        rl.PlayMusicStream(looping);
        audio.music = looping;
        return true;
    }

    /// The music gone, not merely held: `playMusic` again to have any.
    pub fn stopMusic(audio: *Audio) void {
        const stream = audio.music orelse return;
        rl.StopMusicStream(stream);
        rl.UnloadMusicStream(stream);
        audio.music = null;
    }

    pub fn pauseMusic(audio: *Audio) void {
        if (audio.music) |stream| rl.PauseMusicStream(stream);
    }

    pub fn resumeMusic(audio: *Audio) void {
        if (audio.music) |stream| rl.ResumeMusicStream(stream);
    }

    pub fn musicPlaying(audio: *const Audio) bool {
        const stream = audio.music orelse return false;
        return rl.IsMusicStreamPlaying(stream);
    }

    pub fn setMusicVolume(audio: *Audio, level: f32) void {
        if (audio.music) |stream| rl.SetMusicVolume(stream, level);
    }

    /// Seconds into the track, and seconds it runs. Nought and nought without one.
    pub fn musicTime(audio: *const Audio) struct { played: f32, length: f32 } {
        const stream = audio.music orelse return .{ .played = 0, .length = 0 };
        return .{ .played = rl.GetMusicTimePlayed(stream), .length = rl.GetMusicTimeLength(stream) };
    }

    // ---- the whole ----

    /// Everything at once, nought to one.
    pub fn setVolume(_: *Audio, level: f32) void {
        rl.SetMasterVolume(level);
    }

    pub fn volume(_: *const Audio) f32 {
        return rl.GetMasterVolume();
    }

    /// A stream is a buffer that runs dry: this tops it up. Once a frame.
    fn feed(audio: *Audio) void {
        if (audio.music) |stream| rl.UpdateMusicStream(stream);
    }

    /// Every clip, copy and stream let go of, and their names.
    fn unloadAll(audio: *Audio) void {
        audio.stopMusic();
        for (audio.overs.items) |over| rl.UnloadSoundAlias(over);
        audio.overs.deinit(audio.gpa);
        audio.overs = .empty;
        var entries = audio.clips.iterator();
        while (entries.next()) |entry| {
            rl.UnloadSound(entry.value_ptr.*);
            audio.gpa.free(entry.key_ptr.*);
        }
        audio.clips.deinit(audio.gpa);
        audio.clips = .empty;
    }
};

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;

        // ---- the systems ----

        fn open(w: *W) void {
            rl.InitAudioDevice();
            // No device — no sound card, a headless run — and raylib says so in the log; every
            // play after simply does nothing.
            if (rl.IsAudioDeviceReady()) rl.SetMasterVolume(config.master_volume);
            _ = w;
        }

        fn tick(w: *W) void {
            w.resource(Audio).feed();
        }

        fn close(w: *W) void {
            w.resource(Audio).unloadAll();
            if (rl.IsAudioDeviceReady()) rl.CloseAudioDevice();
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Audio{ .gpa = allocator, .music_volume = config.music_volume });
            // Held or not, the music plays on: what goes quiet in a pause is the game's to say.
            try w.addSystem(allocator, .{ .name = "audio", .always = true, .onStart = open, .onUpdate = tick, .onCleanup = close });
        }

        // ---- tests: zig build test ----

        test "clips by name: a missing file is nothing, a made one plays and stops" {
            // Opens a real sound device, which the test runner does not always get back
            // from: run when asked, with `test_audio = true` in config.
            if (!config.test_audio) return error.SkipZigTest;
            var w: W = .{};
            defer w.deinit(gpa);
            try w.addPlugin(gpa, plugin);
            w.start();
            defer w.stop();
            // Nowhere to play: nothing to test on this machine.
            if (!rl.IsAudioDeviceReady()) return error.SkipZigTest;

            const audio = w.resource(Audio);
            try std.testing.expect(!audio.play("no/such/file.wav"));
            try std.testing.expect(audio.clip("no/such/file.wav") == null);
            try std.testing.expect(!audio.playing("no/such/file.wav"));

            // A tenth of a second of a sine, made here rather than read from a file the
            // template does not ship.
            var samples: [4410]i16 = undefined;
            for (&samples, 0..) |*sample, i| {
                const t = @as(f32, @floatFromInt(i)) / 44100;
                sample.* = @intFromFloat(@sin(t * 440 * std.math.tau) * 12000);
            }
            const wave = rl.Wave{ .frameCount = samples.len, .sampleRate = 44100, .sampleSize = 16, .channels = 1, .data = &samples };
            try audio.add("beep", rl.LoadSoundFromWave(wave));
            try std.testing.expect(audio.clip("beep") != null);

            try std.testing.expect(audio.play("beep"));
            try std.testing.expect(audio.playing("beep"));
            // Over the top: a copy is made and kept for next time.
            try std.testing.expect(audio.playOver("beep", .{ .pitch = 1.5 }));
            try std.testing.expectEqual(@as(usize, 1), audio.overs.items.len);
            try std.testing.expect(audio.playOver("beep", .{}));
            try std.testing.expectEqual(@as(usize, 2), audio.overs.items.len);
            audio.stop("beep");
            try std.testing.expect(!audio.playing("beep"));

            // Adding under a taken name lets the old one go; removing takes the name back.
            try audio.add("beep", rl.LoadSoundFromWave(wave));
            try std.testing.expect(audio.remove("beep"));
            try std.testing.expect(!audio.remove("beep"));
            try std.testing.expect(!audio.playing("beep"));

            // No music: every music call is a quiet no.
            try std.testing.expect(!audio.playMusic("no/such/theme.ogg"));
            try std.testing.expect(!audio.musicPlaying());
            audio.pauseMusic();
            audio.resumeMusic();
            audio.stopMusic();
            try std.testing.expectEqual(@as(f32, 0), audio.musicTime().length);
        }
    };
}
