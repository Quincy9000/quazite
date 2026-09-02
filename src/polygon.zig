//! Flat polygons: an outline of points, and the things worth asking of one before it
//! becomes geometry.
//!
//! `Builder.polygon` makes a regular shape from a side count. This is the other half —
//! an outline of any shape at all, of the sort clicked out by hand or read off a face —
//! and what has to be done to it before a mesh can be made:
//!
//!   `decompose`  cut into convex pieces, since a convex piece is what most things want
//!   `hull`       the smallest ring holding a set of points
//!   `inset`      the same outline brought in from its edges
//!   `ribs`       the way across a path at each of its points, mitred at the turns
//!   `section`    a face of a solid, laid flat in the two directions a sweep works in
//!
//! The cut is ear clipping into triangles, then neighbours merged back together wherever
//! the join stays convex — so a rectangle is one piece, an L is two, a star is its arms
//! and its middle.
//!
//! Everything here is two dimensional and knows nothing of the world: a ring is read in
//! whatever pair of directions the caller is working in, and it is the caller's business
//! which those are. `section` is the one exception, and only to get a ring OUT of three
//! dimensions and into two.

const std = @import("std");
const rl = @import("raylib.zig").c;

/// A piece: indices into the ring it was cut from, counter-clockwise.
pub const Piece = std.ArrayList(u16);

/// Twice the signed area: positive for a counter-clockwise ring.
pub fn area2(points: []const rl.Vector2) f32 {
    var sum: f32 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        sum += p.x * q.y - q.x * p.y;
    }
    return sum;
}

