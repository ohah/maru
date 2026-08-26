//! 실행 중 session host를 `host_id`로 찾는 exact discovery manifest(U4).
//!
//! Workspace는 `{host_id,runtime_id}`만 저장한다. endpoint/protocol/build를 workspace에 복제하지 않고 이 owner-only
//! registry가 단일 출처로 소유한다. 파일은 `<session-dir>/hosts/<host-id>/host.v1.json`에 0600으로 원자 publish되며,
//! reader는 모든 부모 디렉터리와 leaf를 no-follow/same-UID로 확인한 뒤 bounded JSON을 파싱한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
// Zig 0.16은 Linux `stat` ABI를 공개하지 않는다. Linux는 `statx`로 같은 필드를 얻고 macOS는
// 기존 libc stat을 사용해 owner 검증의 의미를 한 projection으로 유지한다.
const StatInfo = struct {
    dev: posix.dev_t,
    ino: posix.ino_t,
    mode: c.mode_t,
    uid: c.uid_t,
    size: u64,
    ctime_ns: i128,
};
const staged_image = @import("staged_image.zig");
const host_identity = @import("host_identity.zig");
const short_endpoint = @import("short_endpoint.zig");
const test_scratch = @import("test_scratch.zig");

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
const RENAME_SWAP: c_uint = 0x00000002;
const RENAME_EXCL: c_uint = 0x00000004;
var temp_sequence: std.atomic.Value(u64) = .init(1);
const TestFailpoint = enum { none, before_commit_sync, rollback_sync, post_commit_cleanup };
var test_failpoint: TestFailpoint = .none;

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
    /// Disk authority가 old/new 중 어느 세대인지 안전하게 증명할 수 없다. Caller는 wire를 계속 서비스하지 말고 fail-stop한다.
    AuthorityPoisoned,
    OutOfMemory,
};

pub const Published = struct {
    const FileIdentity = struct {
        dev: posix.dev_t,
        ino: posix.ino_t,
        ctime_ns: i128,
    };

    allocator: std.mem.Allocator,
    hosts_root: [:0]u8,
    host_dir: [:0]u8,
    manifest_path: [:0]u8,
    identity: FileIdentity,
    poisoned: bool = false,

    pub const WithdrawOutcome = enum { removed, replaced, absent };

    pub fn deinit(self: *Published) void {
        _ = self.withdraw() catch {};
        self.deinitMemory();
    }

    /// 경로가 다른 세대로 교체됐으면 그 세대를 삭제하지 않는다. rename-to-tomb 뒤 inode를 확인하므로
    /// precheck→unlink 사이의 내부 ABA에도 unknown generation을 unlink하지 않는다.
    pub fn withdraw(self: *Published) Error!WithdrawOutcome {
        if (self.poisoned) return error.AuthorityPoisoned;
        const dir_fd = try openOwnerDir(self.host_dir);
        defer _ = c.close(dir_fd);
        return withdrawExact(self.allocator, dir_fd, self.manifest_path, self.identity);
    }

    pub fn deinitMemory(self: *Published) void {
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.host_dir);
        self.allocator.free(self.hosts_root);
        self.* = undefined;
    }

    pub fn republish(self: *Published, descriptor: Descriptor) Error!void {
        if (self.poisoned) return error.AuthorityPoisoned;
        if (descriptor.host_id == 0) return error.InvalidManifest;
        var expected_dir_buf: [768]u8 = undefined;
        const parent = std.fs.path.dirname(self.host_dir) orelse return error.InvalidDirectory;
        const session_dir = std.fs.path.dirname(parent) orelse return error.InvalidDirectory;
        const expected = hostDirPathIn(&expected_dir_buf, session_dir, descriptor.host_id) catch
            return error.InvalidDirectory;
        if (!std.mem.eql(u8, expected, self.host_dir)) return error.InvalidManifest;
        try validateDescriptor(descriptor, session_dir);
        self.identity = writeAtomic(self.allocator, self.host_dir, self.manifest_path, descriptor, self.identity) catch |err| {
            if (err == error.AuthorityPoisoned) self.poisoned = true;
            // rollback rename도 ctime을 바꾸므로, durable old generation으로 복귀한 SyncFailed만
            // pathname을 다시 읽어 기존 owner의 exact identity를 갱신한다.
            if (err == error.SyncFailed) {
                self.identity = fileIdentity(self.manifest_path) catch {
                    self.poisoned = true;
                    return error.AuthorityPoisoned;
                };
            }
            return err;
        };
    }

    /// tmp cleaner 방지용 시각 갱신도 pathname owner 전환이다. 현재 exact identity를 먼저 확인하고,
    /// 같은 inode의 새 ctime만 다시 채택해 외부 replacement를 정상 owner로 승격하지 않는다.
    pub fn touchExact(self: *Published) Error!void {
        if (self.poisoned) return error.AuthorityPoisoned;
        const fd = c.open(
            self.manifest_path.ptr,
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true },
            @as(c.mode_t, 0),
        );
        if (fd < 0) return error.InvalidManifest;
        defer _ = c.close(fd);
        const before = try fileIdentityFd(fd);
        if (!sameIdentity(before, self.identity)) return error.InvalidManifest;
        if (c.futimens(fd, null) != 0)
            return error.InvalidManifest;
        const after = try fileIdentityFd(fd);
        const path_after = fileIdentity(self.manifest_path) catch {
            self.poisoned = true;
            return error.AuthorityPoisoned;
        };
        if (!sameInode(after, before) or !sameIdentity(path_after, after)) {
            self.poisoned = true;
            return error.AuthorityPoisoned;
        }
        self.identity = path_after;
    }
};

