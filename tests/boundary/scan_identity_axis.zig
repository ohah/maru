const std = @import("std");
const source_digest = @import("source_digest.zig");

// 이 테스트는 **"디렉터리를 직접 열어 잰 identity"(`fstat` 축)를 만들거나 벗기는 자리가 재고에 적힌
// 곳뿐이다**는 규율을 강제한다(docs/file-explorer.md 가 그 규칙의 단일 출처).
//
// **왜 필요한가.** 같은 경로라도 재는 방법마다 다른 값이 나온다 — 축이 셋이다:
//
//   · `readdir`  디렉터리 순회가 준 inode      → 부모 스캔이 자식 항목에 싣는 값
//   · `lstat`    `fstatat` + `SYMLINK_NOFOLLOW` → 링크 자신, 삭제·이름변경 가드가 쓰는 값
//   · `fstat`    열린 핸들                      → 링크가 가리키는 실체, 스냅샷 검증이 쓰는 값
//
// macOS 에서 셋은 실제로 갈린다. 심링크(`/etc`·`/tmp`·`/var`)는 물론이고 **firmlink**
// (`/Users`·`/private`·`/opt`·`/cores`)에서는 `readdir` 이 주는 합성 inode 가 `lstat` 과도 다르다
// (실측 2026-08-21: `Users` readdir=1152921500312570703 · lstat=14494 · fstat=14494).
//
// 2026-08-21 사용자 보고가 그 결과였다: 탐색기 root 를 `/` 로 열면 스냅샷 검증이 **부모가 준 값**과
// **직접 잰 값**을 견줘 `System` 을 뺀 거의 모든 항목에서 실패했고, 펼칠 때마다 "폴더가 바뀌었으니 다시
// 여세요" 안내가 다시 떠 조작이 막혔다. 재배치가 없어도 어긋나는 비교라 **첫 회부터 거짓 경보**였다.
//
// **타입(`file_tree.ScanIdentity`)이 축을 표시하지만 봉인하지는 못한다.** Zig 는 필드 프라이버시가
// 없어서(접근 제어가 선언 단위이고 구조체 필드는 늘 공개) `.{ .value = 아무거나 }` 를 문법으로 막을 길이
// 없다. 그래서 `cwd_axis.zig` 와 같은 결의 소스 스캔으로 **그 자리의 개수를 고정**한다 — 언어가 못 하는
// 봉인을 게이트가 대신한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   · 재고에 적힌 파일 **안에서** 축을 잘못 쓰는 것은 못 본다(개수만 세므로). 한 자리를 빼고 다른 자리를
//     더하면 총합이 보존돼 통과한다 — `cwd_axis.zig` 가 함수 이름을 박아 막은 그 구멍이 여기 남아 있다.
//     지금은 등장 지점이 파일당 한 자릿수라 이름을 박으면 유지보수 소음이 더 크다고 보고 개수로 둔다.
//   · **축을 벗기는 자리는 못 본다.** `identity.value` 로 풀어 다른 축에 넘기는 코드는 `ScanIdentity`
//     토큰을 안 쓰므로(타입 추론) 이 스캔에 안 걸린다 — 2026-08-21 기준 그런 자리는 root 계열 셋
//     (`app_session/file_panel.zig`)이고 각각 주석으로 이유를 달아 뒀다. 그 셋이 타입을 입으면 이 구멍도
//     같이 닫힌다.
//   · 디렉터리 순회는 **비재귀**다. 재고의 파일이 하위 디렉터리로 옮겨 가면 그 안은 안 본다(지금은 없다).
//   · `readdir`·`lstat` 두 축은 아직 타입이 없다(`file_tree.Identity` 하나를 공유한다). 그 둘이 섞이는
//     것은 이 게이트도, 컴파일러도 못 본다 — root 계열까지 타입을 입히는 일이 남은 범위다.
//   · test 블록은 세지 않는다(`source_digest.topLevelTestTokenMask` 가 그 규칙의 단일 출처다) — 테스트는
//     축을 일부러 만들어 검증하므로 그것까지 세면 재고가 테스트 변경마다 흔들려 규칙이 소음이 된다.

