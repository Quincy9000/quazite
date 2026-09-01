//! A save, in between the systems and the disk: chunks of bytes by key. On save each
//! system writes what it owns under a key of its own; on load each reads its own back.
//! The store never knows what a chunk means — only the system that wrote it does — and
//! the file is the chunks laid end to end behind a fingerprint of the types they were
//! written from, so a save from another build is refused rather than misread.
//!
//! Values are written field by field, walked by comptime over the very types the game
//! runs on. What cannot be written — anything behind a pointer, and whatever the rules
//! type names as transient — is skipped on the way out and blanked on the way in, for
//! its owner to rebuild.

const std = @import("std");
const Allocator = std.mem.Allocator;

const magic = "ZGSV";

/// A store whose walk over the types skips what `Rules.transient` says to, on top of
/// every pointer. Hand it the entity type: its fields' shapes make the fingerprint.
pub fn Store(comptime Rules: type) type {
    return struct {
        gpa: Allocator,
        chunks: std.StringArrayHashMapUnmanaged(Chunk) = .empty,

        const Self = @This();
        const Chunk = std.ArrayListUnmanaged(u8);

        /// The container's own format: the layout of the file around the chunks, and
        /// nothing about what is in them. Set by hand, and bumped only when that layout
        /// changes.
        ///
        /// It was a fingerprint of the whole entity type's field shape, and that guarded
        /// the wrong thing in both directions. Nothing writes an entity wholesale — a
        /// save only fires `onSave` and every system writes what it owns — so a field
        /// added to the entity changed the fingerprint and refused every file ever
        /// written, against a risk that did not exist. Meanwhile the types that ARE
        /// written field by field through `put` are the game's own, a grid or a shape
        /// record, and those are not in the entity's shape at all: a field added to one
        /// of them changed nothing, and the next load read the old bytes into the new
        /// layout without a word.
        ///
        /// The guard belongs where the risk is: on the chunk, against the type actually
        /// written into it. See `writerFor`.
        pub const format: u32 = 1;

        /// One type's field shape folded to a number, for stamping a chunk with the shape
        /// of what was written into it.
        pub fn shapeOf(comptime T: type) u32 {
            @setEvalBranchQuota(1_000_000);
            return comptime std.hash.Fnv1a_32.hash(shape(T));
        }

        pub const ParseError = error{ NotASave, OtherVersion, CutShort, OutOfMemory };

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(store: *Self) void {
            for (store.chunks.keys(), store.chunks.values()) |key, *chunk| {
                store.gpa.free(key);
                chunk.deinit(store.gpa);
            }
            store.chunks.deinit(store.gpa);
        }

        /// Somewhere to write under a key, made on first use. Writing to a key twice
        /// appends: a system that writes in two places reads in the same two.
        pub fn writer(store: *Self, key: []const u8) Writer {
            if (store.chunks.getIndex(key)) |index| return .{ .store = store, .index = index };
            const owned = store.gpa.dupe(u8, key) catch @panic("out of memory");
            store.chunks.put(store.gpa, owned, .empty) catch @panic("out of memory");
            return .{ .store = store, .index = store.chunks.getIndex(key).? };
        }

        /// What was written under a key, if anything was.
        pub fn reader(store: *const Self, key: []const u8) ?Reader {
            const chunk = store.chunks.get(key) orelse return null;
            return .{ .bytes = chunk.items };
        }

        /// The same, stamped with the shape of the type written there. Use this — and its
        /// reader — for any chunk that puts a struct, an enum or a union of the game's
        /// own: `put` walks fields positionally and by order alone, so a field added to
        /// such a type turns every older chunk into nonsense that reads without error.
        ///
        /// A chunk of nothing but plain numbers written out by hand needs no stamp, and
        /// `writer` stays the way to make one. The stamp goes on once, when the chunk is
        /// made, so a system that writes to the same key twice still stamps it once.
        pub fn writerFor(store: *Self, key: []const u8, comptime T: type) Writer {
            const fresh = store.chunks.getIndex(key) == null;
            const out = store.writer(key);
            if (fresh) out.put(u32, shapeOf(T));
            return out;
        }

        /// What was written under a key by `writerFor`, if it was written from the same
        /// shape of type. A chunk stamped with another shape reads as absent — which is
        /// what every caller already does with a chunk that is not there, so a type that
        /// changes costs that chunk's worth of a level and nothing else.
        pub fn readerFor(store: *const Self, key: []const u8, comptime T: type) ?Reader {
            var in = store.reader(key) orelse return null;
            if (in.get(u32) != shapeOf(T)) return null;
            return in;
        }

        /// The whole store as one run of bytes for the disk. The caller frees it.
        pub fn serialize(store: *const Self) ![]u8 {
            var out: Chunk = .empty;
            errdefer out.deinit(store.gpa);
            try out.appendSlice(store.gpa, magic);
            try out.appendSlice(store.gpa, std.mem.asBytes(&format));
            const count: u32 = @intCast(store.chunks.count());
            try out.appendSlice(store.gpa, std.mem.asBytes(&count));
            for (store.chunks.keys(), store.chunks.values()) |key, chunk| {
                const key_len: u16 = @intCast(key.len);
                try out.appendSlice(store.gpa, std.mem.asBytes(&key_len));
                try out.appendSlice(store.gpa, key);
                const len: u32 = @intCast(chunk.items.len);
                try out.appendSlice(store.gpa, std.mem.asBytes(&len));
                try out.appendSlice(store.gpa, chunk.items);
            }
            return out.toOwnedSlice(store.gpa);
        }

        /// A store read back from the disk's bytes, which may be freed afterwards.
        pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Self {
            var in: Reader = .{ .bytes = bytes };
            if (!std.mem.eql(u8, in.take(magic.len), magic)) return error.NotASave;
            if (in.get(u32) != format) return error.OtherVersion;

            var store: Self = .init(gpa);
            errdefer store.deinit();
            const count = in.get(u32);
            for (0..count) |_| {
                const key_len = in.get(u16);
                const key = in.take(key_len);
                const len = in.get(u32);
                const data = in.take(len);
                if (in.short) return error.CutShort;
                store.writer(key).bytes(data);
            }
            return store;
        }

        pub const Writer = struct {
            store: *Self,
            index: usize,

            fn chunk(w: Writer) *Chunk {
                return &w.store.chunks.values()[w.index];
            }

            pub fn bytes(w: Writer, slice: []const u8) void {
                w.chunk().appendSlice(w.store.gpa, slice) catch @panic("out of memory");
            }

            /// Writes a value field by field, skipping what cannot be written.
            pub fn put(w: Writer, comptime T: type, value: T) void {
                switch (@typeInfo(T)) {
                    .int, .float, .bool => w.bytes(std.mem.asBytes(&value)),
                    .@"enum" => |e| w.put(e.tag_type, @intFromEnum(value)),
                    .optional => |opt| {
                        w.put(u8, if (value != null) 1 else 0);
                        if (value) |inner| w.put(opt.child, inner);
                    },
                    .array => |arr| {
                        for (value) |item| w.put(arr.child, item);
                    },
                    .@"struct" => |st| {
                        inline for (st.fields) |field| {
                            if (comptime skip(field.type)) continue;
                            w.put(field.type, @field(value, field.name));
                        }
                    },
                    // A tagged union: the tag, then whichever payload it names.
                    .@"union" => |un| {
                        const Tag = un.tag_type orelse @compileError("a save cannot carry an untagged union: " ++ @typeName(T));
                        const tag = std.meta.activeTag(value);
                        w.put(Tag, tag);
                        inline for (un.fields) |field| {
                            if (tag == @field(Tag, field.name)) w.put(field.type, @field(value, field.name));
                        }
                    },
                    .void => {},
                    else => @compileError("a save cannot carry a " ++ @typeName(T)),
                }
            }
        };

        pub const Reader = struct {
            bytes: []const u8,
            at: usize = 0,
            /// Set once a read ran past the end: everything after reads as nothing.
            short: bool = false,

            pub fn take(r: *Reader, count: usize) []const u8 {
                if (r.at + count > r.bytes.len) {
                    r.short = true;
                    r.at = r.bytes.len;
                    return r.bytes[0..0];
                }
                const slice = r.bytes[r.at .. r.at + count];
                r.at += count;
                return slice;
            }

            /// Reads a value field by field, blanking what was never written.
            pub fn get(r: *Reader, comptime T: type) T {
                switch (@typeInfo(T)) {
                    .int, .float, .bool => {
                        var value: T = std.mem.zeroes(T);
                        const raw = r.take(@sizeOf(T));
                        if (raw.len == @sizeOf(T)) @memcpy(std.mem.asBytes(&value), raw);
                        return value;
                    },
                    .@"enum" => |e| return @enumFromInt(r.get(e.tag_type)),
                    .optional => |opt| {
                        if (r.get(u8) == 0) return null;
                        return r.get(opt.child);
                    },
                    .array => |arr| {
                        var value: T = undefined;
                        for (&value) |*item| item.* = r.get(arr.child);
                        if (comptime arr.sentinel()) |end| value[arr.len] = end;
                        return value;
                    },
                    .@"struct" => |st| {
                        var value: T = undefined;
                        inline for (st.fields) |field| {
                            @field(value, field.name) = if (comptime skip(field.type))
                                std.mem.zeroes(field.type)
                            else
                                r.get(field.type);
                        }
                        return value;
                    },
                    .@"union" => |un| {
                        const Tag = un.tag_type orelse @compileError("a save cannot carry an untagged union: " ++ @typeName(T));
                        const tag = r.get(Tag);
                        inline for (un.fields) |field| {
                            if (tag == @field(Tag, field.name)) return @unionInit(T, field.name, r.get(field.type));
                        }
                        // A tag no field answers to, off a short read: the first, blank.
                        return @unionInit(T, un.fields[0].name, std.mem.zeroes(un.fields[0].type));
                    },
                    .void => return {},
                    else => @compileError("a save cannot carry a " ++ @typeName(T)),
                }
            }
        };

        /// Whether a type is left out of the walk: a pointer, whatever the rules name,
        /// or an optional or array of either.
        fn skip(comptime T: type) bool {
            if (@hasDecl(Rules, "transient") and Rules.transient(T)) return true;
            return switch (@typeInfo(T)) {
                .pointer => true,
                .optional => |opt| skip(opt.child),
                .array => |arr| skip(arr.child),
                // A union is all or nothing: one payload that cannot be written and
                // the whole of it is left out.
                .@"union" => |un| for (un.fields) |field| {
                    if (skip(field.type)) break true;
                } else false,
                else => false,
            };
        }

        /// A type's shape as text — names, fields, lengths, tags — for the fingerprint.
        fn shape(comptime T: type) []const u8 {
            comptime {
                var text: []const u8 = @typeName(T);
                switch (@typeInfo(T)) {
                    .@"struct" => |st| for (st.fields) |field| {
                        if (skip(field.type)) continue;
                        text = text ++ "." ++ field.name ++ ":" ++ shape(field.type);
                    },
                    .optional => |opt| text = text ++ "?" ++ shape(opt.child),
                    .array => |arr| text = text ++ "[" ++ std.fmt.comptimePrint("{d}", .{arr.len}) ++ "]" ++ shape(arr.child),
                    .@"enum" => |e| for (e.fields) |field| {
                        text = text ++ "|" ++ field.name;
                    },
                    .@"union" => |un| for (un.fields) |field| {
                        text = text ++ "|" ++ field.name ++ ":" ++ shape(field.type);
                    },
                    else => {},
                }
                return text;
            }
        }
    };
}

