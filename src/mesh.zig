//! Meshes: built, kept, and drawn. Three layers, each of use on its own.
//!
//! `Builder` is geometry on the CPU: vertices and triangles added by hand, or whole
//! shapes appended — `b.cube(1, at)`, `b.cylinder(...)` — painted, shaded, moved, and
//! then `upload`ed to the GPU. `Mesh` is the uploaded thing: drawn with a matrix, let
//! go of with `deinit`; and `Mesh.cube(1)`, `Mesh.polygon(6, 2)` and the rest are the
//! one-liners for when a shape is all that is wanted. `Meshes` is a resource that keeps
//! them by id and name so a hundred crates share one cube, and `Model` is the component
//! an entity carries to be drawn with one: give `Entity` a `model: ?mesh.Model` and
//! register `drawModels` in the render pass.
//!
//! Raylib's default shader knows nothing of light, so shading is baked into the vertex
//! colours: `shade` darkens every face by how far it turns from the light. Faces are
//! flat — every shape is faceted, which reads well low-poly — except the sphere, which
//! is smooth.
//!
//! Winding is counter-clockwise seen from outside, which is what raylib culls by, and
//! y is up.

const std = @import("std");
const rl = @import("raylib.zig").c;

const identity = rl.Quaternion{ .x = 0, .y = 0, .z = 0, .w = 1 };

const ones = rl.Vector3{ .x = 1, .y = 1, .z = 1 };

const origin = rl.Vector3{ .x = 0, .y = 0, .z = 0 };

