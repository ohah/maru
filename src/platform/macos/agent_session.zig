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

/// codex 세션 탐색 상한 — 자정/월말/연말을 넘긴 장수명 세션도 찾도록 최근 연(top)·월(top)·day(존재 기준)를
/// 최신순으로 훑되, 방문 day 디렉터리 수를 제한해 비용을 묶는다(docs/agent-session.md "성능"). 14 = 빈 날을
/// 안 세므로 보통 수 주를 커버. 매우 오래된 세션은 못 찾으나 그건 사실상 죽은 세션이다.
const codex_topk_year: usize = 2;
const codex_topk_month: usize = 2;
const codex_max_day_dirs: usize = 14;

/// codex 날짜 디렉터리 수집 버퍼 — 한 레벨(연/월/일)의 이름을 모아 최신순 정렬한다. 이름은 YYYY/MM/DD라 짧고(≤8),
/// 한 레벨 개수도 적다(연 수개·월 12·일 31). cap은 day 31 + 여유.
const subdir_name_max: usize = 8;
const subdir_collect_cap: usize = 40;

fn unknownPoll() Poll {
    return .{ .state = .unknown, .answer_len = 0, .mtime = 0 };
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

    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return unknownPoll();
    const mtime: i128 = st.mtime.nanoseconds;
    // mtime 안 바뀌었으면 tail read·재파싱을 건너뛴다(느린 API 중 잦은 헛 재파싱 회피).
    if (prev_mtime != 0 and mtime == prev_mtime) return .{ .state = null, .answer_len = 0, .mtime = mtime };

    const status = switch (kind) {
        // claude는 마지막 assistant 턴이 대량 메타 엔트리에 밀릴 수 있어 끝에서부터 지수 확장 스캔한다.
        .claude => readTailScan(io, gpa, path, answer_buf) orelse return .{ .state = .unknown, .answer_len = 0, .mtime = mtime },
        // codex는 마지막이 task_complete라 끝 tail_window로 충분(tick마다 alloc/free — 0.5s 간격이라 무시 가능).
        .codex => brk: {
            const sc = gpa.alloc(u8, tail_window) catch return .{ .state = .unknown, .answer_len = 0, .mtime = mtime };
            defer gpa.free(sc);
            const tail = readTail(io, sc, path) orelse return .{ .state = .unknown, .answer_len = 0, .mtime = mtime };
            break :brk transcript.parseCodexTail(gpa, tail, answer_buf);
        },
    };
    return .{ .state = status.state, .answer_len = status.answer.len, .mtime = mtime };
}

/// 에이전트 종류·cwd로 세션 파일을 찾아 그 **세션 id**를 `out`으로 복사해 돌려준다 — workspace restore가 종료
/// 시점에 resume 대상 id를 캡처하는 용도(docs/workspace-restore.md "에이전트 세션 자동 resume"). claude는 세션
/// 파일명이 곧 `<uuid>.jsonl`이라 파일명에서 확장자만 떼고, codex는 rollout 첫 줄 `session_meta.payload.id`를
/// 읽는다. 세션을 못 찾거나 id가 비정상이면 null(호출자는 폴백 resume으로 degrade). poll과 같은 tick 스레드 단일
/// 경로. `gpa`는 codex 첫 줄 read·JSON 파싱용 임시 할당(즉시 해제), `out`엔 id를 복사해 그 슬라이스를 돌려준다.
pub fn resolveSessionId(io: std.Io, gpa: std.mem.Allocator, kind: Kind, root_path: []const u8, cwd: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    switch (kind) {
        .claude => {
            const path = resolveClaude(io, &path_buf, root_path, cwd) orelse return null;
            const base = std.fs.path.basename(path); // "<uuid>.jsonl"
            if (!std.mem.endsWith(u8, base, ".jsonl")) return null;
            const id = base[0 .. base.len - ".jsonl".len];
            if (id.len == 0 or id.len > out.len) return null;
            @memcpy(out[0..id.len], id);
            return out[0..id.len];
        },
        .codex => {
            const scratch = gpa.alloc(u8, tail_window) catch return null;
            defer gpa.free(scratch);
            const path = resolveCodex(io, gpa, &path_buf, scratch, root_path, cwd) orelse return null;
            // resolveCodex가 고른 파일의 첫 줄을 다시 읽어 id를 파싱한다(종료 시 1회 — 재읽기 사이 파일이 회전/절단
            // 되면 null→폴백 resume으로 graceful). path를 dir/name으로 쪼개 readFirstLine을 재사용한다(중복 제거).
            const dir_path = std.fs.path.dirname(path) orelse return null;
            var pdir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
            defer pdir.close(io);
            const first = readFirstLine(io, scratch, pdir, std.fs.path.basename(path)) orelse return null;
            var id_buf: [256]u8 = undefined;
            const id = transcript.parseCodexId(gpa, first, &id_buf) orelse return null;
            if (id.len == 0 or id.len > out.len) return null;
            @memcpy(out[0..id.len], id);
            return out[0..id.len];
        },
    }
}

