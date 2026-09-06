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
    // RF4: 원격 파일 행은 열기로 간다 — 열기 진입점과 «못 읽는다» 안내가 함께 있어야 한다(§2.5).
    try std.testing.expect(std.mem.indexOf(u8, panel, "openRemoteFileReadOnly(self, v.path, v.supported)") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, ".fp_remote_file_read_failed") != null);
}

test "로컬 root 커밋의 capability 요구는 그대로다 — 갈래는 정확히 둘이어야 한다 (§2.2)" {
    // 원격 갈래가 생기면서 가장 위험한 한 줄은 「원격 root 가 capability 없는 로컬 root 로 커밋되는
    // 것」이다. 로컬 쪽 하드 게이트(`.fp_root_capability_gone`)가 사라지면 그 문이 열린다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);
    try std.testing.expect(std.mem.count(u8, panel, ".fp_root_capability_gone") >= 1);
}

test "감시 채널은 창 당 하나다 — 뷰가 나눠 쓰지, 트리 전용 채널을 새로 만들지 않는다 (RF5a §③)" {
    // ③ 확정의 못이다: 세션 예산(`MaxSessions` 기본 10, pane 당 이미 둘)을 지키는 근거가 「도크는 한
    // 번에 한 뷰라 동시 수요가 없다」이므로, **채널을 새로 띄우는 자리가 늘면 그 근거가 무너진다.**
    // 그래서 `spawnRemoteWatch` 소비처는 정확히 하나여야 한다(감시 펌프).
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 8 * 1024 * 1024);
    defer allocator.free(git);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, git, "spawnRemoteWatch("));
    // 대상 해석이 **뷰로** 갈린다 — 두 주인이 같은 함수를 지난다(따로 만들면 드리프트가 조용히 생긴다).
    try std.testing.expect(std.mem.indexOf(u8, git, "remoteWatchTarget(self)") != null);
    try std.testing.expect(std.mem.indexOf(u8, git, ".explorer =>") != null);
    // 못 서는 원격은 **화면이 말한다**(§2.5) — 주인마다 다른 안내 키.
    try std.testing.expect(std.mem.indexOf(u8, git, ".scm_remote_watch_gave_up") != null);
    try std.testing.expect(std.mem.indexOf(u8, git, ".fp_remote_watch_gave_up") != null);

    // 다른 파일이 감시자를 따로 띄우지 않는다(탐색기는 **설치만** 재사용한다 — RF3a 부터의 규율).
    const still_zero = [_][]const u8{
        "src/platform/macos/app_session/file_panel.zig",
        "src/platform/macos/app_session/scm_dock.zig",
    };
    for (still_zero) |path| {
        const source = try read(allocator, path, 8 * 1024 * 1024);
        defer allocator.free(source);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "spawnRemoteWatch"));
    }
}

test "원격 변경은 로컬 변경 백엔드를 안 탄다 — 문이 하나이고 그 앞에서 갈린다 (RF6b §2.4)" {
    // RF6b 가 이름 변경을 열면서 가장 위험해진 한 줄은 「원격 경로가 로컬 mutation 백엔드로 가는 것」
    // 이다. 그쪽은 휴지통 staging·롤백·에디터 잠금이 **로컬 파일시스템 의미**에 묶여 있어, 같은
    // 철자의 로컬 파일이 대상이 된다. 그래서 ⑴ 갈림은 `enqueueFileTreeEdit` 맨 앞 한 자리이고
    // ⑵ 원격 커밋은 로컬 백엔드 심볼을 **하나도** 안 쓴다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);

    // 갈림이 그 문의 **첫 문장**이어야 한다 — 뒤에 두면 그 앞 배관(예약·잠금)을 이미 지난다.
    const gate = std.mem.indexOf(u8, panel, "if (target.remote) return enqueueRemoteFileTreeRename(self, target, name);") orelse
        return error.TestUnexpectedResult;
    const door = std.mem.indexOf(u8, panel, "pub fn enqueueFileTreeEdit(").?;
    const reserve = std.mem.indexOf(u8, panel, "file_tree_mutation_backend.tryReserve()").?;
    try std.testing.expect(door < gate and gate < reserve);

    // 원격 커밋 본문은 로컬 백엔드를 안 만진다(같은 함수 안에서 섞이면 그 규율이 호출자에게 샌다).
    const body = fnBody(panel, "enqueueRemoteFileTreeRename") orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "file_tree_mutation_backend", "tryReserve", "submitReserved", "file_tree_trash" }) |symbol| {
        try std.testing.expect(std.mem.indexOf(u8, body, symbol) == null);
    }
    // 이름 규칙은 **로컬과 같은 순수 함수**가 소유한다 — 두 벌이면 한쪽만 고쳐진다.
    try std.testing.expect(std.mem.indexOf(u8, body, "file_tree_mutation.validateName(name)") != null);
    // 로컬 타깃의 원격 펜스는 **그대로 서 있다**(RF6b 는 그것을 안 열었다 — 원격은 다른 문이다).
    try std.testing.expect(std.mem.indexOf(u8, panel, "if (self.file_tree_rows_remote) return null;") != null);
}
