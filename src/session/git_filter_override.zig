//! **신뢰 전 저장소 필터 덮어쓰기**(계획 workspace-trust WT6b-1b) — 순수 계산. 앱의 git 읽기(`git_command`·`git_backend`)와
//! 원격 감시자(`tools/remote-watch` — 원격 신뢰와 무관하게 늘 신뢰 전 규칙)가 **같은 모듈을 문다**: 끌 드라이버를 고르는 규칙이 두 벌이면 한쪽이 낡아
//! 그쪽만 저장소가 정한 프로그램을 돌린다. 그래서 `std` 만 임포트한다(감시자는 원격에 실어 나르는 바이너리다).
//!
//! 흐름: 작업트리를 읽기 전에 한 번 `probe_args` 로 조회하되 표지(`filter_probe_canary`)를 `GIT_CONFIG_*` env 로 함께 싣고, 그
//! 출력으로 `untrustedFilterConfig` 가 덮어쓰기를 만든다. 조회가 실패하면(옛 git — `--show-scope` 는 2.26+) `probe_local_args`·
//! `probe_worktree_args` 출력에 `repoDefinesFilters` 를 묻는다. 끌 수 없으면 그 읽기를 하지 않는다. 덮어쓰기는 `GIT_CONFIG_COUNT`
//! env 로, 그 읽기엔 `ignore_dirty_submodules` 플래그도 단다.

const std = @import("std");
const testing = std.testing;

/// 필터 조회 — 모든 범위를 한 번에(저장소 범위는 include·includeIf 로 끌어온 것도 `local` 로 나온다 — 실측). 아무것도 실행하지
/// 않는 조회다. 일치가 없으면 exit 1(빈 답).
pub const probe_args = [_][]const u8{ "config", "-z", "--show-scope", "--get-regexp", "^(filter\\.|lfs\\.extension\\.|maru\\.wt6bcanary$)" };
/// 옛 git(2.26 미만)의 대체 조회 — 출력이 있으면 그 git 으론 끌 수 없어 읽지 않는다(`repoDefinesFilters`).
pub const probe_local_args = [_][]const u8{ "config", "--local", "--includes", "-z", "--get-regexp", "^(filter|lfs\\.extension)\\." };
/// 위와 같되 워크트리 설정(git 2.20+; 그보다 옛 git 엔 없다 — 실패하면 묻지 않은 것으로 본다).
pub const probe_worktree_args = [_][]const u8{ "config", "--worktree", "--includes", "-z", "--get-regexp", "^(filter|lfs\\.extension)\\." };
/// 작업트리 읽기에 다는 submodule 플래그 — 하위 명령 바로 뒤. config(`diff.ignoreSubmodules`)가 아니라 플래그인 이유: 저장소의
/// `submodule.<n>.ignore=none` 이 config 는 이기고 플래그는 못 이긴다(실측).
pub const ignore_dirty_submodules = "--ignore-submodules=dirty";

/// 신뢰 전 읽기가 한 번에 끌 수 있는 저장소 필터 드라이버의 상한(계획 workspace-trust WT6b-1b — 2026-10-10 사용자 결정: 넘으면
/// 읽지 않고 사유를 보인다). 드라이버마다 `GIT_CONFIG_*` 쌍이 넷이고, 원격은 그 env 를 명령 문자열(`remote_shell.max_command_bytes`
/// 8 KiB)에 싣는다 — 16 이면 이름이 길어도 들어간다. 실제 저장소는 하나둘이다(LFS·git-crypt·nbstripout).
pub const max_filter_drivers = 16;

/// `GIT_CONFIG_KEY_n`/`VALUE_n` 한 쌍.
pub const ConfigPair = struct { key: []const u8, value: []const u8 };

/// 드라이버의 네 변수. 명령 셋(`clean`·`smudge`·`process`)은 빈 값으로 끄고, `required` 는 하나라도 끈 드라이버면 `false` — 빈
/// `clean`·`process` 도 `required=true` 면 git 이 실패로 본다(적대적 검증 1회차 실측: 전역 `required=true` 를 되살리고 `process=""` 를
/// 실었더니 목록 전체가 `fatal: clean filter 'lfs' failed`).
const filter_vars = [_][]const u8{ "clean", "smudge", "process", "required" };

