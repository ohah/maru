//! L4 platform adapter (macOS) — 에이전트 세션 트랜스크립트 *파일 찾기 + tail read*. session core
//! (src/session/agent_transcript.zig)가 바이트→상태를 순수하게 판정하고, 이 모듈은 그 바이트를 디스크에서
//! 가져오는 OS I/O만 맡는다(세션 파일 위치·디렉터리 나열·끝부분 seek read). 경로는 macOS 관례
//! (`~/.claude/projects`, `~/.codex/sessions`)지만 로직 자체는 경로만 바꾸면 다른 OS로 옮겨진다
//! (docs/agent-session.md "아키텍처/레이어" — platform adapter). 호출은 tick 스레드(pollAgentKinds) 단일 경로.
//!
//! 성능(docs/agent-session.md "성능"): 긴 트랜스크립트는 수백 MB가 될 수 있어 **절대 전체를 읽지 않는다** —
//! 파일 끝 tail_window 바이트만 seek해 읽고, 그 안 마지막 *대화/turn* 엔트리로 상태를 판정한다. mtime이 직전과
//! 같으면 tail read·재파싱을 건너뛴다(prev_mtime).
//!
//! 세션 파일 위치는 이제 **훅 매핑**(src/platform/macos/agent_hooks.zig)이 준다 — 라이브 poll은 `transcript_path`를
//! 직접 받고(cwd/mtime 추측 없음), workspace restore의 종료 시점 id 캡처도 그 경로에서 뽑는다(`sessionIdFromTranscript`
//! — claude=파일명 uuid, codex=첫 줄 session_meta.id). 옛 cwd+mtime/날짜-스캔 탐색(`resolveClaude`/`resolveCodex`)은
//! 훅으로 대체돼 제거됐다.

const std = @import("std");
const maru = @import("maru");

const transcript = maru.session.agent_transcript;

pub const State = transcript.AgentState;

/// 어느 에이전트의 트랜스크립트인지. agent_resume.Kind를 재사용한다(claude/codex 구분 단일 출처 — 별도 enum과
/// 수동 변환 제거). `none`(포그라운드가 에이전트 아님)은 호출자가 처리한다 — 여기 오는 건 claude/codex뿐이고,
/// 세션 파일 위치·파서가 다르다.
pub const Kind = maru.app.agent_resume.Kind;

pub const Poll = struct {
    /// 새로 계산한 상태. `null`이면 세션 파일 mtime이 `prev_mtime`과 같아 재파싱을 건너뛴 것 — 호출자는 직전
    /// 상태를 유지한다(docs/agent-session.md "성능": mtime 안 바뀌면 재파싱 skip).
    state: ?State,
    /// `state`가 non-null이고 idle일 때 `answer_buf`에 쓴 마지막 답변 첫 줄 길이(running/unknown이면 0).
    answer_len: usize,
    /// 찾은 세션 파일의 mtime(나노초). 못 찾으면 0. 호출자가 캐시해 다음 poll에 `prev_mtime`으로 넘긴다.
    mtime: i128,
    /// 매핑된 트랜스크립트 **파일 자체가 없음**(`FileNotFound`) = 그 세션이 사라짐(경로는 세션 내내 고정이라 회전 아님 —
    /// docs/agent-session.md "매핑된 트랜스크립트 부재"). 일반 unknown(불완전 tail=일시적, 직전 상태 보존)과 구분해,
    /// 호출자가 stale 매핑을 파기하고 stuck 상태(삭제된 running이 스피너 안 풀림)를 리셋하게 한다.
    missing: bool = false,
};

/// codex tail/첫 줄 읽기용 창 크기. codex는 마지막 엔트리가 task_complete(명시적 완료)라 끝부분만으로 충분하다.
/// claude는 마지막 assistant 턴이 대량 비-대화 엔트리(attachment·file-history-snapshot 등)에 밀릴 수 있어
/// readTailScan으로 끝에서부터 더 거슬러 읽는다(아래). 거대 파일을 통째로 읽지 않게 둘 다 작게 유지한다.
const tail_window: usize = 64 * 1024;

