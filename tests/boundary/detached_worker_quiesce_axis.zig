//! **detached worker 는 판정자보다 오래 살면 안 된다** — 그 규율에 자리를 남기지 않는 게이트.
//!
//! ## 왜 판정자가 필요한가
//!
//! macOS 층의 backend 들은 느린 FS·프로세스 I/O 를 detached thread 로 돌리고, 물러날 때 **기다리지
//! 않는다**(refcount 가 마지막 하나를 파괴한다). 제품에서는 그게 맞다 — 멈춘 I/O 로 창 닫기가 굳는 것이
//! 훨씬 나쁘다. **판정자에서는 그 대가를 다른 판정자가 문다**: 스캔을 던져 놓고 세션이 끝나면 아직 도는
//! job 의 할당이 테스트 할당자 결산에 누수로 잡히고, 그 워커가 뒤이어 해제된 자리를 만지면 트레이스를
//! 찍는 도중에 죽는다. 2026-09-08 CI 샤드가 정확히 그 모양으로 abort 했다(`dupe` 누수 → segfault → 134).
//!
//! 그 실패의 **가장 나쁜 성질은 오귀속**이다. 누수 결산은 매 판정자 끝에 도는데 워커를 남긴 판정자와
//! 결산이 걸린 판정자가 다르고, 트레이스를 찍다 죽어 **이름조차 안 남는다**. 그래서 무관한 커밋의
//! 회귀로 읽었다. 빠른 기계에서는 워커가 먼저 끝나 아예 안 보인다.
//!
//! 처방은 산문으로 두면 **새 backend 가 반드시 샌다** — 실제로 새로 다는 자리가 여덟이었고, 처음 판은
//! 그중 둘을 잘못된 순서로 묶어 상한까지 헛돌았다(적대적 검증 1 회차 실측). 그래서 게이트로 못 박는다.
//!
//! ## 무엇을 재나 — **이름이 아니라 「거두는가」를 센다**
//!
//! `src/platform/macos` 에서 **detached worker 를 띄우고 refcount 로 state 를 붙드는 파일**(=
//! `Thread.spawn` + `refs` 를 모두 든 파일)을 전부 찾아, 각자가 둘 중 **하나**를 만족하는지 본다:
//!
//! - ⒜ **자기 `deinit` 안에서 거둔다** — `builtin.is_test` 갈래에 대기가 있다. 워커가 `shutting_down`
//!   을 봐야 빠져나오는(게이트 있는) backend 는 **반드시 이쪽**이다: 취소를 세우는 것이 `deinit` 이므로
//!   그 **앞**에서 기다리면 영원히 안 끝난다.
//! - ⒝ **세션이 물러나며 거둔다** — `app_session.zig` 의 `quietDetachedWorkersForTest` 가 그 파일의
//!   backend 를 부른다. 게이트가 **없는** backend 만 이쪽에 둘 수 있다.
//!
//! 둘 다 아니면 실패다. 재고에 이름만 적는 방식은 쓰지 않는다 — 그 파일이 아무것도 안 거둬도 통과하는
//! 공허한 판정이 되기 때문이다(이 저장소가 반복해서 당한 실패다).
//!
//! ## 이 게이트가 못 보는 것 — 정직하게
//!
//! - 거두는 **호출이 있는데 자리가 틀린 것**은 못 본다(⒜ 안에서 취소보다 앞에 둔 경우). 그 축은
//!   판정자 「상세 backend: 게이트에 세워 둔 워커는 deinit 이 거두고 나간다」가 제품 경로로 잰다.
//! - `Thread.spawn` 을 다른 이름 뒤에 숨기면 안 걸린다. 지금 그런 자리는 없고, 생기면 그것 자체가
//!   리뷰 대상이다.
//! - test 블록은 세지 않는다(`source_digest.anyDepthTestTokenMask` 가 그 규칙의 단일 출처다) — 판정자가
//!   자기 안에서 띄우는 probe 스레드는 이 축이 아니다.
//! - refcount 를 `refs: std.atomic.Value` 말고 다른 이름으로 들면 이 축에 안 잡힌다. 지금 이 층의
//!   backend 는 전부 그 이름을 쓰고, 안 쓰는 것을 새로 만들면 그것 자체가 리뷰 대상이다.

