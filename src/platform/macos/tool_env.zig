//! 언어 서버의 도구 환경(계획 docs/plans/workspace-trust.md WT3b — 계약 docs/editor-surface-tooling.md §8.1 「서버 환경은 사용자 셸
//! 환경」). 사용자의 로그인 셸을 한 번 띄워 그 환경을 담고(`session/lsp/shell_env.zig` 의 순수 계산), 서버 찾기·띄우기가 그것을 쓴다.
//!
//! **앱 전체에 하나다** — 환경은 사용자의 것이지 창의 것이 아니다(창마다 셸을 띄우지 않는다). 메인 스레드가 시작·결과 받기를 하고,
//! 셸을 띄우고 기다리는 일은 detach 된 워커 스레드가 한다(서버 띄우기가 메인 tick 안이라 셸을 기다리면 앱이 선다). 결과는 **세대**가
//! 붙어 잠금 슬롯으로 넘어온다 — 다시 읽기·스위치 변경으로 세대가 오르면 옛 워커의 결과는 버린다.
//!
//! 셸을 안 띄우는 경우(스위치 끔·macOS 12.3 미만 — `env -0` 이 없다·지원 안 하는 셸·로그인 셸을 못 구함·안전하지 않은 임시 경로)는
//! 조용히 앱 환경으로 대신한다. 띄웠는데 실패한 경우(시한·`Malformed`·띄우기 실패)는 앞서 담은 셸 환경이 있으면 그것을 지키고(원인은
//! 앱 로그에), 없으면 앱 환경으로 대신하되 그 환경에서 서버를 못 찾으면 상태바의 「없음」이 셸 환경을 못 읽었다고 말한다(찾으면 따로
//! 알리지 않는다 — `usingAppFallback`). 어느 대체든 앱 환경을 `shell_env.sanitize` 로 거른 것이다(해석 결과와 같은 위생).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const shell_env = maru.session.editor.lsp.shell_env;

/// 워커와 결과가 쓰는 할당자 — 워커는 detach 라 창 세션보다 오래 살 수 있다(`git_backend` 와 같은 이유).
const gpa = std.heap.smp_allocator;

pub const Status = enum {
    /// 아직 시작하지 않았다.
    idle,
    /// 셸을 기다린다 — 「없음」을 판정하지 않는다(「셸 환경 읽는 중」).
    resolving,
    /// 사용자 셸 환경을 담았다.
    ready,
    /// 셸을 띄우지 않고 앱 환경으로 대신했다(조용히 — `reason`).
    fallback,
    /// 셸을 띄웠는데 못 읽었다 — 앞서 담은 셸 환경이 있으면 그것을, 없으면 앱 환경을 쓴다(`reason`·`usingAppFallback`).
    failed,
};

pub const Reason = enum { none, disabled, old_macos, unsupported_shell, no_login_shell, unsafe_path, test_default, timeout, malformed, spawn };

/// 결과 파일 상한 — 넘으면 못 읽은 것으로 본다(환경이 1 MiB 를 넘을 이유가 없다).
const max_output_bytes: usize = 1 << 20;

const Env = struct {
    /// 시스템 위생(`shell_env.sanitize`)만 거친 항목 — 사용자 제외 목록은 아직 안 거른 원본이다(목록 상자가 「제외됨」을 보인다).
    resolved: shell_env.Resolved,
    /// `execve` 에 줄 환경 — `resolved.entries` 중 사용자 제외 목록에 안 걸린 것(빌린다). 목록을 바꾸면 이것만 다시 만든다(`setExcluded`).
    envp: [:null]?[*:0]const u8,

    fn deinit(self: *Env) void {
        gpa.free(self.envp);
        self.resolved.deinit(gpa);
    }
};

var status_: Status = .idle;
var reason_: Reason = .none;
var generation_: u64 = 0;
var enabled_: bool = true;
/// 스위치를 한 번이라도 정했나 — 처음 시작할 때 첫 창의 설정으로 정하고, 그 뒤로는 사용자의 명시 행동(`setEnabled`)으로만 바뀐다.
var enabled_set: bool = false;
var current: ?Env = null;
/// `current` 가 사용자 셸에서 담은 환경인가(아니면 앱 환경을 거른 대체). 다시 읽기가 실패해도 담아 둔 셸 환경은 지킨다.
var current_from_shell: bool = false;
/// 읽기 시작·다 됨의 횟수 — 창마다 마지막으로 본 값과 견줘 상태바를 다시 그린다(결과는 한 창의 pump 가 받고 다시 읽기는 한 창이
/// 부르지만 「셸 환경 읽는 중」·「못 읽음」은 모든 창에 있다; 워커 스레드의 완료는 다른 무엇도 다시 그리게 하지 않는다).
var change_count: u64 = 0;
/// 사용자 제외 목록(설정 `lsp.environment-exclude` 원문 — 소유, 앞뒤 공백을 다듬은 것; 계획 WT5b-1). 앱 전역 하나다 — 해석기가 하나이고
/// 창마다의 설정은 미러다(스위치 `enabled_` 와 같은 규율: 처음 시작할 때 첫 창의 설정으로, 그 뒤로는 사용자의 명시 행동으로만).
var excluded_text: []u8 = &.{};
var excluded_set: bool = false;
/// 지금 세대를 사용자의 다시 읽기(`reload`)가 시작했나 — 그것마저 못 읽었으면 상태바는 다시 읽기를 더 권하지 않는다(`failedAfterReload`).
var from_reload: bool = false;

const Outcome = union(enum) { ok: shell_env.Resolved, failed: Reason };
const Result = struct { generation: u64, outcome: Outcome };
/// 워커 → 메인. 메인이 가져가기 전에 다음 결과가 오면 앞 것은 버린다(그 세대는 이미 지났다). 잠금 안에서만 읽고 쓴다 — 원자 CAS 로
/// 두면 워커가 슬롯의 결과를 읽는(세대 비교) 사이 메인이 그것을 가져가 해제할 수 있었다(5회차 적대적 검증 — 해제된 칸의 세대를 읽어
/// 자기 결과를 버리면 「읽는 중」에 갇힌다). `pty/macos.zig` 의 `winsize_lock` 과 같은 pthread 잠금(이 모듈엔 `Io` 가 없다).
var slot: ?*Result = null;
var slot_lock: std.c.pthread_mutex_t = .{};

fn takeSlot() ?*Result {
    _ = std.c.pthread_mutex_lock(&slot_lock);
    defer _ = std.c.pthread_mutex_unlock(&slot_lock);
    const r = slot;
    slot = null;
    return r;
}

