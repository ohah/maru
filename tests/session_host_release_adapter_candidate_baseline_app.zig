//! Pins the preserved app executables to one typed candidate product before any child runs.

const std = @import("std");
const c = std.c;
const app = @import("release_adapter_candidate_baseline_app");
const files = @import("release_adapter_files");

fn digest(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

const Product = struct {
    frozen: [64]u8 = "0d6e4079e36703ebd37c00722f5891d28b0e2811dc114b129215123adcce3605".*,
    requirement: [64]u8 = "f8dcb7a13bf4991a7d7969ea1c8add149e79b13ae91c0e6c13994da38eb3636a".*,
    team_id: []const u8 = "TEAMID0000",
    drift: bool = false,
    calls: usize = 0,

    pub fn revalidate(self: *@This()) !app.ProductView {
        self.calls += 1;
        if (self.drift and self.calls > 1) self.frozen = digest("drifted");
        return .{ .frozen_sha256 = &self.frozen, .designated_requirement_sha256 = &self.requirement, .team_id = self.team_id };
    }
};

const Observer = struct {
    main_team: [10]u8 = "TEAMID0000".*,
    cli_team: [10]u8 = "TEAMID0000".*,

    pub fn pin(_: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }
    pub fn signer(self: *@This(), path: [:0]const u8) ![10]u8 {
        return if (std.mem.endsWith(u8, path, "/maru-macos-app")) self.main_team else self.cli_team;
    }
};

const Deadline = struct {
    calls: usize = 0,
    fail_at: usize = 0,

    pub fn remaining(self: *@This()) !i128 {
        self.calls += 1;
        if (self.fail_at != 0 and self.calls == self.fail_at) return error.TimedOut;
        return 1_000_000;
    }
};

const UntilObserver = struct {
    events: [128]u8 = undefined,
    length: usize = 0,
    team_id: [10]u8 = "TEAMID0000".*,
    foreign_capture: bool = false,

    fn add(self: *@This(), value: []const u8) void {
        if (self.length != 0) {
            self.events[self.length] = ',';
            self.length += 1;
        }
        @memcpy(self.events[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn log(self: *const @This()) []const u8 {
        return self.events[0..self.length];
    }
    pub fn pin(self: *@This(), path: [:0]const u8, result: *files.PinnedReleaseFile) !void {
        self.add(if (std.mem.endsWith(u8, path, "/maru-macos-app")) "pin-main" else "pin-cli");
        try files.pinReleaseFileObserved(result, path, true, files.max_release_asset_bytes);
    }
    pub fn verifyAndTeam(self: *@This(), path: [:0]const u8, deadline: *Deadline) ![10]u8 {
        _ = try deadline.remaining();
        self.add(if (std.mem.endsWith(u8, path, "/maru-macos-app")) "verify-main" else "verify-cli");
        _ = try deadline.remaining();
        _ = try deadline.remaining();
        self.add(if (std.mem.endsWith(u8, path, "/maru-macos-app")) "detail-main" else "detail-cli");
        _ = try deadline.remaining();
        if (self.foreign_capture) return error.ForeignCapture;
        return self.team_id;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    main_path: [std.fs.max_path_bytes:0]u8 = @splat(0),
    cli_path: [std.fs.max_path_bytes:0]u8 = @splat(0),

    fn init(self: *@This()) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try self.tmp.dir.createDirPath(std.testing.io, "Maru.app/Contents/MacOS");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru-macos-app", .data = "main" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru", .data = "cli" });
        var root: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root);
        _ = try std.fmt.bufPrintZ(&self.main_path, "{s}/Maru.app/Contents/MacOS/maru-macos-app", .{root[0..len]});
        _ = try std.fmt.bufPrintZ(&self.cli_path, "{s}/Maru.app/Contents/MacOS/maru", .{root[0..len]});
        if (c.chmod(self.main().ptr, 0o755) != 0 or c.chmod(self.cli().ptr, 0o755) != 0) return error.FixtureFailed;
    }
    fn deinit(self: *@This()) void {
        self.tmp.cleanup();
    }
    fn main(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.main_path, 0);
    }
    fn cli(self: *@This()) [:0]const u8 {
        return std.mem.sliceTo(&self.cli_path, 0);
    }
    fn paths(self: *@This()) app.Paths {
        return .{ .main_executable = self.main(), .cli_executable = self.cli() };
    }
};