fn cross(o: rl.Vector2, a: rl.Vector2, b: rl.Vector2) f32 {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

/// Whether a ring of the points, by index, turns the same way all the way round.
pub fn isConvex(points: []const rl.Vector2, ring: []const u16) bool {
    if (ring.len < 3) return false;
    for (ring, 0..) |_, i| {
        const a = points[ring[i]];
        const b = points[ring[(i + 1) % ring.len]];
        const c = points[ring[(i + 2) % ring.len]];
        if (cross(a, b, c) < -1e-5) return false;
    }
    return true;
}

fn inside(p: rl.Vector2, a: rl.Vector2, b: rl.Vector2, c: rl.Vector2) bool {
    return cross(a, b, p) >= -1e-6 and cross(b, c, p) >= -1e-6 and cross(c, a, p) >= -1e-6;
}

/// The ring cut into convex pieces. The ring must be counter-clockwise and simple —
/// not crossing itself. The pieces, and every piece's list, are the caller's to free.
pub fn decompose(gpa: std.mem.Allocator, points: []const rl.Vector2) !std.ArrayList(Piece) {
    var pieces: std.ArrayList(Piece) = .empty;
    errdefer freePieces(gpa, &pieces);
    if (points.len < 3) return pieces;

    // Already convex: one piece, and no cutting.
    var whole: Piece = .empty;
    for (0..points.len) |i| try whole.append(gpa, @intCast(i));
    if (isConvex(points, whole.items)) {
        try pieces.append(gpa, whole);
        return pieces;
    }

    // Ear clipping: a corner that turns left, with nobody inside its triangle, is an
    // ear; cut it off, and go round again until three are left.
    var ring = whole;
    defer ring.deinit(gpa);
    var guard: usize = 0;
    while (ring.items.len > 3 and guard < 10_000) : (guard += 1) {
        var clipped = false;
        for (ring.items, 0..) |_, i| {
            const ia = ring.items[(i + ring.items.len - 1) % ring.items.len];
            const ib = ring.items[i];
            const ic = ring.items[(i + 1) % ring.items.len];
            const a = points[ia];
            const b = points[ib];
            const c = points[ic];
            if (cross(a, b, c) <= 1e-6) continue;
            var empty = true;
            for (ring.items) |other| {
                if (other == ia or other == ib or other == ic) continue;
                if (inside(points[other], a, b, c)) {
                    empty = false;
                    break;
                }
            }
            if (!empty) continue;
            var ear: Piece = .empty;
            try ear.appendSlice(gpa, &.{ ia, ib, ic });
            try pieces.append(gpa, ear);
            _ = ring.orderedRemove(i);
            clipped = true;
            break;
        }
        // A ring that clips no ear is not simple: what is left is taken as it is.
        if (!clipped) break;
    }
    var last: Piece = .empty;
    try last.appendSlice(gpa, ring.items);
    try pieces.append(gpa, last);

    // Merging: any two pieces sharing an edge, joined along it, if the join stays
    // convex. Again until nothing more will join.
    var merged = true;
    while (merged) {
        merged = false;
        outer: for (pieces.items, 0..) |first, i| {
            for (pieces.items[i + 1 ..], i + 1..) |second, j| {
                if (try join(gpa, points, first, second)) |joined| {
                    pieces.items[i].deinit(gpa);
                    pieces.items[i] = joined;
                    var gone = pieces.orderedRemove(j);
                    gone.deinit(gpa);
                    merged = true;
                    break :outer;
                }
            }
        }
    }
    return pieces;
}

/// Two pieces joined along an edge they share, if they share one and the join is
/// convex; otherwise null.
fn join(gpa: std.mem.Allocator, points: []const rl.Vector2, first: Piece, second: Piece) !?Piece {
    const a = first.items;
    const b = second.items;
    for (a, 0..) |_, i| {
        const p = a[i];
        const q = a[(i + 1) % a.len];
        // The same edge the other way round in the second piece.
        for (b, 0..) |_, k| {
            if (b[k] != q or b[(k + 1) % b.len] != p) continue;
            // First from q round to p, then second from p round to q, the shared
            // edge dropped from both.
            var ring: Piece = .empty;
            errdefer ring.deinit(gpa);
            for (0..a.len - 1) |step| try ring.append(gpa, a[(i + 1 + step) % a.len]);
            for (0..b.len - 1) |step| try ring.append(gpa, b[(k + 1 + step) % b.len]);
            if (!isConvex(points, ring.items)) {
                ring.deinit(gpa);
                return null;
            }
            return ring;
        }
    }
    return null;
}

pub fn freePieces(gpa: std.mem.Allocator, pieces: *std.ArrayList(Piece)) void {
    for (pieces.items) |*piece| piece.deinit(gpa);
    pieces.deinit(gpa);
    pieces.* = .empty;
}

// ---- tests ----

fn pieceArea2(points: []const rl.Vector2, piece: Piece) f32 {
    var sum: f32 = 0;
    for (piece.items, 0..) |_, i| {
        const p = points[piece.items[i]];
        const q = points[piece.items[(i + 1) % piece.items.len]];
        sum += p.x * q.y - q.x * p.y;
    }
    return sum;
}

test "a square is one piece, an L is two, and the pieces add up" {
    const gpa = std.testing.allocator;
    const square = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 } };
    var one = try decompose(gpa, &square);
    defer freePieces(gpa, &one);
    try std.testing.expectEqual(@as(usize, 1), one.items.len);
    try std.testing.expectEqual(@as(usize, 4), one.items[0].items.len);

    const ell = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 3 }, .{ .x = 0, .y = 3 } };
    try std.testing.expect(area2(&ell) > 0);
    var two = try decompose(gpa, &ell);
    defer freePieces(gpa, &two);
    try std.testing.expectEqual(@as(usize, 2), two.items.len);
    var total: f32 = 0;
    for (two.items) |piece| {
        try std.testing.expect(isConvex(&ell, piece.items));
        total += pieceArea2(&ell, piece);
    }
    try std.testing.expectApproxEqAbs(area2(&ell), total, 1e-4);
}

test "a star's arms come off its middle, all convex, all of it" {
    const gpa = std.testing.allocator;
    var star: [10]rl.Vector2 = undefined;
    for (&star, 0..) |*p, i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i)) / 10;
        const r: f32 = if (i % 2 == 0) 4 else 1.7;
        p.* = .{ .x = @cos(angle) * r, .y = @sin(angle) * r };
    }
    var pieces = try decompose(gpa, &star);
    defer freePieces(gpa, &pieces);
    try std.testing.expect(pieces.items.len >= 5);
    var total: f32 = 0;
    for (pieces.items) |piece| {
        try std.testing.expect(isConvex(&star, piece.items));
        total += pieceArea2(&star, piece);
    }
    try std.testing.expectApproxEqAbs(area2(&star), total, 1e-3);
}