// ── 판정자 주입 ──
var test_shell: ?[]const u8 = null;
var test_timeout_ms: ?u64 = null;
var test_os_version: ?[]const u8 = null;
var spawn_count: std.atomic.Value(u32) = .init(0);
/// 띄운 워커·끝난 워커 수(판정자) — `resetForTest` 가 떠 있는 워커를 다 기다린다. 줄지 않는다(기다림은 차이로 잰다).
var started_count: std.atomic.Value(u32) = .init(0);
var finished_count: std.atomic.Value(u32) = .init(0);

/// 판정자의 로그인 셸(가짜 셸). 테스트 빌드는 이것이 없으면 셸을 띄우지 않고 조용히 앱 환경으로 대신한다(진짜 사용자 셸을 띄우지
/// 않는다 — 계획 WT3 「판정자에서는 진짜 사용자 셸을 띄우지 않는다」). 상태도 비운다.
pub fn setShellForTest(shell: ?[]const u8, timeout_ms: ?u64) void {
    if (!builtin.is_test) @compileError("test-only");
    resetForTest();
    test_shell = shell;
    test_timeout_ms = timeout_ms;
}

pub fn setOsVersionForTest(version: ?[]const u8) void {
    if (!builtin.is_test) @compileError("test-only");
    test_os_version = version;
}

pub fn resetForTest() void {
    if (!builtin.is_test) @compileError("test-only");
    // 떠 있는 워커를 다 기다린다 — 앞 판정자가 남긴 워커가 다음 판정자의 슬롯·집계에 끼면 순서·샤드에 따라 빨개지거나 헛돈다
    // (적대적 검증). 판정자는 느린 셸을 관문 파일로 붙잡았으면 끝내기 전에 푼다(못 풀었으면 셸의 시한까지 기다린다).
    var waited: u32 = 0;
    while (finished_count.load(.acquire) != started_count.load(.acquire) and waited < 15_000) : (waited += 5) {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    if (takeSlot()) |r| freeResult(r);
    if (current) |*e| e.deinit();
    current = null;
    current_from_shell = false;
    status_ = .idle;
    reason_ = .none;
    enabled_ = true;
    enabled_set = false;
    gpa.free(excluded_text);
    excluded_text = &.{};
    excluded_set = false;
    from_reload = false;
    test_shell = null;
    test_timeout_ms = null;
    test_os_version = null;
    spawn_count.store(0, .release);
}

/// 셸을 띄운 횟수(판정자 — 스위치를 끄면 0 이어야 한다).
pub fn spawnCountForTest() u32 {
    if (!builtin.is_test) @compileError("test-only");
    return spawn_count.load(.acquire);
}

/// 결과를 슬롯에 넘기고(또는 버리고) 끝난 워커 수(판정자 — 시간 대신 순서로 기다린다).
fn finishedCountForTest() u32 {
    return finished_count.load(.acquire);
}

// ── 메인 스레드 ──

/// 서버가 필요한 문서의 gate 와 이름 목록 명령(`trust_ui.openEnvNames`)이 부른다 — 처음이면 시작하고, 워커 결과가 왔으면 받는다(pump 는 `poll` 만 — 받기만 한다). `initial` 은 **처음 한 번만**
/// 읽는다(그 창의 `lsp.shell-environment`). 스위치는 앱 전역이라 창마다의 설정 미러로 매 tick 견주면, 자동 reload 를 끈 창 하나가
/// 다른 값을 들고 있을 때 tick 마다 셸을 새로 띄운다(적대적 검증) — 바꾸는 것은 사용자의 명시 행동뿐이다(`setEnabled` —
/// `window.quit-after-last-window-closed` 와 같은 규율).
pub fn tick(initial: bool) void {
    if (status_ == .idle) {
        if (!enabled_set) enabled_ = initial;
        enabled_set = true;
        start();
    }
    poll();
}

/// 스위치를 바꾼다 — 세팅 토글·행 되돌리기·Reload Config(파일 감시 자동 reload 포함)·전체 리셋(사용자의 명시 행동)만 부른다. 같은 값이면 아무것도 안 한다.
pub fn setEnabled(value: bool) void {
    if (enabled_set and value == enabled_) return;
    enabled_ = value;
    enabled_set = true;
    if (status_ == .idle) return;
    from_reload = false;
    // 켜면 셸을 바로 띄우지 않고 처음으로 되돌린다 — 다음에 서버가 필요한 문서의 gate 가 시작한다(언어 서버를 껐거나 그런 문서가
    // 없으면 셸 설정을 돌리지 않는다 — 계획 「언제」, 적대적 검증). 켜기 전은 늘 끈 상태(끌 때 `start` 가 세대를 올려 읽던 결과는
    // 이미 버린다)라 세대는 그대로 둔다. 끄면 셸 없이 바로 앱 환경으로.
    if (value) {
        status_ = .idle;
        reason_ = .none;
    } else start();
}

/// 다시 읽는다(팔레트 「Reload Shell Environment」·상태바 「못 읽음」 클릭) — 세대를 올리고 처음부터. 아직 아무도 스위치를 정하지
/// 않았으면(셸을 한 번도 시작하지 않았다) `initial`(그 창의 `lsp.shell-environment`)로 정한다 — 기본값(켬)으로 시작하면 꺼 둔 사용자의
/// 셸을 띄운다(적대적 검증).
pub fn reload(initial: bool) void {
    if (!enabled_set) enabled_ = initial;
    enabled_set = true;
    from_reload = true;
    start();
}

/// 사용자 제외 목록을 정한다(설정 `lsp.environment-exclude` — 쉼표로 가른 이름, 끝 `*` 는 접두; 계획 WT5b-1). 담아 둔 환경의 envp 만
/// 다시 만든다 — 셸을 다시 띄우지 않는다(걸러 낸 원본을 지킨다). **이미 떠 있는 서버는 다음에 띄울 때부터** 새 목록으로 뜬다. 못 담으면
/// (메모리) 목록도 envp 도 앞의 것을 지킨다.
pub fn setExcluded(text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (excluded_set and std.mem.eql(u8, excluded_text, trimmed)) return;
    const owned = gpa.dupe(u8, trimmed) catch return;
    // 새 envp 를 먼저 만든다 — 못 만들면 목록도 그대로 둔다(목록 상자·세팅 미러가 「제외됨」이라 말하는데 서버는 그 변수를 받는 일이
    // 없게; 적대적 검증).
    const ptrs: ?[:null]?[*:0]const u8 = if (current) |e| (filteredEnvp(e.resolved.entries, owned) catch {
        gpa.free(owned);
        return;
    }) else null;
    gpa.free(excluded_text);
    excluded_text = owned;
    excluded_set = true;
    if (ptrs) |p| {
        gpa.free(current.?.envp);
        current.?.envp = p;
    }
}

/// 아직 아무도 정하지 않았으면 이 창의 설정으로 정한다(처음 시작할 때 — 스위치 `tick(initial)` 와 같은 규율).
pub fn initExcluded(text: []const u8) void {
    if (!excluded_set) setExcluded(text);
}

/// 사용자가 정한 제외 목록 — 아직 아무도 정하지 않았으면 `null`. 세팅 화면이 창의 설정 미러를 이 값으로 되맞춘다(`enabledOverride` 와 같다).
pub fn excludedOverride() ?[]const u8 {
    return if (excluded_set) excluded_text else null;
}

/// 서버에 줄 환경의 변수 하나 — 이름(값은 보이지 않는다)과 제외 목록에 걸렸는지.
pub const Name = struct { name: []const u8, excluded: bool };

/// 담아 둔 환경의 이름들(시스템 위생을 지난 것 — 순서는 담은 순서). 다 되기 전이면 `null`. 이름은 다음 해석·`setExcluded` 전까지 산다.
pub fn names() ?NameIter {
    if (!settled()) return null;
    const e = current orelse return null;
    return .{ .entries = e.resolved.entries };
}

pub const NameIter = struct {
    entries: []const [:0]u8,
    i: usize = 0,

    pub fn next(self: *NameIter) ?Name {
        if (self.i >= self.entries.len) return null;
        const name = shell_env.entryName(self.entries[self.i]);
        self.i += 1;
        return .{ .name = name, .excluded = shell_env.excludedBy(name, excluded_text) };
    }
};

/// 셸을 못 읽어 **앱 환경으로** 대신했나 — 상태바 「없음」이 셸 환경 탓일 수 있다고 말하는 조건. 앞서 담은 셸 환경을 지킨 실패면
/// 거짓이다(그 환경에서 못 찾은 것은 셸 탓이 아니다 — 10회차; 원인은 앱 로그에 있다).
pub fn usingAppFallback() bool {
    return status_ == .failed and !current_from_shell;
}

/// 사용자가 다시 읽었는데도 못 읽었나 — 상태바 「없음」이 다시 읽기 대신 설치로 돌아간다(`exec tmux` 처럼 늘 실패하는 셸 설정에서
/// 클릭이 다시 읽기만 되풀이하면 설치로 갈 길이 없다 — 다시 읽기는 팔레트에 남는다).
pub fn failedAfterReload() bool {
    return status_ == .failed and from_reload;
}

/// 사용자가 정한 스위치 — 아직 아무도 정하지 않았으면 `null`. 세팅 화면이 창의 설정 미러를 이 값으로 되맞춘다(다른 창에서 바꾼 앱 전역
/// 값 — `window.quit-after-last-window-closed` 의 `appQuitAfterLastWindowClosedOverride` 와 같은 규율).
pub fn enabledOverride() ?bool {
    return if (enabled_set) enabled_ else null;
}

pub fn changeCount() u64 {
    return change_count;
}

pub fn status() Status {
    return status_;
}

pub fn reason() Reason {
    return reason_;
}

/// 다 됐나(해석했든 대신했든) — 아니면 서버를 찾지도 띄우지도 않는다.
pub fn settled() bool {
    return status_ == .ready or status_ == .fallback or status_ == .failed;
}

/// 서버 찾기에 쓸 PATH(정리한 값). 다 되기 전이나 PATH 가 없으면 빈 문자열.
pub fn path() []const u8 {
    if (liveForTest()) return std.mem.span(std.c.getenv("PATH") orelse return "");
    const e = current orelse return "";
    return e.resolved.path orelse "";
}

/// 서버에 줄 환경. 다 되기 전이면 `null`(띄우지 않는다).
pub fn envp() ?[*:null]const ?[*:0]const u8 {
    if (!settled()) return null; // 다시 읽는 중에는 옛 환경으로 띄우지 않는다
    if (liveForTest()) return @ptrCast(std.c.environ);
    const e = current orelse return null;
    return e.envp.ptr;
}

/// **판정자의 기본**(가짜 셸을 주입하지 않았다 — `test_default`)은 떠 둔 환경이 아니라 **지금의** 앱 환경을 거르지 않고 준다 — 판정자는
/// 테스트마다 `setenv` 로 가짜 서버의 동작(`MARU_FAKE_LSP_*` — 위생은 `MARU_` 를 뺀다)을 고르고, 이 표는 앱 전역이라 처음 정할 때 뜬 환경이
/// 낡는다. 위생·해석 경로는 가짜 셸을 주입한 판정자가 잰다.
fn liveForTest() bool {
    return builtin.is_test and status_ == .fallback and reason_ == .test_default;
}

fn start() void {
    generation_ +%= 1;
    if (!enabled_) return settleFallback(.fallback, .disabled);
    if (builtin.is_test and test_shell == null) return settleFallback(.fallback, .test_default);
    if (!osSupportsEnvNul()) return settleFallback(.fallback, .old_macos);
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const login = loginShell(&shell_buf, &home_buf) orelse return settleFallback(.fallback, .no_login_shell);
    const kind = shell_env.shellKind(login.shell) orelse return settleFallback(.fallback, .unsupported_shell);
    const job = Job.create(login.shell, login.home, kind, generation_) catch return settleFallback(.failed, .spawn);
    const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        job.destroy();
        return settleFallback(.failed, .spawn);
    };
    thread.detach();
    if (builtin.is_test) _ = started_count.fetchAdd(1, .acq_rel);
    status_ = .resolving;
    change_count +%= 1;
    reason_ = .none;
}