const LoadedExact = struct {
    manifest: Manifest,
    identity: Published.FileIdentity,
};

/// Existing `restoring` manifest를 pathname 재생성 없이 exact generation으로
/// 채택하기 전의 rollback-safe token. `discard`는 메모리만 해제하고 disk
/// manifest를 유지해 rollback image가 같은 authority를 이어받을 수 있다.
pub const PreparedAdoption = struct {
    pub const State = enum { prepared, validated, active, dead };

    publication: Published,
    manifest: Manifest,
    state: State = .prepared,

    pub fn descriptor(self: *const PreparedAdoption) Error!Descriptor {
        if (self.state != .prepared and self.state != .validated)
            return error.InvalidManifest;
        return self.manifest.descriptor();
    }

    pub fn revalidate(self: *PreparedAdoption, session_dir: [:0]const u8) Error!void {
        if (self.state != .prepared) return error.InvalidManifest;
        var actual = try loadExact(
            self.manifest.allocator,
            session_dir,
            self.manifest.host_id,
        );
        defer actual.manifest.deinit();
        if (!sameIdentity(actual.identity, self.publication.identity) or
            !sameDescriptor(actual.manifest.descriptor(), self.manifest.descriptor()))
            return error.InvalidManifest;
        self.state = .validated;
    }

    /// Restore activation의 단일 durable frontier. 기존 exact `restoring`
    /// generation을 마지막으로 재검증한 token만 ready descriptor로
    /// republish하고, 성공한 경우에만 destructive lifetime owner가 된다.
    pub fn commitReadyPublication(
        self: *PreparedAdoption,
        ready_descriptor: Descriptor,
    ) Error!*Published {
        if (self.state != .validated or ready_descriptor.lifecycle != .ready or
            ready_descriptor.host_id != self.manifest.host_id or
            !std.mem.eql(u8, ready_descriptor.endpoint, self.manifest.endpoint))
            return error.InvalidManifest;
        const epoch_ok = ready_descriptor.upgrade_epoch == self.manifest.upgrade_epoch or
            (self.manifest.upgrade_epoch != std.math.maxInt(u64) and
                ready_descriptor.upgrade_epoch == self.manifest.upgrade_epoch + 1);
        if (!epoch_ok) return error.InvalidManifest;
        // Same-epoch publication is rollback recovery, not a new generation.
        // It must preserve the exact executable/wire identity recorded by the
        // restoring manifest; only a target commit may advance that identity.
        if (ready_descriptor.upgrade_epoch == self.manifest.upgrade_epoch and
            (!std.mem.eql(u8, ready_descriptor.build_id, self.manifest.build_id) or
                ready_descriptor.protocol_major != self.manifest.protocol_major or
                ready_descriptor.screen_codec_version != self.manifest.screen_codec_version))
            return error.InvalidManifest;
        try self.publication.republish(ready_descriptor);
        self.state = .active;
        return &self.publication;
    }

    pub fn discard(self: *PreparedAdoption) void {
        if (self.state != .prepared and self.state != .validated) return;
        self.publication.deinitMemory();
        self.manifest.deinit();
        self.state = .dead;
    }

    pub fn deinit(self: *PreparedAdoption) void {
        switch (self.state) {
            .prepared, .validated => {
                self.publication.deinitMemory();
                self.manifest.deinit();
            },
            .active => {
                self.publication.deinit();
                self.manifest.deinit();
            },
            .dead => return,
        }
        self.state = .dead;
    }
};

