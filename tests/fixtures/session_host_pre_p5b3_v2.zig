//! Frozen, standalone MRSH v2 compatibility host extracted from the public wire behavior at
//! source revision `a9ed24855f6261303d6f467203bcfed183f27175`, immediately before P5b3.
//!
//! This fixture deliberately imports only `std`. It must not inherit current server capability
//! negotiation or controller-transfer behavior. The product E2E supplies an encoded v2 snapshot
//! as an opaque file; this old side only frames and serves those frozen bytes.

const std = @import("std");
const c = std.c;
const posix = std.posix;

const header_len = 32;
const runtime_get = "runtime.get";
const runtime_attach = "runtime.attach";
const runtime_detach = "runtime.detach";
const controller_takeover = "controller.takeover";

const Frame = struct {
    kind: u16,
    flags: u32,
    request_id: u64,
    stream_id: u64,
    payload: []u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next() orelse return error.MissingExecutable;
    const socket_path = args.next() orelse return error.MissingSocket;
    const host_id = args.next() orelse return error.MissingHost;
    const runtime_id = args.next() orelse return error.MissingRuntime;
    const snapshot_path = args.next() orelse return error.MissingSnapshot;
    const report_path = args.next() orelse return error.MissingReport;
    const owner_path = args.next() orelse return error.MissingOwner;
    const build_id = args.next() orelse return error.MissingBuildId;
    if (args.next() != null or host_id.len != 32 or runtime_id.len != 32)
        return error.InvalidArguments;

    const snapshot = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        snapshot_path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
    defer allocator.free(snapshot);
    const socket_z = try allocator.dupeZ(u8, socket_path);
    defer allocator.free(socket_z);
    const report_z = try allocator.dupeZ(u8, report_path);
    defer allocator.free(report_z);
    const owner_z = try allocator.dupeZ(u8, owner_path);
    defer allocator.free(owner_z);
    const owner_fd = c.open(owner_z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (owner_fd < 0 or c.fchmod(owner_fd, 0o600) != 0 or
        c.flock(owner_fd, c.LOCK.EX | c.LOCK.NB) != 0)
        return error.OwnerLeaseFailed;
    defer _ = c.close(owner_fd);

    _ = c.unlink(socket_z.ptr);
    const listener = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    defer _ = c.close(listener);
    var address = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&address.path, 0);
    if (socket_path.len >= address.path.len) return error.SocketPathTooLong;
    @memcpy(address.path[0..socket_path.len], socket_path);
    if (c.bind(listener, @ptrCast(&address), @sizeOf(posix.sockaddr.un)) != 0)
        return error.BindFailed;
    if (c.chmod(socket_z.ptr, 0o600) != 0 or c.listen(listener, 16) != 0)
        return error.ListenFailed;
    try appendReport(report_z, "ready\n");

    while (true) {
        const fd = c.accept(listener, null, null);
        if (fd < 0) {
            if (posix.errno(fd) == .INTR) continue;
            return error.AcceptFailed;
        }
        const worker = std.Thread.spawn(.{}, serveWorker, .{
            allocator,
            fd,
            host_id,
            runtime_id,
            snapshot,
            report_z,
            build_id,
        }) catch {
            _ = c.close(fd);
            return error.ThreadFailed;
        };
        worker.detach();
    }
}

fn serveWorker(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    host_id: []const u8,
    runtime_id: []const u8,
    snapshot: []const u8,
    report: [:0]const u8,
    build_id: []const u8,
) void {
    defer _ = c.close(fd);
    serveConnection(allocator, fd, host_id, runtime_id, snapshot, report, build_id) catch |err| {
        var error_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&error_buf, "error:{s}\n", .{@errorName(err)}) catch
            "error:format\n";
        appendReport(report, line) catch {};
    };
}

