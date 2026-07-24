//! 실행 중 session host를 `host_id`로 찾는 exact discovery manifest(U4).
//!
//! Workspace는 `{host_id,runtime_id}`만 저장한다. endpoint/protocol/build를 workspace에 복제하지 않고 이 owner-only
//! registry가 단일 출처로 소유한다. 파일은 `<session-dir>/hosts/<host-id>/host.v1.json`에 0600으로 원자 publish되며,
//! reader는 모든 부모 디렉터리와 leaf를 no-follow/same-UID로 확인한 뒤 bounded JSON을 파싱한다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const staged_image = @import("staged_image.zig");
const host_identity = @import("host_identity.zig");
const short_endpoint = @import("short_endpoint.zig");

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
const RENAME_SWAP: c_uint = 0x00000002;
const RENAME_EXCL: c_uint = 0x00000004;

pub const schema_version: u16 = 1;
pub const max_manifest_bytes: usize = 16 * 1024;
pub const max_build_id_bytes: usize = 128;
pub const max_endpoint_bytes: usize = 103;

pub const Lifecycle = host_identity.Lifecycle;

pub const Descriptor = struct {
    host_id: u128,
    build_id: []const u8,
    protocol_major: u16,
    screen_codec_version: u16,
    upgrade_epoch: u64,
    lifecycle: Lifecycle,
    endpoint: []const u8,
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    host_id: u128,
    build_id: []u8,
    protocol_major: u16,
    screen_codec_version: u16,
    upgrade_epoch: u64,
    lifecycle: Lifecycle,
    endpoint: []u8,

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.build_id);
        self.allocator.free(self.endpoint);
        self.* = undefined;
    }

    pub fn descriptor(self: *const Manifest) Descriptor {
        return .{
            .host_id = self.host_id,
            .build_id = self.build_id,
            .protocol_major = self.protocol_major,
            .screen_codec_version = self.screen_codec_version,
            .upgrade_epoch = self.upgrade_epoch,
            .lifecycle = self.lifecycle,
            .endpoint = self.endpoint,
        };
    }
};

pub const Error = error{
    ManifestNotFound,
    InvalidDirectory,
    InvalidManifest,
    OpenFailed,
    ReadFailed,
    WriteFailed,
    SyncFailed,
    RenameFailed,
    OutOfMemory,
};

pub const Published = struct {
    const FileIdentity = struct {
        dev: posix.dev_t,
        ino: posix.ino_t,
    };

    allocator: std.mem.Allocator,
    hosts_root: [:0]u8,
    host_dir: [:0]u8,
    manifest_path: [:0]u8,
    identity: FileIdentity,

    pub fn deinit(self: *Published) void {
        if (fileIdentity(self.manifest_path)) |current| {
            if (sameIdentity(current, self.identity)) _ = c.unlink(self.manifest_path.ptr);
        } else |_| {}
        if (openOwnerDir(self.host_dir)) |fd| {
            _ = c.fsync(fd);
            _ = c.close(fd);
        } else |_| {}
        _ = c.rmdir(self.host_dir.ptr);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.host_dir);
        _ = c.rmdir(self.hosts_root.ptr);
        self.allocator.free(self.hosts_root);
        self.* = undefined;
    }

    pub fn republish(self: *Published, descriptor: Descriptor) Error!void {
        if (descriptor.host_id == 0) return error.InvalidManifest;
        var expected_dir_buf: [768]u8 = undefined;
        const parent = std.fs.path.dirname(self.host_dir) orelse return error.InvalidDirectory;
        const session_dir = std.fs.path.dirname(parent) orelse return error.InvalidDirectory;
        const expected = hostDirPathIn(&expected_dir_buf, session_dir, descriptor.host_id) catch
            return error.InvalidDirectory;
        if (!std.mem.eql(u8, expected, self.host_dir)) return error.InvalidManifest;
        try validateDescriptor(descriptor, session_dir);
        const current = try fileIdentity(self.manifest_path);
        if (!sameIdentity(current, self.identity)) return error.InvalidManifest;
        self.identity = try writeAtomic(self.allocator, self.host_dir, self.manifest_path, descriptor, true);
    }
};

