//! The official Release executable reads one credential name and delegates value policy to the
//! existing transport validator. Fixtures use inert bytes and never inspect a real credential.

const std = @import("std");
const token_environment = @import("release_adapter_token_environment");
const transport = @import("release_adapter_github_transport");

const Lookup = struct {
    value: ?[]const u8,
    calls: usize = 0,
    name: []const u8 = "",

    pub fn get(self: *@This(), name: [:0]const u8) ?[]const u8 {
        self.calls += 1;
        self.name = name;
        return self.value;
    }
};

test "reads exact GH_TOKEN once and returns the borrowed validated bytes" {
    const fixture = "inert-test-token";
    var lookup = Lookup{ .value = fixture };
    const token = try token_environment.read(&lookup);
    try std.testing.expectEqual(@as(usize, 1), lookup.calls);
    try std.testing.expectEqualStrings("GH_TOKEN", lookup.name);
    try std.testing.expectEqualStrings(fixture, token);
    try std.testing.expectEqual(@intFromPtr(fixture.ptr), @intFromPtr(token.ptr));
}

test "missing token fails closed after one exact lookup" {
    var lookup = Lookup{ .value = null };
    try std.testing.expectError(error.MissingToken, token_environment.read(&lookup));
    try std.testing.expectEqual(@as(usize, 1), lookup.calls);
    try std.testing.expectEqualStrings("GH_TOKEN", lookup.name);
}

test "empty control NUL and cap plus one reuse transport invalid-token policy" {
    const invalid = [_][]const u8{
        "",
        "line\nfeed",
        "delete\x7fbyte",
        "nul\x00byte",
        "x" ** (transport.max_token_bytes + 1),
    };
    for (invalid) |value| {
        var lookup = Lookup{ .value = value };
        try std.testing.expectError(error.InvalidToken, token_environment.read(&lookup));
        try std.testing.expectEqual(@as(usize, 1), lookup.calls);
    }
}

test "the transport maximum remains accepted without allocation or copying" {
    const maximum = "t" ** transport.max_token_bytes;
    var lookup = Lookup{ .value = maximum };
    const token = try token_environment.read(&lookup);
    try std.testing.expectEqual(transport.max_token_bytes, token.len);
    try std.testing.expectEqual(@intFromPtr(maximum.ptr), @intFromPtr(token.ptr));
}

test "process leaf compiles without treating a local credential as a test oracle" {
    // Referencing the product leaf compiles it without reading the developer's ambient credential.
    _ = &token_environment.readCurrent;
}