/// 조회(`filter_probe`)에 함께 싣는 표지 — 이 git 이 `GIT_CONFIG_COUNT` 덮어쓰기(git 2.31+)를 읽는지 스스로 확인한다(적대적 검증
/// 1회차: 2.26~2.30 은 `--show-scope` 는 알지만 그 env 는 무시해, 끈 줄 아는 필터가 원격에서 그대로 돈다). 출력의 `command` 범위에
/// 이 키가 없으면 덮어쓰기가 안 먹는 git 이다.
pub const filter_probe_canary: ConfigPair = .{ .key = "maru.wt6bcanary", .value = "1" };

/// 신뢰 전 읽기에 실을 필터 덮어쓰기 — 할당하지 않는다(워커 스레드의 스레드 지역 자리에 산다).
pub const FilterConfig = struct {
    pairs: [max_filter_drivers * filter_vars.len]ConfigPair = undefined,
    len: usize = 0,
    store: [4096]u8 = undefined,
    store_len: usize = 0,

    pub fn slice(self: *const FilterConfig) []const ConfigPair {
        return self.pairs[0..self.len];
    }

    fn keep(self: *FilterConfig, parts: []const []const u8) ?[]const u8 {
        const start = self.store_len;
        for (parts) |p| {
            if (self.store_len + p.len > self.store.len) return null;
            @memcpy(self.store[self.store_len..][0..p.len], p);
            self.store_len += p.len;
        }
        return self.store[start..self.store_len];
    }

    fn push(self: *FilterConfig, name: []const u8, var_name: []const u8, value: []const u8) bool {
        const key = self.keep(&.{ "filter.", name, ".", var_name }) orelse return false;
        // 값은 **늘** 복사한다 — 전역에서 읽은 값은 조회 출력 버퍼를 가리키고, 그 버퍼는 이 덮어쓰기가 쓰이기 전에 풀린다(적대적 검증
        // 2회차: 전역 `required=false` 를 리터럴처럼 아꼈다가 해제된 메모리를 실었다).
        const stored = self.keep(&.{value}) orelse return false;
        self.pairs[self.len] = .{ .key = key, .value = stored };
        self.len += 1;
        return true;
    }
};

/// `filter_probe` 출력(`<범위>\0<키>\n<값>\0` …)으로 신뢰 전 읽기에 실을 덮어쓰기를 `out` 에 채운다(계획 workspace-trust WT6b-1b).
/// **저장소 범위**(`local`·`worktree` — include 로 끌어온 것도 `local`)가 정의한 드라이버마다, 저장소가 정의한 변수만 덮어쓴다:
/// 같은 이름·같은 변수가 전역(`global`)에도 있으면 **전역 값을 다시 넣고**(저장소가 `filter.lfs.*` 를 덮어써도 사용자의 LFS 는
/// 돈다), 없으면 끈다. 하나라도 끈 드라이버는 `required=false`. 같은 키가 여러 번이면 git 처럼 마지막 값. 사용자 자신의 범위
/// (`global`·`command`)는 건드리지 않는다.
///
/// false 면 그 읽기를 하지 않는다(끄지 못한 필터가 도는 일이 없게 — 2026-10-10 사용자 결정):
/// - 저장소 드라이버가 있는데 표지(`filter_probe_canary`)가 없다 — 덮어쓰기가 안 먹는 git.
/// - 저장소 범위에 `lfs.extension.*` 가 있다 — 전역 LFS 의 clean 이 그 명령을 실행한다(적대적 검증 1회차; git-lfs 문서).
/// - 드라이버가 `max_filter_drivers` 를 넘거나 저장 자리를 넘는다.
pub fn untrustedFilterConfig(probe: []const u8, out: *FilterConfig) bool {
    out.* = .{};
    var names: [max_filter_drivers][]const u8 = undefined;
    var name_count: usize = 0;
    var canary = false;
    var it = ConfigEntries{ .rest = probe };
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.scope, "command") and std.mem.eql(u8, e.key, filter_probe_canary.key)) canary = true;
        if (!isRepoScope(e.scope)) continue;
        if (std.mem.startsWith(u8, e.key, "lfs.extension.")) return false;
        const f = filterKey(e.key) orelse continue;
        const seen = for (names[0..name_count]) |n| {
            if (std.mem.eql(u8, n, f.name)) break true;
        } else false;
        if (seen) continue;
        if (name_count == names.len) return false;
        names[name_count] = f.name;
        name_count += 1;
    }
    if (name_count > 0 and !canary) return false;
    for (names[0..name_count]) |name| {
        var emptied = false;
        var repo_required = false;
        for (filter_vars) |v| {
            if (!lastValue(probe, isRepoScope, name, v, null)) continue; // 저장소가 안 정한 변수는 그대로 둔다
            if (std.mem.eql(u8, v, "required")) {
                repo_required = true;
                continue;
            }
            var global: []const u8 = undefined;
            const value = if (lastValue(probe, isGlobalScope, name, v, &global)) global else blk: {
                emptied = true;
                break :blk "";
            };
            if (!out.push(name, v, value)) return false;
        }
        if (emptied or repo_required) {
            var global: []const u8 = undefined;
            const required = if (!emptied and lastValue(probe, isGlobalScope, name, "required", &global)) global else "false";
            if (!out.push(name, "required", required)) return false;
        }
    }
    return true;
}