pub fn hostsRootPathIn(buf: []u8, session_dir: []const u8) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/hosts", .{trimTrailingSlash(session_dir)});
}

pub fn hostDirPathIn(buf: []u8, session_dir: []const u8, host_id: u128) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/hosts/{x:0>32}", .{ trimTrailingSlash(session_dir), host_id });
}

pub fn manifestPathIn(buf: []u8, session_dir: []const u8, host_id: u128) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/hosts/{x:0>32}/host.v1.json", .{ trimTrailingSlash(session_dir), host_id });
}

pub fn ownerLockPathIn(buf: []u8, session_dir: []const u8, host_id: u128) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/hosts/{x:0>32}/owner.lock", .{ trimTrailingSlash(session_dir), host_id });
}

/// Socket bind 전에 host별 lifetime owner lease를 잡을 수 있도록 registry directory만 먼저 준비한다.
pub fn prepareHostDirectory(session_dir: [:0]const u8, host_id: u128) Error!void {
    if (host_id == 0) return error.InvalidManifest;
    try validateOwnerDir(session_dir);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return error.InvalidDirectory;
    try ensureOwnerDir(hosts_root);
    var host_buf: [768]u8 = undefined;
    const host_dir = hostDirPathIn(&host_buf, session_dir, host_id) catch return error.InvalidDirectory;
    try ensureOwnerDir(host_dir);
}

/// 현재 실행 image의 SHA-256을 manifest build identity로 쓴다. Protocol major만으로 같은 major의 서로 다른
/// body 의미를 추측하지 않기 위한 exact fingerprint이며, updater의 마케팅 버전과는 별개다.
pub fn buildIdForExecutable(allocator: std.mem.Allocator, executable_path: [:0]const u8) Error![]u8 {
    const identity = staged_image.inspect(executable_path) catch return error.InvalidManifest;
    const hex = std.fmt.bytesToHex(identity.sha256, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{&hex}) catch return error.OutOfMemory;
}

pub fn publish(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    descriptor: Descriptor,
) Error!Published {
    try validateDescriptor(descriptor, session_dir);
    try validateOwnerDir(session_dir);

    try prepareHostDirectory(session_dir, descriptor.host_id);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return error.InvalidDirectory;
    var host_buf: [768]u8 = undefined;
    const host_dir = hostDirPathIn(&host_buf, session_dir, descriptor.host_id) catch return error.InvalidDirectory;
    var manifest_buf: [832]u8 = undefined;
    const manifest_path = manifestPathIn(&manifest_buf, session_dir, descriptor.host_id) catch
        return error.InvalidDirectory;

    const identity = try writeAtomic(allocator, host_dir, manifest_path, descriptor, false);
    errdefer {
        _ = c.unlink(manifest_path.ptr);
        _ = c.rmdir(host_dir.ptr);
        _ = c.rmdir(hosts_root.ptr);
    }
    const owned_hosts_root = allocator.dupeZ(u8, hosts_root) catch return error.OutOfMemory;
    errdefer allocator.free(owned_hosts_root);
    const owned_host_dir = allocator.dupeZ(u8, host_dir) catch return error.OutOfMemory;
    errdefer allocator.free(owned_host_dir);
    const owned_manifest = allocator.dupeZ(u8, manifest_path) catch return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .hosts_root = owned_hosts_root,
        .host_dir = owned_host_dir,
        .manifest_path = owned_manifest,
        .identity = identity,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
) Error!Manifest {
    if (host_id == 0) return error.InvalidManifest;
    try validateOwnerDir(session_dir);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return error.InvalidDirectory;
    validateOwnerDir(hosts_root) catch |err| return mapMissingDirectory(err);
    var host_buf: [768]u8 = undefined;
    const host_dir = hostDirPathIn(&host_buf, session_dir, host_id) catch return error.InvalidDirectory;
    validateOwnerDir(host_dir) catch |err| return mapMissingDirectory(err);
    var path_buf: [832]u8 = undefined;
    const path = manifestPathIn(&path_buf, session_dir, host_id) catch return error.InvalidDirectory;

    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) {
        if (posix.errno(fd) == .NOENT) return error.ManifestNotFound;
        return error.OpenFailed;
    }
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        (stat.mode & 0o777) != 0o600 or stat.size <= 0 or stat.size > max_manifest_bytes)
        return error.InvalidManifest;

    const bytes = allocator.alloc(u8, @intCast(stat.size)) catch return error.OutOfMemory;
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) return error.ReadFailed;
        offset += @intCast(rc);
    }
    var manifest = try decode(allocator, bytes);
    errdefer manifest.deinit();
    if (manifest.host_id != host_id) return error.InvalidManifest;
    try validateDescriptor(manifest.descriptor(), session_dir);
    return manifest;
}

