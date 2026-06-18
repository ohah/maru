//! L4 platform adapter (macOS) — 에이전트 세션 트랜스크립트 *파일 찾기 + tail read*. session core
//! (src/session/agent_transcript.zig)가 바이트→상태를 순수하게 판정하고, 이 모듈은 그 바이트를 디스크에서
//! 가져오는 OS I/O만 맡는다(세션 파일 위치·디렉터리 나열·끝부분 seek read). 경로는 macOS 관례
//! (`~/.claude/projects`, `~/.codex/sessions`)지만 로직 자체는 경로만 바꾸면 다른 OS로 옮겨진다
//! (docs/agent-session.md "아키텍처/레이어" — platform adapter). 호출은 tick 스레드(pollAgentKinds) 단일 경로.
//!
//! 성능(docs/agent-session.md "성능"): 긴 트랜스크립트는 수백 MB가 될 수 있어 **절대 전체를 읽지 않는다** —
//! 파일 끝 tail_window 바이트만 seek해 읽고, 그 안 마지막 *대화/turn* 엔트리로 상태를 판정한다. mtime이 직전과
//! 같으면 tail read·재파싱을 건너뛴다(prev_mtime). claude는 cwd 인코딩으로 디렉터리를 바로 찾고, codex는 날짜
//! 분할이라 최신 날짜 디렉터리의 rollout들 중 첫 줄 cwd가 일치하는 최신을 고른다.

const std = @import("std");
const maru = @import("maru");

const transcript = maru.session.agent_transcript;

pub const State = transcript.AgentState;

/// 어느 에이전트의 트랜스크립트인지. `none`(포그라운드가 에이전트 아님)은 호출자가 처리한다 — 여기 오는 건
/// claude/codex뿐이고, 세션 파일 위치·파서가 다르다.
pub const Kind = enum { claude, codex };

pub const Poll = struct {
    /// 새로 계산한 상태. `null`이면 세션 파일 mtime이 `prev_mtime`과 같아 재파싱을 건너뛴 것 — 호출자는 직전
    /// 상태를 유지한다(docs/agent-session.md "성능": mtime 안 바뀌면 재파싱 skip).
    state: ?State,
    /// `state`가 non-null이고 idle일 때 `answer_buf`에 쓴 마지막 답변 첫 줄 길이(running/unknown이면 0).
    answer_len: usize,
    /// 찾은 세션 파일의 mtime(나노초). 못 찾으면 0. 호출자가 캐시해 다음 poll에 `prev_mtime`으로 넘긴다.
    mtime: i128,
};

/// 파일 끝에서 읽는 창 크기. 마지막 대화/turn 엔트리(+ codex session_meta 첫 줄 ~22KB)를 담기 충분하면서도
/// 거대 파일을 통째로 읽지 않게 작게 유지한다.
const tail_window: usize = 64 * 1024;

fn unknownPoll() Poll {
    return .{ .state = .unknown, .answer_len = 0, .mtime = 0 };
}

