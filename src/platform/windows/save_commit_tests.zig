//! Platform-root aggregation keeps shared native imports inside the module.
test {
    _ = @import("editor/save_commit_worker.zig");
}
