//! Box3D as a plugin, taken or left — the way Bevy's are. A game that wants bodies sets
//! `physics = true` in build.zig, which compiles the C in, and adds `physics.plugin`; a
//! game that does not pays nothing for it: this file is never analysed and box3d is
//! never built or linked.
//!
//! Bodies are components, the way Unity has them, in the kinds Godot names them:
//!
//!   `StaticBody`     stands still; everything else collides with it.
//!   `RigidBody`      simulated: falls, bounces, is pushed. The plugin writes where it
//!                    is into the entity's `position` and how it is turned and moving
//!                    into the component, every frame.
//!   `KinematicBody`  the game moves it — sets the entity's `position` and the
//!                    component's `rotation` — and it pushes what is in the way,
//!                    yielding to nothing.
//!   `CharacterBody`  a capsule the game drives with `moveAndSlide`: walked into the
//!                    world, slid along whatever it meets, stood on what is flat
//!                    enough. Rigid bodies bump into it; it never bumps into another
//!                    character — keeping characters apart is the game's.
//!
//! Give an entity one — a field of that type, named anything, next to a `position` —
//! and the plugin makes the box3d body for it where the entity stands, keeps the two
//! in step, and takes the body away when the entity goes. The drawing is the game's:
//! it reads `position` and `rotation` like any other component.
//!
//! Every body has a `BodyId` the plugin fills in, and every question and order goes
//! by it: `velocityOf(id)`, `push(id, ...)`, `place(id, ...)`, `entityOf(id)`. Box3d's
//! ids carry a generation the way the world's entity ids do, so an id whose body is
//! gone answers `valid` false and is safe to hold. A `BodyId` is not a save's to
//! keep: name it in `Entity.transient`, and a loaded body is made again where the
//! entity was.

const std = @import("std");
const rl = @import("raylib.zig").c;
pub const b3 = @import("box3d.zig").c;
const Clock = @import("clock.zig").Clock;

pub const BodyId = b3.b3BodyId;

/// No body yet. What every body component starts as, and what a load blanks the id
/// back to: the plugin makes a body for any component whose id is this.
pub const none: BodyId = std.mem.zeroes(BodyId);

const identity = rl.Quaternion{ .x = 0, .y = 0, .z = 0, .w = 1 };

const still = rl.Vector3{ .x = 0, .y = 0, .z = 0 };

/// A collider, about the body's centre.
pub const Shape = union(enum) {
    /// Half-widths.
    box: rl.Vector3,
    sphere: f32,
    /// Standing up.
    capsule: Capsule,
};

/// Two spheres of `radius`, their centres `half_length` above and below the middle.
pub const Capsule = struct {
    radius: f32,
    half_length: f32,
};

/// What a collider is made of. Density is what gives a rigid body its mass.
pub const Surface = struct {
    density: f32 = 1,
    friction: f32 = 0.6,
    restitution: f32 = 0,
};

pub const StaticBody = struct {
    shape: Shape,
    surface: Surface = .{},
    rotation: rl.Quaternion = identity,
    id: BodyId = none,
};

pub const RigidBody = struct {
    shape: Shape,
    surface: Surface = .{},
    /// Where it is turned and how it is moving, as of the last step. Set before the
    /// body is made, they are how it starts.
    rotation: rl.Quaternion = identity,
    velocity: rl.Vector3 = still,
    angular: rl.Vector3 = still,
    /// How much of the world's gravity it feels.
    gravity: f32 = 1,
    id: BodyId = none,
};

pub const KinematicBody = struct {
    shape: Shape,
    surface: Surface = .{},
    rotation: rl.Quaternion = identity,
    id: BodyId = none,
};