/// `HostAuthority`가 embedded `Published` 주소를 장기간 borrow하므로 restore
/// adoption은 heap에 pin한다. Wrapper 이동은 pointee 주소를 바꾸지 않는다.
pub const PinnedAdoption = struct {
    allocator: std.mem.Allocator,
    value: *PreparedAdoption,

    pub fn get(self: *PinnedAdoption) *PreparedAdoption {
        return self.value;
    }

    pub fn deinit(self: *PinnedAdoption) void {
        self.value.deinit();
        self.allocator.destroy(self.value);
        self.* = undefined;
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

/// Manifest와 owner.lock이 철거되고 socket server가 닫힌 뒤 daemon이 빈 host registry directory를 회수한다.
/// ENOTEMPTY는 다른 generation/residue가 있다는 뜻이므로 삭제를 강행하지 않는다.
pub fn removeEmptyHostDirectories(session_dir: [:0]const u8, host_id: u128) void {
    var host_buf: [768]u8 = undefined;
    const host_dir = hostDirPathIn(&host_buf, session_dir, host_id) catch return;
    _ = c.rmdir(host_dir.ptr);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return;
    _ = c.rmdir(hosts_root.ptr);
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

    const owned_hosts_root = allocator.dupeZ(u8, hosts_root) catch return error.OutOfMemory;
    errdefer allocator.free(owned_hosts_root);
    const owned_host_dir = allocator.dupeZ(u8, host_dir) catch return error.OutOfMemory;
    errdefer allocator.free(owned_host_dir);
    const owned_manifest = allocator.dupeZ(u8, manifest_path) catch return error.OutOfMemory;
    errdefer allocator.free(owned_manifest);
    const identity = try writeAtomic(allocator, host_dir, manifest_path, descriptor, null);
    return .{
        .allocator = allocator,
        .hosts_root = owned_hosts_root,
        .host_dir = owned_host_dir,
        .manifest_path = owned_manifest,
        .identity = identity,
    };
}

pub fn prepareAdoptRestoring(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
    upgrade_epoch: u64,
    endpoint: []const u8,
) Error!PreparedAdoption {
    var loaded = try loadExact(allocator, session_dir, host_id);
    errdefer loaded.manifest.deinit();
    if (loaded.manifest.lifecycle != .restoring or
        loaded.manifest.upgrade_epoch != upgrade_epoch or
        !std.mem.eql(u8, loaded.manifest.endpoint, endpoint))
        return error.InvalidManifest;

    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return error.InvalidDirectory;
    var host_buf: [768]u8 = undefined;
    const host_dir = hostDirPathIn(&host_buf, session_dir, host_id) catch return error.InvalidDirectory;
    var manifest_buf: [832]u8 = undefined;
    const manifest_path = manifestPathIn(&manifest_buf, session_dir, host_id) catch
        return error.InvalidDirectory;
    const owned_hosts_root = allocator.dupeZ(u8, hosts_root) catch return error.OutOfMemory;
    errdefer allocator.free(owned_hosts_root);
    const owned_host_dir = allocator.dupeZ(u8, host_dir) catch return error.OutOfMemory;
    errdefer allocator.free(owned_host_dir);
    const owned_manifest = allocator.dupeZ(u8, manifest_path) catch return error.OutOfMemory;
    return .{
        .publication = .{
            .allocator = allocator,
            .hosts_root = owned_hosts_root,
            .host_dir = owned_host_dir,
            .manifest_path = owned_manifest,
            .identity = loaded.identity,
        },
        .manifest = loaded.manifest,
    };
}

pub fn prepareAdoptRestoringPinned(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
    expected_epoch: u64,
    expected_endpoint: []const u8,
) Error!PinnedAdoption {
    const value = allocator.create(PreparedAdoption) catch
        return error.OutOfMemory;
    errdefer allocator.destroy(value);
    value.* = try prepareAdoptRestoring(
        allocator,
        session_dir,
        host_id,
        expected_epoch,
        expected_endpoint,
    );
    return .{ .allocator = allocator, .value = value };
}

pub fn load(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
) Error!Manifest {
    return (try loadExact(allocator, session_dir, host_id)).manifest;
}

/// Recovery 열거가 빈 registry도 안전하게 판정할 수 있게 root 자체를 검증한다.
/// 개별 manifest load와 같은 owner/mode/no-symlink 규칙을 쓰며 파일을 만들거나 고치지 않는다.
pub fn validateRegistryRoot(session_dir: [:0]const u8) Error!void {
    try validateOwnerDir(session_dir);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = hostsRootPathIn(&hosts_buf, session_dir) catch return error.InvalidDirectory;
    try validateOwnerDir(hosts_root);
}

fn loadExact(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
) Error!LoadedExact {
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
    var stat: StatInfo = undefined;
    if (statFd(fd, &stat) != .SUCCESS or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
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
    return .{
        .manifest = manifest,
        .identity = identityFromStat(stat),
    };
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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidManifest,
    };
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
    expected_old: ?Published.FileIdentity,
) Error!Published.FileIdentity {
    try validateOwnerDir(host_dir);
    const dir_fd = try openOwnerDir(host_dir);
    defer _ = c.close(dir_fd);
    const bytes = try encode(allocator, descriptor);
    defer allocator.free(bytes);
    const nonce = temp_sequence.fetchAdd(1, .monotonic);
    const tmp_path = std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.host.v1.json.tmp-{d}-{x}",
        .{ host_dir, c.getpid(), nonce },
        0,
    ) catch return error.OutOfMemory;
    defer allocator.free(tmp_path);
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
    try writeAll(fd, bytes);
    if (c.fsync(fd) != 0) return error.SyncFailed;
    const new_identity = try fileIdentityFd(fd);
    var tmp_holds_new = true;
    defer if (tmp_holds_new) unlinkIfIdentity(tmp_path, new_identity);
    _ = c.close(fd);
    open = false;
    if (expected_old) |old_identity| {
        const current = fileIdentity(manifest_path) catch return error.InvalidManifest;
        if (!sameIdentity(current, old_identity)) return error.InvalidManifest;
    }
    const renamed = if (expected_old != null)
        renameExchange(tmp_path, manifest_path)
    else
        renameNoReplace(tmp_path, manifest_path);
    if (!renamed) return error.RenameFailed;
    tmp_holds_new = false;

    if (expected_old) |old_identity| {
        const displaced = fileIdentity(tmp_path) catch {
            try rollbackSwapTracked(dir_fd, tmp_path, manifest_path, new_identity, &tmp_holds_new);
            return error.InvalidManifest;
        };
        const installed = fileIdentity(manifest_path) catch {
            try rollbackSwapTracked(dir_fd, tmp_path, manifest_path, new_identity, &tmp_holds_new);
            return error.AuthorityPoisoned;
        };
        if (!sameInode(displaced, old_identity) or !sameInode(installed, new_identity)) {
            try rollbackSwapTracked(dir_fd, tmp_path, manifest_path, new_identity, &tmp_holds_new);
            return error.InvalidManifest;
        }
    } else {
        const installed = fileIdentity(manifest_path) catch return error.AuthorityPoisoned;
        if (!sameInode(installed, new_identity)) return error.AuthorityPoisoned;
    }

    if ((builtin.is_test and (test_failpoint == .before_commit_sync or test_failpoint == .rollback_sync)) or
        c.fsync(dir_fd) != 0)
    {
        if (expected_old != null) {
            try rollbackSwapTracked(dir_fd, tmp_path, manifest_path, new_identity, &tmp_holds_new);
        } else {
            if (!renameNoReplace(manifest_path, tmp_path))
                return error.AuthorityPoisoned;
            tmp_holds_new = true;
            if (c.fsync(dir_fd) != 0) return error.AuthorityPoisoned;
        }
        return error.SyncFailed;
    }

    const committed_identity = fileIdentity(manifest_path) catch return error.AuthorityPoisoned;
    if (!sameInode(committed_identity, new_identity)) return error.AuthorityPoisoned;
    if (expected_old) |old_identity| {
        // 여기부터 new generation은 durable commit됐다. old temp 회수 실패는 authority 실패가 아니라 bounded residue다.
        if (builtin.is_test and test_failpoint == .post_commit_cleanup) {
            unlinkIfInode(tmp_path, old_identity);
            return committed_identity;
        }
        unlinkIfInode(tmp_path, old_identity);
        _ = c.fsync(dir_fd);
    }
    return committed_identity;
}

fn fileIdentity(path: [:0]const u8) Error!Published.FileIdentity {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    return fileIdentityFd(fd);
}

fn fileIdentityFd(fd: c.fd_t) Error!Published.FileIdentity {
    var stat: StatInfo = undefined;
    if (statFd(fd, &stat) != .SUCCESS or !posix.S.ISREG(stat.mode) or stat.uid != c.getuid() or
        (stat.mode & 0o777) != 0o600)
        return error.InvalidManifest;
    return identityFromStat(stat);
}

fn sameIdentity(a: Published.FileIdentity, b: Published.FileIdentity) bool {
    return sameInode(a, b) and a.ctime_ns == b.ctime_ns;
}

fn sameInode(a: Published.FileIdentity, b: Published.FileIdentity) bool {
    return a.dev == b.dev and a.ino == b.ino;
}

fn identityFromStat(stat: StatInfo) Published.FileIdentity {
    return .{ .dev = stat.dev, .ino = stat.ino, .ctime_ns = stat.ctime_ns };
}

fn rollbackSwapOrPoison(
    dir_fd: c.fd_t,
    tmp_path: [:0]const u8,
    manifest_path: [:0]const u8,
) Error!void {
    if (!renameExchange(tmp_path, manifest_path)) return error.AuthorityPoisoned;
    if (builtin.is_test and test_failpoint == .rollback_sync) return error.AuthorityPoisoned;
    if (c.fsync(dir_fd) != 0) return error.AuthorityPoisoned;
}

fn rollbackSwapTracked(
    dir_fd: c.fd_t,
    tmp_path: [:0]const u8,
    manifest_path: [:0]const u8,
    new_identity: Published.FileIdentity,
    tmp_holds_new: *bool,
) Error!void {
    rollbackSwapOrPoison(dir_fd, tmp_path, manifest_path) catch |err| {
        if (fileIdentity(tmp_path)) |identity| {
            tmp_holds_new.* = sameInode(identity, new_identity);
        } else |_| {}
        return err;
    };
    tmp_holds_new.* = true;
}

fn unlinkIfIdentity(path: [:0]const u8, identity: Published.FileIdentity) void {
    const current = fileIdentity(path) catch return;
    if (sameIdentity(current, identity)) _ = c.unlink(path.ptr);
}

fn unlinkIfInode(path: [:0]const u8, identity: Published.FileIdentity) void {
    const current = fileIdentity(path) catch return;
    if (sameInode(current, identity)) _ = c.unlink(path.ptr);
}

fn withdrawExact(
    allocator: std.mem.Allocator,
    dir_fd: c.fd_t,
    path: [:0]const u8,
    expected: Published.FileIdentity,
) Error!Published.WithdrawOutcome {
    const current = fileIdentity(path) catch |err| return switch (err) {
        error.OpenFailed => .absent,
        else => err,
    };
    if (!sameIdentity(current, expected)) return .replaced;

    const tomb = std.fmt.allocPrintSentinel(
        allocator,
        "{s}.withdraw-{d}-{x}",
        .{ path, c.getpid(), temp_sequence.fetchAdd(1, .monotonic) },
        0,
    ) catch return error.OutOfMemory;
    defer allocator.free(tomb);
    if (!renameNoReplace(path, tomb)) return error.RenameFailed;
    const moved = fileIdentity(tomb) catch return error.AuthorityPoisoned;
    if (!sameInode(moved, expected)) {
        if (!renameNoReplace(tomb, path)) return error.AuthorityPoisoned;
        if (c.fsync(dir_fd) != 0) return error.AuthorityPoisoned;
        return .replaced;
    }
    if (c.unlink(tomb.ptr) != 0) return error.AuthorityPoisoned;
    if (c.fsync(dir_fd) != 0) return error.AuthorityPoisoned;
    return .removed;
}

fn ensureOwnerDir(path: [:0]const u8) Error!void {
    const rc = c.mkdir(path.ptr, 0o700);
    if (rc != 0 and posix.errno(rc) != .EXIST) return error.InvalidDirectory;
    try validateOwnerDir(path);
}

fn validateOwnerDir(path: [:0]const u8) Error!void {
    var stat: StatInfo = undefined;
    const stat_errno = statAtNoFollow(posix.AT.FDCWD, path, &stat);
    if (stat_errno != .SUCCESS) {
        if (stat_errno == .NOENT) return error.ManifestNotFound;
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

fn statFd(fd: c.fd_t, out: *StatInfo) posix.E {
    if (builtin.os.tag == .linux) {
        var stat: std.os.linux.Statx = undefined;
        const rc = c.statx(fd, "", posix.AT.EMPTY_PATH | posix.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stat);
        const err = posix.errno(rc);
        if (err != .SUCCESS) return err;
        out.* = statInfoFromLinux(stat);
        return .SUCCESS;
    }
    var stat: posix.Stat = undefined;
    const err = posix.errno(c.fstat(fd, &stat));
    if (err != .SUCCESS) return err;
    const ctime = stat.ctime();
    out.* = .{
        .dev = stat.dev,
        .ino = stat.ino,
        .mode = stat.mode,
        .uid = stat.uid,
        .size = @intCast(stat.size),
        .ctime_ns = @as(i128, ctime.sec) * std.time.ns_per_s + ctime.nsec,
    };
    return .SUCCESS;
}

fn renameNoReplace(from: [:0]const u8, to: [:0]const u8) bool {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.renameat2(posix.AT.FDCWD, from.ptr, posix.AT.FDCWD, to.ptr, .{ .NOREPLACE = true });
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    return renamex_np(from.ptr, to.ptr, RENAME_EXCL) == 0;
}

fn renameExchange(from: [:0]const u8, to: [:0]const u8) bool {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.renameat2(posix.AT.FDCWD, from.ptr, posix.AT.FDCWD, to.ptr, .{ .EXCHANGE = true });
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    return renamex_np(from.ptr, to.ptr, RENAME_SWAP) == 0;
}

fn statAtNoFollow(dir_fd: c.fd_t, path: [:0]const u8, out: *StatInfo) posix.E {
    if (builtin.os.tag == .linux) {
        var stat: std.os.linux.Statx = undefined;
        const rc = c.statx(dir_fd, path.ptr, posix.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stat);
        const err = posix.errno(rc);
        if (err != .SUCCESS) return err;
        out.* = statInfoFromLinux(stat);
        return .SUCCESS;
    }
    var stat: posix.Stat = undefined;
    const err = posix.errno(c.fstatat(dir_fd, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW));
    if (err != .SUCCESS) return err;
    const ctime = stat.ctime();
    out.* = .{
        .dev = stat.dev,
        .ino = stat.ino,
        .mode = stat.mode,
        .uid = stat.uid,
        .size = @intCast(stat.size),
        .ctime_ns = @as(i128, ctime.sec) * std.time.ns_per_s + ctime.nsec,
    };
    return .SUCCESS;
}

fn statInfoFromLinux(stat: std.os.linux.Statx) StatInfo {
    const dev = (@as(u64, stat.dev_major) << 32) | stat.dev_minor;
    return .{
        .dev = @intCast(dev),
        .ino = @intCast(stat.ino),
        .mode = @intCast(stat.mode),
        .uid = stat.uid,
        .size = stat.size,
        .ctime_ns = @as(i128, stat.ctime.sec) * std.time.ns_per_s + stat.ctime.nsec,
    };
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

fn sameDescriptor(a: Descriptor, b: Descriptor) bool {
    return a.host_id == b.host_id and
        a.protocol_major == b.protocol_major and
        a.screen_codec_version == b.screen_codec_version and
        a.upgrade_epoch == b.upgrade_epoch and
        a.lifecycle == b.lifecycle and
        std.mem.eql(u8, a.build_id, b.build_id) and
        std.mem.eql(u8, a.endpoint, b.endpoint);
}

pub fn descriptorEql(a: Descriptor, b: Descriptor) bool {
    return sameDescriptor(a, b);
}

/// descriptor 가 어긋난 **축**. `sameDescriptor` 와 완전히 같은 순서·같은 조건이며, 판정에는 관여하지 않는다.
///
/// 왜 나눠 두는가. 불일치는 전부 `stale_manifest` 한 값으로 접혀 나가는데, 그 값에 도달하는 축이 일곱이다.
/// 2026-08-27 실측에서 exec upgrade 가 `reason=stale_manifest` 로 실패해 **같은 build_id host 가 둘** 남았고
/// (구 host 가 PTY 6 개를 전부 쥔 채, 새 host 는 빈 껍데기로), 그 한 단어만으로는 `build_id` 인지
/// `lifecycle` 인지 `upgrade_epoch` 인지 좁힐 수 없었다. 축을 남기면 다음 재발이 곧 원인이다.
pub const DescriptorAxis = enum {
    host_id,
    protocol_major,
    screen_codec_version,
    upgrade_epoch,
    lifecycle,
    build_id,
    endpoint,
};

pub fn firstDescriptorMismatch(a: Descriptor, b: Descriptor) ?DescriptorAxis {
    if (a.host_id != b.host_id) return .host_id;
    if (a.protocol_major != b.protocol_major) return .protocol_major;
    if (a.screen_codec_version != b.screen_codec_version) return .screen_codec_version;
    if (a.upgrade_epoch != b.upgrade_epoch) return .upgrade_epoch;
    if (a.lifecycle != b.lifecycle) return .lifecycle;
    if (!std.mem.eql(u8, a.build_id, b.build_id)) return .build_id;
    if (!std.mem.eql(u8, a.endpoint, b.endpoint)) return .endpoint;
    return null;
}

test "firstDescriptorMismatch 는 sameDescriptor 와 같은 판정을 축으로 되돌려 준다" {
    const base = Descriptor{
        .host_id = 0xAABB,
        .build_id = "b1",
        .protocol_major = 2,
        .screen_codec_version = 3,
        .upgrade_epoch = 7,
        .lifecycle = .ready,
        .endpoint = "/tmp/x.sock",
    };
    try std.testing.expect(firstDescriptorMismatch(base, base) == null);
    try std.testing.expect(sameDescriptor(base, base));

    var other = base;
    other.build_id = "b2";
    try std.testing.expectEqual(DescriptorAxis.build_id, firstDescriptorMismatch(base, other).?);
    try std.testing.expect(!sameDescriptor(base, other));

    var life = base;
    life.lifecycle = .restoring;
    try std.testing.expectEqual(DescriptorAxis.lifecycle, firstDescriptorMismatch(base, life).?);

    var epoch = base;
    epoch.upgrade_epoch = 8;
    try std.testing.expectEqual(DescriptorAxis.upgrade_epoch, firstDescriptorMismatch(base, epoch).?);
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
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "host-manifest");
    defer test_scratch.close(std.testing.io, dir);
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

    // 제품의 주기적 보존 touch가 exact owner ctime을 갱신한 뒤에도 같은 권위가 다음 generation을 게시한다.
    try published.touchExact();
    exact.upgrade_epoch = 2;
    exact.lifecycle = .restoring;
    try published.republish(exact);
    var updated = try load(std.testing.allocator, dir, exact.host_id);
    defer updated.deinit();
    try std.testing.expectEqual(@as(u64, 2), updated.upgrade_epoch);
    try std.testing.expectEqual(Lifecycle.restoring, updated.lifecycle);
}

test "host manifest restoring adoption discard preserves disk and commit transfers exact cleanup authority" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "host-manifest-adopt");
    defer test_scratch.close(std.testing.io, dir);
    const host_id: u128 = 0xAD07;
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);
    const descriptor: Descriptor = .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 4,
        .lifecycle = .restoring,
        .endpoint = endpoint,
    };
    var published = try publish(std.testing.allocator, dir, descriptor);

    var replaced = try prepareAdoptRestoring(
        std.testing.allocator,
        dir,
        host_id,
        descriptor.upgrade_epoch,
        endpoint,
    );
    // Descriptor bytes가 같아도 atomic republish가 만든 새 inode는 다른
    // authority generation이다. Prepared token이 이를 채택하면 old cleanup
    // handle과 새 manifest가 섞이므로 exact identity로 거부한다.
    try published.republish(descriptor);
    try std.testing.expectError(error.InvalidManifest, replaced.revalidate(dir));
    replaced.discard();

    var discarded = try prepareAdoptRestoring(
        std.testing.allocator,
        dir,
        host_id,
        descriptor.upgrade_epoch,
        endpoint,
    );
    discarded.discard();
    var still_present = try load(std.testing.allocator, dir, host_id);
    still_present.deinit();

    var prepared = try prepareAdoptRestoringPinned(
        std.testing.allocator,
        dir,
        host_id,
        descriptor.upgrade_epoch,
        endpoint,
    );
    try prepared.get().revalidate(dir);
    // Same-PID exec loses the old Published value without withdrawing disk.
    // Mirror that ownership move explicitly in the process-local test.
    published.deinitMemory();
    defer prepared.deinit();
    var ready_descriptor = descriptor;
    ready_descriptor.lifecycle = .ready;
    var invalid_rollback = ready_descriptor;
    invalid_rollback.protocol_major += 1;
    try std.testing.expectError(
        error.InvalidManifest,
        prepared.get().commitReadyPublication(invalid_rollback),
    );
    ready_descriptor.upgrade_epoch += 1;
    _ = try prepared.get().commitReadyPublication(ready_descriptor);
    var ready = try load(std.testing.allocator, dir, host_id);
    defer ready.deinit();
    try std.testing.expectEqual(Lifecycle.ready, ready.lifecycle);
    try std.testing.expectEqual(@as(u64, 5), ready.upgrade_epoch);
    try std.testing.expectError(
        error.InvalidManifest,
        prepared.get().commitReadyPublication(ready_descriptor),
    );
}

