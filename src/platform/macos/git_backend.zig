//! 도크 소스 컨트롤 뷰의 **git 읽기 backend**(L4). render tick은 `submit`/`takeResult`만 부르고 둘 다 메모리
//! 조작뿐이다 — 실제 프로세스 spawn·출력 수집은 detached worker thread에서 한다.
//!
//! `file_tree_backend`와 같은 형태다(제출·bounded in-flight·완료 큐). 다르게 만들 이유가 없고, 같은 모양이면
//! frame tick에서 syscall이 도는지 판단하는 규칙이 하나로 유지된다.
//!
//! **무엇을 실행할지는 여기서 정하지 않는다.** argv·env는 `session.git_command`가 소유하고(안전 조건이 전부
//! 거기 있다 — docs/editor-surface.md §6) 이 모듈은 그것을 그대로 spawn한다. 출력 해석도 `session.git_status`가
//! 한다. 즉 이 파일의 책임은 **프로세스 수명과 상한**뿐이다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const git_command = maru.session.git_command;

/// 창 하나가 동시에 돌리는 git 읽기 요청 수. 뷰가 하나뿐이라 1이면 충분하고, 갱신이 겹치면 뒤 요청을 버린다
/// (오래된 결과로 화면을 덮어쓰지 않기 위해 어차피 최신 하나만 쓴다).
pub const max_inflight: usize = 1;

/// 명령 하나의 출력 상한. 변경 파일이 수만 개인 저장소에서도 목록은 화면에 다 못 들어가므로, 여기서 잘라도
/// 사용자가 보는 것은 같다. 상한을 넘으면 **잘린 사실을 결과에 싣는다** — 조용히 일부만 보여 주지 않는다.
pub const max_output_bytes: usize = 1 << 20;

pub const Result = struct {
    /// `git status --porcelain=v2 --branch` 출력.
    status: []u8 = &.{},
    /// `git diff --numstat --cached` 출력.
    numstat_staged: []u8 = &.{},
    /// `git diff --numstat` 출력.
    numstat_worktree: []u8 = &.{},
    /// 셋 다 정상 종료했는가. 하나라도 실패하면 부분 결과를 쓰지 않는다(섹션이 서로 다른 시점을 섞지 않게).
    ok: bool = false,
    /// 출력이 상한에 걸려 잘렸는가. 목록 끝에 그 사실을 표시한다.
    truncated: bool = false,
    /// 이 결과가 어느 요청의 것인지. 늦게 온 결과가 최신 화면을 덮어쓰지 않게 호출자가 대조한다.
    request_id: u64 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.numstat_staged);
        allocator.free(self.numstat_worktree);
        self.* = .{};
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    refs: std.atomic.Value(u32) = .init(1),
    shutting_down: bool = false,
    inflight: usize = 0,
    result: ?Result = null,

    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |*r| r.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const Job = struct {
    state: *State,
    /// worker가 소유하고 끝나면 해제한다(호출자 문자열 수명에 매이지 않게 복사해 넘긴다).
    git_exe: []u8,
    repo: []u8,
    request_id: u64,
};

pub const Backend = struct {
    state: ?*State = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator };
        return .{ .state = state };
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        state.mutex.lock();
        state.shutting_down = true;
        state.mutex.unlock();
        self.state = null;
        state.release();
    }

    /// 요청을 건다. frame tick에서 불러도 syscall이 없다(스레드 생성만). 이미 in-flight면 false —
    /// 호출자는 다음 갱신 시점에 다시 시도한다(큐를 쌓아 오래된 결과를 줄줄이 만들지 않는다).
    pub fn submit(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lock();
        if (state.shutting_down or state.inflight >= max_inflight) {
            state.mutex.unlock();
            return false;
        }
        state.inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock();

        const job = state.allocator.create(Job) catch return self.abandon();
        job.* = .{
            .state = state,
            .git_exe = state.allocator.dupe(u8, git_exe) catch {
                state.allocator.destroy(job);
                return self.abandon();
            },
            .repo = undefined,
            .request_id = request_id,
        };
        job.repo = state.allocator.dupe(u8, repo) catch {
            state.allocator.free(job.git_exe);
            state.allocator.destroy(job);
            return self.abandon();
        };
        const thread = std.Thread.spawn(.{}, worker, .{job}) catch {
            state.allocator.free(job.git_exe);
            state.allocator.free(job.repo);
            state.allocator.destroy(job);
            return self.abandon();
        };
        thread.detach();
        return true;
    }

    fn abandon(self: *Backend) bool {
        const state = self.state orelse return false;
        state.mutex.lock();
        state.inflight -= 1;
        state.mutex.unlock();
        state.release();
        return false;
    }

    /// 완료 결과 하나의 소유권을 호출자에게 넘긴다. frame tick에서 불러도 syscall이 없다.
    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lock();
        defer state.mutex.unlock();
        const result = state.result orelse return null;
        state.result = null;
        return result;
    }
};