/// claude readTailScan의 첫 청크 크기와 상한. 끝에서 tail_chunk부터 지수 확장하며 마지막 대화 엔트리(assistant
/// stop_reason / non-meta user)를 찾고, tail_cap까지 못 찾으면 unknown(사실상 죽은 세션 — 거대 파일 통째
/// 읽기 방지 안전판). 실측: 활성 세션도 마지막 assistant가 끝에서 ~800KB까지 밀릴 수 있어 64KB로는 부족했다.
const tail_chunk: usize = 256 * 1024;
const tail_cap: usize = 8 * 1024 * 1024;

fn unknownPoll() Poll {
    return .{ .state = .unknown, .answer_len = 0, .mtime = 0 };
}

/// 매핑된 트랜스크립트 파일이 없음(`FileNotFound`) — 세션 gone. 호출자가 stale 매핑 파기 + 상태 리셋에 쓴다.
fn missingPoll() Poll {
    return .{ .state = .unknown, .answer_len = 0, .mtime = 0, .missing = true };
}

/// 에이전트 세션 트랜스크립트 파일(`transcript_path`)의 tail을 읽어 상태·마지막 답변을 계산한다. 경로는
/// **agent_hooks.readMapping**이 준다 — 에이전트 SessionStart 훅이 `MARU_PANE_ID`로 남긴 정확한 경로라, 같은
/// cwd 다중 세션도 팬별 정확 매칭이다(cwd 추측·mtime 폴백 없음 — docs/agent-session.md "훅 매핑"). `gpa`는 tail
/// 버퍼·줄 파싱용 임시 할당(즉시 해제), `answer_buf`엔 idle일 때 답변을 쓴다. `transcript_path`가 null(훅 매핑 없음)
/// 이거나 파일이 없으면 state=unknown.
pub fn poll(
    io: std.Io,
    gpa: std.mem.Allocator,
    kind: Kind,
    prev_mtime: i128,
    answer_buf: []u8,
    transcript_path: ?[]const u8,
) Poll {
    const path = transcript_path orelse return unknownPoll();

    // 파일 자체가 없음(FileNotFound) = 세션 gone → missing(호출자가 stale 매핑 파기 + 상태 리셋). 그 외 stat 오류
    // (EACCES 등)는 일시적일 수 있어 unknown(직전 상태 보존). 경로는 세션 내내 고정이라 부재=삭제, 회전이 아니다.
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return missingPoll(),
        else => return unknownPoll(),
    };
    const mtime: i128 = st.mtime.nanoseconds;
    // mtime 안 바뀌었으면 tail read·재파싱을 건너뛴다(느린 API 중 잦은 헛 재파싱 회피).
    if (prev_mtime != 0 and mtime == prev_mtime) return .{ .state = null, .answer_len = 0, .mtime = mtime };

    // **둘 다 지수 확장 스캔**한다. 예전엔 codex만 고정 64KB tail이었는데("마지막이 task_complete라 충분"),
    // 실측 codex rollout의 **한 줄이 2.9MB**에 이른다(중단된 명령의 exec_command_end가 캡처 출력을 통째로 싣는다).
    // 그러면 그 한 줄이 64KB 창을 통째로 밀어내 `turn_aborted` 마커가 창 밖으로 사라지고, 인터럽트 latch가 안 걸려
    // 상태가 running으로 되돌아간다 — 파일은 더 안 자라니 mtime 게이트가 재파싱도 막아 **스피너가 영구 고착**된다
    // (이 수정이 없애려던 바로 그 버그, code-review). claude가 같은 부류의 절단에서 안전한 이유가 이 스캔이다.
    const status = readTailScan(io, gpa, kind, path, answer_buf) orelse
        return .{ .state = .unknown, .answer_len = 0, .mtime = mtime };
    return .{ .state = status.state, .answer_len = status.answer.len, .mtime = mtime };
}