const std = @import("std");
const source_digest = @import("source_digest.zig");
const posix_walk = @import("posix_walk.zig");

/// **재귀로 훑는다.** 디렉터리 목록을 손으로 적으면 하위 디렉터리 하나가 생기는 순간 게이트가 조용히
/// 눈을 감는다 — 이 게이트가 막으려는 실패(자리가 하나 더 생겼는데 아무도 모른다)와 같은 모양이다.
const scan_dir = "src/platform/macos";
const session_path = "src/platform/macos/app_session.zig";
const session_owner_fn = "quietDetachedWorkersForTest";

/// ⒜ 로 거두는 파일과 그 이유. **새로 늘리려면 여기에 이유를 적어야 한다.**
const InDeinit = struct { file: []const u8, why: []const u8 };

const in_deinit = [_]InDeinit{
    .{
        .file = "agent_session_archive_backend.zig",
        .why = "워커가 `waitForTestGate` 에서 `shutting_down`·게이트 해제를 봐야 나온다 — 취소를 세우는 `deinit` 안에서만 거둘 수 있다.",
    },
    .{
        .file = "agent_session_archive_detail_backend.zig",
        .why = "본체와 같은 게이트를 든다(같은 이유).",
    },
    .{
        .file = "agent_image_scan_backend.zig",
        .why = "제품 `deinit` 이 취소를 걸고 스레드를 **join** 한다(테스트 전용이 아니다) — 3.6 초짜리 스캔을 끝까지 돌릴 이유가 없다.",
    },
    .{
        .file = "agent_image_decode_backend.zig",
        .why = "제품 `deinit` 이 스레드를 **join** 한다(테스트 전용이 아니다) — 대기가 한 장 디코드(실측 평균 4.4 ms)로 한정된다.",
    },
};

fn readFileZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try allocator.allocSentinel(u8, @intCast(stat.size), 0);
    errdefer allocator.free(buffer);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buffer);
    return buffer;
}

/// test 블록 **밖에서** 이 토큰이 나오는지 본다. 판정자가 자기 안에서 띄우는 probe 스레드는 이 축이 아니다.
fn hasProductToken(allocator: std.mem.Allocator, source: [:0]const u8, token: []const u8) !bool {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const mask = try source_digest.anyDepthTestTokenMask(allocator, &tree);
    defer allocator.free(mask);
    var index: std.zig.Ast.TokenIndex = 0;
    while (index < tree.tokens.len) : (index += 1) {
        if (mask[index]) continue;
        if (std.mem.eql(u8, tree.tokenSlice(index), token)) return true;
    }
    return false;
}

/// `deinit` 본문 안에 **대기가 실제로 있는지** — 본문 범위로 본다(파일 어딘가에 그 토큰이 있다는 것만
/// 으로 통과하면 공허해진다).
///
/// 두 모양을 모두 받는다. ⑴ `builtin.is_test` 갈래의 테스트 전용 거둠(대부분), ⑵ **항상** 거두는
/// `join`(이미지 스캔·디코드 — 대기 상한이 작아 제품에서도 기다리는 편이 낫다고 이미 결정한 자리다).
/// 둘 다 「기다린다」는 같은 성질이고, 이 축이 재는 것은 **기다리는가**이지 어느 갈래인가가 아니다.
fn deinitDrains(source: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "pub fn deinit(self: *Backend) void {")) |start| {
        const body_start = start + "pub fn deinit(self: *Backend) void {".len;
        var depth: usize = 1;
        var index = body_start;
        while (index < source.len and depth > 0) : (index += 1) {
            switch (source[index]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
        }
        const body = source[body_start..index];
        if (std.mem.indexOf(u8, body, "is_test") != null) return true;
        if (std.mem.indexOf(u8, body, ".join()") != null) return true;
        cursor = index;
    }
    return false;
}