/// 에이전트 종류·cwd로 세션 파일을 찾아 tail을 읽고 상태·마지막 답변을 계산한다. `root_path`는 그 에이전트의
/// 세션 루트(claude=`<home>/.claude/projects`, codex=`<home>/.codex/sessions`) — 테스트가 temp dir를 주입할 수
/// 있게 인자로 받는다. `gpa`는 tail 버퍼·줄 파싱용 임시 할당(즉시 해제). `answer_buf`엔 idle일 때 답변을 쓴다.
/// 세션을 못 찾으면 state=unknown.
pub fn poll(
    io: std.Io,
    gpa: std.mem.Allocator,
    kind: Kind,
    root_path: []const u8,
    cwd: []const u8,
    prev_mtime: i128,
    answer_buf: []u8,
) Poll {
    // tail read + codex 첫 줄 읽기용 임시 버퍼(tick 주기마다 alloc/free — 0.5s 간격이라 무시 가능). 거대 파일을
    // 통째로 안 읽으려고 이 창 크기로 고정한다.
    const scratch_buf = gpa.alloc(u8, tail_window) catch return unknownPoll();
    defer gpa.free(scratch_buf);

    var path_buf: [4096]u8 = undefined;
    const path = switch (kind) {
        .claude => resolveClaude(io, &path_buf, root_path, cwd),
        .codex => resolveCodex(io, gpa, &path_buf, scratch_buf, root_path, cwd),
    } orelse return unknownPoll();

    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return unknownPoll();
    const mtime: i128 = st.mtime.nanoseconds;
    // mtime 안 바뀌었으면 tail read·재파싱을 건너뛴다(느린 API 중 잦은 헛 재파싱 회피).
    if (prev_mtime != 0 and mtime == prev_mtime) return .{ .state = null, .answer_len = 0, .mtime = mtime };

    const tail = readTail(io, scratch_buf, path) orelse return .{ .state = .unknown, .answer_len = 0, .mtime = mtime };
    const status = switch (kind) {
        .claude => transcript.parseClaudeTail(gpa, tail, answer_buf),
        .codex => transcript.parseCodexTail(gpa, tail, answer_buf),
    };
    return .{ .state = status.state, .answer_len = status.answer.len, .mtime = mtime };
}

// ── claude: cwd 인코딩 디렉터리에서 최신 .jsonl ──────────────────────────────────────

/// claude 세션 파일 경로를 `path_buf`에 써서 돌려준다. `<root>/<enc(cwd)>/` 안 mtime이 가장 최신인 `.jsonl`.
/// 디렉터리가 없거나(해당 cwd 세션 없음) `.jsonl`이 없으면 null.
fn resolveClaude(io: std.Io, path_buf: []u8, root_path: []const u8, cwd: []const u8) ?[]const u8 {
    var name_buf: [4096]u8 = undefined;
    const enc = transcript.encodeClaudeProjectDir(&name_buf, cwd) orelse return null;

    var dir_path_buf: [4096]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_path_buf, "{s}/{s}", .{ root_path, enc }) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best_name_buf: [256]u8 = undefined;
    var best_name: ?[]const u8 = null;
    var best_mtime: i128 = std.math.minInt(i128);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const mt: i128 = st.mtime.nanoseconds;
        if (mt <= best_mtime) continue;
        if (entry.name.len > best_name_buf.len) continue; // 비정상적으로 긴 이름은 건너뜀
        best_mtime = mt;
        @memcpy(best_name_buf[0..entry.name.len], entry.name);
        best_name = best_name_buf[0..entry.name.len];
    }
    const name = best_name orelse return null;
    return std.fmt.bufPrint(path_buf, "{s}/{s}/{s}", .{ root_path, enc, name }) catch null;
}

// ── codex: 최신 날짜 디렉터리에서 cwd 일치 최신 rollout ───────────────────────────────