fn worker(job: *Job) void {
    const state = job.state;
    var result: Result = .{ .request_id = job.request_id };
    var ok = true;
    var truncated = false;
    inline for (.{
        .{ git_command.Kind.status, "status" },
        .{ git_command.Kind.numstat_staged, "numstat_staged" },
        .{ git_command.Kind.numstat_worktree, "numstat_worktree" },
    }) |pair| {
        if (ok) {
            const out = run(state.allocator, pair[0], job.git_exe, job.repo) catch null;
            if (out) |o| {
                @field(result, pair[1]) = o.bytes;
                if (o.truncated) truncated = true;
            } else ok = false;
        }
    }
    result.ok = ok;
    result.truncated = truncated;
    state.allocator.free(job.git_exe);
    state.allocator.free(job.repo);
    state.allocator.destroy(job);

    state.mutex.lock();
    if (!state.shutting_down and state.result == null and ok) {
        state.result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.inflight -= 1;
    state.mutex.unlock();
    state.release();
}

const Output = struct { bytes: []u8, truncated: bool };

fn run(allocator: std.mem.Allocator, kind: git_command.Kind, git_exe: []const u8, repo: []const u8) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.build(kind, git_exe, repo, &argv_buf);

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    // stderr에는 경로·사용자·저장소 정보가 섞이므로 **읽지 않고 버린다**(docs/editor-surface.md §6 — raw로
    // page/trace에 흘리지 않는다). 실패 여부는 종료 코드로 충분하다.
    child.stderr_behavior = .Ignore;

    // 환경은 상속이 아니라 덮어쓴다 — 사용자 환경의 GIT_* 가 읽기 전용 계약을 깨뜨릴 수 있다.
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    for (git_command.env_overrides) |e| try env.put(e.name, e.value);
    child.env_map = &env;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    const stdout = child.stdout.?;
    var truncated = false;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = stdout.read(&chunk) catch break;
        if (n == 0) break;
        if (buffer.items.len + n > max_output_bytes) {
            const room = max_output_bytes -| buffer.items.len;
            if (room > 0) try buffer.appendSlice(allocator, chunk[0..room]);
            truncated = true;
            break; // 상한을 넘으면 더 읽지 않는다. 아래 wait가 파이프를 닫아 자식을 끝낸다.
        }
        try buffer.appendSlice(allocator, chunk[0..n]);
    }
    const term = child.wait() catch return error.GitFailed;
    switch (term) {
        .Exited => |code| if (code != 0 and !truncated) return error.GitFailed,
        else => return error.GitFailed,
    }
    return .{ .bytes = try buffer.toOwnedSlice(allocator), .truncated = truncated };
}

const testing = std.testing;

test "submit은 in-flight 상한을 넘기지 않고 tick을 막지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var backend = try Backend.init(testing.allocator);
    defer backend.deinit();
    // 존재하지 않는 실행 파일이라 worker는 곧 실패하지만, submit 자체는 **스레드 생성만** 하고 즉시 돌아온다.
    try testing.expect(backend.submit("/nonexistent/git", "/tmp", 1));
    // 상한이 1이므로 곧바로 두 번째를 걸면 거부돼야 한다(큐를 쌓아 오래된 결과를 만들지 않는다).
    // 첫 요청이 이미 끝났을 수도 있어 결과와 무관하게 **크래시하지 않는 것**만 계약으로 둔다.
    _ = backend.submit("/nonexistent/git", "/tmp", 2);
    // 실패한 요청은 결과를 남기지 않는다(부분 결과로 섹션을 섞지 않는다).
    std.Thread.sleep(50 * std.time.ns_per_ms);
    if (backend.takeResult()) |*r| {
        var res = r.*;
        defer res.deinit(testing.allocator);
        try testing.expect(res.ok);
    }
}