/// 훅 매핑이 준 **정확한 트랜스크립트 경로**에서 그 세션의 **세션 id**를 뽑아 `out`에 복사해 돌려준다 — workspace
/// restore가 종료 시점에 resume 대상 id를 캡처하는 용도(docs/workspace-restore.md "에이전트 세션 자동 resume").
/// 라이브 poll과 같은 훅 경로를 쓰므로 **cwd+mtime 추측이 없다** → 같은 폴더 다중 세션도 팬별 정확. claude는 파일명이
/// 곧 `<uuid>.jsonl`이라 확장자만 떼고, codex는 rollout 첫 줄 `session_meta.payload.id`를 읽는다(파일명의 uuid와 별개일
/// 수 있어 첫 줄이 정본). 경로가 비정상이거나 id를 못 구하면 null(호출자는 폴백 resume으로 degrade). tick이 멈춘 종료
/// 시점 호출. `gpa`는 codex 첫 줄 read·JSON 파싱용 임시 할당(즉시 해제).
pub fn sessionIdFromTranscript(io: std.Io, gpa: std.mem.Allocator, kind: Kind, transcript_path: []const u8, out: []u8) ?[]const u8 {
    switch (kind) {
        .claude => {
            const base = std.fs.path.basename(transcript_path); // "<uuid>.jsonl"
            if (!std.mem.endsWith(u8, base, ".jsonl")) return null;
            // 파일이 실제로 있어야 resume 가능(삭제·회전된 매핑이면 non-resumable id를 저장하지 않게 — codex는 아래에서
            // 첫 줄을 읽어 자연히 걸러지지만 claude는 파일명만 쓰므로 명시 stat).
            _ = std.Io.Dir.cwd().statFile(io, transcript_path, .{}) catch return null;
            const id = base[0 .. base.len - ".jsonl".len];
            if (id.len == 0 or id.len > out.len) return null;
            @memcpy(out[0..id.len], id);
            return out[0..id.len];
        },
        .codex => {
            // codex resume id = 첫 줄 session_meta.payload.id. readFirstLine이 full path로 직접 열어 첫 줄을 읽는다
            // (파일 없으면 null → 삭제·회전 매핑 자연 차단). 옛 dir/name 쪼개기+openDir 제거.
            const scratch = gpa.alloc(u8, tail_window) catch return null;
            defer gpa.free(scratch);
            const first = readFirstLine(io, scratch, transcript_path) orelse return null;
            var id_buf: [256]u8 = undefined;
            const id = transcript.parseCodexId(gpa, first, &id_buf) orelse return null;
            if (id.len == 0 or id.len > out.len) return null;
            @memcpy(out[0..id.len], id);
            return out[0..id.len];
        },
    }
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

/// claude 트랜스크립트의 마지막 대화 엔트리(assistant stop_reason / non-meta user)를 찾아 상태를 판정한다. 끝에서
/// `tail_chunk`부터 지수 확장(→2×→…→`tail_cap`)하며 매번 "끝 window 바이트"를 통읽어 parseClaudeTail에 넣고,
/// unknown이 아니면 멈춘다. 파서가 잘린 선두 줄을 skip하므로(parseFromSlice 실패 = skip) 청크 경계가 줄을 잘라도
/// 안전하다 — 다음 더 큰 window가 그 줄을 온전히 포함한다. 활성 세션의 흔한 경우는 첫 청크로 끝나고, 마지막 턴이
/// 멀 때만 확장한다. 파일을 못 열면 null(호출자가 unknown 처리). 매 청크 gpa.alloc/free — tick 0.5s 간격이라 무시.
fn readTailScan(io: std.Io, gpa: std.mem.Allocator, kind: Kind, path: []const u8, answer_buf: []u8) ?transcript.Status {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var size_rbuf: [512]u8 = undefined;
    var size_reader = file.reader(io, &size_rbuf);
    const size: usize = @intCast(size_reader.getSize() catch return null);

    var window: usize = tail_chunk;
    while (true) {
        const read_len: usize = @min(window, size);
        const start: usize = size - read_len;
        const buf = gpa.alloc(u8, read_len) catch return null;
        defer gpa.free(buf);
        var rbuf: [512]u8 = undefined;
        var reader = file.reader(io, &rbuf);
        reader.seekTo(@intCast(start)) catch return null;
        const n = reader.interface.readSliceShort(buf) catch return null;
        const status = switch (kind) {
            .claude => transcript.parseClaudeTail(gpa, buf[0..n], answer_buf),
            .codex => transcript.parseCodexTail(gpa, buf[0..n], answer_buf),
        };
        // 마지막 대화/turn 엔트리를 찾았거나(non-unknown), 파일 전체를 봤거나, 상한 도달이면 멈춘다.
        if (status.state != .unknown or read_len >= size or window >= tail_cap) return status;
        window = @min(window * 2, tail_cap);
    }
}

/// `path` 파일의 첫 줄(개행 전까지)을 `buf`로 읽어 돌려준다. 첫 줄이 `buf`보다 길어 개행을 못 찾으면 null(거대 첫 줄은
/// 건너뜀). codex resume id용 session_meta 첫 줄(~22KB)을 읽는다. readTail처럼 full path로 직접 연다(호출자 dir 쪼개기 불요).
fn readFirstLine(io: std.Io, buf: []u8, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
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

test "poll claude: transcript_path의 세션을 tail-read해 idle + 답변, mtime 같으면 skip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects/-a-b");
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/s.jsonl", .data =
        \\{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"내 답변"}]}}
    });
    setMtime(io, tmp.dir, "projects/-a-b/s.jsonl", 2_000);
    var path_buf: [4096]u8 = undefined;
    const path = try tmpSubPath(&path_buf, tmp, "projects/-a-b/s.jsonl");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .claude, 0, &answer, path);
    try std.testing.expectEqual(State.idle, r.state.?);
    try std.testing.expectEqualStrings("내 답변", answer[0..r.answer_len]);
    // mtime 같으면 재파싱 skip(state=null).
    const again = poll(io, std.testing.allocator, .claude, r.mtime, &answer, path);
    try std.testing.expectEqual(@as(?State, null), again.state);
}