pub const Builder = struct {
    gpa: std.mem.Allocator,
    positions: std.ArrayList(f32) = .empty,
    normals: std.ArrayList(f32) = .empty,
    uvs: std.ArrayList(f32) = .empty,
    colors: std.ArrayList(u8) = .empty,
    indices: std.ArrayList(u16) = .empty,
    /// What every vertex added from now on is painted. `paint` sets it.
    color: rl.Color = rl.WHITE,

    pub const Error = error{ OutOfMemory, TooManyVertices };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.positions.deinit(b.gpa);
        b.normals.deinit(b.gpa);
        b.uvs.deinit(b.gpa);
        b.colors.deinit(b.gpa);
        b.indices.deinit(b.gpa);
    }

    /// Everything gone; the builder is ready to go again.
    pub fn clear(b: *Builder) void {
        b.positions.clearRetainingCapacity();
        b.normals.clearRetainingCapacity();
        b.uvs.clearRetainingCapacity();
        b.colors.clearRetainingCapacity();
        b.indices.clearRetainingCapacity();
    }

    pub fn vertexCount(b: *const Builder) usize {
        return b.positions.items.len / 3;
    }

    pub fn triangleCount(b: *const Builder) usize {
        return b.indices.items.len / 3;
    }

    /// The colour every vertex added from now on gets.
    pub fn paint(b: *Builder, color: rl.Color) void {
        b.color = color;
    }

    // ---- by hand ----

    /// One vertex, painted the current colour. Its index, for `triangle` and `quad`.
    pub fn vertex(b: *Builder, at: rl.Vector3, normal: rl.Vector3, uv: rl.Vector2) Error!u16 {
        const index = b.vertexCount();
        if (index > std.math.maxInt(u16)) return error.TooManyVertices;
        try b.positions.appendSlice(b.gpa, &.{ at.x, at.y, at.z });
        try b.normals.appendSlice(b.gpa, &.{ normal.x, normal.y, normal.z });
        try b.uvs.appendSlice(b.gpa, &.{ uv.x, uv.y });
        try b.colors.appendSlice(b.gpa, &.{ b.color.r, b.color.g, b.color.b, b.color.a });
        return @intCast(index);
    }

    /// Three vertices already added, counter-clockwise from outside.
    pub fn triangle(b: *Builder, first: u16, second: u16, third: u16) Error!void {
        try b.indices.appendSlice(b.gpa, &.{ first, second, third });
    }

    /// Four vertices already added, counter-clockwise from outside, as two triangles.
    pub fn quad(b: *Builder, first: u16, second: u16, third: u16, fourth: u16) Error!void {
        try b.triangle(first, second, third);
        try b.triangle(first, third, fourth);
    }

    /// A flat triangle from three corners, counter-clockwise from outside: three new
    /// vertices sharing the face's normal.
    pub fn tri(b: *Builder, corners: [3]rl.Vector3) Error!void {
        const normal = faceNormal(corners[0], corners[1], corners[2]);
        const uvs = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0.5, .y = 1 } };
        var ids: [3]u16 = undefined;
        for (corners, uvs, &ids) |corner, uv, *id| id.* = try b.vertex(corner, normal, uv);
        try b.triangle(ids[0], ids[1], ids[2]);
    }

    /// A flat quadrilateral from four corners, counter-clockwise from outside: four
    /// new vertices sharing the face's normal, the texture laid across it once.
    pub fn face(b: *Builder, corners: [4]rl.Vector3) Error!void {
        const normal = faceNormal(corners[0], corners[1], corners[3]);
        const uvs = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } };
        var ids: [4]u16 = undefined;
        for (corners, uvs, &ids) |corner, uv, *id| id.* = try b.vertex(corner, normal, uv);
        try b.quad(ids[0], ids[1], ids[2], ids[3]);
    }

    // ---- shapes, appended ----

    pub fn cube(b: *Builder, size: f32, at: rl.Vector3) Error!void {
        try b.box(.{ .x = size, .y = size, .z = size }, at);
    }

    /// A box of a full width, height and depth, centred on `at`.
    pub fn box(b: *Builder, size: rl.Vector3, at: rl.Vector3) Error!void {
        const x = size.x / 2;
        const y = size.y / 2;
        const z = size.z / 2;
        const c = struct {
            fn corner(o: rl.Vector3, px: f32, py: f32, pz: f32) rl.Vector3 {
                return .{ .x = o.x + px, .y = o.y + py, .z = o.z + pz };
            }
        };
        // front +z
        try b.face(.{ c.corner(at, -x, -y, z), c.corner(at, x, -y, z), c.corner(at, x, y, z), c.corner(at, -x, y, z) });
        // back -z
        try b.face(.{ c.corner(at, x, -y, -z), c.corner(at, -x, -y, -z), c.corner(at, -x, y, -z), c.corner(at, x, y, -z) });
        // right +x
        try b.face(.{ c.corner(at, x, -y, z), c.corner(at, x, -y, -z), c.corner(at, x, y, -z), c.corner(at, x, y, z) });
        // left -x
        try b.face(.{ c.corner(at, -x, -y, -z), c.corner(at, -x, -y, z), c.corner(at, -x, y, z), c.corner(at, -x, y, -z) });
        // top +y
        try b.face(.{ c.corner(at, -x, y, z), c.corner(at, x, y, z), c.corner(at, x, y, -z), c.corner(at, -x, y, -z) });
        // bottom -y
        try b.face(.{ c.corner(at, -x, -y, -z), c.corner(at, x, -y, -z), c.corner(at, x, -y, z), c.corner(at, -x, -y, z) });
    }

    /// A standing rectangle facing +z, centred on `at`: a sign, a sprite's board.
    pub fn quadShape(b: *Builder, width: f32, height: f32, at: rl.Vector3) Error!void {
        const x = width / 2;
        const y = height / 2;
        try b.face(.{
            .{ .x = at.x - x, .y = at.y - y, .z = at.z },
            .{ .x = at.x + x, .y = at.y - y, .z = at.z },
            .{ .x = at.x + x, .y = at.y + y, .z = at.z },
            .{ .x = at.x - x, .y = at.y + y, .z = at.z },
        });
    }

    /// A flat rectangle facing up, centred on `at`: a floor, a table top.
    pub fn plane(b: *Builder, width: f32, length: f32, at: rl.Vector3) Error!void {
        const x = width / 2;
        const z = length / 2;
        try b.face(.{
            .{ .x = at.x - x, .y = at.y, .z = at.z + z },
            .{ .x = at.x + x, .y = at.y, .z = at.z + z },
            .{ .x = at.x + x, .y = at.y, .z = at.z - z },
            .{ .x = at.x - x, .y = at.y, .z = at.z - z },
        });
    }

    /// A flat regular polygon facing up — three sides a triangle, six a hexagon, many
    /// a disc — of a radius to its corners, centred on `at`.
    pub fn polygon(b: *Builder, sides: u16, radius: f32, at: rl.Vector3) Error!void {
        try b.disc(sides, radius, at, .up);
    }

    const Facing = enum { up, down };

    fn disc(b: *Builder, sides: u16, radius: f32, at: rl.Vector3, facing: Facing) Error!void {
        const count = @max(sides, 3);
        const normal = rl.Vector3{ .x = 0, .y = if (facing == .up) 1 else -1, .z = 0 };
        const centre = try b.vertex(at, normal, .{ .x = 0.5, .y = 0.5 });
        const first = b.vertexCount();
        for (0..count) |i| {
            const p = rim(count, i);
            _ = try b.vertex(
                .{ .x = at.x + p.x * radius, .y = at.y, .z = at.z + p.z * radius },
                normal,
                .{ .x = 0.5 + p.x / 2, .y = 0.5 + p.z / 2 },
            );
        }
        for (0..count) |i| {
            const here: u16 = @intCast(first + i);
            const next: u16 = @intCast(first + (i + 1) % count);
            // Counter-clockwise from above is the other way round from below.
            if (facing == .up) try b.triangle(centre, next, here) else try b.triangle(centre, here, next);
        }
    }

    /// A cylinder standing up, of a full height, centred on `at`: `sides` round.
    pub fn cylinder(b: *Builder, radius: f32, height: f32, sides: u16, at: rl.Vector3) Error!void {
        const count = @max(sides, 3);
        const h = height / 2;
        const top = rl.Vector3{ .x = at.x, .y = at.y + h, .z = at.z };
        const bottom = rl.Vector3{ .x = at.x, .y = at.y - h, .z = at.z };
        for (0..count) |i| {
            const p = rim(count, i);
            const q = rim(count, (i + 1) % count);
            try b.face(.{
                .{ .x = at.x + q.x * radius, .y = bottom.y, .z = at.z + q.z * radius },
                .{ .x = at.x + p.x * radius, .y = bottom.y, .z = at.z + p.z * radius },
                .{ .x = at.x + p.x * radius, .y = top.y, .z = at.z + p.z * radius },
                .{ .x = at.x + q.x * radius, .y = top.y, .z = at.z + q.z * radius },
            });
        }
        try b.disc(count, radius, top, .up);
        try b.disc(count, radius, bottom, .down);
    }

    /// A cone standing up, its point at the top, of a full height, centred on `at`.
    pub fn cone(b: *Builder, radius: f32, height: f32, sides: u16, at: rl.Vector3) Error!void {
        const count = @max(sides, 3);
        const h = height / 2;
        const apex = rl.Vector3{ .x = at.x, .y = at.y + h, .z = at.z };
        const bottom = rl.Vector3{ .x = at.x, .y = at.y - h, .z = at.z };
        for (0..count) |i| {
            const p = rim(count, i);
            const q = rim(count, (i + 1) % count);
            try b.tri(.{
                .{ .x = at.x + q.x * radius, .y = bottom.y, .z = at.z + q.z * radius },
                .{ .x = at.x + p.x * radius, .y = bottom.y, .z = at.z + p.z * radius },
                apex,
            });
        }
        try b.disc(count, radius, bottom, .down);
    }

    /// A smooth sphere, `rings` from pole to pole and `slices` round, centred on `at`.
    pub fn sphere(b: *Builder, radius: f32, rings: u16, slices: u16, at: rl.Vector3) Error!void {
        const down_count: usize = @max(rings, 2);
        const round_count: usize = @max(slices, 3);
        const first = b.vertexCount();
        for (0..down_count + 1) |r| {
            const lat = std.math.pi * @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(down_count));
            for (0..round_count + 1) |s| {
                const lon = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(round_count));
                const normal = rl.Vector3{ .x = @sin(lat) * @cos(lon), .y = @cos(lat), .z = @sin(lat) * @sin(lon) };
                _ = try b.vertex(
                    .{ .x = at.x + normal.x * radius, .y = at.y + normal.y * radius, .z = at.z + normal.z * radius },
                    normal,
                    .{ .x = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(round_count)), .y = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(down_count)) },
                );
            }
        }
        const stride = round_count + 1;
        for (0..down_count) |r| {
            for (0..round_count) |s| {
                const upper: usize = first + r * stride + s;
                const lower: usize = upper + stride;
                try b.quad(@intCast(lower + 1), @intCast(lower), @intCast(upper), @intCast(upper + 1));
            }
        }
    }

    /// A terrain: a grid of `columns` by `rows` cells over `width` by `depth`, centred
    /// on `at`, every vertex lifted by `height(context, x, z)` — a noise, a heightmap,
    /// anything. Vertices are shared between cells and their normals taken from the
    /// neighbouring heights, so the surface is smooth. `(columns + 1) * (rows + 1)`
    /// vertices: keep one grid under 255 a side, and chunk anything bigger.
    pub fn grid(
        b: *Builder,
        width: f32,
        depth: f32,
        columns: u16,
        rows: u16,
        at: rl.Vector3,
        context: anytype,
        comptime height: fn (@TypeOf(context), f32, f32) f32,
    ) Error!void {
        const across: usize = @max(columns, 1);
        const down: usize = @max(rows, 1);
        const dx = width / @as(f32, @floatFromInt(across));
        const dz = depth / @as(f32, @floatFromInt(down));
        const x0 = at.x - width / 2;
        const z0 = at.z - depth / 2;
        const first = b.vertexCount();
        for (0..down + 1) |j| {
            const z = z0 + dz * @as(f32, @floatFromInt(j));
            for (0..across + 1) |i| {
                const x = x0 + dx * @as(f32, @floatFromInt(i));
                // The slope either side, for the normal: minus the rise per unit.
                const left = height(context, x - dx, z);
                const right = height(context, x + dx, z);
                const back = height(context, x, z - dz);
                const front = height(context, x, z + dz);
                const normal = rl.Vector3Normalize(.{ .x = (left - right) / (2 * dx), .y = 1, .z = (back - front) / (2 * dz) });
                _ = try b.vertex(
                    .{ .x = x, .y = at.y + height(context, x, z), .z = z },
                    normal,
                    .{ .x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(across)), .y = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(down)) },
                );
            }
        }
        const stride = across + 1;
        for (0..down) |j| {
            for (0..across) |i| {
                const near: usize = first + j * stride + i;
                const far: usize = near + stride;
                // Counter-clockwise from above, the way `plane` is wound.
                try b.quad(@intCast(far), @intCast(far + 1), @intCast(near + 1), @intCast(near));
            }
        }
    }

    /// A unit point round the rim, `i` of `count` from +x, going round +z.
    fn rim(count: usize, i: usize) rl.Vector3 {
        const angle = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
        return .{ .x = @cos(angle), .y = 0, .z = @sin(angle) };
    }

    // ---- over the whole ----

    /// Every vertex so far moved by a matrix; normals turned with it.
    pub fn transform(b: *Builder, matrix: rl.Matrix) void {
        var i: usize = 0;
        while (i + 2 < b.positions.items.len) : (i += 3) {
            const p = rl.Vector3Transform(.{ .x = b.positions.items[i], .y = b.positions.items[i + 1], .z = b.positions.items[i + 2] }, matrix);
            b.positions.items[i] = p.x;
            b.positions.items[i + 1] = p.y;
            b.positions.items[i + 2] = p.z;
            // A direction: turned, not moved.
            var turned = rl.Vector3Transform(.{ .x = b.normals.items[i], .y = b.normals.items[i + 1], .z = b.normals.items[i + 2] }, matrix);
            const zero = rl.Vector3Transform(origin, matrix);
            turned = rl.Vector3Normalize(rl.Vector3Subtract(turned, zero));
            b.normals.items[i] = turned.x;
            b.normals.items[i + 1] = turned.y;
            b.normals.items[i + 2] = turned.z;
        }
    }

    /// Every vertex so far moved.
    pub fn translate(b: *Builder, by: rl.Vector3) void {
        b.transform(rl.MatrixTranslate(by.x, by.y, by.z));
    }

    /// Every vertex so far turned about the origin.
    pub fn rotate(b: *Builder, rotation: rl.Quaternion) void {
        b.transform(rl.QuaternionToMatrix(rotation));
    }

    /// Every vertex so far scaled about the origin.
    pub fn scale(b: *Builder, by: rl.Vector3) void {
        b.transform(rl.MatrixScale(by.x, by.y, by.z));
    }

    /// Light baked into the colours so far: each vertex darkened by how far its
    /// normal turns from `toward` (the direction the light comes from), down to
    /// `ambient` of its colour facing away. Raylib's default shader does no lighting,
    /// so this is what makes a cube read as a cube.
    pub fn shade(b: *Builder, toward: rl.Vector3, ambient: f32) void {
        const light = rl.Vector3Normalize(toward);
        var i: usize = 0;
        while (i + 2 < b.normals.items.len) : (i += 3) {
            const n = rl.Vector3{ .x = b.normals.items[i], .y = b.normals.items[i + 1], .z = b.normals.items[i + 2] };
            const facing = @max(rl.Vector3DotProduct(n, light), 0);
            const brightness = ambient + (1 - ambient) * facing;
            const c = i / 3 * 4;
            for (0..3) |k| b.colors.items[c + k] = @intFromFloat(@min(@round(@as(f32, @floatFromInt(b.colors.items[c + k])) * brightness), 255));
        }
    }

    /// The box round everything so far.
    pub fn bounds(b: *const Builder) rl.BoundingBox {
        var box_min = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
        var box_max = rl.Vector3{ .x = 0, .y = 0, .z = 0 };
        var i: usize = 0;
        while (i + 2 < b.positions.items.len) : (i += 3) {
            const p = rl.Vector3{ .x = b.positions.items[i], .y = b.positions.items[i + 1], .z = b.positions.items[i + 2] };
            if (i == 0) {
                box_min = p;
                box_max = p;
            } else {
                box_min = rl.Vector3Min(box_min, p);
                box_max = rl.Vector3Max(box_max, p);
            }
        }
        return .{ .min = box_min, .max = box_max };
    }

    /// To the GPU. The builder is left as it was, to build on or upload again. The
    /// window must be open: this is the graphics card's memory.
    pub fn upload(b: *const Builder) Error!Mesh {
        if (b.vertexCount() > std.math.maxInt(u16) + 1) return error.TooManyVertices;
        // The mesh keeps its own copies, in Zig's memory; `deinit` frees them with the
        // same allocator — raylib's UnloadMesh, which would use C's free, is never called.
        const page = std.heap.page_allocator;
        const positions = try page.dupe(f32, b.positions.items);
        errdefer page.free(positions);
        const normals = try page.dupe(f32, b.normals.items);
        errdefer page.free(normals);
        const uvs = try page.dupe(f32, b.uvs.items);
        errdefer page.free(uvs);
        const colors = try page.dupe(u8, b.colors.items);
        errdefer page.free(colors);
        const indices = try page.dupe(u16, b.indices.items);
        errdefer page.free(indices);

        var raw = std.mem.zeroes(rl.Mesh);
        raw.vertexCount = @intCast(b.vertexCount());
        raw.triangleCount = @intCast(b.triangleCount());
        raw.vertices = positions.ptr;
        raw.normals = normals.ptr;
        raw.texcoords = uvs.ptr;
        raw.colors = colors.ptr;
        raw.indices = indices.ptr;
        rl.UploadMesh(&raw, false);
        return .{ .raw = raw, .bounds = b.bounds() };
    }
};

