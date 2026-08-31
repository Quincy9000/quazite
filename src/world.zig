const std = @import("std");
const store_module = @import("store.zig");

pub fn World(comptime Entity: type) type {
    return struct {
        systems: std.ArrayList(System) = .empty,
        /// The entities, one row each, packed: a removal moves the last row into the
        /// gap, so a row number is only good until the next removal. Add and remove
        /// through the world — `addEntity`, `removeEntity`, `removeRow` — never on the
        /// table itself, so the ids stay right.
        entities: std.MultiArrayList(Entity) = .empty,
        /// Seconds each system's last update took, parallel to `systems` — filled only
        /// while a clock is set.
        spent: std.ArrayList(f64) = .empty,
        /// One slot per id ever handed out: which row its entity is on now, and how
        /// many entities have had the slot. An id names a slot and the generation it
        /// was given at; a removal bumps the generation, so every old id to that slot
        /// is dead, and the slot goes on to the next entity spawned.
        slots: std.ArrayList(Slot) = .empty,
        /// Slots whose entity is gone, ready to be given out again.
        free: std.ArrayList(u32) = .empty,
        /// Each row's slot, parallel to `entities`: the way back from a row to its id.
        keys: std.ArrayList(u32) = .empty,
        /// The world's singletons: one value of each type, for whatever is state but
        /// not an entity — the hour, the score, the window. Put in by the plugin that
        /// owns one, taken by type by any system, and changed in place: the pointer
        /// holds still for as long as the resource is in. Gone with the world, so a
        /// restart begins with fresh ones.
        resources: std.AutoHashMapUnmanaged(usize, Resource) = .empty,

        const Self = @This();
        pub const Field = std.meta.FieldEnum(Entity);

        /// A resource as the world holds it: boxed on the heap behind a pointer with no
        /// type, and the one function that knows the type well enough to free it.
        const Resource = struct {
            ptr: *anyopaque,
            free: *const fn (std.mem.Allocator, *anyopaque) void,
        };

        /// An entity's name for as long as it lives: what one entity holds to point at
        /// another. Not a pointer and not a row, so it cannot dangle: an entity that
        /// has been removed makes every id to it answer "gone" — `alive`, `rowOf` and
        /// `get` all say so — and the game decides what to do about that. Two u32s, so
        /// it goes in a component and in a save; but a load spawns entities afresh
        /// with new ids, so an id kept across a save has to be re-found.
        pub const Id = struct {
            index: u32,
            generation: u32,

            /// No entity at all: what a component holds before it points at anything.
            /// Never alive.
            pub const none: Id = .{ .index = std.math.maxInt(u32), .generation = 0 };

            pub fn eql(a: Id, b: Id) bool {
                return a.index == b.index and a.generation == b.generation;
            }
        };

        const Slot = struct {
            generation: u32 = 0,
            row: u32 = no_row,
        };

        const no_row = std.math.maxInt(u32);

        /// A stopwatch, in seconds, for timing the systems. Null, and nothing is timed.
        pub var clock: ?*const fn () f64 = null;

        /// A world held still: the updates do not run, only the systems that asked to
        /// go on regardless, and the drawing — so the country stands there, looked at
        /// but not turning. Set by whatever owns the pause.
        pub var paused: bool = false;

        pub const System = @import("system.zig").System(Self);

        /// A save of this world: chunks by key, walked by the entity type's own rules
        /// about what can be written.
        pub const Store = store_module.Store(Entity);

        /// Registers systems and entities on the world it is handed.
        pub const Plugin = *const fn (*Self, std.mem.Allocator) anyerror!void;

        pub fn deinit(world: *Self, gpa: std.mem.Allocator) void {
            world.systems.deinit(gpa);
            world.spent.deinit(gpa);
            world.entities.deinit(gpa);
            world.slots.deinit(gpa);
            world.free.deinit(gpa);
            world.keys.deinit(gpa);
            var boxes = world.resources.valueIterator();
            while (boxes.next()) |box| box.free(gpa, box.ptr);
            world.resources.deinit(gpa);
        }

        // ---- resources ----

        /// Puts a value in as the world's one of its type, in place of any there was.
        /// The value is copied onto the heap, so the pointer handed back — and every
        /// one `resource` hands out after — holds still until it is removed. A plugin
        /// does this as it registers, so a rebuilt world has a fresh one.
        pub fn insertResource(world: *Self, gpa: std.mem.Allocator, value: anytype) !*@TypeOf(value) {
            const T = @TypeOf(value);
            const box = try gpa.create(T);
            errdefer gpa.destroy(box);
            box.* = value;
            const slot = try world.resources.getOrPut(gpa, typeId(T));
            if (slot.found_existing) slot.value_ptr.free(gpa, slot.value_ptr.ptr);
            slot.value_ptr.* = .{ .ptr = @ptrCast(box), .free = freer(T) };
            return box;
        }

        /// The world's one of a type, to read or change. Asking for one that was never
        /// put in is a plugin registered before the one it leans on, and says so.
        pub fn resource(world: *const Self, comptime T: type) *T {
            return world.getResource(T) orelse @panic("no such resource: " ++ @typeName(T));
        }

        /// The world's one of a type, or null when there is none: for a system that can
        /// do without.
        pub fn getResource(world: *const Self, comptime T: type) ?*T {
            const found = world.resources.get(typeId(T)) orelse return null;
            return @ptrCast(@alignCast(found.ptr));
        }

        pub fn hasResource(world: *const Self, comptime T: type) bool {
            return world.resources.contains(typeId(T));
        }

        /// Takes the world's one of a type out and frees its box. Whatever the value
        /// itself owned is its owner's to have let go of first. Whether there was one.
        pub fn removeResource(world: *Self, gpa: std.mem.Allocator, comptime T: type) bool {
            const removed = world.resources.fetchRemove(typeId(T)) orelse return false;
            removed.value.free(gpa, removed.value.ptr);
            return true;
        }

        pub fn addPlugin(world: *Self, gpa: std.mem.Allocator, plugin: Plugin) !void {
            try plugin(world, gpa);
        }

        pub fn addSystem(world: *Self, gpa: std.mem.Allocator, system: System) !void {
            try world.systems.append(gpa, system);
            try world.spent.append(gpa, 0);
        }

        // ---- entities, by id ----

        /// Puts an entity in and hands back its id: a free slot's, given again with a
        /// new generation, or a new slot's. The room for the row is made first, so a
        /// failure leaves nothing half done.
        pub fn addEntity(world: *Self, gpa: std.mem.Allocator, entity: Entity) !Id {
            try world.entities.ensureUnusedCapacity(gpa, 1);
            try world.keys.ensureUnusedCapacity(gpa, 1);
            const index: u32 = world.free.pop() orelse blk: {
                try world.slots.append(gpa, .{});
                // Every slot may be free at once: room for that now, so a removal
                // never has to allocate and never fails.
                try world.free.ensureTotalCapacity(gpa, world.slots.items.len);
                break :blk @intCast(world.slots.items.len - 1);
            };
            const slot = &world.slots.items[index];
            slot.row = @intCast(world.entities.len);
            world.entities.appendAssumeCapacity(entity);
            world.keys.appendAssumeCapacity(index);
            return .{ .index = index, .generation = slot.generation };
        }

        /// Takes an entity out by id, if it is still there: whether it was. Every id
        /// to it is dead from here.
        pub fn removeEntity(world: *Self, id: Id) bool {
            const row = world.rowOf(id) orelse return false;
            world.removeRow(row);
            return true;
        }

        /// Takes the entity on a row out. The last row moves into the gap, and its id
        /// is told where it went; the removed entity's slot is bumped and freed. Not
        /// for the middle of a query's walk — the walk would skip the moved row — so
        /// collect ids as you go and remove them after.
        pub fn removeRow(world: *Self, row: usize) void {
            const index = world.keys.items[row];
            const slot = &world.slots.items[index];
            slot.generation +%= 1;
            slot.row = no_row;
            world.free.appendAssumeCapacity(index);

            world.entities.swapRemove(row);
            _ = world.keys.swapRemove(row);
            if (row < world.keys.items.len) world.slots.items[world.keys.items[row]].row = @intCast(row);
        }

        /// Whether the entity an id names is still in the world.
        pub fn alive(world: *const Self, id: Id) bool {
            return world.rowOf(id) != null;
        }

        /// The row an id's entity is on now, or null if it is gone — or never was.
        /// Good until the next removal: take it, use it, let it go.
        pub fn rowOf(world: *const Self, id: Id) ?usize {
            if (id.index >= world.slots.items.len) return null;
            const slot = world.slots.items[id.index];
            if (slot.generation != id.generation or slot.row == no_row) return null;
            return slot.row;
        }

        /// The id of the entity on a row: for a walk over the table that wants to hold
        /// on to something it found.
        pub fn idAt(world: *const Self, row: usize) Id {
            const index = world.keys.items[row];
            return .{ .index = index, .generation = world.slots.items[index].generation };
        }

        /// One component of an id's entity, to read or change: null if the entity is
        /// gone, and null if it is there but has no such component.
        pub fn get(world: *Self, id: Id, comptime field: Field) ?ComponentPtr(field) {
            const row = world.rowOf(id) orelse return null;
            const cell = &world.entities.items(field)[row];
            return switch (@typeInfo(@FieldType(Entity, @tagName(field)))) {
                .optional => if (cell.* == null) null else &cell.*.?,
                else => cell,
            };
        }

        /// A pointer to a component, through its optional if it has one.
        pub fn ComponentPtr(comptime field: Field) type {
            const T = @FieldType(Entity, @tagName(field));
            return switch (@typeInfo(T)) {
                .optional => |optional| *optional.child,
                else => *T,
            };
        }

        /// Fires onStart once, in the order the systems were added.
        pub fn start(world: *Self) void {
            for (world.systems.items) |system| system.start(world);
        }

        /// Fires every onUpdate, then every onDraw, each in the order the
        /// systems were added — simulation settles before anything renders.
        pub fn run(world: *Self) void {
            const held = paused;
            if (clock) |now| {
                for (world.systems.items, 0..) |system, i| {
                    if (held and !system.always) {
                        world.spent.items[i] = 0;
                        continue;
                    }
                    const began = now();
                    system.update(world);
                    world.spent.items[i] = now() - began;
                }
            } else {
                for (world.systems.items) |system| {
                    if (held and !system.always) continue;
                    system.update(world);
                }
            }
            for (world.systems.items) |system| system.draw(world);
        }

        /// Fires onSave once, in order: every system writes what it owns.
        pub fn save(world: *Self, store: *Store) void {
            for (world.systems.items) |system| system.save(world, store);
        }

        /// Fires onLoad once, in order — the same order the world was built in, so what
        /// a system reads back can lean on what the systems before it have restored.
        pub fn load(world: *Self, store: *Store) void {
            for (world.systems.items) |system| system.load(world, store);
        }

        /// Fires onCleanup once, in reverse order, so teardown mirrors setup.
        pub fn stop(world: *Self) void {
            var i = world.systems.items.len;
            while (i > 0) {
                i -= 1;
                world.systems.items[i].cleanup(world);
            }
        }

        pub fn query(world: *Self, comptime fields: anytype) Query(fields) {
            return .{ .world = world, .columns = world.entities.slice() };
        }

        pub fn Query(comptime fields: anytype) type {
            return struct {
                world: *Self,
                index: usize = 0,
                /// The columns' pointers, taken once. Asking the table for a column
                /// walks every field's pointer to find the one — forty of them — and
                /// a query that asked per row spent most of its time on that walk:
                /// forty microseconds over a thousand rows to find nothing. Taken
                /// again if the table has been moved since, so a spawn mid-walk still
                /// cannot leave a query reading freed memory.
                columns: std.MultiArrayList(Entity).Slice,

                pub const Item = item: {
                    var names: [fields.len][]const u8 = undefined;
                    var types: [fields.len]type = undefined;
                    for (fields, &names, &types) |field, *name, *Component| {
                        name.* = @tagName(@as(Field, field));
                        Component.* = switch (@typeInfo(@FieldType(Entity, @tagName(@as(Field, field))))) {
                            .optional => |optional| *optional.child,
                            else => *@FieldType(Entity, @tagName(@as(Field, field))),
                        };
                    }
                    break :item @Struct(.auto, null, &names, &types, &@splat(.{}));
                };

                /// Yields every entity that has all of the queried components,
                /// skipping those whose optional components are null.
                pub fn next(q: *@This()) ?Item {
                    if (q.columns.capacity != q.world.entities.capacity) q.columns = q.world.entities.slice();
                    rows: while (q.index < q.world.entities.len) {
                        defer q.index += 1;
                        var item: Item = undefined;
                        inline for (fields) |field| {
                            const component = &q.column(@as(Field, field))[q.index];
                            @field(item, @tagName(@as(Field, field))) = switch (@typeInfo(@TypeOf(component.*))) {
                                .optional => if (component.* == null) continue :rows else &component.*.?,
                                else => component,
                            };
                        }
                        return item;
                    }
                    return null;
                }

                /// The id of the entity `next` last gave: for holding on to it past
                /// the walk, or handing it to another entity to hold.
                pub fn id(q: *const @This()) Id {
                    return q.world.idAt(q.index - 1);
                }

                /// One column, unbounded: the rows are counted against the table's
                /// own length, which a spawn mid-walk may have grown past the slice's.
                fn column(q: *const @This(), comptime field: Field) [*]@FieldType(Entity, @tagName(field)) {
                    return @ptrCast(@alignCast(q.columns.ptrs[@intFromEnum(field)]));
                }
            };
        }
    };
}

