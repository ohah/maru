//! Release evidence의 durable aggregate가 실제 A/B candidate와 제품 gate를 닫아 결속하는지 검증한다.
//!
//! leaf parser와 aggregate writer/parser를 함께 통과시켜 테스트 결과 파일 이름이나 caller bool이
//! publication 권위로 승격되지 못하게 한다. 실제 signed 제품 실행과 GitHub attestation은 이 gate의 범위가 아니다.

const std = @import("std");
const evidence = @import("release_evidence");

const uuid = "123e4567-e89b-42d3-a456-426614174000";
const sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const sha_c = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const sha_d = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const sha_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const sha_f = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

fn common() evidence.Common {
    return .{
        .test_uuid = uuid,
        .repository = .{ .id = 123, .owner = "ohah", .name = "maru" },
        .release = .{ .id = 456, .tag = "v1.2.3", .version = "1.2.3" },
        .source = .{
            .commit = "1111111111111111111111111111111111111111",
            .tree = "2222222222222222222222222222222222222222",
        },
        .build = .{
            .workflow_ref = "ohah/maru/.github/workflows/release.yml@refs/tags/v1.2.3",
            .run_id = 789,
            .run_attempt = 2,
        },
        .candidate = .{ .dmg_sha256 = sha_a, .executable_sha256 = sha_b },
    };
}

fn predecessor() evidence.Predecessor {
    return .{
        .release_id = 400,
        .tag = "v1.2.2",
        .commit = "3333333333333333333333333333333333333333",
        .manifest_sha256 = sha_c,
        .dmg_sha256 = sha_d,
        .executable_sha256 = sha_e,
    };
}

fn defaultLeaf() []const u8 {
    const json =
        \\{"schema":"maru.session-host-default-false-baseline.v1","test_uuid":"123e4567-e89b-42d3-a456-426614174000","result":"passed","candidate_dmg_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","candidate_executable_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","resolved_default":false,"explicit_override_present":false,"signed_product":true}
    ;
    return json ++ "\n";
}

fn quitLeaf() []const u8 {
    const json =
        \\{"schema":"maru.session-host-signed-app-quit-reattach.v1","test_uuid":"123e4567-e89b-42d3-a456-426614174000","result":"passed","candidate_dmg_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","candidate_executable_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","runtime_count":1,"same_host_pid":true,"all_runtime_pids_preserved":true,"gui_exact_reattach":true,"runtime_screen_before_preserved":true,"runtime_screen_after_writable":true,"cleanup_complete":true}
    ;
    return json ++ "\n";
}

fn upgradeLeaf(comptime count: u64) []const u8 {
    const runtime_set = if (count == 1) sha_f else sha_c;
    return std.fmt.comptimePrint(
        "{{\"schema\":\"maru.session-host-signed-upgrade-e2e.v2\",\"test_uuid\":\"{s}\",\"result\":\"passed\",\"predecessor_executable_sha256\":\"{s}\",\"candidate_executable_sha256\":\"{s}\",\"signer_requirement_sha256\":\"{s}\",\"runtime_count\":{d},\"runtime_set_sha256\":\"{s}\",\"same_host_pid\":true,\"all_runtime_pids_preserved\":true,\"runtime_screen_before_preserved\":true,\"runtime_screen_after_writable\":true,\"gui_exact_reattach\":true,\"runtime_reaped_after_exit\":true,\"runtime_inventory_absent_observations\":2,\"status_committed\":true,\"status_reason\":\"none\",\"upgrade_capability_preserved\":true,\"epoch_before\":3,\"epoch_after\":4}}\n",
        .{ uuid, sha_e, sha_b, sha_f, count, runtime_set },
    );
}

test "baseline A leaves assemble into a canonical bound aggregate" {
    const bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .baseline_a = common() });
    try std.testing.expectEqualStrings(evidence.schema, parsed.schema());
}

test "upgrade B leaves assemble one and near-max without swapping identities" {
    const bytes = try evidence.assembleUpgrade(
        std.testing.allocator,
        common(),
        predecessor(),
        upgradeLeaf(1),
        upgradeLeaf(evidence.near_max_runtime_count),
    );
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    try evidence.bind(parsed.value(), .{ .upgrade_b = .{ .common = common(), .predecessor = predecessor() } });
    try std.testing.expectEqual(evidence.Profile.upgrade_b, parsed.profile());
}

test "aggregate parser rejects duplicate unknown missing trailing and noncanonical bytes" {
    const bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
    defer std.testing.allocator.free(bytes);
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "{\"schema\":", "{\"schema\":\"maru.session-host-release-evidence.v1\",\"schema\":");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidJson, evidence.parseCanonical(std.testing.allocator, duplicate));
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "{\"schema\":", "{\"unknown\":1,\"schema\":");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.InvalidJson, evidence.parseCanonical(std.testing.allocator, unknown));
    const nested_unknown = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"repository\":{", "\"repository\":{\"unknown\":1,");
    defer std.testing.allocator.free(nested_unknown);
    try std.testing.expectError(error.InvalidJson, evidence.parseCanonical(std.testing.allocator, nested_unknown));
    try std.testing.expectError(error.NonCanonical, evidence.parseCanonical(std.testing.allocator, bytes[0 .. bytes.len - 2]));
    const trailing = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, "{}" });
    defer std.testing.allocator.free(trailing);
    try std.testing.expectError(error.NonCanonical, evidence.parseCanonical(std.testing.allocator, trailing));
    const spaced = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, ":", ": ");
    defer std.testing.allocator.free(spaced);
    try std.testing.expectError(error.NonCanonical, evidence.parseCanonical(std.testing.allocator, spaced));
}