fn faceNormal(a: rl.Vector3, b: rl.Vector3, c: rl.Vector3) rl.Vector3 {
    return rl.Vector3Normalize(rl.Vector3CrossProduct(rl.Vector3Subtract(b, a), rl.Vector3Subtract(c, a)));
}

/// How many vertex buffers raylib gives a mesh (its MAX_MESH_VERTEX_BUFFERS): ids it
/// never set are nought, and unloading nought is nothing.
const vertex_buffers = 9;

pub const Mesh = struct {
    raw: rl.Mesh,
    /// The box round it as built, for whoever wants to cull.
    bounds: rl.BoundingBox,

    // ---- the one-liners: built, shaded and uploaded ----

    pub fn cube(size: f32) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: f32) Builder.Error!void {
                try b.cube(s, origin);
            }
        }.add, size);
    }

    pub fn box(size: rl.Vector3) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: rl.Vector3) Builder.Error!void {
                try b.box(s, origin);
            }
        }.add, size);
    }

    pub fn quad(width: f32, height: f32) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: [2]f32) Builder.Error!void {
                try b.quadShape(s[0], s[1], origin);
            }
        }.add, .{ width, height });
    }

    pub fn plane(width: f32, length: f32) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: [2]f32) Builder.Error!void {
                try b.plane(s[0], s[1], origin);
            }
        }.add, .{ width, length });
    }

    pub fn polygon(sides: u16, radius: f32) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: struct { u16, f32 }) Builder.Error!void {
                try b.polygon(s[0], s[1], origin);
            }
        }.add, .{ sides, radius });
    }

    pub fn cylinder(radius: f32, height: f32, sides: u16) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: struct { f32, f32, u16 }) Builder.Error!void {
                try b.cylinder(s[0], s[1], s[2], origin);
            }
        }.add, .{ radius, height, sides });
    }

    pub fn cone(radius: f32, height: f32, sides: u16) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: struct { f32, f32, u16 }) Builder.Error!void {
                try b.cone(s[0], s[1], s[2], origin);
            }
        }.add, .{ radius, height, sides });
    }

    pub fn sphere(radius: f32, rings: u16, slices: u16) Builder.Error!Mesh {
        return shaped(struct {
            fn add(b: *Builder, s: struct { f32, u16, u16 }) Builder.Error!void {
                try b.sphere(s[0], s[1], s[2], origin);
            }
        }.add, .{ radius, rings, slices });
    }

    /// One shape, built white, shaded by the config's light, uploaded.
    fn shaped(comptime add: anytype, args: anytype) Builder.Error!Mesh {
        var b = Builder.init(std.heap.smp_allocator);
        defer b.deinit();
        try add(&b, args);
        if (!lit) b.shade(default_light, default_ambient);
        return b.upload();
    }

    // ---- drawing ----

    /// Drawn where a matrix puts it, tinted: white is the mesh's own colours.
    pub fn draw(m: *const Mesh, transform: rl.Matrix, tint: rl.Color) void {
        m.drawWith(transform, tint, null);
    }

    /// The same, wearing a picture. Without one the mesh keeps its own colours, which
    /// is what the editor wants while it is being built and a game wants for anything
    /// plain.
    pub fn drawWith(m: *const Mesh, transform: rl.Matrix, tint: rl.Color, picture: ?rl.Texture2D) void {
        var mat = material(picture);
        mat.maps[rl.MATERIAL_MAP_DIFFUSE].color = tint;
        rl.DrawMesh(m.raw, mat, transform);
    }

    pub fn drawAt(m: *const Mesh, at: rl.Vector3, tint: rl.Color) void {
        m.draw(rl.MatrixTranslate(at.x, at.y, at.z), tint);
    }

    pub fn drawPosed(m: *const Mesh, at: rl.Vector3, rotation: rl.Quaternion, scaling: rl.Vector3, tint: rl.Color) void {
        m.draw(matrixOf(at, rotation, scaling), tint);
    }

    pub fn drawPosedWith(m: *const Mesh, at: rl.Vector3, rotation: rl.Quaternion, scaling: rl.Vector3, tint: rl.Color, picture: ?rl.Texture2D) void {
        m.drawWith(matrixOf(at, rotation, scaling), tint, picture);
    }

    /// The GPU's copy let go of, and the CPU's with it. By hand rather than through
    /// raylib's UnloadMesh, which frees the arrays with C's free: these are Zig's.
    pub fn deinit(m: *Mesh) void {
        // Already let go of: nothing to unload, and nothing to free twice.
        if (m.raw.vertexCount == 0 and m.raw.vertices == null) return;
        if (m.raw.vaoId != 0) rl.rlUnloadVertexArray(m.raw.vaoId);
        if (m.raw.vboId != null) {
            // The buffer ids are raylib's own array, made in UploadMesh: freed its way.
            for (0..vertex_buffers) |i| rl.rlUnloadVertexBuffer(m.raw.vboId[i]);
            rl.MemFree(m.raw.vboId);
        }
        const page = std.heap.page_allocator;
        const verts: usize = @intCast(m.raw.vertexCount);
        const tris: usize = @intCast(m.raw.triangleCount);
        if (m.raw.vertices != null) page.free(m.raw.vertices[0 .. verts * 3]);
        if (m.raw.normals != null) page.free(m.raw.normals[0 .. verts * 3]);
        if (m.raw.texcoords != null) page.free(m.raw.texcoords[0 .. verts * 2]);
        if (m.raw.colors != null) page.free(m.raw.colors[0 .. verts * 4]);
        if (m.raw.indices != null) page.free(m.raw.indices[0 .. tris * 3]);
        m.raw = std.mem.zeroes(rl.Mesh);
    }
};

