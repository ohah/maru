const std = @import("std");
const receipt = @import("release_adapter_notification_app_receipt");

const host_id = "00000000000000000000000000000001";
const runtime_id = "00000000000000000000000000000002";
const request = "maru-" ++ host_id ++ "-" ++ runtime_id ++ "-7";

fn expected(scenario: receipt.Scenario) receipt.Expected {
    return .{
        .scenario = scenario,
        .request_identifier = request,
        .host_id = host_id,
        .runtime_id = runtime_id,
        .event_id = 7,
        .clicked_at_ns = 30,
        .deadline_ns = 100,
    };
}

const canonical_zero = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":50,\"attach_kind\":\"recovered\"}";
const canonical_live = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-live-then-quit\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":60,\"attach_at_ns\":70,\"attach_kind\":\"bound\"}";

test "R2b2 canonical gui-zero receipt binds recovered attach after helper click" {
    const observed = try receipt.parse(std.testing.allocator, canonical_zero, expected(.gui_zero));
    try std.testing.expectEqual(receipt.AttachKind.recovered, observed.attach_kind);
    try std.testing.expectEqual(@as(u64, 40), observed.callback_at_ns);
    try std.testing.expectEqual(@as(u64, 50), observed.attach_at_ns);
}

test "R2b2 canonical live receipt binds the existing runtime" {
    const observed = try receipt.parse(std.testing.allocator, canonical_live, expected(.gui_live_then_quit));
    try std.testing.expectEqual(receipt.AttachKind.bound, observed.attach_kind);
}

test "R2b2 rejects noncanonical JSON duplicate unknown reordered and oversized payloads" {
    const bytes = canonical_zero;
    try std.testing.expectError(error.NonCanonicalReceipt, receipt.parse(std.testing.allocator, " " ++ bytes, expected(.gui_zero)));
    try std.testing.expectError(error.InvalidReceipt, receipt.parse(std.testing.allocator, bytes[0 .. bytes.len - 1] ++ ",\"extra\":1}", expected(.gui_zero)));
    try std.testing.expectError(error.NonCanonicalReceipt, receipt.parse(
        std.testing.allocator,
        "{\"scenario\":\"gui-zero\",\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":50,\"attach_kind\":\"recovered\"}",
        expected(.gui_zero),
    ));
    var oversized: [1025]u8 = @splat('x');
    try std.testing.expectError(error.ReceiptTooLarge, receipt.parse(std.testing.allocator, &oversized, expected(.gui_zero)));
}

test "R2b2 rejects identity time and scenario attach-kind drift" {
    var wrong = expected(.gui_zero);
    wrong.host_id = "00000000000000000000000000000003";
    wrong.request_identifier = "maru-00000000000000000000000000000003-" ++ runtime_id ++ "-7";
    try std.testing.expectError(error.IdentityMismatch, receipt.parse(std.testing.allocator, canonical_zero, wrong));
    const early = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":30,\"attach_at_ns\":50,\"attach_kind\":\"recovered\"}";
    const late = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":100,\"attach_kind\":\"recovered\"}";
    const wrong_kind = "{\"schema\":\"maru.session-host-notification-app-receipt.v1\",\"scenario\":\"gui-zero\",\"request_identifier\":\"" ++ request ++ "\",\"host_id\":\"" ++ host_id ++ "\",\"runtime_id\":\"" ++ runtime_id ++ "\",\"event_id\":7,\"callback_at_ns\":40,\"attach_at_ns\":50,\"attach_kind\":\"bound\"}";
    try std.testing.expectError(error.InvalidTimeline, receipt.parse(std.testing.allocator, early, expected(.gui_zero)));
    try std.testing.expectError(error.InvalidTimeline, receipt.parse(std.testing.allocator, late, expected(.gui_zero)));
    try std.testing.expectError(error.AttachKindMismatch, receipt.parse(std.testing.allocator, wrong_kind, expected(.gui_zero)));
}

test "R2b2 publishes exact canonical bytes only after validation" {
    const Publisher = struct {
        calls: usize = 0,
        bytes: ?[]const u8 = null,
        pub fn publish(self: *@This(), _: [:0]const u8, value: []const u8) !void {
            self.calls += 1;
            self.bytes = value;
        }
    };
    const bytes = canonical_zero;
    var publisher = Publisher{};
    const observed = try receipt.parseAndPublishWith(&publisher, std.testing.allocator, bytes, expected(.gui_zero), "/private/tmp/receipt.json");
    try std.testing.expectEqual(@as(usize, 1), publisher.calls);
    try std.testing.expectEqualStrings(bytes, publisher.bytes.?);
    try std.testing.expectEqual(receipt.AttachKind.recovered, observed.attach_kind);

    var invalid_publisher = Publisher{};
    try std.testing.expectError(error.NonCanonicalReceipt, receipt.parseAndPublishWith(
        &invalid_publisher,
        std.testing.allocator,
        " " ++ bytes,
        expected(.gui_zero),
        "/private/tmp/receipt.json",
    ));
    try std.testing.expectEqual(@as(usize, 0), invalid_publisher.calls);
}

test "R2b2 actual publication is absent 0600 and never replaces an existing leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var path_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_storage, "{s}/receipt.json", .{root[0..root_len]});
    _ = try receipt.parseAndPublish(std.testing.allocator, canonical_zero, expected(.gui_zero), path);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "receipt.json", std.testing.allocator, .limited(receipt.max_receipt_bytes));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(canonical_zero, bytes);
    const stat = try tmp.dir.statFile(std.testing.io, "receipt.json", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    try std.testing.expectError(error.DestinationExists, receipt.parseAndPublish(
        std.testing.allocator,
        canonical_zero,
        expected(.gui_zero),
        path,
    ));
}

fn allocationParse(allocator: std.mem.Allocator) !void {
    _ = try receipt.parse(allocator, canonical_zero, expected(.gui_zero));
}

test "R2b2 parser fails closed at every allocation index" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationParse, .{});
}

test "R2b2 receipt leaf reuses the exclusive file SSOT and owns no pathname syscall" {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/platform/macos/session_host/release_adapter_notification_app_receipt.zig",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(source);
    const parse_at = std.mem.indexOf(u8, source, "const observed = try parse(allocator, bytes, expected);") orelse
        return error.MissingParse;
    const publish_at = std.mem.indexOf(u8, source, "try publisher.publish(output_path, bytes);") orelse
        return error.MissingPublish;
    try std.testing.expect(parse_at < publish_at);
    try std.testing.expectEqual(@as(usize, 1), count(source, "files.publishSummaryExclusive("));
    inline for (.{ "std.fs.cwd", "open(", "unlink", "deleteFile", "chmod(", "rename(" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(source, forbidden));
    }
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}