// ── claude: cwd 인코딩 디렉터리에서 최신 .jsonl (워크스페이스 restore 전용) ─────────────────────

/// claude 세션 파일 경로를 `path_buf`에 써서 돌려준다 — `<root>/<enc(cwd)>/` 안 mtime이 가장 최신인 `.jsonl`.
/// **라이브 상태 poll은 이제 훅 매핑(정확한 경로)을 쓰므로 이 함수는 `resolveSessionId`(워크스페이스 restore의 종료
/// 시점 resume 대상 캡처) 전용이다.** 디렉터리가 없거나 `.jsonl`이 없으면 null.
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

// ── codex: 최근 날짜 디렉터리들에서 cwd 일치 최신 rollout ──────────────────────────────

/// codex 세션 파일 경로를 `path_buf`에 써서 돌려준다. codex는 `<root>/<YYYY>/<MM>/<DD>/`로 날짜 분할이라 cwd로
/// 디렉터리를 바로 못 찾는다. 최신 날짜 하나만 보면 자정·월말·연말을 넘긴 세션을 놓치므로, 연(top)·월(top)·day를
/// **최신순으로 평탄 순회**하며 첫 줄 session_meta.cwd가 일치하는 최신 rollout을 찾는다(최신순이라 첫 매칭=전역
/// 최신). 방문 day 디렉터리 수는 `codex_max_day_dirs`로 제한해 비용을 묶는다(빈 날은 안 셈). 못 찾으면 null.
fn resolveCodex(io: std.Io, gpa: std.mem.Allocator, path_buf: []u8, scratch_buf: []u8, root_path: []const u8, cwd: []const u8) ?[]const u8 {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);

    var years: [subdir_collect_cap][subdir_name_max]u8 = undefined;
    var year_lens: [subdir_collect_cap]usize = undefined;
    const n_years = collectSubdirsDesc(io, root, &years, &year_lens);

    var days_visited: usize = 0;
    var yi: usize = 0;
    while (yi < n_years and yi < codex_topk_year) : (yi += 1) {
        const year = years[yi][0..year_lens[yi]];
        var year_dir = root.openDir(io, year, .{ .iterate = true }) catch continue;
        defer year_dir.close(io);

        var months: [subdir_collect_cap][subdir_name_max]u8 = undefined;
        var month_lens: [subdir_collect_cap]usize = undefined;
        const n_months = collectSubdirsDesc(io, year_dir, &months, &month_lens);

        var mi: usize = 0;
        while (mi < n_months and mi < codex_topk_month) : (mi += 1) {
            const month = months[mi][0..month_lens[mi]];
            var month_dir = year_dir.openDir(io, month, .{ .iterate = true }) catch continue;
            defer month_dir.close(io);

            var days: [subdir_collect_cap][subdir_name_max]u8 = undefined;
            var day_lens: [subdir_collect_cap]usize = undefined;
            const n_days = collectSubdirsDesc(io, month_dir, &days, &day_lens);

            var di: usize = 0;
            while (di < n_days) : (di += 1) {
                if (days_visited >= codex_max_day_dirs) return null; // 상한 — 더 오래된 세션은 사실상 죽은 것.
                days_visited += 1;
                const day = days[di][0..day_lens[di]];
                var day_dir = month_dir.openDir(io, day, .{ .iterate = true }) catch continue;
                defer day_dir.close(io);
                var name_buf: [256]u8 = undefined;
                if (scanDayForCwd(io, gpa, day_dir, scratch_buf, cwd, &name_buf)) |name| {
                    return std.fmt.bufPrint(path_buf, "{s}/{s}/{s}/{s}/{s}", .{ root_path, year, month, day, name }) catch null;
                }
            }
        }
    }
    return null;
}