test "poll: null 매핑=unknown(missing 아님), 삭제된 파일=missing(세션 gone)" {
    const io = std.testing.io;
    var answer: [192]u8 = undefined;
    // 매핑 자체가 없음(null) = 훅 미발화 창 → unknown, missing=false(직전 상태 보존, 파기 안 함).
    const none = poll(io, std.testing.allocator, .claude, 0, &answer, null);
    try std.testing.expectEqual(State.unknown, none.state.?);
    try std.testing.expect(!none.missing);
    // 매핑은 있는데 가리키는 트랜스크립트 파일이 없음(FileNotFound) = 세션 gone → missing=true(호출자가 매핑 파기·리셋).
    const gone = poll(io, std.testing.allocator, .claude, 0, &answer, "/no/such/s.jsonl");
    try std.testing.expectEqual(State.unknown, gone.state.?);
    try std.testing.expect(gone.missing);
    // codex도 동일 — null=unknown/미parse, 없는 파일=missing.
    try std.testing.expect(!poll(io, std.testing.allocator, .codex, 0, &answer, null).missing);
    try std.testing.expect(poll(io, std.testing.allocator, .codex, 0, &answer, "/no/such/r.jsonl").missing);
}

test "poll codex: transcript_path의 rollout을 tail-read해 idle + 답변" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sessions/2026/06/18");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/18/rollout-mine.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"m","cwd":"/Users/me/ws"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"내 답변 완료"}}
    });
    var path_buf: [4096]u8 = undefined;
    const path = try tmpSubPath(&path_buf, tmp, "sessions/2026/06/18/rollout-mine.jsonl");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .codex, 0, &answer, path);
    try std.testing.expectEqual(State.idle, r.state.?);
    try std.testing.expectEqualStrings("내 답변 완료", answer[0..r.answer_len]);
}

