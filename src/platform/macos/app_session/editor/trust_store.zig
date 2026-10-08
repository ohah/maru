//! 앱 전역 LSP 신뢰 저장소(docs/plans/workspace-trust.md WT2 — tooling §8.1 「저장소(workspace) 단위 신뢰 하나」).
//!
//! **표는 앱 전체에 하나다**(`store`). 창(세션)은 캐시하지 않고 이것을 읽는다 — 예전에는 창마다 파일을 한 번 읽어 제 캐시만 고쳐서 창 A 의
//! 결정을 창 B 가 몰랐다. 결정이 바뀌면 `store.generation` 이 오르고, 각 창의 LSP pump 가 그것을 보고 제 클라이언트에 다시 적용한다
//! (`lsp.zig` `applyTrustChanges` — 거부면 서버를 내린다). 메인 스레드 전용(세션 tick 과 같은 계약).
//!
//! **키는 (볼륨, 실제 경로)**(`keyFor`) — 작업 root(서버의 rootUri·표시)와 따로다. `/tmp/x`↔`/private/tmp/x`·심링크·대소문자만 다른
//! 경로가 한 키가 된다. 볼륨은 볼륨 UUID 라 같은 자리(`/Volumes/Untitled`)에 붙은 다른 디스크는 다른 키다.
//!
//! 파일은 상태 디렉터리 `~/Library/Application Support/maru/lsp-trust` 다 — 사용자가 손으로 고치는 설정이 아니라 앱이 기록하는 상태다.
//! 옛 자리(설정 파일 옆 `lsp-trust`, 옛 형식)는 새 파일이 아직 없을 때 한 번 이관하고 지운다(`ensureLoaded`).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const trust = maru.session.editor.lsp.trust;

/// 표가 쓰는 allocator — 창보다 오래 사는 앱 전역 수명이라 `app_runtime` 과 같은 `smp_allocator`.
const gpa = std.heap.smp_allocator;

/// 앱 전역 표. **이 파일 밖에서는 못 고친다** — 쓰는 길은 `decide`(사용자의 답) 하나다(계획 WT2 「신뢰 부여는 사용자 클릭으로만」).
var store: trust.Store = .{};
var loaded = false;
/// 새 표를 못 읽었다(권한·크기) — 이번 실행은 그 파일에 덧붙이지도 덮어쓰지도 않는다(메모리로만 쓴다).
var file_writable = true;

/// **테스트 주입 자리**(`backup.zig` 의 `setDirForTest` 와 같은 관례). `null` 이면 `$HOME/Library/Application Support/maru`.
/// 테스트 빌드는 주입 없이 사용자 자리로 떨어지지 않는다(`dirPath`) — 그때 표는 메모리에만 있다.
var dir_override: ?[]const u8 = null;
/// 옛 자리의 테스트 주입. 테스트 빌드는 **이것만** 이관한다 — 세션의 설정 경로로 구한 옛 자리는 판정자에서 사용자의 실제
/// `~/.config/maru/lsp-trust` 일 수 있고, 이관은 그 파일을 지운다.
var legacy_override: ?[]const u8 = null;

pub const file_name = "lsp-trust";

/// 주입을 바꾸고 표를 비운다(다음 읽기가 그 자리에서 다시 읽는다). 표는 앱 전역이라 판정자끼리 결정이 새지 않게 픽스처가 부른다.
/// 옛 자리 주입도 비운다. 판정자 전용 — 제품 빌드에서 부르면 컴파일되지 않는다.
pub fn setDirForTest(path: ?[]const u8) void {
    if (!builtin.is_test) @compileError("test-only");
    resetForTest();
    dir_override = path;
    legacy_override = null;
}

pub fn setLegacyPathForTest(path: ?[]const u8) void {
    if (!builtin.is_test) @compileError("test-only");
    legacy_override = path;
}

/// 표를 비운다 — 세대는 이어 간다(살아 있는 세션의 `seen_trust_generation` 과 다시 같아져 전파를 건너뛰지 않게).
pub fn resetForTest() void {
    if (!builtin.is_test) @compileError("test-only");
    const gen = store.generation;
    store.deinit(gpa);
    store.generation = gen;
    loaded = false;
    file_writable = true;
}

pub fn get(key: trust.Key) ?trust.Decision {
    return store.get(key);
}

pub fn changedAt(key: trust.Key) ?u64 {
    return store.changedAt(key);
}

pub fn generation() u64 {
    return store.generation;
}

