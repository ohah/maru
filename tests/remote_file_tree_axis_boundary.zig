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
    const after = start + needle.len;
    // ⚠️ **둘 다 본다**(`\nfn ` 와 `\npub fn `). 예전에는 `\nfn ` 만 봐서, 뒤따르는 것이 전부 `pub fn`
    // 이면 본문이 **다음 함수들까지 삼켰다** — 그러면 「이 본문에 X 가 없다」 같은 부정 단언이
    // 남의 코드를 보고 죽는다(RF6c 에서 실제로 그렇게 걸렸다).
    var end = source.len;
    if (std.mem.indexOfPos(u8, source, after, "\nfn ")) |next| end = @min(end, next);
    if (std.mem.indexOfPos(u8, source, after, "\npub fn ")) |next| end = @min(end, next);
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

test "원격 만들기도 같은 문을 지나고 부모 신원을 짝지어 보낸다 (RF6d)" {
    // 만들기가 로컬 백엔드로 새면 §2.4 가 깨진다 — 갈림은 이름 변경과 **같은 한 자리**여야 한다.
    // 그리고 부모 신원 짝짓기는 **순수 함수 하나**가 소유해야 한다: 짝이 어긋나면 저쪽 재확인이
    // 항상 stale 이 되어 만들기가 조용히 안 되고, 화면에는 「트리가 낡았다」로만 보인다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);

    // 원격 커밋이 만들기를 **같은 자리에서** 갈라 받는다(문이 둘이 되면 규율이 호출자에게 샌다).
    const commit = fnBody(panel, "enqueueRemoteFileTreeRename") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, commit, "enqueueRemoteFileTreeCreate(self, target, name)") != null);

    // 만들기 본문도 로컬 백엔드를 안 만진다.
    const create = fnBody(panel, "enqueueRemoteFileTreeCreate") orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "file_tree_mutation_backend", "tryReserve", "file_tree_trash" }) |symbol| {
        try std.testing.expect(std.mem.indexOf(u8, create, symbol) == null);
    }
    // 이름 규칙은 공용 순수 함수, 짝짓기는 순수 함수 하나가 소유한다.
    try std.testing.expect(std.mem.indexOf(u8, create, "file_tree_mutation.validateName(name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "remoteCreateContainer(target)") != null);

    // 그 순수 함수가 파일 행에서 **부모** 신원을 고른다(자기 신원이 아니다).
    const container = fnBody(panel, "remoteCreateContainer") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, container, ".identity = target.parent_identity") != null);
}