/// A number for a type: the same every time the same type is asked about, and never
/// another's. It is the address of a byte declared once per type — a type the world
/// has never been asked about has no byte, and one asked about twice has one.
pub fn typeId(comptime T: type) usize {
    const Tag = struct {
        comptime {
            _ = T;
        }
        var byte: u8 = 0;
    };
    return @intFromPtr(&Tag.byte);
}

/// The one function that frees a box of a type, kept beside the box so the world can
/// free what it holds without knowing what it is.
fn freer(comptime T: type) *const fn (std.mem.Allocator, *anyopaque) void {
    return &struct {
        fn free(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            gpa.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
        }
    }.free;
}

// ---- tests: zig build test ----

const TestEntity = struct {
    position: f32,
    target: ?Id = null,
    tag: ?u8 = null,

    const Id = World(TestEntity).Id;
};

test "an id outlives a row but not its entity" {
    const gpa = std.testing.allocator;
    var w: World(TestEntity) = .{};
    defer w.deinit(gpa);

    const a = try w.addEntity(gpa, .{ .position = 1 });
    const b = try w.addEntity(gpa, .{ .position = 2 });
    const c = try w.addEntity(gpa, .{ .position = 3, .tag = 7 });
    try std.testing.expect(w.alive(a) and w.alive(b) and w.alive(c));
    try std.testing.expectEqual(@as(f32, 3), w.get(c, .position).?.*);
    try std.testing.expectEqual(@as(u8, 7), w.get(c, .tag).?.*);
    // There, but without the component: null too, and `alive` tells the two apart.
    try std.testing.expectEqual(@as(?*u8, null), w.get(a, .tag));
    try std.testing.expect(w.alive(a));

    // Removing the first row moves the last entity into it; its id still finds it.
    try std.testing.expect(w.removeEntity(a));
    try std.testing.expect(!w.alive(a));
    try std.testing.expectEqual(@as(?usize, 0), w.rowOf(c));
    try std.testing.expectEqual(@as(f32, 3), w.get(c, .position).?.*);
    try std.testing.expect(w.idAt(0).eql(c));
    try std.testing.expect(!w.removeEntity(a));

    // The freed slot goes to the next entity with a new generation: the old id is
    // still dead, the new one alive, though they share an index.
    const d = try w.addEntity(gpa, .{ .position = 4 });
    try std.testing.expectEqual(a.index, d.index);
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!w.alive(a));
    try std.testing.expectEqual(@as(f32, 4), w.get(d, .position).?.*);
    try std.testing.expectEqual(@as(?*f32, null), w.get(a, .position));

    // An id held in a component, followed — and then found wanting.
    w.entities.items(.target)[w.rowOf(b).?] = c;
    const target = w.get(b, .target).?.*;
    try std.testing.expect(w.alive(target));
    try std.testing.expectEqual(@as(f32, 3), w.get(target, .position).?.*);
    try std.testing.expect(w.removeEntity(target));
    try std.testing.expect(w.get(b, .target) != null); // b still holds it
    try std.testing.expect(!w.alive(w.get(b, .target).?.*)); // but it points at nothing now
    try std.testing.expectEqual(@as(?*f32, null), w.get(target, .position));

    // Nothing is never alive, and an id from some other world's count is not either.
    try std.testing.expect(!w.alive(TestEntity.Id.none));
    try std.testing.expect(!w.alive(.{ .index = 1000, .generation = 0 }));
}

