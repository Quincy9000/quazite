//! `zig build new -- <name> [--at <dir>]`: a new game made from the template, next
//! door to the framework unless told where. The template's files are baked into this
//! program, so it needs nothing but a place to write; the name goes into the package,
//! the title and the fingerprint, and the path back to the framework is worked out
//! from wherever the game is put.

const std = @import("std");

const File = struct { path: []const u8, text: []const u8 };

const files = [_]File{
    .{ .path = "build.zig", .text = @embedFile("template/build.zig") },
    .{ .path = "build.zig.zon", .text = @embedFile("template/build.zig.zon") },
    .{ .path = ".gitignore", .text = @embedFile("template/.gitignore") },
    .{ .path = "src/main.zig", .text = @embedFile("template/src/main.zig") },
    .{ .path = "src/controls.zig", .text = @embedFile("template/src/controls.zig") },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(gpa);
    var world_dir: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var at: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--world")) {
            i += 1;
            if (i == args.len) return usage();
            world_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--at")) {
            i += 1;
            if (i == args.len) return usage();
            at = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage();
        } else if (name == null) {
            name = arg;
        } else {
            return usage();
        }
    }
    const game = name orelse return usage();
    if (game.len == 0 or std.mem.indexOfAny(u8, game, "/\\ ") != null) {
        std.debug.print("a name is one word, without slashes: not \"{s}\"\n", .{game});
        return error.BadName;
    }

    // Where the framework is, and where the game goes: both absolute, so the path
    // from one to the other can be worked out.
    const here = try std.process.currentPathAlloc(io, gpa);
    const world = try cwd.realPathFileAlloc(io, world_dir orelse "../world", gpa);
    const dest = try std.fs.path.resolve(gpa, &.{ here, at orelse try std.fs.path.join(gpa, &.{ world, "..", game }) });
    const native = try std.fs.path.relative(gpa, here, null, dest, world);
    // That path is written into a .zon string, where a backslash is an escape: on
    // windows `..\..\world` would not parse. Zig's build system takes forward slashes
    // on every platform, so that is what goes in.
    const back = try std.mem.replaceOwned(u8, gpa, native, "\\", "/");

    if (cwd.access(io, dest, .{})) |_| {
        std.debug.print("{s} is already there; nothing was written\n", .{dest});
        return error.AlreadyThere;
    } else |_| {}

    // The name as the package will call it: a plain identifier, or quoted.
    const package = if (isIdentifier(game)) game else try std.fmt.allocPrint(gpa, "@\"{s}\"", .{game});
    const fingerprint = try std.fmt.allocPrint(gpa, "0x{x}", .{mint(game, dest)});
    const title = try std.fmt.allocPrint(gpa, "\"{s}\"", .{game});

    try cwd.createDirPath(io, try std.fs.path.join(gpa, &.{ dest, "src" }));
    for (files) |file| {
        var text = file.text;
        text = try std.mem.replaceOwned(u8, gpa, text, ".name = .template,", try std.fmt.allocPrint(gpa, ".name = .{s},", .{package}));
        text = try std.mem.replaceOwned(u8, gpa, text, ".fingerprint = 0x97601f834bf199ab,", try std.fmt.allocPrint(gpa, ".fingerprint = {s},", .{fingerprint}));
        text = try std.mem.replaceOwned(u8, gpa, text, ".path = \"..\"", try std.fmt.allocPrint(gpa, ".path = \"{s}\"", .{back}));
        text = try std.mem.replaceOwned(u8, gpa, text, "\"my super awesome game\"", title);
        const path = try std.fs.path.join(gpa, &.{ dest, file.path });
        try cwd.writeFile(io, .{ .sub_path = path, .data = text });
    }

    std.debug.print(
        \\made {s}
        \\  package  {s}
        \\  world    {s}  (from the game's build.zig.zon)
        \\
        \\  cd {s} && zig build run
        \\
    , .{ dest, package, back, dest });
}

fn usage() error{Usage} {
    std.debug.print(
        \\usage: zig build new -- <name> [--at <dir>]
        \\
        \\  <name>     the game's name: its package, its title, its directory
        \\  --at <dir> where to put it; next to the framework if left out
        \\
    , .{});
    return error.Usage;
}

/// A package fingerprint the way `zig build` checks one: the name's CRC32 in the top
/// half and an id in the bottom, neither nought nor all ones. The id is hashed from
/// where the game is put, which no two games share.
fn mint(name: []const u8, dest: []const u8) u64 {
    var id: u32 = @truncate(std.hash.Wyhash.hash(0x5ec7e7, dest));
    if (id == 0 or id == std.math.maxInt(u32)) id = 0x1234_5678;
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | id;
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return !std.zig.isPrimitive(name) and std.zig.Token.getKeyword(name) == null;
}