/// Scale, then turn, then move: the model matrix for a thing at a spot.
pub fn matrixOf(at: rl.Vector3, rotation: rl.Quaternion, scaling: rl.Vector3) rl.Matrix {
    const scaled = rl.MatrixScale(scaling.x, scaling.y, scaling.z);
    const turned = rl.MatrixMultiply(scaled, rl.QuaternionToMatrix(rotation));
    return rl.MatrixMultiply(turned, rl.MatrixTranslate(at.x, at.y, at.z));
}

/// The one material every mesh draws with — raylib's default, with its tint and its
/// picture set per draw. Made the first time it is asked for, after the window is
/// open, and let go of with the window.
var default_material: ?rl.Material = null;

/// The shader every mesh draws with, when something has one to lend: the lighting
/// sets it, and takes it back. Null is raylib's own, unlit.
pub var shader: ?rl.Shader = null;

/// Whether a light is on the meshes: then the one-liner shapes leave their colours
/// alone rather than baking a light of their own in.
pub var lit = false;

/// Where the baked light comes from, and how much of a colour a face turned away
/// from it keeps. The plugin sets them from the config.
pub var default_light: rl.Vector3 = .{ .x = 0.4, .y = 1, .z = 0.3 };

pub var default_ambient: f32 = 0.55;