pub const CharacterBody = struct {
    capsule: Capsule,
    /// Set by the game — walking, gravity, a jump — and clipped by `moveAndSlide` to
    /// what the world allowed.
    velocity: rl.Vector3 = still,
    /// What the last `moveAndSlide` met.
    on_floor: bool = false,
    on_wall: bool = false,
    on_ceiling: bool = false,
    floor_normal: rl.Vector3 = .{ .x = 0, .y = 1, .z = 0 },
    /// How flat a plane must be to stand on: its normal's height, nought to one.
    floor_min: f32 = 0.7,
    /// How far down a character that just lost the floor reaches for it, so a step
    /// down is a step and not a fall.
    snap: f32 = 0.3,
    id: BodyId = none,
};

/// What the shapes are tagged with, so a character's sweep can leave characters out.
pub const Category = struct {
    pub const world: u64 = 1 << 0;
    pub const character: u64 = 1 << 1;
};

const max_planes = 64;

const Gathered = struct {
    planes: [max_planes]b3.b3CollisionPlane = undefined,
    count: usize = 0,
};

/// Called once per shape the capsule overlaps, with every plane that shape produced.
fn gather(_: b3.b3ShapeId, results: [*c]const b3.b3PlaneResult, count: c_int, context: ?*anyopaque) callconv(.c) bool {
    const found: *Gathered = @ptrCast(@alignCast(context.?));
    for (0..@intCast(count)) |index| {
        if (found.count == max_planes) return false;
        found.planes[found.count] = .{
            .plane = results[index].plane,
            .pushLimit = std.math.floatMax(f32),
            .push = 0,
            .clipVelocity = true,
        };
        found.count += 1;
    }
    return true;
}

/// One gather, one solve, one move. Everything box3d hands back is relative to where
/// the body stood when the planes were gathered.
fn slide(world: b3.b3WorldId, position: *rl.Vector3, character: *CharacterBody, capsule: b3.b3Capsule, delta: f32) void {
    var gathered: Gathered = .{};
    b3.b3World_CollideMover(world, toPos(position.*), &capsule, worldOnly(), gather, &gathered);
    const count: c_int = @intCast(gathered.count);

    const wanted = rl.Vector3Scale(character.velocity, delta);
    const solved = b3.b3SolvePlanes(toVec(wanted), &gathered.planes, count);
    position.* = rl.Vector3Add(position.*, fromVec(solved.delta));

    for (gathered.planes[0..gathered.count]) |plane| {
        if (plane.push <= 0) continue;
        const up = plane.plane.normal.y;
        if (up >= character.floor_min) {
            character.on_floor = true;
            character.floor_normal = fromVec(plane.plane.normal);
        } else if (up <= -character.floor_min) {
            character.on_ceiling = true;
        } else {
            character.on_wall = true;
        }
    }
    character.velocity = fromVec(b3.b3ClipVector(toVec(character.velocity), &gathered.planes, count));
}

/// The filter a character sweeps with: the world, never a character — its own body
/// least of all.
fn worldOnly() b3.b3QueryFilter {
    var filter = b3.b3DefaultQueryFilter();
    filter.maskBits = Category.world;
    return filter;
}

fn capsuleOf(capsule: Capsule) b3.b3Capsule {
    return .{
        .center1 = .{ .x = 0, .y = -capsule.half_length, .z = 0 },
        .center2 = .{ .x = 0, .y = capsule.half_length, .z = 0 },
        .radius = capsule.radius,
    };
}

fn attach(body: BodyId, shape: Shape, surface: Surface, category: u64) void {
    var def = b3.b3DefaultShapeDef();
    def.density = surface.density;
    def.baseMaterial.friction = surface.friction;
    def.baseMaterial.restitution = surface.restitution;
    def.filter.categoryBits = category;
    switch (shape) {
        .box => |half| {
            const hull = b3.b3MakeBoxHull(half.x, half.y, half.z);
            _ = b3.b3CreateHullShape(body, &def, &hull.base);
        },
        .sphere => |radius| {
            const ball = b3.b3Sphere{ .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = radius };
            _ = b3.b3CreateSphereShape(body, &def, &ball);
        },
        .capsule => |capsule| {
            const pill = capsuleOf(capsule);
            _ = b3.b3CreateCapsuleShape(body, &def, &pill);
        },
    }
}