/// 워커 결과가 왔으면 받는다 — 시작하지는 않는다(LSP pump 가 매 tick 부른다 — 시작은 서버가 필요한 문서의 gate 와 이름 목록 명령만 한다).
pub fn poll() void {
    const r = takeSlot() orelse return;
    defer gpa.destroy(r);
    if (r.generation != generation_) {
        if (r.outcome == .ok) r.outcome.ok.deinit(gpa);
        return;
    }
    switch (r.outcome) {
        .ok => |resolved| {
            const env = buildEnv(resolved) catch {
                var owned = resolved;
                owned.deinit(gpa);
                return settleFallback(.failed, .malformed);
            };
            replaceCurrent(env);
            current_from_shell = true;
            status_ = .ready;
            reason_ = .none;
            change_count +%= 1;
        },
        .failed => |why| settleFallback(if (why == .unsafe_path) .fallback else .failed, why),
    }
}

/// 앱 환경을 거른 것으로 대신한다(`sanitize` — 해석 결과와 같은 위생). 단 **실패**(셸을 띄웠는데 못 읽었다)인데 앞서 담아 둔 셸
/// 환경이 있으면 그것을 지킨다 — 다시 읽기의 시한·일시적 rc 오류 한 번으로 잘 돌던 서버를 다음 기동부터 앱 PATH 로 찾아 「없음」이
/// 되면 세션 끝까지 못 푼다(9회차 적대적 검증). 스위치를 끈 것 같은 조용한 대신은 늘 앱 환경이다(사용자가 셸 환경을 원치 않는다).
fn settleFallback(to: Status, why: Reason) void {
    defer {
        status_ = to;
        reason_ = why;
        change_count +%= 1;
    }
    if (to == .failed) {
        // 원인을 남긴다 — 상태바는 「못 읽음」만 말하고, 무엇 때문인지(시한 — 셸 설정이 멈췄다 · Malformed — `exec` 로 다른 프로그램을
        // 띄웠다 등)는 여기서만 안다.
        if (!builtin.is_test) std.log.scoped(.lsp).warn("shell environment unreadable: reason={s}; using {s}", .{
            @tagName(why), if (current != null and current_from_shell) "the previously read shell environment" else "the app environment",
        });
        if (current != null and current_from_shell) return;
    }
    var app: std.ArrayList([]const u8) = .empty;
    defer app.deinit(gpa);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) app.append(gpa, std.mem.span(entry)) catch break;
    if (shell_env.sanitize(gpa, app.items)) |resolved| {
        if (buildEnv(resolved)) |env| {
            replaceCurrent(env);
            current_from_shell = false; // 갈아 끼운 뒤에만 — OOM 으로 못 바꿨으면 남은 것은 여전히 셸 환경이다
        } else |_| {
            var owned = resolved;
            owned.deinit(gpa);
        }
    } else |_| {}
}

