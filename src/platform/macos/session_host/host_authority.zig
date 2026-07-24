//! Disk manifest와 wire `host.info`를 한 순서로 갱신하는 daemon-local authority.

const std = @import("std");
const host_manifest = @import("host_manifest.zig");
const socket_server = @import("socket_server.zig");
const protocol = @import("protocol.zig");
const screen_stream = @import("screen_stream.zig");
const upgrade_wire = @import("upgrade_wire.zig");

pub const Error = host_manifest.Error || error{InvalidTransition};

pub const HostAuthority = struct {
    allocator: std.mem.Allocator,
    published: *host_manifest.Published,
    server: *socket_server.SocketServer,
    descriptor: host_manifest.Descriptor,

    pub fn init(
        allocator: std.mem.Allocator,
        published: *host_manifest.Published,
        server: *socket_server.SocketServer,
        descriptor: host_manifest.Descriptor,
    ) Error!HostAuthority {
        const build_id = allocator.dupe(u8, descriptor.build_id) catch return error.OutOfMemory;
        errdefer allocator.free(build_id);
        const endpoint = allocator.dupe(u8, descriptor.endpoint) catch return error.OutOfMemory;
        var result = HostAuthority{
            .allocator = allocator,
            .published = published,
            .server = server,
            .descriptor = .{
                .host_id = descriptor.host_id,
                .build_id = build_id,
                .protocol_major = descriptor.protocol_major,
                .screen_codec_version = descriptor.screen_codec_version,
                .upgrade_epoch = descriptor.upgrade_epoch,
                .lifecycle = descriptor.lifecycle,
                .endpoint = endpoint,
            },
        };
        result.publishWireStatus(false);
        return result;
    }

    pub fn deinit(self: *HostAuthority) void {
        self.server.upgrade_ops = null;
        self.server.host_status = .{};
        self.allocator.free(self.descriptor.build_id);
        self.allocator.free(self.descriptor.endpoint);
        self.* = undefined;
    }

    /// Staged self-image/preflight가 모두 준비된 controller만 설치한다. Ops 존재와 hello capability를 한 commit으로
    /// 바꿔 "광고했지만 dispatch 없음" 또는 "dispatch 있지만 숨김" 상태를 만들지 않는다.
    pub fn installUpgradeController(self: *HostAuthority, ops: ?upgrade_wire.Ops) void {
        self.server.upgrade_ops = ops;
        self.publishWireStatus(ops != null);
    }

    pub fn beginRestoring(self: *HostAuthority) Error!void {
        if (self.descriptor.lifecycle != .ready) return error.InvalidTransition;
        var next = self.descriptor;
        next.lifecycle = .restoring;
        try self.commitDescriptor(next);
    }

    pub fn rollbackReady(self: *HostAuthority) Error!void {
        if (self.descriptor.lifecycle != .restoring) return error.InvalidTransition;
        var next = self.descriptor;
        next.lifecycle = .ready;
        try self.commitDescriptor(next);
    }

    pub fn commitTarget(
        self: *HostAuthority,
        build_id: []const u8,
        protocol_major: u16,
        screen_codec_version: u16,
    ) Error!void {
        if (self.descriptor.lifecycle != .restoring or self.descriptor.upgrade_epoch == std.math.maxInt(u64))
            return error.InvalidTransition;
        const owned_build_id = self.allocator.dupe(u8, build_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_build_id);
        const old_build_id = self.descriptor.build_id;
        var next = self.descriptor;
        next.build_id = owned_build_id;
        next.protocol_major = protocol_major;
        next.screen_codec_version = screen_codec_version;
        next.upgrade_epoch += 1;
        next.lifecycle = .ready;
        try self.commitDescriptor(next);
        self.allocator.free(old_build_id);
    }

    pub fn markDraining(self: *HostAuthority) Error!void {
        if (self.descriptor.lifecycle != .ready) return error.InvalidTransition;
        var next = self.descriptor;
        next.lifecycle = .draining;
        try self.commitDescriptor(next);
    }

    fn commitDescriptor(self: *HostAuthority, next: host_manifest.Descriptor) Error!void {
        // Disk routing authority가 먼저 durable해진 뒤에만 새 connection이 보는 wire identity를 바꾼다.
        try self.published.republish(next);
        self.descriptor = next;
        self.publishWireStatus(self.server.host_status.upgrade_capable);
    }

    fn publishWireStatus(self: *HostAuthority, upgrade_capable: bool) void {
        self.server.host_status = .{
            .manifest_capable = true,
            .upgrade_capable = upgrade_capable,
            .build_id = self.descriptor.build_id,
            .protocol_major = self.descriptor.protocol_major,
            .screen_codec_version = self.descriptor.screen_codec_version,
            .upgrade_epoch = self.descriptor.upgrade_epoch,
            .lifecycle = self.descriptor.lifecycle,
        };
    }
};

test "host authority owns wire build and endpoint strings" {
    const allocator = std.testing.allocator;
    var registry = @import("registry.zig").TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server: socket_server.SocketServer = .{
        .listen_fd = -1,
        .server_uid = std.c.getuid(),
        .socket_path = try allocator.dupeZ(u8, "/tmp/unused-authority.sock"),
        .allocator = allocator,
        .host_id = 1,
        .registry = &registry,
    };
    defer allocator.free(server.socket_path);
    var publication: host_manifest.Published = undefined;
    const source_build = try allocator.dupe(u8, "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    const source_endpoint = try allocator.dupe(u8, "/tmp/maru-0/sh/00000000000000000000000000000001.sock");
    var authority = try HostAuthority.init(allocator, &publication, &server, .{
        .host_id = 1,
        .build_id = source_build,
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 0,
        .lifecycle = .ready,
        .endpoint = source_endpoint,
    });
    allocator.free(source_build);
    allocator.free(source_endpoint);
    defer authority.deinit();
    try std.testing.expectEqualStrings(
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        server.host_status.build_id,
    );
}

comptime {
    if (protocol.version_major == 0 or screen_stream.codec_version == 0)
        @compileError("host authority requires explicit protocol and screen generations");
}
