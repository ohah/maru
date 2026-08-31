//! Apple release 관측이 caller가 고른 command나 inherited environment를 실행하지 못하게 한다.
//!
//! 이 gate는 command transport까지만 검증한다. pathname authority와 DMG extraction은 후속 owner다.

const std = @import("std");
const transport = @import("release_adapter_apple_transport");

const Paths = transport.Paths{
    .app_bundle = "/private/tmp/Maru.app",
    .info_plist = "/private/tmp/Maru.app/Contents/Info.plist",
    .product_executable = "/private/tmp/Maru.app/Contents/MacOS/maru-macos-app",
    .dmg = "/private/tmp/Maru-1.2.3-universal.dmg",
};

test "Apple command plans close every executable and argv" {
    const cases = [_]struct {
        command: transport.Command,
        executable: []const u8,
        args: []const []const u8,
        capture: bool,
    }{
        .{ .command = .plist_json, .executable = "/usr/bin/plutil", .args = &.{ "-convert", "json", "-o", "-", Paths.info_plist }, .capture = true },
        .{ .command = .codesign_detail, .executable = "/usr/bin/codesign", .args = &.{ "-d", "--verbose=4", Paths.app_bundle }, .capture = true },
        .{ .command = .designated_requirement, .executable = "/usr/bin/codesign", .args = &.{ "-d", "-r-", "--verbose=0", Paths.app_bundle }, .capture = true },
        .{ .command = .architectures, .executable = "/usr/bin/lipo", .args = &.{ "-archs", Paths.product_executable }, .capture = true },
        .{ .command = .strict_signature, .executable = "/usr/bin/codesign", .args = &.{ "--verify", "--strict", "--deep", Paths.app_bundle }, .capture = false },
        .{ .command = .app_staple, .executable = "/usr/bin/xcrun", .args = &.{ "stapler", "validate", Paths.app_bundle }, .capture = false },
        .{ .command = .dmg_staple, .executable = "/usr/bin/xcrun", .args = &.{ "stapler", "validate", Paths.dmg }, .capture = false },
        .{ .command = .dmg_gatekeeper, .executable = "/usr/sbin/spctl", .args = &.{ "-a", "-t", "open", "--context", "context:primary-signature", "-v", Paths.dmg }, .capture = false },
    };
    for (cases) |case| {
        var args_storage: transport.ArgsStorage = undefined;
        const plan = try transport.plan(&args_storage, case.command, Paths);
        try std.testing.expectEqualStrings(case.executable, plan.executable);
        try std.testing.expectEqual(case.capture, plan.capture);
        try std.testing.expectEqual(case.args.len, plan.args.len);
        for (case.args, plan.args) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }
}

test "Apple command plans reject relative or controlled paths" {
    var args: transport.ArgsStorage = undefined;
    var paths = Paths;
    paths.app_bundle = "relative.app";
    try std.testing.expectError(error.InvalidPath, transport.plan(&args, .codesign_detail, paths));
    paths = Paths;
    paths.dmg = "/tmp/bad\nname.dmg";
    try std.testing.expectError(error.InvalidPath, transport.plan(&args, .dmg_staple, paths));
}

test "Apple collection executes exact order with empty environment and assembles all receipts" {
    const Fake = struct {
        call: usize = 0,

        pub fn capture(
            self: *@This(),
            executable: []const u8,
            args: []const []const u8,
            environment: []const []const u8,
            output: []u8,
            budget_ns: i128,
        ) ![]const u8 {
            try std.testing.expect(environment.len == 0);
            try std.testing.expect(budget_ns > 0);
            const expected = [_][]const u8{ "plutil", "codesign", "codesign", "lipo", "codesign", "xcrun", "xcrun", "spctl" };
            try std.testing.expect(std.mem.endsWith(u8, executable, expected[self.call]));
            try std.testing.expect(args.len > 0);
            const captures = [_][]const u8{
                "{\"CFBundleIdentifier\":\"dev.maru.apphost\"}",
                "Identifier=dev.maru.apphost\nTeamIdentifier=ABCDEFGHIJ\n",
                "designated => anchor apple generic\n",
                "arm64 x86_64\n",
                "",
                "",
                "",
                "",
            };
            const value = captures[self.call];
            self.call += 1;
            @memcpy(output[0..value.len], value);
            return output[0..value.len];
        }
    };
    var fake = Fake{};
    var storage: transport.Storage = undefined;
    const result = try transport.collectWith(
        &fake,
        Paths,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        &storage,
        std.time.ns_per_s,
    );
    try std.testing.expectEqual(@as(usize, 8), fake.call);
    try std.testing.expectEqualStrings("arm64 x86_64\n", result.architectures);
    try std.testing.expect(result.strict_signature_verified);
    try std.testing.expect(result.app_staple_verified);
    try std.testing.expect(result.dmg_staple_verified);
    try std.testing.expect(result.dmg_gatekeeper_verified);
}

test "Apple collection returns no partial observation after any child failure" {
    const Fake = struct {
        fail_at: usize,
        call: usize = 0,

        pub fn capture(self: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, output: []u8, _: i128) ![]const u8 {
            if (self.call == self.fail_at) return error.ChildFailed;
            self.call += 1;
            output[0] = 'x';
            return output[0..1];
        }
    };
    for (0..8) |fail_at| {
        var fake = Fake{ .fail_at = fail_at };
        var storage: transport.Storage = undefined;
        try std.testing.expectError(
            error.ChildFailed,
            transport.collectWith(&fake, Paths, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &storage, std.time.ns_per_s),
        );
    }
}

test "Apple collection rejects executor output outside the supplied bounded buffer" {
    const Fake = struct {
        pub fn capture(_: *@This(), _: []const u8, _: []const []const u8, _: []const []const u8, _: []u8, _: i128) ![]const u8 {
            return "foreign capture";
        }
    };
    var fake = Fake{};
    var storage: transport.Storage = undefined;
    try std.testing.expectError(
        error.InvalidCapture,
        transport.collectWith(&fake, Paths, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &storage, std.time.ns_per_s),
    );
}

test "Apple product leaf fails closed on child failure" {
    var storage: transport.Storage = undefined;
    var paths = Paths;
    paths.info_plist = "/usr/bin/false";
    try std.testing.expectError(
        error.ChildFailed,
        transport.collect(std.testing.io, paths, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", &storage, std.time.ns_per_s),
    );
}
