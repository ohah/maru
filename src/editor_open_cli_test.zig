//! Test entrypoint at src/ so the CLI and shared receiver retain one module root.
test {
    _ = @import("cli/editor.zig");
}
