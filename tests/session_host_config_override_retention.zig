const std = @import("std");
const config = @import("config");

const Owner = config.SessionKeepAliveBootstrapOwner;

test "G2 bootstrap seals one lease-owned scalar snapshot and rejects duplicate initialization" {
    var owner: Owner = .{};
    const first = try owner.initialize(.{
        .value = false,
        .provenance = .absent,
        .file_provenance = .missing,
    });
    try std.testing.expect(!first.value);
    try std.testing.expectEqual(config.SessionKeepAliveProvenance.absent, first.provenance);
    try std.testing.expectEqual(config.ConfigFileProvenance.missing, first.file_provenance);
    try std.testing.expectError(error.AlreadyInitialized, owner.initialize(.{
        .value = true,
        .provenance = .{ .explicit_valid = true },
        .file_provenance = .readable,
    }));
    try std.testing.expectEqual(first, owner.borrow().?);
}

test "G2 Reset plan distinguishes absent valid and invalid intent without consulting the default" {
    var absent: Owner = .{};
    _ = try absent.initialize(.{
        .value = false,
        .provenance = .absent,
        .file_provenance = .readable,
    });
    try std.testing.expectEqual(config.SessionKeepAliveResetPlan.none, absent.resetPlan().?);

    inline for (.{ false, true }) |value| {
        var explicit: Owner = .{};
        _ = try explicit.initialize(.{
            .value = value,
            .provenance = .{ .explicit_valid = value },
            .file_provenance = .readable,
        });
        try std.testing.expectEqual(config.SessionKeepAliveResetPlan{ .preserve = value }, explicit.resetPlan().?);
    }

    var invalid: Owner = .{};
    _ = try invalid.initialize(.{
        .value = true,
        .provenance = .explicit_invalid,
        .file_provenance = .readable,
    });
    try std.testing.expectEqual(config.SessionKeepAliveResetPlan{ .preserve = true }, invalid.resetPlan().?);
    try invalid.commitReset();
    try std.testing.expectEqual(
        config.SessionKeepAliveProvenance{ .explicit_valid = true },
        invalid.borrow().?.provenance,
    );
}

test "G2 Workspace toggle and reload replace the shared snapshot but Reset commit preserves ownership" {
    var owner: Owner = .{};
    _ = try owner.initialize(.{
        .value = false,
        .provenance = .absent,
        .file_provenance = .missing,
    });

    try owner.setExplicit(true);
    try std.testing.expectEqual(
        config.SessionKeepAliveProvenance{ .explicit_valid = true },
        owner.borrow().?.provenance,
    );
    // 라이브 토글 publication과 비동기 파일 write 완료를 한 상태로 거짓 합치지 않는다.
    try std.testing.expectEqual(config.ConfigFileProvenance.missing, owner.borrow().?.file_provenance);

    try owner.replaceFromReload(.{
        .value = false,
        .provenance = .explicit_invalid,
        .file_provenance = .readable,
    });
    try std.testing.expect(!owner.borrow().?.value);
    try std.testing.expectEqual(config.SessionKeepAliveProvenance.explicit_invalid, owner.borrow().?.provenance);
}

test "G2 mutation before bootstrap is rejected without publishing a snapshot" {
    var owner: Owner = .{};
    try std.testing.expectError(error.NotInitialized, owner.setExplicit(true));
    try std.testing.expectError(error.NotInitialized, owner.replaceFromReload(.{
        .value = true,
        .provenance = .{ .explicit_valid = true },
        .file_provenance = .readable,
    }));
    try std.testing.expectError(error.NotInitialized, owner.commitReset());
    try std.testing.expect(owner.borrow() == null);
    try std.testing.expect(owner.resetPlan() == null);
}
