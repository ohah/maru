//! Process-environment leaf for the session-host release validator.
//!
//! Workflow shell code must not choose or rename identity inputs. This leaf asks the current
//! process for the context parser's closed list and immediately validates it as typed identity.

const std = @import("std");
const context = @import("release_adapter_context");

pub const Error = context.Error;

/// Reads the closed environment vocabulary through an injectable lookup for deterministic tests.
pub fn read(lookup: anytype) Error!context.Context {
    var entries: [context.required_names.len]context.Entry = undefined;
    inline for (context.required_names, 0..) |name, index| {
        const value = lookup.get(name) orelse return error.MissingKey;
        entries[index] = .{ .name = name, .value = value };
    }
    return context.parse(&entries);
}

/// Product entry point. The returned context contains slices into the process environment and must
/// be consumed before any code mutates that environment; the release adapter never calls setenv.
pub fn readCurrent() Error!context.Context {
    var environment = CurrentEnvironment{};
    return read(&environment);
}

const CurrentEnvironment = struct {
    fn get(_: *@This(), name: [:0]const u8) ?[]const u8 {
        const raw = std.c.getenv(name) orelse return null;
        return std.mem.span(raw);
    }
};