/// A face's outline, in the two directions a path's section lives in: across the path,
/// and up off the plane it is laid on.
///
/// This is what lets a path be any shape. A hexagon cut in a wall, picked and swept, is a
/// hexagonal tunnel; the rectangle the tool has always made is the same thing with four
/// corners. The ring goes in as it stands in the level and comes out flat, in the frame
/// the sweep works in.
///
/// Which way is up for the section is the world's up laid into the face. A face standing
/// upright keeps the up it already had, so a doorway swept down a path is still a doorway
/// and not a doorway on its side.
///
/// A face lying flat has no such direction — nothing in it is more up than anything else
/// — and then the section is the shape seen from above, stood on end. That is the case
/// worth saying out loud, because it is the one people reach for: a hexagon drawn flat on
/// the ground, picked, and swept into a hexagonal tunnel.
///
/// It comes out centred across and standing on nought, so the line one clicks is the
/// middle of the tunnel's floor rather than a spot somewhere inside its wall. And
/// counter-clockwise, which is what `decompose` wants of it.
pub fn section(gpa: std.mem.Allocator, ring: []const rl.Vector3, facing: rl.Vector3, up: rl.Vector3) ![]rl.Vector2 {
    const out = try flatten(gpa, ring, facing, up);
    errdefer gpa.free(out);
    settle(&.{out});
    return out;
}

/// The frame a face is read in: which way is across it, and which way is up it.
///
/// Worked out once and handed round, because several faces of one surface have to be read
/// in the SAME frame. A ring left by an inset is four or six faces lying in one plane, and
/// each read in a frame of its own would come out as several shapes all sitting on top of
/// one another instead of a ring.
pub fn frameOf(facing: rl.Vector3, up: rl.Vector3) struct { side: rl.Vector3, rise: rl.Vector3 } {
    const n = rl.Vector3Normalize(facing);
    var rise = rl.Vector3Subtract(up, rl.Vector3Scale(n, rl.Vector3DotProduct(up, n)));
    if (rl.Vector3Length(rise) < 1e-4) {
        // Flat: any pair of directions square to the face will do, and this picks the
        // same one every time, so the same face always comes out the same way up.
        const lean = if (@abs(n.y) < 0.9) rl.Vector3{ .x = 0, .y = 1, .z = 0 } else rl.Vector3{ .x = 1, .y = 0, .z = 0 };
        rise = rl.Vector3CrossProduct(lean, n);
    }
    rise = rl.Vector3Normalize(rise);
    return .{ .side = rl.Vector3Normalize(rl.Vector3CrossProduct(rise, n)), .rise = rise };
}

/// A ring laid flat in that frame, and nowhere in particular yet: `settle` puts it where
/// it belongs, and does it for several rings at once when there are several.
pub fn flatten(gpa: std.mem.Allocator, ring: []const rl.Vector3, facing: rl.Vector3, up: rl.Vector3) ![]rl.Vector2 {
    if (ring.len < 3) return error.NotARing;
    const frame = frameOf(facing, up);
    var out = try gpa.alloc(rl.Vector2, ring.len);
    errdefer gpa.free(out);
    for (ring, 0..) |p, i| {
        out[i] = .{
            .x = rl.Vector3DotProduct(p, frame.side),
            .y = rl.Vector3DotProduct(p, frame.rise),
        };
    }
    return out;
}

/// Shapes moved to where a path's section belongs: centred across the line and standing
/// on nought, so the line one clicks is the middle of the tunnel's floor rather than a
/// spot somewhere inside its wall.
///
/// All of them together, against one box round the lot: several faces of one surface keep
/// how they stand to each other, which is the whole of what makes a ring a ring. Each is
/// then wound counter-clockwise, which is what `decompose` asks of it.
pub fn settle(shapes: []const []rl.Vector2) void {
    var low: ?rl.Vector2 = null;
    var high: rl.Vector2 = undefined;
    for (shapes) |shape| {
        for (shape) |q| {
            if (low == null) {
                low = q;
                high = q;
                continue;
            }
            low.?.x = @min(low.?.x, q.x);
            low.?.y = @min(low.?.y, q.y);
            high.x = @max(high.x, q.x);
            high.y = @max(high.y, q.y);
        }
    }
    const bottom = low orelse return;
    const middle = (bottom.x + high.x) / 2;
    for (shapes) |shape| {
        for (shape) |*q| {
            q.x -= middle;
            q.y -= bottom.y;
        }
        if (area2(shape) < 0) std.mem.reverse(rl.Vector2, shape);
    }
}

