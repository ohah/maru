//! 에이전트 관측 — 상태·종류·트랜스크립트 폴링, 상태줄 조정, 스피너, 사이드바 에이전트 행,
//! 세션 재개.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F14).
//!
//! **에이전트 세션 기록 도크는 여기가 아니다** — 그건 F1이 `agent_dock.zig`로 가져갔다. 이름이
//! `agentSessionArchive*`인 열 개는 본문이 `agent_dock.agentSessionDockSmokeProbe(self)` 같은 위임
//! 한 줄인 **F1의 ABI facade**라 제외했다(F8의 `scrollToCurrentMatch`와 같은 판단 — 남의 facade를
//! 옮기면 원본에서 멀어진다).
//!
//! 여기 있는 것은 **관측**이다. 에이전트가 무엇을 하고 있는지 주기적으로 읽어(`pollAgentKinds`·
//! `pollAgentState`·`pollAgentTranscript`) 상태줄과 사이드바 행에 반영한다. 읽기 자체는 worker
//! (`agent_observer`·`agent_transcript`)가 소유하고, 여기서는 그 결과를 메인 스레드 상태로 옮긴다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const git_ops = @import("git.zig");
const capture_file = @import("../capture_file.zig");
const turn_capture = maru.session.turn_capture;
const usableRestoreCwd = app_session_mod.usableRestoreCwd;
const writeExecutableFile = AppSession.writeExecutableFile;
const resolveConfiguredShell = app_session_mod.resolveConfiguredShell;
const writeStatusLineCommand = AppSession.writeStatusLineCommand;
const readStatusLineState = AppSession.readStatusLineState;
const turnStateOf = AppSession.turnStateOf;
const StatuslineLock = AppSession.StatuslineLock;
const agent_dock = app_session_mod.agent_dock;
const diag_gate = app_session_mod.diag_gate;
const readFileAlloc = AppSession.readFileAlloc;
const readFileState = AppSession.readFileState;
const sidebar_ops = @import("sidebar.zig");
const spawnRequest = app_session_mod.spawnRequest;
const agent_running_flag = app_session_mod.agent_running_flag;
const layout_math = app_session_mod.layout_math;
const sessionCacheBase = AppSession.sessionCacheBase;
const settings_ops = @import("settings.zig");
const spinner_wave = app_session_mod.spinner_wave;
const workspace_ops = @import("workspace.zig");
const AgentKind = app_session_mod.AgentKind;
const AgentTally = AppSession.AgentTally;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const WorkspaceSession = AppSession.WorkspaceSession;
const agent_session_archive_backend = app_session_mod.agent_session_archive_backend;
const git_backend_mod = app_session_mod.git_backend_mod;
const is_macos = app_session_mod.is_macos;
const pane_ops = @import("pane.zig");
const tab_ops = @import("tab.zig");
const image_gallery_ops = @import("image_gallery.zig");

/// 에이전트 턴이 끝났다 — 그 순간의 작업트리를 tree 하나로 굳힌다(§6.1). 실패하면 그냥 안 찍힌 것이고
/// 다음 턴에 다시 시도한다(스냅샷 실패가 목록·diff를 막지 않는다).
/// 테스트 전용 호출 카운터. 이 함수는 git 저장소가 없으면 **조용히 돌아가므로**, 결과(링)로는
/// «불렸는가» 를 볼 수 없다 — 훅 모드가 턴 끝에 이것을 부르는지는 호출 자체를 세야 알 수 있다.
/// 제품 빌드에서는 `comptime` 으로 사라진다(배타 카운터와 같은 규약).
pub var test_turn_snapshot_calls: usize = 0;

/// 이 캡처에 실을 **턴 키**. 턴이 끝났을 때만 있다.
///
/// ⚠️ **`progress.turnKey()` 를 그대로 넘기면 안 된다.** `Progress.reset()` 은 턴 키를 **일부러 남기는데**
/// (그 자체는 옳다 — 같은 턴의 다음 이벤트가 «키가 바뀌었다» 로 읽히면 매 이벤트마다 리셋이 돈다), 그래서
/// `SessionStart` 만 온 배치에서도 **직전 턴의 키**가 남아 있다. 그걸 base 에 실으면 계약이 「턴이 아니다」
/// 라고 정한 스냅샷에 턴 키가 붙고, `/clear` 뒤라면 **옛 세션의 키가 새 세션 base 에** 붙는다 — AT3 귀속이
/// 거기에 옛 턴 기록을 매단다.
/// 한 배치가 모으는 **턴 사실들**. 값을 **지역 버퍼에 복사해서** 든다.
///
/// ⚠️ **배치 끝에서 `term` 을 다시 읽으면 안 된다.** 한 tick 의 배치에 `Stop(p-1)` 다음
/// `UserPromptSubmit(p-2)` 가 함께 올 수 있고(사용자가 곧바로 다음 프롬프트를 넣으면 그렇다), 그때
/// `progress.turnKey()` 는 이미 **다음 턴의 키**이며 `reply()` 는 그 프롬프트가 지워 **비어 있다**.
/// 그대로 실으면 턴 1의 스냅샷에 턴 2의 키가 붙는다 — 계약 §3.1 이 「시각으로 맞추면 tick 지연에서
/// 어긋난다」며 키를 도입한 바로 그 어긋남이다.
///
/// **턴이 끝나는 그 순간** 굳히고, 한 배치에 턴 끝이 여럿이면 **마지막 것이 이긴다**(스냅샷도 하나다).
/// **테스트가 직접 물 수 있게 `pub` 이다.** 「턴이 끝나는 순간 굳힌다」는 규율은 배치 루프 안에만 있는데,
/// 통합 test 는 `captureTurnSnapshot` 을 직접 부르므로 그 자리를 지나지 않는다 — seam 이 없으면 그 규율을
/// 지운 뮤턴트가 판정자를 전부 통과한다(AT1 이 같은 이유로 `turnFactsForCapture` 를 열었다).
pub const BatchTurnFacts = struct {
    key_buf: [maru.session.turn_snapshot.max_turn_key_len]u8 = undefined,
    key_len: usize = 0,
    title_buf: [maru.session.turn_snapshot.max_turn_title_len]u8 = undefined,
    title_len: usize = 0,
    /// **그 턴을 돌린 세션.** 키·제목과 같은 이유로 여기서 굳힌다 — 배치 끝에 다시 조회하면 그 사이
    /// `SessionStart(새 id)` 가 와서 신원이 갈렸을 때 **끝난 턴이 새 세션의 링에 실린다**(AT0 이 막으려던
    /// 그것). 실측(2026-08-26): `Stop` 직후 이벤트 677건 중 세션이 바뀐 `SessionStart` 가 1건.
    session_buf: [maru.session.turn_snapshot.max_session_id_len]u8 = undefined,
    session_len: usize = 0,

    pub fn captureFrom(self: *BatchTurnFacts, term: *Term) void {
        const sid = term.agent_transcript.identity();
        self.session_len = if (sid.len <= self.session_buf.len) sid.len else 0;
        if (self.session_len > 0) @memcpy(self.session_buf[0..sid.len], sid);
        const key = term.agent_hook_progress.turnKey();
        self.key_len = if (key.len <= self.key_buf.len) key.len else 0;
        if (self.key_len > 0) @memcpy(self.key_buf[0..key.len], key);
        const title = maru.session.agent_transcript.clampUtf8(term.agent_transcript.reply(), self.title_buf.len);
        self.title_len = title.len;
        if (title.len > 0) @memcpy(self.title_buf[0..title.len], title);
    }

    pub fn facts(self: *const BatchTurnFacts) TurnFacts {
        return .{
            .key = self.key_buf[0..self.key_len],
            .title = self.title_buf[0..self.title_len],
            .session = self.session_buf[0..self.session_len],
        };
    }
};

/// **테스트가 직접 물 수 있게 `pub` 이다.** base 가 옛 턴의 키를 물려받지 않는다는 가드는 이 함수 안에만
/// 있는데, 통합 test 는 `captureTurnSnapshot` 을 직접 불러 이 자리를 **지나지 않는다** — 그러면 가드를
/// 지운 뮤턴트가 판정자를 전부 통과한다(AT1 에서 같은 실패를 한 번 겪었다).
pub fn turnFactsForCapture(term: *Term, turn_ended: bool) TurnFacts {
    if (!turn_ended) return .{};
    return .{
        .key = term.agent_hook_progress.turnKey(),
        // 그 턴의 마지막 응답. `applyHookEvent` 가 `.stop`·`.stop_failure` 에서 이미 눕혀 담아 두었다
        // (`hookConversationText` — 이스케이프 해제 + 경계 정리 + 개행 눕히기). 여기서 다시 만들지 않는다.
        //
        // ⚠️ **이 값이 «이번 턴의 것» 이라는 보장은 여기 없다.** 그것은 `.user_prompt_submit` 분기가 새 턴
        // 시작에 `setReply("")` 로 지워 주기 때문에 성립한다 — **두 분기에 걸친 암묵 의존**이다. 그 지우기가
        // `if (ev.text.len > 0)` 안에 있으므로, 프롬프트가 비면 안 지워지고 그때 `Stop` 의 응답도 비면
        // **직전 턴의 제목이 이번 턴에 붙는다**(세션 base 가 옛 키를 물려받던 것과 같은 모양이다).
        //
        // 실측(2026-08-25, 이 기계의 훅 로그)에서는 `Stop`/`StopFailure` 의 `last_assistant_message` 가
        // 346/346, `UserPromptSubmit` 의 `prompt` 가 386/386 으로 **둘 다 100%** 라 지금은 안 밟힌다.
        // 그래서 가드를 더하지 않는다 — 대신 그 의존을 여기 적어, `setReply("")` 를 옮기거나 그 가드를
        // 바꾸는 사람이 이 자리를 함께 보게 한다.
        //
        // **오류로 끝난 턴은 그 사유가 제목이 된다**(`.stop_failure` 도 같은 분기다). 그 턴이 마지막으로
        // 한 말이 사유이므로 맞다.
        .title = term.agent_transcript.reply(),
    };
}

/// 이 캡처에 실을 **그 턴의 사실들**. 세션 base 와 관측 모드는 빈 값이다 — 전자는 계약상 턴이 아니고
/// 후자는 그 축을 알 길이 없다(`Snapshot.turn`·`Snapshot.title` 주석).
pub const TurnFacts = struct {
    /// 턴 식별자(계약 §3.1).
    key: []const u8 = "",
    /// 턴 제목(AT2).
    title: []const u8 = "",
    /// **그 턴을 돌린 세션**(비면 지금 신원을 쓴다 — base 가 그렇다).
    ///
    /// ⚠️ 키·제목과 같은 이유로 **턴이 끝나는 순간** 굳힌 값이다. 배치 끝에 다시 조회하면 그 사이
    /// 신원이 갈렸을 때(`/clear`) **끝난 턴이 새 세션의 링에 실린다.**
    session: []const u8 = "",
};

/// 테스트 전용 — **마지막 캡처에 넘어간 턴 사실**. `test_turn_snapshot_calls` 와 같은 규약이고 같은 이유다:
/// 이 함수는 git 저장소가 없으면 조용히 돌아가므로 **링(결과)으로는 「무엇을 넘겼나」를 볼 수 없다.**
/// 넘긴 값 자체를 기록해야 「배치 안에서 다음 턴이 시작돼도 끝난 턴의 사실을 든다」를 잴 수 있다.
pub var test_last_turn_key: [maru.session.turn_snapshot.max_turn_key_len]u8 = undefined;
pub var test_last_turn_key_len: usize = 0;
pub var test_last_turn_title: [maru.session.turn_snapshot.max_turn_title_len]u8 = undefined;
pub var test_last_turn_title_len: usize = 0;

/// `PreToolUse` 가 경로를 실어 오면 **그 순간** 그림자 사본(before)을 뜬다(계약 §4.4).
///
/// **tick 안에서 동기로 읽는 근거는 성능이 아니라 정확성이다.** 우리가 이 이벤트를 보는 시점에 도구는
/// **이미 돌고 있다**(계약 A13 — 훅의 이득은 놓침 제거이지 지연 제거가 아니다). 비동기 홉은 우리 읽기와
/// 도구 쓰기 사이 창을 넓혀 **before 가 after 로 오염될 확률**을 올린다.
///
/// 캡처하지 않는 셋:
///
/// - **backlog 따라잡기 중** — 그 이벤트는 창이 없던 시간의 것이라 도구가 **이미 오래전에 끝났다.**
///   지금 읽으면 **현재 내용을 끝난 턴의 before 로 이름 붙인다** — 없는 것보다 나쁘다. 알림을 억제하는
///   것과 같은 자리·같은 근거다. 이 규칙이 「한 tick 에 64회 읽기」 최악도 함께 없앤다.
/// - **자식(subagent) 이벤트** — lead 의 턴에 자식의 경로를 섞지 않는다(계약 §2 의 같은 규율).
/// - **신원이 없을 때** — 귀속 못 할 바이트를 드는 것은 순수한 누수다(`captureTurnSnapshot` 과 같다).
///
/// 루트 밖·바이너리·상한 초과는 **거부가 아니라 접기**다 — 경로는 남고 내용만 없다(`capture_file`).
fn captureBeforeForEvent(self: *AppSession, term: *Term, ev: maru.session.agent_hook_event.Event) void {
    if (ev.kind != .pre_tool_use) return;
    // ⚠️ **자식(서브에이전트) 이벤트도 센다.** 계약이 말하는 「자식 이벤트는 **부모 상태**를 옮기지
    // 않는다」는 배지·턴 셈의 규율이지 **파일 귀속**의 규율이 아니다 — 서브에이전트가 고친 파일도
    // 「에이전트가 편집 도구로 고쳤다」이고, 그 일이 속할 턴은 부모의 턴 말고 없다(링에 자식의 턴이 없다).
    //
    // 처음에는 그 규율을 과잉 적용해 자식을 통째로 뺐다. 실측(2026-08-26)이 대가를 보여 줬다:
    // **셸 호출의 15.6%(1,516/9,735)가 자식의 것**이라 고지가 그만큼 적게 셌고, 자식의 편집은
    // `✎` 대신 `·` 로 떨어졌다.
    if (term.agent_hook_backlog_catchup) return;
    const identity = term.agent_transcript.identity();
    if (identity.len == 0) return;

    // **셸은 경로를 안 준다 — 셀 수만 있다**(계약 §2.3: provider 구현이 그 필드를 아예 안 만든다).
    // 그 수가 목록의 `·` 가 왜 있는지를 말하는 유일한 근거다(계약 §5 고지 줄).
    //
    // **위 게이트 넷을 그대로 지난 뒤**에 센다 — 자식·backlog·회전본·신원 없음. 게이트를 공유하지 않으면
    // 「창이 없던 시간의 셸 명령」이 지금 턴에 세어져 고지가 거짓 수를 말한다.
    //
    // 저장소 루트 판정보다 **앞**이다: 세는 데는 루트가 필요 없다.
    if (isShellTool(ev.tool_name)) {
        self.turn_captures.noteShellCall(identity);
        return;
    }

    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = self.git_repo orelse (git_ops.gitRepoRoot(self, &repo_buf) orelse return);

    // Claude 는 `tool_input.file_path` 하나, Codex 는 패치 텍스트 안에 여러 개다.
    // ⚠️ `patchPaths` 는 `tool_command` 를 훑으므로 **`apply_patch` 에만** 부른다 — 셸 이벤트에 부르면
    // 실행할 명령을 패치로 파싱한다.
    if (ev.file_path.len > 0) {
        var decoded_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = decodeHookPath(&decoded_buf, ev.file_path) orelse return;
        noteBeforePath(self, identity, root, path, triggerForTool(ev.tool_name));
        return;
    }
    if (!std.mem.eql(u8, ev.tool_name, "apply_patch")) return;
    var it = maru.session.agent_hook_event.patchPaths(ev);
    while (it.next()) |p| {
        // ⚠️ **패치는 경로를 «쓰인 철자 그대로» 적는다 — 상대·절대가 섞인다**(계약 §2.3.1 이 Codex 소스를
        // 읽고 못 박았다). 상대경로를 그대로 넘기면 `underRoot` 이 «루트 밖» 으로 판정해 **조용히 캡처를
        // 잃는다.** 이 기계의 실측(42 이벤트·74 경로)은 전부 절대였지만, 계약이 섞인다고 적었으므로
        // 관측이 아니라 **계약**을 따른다.
        var decoded_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = decodeHookPath(&decoded_buf, p) orelse continue;
        var joined: [std.fs.max_path_bytes]u8 = undefined;
        const abs = if (maru.path_shape.isAbsolute(path))
            path
        else
            (std.fmt.bufPrint(&joined, "{s}/{s}", .{ root, path }) catch continue);
        noteBeforePath(self, identity, root, abs, .edit);
    }
}

/// 훅 payload 의 경로를 **이스케이프를 풀어** 돌려준다(못 담으면 null).
///
/// ⚠️ **payload 문자열은 원문이다** — `agent_hook_event` 가 「JSON 이스케이프가 남아 있는 원문이다.
/// 화면에 올릴 때만 `decodeInto` 로 푼다」를 계약으로 적어 뒀고, AT1 의 `session_id` 채택이 같은 이유로
/// 같은 함수를 쓴다. 이 기계 실측(661/661)은 이스케이프가 없었지만 **관측이 아니라 계약을 따른다** —
/// 따옴표나 비ASCII 가 든 경로에서 조용히 깨지는 자리다.
///
/// **넘치면 아예 안 담는다(자르지 않는다).** 잘린 경로는 **다른 파일**을 가리킨다 — 없는 것보다 나쁘다.
/// (`decodeInto` 는 `\uXXXX` 를 자리만 지키는 `?` 로 푼다. 그런 경로는 열리지 않아 «모름» 으로 떨어지는데,
/// 원문 그대로 열어도 마찬가지라 잃는 것이 없다.)
fn decodeHookPath(buf: []u8, raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or raw.len > buf.len) return null;
    const decoded = maru.session.agent_hook_event.decodeInto(buf, raw);
    return if (decoded.len == 0) null else decoded;
}

/// 그 도구가 **셸 명령을 돌리는가** — 즉 파일을 고쳤을 수 있는데 우리는 그 경로를 모르는가.
///
/// ⚠️ **`Bash` 만 세면 적게 센다.** 실측(2026-08-26): `Monitor` 가 71건 전부 `tool_input.command` 를
/// 싣는다 — 셸 명령을 돌리는 도구다. 그것을 빼면 고지가 **실제보다 적은 수**를 말하고, 그 수가 곧
/// 「목록의 `·` 가 왜 있는지」의 답이므로 답이 약해진다.
///
/// ⚠️ **`apply_patch` 는 `command` 를 싣지만 셸이 아니다** — 그 값은 패치 텍스트다. 그래서 「`command`
/// 가 있으면 셸」이라는 편한 규칙을 쓰지 않고 **이름을 명시한다.**
///
/// `exec` 는 계약이 codex 의 셸 이름으로 적어 둔 것인데 **이 기계 실측에서는 안 나왔다**(codex 도 `Bash`
/// 를 쓴다 — 185건). 지우지 않는 이유는 계약이 그 이름을 말하기 때문이다 — 관측이 계약을 이기지 않는다.
/// ⚠️ **codex 도 `Bash` 로 보고한다**(2026-08-26 실측: codex 훅 이벤트의 도구 이름은
/// `Bash` 185 · `apply_patch` 42 · `update_plan` 13 · mcp 몇 — **`exec` 는 양 provider 통틀어 0건**).
/// 계약 §2 가 적은 `exec-96de8969-…` 는 **`tool_use_id` 의 접두어**이지 도구 이름이 아니다.
/// 그래서 아래 `exec` 가지는 지금 한 번도 안 밟힌다 — 방어로 남기되, **codex 를 위해 `Bash` 를 지우면
/// codex 의 셸이 통째로 안 세어진다.**
fn isShellTool(tool_name: []const u8) bool {
    if (std.mem.eql(u8, tool_name, "Bash")) return true;
    if (std.mem.eql(u8, tool_name, "exec")) return true;
    if (std.mem.eql(u8, tool_name, "Monitor")) return true;
    return false;
}

/// 그 도구가 **바꾸려고** 여는 것인가.
///
/// ⚠️ **`Read` 를 편집으로 세면 화면이 거짓말을 한다.** 실측: 경로를 실은 `PreToolUse` 517건 중 `Read`
/// 가 360건(70%)이다. 「캡처됐다」를 「편집됐다」로 읽으면 **읽기만 한 파일이 «AI 편집»으로 뜬다.**
/// 모르는 도구는 `.read` 로 둔다 — 편집이라 단정하는 쪽이 거짓을 만든다.
fn triggerForTool(tool_name: []const u8) turn_capture.Trigger {
    if (std.mem.eql(u8, tool_name, "Edit")) return .edit;
    if (std.mem.eql(u8, tool_name, "Write")) return .edit;
    if (std.mem.eql(u8, tool_name, "NotebookEdit")) return .edit;
    if (std.mem.eql(u8, tool_name, "apply_patch")) return .edit;
    return .read;
}

fn noteBeforePath(
    self: *AppSession,
    identity: []const u8,
    root: []const u8,
    path: []const u8,
    trigger: turn_capture.Trigger,
) void {
    // **이미 있으면 읽지도 않는다.** 「첫 캡처로 고정」은 저장 층의 규칙이지만, 여기서 먼저 걸러야
    // 같은 파일을 여러 번 만지는 턴에서 **읽기가 도구 수만큼 는다**(순수 층은 읽은 뒤에야 버린다).
    if (self.turn_captures.openTurn(identity)) |turn| {
        if (turn.find(path)) |i| {
            if (trigger == .edit) turn.entries.items[i].trigger = .edit;
            return;
        }
    }
    const side = capture_file.readSide(self.allocator, root, path);
    _ = self.turn_captures.noteBefore(self.allocator, identity, path, trigger, side);
}

/// 턴이 끝나면 그 집합의 경로를 **다시 읽어** after 를 채우고 봉인한다. 반환값이 링에 실릴 `capture_id`.
///
/// **역시 tick 동기다.** 상한이 시간을 이미 묶는다 — 턴당 4 MiB·256 경로라 page cache 에서 최악 ~5 ms 다.
/// 비교 대상이 결정적이다: 이 코드가 **걷어낼** `git write-tree` 가 같은 자리에서 **490 ms** 다(§2.6).
/// 5 ms 를 위해 worker 를 들이면 `freeDiffContent` 가 실측으로 경고하는 할당자 갈림을 새로 만드는 순손실이다.
/// **턴이 끝나는 그 순간** 사본을 굳힌다. 배치 루프가 `applied.turn_end` 에서 부른다.
///
/// ⚠️ **배치 끝에서 봉인하면 사본이 섞인다.** 한 tick 이 최대 64 이벤트를 읽으므로 `Stop` 뒤에 다음 턴의
/// `UserPromptSubmit`·`PreToolUse` 가 **같은 배치**에 올 수 있고, 캡처는 이벤트마다 열린 버킷에 쓴다 —
/// 그러면 **다음 턴의 파일이 끝난 턴의 사본에** 들어가 그 턴의 `✎` 와 배지가 남의 편집을 센다.
/// `BatchTurnFacts.captureFrom` 이 턴 키에서 같은 이유로 같은 자리에 있다(AT2 가 겪은 결함).
pub fn sealTurnCaptureNow(self: *AppSession, term: *Term) turn_capture.Id {
    const identity = term.agent_transcript.identity();
    if (identity.len == 0) return 0;
    // **봉인 전에 고아를 비운다** — 봉인 자리는 「링이 가리킬 수 있는 최대 + 1」이라 그 한 칸이 고아로
    // 채워지면 아직 가리켜지는 사본이 밀려난다.
    git_ops.sweepTurnCaptures(self);
    return sealTurnCapture(self, identity);
}

fn sealTurnCapture(self: *AppSession, identity: []const u8) turn_capture.Id {
    const turn = self.turn_captures.openTurn(identity) orelse return 0;
    // **경로 수가 아니라 「붙일 것이 있나」로 묻는다.** 예전에는 `entries.len == 0` 이면 여기서 돌아섰는데,
    // 그러면 **셸만 쓴 턴이 봉인에 닿지 못한다** — 경로가 0개이므로. 그런데 그 턴이야말로 고지가 가장
    // 필요한 자리다(파일 행이 전부 `·` 인데 왜 그런지를 말해 줄 것이 셸 수뿐이다). `Store.seal` 이
    // 이미 같은 질문을 하지만, 여기서 먼저 물어야 **뒤의 저장소 루트 조회를 안 한다**.
    if (!turn.hasEvidence()) return 0;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    // 경로가 없으면 사본을 뜰 것도 없다 — 루트를 찾는 syscall 도 건너뛴다.
    const root = if (turn.entries.items.len == 0) "" else (self.git_repo orelse (git_ops.gitRepoRoot(self, &repo_buf) orelse ""));
    if (root.len != 0) {
        // **인덱스로 훑어도 안전한 이유**: `noteAfter` 는 `after` 필드만 채우고 **항목을 추가하지 않는다**
        // — 리스트가 재할당되지 않으므로 순회 중 길이·주소가 안 흔들린다. (경로 슬라이스는 항목이 소유하고
        // 그 항목은 안 움직인다.)
        //
        // 인덱스를 알면서도 경로로 되짚는 `noteAfter` 를 거치는 이유는 **예산 판정이 그 안에 있기**
        // 때문이다 — 여기서 직접 대입하면 상한이 두 자리로 갈린다.
        var i: usize = 0;
        while (i < turn.entries.items.len) : (i += 1) {
            if (turn.entries.items[i].after != null) continue;
            const path = turn.entries.items[i].path;
            const side = capture_file.readSide(self.allocator, root, path);
            self.turn_captures.noteAfter(self.allocator, identity, path, side);
        }
    }
    return self.turn_captures.seal(self.allocator, identity);
}