/// codex 세션 파일 경로를 `path_buf`에 써서 돌려준다. `<root>/<YYYY>/<MM>/<DD>/`(가장 최신 날짜)의
/// `rollout-*.jsonl` 중 첫 줄 session_meta.cwd가 `cwd`와 같은 최신 파일. 못 찾으면 null. 날짜 분할이라 cwd로
/// 디렉터리를 바로 못 찾으므로 최신 날짜 디렉터리만 훑는다 — 자정을 넘긴 장수명 세션은 못 찾을 수 있다(한계).
fn resolveCodex(io: std.Io, gpa: std.mem.Allocator, path_buf: []u8, scratch_buf: []u8, root_path: []const u8, cwd: []const u8) ?[]const u8 {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var y_buf: [32]u8 = undefined;
    const year = newestSubdir(io, root, &y_buf) orelse return null;
    var year_dir = root.openDir(io, year, .{ .iterate = true }) catch return null;
    defer year_dir.close(io);

    var m_buf: [32]u8 = undefined;
    const month = newestSubdir(io, year_dir, &m_buf) orelse return null;
    var month_dir = year_dir.openDir(io, month, .{ .iterate = true }) catch return null;
    defer month_dir.close(io);

    var d_buf: [32]u8 = undefined;
    const day = newestSubdir(io, month_dir, &d_buf) orelse return null;
    var day_dir = month_dir.openDir(io, day, .{ .iterate = true }) catch return null;
    defer day_dir.close(io);

    // 그 날 디렉터리의 rollout 중 cwd 일치 최신을 단일 패스로 찾는다. 현재 best보다 최신인 후보만 첫 줄 cwd를
    // 확인하므로(첫 줄 ~22KB read), 보통 최신 1~몇 개만 읽는다.
    var best_name_buf: [256]u8 = undefined;
    var best_name: ?[]const u8 = null;
    var best_mtime: i128 = std.math.minInt(i128);
    var it = day_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "rollout-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = day_dir.statFile(io, entry.name, .{}) catch continue;
        const mt: i128 = st.mtime.nanoseconds;
        if (mt <= best_mtime) continue; // 이미 더 최신 매칭이 있으면 첫 줄 read 생략
        const first_line = readFirstLine(io, scratch_buf, day_dir, entry.name) orelse continue;
        var cwd_buf: [4096]u8 = undefined;
        const got = transcript.parseCodexCwd(gpa, first_line, &cwd_buf) orelse continue;
        if (!std.mem.eql(u8, got, cwd)) continue;
        if (entry.name.len > best_name_buf.len) continue;
        best_mtime = mt;
        @memcpy(best_name_buf[0..entry.name.len], entry.name);
        best_name = best_name_buf[0..entry.name.len];
    }
    const name = best_name orelse return null;
    return std.fmt.bufPrint(path_buf, "{s}/{s}/{s}/{s}/{s}", .{ root_path, year, month, day, name }) catch null;
}

/// `parent` 안에서 이름이 사전순(=날짜 분할은 zero-pad라 수치순) 최대인 하위 디렉터리 이름을 `out`에 복사해
/// 돌려준다. 없으면 null. codex `<YYYY>/<MM>/<DD>/`에서 최신 날짜를 고를 때 쓴다.
fn newestSubdir(io: std.Io, parent: std.Io.Dir, out: []u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = parent.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > out.len) continue;
        if (best == null or std.mem.order(u8, entry.name, best.?) == .gt) {
            @memcpy(out[0..entry.name.len], entry.name);
            best = out[0..entry.name.len];
        }
    }
    return best;
}

// ── 파일 읽기(끝 tail / 첫 줄) ───────────────────────────────────────────────────────

/// `path` 파일의 끝 `tail_window` 바이트를 `buf`로 읽어 돌려준다(파일이 더 작으면 전체). 거대 파일을 통째로
/// 읽지 않으려고 seek 후 끝부분만 읽는다. 실패하면 null.
fn readTail(io: std.Io, buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var rbuf: [512]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const size = reader.getSize() catch return null;
    const start: u64 = if (size > tail_window) size - tail_window else 0;
    reader.seekTo(start) catch return null;
    const n = reader.interface.readSliceShort(buf) catch return null;
    return buf[0..n];
}

/// `dir`/`name` 파일의 첫 줄(개행 전까지)을 `buf`로 읽어 돌려준다. 첫 줄이 `buf`보다 길어 개행을 못 찾으면 null
/// (거대 첫 줄은 건너뜀). codex 세션 매핑용 session_meta 첫 줄(~22KB)을 읽는다.
fn readFirstLine(io: std.Io, buf: []u8, dir: std.Io.Dir, name: []const u8) ?[]const u8 {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var rbuf: [512]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    const n = reader.interface.readSliceShort(buf) catch return null;
    const chunk = buf[0..n];
    const nl = std.mem.indexOfScalar(u8, chunk, '\n') orelse return null;
    return chunk[0..nl];
}