test "UUID profile role predecessor and result policy fail closed" {
    var bad = common();
    bad.test_uuid = "123e4567-e89b-12d3-a456-426614174000";
    try std.testing.expectError(error.InvalidUuid, evidence.assembleBaseline(std.testing.allocator, bad, defaultLeaf(), quitLeaf()));
    const failed = try std.mem.replaceOwned(u8, std.testing.allocator, defaultLeaf(), "\"passed\"", "\"failed\"");
    defer std.testing.allocator.free(failed);
    try std.testing.expectError(error.InvalidLeaf, evidence.assembleBaseline(std.testing.allocator, common(), failed, quitLeaf()));

    const bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    var stale_run = common();
    stale_run.build.run_attempt += 1;
    try std.testing.expectError(error.BindingMismatch, evidence.bind(parsed.value(), .{ .baseline_a = stale_run }));
}

test "leaf parser rejects replay duplicate unknown and candidate drift" {
    const replay = try std.mem.replaceOwned(u8, std.testing.allocator, defaultLeaf(), uuid, "123e4567-e89b-42d3-a456-426614174001");
    defer std.testing.allocator.free(replay);
    try std.testing.expectError(error.LeafMismatch, evidence.assembleBaseline(std.testing.allocator, common(), replay, quitLeaf()));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, quitLeaf(), "{\"schema\":", "{\"schema\":\"maru.session-host-signed-app-quit-reattach.v1\",\"schema\":");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.InvalidLeaf, evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), duplicate));
    const drift = try std.mem.replaceOwned(u8, std.testing.allocator, quitLeaf(), sha_b, sha_c);
    defer std.testing.allocator.free(drift);
    try std.testing.expectError(error.LeafMismatch, evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), drift));
}

test "upgrade leaves cannot exchange one and near-max roles or A and B images" {
    try std.testing.expectError(error.InvalidRuntimeCount, evidence.assembleUpgrade(
        std.testing.allocator,
        common(),
        predecessor(),
        upgradeLeaf(evidence.near_max_runtime_count),
        upgradeLeaf(1),
    ));
    const swapped = try std.mem.replaceOwned(u8, std.testing.allocator, upgradeLeaf(1), sha_e, sha_b);
    defer std.testing.allocator.free(swapped);
    try std.testing.expectError(error.LeafMismatch, evidence.assembleUpgrade(
        std.testing.allocator,
        common(),
        predecessor(),
        swapped,
        upgradeLeaf(evidence.near_max_runtime_count),
    ));

    const bytes = try evidence.assembleUpgrade(
        std.testing.allocator,
        common(),
        predecessor(),
        upgradeLeaf(1),
        upgradeLeaf(evidence.near_max_runtime_count),
    );
    defer std.testing.allocator.free(bytes);
    var parsed = try evidence.parseCanonical(std.testing.allocator, bytes);
    defer parsed.deinit();
    var wrong_predecessor = predecessor();
    wrong_predecessor.executable_sha256 = sha_b;
    try std.testing.expectError(error.BindingMismatch, evidence.bind(parsed.value(), .{ .upgrade_b = .{
        .common = common(),
        .predecessor = wrong_predecessor,
    } }));
}

test "evidence and scalar caps reject before publication" {
    const oversized = "x" ** (evidence.max_evidence_bytes + 1);
    try std.testing.expectError(error.EvidenceTooLarge, evidence.parseCanonical(std.testing.allocator, oversized));
    var bad = common();
    bad.repository.owner = "x" ** (evidence.max_scalar_string_bytes + 1);
    try std.testing.expectError(error.ScalarTooLarge, evidence.assembleBaseline(std.testing.allocator, bad, defaultLeaf(), quitLeaf()));

    const bytes = try evidence.assembleBaseline(std.testing.allocator, common(), defaultLeaf(), quitLeaf());
    defer std.testing.allocator.free(bytes);
    const long_owner = "x" ** (evidence.max_scalar_string_bytes + 1);
    const oversized_scalar = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "ohah", long_owner);
    defer std.testing.allocator.free(oversized_scalar);
    try std.testing.expectError(error.ScalarTooLarge, evidence.parseCanonical(std.testing.allocator, oversized_scalar));
}

fn assembleUpgradeAlloc(allocator: std.mem.Allocator) !void {
    const bytes = try evidence.assembleUpgrade(
        allocator,
        common(),
        predecessor(),
        upgradeLeaf(1),
        upgradeLeaf(evidence.near_max_runtime_count),
    );
    defer allocator.free(bytes);
    var parsed = try evidence.parseCanonical(allocator, bytes);
    defer parsed.deinit();
}

test "upgrade aggregate unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, assembleUpgradeAlloc, .{});
}