/// 옛 git(`--show-scope` 를 모른다 — 2.26 미만)의 대체 조회(`filter_probe_local`·`filter_probe_worktree`) 출력 — 저장소 범위에
/// 드라이버나 `lfs.extension.*` 가 하나라도 있나. 있으면 그 git 으론 끌 수 없으니(env 덮어쓰기도 2.31+) 읽지 않는다.
pub fn repoDefinesFilters(probe: []const u8) bool {
    return std.mem.trim(u8, probe, " \t\r\n\x00").len > 0;
}

fn isRepoScope(scope: []const u8) bool {
    return std.mem.eql(u8, scope, "local") or std.mem.eql(u8, scope, "worktree");
}

fn isGlobalScope(scope: []const u8) bool {
    return std.mem.eql(u8, scope, "global");
}

/// 그 범위들에서 `filter.<name>.<var>` 가 있나 — 있으면 마지막 값을 `value` 에(git 처럼 마지막이 이긴다).
fn lastValue(probe: []const u8, comptime inScope: fn ([]const u8) bool, name: []const u8, var_name: []const u8, value: ?*[]const u8) bool {
    var found = false;
    var it = ConfigEntries{ .rest = probe };
    while (it.next()) |e| {
        if (!inScope(e.scope)) continue;
        const f = filterKey(e.key) orelse continue;
        if (!std.mem.eql(u8, f.name, name) or !std.mem.eql(u8, f.var_name, var_name)) continue;
        found = true;
        if (value) |v| v.* = e.value;
    }
    return found;
}

/// `filter.<이름>.<변수>` 를 가른다 — 이름엔 `.`·`=` 가 들 수 있고 **비어 있을 수도 있다**(`[filter ""]` — `.gitattributes` 의
/// `filter=` 가 그 이름을 쓴다; 적대적 검증 1회차 실측). 마지막 `.` 이 변수를 가른다. `filter.<변수>`(점 하나)는 드라이버가 아니다.
fn filterKey(key: []const u8) ?struct { name: []const u8, var_name: []const u8 } {
    if (!std.mem.startsWith(u8, key, "filter.")) return null;
    const body = key["filter.".len..];
    const dot = std.mem.lastIndexOfScalar(u8, body, '.') orelse return null;
    return .{ .name = body[0..dot], .var_name = body[dot + 1 ..] };
}