pub fn claimant(key: trust.Key) ?usize {
    return store.claimant(key);
}

/// 저장소 디렉터리. 테스트 빌드는 주입 없이는 `null`(파일을 안 읽고 안 쓴다).
pub fn dirPath(buf: []u8) ?[]const u8 {
    if (dir_override) |d| {
        if (d.len == 0 or d.len > buf.len) return null;
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    if (builtin.is_test) return null;
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.trimEnd(u8, std.mem.span(home_z), "/");
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/maru", .{home}) catch null;
}

const AttrList = extern struct { bitmapcount: u16, reserved: u16, commonattr: u32, volattr: u32, dirattr: u32, fileattr: u32, forkattr: u32 };
extern "c" fn fgetattrlist(fd: c_int, attrlist: *const AttrList, buf: *anyopaque, size: usize, options: u32) c_int;
const attr_bit_map_count: u16 = 5;
const attr_vol_info: u32 = 0x8000_0000;
const attr_vol_uuid: u32 = 0x0004_0000;

/// 저장소의 신뢰 키 — 실제 경로(심링크·`/tmp`·대소문자를 푼다)와 그 볼륨. 디렉터리가 아니거나 못 열면 `null`.
/// 경로와 볼륨을 **같은 fd** 에서 얻는다 — 따로 풀면 그 사이에 심링크가 바뀌어 둘이 다른 저장소를 가리킬 수 있다.
pub fn keyFor(root: []const u8, buf: *[std.fs.max_path_bytes]u8) ?trust.Key {
    if (comptime builtin.os.tag != .macos) return null;
    if (root.len == 0 or root[0] != '/' or root.len >= buf.len) return null;
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(z[0..root.len], root);
    z[root.len] = 0;
    const fd = std.c.open(z[0..root.len :0].ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    if (std.c.fcntl(fd, std.c.F.GETPATH, buf) == -1) return null; // std 의 realpath 와 같은 길(디스크의 이름·대소문자)
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return .{ .volume = volumeOf(fd) orelse return null, .path = buf[0..n] };
}

/// 볼륨 — 볼륨 UUID(APFS·HFS+, 다시 붙여도 같다)를 64비트로 접는다. UUID 가 없는 파일 시스템(devfs·일부 네트워크)은 장치 번호로
/// 물러선다 — 다시 붙이면 바뀌어 다시 묻는다(신뢰가 이어지지 않는 쪽).
fn volumeOf(fd: c_int) ?u64 {
    const al: AttrList = .{ .bitmapcount = attr_bit_map_count, .reserved = 0, .commonattr = 0, .volattr = attr_vol_info | attr_vol_uuid, .dirattr = 0, .fileattr = 0, .forkattr = 0 };
    var out: extern struct { len: u32, uuid: [16]u8 } = undefined;
    if (fgetattrlist(fd, &al, &out, @sizeOf(@TypeOf(out)), 0) == 0 and out.len >= @sizeOf(@TypeOf(out))) {
        const folded = std.mem.readInt(u64, out.uuid[0..8], .big) ^ std.mem.readInt(u64, out.uuid[8..16], .big);
        if (folded != 0) return folded;
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    return @as(u32, @bitCast(st.dev)); // `dev_t` 는 부호 있는 32비트다 — 음수여도 그대로 접는다
}

/// 옛 자리 — 설정 파일 옆 `lsp-trust`(창마다 따로 읽던 옛 형식). 테스트 빌드는 주입한 것만.
pub fn legacyPathFor(config_path: []const u8, buf: []u8) ?[]const u8 {
    if (builtin.is_test) return legacy_override;
    const dir = std.fs.path.dirname(config_path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ file_name, .{dir}) catch null;
}

/// 처음 한 번 파일을 읽는다. **새 파일이 아직 없을 때만** 옛 자리 `legacy_path` 를 이관한다 — 새 파일이 있으면 이관은 이미
/// 끝났다(옛 파일을 못 지웠어도 다시 합치지 않는다: 합치면 옛 거부가 그 뒤의 「다시 묻기」 허용을 매번 덮는다). 새 파일을 못 읽으면
/// (권한·크기) 이관도 덮어쓰기도 덧붙이기도 하지 않는다 — 그 표를 옛 데이터로 갈아 끼우면 거부를 잃는다.
/// 테스트 빌드에서 주입이 없으면 아무것도 안 읽는다.
pub fn ensureLoaded(io: std.Io, legacy_path: ?[]const u8) void {
    if (loaded) return;
    loaded = true;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/" ++ file_name, .{dir}) catch return;
    switch (readSmall(io, path)) {
        .ok => |text| {
            defer gpa.free(text);
            store.load(gpa, text) catch {};
            return;
        },
        .unreadable => {
            file_writable = false;
            return;
        },
        .missing => {},
    }
    const legacy = legacy_path orelse return;
    const old = switch (readSmall(io, legacy)) {
        .ok => |t| t,
        .missing, .unreadable => return,
    };
    defer gpa.free(old);
    const Canon = struct {
        fn f(_: void, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ?trust.Key {
            return keyFor(root, buf);
        }
    };
    _ = store.mergeLegacy(gpa, old, {}, Canon.f) catch return;
    // 합친 표를 새 자리에 통째로 쓰고 나서야 옛 파일을 지운다 — 못 쓰면 옛 파일을 남겨 다음 실행이 다시 이관한다. 그러려면 이번 실행은
    // 새 자리에 **덧붙이지도 않는다** — 덧붙인 한 줄이 새 파일을 만들면 다음 실행은 이관이 끝난 것으로 보고 옛 결정을 영영 안 읽는다.
    if (!rewrite(io, dir, path)) {
        file_writable = false;
        return;
    }
    std.Io.Dir.cwd().deleteFile(io, legacy) catch {};
}

/// 결정을 둔다 — 표를 고치고(세대가 오른다) 파일에 한 줄 덧붙인다(마지막 줄이 이긴다). **사용자의 답만** 여기로 온다
/// (`lsp.zig` `recordTrust` ← `answerTrust` — 계획 WT2 「신뢰 부여는 사용자 클릭으로만」, LSPB23).
pub fn decide(io: std.Io, key: trust.Key, decision: trust.Decision) void {
    const changed = store.put(gpa, key, decision) catch return;
    if (!changed) {
        store.touch(key); // 같은 답 — 파일은 그대로, 다시 묻던 다른 창이 이것을 답으로 본다
        return;
    }
    if (!file_writable) return;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dirPath(&dir_buf) orelse return;
    if (!ensureDir(io, dir)) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/" ++ file_name, .{dir}) catch return;
    var line_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const l = trust.line(decision, key, &line_buf) orelse return;
    appendSmall(path, l);
}

/// 그 창이 잡은 묻는 자리를 놓는다(`key == null` 이면 전부 — 창이 닫힌다).
pub fn release(key: ?trust.Key, owner: usize) void {
    store.release(gpa, key, owner);
}

pub fn claim(key: trust.Key, owner: usize) bool {
    return store.claim(gpa, key, owner) catch false;
}

/// 자리를 만든다. 권한은 건드리지 않는다 — 이 디렉터리(`Application Support/maru`)는 작업 공간·웹 데이터와 함께 쓰는 자리라 그
/// 권한은 이 파일의 것이 아니다. 신뢰 파일 자체가 소유자만 읽는다(0600).
fn ensureDir(io: std.Io, dir: []const u8) bool {
    std.Io.Dir.cwd().createDirPath(io, dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return false,
    };
    return true;
}

fn rewrite(io: std.Io, dir: []const u8, path: []const u8) bool {
    if (!ensureDir(io, dir)) return false;
    const text = store.serialize(gpa) catch return false;
    defer gpa.free(text);
    var af = std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .permissions = @enumFromInt(0o600) }) catch return false;
    defer af.deinit(io);
    af.file.setPermissions(io, @enumFromInt(0o600)) catch return false;
    var buf: [4096]u8 = undefined;
    var w = af.file.writer(io, &buf);
    w.interface.writeAll(text) catch return false;
    w.interface.flush() catch return false;
    af.replace(io) catch return false;
    return true;
}

const Read = union(enum) { ok: []u8, missing, unreadable };

fn readSmall(io: std.Io, path: []const u8) Read {
    // 신뢰 파일이 1 MB 를 넘을 이유가 없다 — 넘으면 못 읽은 것으로 본다(덮어쓰지 않는다).
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| return switch (e) {
        error.FileNotFound => .missing,
        else => .unreadable,
    };
    return .{ .ok = text };
}

/// 한 줄을 덧붙인다. 파일 끝이 개행이 아니면(앞서 덧붙이다 끊긴 줄) 그 줄을 **`\t\n` 으로 닫는다** — 개행만 붙이면 끊긴 줄이 완성된
/// 줄이 되어 잘린 경로(`/r/sub` → `/r`)가 부모의 결정으로 읽힌다. 칸이 하나 남는 줄은 어느 형식으로도 읽히지 않고, 이 줄은 그 줄에
/// 붙지 않는다.
fn appendSmall(path: []const u8, line: []const u8) void {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
    const fd = std.c.open(z.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    const size = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (size > 0) {
        var last: [1]u8 = undefined;
        if (std.c.pread(fd, &last, 1, size - 1) != 1) return;
        if (last[0] != '\n' and !writeAll(fd, "\t\n")) return;
    }
    _ = writeAll(fd, line);
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn joinBuf(buf: []u8, a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ a, b });
}

test "LST6 신뢰 키 — 심링크·대소문자·/tmp↔/private/tmp 가 한 키, 볼륨은 실제 볼륨(상수가 아니다), 없는 경로·파일·상대 경로는 키가 없다 (계획 WT2)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Repo/sub");
    try tmp.dir.symLink(io, "Repo", "link", .{ .is_directory = true });
    try tmp.dir.writeFile(io, .{ .sub_path = "Repo/file.c", .data = "x" });
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const want = keyFor(try joinBuf(&p, base, "Repo"), &want_buf).?;
    var k: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(keyFor(try joinBuf(&p, base, "link"), &k).?.eql(want)); // 심링크
    try testing.expect(keyFor(try joinBuf(&p, base, "repo"), &k).?.eql(want)); // 대소문자(기본 APFS)
    try testing.expect(std.mem.endsWith(u8, want.path, "/Repo")); // 디스크의 대소문자
    try testing.expectEqualStrings(base, want.path[0 .. want.path.len - "/Repo".len]);
    try testing.expect(keyFor(try joinBuf(&p, base, "Repo/sub"), &k).?.volume == want.volume);
    var t1: [std.fs.max_path_bytes]u8 = undefined;
    var t2: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(keyFor("/tmp", &t1).?.eql(keyFor("/private/tmp", &t2).?)); // `/tmp` 는 `/private/tmp` 의 심링크
    try testing.expectEqualStrings("/private/tmp", keyFor("/tmp", &t1).?.path);
    // 볼륨은 그 디렉터리의 볼륨이다 — `/`(봉인된 시스템 볼륨)와 데이터 볼륨은 다르다.
    var r: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(keyFor("/", &r).?.volume != keyFor("/private/tmp", &t2).?.volume);
    try testing.expect(keyFor(try joinBuf(&p, base, "nope"), &k) == null);
    try testing.expect(keyFor(try joinBuf(&p, base, "Repo/file.c"), &k) == null); // 디렉터리가 아니다
    try testing.expect(keyFor("relative/path", &k) == null);
    try testing.expect(keyFor("", &k) == null);
}

