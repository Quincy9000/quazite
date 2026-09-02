//! Every number the framework is tuned by, with a default for each. A game sets the
//! ones it cares about in its spec and leaves the rest:
//!
//!     pub const config: world.Config = .{ .game_title = "mine", .view = .two };

const rl = @import("raylib.zig").c;

/// Whether the world is drawn in two dimensions or three: which eye the game is made
/// with — `camera2d` or `camera` — and which pass the frame draws in. Light is a 3D
/// thing; everything else is the same either way.
pub const View = enum { two, three };

/// How a picture is sampled when it is drawn.
pub const Sampling = enum {
    /// Smoothed between its own texels, with no mip levels under it. What a game drawing
    /// a sprite or a wall at a size it chose wants.
    smooth,
    /// Texels kept square when magnified, mip levels under them, anisotropy on top.
    ///
    /// What a tool wants, and what a game wants for pixel art. A wall seen from across a
    /// room samples one texel in a dozen and crawls as the eye moves; mip levels are what
    /// stop that, and anisotropy is what keeps a floor from going to mush at a grazing
    /// angle, which is most of what is looked at. Nearest across a level keeps a texel a
    /// square, which is the whole point of drawing one.
    ///
    /// It is set through rlgl rather than raylib's `SetTextureFilter`, whose filters are a
    /// fixed menu and do not include this pairing: POINT turns mipmapping off again, and
    /// BILINEAR and TRILINEAR both smear the texels the picture is there to show.
    crisp,
};

pub const Config = struct {
    view: View = .three,

    // ---- the window ----

    game_title: [*:0]const u8 = "world",
    window_width: c_int = 1600,
    window_height: c_int = 900,
    /// Whether the window can be dragged to another size. On, everything that lays
    /// itself out asks the screen for its size each frame rather than being told once.
    window_resizable: bool = true,
    /// The smallest it may be dragged to, so a panel cannot end up wider than the
    /// window it is in.
    window_min_width: c_int = 960,
    window_min_height: c_int = 600,
    /// How near and how far the eye can see, in world units.
    near_plane: f32 = 0.1,
    far_plane: f32 = 1000,
    sky: rl.Color = .{ .r = 24, .g = 28, .b = 36, .a = 255 },
    // ---- the pictures ----

    /// How every picture is sampled. See `Sampling`.
    sampling: Sampling = .smooth,
    /// How far anisotropy is taken, where `sampling` is `.crisp`. Sixteen is the most any
    /// card in use offers and the cost of it is nothing worth measuring.
    anisotropy: c_int = 16,

    /// Whether the frame waits for the display before it is shown.
    ///
    /// On, and the game runs at whatever the monitor is set to and never draws a frame
    /// nobody sees. Off, and the frame rate says how fast the thing being made actually
    /// draws — which is what a tool wants, and exactly what waiting hides: with it on, a
    /// debug build and a fast one report the same number and neither number is about the
    /// game. The price is tearing, and frames drawn that the display never shows.
    vsync: bool = true,
    /// The most frames a second to draw, or nought for as many as the card will give.
    ///
    /// Worth setting when `vsync` is off: uncapped, a small scene runs the card flat out
    /// drawing thousands of frames a second that nobody will ever see, for a fan that
    /// never settles. A cap well above any display leaves the number meaning something
    /// and the machine quiet.
    frame_cap: c_int = 0,
    /// The key that closes the window: raylib's Escape. `rl.KEY_NULL` for a game that
    /// leaves some other way — a menu, or an editor that wants Escape for itself.
    exit_key: c_int = rl.KEY_ESCAPE,
    /// Whether the game steers the eye itself: then no free camera is made, and the
    /// game sets `fw.camera.current` (or `fw.camera2d.current`) every frame.
    own_camera: bool = false,

    // ---- the input ----

    /// Degrees turned for each pixel the mouse moves.
    mouse_sensitivity: f32 = 0.15,
    /// Degrees a second the look stick turns at full tilt.
    stick_sensitivity: f32 = 180,
    /// How far a stick reads before it counts: the wobble about the middle taken out.
    deadzone: f32 = 0.2,

    // ---- the eye, in three dimensions ----

    field_of_view: f32 = 70,
    camera_start: rl.Vector3 = .{ .x = 12, .y = 9, .z = 12 },
    camera_target: rl.Vector3 = .{ .x = 0, .y = 0, .z = 0 },
    /// World units a second the free camera flies at, and what sprinting multiplies it by.
    fly_speed: f32 = 8,
    fly_sprint: f32 = 3,
    /// The floor drawn under everything: how many lines a side, and how far apart.
    grid_lines: c_int = 40,
    grid_step: f32 = 1,

    // ---- the eye, flat ----

    camera2d_start: rl.Vector2 = .{ .x = 0, .y = 0 },
    camera2d_zoom: f32 = 1,
    /// Pixels a second the pan covers at a zoom of one, and what sprinting multiplies it by.
    pan_speed: f32 = 400,
    pan_sprint: f32 = 3,
    /// What a notch of the wheel multiplies the zoom by, and what a second on the zoom
    /// axis does; and how far in and out it goes.
    wheel_zoom: f32 = 1.1,
    zoom_rate: f32 = 2,
    zoom_min: f32 = 0.1,
    zoom_max: f32 = 10,
    /// The flat floor: `grid_lines` cells a side, this many pixels each, in this colour.
    grid_cell: f32 = 64,
    grid_color: rl.Color = .{ .r = 52, .g = 58, .b = 70, .a = 255 },

    // ---- the physics: only with physics on in the build ----

    /// What box3d takes a metre to be, in world units.
    units_per_meter: f32 = 1,
    gravity: rl.Vector3 = .{ .x = 0, .y = -9.8, .z = 0 },
    /// The fixed step the world is simulated in, how many substeps the solver takes in
    /// each, and the most steps one frame may take before the rest is dropped.
    physics_step: f32 = 1.0 / 60.0,
    physics_substeps: c_int = 4,
    physics_max_steps: u32 = 5,

    // ---- the light ----

    /// The shadow map's side, in texels: bigger is sharper and dearer.
    shadow_size: c_int = 2048,

    // ---- the meshes ----

    /// Where the light the shapes are shaded by comes from when no lighting is on, and
    /// how much of a colour a face turned right away from it keeps.
    mesh_light: rl.Vector3 = .{ .x = 0.4, .y = 1, .z = 0.3 },
    mesh_ambient: f32 = 0.55,

    // ---- the sound ----

    master_volume: f32 = 1,
    music_volume: f32 = 0.8,
    /// Whether the tests open the sound device: the test runner can hang on it.
    test_audio: bool = false,

    // ---- the save ----

    save_path: [*:0]const u8 = "save.bin",
    /// Seconds the word "saved" or "loaded" stays up.
    notice_time: f32 = 2.5,

    // ---- the readout ----

    /// Whether the frame draws its own line of hints along the bottom. A game with
    /// a readout of its own turns it off, or the two are drawn over each other.
    hud_hint: bool = true,
    hud_margin: c_int = 14,
    hud_text_size: c_int = 20,
    hud_dim: rl.Color = .{ .r = 180, .g = 186, .b = 196, .a = 255 },
};