/// 그 턴의 작업트리를 tree 로 굳혀 링에 실을 준비를 한다(§6.1). 실제 적재는 수확부가 한다.
///
/// ⚠️ **`facts` 와 `capture_id` 는 «턴이 끝나는 그 순간» 의 값이어야 한다.** 호출자(배치 루프)가
/// `applied.turn_end` 에서 `BatchTurnFacts.captureFrom` 과 `sealTurnCaptureNow` 로 굳혀 넘긴다.
/// 여기서 다시 만들면 안 되는 이유가 셋이고 셋 다 실측으로 걸렸다:
///
/// - **턴 키·제목**: 한 배치에 다음 턴이 시작되면 옛 스냅샷에 새 턴의 키가 붙는다(AT2 가 겪었다).
/// - **사본**: 캡처는 이벤트마다 열린 버킷에 쓰므로, 배치 끝에 봉인하면 **다음 턴의 파일이 끝난 턴의
///   사본에** 들어간다(실측: `Stop` 직후 `PreToolUse` 6건).
/// - **세션**: 그 사이 `SessionStart(새 id)` 가 오면 **끝난 턴이 새 세션의 링에** 실린다 — AT0 이
///   막으려던 그것이다(실측: `Stop` 직후 677건 중 1건).
///
/// `capture_id == 0` 은 「사본 없음」이다(관측 모드·훅 없는 세션·붙일 것이 없던 턴).
/// `std.Io.Dir.openDirAbsolute` 는 **상대경로에 `assert` 로 죽는다** — `catch` 가 못 막는 종류다.
/// 이 파일이 여는 경로는 전부 `HOME`·`CLAUDE_CONFIG_DIR` 에서 만든 것이라, 그 env 가 상대경로면 **앱이
/// 통째로 abort** 한다. 실제로 그렇게 죽었다(2026-08-31: 제품 스모크 `macos-session-host-c4-quit-cancel-smoke`
/// 가 HOME 을 `zig-out/…` 상대경로로 띄우는데, 그 실행에서 `removeAgentStatuslineHook` 이 SIGABRT 를 냈고
/// CI 의 세 PR 이 같은 자리에서 빨갰다).
///
/// **여는 자리를 하나로 모은다.** 호출부마다 `isAbsolute` 를 적으면 새로 여는 자리 하나가 그 규율 밖에
/// 남고, 그 하나가 곧 abort 다 — 규율을 주석이 아니라 **함수**가 진다.
fn openAgentDirAbsolute(self: *AppSession, path: []const u8, options: std.Io.Dir.OpenOptions) ?std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return null;
    return std.Io.Dir.openDirAbsolute(self.io, path, options) catch null;
}

pub fn captureTurnSnapshot(self: *AppSession, surface_id: u64, facts: TurnFacts, capture_id: turn_capture.Id) void {
    if (builtin.is_test) {
        test_turn_snapshot_calls += 1;
        // **게이트보다 먼저 기록한다** — 저장소가 없어도 「무엇을 넘겼나」는 사실이다.
        test_last_turn_key_len = @min(facts.key.len, test_last_turn_key.len);
        @memcpy(test_last_turn_key[0..test_last_turn_key_len], facts.key[0..test_last_turn_key_len]);
        test_last_turn_title_len = @min(facts.title.len, test_last_turn_title.len);
        @memcpy(test_last_turn_title[0..test_last_turn_title_len], facts.title[0..test_last_turn_title_len]);
        // **어느 세션에 실릴 것인가**도 사실이다 — 그 판정이 이 함수 안에 있으므로 결과(링)로는 못 본다.
        const resolved = if (facts.session.len > 0) facts.session else git_ops.sessionIdentityFor(self, surface_id);
        test_last_turn_session_len = @min(resolved.len, test_last_turn_session.len);
        @memcpy(test_last_turn_session[0..test_last_turn_session_len], resolved[0..test_last_turn_session_len]);
    }
    // **봉인은 git 보다 앞이다.** 그림자 사본은 이미 우리 손에 있고 git 을 한 번도 안 부른다 —
    // 계약 §4.4 가 「git 없이도 된다」를 근거로 든 그 성질이다. 아래 게이트·저장소 판정 뒤에 두면
    // ⑴ git 이 없는 워크스페이스에서 사본이 **통째로 안 만들어지고** ⑵ 백엔드가 거절할 때도 그렇다.
    //
    // 봉인해 두면 링에 못 실리는 경우에도 손해가 없다 — 그 id 는 고아가 되고 `Store.sweep` 이 곧
    // 해제한다(도달성으로 두는 이유 넷 중 하나가 정확히 이 경로다).
    // **테스트에서는 세기만 하고 실제 작업은 하지 않는다.**
    //
    // 아래 `submitSnapshot` 은 detached worker 에 job 을 넘기고 그 해제를 **그 스레드가** 한다. 테스트는
    // 세션을 만들자마자 `deinit` 하므로 worker 가 아직 안 끝난 순간이 있고, 그러면 job 의 `create`·`dupe`
    // 가 누수로 잡힌다 — 타이밍을 타서 **로컬은 통과하고 CI 만 빨개진다**(실제로 그렇게 났다).
    // 게다가 이 경로는 `git` 을 띄우고 캐시에 임시 index 를 쓴다: 테스트가 개발자 머신에 부작용을 내지
    // 않는다는 규율(`test_allow_provider_writes`·`test_allow_log_cleanup`)과 같은 자리다.
    //
    // 세는 것은 계속한다 — 훅 모드가 «턴 끝에 이것을 부르는가» 는 그 카운터가 보는 계약이고, 부르는 것과
    // 실제로 git 을 돌리는 것은 다른 사실이다. **링을 실제로 채우는 것을 보는 테스트**는 아래 스위치로
    // 밝히고 돈다(통째로 막았더니 그 테스트가 깨졌다 — 막는 것과 못 돌게 하는 것은 다르다).
    if (builtin.is_test and !test_allow_turn_snapshot) return;
    // **신원이 없으면 찍지 않는다**(AT0 — 계약 §6.1 «훅 모드 전용»). 링에 넣을 키가 없는데 찍으면
    // git 프로세스만 공짜로 띄운다. 관측 모드에서 목록이 비는 것은 그래서이고, 오류가 아니다.
    // **턴이 끝나는 순간의 신원을 쓴다**(있으면). 여기서 다시 조회하면 그 사이 `SessionStart(새 id)` 가
    // 온 배치에서 **끝난 턴이 새 세션의 링에 실린다** — AT0 이 막으려던 그것이다. base 는 그 순간이
    // 따로 없으므로 지금 신원을 쓴다.
    const identity = if (facts.session.len > 0) facts.session else git_ops.sessionIdentityFor(self, surface_id);
    if (identity.len == 0) return;
    // **턴을 찍었다는 것 자체가 그 세션이 활동했다는 뜻이다** — 그러니 여기서도 «직전에 본 세션» 을
    // 갱신한다. 화면 조회에만 맡기면, 사용자가 그 에이전트 Term 을 활성으로 한 번도 두지 않은 채
    // (예: 목록을 열자마자 diff 를 연 상태) 턴이 끝나면 폴백이 영영 비어 목록이 서지 않는다.
    git_ops.rememberAgentSession(self, identity);
    // ⚠️ **원격 목록을 보는 동안에는 스냅샷을 뜨지 않는다**(RS2 적대적 검증 1회차 — 셋 중 가장 나쁜
    // 자리다). 여기는 `add -A` 로 **작업트리를 통째로 임시 index 에 굳히는** 경로인데, `git_repo` 에 든
    // 것이 원격 경로라 로컬에 우연히 같은 경로가 있으면 **그 로컬 트리**가 원격 세션의 턴 스냅샷으로
    // 박힌다. 원격 턴의 변경분은 RS3·RS4 가 원격 축으로 다시 잇는다.
    if (git_ops.scmTargetIsRemote(self)) return;
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = self.git_repo orelse (git_ops.gitRepoRoot(self, &repo_buf) orelse return);
    // 저장소 전환은 **그 세션의 링만** 비운다 — `RingMap.ringFor` 가 수확 시점에 판정한다(§6.1).

    const index_file = self.turnIndexPath() orelse return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    // **요청 시점의 신원을 붙들어 둔다**(적대적 검증 1회차). 수확 때 다시 조회하면 그 사이 `/clear` 로
    // 세션이 갈렸을 때 옛 턴이 새 세션 링에 들어간다.
    const owned = self.allocator.dupe(u8, identity) catch return;
    const owned_repo = self.allocator.dupe(u8, repo) catch {
        self.allocator.free(owned);
        return;
    };
    if (!self.git_backend.?.submitSnapshot(git_exe, repo, index_file, surface_id)) {
        // **거절을 조용히 삼키지 않는다**(적대적 검증 3회차). 백엔드 스냅샷 자리가 하나라 다른 세션의
        // 캡처가 도는 중이면 이 턴은 **영영 안 찍힌다** — 재시도하면 스냅샷 시점이 «턴이 끝난 순간» 이
        // 아니라 «재시도한 순간» 이 되어 내용이 틀린 턴을 만드는데, 그것은 없는 것보다 나쁘다.
        // 그래서 버리되 **버렸다는 사실을 남긴다**(화면이 그 수를 말한다).
        self.allocator.free(owned);
        self.allocator.free(owned_repo);
        if (self.turn_rings.findMut(identity)) |ring| ring.missed +|= 1;
        return;
    }
    if (self.turn_snapshot_session) |old_sid| self.allocator.free(old_sid);
    if (self.turn_snapshot_repo) |old_repo| self.allocator.free(old_repo);
    self.turn_snapshot_session = owned;
    self.turn_snapshot_repo = owned_repo;
    self.turn_snapshot_capture = capture_id;
    // **상한을 넘는 키는 안 담는다(자르지 않는다)** — 순수 층 `Ring.push` 와 같은 규율이고, 잘린 키는
    // AT3 귀속에서 남의 턴과 거짓으로 일치한다. 여기서도 거르면 링까지 안 간다.
    self.turn_snapshot_key_len = if (facts.key.len > 0 and facts.key.len <= self.turn_snapshot_key.len) facts.key.len else 0;
    if (self.turn_snapshot_key_len > 0) @memcpy(self.turn_snapshot_key[0..facts.key.len], facts.key);
    // **제목은 반대로 자른다**(키는 신원이라 자르면 거짓 일치, 제목은 산문이라 앞부분이 쓸모 있다).
    // 경계는 순수 층 규칙을 그대로 빌린다 — 여기서 다시 적으면 두 자리가 갈린다.
    const title = maru.session.agent_transcript.clampUtf8(facts.title, self.turn_snapshot_title.len);
    self.turn_snapshot_title_len = title.len;
    if (title.len > 0) @memcpy(self.turn_snapshot_title[0..title.len], title);
}

/// Archive에서 고른 provider-native session을 새 terminal 탭으로 재개한다. transcript를 셸에 paste하거나
/// `sh -c`로 조립하지 않고, `/usr/bin/env`와 provider argv를 분리해 직접 exec 한다.
pub fn resumeAgentSessionInNewTerm(self: *AppSession, record: *const agent_session_archive_backend.Record) !void {
    const pane = pane_ops.activePane(self);
    const size = layout_math.gridFromRectPx(self.cell_width_px, self.cell_height_px, self.active_pane_rect.w, self.active_pane_rect.h);
    var cfg = self.new_tab_config;
    cfg.size = size;
    // ZDOTDIR은 **새 탭과 같은 지점**(`shellIntegrationZdotdir`)에서 얻는다. 예전에는 여기만 보관 필드
    // (`new_tab_zdotdir`)를 직접 읽었는데, 그 함수는 캐시의 `.zshenv`가 사라졌으면 다시 써 주는 자가 복구를
    // 한다(앱 시작 때 한 번만 도는 `setupZsh`의 산출물이라 캐시 정리에 그대로 노출된다). 직접 읽으면 캐시가
    // 비워진 뒤 **재개 탭만** 셸 통합이 통째로 빠져, provider를 끝내고 프롬프트로 돌아와도 그 탭은 OSC 7·
    // OSC 133을 영영 보내지 않는다.
    var req = spawnRequest(cfg, self.loaded_config.config.term, self.loaded_config.config.shell, self.loaded_config.config.env, self.shellIntegrationZdotdir(), self.new_tab_ssh_bin);
    const provider_command: []const u8 = record.parsed.provider.label();
    const args = switch (record.parsed.provider) {
        .claude => [_][]const u8{ "claude", "--resume", record.parsed.session_id },
        .codex => [_][]const u8{ "codex", "resume", record.parsed.session_id },
    };
    // The isolated AppKit fixture supplies one absolute fake executable so it can prove the
    // provider-native argv without starting a real account session or depending on the build
    // runner's inherited PATH.  That seam stays a direct exec with no shell wrapper.
    var shell_command: ?[]u8 = null;
    defer if (shell_command) |owned| self.allocator.free(owned);
    if (agent_dock.archiveSmokeFakeProviderExecutable(record.parsed.provider)) |fake_executable| {
        req.command = fake_executable;
        req.args = args[1..];
        req.login = false;
    } else {
        // 제품 경로는 **사용자 로그인 셸을 거쳐** provider를 찾는다. 예전에는 `/usr/bin/env claude`를
        // 직접 exec했는데, 그러면 provider를 **부모 프로세스의 PATH에서만** 찾는다. 터미널에서 띄운
        // 앱은 셸 PATH를 상속해 우연히 동작했지만 Dock/Finder에서 띄운 앱은 실패했다 — GUI 앱이
        // 물려받는 PATH에는 `~/.local/bin`이나 버전 매니저 shim이 없다(실측: `launchctl getenv PATH`
        // 미설정, `env -i … zsh -lc 'command -v claude'` 실패, `-lic`는 성공).
        //
        // `login = true`만 켜는 것으로는 안 된다. login(1) 래핑은 최종적으로
        // `… -c "exec -l '<command>' '<args>'"`를 만드는데, `<command>`가 `/usr/bin/env`면 exec 대상이
        // 셸이 아니라 **dotfile을 읽는 주체가 없다**. 그래서 exec 대상 자체를 셸로 만든다.
        //
        // 셸 종류로 분기하지 않는다. 분기해서 직접 exec으로 폴백해 봐야 그건 **이 커밋이 고치는
        // 바로 그 실패**(Dock에서 PATH 못 찾음)로 되돌아가는 것이고, 경로가 둘이 되어 유지보수만
        // 는다. 셸이 이 인자를 못 받으면 그 셸이 에러를 내고 PTY 화면에 그대로 뜬다 — 조용히
        // 실패하지 않으므로 사용자가 원인을 본다.
        shell_command = try buildResumeShellCommand(self.allocator, &args);
        req.command = resolveConfiguredShell(self.loaded_config.config.shell.command);
        // `-i`가 필요하다: PATH를 `.zshrc`에 두는 환경이 흔하고 zsh는 `-l`만으로는 그 파일을 읽지
        // 않는다. 일반 새 탭은 이미 대화형 로그인 셸이므로 이 경로가 오히려 나머지 탭과 동작을
        // 일치시킨다. `exec`로 중간 셸을 남기지 않아 실행 중 판정(foreground process group 열거)도
        // 그대로 성립한다.
        req.args = &[_][]const u8{ "-l", "-i", "-c", shell_command.? };
        req.login = true;
    }
    // cwd는 **명령 문자열에 넣지 않고** spawn 작업 디렉터리로만 전달한다 — 셸 메타문자가 명령으로
    // 재해석될 여지를 두지 않는다.
    if (usableRestoreCwd(record.parsed.cwd)) |cwd| req.cwd = cwd;
    const term = try term_ops.createTerm(self, req, size, cfg.queue_capacity, provider_command, args[0]);
    errdefer term_ops.destroyTerm(self, term);
    try pane.terms.append(self.allocator, term);
    self.focusTerm(pane.terms.items.len - 1);
}

pub fn tallyAgents(self: *const AppSession) AgentTally {
    var t: AgentTally = .{};
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                switch (term.agent_state) {
                    .running => {
                        t.running += 1;
                        // 대표 kind는 **처음 만난 것**이다 — 섞여 있을 때 무엇을 대표로 삼을지 의미 있는
                        // 규칙이 없고, 개수가 이미 "여럿"을 말해 준다.
                        if (t.running_kind == .none and term.agent_kind != .none) t.running_kind = term.agent_kind;
                    },
                    .blocked => t.blocked += 1,
                    .unknown, .idle => {},
                }
            }
        }
    }
    return t;
}

pub fn agentStatePriority(state: maru.session.agent_observer.State) u8 {
    return switch (state) {
        .blocked => 3,
        .running => 2,
        .idle => 1,
        .unknown => 0,
    };
}

/// 이 탭(tab_index)의 에이전트 상태/종류 변화가 **화면에 보이는 running 표시**에 영향을 주는가 — pollAgentKinds/State의
/// metal_dirty 게이트. 옛 "활성 Term만 보이면 재렌더"에서 확장한다: (1) 사이드바 카드 스피너·아이콘·색은 이제 **워크스페이스
/// 단위**(tabHasRunningAgent/tabAgentKind)라 그 탭의 **어느 Term** 상태가 바뀌어도 카드가 바뀐다 → 카드가 보이면 재렌더.
/// (2) 탭 바는 **활성 탭의 모든 Term**에 정적 플래그(●)를 그리므로 활성 탭의 어느 Term 변화든 반영해야 한다. 둘 다 안 보이면
/// (접힘/최소 + 비활성 탭) 진짜로 화면에 없으니 재렌더 안 함(안 보이는 background Term churn으로 헛 재렌더 방지 — 옛 게이트 취지 유지).
pub fn agentDisplayVisible(self: *AppSession, tab_index: usize) bool {
    // (1) 사이드바 카드가 보이고 이 탭이 검색 필터를 통과하면(displaySlotOf 재사용 — 멤버십 스캔 단일 출처, code-review high).
    if (!self.sidebar_collapsed and !self.chrome_minimal and self.displaySlotOf(tab_index) != null) return true;
    // (2) 탭 바가 그려지고(chrome_minimal이면 paneBarHeightPx==0) 이 탭이 활성이면 이 탭의 Term들이 탭으로 보인다.
    return pane_ops.paneBarHeightPx(self) > 0 and self.app_window.active_tab == tab_index;
}

/// 에이전트 행의 ✕ → **그 Term 하나만** 닫는다(워크스페이스나 pane이 아니라). 인덱스는 클릭 시점에 재조회해
/// 유효하지 않으면 무동작한다. 실행 중 명령 확인은 Term 단위 닫기의 기존 규율(`closeTermAt` → 캐스케이드)을
/// 그대로 따른다 — 마지막 Term이면 pane이, 마지막 pane이면 워크스페이스가 함께 닫힌다.
pub fn closeAgentRow(self: *AppSession, tab_index: usize, pane_index: usize, term_index: usize) void {
    if (tab_index >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_index];
    if (pane_index >= tab.panes.items.len) return;
    if (term_index >= tab.panes.items[pane_index].terms.items.len) return;
    // **반드시 requestClose를 거친다**: 실행 중 명령 확인 모달과 마지막-Term 캐스케이드(pane→탭→세션 latch)가
    // 거기 있다. closeTermAt을 직접 부르면 (1) 돌고 있는 에이전트가 확인 없이 죽고 (2) 마지막 워크스페이스의
    // 마지막 Term에서 closeTab이 세션 latch로 빠지며 해제된 surface에 쓰고(UAF) 이어지는 rebuild가 빈 pane을
    // 인덱싱해 패닉한다(code-review max).
    self.requestClose(.{ .agent_term = .{ .tab = tab_index, .pane = pane_index, .term = term_index } });
}

/// 에이전트 행 클릭 → **그 에이전트가 도는 자리**로 이동한다(§5): 워크스페이스 전환 → 그 Pane 포커스 →
/// 그 Pane 안에서 그 Term 탭 활성화. **3단계가 핵심이다** — Pane까지만 가면 그 Pane의 현재 활성 탭이 보일 뿐,
/// 사용자가 목록에서 지목한 에이전트는 여전히 가려진 탭에 있다.
/// 인덱스는 클릭 시점에 **재조회**해 유효하지 않으면(사이 tick에 닫힘·종료) 무동작한다(stale deref 금지).
pub fn focusAgentRow(self: *AppSession, tab_index: usize, pane_index: usize, term_index: usize) void {
    if (tab_index >= self.tabs.items.len) return;
    _ = tab_ops.switchTab(self, tab_index); // 1) 다른 카드였으면 그 워크스페이스로
    const tab = self.tabs.items[tab_index];
    if (pane_index >= tab.panes.items.len) return;
    const pane = tab.panes.items[pane_index];
    _ = pane_ops.focusPaneByPtr(self, pane); // 2) 그 Pane으로(같은 pane이면 무동작)
    if (term_index >= pane.terms.items.len) return;
    self.focusTerm(term_index); // 3) 그 Pane 안 그 Term 탭으로 — 가려진 탭이 실제로 앞으로 나온다
    self.metal_dirty = true;
}

/// 카드 아래에 붙는 **세션 목록 행**(에이전트 + 일반 터미널)을 방출한다: `N sessions` 토글 + (펼쳐졌으면) 행들.
/// 접힘은 `tab.agents_collapsed`가 든다(비영속, §4).
///
/// **목록을 낼지 말지**(사용자 결정 2026-08-11 — docs/sidebar-agent-list.md §1):
///   - 에이전트가 하나라도 있으면 **Term이 1개여도** 목록을 낸다. 접기는 개수가 아니라 "이 카드를 지금 얼마나
///     펼쳐 둘 것인가"의 문제라서다(2026-07-26 정정 — 그 결정을 여기서 되돌리지 않는다).
///   - 에이전트가 0이면 **Term이 2개 이상일 때만** 낸다. 터미널 하나짜리 워크스페이스는 카드 헤더가 이미 그
///     Term의 폴더·브랜치를 그리므로(sidebarCardTerm = 활성 pane의 활성 Term) 행을 더해도 같은 정보가 두 번
///     나올 뿐이고, 모든 카드가 토글 때문에 두 줄씩 길어진다.
///
/// `Row.agent`/`.agent_toggle` variant 이름은 그대로 둔다 — 이제 터미널 행도 이 variant를 쓰지만, 이름을 바꾸려면
/// `app_session.zig`의 exhaustive switch 25곳을 함께 고쳐야 해서 동작 변경과 기계적 개명이 한 diff에 섞인다.
/// 개명은 후속으로 분리한다(docs/sidebar-agent-list.md §2).
pub fn appendAgentRows(self: *AppSession, out: *std.ArrayList(chrome.components.sidebar.Row), tab_index: usize, depth: u8) void {
    if (tab_index >= self.tabs.items.len) return;
    const tab = self.tabs.items[tab_index];
    var sessions: std.ArrayList(WorkspaceSession) = .empty;
    defer sessions.deinit(self.allocator);
    workspace_ops.collectWorkspaceSessions(tab, &sessions, self.allocator);
    if (sessions.items.len == 0) return;
    // 에이전트 유무는 **라이브 재조회**로 센다 — WorkspaceSession은 인덱스만 들고 kind를 캐시하지 않는다(§2).
    var agent_count: usize = 0;
    for (sessions.items) |s| {
        const t = agentTermOf(tab, s) orelse continue;
        if (t.agent_kind != .none) agent_count += 1;
    }
    if (agent_count == 0 and sessions.items.len < 2) return; // 터미널 1개뿐 = 카드 헤더가 곧 그 Term(위 주석)
    out.append(self.allocator, .{
        .agent_toggle = .{
            .tab = tab_index,
            .count = std.math.lossyCast(u16, sessions.items.len),
            .collapsed = tab.agents_collapsed,
            .depth = depth,
            .last = tab.agents_collapsed, // 접히면 토글이 이 묶음의 마지막 행이다(아래 여백을 카드와 같게)
        },
    }) catch return;
    if (tab.agents_collapsed) return; // 접혔으면 행은 안 낸다(토글만 남는다)
    for (sessions.items, 0..) |s, idx| {
        out.append(self.allocator, .{
            .agent = .{
                .tab = tab_index,
                .pane = s.pane,
                .term = s.term,
                .depth = depth,
                .lines = sidebar_ops.sidebarAgentRowLines(self, tab, s),
                .last = idx + 1 == sessions.items.len, // 마지막 행만 아래 여백을 카드와 같게(밴드 하단)
            },
        }) catch return;
    }
}

/// 인덱스 경로 → 라이브 Term(범위 밖이면 null). 목록 행이 포인터 대신 인덱스를 드는 계약의 재조회 지점이다.
pub fn agentTermOf(tab: *Tab, ag: WorkspaceSession) ?*Term {
    if (ag.pane >= tab.panes.items.len) return null;
    const pane = tab.panes.items[ag.pane];
    if (ag.term >= pane.terms.items.len) return null;
    return pane.terms.items[ag.term];
}

pub fn agentPollIntervalTicks(self: *const AppSession) u32 {
    return self.ticksForMs(agent_poll_interval_ms);
}

pub fn agentObserverIntervalTicks(self: *const AppSession) u32 {
    return self.ticksForMs(agent_observer_interval_ms);
}

