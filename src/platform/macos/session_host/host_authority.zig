//! Disk manifest와 wire `host.info`를 한 순서로 갱신하는 daemon-local authority.

const std = @import("std");
const host_manifest = @import("host_manifest.zig");
const socket_server = @import("socket_server.zig");
const protocol = @import("protocol.zig");
const screen_stream = @import("screen_stream.zig");

pub const Error = host_manifest.Error || error{InvalidTransition};

pub const HostAuthority = struct {
    published: *host_manifest.Published,
    server: *socket_server.SocketServer,
    descriptor: host_manifest.Descriptor,

    pub fn init(
        published: *host_manifest.Published,
        server: *socket_server.SocketServer,
        descriptor: host_manifest.Descriptor,
    ) HostAuthority {
        var result = HostAuthority{
            .published = published,
            .server = server,
            .descriptor = descriptor,
        };
        result.publishWireStatus(false);
        return result;
    }

    pub fn setUpgradeCapable(self: *HostAuthority, capable: bool) void {
        self.publishWireStatus(capable);
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
        var next = self.descriptor;
        next.build_id = build_id;
        next.protocol_major = protocol_major;
        next.screen_codec_version = screen_codec_version;
        next.upgrade_epoch += 1;
        next.lifecycle = .ready;
        try self.commitDescriptor(next);
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

comptime {
    if (protocol.version_major == 0 or screen_stream.codec_version == 0)
        @compileError("host authority requires explicit protocol and screen generations");
}
