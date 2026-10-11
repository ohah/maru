//! **원격 감시자의 폴링 다이제스트는 저장소가 정한 필터와 submodule 안을 돌리지 않는다**(계획 workspace-trust WT6b-1b-ii).
//!
//! 감시자는 원격 신뢰와 무관하게 늘 신뢰 전 규칙이다(WT7b — 변화 감지만 한다). 감시자는 5 초마다 `status`·`diff --numstat` 으로 다이제스트를 만드는데, 그 읽기가 저장소 config 의
//! 필터(`filter.<이름>.clean`)를 돌리면 원격에서 저장소가 정한 프로그램이 실행된다. 이 판정자는 **빌드가 만든 실물 감시자**
//! (`MARU_REMOTE_WATCH_BIN` — 호스트 판; macOS 에서는 늘 폴링 갈래다)를 앱이 주는 그 앞머리로 띄워 잰다.
//!
//! 판정은 시계가 아니라 **무엇이 돌았나**로 한다: git 자리에 기록하는 감싸개를 두고, 다이제스트가 `for-each-ref`(필터 읽기 다음
//! 자리)까지 간 것을 본 뒤 감시자의 stdin 을 닫는다(감시자는 EOF 에 끝난다). 그다음 표식 파일과 기록을 본다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const git_command = maru.session.git_command;

fn helperBin() ?[]const u8 {
    if (builtin.os.tag != .macos) return null; // 리눅스 호스트 판은 inotify 갈래라 폴링 다이제스트를 안 돈다
    const raw = std.c.getenv("MARU_REMOTE_WATCH_BIN") orelse return null;
    return std.mem.span(raw);
}

fn sh(gpa: std.mem.Allocator, io: std.Io, script: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/bin/sh", "-c", script, "sh" });
    try argv.appendSlice(gpa, args);
    return std.process.run(gpa, io, .{ .argv = argv.items });
}

fn shOk(gpa: std.mem.Allocator, io: std.Io, script: []const u8, args: []const []const u8) !void {
    const r = try sh(gpa, io, script, args);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    switch (r.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("fixture failed: {s}\n", .{r.stderr});
            return error.FixtureFailed;
        },
        else => return error.FixtureFailed,
    }
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readAlloc(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => err,
    };
}

/// 감시자를 앱이 주는 앞머리(`ssh_upload.watchArgs` 와 같은 모양 — env 덮어쓰기 둘·`git`·굳히기·`status.renames=false`)로 띄우고,
/// 기록에 `until` 이 보이면(다이제스트가 그 읽기까지 갔다) stdin 을 닫아 끝낸다. 상한 30 초 — 넘으면 `until` 이 기록에 없어 호출자의
/// 단언이 실패한다(조용히 통과하지 않는다).
fn runWatcher(gpa: std.mem.Allocator, io: std.Io, bin: []const u8, root: []const u8, git: []const u8, log: []const u8, extra_env: []const []const u8, until: []const u8, launch: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
    }
    try argv.appendSlice(gpa, &.{ log, until });
    try argv.appendSlice(gpa, launch); // 감시자 자신의 env(원격 로그인 셸이 물려주는 것)를 흉내 낼 때 — 보통 비어 있다
    try argv.appendSlice(gpa, &.{ bin, root, "env" });
    for ([_][]const git_command.EnvOverride{ &git_command.env_overrides, &git_command.untrusted_env_overrides }) |list| for (list) |e| {
        const t = try std.fmt.allocPrint(gpa, "{s}={s}", .{ e.name, e.value });
        try owned.append(gpa, t);
        try argv.append(gpa, t);
    };
    try argv.appendSlice(gpa, extra_env);
    try argv.append(gpa, git);
    try argv.appendSlice(gpa, &git_command.config_overrides);
    try argv.appendSlice(gpa, &.{ "-c", "status.renames=false" });
    const script =
        \\log=$1; until=$2; shift 2
        \\i=0
        \\( while ! grep -q -e "$until" "$log" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 300 ] && break; sleep 0.1; done ) | "$@" >/dev/null
    ;
    const r = try sh(gpa, io, script, argv.items);
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    // 파이프의 종료 코드는 감시자의 것이다(마지막 명령). stdin EOF 로 끝나면 0, 스스로 접으면 그 사유 코드.
    return switch (r.term) {
        .exited => |code| code,
        else => 255,
    };
}