// ---- paths ----

/// Which way across a path its section faces at one of its points, and how far that
/// point has to reach because of the turn there.
///
/// `out` bisects the turn, so the pieces either side of a corner meet along one shared
/// edge and leave no gap. `lean` is what a corner's reach is divided by: a point of the
/// section standing `u` across the line goes `out * u / lean` from it, whatever else the
/// section does. A very sharp turn would reach out for ever, so it is held to a limit.
pub const Rib = struct { out: rl.Vector2, lean: f32 };

/// A rib at every point of a path.
///
/// Split out of `sides`, which is this with a rectangle already applied to it. A section
/// of any shape wants the direction and the stretch rather than two edges: a hexagon
/// swept down a path is these same ribs with six offsets on each instead of two.
pub fn ribs(gpa: std.mem.Allocator, points: []const rl.Vector2, limit: f32) ![]Rib {
    const made = try gpa.alloc(Rib, points.len);
    errdefer gpa.free(made);
    for (points, 0..) |p, i| {
        const before: ?rl.Vector2 = if (i > 0) across(points[i - 1], p) else null;
        const after: ?rl.Vector2 = if (i + 1 < points.len) across(p, points[i + 1]) else null;
        var out = if (before) |b| (if (after) |a| rl.Vector2Add(a, b) else b) else after.?;
        const length = rl.Vector2Length(out);
        if (length < 1e-6) {
            out = after orelse before.?;
        } else {
            out = rl.Vector2Scale(out, 1 / length);
        }
        // How far out the corner goes: further the sharper the turn, up to the limit.
        made[i] = .{
            .out = out,
            .lean = if (after) |a| @max(rl.Vector2DotProduct(out, a), 1.0 / limit) else 1,
        };
    }
    return made;
}

/// The two sides of a path of `width` about a line of points, in the plane's own two
/// directions: each corner pushed out along the way the corners either side of it
/// lean, so the pieces meet along shared edges and leave no gap at a turn. A very
/// sharp turn would push the corner out for ever, so the push is held to `limit`.
///
/// The rectangle case of `ribs`: two offsets, one either side.
pub fn sides(gpa: std.mem.Allocator, points: []const rl.Vector2, width: f32, limit: f32) !struct { left: []rl.Vector2, right: []rl.Vector2 } {
    const half = width / 2;
    const rail = try ribs(gpa, points, limit);
    defer gpa.free(rail);
    var left = try gpa.alloc(rl.Vector2, points.len);
    errdefer gpa.free(left);
    const right = try gpa.alloc(rl.Vector2, points.len);
    errdefer gpa.free(right);
    for (points, 0..) |p, i| {
        const push = rl.Vector2Scale(rail[i].out, half / rail[i].lean);
        left[i] = rl.Vector2Add(p, push);
        right[i] = rl.Vector2Subtract(p, push);
    }
    return .{ .left = left, .right = right };
}

/// The smallest ring that holds every one of a set of points, counter-clockwise.
///
/// For one convex face this gives that face back unchanged, so anything built on it
/// behaves exactly as before. For several faces lying in one plane it gives the outline
/// round the lot of them, which is what makes two panels of a wall read as one wall.
/// The slice is the caller's to free.
pub fn hull(gpa: std.mem.Allocator, points: []const rl.Vector2) ![]rl.Vector2 {
    if (points.len < 3) return gpa.dupe(rl.Vector2, points);
    const sorted = try gpa.dupe(rl.Vector2, points);
    defer gpa.free(sorted);
    std.mem.sort(rl.Vector2, sorted, {}, leftOf);

    // The lower chain then the upper, each keeping only the turns that go one way:
    // the monotone chain, which needs nothing but a sort and two passes.
    var made = try gpa.alloc(rl.Vector2, sorted.len * 2);
    errdefer gpa.free(made);
    var len: usize = 0;
    for (sorted) |p| {
        while (len >= 2 and cross(made[len - 2], made[len - 1], p) <= 1e-7) len -= 1;
        made[len] = p;
        len += 1;
    }
    const lower = len + 1;
    var i = sorted.len - 1;
    while (i > 0) : (i -= 1) {
        const p = sorted[i - 1];
        while (len >= lower and cross(made[len - 2], made[len - 1], p) <= 1e-7) len -= 1;
        made[len] = p;
        len += 1;
    }
    // The last point is the first one over again.
    const ring = try gpa.dupe(rl.Vector2, made[0 .. len - 1]);
    gpa.free(made);
    return ring;
}