/// running 에이전트 스피너(사이드바 이퀄라이저 파형) 위상을 한 스텝 진행한다 — **tick()에서 출력과 무관하게 매 tick**
/// 호출된다. 커서 blink(updateCursorBlink)와 달리 스피너는 활성 surface의 출력과 무관한 애니메이션이라, 출력 게이트
/// (`output>0`이면 resetCursorBlink, else updateCursorBlink)에 얹으면 안 된다 — 연속 출력(SSH firehose·바쁜 원격 TUI)이
/// 매 tick 스피너 advance를 굶겨 **다른 탭의 running 에이전트 스피너가 멈추던** 버그의 근본 수정(§10.5 primary). 사이드바에
/// **실제로 보이는** 카드 중 running 에이전트가 있거나 archive worker가 목록을 읽는 동안에만 위상을 진행하고 사이드바만 부분
/// 투영(chrome_dirty)한다. archive spinner도 같은 wall-clock 위상을 재사용해 별도 tick/타이머를 만들지 않는다.
pub fn advanceAgentSpinner(self: *AppSession) void {
    if (!anyAgentRunning(self) and !self.agent_session_archive_loading) {
        self.agent_spin_last_ns = 0; // running 없음 — 무동작 + baseline 리셋(다음 running이 새 위상으로 시작)
        return;
    }
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (self.agent_spin_last_ns == 0) {
        self.agent_spin_last_ns = now; // 첫 running tick — baseline만 세팅, 위상 불변
        return;
    }
    const interval_ns: i128 = @as(i128, agent_spin_interval_ms) * std.time.ns_per_ms;
    const elapsed = now - self.agent_spin_last_ns;
    if (elapsed < interval_ns) return; // 한 주기 안 지남 — 아직 진행 안 함
    // **wall-clock 경과분**만큼 위상 진행(tick 카운트 아님). tick이 느리거나 stall 후 재개돼도 실시간을 따라가
    // 부드럽고, 큰 gap이면 여러 프레임을 한 번에 catch-up한다(§10.5 secondary). 소비한 interval의 나머지는 남겨
    // (last_ns를 정확히 소비분만큼 전진) 위상을 실시간에 drift 없이 고정한다. 파형 길이(14)로 wrap.
    const steps = @divTrunc(elapsed, interval_ns);
    const wrap: u8 = @intCast(@mod(steps, @as(i128, spinner_wave.len)));
    self.agent_spin_frame = (self.agent_spin_frame + wrap) % @as(u8, @intCast(spinner_wave.len));
    self.agent_spin_last_ns += steps * interval_ns;
    self.chrome_dirty = true; // [A] 사이드바만 부분 투영(sync hold 중에도 진행 + full-grid 재셰이프 회피)
}

/// 사이드바에 **실제로 보이는** 워크스페이스 카드 중 running 에이전트가 있으면 true — 스피너 위상을 진행할지/사이드바를
/// 재투영할지 결정한다. 접힘이면 스피너가 안 보이고(false), 검색 필터로 숨은 탭은 카드가 없으므로(스피너 미표시) 제외해야
/// 한다 — 그래서 `tabs` 전체가 아니라 `sidebar_rows`(필터 통과 = 표시 카드)만 본다(code-review high #1: 옛 전체-스캔이
/// 접힘·필터아웃에도 130ms 재투영을 돌리던 회귀). 빈 검색이면 visible_tabs=전체라 평소와 동일.
pub fn anyAgentRunning(self: *AppSession) bool {
    // **사이드바 카드의 애니메이션 파형만** 이 위상 게이트에 걸린다 — 탭바 running 표시는 **정적 1칸 플래그(●)**라
    // 매 프레임 재투영이 필요 없다(상태 변화 시에만 pollAgentKinds가 dirty; 게이트는 agentDisplayVisible이 탭바까지 커버).
    // 접힘·chrome_minimal이면 사이드바가 없어(sidebar_width_px=0) 카드 파형도 없으니 false(표시면 없는데 130ms 재셰이프
    // 방지, code-review high #1 + max). 검색 필터로 숨은 탭은 카드가 없으므로 `sidebar_rows`만 본다. running 판정은
    // 활성 Term만이 아니라 **어느 pane/Term이든**(tabHasRunningAgent) — 백그라운드 Term도 카드 파형을 돌린다(범위 확장).
    if (self.sidebar_collapsed or self.chrome_minimal) return false;
    for (self.sidebar_rows.items) |row| switch (row) {
        .card => |c| if (c.tab < self.tabs.items.len and tab_ops.tabHasRunningAgent(self.tabs.items[c.tab])) return true,
        .agent_toggle, .agent => {}, // 같은 탭의 부속이라 카드 판정으로 충분
        .group_header, .recovered_sessions_header, .recovered_session => {}, // system/header row엔 에이전트가 없다
    };
    return false;
}

/// **에이전트 종류가 바뀌면 지난 프로세스의 관측을 통째로 버린다.**
///
/// 여기서 비우는 자리는 전부 「지난 프로세스가 남긴 값」이고, 하나라도 남으면 새 프로세스가 그 값을
/// 근거로 판정된다. 두 자리가 특히 위험하다:
///
/// - `agent_screen_seq` — 권위표 C1 의 미관측 가드가 `screen_seq != 0` 으로 「화면을 봤다」를 판단한다.
///   남으면 새 프로세스에서 화면을 **한 번도 안 읽었는데 승인 대기가 즉시 풀린다**(적대적 검증이 잡았다).
/// - `agent_arbiter` — C2 의 연속 셈. 남으면 지난 프로세스의 관측으로 새 프로세스를 접는다.
///
/// **호출부에서 분리해 둔 이유는 판정자다.** 이 리셋은 로컬 `classifyAgentProcesses` 경로 안쪽에 있어
/// 제품 테스트로 도달하기 어려웠고(원격 경로는 `remote_owns_kind` 로 갈린다), 그래서 필드 13 개 중
/// `agent_state` 하나만 잠겨 있었다. 함수로 꺼내면 나머지 열둘도 직접 잠근다.
///
/// ⚠️ **여기에 없는 것**: `metal_dirty` 와 사이드바 재투영은 `self` 가 필요해 호출부에 남겼다.
pub fn resetAgentObservationForKindChange(term: *Term) void {
    // 새 프로세스의 화면/OSC/activity를 이전 상태와 섞지 않는다.
    term.agent_state = .unknown;
    term.agent_hook_state = .unknown;
    term.agent_screen_state = .unknown;
    term.agent_screen_visible_blocker = false;
    term.agent_screen_visible_idle = false;
    term.agent_screen_idle_is_chrome = false;
    term.agent_screen_output_active = false;
    term.agent_screen_rule = "";
    term.agent_screen_origin = .screen;
    term.agent_screen_seq = 0;
    term.agent_arbiter.reset();
    term.agent_stabilizer.reset();
    term.agent_screen_generation = 0;
    term.agent_last_output_ms = 0;
    term.agent_transcript.reset();
}

pub fn pollAgentKinds(self: *AppSession) void {
    self.agent_poll_ticks += 1;
    self.agent_observer_poll_ticks += 1;
    // 시간 경과만으로 바뀌는 표시(활동 시각)를 위한 주기적 재렌더. 사이드바가 보이고 에이전트가 하나라도
    // 있을 때만 — 그 조건이 아니면 그릴 것이 없다.
    self.agent_age_repaint_ticks += 1;
    if (self.agent_age_repaint_ticks >= self.ticksForMs(agent_age_repaint_interval_ms)) {
        self.agent_age_repaint_ticks = 0;
        // 사이드바 카드가 실제로 보이는 상태에서만(접힘·minimal chrome이면 그릴 자리가 없다).
        if (!self.sidebar_collapsed and !self.chrome_minimal and anyAgentPresent(self)) self.metal_dirty = true;
    }
    const periodic_kind_probe = self.agent_poll_ticks >= agentPollIntervalTicks(self);
    const observer_probe = self.agent_observer_poll_ticks >= agentObserverIntervalTicks(self);
    if (!periodic_kind_probe and !observer_probe) return;
    if (periodic_kind_probe) self.agent_poll_ticks = 0;
    if (observer_probe) self.agent_observer_poll_ticks = 0;
    if (!self.surface_initialized) return;
    // **원격 채널을 여기서 돌린다 — 소비자보다 먼저, 그러나 같은 throttle 뒤에서.**
    //
    // 순서: 채널을 먼저 채워야 아래 `pollAgentConsumer` 의 모드 판정이 이번 회차에 도착한 이벤트를 본다.
    // 뒤집으면 모든 이벤트가 한 회차씩 늦고, 증상은 «배지가 한 박자 늦다» 뿐이라 원인을 못 찾는다.
    //
    // 자리: tick 마다가 아니라 **이 throttle 뒤**다. 매 tick 부르면 원격 Term 마다 회차당 힙 할당 둘
    // (`dest` dupe + control socket 경로)이 60 fps 로 돈다 — 로컬 훅은 이미 이 게이트 뒤에 있으므로
    // 원격만 앞서 달릴 이유가 없고, 그동안 온 바이트는 파이프가 들고 있다(64 KiB).
    self.pumpRemoteAgentChannels();
    // 모든 pane × 모든 Term을 보되 syscall은 ≈0.5s로 throttle한다. 화면에 카드/탭바가 실제로 보이는 탭만
    // 상태 변화 시 dirty해, background observer가 불필요한 프레임을 만들지 않는다.
    for (self.tabs.items, 0..) |tab, ti| {
        const displayed = agentDisplayVisible(self, ti); // 스피너/플래그/아이콘 재렌더 게이트(카드 or 활성 탭 탭바) — 탭 내 모든 Term 공유
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (!term.rt.live_initialized or term.rt.terminated) continue; // 종료(미reap) Term은 건너뜀(dispatchBell과 동형)
                const be = self.backendFor(term);
                be.readObservation(term.rt.handle, self.allocator, &term.rt.observation, periodic_kind_probe) catch |err| {
                    // 마지막 coherent snapshot은 유지하되 current로 가장하지 않는다. remote reconnect 동안 kind/state를
                    // none/idle로 덮지 않는 것이 알림 누락보다 안전하다.
                    // ⚠️ **사유를 남긴다.** 예전에는 `catch {` 로 오류를 통째로 버려서, 관측이 `stale` 에 머물러도
                    // **왜인지 알 방법이 없었다** — 기록도 notice 도 로그도 없었다. 실사용에서 그 상태가 30 분 넘게
                    // 지속됐는데(2026-09-03) 사유가 안 남아 원격을 하나씩 무죄로 만들어 가며 추측할 수밖에 없었다.
                    //
                    // **`if (… == .current)` 안에 둔다 = 전이 순간만 찍힌다.** 이 자리는 모든 tab/pane/term 을 도는
                    // 주기 루프라 매 회차 찍으면 로그 폭탄인데, 이미 `stale` 이면 이 조건이 막는다. 진동하면 여러 번
                    // 찍히지만 그 진동 자체가 정보다.
                    if (term.rt.observation.availability == .current) {
                        std.log.scoped(.agent).warn(
                            "observation read failed, marking stale (periodic probe) err={s}",
                            .{@errorName(err)},
                        );
                        term.rt.observation.availability = .stale;
                    }
                };
                const observation_current = term.rt.observation.availability == .current;
                const foreground_available = observation_current and term.rt.observation.foreground_available;
                const pgid = if (observer_probe and foreground_available)
                    (term.rt.observation.foreground_pgid orelse 0)
                else
                    term.rt.agent_observer_pgid;
                const pgid_changed = observer_probe and pgid != term.rt.agent_observer_pgid;
                if (observer_probe and foreground_available) term.rt.agent_observer_pgid = pgid;
                // ⚠️ **원격 채널이 있는 Term 은 프로세스 트리로 판정하지 않는다.** 그 pane 의 로컬
                // 포그라운드는 `ssh` 라 여기서 늘 `.none` 이 나오고, 그러면 훅 줄의 provider 로 세워 둔
                // 값을 **매 회차 덮어쓴다** — 게다가 아래 «종류가 바뀌었다» 가지가 `agent_state` 를
                // `.unknown` 으로 되돌리고 대화 줄까지 지운다. 배지가 떴다 사라졌다 하는 모양이 된다
                // (적대적 검증 2 회차가 잡았다).
                //
                // 원격에서는 **훅 줄이 더 확실한 소스다** — 그 줄을 쓴 것이 그 provider 이기 때문이다.
                const remote_owns_kind = term.agent_remote_channel != null;
                if ((periodic_kind_probe or pgid_changed) and foreground_available and !remote_owns_kind) {
                    const prev = term.agent_kind;
                    term.agent_kind = classifyAgentProcesses(term.rt.observation.foreground_processes.items);
                    if (diag_gate.maruDebugEnabled()) std.log.scoped(.agentdiag).info("kind={s} pgid_changed={} live={} term=0x{x}", .{ @tagName(term.agent_kind), pgid_changed, term.rt.live_initialized, @intFromPtr(term) });
                    if (term.agent_kind != prev) {
                        if (displayed) self.metal_dirty = true; // 보이는 Term의 에이전트 변화만 재렌더
                        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info("agent: {s}", .{@tagName(term.agent_kind)});
                        // 새 프로세스의 대화를 이전 세션 것과 섞지 않는다. 응답 줄이 사라지면 행 줄 수도
                        // 바뀌므로 **재투영까지** 해야 한다 — metal_dirty만으로는 행 높이가 옛 값으로 남는다.
                        const had_reply_kind = term.agent_transcript.owned.reply().len > 0;
                        resetAgentObservationForKindChange(term);
                        if (had_reply_kind) sidebar_ops.rebuildSidebar(self) catch {};
                    }
                }
                // **원격 채널이 열린 Term 도 들어온다.** ssh 너머의 프로세스 트리는 로컬에서 안 보여
                // `agent_kind` 가 영영 `.none` 이라, `!= .none` 만으로 막으면 원격 축은 판정 함수까지
                // 도달하지도 못한다 — 채널이 열려도 배지가 영영 안 서는 자리였다.
                if (observer_probe and (term.agent_kind != .none or term.agent_remote_channel != null)) {
                    // **판정은 Term 마다 하나이고, 그 판정에 두 소스가 들어간다**(계약 §1 — 2026-09-01
                    // 개정). 예전 주석은 「훅 모드면 화면·OSC 를 아예 읽지 않는다」였는데 그 배타가
                    // 승인 해제·codex 오류 턴·훅 유실을 구조적으로 못 메웠다. 지금은 §1.1 권위표가
                    // 둘을 중재하고, 뒤집기는 그 표에 열거된 것만 허용한다.
                    //
                    // 훅 로그 확인은 `observation_current` 를 요구하지 않는다 — 그것은 화면 관측이 최신인지의
                    // 조건이고, 파일을 읽는 데는 상관이 없다.
                    pollAgentConsumer(self, term, displayed, observation_current);
                }
            }
        }
    }
}

/// 세션 기록 파일에서 그 Term의 **마지막 대화**(프롬프트·응답)를 갱신한다(docs/sidebar-agent-list.md §7).
///
/// **선택적 보강**(계약 1)이라 어떤 실패도 조용히 지나간다 — 디렉터리가 없든(경로 인코딩 규칙이 provider 변경으로
/// 어긋나든), 파일을 못 열든, JSON이 깨졌든 행은 아이콘·상태·폴더·브랜치로 정상 동작하고 대화 줄만 빈다.
/// 그래서 이 함수는 error를 내지 않는다.
pub fn pollAgentTranscript(self: *AppSession, term: *Term, displayed: bool) void {
    if (term.agent_kind == .none) return;
    const cache = &term.agent_transcript;
    const now = self.awakeMs();
    if (cache.last_poll_ms != 0 and now -| cache.last_poll_ms < transcript_poll_interval_ms) return;
    cache.last_poll_ms = now;

    // **줄 수를 좌우하는 값**으로 재투영을 판정한다. 예전엔 `isEmpty()`(프롬프트 OR 응답) 변화로 봤는데, 행
    // 줄 수는 `reply()`만 늘리므로 "프롬프트는 이미 있고 응답만 새로 왔다"에서 재투영이 안 돌아 렌더는 3줄을
    // 그리고 행 높이는 2줄로 남았다 — 그러면 응답 줄이 다음 행 위에 그려지고 클릭이 이웃 행의 ✕에 닿는다
    // (code-review max). 프롬프트는 1행 안에서 자리를 바꿀 뿐이라 줄 수에 영향이 없다.
    // **provider가 밝힌 세션 신원**을 먼저 확보한다(§7.2 채택안). 얻으면 그 값으로 파일을 확정하고, 못 얻으면
    // 아래 provider 경로가 활동 상관 폴백으로 내려간다. 자식이 떠 있는 순간에만 읽히므로 캐시가 필수다.
    // The provider-native identity is also the authority for the archive detail's exact
    // live-Term action.  It must not depend on a shell OSC-7 CWD report: an agent launched
    // before its shell integration emits CWD can still be the already-open session the user
    // asked to return to.  Transcript path lookup below does require CWD, so keep that
    // optional enrichment separate from identity observation.
    refreshAgentSessionIdentity(self, term);
    // **cwd는 Claude 경로에만 필요하다.** 그 경로는 `~/.claude/projects/<cwd 슬러그>/`를 찾느라 cwd를 쓰지만
    // (`claudeDirName`), codex는 신원이 곧 파일명이라 `refreshCodexTranscript`가 `_ = cwd`로 무시한다.
    // 그런데 예전에는 여기서 **둘 다** 막았다 — cwd를 모르면 codex도 대화를 못 읽었다. 그 provider에게는
    // 필요하지도 않은 값 때문에. 아래처럼 provider별로 가른다.
    //
    // 그리고 그 cwd 자체도 **축**을 쓴다(`git_ops.termCwd` — OSC 7 → 커널 조회 2단, 단일 출처는
    // docs/editor-surface-dock.md §3.5). 관측만 보던 동안에는 셸 통합이 없는 셸과 재개 Term에서 Claude
    // 대화가 통째로 비어, 사이드바 에이전트 행이 마지막 프롬프트·응답 없이 종류 이름만 보였다.
    //
    // **수명**: `refreshClaudeTranscript`는 이 슬라이스를 슬러그 계산에만 쓰고 밖으로 내보내지 않으므로
    // 스택 버퍼로 충분하다. 이 함수는 Term당 `transcript_poll_interval_ms`(1초)로 throttle되어 있어
    // 커널 조회가 여기서 늘리는 비용은 무시할 수준이다.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = git_ops.termCwd(self, term, &cwd_buf) orelse "";
    const had_reply = cache.owned.reply().len > 0;
    // provider마다 다른 건 **경로 규칙·신원 확인·레코드 모양** 셋뿐이다(§7.3). 매핑 규율(고정하지 않음)·throttle·
    // 재투영은 여기 공통으로 남는다.
    const changed = switch (term.agent_kind) {
        // cwd를 못 풀면 슬러그를 만들 수 없어 이 갈래만 건너뛴다(추측으로 다른 디렉터리를 열지 않는다).
        .claude => cwd.len > 0 and refreshClaudeTranscript(self, term, cwd),
        .codex => refreshCodexTranscript(self, term, cwd),
        .none => false,
    };
    if (!changed) return;

    // 대화 **유무**가 바뀌면 행 줄 수가 바뀌므로 재투영이 필요하다(행 높이·hit-test·밴드가 sidebar_rows에서
    // 나온다). 텍스트만 바뀐 경우엔 라벨이 매 프레임 조립되므로 dirty만 세우면 된다.
    const has_reply = cache.owned.reply().len > 0;
    if (has_reply != had_reply) sidebar_ops.rebuildSidebar(self) catch {};
    if (displayed) self.metal_dirty = true;
}

/// 갤러리 소스를 **훅 없이** 채운다(계약 §4.4 폴백).
///
/// 훅이 `transcript_path` 를 주는 것이 기본 경로다. 하지만 훅이 설치 전이거나 codex 승인 대기이거나
/// 에이전트가 창보다 먼저 떠 있었으면 그 값이 영영 안 온다 — 그때 갤러리는 「이미지가 없습니다」로
/// 조용히 비고, 사용자에게는 고장과 구분되지 않는다.
///
/// **추측은 하지 않는다.** 여기서 쓰는 것은 사이드바 대화 라벨이 이미 자식 env 신원으로 확정해 둔
/// 바로 그 파일(`term.agent_transcript`)이다. 신원이 없으면 폴백도 없다 — 「그 디렉터리의 최신 파일」
/// 추측은 §7.2 가 이미 기각했다(새 터미널에 직전 세션 대화가 붙었다).
///
/// 이미 소스가 있으면 아무것도 하지 않는다. 훅이 나중에 오면 그 값이 이긴다(같은 파일이면 무동작).
pub fn adoptFallbackImageSource(self: *AppSession, term: *Term) void {
    if (!term.agent_image_source.isEmpty()) return;
    const cache = &term.agent_transcript;
    if (cache.identity_len == 0 or cache.name_len == 0) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path: []const u8 = switch (term.agent_kind) {
        .none => return,
        // codex 는 `fileName()` 이 `~/.codex/sessions` 아래 상대경로다(날짜 계층을 포함한다).
        .codex => blk: {
            const home_z = std.c.getenv("HOME") orelse return;
            break :blk maru.session.agent_transcript.codexTranscriptPath(&buf, std.mem.span(home_z), cache.fileName()) orelse return;
        },
        // claude 는 `~/.claude/projects/<cwd 슬러그>/<신원>.jsonl` 이다 — 슬러그 때문에 cwd 가 필요하다.
        .claude => blk: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = git_ops.termCwd(self, term, &cwd_buf) orelse return;
            var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
            const claude_dir = settings_ops.claudeConfigDir(&dir_buf) orelse return;
            break :blk maru.session.agent_transcript.claudeTranscriptPath(&buf, claude_dir, cwd, cache.fileName()) orelse return;
        },
    };
    _ = term.agent_image_source.set(path);
}

/// 자식 프로세스 env에서 세션 신원을 읽는다(§7.2.1 — 기본 경로, 사용자 파일 무침습).
pub fn agentIdentityFromChildEnv(self: *AppSession, term: *Term, key: []const u8, buf: []u8) ?[]const u8 {
    _ = self;
    const pid = agentProcessPid(term.rt.observation.foreground_processes.items, term.agent_kind) orelse return null;
    return maru.pty.PtySession.agentSessionIdentity(pid, key, buf);
}

/// claude 상태줄 훅이 적어둔 per-pane 신원 파일을 읽는다(§7.2.2 — 옵션 보강).
///
/// 훅은 `MARU_PANE_ID`(= surface id)를 파일명으로 쓰므로 **어느 Term의 세션인지가 자동으로 붙는다**. 자식 env가
/// 안 잡히는 경우(도구를 한 번도 안 쓴 세션)를 이 경로가 메운다. codex는 해당 없다 — 외부 스크립트를 실행하는
/// 상태줄 설정이 없다.
pub fn agentIdentityFromStatuslineFile(self: *AppSession, term: *Term, buf: []u8) ?[]const u8 {
    if (term.agent_kind != .claude) return null;
    const sl = maru.session.agent_statusline;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = sessionCacheBase(a) orelse return null;
    const path = std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ base, sl.session_dir_rel, term.surfaceId() }) catch return null;
    const raw = readFileAlloc(self.io, a, path) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!sl.plausibleIdentity(trimmed)) return null;
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

/// claude 상태줄 훅을 config(`sidebar.agent-transcript-hook`)에 맞춰 설치하거나 제거한다. 앱 시작 시 한 번,
/// 그리고 config 재적용 때 호출한다(docs/sidebar-agent-list.md §7.2.2).
///
/// **사용자 소유 파일을 건드리는 유일한 자리**라 규율을 여기서 지킨다:
/// - 이미 사용자가 쓰던 상태줄이 있으면 **지우지 않고 감싼다**(우리 스크립트가 그 명령을 그대로 실행).
/// - 감쌌던 원래 명령의 **단일 출처는 설치 마커**다. 스크립트 안의 표식은 사람이 읽으라고 있는 것이고, 우리가
///   매 실행마다 덮어쓰는 파일을 유일한 근거로 삼았다가 실제로 사용자 상태줄을 영구히 잃었다(§7.2.2).
/// - 마커 파일 `flock`으로 **인스턴스 사이를 직렬화**한다. 잡지 못하면 물러난다.
/// - 끄면 감쌌던 원래 명령을 `statusLine`에 복원하고 우리 것(스크립트·마커)을 지운다 — 설치 전 상태로 돌아간다.
///
/// best-effort다. 실패는 조용히 지나간다 — 이 훅이 없어도 대화는 자식 신원 경로(§7.2.1)로 대부분 잡힌다.
/// **상태줄 훅을 거둔다**(계약 §5 — 2026-08-21 실행). 설치는 더 이상 하지 않는다.
///
/// 그 훅이 하던 일은 payload 에서 `session_id` 를 뽑아 pane 파일에 적는 것 하나였는데, provider 훅
/// `SessionStart` 가 `session_id` + `transcript_path` + `cwd` 를 함께 준다 — 상위집합이고 경로 조립도
/// 사라진다. 사용자 `statusLine.command` 를 감싸던 침습이 없어지는 것은 순이득이다: 그 경로는 과거에
/// 실제로 사용자 상태줄을 잃은 사고를 냈고, **오늘도 한 번 더 냈다**(격리를 잊은 실험이 사용자 원본을
/// 덮었다 — 감싸는 설계는 «settings 의 현재 값 = 사용자 것» 을 믿을 수밖에 없어 그 믿음이 깨지면
/// 원본이 사라진다).
///
/// ⚠️ **대가**: 관측 모드에서 세션 신원을 자식 env 로 못 잡는 세션은 사이드바 대화 줄이 빈다
/// (sidebar-agent-list.md §7.2 가 원래 적어 둔 한계로 돌아간다). 훅 게이트가 아직 기본 꺼짐이라,
/// 켜지 않은 사용자에게는 **잃기만 하는** 변경이다. 그 사실을 계약 §5 에 적어 둔다.
///
/// 이 함수는 **되돌리는 일만** 한다 — 우리 것이면 원본으로 되돌리고 우리 파일을 거둔다. 사용자가 그 사이
/// statusLine 을 직접 바꿨으면 settings 는 그대로 두고 우리 파일만 치운다.
pub fn removeAgentStatuslineHook(self: *AppSession) void {
    if (!is_macos) return;
    // **테스트에서는 밝힌 경우에만 돈다** — `reconcileAgentHooks` 와 같은 규율이다. 격리를 잊은 테스트가
    // 개발자의 사용자 상태줄 설정을 덮은 사고가 실제로 났다.
    if (builtin.is_test and !test_allow_provider_writes) return;
    const sl = maru.session.agent_statusline;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // **claude 가 설치돼 있을 때만 손댄다.** 디렉터리가 없으면 claude 를 쓰지 않는 사람이므로 만들지 않는다.
    var claude_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const claude_dir = settings_ops.claudeConfigDir(&claude_dir_buf) orelse return;
    const dir_handle = openAgentDirAbsolute(self, claude_dir, .{}) orelse return;
    dir_handle.close(self.io);
    const script_path = std.fmt.allocPrint(a, "{s}/{s}", .{ claude_dir, sl.script_name }) catch return;
    const hooks_path = std.fmt.allocPrint(a, "{s}/settings.json", .{claude_dir}) catch return;
    const marker_path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ claude_dir, sl.marker_name }, 0) catch return;

    // **마커를 만들지 않는다**(`create = false`). 지우는 쪽이라 잠글 것이 없으면 할 일도 없다 — 만들었다
    // 지우는 것도 남의 홈을 건드리는 일이다.
    const lock = switch (StatuslineLock.acquire(marker_path, false)) {
        // 다른 인스턴스가 지금 같은 일을 하고 있다 → 우리가 할 일은 없다.
        .contended => return,
        // 애초에 잠글 수 없는 환경(권한·파일시스템)이다. 락을 넣기 전과 같은 위험을 지고 진행한다.
        .unlockable => |l| l,
        .locked => |l| l,
    };
    defer lock.release();

    const script_read = readFileState(self.io, a, script_path);
    const existing_script: ?[]const u8 = switch (script_read) {
        .present => |body| body,
        else => null,
    };
    const settings = readStatusLineState(a, self.io, hooks_path);
    const marker: ?sl.Marker = switch (readFileState(self.io, a, marker_path)) {
        .present => |text| sl.parseMarker(text),
        else => null,
    };
    const script_wrapped = if (existing_script) |body| sl.extractWrappedCommand(a, body) else null;

    // **복원**: 마커 → 스크립트 wrap 순으로 원본을 찾는다.
    const restored = switch (sl.restoreActionFor(settings, marker, script_wrapped)) {
        // 현재 상태를 못 읽었다 — 지우고 나면 되돌릴 근거가 사라지므로 **아무것도 하지 않는다**.
        .unknown => return,
        .leave => true,
        .set => |cmd| writeStatusLineCommand(a, self.io, hooks_path, cmd, settings),
        .clear => writeStatusLineCommand(a, self.io, hooks_path, null, settings),
    };
    // **복원에 실패했으면 근거를 지우지 않는다.** 지워버리면 사용자가 나중에 파일을 고쳐도 되살릴 것이 없다.
    if (!restored) return;
    std.Io.Dir.cwd().deleteFile(self.io, script_path) catch {};
    // 마커는 락 대상이라 지금 잡고 있는 fd 가 가리킨다. 지우고 나서 close 해도 락은 정상적으로 풀린다.
    std.Io.Dir.cwd().deleteFile(self.io, marker_path) catch {};
}

