//! Noise: a field of numbers asked for by coordinate, the same for the same seed, so
//! one seed is one world down to the last hill. Set it up once, then ask anywhere:
//!
//!     const hills = noise.Noise.init(.{ .kind = .perlin, .seed = 7, .scale = 40, .octaves = 4 });
//!     const height = hills.between(x, z, 0, 12);
//!
//! `scale` is how wide a feature is in world units; `octaves` pile finer detail on top,
//! each `lacunarity` times finer and `persistence` times fainter; `fractal` shapes the
//! pile — plain hills, ridged mountains, turbulent clouds. Every kind answers in
//! minus one to one before `amplitude`; `unit` and `between` remap that.
//!
//! The kinds: `perlin` (gradients on a lattice, the classic — smooth, a little grid-
//! aligned), `simplex` (the same idea on triangles, without the grid look), `value`
//! (random values on a lattice, blended: softer, blobbier), `cellular` (distance to
//! the nearest of scattered points: cells, scales, cracks) and `white` (a random
//! number per cell, no blending at all).

const std = @import("std");

pub const Kind = enum { perlin, simplex, value, cellular, white };

/// How the octaves are shaped before they are summed.
pub const Fractal = enum {
    /// As they come: rolling.
    plain,
    /// Folded about nought and turned over, so the crests are sharp: mountains.
    ridged,
    /// Folded about nought: billows, clouds, marble.
    turbulent,
};

pub const Options = struct {
    kind: Kind = .perlin,
    seed: u64 = 0,
    /// World units across one feature.
    scale: f32 = 1,
    octaves: u8 = 1,
    /// How much fainter each octave is than the one before.
    persistence: f32 = 0.5,
    /// How much finer each octave is than the one before.
    lacunarity: f32 = 2,
    fractal: Fractal = .plain,
    /// What the minus-one-to-one answer is multiplied by.
    amplitude: f32 = 1,
    /// Added to every coordinate asked for: the same seed, elsewhere.
    offset: [3]f32 = .{ 0, 0, 0 },
};

const table_size = 256;
const wrap = table_size - 1;

