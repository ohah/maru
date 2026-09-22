//! 턴 링의 **디스크 저장소**(AT7 — 계약 [§6.3~6.4](../../../../docs/agent-turn-changes.md)). 순수 층 `turn_persist` 가
//! 바이트 ↔ 구조를 맡고, 여기는 **파일 규율**만 맡는다: 어디에(`<cache>/turn-rings/<session-id>/`), 어떤 권한으로
//! (디렉터리 0700 · 파일 0600 — 사본은 사용자 소스 원문이라 훅 로그와 같은 급), 어떻게 갈아 끼우나(임시 → rename),
//! blob 은 언제 쓰고 언제 지우나(있으면 건너뜀 · 도달성 sweep), 오래된 세션 디렉터리는 언제 치우나(7일 — 스풀·훅 로그와 같은 값).
//!
//! **tree 존재 확인은 여기 없다.** 그것은 git 을 부르는 일이라 비동기 러너를 가진 쪽(`git.zig` 의 배선)이 한다 — 이
//! 모듈은 git 을 모른다.
const std = @import("std");
const maru = @import("maru");
const turn_persist = maru.session.turn_persist;
const turn_snapshot = maru.session.turn_snapshot;
const turn_capture = maru.session.turn_capture;

pub const dir_rel = "turn-rings";
pub const manifest_name = "ring.v1";
pub const blobs_dir = "blobs";
/// 세션 디렉터리 수명 — 마지막 쓰기(`ring.v1` mtime)로부터. 원격 스풀·훅 로그와 **같은 7일**(계약 §6.4).
pub const stale_after_s: i64 = 7 * 24 * 60 * 60;
/// `ring.v1` 한 장의 상한 — 스냅샷 8 × 턴 경로 256 × 한 줄 ≤ 1 KiB 를 넉넉히 덮는다. 넘으면 손상으로 본다.
pub const max_manifest_bytes: u64 = 4 << 20;

/// 세션 id 가 디렉터리 이름으로 안전한가 — provider 가 만든 UUID 만 받는다(`/`·`..`·제어문자·공백 거절). 훅이 준 값이지만
/// 남의 프로세스가 적은 파일에서 온 것이라 **다시 검증한다**(`remote_tmux_route.isRoutableNonce` 와 같은 규율).
pub fn isSafeSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > turn_snapshot.max_session_id_len) return false;
    if (id[0] == '.') return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// `<base>/turn-rings/<session-id>` — null 이면 id 가 안전하지 않다.
pub fn sessionDirAlloc(a: std.mem.Allocator, base: []const u8, session_id: []const u8) ?[]u8 {
    if (!isSafeSessionId(session_id)) return null;
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), dir_rel, session_id }) catch null;
}

fn mkdir0700(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.mkdir(z.ptr, 0o700);
    _ = std.c.chmod(z.ptr, 0o700);
}

fn ensureDirs(base: []const u8, session_dir: []const u8) void {
    // `<base>` 는 이미 있을 수 있다(다른 캐시가 만든다). 없으면 만들되 권한은 우리가 만든 것만 조인다.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rings = std.fmt.bufPrint(&buf, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), dir_rel }) catch return;
    mkdir0700(base);
    mkdir0700(rings);
    mkdir0700(session_dir);
    var bbuf: [std.fs.max_path_bytes]u8 = undefined;
    const blobs = std.fmt.bufPrint(&bbuf, "{s}/{s}", .{ session_dir, blobs_dir }) catch return;
    mkdir0700(blobs);
}