/// 훅 이벤트 로그 디렉터리의 절대 경로. **설치와 정리가 같은 자리를 봐야 한다** — 두 곳에서 따로 조립하면
/// 한쪽만 바뀌었을 때 «설치는 A 에 쓰고 정리는 B 를 지운다» 가 조용히 성립하고, 증상은 「로그가 안 줄어든다」
/// 하나뿐이라 원인에 닿기 어렵다.
fn agentHookLogDir(a: std.mem.Allocator) ?[:0]const u8 {
    const base = sessionCacheBase(a) orelse return null;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ base, maru.session.agent_hook_command.log_dir_rel }, 0) catch null;
}

/// 이 **프로세스**를 가리키는 훅 로그 인스턴스 식별자(현재 pid).
///
/// **왜 필요한가**(계약 §4): 로그 디렉터리는 사용자 캐시 하나뿐인데 `surface.id` 는 프로세스마다 1 부터
/// 발급된다(`SurfaceIdAllocator`). 그래서 maru 를 두 개 띄우면 두 인스턴스의 첫 pane 이 **같은 파일 이름**을
/// 갖는다 — 서로의 이벤트를 읽고, 시작 시 정리가 남의 살아 있는 로그를 지운다. 이 값이 그 이름공간을 가른다.
///
/// **pid 를 쓰는 이유**: 살아 있는지 물어볼 수 있는 유일한 값이다(`kill(pid, 0)`). 시작 시 정리가 «남의
/// 인스턴스 디렉터리를 지워도 되는가» 를 그것으로 판정한다 — 무작위 id 였다면 그 질문에 답할 수 없어
/// 옛 정리처럼 «전부 지운다» 로 돌아가야 한다.
pub fn hookInstanceId() u64 {
    return @intCast(std.c.getpid());
}

/// 이 프로세스가 소유하는 훅 인스턴스 칸의 **이름**. 값 자체는 pid 지만 문자열 모양은 계약 모듈이 정한다 —
/// host 소유 칸(`host_<hex>`)과 한 이름공간을 쓰므로 두 모양을 한곳에서 봐야 «어느 방법으로 살아 있는지
/// 묻는가» 가 갈리지 않는다(docs/agent-hooks.md §4).
pub fn hookInstanceToken(buf: *[maru.session.agent_hook_command.instance_token_max]u8) []const u8 {
    return maru.session.agent_hook_command.formatGuiInstance(buf, @intCast(hookInstanceId()));
}

/// 이 인스턴스의 훅 로그 칸(`<로그 디렉터리>/<인스턴스>`). 훅이 파일을 만드는 자리이자, 우리가 읽고
/// 종료할 때 지우는 자리다.
fn agentHookInstanceDir(a: std.mem.Allocator) ?[:0]const u8 {
    const dir = agentHookLogDir(a) orelse return null;
    var token_buf: [maru.session.agent_hook_command.instance_token_max]u8 = undefined;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, hookInstanceToken(&token_buf) }, 0) catch null;
}

/// 이 프로세스가 훅 로그를 이미 정리했는가(위 «프로세스에 한 번» 규칙). 테스트는 한 바이너리에서 세션을
/// 여러 번 만들므로 정리 경로를 보려면 이 값을 되돌린다.
pub var hook_logs_cleaned = false;

/// 테스트가 **시작 시 정리를 실제로 돌리겠다**고 밝히는 스위치. 기본은 꺼짐이다.
///
/// 왜 필요한가: 이 정리는 로그 디렉터리의 `<숫자>.ndjson` 을 **전부** 지운다. 테스트가 `AppSession.init`
/// 을 부르면서 `XDG_CACHE_HOME`(또는 `HOME`)을 격리하지 않으면 그 «전부» 가 **개발자의 진짜 캐시**다 —
/// 실제로 그렇게 사용자가 쓰고 있던 세션의 이벤트 로그를 날렸다(2026-08-21, 실사용 중에 재현). 테스트는
/// 자기 머신 밖에 흔적을 남기지 않아야 하고, 남기더라도 **그러겠다고 밝힌 테스트만** 그래야 한다.
pub var test_allow_log_cleanup = false;

/// 테스트가 **provider 설정 파일을 실제로 고치겠다**고 밝히는 스위치. 기본은 꺼짐이다.
/// 격리를 잊은 테스트가 개발자의 `~/.claude/settings.json`·`~/.codex/hooks.json` 을 고치지 않게 —
/// 그 사고가 실제로 났다(`reconcileAgentHooks`).
pub var test_allow_provider_writes = false;

/// 테스트가 **턴 스냅샷을 실제로 찍겠다**고 밝히는 스위치. 기본은 꺼짐이다.
///
/// 이 경로는 `git` 을 띄우고 캐시에 임시 index 를 쓰며, `submitSnapshot` 이 job 을 **detached worker** 에
/// 넘기고 그 해제를 그 스레드가 한다. 테스트가 곧바로 `deinit` 하면 worker 가 아직 안 끝난 순간이 있어
/// job 의 `create`·`dupe` 가 누수로 잡힌다 — 타이밍을 타서 **로컬은 통과하고 CI 만 빨개진다**(실제로
/// 그렇게 났다). 링을 실제로 채우는지 보는 테스트만 켜고 돈다.
pub var test_allow_turn_snapshot = false;
/// 마지막 캡처가 **어느 세션에 실으려 했나**(테스트 전용). 게이트 앞에서 기록한다.
pub var test_last_turn_session: [maru.session.turn_snapshot.max_session_id_len]u8 = undefined;
pub var test_last_turn_session_len: usize = 0;

/// 시작할 때 남아 있는 훅 이벤트 로그를 **읽지 않고 지운다**(docs/agent-hooks.md §4.2·§5).
///
/// **게이트와 무관하게 돈다.** 게이트를 꺼도 이미 설치된 훅은 계속 쓰는데, 회전이 «소비»에 붙어 있어
/// (§4.2) 소비자가 없으면 파일이 무한히 자란다. 그 안에는 프롬프트 원문·셸 명령·편집 전후 문자열이
/// 평문으로 들어 있으므로(§7) 자라게 두는 것 자체가 손해다.
///
/// **시작할 때만 부른다.** config 재적용 때 같이 돌면 살아 있는 세션이 방금 적은 이벤트를 지운다 —
/// 지금은 소비자가 없어 차이가 없지만, AH3이 들어오는 순간 조용한 유실이 된다.
///
/// 지난 실행의 이벤트를 버리는 것은 의도다. 로그는 «기록»이 아니라 «큐»이고(§4.2), 이미 끝난 세션의
/// 큐에는 옮길 곳이 없다.
pub fn cleanupAgentHookLogs(self: *AppSession) void {
    if (!is_macos) return;
    // **프로세스에 한 번이다.** `AppSession`은 **창마다** 만들어지므로(`maru_macos_app_session_create`), 창을
    // 하나 더 열 때마다 이 함수가 다시 돌면 **먼저 열린 창의 터미널이 지금 쓰고 있는 로그를 지운다.** 지금은
    // 소비자가 없어 티가 안 나지만 AH3이 들어오면 그대로 조용한 유실이다.
    if (hook_logs_cleaned) return;
    // **테스트에서는 밝힌 경우에만 돈다.** 격리를 잊은 테스트가 개발자의 진짜 로그를 지우지 않게 —
    // 그 사고가 실제로 났다(위 `test_allow_log_cleanup`).
    if (builtin.is_test and !test_allow_log_cleanup) return;
    hook_logs_cleaned = true;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const log_dir = agentHookLogDir(a) orelse return;
    var dir = openAgentDirAbsolute(self, log_dir, .{ .iterate = true }) orelse return;
    defer dir.close(self.io);

    // **훑고 나서 지운다.** 순회 중에 지우면 readdir이 뒤 항목을 건너뛸 수 있어 매번 몇 개씩 남는다.
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    var doomed_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(self.io) catch return) |entry| {
        // **인스턴스 칸은 살아 있는지 물어보고 지운다**(계약 §4). 이름이 pid 라 `kill(pid, 0)` 으로 답할 수
        // 있다 — 예전에는 디렉터리를 통째로 훑어 지워서, **두 번째 maru 를 켜는 것만으로 첫 번째가 지금
        // 쓰고 있는 로그가 사라졌다**(그 프로세스의 Term 들은 커서 기준을 잃는다). 우리 것이면 지운다
        // (지난 실행의 잔재이거나 우리가 방금 만든 빈 칸이다 — 어느 쪽이든 큐를 비우고 시작한다).
        if (entry.kind == .directory) {
            // **host 가 소유하는 칸(`host_<hex>`)은 우리 것이 아니다**(계약 §4 — 각 소유자가 자기 칸을
            // 만들고 치운다). 숫자 파싱이 그것을 이미 거르지만, 그 사실이 «우연» 이 아니라 계약이라는 것을
            // 여기 적어 둔다 — 이 필터를 넓히는 변경은 **살아 있는 host 의 로그를 지운다.**
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue; // 숫자 이름만 우리 것이다
            const ours = pid == @as(i32, @intCast(std.c.getpid()));
            if (!ours and instanceAlive(pid)) continue; // 남이 살아 있다 — 그 칸은 그 인스턴스 것이다
            doomed_dirs.append(a, a.dupe(u8, entry.name) catch return) catch return;
            continue;
        }
        if (entry.kind != .file) continue;
        // **우리가 만든 이름만 지운다** — pane 식별자(숫자) + `.ndjson`. 남이 이 디렉터리에 무엇을 두었든
        // 그것까지 치우는 것은 우리 일이 아니다.
        // 회전 도중 죽으면 `<id>.ndjson.rotated` 만 남는다 — 그것도 우리 것이므로 함께 거둔다.
        const rotated_suffix = maru.session.agent_hook_event.rotated_suffix;
        const without_rotated = if (std.mem.endsWith(u8, entry.name, rotated_suffix))
            entry.name[0 .. entry.name.len - rotated_suffix.len]
        else
            entry.name;
        if (!std.mem.endsWith(u8, without_rotated, ".ndjson")) continue;
        const stem = without_rotated[0 .. without_rotated.len - ".ndjson".len];
        if (stem.len == 0) continue;
        var all_digits = true;
        for (stem) |c| {
            if (c < '0' or c > '9') all_digits = false;
        }
        if (!all_digits) continue;
        doomed.append(a, a.dupe(u8, entry.name) catch return) catch return;
    }
    for (doomed.items) |name| dir.deleteFile(self.io, name) catch {};
    for (doomed_dirs.items) |name| {
        const sub = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ log_dir, name }, 0) catch continue;
        var sub_handle = openAgentDirAbsolute(self, sub, .{ .iterate = true }) orelse continue;
        var sub_doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        var sub_it = sub_handle.iterate();
        while (sub_it.next(self.io) catch break) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            sub_doomed.append(a, a.dupe(u8, sub_entry.name) catch break) catch break;
        }
        for (sub_doomed.items) |sub_name| sub_handle.deleteFile(self.io, sub_name) catch {};
        sub_handle.close(self.io);
        std.Io.Dir.deleteDirAbsolute(self.io, sub) catch {};
    }
}

/// 그 pid 의 프로세스가 아직 사는가. 시작 시 정리가 «남의 인스턴스 칸을 지워도 되는가» 를 이것으로 묻는다.
///
/// `ESRCH` 만 «죽었다» 로 읽는다 — `EPERM`(다른 사용자의 프로세스)은 **살아 있다는 뜻**이므로 남긴다.
/// ⚠️ pid 는 재사용되므로 «죽은 maru 의 pid 를 다른 프로그램이 물려받은» 경우 그 칸이 남는다. 그때는 그
/// 프로그램이 끝난 뒤 다음 실행이 거둔다 — 살아 있는 남의 로그를 지우는 쪽보다 이 방향이 낫다.
/// Zig 0.16 `std.c` 가 노출하지 않는 것(메모리: syscall 미노출 목록) — 직접 선언한다.
const posix_ext = struct {
    extern "c" fn getpgid(pid: std.c.pid_t) std.c.pid_t;
};

fn instanceAlive(pid: i32) bool {
    // `kill(pid, 0)` 대신 `getpgid` 로 존재만 묻는다 — macOS 의 `kill` 시그니처가 signal **열거**를 요구해
    // 0 을 넘길 수 없다. 판정 규율은 같다: `ESRCH` 만 «죽었다» 이고, 권한 거부 등 나머지는 **살아 있다** 는
    // 뜻이므로 보수적으로 남긴다.
    const rc = posix_ext.getpgid(pid);
    if (rc >= 0) return true;
    return std.posix.errno(rc) != .SRCH;
}

/// provider 훅을 config(`sidebar.agent-hooks`)에 맞춰 claude `settings.json`에 설치한다. 앱 시작 시 한 번,
/// config 재적용 때 한 번 — 위 `reconcileAgentStatusline`과 같은 자리에서 돈다(docs/agent-hooks.md §5).
///
/// **판정과 트리 수술은 여기서 하지 않는다.** `session/agent_hook_install.zig`가 순수 층으로 소유하고
/// (파일 없이 전수로 돌 수 있다), 여기서는 그 층이 요구하는 것을 파일 세계에서 지킨다:
/// - **읽지 못한 파일은 건드리지 않는다.** 0바이트 창(provider가 쓰는 중)을 «빈 설정»으로 접으면 사용자
///   설정을 통째로 날린다 — 같은 계열의 상태줄 경로가 실제로 낸 사고다.
/// - **`flock`으로 인스턴스 사이를 직렬화**하되, 잠글 것은 `settings.json` **자신**이다. 상태줄 경로는 잠글
///   대상이 스크립트·settings 둘이라 별도 마커가 필요했지만, 여기서는 고치는 파일이 하나뿐이라 남의 홈에
///   새 파일을 만들 이유가 없다.
/// - **compare-and-swap.** 읽고 쓰는 사이에 provider나 사용자가 바꾼 값을 덮지 않는다.
/// - **한 번만 쓴다.** «걷어 내고 다시 넣기»를 두 번에 나눠 쓰면 그 사이에 죽었을 때 훅이 사라진 파일이 남는다.
///
/// **끔은 «설치하지 않음»이지 «제거»가 아니다**(계약 §5). 게이트가 꺼져 있으면 여기서 그냥 나간다 —
/// 인스턴스 둘이 서로 다른 게이트 값을 가지면(정식 빌드와 dev 빌드) 설치·삭제가 무한히 왕복하기 때문이다.
///
/// best-effort다. 실패는 조용히 지나가고, 그러면 그 세션은 관측 모드로 남는다(계약 §1.2).
pub fn reconcileAgentHooks(self: *AppSession) void {
    if (!is_macos) return;
    // **테스트에서는 밝힌 경우에만 돈다.** 이 함수는 게이트가 꺼져 있으면 «지운다» 경로를 타는데,
    // `CLAUDE_CONFIG_DIR`·`HOME` 을 격리하지 않은 테스트가 `AppSession.init` 을 부르면 그 대상이
    // **개발자의 진짜 `~/.claude/settings.json`** 이다 — 실제로 사용자가 켜 둔 훅을 지웠다(2026-08-21,
    // 표식 있는 항목만 정확히 사라지는 것으로 재현했다. 로직은 맞고 대상이 틀렸다).
    // 로그 정리(`cleanupAgentHookLogs`)와 같은 규율이다.
    if (builtin.is_test and !test_allow_provider_writes) return;
    const hook_command = maru.session.agent_hook_command;

    // **끄면 지운다**(계약 §5). 게이트 값이 곧 의도다 — 켜고 끄기가 한 쌍이라야 사용자가 되돌릴 수 있다.
    // 판정이 개수에만 달려 있어(`ours > 0`) 이미 지워진 상태에서 다시 돌아도 무동작이다.
    const intent: maru.session.agent_hook_install.Intent =
        if (self.loaded_config.config.sidebar.agent_hooks) .ensure else .uninstall;

    // **provider 마다 따로 돈다.** 한쪽이 없거나 실패해도 다른 쪽은 서야 한다 — 둘을 한 트랜잭션으로
    // 묶으면 claude 를 안 쓰는 사람에게 codex 훅도 안 걸린다.
    inline for (.{ hook_command.Provider.claude, hook_command.Provider.codex }) |provider| {
        reconcileProviderHooks(self, provider, intent);
    }
}

