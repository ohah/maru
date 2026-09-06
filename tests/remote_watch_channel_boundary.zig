//! 원격 감시 **채널**(RW3)의 배선 계약([계획](../docs/plans/remote-watch.md) §5·§RW3).
//!
//! ## 왜 소스를 세는가
//!
//! 이 계약들의 값은 **고아를 안 남기는 것**인데, 그것은 동작 test 로 못 본다 — 프로세스를 실제로 띄우고
//! 부모를 죽여야 드러나고, 그 실패는 **남의 서버에 쌓이므로 우리가 영영 모른다.** 실물 검증은 하니스로
//! 하고(계획 §5.1), 여기서는 **그 실물이 기대는 배선**이 지워지지 않게 못 박는다.

const std = @import("std");

fn read(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

/// 줄 주석(`//`)을 벗긴다. **부정 단언은 반드시 이것을 지나야 한다** — 그러지 않으면 「그 함정을
/// 설명하는 주석」이 걸린다. 이 판정자가 실제로 그렇게 한 번 빨갛게 났다(`submitGitRead` 언급).
/// 세야 하는 것은 「언급하는가」가 아니라 **「쓰는가」**다.
fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// 함수 본문을 자른다. **`max` 를 넘으면 실패한다** — 경계가 안 맞으면 슬라이스가 파일 끝까지 달아나고
/// 그러면 needle 이 아무 데서나 걸려 판정자가 통째로 초록이 된다.
fn bodyOf(src: []const u8, head: []const u8, close: []const u8, max: usize) ![]const u8 {
    const at = std.mem.indexOf(u8, src, head) orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at, close) orelse return error.FunctionUnterminated;
    const body = src[at..end];
    if (body.len > max) return error.FunctionBodyRunaway;
    return body;
}

test "조용한 감시자는 stdin 이 «파이프» 여야 한다 — /dev/null 이면 고아가 된다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "src/platform/macos/ssh_upload.zig", 512 * 1024);
    defer allocator.free(src);

    const spawn = try bodyOf(src, "pub fn spawnRemoteWatch(", "\n}\n", 6144);

    // ⚠️ **이 파일의 다른 spawn 은 `/dev/null` 로 막는다** — 그쪽은 «쓰는» 자식이라 EPIPE 로 죽는다.
    // 감시자는 조용해서 EPIPE 를 못 받고, 실측에서 ssh 가 SIGKILL 돼도 살아남았다(계획 §5).
    // 그래서 여기만은 **파이프**여야 하고, 그 차이가 지워지면 고아가 돌아온다.
    try std.testing.expect(std.mem.indexOf(u8, spawn, "/dev/null") == null);
    try std.testing.expect(std.mem.indexOf(u8, spawn, "in_pipe") != null);
    try std.testing.expect(std.mem.indexOf(u8, spawn, "dup2(in_pipe[0], 0)") != null);
    // 부모가 **쓰기 끝을 든다** — 그 fd 의 존재가 「부모가 살아 있다」이고, 닫힘이 EOF 다.
    try std.testing.expect(std.mem.indexOf(u8, spawn, ".in_fd = in_pipe[1]") != null);
    // 읽기는 UI 를 안 멈춘다(에이전트 채널과 같은 규율).
    try std.testing.expect(std.mem.indexOf(u8, spawn, "NONBLOCK") != null);
}

test "채널을 끝낼 때 stdin 을 «먼저» 닫는다 — 그것이 정상 종료 신호다" {
    const allocator = std.testing.allocator;
    const src = try read(allocator, "src/platform/macos/ssh_upload.zig", 512 * 1024);
    defer allocator.free(src);
    const stop = try bodyOf(src, "pub fn stopRemoteWatch(", "\n}\n", 2048);

    const in_at = std.mem.indexOf(u8, stop, "stream.in_fd") orelse return error.NoStdinClose;
    const out_at = std.mem.indexOf(u8, stop, "stream.out_fd") orelse return error.NoStdoutClose;
    const kill_at = std.mem.indexOf(u8, stop, "SIG.TERM") orelse return error.NoSignalFallback;
    // 순서가 곧 뜻이다: EOF 로 스스로 끝내게 하고, `SIGTERM` 은 보루다.
    try std.testing.expect(in_at < out_at);
    try std.testing.expect(out_at < kill_at);
    // ⚠️ `kill(0, …)` 은 **프로세스 그룹 전체**다 — pid 를 검사하지 않으면 GUI 자신과 모든 터미널
    // 자식을 죽인다(에이전트 채널이 같은 자리에 같은 가드를 둔다).
    try std.testing.expect(std.mem.indexOf(u8, stop, "stream.pid <= 0") != null);
}