/// The single white texel raylib's default material starts with, kept from the moment
/// that material is made. Wearing it leaves a mesh its own colours.
var blank_texture: rl.Texture2D = undefined;

fn material(picture: ?rl.Texture2D) rl.Material {
    if (default_material == null) {
        default_material = rl.LoadMaterialDefault();
        blank_texture = default_material.?.maps[rl.MATERIAL_MAP_DIFFUSE].texture;
    }
    var mat = default_material.?;
    if (shader) |lent| mat.shader = lent;
    // Set every time, never only when there is one to set. `maps` is a pointer into the
    // one material every mesh shares, so writing a picture there leaves it there: a mesh
    // wearing none, drawn after one that was, would keep the other's picture and every
    // bare thing in the world would come out wearing whatever was drawn before it.
    mat.maps[rl.MATERIAL_MAP_DIFFUSE].texture = picture orelse blank_texture;
    return mat;
}

pub const MeshId = u32;

pub const Meshes = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Mesh) = .empty,
    names: std.StringHashMapUnmanaged(MeshId) = .empty,

    /// Keeps a mesh; its id is what a `Model` holds. Let go of with the rest at the
    /// end.
    pub fn add(ms: *Meshes, m: Mesh) !MeshId {
        try ms.list.append(ms.gpa, m);
        return @intCast(ms.list.items.len - 1);
    }

    /// Keeps a mesh under a name too, to be found by it.
    pub fn name(ms: *Meshes, label: []const u8, m: Mesh) !MeshId {
        const id = try ms.add(m);
        const owned = try ms.gpa.dupe(u8, label);
        errdefer ms.gpa.free(owned);
        try ms.names.put(ms.gpa, owned, id);
        return id;
    }

    /// One mesh let go of, its id left dead: what it drew is drawn no more. For a
    /// thing deleted, whose mesh would otherwise sit on the card until the end.
    pub fn discard(ms: *Meshes, id: MeshId) void {
        const m = ms.get(id) orelse return;
        m.deinit();
    }

    /// A mesh made again in place of one kept — a thing edited — so every `Model`
    /// holding the id draws the new one. The old is let go of.
    pub fn replace(ms: *Meshes, id: MeshId, m: Mesh) void {
        const old = ms.get(id) orelse return;
        old.deinit();
        old.* = m;
    }

    pub fn get(ms: *Meshes, id: MeshId) ?*Mesh {
        if (id >= ms.list.items.len) return null;
        return &ms.list.items[id];
    }

    pub fn find(ms: *const Meshes, label: []const u8) ?MeshId {
        return ms.names.get(label);
    }

    fn unloadAll(ms: *Meshes) void {
        for (ms.list.items) |*m| m.deinit();
        ms.list.deinit(ms.gpa);
        ms.list = .empty;
        var keys = ms.names.keyIterator();
        while (keys.next()) |key| ms.gpa.free(key.*);
        ms.names.deinit(ms.gpa);
        ms.names = .empty;
    }
};