fn leftOf(_: void, a: rl.Vector2, b: rl.Vector2) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

test "a hull wraps what it is given, and leaves a convex ring alone" {
    const gpa = std.testing.allocator;
    // Two squares side by side, as two faces of a wall would be: the outline round
    // both is the one rectangle, four corners, not eight.
    const pair = [_]rl.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 },
        .{ .x = 2, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 2, .y = 2 },
    };
    const both = try hull(gpa, &pair);
    defer gpa.free(both);
    try std.testing.expectEqual(@as(usize, 4), both.len);
    try std.testing.expect(area2(both) > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 16), area2(both), 1e-4);

    // One convex ring comes back as itself, so a single face is untouched by this.
    const square = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 } };
    const one = try hull(gpa, &square);
    defer gpa.free(one);
    try std.testing.expectEqual(@as(usize, 4), one.len);
    try std.testing.expectApproxEqAbs(area2(&square), area2(one), 1e-4);
}

/// A ring pulled inward the same distance from every one of its edges: each corner
/// moved along the bisector of the two edges that meet there, far enough that both
/// edges end up `by` further in. A negative distance pushes it out instead.
///
/// Null when the ring would fold through itself — which is what says how far in an
/// inset is allowed to go, without anyone having to work out a limit beforehand. The
/// ring must be counter-clockwise; the slice is the caller's to free.
pub fn inset(gpa: std.mem.Allocator, ring: []const rl.Vector2, by: f32) !?[]rl.Vector2 {
    if (ring.len < 3) return null;
    const out = try gpa.alloc(rl.Vector2, ring.len);
    errdefer gpa.free(out);
    for (ring, 0..) |p, i| {
        // The two edges meeting here, each turned to face into the ring.
        const first = across(ring[(i + ring.len - 1) % ring.len], p);
        const second = across(p, ring[(i + 1) % ring.len]);
        // How far along the bisector: further the sharper the corner, and off to
        // infinity where the two edges double back on each other.
        const lean = 1 + rl.Vector2DotProduct(first, second);
        if (lean < 1e-4) {
            gpa.free(out);
            return null;
        }
        out[i] = rl.Vector2Add(p, rl.Vector2Scale(rl.Vector2Add(first, second), by / lean));
    }
    // Pulled in past its own middle, a ring has no inside left.
    if (area2(out) <= 1e-5) {
        gpa.free(out);
        return null;
    }
    // Or an edge alone has crossed over, which the area can miss: every edge must
    // still run the way it ran.
    for (out, 0..) |_, i| {
        const was = rl.Vector2Subtract(ring[(i + 1) % ring.len], ring[i]);
        const now = rl.Vector2Subtract(out[(i + 1) % out.len], out[i]);
        if (rl.Vector2DotProduct(was, now) < 0) {
            gpa.free(out);
            return null;
        }
    }
    return out;
}