fn replaceCurrent(env: Env) void {
    if (current) |*e| e.deinit();
    current = env;
}

/// `Resolved` 를 넘겨받아 envp 를 만든다(사용자 제외 목록을 거른다). 실패하면 `resolved` 는 호출자가 푼다.
fn buildEnv(resolved: shell_env.Resolved) error{OutOfMemory}!Env {
    return .{ .resolved = resolved, .envp = try filteredEnvp(resolved.entries, excluded_text) };
}

fn filteredEnvp(entries: []const [:0]u8, list: []const u8) error{OutOfMemory}![:null]?[*:0]const u8 {
    var n: usize = 0;
    for (entries) |e| {
        if (!shell_env.excludedBy(shell_env.entryName(e), list)) n += 1;
    }
    const ptrs = try gpa.allocSentinel(?[*:0]const u8, n, null);
    var i: usize = 0;
    for (entries) |e| {
        if (shell_env.excludedBy(shell_env.entryName(e), list)) continue;
        ptrs[i] = e.ptr;
        i += 1;
    }
    return ptrs;
}

/// macOS 12.3 이상인가(`/usr/bin/env -0` — Apple `shell_cmds` 240 부터). 판을 못 읽으면 있는 것으로 본다(띄워 보고 실패하면 알린다).
fn osSupportsEnvNul() bool {
    if (test_os_version) |v| return atLeast(v, 12, 3);
    if (builtin.os.tag != .macos) return true;
    var buf: [32]u8 = undefined;
    var len: usize = buf.len;
    if (std.c.sysctlbyname("kern.osproductversion", &buf, &len, null, 0) != 0) return true;
    const v = std.mem.sliceTo(buf[0..@min(len, buf.len)], 0);
    return atLeast(v, 12, 3);
}

/// `"12.2.1"` 같은 판이 `major.minor` 이상인가. 못 읽으면 `true`.
fn atLeast(version: []const u8, major: u32, minor: u32) bool {
    var it = std.mem.splitScalar(u8, version, '.');
    const ma = std.fmt.parseInt(u32, it.next() orelse return true, 10) catch return true;
    const mi = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return ma > major or (ma == major and mi >= minor);
}

const Login = struct { shell: []const u8, home: []const u8 };

fn usableHome(h: []const u8) bool {
    if (h.len == 0 or h[0] != '/') return false;
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const hz = std.fmt.bufPrintZ(&z, "{s}", .{h}) catch return false;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, hz.ptr, &st, 0) != 0) return false;
    return (st.mode & std.c.S.IFMT) == std.c.S.IFDIR;
}

/// 로그인 셸(`getpwuid` — 판정자는 주입한 셸)과 홈. 홈은 **앱 환경의 `HOME`** 이다(셸 cwd — 셸에 넘기는 `HOME` 과 같은 값, 쓸 수 없어 `getpwuid` 로 대신할 때만 다르다; 계획 WT5b-1
/// 결정: `getpwuid` 로 고정하지 않는다 — 격리 HOME 실행이 기대고 다른 편집기도 프로세스 환경을 그대로 준다). 앱 환경에 없거나 비었으면
/// `getpwuid` 의 홈.
fn loginShell(shell_buf: []u8, home_buf: []u8) ?Login {
    const pw = std.c.getpwuid(std.c.getuid()); // 판정자도 읽는다 — 홈이 `HOME` 을 따르는지(이 값이 아닌지)를 가른다
    const s: []const u8 = if (builtin.is_test) (test_shell orelse return null) else std.mem.span((pw orelse return null).shell orelse return null);
    const env_home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    // 쓸 수 없는 `HOME`(상대 경로·없는 폴더 — 지운 격리 홈)이면 셸이 cwd 로 못 들어가 빈 출력(「못 읽음」)이 된다 — 그때는 `getpwuid`.
    const h: []const u8 = if (usableHome(env_home)) env_home else if (pw) |p| std.mem.span(p.dir orelse return null) else return null;
    if (s.len == 0 or h.len == 0 or s.len > shell_buf.len or h.len > home_buf.len) return null;
    @memcpy(shell_buf[0..s.len], s);
    @memcpy(home_buf[0..h.len], h);
    return .{ .shell = shell_buf[0..s.len], .home = home_buf[0..h.len] };
}

// ── 워커 ──

const Job = struct {
    shell: [:0]u8,
    home: [:0]u8,
    kind: shell_env.Shell,
    generation: u64,
    timeout_ms: u64,
    /// 앱 환경 사본(메인에서 떴다 — 워커가 도는 동안 메인이 `setenv` 할 수 있다).
    env: [][]u8,
    /// 사용자 임시 디렉터리(`$TMPDIR` — 같은 이유로 메인에서 떴다).
    tmp: []u8,

    fn create(shell: []const u8, home: []const u8, kind: shell_env.Shell, gen: u64) error{OutOfMemory}!*Job {
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const s = try gpa.dupeZ(u8, shell);
        errdefer gpa.free(s);
        const h = try gpa.dupeZ(u8, home);
        errdefer gpa.free(h);
        var env: std.ArrayList([]u8) = .empty;
        errdefer {
            for (env.items) |e| gpa.free(e);
            env.deinit(gpa);
        }
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const d = try gpa.dupe(u8, std.mem.span(entry));
            errdefer gpa.free(d);
            try env.append(gpa, d);
        }
        const t = try gpa.dupe(u8, if (std.c.getenv("TMPDIR")) |v| std.mem.span(v) else "/tmp");
        errdefer gpa.free(t);
        job.* = .{ .shell = s, .home = h, .kind = kind, .generation = gen, .timeout_ms = test_timeout_ms orelse shell_env.timeout_ms, .env = try env.toOwnedSlice(gpa), .tmp = t };
        return job;
    }

    fn destroy(self: *Job) void {
        for (self.env) |e| gpa.free(e);
        gpa.free(self.env);
        gpa.free(self.tmp);
        gpa.free(self.shell);
        gpa.free(self.home);
        gpa.destroy(self);
    }
};