/// What an entity carries to be drawn with a mesh from `Meshes`, where the entity's
/// `position` is.
pub const Model = struct {
    mesh: MeshId,
    rotation: rl.Quaternion = identity,
    scale: rl.Vector3 = ones,
    tint: rl.Color = rl.WHITE,
    /// The picture it wears, out of `Textures`. None leaves it its own colours.
    texture: ?TextureId = null,
    /// Whether it is drawn at all. For something taken out of sight for a moment and
    /// put back — a wall an editor is seeing past — where letting the mesh go and
    /// building it again every frame would be far dearer than not drawing it. A fully
    /// see-through tint is not the same thing: that still writes depth, and would go on
    /// hiding whatever stood behind it.
    shown: bool = true,
};

// ---- the pictures ----

pub const TextureId = u32;

/// An id no picture will ever answer to, so `get` gives the check for it. What a face
/// wears when the level names a picture that is not in the folder any more: it should
/// say so on the wall rather than quietly going plain.
pub const no_such_texture: TextureId = std.math.maxInt(TextureId);

/// The picture a face wears when the one it asks for is not there: a loud magenta
/// check, kept crisp rather than smoothed so it reads as a fault and not as a design.
/// Made the first time it is wanted, after the window is open, and never loaded from
/// a file — a missing-picture picture that could itself go missing would be no use.
///
/// Wearing no picture at all is a different thing and stays as it is: the mesh keeps
/// its own colours, which is what a plain or a half-built thing should look like.
var missing_texture: ?rl.Texture2D = null;

pub fn missing() rl.Texture2D {
    if (missing_texture == null) {
        const image = rl.GenImageChecked(64, 64, 8, 8, .{ .r = 255, .g = 0, .b = 220, .a = 255 }, .{ .r = 24, .g = 20, .b = 28, .a = 255 });
        defer rl.UnloadImage(image);
        const made = rl.LoadTextureFromImage(image);
        rl.SetTextureFilter(made, rl.TEXTURE_FILTER_POINT);
        rl.SetTextureWrap(made, rl.TEXTURE_WRAP_REPEAT);
        missing_texture = made;
    }
    return missing_texture.?;
}

