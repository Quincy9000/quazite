//! Effects over the whole picture, after the world is drawn and before the readout:
//! a chain of passes the game adds to, each one a small shader run over the frame.
//!
//!     const fx = w.resource(effects.Effects);
//!     try fx.add(.{ .vignette = .{ .strength = 0.5 } });
//!     try fx.add(.{ .bloom = .{ .threshold = 0.7, .strength = 0.8 } });
//!     try fx.add(.{ .grade = .{ .saturation = 1.2 } });
//!     fx.get(.vignette).?.strength = 0.8;       // change one in place
//!     _ = fx.remove(.bloom);
//!
//! With the chain empty nothing happens and nothing costs; with anything in it the
//! scene is drawn into a texture first and the chain is run over that, in order, onto
//! the screen. `fade` is the one for transitions: tween its `amount` to nought or one.
//! The readout — everything drawn after `apply` — is never touched.

const std = @import("std");
const rl = @import("raylib.zig").c;

pub const Vignette = struct {
    /// How dark the corners go, nought to one.
    strength: f32 = 0.5,
    /// How far in from the corners the darkening starts, nought to one.
    softness: f32 = 0.6,
    color: rl.Vector3 = .{ .x = 0, .y = 0, .z = 0 },
};

pub const Grade = struct {
    /// Added to everything: minus one to one.
    brightness: f32 = 0,
    /// One as it is; more is punchier.
    contrast: f32 = 1,
    /// One as it is; nought is grey.
    saturation: f32 = 1,
    /// What everything is multiplied by.
    tint: rl.Vector3 = .{ .x = 1, .y = 1, .z = 1 },
};

/// The picture gone to a colour by `amount`: nought is the picture, one the colour.
pub const Fade = struct {
    color: rl.Vector3 = .{ .x = 0, .y = 0, .z = 0 },
    amount: f32 = 0,
};

pub const Pixelate = struct {
    /// Screen pixels to a block.
    size: f32 = 4,
};

pub const Grain = struct {
    strength: f32 = 0.1,
};

pub const Blur = struct {
    /// Pixels.
    radius: f32 = 4,
};

pub const Bloom = struct {
    /// How bright a spot has to be to bloom, nought to one.
    threshold: f32 = 0.7,
    strength: f32 = 0.6,
    /// Pixels.
    radius: f32 = 8,
};

pub const Effect = union(enum) {
    vignette: Vignette,
    grade: Grade,
    fade: Fade,
    pixelate: Pixelate,
    grain: Grain,
    blur: Blur,
    bloom: Bloom,
};

pub const Tag = std.meta.Tag(Effect);