/// 한 provider 의 훅 파일을 맞춘다. 위 `reconcileAgentHooks` 의 doc comment 가 규율의 단일 출처다.
fn reconcileProviderHooks(
    self: *AppSession,
    provider: maru.session.agent_hook_command.Provider,
    intent: maru.session.agent_hook_install.Intent,
) void {
    const install = maru.session.agent_hook_install;
    const hook_command = maru.session.agent_hook_command;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // **그 provider 가 설치돼 있을 때만 손댄다.** 디렉터리가 없으면 그것을 쓰지 않는 사람이므로 만들지 않는다.
    var config_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env_value = if (std.c.getenv(install.configDirEnv(provider))) |v| std.mem.span(v) else null;
    const home = if (std.c.getenv("HOME")) |v| std.mem.span(v) else null;
    const config_dir = install.configDir(provider, &config_dir_buf, env_value, home) orelse return;
    const dir_handle = openAgentDirAbsolute(self, config_dir, .{}) orelse return;
    dir_handle.close(self.io);

    // **로그 디렉터리를 먼저 만든다.** 훅은 디렉터리를 만들지 않고 없으면 조용히 아무것도 적지 않는다
    // (그 조용함은 의도다 — 계약 §4.1). 설치만 하고 이 자리를 빠뜨리면 훅이 도는데 이벤트가 0인,
    // 진단하기 가장 나쁜 상태가 된다. 권한은 0700이고 파일 쪽 0600은 커맨드의 `umask`가 지킨다.
    // **지울 때는 디렉터리를 만들지 않는다.** 끄는 사람의 디스크에 우리 자리를 새로 잡을 이유가 없다.
    // 경로 자체는 커맨드를 만들 때 필요하므로(그 문자열이 우리 항목의 모양이다) 계산은 양쪽 다 한다.
    const log_dir = agentHookLogDir(a) orelse return;
    if (intent == .ensure) {
        // 캐시 base 자체가 아직 없을 수 있다(새 사용자·캐시를 비운 뒤). `mkdir`은 부모를 만들지 않으므로 둘을 차례로 만든다.
        const cache_base = sessionCacheBase(a) orelse return;
        const base_z = std.fmt.allocPrintSentinel(a, "{s}", .{cache_base}, 0) catch return;
        _ = std.c.mkdir(base_z.ptr, 0o700);
        _ = std.c.mkdir(log_dir.ptr, 0o700); // 이미 있으면 EEXIST — 그대로 진행한다
        // **인스턴스 칸도 우리가 만든다.** 훅은 `mkdir` 을 부르지 않으므로(계약 §4.1) 이 자리가 없으면
        // 훅이 조용히 아무것도 안 적는다 — 이벤트 0 인 채로 도는, 진단하기 가장 나쁜 상태다.
        if (agentHookInstanceDir(a)) |inst_dir| {
            _ = std.c.mkdir(inst_dir.ptr, 0o700);
            _ = std.c.chmod(inst_dir.ptr, 0o700);
        }
        // **이미 있던 디렉터리도 좁힌다.** `mkdir`은 EEXIST면 권한을 손대지 않으므로, 옛 버전이나 넉넉한 umask가
        // 만들어 둔 `0755` 디렉터리가 그대로 남는다. 우리가 만든 자리이니 우리가 맞춘다(파일 쪽은 훅의 `umask`).
        _ = std.c.chmod(log_dir.ptr, 0o700);
        // **만들지 못했으면 설치하지 않는다.** 훅만 걸고 디렉터리가 없으면 이벤트가 0인 채로 도는, 진단하기 가장
        // 나쁜 상태가 된다(그 조용함은 훅 커맨드의 의도된 성질이라 사용자에게 아무 신호도 가지 않는다).
        const log_dir_handle = openAgentDirAbsolute(self, log_dir, .{}) orelse return;
        log_dir_handle.close(self.io);
    }

    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    hook_command.build(&cmd, a, provider.tag(), log_dir, .local) catch return;

    const hooks_path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ config_dir, install.hooksFileName(provider) }, 0) catch return;

    // 훅 파일 자신을 잠근다. **파일이 없으면 만들지 않는다**(`create = false`) — 잠그자고 남의 홈에
    // 빈 파일을 만들 이유가 없고, 그때는 락 없이 진행한다(설치 전과 같은 위험이고 더 나빠지지 않는다).
    //
    // **심링크는 실체를 잠근다.** dotfile 관리자가 그 파일을 심링크로 두는 구성이 흔한데
    // (`writeExecutableFile`이 같은 이유로 실체를 해석한다), 락은 `O_NOFOLLOW`로 열기 때문에 심링크면 열기
    // 자체가 실패해 **직렬화가 조용히 사라진다.** 쓰는 쪽이 실체를 갈아 끼우므로 잠글 것도 실체다.
    const lock_path = blk: {
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.realPathFileAbsolute(self.io, hooks_path, &real_buf) catch break :blk hooks_path;
        break :blk std.fmt.allocPrintSentinel(a, "{s}", .{real_buf[0..len]}, 0) catch break :blk hooks_path;
    };
    const lock = switch (StatuslineLock.acquire(lock_path, false)) {
        .contended => return, // 다른 인스턴스가 지금 같은 일을 하고 있다
        .unlockable => |l| l,
        .locked => |l| l,
    };
    defer lock.release();

    // 여기부터 끝까지가 하나의 read-modify-write다.
    const before = readFileState(self.io, a, hooks_path);
    const state: install.State = switch (before) {
        .unreadable => .unreadable,
        .absent => .absent,
        .present => |text| blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch break :blk .unreadable;
            const root = switch (parsed.value) {
                .object => |o| o,
                else => break :blk .unreadable,
            };
            break :blk if (install.scan(provider, .local, root.get("hooks"), cmd.items)) |known|
                .{ .known = known }
            else
                .unreadable;
        },
    };
    const plan = install.planForSet(provider, .local, state, intent);
    if (plan == .abort) return; // 모르는 상태 — 손대지 않는다
    if (!install.mutates(plan)) {
        // 이미 설치돼 있어도 **신뢰 항목은 확인한다** — 훅 파일은 그대로인데 `config.toml` 쪽만
        // 지워졌을 수 있고(캐시 정리·수동 편집), 그러면 훅이 돌지 않는다.
        if (provider == .codex and intent == .ensure) ensureCodexTrust(self, a, config_dir, hooks_path, cmd.items);
        // 지우는 쪽은 훅 항목이 없어도 **신뢰 잔재가 남아 있을 수 있다**(위치가 바뀌어 옛 키가 남은 경우).
        if (provider == .codex and intent == .uninstall) removeCodexTrust(self, a, config_dir);
        return;
    }

    // 계획을 세운 그 바이트를 다시 읽어 트리를 만든다. 읽기 실패·파싱 실패는 여기서도 «쓰지 않음»이다.
    var root: std.json.ObjectMap = .empty;
    switch (before) {
        .absent => {},
        .unreadable => return,
        .present => |text| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return;
            switch (parsed.value) {
                .object => |o| root = o,
                else => return,
            }
        },
    }

    // compare-and-swap: 판단 근거가 아직 유효한가. **여기서는 `stillOwns`(inode 대조)를 따로 보지 않는다** —
    // 파일 바이트 전체를 대조하는 이쪽이 더 강하고(내용이 같으면 어느 inode든 우리가 본 그 상태다), 상태줄
    // 경로가 inode를 봐야 했던 것은 그쪽이 마커 파일을 지웠다 만들기 때문이다. 로그 디렉터리 생성과 커맨드 조립 사이에 provider가
    // 자기 훅을 넣었을 수 있다.
    const now = readFileState(self.io, a, hooks_path);
    const unchanged = switch (before) {
        .absent => now == .absent,
        .unreadable => false,
        .present => |old| switch (now) {
            .present => |fresh| std.mem.eql(u8, old, fresh),
            else => false,
        },
    };
    if (!unchanged) return;

    var hooks: std.json.ObjectMap = switch (root.get("hooks") orelse std.json.Value{ .object = .empty }) {
        .object => |o| o,
        else => return, // scan이 이미 걸렀어야 하지만, 쓰기 직전에 한 번 더 본다
    };
    const mode: maru.session.agent_hook_install.Mode = switch (intent) {
        .ensure => .install,
        .uninstall => .remove,
    };
    install.apply(provider, .local, a, &hooks, cmd.items, mode) catch return;
    if (hooks.count() == 0) {
        _ = root.orderedRemove("hooks");
    } else {
        root.put(a, "hooks", .{ .object = hooks }) catch return;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(a, &out);
    std.json.Stringify.value(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    out = aw.toArrayList();
    writeExecutableFile(self.io, hooks_path, out.items, false) catch return;

    // 쓴 **뒤에** 신뢰를 맞춘다 — 키가 항목의 위치 인덱스를 담으므로 파일이 확정된 다음이라야 한다.
    if (provider == .codex) {
        switch (intent) {
            .ensure => ensureCodexTrust(self, a, config_dir, hooks_path, cmd.items),
            .uninstall => removeCodexTrust(self, a, config_dir),
        }
    }
}

/// codex `config.toml` 에서 **우리 표식이 붙은 신뢰 블록**을 거둔다(계약 §5 — 끄면 지운다).
///
/// **표식이 유일한 기준이다.** 사용자가 직접 승인해 codex 가 적은 항목에는 표식이 없으므로 살아남는다.
/// 키 모양으로 판정하면 같은 훅을 손수 승인한 사람의 신뢰를 지운다.
///
/// 거둔 뒤 남은 것이 공백뿐이면 **파일째 지운다** — 우리가 만든 파일이었다는 뜻이라, 그래야 설치 전
/// 상태로 정확히 돌아간다(빈 파일을 남기면 «껐는데 뭔가 남았다» 가 된다).
///
/// best-effort다. 실패하면 잔재가 남을 뿐이고, codex 는 짝이 안 맞는 키를 무시한다.
fn removeCodexTrust(self: *AppSession, a: std.mem.Allocator, config_dir: []const u8) void {
    const trust = maru.session.agent_hook_trust;

    const config_path = std.fmt.allocPrint(a, "{s}/config.toml", .{config_dir}) catch return;
    const before: []const u8 = switch (readFileState(self.io, a, config_path)) {
        .present => |body| body,
        // 없으면 지울 것도 없다. 읽지 못한 파일에는 손대지 않는다(설치 경로와 같은 규율).
        .absent, .unreadable => return,
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    const removed = trust.removeTrustEntries(&out, a, before) catch return;
    if (!removed) return; // 우리 것이 없었다 — 사용자 파일의 mtime 을 흔들지 않는다

    // compare-and-swap: 읽은 바이트가 그대로일 때만 쓴다(설치 경로와 같은 이유 — 훅 파일이 없으면
    // 잠글 것이 없어 두 인스턴스가 동시에 여기 올 수 있다).
    const now: []const u8 = switch (readFileState(self.io, a, config_path)) {
        .present => |body| body,
        .absent => "",
        .unreadable => return,
    };
    if (!std.mem.eql(u8, before, now)) return;

    if (trust.isBlank(out.items)) {
        std.Io.Dir.cwd().deleteFile(self.io, config_path) catch {};
        return;
    }
    writeExecutableFile(self.io, config_path, out.items, false) catch return;
}

/// codex `config.toml` 의 신뢰 항목을 맞춘다(계약 §2.1). codex 는 신뢰가 적혀 있지 않은 훅을 실행하지
/// 않으므로, 이것이 없으면 설치는 됐는데 아무것도 안 도는 상태가 된다.
///
/// **비어 있는 키만 채운다.** 이미 값이 있으면 우리 것이든 codex 가 고친 것이든 건드리지 않는다 —
/// codex 쪽 포맷이 바뀌어 우리 값이 틀려졌을 때, 사용자가 승인해 codex 가 적은 올바른 값을 매번 덮어
/// 지우면 **무한 승인 프롬프트**가 된다. 비어 있을 때만 쓰면 최악이 프롬프트 한 번이고 그 뒤로 낫는다.
///
/// best-effort다. 실패하면 codex 가 한 번 물어볼 뿐이다.
fn ensureCodexTrust(
    self: *AppSession,
    a: std.mem.Allocator,
    config_dir: []const u8,
    hooks_path: []const u8,
    cmd: []const u8,
) void {
    const install = maru.session.agent_hook_install;
    const hook_command = maru.session.agent_hook_command;
    const trust = maru.session.agent_hook_trust;

    // 방금 쓴 파일을 **다시 읽어** 자리를 잡는다. 메모리의 트리를 그대로 쓰면 rename 이 실패했거나 다른
    // 인스턴스가 끼어든 경우에도 «썼다» 고 믿게 된다.
    const text = switch (readFileState(self.io, a, hooks_path)) {
        .present => |body| body,
        else => return,
    };
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return;
    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    var slots: [install.max_events]install.Placement = undefined;
    const found = install.ourPlacements(root_obj.get("hooks"), cmd, &slots);
    if (found == 0 or found > slots.len) return; // 넘치면 어느 것이 빠졌는지 모른다 — 손대지 않는다

    // **키는 실체 경로로 만든다** — 심링크 경로로 적으면 codex 가 정규화한 키와 어긋나 그 훅이 영영
    // 미신뢰로 남는다(계약 §2.1 실측).
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hooks_real = if (std.Io.Dir.realPathFileAbsolute(self.io, hooks_path, &real_buf)) |len|
        real_buf[0..len]
    else |_|
        hooks_path;

    const config_path = std.fmt.allocPrint(a, "{s}/config.toml", .{config_dir}) catch return;
    const before: []const u8 = switch (readFileState(self.io, a, config_path)) {
        .present => |body| body,
        .absent => "",
        // 읽지 못한 파일에는 쓰지 않는다 — 우리가 모르는 상태다(설치 경로와 같은 규율).
        .unreadable => return,
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    out.appendSlice(a, before) catch return;
    // **판정은 순수 층 하나가 한다.** 이 결정에는 두 겹의 미묘함이 있고(값이 낡았을 때의 갱신, «이미
    // 써 본 값» 을 다시 안 쓰는 루프 방지) 원격 설치기(`maru agent-hooks`)도 같은 결정을 해야 한다 —
    // 두 곳에 적으면 반드시 갈리고, 갈린 쪽은 매 실행 승인 프롬프트가 뜨는 무한 루프가 된다.
    var slot_buf: [install.max_events]trust.Slot = undefined;
    for (slots[0..found], 0..) |placement, i| {
        // matcher 는 **세트가 정한 값**이다(파일에 적힌 값이 아니라) — 우리가 넣은 항목이므로 같다.
        var matcher: ?[]const u8 = null;
        for (hook_command.eventsFor(.codex, .local)) |e| {
            if (std.mem.eql(u8, e.name, placement.json_name)) matcher = e.matcher;
        }
        slot_buf[i] = .{
            .json_name = placement.json_name,
            .group_index = placement.group_index,
            .handler_index = placement.handler_index,
            .matcher = matcher,
        };
    }
    const stats = trust.applyEntries(&out, a, hooks_real, slot_buf[0..found], cmd, hook_command.timeout_seconds) catch return;
    const added = stats.added;
    const stale = stats.stale;
    const refreshed = stats.refreshed;
    const diverged = stats.diverged;
    // 쓰기 성패와 무관하게 알린다 — 어긋남은 «쓸 것이 없어서» 안 쓰는 경로에서 생긴다.
    //
    // **0 도 그대로 쓴다(latch 금지).** `if (stale != 0)` 로 두면 한 번 세워진 수가 안 내려가서, 사용자가
    // codex 에서 승인해 값이 맞아진 뒤에 이 함수가 다시 돌아도(설정 적용 등) 옛 수가 남아 **거짓 알림**이
    // 뜬다. 이 값은 «지금 어긋난 개수» 이지 «어긋난 적이 있다» 가 아니다.
    //
    // **«고쳤다» 는 쓴 뒤에야 참이다.** 아래 CAS 는 다른 인스턴스가 끼어들면 쓰기를 건너뛰고, 쓰기 자체도
    // 실패할 수 있다. 그 전에 세워 두면 **아무것도 안 고쳤는데 「고쳤습니다」** 가 뜬다. 그리고 그때 그
    // 훅들은 여전히 안 도는 상태이므로, 쓰기 전에는 **고치려던 것까지 «어긋남» 으로** 센다 — 사용자에게
    // 갈 말은 「고쳤다」가 아니라 「codex 에서 승인하라」다.
    self.agent_hook_trust_stale = stale + refreshed;
    self.agent_hook_trust_refreshed = 0;
    // 관측이라 쓰기와 무관하다(쓰기 성패가 이 사실을 바꾸지 않는다).
    self.agent_hook_trust_diverged = diverged;
    if (added == 0 and refreshed == 0) return; // 쓸 것이 없으면 사용자 파일의 mtime 을 흔들지 않는다

    // **compare-and-swap.** 훅 파일 락이 인스턴스 사이를 대부분 직렬화하지만, 훅 파일이 **아직 없을 때는**
    // 잠글 것이 없어(그때는 만들지 않는다) 두 인스턴스가 동시에 여기 올 수 있다. 그대로 두면 둘 다
    // 붙여서 **같은 테이블이 두 번** 적히고, 그 순간 codex 는 `config.toml` 전체를 못 읽는다 — 훅이
    // 아니라 사용자의 설정이 통째로 죽는다. 읽은 바이트가 그대로일 때만 쓴다.
    const now: []const u8 = switch (readFileState(self.io, a, config_path)) {
        .present => |body| body,
        .absent => "",
        .unreadable => return,
    };
    if (!std.mem.eql(u8, before, now)) return; // 그 사이 누가 고쳤다 — 다음 기회에 맞춘다

    writeExecutableFile(self.io, config_path, out.items, false) catch return;
    // 여기까지 왔으면 파일에 실제로 들어갔다 — 그제서야 «고쳤다» 다.
    self.agent_hook_trust_stale = stale;
    self.agent_hook_trust_refreshed = refreshed;
    // **새로 만든 파일은 좁힌다.** 기존 파일이면 `writeExecutableFile` 이 권한을 승계하므로 손대지 않는다
    // (사용자가 일부러 넓혀 둔 것을 우리가 되돌릴 이유가 없다). 없던 파일은 umask 를 타므로 우리가 정한다.
    if (before.len == 0) {
        const path_z = std.fmt.allocPrintSentinel(a, "{s}", .{config_path}, 0) catch return;
        _ = std.c.chmod(path_z.ptr, 0o600);
    }
}

/// 에이전트가 자식에게 내려주는 **세션 신원**을 캐시에 채운다(claude `CLAUDE_CODE_SESSION_ID`, codex
/// `CODEX_THREAD_ID`). 이미 값이 있으면 자식이 없어도 유지하고, 새 값이 오면 교체한다(`/clear`로 세션이
/// 갈리는 경우 — 같은 프로세스가 새 id를 내려준다).
///
/// 자식은 **도구 실행 중에만** 존재하므로 대부분의 호출은 null이다. 그래서 값을 얻지 못한 것 자체는 실패가
/// 아니고, 호출부는 신원이 있으면 확정 결속·없으면 활동 상관 폴백으로 갈린다.
pub fn refreshAgentSessionIdentity(self: *AppSession, term: *Term) void {
    if (!is_macos) return; // 원격 host-backed는 pid가 이 기계에 없다 — 폴백 경로가 받는다
    const key: []const u8 = switch (term.agent_kind) {
        .claude => "CLAUDE_CODE_SESSION_ID",
        .codex => "CODEX_THREAD_ID",
        .none => return,
    };
    var buf: [maru.session.agent_transcript.max_identity_bytes]u8 = undefined;
    const value = agentIdentityFromChildEnv(self, term, key, &buf) orelse
        agentIdentityFromStatuslineFile(self, term, &buf) orelse return;
    const cache = &term.agent_transcript;
    if (std.mem.eql(u8, cache.identity(), value)) return;
    // 신원이 바뀌었다 = 다른 세션이다. 옛 대화가 새 세션 행에 남지 않게 매핑을 통째로 버린다.
    cache.reset();
    cache.setIdentity(value);
    self.metal_dirty = true;
}

/// 훅 payload 가 밝힌 **세션 신원**을 채택한다(AT1).
///
/// 위 `refreshAgentSessionIdentity` 와 **같은 채택 절차**이고 다른 것은 값의 출처뿐이다 — 그쪽은 자식
/// 프로세스 env 를 «샘플» 하고(짧은 도구는 그 창을 대부분 놓친다), 이쪽은 provider 자신의 진술을 읽는다.
/// 두 값이 갈리면 **payload 가 이긴다**.
///
/// **이 배관은 `git.zig` 의 `sessionIdentityFor` 주석이 이미 약속하던 것**인데 실제로는 없었다. 그래서
/// 훅 모드의 링이 빈 신원(→ `captureTurnSnapshot` 이 그대로 조기 반환)이나 `/clear` 뒤의 **낡은 신원**에
/// 붙었다.
fn adoptHookSessionIdentity(self: *AppSession, term: *Term, ev: maru.session.agent_hook_event.Event) void {
    const tr = maru.session.agent_transcript;
    if (!maru.session.agent_hook_mode.carriesSessionIdentity(ev)) return;
    // **이스케이프를 푼 뒤 상한을 잰다** — 한 자리에서 해야 «풀고 나서 길어지는» 값이 안 샌다. 버퍼가
    // 상한보다 하나 큰 이유가 그것이다: 넘치는 값이 상한에 딱 맞게 잘려 **통과해 버리는** 것을 막는다.
    //
    // 표시 경로(`hookDisplayText`)는 쓰지 않는다 — 그쪽은 UTF-8 경계로 자르는데, 키를 자르면 조용히
    // **다른 키**가 된다.
    var buf: [tr.max_identity_bytes + 1]u8 = undefined;
    const value = maru.session.agent_hook_event.decodeInto(&buf, ev.session_id);
    // **상한을 넘으면 채택하지 않는다(자르지 않는다).** `Cache.setIdentity` 는 `@min` 으로 자르는데
    // `RingMap.ringFor` 는 그 길이를 정상 키로 받는다 — 앞부분을 공유하는 **서로 다른 두 세션의 링이
    // 말없이 병합된다**. 순수 층의 `RingMap.setRepo`(「못 담으면 아예 기억하지 않는다」)를 문 앞에 세운다.
    //
    // 실측(2026-08-24, 이 기계의 훅 로그 5,221 이벤트)에서는 `session_id` 가 **전부 36바이트 UUID** 라
    // 이 가지가 밟힌 적이 없다. 그럼에도 남기는 이유는 밟혔을 때의 오염이 **조용하기** 때문이다.
    if (value.len == 0 or value.len > tr.max_identity_bytes) return;
    const cache = &term.agent_transcript;
    if (std.mem.eql(u8, cache.identity(), value)) return;
    // 신원이 바뀌었다 = 다른 세션이다(`/clear`). 옛 대화가 새 세션 행에 남지 않게 매핑을 통째로 버린다 —
    // 관측 경로와 **같은 판단**이다.
    //
    // **진행 중 그림자 사본도 같은 이유로 버린다.** 그 턴은 영영 안 끝난다 — 봉인은 **새** 신원으로
    // 오므로 옛 신원의 진행 중 자리는 아무도 안 닫는다. 안 버리면 ⑴ 그 바이트를 세션이 끝날 때까지 들고
    // ⑵ 진행 중 자리가 8개뿐이라 `/clear` 를 여덟 번 하면 **캡처가 조용히 멈춘다**(새 세션이 자리를 못 얻어
    // `noteBefore` 가 계속 실패한다). `cache.reset()` **전에** 불러야 한다 — 그 뒤에는 옛 신원 슬라이스가
    // 무효다.
    self.turn_captures.dropOpen(self.allocator, cache.identity());
    cache.reset();
    cache.setIdentity(value);
    self.metal_dirty = true;
}

/// 이미지 갤러리가 읽을 파일을 훅 payload 에서 채택한다(docs/agent-image-gallery.md §4.4).
/// `transcript_path` 는 provider 가 **절대 경로를 통째로** 주므로 디렉터리 조립도 추측도 없다 —
/// 바로 위 `adoptHookSessionIdentity` 가 `session_id` 로 하는 일의 짝이다.
///
/// **경로가 바뀌면 그 Term 의 인덱스가 무효다.** `/clear` 는 새 파일을 만들고(실측: 직전 세션 종료
/// 46 ms 뒤 새 세션 시작), 옛 파일의 바이트 오프셋은 새 파일에서 아무 뜻이 없다. 지금은 갤러리가
/// 스캔을 들고 있지 않으므로 다시 그리기만 요청한다 — 인덱스 무효화는 소비자가 생길 때 여기 붙는다.
///
/// 버퍼가 상한보다 하나 큰 이유는 `adoptHookSessionIdentity` 와 같다: 넘치는 값이 상한에 딱 맞게 잘려
/// **통과해 버리는** 것을 막는다. `Source.set` 이 그 길이를 거절해 **비운다** — 자른 경로는 없는 파일이거나
/// 더 나쁘게는 다른 파일이다.
/// 이 pane 이 **지금** 원격인가 — 그 대화 파일은 이쪽 기계에 없다는 뜻이다.
///
/// **채널이 열렸다는 사실이 원격의 증거다**(계약 §11.1). ssh 너머는 `agent_kind` 가 영영 `none` 이고
/// 로컬 로그 파일도 없어서 그 둘로는 판정할 수 없다. ssh 를 빠져나오면 채널을 **떼어 내므로**
/// (`app_session.zig` 의 `remoteUploadContextFor` 분기) 이 값은 래치가 아니다.
pub fn isRemoteAgentPane(term: *const Term) bool {
    return term.agent_remote_channel != null;
}

fn adoptHookImageSource(self: *AppSession, term: *Term, ev: maru.session.agent_hook_event.Event) void {
    if (ev.transcript_path.len == 0) return;
    var buf: [maru.session.agent_image_index.max_source_path_bytes + 1]u8 = undefined;
    const value = maru.session.agent_hook_event.decodeInto(&buf, ev.transcript_path);
    if (!term.agent_image_source.set(value)) return;
    self.metal_dirty = true;
    // 갤러리를 **보고 있을 때만** 다시 훑는다. 안 보는 뷰 때문에 1.6 GB 를 읽지 않는다 —
    // 다음에 들어올 때 `refresh` 가 경로 불일치를 보고 알아서 훑는다.
    image_gallery_ops.onSourceChanged(self);
}

/// claude: 작업 디렉터리를 인코딩한 디렉터리의 **직속** 파일만 본다 — 서브에이전트 기록은 `<세션 id>/` 하위에
/// 쌓이므로 그것만으로 배제된다(§7.3). 대화가 갱신됐으면 true.
pub fn refreshClaudeTranscript(self: *AppSession, term: *Term, cwd: []const u8) bool {
    const tr = maru.session.agent_transcript;
    const cache = &term.agent_transcript;
    // **신원이 없으면 아무것도 하지 않는다.** 예전엔 여기서 "그 디렉터리의 가장 최신 파일"을 추측했는데, 그게
    // 새 터미널에 직전 세션의 대화를 붙이고(사용자 제보) 같은 cwd의 두 에이전트가 서로의 대화를 물게 했다.
    // 추측으로 틀린 대화를 보여주느니 비우는 편이 낫다는 계약 1과도 어긋났다 — 그래서 폴백을 없앴다(§7.2).
    if (cache.identity_len == 0) return false;
    var claude_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const claude_dir = settings_ops.claudeConfigDir(&claude_dir_buf) orelse return false;
    var slug_buf: [1024]u8 = undefined;
    const slug = tr.claudeDirName(cwd, &slug_buf) orelse return false;
    var path_buf: [2048]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&path_buf, "{s}/projects/{s}", .{ claude_dir, slug }) catch return false;
    const dir = openAgentDirAbsolute(self, dir_path, .{}) orelse return false;
    defer dir.close(self.io);

    // **신원이 곧 파일명이다** — `CLAUDE_CODE_SESSION_ID`가 그대로 `<id>.jsonl`이다(provider가 자식 env로 밝힌
    // 값, §7.2). 디렉터리를 훑을 것도 시간을 비교할 것도 없다.
    var name_buf: [tr.max_name_bytes]u8 = undefined;
    const wanted = std.fmt.bufPrint(&name_buf, "{s}.jsonl", .{cache.identity()}) catch return false;
    if (!std.mem.eql(u8, wanted, cache.fileName())) {
        cache.setFileName(wanted);
        cache.read_mtime_ns = 0;
        cache.owned.clear();
    }

    // mtime이 그대로면 다시 읽지 않는다(계약 4).
    const st = dir.statFile(self.io, cache.fileName(), .{}) catch return false;
    if (st.mtime.nanoseconds == cache.read_mtime_ns) return false;
    cache.read_mtime_ns = st.mtime.nanoseconds;

    const tail_buf = self.allocator.alloc(u8, tr.max_tail_bytes) catch return false;
    defer self.allocator.free(tail_buf);
    const tail = tr.readTail(self.io, dir, cache.fileName(), tail_buf);
    if (tail.len == 0) return false;

    var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer parse_arena.deinit();
    var fresh: maru.session.agent_transcript.Owned = .{};
    tr.parseClaudeTail(parse_arena.allocator(), tail, &fresh);
    // 못 찾은 항목은 이전 값을 지킨다(§7.8) — provider 무관 공통 규율.
    tr.mergeKeepingMissing(&cache.owned, &fresh);
    return true;
}

/// codex: 날짜 계층(`YYYY/MM/DD`)이라 디렉터리 이름이 작업 디렉터리를 말해주지 않고, 서브에이전트 기록이
/// **같은 계층에 섞인다**(실측: 최근 40개 중 32개). 그래서 최근 후보를 열어 `session_meta`로 신원을 확인한다 —
/// `thread_source == "user"`이고 cwd가 이 Term과 같은 첫 후보를 고른다. 대화가 갱신됐으면 true.
pub fn refreshCodexTranscript(self: *AppSession, term: *Term, cwd: []const u8) bool {
    const tr = maru.session.agent_transcript;
    const cache = &term.agent_transcript;
    _ = cwd; // 신원으로 파일을 확정하므로 cwd 대조가 필요 없다(그 값이 곧 그 세션이다)
    if (cache.identity_len == 0) return false; // claude와 같은 이유로 폴백 없음(§7.2)
    const home_z = std.c.getenv("HOME") orelse return false;
    const home = std.mem.span(home_z);
    var path_buf: [2048]u8 = undefined;
    const root_path = std.fmt.bufPrint(&path_buf, "{s}/.codex/sessions", .{home}) catch return false;
    const root = openAgentDirAbsolute(self, root_path, .{}) orelse return false;
    defer root.close(self.io);

    // **신원이 파일명에 박혀 있다** — rollout 파일명이 `rollout-<ts>-<thread_id>.jsonl`이고 `CODEX_THREAD_ID`가
    // 그 thread_id(= `session_meta.id`)다. 후보를 열어 신원을 확인할 필요가 없어졌다.
    if (cache.name_len == 0) {
        var suffix_buf: [tr.max_identity_bytes + 8]u8 = undefined;
        const suffix = std.fmt.bufPrint(&suffix_buf, "{s}.jsonl", .{cache.identity()}) catch return false;
        var found_buf: [tr.max_name_bytes]u8 = undefined;
        const found = tr.findCodexByThreadId(self.io, root, suffix, &found_buf) orelse return false;
        cache.setFileName(found);
        cache.read_mtime_ns = 0;
    }

    const st = root.statFile(self.io, cache.fileName(), .{}) catch return false;
    if (st.mtime.nanoseconds == cache.read_mtime_ns) return false;
    cache.read_mtime_ns = st.mtime.nanoseconds;

    const tail_buf = self.allocator.alloc(u8, tr.max_tail_bytes) catch return false;
    defer self.allocator.free(tail_buf);
    const tail = tr.readTail(self.io, root, cache.fileName(), tail_buf);
    if (tail.len == 0) return false;

    var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer parse_arena.deinit();
    var fresh: maru.session.agent_transcript.Owned = .{};
    tr.parseCodexTail(parse_arena.allocator(), tail, &fresh);
    tr.mergeKeepingMissing(&cache.owned, &fresh);
    return true;
}

/// 이 Term 의 상태·대화를 이번 tick 에 **누가** 채우는가. 계약 §1의 «소스는 Term 마다 정확히 하나» 가
/// 여기서 지켜진다 — 두 소비자를 함께 부르면 그 Term 의 상태가 두 곳에서 오고, 증상은 «배지가 가끔 틀림»
/// 이라 재현되지 않는다.
///
/// **이름 있는 함수로 뺀 이유**: 루프 안 `switch` 로 두었더니 그 규칙을 무는 테스트를 쓸 수 없었다.
/// 실제 tick 경로(`pollAgentKinds`)는 도중에 `agent_kind` 를 다시 판정해 되돌리는 자리가 있어, 테스트가
/// 그 뒤를 단언하려 하면 조건부로 건너뛰게 된다(실제로 그렇게 «통과하지만 아무것도 안 보는» 테스트를
/// 한 번 썼고 뮤테이션이 그것을 드러냈다). seam 을 열어 두면 그 규칙만 정확히 겨눌 수 있다.
pub fn pollAgentConsumer(self: *AppSession, term: *Term, displayed: bool, observation_current: bool) void {
    // **모드 판정보다 먼저 «파일이 생겼는지» 를 본다.** 이 한 줄이 없으면 판정이 자기 자신을 잠근다:
    // `log_present` 를 세우는 곳은 `pollAgentHookEvents` 뿐인데 그 함수는 **이미 훅 모드일 때만** 불린다.
    // 그래서 새 Term 은 훅이 로그를 계속 쓰는데도 영영 관측 모드에 남는다 — 게이트를 켠 의미가 없다.
    refreshAgentHookLogPresence(self, term);
    // **두 소스를 한 판정으로 합친다**(§1.1). 예전에는 이 분기가 배타라 훅 Term 에서 `pollAgentState` 가
    // 아예 안 돌았고, 그래서 승인 해제·codex 오류 턴·훅 유실이 구조적으로 못 메워졌다. 지금은 훅이 있어도
    // 화면을 함께 읽고 §1.1 권위표가 둘을 중재한다.
    switch (agentHookMode(self, term)) {
        .hook => {
            pollAgentHookEvents(self, term, displayed);
            // **transcript 는 안 읽는다** — 훅 payload 가 그 자리를 채운다(문서 머리말).
            if (observation_current) pollAgentState(self, term, displayed);
        },
        .observe => {
            // 훅 모드에서 남은 **진행 중 세부**를 버린다. 남겨 두면 관측 소스가 그린 배지 옆에 훅이
            // 적은 문구가 붙는다 — 그것이 곧 계약 §1 이 금지하는 «한 Term 두 소스» 다.
            term.agent_hook_tool.clear();
            // **작업 디렉터리도 버린다**(적대적 검증 1 회차). 안 버리면 에이전트를 끝내고 평범한 셸로
            // 돌아온 뒤에도 폴더줄이 **옛 경로에 붙박인다** — 그때부터는 OSC 7 이 제대로 갱신되는데
            // 그것을 무시하게 되고, 그 모양이 바로 이 블록이 금지하는 «한 Term 두 소스» 다.
            term.agent_hook_cwd.clear();
            // 자식 셈도 버린다. 남기면 훅 모드로 돌아온 뒤 첫 lead `Stop` 이 «자식이 남았다» 로 읽혀
            // 배지가 안 풀린다(다음 프롬프트가 셈을 지울 때까지).
            term.agent_hook_progress.reset();
            // **훅 상태도 버린다**(적대적 검증 2026-09-01 — 위 셋과 같은 이유인데 빠져 있었다). 남기면
            // 훅 소스가 돌아온 순간 **낡은 값이 그대로 배지가 된다**: 설정을 껐다 켜거나 로그가
            // 사라졌다 돌아오는 사이 에이전트가 턴을 끝냈어도 배지는 옛 `running` 이다. `unknown` 으로
            // 두면 §1.1 의 B0 가 첫 훅 이벤트가 올 때까지 화면을 쓴다 — 「모른다」와 「idle 이다」는 다르다.
            term.agent_hook_state = .unknown;
            if (observation_current) {
                pollAgentState(self, term, displayed);
                pollAgentTranscript(self, term, displayed);
            }
        },
    }
    // **배지로 나갈 값은 여기서만 정해진다**(§1.6-⑴). 위 두 경로는 각자 자기 자리에만 썼다.
    arbitrateAgentState(self, term, displayed);
}

/// 훅이 이 pane 의 로그를 **한 번이라도 썼는지** 본다(계약 §1.2의 유일한 동적 입력).
///
/// 모드 판정과 그 입력을 갱신하는 일을 **갈라 둔다.** 한데 두면(= 훅 모드 안에서만 갱신하면) 판정이
/// 자기 입력을 잠근다. 그 실패는 테스트로도 잘 안 드러난다 — 제품 테스트가 `pollAgentHookEvents` 를
/// **직접** 부른 뒤 분기를 보면 이미 값이 서 있어 «들어가는» 경로를 한 번도 안 본다(실제로 그랬다).
///
/// 값싼 `stat` 하나이고 **아직 못 본 Term 에만** 돈다 — 한 번 생긴 파일은 세션 중에 사라지지 않으므로
/// (회전을 시작 시에만 한다) 참이 된 뒤에는 다시 묻지 않는다.
fn refreshAgentHookLogPresence(self: *AppSession, term: *Term) void {
    if (!is_macos) return;
    if (term.agent_hook_log_present) return;
    if (!self.loaded_config.config.sidebar.agent_hooks) return;
    if (term.agent_kind == .none) return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const path = agentHookLogPath(arena_state.allocator(), term) orelse return;
    _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
    term.agent_hook_log_present = true;
}

/// 이 Term 이 지금 **어느 모드인가**(계약 §1.2). 판정의 유일한 동적 입력은 «그 pane 의 로그 파일이 있는가» 다.
///
/// 한 번 생긴 파일은 세션 중에 사라지지 않는다 — 지금은 회전을 하지 않고(계약 §4.2의 ⚠️) 시작 시에만
/// 치우기 때문이다. 없는 파일은 훅이 처음 도는 순간 생긴다.
pub fn agentHookMode(self: *AppSession, term: *Term) maru.session.agent_hook_mode.Mode {
    const mode_mod = maru.session.agent_hook_mode;
    return mode_mod.modeFor(.{
        .gate_on = self.loaded_config.config.sidebar.agent_hooks,
        .log_present = term.agent_hook_log_present,
        .agent_present = term.agent_kind != .none,
        // **원격 축**([계획](../../../../docs/plans/remote-agent-state.md) RA5). ssh 너머는 `agent_kind` 가
        // 영영 `none` 이라(로컬에서 원격 process tree 가 안 보인다) 위 두 줄로는 훅 모드가 성립할 수 없다 —
        // 계약 §11.1 의 세 겹 중 첫째다. 채널이 열렸다는 것 자체가 «저 너머에 훅이 돈다» 는 증거다.
        .remote_channel_open = if (term.agent_remote_channel) |ch| ch.state == .open else false,
    });
}
/// 이 시간을 넘겨 열려 있는 턴은 진단에 한 줄 남긴다. **판정에는 쓰지 않는다** — 시간으로 턴을 닫는 것은
/// 계약이 금지한 그것이다(오래 도는 턴을 조용히 완료로 단정한다). 여기서는 «오래 열려 있다» 는 사실만 적어,
/// 사후에 중단으로 끊긴 턴을 mtime 추정 없이 구분할 수 있게 한다.
const turn_open_warn_ms: i96 = 10 * std.time.ms_per_s * 60; // 10 분

/// 원격 채널에서 온 줄을 소비한다([계획](../../../../docs/plans/remote-agent-state.md) RA5).
///
/// **`pollAgentHookEvents` 와 같은 자리에 같은 값을 쓴다** — 소스만 다르다. 그래서 사이드바·탭 라벨은
/// 아무것도 바뀌지 않고, 상태 전이·알림·대화 줄이 로컬과 **한 벌**로 유지된다(`applyHookEvent` 재사용).
///
/// **파일을 안 읽는다.** 원격 로그는 저쪽 기계에 있고, 이 함수는 이미 도착한 바이트만 본다. 채널을
/// 채우는 것(자식 프로세스 읽기)은 이 함수 밖이다 — 그래야 이 소비 규칙을 파일도 소켓도 없이 시험할 수 있다.
pub fn consumeRemoteAgentLines(self: *AppSession, term: *Term, lines: []const []const u8, now_ms: u64) void {
    const ras = maru.session.remote_agent_stream;
    var ch = &(term.agent_remote_channel orelse return);

    const nonce = term.agent_remote_nonce[0..term.agent_remote_nonce_len];
    for (lines) |line| {
        switch (ch.feed(line, now_ms)) {
            // 커서는 **host 소유**다(채널이 host 당 하나라 모든 Term 이 같은 줄을 본다) — 기억은
            // `recordRemoteCursors` 가 한 곳에서 한다.
            .heartbeat, .ignored, .cursor => {},
            .event => |e| {
                // **우리 pane 의 것만 먹는다.** 채널은 host 당 하나라(RA4) 여러 pane 이 섞여 온다.
                // 형태 검증(경로 문자·대문자 등)은 채널이 이미 했다(`parseFrame`). 여기서는 **우리
                // 것인가**만 본다 — 발급할 때 쓴 값과 바이트가 같아야 한다.
                if (nonce.len == 0 or !std.mem.eql(u8, e.nonce, nonce)) continue;
                var un: std.ArrayListUnmanaged(u8) = .empty;
                defer un.deinit(self.allocator);
                ras.unescapeInto(&un, self.allocator, e.line) catch continue;
                const ev = ras.hookEventFrom(un.items) orelse continue;
                // **이벤트가 provider 를 말해 준다 — 그것으로 `agent_kind` 를 세운다.**
                //
                // ⚠️ 이 한 줄이 없으면 **상태는 옳게 채워지는데 화면이 그것을 안 그린다.** 사이드바·탭·
                // 도크가 「이 Term 에 에이전트가 있나」를 `agent_kind` 로 묻는데, 원격은 프로세스 트리가
                // 안 보여 그 값이 영영 `.none` 이다(계약 §11.1 의 첫 겹) — 그래서 행이 평범한 터미널로
                // 그려지고 배지도 대화 줄도 안 뜬다. 실사용에서 정확히 그 모양이었다: 이벤트는 흐르고
                // 알림도 오는데 **왼쪽 목록만 안 바뀐다**(2026-08-31).
                //
                // 로컬에서는 `classifyAgentProcesses` 가 이 값을 세운다. 원격에서는 **훅 줄의 provider
                // 표식**이 같은 사실을 더 확실하게 말해 준다 — 그 줄을 쓴 것이 그 provider 이기 때문이다.
                const kind: AgentKind = if (std.mem.eql(u8, ev.provider, maru.session.agent_hook_command.Provider.claude.tag()))
                    .claude
                else if (std.mem.eql(u8, ev.provider, maru.session.agent_hook_command.Provider.codex.tag()))
                    .codex
                else
                    .none;
                if (kind != .none and term.agent_kind != kind) {
                    term.agent_kind = kind;
                    self.metal_dirty = true;
                    // 행 높이가 바뀐다(에이전트 행은 상태·대화 줄을 더 쓴다) — 재투영까지 해야 한다.
                    sidebar_ops.rebuildSidebar(self) catch {};
                }
                _ = applyHookEvent(self, term, ev);
            },
        }
    }
    // **원격 이벤트도 배지까지 가야 한다**(§1.6-⑴). `applyHookEvent` 는 훅 자리만 쓰므로, 여기서
    // 권위표를 돌리지 않으면 원격 pane 의 배지가 영영 안 움직인다. C2 의 셈은 `screen_seq` 가 그대로라
    // 늘지 않는다 — 중재를 한 번 더 부르는 것과 화면을 한 번 더 보는 것은 다르다.
    arbitrateAgentState(self, term, true);
    ch.tick(now_ms);
}

/// 훅 이벤트 로그를 읽어 **`term.agent_hook_state`** 를 채운다(계약 §4).
///
/// **배지로 나가는 값은 여기서 정해지지 않는다**(§1.1 · 2026-09-01 개정). 예전에는 이 함수가 훅 모드의
/// 유일한 상태 소스라 `term.agent_state` 를 직접 썼는데, 그러면 승인 해제·codex 오류 턴·훅 유실을
/// 구조적으로 못 메웠다(§1 의 «훅만 보면 비는 자리 셋»). 지금은 같은 tick 에서 `pollAgentState` 도 함께
/// 돌고, 두 자리를 §1.1 권위표가 중재한다(`arbitrateAgentState`).
///
/// 그래도 **자리는 섞이지 않는다.** 이 함수는 훅 자리만 읽고 훅 자리만 쓴다 — `advance` 가 그 값을
/// 입력으로도 쓰기 때문에 화면이 끼어들면 상태 기계가 오염된다(§1.6-⑴).
pub fn pollAgentHookEvents(self: *AppSession, term: *Term, displayed: bool) void {
    if (builtin.is_test) test_hook_calls += 1;
    if (!is_macos) return;
    const event = maru.session.agent_hook_event;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const log_path = agentHookLogPath(a, term) orelse return;

    // 파일이 아직 없으면 훅이 한 번도 안 돈 것이다 — 모드 판정이 그것으로 관측 모드를 유지한다.
    const st = std.Io.Dir.cwd().statFile(self.io, log_path, .{}) catch {
        term.agent_hook_log_present = false;
        return;
    };
    term.agent_hook_log_present = true;

    // **회전을 크기만으로 판정하지 않는다.** 같은 크기로 갈린 파일이 있으면 옛 오프셋으로 새 내용을 읽어
    // 줄 가운데부터 파싱한다. inode 를 함께 본다.
    const same_file = st.inode == term.agent_hook_cursor_inode;
    const first_read = term.agent_hook_cursor_inode == 0;
    term.agent_hook_cursor_inode = st.inode;
    _ = term.agent_hook_cursor.resetIfRotated(st.size, same_file);

    // **부재 중 쌓인 것을 처음부터 재생하지 않는다**(계약 §4). 회전은 GUI 소비에 묶여 있어 keep-alive 로
    // GUI 를 끈 사이엔 아무도 돌리지 않는다 — 재접속한 창이 그 파일을 앞에서부터 읽으면 몇 시간 전 턴을
    // tick 마다 되짚고, 그 사이 알림이 줄줄이 나간다. 첫 읽기에서 창 하나만큼만 남기고 건너뛴다.
    // 창 크기는 «한 tick 이 실제로 닿을 수 있는 만큼» 이다. tick 상한이 이벤트 개수라(`max_events_per_tick`)
    // 창을 그 개수 × 줄 상한으로 잡으면, 짧은 줄이 수만 개인 파일에서 **꼬리에 영영 못 닿는다**(앞에서부터
    // 64 개씩 되짚는다 — 처음에 그렇게 짰다가 테스트가 잡았다). 줄 상한의 두 배면 부분 줄 하나를 버려도
    // 완전한 줄이 반드시 하나는 남고, 남는 것은 **가장 최근** 이벤트다.
    const backlog_window: u64 = maru.session.agent_hook_event.max_line_bytes * 2;
    if (first_read and st.size > term.agent_hook_cursor.offset + backlog_window) {
        term.agent_hook_cursor.offset = st.size - backlog_window;
        term.agent_hook_backlog_catchup = true;
    }

    if (st.size <= term.agent_hook_cursor.offset) return; // 새 내용이 없다

    const want = st.size - term.agent_hook_cursor.offset;
    const chunk_len: usize = @intCast(@min(want, @as(u64, event.max_line_bytes * event.max_events_per_tick)));
    const buf = a.alloc(u8, chunk_len) catch return;
    const file = std.Io.Dir.cwd().openFile(self.io, log_path, .{}) catch return;
    defer file.close(self.io);
    const n = file.readPositionalAll(self.io, buf, term.agent_hook_cursor.offset) catch return;
    if (n == 0) return;

    var events: [event.max_events_per_tick]event.Event = undefined;
    const batch = term.agent_hook_cursor.take(buf[0..n], &events);

    const before = term.agent_state;
    const tool_before = term.agent_hook_tool;
    const had_reply = term.agent_transcript.owned.reply().len > 0;
    var conversation_changed = false;
    var turn_ended = false;
    var base_opened = false;
    var batch_facts: BatchTurnFacts = .{};
    var batch_capture: turn_capture.Id = 0;
    for (events[0..batch.count]) |ev| {
        const applied = applyHookEvent(self, term, ev);
        if (applied.base) base_opened = true;
        // **턴이 끝나는 그 순간** 사실을 굳힌다(`BatchTurnFacts` 주석 — 배치 끝에서 읽으면 다음 턴의
        // 키·빈 제목이 실린다).
        // **턴이 끝나는 그 순간** 사실과 사본을 함께 굳힌다 — 배치 끝에서 하면 다음 턴의 것이 섞인다.
        if (applied.turn_end) {
            batch_facts.captureFrom(term);
            batch_capture = sealTurnCaptureNow(self, term);
        }
        if (applied.conversation) conversation_changed = true;
        if (applied.turn_end) turn_ended = true;
        // 활동 시각은 관측 모드와 같은 필드를 쓴다 — 사이드바의 «몇 분 전» 이 소스를 타지 않게.
        term.agent_last_output_ms = self.awakeMs();
        term.agent_last_output_wall_ns = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
    }
    if (batch.dropped != 0 or batch.recovered != 0) {
        // **개수만** 남긴다 — payload 에는 프롬프트 원문과 셸 명령이 들어 있다(계약 §7).
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agenthook).info(
            "hook batch: count={d} dropped={d} recovered={d} more={}",
            .{ batch.count, batch.dropped, batch.recovered, batch.more },
        );
    }
    // **열린 지 오래된 턴을 남긴다.** provider 는 턴 중단에 아무 이벤트도 보내지 않아(계약 «실측 신호
    // 기록») 그런 턴은 다음 프롬프트까지 «진행 중» 으로 남는다. 그 자체는 정상 동작이지만, 사후에
    // «얼마나 오래였나» 를 답할 근거가 없었다 — payload 에 시각이 없고 파일 mtime 은 로그 전체의 마지막
    // 쓰기다. 이 한 줄이 그 근거다. 시각을 주장할 수 있을 때만(=backlog 가 아니었을 때) 찍는다.
    if (diag_gate.maruDebugEnabled() and term.agent_hook_turn_opened_wall_ns != 0) {
        const now_ns: i96 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
        const open_ms = @divFloor(now_ns - term.agent_hook_turn_opened_wall_ns, std.time.ns_per_ms);
        if (open_ms >= turn_open_warn_ms) std.log.scoped(.agenthook).info(
            "hook turn still open: {d}ms (state={s})",
            .{ open_ms, @tagName(term.agent_hook_state) },
        );
    }
    // **backlog 는 상태만 세우고 알리지 않는다**(계약 §4). 그 이벤트는 창이 없던 시간의 것이라 «지금 막
    // 일어난 일» 이 아니다 — 재접속하자마자 몇 시간 전 턴의 «완료» 가 뜨면 그것은 거짓말이다. 배지·대화
    // 줄은 그대로 두어 **지금 상태**는 옳게 선다.
    if (term.agent_hook_backlog_catchup) {
        term.agent_hook_notice.clear();
        // **따라잡기가 끝나는 순간**(더 읽을 것이 없다)부터 다시 알린다. 그 뒤의 이벤트는 창이 열린 채
        // 일어난 «지금» 이다.
        if (!batch.more) term.agent_hook_backlog_catchup = false;
    }
    // **배치당 한 번만 찍는다** — 배치 안의 이벤트는 모두 같은 작업트리를 본다(위 `applyHookEvent`).
    //
    // **사유가 둘이어도 한 번이다.** 세션 base(턴 0)와 턴 끝이 한 배치에 함께 와도(첫 프롬프트가 곧바로
    // 끝난 경우) 작업트리가 같으므로 두 번 찍을 이유가 없다. 배치를 건너 겹치는 경우는 순수 층의
    // 「같은 tree 가 연달아 오면 넣지 않는다」가 흡수한다(계약 §3 이 정한 안전망).
    // **키는 `ev.turn_key` 가 아니라 진행 상태에서 읽는다.** 자식이 남은 턴은 마지막 `SubagentStop` 이
    // 전이를 만드는데 **그 이벤트의 `turn_key` 는 codex 에서 자식의 것**이다(계약 §2 실측). `advance` 는
    // lead 이벤트에서만 키를 채택하므로 `progress.turnKey()` 가 언제나 lead 의 현재 키다 — 알림 본문이
    // 「자식이 아니라 lead 의 것이어야 한다」로 이미 판정된 것과 같은 함정, 같은 답이다.
    if (turn_ended or base_opened) captureTurnSnapshot(self, term.surfaceId(), if (turn_ended) batch_facts.facts() else .{}, batch_capture);
    // **훅 자리를 채웠으면 배지까지 간다**(§1.6-⑴). 이 함수를 직접 부르는 경로(원격 드레인·제품 게이트)가
    // 있어 여기서 안 돌리면 그쪽 배지가 안 움직인다. 소비자가 화면을 읽은 뒤 한 번 더 부르지만 **C2 의
    // 셈은 `screen_seq` 가 지킨다** — 중재를 다시 부르는 것과 화면을 다시 보는 것은 다르다.
    arbitrateAgentState(self, term, displayed);
    if (displayed and term.agent_state != before) self.metal_dirty = true;
    // 세부가 바뀌면 그 줄의 **글자가** 달라진다 — 스피너 위상 진행이 다음 주기에 어차피 다시 그리지만,
    // 그때까지 옛 도구 이름이 남는다. 바뀐 tick 에 바로 반영한다.
    if (displayed and !std.mem.eql(u8, term.agent_hook_tool.text(), tool_before.text()))
        self.chrome_dirty = true;

    // **다 읽은 뒤에 회전한다**(계약 §4.2). 읽기 전에 돌리면 방금 온 이벤트를 회전본에 두고 새 파일부터
    // 읽게 되어, tail 재수집이 없으면 그대로 유실이다. `more` 가 남아 있으면(tick 상한에 걸렸다) 미룬다 —
    // 아직 읽을 것이 있는 파일을 갈아 끼울 이유가 없다.
    if (!batch.more and event.shouldRotate(st.size)) rotateAgentHookLog(self, term, log_path);
    // 응답 줄이 생기거나 사라지면 **행 높이가 바뀐다** — 재투영까지 해야 옛 높이가 남지 않는다
    // (관측 모드의 `pollAgentKinds` 가 같은 이유로 그렇게 한다).
    if (conversation_changed) {
        const has_reply = term.agent_transcript.owned.reply().len > 0;
        if (has_reply != had_reply) sidebar_ops.rebuildSidebar(self) catch {} else if (displayed) self.metal_dirty = true;
    }
}

/// 훅 이벤트 하나를 Term 에 적용한다 — 상태·마지막 대화·알림 예약이 **한 곳에서** 일어난다.
///
/// **두 경로가 이것을 공유해야 한다**(평시 tail 읽기와 회전본 건지기). 처음엔 각자 적었는데, 회전본 쪽이
/// 대화를 빠뜨려 **마지막 `Stop` 이 회전본에 들어가면 응답을 잃는** 결함이 생겼다(테스트가 잡았다).
/// 대화가 바뀌었으면 `true` 를 돌려준다 — 응답 줄이 생기거나 사라지면 행 높이가 달라져 재투영이 필요하다.
/// 이벤트 하나를 적용한 뒤 **호출자가 배치 단위로 처리해야 하는 사실들**.
const Applied = struct {
    /// 마지막 대화가 바뀌었다 — 응답 줄이 생기거나 사라지면 행 높이가 달라져 재투영이 필요하다.
    conversation: bool = false,
    /// 이 이벤트로 턴이 끝났다.
    turn_end: bool = false,
    /// 이 이벤트가 **세션 base(턴 0)** 를 연다(`opensSessionBase`).
    ///
    /// `turn_end` 와 **섞지 않는다** — 두 사실의 이름이 다르고, 알림 억제(`suppressesNotice`)가 이미 그
    /// 둘을 가르고 있다(`SessionStart` 는 배지를 바꾸되 알림은 안 낸다). 둘은 상호배타라 한 이벤트가
    /// 동시에 세우지 못하지만, **한 배치 안에서는 함께** 참이 될 수 있다(다른 이벤트로).
    base: bool = false,
};

/// 훅 payload 의 문자열을 **사람이 보는 형태로** 푼다(계약 §4).
///
/// 파서는 줄 버퍼를 빌려 쓰느라 JSON 이스케이프를 그대로 둔다(`agent_hook_event.Event` 주석 — «화면에
/// 올릴 때만 `decodeInto` 로 푼다»). 그 규칙을 지키는 자리가 없어서, claude 응답처럼 **여러 줄인 값이
/// 사이드바 대화 줄과 알림 본문에 `\n` 두 글자로** 그대로 나갔다(따옴표마다 역슬래시도 붙는다).
/// 훅에서 온 문자열이 표시 버퍼로 들어가는 길목은 전부 이 함수를 지난다.
///
/// 담을 수 있는 만큼만 담으므로 호출자가 **자기 상한 크기의 버퍼**를 준다.
///
/// ⚠️ **글자 경계는 여기서 물린다 — 받는 쪽에 맡기면 안 된다.** 받는 쪽의 `clampUtf8` 은 «상한을 **넘을**
/// 때만» 자르는데, 버퍼를 꽉 채우고 나온 이 슬라이스는 길이가 정확히 그 상한이라 **손을 안 댄다.**
/// 512 바이트면 한글 170자 + 2바이트라, 조금 긴 한글 답변 하나면 알림 배너 끝에 U+FFFD 가 붙는다
/// (적대적 검증 2차에서 실측으로 재현했다 — 「받는 쪽이 이미 한다」고 적어 둔 앞 판이 틀렸다).
fn hookDisplayText(buf: []u8, raw: []const u8) []const u8 {
    const decoded = maru.session.agent_hook_event.decodeInto(buf, raw);
    return decoded[0..maru.session.agent_transcript.trimToCharBoundary(decoded)];
}

/// 훅 문자열을 **사이드바 한 줄에 담을 모양**으로 만든다: 이스케이프를 풀고(위) 여러 줄을 눕힌다.
///
/// **푸는 것만으로는 모자란다.** 사이드바 대화 줄·진행 중 세부는 한 줄 텍스트 run 이라 진짜 개행이
/// 들어가면 글자가 뭉개진다 — 이스케이프를 그대로 두던 동안에는 `\n` 이 두 글자라 «못생겼지만 한 줄» 이었고,
/// 푸는 순간 그것이 제어문자가 된다. 관측 모드 파서는 저장 직전에 `flatten` 을 지나므로(같은 파일) 훅 모드도
/// 같은 자리를 지나야 **두 소스가 같은 모양**을 낸다(계약 §1).
///
/// 알림 본문은 이 함수를 쓰지 않는다 — OS 배너는 여러 줄을 제대로 보여주고, 인앱 히스토리는 자기 tail 에서
/// 눕힌다(`flattenForHistory`). 두 표면의 요구가 다르다.
fn hookConversationText(buf: []u8, scratch: []u8, raw: []const u8) []const u8 {
    return maru.session.agent_transcript.flatten(hookDisplayText(scratch, raw), buf);
}

/// 테스트 진입점. 제품은 배치 루프에서만 부르므로 **한 이벤트씩** 먹여 배선을 보려면 이 자리가 필요하다.
/// (로그 파일을 거치면 파서·커서·회전까지 함께 도는데, 그 셋은 각자 테스트가 있고 여기서 보려는 것은
/// **어떤 이벤트가 무엇을 트리거하는가** 뿐이다.)
pub fn testApplyHookEvent(self: *AppSession, term: *Term, ev: maru.session.agent_hook_event.Event) Applied {
    comptime std.debug.assert(builtin.is_test);
    return applyHookEvent(self, term, ev);
}

fn applyHookEvent(self: *AppSession, term: *Term, ev: maru.session.agent_hook_event.Event) Applied {
    const mode_mod = maru.session.agent_hook_mode;
    // **맨 앞이어야 한다.** 신원이 갈리면 `cache.reset()` 이 `owned` 를 비우는데, 이 함수 아래쪽이
    // `owned.setPrompt`/`setReply` 를 쓰고 `.done` 분기가 `owned.reply()` 를 읽는다 — 뒤에 두면 방금
    // 저장한 대화를 스스로 지운다.
    // **맨 앞이어야 한다.** 뒤로 옮기면 두 겹으로 깨지고, **먼저 걸리는 것은 ⑵ 다**(뮤테이션으로 확인 —
    // 함수 끝으로 옮기니 `Stop` 의 신원 채택이 통째로 사라졌다):
    //   ⑴ 신원이 갈리면 `cache.reset()` 이 `owned` 를 비우는데 대화 저장이 아래쪽이다.
    //   ⑵ 그 switch 는 `.stop`·`.user_prompt_submit` 에서 **early return** 한다 — 대화를 싣는 바로 그
    //      이벤트에서 채택이 **아예 안 돈다**.
    // 판정자: `app_session.zig` 「신원은 payload 가 정한다」 블록의 마지막 두 단언.
    adoptHookSessionIdentity(self, term, ev);
    adoptHookImageSource(self, term, ev);
    // **훅이 알려 준 작업 디렉터리를 담는다.** 원격 pane 에서 OSC 7 은 `precmd` 라 전면 TUI 가 붙어
    // 있는 동안 발화하지 못해 값이 접속 직전에서 멈춘다(ssh-integration.md §9.5) — 훅은 그 구간에도
    // **매 턴** 오므로 이 값이 그 자리를 메운다. 로컬은 커널 조회가 이미 정확해서 소비하지 않는다.
    if (ev.cwd.len > 0) term.agent_hook_cwd.set(ev.cwd, self.awakeMs());
    captureBeforeForEvent(self, term, ev);
    // **훅 자리만 읽고 훅 자리만 쓴다**(§1.6-⑴). 이 값은 `advance` 의 입력이자 출력이라 화면이 끼어들면
    // 상태 기계가 오염된다 — 배지에 나가는 값은 권위표를 통과한 `agent_state` 다.
    const prev_state = term.agent_hook_state;
    // **`advance` 를 쓴다**(`next` 가 아니라) — 서브에이전트를 세야 lead 의 `Stop` 을 완료로 단정하지
    // 않으면서도 마지막 자식이 끝날 때 배지가 풀린다(계약 §2).
    const turn_open_before = term.agent_hook_progress.turn_open;
    var key_before_buf: [@sizeOf(@FieldType(mode_mod.Progress, "turn_buf"))]u8 = undefined;
    const key_before_src = term.agent_hook_progress.turnKey();
    @memcpy(key_before_buf[0..key_before_src.len], key_before_src);
    const key_before = key_before_buf[0..key_before_src.len];
    term.agent_hook_state = mode_mod.advance(&term.agent_hook_progress, term.agent_hook_state, ev);

    // 턴이 **열리는 순간**을 찍는다(session_model 의 필드 주석 — provider payload 에 시각이 없다).
    //
    // **불리언 경계만 보면 안 된다.** 중단 뒤 새 프롬프트가 오면 `reset` 이 턴을 닫았다가 같은 이벤트가
    // 다시 여니 `true → true` 라 경계가 서지 않는다 — 하필 이 값이 가장 필요한 경우이고, 그때 옛 턴의
    // 시각이 남으면 **방금 시작한 턴이 «3 시간 열려 있다» 로** 보고된다. 그래서 **턴 정체**(turn key)가
    // 바뀐 것도 새 턴으로 본다.
    //
    // backlog 따라잡기 중에는 찍지 않는다: 창이 없던 시간의 이벤트라 지금을 찍으면 몇 시간 전 턴이
    // «방금 열렸다» 가 된다. 그 구간의 턴은 시각을 주장하지 않고 0 으로 남는다.
    const open_now = term.agent_hook_progress.turn_open;
    const key_now = term.agent_hook_progress.turnKey();
    const turn_changed = !std.mem.eql(u8, key_before, key_now);
    // **권위표의 C2 가 언제 셈을 버릴지의 유일한 입력이다**(§1.6-⑵-a). 안 올리면 C2 가 한 번 성공한 뒤
    // 카운터가 임계에 남아, 새 턴의 첫 판정에서 화면이 아직 이전 idle chrome 을 들고 있는 동안 **확인
    // 절차 없이 완료**가 된다(적대적 검증 R8 에서 재현한 그 버그다). 턴 정체가 바뀌면 새 턴이다.
    if (turn_changed) term.agent_hook_turn_seq +%= 1;
    if (open_now != turn_open_before or (open_now and turn_changed)) {
        term.agent_hook_turn_opened_wall_ns = if (open_now and !term.agent_hook_backlog_catchup)
            @intCast(std.Io.Clock.real.now(self.io).nanoseconds)
        else
            0;
    }

    // **진행 중 세부**(계약 §2). 훅 모드는 화면·프로세스 관측을 끄므로(§1.1) 이 자리를 안 채우면
    // 배지가 «진행중» 한 마디만 말한다 — 훅을 켠 사용자가 정보를 잃는다(§8).
    var label_buf: [mode_mod.ToolLabel.max_text]u8 = undefined;
    var label_scratch: [mode_mod.ToolLabel.max_text]u8 = undefined;
    switch (mode_mod.labelFor(ev)) {
        .keep => {},
        .clear => term.agent_hook_tool.clear(),
        .set => |body| term.agent_hook_tool.set(hookConversationText(&label_buf, &label_scratch, body)),
    }

    // **턴이 끝났다는 사실만 돌려준다**(계약 §1 표 — 훅 모드의 턴 경계는 `UserPromptSubmit`/`Stop`).
    // 관측 모드는 `pollAgentState` 가 같은 일을 하는데 훅 모드는 그 함수를 **아예 부르지 않으므로**
    // (§1.3 배타) 이것을 안 하면 «에이전트가 방금 바꾼 것» 이 통째로 사라진다 — 게이트를 켠 것만으로
    // 조용히 잃는 기능이 된다. 판정은 관측 모드와 **같은 술어**(`isTurnEnd`)를 쓴다: 두 모드가 서로
    // 다른 «턴 끝» 을 갖는 순간 링의 의미가 갈린다.
    //
    // **여기서 찍지 않는 이유**: 한 tick 의 배치에 턴 끝이 여럿 들어올 수 있고(회전본을 건질 때가
    // 특히 그렇다), 그때마다 찍으면 `git write-tree` 가 그 수만큼 **동기로** 돈다. 배치 안의 이벤트는
    // 모두 **같은 작업트리**를 보므로 여러 번 찍어도 나오는 tree 가 같다 — 비용만 늘고 얻는 것이 없다.
    // 호출자가 배치 끝에서 한 번 찍는다.
    const turn_end = maru.session.turn_snapshot.isTurnEnd(turnStateOf(prev_state), turnStateOf(term.agent_hook_state));
    // **세션 base(턴 0)** — 타임라인은 스냅샷 **두 개**라야 완료 턴 하나를 낸다. base 가 없으면 그 세션의
    // 첫 턴이 화면에 아예 안 뜬다(두 번째 턴이 끝나야 보인다). `previous == .running` 인 `SessionStart`
    // 는 위 `turn_end` 가 이미 잡으므로 여기서 빠진다 — 둘은 상호배타다(`opensSessionBase` 주석의 표).
    const base = mode_mod.opensSessionBase(prev_state, ev);

    // **알림은 전이에 붙는다**(계약 §6). 같은 턴에서 `Stop` 이 여러 번 와도 상태가 이미 `idle` 이라
    // 전이가 없어 두 번 울리지 않는다 — 「턴 단위 1회」를 따로 세지 않아도 성립한다.
    // **세션이 (재)시작되며 만든 전이는 알리지 않는다**(§6). `resume`·컨텍스트 압축은 턴 중간에도
    // `SessionStart` 를 만드는데, 그것이 상태를 «대기» 로 놓는 것은 «턴이 끝났다» 가 아니라 «다시
    // 시작했다» 다. 배지는 그대로 바뀌고 알림만 가려진다.
    // **알림은 훅 전이에만 붙는다**(§1.1.1). C1·C2 가 만든 전이에 걸면 codex 오류 턴에 「완료」가
    // 나간다 — 화면은 «끝났다» 는 알아도 «어떻게 끝났는지» 는 모른다(계약 §2).
    const notice = if (mode_mod.suppressesNotice(ev)) mode_mod.Notice.none else mode_mod.noticeOn(prev_state, term.agent_hook_state);
    switch (notice) {
        .none => {},
        // 턴 끝은 같은 전이지만 **오류로 끝난 턴을 «완료» 라 부르지 않는다**(계약 §2). 그 사실은
        // 진행 상태가 들고 있다 — 자식이 남았으면 끝 전이가 `StopFailure` 가 아니라 마지막
        // `SubagentStop` 에서 일어나기 때문이다.
        //
        // **오류 사유를 버리지 않는다.** `StopFailure` 도 `last_assistant_message` 에 사유를 싣고 온다
        // (실측 — 로그인 안 된 세션에서 "Not logged in · Please run /login" 을 받았다). 그 자리를 비우면
        // 알림이 «오류로 끝났습니다» 한 마디만 하고, 사용자는 무엇이 잘못됐는지 다시 찾아야 한다.
        // 자식 뒤에 끝난 경우엔 마지막 `SubagentStop` 이 전이를 만들어 그 이벤트에 사유가 없다 — 그때는
        // 비어 있고, 그것은 원래 사유가 없는 것이지 버린 것이 아니다.
        //
        // **본문은 lead 의 것이어야 한다.** 자식이 남아 lead 를 붙잡았다면 턴 끝 전이는 마지막
        // `SubagentStop` 에서 일어나는데, 그 이벤트의 `last_assistant_message` 는 **자식의 응답**이다
        // (실측에서 `"from-child"` 를 받았다). 그것을 그대로 실으면 «완료: from-child» 가 나가 lead 가
        // 무슨 말을 했는지 대신 자식이 무슨 말을 했는지를 알린다. 자식 이벤트가 만든 전이에서는
        // 그 Term 에 이미 쌓아 둔 **lead 의 마지막 응답**을 쓴다.
        .done => {
            // 이벤트에서 바로 꺼낸 문자열만 푼다 — 쌓아 둔 lead 응답은 저장할 때 이미 풀었다.
            var body_buf: [mode_mod.PendingNotice.max_text]u8 = undefined;
            const body = if (ev.agent_id.len == 0) hookDisplayText(&body_buf, ev.text) else term.agent_transcript.owned.reply();
            if (term.agent_hook_progress.takeFailed())
                term.agent_hook_notice.set(.failed, body, self.awakeMs())
            else
                term.agent_hook_notice.set(.done, body, self.awakeMs());
        },
        // `noticeOn` 은 전이만 보므로 지금은 이 값을 내지 않는다(위 `.done` 에서 갈린다). 그래도
        // `unreachable` 을 두지 않는다 — 뒷날 그 함수가 이벤트를 보게 되면 그 순간 제품이 죽는다.
        .failed => term.agent_hook_notice.set(.failed, "", self.awakeMs()),
        .attention => {
            // 무엇을 승인하는지 — 사람이 읽는 설명이 있으면 그것, 없으면 도구 이름. **명령 원문은
            // 싣지 않는다**(계약 §7: 길고 민감하다).
            //
            // **두 소스가 서로 다른 자리를 싣는다**(계약 §6). `PermissionRequest` 는 `tool_name`·
            // `tool_input` 을, `Notification` 은 `message` 를 준다 — 도구 이름 규칙만 쓰면 후자에서
            // **본문이 빈 문자열**이 되어 «떴는데 아무 말도 안 하는» 알림이 된다.
            const raw = if (ev.tool_description.len > 0)
                ev.tool_description
            else if (ev.tool_name.len > 0)
                ev.tool_name
            else
                ev.notice_text;
            var body_buf: [mode_mod.PendingNotice.max_text]u8 = undefined;
            term.agent_hook_notice.set(.attention, hookDisplayText(&body_buf, raw), self.awakeMs());
        },
    }

    // **마지막 대화도 훅에서 온다**(계약 §4b). 그 Term 은 transcript 파일을 읽지 않으므로 신원 해소·
    // 256 KiB tail 파싱·폴링이 통째로 빠진다.
    var text_buf: [maru.session.agent_transcript.max_text_bytes]u8 = undefined;
    var text_scratch: [maru.session.agent_transcript.max_text_bytes]u8 = undefined;
    switch (ev.kind) {
        .user_prompt_submit => if (ev.text.len > 0) {
            term.agent_transcript.owned.setPrompt(hookConversationText(&text_buf, &text_scratch, ev.text));
            // 새 프롬프트가 오면 이전 응답은 지난 턴 것이다 — 남겨 두면 «질문은 새것, 답은 옛것» 이 붙는다.
            term.agent_transcript.owned.setReply("");
            return .{ .conversation = true, .turn_end = turn_end, .base = base };
        },
        // **오류 사유도 마지막 응답이다.** provider 가 `StopFailure` 의 `last_assistant_message` 로
        // 사유를 준다(실측). 저장하지 않으면 사이드바 대화 줄이 오류 턴만 비고, 자식이 남아 알림이
        // 늦게 나가는 경우엔 그 본문마저 잃는다(위 `.done` 분기가 이 값을 쓴다).
        .stop, .stop_failure => if (ev.text.len > 0) {
            term.agent_transcript.owned.setReply(hookConversationText(&text_buf, &text_scratch, ev.text));
            return .{ .conversation = true, .turn_end = turn_end, .base = base };
        },
        else => {},
    }
    return .{ .turn_end = turn_end, .base = base };
}

/// 종료할 때 **이 세션이 소유한 pane 의** 이벤트 로그를 지운다(계약 §4.2).
///
/// **시작 시 정리와 범위가 다르다.** 그쪽은 디렉터리를 통째로 훑는다(그 시점엔 우리 프로세스가 하나뿐이다).
/// 종료는 다른 창이 아직 쓰는 중일 수 있어 **내 Term 만** 지운다 — 남의 pane 로그를 지우면 그 창의 배지가
/// 그 자리에서 멈춘다.
///
/// ⚠️ **강제 종료로는 이 경로가 안 돈다.** 그래서 다음 시작의 정리가 여전히 안전망이다 — 둘 중 하나만 두면
/// «정상 종료 후 다음 실행까지» 또는 «강제 종료 뒤 영영» 남는다.
pub fn cleanupOwnedAgentHookLogs(self: *AppSession) void {
    if (!is_macos) return;
    const event = maru.session.agent_hook_event;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const dir = agentHookInstanceDir(a) orelse return;
    // **인스턴스 칸을 통째로 거둔다.** 예전에는 살아 있는 Term 의 `surface_id` 이름만 지웠는데, 그러면
    // 이미 닫힌 Term 의 파일과 회전 흔적이 남았다. 이 칸은 **이 프로세스만** 쓰므로(이름이 pid) 통째로
    // 지우는 것이 안전하고, 계약 §4.2 의 «소비 즉시 비우는 큐» 와도 맞는다.
    _ = event; // 회전 접미도 아래 통짜 삭제에 함께 걸린다.
    var handle = openAgentDirAbsolute(self, dir, .{ .iterate = true }) orelse return;
    defer handle.close(self.io);
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(self.io) catch return) |entry| {
        if (entry.kind != .file) continue;
        doomed.append(a, a.dupe(u8, entry.name) catch return) catch return;
    }
    for (doomed.items) |name| handle.deleteFile(self.io, name) catch {};
    std.Io.Dir.deleteDirAbsolute(self.io, dir) catch {};
}