/// Every picture the world has to hand, kept by id and by name. A game loads a folder
/// of them at the start and asks for one by name; whatever holds an id — a `Model`, a
/// brush's face — holds it for as long as the world does.
pub const Textures = struct {
    const Kept = struct { name: []u8, texture: rl.Texture2D };

    gpa: std.mem.Allocator,
    list: std.ArrayList(Kept) = .empty,
    by_name: std.StringHashMapUnmanaged(TextureId) = .empty,

    /// One picture from a file, under its own file name without the extension. Loading
    /// a name that is already here gives back the one that is here: a folder read twice
    /// does not double.
    pub fn load(ts: *Textures, path: [*:0]const u8) !TextureId {
        // raylib hands this back out of a static buffer it wipes on the next call, so
        // it is taken a copy of at once rather than held on to across the loading.
        const label = try ts.gpa.dupe(u8, std.mem.span(rl.GetFileNameWithoutExt(path)));
        errdefer ts.gpa.free(label);
        if (ts.by_name.get(label)) |had| {
            ts.gpa.free(label);
            return had;
        }
        const texture = rl.LoadTexture(path);
        if (texture.id == 0) return error.TextureNotLoaded;
        // A wall wants to repeat, and to be smoothed between its own texels and nothing
        // else. No mip levels are made: raylib's bilinear on a mipmapped texture is
        // LINEAR_MIP_NEAREST, which still blends between levels and still reads soft —
        // plain bilinear is only plain when there is nothing to mip to.
        rl.SetTextureFilter(texture, rl.TEXTURE_FILTER_BILINEAR);
        rl.SetTextureWrap(texture, rl.TEXTURE_WRAP_REPEAT);
        try ts.list.append(ts.gpa, .{ .name = label, .texture = texture });
        const id: TextureId = @intCast(ts.list.items.len - 1);
        try ts.by_name.put(ts.gpa, label, id);
        return id;
    }

    /// The extensions a picture may have. raylib splits this on the semicolon and
    /// matches without regard to case, so `WALL.PNG` counts.
    const picture_kinds = ".png;.jpg;.jpeg;.bmp;.tga;.gif";

    /// Every picture in a folder, and — with `deep` — in every folder under it, all the
    /// way down. How many were loaded. A folder that is not there is none of them, which
    /// is not an error: a game may simply have no pictures yet.
    ///
    /// A name already loaded is not loaded twice, so several folders may be scanned one
    /// after another and whichever is scanned first wins the name.
    ///
    /// A whole project tree is a fine thing to point this at. Walking a few thousand
    /// entries that are not pictures costs nothing worth measuring, and picking out the
    /// folders worth walking is guesswork that gets it wrong the first time someone
    /// names a folder something unexpected.
    pub fn loadFolder(ts: *Textures, folder: [*:0]const u8, deep: bool) usize {
        if (!rl.DirectoryExists(folder)) return 0;
        const found = rl.LoadDirectoryFilesEx(folder, picture_kinds, deep);
        defer rl.UnloadDirectoryFiles(found);
        var added: usize = 0;
        for (0..found.count) |i| {
            const path = found.paths[i];
            // raylib scans the tree twice and forces the count down if a file went
            // away between the two, which leaves empty strings on the end of the list.
            if (path == null or path[0] == 0) continue;
            _ = ts.load(path) catch continue;
            added += 1;
        }
        return added;
    }

    /// How deep the walk will go. A folder that links back to one above it would
    /// otherwise be walked for ever, and raylib's own recursion follows links.
    const walk_deepest: u8 = 24;

    /// Every picture under a folder, all the way down, skipping folders whose name
    /// starts with a dot.
    ///
    /// The walk is done here rather than handed to raylib because raylib's own
    /// recursion cannot be told to leave a folder alone, and the hidden ones are where
    /// the thousands of files that are not pictures live — a build cache, a repository.
    /// One rule covers all of them, which is better than a list of names to keep
    /// guessing at.
    pub fn loadUnder(ts: *Textures, root: [*:0]const u8) usize {
        return ts.walkUnder(root, 0);
    }

    fn walkUnder(ts: *Textures, root: [*:0]const u8, depth: u8) usize {
        if (depth > walk_deepest) return 0;
        if (!rl.DirectoryExists(root)) return 0;
        // The loose ones lying here first, so a name near the top beats the same name
        // buried deeper.
        var added = ts.loadFolder(root, false);
        const folders = rl.LoadDirectoryFilesEx(root, "DIRS*", false);
        defer rl.UnloadDirectoryFiles(folders);
        for (0..folders.count) |i| {
            const path = folders.paths[i];
            if (path == null or path[0] == 0) continue;
            // Points into the path itself, which lives as long as the list does.
            const name = std.mem.span(rl.GetFileName(path));
            if (name.len == 0 or name[0] == '.') continue;
            added += ts.walkUnder(path, depth + 1);
        }
        return added;
    }

    pub fn find(ts: *const Textures, label: []const u8) ?TextureId {
        return ts.by_name.get(label);
    }

    /// A picture by id. An id nothing answers to gives the check rather than nothing:
    /// a level opened where a picture has been renamed or deleted should say so on the
    /// wall, loudly, instead of quietly looking finished.
    pub fn get(ts: *const Textures, id: TextureId) rl.Texture2D {
        if (id >= ts.list.items.len) return missing();
        return ts.list.items[id].texture;
    }

    /// The same, but honest about it: null where there is no such picture, for whoever
    /// needs to know rather than to draw.
    pub fn lookup(ts: *const Textures, id: TextureId) ?rl.Texture2D {
        if (id >= ts.list.items.len) return null;
        return ts.list.items[id].texture;
    }

    pub fn has(ts: *const Textures, id: TextureId) bool {
        return id < ts.list.items.len;
    }

    /// What a picture is called, for the readout and for saving a level by name rather
    /// than by a number that would move the next time the folder changed.
    pub fn nameOf(ts: *const Textures, id: TextureId) []const u8 {
        if (id >= ts.list.items.len) return "missing";
        return ts.list.items[id].name;
    }

    pub fn count(ts: *const Textures) usize {
        return ts.list.items.len;
    }

    pub fn unloadAll(ts: *Textures) void {
        if (missing_texture) |made| rl.UnloadTexture(made);
        missing_texture = null;
        for (ts.list.items) |*kept| {
            rl.UnloadTexture(kept.texture);
            ts.gpa.free(kept.name);
        }
        ts.list.deinit(ts.gpa);
        ts.by_name.deinit(ts.gpa);
        ts.list = .empty;
        ts.by_name = .empty;
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

        // ---- building ----

        // ---- the uploaded mesh ----

        // ---- the resource: meshes kept by id and name ----

        // ---- the component ----

        /// Every entity with a `Model` drawn, inside the scene's pass. Register it in the
        /// render plugin between "begin scene" and "end scene".
        pub fn drawModels(w: *W) void {
            const meshes = w.resource(Meshes);
            const pictures = w.resource(Textures);
            inline for (comptime components.fieldsOf(Model)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const model = @field(entity, @tagName(field));
                    const m = meshes.get(model.mesh) orelse continue;
                    // A mesh let go of draws nothing, and neither does one told not to.
                    if (m.raw.vertexCount == 0 or !model.shown) continue;
                    const picture = if (model.texture) |id| pictures.get(id) else null;
                    m.drawPosedWith(entity.position.*, model.rotation, model.scale, model.tint, picture);
                }
            }
        }

        // ---- the systems ----

        fn close(w: *W) void {
            w.resource(Meshes).unloadAll();
            w.resource(Textures).unloadAll();
            // Unloaded wearing raylib's own shader: a lent one is its lender's to unload.
            if (default_material) |mat| {
                var own = mat;
                own.shader.id = rl.rlGetShaderIdDefault();
                rl.UnloadMaterial(own);
            }
            default_material = null;
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Meshes{ .gpa = allocator });
            _ = try w.insertResource(allocator, Textures{ .gpa = allocator });
            default_light = config.mesh_light;
            default_ambient = config.mesh_ambient;
            // After the window, whose context the meshes live in; before anything that builds one.
            try w.addSystem(allocator, .{ .name = "meshes", .onCleanup = close });
        }
    };
}