// ---- tests ----

const TestRules = struct {
    pub const Entity = struct { position: [3]f32 = .{ 0, 0, 0 } };
};

test "a chunk written from one shape does not read back as another" {
    const gpa = std.testing.allocator;
    const S = Store(TestRules);

    const Grid = struct { origin: [3]f32, step: f32 };
    const WiderGrid = struct { origin: [3]f32, step: f32, tilt: f32 };

    var out: S = .init(gpa);
    defer out.deinit();
    // One chunk stamped with the type it holds, and one plain chunk of bare numbers.
    const grids = out.writerFor("grids", Grid);
    grids.put(u32, 1);
    grids.put(Grid, .{ .origin = .{ 1, 2, 3 }, .step = 0.5 });
    const notes = out.writer("notes");
    notes.put(u32, 7);

    const bytes = try out.serialize();
    defer gpa.free(bytes);
    var back = try S.parse(gpa, bytes);
    defer back.deinit();

    // Read back as what it was written as, and the stamp is eaten rather than counted.
    var same = back.readerFor("grids", Grid).?;
    try std.testing.expectEqual(@as(u32, 1), same.get(u32));
    try std.testing.expectEqual(@as(f32, 0.5), same.get(Grid).step);

    // The same bytes asked for as a type with one more field: absent, not nonsense. This
    // is the whole point — before the stamp this read the old bytes into the new layout
    // and answered with a grid whose step was whatever followed it in the file.
    try std.testing.expect(back.readerFor("grids", WiderGrid) == null);

    // A plain chunk is untouched by any of it.
    var plain = back.reader("notes").?;
    try std.testing.expectEqual(@as(u32, 7), plain.get(u32));
}

test "a save is refused by its container format, and not by the shape of the game" {
    const gpa = std.testing.allocator;
    const S = Store(TestRules);
    // A different game, whose entity has nothing to do with this one's.
    const OtherRules = struct {
        pub const Entity = struct { position: [3]f32 = .{ 0, 0, 0 }, health: u8 = 0, name: [8]u8 = @splat(0) };
    };
    const Other = Store(OtherRules);

    var out: S = .init(gpa);
    defer out.deinit();
    out.writer("hello").put(u32, 42);
    const bytes = try out.serialize();
    defer gpa.free(bytes);

    // A file written by one game opens in another: what a chunk means is the writing
    // system's business, and the entity's shape was never the file's to care about.
    var back = try Other.parse(gpa, bytes);
    defer back.deinit();
    var in = back.reader("hello").?;
    try std.testing.expectEqual(@as(u32, 42), in.get(u32));

    // Nonsense is still refused.
    try std.testing.expectError(error.NotASave, S.parse(gpa, "not a save at all"));
    var wrong = try gpa.dupe(u8, bytes);
    defer gpa.free(wrong);
    wrong[magic.len] +%= 1;
    try std.testing.expectError(error.OtherVersion, S.parse(gpa, wrong));
}