pub const Noise = struct {
    options: Options,
    /// A shuffled 0..255, stored twice so neighbour lookups never need a bounds check.
    permutation: [table_size * 2]u8,

    pub fn init(options: Options) Noise {
        var permutation: [table_size * 2]u8 = undefined;
        for (permutation[0..table_size], 0..) |*value, i| value.* = @intCast(i);
        var prng: std.Random.DefaultPrng = .init(options.seed);
        prng.random().shuffle(u8, permutation[0..table_size]);
        @memcpy(permutation[table_size..], permutation[0..table_size]);
        return .{ .options = options, .permutation = permutation };
    }

    // ---- asking ----

    /// The field at a point, minus one to one times the amplitude.
    pub fn at(n: *const Noise, x: f32, y: f32) f32 {
        return n.sum(x + n.options.offset[0], y + n.options.offset[1], null);
    }

    /// The same in three dimensions: caves, clouds, a world that changes with height.
    /// Simplex has no third dimension here and answers as perlin.
    pub fn at3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        return n.sum(x + n.options.offset[0], y + n.options.offset[1], z + n.options.offset[2]);
    }

    /// Nought to one.
    pub fn unit(n: *const Noise, x: f32, y: f32) f32 {
        return std.math.clamp((n.at(x, y) / n.options.amplitude + 1) / 2, 0, 1);
    }

    pub fn unit3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        return std.math.clamp((n.at3(x, y, z) / n.options.amplitude + 1) / 2, 0, 1);
    }

    /// Between two values: a height, a temperature, a chance.
    pub fn between(n: *const Noise, x: f32, y: f32, low: f32, high: f32) f32 {
        return low + (high - low) * n.unit(x, y);
    }

    /// Whether the field is above a line at a point, nought to one: a tree here or
    /// not, rock or air.
    pub fn above(n: *const Noise, x: f32, y: f32, line: f32) bool {
        return n.unit(x, y) > line;
    }

    // ---- the octaves ----

    fn sum(n: *const Noise, x: f32, y: f32, z: ?f32) f32 {
        const o = n.options;
        var total: f32 = 0;
        var strongest: f32 = 0;
        var frequency: f32 = 1 / @max(o.scale, 1e-6);
        var amplitude: f32 = 1;
        for (0..@max(o.octaves, 1)) |_| {
            const raw = if (z) |depth| n.raw3(x * frequency, y * frequency, depth * frequency) else n.raw2(x * frequency, y * frequency);
            const shaped = switch (o.fractal) {
                .plain => raw,
                .turbulent => @abs(raw) * 2 - 1,
                .ridged => blk: {
                    const ridge = 1 - @abs(raw);
                    break :blk ridge * ridge * 2 - 1;
                },
            };
            total += shaped * amplitude;
            strongest += amplitude;
            frequency *= o.lacunarity;
            amplitude *= o.persistence;
        }
        return total / strongest * o.amplitude;
    }

    fn raw2(n: *const Noise, x: f32, y: f32) f32 {
        return switch (n.options.kind) {
            .perlin => n.perlin2(x, y),
            .simplex => n.simplex2(x, y),
            .value => n.value2(x, y),
            .cellular => n.cellular2(x, y),
            .white => n.white2(x, y),
        };
    }

    fn raw3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        return switch (n.options.kind) {
            .perlin, .simplex => n.perlin3(x, y, z),
            .value => n.value3(x, y, z),
            .cellular => n.cellular3(x, y, z),
            .white => n.white3(x, y, z),
        };
    }

    // ---- the lattice ----

    /// A number for a cell, the same every time: the table walked once per axis.
    fn hash2(n: *const Noise, x: i32, y: i32) u8 {
        return n.permutation[@as(usize, n.permutation[@intCast(x & wrap)]) + @as(usize, @intCast(y & wrap))];
    }

    fn hash3(n: *const Noise, x: i32, y: i32, z: i32) u8 {
        const xy = n.permutation[@as(usize, n.permutation[@intCast(x & wrap)]) + @as(usize, @intCast(y & wrap))];
        return n.permutation[@as(usize, xy) + @as(usize, @intCast(z & wrap))];
    }

    // ---- perlin ----

    fn perlin2(n: *const Noise, x: f32, y: f32) f32 {
        const cell_x = cell(x);
        const cell_y = cell(y);
        const fx = x - @floor(x);
        const fy = y - @floor(y);
        const u = fade(fx);
        const v = fade(fy);
        return lerp(
            lerp(gradient2(n.hash2(cell_x, cell_y), fx, fy), gradient2(n.hash2(cell_x + 1, cell_y), fx - 1, fy), u),
            lerp(gradient2(n.hash2(cell_x, cell_y + 1), fx, fy - 1), gradient2(n.hash2(cell_x + 1, cell_y + 1), fx - 1, fy - 1), u),
            v,
        );
    }

    fn perlin3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        const cx = cell(x);
        const cy = cell(y);
        const cz = cell(z);
        const fx = x - @floor(x);
        const fy = y - @floor(y);
        const fz = z - @floor(z);
        const u = fade(fx);
        const v = fade(fy);
        const w = fade(fz);
        const g = struct {
            fn at(nn: *const Noise, ix: i32, iy: i32, iz: i32, dx: f32, dy: f32, dz: f32) f32 {
                return gradient3(nn.hash3(ix, iy, iz), dx, dy, dz);
            }
        };
        return lerp(
            lerp(
                lerp(g.at(n, cx, cy, cz, fx, fy, fz), g.at(n, cx + 1, cy, cz, fx - 1, fy, fz), u),
                lerp(g.at(n, cx, cy + 1, cz, fx, fy - 1, fz), g.at(n, cx + 1, cy + 1, cz, fx - 1, fy - 1, fz), u),
                v,
            ),
            lerp(
                lerp(g.at(n, cx, cy, cz + 1, fx, fy, fz - 1), g.at(n, cx + 1, cy, cz + 1, fx - 1, fy, fz - 1), u),
                lerp(g.at(n, cx, cy + 1, cz + 1, fx, fy - 1, fz - 1), g.at(n, cx + 1, cy + 1, cz + 1, fx - 1, fy - 1, fz - 1), u),
                v,
            ),
            w,
        );
    }

    // ---- simplex ----

    /// Gustavson's 2D simplex: the plane cut into triangles rather than squares.
    fn simplex2(n: *const Noise, x: f32, y: f32) f32 {
        const skew: f32 = 0.5 * (@sqrt(3.0) - 1.0);
        const unskew: f32 = (3.0 - @sqrt(3.0)) / 6.0;
        const s = (x + y) * skew;
        const i = @floor(x + s);
        const j = @floor(y + s);
        const t = (i + j) * unskew;
        const x0 = x - (i - t);
        const y0 = y - (j - t);
        // Which of the cell's two triangles: the lower-right or the upper-left.
        const step_i: f32 = if (x0 > y0) 1 else 0;
        const step_j: f32 = if (x0 > y0) 0 else 1;
        const x1 = x0 - step_i + unskew;
        const y1 = y0 - step_j + unskew;
        const x2 = x0 - 1 + 2 * unskew;
        const y2 = y0 - 1 + 2 * unskew;
        const ci: i32 = @intFromFloat(i);
        const cj: i32 = @intFromFloat(j);
        const corner0 = simplexCorner(n.hash2(ci, cj), x0, y0);
        const corner1 = simplexCorner(n.hash2(ci + @as(i32, @intFromFloat(step_i)), cj + @as(i32, @intFromFloat(step_j))), x1, y1);
        const corner2 = simplexCorner(n.hash2(ci + 1, cj + 1), x2, y2);
        // Scaled so the answer fills minus one to one.
        return 70 * (corner0 + corner1 + corner2);
    }

    fn simplexCorner(hash: u8, x: f32, y: f32) f32 {
        var t = 0.5 - x * x - y * y;
        if (t < 0) return 0;
        t *= t;
        return t * t * gradient2(hash, x, y);
    }

    // ---- value ----

    fn value2(n: *const Noise, x: f32, y: f32) f32 {
        const cx = cell(x);
        const cy = cell(y);
        const u = fade(x - @floor(x));
        const v = fade(y - @floor(y));
        return lerp(
            lerp(signed(n.hash2(cx, cy)), signed(n.hash2(cx + 1, cy)), u),
            lerp(signed(n.hash2(cx, cy + 1)), signed(n.hash2(cx + 1, cy + 1)), u),
            v,
        );
    }

    fn value3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        const cx = cell(x);
        const cy = cell(y);
        const cz = cell(z);
        const u = fade(x - @floor(x));
        const v = fade(y - @floor(y));
        const w = fade(z - @floor(z));
        return lerp(
            lerp(
                lerp(signed(n.hash3(cx, cy, cz)), signed(n.hash3(cx + 1, cy, cz)), u),
                lerp(signed(n.hash3(cx, cy + 1, cz)), signed(n.hash3(cx + 1, cy + 1, cz)), u),
                v,
            ),
            lerp(
                lerp(signed(n.hash3(cx, cy, cz + 1)), signed(n.hash3(cx + 1, cy, cz + 1)), u),
                lerp(signed(n.hash3(cx, cy + 1, cz + 1)), signed(n.hash3(cx + 1, cy + 1, cz + 1)), u),
                v,
            ),
            w,
        );
    }

    // ---- cellular ----

    /// How far to the nearest of one scattered point per cell: nought on a point,
    /// one about as far as it gets. Mapped to minus one to one like the rest.
    fn cellular2(n: *const Noise, x: f32, y: f32) f32 {
        const cx = cell(x);
        const cy = cell(y);
        var nearest: f32 = 4;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const ix = cx + dx;
                const iy = cy + dy;
                const px = @as(f32, @floatFromInt(ix)) + unsigned(n.hash2(ix, iy));
                const py = @as(f32, @floatFromInt(iy)) + unsigned(n.hash2(ix + 131, iy + 71));
                const d = (px - x) * (px - x) + (py - y) * (py - y);
                nearest = @min(nearest, d);
            }
        }
        return std.math.clamp(@sqrt(nearest), 0, 1) * 2 - 1;
    }

    fn cellular3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        const cx = cell(x);
        const cy = cell(y);
        const cz = cell(z);
        var nearest: f32 = 4;
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const ix = cx + dx;
                    const iy = cy + dy;
                    const iz = cz + dz;
                    const px = @as(f32, @floatFromInt(ix)) + unsigned(n.hash3(ix, iy, iz));
                    const py = @as(f32, @floatFromInt(iy)) + unsigned(n.hash3(ix + 131, iy + 71, iz + 29));
                    const pz = @as(f32, @floatFromInt(iz)) + unsigned(n.hash3(ix + 17, iy + 193, iz + 83));
                    const d = (px - x) * (px - x) + (py - y) * (py - y) + (pz - z) * (pz - z);
                    nearest = @min(nearest, d);
                }
            }
        }
        return std.math.clamp(@sqrt(nearest), 0, 1) * 2 - 1;
    }

    // ---- white ----

    fn white2(n: *const Noise, x: f32, y: f32) f32 {
        return signed(n.hash2(cell(x), cell(y)));
    }

    fn white3(n: *const Noise, x: f32, y: f32, z: f32) f32 {
        return signed(n.hash3(cell(x), cell(y), cell(z)));
    }
};