fn serveConnection(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    host_id: []const u8,
    runtime_id: []const u8,
    snapshot: []const u8,
    report: [:0]const u8,
    build_id: []const u8,
) !void {
    const hello = try readFrame(allocator, fd);
    defer allocator.free(hello.payload);
    if (hello.kind != 1 or hello.request_id != 0 or
        std.mem.indexOf(u8, hello.payload, "\"protocol_min\":2") == null or
        std.mem.indexOf(u8, hello.payload, "\"protocol_max\":2") == null)
        return error.InvalidHello;
    const legacy_gui = std.mem.indexOf(u8, hello.payload, "\"client_kind\":\"gui\"") != null;
    const ack = try std.fmt.allocPrint(
        allocator,
        "{{\"version\":2,\"host_id\":\"{s}\",\"build_id\":\"{s}\",\"lifecycle\":\"ready\",\"upgrade_epoch\":0,\"screen_codec_version\":2,\"capabilities\":[\"host_manifest_v1\",\"runtime_metadata_v1\",\"screen_stream_v2_current_body\"]}}",
        .{ host_id, build_id },
    );
    defer allocator.free(ack);
    try writeFrame(fd, 2, 0, hello.request_id, 0, ack);
    try appendReport(report, "hello\n");

    while (true) {
        const frame = readFrame(allocator, fd) catch return;
        defer allocator.free(frame.payload);
        var frame_buf: [64]u8 = undefined;
        const frame_line = try std.fmt.bufPrint(&frame_buf, "frame:{d}\n", .{frame.kind});
        try appendReport(report, frame_line);
        if (frame.kind == 8) {
            try appendReport(report, "input\n");
            continue;
        }
        if (frame.kind != 3 or frame.request_id == 0) return error.InvalidFrame;
        if (std.mem.indexOf(u8, frame.payload, runtime_get) != null) {
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"result\":{{\"runtime_id\":\"{s}\",\"cols\":1,\"rows\":1,\"resize_generation\":0,\"has_controller\":true,\"observer_count\":0}}}}",
                .{runtime_id},
            );
            defer allocator.free(body);
            try writeFrame(fd, 4, 0, frame.request_id, 0, body);
            try appendReport(report, "runtime.get\n");
        } else if (std.mem.indexOf(u8, frame.payload, runtime_attach) != null) {
            const observer = std.mem.indexOf(u8, frame.payload, "\"mode\":\"observer\"") != null;
            const controller = legacy_gui and
                std.mem.indexOf(u8, frame.payload, "\"mode\":\"controller\"") != null;
            if (!observer and !controller) return error.ControllerAttachForbidden;
            const body = if (observer)
                "{\"result\":{\"stream_id\":1,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}"
            else
                "{\"result\":{\"stream_id\":1,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}";
            try writeFrame(fd, 4, 0, frame.request_id, 0, body);
            try writeFrame(fd, 6, 1, 0, 1, snapshot);
            try appendReport(report, if (observer) "runtime.attach.observer\n" else "runtime.attach.controller\n");
        } else if (std.mem.indexOf(u8, frame.payload, runtime_detach) != null) {
            try writeFrame(fd, 4, 0, frame.request_id, 0, "{\"result\":{\"detached\":true}}");
            try appendReport(report, "runtime.detach\n");
        } else if (std.mem.indexOf(u8, frame.payload, controller_takeover) != null) {
            try appendReport(report, "controller.takeover.UNEXPECTED\n");
            return error.TakeoverRequestForbidden;
        } else return error.UnknownMethod;
    }
}

fn readFrame(allocator: std.mem.Allocator, fd: c.fd_t) !Frame {
    var header: [header_len]u8 = undefined;
    try readExact(fd, &header);
    if (!std.mem.eql(u8, header[0..4], "MRSH") or std.mem.readInt(u16, header[4..6], .big) != 2)
        return error.InvalidHeader;
    const payload_len = std.mem.readInt(u32, header[28..32], .big);
    if (payload_len > 1024 * 1024) return error.PayloadTooLarge;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try readExact(fd, payload);
    return .{
        .kind = std.mem.readInt(u16, header[6..8], .big),
        .flags = std.mem.readInt(u32, header[8..12], .big),
        .request_id = std.mem.readInt(u64, header[12..20], .big),
        .stream_id = std.mem.readInt(u64, header[20..28], .big),
        .payload = payload,
    };
}

fn writeFrame(fd: c.fd_t, kind: u16, flags: u32, request_id: u64, stream_id: u64, payload: []const u8) !void {
    var header: [header_len]u8 = undefined;
    @memcpy(header[0..4], "MRSH");
    std.mem.writeInt(u16, header[4..6], 2, .big);
    std.mem.writeInt(u16, header[6..8], kind, .big);
    std.mem.writeInt(u32, header[8..12], flags, .big);
    std.mem.writeInt(u64, header[12..20], request_id, .big);
    std.mem.writeInt(u64, header[20..28], stream_id, .big);
    std.mem.writeInt(u32, header[28..32], @intCast(payload.len), .big);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

fn readExact(fd: c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return error.ReadFailed;
        offset += @intCast(rc);
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

fn appendReport(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.ReportFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
}
