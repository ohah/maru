//! Platform-root aggregation keeps shared native imports inside the module.
test {
    _ = @import("editor/open_worker.zig");
}