fn worker(job: *Job) void {
    defer job.destroy();
    defer if (builtin.is_test) {
        _ = finished_count.fetchAdd(1, .acq_rel);
    };
    const outcome = run(job);
    const r = gpa.create(Result) catch {
        if (outcome == .ok) {
            var owned = outcome.ok;
            owned.deinit(gpa);
        }
        return;
    };
    r.* = .{ .generation = job.generation, .outcome = outcome };
    // 슬롯에 더 새로운 세대의 결과가 있으면 내 것을 버린다 — 늦게 끝난 옛 워커가 새 결과를 지우면 메인은 「읽는 중」에 영영 남는다
    // (적대적 검증). 아니면 갈아 끼우고 옛 것을 버린다.
    _ = std.c.pthread_mutex_lock(&slot_lock);
    const drop: *Result = blk: {
        if (slot) |c| if (c.generation > r.generation) break :blk r;
        const old = slot;
        slot = r;
        _ = std.c.pthread_mutex_unlock(&slot_lock);
        if (old) |o| freeResult(o);
        return;
    };
    _ = std.c.pthread_mutex_unlock(&slot_lock);
    freeResult(drop);
}

fn freeResult(r: *Result) void {
    if (r.outcome == .ok) r.outcome.ok.deinit(gpa);
    gpa.destroy(r);
}

fn run(job: *Job) Outcome {
    // 비공개 디렉터리(0700 — mkdtemp) 아래 빈 파일(0600, O_EXCL·O_NOFOLLOW)을 미리 만든다 — 셸이 `>>` 로 덧붙인다(shell_env 머리 주석).
    const tmp = job.tmp;
    if (tmp.len == 0) return .{ .failed = .unsafe_path };
    var tmpl_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const tmpl = std.fmt.bufPrintZ(&tmpl_buf, "{s}/maru-env.XXXXXX", .{std.mem.trimEnd(u8, tmp, "/")}) catch return .{ .failed = .unsafe_path };
    const dir_z = mkdtemp(tmpl.ptr) orelse return .{ .failed = .spawn };
    const dir = std.mem.span(dir_z);
    defer _ = std.c.rmdir(dir_z);
    var out_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const out_path = std.fmt.bufPrintZ(&out_buf, "{s}/out", .{dir}) catch return .{ .failed = .unsafe_path };
    const created = std.c.open(out_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (created < 0) return .{ .failed = .spawn };
    _ = std.c.close(created);
    defer _ = std.c.unlink(out_path.ptr);

    var nonce_bytes: [shell_env.nonce_len / 2]u8 = undefined;
    std.c.arc4random_buf(&nonce_bytes, nonce_bytes.len);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    var cmd_buf: [3 * std.fs.max_path_bytes + 256]u8 = undefined;
    const cmd = shell_env.command(out_path, &nonce, &cmd_buf) catch return .{ .failed = .unsafe_path };

    // argv·envp 를 fork 전에 만든다 — 자식에서 할당하지 않는다.
    var owned: std.ArrayList([:0]u8) = .empty;
    defer {
        for (owned.items) |s| gpa.free(s);
        owned.deinit(gpa);
    }
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(gpa);
    var env_ptrs: std.ArrayList(?[*:0]const u8) = .empty;
    defer env_ptrs.deinit(gpa);
    build: {
        argv.append(gpa, job.shell.ptr) catch break :build;
        for (shell_env.flags(job.kind)) |f| {
            const z = gpa.dupeZ(u8, f) catch break :build;
            owned.append(gpa, z) catch {
                gpa.free(z);
                break :build;
            };
            argv.append(gpa, z.ptr) catch break :build;
        }
        const cz = gpa.dupeZ(u8, cmd) catch break :build;
        owned.append(gpa, cz) catch {
            gpa.free(cz);
            break :build;
        };
        argv.append(gpa, cz.ptr) catch break :build;
        argv.append(gpa, null) catch break :build;
        var probe: std.ArrayList([]const u8) = .empty;
        defer probe.deinit(gpa);
        const borrowed: []const []const u8 = @ptrCast(job.env);
        shell_env.probeEnv(gpa, borrowed, &probe) catch break :build;
        for (probe.items) |e| {
            const z = gpa.dupeZ(u8, e) catch break :build;
            owned.append(gpa, z) catch {
                gpa.free(z);
                break :build;
            };
            env_ptrs.append(gpa, z.ptr) catch break :build;
        }
        env_ptrs.append(gpa, null) catch break :build;
    }
    if (argv.items.len == 0 or argv.items[argv.items.len - 1] != null or env_ptrs.items.len == 0 or env_ptrs.items[env_ptrs.items.len - 1] != null) return .{ .failed = .spawn };

    _ = spawn_count.fetchAdd(1, .acq_rel);
    const pid = std.c.fork();
    if (pid < 0) return .{ .failed = .spawn };
    if (pid == 0) {
        // 새 세션 — 제어 터미널이 없다(터미널에서 띄운 앱이어도 셸이 그 `/dev/tty` 를 잡지 못한다 — compinit·`read -q` 같은 물음은
        // 「can't open terminal」로 바로 끝난다). 그룹째 끝낼 수 있게 세션 우두머리가 곧 그룹 우두머리다.
        if (std.c.setsid() < 0) std.c._exit(126);
        if (std.c.chdir(job.home.ptr) != 0) std.c._exit(126); // 저장소의 direnv·mise 훅이 신뢰 전에 돌지 않게 cwd 는 홈
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (devnull < 0) std.c._exit(126);
        _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(devnull, 1);
        _ = std.c.dup2(devnull, 2);
        if (devnull > 2) _ = std.c.close(devnull);
        // 앱의 fd 를 셸에 넘기지 않는다 — CLOEXEC 가 없는 것(컨트롤 소켓 잠금 등)이 있고, 성공한 셸이 띄운 데몬은 그룹째 끝내지 않아
        // 그것을 쥔 채 남는다(적대적 검증).
        const max_fd = getdtablesize();
        var fd: c_int = 3;
        while (fd < max_fd) : (fd += 1) _ = std.c.close(fd);
        _ = std.c.execve(job.shell.ptr, @ptrCast(argv.items.ptr), @ptrCast(env_ptrs.items.ptr));
        std.c._exit(127);
    }
    // 셸이 끝나기를 기다린다 — 파이프 EOF 가 아니라 프로세스 종료(셸이 띄운 데몬이 남아도 시한까지 가지 않는다).
    var waited: u64 = 0;
    var st: c_int = 0;
    while (true) {
        const r = std.c.waitpid(pid, &st, std.c.W.NOHANG);
        if (r == pid) break;
        if (r < 0 and std.posix.errno(r) != .INTR) {
            // 거둘 수 없다 — 그룹째 끝내고 한 번 더 거둔다(고아·좀비를 남기지 않게).
            _ = std.c.kill(-pid, std.c.SIG.KILL);
            _ = std.c.waitpid(pid, &st, 0);
            return .{ .failed = .spawn };
        }
        if (waited >= job.timeout_ms) {
            _ = std.c.kill(-pid, std.c.SIG.KILL); // 그룹째(세션 우두머리 = 그룹 우두머리)
            _ = std.c.kill(pid, std.c.SIG.KILL);
            _ = std.c.waitpid(pid, &st, 0);
            return .{ .failed = .timeout };
        }
        sleepMs(10);
        waited += 10;
    }

    const data = readSmall(out_path) orelse return .{ .failed = .malformed };
    defer gpa.free(data);
    const resolved = shell_env.resolve(gpa, data, &nonce) catch return .{ .failed = .malformed };
    return .{ .ok = resolved };
}

/// libc `mkdtemp`(0700 디렉터리)·`getdtablesize` — `std.c` 에 없다.
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn getdtablesize() c_int;

fn readSmall(p: [:0]const u8) ?[]u8 {
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            list.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        if (list.items.len + @as(usize, @intCast(n)) > max_output_bytes) {
            list.deinit(gpa);
            return null;
        }
        list.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch {
        list.deinit(gpa);
        return null;
    };
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tool_env: macOS 판 비교 — 12.3 이상만 env -0 이 있다; 못 읽는 판은 있는 것으로 본다" {
    try testing.expect(atLeast("12.3", 12, 3));
    try testing.expect(atLeast("12.3.1", 12, 3));
    try testing.expect(atLeast("13.0", 12, 3));
    try testing.expect(atLeast("26.1", 12, 3));
    try testing.expect(!atLeast("12.2.1", 12, 3));
    try testing.expect(!atLeast("12.0", 12, 3));
    try testing.expect(!atLeast("11.7.10", 12, 3));
    try testing.expect(atLeast("", 12, 3));
    try testing.expect(atLeast("x.y", 12, 3));
}

/// 판정자 — 가짜 셸이 끝날 때까지 돈다(실패하면 `false`).
fn settleForTest(enabled: bool, max_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < max_ms) : (waited += 10) {
        tick(enabled);
        if (settled()) return true;
        sleepMs(10);
    }
    return false;
}

