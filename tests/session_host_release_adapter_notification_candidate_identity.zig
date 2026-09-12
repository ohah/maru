//! R2c must not run either GUI scenario until the three exact mounted executables share one
//! Developer ID TeamIdentifier and hardened-runtime signature under held-file authority.

const std = @import("std");
const identity = @import("release_adapter_notification_candidate_identity");
const dmg = @import("release_adapter_dmg_authority");
const files = @import("release_adapter_files");

const requirement = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const main_sha = "0d6e4079e36703ebd37c00722f5891d28b0e2811dc114b129215123adcce3605";
const cli_sha = "99bb88401742848e032fd6f51709415fb6be169a72d2e5d7fc44289255160d3c";
const helper_sha = "e81d3b0e9d82feaaf5f6e55bdff24731d7eee08632ffa63801e6397290c5d20a";

const Observer = struct {
    team: [10]u8 = "TEAMID0000".*,
    foreign_role: ?identity.Role = null,
    no_runtime_role: ?identity.Role = null,
    calls: usize = 0,

    pub fn pin(_: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }
    pub fn signature(self: *@This(), role: identity.Role, _: [:0]const u8) !identity.Signature {
        self.calls += 1;
        return .{
            .team_id = if (self.foreign_role == role) "FOREIGN000".* else self.team,
            .hardened_runtime = self.no_runtime_role != role,
        };
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    app: [std.fs.max_path_bytes:0]u8 = @splat(0),
    main: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli: [std.fs.max_path_bytes:0]u8 = @splat(0),
    helper: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDirPath(std.testing.io, "Maru.app/Contents/MacOS");
        try self.tmp.dir.createDirPath(std.testing.io, "Maru.app/Contents/Helpers");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru-macos-app", .data = "main" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru", .data = "cli" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/Helpers/maru-session-host-notification-center-helper", .data = "helper" });
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root);
        _ = try std.fmt.bufPrintZ(&self.app, "{s}/Maru.app", .{root[0..len]});
        _ = try std.fmt.bufPrintZ(&self.main, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{root[0..len]});
        _ = try std.fmt.bufPrintZ(&self.cli, "{s}/Maru.app/Contents/MacOS/maru", .{root[0..len]});
        _ = try std.fmt.bufPrintZ(&self.helper, "{s}/Maru.app/Contents/Helpers/maru-session-host-notification-center-helper", .{root[0..len]});
        const paths = [_][:0]const u8{ self.mainPath(), self.cliPath(), self.helperPath() };
        for (paths) |path|
            try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o755));
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn appPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.app, 0);
    }
    fn mainPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.main, 0);
    }
    fn cliPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.cli, 0);
    }
    fn helperPath(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.helper, 0);
    }
    fn view(self: *@This()) dmg.MountedCandidate {
        return .{
            .cli_path = self.cliPath(),
            .app_bundle_path = self.appPath(),
            .main_path = self.mainPath(),
            .mounted_cli_path = self.cliPath(),
            .helper_path = self.helperPath(),
            .main_sha256 = main_sha,
            .cli_sha256 = cli_sha,
            .helper_sha256 = helper_sha,
            .designated_requirement_sha256 = requirement,
            .team_id = "TEAMID0000",
        };
    }
};

test "R2c mounted main CLI and helper bind to one signer before execution" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var observer = Observer{};
    var authority: identity.Authority = .{};
    try identity.bindWith(&observer, fixture.view(), &authority);
    try std.testing.expectEqual(@as(usize, 3), observer.calls);
    try authority.revalidate(fixture.view());
    try authority.deinit();
}

test "R2c production bind rejects an expired caller deadline before observation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var expired: identity.Authority = .{};
    try std.testing.expectError(error.TimedOut, identity.bindUntil(std.testing.io, fixture.view(), &expired, now));
    try std.testing.expect(expired.value() == null);
}

test "R2c foreign signer and missing hardened runtime publish no authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    inline for (.{ identity.Role.main, identity.Role.cli, identity.Role.helper }) |role| {
        var observer = Observer{ .foreign_role = role };
        var authority: identity.Authority = .{};
        try std.testing.expectError(error.SignerMismatch, identity.bindWith(&observer, fixture.view(), &authority));
        try std.testing.expect(authority.value() == null);
        observer = .{ .no_runtime_role = role };
        try std.testing.expectError(error.HardenedRuntimeRequired, identity.bindWith(&observer, fixture.view(), &authority));
        try std.testing.expect(authority.value() == null);
    }
}

test "R2c path substitution is rejected before signer observation" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var observer = Observer{};
    var authority: identity.Authority = .{};
    var view = fixture.view();
    view.helper_path = fixture.mainPath();
    try std.testing.expectError(error.InvalidCandidate, identity.bindWith(&observer, view, &authority));
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
}

test "R2c byte drift after bind revokes execution authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var observer = Observer{};
    var authority: identity.Authority = .{};
    try identity.bindWith(&observer, fixture.view(), &authority);
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/Helpers/maru-session-host-notification-center-helper", .data = "drift" });
    try std.testing.expectError(error.CandidateChanged, authority.revalidate(fixture.view()));
    try authority.deinit();
}

test "R2c codesign detail requires one TeamIdentifier and runtime flag" {
    const parsed = try identity.parseSignatureForTest("CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded\nTeamIdentifier=TEAMID0000\n");
    try std.testing.expectEqualStrings("TEAMID0000", &parsed.team_id);
    try std.testing.expect(parsed.hardened_runtime);
    try std.testing.expectError(error.InvalidSignature, identity.parseSignatureForTest("CodeDirectory flags=0x0(none)\nTeamIdentifier=TEAMID0000\n"));
    try std.testing.expectError(error.InvalidSignature, identity.parseSignatureForTest("CodeDirectory flags=0x10000(runtime)\nTeamIdentifier=TEAMID0000\nTeamIdentifier=TEAMID0000\n"));
}