/// `day_dir`의 `rollout-*.jsonl` 중 첫 줄 session_meta.cwd가 `cwd`와 같은 mtime 최신 파일 이름을 `out_name`에 복사해
/// 돌려준다(없으면 null). 현재 best보다 최신인 후보만 첫 줄(~22KB)을 읽어 매칭하므로 보통 최신 1~몇 개만 읽는다.
fn scanDayForCwd(io: std.Io, gpa: std.mem.Allocator, day_dir: std.Io.Dir, scratch_buf: []u8, cwd: []const u8, out_name: []u8) ?[]const u8 {
    var best_len: usize = 0;
    var best_mtime: i128 = std.math.minInt(i128);
    var found = false;
    var it = day_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "rollout-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = day_dir.statFile(io, entry.name, .{}) catch continue;
        const mt: i128 = st.mtime.nanoseconds;
        if (found and mt <= best_mtime) continue; // 이미 더 최신 매칭이 있으면 첫 줄 read 생략
        const first_line = readFirstLine(io, scratch_buf, day_dir, entry.name) orelse continue;
        var cwd_buf: [4096]u8 = undefined;
        const got = transcript.parseCodexCwd(gpa, first_line, &cwd_buf) orelse continue;
        if (!std.mem.eql(u8, got, cwd)) continue;
        if (entry.name.len > out_name.len) continue;
        best_mtime = mt;
        @memcpy(out_name[0..entry.name.len], entry.name);
        best_len = entry.name.len;
        found = true;
    }
    return if (found) out_name[0..best_len] else null;
}

/// `parent`의 하위 디렉터리 이름들을 사전순(=zero-pad 날짜라 수치순) **내림차순**으로 `names`/`lens`에 채운다.
/// 반환=개수(최대 subdir_collect_cap). codex 날짜 디렉터리(YYYY/MM/DD)를 최신순으로 훑는 단일 출처 — iterate
/// 순서는 불정이라 직접 정렬해 최신순을 보장한다. 한 레벨 개수가 적어(연·월·일) 삽입정렬로 충분하다.
fn collectSubdirsDesc(io: std.Io, parent: std.Io.Dir, names: *[subdir_collect_cap][subdir_name_max]u8, lens: *[subdir_collect_cap]usize) usize {
    var count: usize = 0;
    var it = parent.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name.len > subdir_name_max) continue;
        if (count >= subdir_collect_cap) break;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lens[count] = entry.name.len;
        count += 1;
    }
    // 내림차순 삽입정렬(count는 작아 O(n^2) 무방). 이름 + 길이를 함께 옮긴다.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var name_tmp: [subdir_name_max]u8 = undefined;
        const len_tmp = lens[i];
        @memcpy(name_tmp[0..len_tmp], names[i][0..len_tmp]);
        var j: usize = i;
        while (j > 0 and std.mem.order(u8, names[j - 1][0..lens[j - 1]], name_tmp[0..len_tmp]) == .lt) : (j -= 1) {
            const prev_len = lens[j - 1];
            @memcpy(names[j][0..prev_len], names[j - 1][0..prev_len]);
            lens[j] = prev_len;
        }
        @memcpy(names[j][0..len_tmp], name_tmp[0..len_tmp]);
        lens[j] = len_tmp;
    }
    return count;
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
fn readTailScan(io: std.Io, gpa: std.mem.Allocator, path: []const u8, answer_buf: []u8) ?transcript.Status {
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
        const status = transcript.parseClaudeTail(gpa, buf[0..n], answer_buf);
        // 마지막 대화 엔트리를 찾았거나(non-unknown), 파일 전체를 봤거나, 상한 도달이면 멈춘다.
        if (status.state != .unknown or read_len >= size or window >= tail_cap) return status;
        window = @min(window * 2, tail_cap);
    }
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