test "an inset ring sits the same distance in from every edge, until there is no room" {
    const gpa = std.testing.allocator;
    // Four by two, counter-clockwise: pulled in a half is three by one, centred where
    // it was.
    const rect = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 0, .y = 2 } };
    try std.testing.expect(area2(&rect) > 0);
    const in = (try inset(gpa, &rect, 0.5)).?;
    defer gpa.free(in);
    const want = [_]rl.Vector2{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 3.5, .y = 0.5 }, .{ .x = 3.5, .y = 1.5 }, .{ .x = 0.5, .y = 1.5 } };
    for (want, 0..) |p, i| try std.testing.expect(rl.Vector2Distance(p, in[i]) < 1e-4);

    // Negative goes the other way: out, by the same distance from every edge.
    const out = (try inset(gpa, &rect, -1)).?;
    defer gpa.free(out);
    try std.testing.expect(rl.Vector2Distance(.{ .x = -1, .y = -1 }, out[0]) < 1e-4);
    try std.testing.expectApproxEqAbs(area2(&rect) + 2 * 2 * (4 + 2) + 2 * 4, area2(out), 1e-3);

    // Half the short way in and there is nothing left of it.
    try std.testing.expect(try inset(gpa, &rect, 1) == null);
    try std.testing.expect(try inset(gpa, &rect, 2) == null);

    // A triangle's corners lean much further than a square's, and it too runs out.
    const tri = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 6, .y = 0 }, .{ .x = 0, .y = 6 } };
    const small = (try inset(gpa, &tri, 0.5)).?;
    defer gpa.free(small);
    try std.testing.expect(area2(&tri) > area2(small));
    try std.testing.expect(rl.Vector2Distance(.{ .x = 0.5, .y = 0.5 }, small[0]) < 1e-4);
    try std.testing.expect(try inset(gpa, &tri, 4) == null);
}

/// The way across a segment: its direction turned a quarter.
fn across(a: rl.Vector2, b: rl.Vector2) rl.Vector2 {
    const d = rl.Vector2Subtract(b, a);
    const length = rl.Vector2Length(d);
    if (length < 1e-6) return .{ .x = 0, .y = 1 };
    return .{ .x = -d.y / length, .y = d.x / length };
}

test "a path's sides run either side of it and meet at the turns" {
    const gpa = std.testing.allocator;
    // A straight line east: the sides are a width apart, north and south of it.
    const straight = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 8, .y = 0 } };
    const flat = try sides(gpa, &straight, 2, 4);
    defer gpa.free(flat.left);
    defer gpa.free(flat.right);
    for (straight, 0..) |p, i| {
        try std.testing.expectApproxEqAbs(p.x, flat.left[i].x, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), flat.left[i].y, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, -1), flat.right[i].y, 1e-4);
    }

    // A right-angled turn: the outside corner is pushed further than half the width,
    // so the two pieces meet along one edge rather than leaving a wedge.
    const bend = [_]rl.Vector2{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 4 } };
    const turned = try sides(gpa, &bend, 2, 4);
    defer gpa.free(turned.left);
    defer gpa.free(turned.right);
    const corner = rl.Vector2Distance(turned.left[1], bend[1]);
    try std.testing.expect(corner > 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(2.0)), corner, 1e-3);
    // Every piece keeps its width across: the two sides of the middle are as far
    // apart as the path is wide, measured through the corner.
    try std.testing.expectApproxEqAbs(@as(f32, 2 * @sqrt(2.0)), rl.Vector2Distance(turned.left[1], turned.right[1]), 1e-3);
}
test "a rib faces across the path, and reaches further round a corner" {
    const gpa = std.testing.allocator;

    // Straight along x: across is square to it, and nothing has to reach.
    const straight = [_]rl.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 8, .y = 0 },
    };
    const flat = try ribs(gpa, &straight, 4);
    defer gpa.free(flat);
    for (flat) |rib| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), rib.out.x, 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(rib.out.y), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), rib.lean, 1e-4);
    }

    // A right angle: the middle rib bisects it, and reaches out by root two, which is
    // what makes the two pieces meet along one edge instead of leaving a wedge of a gap.
    const corner = [_]rl.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 4, .y = 4 },
    };
    const bent = try ribs(gpa, &corner, 4);
    defer gpa.free(bent);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rl.Vector2Length(bent[1].out), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(0.5)), bent[1].lean, 1e-4);
    // The ends are square to their one segment and reach no further than themselves.
    try std.testing.expectApproxEqAbs(@as(f32, 1), bent[0].lean, 1e-4);

    // A turn so sharp the reach would run away with it: held to the limit instead.
    const sharp = [_]rl.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 0.5, .y = 0.5 },
    };
    const held = try ribs(gpa, &sharp, 4);
    defer gpa.free(held);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), held[1].lean, 1e-4);

    // Folded exactly back on itself there is no bisector to be had — the two ways across
    // are opposite and add to nothing — so it takes the way out and reaches no further.
    // Without that fallback this is a divide by nothing and the path comes out as NaN.
    const fold = [_]rl.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 0.1, .y = 0 },
    };
    const back = try ribs(gpa, &fold, 4);
    defer gpa.free(back);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rl.Vector2Length(back[1].out), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), back[1].lean, 1e-4);
}