test "WT6b-1b-ii 원격 감시자의 다이제스트는 저장소 필터·submodule 안을 안 돌리고(사용자 자신의 드라이버는 돈다), 끌 수 없는 저장소(lfs.extension·옛 git)는 필터 읽기를 건너뛴다 (계획 workspace-trust)" {
    const bin = helperBin() orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir_buf: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&dir_buf, "/tmp/maru-wt6b-watch.{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var real_git_buf: [std.fs.max_path_bytes]u8 = undefined;
    const which = try sh(gpa, io, "command -v git", &.{});
    defer gpa.free(which.stdout);
    defer gpa.free(which.stderr);
    const real_git = try std.fmt.bufPrint(&real_git_buf, "{s}", .{std.mem.trim(u8, which.stdout, " \n")});
    if (real_git.len == 0) return error.SkipZigTest;

    // 픽스처: 저장소 드라이버 `evil`(표식 m_evil), submodule 드라이버 `subf`(m_sub — `submodule.sub.ignore=none` 을 적어도), 사용자의
    // 전역 드라이버 `userf`(m_user — 판정자 파일로 고정한 전역 설정; 이것이 돌면 `status` 가 실제로 돈 것이다). git 자리엔 기록하는
    // 감싸개(`MARU_TEST_OLD_GIT` 면 `--show-scope` 를 거절해 옛 git 을 흉내 낸다).
    try shOk(gpa, io,
        \\set -eu
        \\R=$1; G=$2
        \\rm -rf "$R"; mkdir -p "$R"
        \\cat > "$R/global.cfg" <<EOF
        \\[user]
        \\    name = t
        \\    email = t@t
        \\[filter "userf"]
        \\    clean = touch '$R/m_user'; cat
        \\[protocol "file"]
        \\    allow = always
        \\EOF
        \\export GIT_CONFIG_GLOBAL="$R/global.cfg" GIT_CONFIG_NOSYSTEM=1
        \\cat > "$R/gitw" <<EOF
        \\#!/bin/sh
        \\printf '%s\n' "\$*" >> "\$MARU_TEST_GIT_LOG"
        \\if [ -n "\${MARU_TEST_OLD_GIT:-}" ]; then case "\$*" in *--show-scope*) exit 129;; esac; fi
        \\if [ -n "\${MARU_TEST_CRASH_WT:-}" ]; then case "\$*" in *--worktree*) kill -9 \$\$;; esac; fi
        \\if [ -n "\${MARU_TEST_NO_GIT:-}" ]; then exit 127; fi
        \\if [ -n "\${MARU_TEST_CRASH_SCOPE:-}" ]; then case "\$*" in *--show-scope*) kill -9 \$\$;; esac; fi
        \\exec '$G' "\$@"
        \\EOF
        \\chmod +x "$R/gitw"
        \\git init -q "$R/subsrc"
        \\printf '*.txt filter=subf\n' > "$R/subsrc/.gitattributes"; printf 's\n' > "$R/subsrc/s.txt"
        \\git -C "$R/subsrc" add -A; git -C "$R/subsrc" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm s
        \\git init -q "$R/repo"
        \\printf '*.txt filter=evil\n*.u filter=userf\n*.v filter=envf\n' > "$R/repo/.gitattributes"
        \\printf 'a\n' > "$R/repo/a.txt"; printf 'u\n' > "$R/repo/g.u"; printf 'v\n' > "$R/repo/h.v"
        \\git -C "$R/repo" add -A
        \\git -C "$R/repo" submodule -q add "$R/subsrc" sub
        \\git -C "$R/repo" -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm r
        \\git -C "$R/repo" config filter.evil.clean "touch '$R/m_evil'; cat"
        \\git -C "$R/repo" config submodule.sub.ignore none
        \\git config --file "$R/repo/.git/modules/sub/config" filter.subf.clean "touch '$R/m_sub'; cat"
    , &.{ root, real_git });
    const force =
        \\R=$1; sleep 0.05
        \\printf 'a\n' > "$R/repo/a.txt"; printf 'u\n' > "$R/repo/g.u"; printf 'v\n' > "$R/repo/h.v"; printf 's\n' > "$R/repo/sub/s.txt"
        \\rm -f "$R"/m_* "$R/git.log"
    ;
    var pb: [8][160]u8 = undefined;
    const repo = try std.fmt.bufPrint(&pb[0], "{s}/repo", .{root});
    const gitw = try std.fmt.bufPrint(&pb[1], "{s}/gitw", .{root});
    const log = try std.fmt.bufPrint(&pb[2], "{s}/git.log", .{root});
    const m_evil = try std.fmt.bufPrint(&pb[3], "{s}/m_evil", .{root});
    const m_sub = try std.fmt.bufPrint(&pb[4], "{s}/m_sub", .{root});
    const m_user = try std.fmt.bufPrint(&pb[5], "{s}/m_user", .{root});
    const global_env = try std.fmt.bufPrint(&pb[6], "GIT_CONFIG_GLOBAL={s}/global.cfg", .{root});
    const log_env = try std.fmt.bufPrint(&pb[7], "MARU_TEST_GIT_LOG={s}", .{log});

    // 대조군 — 굳히기 없는 git 이 세 드라이버를 다 돌린다(아니면 이 기계의 git 이 그 길을 안 탄다 — 판정이 헛돈다).
    try shOk(gpa, io, force, &.{root});
    try shOk(gpa, io, "GIT_CONFIG_GLOBAL=\"$1/global.cfg\" GIT_CONFIG_NOSYSTEM=1 git -C \"$1/repo\" status --porcelain >/dev/null", &.{root});
    if (!exists(io, m_evil) or !exists(io, m_sub) or !exists(io, m_user)) return error.SkipZigTest;

    // ⑴ 감시자 — `status` 는 submodule 플래그를 달고 돌고(사용자 드라이버 m_user 가 그 증거), 저장소·submodule 드라이버는 안 돈다.
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 0), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env }, "--cached", &.{}));
    {
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "status --ignore-submodules=dirty") != null);
        // 다섯 읽기 중 작업트리를 읽는 셋이 모두 플래그를 달고 돌았다(마지막 `--cached` 까지 기다렸다 — 적대적 검증 1회차: 첫 읽기만
        // 보고 끊어 `numstat` 쪽 변이가 열에 여덟 살았다).
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "diff --ignore-submodules=dirty --numstat"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "--numstat"));
        try std.testing.expect(std.mem.indexOf(u8, text, "--show-scope") != null);
        try std.testing.expect(exists(io, m_user));
        try std.testing.expect(!exists(io, m_evil));
        try std.testing.expect(!exists(io, m_sub));
    }

    // ⑵ 옛 git(`--show-scope` 거절) — 저장소에 드라이버가 있으니 끌 수 없다: 필터 읽기를 건너뛴다(`status` 가 안 돈다).
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 0), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env, "MARU_TEST_OLD_GIT=1" }, "worktree list", &.{}));
    {
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "--local") != null); // 대체 조회가 돌았다
        try std.testing.expect(std.mem.indexOf(u8, text, "worktree list") != null); // 다이제스트가 끝까지 갔다(죽지 않았다)
        try std.testing.expect(std.mem.indexOf(u8, text, "--numstat") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, " status ") == null);
        try std.testing.expect(!exists(io, m_evil) and !exists(io, m_sub) and !exists(io, m_user));
    }

    // ⑵′ 대체 조회가 128·129 가 아닌 이유(신호)로 죽으면 드라이버가 있는지 **모른다** — 필터 읽기를 돌리지 않고(1회차 실측 — 예전엔
    // 「없음」으로 쳐 필터가 돌았다), 그 다이제스트는 실패다: 첫 주기면 감시자가 사유와 함께 접는다(`unsupported` — 2회차: 「건너뜀」
    // 으로 접으면 git 이 없는 원격도 조용히 반쪽만 감시했다). 드라이버 없는 저장소(submodule 원본)라야 `--worktree` 까지 간다.
    var sub_buf: [160]u8 = undefined;
    const sub_src = try std.fmt.bufPrint(&sub_buf, "{s}/subsrc", .{root});
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 3), try runWatcher(gpa, io, bin, sub_src, gitw, log, &.{ global_env, log_env, "MARU_TEST_OLD_GIT=1", "MARU_TEST_CRASH_WT=1" }, "--worktree", &.{}));
    {
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "--worktree") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "--numstat") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, " status ") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "for-each-ref") == null);
    }
    // ⑵″ 조회와 읽기는 **같은 수**를 본다 — 물려받은 `GIT_CONFIG_COUNT=" 1"` 을 git 은 1 로, 우리는 0 으로 읽는다. 읽기가 덮어쓰기
    // 없이 그 값을 그대로 두면 조회(표지가 0 번을 덮었다)가 못 본 설정을 읽기가 본다(2회차 실측 우회). 드라이버 없는 저장소에서,
    // 물려받은 0 번이 정의하는 드라이버(`subf`)가 조회에도 읽기에도 안 보여야 한다 — 읽기가 늘 우리 `COUNT` 를 실으니까.
    try shOk(gpa, io, force, &.{root});
    {
        var se_buf: [256]u8 = undefined;
        const se_value = try std.fmt.bufPrint(&se_buf, "GIT_CONFIG_VALUE_0=touch '{s}/m_subenv'; cat", .{root});
        try shOk(gpa, io, "printf 's2\n' > \"$1/subsrc/s.txt\"; sleep 0.05; printf 's\n' > \"$1/subsrc/s.txt\"", &.{root});
        try std.testing.expectEqual(@as(u8, 0), try runWatcher(gpa, io, bin, sub_src, gitw, log, &.{ global_env, log_env }, "--cached", &.{ "/usr/bin/env", "GIT_CONFIG_COUNT= 1", "GIT_CONFIG_KEY_0=filter.subf.clean", se_value }));
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        var mse_buf: [160]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, text, "status --ignore-submodules=dirty") != null);
        try std.testing.expect(!exists(io, try std.fmt.bufPrint(&mse_buf, "{s}/m_subenv", .{root})));
    }

    // 주 조회가 신호로 죽음 — 옛 git(129)이 아니니 대체 조회로 받지 않고 「모름」(다이제스트 실패)이다. 대체 조회로 받으면 드라이버가
    // 있는 저장소에서 판정이 ok ↔ refused 로 뒤집혀 변화 없이 `change` 가 나갔다(3회차 실측).
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 3), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env, "MARU_TEST_CRASH_SCOPE=1" }, "--show-scope", &.{}));
    {
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "--local") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, " status ") == null);
    }

    // git 이 없다(127) — 첫 주기에 사유와 함께 접는다(예전 판과 같다; 2회차 실측 회귀).
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 3), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env, "MARU_TEST_NO_GIT=1" }, "config", &.{}));

    // ⑶′ 감시자가 물려받은 `GIT_CONFIG_*`(로그인 셸의 사용자 설정) — 우리 덮어쓰기는 그 **뒤 번호에** 이어, 사용자 자신의 설정은
    // 조회와 읽기가 똑같이 보고(`envf` 정의 — m_env 가 생긴다), 저장소 드라이버와 같은 키는 우리 것이 이긴다(m_inherited 없음).
    // 감시자의 env 로 물려준다(`env` 앞머리 밖 — 원격 로그인 셸이 그렇게 준다).
    try shOk(gpa, io, force, &.{root});
    {
        var inherited_buf: [256]u8 = undefined;
        const inherited_value = try std.fmt.bufPrint(&inherited_buf, "GIT_CONFIG_VALUE_1=touch '{s}/m_inherited'; cat", .{root});
        var env_buf: [256]u8 = undefined;
        const env_value = try std.fmt.bufPrint(&env_buf, "GIT_CONFIG_VALUE_0=touch '{s}/m_env'; cat", .{root});
        try std.testing.expectEqual(@as(u8, 0), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env }, "--cached", &.{ "/usr/bin/env", "GIT_CONFIG_COUNT=2", "GIT_CONFIG_KEY_0=filter.envf.clean", env_value, "GIT_CONFIG_KEY_1=filter.evil.clean", inherited_value }));
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        var mi_buf: [160]u8 = undefined;
        try std.testing.expect(std.mem.indexOf(u8, text, "status --ignore-submodules=dirty") != null);
        try std.testing.expect(!exists(io, try std.fmt.bufPrint(&mi_buf, "{s}/m_inherited", .{root})));
        try std.testing.expect(exists(io, try std.fmt.bufPrint(&mi_buf, "{s}/m_env", .{root})));
        try std.testing.expect(!exists(io, m_evil));
        try std.testing.expect(exists(io, m_user));
    }

    // ⑶ 저장소의 `lfs.extension.*` — 전역 LFS 가 그 명령을 돌리므로 끌 수 없다.
    try shOk(gpa, io, "git -C \"$1/repo\" config lfs.extension.x.clean true", &.{root});
    try shOk(gpa, io, force, &.{root});
    try std.testing.expectEqual(@as(u8, 0), try runWatcher(gpa, io, bin, repo, gitw, log, &.{ global_env, log_env }, "worktree list", &.{}));
    {
        const text = try readAlloc(gpa, io, log);
        defer gpa.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, "worktree list") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "--numstat") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, " status ") == null);
        try std.testing.expect(!exists(io, m_evil) and !exists(io, m_sub) and !exists(io, m_user));
    }
}
