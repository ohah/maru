//! **발행 목록(`file_tree_rows`)의 출처 축**을 고정한다.
//!
//! ## 왜 판정자가 필요한가
//!
//! 도크 트리가 그리는 행 목록은 **하나**인데 그것을 채우는 모델은 둘이다 — 로컬(`file_tree`)과
//! 원격(`remote_explorer.tree`). 어느 쪽이 채웠는지는 `file_tree_rows_remote` 가 적고, 그 판정 하나로
//! 클릭·이름 변경·삭제가 로컬 갈래와 원격 갈래로 갈린다(docs/plans/remote-file-tree.md §10.4 ③c —
//! 「키는 언제나 **발행 출처**다」).
//!
//! 그 출처를 정하는 자리는 `updateFileTree` 의 발행 단계 **하나**여야 한다. 그런데 목록을 그 단계
//! **밖에서** 통째로 갈아 끼우는 자리가 실재한다(트리 커밋·workspace 교체). 거기서 로컬 행을 발행하고
//! 지나가면 두 가지가 함께 깨진다:
//!
//! - **행은 로컬인데 플래그는 원격**이 되어, 원격 갈래가 로컬 행에 걸린다(그 반대 방향이 §10.4 ③c 다).
//! - 재빌드가 예약되지 않아 **원격을 보는 중인데 로컬 트리가 화면에 남는다** — 2026-09-07 사용자 보고가
//!   그것이다(원격 트리에서 파일을 열면 RF4 의 미러가 로컬 열기 파이프라인을 타면서 그 자리를 지난다).
//!
//! 처방은 그 두 줄을 한 함수(`notePublishedLocalFileTreeRows`)에 모으는 것이었는데, **산문으로 두면
//! 새 자리가 반드시 샌다** — 실제로 자리가 둘이었고 처음 판은 그중 하나만 고쳤다(적대적 검증 1 회차).
//! 그래서 §5 가 트리 축에 세운 그 규율대로 게이트로 못 박는다.
//!
//! ## 무엇을 재나 — **이름이 아니라 「쓰는가」를 센다**
//!
//! 재고에 파일 이름만 적으면 그 파일이 헬퍼를 **부르지 않아도** 통과한다(이 저장소가 반복해서 당한
//! 공허한 통과다). 그래서 판정은 개수 비교다: 한 파일에서
//!
//! - `… .file_tree_rows =` (발행 목록에 **대입**하는 자리) 가 N 번 나오면
//! - `notePublishedLocalFileTreeRows(` **호출**이 N 번 이상 있어야 한다.
//!
//! `&self.file_tree_rows` 로 **넘겨서 채우는** 발행 단계 자신은 대입이 아니라 안 걸린다 — 그 자리가
//! 출처를 직접 정하는 소유자이므로 세면 안 된다.
//!
//! ## 이 게이트가 못 보는 것 — 정직하게
//!
//! - 헬퍼를 **부르고도** 그 앞에서 엉뚱한 행을 넣는 것은 못 본다(개수 비교다). 그 축은 판정자
//!   「원격 탐색기 유지…(RF7)」가 제품 경로로 잰다.
//! - `file_tree_rows` 를 다른 이름으로 별칭 잡아(`const rows = &self.file_tree_rows`) 대입하면 안
//!   걸린다. 지금 그런 자리는 없고, 생기면 그것 자체가 리뷰 대상이다.
//! - test 블록은 세지 않는다(`source_digest.anyDepthTestTokenMask` 가 그 규칙의 단일 출처다 — **중첩
//!   `test` 까지** 뺀다. 최상위판을 쓰면 중첩 테스트의 헬퍼 호출이 `notes` 를 부풀려 **제품의 빠진
//!   호출을 가린다** — 새로 세는 쪽은 이 판을 쓰라는 그 함수의 규정이 이 방향 때문이다).

const std = @import("std");
const source_digest = @import("source_digest.zig");
const posix_walk = @import("posix_walk.zig");

/// 발행 단계 **밖에서** 목록을 갈아 끼우는 것이 허용된 파일과 그 이유.
/// **새로 늘리려면 여기에 이유를 적어야 한다** — 그게 이 게이트의 목적이다.
const Entry = struct {
    path: []const u8,
    /// test 블록 밖에서 `.file_tree_rows =` 대입이 나오는 횟수.
    assigns: usize,
    why: []const u8,
};

const inventory = [_]Entry{
    .{
        .path = "src/platform/macos/app_session/file_panel.zig",
        .assigns = 1,
        .why = "트리 커밋(`commitFileTreeCandidate`) — root 교체·파일 열기·이름 변경이 모두 이 한 자리로 모인다. 헬퍼의 정의도 이 파일이 든다(정의는 호출로 안 세므로 공허해지지 않는다).",
    },
    .{
        .path = "src/platform/macos/app_session/workspace.zig",
        .assigns = 1,
        .why = "workspace 교체 — 트리·백엔드·open 상태를 한 묶음으로 갈아 끼우는 자리라 커밋 함수로 접을 수 없다(소유 집합이 다르다).",
    },
};

/// **`src` 전체를 재귀로** 훑는다. 이 필드는 `AppSession` 의 것이라 오늘 만지는 자리는 macOS 층뿐이지만,
/// 디렉터리 목록을 손으로 적으면 **하위 디렉터리 하나가 생기는 순간 게이트가 조용히 눈을 감는다** —
/// 이 게이트가 막으려는 실패(자리가 하나 더 생겼는데 아무도 모른다)와 정확히 같은 모양이다.
const scan_root = "src";

