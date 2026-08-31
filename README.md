# world

A small game framework in Zig over raylib: an ECS with plugins, systems, generational
entity ids and typed resources; saves; input by name with controller support; meshes,
lighting, post effects, audio, noise and tweens; and box3d physics when it is built
in. Zig 0.16, raylib 6.0. The engine part was lifted out of a survival game; the rest
was built to be taken or left.

`template/` is a game made with it — a grid, a camera, a light, nothing in the world
yet — and what a new game is stamped from:

```
zig build new -- fps              # makes ../fps, next door to this package
zig build new -- fps --at ~/code/fps
cd ../fps && zig build run
```

That writes the template with the name as its package, its title and its directory,
a fresh fingerprint, and the path back to the framework worked out from where it went.
From there it is `src/main.zig` (the spec, the plugins) and `src/controls.zig` (the
keys).

## Using it

A game depends on the package in its `build.zig.zon`:

```zig
.dependencies = .{
    .world = .{ .path = "../world" },   // or .url + .hash, from `zig fetch --save <url>`
},
```

and imports the module in its `build.zig`, choosing whether box3d comes along:

```zig
const world = b.dependency("world", .{ .target = target, .optimize = optimize, .physics = false });
exe.root_module.addImport("world", world.module("world"));
```

Raylib and the headers come with the module; the game's own module needs `link_libc`.

Then the game tells the framework about itself once — its entity type and its config —
and gets back every module specialised to it:

```zig
const world = @import("world");
const rl = world.rl;                     // the one raylib import: use this, not your own

pub const Spec = struct {
    pub const Entity = struct {
        position: rl.Vector3,
        model: ?world.mesh.Model = null,
        lamp: ?world.lighting.Lamp = null,
        pub fn transient(comptime T: type) bool { _ = T; return false; }
    };
    pub const config: world.Config = .{ .game_title = "mine", .view = .three };
};

pub const fw = world.Framework(Spec);
pub const W = fw.W;

pub fn main() !void {
    var game = try fw.Game.init();       // window, input, clock, tweens, audio, meshes, light, effects, the eye
    defer game.deinit();
    controls.bind();                     // the game's own key names, once
    try game.add(mine.plugin);           // the game's own plugins, after the standard ones
    try game.drawInScene(mine.draw);     // and draws: inside the lit scene, or drawOnScreen
    game.run();                          // saves and the render pass last; runs until quit
}
```

Component types — `world.mesh.Model`, `world.lighting.Lamp`, `world.physics.RigidBody` —
live at the top of each module and never depend on the spec, so the entity can name
them. Everything that runs — plugins, resources, draw hooks — is under `fw.<module>`,
built over the game's world. `world.Config` has a default for every knob; the spec sets
only what it wants.

## The engine

Four files that never change from game to game:

| file | what it is |
| --- | --- |
| `engine.zig` | `Engine(Entity)`: a list of plugins, and a world built from them. `start`, `run`, `restart`, `deinit`. |
| `world.zig` | `World(Entity)`: the systems in order, the entities as one `MultiArrayList` table with generational ids, `query`, resources by type, the hooks fired in order. |
| `system.zig` | `System`: a name and up to six optional hooks — `onStart`, `onUpdate`, `onDraw`, `onCleanup`, `onSave`, `onLoad`. |
| `store.zig` | `Store(Entity)`: a save as chunks of bytes by key, walked over the real types at comptime. |

### Entities

The spec's `Entity` is one struct; every component is an optional field on it, and an
entity *has* a component when the field is not null. Queries walk the columns:

```zig
var things = w.query(.{ .position, .color });
while (things.next()) |thing| {
    // thing.position: *Vector3, thing.color: *Color — pointers into the table.
}
```

`addEntity` hands back a `W.Id` — a slot plus a generation, never a row — so an id to
something removed says so (`alive`, `rowOf`, `get(id, .field)`) rather than reading
whatever moved in. Add and remove only through the world (`addEntity`, `removeEntity`,
`removeRow`), never on `w.entities`; don't remove mid-walk — collect `query.id()`s and
remove after.

### Resources

State that is not an entity is a resource: one value per type, owned by the world,
found by type. The plugin that owns one puts it in as it registers;
`w.resource(T)` reads or changes it anywhere. `getResource`, `hasResource`,
`removeResource`. The clock, the audio, the meshes, the physics world are all these.

### Systems and plugins

A plugin is any `fn (*W, Allocator) !void` that calls `w.addSystem`:

```zig
pub fn plugin(w: *W, allocator: std.mem.Allocator) !void {
    try w.addSystem(allocator, .{ .name = "things", .onStart = spawn, .onUpdate = move, .onSave = keep, .onLoad = recall });
}
```

Systems fire in registration order; `.always = true` keeps one updating while
`W.paused`. A system that owns entities saves them with `fw.keepAll` and reads them
back with `fw.purge` + `fw.recallAll`.

### The clock

`w.resource(world.clock.Clock)`: `delta` is the frame's step (nought while paused),
`real` the wall's, `elapsed` and `frame` the world's run. `GetFrameTime` is called in
one place; everything that moves reads `delta`.

## Input

`world.input` knows no actions. The game names them, once, in its own `controls.zig`:

```zig
input.bind("jump", .{ .key = rl.KEY_SPACE });
input.bind("jump", .{ .pad = rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN });
input.bindAxis("move", .{ .keys = .{ .left = rl.KEY_A, .right = rl.KEY_D, .down = rl.KEY_S, .up = rl.KEY_W } });
input.bindAxis("move", .{ .stick = .{ .x = rl.GAMEPAD_AXIS_LEFT_X, .y = rl.GAMEPAD_AXIS_LEFT_Y } });
```

and asks by name: `isActionPressed/Down/Released("jump")`, `getAxis("move")` (a
`Vector2`, x right, y up, every device summed). The framework's own systems ask for
`"move"`, `"look"`, `"climb"`, `"zoom"`, `"sprint"`, `"save"`, `"load"`, `"restart"`
and `"profile"`; leave one unbound and it never happens. Under the names are the plain
device questions — `keyPressed`, `mouseDelta`, `stick(...)`, `Pad{ .slot }` for more
than one player — and the first *real* controller is found by name, past touchpads and
keyboards that show up as joysticks.

## The rest

- **Meshes** — `world.mesh.Mesh.cube(1)`, `.box`, `.quad`, `.plane`, `.polygon(sides, r)`,
  `.cylinder`, `.cone`, `.sphere`; a `Builder` for anything else, with `grid` for
  terrain; a `Meshes` resource keeping them by id and name; a `Model` component drawn
  by the render pass. Built after the window is open (an `onStart`).
- **Lighting** (3D) — `w.resource(world.lighting.Lighting)`: sun, sky/ground fill, fog,
  shadows, and `Lamp` components. Every `Model` casts and receives; custom draws cast
  if drawn between `fw.lighting.shadowBegin`/`shadowEnd`.
- **Effects** — `w.resource(world.effects.Effects)`: `add(.{ .vignette = .{} })`,
  `bloom`, `grade`, `fade`, `pixelate`, `grain`, `blur`; `get(.tag)` to tweak, `remove`.
- **Audio** — `w.resource(world.audio.Audio)`: `play(path)`, `playMixed`, `playOver`,
  `playMusic`, volumes.
- **Noise** — `world.noise.Noise.init(.{ .kind = .perlin, .seed, .scale, .octaves, .fractal })`
  then `at`, `unit`, `between`, `above`, `at3`.
- **Tweens** — `world.tween.Tween(T)` as a value you tick; or the `Tweens` resource for
  Godot-style sequences: `tween`, `parallel`, `wait`, `call`, `repeat`, `setSpeed`.
- **Physics** (opt-in) — Godot's kinds as components: `world.physics.StaticBody`,
  `RigidBody`, `KinematicBody`, `CharacterBody`; the plugin makes and reaps the box3d
  bodies, `moveAndSlide` drives characters; everything by `BodyId`. Name
  `world.physics.BodyId` in `Entity.transient`. Turn it on with `.physics = true` on
  the dependency and `try game.add(fw.physics.plugin)`.

## Building the framework itself

```
zig build test                  # every test reachable from src/tests.zig
zig build test -Dphysics=true   # with box3d: drops a crate, walks a character into a wall
```

There is no executable here; run `../template`.

## What is vendored here

`include/` carries two other people's libraries, both under permissive licences and
both unmodified:

- **raylib** (`raylib.h`, `raymath.h`, `rlgl.h`) — zlib/libpng licence,
  © Ramon Santamaria ([@raysan5](https://github.com/raysan5/raylib)). Everything here
  draws through it.
- **box3d** (`box3d/`) — MIT licence, © Erin Catto
  ([box3d](https://github.com/erincatto/box3d)). Built only with `-Dphysics=true`;
  every file keeps its own SPDX header.

Neither is a fork. They are here so that a clone builds without fetching anything.