test "채널 수명은 «호스트가 바뀌는 그 길목» 하나가 진다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);

    // `rememberGitRepoDest` 의 **두 분기 모두**에서 끊는다 — 한쪽만 끊으면 그 전이에서 채널이
    // 저쪽 기계를 계속 보고, 로컬로 돌아온 화면에 저쪽 변화가 트리거로 들어온다.
    const remember = try bodyOf(git, "pub fn rememberGitRepoDest(", "\n}\n", 4096);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, remember, "remote_watch.stop()"));
    // 세션이 끝날 때도 끊는다 — 그러지 않으면 앱을 닫아도 남의 서버에 남는다.
    try std.testing.expect(std.mem.indexOf(u8, app, "self.remote_watch.deinit(self.allocator)") != null);
}

test "감시는 도크가 보일 때만 돌고, 트리거는 기존 읽기 경로를 부른다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 16384);

    // 안 보이는 동안 **남의 서버에 프로세스를 띄워 두지 않는다**(`pumpRepoStatus` 와 같은 게이트).
    try std.testing.expect(std.mem.indexOf(u8, pump, "dock_ops.dockVisible(self)") != null);
    // ⚠️ **그때는 «잠시 멈춤» 이다**(적대적 검증 2026-09-04 1 회차). `stop()` 을 쓰면 `.gave_up` 이
    // 풀려 도크를 껐다 켤 때마다 못 하는 원격에 다시 띄운다 — RW5 가 없앤 폭주가 되살아난다.
    const hidden = try bodyOf(pump, "!dock_ops.dockVisible(self)) {", "\n    }\n", 1024);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "remote_watch.pause()") != null);
    const hidden_code = try stripComments(allocator, hidden);
    defer allocator.free(hidden_code);
    try std.testing.expect(std.mem.indexOf(u8, hidden_code, "remote_watch.stop()") == null);
    // 원격 대상이 없으면 채널이 있을 이유가 없다. **판정이 `remoteWatchTarget` 으로 옮겼다**(RF5a —
    // 채널 하나를 두 뷰가 나눠 쓴다). 펌프는 그 하나를 지나고, 목적지 판정은 그 안에 그대로 있다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "remoteWatchTarget(self) orelse") != null);
    const target_fn = try bodyOf(git, "fn remoteWatchTarget(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, target_fn, "self.git_repo_dest orelse") != null);
    // 두 주인이 **같은 함수**를 지난다 — 따로 만들면 드리프트가 조용히 생긴다(§③ 확정).
    try std.testing.expect(std.mem.indexOf(u8, target_fn, ".source_control =>") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_fn, ".explorer =>") != null);
    // 소켓 판정을 **다시 만들지 않는다** — 있는 함수를 쓴다(두 벌이면 한쪽만 고쳐진다).
    try std.testing.expect(std.mem.indexOf(u8, pump, "remoteControlSocketFor(self, dest") != null);
    // ⚠️ **트리거만 건다.** 여기서 읽기를 직접 조립하면 파싱 계약이 두 벌이 된다(계약 §2).
    // 주인마다 받는 자리가 다르되(RF5a) **둘 다 기존 경로**다 — 새 읽기를 여기서 만들지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "refreshGitStatus(self)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "invalidateRemoteExplorerExpanded(self)") != null);
    // 부정 단언은 **주석을 벗기고** 센다 — 안 그러면 그 함정을 설명하는 주석이 걸린다(실제로 걸렸다).
    const pump_code = try stripComments(allocator, pump);
    defer allocator.free(pump_code);
    try std.testing.expect(std.mem.indexOf(u8, pump_code, "submitGitRead") == null);
    // 즉시 재시도하지 않는다 — 소켓이 죽었으면 초당 수십 개의 ssh 자식이 된다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "retry_at_ns") != null);
    // ⚠️ **영구 실패는 포기한다**(RW5). 「한도를 넘었다」에 계속 재시도하면 도크를 열어 둔 내내
    // 5 초마다 ssh 자식이 뜬다 — 실측 30 초에 7 번. 종료 코드를 **보고** 정해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "stopReporting()") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "isPermanent(why)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, ".gave_up") != null);
    // ⚠️ **감시 루트는 저장소 «루트» 다.** `git_repo` 는 원격에서 **cwd** 라(그것으로 충분한 것은
    // `git -C` 가 상위를 찾기 때문), 그걸 감시하면 하위 디렉터리에 서 있을 때 바깥 변경을 놓친다 —
    // 실측에서 저장소 루트의 변경이 **0 개**의 읽기를 불렀다(적대적 검증 1 회차).
    // ⚠️ **이 이른 반환도 자식을 놓고 나간다**(적대적 검증 2026-09-04 3 회차). 루트만 비우고 호스트는
    // 그대로인 전이에서 감시자가 옛 저장소를 계속 보고, 아무도 드레인하지 않아 파이프가 차면 저쪽이
    // write 에 걸려 선다.
    // 루트 판정도 `remoteWatchTarget` 안에 있다(RF5a) — SCM 은 저장소 루트, 탐색기는 원격 트리 루트.
    try std.testing.expect(std.mem.indexOf(u8, target_fn, "self.git_repo_remote_root orelse") != null);
    try std.testing.expect(std.mem.indexOf(u8, target_fn, "re.root.items") != null);
    // 대상이 없으면 **놓아주는 것이 아니라 멈춘다** — `stop` 이 지우는 설치 답·`.gave_up` 은 호스트의
    // 성질이라 화면이 바뀌었다고 버릴 값이 아니다(호스트 전이는 `rememberGitRepoDest` 가 잡는다).
    const no_target = try bodyOf(pump, "remoteWatchTarget(self) orelse {", "\n    };", 512);
    try std.testing.expect(std.mem.indexOf(u8, no_target, "remote_watch.pause()") != null);

    // ⚠️ **같은 호스트에서 저장소만 바뀌는 전환**(적대적 검증 2026-09-04 6 회차). `git_repo_dest` 가
    // 그대로라 `rememberGitRepoDest` 는 조기 반환한다 — 채널이 무엇을 보고 있는지 스스로 알아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "self.remote_watch.watchedRoot(), repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "self.remote_watch.rememberRoot(repo)") != null);
    // ⚠️ **추적할 수 없는 루트는 아예 안 띄운다**(7 회차). 띄워 놓고 무엇을 보는지 모르면 전환 판정이
    // 영영 안 걸리고(옛 감시자가 조용히 남는다), 그렇다고 매 tick 「달라졌다」로 읽으면 재기동 폭주다.
    // 이 게이트가 있어야 `started` 가 곧 「기억이 있다」가 된다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "remote_watch_mod.canTrack(repo)") != null);
    const can_at = std.mem.indexOf(u8, pump, "remote_watch_mod.canTrack(repo)").?;
    const spawn_at = std.mem.indexOf(u8, pump, "ssh_upload.spawnRemoteWatch(").?;
    try std.testing.expect(can_at < spawn_at);
    // ⚠️ **전환 판정은 「기억이 있는가」로 묻는다**(8 회차). `started` 로 물으면 `.gave_up`·`.backoff`
    // 채널(둘 다 `started == false`)이 전환을 영영 못 본다 — A 에서 포기하고 B 로 옮기면 B 가 영원히
    // 감시되지 않는다.
    const pump_code2 = try stripComments(allocator, pump);
    defer allocator.free(pump_code2);
    try std.testing.expect(std.mem.indexOf(u8, pump_code2, "remote_watch.root_len != 0 and") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump_code2, "remote_watch.started and !std.mem.eql") == null);
    // ⚠️ **저장소 전환은 `stop` 이 아니라 `switchRoot` 다**(13 회차). 감시자는 **호스트마다** 심기므로
    // 저장소가 바뀐다고 저쪽 파일이 사라지지 않는다 — `stop` 을 쓰면 옮길 때마다 `uname` + `check`
    // 두 왕복을 남의 서버에 다시 묻는다.
    const swap = try bodyOf(pump, "self.remote_watch.watchedRoot(), repo)) {", "\n    }", 1024);
    try std.testing.expect(std.mem.indexOf(u8, swap, "remote_watch.switchRoot()") != null);
    const swap_code = try stripComments(allocator, swap);
    defer allocator.free(swap_code);
    try std.testing.expect(std.mem.indexOf(u8, swap_code, "remote_watch.stop()") == null);
    // **switch 보다 «먼저» 본다** — 뒤에 두면 `.gave_up` 이 곧장 return 해 전환을 영영 못 본다.
    const switch_at = std.mem.indexOf(u8, pump, "switch (self.remote_watch.phase)").?;
    const swap_at = std.mem.indexOf(u8, pump, "self.remote_watch.watchedRoot(), repo").?;
    try std.testing.expect(swap_at < switch_at);
    try std.testing.expect(std.mem.indexOf(u8, pump_code, "self.git_repo orelse return") == null);
}