/// 축을 만들거나 벗기는 것이 허용된 파일과 그 이유. **새로 늘리려면 여기에 이유를 적어야 한다** —
/// 그게 이 게이트의 목적이다.
const Entry = struct {
    path: []const u8,
    /// `ScanIdentity` 토큰이 **test 블록 밖에서** 나오는 횟수.
    count: usize,
    why: []const u8,
};

const inventory = [_]Entry{
    .{
        .path = "src/session/file_tree.zig",
        .count = 5,
        .why = "타입 정의와 그 축의 소유자 — 노드 필드·비교·기록·이전 규칙(`Node.inheritIdentityFrom`). 노드를 새로 만드는 네 자리(복제·스냅샷 이전·root 재구성·root 트랜잭션)는 그 함수 **하나**를 지나므로 축이 늘어도 여기만 는다.",
    },
    .{
        .path = "src/platform/macos/file_tree_backend.zig",
        .count = 1,
        .why = "`fstat` 축을 **만드는 유일한 자리** — 디렉터리 스캔과 root 검증이 열린 핸들에서 잰다.",
    },
    .{
        .path = "src/platform/macos/app_session.zig",
        .count = 1,
        .why = "스냅샷 축의 테스트 헬퍼 선언(`testFileTreeScanIdentity`) — 본문은 test 밖 함수다.",
    },
};

const scan_roots = [_][]const u8{
    "src/session",
    "src/platform/macos",
    "src/platform/macos/app_session",
};

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

/// test 블록 밖의 `ScanIdentity` 토큰 수. 마스킹 규칙은 `source_digest` 가 소유한다(두 벌을 만들지 않는다).
fn countOutsideTests(allocator: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const mask = try source_digest.topLevelTestTokenMask(allocator, &tree);
    defer allocator.free(mask);
    var count: usize = 0;
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (mask[token]) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token), "ScanIdentity")) count += 1;
    }
    return count;
}

test "스캔 축: `ScanIdentity` 를 만지는 자리는 재고에 적힌 파일·개수뿐이다" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    for (scan_roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.name }));
        }
    }

    var failed = false;
    var seen: [inventory.len]bool = .{false} ** inventory.len;
    for (paths.items) |path| {
        const source = readZigFileZ(allocator, io, path) catch continue;
        defer allocator.free(source);
        const count = countOutsideTests(allocator, source) catch continue;
        var listed: ?usize = null;
        for (inventory, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) listed = index;
        }
        if (listed) |index| {
            seen[index] = true;
            if (count != inventory[index].count) {
                std.debug.print(
                    "scan-identity axis: {s} 의 `ScanIdentity` 등장이 {d} 개다(재고 {d}). 축을 만지는 자리가 달라졌으면 재고와 이유를 갱신하라.\n",
                    .{ path, count, inventory[index].count },
                );
                failed = true;
            }
        } else if (count != 0) {
            std.debug.print(
                "scan-identity axis: {s} 가 재고 밖에서 `ScanIdentity` 를 {d} 번 만진다. 이 축을 새로 쓰는 이유를 재고에 적어라.\n",
                .{ path, count },
            );
            failed = true;
        }
    }
    for (inventory, 0..) |entry, index| {
        if (seen[index]) continue;
        std.debug.print("scan-identity axis: 재고의 {s} 를 못 찾았다(옮겨졌으면 재고를 갱신하라).\n", .{entry.path});
        failed = true;
    }
    try std.testing.expect(!failed);
}

test "스캔 축 스캐너: test 블록 안의 등장은 세지 않는다" {
    const allocator = std.testing.allocator;
    const fixture =
        \\const file_tree = @import("file_tree.zig");
        \\fn produce() file_tree.ScanIdentity {
        \\    return .{ .value = undefined };
        \\}
        \\test "planting is fine" {
        \\    const a: file_tree.ScanIdentity = .{ .value = undefined };
        \\    const b: file_tree.ScanIdentity = .{ .value = undefined };
        \\    _ = a;
        \\    _ = b;
        \\}
    ;
    // 본문 1 + test 안 2 → test 밖은 1 이다.
    try std.testing.expectEqual(@as(usize, 1), try countOutsideTests(allocator, fixture));
}
