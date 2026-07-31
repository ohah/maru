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
    io: std.Io,
    mutex: std.Io.Mutex = .init,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Backend {
        const state = try allocator.create(State);
        state.* = .{ .allocator = allocator, .io = io };
        return .{ .state = state };
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state orelse return;
        state.mutex.lockUncancelable(state.io);
        state.shutting_down = true;
        state.mutex.unlock(state.io);
        self.state = null;
        state.release();
    }

    /// 요청을 건다. frame tick에서 불러도 syscall이 없다(스레드 생성만). 이미 in-flight면 false —
    /// 호출자는 다음 갱신 시점에 다시 시도한다(큐를 쌓아 오래된 결과를 줄줄이 만들지 않는다).
    pub fn submit(self: *Backend, git_exe: []const u8, repo: []const u8, request_id: u64) bool {
        const state = self.state orelse return false;
        state.mutex.lockUncancelable(state.io);
        if (state.shutting_down or state.inflight >= max_inflight) {
            state.mutex.unlock(state.io);
            return false;
        }
        state.inflight += 1;
        _ = state.refs.fetchAdd(1, .monotonic);
        state.mutex.unlock(state.io);

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
        state.mutex.lockUncancelable(state.io);
        state.inflight -= 1;
        state.mutex.unlock(state.io);
        state.release();
        return false;
    }

    /// 완료 결과 하나의 소유권을 호출자에게 넘긴다. frame tick에서 불러도 syscall이 없다.
    pub fn takeResult(self: *Backend) ?Result {
        const state = self.state orelse return null;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
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
            const out = run(state.allocator, state.io, pair[0], job.git_exe, job.repo) catch null;
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

    state.mutex.lockUncancelable(state.io);
    if (!state.shutting_down and state.result == null and ok) {
        state.result = result;
    } else {
        result.deinit(state.allocator);
    }
    state.inflight -= 1;
    state.mutex.unlock(state.io);
    state.release();
}

const Output = struct { bytes: []u8, truncated: bool };

fn run(allocator: std.mem.Allocator, io: std.Io, kind: git_command.Kind, git_exe: []const u8, repo: []const u8) !Output {
    var argv_buf: [git_command.max_argv][]const u8 = undefined;
    const argv = git_command.build(kind, git_exe, repo, &argv_buf);

    // 환경은 상속이 아니라 덮어쓴다 — 사용자 환경의 GIT_* 가 읽기 전용 계약을 깬다(git_command.env_overrides).
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    for (git_command.env_overrides) |e| try env.put(e.name, e.value);

    // stderr에는 경로·사용자·저장소 정보가 섞이므로 **버린다**(docs/editor-surface.md §6 — raw로 흘리지 않는다).
    // 실패 여부는 종료 코드로 충분하다. stdout만 상한 안에서 받는다.
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = &env,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(4096),
    }) catch return error.GitFailed;
    allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }
    // 상한에 걸렸는지는 길이로 판정한다 — 잘렸으면 목록 끝에 그 사실을 표시한다(조용히 일부만 보여 주지 않는다).
    return .{ .bytes = result.stdout, .truncated = result.stdout.len >= max_output_bytes };
}

const testing = std.testing;

test "제출 없이 열고 닫아도 안전하다(수명 계약)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // 실제 spawn을 테스트에서 돌리지 않는다 — worker가 detached라 테스트 종료와 경합해 결과가 비결정적이 된다.
    // 여기서 고정하는 것은 **수명**뿐이고, argv·env는 `session.git_command`가, 파싱은 `session.git_status`가
    // 각각 헤드리스로 전수 검증한다.
    var backend = try Backend.init(testing.allocator, std.Io.Threaded.global_single_threaded.io());
    backend.deinit();
    try testing.expect(backend.state == null);
}