test "포기했으면 «화면이» 말한다 — 로그는 사용자가 안 본다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 16384);

    // RW5 가 「다시 안 띄운다」를 세웠지만, 그것만으로는 화면이 **조용히** 낡는다 — 사용자에게는
    // 「어느 순간부터 도크가 안 바뀐다」로만 보이고 저장소가 안 바뀐 것으로 읽힌다.
    // **주인마다 문구가 다르다**(RF5a) — 사용자가 다음에 할 일이 다르기 때문이다. 선택자 하나가
    // 그 갈래를 소유하고, 두 키가 다 살아 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "showNoticeKey(watchGaveUpNoticeKey(target.owner))") != null);
    const notice_fn = try bodyOf(git, "fn watchGaveUpNoticeKey(", "\n}\n", 1024);
    try std.testing.expect(std.mem.indexOf(u8, notice_fn, ".scm_remote_watch_gave_up") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice_fn, ".fp_remote_watch_gave_up") != null);

    // ⚠️ **영구 실패에서만 말한다.** 일시적 끊김(슬립·네트워크)에도 띄우면 배너가 잔소리가 되고,
    // 그러면 사용자가 배너 자체를 무시하게 된다 — 정작 영구 실패일 때 안 읽힌다.
    const permanent = try bodyOf(pump, "if (remote_watch_mod.isPermanent(why)) {", "\n        } else {", 4096);
    try std.testing.expect(std.mem.indexOf(u8, permanent, "showNoticeKey(watchGaveUpNoticeKey(target.owner))") != null);
    const transient = try bodyOf(pump, "\n        } else {", "\n        }\n", 4096);
    const transient_code = try stripComments(allocator, transient);
    defer allocator.free(transient_code);
    // ⚠️ **부정 단언은 슬라이스가 비면 공허하게 통과한다**(적대적 검증 2026-09-04 1 회차 — 내 판정자를
    // 내가 공격했다). 그 갈래를 실제로 잡았는지 먼저 못 박는다.
    try std.testing.expect(std.mem.indexOf(u8, transient_code, ".backoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, transient_code, "retry_at_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, transient_code, "showNoticeKey") == null);

    // 문구는 **두 로케일 다** 있어야 한다 — 한쪽만 넣으면 다른 쪽에서 컴파일은 되는데 빈 화면이 된다.
    const i18n = try read(allocator, "src/i18n.zig", 8 * 1024 * 1024);
    defer allocator.free(i18n);
    try std.testing.expect(std.mem.indexOf(u8, i18n, "scm_remote_watch_gave_up: [:0]const u8,") != null);
    var locales: usize = 0;
    var it = std.mem.splitSequence(u8, i18n, ".scm_remote_watch_gave_up = \"");
    _ = it.next();
    while (it.next()) |_| locales += 1;
    try std.testing.expectEqual(@as(usize, 2), locales);
}