/// 파일 하나를 임시 → rename 으로 갈아 끼운다(0600). 부분 파일이 다음 시작에 읽히지 않게.
///
/// **비용 실측**(2026-09-22, 적대적 2회차 — 계획 AT7 공격 H): 이 함수 자체는 2 KB 에 118 µs(rename·fsync 포함). `save` 전체가 1 MiB 사본
/// 8개로 20~36 ms 나온 것은 **Debug 빌드의 Wyhash 8 MiB**(`fromRing` 이 blob 이름을 만든다)였고 fsync 는 아니었다 — 실제 턴(사본 중앙값
/// 7.8 KB · 턴당 경로 2)에서는 1 ms 아래다. 그래서 fsync 는 둔다(`writeExecutableFile` 과 같은 규율 — rename 만 남고 데이터가 비는
/// 전원 차단을 막는다).
fn writeAtomic(io: std.Io, path: []const u8, body: []const u8) !void {
    // 임시 이름에 pid 를 붙인다 — 같은 세션을 두 창이 쓰면(`--resume` 둘, §6.5) 같은 임시 파일을 서로 rename 해 간다.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.maru-tmp.{d}", .{ path, std.c.getpid() }) catch return error.BadPath;
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        try file.writePositionalAll(io, body, 0);
        file.setPermissions(io, @enumFromInt(0o600)) catch {};
        file.sync(io) catch {};
    }
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

fn blobPath(buf: []u8, session_dir: []const u8, hash: u64) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{x:0>16}", .{ session_dir, blobs_dir, hash }) catch null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// 세션 하나를 통째로 쓴다: blob(없는 것만) → `ring.v1`(임시 → rename) → 안 가리켜지는 blob 제거. `turns` 는 링이 가리키는
/// 봉인 턴들(호출자가 `Store.sealedTurn` 으로 모은다 — 이 모듈은 스토어를 훑지 않는다).
pub const SaveError = anyerror;

pub fn save(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: []const u8,
    entry: *const turn_snapshot.RingMap.Entry,
    turns: []const turn_persist.SealedRef,
) SaveError!void {
    const session_dir = sessionDirAlloc(gpa, base, entry.sessionId()) orelse return error.UnsafeSessionId;
    defer gpa.free(session_dir);
    ensureDirs(base, session_dir);

    var m = try turn_persist.fromRing(gpa, entry, turns);
    defer turn_persist.releaseBorrowed(gpa, &m);

    // blob — 내용 주소라 있으면 그대로 둔다(같은 해시 = 같은 바이트).
    for (turns) |t| {
        for (t.turn.entries.items) |e| {
            try writeBlobIfText(io, session_dir, e.before);
            if (e.after) |a| try writeBlobIfText(io, session_dir, a);
        }
    }

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    turn_persist.write(&text.writer, &m) catch return error.OutOfMemory;
    var mpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mpath = std.fmt.bufPrint(&mpath_buf, "{s}/{s}", .{ session_dir, manifest_name }) catch return error.BadPath;
    try writeAtomic(io, mpath, text.written());

    sweepBlobs(io, gpa, session_dir, &m);
}

fn writeBlobIfText(io: std.Io, session_dir: []const u8, side: turn_capture.Side) SaveError!void {
    const bytes = switch (side) {
        .text => |t| t,
        else => return,
    };
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = blobPath(&pbuf, session_dir, turn_persist.blobHash(bytes)) orelse return error.BadPath;
    if (fileExists(io, path)) return;
    try writeAtomic(io, path, bytes);
}

/// manifest 가 안 가리키는 blob 을 지운다 — 링이 밀어낸 턴의 사본(계약 §6.4 ⑴, 메모리 `Store.sweep` 과 같은 도달성 규칙).
fn sweepBlobs(io: std.Io, gpa: std.mem.Allocator, session_dir: []const u8, m: *const turn_persist.Manifest) void {
    var live = std.AutoHashMap(u64, void).init(gpa);
    defer live.deinit();
    const Ctx = struct {
        map: *std.AutoHashMap(u64, void),
        fn note(self: @This(), hash: u64, _: u64) void {
            self.map.put(hash, {}) catch {};
        }
    };
    m.eachBlob(Ctx{ .map = &live }, Ctx.note);
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const blobs = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ session_dir, blobs_dir }) catch return;
    var dir = std.Io.Dir.openDirAbsolute(io, blobs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file) continue;
        const hash = std.fmt.parseInt(u64, ent.name, 16) catch {
            dir.deleteFile(io, ent.name) catch {}; // 우리 이름이 아니다 — 잔해
            continue;
        };
        if (live.contains(hash)) continue;
        dir.deleteFile(io, ent.name) catch {};
    }
}