test "LST7 테스트 빌드는 주입 없이 사용자 자리로 떨어지지 않는다 — 표는 메모리에만(옛 자리도 주입한 것만), 주입하면 그 자리에 소유자만 읽게 쓴다" {
    const saved = dir_override;
    defer setDirForTest(saved);
    setDirForTest(null);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(dirPath(&buf) == null);
    try testing.expect(legacyPathFor("/Users/someone/.config/maru/config", &buf) == null); // 사용자의 옛 파일을 지우지 않는다
    ensureLoaded(testing.io, null);
    decide(testing.io, .{ .volume = 1, .path = "/never/written" }, .allow);
    try testing.expectEqual(@as(?trust.Decision, .allow), get(.{ .volume = 1, .path = "/never/written" }));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/state/maru", .{root});
    // 저장소 자리는 이미 있다 — 제품의 `Application Support/maru` 처럼 작업 공간·웹 데이터와 함께 쓰는 자리라 그 권한(0755)을 건드리면 안 된다.
    try tmp.dir.createDirPath(testing.io, "state/maru");
    try tmp.dir.setFilePermissions(testing.io, "state/maru", @enumFromInt(0o755), .{});
    const gen_before = generation();
    setDirForTest(dir);
    try testing.expect(get(.{ .volume = 1, .path = "/never/written" }) == null); // 주입을 바꾸면 표가 빈다
    try testing.expectEqual(gen_before, generation()); // 세대는 이어 간다(되돌리면 살아 있는 창이 전파를 건너뛴다)
    ensureLoaded(testing.io, null);
    decide(testing.io, .{ .volume = 7, .path = "/r" }, .deny);
    decide(testing.io, .{ .volume = 7, .path = "/r" }, .deny); // 같은 답은 줄을 늘리지 않는다
    const text = try tmp.dir.readFileAlloc(testing.io, "state/maru/" ++ file_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("deny\t7\t/r\n", text);
    const dst = try tmp.dir.statFile(testing.io, "state/maru", .{}); // 함께 쓰는 자리의 권한은 그대로다
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(@intFromEnum(dst.permissions) & 0o777)));
    const fst = try tmp.dir.statFile(testing.io, "state/maru/" ++ file_name, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(fst.permissions) & 0o777)));
}