test "preserved main and CLI bind to one candidate product" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{};
    var observer = Observer{};
    var authority: app.CandidateApp = .{};
    try app.bindWith(&observer, &product, fixture.paths(), &authority);
    const view = try authority.revalidateWith(&product, fixture.paths());
    try std.testing.expectEqualStrings(&digest("main"), &view.main.sha256);
    try std.testing.expectEqualStrings(&digest("cli"), &view.cli.sha256);
    try authority.deinit();
}

test "production composition pins then verifies both executables under one deadline" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{};
    var observer = UntilObserver{};
    var deadline = Deadline{};
    var authority: app.CandidateApp = .{};
    try app.bindCandidateUntilWith(&observer, &deadline, &product, fixture.paths(), &authority);
    try std.testing.expectEqualStrings("pin-main,pin-cli,verify-main,detail-main,verify-cli,detail-cli", observer.log());
    try std.testing.expectEqual(@as(usize, 10), deadline.calls);
    try authority.deinit();
}

test "deadline and command failures publish no app authority and close held files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{};
    var observer = UntilObserver{};
    var deadline = Deadline{ .fail_at = 4 };
    var authority: app.CandidateApp = .{};
    try std.testing.expectError(error.TimedOut, app.bindCandidateUntilWith(&observer, &deadline, &product, fixture.paths(), &authority));
    try std.testing.expect(authority.value() == null);
    try std.testing.expectEqual(@as(c.fd_t, -1), authority.main.fd);
    try std.testing.expectEqual(@as(c.fd_t, -1), authority.cli.fd);

    observer = .{ .foreign_capture = true };
    deadline = .{};
    try std.testing.expectError(error.ForeignCapture, app.bindCandidateUntilWith(&observer, &deadline, &product, fixture.paths(), &authority));
    try std.testing.expect(authority.value() == null);
}

test "deadline storage alias is rejected before filesystem or clock access" {
    var authority: app.CandidateApp = .{};
    var product = Product{};
    var observer = UntilObserver{};
    const bytes = std.mem.asBytes(&authority);
    const deadline: *Deadline = @ptrCast(@alignCast(bytes.ptr));
    try std.testing.expectError(error.InvalidOwner, app.bindCandidateUntilWith(&observer, deadline, &product, .{
        .main_executable = "/tmp/Maru.app/Contents/MacOS/maru-macos-app",
        .cli_executable = "/tmp/Maru.app/Contents/MacOS/maru",
    }, &authority));
    try std.testing.expectEqual(@as(usize, 0), observer.length);

    var real_deadline = Deadline{};
    const deadline_bytes = std.mem.asBytes(&real_deadline);
    const aliased_path: [:0]const u8 = @ptrCast(deadline_bytes[0 .. deadline_bytes.len - 1 :0]);
    try std.testing.expectError(error.InvalidOwner, app.bindCandidateUntilWith(&observer, &real_deadline, &product, .{
        .main_executable = aliased_path,
        .cli_executable = "/tmp/Maru.app/Contents/MacOS/maru",
    }, &authority));
    try std.testing.expectEqual(@as(usize, 0), real_deadline.calls);
}

test "production codesign plans are closed and pathname exact" {
    var storage: app.CommandStorage = .{};
    const path: [:0]const u8 = "/Applications/Maru.app/Contents/MacOS/maru";
    const verify = app.commandPlanForTest(.verify, path, &storage);
    try std.testing.expectEqualStrings("/usr/bin/codesign", verify.executable);
    const verify_expected = [_][:0]const u8{ "/usr/bin/codesign", "--verify", "--strict", "--verbose=0", path };
    try std.testing.expectEqualDeep(verify_expected[0..], verify.args);
    const detail = app.commandPlanForTest(.detail, path, &storage);
    const detail_expected = [_][:0]const u8{ "/usr/bin/codesign", "-d", "--verbose=4", path };
    try std.testing.expectEqualDeep(detail_expected[0..], detail.args);
    try std.testing.expectEqual(@as(usize, 0), detail.environment.len);
}

test "codesign detail requires one valid TeamIdentifier" {
    try std.testing.expectEqualStrings("TEAMID0000", &try app.teamIdentifierForTest("Identifier=maru\nTeamIdentifier=TEAMID0000\n"));
    try std.testing.expectError(error.InvalidTeamIdentifier, app.teamIdentifierForTest("Identifier=maru\n"));
    try std.testing.expectError(error.InvalidTeamIdentifier, app.teamIdentifierForTest("TeamIdentifier=not set\n"));
    try std.testing.expectError(error.InvalidTeamIdentifier, app.teamIdentifierForTest("TeamIdentifier=teamid0000\n"));
    try std.testing.expectError(error.InvalidTeamIdentifier, app.teamIdentifierForTest("TeamIdentifier=TEAMID0000\nTeamIdentifier=TEAMID0000\n"));
}

