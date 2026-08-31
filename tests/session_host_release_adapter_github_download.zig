//! Predecessor release assets가 gh pathname write 없이 descriptor-owned mapping으로만 내려오는지 검증한다.

const std = @import("std");
const manifest = @import("release_manifest");
const download = @import("release_adapter_github_download");

const payloads = [_][]const u8{ "dmg-bytes", "executable-bytes", "evidence-bytes" };
const leaves = [_][]const u8{
    "work/Maru-1.2.3-universal.dmg",
    "work/maru-session-host-1.2.3",
    "work/Maru-1.2.3-session-host-release.json",
};
const assets = [_]manifest.Asset{
    .{ .role = .universal_dmg, .name = "Maru-1.2.3-universal.dmg", .sha256 = "6652eabd1eceba46459c321bb97517f4b13a8c1d5c870274ea8e5b135181c6ec", .size = payloads[0].len },
    .{ .role = .frozen_product_executable, .name = "maru-session-host-1.2.3", .sha256 = "8018b11dad8c7822fad2ca35796f77c70f29a3f26858a7599be64b7dfc677b0a", .size = payloads[1].len },
    .{ .role = .evidence_summary, .name = "Maru-1.2.3-session-host-release.json", .sha256 = "3c2cc14b5c5beb243cf6ce364e02599dadd6ebccbd186c230f9f2139209ab7be", .size = payloads[2].len },
};

fn expected() download.Expected {
    return .{ .tag = "v1.2.3", .assets = &assets };
}

fn absolute(tmp: *std.testing.TmpDir, leaf: []const u8, out: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(out, "{s}/{s}", .{ root[0..len], leaf });
}

const Mode = enum { success, short, corrupt, foreign, too_long, timeout };

const Fake = struct {
    mode: Mode = .success,
    call: usize = 0,

    pub fn capture(self: *@This(), executable: []const u8, args: []const []const u8, environment: []const []const u8, output: []u8, budget_ns: i128) ![]const u8 {
        try std.testing.expectEqualStrings("/opt/trusted/gh", executable);
        try std.testing.expectEqualStrings("release", args[0]);
        try std.testing.expectEqualStrings("download", args[1]);
        try std.testing.expectEqualStrings("--output", args[7]);
        try std.testing.expectEqualStrings("-", args[8]);
        try std.testing.expectEqual(@as(usize, 2), environment.len);
        try std.testing.expectEqualStrings("GH_TOKEN=secret-token", environment[0]);
        try std.testing.expectEqualStrings("GH_PROMPT_DISABLED=1", environment[1]);
        try std.testing.expect(budget_ns > 0);
        const bytes = payloads[self.call];
        self.call += 1;
        switch (self.mode) {
            .success => {
                @memcpy(output, bytes);
                return output;
            },
            .short => {
                @memcpy(output[0 .. bytes.len - 1], bytes[0 .. bytes.len - 1]);
                return output[0 .. bytes.len - 1];
            },
            .corrupt => {
                @memcpy(output, bytes);
                output[0] ^= 1;
                return output;
            },
            .foreign => return bytes,
            .too_long => return error.OutputTooLarge,
            .timeout => return error.TimedOut,
        }
    }
};

test "predecessor download escapes glob metacharacters into exact stdout command" {
    var storage: download.PlanStorage = undefined;
    const special: manifest.Asset = .{ .role = .universal_dmg, .name = "literal[*]?.dmg", .sha256 = assets[0].sha256, .size = 1 };
    const plan = try download.plan(&storage, "v1.2.3", special);
    const want = [_][]const u8{ "release", "download", "v1.2.3", "--repo", "ohah/maru", "--pattern", "literal\\[\\*]\\?.dmg", "--output", "-" };
    try std.testing.expectEqual(want.len, plan.args.len);
    for (want, plan.args) |left, right| try std.testing.expectEqualStrings(left, right);
}

test "predecessor download requires the canonical three-role expected set" {
    try download.validateExpected(expected());
    var duplicate = assets;
    duplicate[2].role = .universal_dmg;
    try std.testing.expectError(error.InvalidExpected, download.validateExpected(.{ .tag = "v1.2.3", .assets = &duplicate }));
    try std.testing.expectError(error.InvalidExpected, download.validateExpected(.{ .tag = "v1.2.3", .assets = assets[0..2] }));
}

test "predecessor download writes exact mapped assets and cleanup removes owned workdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var fake = Fake{};
    var set: download.DownloadedSet = .{};
    try download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "secret-token", try absolute(&tmp, "work", &path_buf), expected(), std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 3), set.count());
    for (assets, payloads, leaves) |asset, bytes, leaf| {
        const observed = set.asset(asset.role) orelse return error.MissingDownloadedAsset;
        try std.testing.expect(std.mem.endsWith(u8, observed.path, leaf));
        try std.testing.expectEqual(asset.size, observed.size);
        try std.testing.expectEqualStrings(asset.sha256, observed.sha256);
        try std.testing.expect(observed.device != 0 and observed.inode != 0);
        const read = try tmp.dir.readFileAlloc(std.testing.io, leaf, std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(read);
        try std.testing.expectEqualStrings(bytes, read);
        const stat = try tmp.dir.statFile(std.testing.io, leaf, .{});
        try std.testing.expectEqual(@as(u32, 0o400), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    }
    try set.cleanup();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
}

test "predecessor download short output fails and leaves no residue" {
    try expectFailureNoResidue(.short, error.SizeMismatch);
}

test "predecessor download long output fails and leaves no residue" {
    try expectFailureNoResidue(.too_long, error.OutputTooLarge);
}

test "predecessor download digest mismatch fails and leaves no residue" {
    try expectFailureNoResidue(.corrupt, error.DigestMismatch);
}

test "predecessor download rejects foreign capture token budget and occupied workdir" {
    try expectFailureNoResidue(.foreign, error.InvalidCapture);
    try expectFailureNoResidue(.timeout, error.TimedOut);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "work", .default_dir);
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var fake = Fake{};
    var set: download.DownloadedSet = .{};
    const path = try absolute(&tmp, "work", &path_buf);
    try std.testing.expectError(error.DestinationExists, download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "secret-token", path, expected(), std.time.ns_per_s));
    try std.testing.expectError(error.InvalidToken, download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "bad\ntoken", path, expected(), std.time.ns_per_s));
    try std.testing.expectError(error.InvalidBudget, download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "secret-token", path, expected(), 0));

    var link_path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const link_path = try absolute(&tmp, "linked-work", &link_path_buf);
    try tmp.dir.symLink(std.testing.io, "work", "linked-work", .{});
    try std.testing.expectError(error.DestinationExists, download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "secret-token", link_path, expected(), std.time.ns_per_s));
}

test "predecessor download product child failure leaves no residue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var set: download.DownloadedSet = .{};
    try std.testing.expectError(error.ChildFailed, download.downloadAll(&set, std.testing.io, "/usr/bin/false", "secret-token", try absolute(&tmp, "work", &path_buf), expected(), std.time.ns_per_s));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
}

fn expectFailureNoResidue(mode: Mode, expected_error: anyerror) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var fake = Fake{ .mode = mode };
    var set: download.DownloadedSet = .{};
    try std.testing.expectError(expected_error, download.downloadAllWith(&set, &fake, "/opt/trusted/gh", "secret-token", try absolute(&tmp, "work", &path_buf), expected(), std.time.ns_per_s));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "work", .{}));
}