/// 이벤트 로그를 회전한다(계약 §4.2). **순서가 계약이다** — 네 단계 중 셋째를 빼면 회전할 때마다 마지막
/// 몇 이벤트가 조용히 사라진다.
///
/// 1. `rename` — 이 순간 훅이 열어 둔 fd 는 **옛 inode 에 계속 쓴다.**
/// 2. 커서를 되돌린다(새 파일은 아직 없거나 비어 있다).
/// 3. **회전본을 한 번 더 읽어 tail 을 건진다.** ⑴에서 열린 창을 여기서 메운다.
/// 4. 건진 뒤 회전본을 지운다.
///
/// best-effort 다. 어느 단계가 실패해도 다음 tick 이 같은 자리에서 다시 시도한다(회전본이 남아 있으면
/// 시작 시 정리가 치운다 — 이름이 원본 접두를 유지하는 이유다).
fn rotateAgentHookLog(self: *AppSession, term: *Term, log_path: []const u8) void {
    const event = maru.session.agent_hook_event;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const rotated = std.fmt.allocPrint(a, "{s}{s}", .{ log_path, event.rotated_suffix }) catch return;
    // 옛 회전본이 남아 있으면(직전 회전이 도중에 죽었다) 먼저 치운다 — rename 이 그것을 덮어쓰면 아직
    // 건지지 않은 tail 을 잃는다.
    if (readFileState(self.io, a, rotated) != .absent) {
        drainRotatedAgentHookLog(self, term, rotated);
    }
    std.Io.Dir.renameAbsolute(log_path, rotated, self.io) catch return;

    // **커서를 여기서 건드리지 않는다.** 다음 poll 의 `resetIfRotated` 가 잡는다 — 그것은 inode 와 크기를
    // **둘 다** 보므로(`same_file and file_size >= offset` 일 때만 유지) 새 파일이 같은 inode 를
    // 재사용하더라도 크기가 작아 리셋된다. 여기서 한 번 더 지우면 같은 일을 두 곳에서 하게 되고, 커서에
    // 필드가 늘 때 한쪽만 고쳐지는 자리가 생긴다. **우리가 아닌 쪽이 갈아 끼운 경우까지 잡아야 하므로
    // `resetIfRotated` 는 어차피 없앨 수 없다** — 그래서 그쪽을 유일한 자리로 둔다.
    //
    // ⚠️ 이 마지막 건지기가 막는 것은 **동시 기록 경합**이다 — 우리가 마지막으로 읽은 뒤 `rename` 전까지
    // 훅이 덧쓴 줄. 단일 프로세스 테스트로는 그 창을 만들 수 없어 자동 검증이 없다(`drainRotated…` 함수
    // 자체는 «회전 도중 죽어 남은 회전본» 테스트가 덮는다).
    drainRotatedAgentHookLog(self, term, rotated);
}