pub fn valid(body: BodyId) bool {
    return b3.b3Body_IsValid(body);
}

/// Takes a body out of the world, if it is still in it. A component still holding
/// the id holds nothing, and `valid` says so; set it to `none` to have another made.
pub fn destroy(body: BodyId) void {
    if (b3.b3Body_IsValid(body)) b3.b3DestroyBody(body);
}

pub fn positionOf(body: BodyId) rl.Vector3 {
    return fromPos(b3.b3Body_GetPosition(body));
}

pub fn rotationOf(body: BodyId) rl.Quaternion {
    return fromQuat(b3.b3Body_GetRotation(body));
}

pub fn velocityOf(body: BodyId) rl.Vector3 {
    return fromVec(b3.b3Body_GetLinearVelocity(body));
}

pub fn setVelocity(body: BodyId, velocity: rl.Vector3) void {
    b3.b3Body_SetLinearVelocity(body, toVec(velocity));
}

pub fn angularOf(body: BodyId) rl.Vector3 {
    return fromVec(b3.b3Body_GetAngularVelocity(body));
}

pub fn setAngular(body: BodyId, angular: rl.Vector3) void {
    b3.b3Body_SetAngularVelocity(body, toVec(angular));
}

/// Puts a body somewhere, turned some way, at once: a teleport. What the plugin does
/// for a kinematic body every frame, from the entity's position.
pub fn place(body: BodyId, at: rl.Vector3, rotation: rl.Quaternion) void {
    b3.b3Body_SetTransform(body, toPos(at), toQuat(rotation));
}

/// A shove: an impulse through the centre, waking the body.
pub fn push(body: BodyId, impulse: rl.Vector3) void {
    b3.b3Body_ApplyLinearImpulseToCenter(body, toVec(impulse), true);
}

/// A steady force through the centre for this step, waking the body.
pub fn pull(body: BodyId, force: rl.Vector3) void {
    b3.b3Body_ApplyForceToCenter(body, toVec(force), true);
}

/// The model matrix for drawing a body where its entity is, turned as it is.
pub fn matrix(at: rl.Vector3, rotation: rl.Quaternion) rl.Matrix {
    return rl.MatrixMultiply(rl.QuaternionToMatrix(rotation), rl.MatrixTranslate(at.x, at.y, at.z));
}

pub fn toVec(v: rl.Vector3) b3.b3Vec3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

pub fn fromVec(v: b3.b3Vec3) rl.Vector3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