pub fn encode(allocator: std.mem.Allocator, descriptor: Descriptor) Error![]u8 {
    try validateDescriptorShape(descriptor);
    var host_hex_buf: [32]u8 = undefined;
    const host_hex = std.fmt.bufPrint(&host_hex_buf, "{x:0>32}", .{descriptor.host_id}) catch
        return error.InvalidManifest;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.write(.{
        .schema = schema_version,
        .host_id = host_hex,
        .build_id = descriptor.build_id,
        .protocol_major = descriptor.protocol_major,
        .screen_codec_version = descriptor.screen_codec_version,
        .upgrade_epoch = descriptor.upgrade_epoch,
        .lifecycle = @tagName(descriptor.lifecycle),
        .endpoint = descriptor.endpoint,
    }) catch return error.OutOfMemory;
    if (out.written().len > max_manifest_bytes) return error.InvalidManifest;
    return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Manifest {
    if (bytes.len == 0 or bytes.len > max_manifest_bytes) return error.InvalidManifest;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidManifest;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidManifest,
    };
    const schema = intField(obj, "schema") orelse return error.InvalidManifest;
    if (schema != schema_version) return error.InvalidManifest;
    const host_hex = stringField(obj, "host_id") orelse return error.InvalidManifest;
    if (host_hex.len != 32 or !isLowerHex(host_hex)) return error.InvalidManifest;
    const host_id = std.fmt.parseInt(u128, host_hex, 16) catch return error.InvalidManifest;
    const build_id = stringField(obj, "build_id") orelse return error.InvalidManifest;
    const protocol_major = std.math.cast(u16, intField(obj, "protocol_major") orelse return error.InvalidManifest) orelse
        return error.InvalidManifest;
    const screen_codec_version = std.math.cast(u16, intField(obj, "screen_codec_version") orelse return error.InvalidManifest) orelse
        return error.InvalidManifest;
    const upgrade_epoch = std.math.cast(u64, intField(obj, "upgrade_epoch") orelse return error.InvalidManifest) orelse
        return error.InvalidManifest;
    const lifecycle_raw = stringField(obj, "lifecycle") orelse return error.InvalidManifest;
    const lifecycle = std.meta.stringToEnum(Lifecycle, lifecycle_raw) orelse return error.InvalidManifest;
    const endpoint = stringField(obj, "endpoint") orelse return error.InvalidManifest;
    const descriptor: Descriptor = .{
        .host_id = host_id,
        .build_id = build_id,
        .protocol_major = protocol_major,
        .screen_codec_version = screen_codec_version,
        .upgrade_epoch = upgrade_epoch,
        .lifecycle = lifecycle,
        .endpoint = endpoint,
    };
    try validateDescriptorShape(descriptor);
    const owned_build = allocator.dupe(u8, build_id) catch return error.OutOfMemory;
    errdefer allocator.free(owned_build);
    const owned_endpoint = allocator.dupe(u8, endpoint) catch return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .host_id = host_id,
        .build_id = owned_build,
        .protocol_major = protocol_major,
        .screen_codec_version = screen_codec_version,
        .upgrade_epoch = upgrade_epoch,
        .lifecycle = lifecycle,
        .endpoint = owned_endpoint,
    };
}