// ---- the pieces ----

/// Nought to one, stretched away from the middle: octaves average toward a half, and
/// this gives the whole range back.
pub fn contrast(value: f32, amount: f32) f32 {
    return std.math.clamp((value - 0.5) * amount + 0.5, 0, 1);
}

/// The cell a coordinate falls in.
fn cell(value: f32) i32 {
    return @intFromFloat(@floor(value));
}

/// A hash as minus one to one.
fn signed(hash: u8) f32 {
    return @as(f32, @floatFromInt(hash)) / 127.5 - 1;
}

/// A hash as nought to one.
fn unsigned(hash: u8) f32 {
    return @as(f32, @floatFromInt(hash)) / 255;
}

/// Perlin's 6t^5 - 15t^4 + 10t^3, flat at both ends so cells blend seamlessly.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}

/// The offset dotted with one of eight directions picked by the hash.
fn gradient2(hash: u8, x: f32, y: f32) f32 {
    return switch (@as(u3, @truncate(hash))) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x,
        5 => -x,
        6 => y,
        7 => -y,
    };
}

/// The offset dotted with one of Perlin's twelve edge directions.
fn gradient3(hash: u8, x: f32, y: f32, z: f32) f32 {
    return switch (@as(u4, @truncate(hash))) {
        0, 12 => x + y,
        1, 13 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x + z,
        5 => -x + z,
        6 => x - z,
        7 => -x - z,
        8 => y + z,
        9, 14 => -y + z,
        10 => y - z,
        11, 15 => -y - z,
    };
}

