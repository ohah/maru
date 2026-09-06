//! **원격 파일 트리 안전 게이트**(RF2b — [계획](../docs/plans/remote-file-tree.md) §5).
//!
//! 계약 §2.4: **원격 root 아래 경로는 로컬 syscall 에 절대 안 간다.** 원격 경로를 로컬 파일시스템에
//! 대고 해석하면, 로컬에 우연히 같은 철자가 있을 때 남의 폴더가 원격인 척 뜨고 — 변경 축이 열리는
//! 순간 그 폴더가 **지워진다**. 이 규율을 산문으로 두면 새 소비처가 반드시 새어 나간다는 것이
//! `cwd_axis` 게이트가 생긴 이유이고(전수 조사에서 여섯 곳), 여기는 그 트리판이다.
//!
//! RF1 때 이 게이트를 안 세운 이유가 「빈 재고를 못 박는 게이트는 아무것도 안 잡는다」였다 — 이제
//! 첫 배선(RF2b)이 생겨 잡을 것이 있다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// `fn <이름>` 부터 다음 최상위 `fn ` 직전까지 — 본문을 문자열이 아니라 **구조(들여쓰기 0 의 fn)**로
/// 자른다(「문자열로 구조를 찾지 말라」의 타협점: 이 파일의 최상위 fn 은 컬럼 0 에서 시작한다).
fn fnBody(source: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "fn {s}(", .{name}) catch return null;
    const start = std.mem.indexOf(u8, source, needle) orelse return null;
    var end = start + needle.len;
    while (std.mem.indexOfPos(u8, source, end, "\nfn ")) |next| {
        end = next;
        break;
    } else end = source.len;
    return source[start..end];
}

test "원격 스캔 갈래는 로컬 파일시스템에 닿지 않는다 (§2.4)" {
    const allocator = std.testing.allocator;
    const backend = try read(allocator, "src/platform/macos/file_tree_backend.zig", 2 * 1024 * 1024);
    defer allocator.free(backend);

    // 원격 갈래 둘의 본문에서 로컬 FS 진입 토큰을 센다. **호출 토큰**이다 — 주석의 낱말이 아니라
    // `(` 까지 붙여 세므로 산문이 걸리지 않는다.
    const local_fs_tokens = [_][]const u8{
        ".openDir(",       ".openFile(",   ".statFile(", ".realpath", "std.c.open", "std.c.fstat",
        "std.posix.fstat", ".deleteTree(", ".makePath(", ".iterate(",
    };
    for ([_][]const u8{ "remoteScanDirectory", "remoteResultFromWire" }) |name| {
        const body = fnBody(backend, name) orelse return error.TestUnexpectedResult;
        for (local_fs_tokens) |token| {
            if (std.mem.indexOf(u8, body, token) != null) {
                std.debug.print("원격 갈래 {s} 가 로컬 FS 토큰 {s} 을 문다 — §2.4 위반\n", .{ name, token });
                return error.TestUnexpectedResult;
            }
        }
        // capability(열린 fd)는 국경을 못 넘는다(§2.3) — 원격 갈래가 validated_dir 를 만들면 그것은
        // 「capability 있는 척하는 원격 root」다.
        try std.testing.expect(std.mem.indexOf(u8, body, "validated_dir") == null);
    }
    // 전송은 정확히 하나의 문으로 나간다.
    const scan = fnBody(backend, "remoteScanDirectory").?;
    try std.testing.expect(std.mem.indexOf(u8, scan, "runRemoteCapped") != null);
}

test "원격 submit 의 소비처 재고 — 여는 자리는 정확히 하나다" {
    // `submitRemoteDirectory` 를 부르는 제품 파일의 **전수 재고**다. RF3a 가 열었다: 소비처는
    // `file_panel.zig` 의 원격 펌프 **하나**이고, 그 펌프는 remote_explorer(별도 모델 · §2.1 쌍 ·
    // remoteScmTarget 판정)를 지나는 경로에만 있다. 다른 파일에서 늘면 원격 경로가 그 검증 없이
    // 트리에 들어온 것이다 — 재고를 이유와 함께 올려라.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, panel, ".submitRemoteDirectory("));
    const still_zero = [_][]const u8{
        "src/platform/macos/file_tree_mutation_backend.zig",
        "src/platform/macos/app_session.zig",
    };
    for (still_zero) |path| {
        const source = try read(allocator, path, 8 * 1024 * 1024);
        defer allocator.free(source);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "submitRemoteDirectory"));
    }
}

test "원격 상호작용 펜스가 서 있다 — 열기·변경이 원격 모델 뒤에서 갈린다 (§2.4)" {
    // RF3a 의 펜스: 행 활성화·변경 진입점이 원격 판정 하나(explorerRemoteActive)를 지나고, 원격
    // 파일 열기는 안내 키로 거절된다. 가드가 리팩터로 지워지면 여기서 걸린다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);
    // 키는 «지금 모드» 가 아니라 **발행 출처**다(적대적 검증 2026-09-06 2 회차 — 원격이 내려간 뒤
    // 재빌드 전의 낡은 원격 행이 로컬 갈래로 들어가는 창. 신원 pin 이 실질 방어이고 이 키는 심층
    // 방어인데, 둘 다 있어야 «pin 이 없는 새 행 동작» 이 생겨도 안 샌다).
    try std.testing.expect(std.mem.count(u8, panel, "self.file_tree_rows_remote") >= 3); // 굳힘 + 펜스 둘
    try std.testing.expect(std.mem.indexOf(u8, panel, ".fp_remote_open_unsupported") != null);
}

test "로컬 root 커밋의 capability 요구는 그대로다 — 갈래는 정확히 둘이어야 한다 (§2.2)" {
    // 원격 갈래가 생기면서 가장 위험한 한 줄은 「원격 root 가 capability 없는 로컬 root 로 커밋되는
    // 것」이다. 로컬 쪽 하드 게이트(`.fp_root_capability_gone`)가 사라지면 그 문이 열린다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);
    try std.testing.expect(std.mem.count(u8, panel, ".fp_root_capability_gone") >= 1);
}