// ── 테스트(macOS, temp dir 통합) ─────────────────────────────────────────────────────
// session core 순수 파싱은 agent_transcript.zig가 fixture로 검증한다. 여기선 platform I/O 글루(디렉터리 나열·
// 최신 파일 선택·tail seek read·codex 날짜 walk + cwd 매칭)를 temp dir에 실제 파일을 만들어 검증한다.

test "poll claude: enc(cwd) 디렉터리의 최신 .jsonl을 tail-read해 idle + 답변" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // <tmp>/projects/-a-b/ 에 두 세션. 최신(running 마커) vs 옛것. 최신이 골라져야 한다.
    try tmp.dir.createDirPath(io, "projects/-a-b");
    // 옛 세션: end_turn(idle) — 하지만 mtime이 더 옛것.
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/old.jsonl", .data =
        \\{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"옛 답변"}]}}
    });
    // 최신 세션: 마지막이 user → running. mtime을 확실히 더 늦게(세션 코어는 mtime 안 보지만 selector가 본다).
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/new.jsonl", .data =
        \\{"type":"user","message":{"role":"user","content":"q"}}
        \\{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"새 답변"}]}}
    });
    setMtime(io, tmp.dir, "projects/-a-b/old.jsonl", 1_000);
    setMtime(io, tmp.dir, "projects/-a-b/new.jsonl", 2_000);

    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "projects");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .claude, root, "/a/b", 0, &answer);
    try std.testing.expectEqual(State.idle, r.state.?);
    try std.testing.expectEqualStrings("새 답변", answer[0..r.answer_len]);
    // mtime을 그대로 다시 넘기면 재파싱 skip(state=null).
    const again = poll(io, std.testing.allocator, .claude, root, "/a/b", r.mtime, &answer);
    try std.testing.expectEqual(@as(?State, null), again.state);
}

test "poll claude: 디렉터리 없으면 unknown" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects");
    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "projects");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .claude, root, "/no/such", 0, &answer);
    try std.testing.expectEqual(State.unknown, r.state.?);
}

test "poll codex: 최신 날짜 디렉터리에서 cwd 일치 최신 rollout을 tail-read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // <tmp>/sessions/2026/06/18/ 에 두 rollout. 하나는 다른 cwd(무시), 하나는 우리 cwd(idle).
    try tmp.dir.createDirPath(io, "sessions/2026/06/18");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/18/rollout-other.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"o","cwd":"/other"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"남의 답변"}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/18/rollout-mine.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"m","cwd":"/Users/me/ws"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"내 답변 완료"}}
    });
    setMtime(io, tmp.dir, "sessions/2026/06/18/rollout-other.jsonl", 3_000);
    setMtime(io, tmp.dir, "sessions/2026/06/18/rollout-mine.jsonl", 2_000);

    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "sessions");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .codex, root, "/Users/me/ws", 0, &answer);
    try std.testing.expectEqual(State.idle, r.state.?); // 남의 세션이 더 최신이어도 cwd 매칭으로 내 세션 선택
    try std.testing.expectEqualStrings("내 답변 완료", answer[0..r.answer_len]);
}

// 테스트 helper: tmpDir 하위 경로를 cwd 기준 상대 경로 문자열로(`.zig-cache/tmp/<sub>/<rel>`).
fn tmpSubPath(buf: []u8, tmp: std.testing.TmpDir, rel: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, rel });
}

// 테스트 helper: 파일 mtime을 고정 나노초로 설정해 "최신" 선택을 결정론적으로 만든다.
fn setMtime(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, seconds: i64) void {
    const ts: std.Io.Timestamp = .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s };
    dir.setTimestamps(io, sub_path, .{ .access_timestamp = .{ .new = ts }, .modify_timestamp = .{ .new = ts } }) catch {};
}