pub const Effects = struct {
    gpa: std.mem.Allocator,
    chain: std.ArrayList(Effect) = .empty,

    // The plugin's own.
    shaders: Shaders = undefined,
    /// Three pictures the size of the screen: the scene, and two to pass it between.
    buffers: [3]rl.RenderTexture2D = undefined,
    width: c_int = 0,
    height: c_int = 0,
    /// Whether the scene is being drawn into the first buffer this frame.
    capturing: bool = false,

    /// One more pass, at the end of the chain.
    pub fn add(fx: *Effects, effect: Effect) !void {
        try fx.chain.append(fx.gpa, effect);
    }

    /// The first pass of a kind, to change: `fx.get(.vignette).?.strength = 1`. Good
    /// until the chain is added to or removed from.
    pub fn get(fx: *Effects, comptime tag: Tag) ?*std.meta.TagPayload(Effect, tag) {
        for (fx.chain.items) |*effect| {
            if (effect.* == tag) return &@field(effect.*, @tagName(tag));
        }
        return null;
    }

    pub fn has(fx: *const Effects, tag: Tag) bool {
        for (fx.chain.items) |effect| {
            if (effect == tag) return true;
        }
        return false;
    }

    /// The first pass of a kind taken out. Whether there was one.
    pub fn remove(fx: *Effects, tag: Tag) bool {
        for (fx.chain.items, 0..) |effect, i| {
            if (effect == tag) {
                _ = fx.chain.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn clear(fx: *Effects) void {
        fx.chain.clearRetainingCapacity();
    }

    pub fn count(fx: *const Effects) usize {
        return fx.chain.items.len;
    }
};

const Shaders = struct {
    vignette: Pass,
    grade: Pass,
    fade: Pass,
    pixelate: Pass,
    grain: Pass,
    blur: Pass,
    threshold: Pass,
    combine: Pass,
};

/// A fragment shader and where its knobs are.
const Pass = struct {
    shader: rl.Shader,
    a: c_int = -1,
    b: c_int = -1,
    c: c_int = -1,
    d: c_int = -1,

    fn load(fragment: [*:0]const u8, names: []const [*:0]const u8) Pass {
        var pass = Pass{ .shader = rl.LoadShaderFromMemory(null, fragment) };
        const slots = [_]*c_int{ &pass.a, &pass.b, &pass.c, &pass.d };
        for (names, 0..) |name, i| slots[i].* = rl.GetShaderLocation(pass.shader, name);
        return pass;
    }

    fn setFloat(pass: Pass, loc: c_int, value: f32) void {
        var v = value;
        rl.SetShaderValue(pass.shader, loc, &v, rl.SHADER_UNIFORM_FLOAT);
    }

    fn setVec2(pass: Pass, loc: c_int, value: [2]f32) void {
        var v = value;
        rl.SetShaderValue(pass.shader, loc, &v, rl.SHADER_UNIFORM_VEC2);
    }

    fn setVec3(pass: Pass, loc: c_int, value: rl.Vector3) void {
        var v = value;
        rl.SetShaderValue(pass.shader, loc, &v, rl.SHADER_UNIFORM_VEC3);
    }
};

const head =
    \\#version 330
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\out vec4 finalColor;
    \\
;

const vignette_fragment = head ++
    \\uniform float strength;
    \\uniform float softness;
    \\uniform vec3 color;
    \\void main() {
    \\    vec4 pic = texture(texture0, fragTexCoord);
    \\    float d = length(fragTexCoord - 0.5) * 1.4142;
    \\    float v = smoothstep(1.0 - softness, 1.0, d) * strength;
    \\    finalColor = vec4(mix(pic.rgb, color, v), pic.a);
    \\}
;

const grade_fragment = head ++
    \\uniform float brightness;
    \\uniform float contrast;
    \\uniform float saturation;
    \\uniform vec3 tint;
    \\void main() {
    \\    vec4 pic = texture(texture0, fragTexCoord);
    \\    vec3 c = pic.rgb * tint + brightness;
    \\    c = (c - 0.5) * contrast + 0.5;
    \\    float grey = dot(c, vec3(0.299, 0.587, 0.114));
    \\    c = mix(vec3(grey), c, saturation);
    \\    finalColor = vec4(clamp(c, 0.0, 1.0), pic.a);
    \\}
;

const fade_fragment = head ++
    \\uniform vec3 color;
    \\uniform float amount;
    \\void main() {
    \\    vec4 pic = texture(texture0, fragTexCoord);
    \\    finalColor = vec4(mix(pic.rgb, color, clamp(amount, 0.0, 1.0)), pic.a);
    \\}
;

const pixelate_fragment = head ++
    \\uniform vec2 resolution;
    \\uniform float size;
    \\void main() {
    \\    vec2 cell = max(size, 1.0) / resolution;
    \\    vec2 uv = (floor(fragTexCoord / cell) + 0.5) * cell;
    \\    finalColor = texture(texture0, uv);
    \\}
;

const grain_fragment = head ++
    \\uniform float strength;
    \\uniform float time;
    \\void main() {
    \\    vec4 pic = texture(texture0, fragTexCoord);
    \\    float n = fract(sin(dot(fragTexCoord * (time + 1.0), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
    \\    finalColor = vec4(clamp(pic.rgb + n * strength, 0.0, 1.0), pic.a);
    \\}
;

/// One direction of a gaussian blur: run once across, once down.
const blur_fragment = head ++
    \\uniform vec2 resolution;
    \\uniform vec2 direction;
    \\uniform float radius;
    \\void main() {
    \\    vec2 step = direction / resolution * (radius / 4.0);
    \\    vec3 sum = texture(texture0, fragTexCoord).rgb * 0.227027;
    \\    float weights[4] = float[](0.1945946, 0.1216216, 0.054054, 0.016216);
    \\    for (int i = 1; i <= 4; i++) {
    \\        vec2 off = step * float(i);
    \\        sum += texture(texture0, fragTexCoord + off).rgb * weights[i - 1];
    \\        sum += texture(texture0, fragTexCoord - off).rgb * weights[i - 1];
    \\    }
    \\    finalColor = vec4(sum, 1.0);
    \\}
;

const threshold_fragment = head ++
    \\uniform float threshold;
    \\void main() {
    \\    vec3 c = texture(texture0, fragTexCoord).rgb;
    \\    float bright = max(max(c.r, c.g), c.b);
    \\    float keep = smoothstep(threshold, 1.0, bright);
    \\    finalColor = vec4(c * keep, 1.0);
    \\}
;

const combine_fragment = head ++
    \\uniform sampler2D glow;
    \\uniform float strength;
    \\void main() {
    \\    vec4 pic = texture(texture0, fragTexCoord);
    \\    vec3 g = texture(glow, fragTexCoord).rgb;
    \\    finalColor = vec4(clamp(pic.rgb + g * strength, 0.0, 1.0), pic.a);
    \\}
;

/// The buffers the size of the screen, made again when the window is resized.
fn fit(fx: *Effects) void {
    const width = rl.GetScreenWidth();
    const height = rl.GetScreenHeight();
    if (width == fx.width and height == fx.height) return;
    for (&fx.buffers) |*buffer| {
        if (buffer.id != 0) rl.UnloadRenderTexture(buffer.*);
        buffer.* = rl.LoadRenderTexture(width, height);
    }
    fx.width = width;
    fx.height = height;
}

/// A blur across then down: from one buffer, through scratch, into another.
fn blur(fx: *Effects, from: usize, to: usize, scratch: usize, radius: f32, resolution: [2]f32) void {
    const pass = fx.shaders.blur;
    pass.setVec2(pass.a, resolution);
    pass.setFloat(pass.c, radius);
    pass.setVec2(pass.b, .{ 1, 0 });
    run(fx, pass, from, scratch);
    pass.setVec2(pass.b, .{ 0, 1 });
    run(fx, pass, scratch, to);
}

/// One pass: a buffer drawn into another through a shader. Between buffers the
/// picture keeps its orientation, so it is drawn as it is.
fn run(fx: *Effects, pass: Pass, from: usize, to: usize) void {
    const width: f32 = @floatFromInt(fx.width);
    const height: f32 = @floatFromInt(fx.height);
    rl.BeginTextureMode(fx.buffers[to]);
    rl.BeginShaderMode(pass.shader);
    rl.DrawTextureRec(fx.buffers[from].texture, .{ .x = 0, .y = 0, .width = width, .height = height }, .{ .x = 0, .y = 0 }, rl.WHITE);
    rl.EndShaderMode();
    rl.EndTextureMode();
}

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;

        // ---- the effects ----

        // ---- the resource ----

        // ---- the shaders: every one takes the picture as texture0 ----

        // ---- the systems ----

        fn load(w: *W) void {
            const fx = w.resource(Effects);
            fx.shaders = .{
                .vignette = Pass.load(vignette_fragment, &.{ "strength", "softness", "color" }),
                .grade = Pass.load(grade_fragment, &.{ "brightness", "contrast", "saturation", "tint" }),
                .fade = Pass.load(fade_fragment, &.{ "color", "amount" }),
                .pixelate = Pass.load(pixelate_fragment, &.{ "resolution", "size" }),
                .grain = Pass.load(grain_fragment, &.{ "strength", "time" }),
                .blur = Pass.load(blur_fragment, &.{ "resolution", "direction", "radius" }),
                .threshold = Pass.load(threshold_fragment, &.{"threshold"}),
                .combine = Pass.load(combine_fragment, &.{ "glow", "strength" }),
            };
            fx.width = 0;
            fx.height = 0;
            fx.capturing = false;
            fit(fx);
        }

        fn unload(w: *W) void {
            const fx = w.resource(Effects);
            inline for (std.meta.fields(Shaders)) |field| rl.UnloadShader(@field(fx.shaders, field.name).shader);
            for (&fx.buffers) |*buffer| {
                if (buffer.id != 0) rl.UnloadRenderTexture(buffer.*);
                buffer.* = std.mem.zeroes(rl.RenderTexture2D);
            }
            fx.width = 0;
            fx.height = 0;
            fx.chain.deinit(fx.gpa);
            fx.chain = .empty;
        }

        /// Turns the scene aside into a texture, if there is a chain to run over it. Right
        /// after the frame opens.
        pub fn begin(w: *W) void {
            const fx = w.resource(Effects);
            if (fx.chain.items.len == 0) return;
            fit(fx);
            rl.BeginTextureMode(fx.buffers[0]);
            rl.ClearBackground(config.sky);
            fx.capturing = true;
        }

        /// Runs the chain over the scene and puts the result on the screen. After the scene,
        /// before the readout.
        pub fn apply(w: *W) void {
            const fx = w.resource(Effects);
            if (!fx.capturing) return;
            rl.EndTextureMode();
            fx.capturing = false;

            const resolution = [2]f32{ @floatFromInt(fx.width), @floatFromInt(fx.height) };
            // The picture passes from one buffer to another, one pass at a time; the third
            // is scratch for the passes that need two pictures at once.
            var from: usize = 0;
            for (fx.chain.items) |effect| {
                const to: usize = if (from == 0) 1 else 0;
                switch (effect) {
                    .vignette => |v| {
                        const pass = fx.shaders.vignette;
                        pass.setFloat(pass.a, v.strength);
                        pass.setFloat(pass.b, v.softness);
                        pass.setVec3(pass.c, v.color);
                        run(fx, pass, from, to);
                    },
                    .grade => |g| {
                        const pass = fx.shaders.grade;
                        pass.setFloat(pass.a, g.brightness);
                        pass.setFloat(pass.b, g.contrast);
                        pass.setFloat(pass.c, g.saturation);
                        pass.setVec3(pass.d, g.tint);
                        run(fx, pass, from, to);
                    },
                    .fade => |f| {
                        const pass = fx.shaders.fade;
                        pass.setVec3(pass.a, f.color);
                        pass.setFloat(pass.b, f.amount);
                        run(fx, pass, from, to);
                    },
                    .pixelate => |p| {
                        const pass = fx.shaders.pixelate;
                        pass.setVec2(pass.a, resolution);
                        pass.setFloat(pass.b, p.size);
                        run(fx, pass, from, to);
                    },
                    .grain => |g| {
                        const pass = fx.shaders.grain;
                        pass.setFloat(pass.a, g.strength);
                        pass.setFloat(pass.b, @floatCast(rl.GetTime()));
                        run(fx, pass, from, to);
                    },
                    .blur => |b| {
                        blur(fx, from, to, 2, b.radius, resolution);
                    },
                    .bloom => |b| {
                        // The bright parts alone into scratch, blurred there and back, then
                        // laid over the picture.
                        const scratch = 2;
                        const pass = fx.shaders.threshold;
                        pass.setFloat(pass.a, b.threshold);
                        run(fx, pass, from, scratch);
                        blur(fx, scratch, to, scratch, b.radius, resolution);
                        const mixer = fx.shaders.combine;
                        mixer.setFloat(mixer.b, b.strength);
                        rl.SetShaderValueTexture(mixer.shader, mixer.a, fx.buffers[scratch].texture);
                        run(fx, mixer, from, to);
                    },
                }
                from = to;
            }

            // Onto the screen, the right way up: a render texture is stored upside down.
            const picture = fx.buffers[from].texture;
            rl.DrawTextureRec(picture, .{ .x = 0, .y = 0, .width = resolution[0], .height = -resolution[1] }, .{ .x = 0, .y = 0 }, rl.WHITE);
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Effects{ .gpa = allocator });
            try w.addSystem(allocator, .{ .name = "effects", .onStart = load, .onCleanup = unload });
        }
    };
}