test "production composition rejects authority alias before touching candidate inputs" {
    var authority: app.CandidateApp = .{};
    var product: @import("release_adapter_candidate_product").CandidateProduct = .{};
    var deadline = Deadline{};
    const candidate: *const @import("release_adapter_candidate_files").CandidateFiles = @ptrCast(@alignCast(&authority));
    try std.testing.expectError(error.InvalidOwner, app.bindCandidateUntil(std.testing.io, candidate, &product, .{
        .dmg = "/tmp/candidate.dmg",
        .frozen_executable = "/tmp/frozen",
        .dmg_work = "/tmp/work",
    }, .{
        .main_executable = "/tmp/Maru.app/Contents/MacOS/maru-macos-app",
        .cli_executable = "/tmp/Maru.app/Contents/MacOS/maru",
    }, &deadline, &authority));
    try std.testing.expectEqual(@as(usize, 0), deadline.calls);
}

test "main digest and either signer mismatch publish no authority" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{ .frozen = digest("foreign") };
    var observer = Observer{};
    var authority: app.CandidateApp = .{};
    try std.testing.expectError(error.ProductMismatch, app.bindWith(&observer, &product, fixture.paths(), &authority));
    product = .{};
    observer.cli_team = "FOREIGN000".*;
    try std.testing.expectError(error.SignerMismatch, app.bindWith(&observer, &product, fixture.paths(), &authority));
    product = .{ .team_id = "teamid0000" };
    observer = .{};
    try std.testing.expectError(error.InvalidCandidate, app.bindWith(&observer, &product, fixture.paths(), &authority));
    try std.testing.expect(authority.value() == null);
}

test "symlink and hardlink aliases fail closed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{};
    var observer = Observer{};
    var authority: app.CandidateApp = .{};
    try fixture.tmp.dir.deleteFile(std.testing.io, "Maru.app/Contents/MacOS/maru-macos-app");
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real-main", .data = "main" });
    try fixture.tmp.dir.symLink(std.testing.io, "../../../real-main", "Maru.app/Contents/MacOS/maru-macos-app", .{});
    try std.testing.expectError(error.UnsafePath, app.bindWith(&observer, &product, fixture.paths(), &authority));
    try fixture.tmp.dir.deleteFile(std.testing.io, "Maru.app/Contents/MacOS/maru-macos-app");
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Maru.app/Contents/MacOS/maru-macos-app", .data = "main" });
    if (c.chmod(fixture.main().ptr, 0o755) != 0) return error.FixtureFailed;
    try fixture.tmp.dir.deleteFile(std.testing.io, "Maru.app/Contents/MacOS/maru");
    try fixture.tmp.dir.hardLink("Maru.app/Contents/MacOS/maru-macos-app", fixture.tmp.dir, "Maru.app/Contents/MacOS/maru", std.testing.io, .{});
    try std.testing.expectError(error.PathAlias, app.bindWith(&observer, &product, fixture.paths(), &authority));
}

test "candidate drift and copied owner are rejected" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var product = Product{ .drift = true };
    var observer = Observer{};
    var authority: app.CandidateApp = .{};
    try std.testing.expectError(error.CandidateChanged, app.bindWith(&observer, &product, fixture.paths(), &authority));
    product = .{};
    try app.bindWith(&observer, &product, fixture.paths(), &authority);
    var copied = authority;
    try std.testing.expectError(error.InvalidOwner, copied.revalidateWith(&product, fixture.paths()));
    try authority.deinit();
}

test "result and pathname storage alias is rejected before filesystem access" {
    std.testing.refAllDecls(app);
    var authority: app.CandidateApp = .{};
    var product = Product{};
    var observer = Observer{};
    const bytes = std.mem.asBytes(&authority);
    const path: [:0]const u8 = @ptrCast(bytes[0..@min(bytes.len - 1, 8) :0]);
    try std.testing.expectError(error.InvalidOwner, app.bindWith(&observer, &product, .{ .main_executable = path, .cli_executable = "/tmp/cli" }, &authority));
    try std.testing.expectError(error.InvalidPath, app.bindWith(&observer, &product, .{ .main_executable = "/tmp/main", .cli_executable = "/tmp/cli" }, &authority));
}