test "LST8 옛 자리 이관 — 새 파일이 없으면 합쳐 쓴 뒤 옛 파일을 지우고, 거부가 이기며, 사라진 root 는 버린다; 다시 읽어도 같다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    const saved = dir_override;
    defer setDirForTest(saved);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Repo");
    try tmp.dir.symLink(io, "Repo", "alias", .{ .is_directory = true });
    try tmp.dir.createDirPath(io, "Other");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const legacy = try joinBuf(&legacy_buf, root, "config-lsp-trust");
    var text_buf: [4 * std.fs.max_path_bytes]u8 = undefined;
    const old = try std.fmt.bufPrint(&text_buf, "allow\t{0s}/Repo\ndeny\t{0s}/alias\nallow\t{0s}/Other\nallow\t{0s}/gone\n", .{root});
    try tmp.dir.writeFile(io, .{ .sub_path = "config-lsp-trust", .data = old });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    setDirForTest(try joinBuf(&dir_buf, root, "state"));
    setLegacyPathForTest(legacy);
    var lb: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(legacy, legacyPathFor("/ignored/config", &lb).?);
    ensureLoaded(io, legacy);

    var k_buf: [std.fs.max_path_bytes]u8 = undefined;
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = keyFor(try joinBuf(&p_buf, root, "Repo"), &k_buf).?;
    try testing.expectEqual(@as(?trust.Decision, .deny), get(repo)); // 같은 저장소의 두 이름 — 거부가 이긴다
    var k2: [std.fs.max_path_bytes]u8 = undefined;
    const other = keyFor(try joinBuf(&p_buf, root, "Other"), &k2).?;
    try testing.expectEqual(@as(?trust.Decision, .allow), get(other));
    try testing.expectEqual(@as(usize, 2), store.entries.items.len); // 사라진 root 는 버렸다
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "config-lsp-trust", .{})); // 옛 파일을 지웠다

    // 새 자리만으로 다시 읽어도 같다(앱을 다시 띄웠다).
    resetForTest();
    ensureLoaded(io, legacy);
    try testing.expectEqual(@as(?trust.Decision, .deny), get(repo));
    try testing.expectEqual(@as(?trust.Decision, .allow), get(other));
}