test "poll: transcript_path가 null이거나 없는 파일이면 unknown(훅 매핑 없음)" {
    const io = std.testing.io;
    var answer: [192]u8 = undefined;
    try std.testing.expectEqual(State.unknown, poll(io, std.testing.allocator, .claude, 0, &answer, null).state.?);
    try std.testing.expectEqual(State.unknown, poll(io, std.testing.allocator, .claude, 0, &answer, "/no/such/s.jsonl").state.?);
    try std.testing.expectEqual(State.unknown, poll(io, std.testing.allocator, .codex, 0, &answer, null).state.?);
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

test "resolveSessionId codex: 자정 넘긴 과거 날짜 세션을 다중 day 스캔으로 찾는다(restore)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 더 최신 날짜(06/20)엔 타 cwd 세션만, 내 세션은 과거(06/13)에 — 단일-최신 로직이면 06/20만 보고 못 찾는다.
    try tmp.dir.createDirPath(io, "sessions/2026/06/20");
    try tmp.dir.createDirPath(io, "sessions/2026/06/13");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/20/rollout-other.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"019e8298-f7bf-7b63-b9a4-46626868c0ff","cwd":"/other"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"남"}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/13/rollout-mine.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"019e8298-f7bf-7b63-b9a4-46626868c072","cwd":"/Users/me/ws"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"내"}}
    });
    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "sessions");
    var id_buf: [256]u8 = undefined;
    const id = resolveSessionId(io, std.testing.allocator, .codex, root, "/Users/me/ws", &id_buf).?;
    try std.testing.expectEqualStrings("019e8298-f7bf-7b63-b9a4-46626868c072", id);
}

test "resolveSessionId claude: 최신 .jsonl 파일명에서 세션 id(확장자 제거)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects/-a-b");
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/old.jsonl", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "projects/-a-b/23cb4875-83e6-4e9e-b37f-6e1112d5fff9.jsonl", .data = "{}" });
    setMtime(io, tmp.dir, "projects/-a-b/old.jsonl", 1_000);
    setMtime(io, tmp.dir, "projects/-a-b/23cb4875-83e6-4e9e-b37f-6e1112d5fff9.jsonl", 2_000);
    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "projects");
    var id_buf: [256]u8 = undefined;
    const id = resolveSessionId(io, std.testing.allocator, .claude, root, "/a/b", &id_buf).?;
    try std.testing.expectEqualStrings("23cb4875-83e6-4e9e-b37f-6e1112d5fff9", id);
}

test "resolveSessionId codex: cwd 일치 rollout 첫 줄 session_meta.id" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sessions/2026/06/18");
    try tmp.dir.writeFile(io, .{ .sub_path = "sessions/2026/06/18/rollout-mine.jsonl", .data =
        \\{"type":"session_meta","payload":{"id":"019e8298-f7bf-7b63-b9a4-46626868c072","cwd":"/Users/me/ws"}}
        \\{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}
    });
    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "sessions");
    var id_buf: [256]u8 = undefined;
    const id = resolveSessionId(io, std.testing.allocator, .codex, root, "/Users/me/ws", &id_buf).?;
    try std.testing.expectEqualStrings("019e8298-f7bf-7b63-b9a4-46626868c072", id);
}

test "resolveSessionId: 세션 못 찾으면 null(폴백 degrade)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "projects");
    var root_buf: [4096]u8 = undefined;
    const root = try tmpSubPath(&root_buf, tmp, "projects");
    var id_buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), resolveSessionId(io, std.testing.allocator, .claude, root, "/no/such", &id_buf));
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