/// 회전본의 **남은 tail 을 건지고 지운다**(위 절차 ③④). 커서는 새 파일 것이라 여기서 쓰지 않는다 —
/// 회전본은 통째로 한 번 읽고 끝이다.
/// 테스트가 «회전 도중 죽어 남은 회전본» 상황을 만들 수 있게 연 seam. 그 상황은 단일 프로세스에서
/// 자연히 생기지 않는다(회전과 건지기가 한 호출 안에서 끝난다).
pub fn drainRotatedAgentHookLogForTest(self: *AppSession, term: *Term, rotated_path: []const u8) void {
    drainRotatedAgentHookLog(self, term, rotated_path);
}

fn drainRotatedAgentHookLog(self: *AppSession, term: *Term, rotated_path: []const u8) void {
    const event = maru.session.agent_hook_event;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    defer std.Io.Dir.cwd().deleteFile(self.io, rotated_path) catch {};

    const text = switch (readFileState(self.io, a, rotated_path)) {
        .present => |body| body,
        else => return,
    };
    // **커서를 새로 만들어 통째로 훑는다.** tick 상한은 여기 적용하지 않는다 — 회전은 드물고, 남은 것을
    // 다음 기회로 미루면 그 파일을 지울 수 없다.
    var cursor: event.Cursor = .{};
    var events: [event.max_events_per_tick]event.Event = undefined;
    // **회전본은 backlog 와 같은 성질이다** — 이미 지나간 이벤트다. 그 `PreToolUse` 의 도구는 **이미
    // 끝났으므로** 지금 그 파일을 읽으면 «끝난 턴의 before» 자리에 **현재 내용**(= 그 편집의 결과)이
    // 들어간다. 그러면 그 턴의 diff 가 자기 편집을 통째로 숨긴다 — 없는 것보다 나쁘다.
    //
    // 알림 억제와 **같은 플래그**를 쓴다(사유가 같기 때문이다). 드레인이 끝나면 되돌린다 — 이 함수는
    // tick 안에서 동기로 돌므로 그 사이 다른 경로가 이 플래그를 볼 일이 없다.
    const restore_catchup = term.agent_hook_backlog_catchup;
    term.agent_hook_backlog_catchup = true;
    defer term.agent_hook_backlog_catchup = restore_catchup;
    while (true) {
        const batch = cursor.take(text, &events);
        var rotated_turn_end = false;
        var rotated_base = false;
        var rotated_facts: BatchTurnFacts = .{};
        // ⚠️ **회전본에서는 봉인하지 않는다 — 늘 0이다.** 그 이벤트의 도구는 이미 오래전에 끝나 사본이
        // 없고(위에서 캡처를 막는다), 그런데도 봉인하면 **지금 진행 중인 턴의 열린 버킷**을 굳혀 버린다 —
        // 회전본에 `Stop` 이 들어 있으면 진행 중 턴의 사본이 **엉뚱한 턴으로 도둑맞고** 진짜 턴 끝에는
        // 빈 버킷만 남는다. 스냅샷(tree)은 회전본에도 찍는 것이 맞지만(그 세션의 첫 턴을 잃지 않으려고)
        // 사본은 그렇지 않다 — 없는 것을 지어내는 쪽이 나쁘다.
        const rotated_capture: turn_capture.Id = 0;
        for (events[0..batch.count]) |ev| {
            const applied = applyHookEvent(self, term, ev);
            if (applied.turn_end) {
                rotated_turn_end = true;
                rotated_facts.captureFrom(term); // 회전본도 같은 규율이다
            }
            if (applied.base) rotated_base = true;
        }
        // 회전본에도 **같은 규율**을 건다 — 여기만 빠지면 회전된 로그에 든 `SessionStart` 의 base 를 잃고,
        // 그 세션의 첫 턴이 영영 안 뜬다.
        if (rotated_turn_end or rotated_base) captureTurnSnapshot(self, term.surfaceId(), if (rotated_turn_end) rotated_facts.facts() else .{}, rotated_capture);
        // **건진 이벤트도 배지까지 간다**(§1.6-⑴). `applyHookEvent` 는 훅 자리만 쓰므로 여기서 권위표를
        // 안 돌리면 회전본으로 끝난 턴의 배지가 «진행 중» 에 남는다.
        arbitrateAgentState(self, term, true);
        if (!batch.more or batch.advanced == 0) break; // `advanced == 0` = 더 나아가지 못한다(무한 루프 방지)
    }
}

/// 꺼내 간 훅 알림. 본문은 **Term 소유 고정 버퍼를 빌린 것**이라 호출자가 바로 dupe 해야 한다
/// (`emitNotification` 이 그렇게 한다).
pub const HookNotice = struct {
    kind: maru.session.agent_hook_mode.Notice,
    body: []const u8,
};

/// 예약된 훅 알림을 지금 띄울 수 있는가(계약 §6). 완료 알림은 바로, 주의 알림은 디바운스 뒤에 —
/// 그 사이 상태가 `blocked` 를 떠났으면(자동 승인으로 해소) **버린다**.
///
/// 꺼내 가면 슬롯을 비운다. 비우지 않으면 다음 tick 마다 같은 것을 다시 본다.
pub fn takeAgentHookNotice(self: *AppSession, term: *Term) ?HookNotice {
    const mode_mod = maru.session.agent_hook_mode;
    const kind = term.agent_hook_notice.kind;
    switch (kind) {
        .none => return null,
        // 완료도 오류도 **바로** 띄운다 — 디바운스는 «곧 저절로 해소될 수 있는» 주의 알림만의 규율이다.
        .done, .failed => {},
        // **여기는 훅 자리가 아니라 «지금 배지» 다**(§1.1.1 — 적대적 검증이 잡았다). 알림을 **만드는** 것은
        // 훅 전이지만, 만들어 둔 알림을 **띄울지**는 지금도 유효한가의 문제다. 훅에는 승인 해제 이벤트가
        // 없어 `agent_hook_state` 는 영영 `blocked` 이므로, 그것으로 판단하면 C1 이 화면으로 풀어 준 뒤에도
        // 디바운스가 끝나며 「승인이 필요합니다」가 나간다 — 사용자가 이미 승인한 뒤에.
        .attention => switch (mode_mod.attentionDebounce(term.agent_state, term.agent_hook_notice.since_ms, self.awakeMs())) {
            .wait => return null,
            .drop => {
                term.agent_hook_notice.clear();
                return null;
            },
            .emit => {},
        },
    }
    const body = term.agent_hook_notice.text();
    term.agent_hook_notice.clear();
    return .{ .kind = kind, .body = body };
}