/// `ring.v1` 을 읽어 파싱한다. 없거나(정상 — 새 세션) 손상이면 null. 손상은 **파일을 지운다** — 다음 시작마다 같은 손상을
/// 다시 읽을 이유가 없고, 사본 blob 도 함께 걷어야 «반쯤 남은 세션» 이 안 생긴다(세션 통째로 — 사용자 결정).
pub fn load(io: std.Io, gpa: std.mem.Allocator, base: []const u8, session_id: []const u8) ?turn_persist.Manifest {
    const session_dir = sessionDirAlloc(gpa, base, session_id) orelse return null;
    defer gpa.free(session_dir);
    var mpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mpath = std.fmt.bufPrint(&mpath_buf, "{s}/{s}", .{ session_dir, manifest_name }) catch return null;
    const file = std.Io.Dir.cwd().openFile(io, mpath, .{}) catch return null;
    defer file.close(io);
    const size = (file.stat(io) catch return null).size;
    if (size == 0 or size > max_manifest_bytes) {
        discard(io, session_dir);
        return null;
    }
    const buf = gpa.alloc(u8, @intCast(size)) catch return null;
    defer gpa.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    var m = turn_persist.parse(gpa, buf[0..n]) catch {
        discard(io, session_dir);
        return null;
    };
    if (!std.mem.eql(u8, m.entry.sessionId(), session_id)) {
        // 디렉터리 이름과 안의 id 가 다르다 — 남의 파일이 옮겨졌거나 손상. 통째로.
        m.deinit(gpa);
        discard(io, session_dir);
        return null;
    }
    return m;
}

/// 세션 디렉터리를 통째로 지운다(손상·TTL·저장소 전환).
pub fn discard(io: std.Io, session_dir: []const u8) void {
    const parent = std.fs.path.dirname(session_dir) orelse return;
    const leaf = std.fs.path.basename(session_dir);
    if (leaf.len == 0) return;
    var dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch return;
    defer dir.close(io);
    dir.deleteTree(io, leaf) catch {};
}

pub fn discardSession(io: std.Io, gpa: std.mem.Allocator, base: []const u8, session_id: []const u8) void {
    const session_dir = sessionDirAlloc(gpa, base, session_id) orelse return;
    defer gpa.free(session_dir);
    discard(io, session_dir);
}

const BlobCtx = struct {
    io: std.Io,
    session_dir: []const u8,

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, hash: u64, len: u64) ?[]u8 {
        const self: *BlobCtx = @ptrCast(@alignCast(ctx));
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = blobPath(&pbuf, self.session_dir, hash) orelse return null;
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const size = (file.stat(self.io) catch return null).size;
        // 길이·해시를 **여기서** 다시 잰다 — 이름이 맞아도 내용이 다르면(디스크 손상·부분 쓰기) 사본이 아니다.
        if (size != len or size > turn_capture.max_capture_bytes) return null;
        const buf = gpa.alloc(u8, @intCast(size)) catch return null;
        errdefer gpa.free(buf);
        const n = file.readPositionalAll(self.io, buf, 0) catch {
            gpa.free(buf);
            return null;
        };
        if (n != size or turn_persist.blobHash(buf[0..n]) != hash) {
            gpa.free(buf);
            return null;
        }
        return buf;
    }
};

/// manifest 를 링 항목 + 스토어의 봉인 턴으로 되살린다. blob 하나라도 없거나 안 맞으면 **아무것도 들이지 않고** 세션 디렉터리를
/// 지운다(세션 통째로).
pub fn restore(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: []const u8,
    m: *const turn_persist.Manifest,
    store: *turn_capture.Store,
) ?turn_snapshot.RingMap.Entry {
    const session_dir = sessionDirAlloc(gpa, base, m.entry.sessionId()) orelse return null;
    defer gpa.free(session_dir);
    var ctx: BlobCtx = .{ .io = io, .session_dir = session_dir };
    return turn_persist.restore(gpa, m, store, .{ .ctx = &ctx, .fetch = BlobCtx.fetch }) catch {
        discard(io, session_dir);
        return null;
    };
}