test "LST9 새 자리에 못 쓰면 옛 파일을 지우지 않는다 — 다음 실행이 다시 이관한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    const saved = dir_override;
    defer setDirForTest(saved);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Repo");
    try tmp.dir.createDirPath(io, "ro");
    // 쓸 수 없는 부모 아래의 아직 없는 자리 — 새 파일은 「없음」이라 이관을 하는데 새 자리를 못 만든다.
    try tmp.dir.setFilePermissions(io, "ro", @enumFromInt(0o500), .{});
    defer tmp.dir.setFilePermissions(io, "ro", @enumFromInt(0o700), .{}) catch {};
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var text_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy", .data = try std.fmt.bufPrint(&text_buf, "allow\t{s}/Repo\n", .{root}) });
    var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    setDirForTest(try joinBuf(&dir_buf, root, "ro/state"));
    ensureLoaded(io, try joinBuf(&legacy_buf, root, "legacy"));
    _ = try tmp.dir.statFile(io, "legacy", .{}); // 남았다
    try testing.expectEqual(@as(usize, 1), store.entries.items.len); // 이번 실행은 메모리로 쓴다
    try testing.expect(!file_writable); // 덧붙이지도 않는다 — 새 파일이 생기면 다음 실행이 옛 파일을 안 읽는다
}