/// 그 pane 의 이벤트 로그 경로(`<로그 디렉터리>/<인스턴스>/<pane>.ndjson`). 훅 커맨드가 적는 그 이름이다.
///
/// **소유자에 따라 두 이름이 있다**(계약 §4): GUI 가 띄운 자식은 `<pid>/<surface_id>`, host 가 띄운 자식은
/// `host_<hex host_id>/<hex runtime_id>`. 만드는 곳은 계약 모듈 하나이고 여기서는 어느 쪽인지만 고른다.
///
/// `pub` 인 이유는 **테스트가 이 함수를 직접 물어야 하기 때문**이다. 「훅이 받는 이름 = 여기서 만드는 이름」은
/// 두 프로세스에 걸친 계약이라, 테스트가 경로를 스스로 조립하면 그 이음매를 한 번도 안 건넌다(그렇게 쓰인
/// 기존 테스트는 두 이름이 갈려도 초록이다 — 실제 증상은 «훅은 도는데 이벤트가 0» 이다).
/// 이 Term 이 원격에 실어 보낸 pane nonce([계획](../../../../docs/plans/remote-agent-state.md) RA2).
///
/// **`agentHookLogPath` 와 같은 두 이름을 쓴다** — GUI 가 띄운 자식은 `<pid>`/`<surface_id>`, host 가 띄운
/// 자식은 `host_<hex>`/`<hex runtime_id>`. 그 둘이 곧 `MARU_HOOK_INSTANCE`/`MARU_HOOK_PANE` 이고,
/// `maru ssh` 는 **그 pane 의 셸 env 에서 같은 두 값을 읽어** `LC_MARU_PANE` 을 만든다. 두 곳이 같은
/// 조립기(`formatRemotePaneNonce`)를 쓰는 것이 이 축의 전부다 — 갈리면 그 Term 은 자기 이벤트를 영영 못
/// 받고 증상은 «배지가 안 선다» 뿐이라 어느 쪽이 틀렸는지 화면에 안 나온다(계약 §4 가 로컬에서 겪은 사고다).
///
/// observer 창은 여기서도 `null` 이다 — 같은 이유로 한 runtime 의 이벤트를 두 창이 나눠 먹으면 안 된다.
pub fn remotePaneNonceFor(term: *Term, buf: *[maru.session.agent_hook_command.remote_pane_nonce_max]u8) ?[]const u8 {
    const hook_command = maru.session.agent_hook_command;
    var inst_buf: [hook_command.instance_token_max]u8 = undefined;
    var pane_buf: [hook_command.pane_token_max]u8 = undefined;
    if (hostOwnedHookIdentity(term)) |owned| {
        if (owned.observer) return null;
        return hook_command.formatRemotePaneNonce(
            buf,
            hook_command.formatHostInstance(&inst_buf, owned.host_id),
            hook_command.formatRuntimePane(&pane_buf, owned.runtime_id),
        );
    }
    return hook_command.formatRemotePaneNonce(
        buf,
        hookInstanceToken(&inst_buf),
        hook_command.formatSurfacePane(&pane_buf, term.surfaceId()),
    );
}

pub fn agentHookLogPath(a: std.mem.Allocator, term: *Term) ?[]const u8 {
    const hook_command = maru.session.agent_hook_command;
    if (hostOwnedHookIdentity(term)) |owned| {
        // **observer 는 읽지 않는다**(계약 §4). 이 로그는 «소비 즉시 비우는 큐» 라, 한 runtime 에 붙은 두
        // 창이 같은 파일을 tail 하면 **서로가 필요한 이벤트를 먹고** 회전·삭제는 먼저 한 쪽이 이긴다.
        // 두 번째 controller 는 host 가 조용히 observer 로 강등하므로(persistent-session-host.md §9) 그
        // 창은 여기서 null 을 받아 **관측 모드로 산다** — §1 «한 Term 의 소스는 정확히 하나» 와 같은 결이다.
        // ⚠️ 이 가지는 이 저장소의 자동 게이트로 못 밟는다 — 한 runtime 에 **두 client** 를 붙여야 하고
        // (그래야 host 가 두 번째를 observer 로 강등한다) 그것은 실 fork host + AppSession 둘을 엮는
        // OS-E2E 다. 뮤테이션에서 이 줄만 지워도 초록인 것이 그 증거다.
        if (owned.observer) return null;
        const base = sessionCacheBase(a) orelse return null;
        var inst_buf: [hook_command.instance_token_max]u8 = undefined;
        const inst = hook_command.formatHostInstance(&inst_buf, owned.host_id);
        var pane_buf: [hook_command.pane_token_max]u8 = undefined;
        const pane = hook_command.formatRuntimePane(&pane_buf, owned.runtime_id);
        return std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}.ndjson", .{
            base,
            hook_command.log_dir_rel,
            inst,
            pane,
        }) catch null;
    }
    // **인스턴스 칸을 지난다** — 훅이 쓰는 이름과 같아야 한다(계약 §4). 이 둘이 갈리면 그 Term 은 자기
    // 이벤트를 못 읽고, 같은 숫자를 가진 **다른 인스턴스**의 이벤트를 읽는다.
    const dir = agentHookInstanceDir(a) orelse return null;
    var pane_buf: [hook_command.pane_token_max]u8 = undefined;
    const pane = hook_command.formatSurfacePane(&pane_buf, term.surfaceId());
    return std.fmt.allocPrint(a, "{s}/{s}.ndjson", .{ dir, pane }) catch null;
}

/// host 가 소유하는 Term 인가 — 그렇다면 그 칸을 짓는 두 값과 «우리가 controller 인가» 를 함께 돌려준다.
///
/// 셋이 한 번에 나오는 이유: 셋 다 같은 원격 backend 조회에서 나오고, 하나라도 없으면 그 Term 의 훅 경로를
/// 지을 수 없다(그러면 GUI 소유 규칙으로 떨어지는 것이 아니라 **훅이 없는 것**이다 — 이 Term 의 자식은
/// host 가 띄웠으므로 GUI 칸에는 애초에 아무것도 안 쓴다).
fn hostOwnedHookIdentity(term: *Term) ?struct { host_id: u128, runtime_id: u128, observer: bool } {
    if (!is_macos) return null;
    // ⚠️ **실효 가드는 아래 registry 조회다** — handle 은 앱 전역 유일이라 원격이 아닌 Term 은 그 표에
    // 없어 어차피 null 이 된다. 이 줄은 의도를 적는 자리이고, 그래서 이 줄만 지워도 테스트는 초록이다
    // (뮤테이션으로 확인). 그래도 남기는 이유는 «원격이 아니면 애초에 묻지 않는다» 가 이 함수의 계약이라서다.
    if (term.surface.remote == null) return null;
    const remote = if (app_session_mod.app_remote_backend) |*backend| backend else return null;
    const rid_hex = remote.runtimeIdFor(term.rt.handle) orelse return null;
    const host_id = remote.runtimeHostId(term.rt.handle) orelse return null;
    const runtime_id = std.fmt.parseInt(u128, &rid_hex, 16) catch return null;
    return .{
        .host_id = host_id,
        .runtime_id = runtime_id,
        .observer = remote.attachedAsObserver(term.rt.handle),
    };
}

/// 어느 Term이든 에이전트가 돌고 있는가 — 활동 시각 재렌더 게이트. 전-Term 순회지만 필드 읽기뿐이라 20초에
/// 한 번 도는 비용으로 무시할 만하다.
pub fn anyAgentPresent(self: *AppSession) bool {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.agent_kind != .none) return true;
            }
        }
    }
    return false;
}

/// foreground process와 터미널이 이미 소유한 bounded 화면 tail·OSC title/progress·최근 PTY 출력을 결합한다.
/// raw 화면/제목은 로그에 남기지 않고, 순수 observer의 rule id와 최종 상태만 진단한다.
/// 테스트 전용 호출 카운터. **배타 규칙(계약 §1)은 «둘 다 돌지 않는다» 라 호출 여부를 세지 않으면
/// 검증할 수 없다** — 두 소스가 같은 값을 낼 때는 상태만 봐서는 구분되지 않는다(뮤테이션이 그것을
/// 드러냈다: 분기를 지워 둘 다 돌게 해도 테스트가 통과했다). 제품 빌드에서는 `comptime` 으로 사라진다.
pub var test_observe_calls: usize = 0;
pub var test_hook_calls: usize = 0;

pub fn pollAgentState(self: *AppSession, term: *Term, displayed: bool) void {
    if (builtin.is_test) test_observe_calls += 1;
    // **다시 그릴지는 이 함수가 정하지 않는다**(§1.6-⑴). 화면 상태가 바뀌어도 권위표가 배지를 그대로
    // 두는 경우가 있어(D1·D2) 여기서 dirty 를 세우면 아무것도 안 바뀐 프레임을 다시 그린다. 판단은
    // 아래 `arbitrateAgentState` 가 **결과 전이**를 보고 한다.
    const agent: maru.session.agent_observer.Agent = switch (term.agent_kind) {
        .none => return,
        .claude => .claude,
        .codex => .codex,
    };
    const observation = &term.rt.observation;
    if (observation.availability != .current) return;
    const generation = observation.observer_generation;
    const now_ms = self.awakeMs();
    const activity_age_ms = now_ms -| term.agent_last_output_ms;
    const output_active = term.agent_last_output_ms != 0 and activity_age_ms <= agent_activity_window_ms;
    // **판단은 순수 층이 한다**(`ScanSkip` — 그 doc comment 에 왜 거기 있는지 적었다). 이 if 문 안에
    // 두었을 때 C2 가 조용히 굶었고, 판정자를 세울 자리가 없어 그대로 커밋됐다.
    const has_hook = agentHookMode(self, term) == .hook;
    if ((maru.session.agent_state_arbiter.ScanSkip{
        .hook = if (has_hook) term.agent_hook_state else null,
        .hook_child_count = @intCast(term.agent_hook_progress.childCount()),
        .screen = term.agent_screen_state,
        .idle_confirmations = term.agent_arbiter.idle_confirmations,
        .generation_same = generation == term.agent_screen_generation,
        .output_active = output_active,
        .expiry_probe = term.agent_stabilizer.needsExpiryProbe(),
    }).canSkip()) return;
    const screen = self.backendFor(term).dumpRecentText(term.rt.handle, self.allocator, agent_screen_tail_rows, agent_screen_tail_bytes) catch null;
    defer if (screen) |owned| self.allocator.free(owned);

    term.agent_screen_generation = generation;
    const detection = maru.session.agent_observer.detect(agent, .{
        .screen = screen orelse "",
        .osc_title = observation.window_title.items,
        .osc_progress = observation.agent_progress.items,
        .output_active = output_active,
    });
    observation.clearAgentProgress(self.allocator);
    // **화면 자리만 쓴다**(§1.6-⑴). 배지로 나가는 값은 권위표를 통과한 뒤 `arbitrateAgentState` 가 정한다.
    const previous = term.agent_screen_state;
    const current = term.agent_stabilizer.observe(detection, now_ms);
    term.agent_screen_state = current;
    term.agent_screen_seq +%= 1; // 새 관측 하나 — C2 가 세는 단위다
    term.agent_screen_visible_blocker = detection.visible_blocker;
    term.agent_screen_visible_idle = detection.visible_idle;
    term.agent_screen_idle_is_chrome = detection.idle_is_chrome;
    term.agent_screen_origin = maru.session.agent_state_arbiter.originOfRule(detection.rule_id);
    term.agent_screen_rule = detection.rule_id; // 진단 전용(§1.7) — 어느 화면 규칙이 상태를 냈는지
    // 턴이 끝난 순간의 작업트리를 굳힌다(§6.1) — "에이전트가 방금 바꾼 것"의 기준이 이 tree다.
    //
    // ⚠️ **훅이 있는 Term 에서는 여기서 찍지 않는다**(§1.3). 예전에는 이 함수가 훅 Term 에서 아예 안
    // 불려 배타가 구조로 보장됐는데, §1.1 이 화면 입력을 켜면서 그 전제가 사라졌다. 두 소스가 같은 턴
    // 끝에 각자 `git write-tree` 를 동기로 돌리면 「같은 tree 면 스킵」 규칙이 그 사이 변경을 못 흡수한다.
    if (agentHookMode(self, term) != .hook and
        maru.session.turn_snapshot.isTurnEnd(turnStateOf(previous), turnStateOf(current)))
    {
        // **화면 관측에는 턴 키가 없다** — 그 축은 훅 payload 만 가진 것이라(계약 §3.1) 화면으로는
        // 알 길이 없다. 빈 키는 「모른다」이고, AT3 는 그런 항목에 provider 기록을 붙이지 않는다.
        // 훅이 없으니 사본도 없다(계약 §6) — 0을 넘긴다.
        captureTurnSnapshot(self, term.surfaceId(), .{}, 0);
    }
    if (current != previous) {
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info(
            "agent previous={s} state={s} rule={s} idle={} blocker={} running={} activity_age_ms={d}",
            .{ @tagName(previous), @tagName(current), detection.rule_id, detection.visible_idle, detection.visible_blocker, detection.visible_running, activity_age_ms },
        );
    }
    // **화면 자리를 채웠으면 배지까지 간다**(§1.6-⑴-a). 이 함수를 직접 부르는 경로가 있어 여기서 안
    // 돌리면 그쪽 배지가 안 움직인다. 소비자가 한 번 더 부르지만 **C2 의 셈은 `screen_seq` 가 지킨다**.
    arbitrateAgentState(self, term, displayed);
}

/// 훅과 화면 두 자리를 §1.1 권위표에 넣어 배지로 나갈 값을 정한다.
///
/// **여기가 `agent_state` 를 쓰는 유일한 자리다.** 두 소스가 각자 그 필드를 쓰던 것이 §1.6-⑴ 이 지적한
/// 덮어쓰기였고, 그것을 없애는 것이 이 함수의 존재 이유다.
fn arbitrateAgentState(self: *AppSession, term: *Term, displayed: bool) void {
    const before = term.agent_state;
    const has_hook = agentHookMode(self, term) == .hook;
    const verdict = term.agent_arbiter.arbitrate(.{
        .hook = if (has_hook) term.agent_hook_state else null,
        .hook_child_count = @intCast(term.agent_hook_progress.childCount()),
        .screen = term.agent_screen_state,
        .screen_visible_blocker = term.agent_screen_visible_blocker,
        .screen_visible_idle = term.agent_screen_visible_idle,
        .screen_idle_is_chrome = term.agent_screen_idle_is_chrome,
        .screen_origin = term.agent_screen_origin,
        // **우리에게는 이 축이 `agent_kind` 다**(§1.1 C3 주석). 에이전트가 끝나면 `pollAgentKinds` 가
        // kind 를 `.none` 으로 내리고, 그 전이가 세 상태 자리와 중재기를 통째로 리셋한다 — 「프로세스가
        // 죽으면 즉시 idle」 이 하려던 일을 그쪽이 이미 한다. 여기에 kind 를 다시 실으면 같은 판단이 두
        // 곳에 생기고, 한쪽만 고쳐지는 날이 온다. 그래서 **의도적으로 false 다.**
        .process_exited = false,
        .hook_turn_seq = term.agent_hook_turn_seq,
        .screen_seq = term.agent_screen_seq,
    });
    term.agent_state = verdict.state;
    term.agent_state_origin = verdict.origin;
    term.agent_state_rule = verdict.rule;

    // **뒤집힌 전이도 턴 끝이면 작업트리를 굳힌다**(§1.3 · 적대적 검증이 잡았다).
    //
    // 스냅샷을 찍던 세 자리가 전부 **훅 전이** 기준이라, C2 가 닫은 턴(codex 오류 턴)은 아무도 안 찍었다 —
    // 「배지는 풀리는데 그 턴에 바뀐 파일은 통째로 사라진다」. 예전 §9-10 의 손해가 형태만 바꿔 남아
    // 있었던 것이다.
    //
    // **`origin == .screen` 일 때만 찍는다.** 훅이 닫은 전이는 위 세 자리가 이미 찍었고, 여기서 또 찍으면
    // 같은 턴 끝에 `git write-tree` 가 두 번 **동기로** 돈다(§1.3 이 막으려던 그것).
    // ⚠️ **훅이 있을 때만이다.** 훅이 없는 Term(§1.1 A)은 `origin` 이 어차피 화면이고 그쪽은
    // `pollAgentState` 가 이미 찍는다 — `has_hook` 을 빼면 A 경로에서 같은 턴 끝을 **두 번** 찍는다
    // (이 블록을 처음 쓸 때 실제로 그랬다).
    if (has_hook and verdict.origin == .screen and
        maru.session.turn_snapshot.isTurnEnd(turnStateOf(before), turnStateOf(verdict.state)))
    {
        // **턴 키를 싣지 않는다.** 이 턴이 어떻게 끝났는지는 훅만 아는데 그 훅이 안 왔기 때문에 C2 가
        // 필요했다 — 빈 키는 「모른다」이고, AT3 는 그런 항목에 provider 기록을 붙이지 않는다.
        captureTurnSnapshot(self, term.surfaceId(), .{}, 0);
    }
    if (verdict.state != before) {
        if (displayed) self.metal_dirty = true;
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info(
            "arbitrate {s} -> {s} origin={s} rule={s} hook={s} screen={s} screen_rule={s} idle={} children={d}",
            .{
                @tagName(before),                      @tagName(verdict.state),
                @tagName(verdict.origin),              verdict.rule,
                @tagName(term.agent_hook_state),       @tagName(term.agent_screen_state),
                term.agent_screen_rule,                term.agent_screen_visible_idle,
                term.agent_hook_progress.childCount(),
            },
        );
    }
}

/// 에이전트 종류 브랜드색(claude=Anthropic 코랄 #CC785C, codex=OpenAI 청록 #10A37F). none이면 null. 아이콘·상태줄
/// 스피너·탭바 파형이 **모두 이 단일 출처**를 쓴다(색이 갈리지 않게 — code-review max, 옛 두 곳 하드코딩 통합).
pub fn agentBrandColor(kind: AgentKind) ?maru.color.Rgb {
    return switch (kind) {
        .claude => .{ .r = 0xCC, .g = 0x78, .b = 0x5C }, // Anthropic 공식 코랄 #CC785C
        .codex => .{ .r = 0x10, .g = 0xA3, .b = 0x7F }, // OpenAI 청록 #10A37F
        .none => null,
    };
}

/// running 마커(`●`) UTF-8 한 글자. 셀 draw list가 마커만 그릴 때 쓴다(제목은 measured 경로).
pub fn agentFlagUtf8() []const u8 {
    return "\u{25CF}";
}

pub fn recolorAgentFlagCells(cells: anytype, kind: AgentKind) void {
    const brand = agentBrandColor(kind) orelse return;
    for (cells) |*c| {
        if (c.codepoint == agent_running_flag) c.style.foreground = .{ .rgb = brand };
    }
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// 커서 깜빡임 반주기는 config(`cursor.blink-interval-ms`, 기본 500ms)에서 온다 — updateCursorBlink가 **실경과 시간**
// (wall-clock)으로 재 tick rate와 무관하게 그 속도를 지킨다(§10.5). 기본값은 macOS 캐럿 관례(on 500ms / off 500ms).
pub const agent_poll_interval_ms: u32 = 500; // 포그라운드 프로세스(에이전트) polling 주기.

/// 세션 기록 파일(transcript) polling 주기. 대화는 **사람이 치는 속도**로 바뀌므로 상태 polling(≈0.5s)보다 느려도
/// 충분하고, 디렉터리 스캔·tail 파싱을 그만큼 덜 한다(docs/sidebar-agent-list.md §7.4).
pub const transcript_poll_interval_ms: u64 = 1000;

/// 활동 시각은 **시간이 흐르는 것만으로** 값이 바뀐다(5m → 6m). 다른 재렌더 사유가 없으면 화면에 멈춘 값이 남다가
/// 무관한 이벤트에 갑자기 뛴다 — 값이 틀린 것보다 그 거동이 더 헷갈린다(code-review max). 그래서 에이전트를 보여주는
/// 동안 이 주기로 재렌더한다. 표기 최소 단위가 분이므로 이보다 촘촘할 이유가 없다.
pub const agent_age_repaint_interval_ms: u32 = 20_000;

pub const agent_observer_interval_ms: u32 = 100; // 화면/OSC/activity 상태 판정 주기.

pub const agent_activity_window_ms: u64 = 500; // 이 안의 마지막 PTY output은 recent activity로 본다.

/// observer가 읽는 화면 tail 상한(행·바이트). 옛 12행은 **사용자 입력이 길어지면 근거를 잃는** 두 번째 원인이었다 —
/// 실측(codex 0.146.0)에서 composer는 입력 행 수만큼 제한 없이 자라, 입력 13행부터 프롬프트 마커가 12행 tail 밖으로
/// 밀려 idle 근거가 사라졌다. 상시 chrome(프롬프트 마커·실행 footer)은 입력 길이와 무관하게 tail 안에 남아야 하므로
/// 화면 높이급으로 둔다. 오래된 오버레이 문구가 현재 근거로 끌려오는 것은 행 수가 아니라 오버레이 규칙의 거리
/// 게이트가 막는다(docs/agent-session.md «상태 모델과 우선순위»).
///
/// byte 상한은 **행 상한을 잘라먹지 않을 만큼** 크게 잡는다. `dumpRecentTextUtf8`이 `max_bytes / (cols*4 + 1)`로 행 수를
/// 다시 계산하므로, 32KiB로 두면 320칸에서 25행·640칸에서 12행으로 줄어 이 상수가 대체하려던 한계가 넓은 창에서 그대로
/// 되살아난다(코드 리뷰에서 재현). 128KiB면 640칸에서도 48행이 유지된다. worst-case 가정(모든 셀 4바이트)일 뿐이고
/// 실제 복사량은 화면 내용만큼이라, ASCII 화면에서는 여전히 수십 KiB다.
pub const agent_screen_tail_rows: usize = 48;

pub const agent_screen_tail_bytes: usize = 128 * 1024;

pub const agent_spin_interval_ms: u32 = 133; // running 스피너 프레임 주기(옛 30Hz 4틱 ≈133ms).

/// login/shell wrapper를 건너뛰고 같은 foreground group 안의 실제 agent 구성원을 찾는다. OS 열거와 provider 정책을
/// 섞지 않도록 PTY는 이름 목록만 준다. 서로 다른 provider가 같은 group에 동시에 보이면 열거 순서로 임의 선택하지 않고
/// none으로 실패해 오분류를 피한다. 같은 provider의 wrapper/native 중복은 하나로 취급한다.
/// foreground 목록에서 **에이전트 프로세스의 pid**를 고른다(없으면 null). 세션 신원 env는 이 pid의 자식에게만
/// 내려오므로(`agentSessionIdentity`) 결속의 출발점이다. 이름 판정은 `classifyAgent` 단일 출처를 재사용한다.
pub fn agentProcessPid(processes: []const maru.pty.types.ForegroundProcessName, kind: AgentKind) ?i32 {
    if (kind == .none) return null;
    for (processes) |*process| {
        if (classifyAgent(process.slice()) != kind) continue;
        if (process.pid > 0) return process.pid;
    }
    return null;
}

pub fn classifyAgentProcesses(processes: []const maru.pty.types.ForegroundProcessName) AgentKind {
    var found: AgentKind = .none;
    for (processes) |*process| {
        const kind = classifyAgent(process.slice());
        if (kind == .none) continue;
        if (found != .none and found != kind) return .none;
        found = kind;
    }
    return found;
}

/// config `shell.command`를 검증해 spawn에 쓸 최종 셸 경로를 돌려준다. 설정돼 있고 실행 가능한 파일이면 그
/// 경로를, 아니면(빈 값·`~`·상대경로·없는 경로·실행 불가) `resolveInteractiveShell()` 기본 셸로 폴백한다.
/// **이유**: 잘못된 셸 경로를 그대로 execve하면 자식이 즉시 _exit(127)로 죽고, 첫(유일) 창이면
/// allTabsTerminated → app_should_terminate로 앱이 시작하자마자 종료된다. 여기서 미리 걸러 세션을 잃지 않는다
/// (workspace.root의 chdir 실패 시 $HOME graceful 폴백과 같은 forgiving 정책). 폴백(resolveInteractiveShell =
/// $MARU_INTERACTIVE_SHELL→$SHELL→/bin/sh)도 실행 불가일 수 있어($SHELL가 삭제된 셸을 가리킴) 한 번 더 검사하고,
/// 그것마저 실패하면 최후로 `/bin/sh`로 떨어진다 — 폴백까지 exec 실패해 첫 창이 종료되는 것을 막는다.
/// **범위(부분 방어)**: 이 함수는 *실행 불가한 셸 경로*만 막는다. 실행은 되지만 즉시 종료하는 셸(예: /usr/bin/false)
/// 이나 셸을 종료시키는 shell.args는 못 막아, 그 경우 여전히 세션이 끝나 유일 창이면 앱이 종료된다 — 그건 별개의
/// 루트커즈("시작 시 유일 surface 즉시 사망 → 앱 종료" lifecycle)로, 후속 과제다(project-rules.md §루트커즈). 반환
/// 슬라이스는 `command`(config arena) 또는 environ/정적 리터럴을 가리켜 caller가 소유/해제하지 않는다(spawn 시 dupeZ 복사).
/// `exec <provider> <args…>` 문자열을 만든다. 각 토큰을 작은따옴표로 감싸 셸이 어떤 확장도 하지
/// 않게 한다(메커니즘 단일 출처: `maru.pty.types.appendSingleQuoted`).
///
/// `exec`를 붙이는 이유: 중간 셸이 남지 않아 프로세스 트리가 직접 exec일 때와 같아지고, 실행 중
/// 판정(foreground process group 열거)이 그대로 성립한다. 호출자가 반환 슬라이스를 free한다.
pub fn buildResumeShellCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "exec");
    for (argv) |token| {
        try out.append(allocator, ' ');
        try maru.pty.types.appendSingleQuoted(allocator, &out, token);
    }
    return try out.toOwnedSlice(allocator);
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

/// 포그라운드 process group 구성원 이름 하나를 에이전트 종류로 분류한다(대소문자 무시 prefix 일치).
/// PTY backend가 comm이 interpreter면 argv[1], 버전 문자열이면 argv[0]으로 먼저 해소한다.
pub fn classifyAgent(name: ?[]const u8) AgentKind {
    const n = name orelse return .none;
    if (startsWithCi(n, "claude")) return .claude;
    if (startsWithCi(n, "codex")) return .codex;
    return .none;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

/// haystack이 prefix로 시작하는가(대소문자 무시). 프로세스명 분류용 — 부분일치(claudia·mycodex 오탐)를 피하면서
/// 변종("claude-code"·"codex-cli")은 잡는다.
pub fn startsWithCi(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}