test "the sides of a path are its ribs with a rectangle on them" {
    const gpa = std.testing.allocator;
    const line = [_]rl.Vector2{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 4, .y = 4 },
    };
    const rail = try ribs(gpa, &line, 4);
    defer gpa.free(rail);
    const edges = try sides(gpa, &line, 3, 4);
    defer gpa.free(edges.left);
    defer gpa.free(edges.right);

    // Whatever `sides` puts either side is the rib's own direction, one and a half out.
    for (line, 0..) |p, i| {
        const push = rl.Vector2Scale(rail[i].out, 1.5 / rail[i].lean);
        try std.testing.expectApproxEqAbs(p.x + push.x, edges.left[i].x, 1e-4);
        try std.testing.expectApproxEqAbs(p.y + push.y, edges.left[i].y, 1e-4);
        try std.testing.expectApproxEqAbs(p.x - push.x, edges.right[i].x, 1e-4);
        try std.testing.expectApproxEqAbs(p.y - push.y, edges.right[i].y, 1e-4);
    }
}

test "an upright face becomes a section the same way up" {
    const gpa = std.testing.allocator;
    // A doorway in a wall facing along z: two units across, three tall, standing between
    // y = 2 and y = 5 and off to one side in x.
    const ring = [_]rl.Vector3{
        .{ .x = 10, .y = 2, .z = 0 },
        .{ .x = 12, .y = 2, .z = 0 },
        .{ .x = 12, .y = 5, .z = 0 },
        .{ .x = 10, .y = 5, .z = 0 },
    };
    const flat = try section(gpa, &ring, .{ .x = 0, .y = 0, .z = 1 }, .{ .x = 0, .y = 1, .z = 0 });
    defer gpa.free(flat);
    try std.testing.expectEqual(@as(usize, 4), flat.len);

    var low = flat[0];
    var high = flat[0];
    for (flat) |q| {
        low.x = @min(low.x, q.x);
        low.y = @min(low.y, q.y);
        high.x = @max(high.x, q.x);
        high.y = @max(high.y, q.y);
    }
    // Its own size, kept: two across and three up.
    try std.testing.expectApproxEqAbs(@as(f32, 2), high.x - low.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 3), high.y - low.y, 1e-4);
    // Centred across the line, and standing on it rather than sunk through it — however
    // far from the origin the wall it was cut out of happened to be.
    try std.testing.expectApproxEqAbs(@as(f32, -1), low.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), high.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), low.y, 1e-4);
    // Counter-clockwise, which is what cutting it into convex pieces wants.
    try std.testing.expect(area2(flat) > 0);
}

test "a face lying flat is stood on end, keeping its shape" {
    const gpa = std.testing.allocator;
    // A hexagon drawn flat on the ground: the thing one reaches for to get a hexagonal
    // tunnel. Nothing in it is more up than anything else, so there is no up to keep —
    // what matters is that the shape survives.
    var hex: [6]rl.Vector3 = undefined;
    for (&hex, 0..) |*q, i| {
        const angle = std.math.tau * @as(f32, @floatFromInt(i)) / 6;
        q.* = .{ .x = 20 + @cos(angle) * 3, .y = 7, .z = -5 + @sin(angle) * 3 };
    }
    const flat = try section(gpa, &hex, .{ .x = 0, .y = 1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 });
    defer gpa.free(flat);
    try std.testing.expectEqual(@as(usize, 6), flat.len);

    var low = flat[0];
    var high = flat[0];
    for (flat) |q| {
        low.x = @min(low.x, q.x);
        low.y = @min(low.y, q.y);
        high.x = @max(high.x, q.x);
        high.y = @max(high.y, q.y);
    }
    // Six corner to corner and 5.196 flat to flat, which is what a hexagon of that size
    // measures. Which of the two ends up across and which up is not asserted: a face
    // lying flat has no up of its own, so the frame is chosen rather than found, and only
    // that the shape survives is worth holding to.
    const wide = high.x - low.x;
    const tall = high.y - low.y;
    try std.testing.expectApproxEqAbs(@as(f32, 6), @max(wide, tall), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 5.1962), @min(wide, tall), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), low.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), (low.x + high.x) / 2, 1e-4);

    // Its area survives the trip, which a shape that had been squashed or sheared on the
    // way would not: a face is not one thing in the level and another as a section.
    try std.testing.expectApproxEqAbs(@as(f32, 23.3827), area2(flat) / 2, 1e-2);
}