fn readZigFileZ(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buffer = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buffer);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buffer);
    return buffer;
}

const Counts = struct { assigns: usize, notes: usize };

/// **구조로 찾는다**(문자열 부분 일치가 아니라 토큰 이웃으로). `file_tree_rows_dirty` 같은 다른 필드나
/// `.file_tree_rows => "…"` 같은 switch 갈래가 걸리지 않는 이유가 그것이다.
fn countOutsideTests(allocator: std.mem.Allocator, source: [:0]const u8) !Counts {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const mask = try source_digest.anyDepthTestTokenMask(allocator, &tree);
    defer allocator.free(mask);
    const tags = tree.tokens.items(.tag);
    var counts: Counts = .{ .assigns = 0, .notes = 0 };
    var token: std.zig.Ast.TokenIndex = 0;
    while (token + 1 < tree.tokens.len) : (token += 1) {
        if (mask[token]) continue;
        const text = tree.tokenSlice(token);
        if (std.mem.eql(u8, text, "file_tree_rows")) {
            // 대입만 센다 — `&self.file_tree_rows` 로 넘겨 채우는 발행 단계는 출처의 소유자다.
            if (tags[token + 1] == .equal) counts.assigns += 1;
        } else if (std.mem.eql(u8, text, "notePublishedLocalFileTreeRows")) {
            // **호출만 센다.** 선언(`pub fn note…`)까지 세면 정의 하나로 통과하는 공허한 판정이 된다.
            if (tags[token + 1] == .l_paren and (token == 0 or tags[token - 1] != .keyword_fn)) {
                counts.notes += 1;
            }
        }
    }
    return counts;
}

test "발행 축: 목록을 갈아 끼우는 자리는 출처 기록 함수를 반드시 지난다" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    {
        var dir = try std.Io.Dir.cwd().openDir(io, scan_root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try posix_walk.posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ scan_root, entry.path }));
        }
    }
    // **못 찾았으면 통과가 아니라 실패다.** 경로가 바뀌어 스캔이 빈 채로 초록이 되는 것이 이 저장소가
    // 가장 나쁘다고 적어 둔 실패 모드다.
    try std.testing.expect(paths.items.len > 0);

    var failed = false;
    var seen: [inventory.len]bool = .{false} ** inventory.len;
    var total_assigns: usize = 0;
    for (paths.items) |path| {
        // **못 읽거나 못 파싱하면 조용히 건너뛰지 않는다.** `catch continue` 로 두면 파싱이 깨진 파일
        // 하나가 그 안의 위반을 통째로 숨기고도 초록이 된다 — 스캐너의 침묵을 통과로 읽는 그 실패 모드다.
        const source = readZigFileZ(allocator, io, path) catch |err| {
            std.debug.print("publish axis: {s} 를 못 읽었다({s}). 스캔이 못 본 파일을 통과로 읽지 않는다.\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        defer allocator.free(source);
        const counts = countOutsideTests(allocator, source) catch |err| {
            std.debug.print("publish axis: {s} 를 못 파싱했다({s}). 스캔이 못 본 파일을 통과로 읽지 않는다.\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };
        total_assigns += counts.assigns;
        var listed: ?usize = null;
        for (inventory, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) listed = index;
        }
        if (listed) |index| {
            seen[index] = true;
            if (counts.assigns != inventory[index].assigns) {
                std.debug.print(
                    "publish axis: {s} 의 `file_tree_rows` 대입이 {d} 개다(재고 {d}). 발행 자리가 달라졌으면 재고와 이유를 갱신하라.\n",
                    .{ path, counts.assigns, inventory[index].assigns },
                );
                failed = true;
            }
        } else if (counts.assigns != 0) {
            std.debug.print(
                "publish axis: {s} 가 재고 밖에서 `file_tree_rows` 에 대입한다({d} 개). 발행 출처를 정하는 자리는 `updateFileTree` 의 발행 단계 하나이고, 그 밖에서 갈아 끼우려면 재고에 이유를 적고 `notePublishedLocalFileTreeRows` 를 지나야 한다.\n",
                .{ path, counts.assigns },
            );
            failed = true;
        }
        // **이름이 아니라 「쓰는가」다** — 대입하는 파일은 그 수만큼 출처 기록을 호출해야 한다.
        if (counts.assigns > counts.notes) {
            std.debug.print(
                "publish axis: {s} 는 `file_tree_rows` 에 {d} 번 대입하는데 `notePublishedLocalFileTreeRows` 호출은 {d} 번이다. 출처 플래그와 재빌드 예약이 빠진 발행은 «행은 로컬인데 펜스는 원격» 을 만든다.\n",
                .{ path, counts.assigns, counts.notes },
            );
            failed = true;
        }
    }
    for (inventory, 0..) |entry, index| {
        if (seen[index]) continue;
        std.debug.print(
            "publish axis: 재고의 {s} 를 스캔이 못 찾았다({s}). 파일이 옮겨졌으면 재고를 갱신하라 — 못 찾은 것을 통과로 읽지 않는다.\n",
            .{ entry.path, entry.why },
        );
        failed = true;
    }
    // 재고가 통째로 비어도 초록이 되지 않게 한다(빈 재고를 못 박는 게이트는 아무것도 안 잡는다).
    try std.testing.expect(total_assigns >= inventory.len);
    try std.testing.expect(!failed);
}
