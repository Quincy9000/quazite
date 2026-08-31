//! What every module of the framework needs from the game: its entity type, its
//! config, and an allocator — and the few things built on those that every module
//! shares. A game hands these over once as a spec:
//!
//!     const Spec = struct {
//!         pub const Entity = struct { position: rl.Vector3, ... };
//!         pub const config: world.Config = .{ .game_title = "mine" };   // optional
//!         pub const gpa = std.heap.smp_allocator;                        // optional
//!     };
//!
//! and every `Module(Spec)` in the framework reaches for the same `Core(Spec)`, so
//! they all agree on one world type.

const std = @import("std");
const Engine = @import("engine.zig").Engine;
const Config = @import("config.zig").Config;

pub fn Core(comptime Spec: type) type {
    return struct {
        pub const Entity = Spec.Entity;
        pub const config: Config = if (@hasDecl(Spec, "config")) Spec.config else .{};
        pub const gpa: std.mem.Allocator = if (@hasDecl(Spec, "gpa")) Spec.gpa else std.heap.smp_allocator;

        pub const E = Engine(Entity);
        pub const W = E.W;
        pub const Field = W.Field;

        /// Every field of the entity that is an optional of a component type: a plugin
        /// that works on any entity carrying its component finds the fields by type, so
        /// a game names them what it likes, and may have more than one.
        pub fn fieldsOf(comptime T: type) []const Field {
            comptime {
                var found: []const Field = &.{};
                for (std.meta.fields(Entity)) |field| {
                    const inner = switch (@typeInfo(field.type)) {
                        .optional => |optional| optional.child,
                        else => field.type,
                    };
                    if (inner == T) found = found ++ &[_]Field{@field(Field, field.name)};
                }
                return found;
            }
        }

        // ---- what every system does with its own, around a save ----

        /// Takes every entity carrying a component out of the world. A system does this
        /// with its own before reading them back, so a load never doubles what it owns.
        pub fn purge(w: *W, comptime field: Field) void {
            var i = w.entities.len;
            while (i > 0) {
                i -= 1;
                if (w.entities.items(field)[i] == null) continue;
                w.removeRow(i);
            }
        }

        /// Writes every entity carrying a component, whole.
        pub fn keepAll(w: *W, out: W.Store.Writer, comptime field: Field) void {
            var count: u32 = 0;
            for (w.entities.items(field)) |component| {
                if (component != null) count += 1;
            }
            out.put(u32, count);
            for (w.entities.items(field), 0..) |component, i| {
                if (component == null) continue;
                out.put(Entity, w.entities.get(i));
            }
        }

        /// Reads back what `keepAll` wrote, entity by entity. They come back with new
        /// ids: an id one of them holds to another was written as it was, and points
        /// at nothing now.
        pub fn recallAll(w: *W, in: *W.Store.Reader) void {
            const count = in.get(u32);
            for (0..count) |_| {
                if (in.short) return;
                _ = w.addEntity(gpa, in.get(Entity)) catch @panic("out of memory");
            }
        }
    };
}