test "host manifest initial publish is exclusive and old owner cleanup cannot unlink a replacement generation" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "host-manifest-aba");
    defer test_scratch.close(std.testing.io, dir);
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

test "host manifest transaction rolls back precommit failure and poisons indeterminate rollback" {
    var dir_buf: [192]u8 = undefined;
    const dir = try test_scratch.open(std.testing.io, &dir_buf, "host-manifest-txn");
    defer test_scratch.close(std.testing.io, dir);
    const host_id: u128 = 0xD00D;
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);
    var descriptor: Descriptor = .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = endpoint,
    };
    var published = try publish(std.testing.allocator, dir, descriptor);
    defer {
        test_failpoint = .none;
        published.poisoned = false;
        published.deinit();
    }

    descriptor.upgrade_epoch = 2;
    test_failpoint = .before_commit_sync;
    try std.testing.expectError(error.SyncFailed, published.republish(descriptor));
    test_failpoint = .none;
    var rolled_back = try load(std.testing.allocator, dir, host_id);
    defer rolled_back.deinit();
    try std.testing.expectEqual(@as(u64, 1), rolled_back.upgrade_epoch);

    test_failpoint = .post_commit_cleanup;
    try published.republish(descriptor);
    test_failpoint = .none;
    var committed = try load(std.testing.allocator, dir, host_id);
    defer committed.deinit();
    try std.testing.expectEqual(@as(u64, 2), committed.upgrade_epoch);

    descriptor.upgrade_epoch = 3;
    test_failpoint = .rollback_sync;
    try std.testing.expectError(error.AuthorityPoisoned, published.republish(descriptor));
    try std.testing.expect(published.poisoned);
    test_failpoint = .none;
    try std.testing.expectError(error.AuthorityPoisoned, published.republish(descriptor));
}