const ConfigEntries = struct {
    rest: []const u8,
    const Entry = struct { scope: []const u8, key: []const u8, value: []const u8 };
    fn next(self: *ConfigEntries) ?Entry {
        if (self.rest.len == 0) return null;
        const scope_end = std.mem.indexOfScalar(u8, self.rest, 0) orelse return null;
        const scope = self.rest[0..scope_end];
        const after = self.rest[scope_end + 1 ..];
        const kv_end = std.mem.indexOfScalar(u8, after, 0) orelse after.len;
        const kv = after[0..kv_end];
        self.rest = if (kv_end < after.len) after[kv_end + 1 ..] else "";
        const nl = std.mem.indexOfScalar(u8, kv, '\n');
        return .{ .scope = scope, .key = if (nl) |i| kv[0..i] else kv, .value = if (nl) |i| kv[i + 1 ..] else "true" }; // 값 없는 키는 참(git 규약)
    }
};

test "WT6b-1b 저장소 필터 덮어쓰기 — 저장소 범위(local·worktree·include)가 정한 변수만 끄거나 전역 값으로 되살리고, 하나라도 끈 드라이버는 required=false; 빈 이름 드라이버도; 사용자 범위는 안 건드린다 (계획 workspace-trust)" {
    const probe = "global\x00filter.lfs.clean\ngit-lfs clean -- %f\x00" ++
        "global\x00filter.lfs.process\ngit-lfs filter-process\x00" ++
        "global\x00filter.lfs.required\ntrue\x00" ++
        "local\x00filter.evil.clean\ntouch x\x00" ++
        "local\x00filter.lfs.clean\ntouch y\x00" ++ // 전역 이름을 저장소가 덮어쓴다 — 전역 값이 돌아온다
        "local\x00filter.a=b.smudge\ntouch z\x00" ++
        "local\x00filter.dot.ted.clean\ntouch w\x00" ++
        "worktree\x00filter.wt.process\ntouch v\x00" ++
        "local\x00filter.evil.smudge\ntouch u\x00" ++
        "local\x00filter..clean\ntouch e\x00" ++ // `[filter ""]` — `.gitattributes` 의 `filter=` 가 쓴다
        "command\x00filter.mine.clean\nmy-own\x00" ++ // 사용자 자신의 명령줄 설정 — 안 건드린다
        "command\x00maru.wt6bcanary\n1\x00" ++
        "global\x00filter.lfs.clean\ngit-lfs clean --last -- %f\x00"; // 같은 키는 마지막 값
    var cfg: FilterConfig = .{};
    try testing.expect(untrustedFilterConfig(probe, &cfg));
    const Want = struct { []const u8, []const u8 };
    const want = [_]Want{
        .{ "filter.evil.clean", "" },                          .{ "filter.evil.smudge", "" },           .{ "filter.evil.required", "false" },
        .{ "filter.lfs.clean", "git-lfs clean --last -- %f" }, .{ "filter.a=b.smudge", "" },            .{ "filter.a=b.required", "false" },
        .{ "filter.dot.ted.clean", "" },                       .{ "filter.dot.ted.required", "false" }, .{ "filter.wt.process", "" },
        .{ "filter.wt.required", "false" },                    .{ "filter..clean", "" },                .{ "filter..required", "false" },
    };
    const pairs = cfg.slice();
    try testing.expectEqual(want.len, pairs.len);
    for (want, pairs) |w, p| {
        try testing.expectEqualStrings(w[0], p.key);
        try testing.expectEqualStrings(w[1], p.value);
    }
    for (pairs) |p| try testing.expect(std.mem.indexOf(u8, p.key, "mine") == null);
    // 저장소 드라이버가 없으면 빈 덮어쓰기(전역만 있는 정상 LFS 저장소) — 표지가 없어도(옛 git) 읽는다.
    try testing.expect(untrustedFilterConfig("global\x00filter.lfs.clean\ngit-lfs clean -- %f\x00", &cfg));
    try testing.expectEqual(@as(usize, 0), cfg.slice().len);
    try testing.expect(untrustedFilterConfig("", &cfg));
    try testing.expectEqual(@as(usize, 0), cfg.slice().len);
}

