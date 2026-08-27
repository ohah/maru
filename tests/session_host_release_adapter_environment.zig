//! Proves that the executable boundary reads only the closed GitHub Actions vocabulary and sends
//! those values through the existing typed parser. This is a component seam, not GitHub API E2E.

const std = @import("std");
const context = @import("release_adapter_context");
const environment = @import("release_adapter_environment");

const values = [_][]const u8{
    "ohah/maru",
    "123456",
    "refs/tags/v1.2.3",
    "tag",
    "v1.2.3",
    "0123456789abcdef0123456789abcdef01234567",
    "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
    "987654",
    "2",
    "push",
    "true",
};

const Lookup = struct {
    calls: [context.required_names.len][]const u8 = @splat(""),
    call_count: usize = 0,
    missing_index: ?usize = null,
    replacement_index: ?usize = null,
    replacement: []const u8 = "",

    pub fn get(self: *@This(), name: [:0]const u8) ?[]const u8 {
        const index = self.call_count;
        self.calls[index] = name;
        self.call_count += 1;
        if (self.missing_index == index) return null;
        if (self.replacement_index == index) return self.replacement;
        return values[index];
    }
};

test "leaf reads the exact closed vocabulary and returns typed context" {
    var lookup = Lookup{};
    const parsed = try environment.read(&lookup);
    try std.testing.expectEqual(context.required_names.len, lookup.call_count);
    for (context.required_names, lookup.calls) |expected, actual|
        try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(u64, 123456), parsed.repository.id);
    try std.testing.expectEqualStrings("v1.2.3", parsed.tag);
}

test "missing process environment value fails closed" {
    var lookup = Lookup{ .missing_index = 5 };
    try std.testing.expectError(error.MissingKey, environment.read(&lookup));
    try std.testing.expectEqual(@as(usize, 6), lookup.call_count);
}

test "captured values cannot bypass the typed context validator" {
    var control = Lookup{ .replacement_index = 0, .replacement = "ohah/maru\n" };
    try std.testing.expectError(error.InvalidScalar, environment.read(&control));

    var oversized = Lookup{
        .replacement_index = 0,
        .replacement = "x" ** (context.max_value_bytes + 1),
    };
    try std.testing.expectError(error.ValueTooLong, environment.read(&oversized));
}

test "real process leaf is compiled without assuming the runner environment" {
    // CI supplies a different subset than local shells, so this component test must not treat
    // either environment as an oracle for the trusted tag workflow.
    _ = environment.readCurrent() catch {};
}
