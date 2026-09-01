//! Exact process-credential leaf for the official GitHub Release adapter.
//!
//! The workflow does not rename credentials and the executable does not enumerate its ambient
//! environment. Value policy remains owned by the transport that constructs every child process.

const std = @import("std");
const transport = @import("release_adapter_github_transport");

pub const token_name: [:0]const u8 = "GH_TOKEN";
pub const Error = error{ MissingToken, InvalidToken };

/// Reads one exact name through an injectable lookup and returns the borrowed bytes unchanged.
pub fn read(lookup: anytype) Error![]const u8 {
    const token = lookup.get(token_name) orelse return error.MissingToken;
    // The shared validator owns value policy, while this leaf keeps unrelated REST/JSON errors out
    // of its process-environment API.
    transport.validateToken(token) catch return error.InvalidToken;
    return token;
}

/// Product leaf. The returned slice borrows process environment storage; the release executable
/// never mutates its environment and consumes the token before process exit.
pub fn readCurrent() Error![]const u8 {
    var environment = CurrentEnvironment{};
    return read(&environment);
}

const CurrentEnvironment = struct {
    fn get(_: *@This(), name: [:0]const u8) ?[]const u8 {
        const raw = std.c.getenv(name) orelse return null;
        return std.mem.span(raw);
    }
};