/// 판정자 — 가짜 로그인 셸을 `dir/name` 에 쓴다(`body` 는 sh 스크립트, 마지막 인자가 우리 명령이다 — `$cmd`).
fn writeFakeShell(dir: std.Io.Dir, name: []const u8, body: []const u8, out: []u8, root: []const u8) ![]const u8 {
    var script: [2048]u8 = undefined;
    const text = try std.fmt.bufPrint(&script, "#!/bin/sh\nfor a; do cmd=$a; done\n{s}\n", .{body});
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = text });
    const p = try std.fmt.bufPrint(out, "{s}/{s}", .{ root, name });
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    _ = std.c.chmod((try std.fmt.bufPrintZ(&z, "{s}", .{p})).ptr, 0o755);
    return p;
}

const HomeGuard = struct {
    saved: ?[:0]u8,
    fn set(home: []const u8) !HomeGuard {
        const old: ?[:0]u8 = if (std.c.getenv("HOME")) |h| try testing.allocator.dupeZ(u8, std.mem.span(h)) else null;
        var z: [std.fs.max_path_bytes + 1]u8 = undefined;
        _ = setenv("HOME", (try std.fmt.bufPrintZ(&z, "{s}", .{home})).ptr, 1);
        return .{ .saved = old };
    }
    fn restore(self: *HomeGuard) void {
        if (self.saved) |h| {
            _ = setenv("HOME", h.ptr, 1);
            testing.allocator.free(h);
        } else _ = unsetenv("HOME");
    }
};
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// 판정자 — 앱 환경 변수 하나를 세우고 되돌린다(터미널 세션 변수를 앱 환경에 일부러 세워야 「거른다」 단언이 헛돌지 않는다 — CI
/// 러너에는 `TERM` 이 없을 수 있다).
const VarGuard = struct {
    name: [:0]const u8,
    saved: ?[:0]u8,
    fn set(name: [:0]const u8, value: [:0]const u8) !VarGuard {
        const old: ?[:0]u8 = if (std.c.getenv(name.ptr)) |v| try testing.allocator.dupeZ(u8, std.mem.span(v)) else null;
        _ = setenv(name.ptr, value.ptr, 1);
        return .{ .name = name, .saved = old };
    }
    fn restore(self: *VarGuard) void {
        if (self.saved) |v| {
            _ = setenv(self.name.ptr, v.ptr, 1);
            testing.allocator.free(v);
        } else _ = unsetenv(self.name.ptr);
    }
};

fn envValueOf(name: []const u8) ?[]const u8 {
    const e = current orelse return null;
    for (e.resolved.entries) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

test "tool_env: 셸 cwd 는 앱 환경의 HOME — 쓸 수 없는 HOME(없는 폴더·상대 경로·파일)이면 getpwuid 의 홈으로 대신해 「못 읽음」이 되지 않는다 (계획 WT5b-1)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shell = try writeFakeShell(tmp.dir, "zsh",
        \\export FAKE_CWD="$(pwd -P)"
        \\exec /bin/sh -c "$cmd"
    , &shell_buf, root);
    const pw = std.c.getpwuid(std.c.getuid()) orelse return error.SkipZigTest;
    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = std.c.realpath(pw.dir orelse return error.SkipZigTest, &want_buf) orelse return error.SkipZigTest;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "not-a-dir", .data = "" });
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_home = try std.fmt.bufPrint(&file_buf, "{s}/not-a-dir", .{root}); // 폴더가 아닌 파일
    for ([_][]const u8{ "/nonexistent-maru-home-wt5b1", "relative/home", file_home }) |bad| {
        var home = try HomeGuard.set(bad);
        defer home.restore();
        setShellForTest(shell, null);
        defer resetForTest();
        try testing.expect(settleForTest(true, 5000));
        try testing.expectEqual(Status.ready, status());
        try testing.expectEqualStrings(std.mem.sliceTo(want, 0), envValueOf("FAKE_CWD").?);
    }
}

