//! Narrow `maru.session.screen_stream` facade for standalone compatibility-layer tests.

pub const session = struct {
    pub const screen_stream = @import("screen_stream");
};