test "WT6b-1b 덮어쓰기를 만들지 않는 경우 — 표지 없는 git 의 저장소 드라이버, 저장소의 lfs.extension, 상한·저장 자리 초과; 전역 required 는 끈 것이 없을 때만 되살린다 (계획 workspace-trust)" {
    var cfg: FilterConfig = .{};
    // 표지가 없다 — 이 git 은 `GIT_CONFIG_COUNT` 를 안 읽는다(2.26~2.30). 끌 수 없으니 읽지 않는다.
    try testing.expect(!untrustedFilterConfig("local\x00filter.evil.clean\ntouch x\x00", &cfg));
    // 저장소의 `lfs.extension.*` — 전역 LFS 가 그 명령을 돌린다. 전역의 것은 사용자 것이다.
    try testing.expect(!untrustedFilterConfig("command\x00maru.wt6bcanary\n1\x00local\x00lfs.extension.x.clean\ntouch q\x00", &cfg));
    try testing.expect(untrustedFilterConfig("command\x00maru.wt6bcanary\n1\x00global\x00lfs.extension.x.clean\nmine\x00", &cfg));
    // 전역 `required=true` 를 되살리되, 끈 변수가 있으면 false — 빈 `process` 와 `required=true` 는 목록 전체를 죽인다(실측).
    try testing.expect(untrustedFilterConfig("command\x00maru.wt6bcanary\n1\x00global\x00filter.lfs.clean\ng\x00global\x00filter.lfs.required\ntrue\x00local\x00filter.lfs.process\nevil\x00", &cfg));
    try testing.expectEqual(@as(usize, 2), cfg.slice().len);
    try testing.expectEqualStrings("filter.lfs.process", cfg.slice()[0].key);
    try testing.expectEqualStrings("", cfg.slice()[0].value);
    try testing.expectEqualStrings("false", cfg.slice()[1].value);
    try testing.expect(untrustedFilterConfig("command\x00maru.wt6bcanary\n1\x00global\x00filter.lfs.clean\ng\x00global\x00filter.lfs.required\ntrue\x00local\x00filter.lfs.required\nfalse\x00", &cfg));
    try testing.expectEqual(@as(usize, 1), cfg.slice().len);
    try testing.expectEqualStrings("filter.lfs.required", cfg.slice()[0].key);
    try testing.expectEqualStrings("true", cfg.slice()[0].value);
    // 상한 + 1.
    var probe_buf: [8192]u8 = undefined;
    var n: usize = 0;
    const canary = "command\x00maru.wt6bcanary\n1\x00";
    @memcpy(probe_buf[0..canary.len], canary);
    n = canary.len;
    var i: usize = 0;
    var before_last: usize = 0;
    while (i <= max_filter_drivers) : (i += 1) {
        before_last = n;
        const e = try std.fmt.bufPrint(probe_buf[n..], "local\x00filter.d{d}.clean\ntouch x\x00", .{i});
        n += e.len;
    }
    try testing.expect(!untrustedFilterConfig(probe_buf[0..n], &cfg));
    try testing.expect(untrustedFilterConfig(probe_buf[0..before_last], &cfg)); // 상한까지는 된다
    try testing.expectEqual(@as(usize, max_filter_drivers * 2), cfg.slice().len);
    // 아주 긴 이름(담을 자리 초과).
    var long_buf: [6000]u8 = undefined;
    const head = "command\x00maru.wt6bcanary\n1\x00local\x00filter.";
    @memcpy(long_buf[0..head.len], head);
    @memset(long_buf[head.len..][0..5000], 'n');
    const tail = ".clean\nx\x00";
    @memcpy(long_buf[head.len + 5000 ..][0..tail.len], tail);
    try testing.expect(!untrustedFilterConfig(long_buf[0 .. head.len + 5000 + tail.len], &cfg));
    // 옛 git 대체 조회 — 저장소에 무엇이든 있으면 끌 수 없다.
    try testing.expect(repoDefinesFilters("filter.evil.clean\ntouch x\x00"));
    try testing.expect(!repoDefinesFilters(""));
}