// ---- tests: zig build test ----

test "the same seed is the same field; a different one is not" {
    const a = Noise.init(.{ .seed = 1, .scale = 10 });
    const b = Noise.init(.{ .seed = 1, .scale = 10 });
    const c = Noise.init(.{ .seed = 2, .scale = 10 });
    try std.testing.expectEqual(a.at(3.7, 8.2), b.at(3.7, 8.2));
    try std.testing.expect(a.at(3.7, 8.2) != c.at(3.7, 8.2));
}

test "every kind stays in range and is not flat" {
    inline for (.{ .perlin, .simplex, .value, .cellular, .white }) |kind| {
        inline for (.{ .plain, .ridged, .turbulent }) |shape| {
            const n = Noise.init(.{ .kind = kind, .fractal = shape, .seed = 3, .scale = 7, .octaves = 3 });
            var lowest: f32 = 1;
            var highest: f32 = -1;
            var i: f32 = 0;
            while (i < 200) : (i += 1) {
                const v = n.at(i * 1.3, i * 0.7);
                const v3 = n.at3(i * 1.3, i * 0.7, i * 0.4);
                try std.testing.expect(v >= -1 and v <= 1);
                try std.testing.expect(v3 >= -1 and v3 <= 1);
                try std.testing.expect(n.unit(i, i) >= 0 and n.unit(i, i) <= 1);
                lowest = @min(lowest, v);
                highest = @max(highest, v);
            }
            try std.testing.expect(highest - lowest > 0.2);
        }
    }
}

test "perlin is nought on the lattice, between lets a height be asked for" {
    const n = Noise.init(.{ .kind = .perlin, .seed = 9 });
    try std.testing.expectEqual(@as(f32, 0), n.at(4, 7));
    const hills = Noise.init(.{ .seed = 9, .scale = 20, .octaves = 4, .amplitude = 3 });
    const h = hills.between(12.5, 3.25, 10, 20);
    try std.testing.expect(h >= 10 and h <= 20);
    try std.testing.expect(@abs(hills.at(12.5, 3.25)) <= 3);
}