test "감시자는 PATH 처방과 «같은» 굳히기 목록을 받는다" {
    const allocator = std.testing.allocator;
    const up = try read(allocator, "src/platform/macos/ssh_upload.zig", 1024 * 1024);
    defer allocator.free(up);

    // ⚠️ **PATH 처방을 지난다**(RW7a). 감시자 자체는 절대 경로로 부르지만 폴링 갈래가 저쪽에서
    // `git` 을 찾아야 한다 — 비대화형 ssh 의 PATH 는 `/usr/bin:/bin:…` 뿐이라 Homebrew git 이 안 보인다.
    const script = try bodyOf(up, "const watch_script = ", ";\n", 512);
    try std.testing.expect(std.mem.indexOf(u8, script, "remote_shell.path_assign") != null);
    // 인자가 여럿이다 — 루트 하나만 넘기던 `"$1"` 로는 앞머리를 못 싣는다.
    try std.testing.expect(std.mem.indexOf(u8, script, "$@") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$1") == null);

    // ⚠️ **굳히기 목록을 두 벌로 두지 않는다**(RW7b). 감시자가 저쪽에서 git 을 돌리는데 그 목록이
    // 갈리면 «감시자만» 문이 열린 채 돈다. 앱이 L2 의 단일 출처를 그대로 실어 보내야 한다.
    const spawn = try bodyOf(up, "pub fn spawnRemoteWatch(", "\n}\n", 4096);
    try std.testing.expect(std.mem.indexOf(u8, spawn, "git_command.config_overrides") != null);
    const spawn_code = try stripComments(allocator, spawn);
    defer allocator.free(spawn_code);
    // 목록을 손으로 다시 적지 않는다 — 적었다면 그 문자열이 여기 보인다.
    try std.testing.expect(std.mem.indexOf(u8, spawn_code, "core.hooksPath") == null);
}

test "설치 계약이 «죽은 계약» 이 아니다 — 제품이 실제로 심는다" {
    const allocator = std.testing.allocator;
    const app = try read(allocator, "src/platform/macos/app_session.zig", 8 * 1024 * 1024);
    defer allocator.free(app);
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);

    // ⚠️ **이 판정자가 있는 이유.** RW2a 가 계약을, RW2b 가 페이로드를 만들어 두고도 **아무도 실행하지
    // 않았다** — 번들에 네 변종을 싣고 설치 스크립트를 짜 두고, 감시자는 「사람이 손으로 넣은 원격」
    // 에서만 돌았다. 컴파일러는 그것을 못 잡는다(쓰이지 않는 `pub` 는 오류가 아니다).
    for ([_][]const u8{
        "variantFromUname", // 원격이 무엇인지 가른다
        "assetRelPath", //     번들의 어느 파일인지 가른다
        "check_script", //     이미 있고 «우리 판» 인지 «실행해» 본다
        "install_script", //   없으면 심는다
    }) |symbol| {
        var found = false;
        for ([_][]const u8{ app, git }) |src| {
            if (std.mem.indexOf(u8, src, symbol) != null) found = true;
        }
        if (!found) {
            std.debug.print("설치 계약이 제품에서 안 쓰인다: {s}\n", .{symbol});
            return error.TestUnexpectedResult;
        }
    }

    // 띄우기 **전에** 본다 — 뒤에 두면 없는 파일을 `exec` 하고 그 실패를 「일시적」으로 읽어
    // 5 초마다 되풀이한다(증상은 「그냥 안 된다」).
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 16384);
    const install_at = std.mem.indexOf(u8, pump, "self.remote_watch.install").?;
    const spawn_at = std.mem.indexOf(u8, pump, "ssh_upload.spawnRemoteWatch(").?;
    try std.testing.expect(install_at < spawn_at);
    // 확인·심기는 **스레드**가 진다 — ssh 왕복을 틱에서 하면 화면이 선다(업로드와 같은 규율).
    try std.testing.expect(std.mem.indexOf(u8, app, "std.Thread.spawn(.{}, watchInstallWorker") != null);
    // 도는 중에는 **또 시작하지 않는다.**
    try std.testing.expect(std.mem.indexOf(u8, pump, ".running => return") != null);
    // deinit 이 그 스레드를 기다린다 — 안 기다리면 detach 스레드가 해제된 self 를 만진다.
    try std.testing.expect(std.mem.indexOf(u8, app, "self.watch_install_inflight;") != null);

    const begin = try bodyOf(app, "pub fn beginWatchInstall(", "\n    }\n", 4096);
    // ⚠️ **소유본을 «먼저» 만든다**(적대적 검증 2026-09-05 1 회차). 구조체 리터럴 «안»에서 실패
    // 경로가 `job.ctl` 을 free 하던 판이 있었는데, 그때 `job.*` 은 대입 전이라 `create` 가 준
    // **미초기화 메모리**를 free 했다.
    try std.testing.expect(std.mem.indexOf(u8, begin, ".ctl = ctl_owned") != null);
    try std.testing.expect(std.mem.indexOf(u8, begin, ".dest = dest_owned") != null);
    const begin_code = try stripComments(allocator, begin);
    defer allocator.free(begin_code);
    // ⚠️ 처음엔 `free(job.ctl)` 을 **아예** 금지했는데 **너무 넓었다** — `job.*` 대입 «뒤» 의 정리
    // 경로가 그것을 free 하는 것은 옳다. 지켜야 하는 것은 「대입 «전» 에 만지지 않는다」이고, 위
    // 두 단언(`.ctl = ctl_owned`)이 그것을 보장한다.
    //
    // `void` 함수의 `errdefer` 는 **절대 안 돈다** — 보호하는 척만 하므로 두지 않는다(2 회차).
    try std.testing.expect(std.mem.indexOf(u8, begin_code, "errdefer") == null);
    // ⚠️ **늦게 온 답은 버린다**(2 회차). `stop` 이 세대를 올리고, 수확이 그것을 대조한다.
    try std.testing.expect(std.mem.indexOf(u8, begin, ".gen = self.remote_watch.install_gen") != null);
    const drain = try bodyOf(app, "pub fn drainWatchInstall(", "\n    }\n", 2048);
    try std.testing.expect(std.mem.indexOf(u8, drain, "r.gen == self.remote_watch.install_gen") != null);
    // ⚠️ **버릴 때 «되물어본다»**(4 회차). 옛 스레드가 새 스레드보다 늦게 끝나면 낡은 답이 슬롯에
    // 남는데, 버리기만 하면 `install` 이 `.running` 인 채로 굳어 그 호스트가 세션 내내 막힌다.
    try std.testing.expect(std.mem.indexOf(u8, drain, "self.remote_watch.install = .unknown") != null);

    // ⚠️ **영영 못 심는 원격은 포기한다**(6 회차). 모르는 `uname` 이나 번들에 없는 변종은 다시 물어도
    // 답이 같은데, 그때마다 왕복 + 번들 읽기 + 스레드가 든다 — RW5 가 감시자에서 없앤 폭주다.
    try std.testing.expect(std.mem.indexOf(u8, pump, ".unsupported => {") != null);
    const unsup = try bodyOf(pump, ".unsupported => {", "\n            },", 1024);
    try std.testing.expect(std.mem.indexOf(u8, unsup, "phase = .gave_up") != null);
    // 포기했으면 **화면이 말한다**(RW6 과 같은 규율).
    try std.testing.expect(std.mem.indexOf(u8, unsup, "showNoticeKey(watchGaveUpNoticeKey(target.owner))") != null);
    // ⚠️ **틱에서는 ssh 를 «안» 부른다**(8 회차). `runRemoteScript` 에 마감이 없어, 틱에서 부르면
    // 원격이 멈출 때 **UI 가 통째로 선다**(실측: 정상 왕복도 로컬호스트에서 10 ms).
    const begin2 = try bodyOf(app, "pub fn beginWatchInstall(", "\n    }\n", 4096);
    const begin2_code = try stripComments(allocator, begin2);
    defer allocator.free(begin2_code);
    try std.testing.expect(std.mem.indexOf(u8, begin2_code, "runRemoteScript") == null);
    try std.testing.expect(std.mem.indexOf(u8, begin2_code, "uname") == null);
    // 그 왕복은 **스레드**가 진다.
    const worker = try bodyOf(app, "fn watchInstallWorker(", "\n    }\n", 8192);
    try std.testing.expect(std.mem.indexOf(u8, worker, "uname -sm") != null);
    try std.testing.expect(std.mem.indexOf(u8, worker, "variantFromUname") != null);
    // 그리고 «번들 읽기» 도 스레드다 — 그래야 io 를 안 만진다(`uploadWorker` 의 전제).
    try std.testing.expect(std.mem.indexOf(u8, worker, "readFileNoIo") != null);
    // 영구/일시 실패의 갈림도 스레드가 진다.
    try std.testing.expect(std.mem.indexOf(u8, worker, "outcome = .unsupported") != null);

    // ⚠️ **파이프에 쓰다 상대가 먼저 닫아도 죽지 않는다**(5 회차 — 실측: 기본 처분이면 종료 141).
    const upload = try read(allocator, "src/platform/macos/ssh_upload.zig", 1024 * 1024);
    defer allocator.free(upload);
    const wall = try bodyOf(upload, "fn writeAllFd(", "\n}\n", 1024);
    try std.testing.expect(std.mem.indexOf(u8, wall, "silenceSigpipe(fd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, upload, "F_SETNOSIGPIPE") != null);
}
