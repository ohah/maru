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
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 8192);

    // 안 보이는 동안 **남의 서버에 프로세스를 띄워 두지 않는다**(`pumpRepoStatus` 와 같은 게이트).
    try std.testing.expect(std.mem.indexOf(u8, pump, "dock_ops.dockVisible(self)") != null);
    // 로컬 목록이면 채널이 있을 이유가 없다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "self.git_repo_dest orelse") != null);
    // 소켓 판정을 **다시 만들지 않는다** — 있는 함수를 쓴다(두 벌이면 한쪽만 고쳐진다).
    try std.testing.expect(std.mem.indexOf(u8, pump, "remoteControlSocketFor(self, dest") != null);
    // ⚠️ **트리거만 건다.** 여기서 읽기를 직접 조립하면 파싱 계약이 두 벌이 된다(계약 §2).
    try std.testing.expect(std.mem.indexOf(u8, pump, "refreshGitStatus(self)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, pump, "self.git_repo_remote_root orelse return") != null);
    try std.testing.expect(std.mem.indexOf(u8, pump_code, "self.git_repo orelse return") == null);
}

test "포기했으면 «화면이» 말한다 — 로그는 사용자가 안 본다" {
    const allocator = std.testing.allocator;
    const git = try read(allocator, "src/platform/macos/app_session/git.zig", 4 * 1024 * 1024);
    defer allocator.free(git);
    const pump = try bodyOf(git, "pub fn pumpRemoteWatch(", "\n}\n", 8192);

    // RW5 가 「다시 안 띄운다」를 세웠지만, 그것만으로는 화면이 **조용히** 낡는다 — 사용자에게는
    // 「어느 순간부터 도크가 안 바뀐다」로만 보이고 저장소가 안 바뀐 것으로 읽힌다.
    try std.testing.expect(std.mem.indexOf(u8, pump, "showNoticeKey(.scm_remote_watch_gave_up)") != null);

    // ⚠️ **영구 실패에서만 말한다.** 일시적 끊김(슬립·네트워크)에도 띄우면 배너가 잔소리가 되고,
    // 그러면 사용자가 배너 자체를 무시하게 된다 — 정작 영구 실패일 때 안 읽힌다.
    const permanent = try bodyOf(pump, "if (remote_watch_mod.isPermanent(why)) {", "\n        } else {", 4096);
    try std.testing.expect(std.mem.indexOf(u8, permanent, "showNoticeKey(.scm_remote_watch_gave_up)") != null);
    const transient = try bodyOf(pump, "\n        } else {", "\n        }\n", 4096);
    const transient_code = try stripComments(allocator, transient);
    defer allocator.free(transient_code);
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
