//! Light and shadow, for a 3D game. One shader lights every mesh drawn through
//! `mesh.zig`: a sun with a direction and a colour, a hemisphere fill (sky overhead,
//! ground beneath), fog with distance and a layer hugging the floor, up to sixteen
//! lamps that glow and fall off, and shadows — the world drawn once more each frame
//! from the sun into a depth map, which every lit fragment asks whether the sun could
//! see it. Meshes carry their normals, so any shape lights properly.
//!
//! All of it is one resource to set, at any time:
//!
//!     const light = w.resource(lighting.Lighting);
//!     light.sun_direction = .{ .x = -0.3, .y = -1, .z = 0.2 };
//!     light.sun_color = .{ .x = 1, .y = 0.6, .z = 0.4 };          // evening
//!     light.fog_density = 0.01;
//!
//! and a lamp is a component: `lamp: ?lighting.Lamp` on an entity, next to its
//! `position`, and the nearest sixteen to the eye light the scene. The shadow pass
//! draws every `Model`; a game that draws other things itself and wants them to cast
//! shadows draws them between `shadowBegin` and `shadowEnd` too.

const std = @import("std");
const rl = @import("raylib.zig").c;
const mesh = @import("mesh.zig");

pub const max_lamps = 16;

const map_slot: c_int = 10;

const light_near: f32 = 1;

/// A point of light on an entity: what colour it gives, how far it reaches, and how
/// much it wavers (nought for a steady electric light, a half for a fire).
pub const Lamp = struct {
    color: rl.Vector3 = .{ .x = 1, .y = 0.8, .z = 0.5 },
    reach: f32 = 8,
    flicker: f32 = 0,
};

pub const Lighting = struct {
    // ---- the customizer: set any of these, any time ----

    /// Which way the sun's light travels: from it, toward the ground. Any length.
    sun_direction: rl.Vector3 = .{ .x = -0.4, .y = -1, .z = -0.3 },
    /// Colours are red, green, blue, nought to one — or more, for a glare.
    sun_color: rl.Vector3 = .{ .x = 1.0, .y = 0.95, .z = 0.85 },
    /// What a face turned up gets from the sky, sun or no sun.
    sky_fill: rl.Vector3 = .{ .x = 0.40, .y = 0.45, .z = 0.55 },
    /// What a face turned down gets back from the ground.
    ground_fill: rl.Vector3 = .{ .x = 0.18, .y = 0.16, .z = 0.14 },
    fog_color: rl.Vector3 = .{ .x = 0.55, .y = 0.6, .z = 0.7 },
    /// Haze with distance: nought for none, a hundredth for a far horizon.
    fog_density: f32 = 0,
    /// A layer of fog on the floor: how thick at height nought, and how fast it thins
    /// going up. Nought for none.
    fog_floor: f32 = 0,
    fog_falloff: f32 = 0.1,
    shadows: bool = true,
    /// How dark a shadow is: nought is none, one is black.
    shadow_strength: f32 = 0.6,
    /// How far from the eye, in world units, the shadow map reaches: smaller is
    /// sharper.
    shadow_span: f32 = 40,
    /// How far a surface may stand off its own shadow, in world units, before it
    /// shadows itself: raise it if lit faces speckle, lower it if shadows detach.
    shadow_bias: f32 = 0.08,
    /// What every lamp is multiplied by: turn them up at night.
    lamp_scale: f32 = 1,

    // ---- the plugin's own ----

    shader: rl.Shader = undefined,
    depth_shader: rl.Shader = undefined,
    map: rl.RenderTexture2D = undefined,
    light_vp: rl.Matrix = undefined,
    light_far: f32 = 1,
    in_shadow_pass: bool = false,
    locs: Locations = undefined,
};

const Locations = struct {
    light_dir: c_int,
    light_color: c_int,
    sky_fill: c_int,
    ground_fill: c_int,
    eye: c_int,
    fog_color: c_int,
    fog_height: c_int,
    haze: c_int,
    light_vp: c_int,
    shadow_map: c_int,
    map_size: c_int,
    bias: c_int,
    strength: c_int,
    lamp_count: c_int,
    lamp_pos: c_int,
    lamp_tint: c_int,
    lamp_reach: c_int,
    lamp_scale: c_int,
};