fn writeAtomic(
    allocator: std.mem.Allocator,
    host_dir: [:0]const u8,
    manifest_path: [:0]const u8,
    descriptor: Descriptor,
    replace: bool,
) Error!Published.FileIdentity {
    try validateOwnerDir(host_dir);
    const bytes = try encode(allocator, descriptor);
    defer allocator.free(bytes);
    const tmp_path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.host.v1.json.tmp-{d}",
        .{ host_dir, c.getpid() },
        0,
    ) catch return error.OutOfMemory;
    defer allocator.free(tmp_path);
    _ = c.unlink(tmp_path.ptr);
    const fd = c.open(
        tmp_path.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true },
        @as(c.mode_t, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    var open = true;
    defer {
        if (open) _ = c.close(fd);
    }
    errdefer _ = c.unlink(tmp_path.ptr);
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.SyncFailed;
    _ = c.close(fd);
    open = false;
    if (renamex_np(
        tmp_path.ptr,
        manifest_path.ptr,
        if (replace) RENAME_SWAP else RENAME_EXCL,
    ) != 0) return error.RenameFailed;
    const dir_fd = try openOwnerDir(host_dir);
    defer _ = c.close(dir_fd);
    if (c.fsync(dir_fd) != 0) {
        if (replace) {
            // SWAP 뒤 tmp가 old manifest를 보유한다. Commit fsync가 실패하면 다시 swap해 old authority를 복원한다.
            _ = renamex_np(tmp_path.ptr, manifest_path.ptr, RENAME_SWAP);
        } else {
            _ = c.unlink(manifest_path.ptr);
        }
        _ = c.fsync(dir_fd);
        return error.SyncFailed;
    }
    if (replace) {
        // 첫 directory fsync가 new manifest 이름을 durable하게 만들었다. tmp에 남은 old generation은 이제 회수 가능하다.
        _ = c.unlink(tmp_path.ptr);
        _ = c.fsync(dir_fd);
    }
    return fileIdentity(manifest_path);
}

fn fileIdentity(path: [:0]const u8) Error!Published.FileIdentity {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        (stat.mode & 0o777) != 0o600)
        return error.InvalidManifest;
    return .{ .dev = stat.dev, .ino = stat.ino };
}

fn sameIdentity(a: Published.FileIdentity, b: Published.FileIdentity) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

fn ensureOwnerDir(path: [:0]const u8) Error!void {
    const rc = c.mkdir(path.ptr, 0o700);
    if (rc != 0 and posix.errno(rc) != .EXIST) return error.InvalidDirectory;
    try validateOwnerDir(path);
}

fn validateOwnerDir(path: [:0]const u8) Error!void {
    var stat: posix.Stat = undefined;
    const rc = c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW);
    if (rc != 0) {
        if (posix.errno(rc) == .NOENT) return error.ManifestNotFound;
        return error.InvalidDirectory;
    }
    if (!posix.S.ISDIR(stat.mode) or stat.uid != c.getuid() or stat.mode & 0o077 != 0)
        return error.InvalidDirectory;
}

fn openOwnerDir(path: [:0]const u8) Error!c.fd_t {
    try validateOwnerDir(path);
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.InvalidDirectory;
    return fd;
}

fn validateDescriptor(descriptor: Descriptor, session_dir: []const u8) Error!void {
    _ = session_dir;
    try validateDescriptorShape(descriptor);
    short_endpoint.validateCurrentSocketPath(descriptor.endpoint, descriptor.host_id) catch
        return error.InvalidManifest;
}