// ---- tests: zig build test (the CPU side; the GPU needs a window) ----

test "shapes come out the right size, facing out, with unit normals" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    try b.cube(2, origin);
    try std.testing.expectEqual(@as(usize, 24), b.vertexCount());
    try std.testing.expectEqual(@as(usize, 12), b.triangleCount());
    const box_bounds = b.bounds();
    try std.testing.expectEqual(@as(f32, -1), box_bounds.min.x);
    try std.testing.expectEqual(@as(f32, 1), box_bounds.max.z);

    // Every face's normal points away from the centre, and is a unit long.
    var i: usize = 0;
    while (i + 2 < b.normals.items.len) : (i += 3) {
        const n = rl.Vector3{ .x = b.normals.items[i], .y = b.normals.items[i + 1], .z = b.normals.items[i + 2] };
        const p = rl.Vector3{ .x = b.positions.items[i], .y = b.positions.items[i + 1], .z = b.positions.items[i + 2] };
        try std.testing.expectApproxEqAbs(@as(f32, 1), rl.Vector3Length(n), 0.001);
        try std.testing.expect(rl.Vector3DotProduct(n, p) > 0);
    }

    b.clear();
    try b.polygon(6, 1, origin);
    try std.testing.expectEqual(@as(usize, 7), b.vertexCount());
    try std.testing.expectEqual(@as(usize, 6), b.triangleCount());
    // Facing up: the winding of every triangle agrees with +y.
    var t: usize = 0;
    while (t < b.indices.items.len) : (t += 3) {
        const at = struct {
            fn of(bb: *const Builder, index: u16) rl.Vector3 {
                const k = @as(usize, index) * 3;
                return .{ .x = bb.positions.items[k], .y = bb.positions.items[k + 1], .z = bb.positions.items[k + 2] };
            }
        };
        const n = faceNormal(at.of(&b, b.indices.items[t]), at.of(&b, b.indices.items[t + 1]), at.of(&b, b.indices.items[t + 2]));
        try std.testing.expect(n.y > 0.99);
    }

    b.clear();
    try b.cylinder(1, 2, 8, origin);
    try std.testing.expectEqual(@as(usize, 8 * 4 + 2 * 9), b.vertexCount());
    b.clear();
    try b.cone(1, 2, 5, origin);
    try std.testing.expectEqual(@as(usize, 5 * 3 + 6), b.vertexCount());
    b.clear();
    try b.sphere(1, 4, 6, origin);
    try std.testing.expectEqual(@as(usize, 5 * 7), b.vertexCount());
    try std.testing.expectEqual(@as(usize, 4 * 6 * 2), b.triangleCount());
}

test "paint, shade and move" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    b.paint(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try b.plane(2, 2, origin);
    try std.testing.expectEqual(@as(u8, 255), b.colors.items[0]);
    try std.testing.expectEqual(@as(u8, 0), b.colors.items[1]);

    // Lit from straight above, a face pointing up keeps its whole colour; lit from
    // below it keeps only the ambient share.
    b.shade(.{ .x = 0, .y = 1, .z = 0 }, 0.5);
    try std.testing.expectEqual(@as(u8, 255), b.colors.items[0]);
    b.shade(.{ .x = 0, .y = -1, .z = 0 }, 0.5);
    try std.testing.expectEqual(@as(u8, 128), b.colors.items[0]);

    b.translate(.{ .x = 0, .y = 3, .z = 0 });
    try std.testing.expectEqual(@as(f32, 3), b.bounds().min.y);
    // Turned a quarter about x, the normal that pointed up points along z.
    b.rotate(rl.QuaternionFromAxisAngle(.{ .x = 1, .y = 0, .z = 0 }, std.math.pi / 2.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.normals.items[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(b.normals.items[2]), 0.001);
}

test "a grid is a smooth terrain: shared vertices, normals from the slope" {
    const gpa = std.testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const flat = struct {
        fn height(_: void, _: f32, _: f32) f32 {
            return 2;
        }
    };
    try b.grid(10, 10, 4, 3, origin, {}, flat.height);
    try std.testing.expectEqual(@as(usize, 5 * 4), b.vertexCount());
    try std.testing.expectEqual(@as(usize, 4 * 3 * 2), b.triangleCount());
    try std.testing.expectEqual(@as(f32, 2), b.bounds().min.y);
    try std.testing.expectEqual(@as(f32, 1), b.normals.items[1]);

    // A slope up along x: normals lean back toward -x, and every triangle faces up.
    b.clear();
    const ramp = struct {
        fn height(_: void, x: f32, _: f32) f32 {
            return x;
        }
    };
    try b.grid(10, 10, 4, 4, origin, {}, ramp.height);
    try std.testing.expect(b.normals.items[0] < 0);
    var t: usize = 0;
    while (t < b.indices.items.len) : (t += 3) {
        const at = struct {
            fn of(bb: *const Builder, index: u16) rl.Vector3 {
                const k = @as(usize, index) * 3;
                return .{ .x = bb.positions.items[k], .y = bb.positions.items[k + 1], .z = bb.positions.items[k + 2] };
            }
        };
        const n = faceNormal(at.of(&b, b.indices.items[t]), at.of(&b, b.indices.items[t + 1]), at.of(&b, b.indices.items[t + 2]));
        try std.testing.expect(n.y > 0);
    }
}