/// 시작 때 한 번 — `ring.v1` 이 `stale_after_s` 넘게 손 안 탄 세션 디렉터리를 지운다(계약 §6.4 ⑵). `now_s` 는 벽시계 초.
/// 지운 수를 돌려준다(진단용).
pub fn sweepStale(io: std.Io, base: []const u8, now_s: i64) usize {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const rings = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/"), dir_rel }) catch return 0;
    var dir = std.Io.Dir.openDirAbsolute(io, rings, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var removed: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const mrel = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ ent.name, manifest_name }) catch continue;
        const st = dir.statFile(io, mrel, .{}) catch {
            // manifest 가 없는 디렉터리 — 쓰다 만 잔해. 지운다.
            dir.deleteTree(io, ent.name) catch {};
            removed += 1;
            continue;
        };
        const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        if (now_s - mtime_s > stale_after_s) {
            dir.deleteTree(io, ent.name) catch {};
            removed += 1;
        }
    }
    return removed;
}

// ───────────────────────── 판정자 ─────────────────────────

const testing = std.testing;

fn sampleTurn(gpa: std.mem.Allocator) !turn_capture.Turn {
    var t: turn_capture.Turn = .{ .shell_calls = 1 };
    try t.entries.append(gpa, .{ .path = try gpa.dupe(u8, "a.zig"), .trigger = .edit, .before = .{ .text = try gpa.dupe(u8, "one\n") }, .after = .{ .text = try gpa.dupe(u8, "two\n") }, .before_trusted = true });
    return t;
}

test "턴 스냅샷 영속(AT7): 쓰고 되읽으면 같은 링·같은 사본이고, 밀린 턴의 blob 은 sweep 이 지운다 (AT7)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];

    var store: turn_capture.Store = .{};
    defer store.deinit(a);
    const id1 = store.adoptSealed(a, try sampleTurn(a));
    var entry: turn_snapshot.RingMap.Entry = .{ .id_len = 36 };
    @memcpy(entry.id[0..36], "0f6c1a2e-1111-4222-8333-444455556666");
    entry.ring.push(.{ .tree = "t1", .captured_s = 10, .capture_id = id1, .title = "첫 턴" });

    try save(io, a, base, &entry, &.{.{ .id = id1, .turn = store.sealedTurn(id1).? }});
    // 파일·권한
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&p, "{s}/turn-rings/0f6c1a2e-1111-4222-8333-444455556666/ring.v1", .{base});
    const st = try std.Io.Dir.cwd().statFile(io, mpath, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(st.permissions) & 0o777)));
    var bp: [std.fs.max_path_bytes]u8 = undefined;
    const bpath = blobPath(&bp, mpath[0 .. mpath.len - "/ring.v1".len], turn_persist.blobHash("one\n")).?;
    try testing.expect(fileExists(io, bpath));

    // 되읽기
    var m = load(io, a, base, entry.sessionId()) orelse return error.NoManifest;
    defer m.deinit(a);
    var store2: turn_capture.Store = .{};
    defer store2.deinit(a);
    const restored = restore(io, a, base, &m, &store2) orelse return error.RestoreFailed;
    try testing.expectEqualStrings("t1", restored.ring.latest().?.oid());
    try testing.expectEqualStrings("첫 턴", restored.ring.latest().?.titleText());
    const rt = store2.sealedTurn(restored.ring.latest().?.capture_id).?;
    try testing.expectEqualStrings("one\n", rt.entries.items[0].before.text);
    try testing.expectEqualStrings("two\n", rt.entries.items[0].after.?.text);

    // 링이 그 턴을 더는 안 가리키면(새 턴 8개가 밀어냄) 다음 save 의 sweep 이 그 blob 을 지운다.
    var i: usize = 0;
    var tb: [8]u8 = undefined;
    while (i < turn_snapshot.capacity) : (i += 1) {
        entry.ring.push(.{ .tree = try std.fmt.bufPrint(&tb, "n{d}", .{i}), .captured_s = 100 + @as(i64, @intCast(i)) });
    }
    try save(io, a, base, &entry, &.{.{ .id = id1, .turn = store.sealedTurn(id1).? }});
    try testing.expect(!fileExists(io, bpath));
}