test "tool_env: 가짜 로그인 셸 — -l -i -c 로 홈에서, 제어 터미널 없이(setsid) 띄우고, 셸 설정이 세운 PATH·변수를 담는다; 표식·터미널 변수는 서버로 안 간다 (계획 WT3b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shell = try writeFakeShell(tmp.dir, "zsh",
        \\export PATH="$HOME/fakebin:$PATH"
        \\export FAKE_CWD="$(pwd -P)"
        \\export FAKE_ARGS="$1 $2 $3"
        \\if (exec 3</dev/tty) 2>/dev/null; then export FAKE_TTY=yes; else export FAKE_TTY=no; fi
        \\if [ "$(/bin/ps -o pgid= -p $$ | tr -d ' ')" = "$$" ]; then export FAKE_LEADER=yes; else export FAKE_LEADER=no; fi
        \\export FAKE_FDS=" $(/bin/ls /dev/fd | /usr/bin/tr '\n' ' ')"
        \\export FAKE_GOT_TERM="${TERM-none}"
        \\export TERM=shell-term TMUX=shell-tmux
        \\exec /bin/sh -c "$cmd"
    , &shell_buf, root);
    // 앱 환경에 터미널 세션 변수가 있다(터미널에서 띄운 앱) — 셸에도 안 넘기고, 셸 설정이 세운 것도 서버로 안 간다.
    var term_guard = try VarGuard.set("TERM", "xterm-from-app");
    defer term_guard.restore();
    var tmux_guard = try VarGuard.set("TMUX", "/tmp/tmux-app,1,0");
    defer tmux_guard.restore();
    setShellForTest(shell, null);
    defer resetForTest();
    // 앱이 CLOEXEC 없이 연 fd(컨트롤 소켓 잠금 같은 것) — 셸에 넘어가면 안 된다.
    var leak_path: [std.fs.max_path_bytes + 1]u8 = undefined;
    const leak_a = std.c.open((try std.fmt.bufPrintZ(&leak_path, "{s}/leak-a", .{root})).ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    const leak_b = std.c.open((try std.fmt.bufPrintZ(&leak_path, "{s}/leak-b", .{root})).ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(std.c.mode_t, 0o600));
    defer _ = std.c.close(leak_a);
    defer _ = std.c.close(leak_b);
    try testing.expect(leak_b > 3);
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.ready, status());
    try testing.expectEqual(@as(u32, 1), spawnCountForTest());
    var fd_text: [16]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, envValueOf("FAKE_FDS").?, try std.fmt.bufPrint(&fd_text, " {d} ", .{leak_b})) == null);
    try testing.expectEqualStrings("-l -i -c", envValueOf("FAKE_ARGS").?);
    try testing.expectEqualStrings(root, envValueOf("FAKE_CWD").?);
    try testing.expectEqualStrings("no", envValueOf("FAKE_TTY").?); // setsid — 이 판정자를 터미널에서 돌려도 셸은 /dev/tty 를 못 연다
    try testing.expectEqualStrings("yes", envValueOf("FAKE_LEADER").?); // 제어 터미널이 없는 곳(CI)에서도 setsid 를 가른다 — 자기 그룹의 우두머리
    try testing.expect(std.mem.startsWith(u8, path(), root)); // 셸 설정이 앞에 넣은 PATH 항목
    try testing.expect(envValueOf("MARU_RESOLVING_ENVIRONMENT") == null);
    try testing.expect(!std.mem.eql(u8, "xterm-from-app", envValueOf("FAKE_GOT_TERM").?)); // 셸에 넘긴 바탕에 앱의 TERM 이 없다(셸엔 `dumb` 를 준다 — shell_env)
    try testing.expect(envValueOf("TERM") == null); // 셸 설정이 세운 것도 거른다
    try testing.expect(envValueOf("TMUX") == null);
    try testing.expect(envp() != null);
}

test "tool_env: 시한을 넘기면 셸을 그룹째 끝내고 앱 환경(거른 것)으로 대신하며 실패로 알린다; 아무것도 안 쓰고 끝나면 Malformed 로 같다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    // 셸 설정이 데몬을 띄우고 멈춘다 — 시한 뒤 그 데몬까지 끝나야 한다(세션 = 그룹).
    const slow = try writeFakeShell(tmp.dir, "zsh", "/bin/sleep 300 & echo $! > \"$HOME/child.pid\"; wait", &shell_buf, root);
    var term_guard = try VarGuard.set("TERM", "xterm-from-app"); // 대신한 앱 환경도 거르는지 재려면 앱 환경에 있어야 한다
    defer term_guard.restore();
    setShellForTest(slow, 2000); // 시한 — 자식이 exec 전에 fd 를 닫는 데·sh 기동에 느린 러너에서도 남는다
    defer resetForTest();
    try testing.expect(settleForTest(true, 15_000));
    try testing.expectEqual(Status.failed, status());
    try testing.expectEqual(Reason.timeout, reason());
    try testing.expect(envp() != null); // 대신한 환경으로 띄울 수는 있다
    try testing.expect(envValueOf("TERM") == null); // 대신한 것도 거른 것이다
    const pid_text = try tmp.dir.readFileAlloc(testing.io, "child.pid", testing.allocator, .limited(64));
    defer testing.allocator.free(pid_text);
    const child = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
    var gone = false;
    var ms: u64 = 0;
    while (ms < 2000) : (ms += 10) {
        if (std.c.kill(child, @enumFromInt(0)) != 0) {
            gone = true;
            break;
        }
        sleepMs(10);
    }
    try testing.expect(gone);
    // 출력 없이 끝났다(설정 파일이 exec 로 다른 것을 띄웠다).
    var shell2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const quiet = try writeFakeShell(tmp.dir, "bash", "exit 0", &shell2_buf, root);
    setShellForTest(quiet, null);
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.failed, status());
    try testing.expectEqual(Reason.malformed, reason());
}