fn validateDescriptorShape(descriptor: Descriptor) Error!void {
    if (descriptor.host_id == 0 or descriptor.protocol_major == 0 or descriptor.screen_codec_version == 0 or
        descriptor.endpoint.len == 0 or descriptor.endpoint.len > max_endpoint_bytes or descriptor.endpoint[0] != '/' or
        std.mem.indexOfScalar(u8, descriptor.endpoint, 0) != null)
        return error.InvalidManifest;
    if (descriptor.build_id.len != 71 or !std.mem.startsWith(u8, descriptor.build_id, "sha256:") or
        !isLowerHex(descriptor.build_id["sha256:".len..]))
        return error.InvalidManifest;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        if (rc == 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    return switch (obj.get(name) orelse return null) {
        .integer => |value| value,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn isLowerHex(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn mapMissingDirectory(err: Error) Error {
    return switch (err) {
        error.ManifestNotFound => error.ManifestNotFound,
        else => err,
    };
}

fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

test "host manifest codec preserves exact discovery authority and rejects non-exact identities" {
    const allocator = std.testing.allocator;
    const descriptor: Descriptor = .{
        .host_id = 0xAABB,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 7,
        .lifecycle = .draining,
        .endpoint = "/tmp/maru-0/sh/0000000000000000000000000000aabb.sock",
    };
    const bytes = try encode(allocator, descriptor);
    defer allocator.free(bytes);
    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(descriptor.host_id, decoded.host_id);
    try std.testing.expectEqualStrings(descriptor.build_id, decoded.build_id);
    try std.testing.expectEqual(descriptor.protocol_major, decoded.protocol_major);
    try std.testing.expectEqual(descriptor.screen_codec_version, decoded.screen_codec_version);
    try std.testing.expectEqual(descriptor.upgrade_epoch, decoded.upgrade_epoch);
    try std.testing.expectEqual(descriptor.lifecycle, decoded.lifecycle);
    try std.testing.expectEqualStrings(descriptor.endpoint, decoded.endpoint);

    try std.testing.expectError(error.InvalidManifest, decode(
        allocator,
        "{\"schema\":1,\"host_id\":\"0000000000000000000000000000AABB\",\"build_id\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"protocol_major\":2,\"screen_codec_version\":2,\"upgrade_epoch\":7,\"lifecycle\":\"ready\",\"endpoint\":\"/tmp/x\"}",
    ));
}

test "host manifest publish-load is atomic owner-only and exact-host keyed" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-host-manifest-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    const descriptor: Descriptor = .{
        .host_id = 0xCAFE,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/maru-host-manifest-placeholder/control-v2.sock",
    };
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, descriptor.host_id);
    var exact = descriptor;
    exact.endpoint = endpoint;
    var published = try publish(std.testing.allocator, dir, exact);
    defer published.deinit();

    var loaded = try load(std.testing.allocator, dir, exact.host_id);
    defer loaded.deinit();
    try std.testing.expectEqual(exact.host_id, loaded.host_id);
    try std.testing.expectEqualStrings(endpoint, loaded.endpoint);
    try std.testing.expectError(error.ManifestNotFound, load(std.testing.allocator, dir, 0xDEAD));

    exact.upgrade_epoch = 2;
    exact.lifecycle = .restoring;
    try published.republish(exact);
    var updated = try load(std.testing.allocator, dir, exact.host_id);
    defer updated.deinit();
    try std.testing.expectEqual(@as(u64, 2), updated.upgrade_epoch);
    try std.testing.expectEqual(Lifecycle.restoring, updated.lifecycle);
}

test "host manifest initial publish is exclusive and old owner cleanup cannot unlink a replacement generation" {
    var dir_buf: [192]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, "/tmp/maru-host-manifest-aba-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    defer _ = c.rmdir(dir.ptr);
    const host_id: u128 = 0xBEEF;
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);
    const first_descriptor: Descriptor = .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = endpoint,
    };
    var first = try publish(std.testing.allocator, dir, first_descriptor);
    try std.testing.expectError(error.RenameFailed, publish(std.testing.allocator, dir, first_descriptor));

    var manifest_buf: [832]u8 = undefined;
    const manifest_path = try manifestPathIn(&manifest_buf, dir, host_id);
    try std.testing.expect(c.unlink(manifest_path.ptr) == 0);
    var replacement_descriptor = first_descriptor;
    replacement_descriptor.upgrade_epoch = 2;
    var replacement = try publish(std.testing.allocator, dir, replacement_descriptor);
    defer replacement.deinit();

    first.deinit();
    var loaded = try load(std.testing.allocator, dir, host_id);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 2), loaded.upgrade_epoch);
}