test "원격 삭제는 확인을 거치고 로컬 휴지통을 안 탄다 (RF6c ④=㉰)" {
    // ④ 사용자 결정: 원격에는 휴지통이 없어 **되돌릴 수 없다**. 그래서 ⑴ 요청은 확인 모달만 세우고
    // ⑵ 실제 삭제는 확인 뒤에만 일어나며 ⑶ 로컬 휴지통 배관(staging·Trash·복구)을 안 탄다.
    // 이 셋 중 하나라도 무너지면 «묻지 않고 남의 서버에서 지우는» 상태가 된다.
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);

    // 요청 본문: 확인만 세운다 — 워커를 직접 시작하지 않는다.
    const ask = fnBody(panel, "requestDeleteSelectedRemoteFileTreeEntry") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ask, "showConfirmKeys(.remote_file_tree_delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask, "beginRemoteRename(") == null);
    // 되돌릴 수 없다는 것을 **문구와 버튼이** 말한다(§2.3 ⑷ — 차이를 숨기지 않는다).
    try std.testing.expect(std.mem.indexOf(u8, ask, ".fp_remote_delete_confirm") != null);
    try std.testing.expect(std.mem.indexOf(u8, ask, ".btn_delete_forever") != null);

    // 확인 본문: 굳혀 둔 대상으로만 지운다(확인을 누르는 사이 선택이 움직여도 그것을 지운다).
    const confirm = fnBody(panel, "confirmRemoteFileTreeDelete") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, confirm, "pending_remote_delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, confirm, "beginRemoteRename(") != null);

    // 로컬 휴지통 배관은 어느 쪽도 안 탄다.
    for ([_][]const u8{ ask, confirm }) |body| {
        for ([_][]const u8{ "file_tree_trash", "maru-trash", "pending_file_tree_delete" }) |symbol| {
            try std.testing.expect(std.mem.indexOf(u8, body, symbol) == null);
        }
    }

    // 로컬 삭제 진입점이 **원격을 먼저 가른다** — 안 그러면 원격 행이 휴지통 staging 으로 간다.
    const local = fnBody(panel, "requestDeleteSelectedFileTreeEntry") orelse return error.TestUnexpectedResult;
    const gate = std.mem.indexOf(u8, local, "if (self.file_tree_rows_remote) return requestDeleteSelectedRemoteFileTreeEntry(self);") orelse
        return error.TestUnexpectedResult;
    const busy = std.mem.indexOf(u8, local, "fileTreeNamespaceMutationBusy(self)").?;
    try std.testing.expect(gate < busy);
}

test "Term 파일 entry 해제 목록은 한 벌이다 (RF6e)" {
    // 이 게이트가 있는 이유: `destroyTerm` 과 `AppSession.deinit` 이 같은 목록을 **각자** 들고 있었고,
    // 주석이 「동기 유지」를 부탁했지만 사람 기억은 두 번 놓쳤다(N1 편집기 문서 · RF6e 원격 출처).
    // 누수는 `...FAIL` 로 안 찍혀 눈에 안 띈다 — 그래서 「목록이 한 벌인가」를 구조로 센다.
    const allocator = std.testing.allocator;
    const term_src = try read(allocator, "src/platform/macos/app_session/term.zig", 8 * 1024 * 1024);
    defer allocator.free(term_src);
    const app_src = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app_src);

    // 해제 목록을 아는 자리는 **그 함수 하나**다.
    const release = fnBody(term_src, "releaseTermFileEntry") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, release, "entry.remote_origin_dest") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "entry.remote_origin_label") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "freeDiffEntryState(entry)") != null);

    // 그리고 **그 밖에서 entry 를 손으로 파괴하지 않는다** — 두 벌이 되는 순간 한쪽이 낡는다.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, term_src, "self.allocator.destroy(entry);"));
    // ⚠️ **파괴로 좁혀 센다.** 「`term.file_entry` 를 캡처하는 자리」로 세면 읽기용 접근까지 걸려
    //    게이트가 거짓 경보를 낸다(실측으로 그렇게 걸렸다) — 문제는 **푸는 목록이 두 벌인 것**이다.
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, app_src, "self.allocator.destroy(entry);"));
    try std.testing.expect(std.mem.indexOf(u8, app_src, "term_ops.releaseTermFileEntry(self, term)") != null);
}

test "적대적 검증 5 회차의 못 — 정리·스탬프·목적지 (RF6 후속)" {
    const allocator = std.testing.allocator;
    const panel = try read(allocator, "src/platform/macos/app_session/file_panel.zig", 8 * 1024 * 1024);
    defer allocator.free(panel);

    // ① 정리는 **순회하면서 지우지 않는다**. readdir 는 순회 중 삭제 뒤 동작이 불명확해 항목을
    //    건너뛸 수 있고, 그러면 오래된 파일이 남아 캐시가 계속 자란다(조용한 부분 실패).
    const prune = fnBody(panel, "pruneRemoteMirror") orelse return error.TestUnexpectedResult;
    const collect_at = std.mem.indexOf(u8, prune, "buckets.append(") orelse return error.TestUnexpectedResult;
    const del_dir_at = std.mem.indexOf(u8, prune, "root.deleteDir(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(collect_at < del_dir_at); // 모으고 → 지운다
    // 파일도 같은 규율: 이름을 모았다가 순회 **뒤에** 지운다.
    try std.testing.expect(std.mem.indexOf(u8, prune, "stale.append(") != null);
    // ③ tick 비용이 유계다 — 간격과 개수 상한 둘 다.
    try std.testing.expect(std.mem.indexOf(u8, prune, "mirror_prune_interval_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, prune, "max_mirror_prune_buckets") != null);

    // ② 스탬프는 **방금 연 그것**에만 붙는다(「미러인가」로만 물으면 직전 문서를 오염시킨다).
    const stamp = fnBody(panel, "stampRemoteOrigin") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, stamp, "std.mem.eql(u8, entry.path, mirror_path)") != null);

    // ⑤ 변경은 목적지를 **요청할 때 박는다** — 워커 시작 함수가 세션에서 직접 안 읽는다.
    const begin = fnBody(panel, "beginRemoteRename") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, begin, "endpoint.dest()") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin, "endpoint.ctl()") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin, "remote_explorer.dest") == null);
    try std.testing.expect(std.mem.indexOf(u8, begin, "re.ctl.items") == null);
    // 삭제는 **물을 때** 박는다(확인 모달 사이가 가장 넓은 창이다).
    const ask = fnBody(panel, "requestDeleteSelectedRemoteFileTreeEntry") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, ask, "pinRemoteEndpoint(self)") != null);
}
