//! SSH profile contracts must keep legacy calls and command-only semantics intact.
const std = @import("std");
test {
    std.testing.refAllDecls(@import("cli/ssh.zig"));
}