const vertex =
    \\#version 330
    \\in vec3 vertexPosition;
    \\in vec2 vertexTexCoord;
    \\in vec3 vertexNormal;
    \\in vec4 vertexColor;
    \\uniform mat4 mvp;
    \\uniform mat4 matModel;
    \\uniform mat4 matNormal;
    \\out vec3 fragPosition;
    \\out vec2 fragTexCoord;
    \\out vec3 fragNormal;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragPosition = vec3(matModel * vec4(vertexPosition, 1.0));
    \\    fragTexCoord = vertexTexCoord;
    \\    fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
    \\    fragColor = vertexColor;
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const fragment =
    \\#version 330
    \\in vec3 fragPosition;
    \\in vec2 fragTexCoord;
    \\in vec3 fragNormal;
    \\in vec4 fragColor;
    \\uniform sampler2D texture0;
    \\uniform vec4 colDiffuse;
    \\uniform vec3 lightDir;
    \\uniform vec3 lightColor;
    \\uniform vec3 skyFill;
    \\uniform vec3 groundFill;
    \\uniform vec3 eye;
    \\uniform vec3 fogColor;
    \\uniform vec2 fogHeight;
    \\uniform float hazeDensity;
    \\uniform mat4 lightVP;
    \\uniform sampler2D shadowMap;
    \\uniform int shadowMapSize;
    \\uniform float shadowBias;
    \\uniform float shadowStrength;
    \\uniform int lampCount;
    \\uniform vec3 lampPos[16];
    \\uniform vec3 lampTint[16];
    \\uniform float lampReach[16];
    \\uniform float lampScale;
    \\out vec4 finalColor;
    \\void main() {
    \\    vec4 base = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    \\    vec3 normal = normalize(fragNormal);
    \\    float diffuse = max(dot(normal, -lightDir), 0.0);
    \\    float shadow = 1.0;
    \\    if (shadowStrength > 0.0) {
    \\        vec4 lp = lightVP * vec4(fragPosition, 1.0);
    \\        vec3 proj = lp.xyz / lp.w * 0.5 + 0.5;
    \\        if (proj.x > 0.0 && proj.x < 1.0 && proj.y > 0.0 && proj.y < 1.0 && proj.z < 1.0) {
    \\            float bias = shadowBias * (1.0 + 3.0 * (1.0 - diffuse));
    \\            float size = float(shadowMapSize);
    \\            vec2 spot = proj.xy * size - 0.5;
    \\            vec2 base2 = floor(spot);
    \\            vec2 f = spot - base2;
    \\            float lit = 0.0;
    \\            for (int x = -1; x <= 2; x++) {
    \\                float wx = (x == -1) ? 1.0 - f.x : (x == 2) ? f.x : 1.0;
    \\                for (int y = -1; y <= 2; y++) {
    \\                    float wy = (y == -1) ? 1.0 - f.y : (y == 2) ? f.y : 1.0;
    \\                    float d = texture(shadowMap, (base2 + vec2(x, y) + 0.5) / size).r;
    \\                    lit += wx * wy * ((proj.z - bias > d) ? 0.0 : 1.0);
    \\                }
    \\            }
    \\            shadow = mix(1.0, lit / 9.0, shadowStrength);
    \\        }
    \\    }
    \\    vec3 light = mix(groundFill, skyFill, normal.y * 0.5 + 0.5) + lightColor * diffuse * shadow;
    \\    vec3 glow = vec3(0.0);
    \\    for (int i = 0; i < lampCount; i++) {
    \\        float f = clamp(1.0 - distance(fragPosition, lampPos[i]) / lampReach[i], 0.0, 1.0);
    \\        glow += lampTint[i] * f * f;
    \\    }
    \\    vec3 shaded = base.rgb * (light + glow * lampScale);
    \\    vec3 ray = fragPosition - eye;
    \\    float span = length(ray);
    \\    float depth;
    \\    if (abs(ray.y) > 0.01)
    \\        depth = fogHeight.x / fogHeight.y
    \\              * (exp(-eye.y * fogHeight.y) - exp(-(eye.y + ray.y) * fogHeight.y))
    \\              * span / ray.y;
    \\    else
    \\        depth = fogHeight.x * exp(-eye.y * fogHeight.y) * span;
    \\    float haze = span * hazeDensity;
    \\    float fog = clamp(1.0 - exp(-depth - haze * haze), 0.0, 1.0);
    \\    finalColor = vec4(mix(shaded, fogColor, fog), base.a);
    \\}