test "tool_env: 셸을 안 띄우는 경우는 조용한 대신 — 스위치 끔·macOS 12.3 미만·지원 안 하는 셸; 다시 읽기는 세대를 올려 처음부터 (계획 WT3b)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shell = try writeFakeShell(tmp.dir, "zsh", "exec /bin/sh -c \"$cmd\"", &shell_buf, root);
    setShellForTest(shell, null);
    defer resetForTest();
    try testing.expect(settleForTest(false, 1000));
    try testing.expectEqual(Status.fallback, status());
    try testing.expectEqual(Reason.disabled, reason());
    try testing.expectEqual(@as(u32, 0), spawnCountForTest());
    // 매 tick 의 값은 처음 한 번만 읽는다(창마다 다른 설정 미러로 셸이 폭주하지 않게) — 켜는 것은 사용자의 명시 행동(`setEnabled`)이다.
    tick(true);
    try testing.expectEqual(Reason.disabled, reason());
    // 켜기만으로는 셸을 띄우지 않는다 — 처음으로 되돌아가고 다음 tick(서버가 필요한 문서의 gate)이 시작한다.
    setEnabled(true);
    try testing.expectEqual(Status.idle, status());
    try testing.expectEqual(@as(u32, 0), spawnCountForTest());
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.ready, status());
    try testing.expectEqual(@as(u32, 1), spawnCountForTest());
    // 담은 뒤에 껐다 켜도(언어 서버를 꺼 둔 채 세팅을 만졌다) 셸을 안 띄운다.
    setEnabled(false);
    try testing.expectEqual(Reason.disabled, reason());
    setEnabled(true);
    try testing.expectEqual(Status.idle, status());
    try testing.expect(envp() == null);
    sleepMs(100);
    try testing.expectEqual(@as(u32, 1), spawnCountForTest());
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(@as(u32, 2), spawnCountForTest());
    // 다시 읽기 — 셸을 한 번 더 띄우고 다 되기 전에는 envp 가 없다(옛 환경으로 띄우지 않는다).
    reload(true);
    try testing.expect(!settled());
    try testing.expect(envp() == null);
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.ready, status());
    try testing.expectEqual(@as(u32, 3), spawnCountForTest());
    // macOS 12.2 — env -0 이 없다.
    setShellForTest(shell, null);
    setOsVersionForTest("12.2.1");
    try testing.expect(settleForTest(true, 1000));
    try testing.expectEqual(Reason.old_macos, reason());
    try testing.expectEqual(Status.fallback, status());
    try testing.expectEqual(@as(u32, 0), spawnCountForTest());
    // 지원 안 하는 셸(nushell).
    var nu_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nu = try writeFakeShell(tmp.dir, "nu", "exec /bin/sh -c \"$cmd\"", &nu_buf, root);
    setShellForTest(nu, null);
    try testing.expect(settleForTest(true, 1000));
    try testing.expectEqual(Reason.unsupported_shell, reason());
    try testing.expectEqual(@as(u32, 0), spawnCountForTest());
}

test "tool_env: 다시 읽기가 실패해도 앞서 담은 셸 환경을 지킨다 — 실패로 알리되 서버는 그 PATH 로 찾는다; 스위치를 끄면 앱 환경으로" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    // 처음은 셸 설정이 PATH 앞에 홈을 넣고, 다음부터는 아무것도 안 남기고 끝난다(Malformed).
    const shell = try writeFakeShell(tmp.dir, "zsh", "if [ -f \"$HOME/first\" ]; then exit 0; fi\n: > \"$HOME/first\"\nexport PATH=\"$HOME:$PATH\"\nexec /bin/sh -c \"$cmd\"", &shell_buf, root);
    setShellForTest(shell, null);
    defer resetForTest();
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.ready, status());
    try testing.expect(std.mem.startsWith(u8, path(), root));
    reload(true);
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.failed, status());
    try testing.expectEqual(Reason.malformed, reason());
    try testing.expect(std.mem.startsWith(u8, path(), root)); // 담아 둔 셸 환경 그대로
    try testing.expect(envp() != null);
    try testing.expect(!usingAppFallback()); // 상태바는 「못 읽음」을 말하지 않는다 — 그 환경에서 못 찾은 것은 셸 탓이 아니다
    // 스위치를 끄면 사용자가 셸 환경을 원치 않는다 — 앱 환경(거른 것)으로.
    setEnabled(false);
    try testing.expect(!std.mem.startsWith(u8, path(), root));
    // 한 번도 담지 못한 실패는 앱 환경으로(지킬 것이 없다).
    setEnabled(true);
    reload(true);
    try testing.expect(settleForTest(true, 5000));
    try testing.expectEqual(Status.failed, status());
    try testing.expect(!std.mem.startsWith(u8, path(), root));
    try testing.expect(usingAppFallback());
}

test "tool_env: 읽는 중에 스위치를 끄면 늦게 온 셸 결과를 받지 않는다 — 앱 환경(끔)으로 남는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shell = try writeFakeShell(tmp.dir, "zsh", "while [ ! -f \"$HOME/go\" ]; do /bin/sleep 0.02; done; exec /bin/sh -c \"$cmd\"", &shell_buf, root);
    setShellForTest(shell, null);
    defer resetForTest();
    const base = finishedCountForTest();
    tick(true);
    try testing.expectEqual(Status.resolving, status());
    setEnabled(false);
    try testing.expectEqual(Reason.disabled, reason());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "go", .data = "" });
    var ms: u64 = 0;
    while (ms < 5000 and finishedCountForTest() < base + 1) : (ms += 10) sleepMs(10);
    try testing.expectEqual(base + 1, finishedCountForTest());
    poll();
    try testing.expectEqual(Status.fallback, status());
    try testing.expectEqual(Reason.disabled, reason());
}

test "tool_env: 늦게 끝난 옛 워커가 슬롯의 새 세대 결과를 지우지 않는다 — 다시 읽기 뒤 메인은 새 결과를 받는다(「읽는 중」에 갇히지 않는다)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var home = try HomeGuard.set(root);
    defer home.restore();
    var shell_buf: [std.fs.max_path_bytes]u8 = undefined;
    // 처음 부른 셸(옛 세대)은 판정자가 `go` 를 만들 때까지 기다리고, 다음 셸(새 세대)은 바로 끝난다 — 시간이 아니라 순서로 경합을 만든다.
    const shell = try writeFakeShell(tmp.dir, "zsh", "if [ -f \"$HOME/first\" ]; then exec /bin/sh -c \"$cmd\"; fi\n: > \"$HOME/first\"; while [ ! -f \"$HOME/go\" ]; do /bin/sleep 0.02; done; exec /bin/sh -c \"$cmd\"", &shell_buf, root);
    setShellForTest(shell, null);
    defer resetForTest();
    const base = finishedCountForTest();
    tick(true); // 옛 세대 — 느린 셸
    // 첫 셸이 표시 파일을 남긴 뒤에 다시 읽는다 — 그 전이면 둘째 셸도 느리게 돌아 경합이 안 생긴다(판정자가 헛돈다).
    var ms: u64 = 0;
    while (ms < 3000) : (ms += 10) {
        tmp.dir.access(testing.io, "first", .{}) catch {
            sleepMs(10);
            continue;
        };
        break;
    }
    try testing.expect(ms < 3000);
    reload(true); // 새 세대 — 빠른 셸
    // 메인은 둘 다 끝날 때까지 결과를 안 가져간다 — 새 결과가 슬롯에 들어간 뒤(새 워커가 끝났다) 옛 셸을 풀어 옛 워커가 늦게 끝나게 한다.
    ms = 0;
    while (ms < 5000 and finishedCountForTest() < base + 1) : (ms += 10) sleepMs(10);
    try testing.expectEqual(base + 1, finishedCountForTest());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "go", .data = "" });
    ms = 0;
    while (ms < 5000 and finishedCountForTest() < base + 2) : (ms += 10) sleepMs(10);
    try testing.expectEqual(base + 2, finishedCountForTest());
    tick(true);
    try testing.expectEqual(Status.ready, status());
}