test "턴 스냅샷 영속(AT7): 손상(잘린 manifest·바뀐 blob)은 세션 디렉터리를 통째로 지우고 아무것도 들이지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var store: turn_capture.Store = .{};
    defer store.deinit(a);
    const id1 = store.adoptSealed(a, try sampleTurn(a));
    var entry: turn_snapshot.RingMap.Entry = .{ .id_len = 4 };
    @memcpy(entry.id[0..4], "sess");
    entry.ring.push(.{ .tree = "t1", .capture_id = id1 });
    try save(io, a, base, &entry, &.{.{ .id = id1, .turn = store.sealedTurn(id1).? }});
    const sdir = sessionDirAlloc(a, base, "sess").?;
    defer a.free(sdir);

    // blob 을 바꿔치기 — 이름은 그대로, 내용이 다르다.
    var bp: [std.fs.max_path_bytes]u8 = undefined;
    const bpath = blobPath(&bp, sdir, turn_persist.blobHash("one\n")).?;
    try writeAtomic(io, bpath, "one!"); // 같은 길이, 다른 해시
    var m = load(io, a, base, "sess") orelse return error.NoManifest;
    var store2: turn_capture.Store = .{};
    defer store2.deinit(a);
    try testing.expect(restore(io, a, base, &m, &store2) == null);
    m.deinit(a);
    try testing.expectEqual(@as(turn_capture.Id, 1), store2.next_id); // 아무것도 안 들였다
    try testing.expect(!fileExists(io, bpath)); // 디렉터리째 사라졌다

    // 잘린 manifest
    try save(io, a, base, &entry, &.{.{ .id = id1, .turn = store.sealedTurn(id1).? }});
    var mp: [std.fs.max_path_bytes]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&mp, "{s}/{s}", .{ sdir, manifest_name });
    try writeAtomic(io, mpath, "maru.turn-ring.v1\nsession id=\"sess\" repo=\"\" missed=0 history-evicted=0\nsnapshot tree=\"t1\" surface=0 captured=0");
    try testing.expect(load(io, a, base, "sess") == null);
    try testing.expect(!fileExists(io, mpath));

    // 안전하지 않은 id 는 아예 안 만든다.
    try testing.expect(sessionDirAlloc(a, base, "../evil") == null);
    try testing.expect(sessionDirAlloc(a, base, "a b") == null);
    try testing.expect(sessionDirAlloc(a, base, ".hidden") == null);
}

test "턴 스냅샷 영속(AT7): 7일 넘게 손 안 탄 세션 디렉터리와 manifest 없는 잔해는 시작 sweep 이 지운다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp.dir.realPath(io, &base_buf)];
    var store: turn_capture.Store = .{};
    defer store.deinit(a);
    const id1 = store.adoptSealed(a, try sampleTurn(a));
    var entry: turn_snapshot.RingMap.Entry = .{ .id_len = 5 };
    @memcpy(entry.id[0..5], "fresh");
    entry.ring.push(.{ .tree = "t1", .capture_id = id1 });
    try save(io, a, base, &entry, &.{.{ .id = id1, .turn = store.sealedTurn(id1).? }});
    // 잔해 디렉터리(manifest 없음)
    const junk = sessionDirAlloc(a, base, "junk").?;
    defer a.free(junk);
    mkdir0700(junk);
    const fresh = sessionDirAlloc(a, base, "fresh").?;
    defer a.free(fresh);
    var mp: [std.fs.max_path_bytes]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&mp, "{s}/{s}", .{ fresh, manifest_name });
    const st = try std.Io.Dir.cwd().statFile(io, mpath, .{});
    const now_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    // 아직 7일 안 — fresh 는 남고 junk 만 사라진다.
    try testing.expectEqual(@as(usize, 1), sweepStale(io, base, now_s + stale_after_s - 1));
    try testing.expect(fileExists(io, mpath));
    // 7일 지남 — fresh 도 사라진다.
    try testing.expectEqual(@as(usize, 1), sweepStale(io, base, now_s + stale_after_s + 1));
    try testing.expect(!fileExists(io, mpath));
}