test "LST10 새 파일이 있으면 이관하지 않는다 — 옛 파일이 남아 있어도(옛 거부가 그 뒤의 허용을 덮지 않는다), 두 자리가 같은 파일이어도(새 표를 지우지 않는다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    const saved = dir_override;
    defer setDirForTest(saved);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "Repo");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var k_buf: [std.fs.max_path_bytes]u8 = undefined;
    var p_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = keyFor(try joinBuf(&p_buf, root, "Repo"), &k_buf).?;
    var line_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const new_text = trust.line(.allow, repo, &line_buf).?;
    try tmp.dir.writeFile(io, .{ .sub_path = "state/" ++ file_name, .data = new_text });
    var old_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy", .data = try std.fmt.bufPrint(&old_buf, "deny\t{s}/Repo\n", .{root}) });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
    setDirForTest(try joinBuf(&dir_buf, root, "state"));
    ensureLoaded(io, try joinBuf(&legacy_buf, root, "legacy"));
    try testing.expectEqual(@as(?trust.Decision, .allow), get(repo)); // 옛 거부가 덮지 않았다
    _ = try tmp.dir.statFile(io, "legacy", .{}); // 손대지 않았다

    // 두 자리가 같은 파일(심링크로 다른 철자) — 새 표를 읽고 끝난다.
    try tmp.dir.symLink(io, "state", "state-alias", .{ .is_directory = true });
    var same_buf: [std.fs.max_path_bytes]u8 = undefined;
    resetForTest();
    ensureLoaded(io, try std.fmt.bufPrint(&same_buf, "{s}/state-alias/" ++ file_name, .{root}));
    try testing.expectEqual(@as(?trust.Decision, .allow), get(repo));
    const after = try tmp.dir.readFileAlloc(io, "state/" ++ file_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(new_text, after);
}

test "LST11 새 표를 못 읽으면(권한) 옛 파일을 이관하지도, 새 표를 덮어쓰지도, 덧붙이지도 않는다 — 이번 실행은 메모리로 쓴다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    const saved = dir_override;
    defer setDirForTest(saved);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "Repo");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "state/" ++ file_name, .data = "deny\t1\t/kept\n" });
    try tmp.dir.setFilePermissions(io, "state/" ++ file_name, @enumFromInt(0o000), .{});
    defer tmp.dir.setFilePermissions(io, "state/" ++ file_name, @enumFromInt(0o600), .{}) catch {};
    var old_buf: [2 * std.fs.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "legacy", .data = try std.fmt.bufPrint(&old_buf, "allow\t{s}/Repo\n", .{root}) });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var legacy_buf: [std.fs.max_path_bytes]u8 = undefined;
    setDirForTest(try joinBuf(&dir_buf, root, "state"));
    ensureLoaded(io, try joinBuf(&legacy_buf, root, "legacy"));
    try testing.expectEqual(@as(usize, 0), store.entries.items.len); // 옛 허용을 들이지 않았다
    _ = try tmp.dir.statFile(io, "legacy", .{});
    decide(io, .{ .volume = 1, .path = "/new" }, .allow);
    try testing.expectEqual(@as(?trust.Decision, .allow), get(.{ .volume = 1, .path = "/new" }));
    try tmp.dir.setFilePermissions(io, "state/" ++ file_name, @enumFromInt(0o600), .{});
    const after = try tmp.dir.readFileAlloc(io, "state/" ++ file_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("deny\t1\t/kept\n", after); // 그대로다
}

test "LST12 덧붙이다 끊긴 줄 — 그 줄은 읽지 않고(잘린 경로가 부모의 허용이 되지 않게), 다음 결정은 그 줄을 읽히지 않게 닫고 덧붙여 다시 읽어도 그 줄은 무효다" {
    const io = testing.io;
    const saved = dir_override;
    defer setDirForTest(saved);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    // `allow\t1\t/r/sub\n` 을 쓰다 `/r` 에서 끊겼다.
    try tmp.dir.writeFile(io, .{ .sub_path = "state/" ++ file_name, .data = "deny\t1\t/a\nallow\t1\t/r" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    setDirForTest(try joinBuf(&dir_buf, root, "state"));
    ensureLoaded(io, null);
    try testing.expect(get(.{ .volume = 1, .path = "/r" }) == null);
    try testing.expectEqual(@as(?trust.Decision, .deny), get(.{ .volume = 1, .path = "/a" }));
    decide(io, .{ .volume = 1, .path = "/q" }, .deny);
    resetForTest();
    ensureLoaded(io, null);
    try testing.expectEqual(@as(?trust.Decision, .deny), get(.{ .volume = 1, .path = "/q" }));
    try testing.expect(get(.{ .volume = 1, .path = "/r" }) == null);
    const text = try tmp.dir.readFileAlloc(io, "state/" ++ file_name, testing.allocator, .limited(4096));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("deny\t1\t/a\nallow\t1\t/r\t\ndeny\t1\t/q\n", text);
}