;

const depth_vertex =
    \\#version 330
    \\in vec3 vertexPosition;
    \\uniform mat4 mvp;
    \\void main() {
    \\    gl_Position = mvp * vec4(vertexPosition, 1.0);
    \\}
;

const depth_fragment =
    \\#version 330
    \\void main() {}
;

/// A render target with a depth texture and nothing else: what a shadow map is.
fn depthTarget(size: c_int) rl.RenderTexture2D {
    var target = std.mem.zeroes(rl.RenderTexture2D);
    target.id = rl.rlLoadFramebuffer();
    target.texture.width = size;
    target.texture.height = size;
    if (target.id > 0) {
        rl.rlEnableFramebuffer(target.id);
        target.depth.id = rl.rlLoadTextureDepth(size, size, false);
        target.depth.width = size;
        target.depth.height = size;
        target.depth.format = 19;
        target.depth.mipmaps = 1;
        rl.rlFramebufferAttach(target.id, target.depth.id, rl.RL_ATTACHMENT_DEPTH, rl.RL_ATTACHMENT_TEXTURE2D, 0);
        if (!rl.rlFramebufferComplete(target.id)) rl.TraceLog(rl.LOG_WARNING, "shadow map: framebuffer incomplete");
        rl.rlDisableFramebuffer();
    }
    return target;
}

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;
        const camera = @import("camera.zig").Module(Spec);
        const meshes = mesh.Module(Spec);

        // ---- the shaders ----

        // ---- the systems ----

        fn load(w: *W) void {
            const l = w.resource(Lighting);
            l.shader = rl.LoadShaderFromMemory(vertex, fragment);
            l.depth_shader = rl.LoadShaderFromMemory(depth_vertex, depth_fragment);
            l.locs = .{
                .light_dir = rl.GetShaderLocation(l.shader, "lightDir"),
                .light_color = rl.GetShaderLocation(l.shader, "lightColor"),
                .sky_fill = rl.GetShaderLocation(l.shader, "skyFill"),
                .ground_fill = rl.GetShaderLocation(l.shader, "groundFill"),
                .eye = rl.GetShaderLocation(l.shader, "eye"),
                .fog_color = rl.GetShaderLocation(l.shader, "fogColor"),
                .fog_height = rl.GetShaderLocation(l.shader, "fogHeight"),
                .haze = rl.GetShaderLocation(l.shader, "hazeDensity"),
                .light_vp = rl.GetShaderLocation(l.shader, "lightVP"),
                .shadow_map = rl.GetShaderLocation(l.shader, "shadowMap"),
                .map_size = rl.GetShaderLocation(l.shader, "shadowMapSize"),
                .bias = rl.GetShaderLocation(l.shader, "shadowBias"),
                .strength = rl.GetShaderLocation(l.shader, "shadowStrength"),
                .lamp_count = rl.GetShaderLocation(l.shader, "lampCount"),
                .lamp_pos = rl.GetShaderLocation(l.shader, "lampPos"),
                .lamp_tint = rl.GetShaderLocation(l.shader, "lampTint"),
                .lamp_reach = rl.GetShaderLocation(l.shader, "lampReach"),
                .lamp_scale = rl.GetShaderLocation(l.shader, "lampScale"),
            };
            l.map = depthTarget(config.shadow_size);
            var size: c_int = config.shadow_size;
            rl.SetShaderValue(l.shader, l.locs.map_size, &size, rl.SHADER_UNIFORM_INT);
            l.light_vp = rl.MatrixIdentity();
            l.in_shadow_pass = false;

            // Every mesh draws lit from here on, and none bakes its own light.
            mesh.shader = l.shader;
            mesh.lit = true;
        }

        fn unload(w: *W) void {
            const l = w.resource(Lighting);
            mesh.shader = null;
            mesh.lit = false;
            rl.UnloadShader(l.shader);
            rl.UnloadShader(l.depth_shader);
            // The framebuffer takes its depth texture down with it.
            rl.rlUnloadFramebuffer(l.map.id);
            l.map = std.mem.zeroes(rl.RenderTexture2D);
        }

        /// Where the shadow map is centred: the eye.
        fn focus() rl.Vector3 {
            return camera.current.position;
        }

        // ---- the passes ----

        /// Begins the shadow pass, and says whether there is one: the world about the eye
        /// seen from the sun, orthographic, into the depth map. Everything drawn between this
        /// and `shadowEnd` casts a shadow; every mesh draws wearing the depth shader.
        pub fn shadowBegin(w: *W) bool {
            const l = w.resource(Lighting);
            if (!l.shadows or l.shadow_strength <= 0) return false;

            const direction = rl.Vector3Normalize(l.sun_direction);
            const span = l.shadow_span;
            const back = span * 4;
            l.light_far = back * 2;
            var bias: f32 = l.shadow_bias / (l.light_far - light_near);
            rl.SetShaderValue(l.shader, l.locs.bias, &bias, rl.SHADER_UNIFORM_FLOAT);

            // Any up will do for an orthographic light, as long as it is not the direction.
            const up: rl.Vector3 = if (@abs(direction.y) > 0.99) .{ .x = 1, .y = 0, .z = 0 } else .{ .x = 0, .y = 1, .z = 0 };
            const at = focus();
            const light_camera = rl.Camera3D{
                .position = rl.Vector3Subtract(at, rl.Vector3Scale(direction, back)),
                .target = at,
                .up = up,
                .fovy = span * 2,
                .projection = rl.CAMERA_ORTHOGRAPHIC,
            };

            l.in_shadow_pass = true;
            mesh.shader = l.depth_shader;

            // The map is about to be drawn into: off the slot it is sampled from.
            rl.rlActiveTextureSlot(map_slot);
            rl.rlDisableTexture();
            rl.rlActiveTextureSlot(0);

            rl.rlSetClipPlanes(light_near, l.light_far);
            rl.BeginTextureMode(l.map);
            rl.ClearBackground(rl.WHITE);
            rl.BeginMode3D(light_camera);
            rl.BeginShaderMode(l.depth_shader);
            l.light_vp = rl.MatrixMultiply(rl.rlGetMatrixModelview(), rl.rlGetMatrixProjection());
            return true;
        }

        pub fn shadowEnd(w: *W) void {
            const l = w.resource(Lighting);
            rl.EndShaderMode();
            rl.EndMode3D();
            rl.EndTextureMode();
            rl.rlSetClipPlanes(config.near_plane, config.far_plane);
            mesh.shader = l.shader;
            l.in_shadow_pass = false;
        }

        /// The shadow pass over every `Model`, as a draw system: before the scene.
        pub fn shadowPass(w: *W) void {
            if (!shadowBegin(w)) return;
            meshes.drawModels(w);
            shadowEnd(w);
        }

        /// Hands the shader the light as it is now and puts the shader on: everything drawn
        /// until `end` is lit. Inside the scene's pass, before the models.
        pub fn begin(w: *W) void {
            const l = w.resource(Lighting);
            var direction = rl.Vector3Normalize(l.sun_direction);
            rl.SetShaderValue(l.shader, l.locs.light_dir, &direction, rl.SHADER_UNIFORM_VEC3);
            var color = l.sun_color;
            rl.SetShaderValue(l.shader, l.locs.light_color, &color, rl.SHADER_UNIFORM_VEC3);
            var sky = l.sky_fill;
            rl.SetShaderValue(l.shader, l.locs.sky_fill, &sky, rl.SHADER_UNIFORM_VEC3);
            var ground = l.ground_fill;
            rl.SetShaderValue(l.shader, l.locs.ground_fill, &ground, rl.SHADER_UNIFORM_VEC3);
            var fog = l.fog_color;
            rl.SetShaderValue(l.shader, l.locs.fog_color, &fog, rl.SHADER_UNIFORM_VEC3);
            var fog_height = [2]f32{ l.fog_floor, @max(l.fog_falloff, 1e-4) };
            rl.SetShaderValue(l.shader, l.locs.fog_height, &fog_height, rl.SHADER_UNIFORM_VEC2);
            var haze = l.fog_density;
            rl.SetShaderValue(l.shader, l.locs.haze, &haze, rl.SHADER_UNIFORM_FLOAT);
            var eye = camera.current.position;
            rl.SetShaderValue(l.shader, l.locs.eye, &eye, rl.SHADER_UNIFORM_VEC3);
            var strength: f32 = if (l.shadows) l.shadow_strength else 0;
            rl.SetShaderValue(l.shader, l.locs.strength, &strength, rl.SHADER_UNIFORM_FLOAT);
            rl.SetShaderValueMatrix(l.shader, l.locs.light_vp, l.light_vp);
            lamps(w);

            // The depth map on its own slot; the shader reads it from there all frame.
            rl.rlEnableShader(l.shader.id);
            var slot: c_int = map_slot;
            rl.rlActiveTextureSlot(slot);
            rl.rlEnableTexture(l.map.depth.id);
            rl.rlSetUniform(l.locs.shadow_map, &slot, rl.SHADER_UNIFORM_INT, 1);
            rl.rlActiveTextureSlot(0);

            rl.BeginShaderMode(l.shader);
        }

        /// Takes the light off: what draws after this is unlit, unshadowed and unfogged.
        pub fn end(_: *W) void {
            rl.EndShaderMode();
        }

        // ---- the lamps ----

        const Near = struct { at: rl.Vector3, lamp: Lamp, away: f32 };

        fn lamps(w: *W) void {
            const l = w.resource(Lighting);
            const eye = focus();
            var nearest: [max_lamps]Near = undefined;
            var count: usize = 0;
            inline for (comptime components.fieldsOf(Lamp)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const lamp = @field(entity, @tagName(field));
                    offer(&nearest, &count, .{ .at = entity.position.*, .lamp = lamp.*, .away = rl.Vector3Distance(entity.position.*, eye) });
                }
            }

            var positions: [max_lamps]rl.Vector3 = undefined;
            var tints: [max_lamps]rl.Vector3 = undefined;
            var reaches: [max_lamps]f32 = undefined;
            const time: f32 = @floatCast(rl.GetTime());
            for (nearest[0..count], 0..) |near, i| {
                positions[i] = near.at;
                const waver = 1 - near.lamp.flicker * (0.5 - 0.35 * @sin(time * 7 + near.at.x * 0.1) - 0.15 * @sin(time * 11.3 + near.at.z * 0.1));
                tints[i] = rl.Vector3Scale(near.lamp.color, waver);
                reaches[i] = @max(near.lamp.reach, 0.01);
            }
            var lit: c_int = @intCast(count);
            rl.SetShaderValue(l.shader, l.locs.lamp_count, &lit, rl.SHADER_UNIFORM_INT);
            if (count > 0) {
                rl.SetShaderValueV(l.shader, l.locs.lamp_pos, &positions, rl.SHADER_UNIFORM_VEC3, lit);
                rl.SetShaderValueV(l.shader, l.locs.lamp_tint, &tints, rl.SHADER_UNIFORM_VEC3, lit);
                rl.SetShaderValueV(l.shader, l.locs.lamp_reach, &reaches, rl.SHADER_UNIFORM_FLOAT, lit);
            }
            var scale = l.lamp_scale;
            rl.SetShaderValue(l.shader, l.locs.lamp_scale, &scale, rl.SHADER_UNIFORM_FLOAT);
        }

        /// Keeps the nearest lamps, sorted, dropping the furthest off the end.
        fn offer(nearest: *[max_lamps]Near, count: *usize, near: Near) void {
            var at = count.*;
            while (at > 0 and nearest[at - 1].away > near.away) : (at -= 1) {
                if (at < nearest.len) nearest[at] = nearest[at - 1];
            }
            if (at < nearest.len) {
                nearest[at] = near;
                if (count.* < nearest.len) count.* += 1;
            }
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Lighting{});
            // After the meshes, whose material it lends its shader to.
            try w.addSystem(allocator, .{ .name = "lighting", .onStart = load, .onCleanup = unload });
        }
    };
}