test "a walk hands out ids, and removing after the walk keeps every survivor findable" {
    const gpa = std.testing.allocator;
    var w: World(TestEntity) = .{};
    defer w.deinit(gpa);

    var ids: [10]TestEntity.Id = undefined;
    for (&ids, 0..) |*id, i| id.* = try w.addEntity(gpa, .{ .position = @floatFromInt(i), .tag = @intCast(i % 3) });

    // Collect the ones to go during the walk, remove them after it.
    var doomed: [10]TestEntity.Id = undefined;
    var count: usize = 0;
    var walk = w.query(.{ .position, .tag });
    while (walk.next()) |entity| {
        try std.testing.expect(walk.id().eql(ids[@intFromFloat(entity.position.*)]));
        if (entity.tag.* == 0) {
            doomed[count] = walk.id();
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), count);
    for (doomed[0..count]) |id| try std.testing.expect(w.removeEntity(id));

    // Every survivor's id still finds its own row, wherever the swaps put it.
    try std.testing.expectEqual(@as(usize, 6), w.entities.len);
    for (ids, 0..) |id, i| {
        if (i % 3 == 0) {
            try std.testing.expect(!w.alive(id));
        } else {
            try std.testing.expectEqual(@as(f32, @floatFromInt(i)), w.get(id, .position).?.*);
            try std.testing.expect(w.idAt(w.rowOf(id).?).eql(id));
        }
    }

    // Removing every row from the end, the way a purge does, empties the world; the
    // slots come back in new generations after.
    var row = w.entities.len;
    while (row > 0) {
        row -= 1;
        w.removeRow(row);
    }
    try std.testing.expectEqual(@as(usize, 0), w.entities.len);
    const again = try w.addEntity(gpa, .{ .position = 99 });
    try std.testing.expect(w.alive(again));
    for (ids) |id| try std.testing.expect(!w.alive(id));
}
