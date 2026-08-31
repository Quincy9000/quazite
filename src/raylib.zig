/// One shared @cImport. Calling @cImport in two files produces two unrelated sets of
/// types, so everything that touches raylib goes through this.
pub const c = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
    @cInclude("rlgl.h");
    // For the one thing raylib cannot do with a file: remove it.
    @cInclude("stdio.h");
});
