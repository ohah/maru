//! Current/N-1 MRSH connection의 typed ownership boundary.
//!
//! Adapter가 wire major와 exact screen codec을 1급 값으로 소유하고 HostPool/GUI에는 current DTO만 노출한다.
//! capability-tagged MRSH v1 frozen release는 current record body와 같고 screen header version만 1이므로 명시적으로
//! normalize한다. capability 없는 과거 v1 artifact나 MRSH/screen version 교차는 지원하지 않는다.

const std = @import("std");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const screen_stream = @import("screen_stream.zig");
const compatibility = @import("compatibility.zig");

pub const Kind = enum {
    current,
    previous,
};

pub const HostAdapter = struct {
    client: client_mod.Client,
    kind: Kind,

    pub fn init(client: client_mod.Client) !HostAdapter {
        const profile = compatibility.profileForMajor(client.wire_major) orelse return error.UnsupportedProtocol;
        const kind: Kind = switch (profile.kind) {
            .current => .current,
            .previous => .previous,
        };
        if (client.screen_codec_version != profile.screen_codec_version) return error.UnsupportedProtocol;
        return .{ .client = client, .kind = kind };
    }

    pub fn deinit(self: *HostAdapter) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn hostId(self: *const HostAdapter) u128 {
        return self.client.host_id;
    }

    pub fn wireMajor(self: *const HostAdapter) u16 {
        return self.client.wire_major;
    }

    /// host.info/runtime.list/host.upgrade.*처럼 screen codec과 독립된 control RPC.
    pub fn call(self: *HostAdapter, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        return self.client.call(method, params_json);
    }

    /// Client 내부의 selected wire major와 bounded screen reader가 current logical DTO로 normalize한다.
    pub fn logicalClient(self: *HostAdapter) *client_mod.Client {
        return &self.client;
    }
};

test "host adapter classifies current and N-1 without exposing N-1 as a current screen client" {
    const allocator = std.testing.allocator;
    const current_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xAA,
        .wire_major = protocol.version_major,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var current = try HostAdapter.init(current_client);
    defer current.deinit();
    try std.testing.expectEqual(Kind.current, current.kind);
    try std.testing.expectEqual(@as(u128, 0xAA), current.hostId());
    try std.testing.expect(current.logicalClient() == &current.client);

    const previous_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xBB,
        .wire_major = protocol.version_major - 1,
        .screen_codec_version = screen_stream.codec_version - 1,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var previous = try HostAdapter.init(previous_client);
    defer previous.deinit();
    try std.testing.expectEqual(Kind.previous, previous.kind);
    try std.testing.expectEqual(protocol.version_major - 1, previous.wireMajor());
    try std.testing.expect(previous.logicalClient() == &previous.client);
}