test "정지 축: detached worker 를 띄우는 backend 는 자기 deinit 이나 세션 종료가 반드시 거둔다" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const session_source = try readFileZ(allocator, io, session_path);
    defer allocator.free(session_source);
    // 세션 쪽 소유자 함수가 사라졌으면 ⒝ 갈래가 통째로 공허해진다 — 그것부터 못 박는다.
    try std.testing.expect(std.mem.indexOf(u8, session_source, session_owner_fn) != null);
    const owner_start = std.mem.indexOf(u8, session_source, "fn " ++ session_owner_fn).?;
    const owner_end = std.mem.indexOfPos(u8, session_source, owner_start, "\n    }\n").?;
    const owner_body = session_source[owner_start..owner_end];

    var dir = try std.Io.Dir.cwd().openDir(io, scan_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try posix_walk.posixWalk(dir, allocator);
    defer walker.deinit();

    var failed = false;
    var found: usize = 0;
    var seen_in_deinit: [in_deinit.len]bool = .{false} ** in_deinit.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const name = std.fs.path.basename(entry.path);
        if (std.mem.eql(u8, name, "detached_worker_wait.zig")) continue; // 대기 그 자체
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_dir, entry.path });
        defer allocator.free(path);
        // **못 읽거나 못 파싱하면 조용히 건너뛰지 않는다** — 스캐너의 침묵을 통과로 읽지 않는다.
        const source = readFileZ(allocator, io, path) catch |err| {
            std.debug.print("quiesce axis: {s} 를 못 읽었다({s}).\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        defer allocator.free(source);
        const spawns = hasProductToken(allocator, source, "spawn") catch |err| {
            std.debug.print("quiesce axis: {s} 를 못 파싱했다({s}).\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        if (!spawns) continue;
        if (std.mem.indexOf(u8, source, "refs: std.atomic.Value") == null) continue; // refcount backend 만
        found += 1;

        var listed: ?usize = null;
        for (in_deinit, 0..) |item, index| {
            if (std.mem.eql(u8, item.file, name)) listed = index;
        }
        if (listed) |index| {
            seen_in_deinit[index] = true;
            // **이름이 아니라 「거두는가」** — 재고에 적혔어도 실제로 대기가 있어야 한다.
            if (!deinitDrains(source)) {
                std.debug.print(
                    "quiesce axis: {s} 는 재고상 자기 `deinit` 에서 거두기로 되어 있는데({s}) 그 본문에 `is_test` 대기가 없다.\n",
                    .{ path, in_deinit[index].why },
                );
                failed = true;
            }
            continue;
        }
        // ⒝ — 세션 종료가 거둔다. 이름이 아니라 **그 함수가 실제로 부르는지**를 본다.
        const stem = name[0 .. name.len - ".zig".len];
        if (std.mem.indexOf(u8, owner_body, stem) == null) {
            std.debug.print(
                "quiesce axis: {s} 는 detached worker 를 띄우는데 아무도 거두지 않는다. 워커가 `shutting_down` 을 봐야 나오면 자기 `deinit` 안에서(취소 뒤에) 거두고 재고에 이유를 적고, 아니면 `{s}` 에 한 줄 더하라.\n",
                .{ path, session_owner_fn },
            );
            failed = true;
        }
    }

    for (in_deinit, 0..) |item, index| {
        if (seen_in_deinit[index]) continue;
        std.debug.print(
            "quiesce axis: 재고의 {s} 를 스캔이 못 찾았다({s}). 옮겨졌으면 재고를 갱신하라 — 못 찾은 것을 통과로 읽지 않는다.\n",
            .{ item.file, item.why },
        );
        failed = true;
    }
    // 스캔이 통째로 비어도 초록이 되지 않게 한다.
    try std.testing.expect(found >= in_deinit.len);
    try std.testing.expect(!failed);
}