pub fn toPos(v: rl.Vector3) b3.b3Pos {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

pub fn fromPos(p: b3.b3Pos) rl.Vector3 {
    return .{ .x = @floatCast(p.x), .y = @floatCast(p.y), .z = @floatCast(p.z) };
}

pub fn toQuat(q: rl.Quaternion) b3.b3Quat {
    return .{ .v = .{ .x = q.x, .y = q.y, .z = q.z }, .s = q.w };
}

pub fn fromQuat(q: b3.b3Quat) rl.Quaternion {
    return .{ .x = q.v.x, .y = q.v.y, .z = q.v.z, .w = q.s };
}

fn isNone(id: BodyId) bool {
    return std.mem.eql(u8, std.mem.asBytes(&id), std.mem.asBytes(&none));
}

pub fn Module(comptime Spec: type) type {
    return struct {
        const core = @import("core.zig").Core(Spec);
        const components = core;
        const W = core.W;
        const Entity = core.Entity;
        const config = core.config;
        const gpa = core.gpa;

        // ---- the components ----

        // ---- the resource ----

        pub const Physics = struct {
            gpa: std.mem.Allocator,
            /// The box3d world, from start to cleanup, and null outside them.
            world: ?b3.b3WorldId = null,
            /// Frame time owed to the fixed step and not yet simulated.
            owed: f32 = 0,
            /// Steps taken since the world was made.
            steps: u64 = 0,
            /// Every body the plugin made for an entity, to take away when the entity goes.
            made: std.ArrayList(Made) = .empty,

            const Made = struct { body: BodyId, entity: W.Id };

            /// Simulates as many fixed steps as the seconds cover, keeping the remainder for
            /// next time. A long stall is not a long catch-up: past `physics_max_steps` the
            /// rest is dropped, and the world runs slow for a frame rather than freezing.
            pub fn advance(p: *Physics, seconds: f32) void {
                const world = p.world orelse return;
                const longest: f32 = config.physics_step * @as(f32, @floatFromInt(config.physics_max_steps));
                p.owed = @min(p.owed + seconds, longest);
                while (p.owed >= config.physics_step) : (p.owed -= config.physics_step) {
                    b3.b3World_Step(world, config.physics_step, config.physics_substeps);
                    p.steps += 1;
                }
            }

            pub const Kind = enum { static, kinematic, dynamic };

            /// A body of the plugin's own, not an entity's: for a game that wants one it holds
            /// the id of and drives itself — a bullet, a probe. Never taken away by the plugin;
            /// `destroy` it. `none` when there is no world yet.
            pub fn spawn(p: *const Physics, kind: Kind, at: rl.Vector3, rotation: rl.Quaternion, shape: Shape, surface: Surface) BodyId {
                return p.make(kind, at, rotation, shape, surface, Category.world, null);
            }

            fn make(p: *const Physics, kind: Kind, at: rl.Vector3, rotation: rl.Quaternion, shape: Shape, surface: Surface, category: u64, owner: ?W.Id) BodyId {
                const world = p.world orelse return none;
                var def = b3.b3DefaultBodyDef();
                def.type = switch (kind) {
                    .static => b3.b3_staticBody,
                    .kinematic => b3.b3_kinematicBody,
                    .dynamic => b3.b3_dynamicBody,
                };
                def.position = toPos(at);
                def.rotation = toQuat(rotation);
                if (owner) |id| def.userData = packId(id);
                const body = b3.b3CreateBody(world, &def);
                attach(body, shape, surface, category);
                return body;
            }

            /// The nearest thing along a line, if the line reaches one: `along` is the whole
            /// of the ray, not a direction.
            pub fn castRay(p: *const Physics, from: rl.Vector3, along: rl.Vector3) ?Hit {
                const world = p.world orelse return null;
                const result = b3.b3World_CastRayClosest(world, toPos(from), toVec(along), b3.b3DefaultQueryFilter());
                if (!result.hit) return null;
                const body = b3.b3Shape_GetBody(result.shapeId);
                return .{
                    .body = body,
                    .entity = entityOf(body),
                    .point = fromPos(result.point),
                    .normal = fromVec(result.normal),
                    .fraction = result.fraction,
                };
            }

            /// Drives a character by its velocity for `delta` seconds: walks it into the
            /// world, slides it along what it meets, stands it on what is flat enough, and
            /// clips its velocity to what is left. `on_floor`, `on_wall`, `on_ceiling` and
            /// `floor_normal` say what it met. Gravity and walking are the game's to put into
            /// the velocity first, the way Godot's is. The game calls this from its own
            /// system, for each entity with a character, with the entity's position.
            pub fn moveAndSlide(p: *const Physics, position: *rl.Vector3, character: *CharacterBody, delta: f32) void {
                const world = p.world orelse return;
                const capsule = capsuleOf(character.capsule);
                const had_floor = character.on_floor;
                character.on_floor = false;
                character.on_wall = false;
                character.on_ceiling = false;

                // Planes are gathered where the body stands, so a body that would cross more
                // than its own radius in one go is carried there in stages.
                const distance = rl.Vector3Length(character.velocity) * delta;
                const stages: usize = @intFromFloat(std.math.clamp(@ceil(distance / character.capsule.radius), 1, @as(f32, @floatFromInt(config.physics_max_steps))));
                const slice = delta / @as(f32, @floatFromInt(stages));
                for (0..stages) |_| slide(world, position, character, capsule, slice);

                // Walking off the edge of a step is a step, not a fall: a body that had the
                // floor a moment ago reaches down a little for it.
                if (had_floor and !character.on_floor and character.velocity.y <= 0 and character.snap > 0) {
                    const drop = rl.Vector3{ .x = 0, .y = -character.snap, .z = 0 };
                    const reached = b3.b3World_CastMover(world, toPos(position.*), &capsule, toVec(drop), worldOnly(), null, null);
                    if (reached < 1) {
                        position.* = rl.Vector3Add(position.*, rl.Vector3Scale(drop, reached));
                        character.on_floor = true;
                        character.velocity.y = 0;
                    }
                }

                // The body rigid things bump into goes where the character went.
                if (valid(character.id)) b3.b3Body_SetTransform(character.id, toPos(position.*), toQuat(identity));
            }

            /// The bodies the plugin made whose entities are gone, taken away; and the ones
            /// the game destroyed itself, forgotten.
            fn reap(p: *Physics, w: *const W) void {
                var i = p.made.items.len;
                while (i > 0) {
                    i -= 1;
                    const made = p.made.items[i];
                    if (!valid(made.body)) {
                        _ = p.made.swapRemove(i);
                    } else if (!w.alive(made.entity)) {
                        b3.b3DestroyBody(made.body);
                        _ = p.made.swapRemove(i);
                    }
                }
            }
        };

        pub const Hit = struct {
            body: BodyId,
            /// The entity the body belongs to, if the plugin made it for one.
            entity: ?W.Id,
            point: rl.Vector3,
            normal: rl.Vector3,
            /// How far along the ray, nought to one.
            fraction: f32,
        };

        // ---- the character's sweep ----

        // ---- shapes ----

        // ---- asking and telling a body, by id ----

        /// The entity a body was made for, if the plugin made it for one.
        pub fn entityOf(body: BodyId) ?W.Id {
            if (!b3.b3Body_IsValid(body)) return null;
            return unpackId(b3.b3Body_GetUserData(body));
        }

        // ---- between the two worlds' numbers ----

        /// An entity id folded into the pointer box3d keeps for us on a body, and back. An id
        /// is two u32s, a pointer is wider; nothing is allocated. Zero is reserved for "no
        /// entity", so the index is kept one up.
        fn packId(id: W.Id) ?*anyopaque {
            const packed_id: usize = (@as(usize, id.generation) << 32) | (@as(usize, id.index) + 1);
            return @ptrFromInt(packed_id);
        }

        fn unpackId(data: ?*anyopaque) ?W.Id {
            const packed_id: usize = @intFromPtr(data orelse return null);
            return .{ .index = @intCast((packed_id & 0xffff_ffff) - 1), .generation = @intCast(packed_id >> 32) };
        }

        // ---- the entity's bodies ----

        /// A body made for every component that has none yet, where its entity stands.
        fn adopt(w: *W) void {
            const p = w.resource(Physics);
            inline for (comptime components.fieldsOf(StaticBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (!isNone(body.id)) continue;
                    body.id = p.make(.static, entity.position.*, body.rotation, body.shape, body.surface, Category.world, walk.id());
                    remember(p, body.id, walk.id());
                }
            }
            inline for (comptime components.fieldsOf(RigidBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (!isNone(body.id)) continue;
                    body.id = p.make(.dynamic, entity.position.*, body.rotation, body.shape, body.surface, Category.world, walk.id());
                    if (valid(body.id)) {
                        b3.b3Body_SetLinearVelocity(body.id, toVec(body.velocity));
                        b3.b3Body_SetAngularVelocity(body.id, toVec(body.angular));
                        b3.b3Body_SetGravityScale(body.id, body.gravity);
                    }
                    remember(p, body.id, walk.id());
                }
            }
            inline for (comptime components.fieldsOf(KinematicBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (!isNone(body.id)) continue;
                    body.id = p.make(.kinematic, entity.position.*, body.rotation, body.shape, body.surface, Category.world, walk.id());
                    remember(p, body.id, walk.id());
                }
            }
            inline for (comptime components.fieldsOf(CharacterBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (!isNone(body.id)) continue;
                    body.id = p.make(.kinematic, entity.position.*, identity, .{ .capsule = body.capsule }, .{}, Category.character, walk.id());
                    remember(p, body.id, walk.id());
                }
            }
        }

        fn remember(p: *Physics, body: BodyId, entity: W.Id) void {
            if (!valid(body)) return;
            p.made.append(p.gpa, .{ .body = body, .entity = entity }) catch @panic("out of memory");
        }

        /// Kinematic bodies carried to where their entities are: the game moved the entity,
        /// the body follows, and whatever is in the way is pushed.
        fn carry(w: *W) void {
            inline for (comptime components.fieldsOf(KinematicBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (valid(body.id)) place(body.id, entity.position.*, body.rotation);
                }
            }
        }

        /// Rigid bodies' entities put where their bodies are, turned and moving as they are.
        fn follow(w: *W) void {
            inline for (comptime components.fieldsOf(RigidBody)) |field| {
                var walk = w.query(.{ .position, field });
                while (walk.next()) |entity| {
                    const body = @field(entity, @tagName(field));
                    if (!valid(body.id)) continue;
                    entity.position.* = positionOf(body.id);
                    body.rotation = rotationOf(body.id);
                    body.velocity = velocityOf(body.id);
                    body.angular = angularOf(body.id);
                }
            }
        }

        // ---- the systems ----

        fn make(w: *W) void {
            // Before any default is asked for: box3d works out its own thresholds from this,
            // and the defs carry those numbers away with them.
            b3.b3SetLengthUnitsPerMeter(config.units_per_meter);
            var def = b3.b3DefaultWorldDef();
            def.gravity = toVec(config.gravity);
            const p = w.resource(Physics);
            p.world = b3.b3CreateWorld(&def);
            p.owed = 0;
            p.steps = 0;
        }

        fn step(w: *W) void {
            const p = w.resource(Physics);
            p.reap(w);
            adopt(w);
            carry(w);
            p.advance(w.resource(Clock).delta);
            follow(w);
        }

        /// The world gone, and every body with it: a component still holding an id holds
        /// nothing, and `valid` says so.
        fn unmake(w: *W) void {
            const p = w.resource(Physics);
            if (p.world) |world| b3.b3DestroyWorld(world);
            p.world = null;
            p.made.deinit(p.gpa);
            p.made = .empty;
        }

        pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
            _ = try w.insertResource(allocator, Physics{ .gpa = allocator });
            // After the clock, whose step it takes; before anything that reads where a body is.
            try w.addSystem(allocator, .{ .name = "physics", .onStart = make, .onUpdate = step, .onCleanup = unmake });
        }

        // ---- tests: zig build test -Dphysics=true ----

        test "a crate dropped on a floor comes to rest on it, and a ray finds it" {
            var w: W = .{};
            defer w.deinit(gpa);
            try w.addPlugin(gpa, plugin);
            w.start();
            defer w.stop();

            const p = w.resource(Physics);
            try std.testing.expect(p.world != null);
            _ = p.spawn(.static, .{ .x = 0, .y = -1, .z = 0 }, identity, .{ .box = .{ .x = 50, .y = 1, .z = 50 } }, .{});
            const crate = p.spawn(.dynamic, .{ .x = 0, .y = 20, .z = 0 }, identity, .{ .box = .{ .x = 1, .y = 1, .z = 1 } }, .{});
            try std.testing.expect(valid(crate));
            try std.testing.expect(entityOf(crate) == null);

            for (0..240) |_| p.advance(1.0 / 60.0);
            try std.testing.expectApproxEqAbs(@as(f32, 1), positionOf(crate).y, 0.1);
            try std.testing.expect(p.steps == 240);

            const hit = p.castRay(.{ .x = 0, .y = 10, .z = 0 }, .{ .x = 0, .y = -20, .z = 0 }) orelse return error.NoHit;
            try std.testing.expect(b3.B3_ID_EQUALS(hit.body, crate));
            try std.testing.expect(hit.entity == null);
            try std.testing.expectApproxEqAbs(@as(f32, 2), hit.point.y, 0.1);

            destroy(crate);
            try std.testing.expect(!valid(crate));
            destroy(crate); // twice is nothing
        }

        test "a character walks into a wall and slides along it, and stands on the floor" {
            var w: W = .{};
            defer w.deinit(gpa);
            try w.addPlugin(gpa, plugin);
            w.start();
            defer w.stop();

            const p = w.resource(Physics);
            _ = p.spawn(.static, .{ .x = 0, .y = -1, .z = 0 }, identity, .{ .box = .{ .x = 50, .y = 1, .z = 50 } }, .{});
            // A wall across x = 5.
            _ = p.spawn(.static, .{ .x = 6, .y = 5, .z = 0 }, identity, .{ .box = .{ .x = 1, .y = 5, .z = 50 } }, .{});

            var character = CharacterBody{ .capsule = .{ .radius = 0.5, .half_length = 0.5 } };
            var at = rl.Vector3{ .x = 0, .y = 3, .z = 0 };
            // Falls to the floor under gravity the game applies, the way Godot has it.
            for (0..120) |_| {
                character.velocity.y -= 9.8 / 60.0;
                p.moveAndSlide(&at, &character, 1.0 / 60.0);
            }
            try std.testing.expect(character.on_floor);
            // Feet on y 0: the middle a half-length and a radius up.
            try std.testing.expectApproxEqAbs(@as(f32, 1), at.y, 0.05);
            try std.testing.expectApproxEqAbs(@as(f32, 0), character.velocity.y, 0.001);

            // Walks east into the wall: stopped at it, sliding north along it, still afoot.
            for (0..120) |_| {
                character.velocity = .{ .x = 4, .y = character.velocity.y - 9.8 / 60.0, .z = 1 };
                p.moveAndSlide(&at, &character, 1.0 / 60.0);
            }
            try std.testing.expect(character.on_wall);
            try std.testing.expect(character.on_floor);
            try std.testing.expect(at.x < 5.01 and at.x > 4.3);
            try std.testing.expect(at.z > 1.5);
            try std.testing.expectApproxEqAbs(@as(f32, 0), character.velocity.x, 0.001);
        }

        test "bodies are made for components, followed, and taken away with their entities" {
            if (comptime components.fieldsOf(RigidBody).len == 0) return error.SkipZigTest;

            var w: W = .{};
            defer w.deinit(gpa);
            try w.addPlugin(gpa, @import("clock.zig").Module(Spec).plugin);
            try w.addPlugin(gpa, plugin);
            w.start();
            defer w.stop();
            const p = w.resource(Physics);
            const field = comptime components.fieldsOf(RigidBody)[0];

            var falling: Entity = .{ .position = .{ .x = 3, .y = 20, .z = 0 } };
            @field(falling, @tagName(field)) = .{ .shape = .{ .box = .{ .x = 1, .y = 1, .z = 1 } } };
            const crate = try w.addEntity(gpa, falling);

            w.resource(Clock).delta = 1.0 / 60.0;
            step(&w);
            const body = @field(w.entities.get(w.rowOf(crate).?), @tagName(field)).?;
            try std.testing.expect(valid(body.id));
            try std.testing.expect(entityOf(body.id).?.eql(crate));
            try std.testing.expectEqual(@as(usize, 1), p.made.items.len);

            for (0..59) |_| step(&w);
            const at = w.entities.items(.position)[w.rowOf(crate).?];
            try std.testing.expectApproxEqAbs(@as(f32, 3), at.x, 0.001);
            try std.testing.expect(at.y < 20);

            _ = w.removeEntity(crate);
            step(&w);
            try std.testing.expect(!valid(body.id));
            try std.testing.expectEqual(@as(usize, 0), p.made.items.len);
        }
    };
}