test "poll claude: 마지막 assistant가 첫 청크보다 멀어도 readTailScan 확장으로 idle" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects/-a-b");
    // 마지막 assistant(end_turn)를 파일 맨 앞에 두고, 뒤에 첫 청크(tail_chunk=256KB)를 넘는 무시되는 메타 꼬리를
    // 붙인다 → 끝 256KB엔 assistant가 없어 첫 청크는 unknown, 확장(512KB=전체)에서 assistant를 봐 idle이어야 한다.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a,
        \\{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"스캔 답변"}]}}
    );
    try buf.append(a, '\n');
    const filler = "{\"type\":\"file-history-snapshot\",\"snapshot\":\"" ++ ("x" ** 4096) ++ "\"}\n"; // 무시되는 메타 줄
    while (buf.items.len < 300 * 1024) try buf.appendSlice(a, filler);
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/s.jsonl", .data = buf.items });
    var path_buf: [4096]u8 = undefined;
    const path = try tmpSubPath(&path_buf, tmp, "projects/-a-b/s.jsonl");
    var answer: [192]u8 = undefined;
    const r = poll(io, a, .claude, 0, &answer, path);
    try std.testing.expectEqual(State.idle, r.state.?);
    try std.testing.expectEqualStrings("스캔 답변", answer[0..r.answer_len]);
}

test "poll claude: 대화 엔트리 없이 메타만이면 unknown(스캔 무한루프 없이 종료)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects/-a-b");
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/s.jsonl", .data =
        \\{"type":"file-history-snapshot","x":1}
        \\{"type":"system","x":2}
    });
    var path_buf: [4096]u8 = undefined;
    const path = try tmpSubPath(&path_buf, tmp, "projects/-a-b/s.jsonl");
    var answer: [192]u8 = undefined;
    const r = poll(io, std.testing.allocator, .claude, 0, &answer, path);
    try std.testing.expectEqual(State.unknown, r.state.?);
}

test "sessionIdFromTranscript claude: 파일명 <uuid>.jsonl에서 세션 id, 없는 파일/비-.jsonl은 null" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects/-a-b");
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/23cb4875-83e6-4e9e-b37f-6e1112d5fff9.jsonl", .data = "{}" });
    var pbuf: [4096]u8 = undefined;
    const path = try tmpSubPath(&pbuf, tmp, "projects/-a-b/23cb4875-83e6-4e9e-b37f-6e1112d5fff9.jsonl");
    var out: [256]u8 = undefined;
    const id = sessionIdFromTranscript(io, std.testing.allocator, .claude, path, &out).?;
    try std.testing.expectEqualStrings("23cb4875-83e6-4e9e-b37f-6e1112d5fff9", id);
    // 파일이 없으면 null(삭제·회전 매핑 → non-resumable id 저장 방지, stat 검사).
    try std.testing.expectEqual(@as(?[]const u8, null), sessionIdFromTranscript(io, std.testing.allocator, .claude, "/no/such/23cb4875.jsonl", &out));
    // 비-.jsonl 경로 → null.
    try std.testing.expectEqual(@as(?[]const u8, null), sessionIdFromTranscript(io, std.testing.allocator, .claude, "/x/notjsonl", &out));
}

test "sessionIdFromTranscript codex: rollout 첫 줄 session_meta.payload.id, 없는 파일이면 null" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sessions/2026/06/18");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/18/rollout-mine.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"019e8298-f7bf-7b63-b9a4-46626868c072","cwd":"/Users/me/ws"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}
    });
    var pbuf: [4096]u8 = undefined;
    const path = try tmpSubPath(&pbuf, tmp, "sessions/2026/06/18/rollout-mine.jsonl");
    var out: [256]u8 = undefined;
    const id = sessionIdFromTranscript(io, std.testing.allocator, .codex, path, &out).?;
    try std.testing.expectEqualStrings("019e8298-f7bf-7b63-b9a4-46626868c072", id);
    // 없는 파일 → null(폴백 degrade).
    try std.testing.expectEqual(@as(?[]const u8, null), sessionIdFromTranscript(io, std.testing.allocator, .codex, "/no/such/rollout.jsonl", &out));
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