test "a section can be cut into convex pieces, so a path may be any shape at all" {
    const gpa = std.testing.allocator;
    // An archway: square legs and a step in, which is not convex.
    const ring = [_]rl.Vector3{
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 4, .y = 0, .z = 0 },
        .{ .x = 4, .y = 4, .z = 0 },
        .{ .x = 3, .y = 4, .z = 0 },
        .{ .x = 3, .y = 2, .z = 0 },
        .{ .x = 1, .y = 2, .z = 0 },
        .{ .x = 1, .y = 4, .z = 0 },
        .{ .x = 0, .y = 4, .z = 0 },
    };
    const flat = try section(gpa, &ring, .{ .x = 0, .y = 0, .z = 1 }, .{ .x = 0, .y = 1, .z = 0 });
    defer gpa.free(flat);

    var pieces = try decompose(gpa, flat);
    defer freePieces(gpa, &pieces);
    try std.testing.expect(pieces.items.len >= 2);
    var total: f32 = 0;
    for (pieces.items) |piece| {
        try std.testing.expect(isConvex(flat, piece.items));
        total += pieceArea2(flat, piece);
    }
    // Every piece convex, and the pieces are the whole of it: a tunnel of this shape is
    // several brushes and no more solid than the one hole it came from.
    try std.testing.expectApproxEqAbs(area2(flat), total, 1e-3);
}
test "several faces of one surface settle together, keeping the gap between them" {
    const gpa = std.testing.allocator;
    // Two squares side by side in one plane, with a unit of nothing between them: the
    // simplest thing shaped like a ring left by an inset.
    const left = [_]rl.Vector3{
        .{ .x = 0, .y = 0, .z = 5 },
        .{ .x = 1, .y = 0, .z = 5 },
        .{ .x = 1, .y = 1, .z = 5 },
        .{ .x = 0, .y = 1, .z = 5 },
    };
    const right = [_]rl.Vector3{
        .{ .x = 2, .y = 0, .z = 5 },
        .{ .x = 3, .y = 0, .z = 5 },
        .{ .x = 3, .y = 1, .z = 5 },
        .{ .x = 2, .y = 1, .z = 5 },
    };
    const facing = rl.Vector3{ .x = 0, .y = 0, .z = 1 };
    const up = rl.Vector3{ .x = 0, .y = 1, .z = 0 };

    const a = try flatten(gpa, &left, facing, up);
    defer gpa.free(a);
    const b = try flatten(gpa, &right, facing, up);
    defer gpa.free(b);
    settle(&.{ a, b });

    var low = a[0];
    var high = a[0];
    for ([_][]rl.Vector2{ a, b }) |shape| {
        for (shape) |q| {
            low.x = @min(low.x, q.x);
            low.y = @min(low.y, q.y);
            high.x = @max(high.x, q.x);
            high.y = @max(high.y, q.y);
        }
    }
    // Three across the pair of them, centred on the line, standing on nought.
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), low.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), high.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), low.y, 1e-4);

    // And the two are still apart. Settled one at a time they would each be centred on
    // nothing and land on top of each other, and a ring would come out a solid bar.
    var a_low: f32 = a[0].x;
    var a_high: f32 = a[0].x;
    for (a) |q| {
        a_low = @min(a_low, q.x);
        a_high = @max(a_high, q.x);
    }
    var b_low: f32 = b[0].x;
    for (b) |q| b_low = @min(b_low, q.x);
    try std.testing.expectApproxEqAbs(@as(f32, -1.5), a_low, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), a_high, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), b_low, 1e-4);
    try std.testing.expect(b_low > a_high);

    // Both wound the way cutting them into convex pieces wants.
    try std.testing.expect(area2(a) > 0);
    try std.testing.expect(area2(b) > 0);
}
