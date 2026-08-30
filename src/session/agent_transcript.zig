//! 에이전트 **세션 기록 파일**(transcript)에서 마지막 대화를 읽는다 — 사이드바 에이전트 행의 프롬프트·응답 줄
//! (docs/sidebar-agent-list.md §7)의 단일 출처.
//!
//! **왜 화면이 아니라 파일인가**: 상태 판정(`agent_observer`)은 짧은 마커라 화면에서 뽑을 수 있지만, 대화 **본문**은
//! `/clear`를 하거나 응답이 길어 스크롤 밖으로 밀리면 **화면에 존재하지 않는다**. 화면은 대화의 렌더 결과이지
//! 대화가 아니다.
//!
//! **왜 훅이 아닌가**: 세션 파일과 Term을 잇는 데 provider 훅(사용자 config 수정)이 필요하지 않다는 것을 실측으로
//! 확인했다(§7.2). 훅은 사용자 설정 파일을 고쳐 쓰고 설치·제거·자가정리를 유지해야 하며 사용자가 그 설정을 손대면
//! 조용히 깨진다.
//!
//! **계약**(§7.1) — 이 모듈의 모든 함수가 지킨다:
//! 1. **선택적 보강이다.** 어떤 실패도 error가 아니라 **빈 결과**로 돌아온다. 행은 아이콘·상태로 정상 동작하고
//!    대화 줄만 빈다. 이 계약이 없으면 provider가 포맷을 바꿀 때 목록 전체가 죽는다.
//! 2. **파일을 추측하지 않는다.** provider가 **자식 프로세스 env로 밝힌 세션 신원**으로만 파일을 고른다
//!    (claude `CLAUDE_CODE_SESSION_ID`=파일명, codex `CODEX_THREAD_ID`=rollout 접미사 — §7.2.1). 신원을 얻지
//!    못하면 아무것도 보여주지 않는다. 예전엔 "그 순간 갱신된 파일"을 따라갔지만(활동 상관) 그 추측이 새
//!    터미널에 옛 대화를 붙이고 같은 cwd의 두 에이전트가 서로의 대화를 물게 해 폐기했다.
//! 3. **서브에이전트를 배제한다.** claude는 서브에이전트 기록이 `<세션 id>/` **하위 디렉터리**에 쌓이므로 직속
//!    파일만 훑으면 배제된다(§7.3). 실측: 직속 54개 ↔ 하위 포함 1805개.
//! 4. **tail만 읽는다.** 47MB 파일도 끝 `max_tail_bytes`만 본다(§7.4).
//!
//! OS 중립이다 — `std.fs`만 쓰고 macOS 타입에 닿지 않는다.

const std = @import("std");

/// 한 번에 읽는 파일 꼬리 크기. 실측(§7.4): 이 크기 안에 last-prompt 7건·assistant 텍스트 11건이 들어 있었다.
/// 더 키우면 도구 결과가 거대한 세션에서 회수율이 오르지만 매 폴링 비용도 그만큼 오른다 — 계약 1이 있으므로
/// 못 찾으면 그 줄만 비고, 다음 대화 때 다시 잡힌다.
pub const max_tail_bytes: usize = 256 * 1024;

/// 표시용 상한. 사이드바 폭이 좁아 이보다 길면 어차피 잘리고, 무한정 복사할 이유가 없다.
pub const max_text_bytes: usize = 512;

/// 한 세션의 마지막 대화를 담는 소유 버퍼.
///
/// **슬라이스가 아니라 오프셋으로 든다.** 슬라이스로 들면 이 구조체를 복사하는 순간 새 사본의 필드가 원본 버퍼를
/// 가리켜 dangling이 된다 — `mergeKeepingMissing`이 정확히 그 복사를 하므로, 오프셋이어야 병합이 성립한다.
pub const Owned = struct {
    buf: [max_text_bytes * 3]u8 = undefined,
    used: usize = 0,
    prompt_off: usize = 0,
    prompt_len: usize = 0,
    reply_off: usize = 0,
    reply_len: usize = 0,
    cwd_off: usize = 0,
    cwd_len: usize = 0,

    /// 마지막 **사용자** 프롬프트. 빈 슬라이스 = 그 줄 없음(계약 1).
    pub fn prompt(self: *const Owned) []const u8 {
        return self.buf[self.prompt_off..][0..self.prompt_len];
    }

    /// 마지막 **에이전트** 응답.
    pub fn reply(self: *const Owned) []const u8 {
        return self.buf[self.reply_off..][0..self.reply_len];
    }

    /// 이 기록이 주장하는 작업 디렉터리. 호출부가 Term의 cwd와 대조해 **오매핑을 거른다**(§7.3 — 디렉터리 이름
    /// 인코딩 규칙이 불완전해도 여기서 걸린다). codex는 tail에 없어 비어 있다(후보를 고를 때 이미 대조했다).
    pub fn cwd(self: *const Owned) []const u8 {
        return self.buf[self.cwd_off..][0..self.cwd_len];
    }

    pub fn isEmpty(self: *const Owned) bool {
        return self.prompt_len == 0 and self.reply_len == 0;
    }

    pub fn clear(self: *Owned) void {
        self.used = 0;
        self.prompt_len = 0;
        self.reply_len = 0;
        self.cwd_len = 0;
    }

    /// `text`를 버퍼 **끝에 이어 담고** (오프셋, 길이)를 준다. 상한을 넘으면 앞부분만 남긴다(UTF-8 경계는 지킨다).
    ///
    /// **혼자 쓰면 안 된다 — `rewrite`만 부른다.** 이 함수는 `used`를 되돌리지 않으므로 같은 버퍼에 값을
    /// 거듭 담으면 자리가 말라 버린다(아래 `rewrite` 주석의 실측 참조).
    fn store(self: *Owned, text: []const u8) struct { off: usize, len: usize } {
        const room = self.buf.len - self.used;
        const n = @min(text.len, @min(room, max_text_bytes));
        if (n == 0) return .{ .off = self.used, .len = 0 };
        @memcpy(self.buf[self.used..][0..n], text[0..n]);
        const kept = trimToCharBoundary(self.buf[self.used..][0..n]);
        const off = self.used;
        self.used += n;
        return .{ .off = off, .len = kept };
    }

    /// 세 값을 **빈 버퍼에 다시 담는다**(압축). 갱신 경로는 전부 여기를 지난다.
    ///
    /// **왜 이래야 하는가**: `buf`는 세 자리(각 `max_text_bytes`)뿐인 bump 버퍼이고 `store`는 `used`를
    /// 앞으로만 민다. 그래서 같은 `Owned`에 값을 **거듭 쓰면** 몇 번 만에 자리가 말라 새 값이 조용히
    /// 잘리고, 그 다음부터는 **길이 0**으로 들어간다 — 화면에서는 «대화 줄이 갑자기 사라진다»로 보인다.
    /// 훅 모드가 정확히 그 모양이었다(Term이 든 이 버퍼에 턴마다 직접 썼다): 실측으로 4턴은 멀쩡하고
    /// 5턴째에 프롬프트가 잘리고 6턴째부터 프롬프트·응답이 통째로 비었으며, `agent_kind`가 바뀌기 전에는
    /// 회복되지 않았다. 관측 모드가 그 증상을 안 낸 것은 폴링마다 새 `Owned`로 다시 담았기 때문이고,
    /// 그 «다시 담기»가 여기서 갱신 경로의 **기본값**이 된다.
    ///
    /// 인자가 `self.buf`를 가리켜도 안전하다 — 새 값을 임시 버퍼에 다 담은 뒤에 자신을 덮는다.
    ///
    /// ⚠️ **꺼내 둔 슬라이스는 갱신을 못 넘긴다.** 이어 담기만 하던 시절에는 한 번 꺼낸 `reply()` 가 계속
    /// 그 내용을 가리켰지만, 압축은 **같은 버퍼 안에서 내용을 옮긴다** — 포인터는 살아 있는데 가리키는
    /// 글자가 달라진다(길이도 그대로라 검사에 안 걸린다). 꺼낸 값은 **쓰기 전에 복사**한다. 지금 호출부는
    /// 모두 그렇게 한다(`dupe`·`allocPrint`·`appendSlice`·고정 버퍼 `set`).
    fn rewrite(self: *Owned, new_prompt: []const u8, new_reply: []const u8, new_cwd: []const u8) void {
        var tmp: Owned = .{};
        const p = tmp.store(new_prompt);
        tmp.prompt_off = p.off;
        tmp.prompt_len = p.len;
        const r = tmp.store(new_reply);
        tmp.reply_off = r.off;
        tmp.reply_len = r.len;
        const c = tmp.store(new_cwd);
        tmp.cwd_off = c.off;
        tmp.cwd_len = c.len;
        self.* = tmp; // 오프셋 기반이라 복사가 안전하다(슬라이스였다면 여기서 dangling)
    }

    pub fn setPrompt(self: *Owned, text: []const u8) void {
        self.rewrite(text, self.reply(), self.cwd());
    }

    pub fn setReply(self: *Owned, text: []const u8) void {
        self.rewrite(self.prompt(), text, self.cwd());
    }

    pub fn setCwd(self: *Owned, text: []const u8) void {
        self.rewrite(self.prompt(), self.reply(), text);
    }
};

/// `fresh`에서 **찾은 것만** 반영하고 못 찾은 항목은 `dst`의 값을 지킨다.
///
/// **왜 필요한가**: codex는 긴 턴에 추론·도구 레코드가 대량으로 쌓여 마지막 응답은 파일 끝 근처지만 그에 대응하는
/// 사용자 프롬프트는 **수 MB 앞**에 있을 수 있다(실측 최악 22MB — claude는 14KB). tail을 그만큼 키우는 건 매 갱신
/// 비용을 그만큼 올리는 일이라 답이 아니다. 대신 사용자가 프롬프트를 친 **직후에는 그게 파일 끝**이라 작은 tail로
/// 반드시 잡히고, 그 뒤 턴이 길어져도 이 병합이 값을 지킨다.
///
/// 파일이 **바뀌면** 호출부가 먼저 `clear`해야 한다 — 안 그러면 옛 세션의 대화가 새 세션 행에 남는다.
pub fn mergeKeepingMissing(dst: *Owned, fresh: *const Owned) void {
    const p = if (fresh.prompt_len > 0) fresh.prompt() else dst.prompt();
    const r = if (fresh.reply_len > 0) fresh.reply() else dst.reply();
    const c = if (fresh.cwd_len > 0) fresh.cwd() else dst.cwd();
    // 세 값이 `dst`·`fresh` 어느 쪽 버퍼를 가리켜도 안전하다 — `rewrite`가 임시 버퍼에 다 담은 뒤 덮는다.
    dst.rewrite(p, r, c);
}

/// 세션 파일 이름 상한. claude는 `<uuid>.jsonl`(41자)이라 넉넉하다.
pub const max_name_bytes: usize = 128;

/// Term마다 드는 **매핑 + 대화 캐시**. 힙을 잡지 않는다(고정 크기) — Term 생애와 함께 죽으므로 해제가 필요 없고,
/// 매 폴링마다 할당/해제하면 tick 비용이 는다.
///
/// **매핑을 고정하지 않는다**(계약 2). `mapped_output_ms`가 그 규율의 구현이다 — Term이 새로 출력할 때마다
/// (= 이 값이 `agent_last_output_ms`와 어긋날 때마다) 디렉터리를 다시 훑어 그 시점의 최신 파일을 채택한다.
/// `/clear`로 같은 프로세스가 파일을 갈아타도, resume으로 옛 파일에 이어 써도 자동으로 따라간다.
/// 세션 신원 문자열 상한(uuid 36자 + 여유).
pub const max_identity_bytes: usize = 64;

pub const Cache = struct {
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    /// provider가 **자식 env로 밝힌** 세션 신원(claude=세션 파일명, codex=rollout thread id). 비면 미확보 —
    /// 그때만 활동 상관 폴백을 쓴다(§7.2). 이 값이 있으면 파일 선택에 추측이 없다.
    identity_buf: [max_identity_bytes]u8 = undefined,
    identity_len: usize = 0,
    /// 마지막으로 **읽어서 파싱한** 파일 mtime. 그대로면 다시 읽지 않는다(계약 4).
    read_mtime_ns: i96 = 0,
    /// 마지막 폴링 시각(awake ms) — throttle.
    last_poll_ms: u64 = 0,
    /// 매핑을 채택할 때 기준이 된 Term 출력 시각. 위 설명 참조.
    mapped_output_ms: u64 = 0,
    owned: Owned = .{},

    pub fn fileName(self: *const Cache) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn identity(self: *const Cache) []const u8 {
        return self.identity_buf[0..self.identity_len];
    }

    pub fn setIdentity(self: *Cache, value: []const u8) void {
        const n = @min(value.len, self.identity_buf.len);
        @memcpy(self.identity_buf[0..n], value[0..n]);
        self.identity_len = n;
    }

    pub fn setFileName(self: *Cache, name: []const u8) void {
        const n = @min(name.len, self.name.len);
        @memcpy(self.name[0..n], name[0..n]);
        self.name_len = n;
    }

    /// 매핑과 대화를 모두 버린다. cwd가 바뀌었거나 기록이 그 Term의 것이 아님이 드러났을 때.
    ///
    /// **신원은 지우지 않는다** — 그건 provider가 밝힌 사실이지 우리가 추론한 매핑이 아니다. 신원이 바뀌는 경우는
    /// 호출부가 `setIdentity`로 덮어쓴다(그 전에 이 함수로 매핑을 버린다).
    pub fn reset(self: *Cache) void {
        self.name_len = 0;
        self.read_mtime_ns = 0;
        self.mapped_output_ms = 0;
        self.owned.used = 0;
        self.owned.clear();
    }

    pub fn prompt(self: *const Cache) []const u8 {
        return self.owned.prompt();
    }

    pub fn reply(self: *const Cache) []const u8 {
        return self.owned.reply();
    }
};

/// `text`를 `max` 바이트 이하로 자르되 UTF-8 시퀀스를 쪼개지 않는다. 알림처럼 표시 폭이 더 좁은 곳에서 쓴다.
pub fn clampUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    return text[0..trimToCharBoundary(text[0..max])];
}

/// UTF-8 시퀀스 한가운데서 자르지 않도록 길이를 뒤로 줄인다. 잘린 바이트를 그대로 두면 렌더가 U+FFFD를 뿌린다.
///
/// **`clampUtf8` 로는 못 메우는 자리가 있다.** 그쪽은 «상한을 넘을 때만» 자르므로, 이미 **버퍼 끝에서**
/// 잘려 온 슬라이스(길이가 정확히 상한)는 손대지 않는다 — 훅 payload 를 고정 버퍼로 디코드하는 자리가
/// 그렇다(512 = 한글 170자 + 2바이트). 그 자리는 이 함수를 직접 부른다.
pub fn trimToCharBoundary(text: []const u8) usize {
    var n = text.len;
    while (n > 0) {
        const len = std.unicode.utf8ByteSequenceLength(text[n - 1]) catch {
            // continuation byte(10xxxxxx) — 시퀀스 중간이다. 시작 바이트를 찾아 뒤로 간다.
            n -= 1;
            continue;
        };
        if (len == 1) return n; // ASCII: 여기서 끝나도 안전
        // 시작 바이트다. 그 시퀀스가 통째로 들어왔으면 포함, 아니면 잘라낸다.
        return if (n - 1 + len <= text.len) n - 1 + len else n - 1;
    }
    return 0;
}

/// cwd → claude 프로젝트 디렉터리 이름. **실측으로 역추론한 규칙**: `/`와 `.`을 `-`로 치환하는 1:1 매핑이다
/// (기존 프로젝트 디렉터리 8개를 각 파일의 `cwd` 필드와 문자 단위로 대조 — 길이 불일치 0, 대문자 보존).
///
/// 규칙이 모든 문자를 덮는다고 **가정하지 않는다**: provider가 다른 문자도 치환한다면 여기서 만든 이름의
/// 디렉터리가 없어 보강이 조용히 비고(계약 1), 우연히 다른 디렉터리와 겹치더라도 `Conversation.cwd` 대조가
/// 걸러낸다. 그래서 이 함수는 추측을 늘리는 대신 확인된 둘만 치환한다.
///
/// buf가 모자라면 null(계약 1).
pub fn claudeDirName(cwd: []const u8, buf: []u8) ?[]const u8 {
    if (cwd.len == 0 or cwd.len > buf.len) return null;
    for (cwd, 0..) |c, i| buf[i] = if (c == '/' or c == '.') '-' else c;
    return buf[0..cwd.len];
}

/// codex `session_meta` 가 밝히는 **부모 세션**. 재개/fork 로 이어진 세션이면 이전 대화가 그쪽에 있다.
///
/// 실측(2026-08-30, rollout 296 파일): fork/재개가 **172개(58%)**로 일상이고, 부모 id 가 파일명에 박혀
/// 있는 비율이 **100%**다. 그래서 파일을 열어 볼 필요 없이 **이름으로** 찾는다.
pub fn parseCodexParentId(head: []const u8, out: []u8) []const u8 {
    // `session_meta` 는 첫 줄이다 — 그 줄만 본다. 뒤 레코드에도 같은 키가 있으면 남의 부모를 집는다.
    const line = head[0..(std.mem.indexOfScalar(u8, head, '\n') orelse head.len)];
    if (std.mem.indexOf(u8, line, "\"session_meta\"") == null) return "";
    // `parent_thread_id` 가 먼저다 — `forked_from_id` 는 같은 값을 다른 이름으로 싣는 경우가 있어
    // 하나를 골라야 하고, 실측에서 둘 다 있을 때 값이 같았다.
    for ([_][]const u8{ "\"parent_thread_id\":\"", "\"forked_from_id\":\"" }) |key| {
        const at = std.mem.indexOf(u8, line, key) orelse continue;
        const start = at + key.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse continue;
        const v = line[start..end];
        if (v.len == 0 or v.len > out.len) continue;
        @memcpy(out[0..v.len], v);
        return out[0..v.len];
    }
    return "";
}

/// 그 파일명이 이 thread id 의 rollout 인가. 실측 이름 꼴은
/// `rollout-<ISO 시각>-<thread_id>.jsonl` 이라 **접미사**로 판정한다.
///
/// 접두사(`rollout-`)까지 요구하지 않는 이유는 이름 규칙이 바뀌어도 id 만 맞으면 그 파일이 맞기 때문이고,
/// 그렇다고 «id 를 포함» 으로 느슨하게 보면 다른 세션의 이름 안에 우연히 들어간 경우를 집는다.
pub fn isCodexRolloutOf(file_name: []const u8, thread_id: []const u8) bool {
    if (thread_id.len == 0) return false;
    if (!std.mem.endsWith(u8, file_name, ".jsonl")) return false;
    const stem = file_name[0 .. file_name.len - ".jsonl".len];
    if (!std.mem.endsWith(u8, stem, thread_id)) return false;
    // id 앞은 구분자여야 한다 — 안 그러면 `…-Xabc123` 이 `abc123` 의 것으로 읽힌다.
    const at = stem.len - thread_id.len;
    return at == 0 or stem[at - 1] == '-';
}

/// 확정된 트랜스크립트의 **절대경로**(claude). 이름은 호출자가 신원으로 이미 확정한 값이라 여기에
/// 추측이 없다(계약 2) — 하는 일은 `<claude_dir>/projects/<cwd 슬러그>/<이름>` 조립뿐이다.
///
/// 갤러리가 훅 없이도 소스를 얻는 길이다(docs/agent-image-gallery.md §4.4). 빈 입력이나 버퍼 부족은
/// `null` — 반쯤 만든 경로를 돌려주면 엉뚱한 파일을 열게 된다.
pub fn claudeTranscriptPath(buf: []u8, claude_dir: []const u8, cwd: []const u8, file_name: []const u8) ?[]const u8 {
    if (claude_dir.len == 0 or cwd.len == 0 or file_name.len == 0) return null;
    var slug_buf: [1024]u8 = undefined;
    const slug = claudeDirName(cwd, &slug_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/projects/{s}/{s}", .{ claude_dir, slug, file_name }) catch null;
}

/// 같은 것의 codex 판. codex 의 이름은 `~/.codex/sessions` 아래 **상대경로**다(날짜 계층을 포함한다).
pub fn codexTranscriptPath(buf: []u8, home: []const u8, file_name: []const u8) ?[]const u8 {
    if (home.len == 0 or file_name.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.codex/sessions/{s}", .{ home, file_name }) catch null;
}

/// codex 세션 파일이 밝히는 신원 — 첫 `session_meta` 레코드에서 뽑는다.
///
/// claude는 디렉터리 **이름**이 작업 디렉터리를 말해주지만 codex는 날짜 계층(`YYYY/MM/DD`)이라 **파일을 열어야**
/// 알 수 있다. 서브에이전트 배제도 여기서 갈린다 — claude는 하위 디렉터리라 스캔에서 자동으로 빠지지만
/// codex는 **같은 계층에 섞이므로**(실측: 최근 40개 중 32개가 서브에이전트) 이 필드로 거르는 수밖에 없다.
pub const CodexMeta = struct {
    cwd: []const u8 = "",
    /// `thread_source == "user"` — 사람이 연 세션. 서브에이전트·자동 스레드는 false.
    is_user: bool = false,
};

/// 파일 **앞부분**에서 `session_meta`를 찾아 신원을 뽑는다(순수 — IO 없음). `session_meta`는 첫 레코드라
/// 앞 몇 KB면 충분하다. 못 찾으면 빈 결과(계약 1) → 호출부가 그 후보를 건너뛴다.
pub fn parseCodexMeta(allocator: std.mem.Allocator, head: []const u8, out: []u8) CodexMeta {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |line| {
        if (line.len < 2 or line[0] != '{') continue;
        if (std.mem.indexOf(u8, line, "\"session_meta\"") == null) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const payload = switch (obj.get("payload") orelse std.json.Value{ .null = {} }) {
            .object => |p| p,
            else => continue,
        };
        var meta: CodexMeta = .{};
        switch (payload.get("thread_source") orelse std.json.Value{ .null = {} }) {
            .string => |src| meta.is_user = std.mem.eql(u8, src, "user"),
            else => {},
        }
        switch (payload.get("cwd") orelse std.json.Value{ .null = {} }) {
            .string => |c| {
                const n = @min(c.len, out.len);
                @memcpy(out[0..n], c[0..n]);
                meta.cwd = out[0..n];
            },
            else => {},
        }
        return meta;
    }
    return .{};
}

/// codex `## My request for Codex:` 마커 뒤만 남긴다. codex는 사용자 요청 앞에 컨텍스트를 덧대 보낼 때 이 마커로
/// 실제 요청의 시작을 표시한다 — codex 자신의 추출기(`state/extract.rs::strip_user_message_prefix`)와 같은 규칙이다.
/// 마커가 없으면 통째로 쓴다(대부분의 평범한 입력).
pub fn stripCodexUserPrefix(text: []const u8) []const u8 {
    const marker = "## My request for Codex:";
    if (std.mem.indexOf(u8, text, marker)) |idx| {
        return std.mem.trim(u8, text[idx + marker.len ..], " \t\r\n");
    }
    return std.mem.trim(u8, text, " \t\r\n");
}

/// codex JSONL tail에서 마지막 대화를 뽑는다(순수 — IO 없음).
///
/// **`event_msg`를 본다 — `response_item`이 아니다.** codex 자신의 추출기(`state/extract.rs`)가 그렇게 한다.
/// `response_item`의 `role == "user"` 메시지에는 환경 컨텍스트·규칙 파일·이미지 마커가 섞여 들어와 사람이 친 말과
/// 구분하려면 주입 태그 목록(`<environment_context>`·`<user_instructions>` 등 10종)을 따라다녀야 한다. 반면
/// `event_msg`의 `user_message`/`agent_message`는 **UI에 보여줄 원문**이라 그 필터가 통째로 필요 없다.
///
/// `cwd`는 tail이 아니라 **파일 앞** `session_meta`에 있으므로 여기서 채우지 않는다 — 후보를 고를 때 이미 봤다.
pub fn parseCodexTail(allocator: std.mem.Allocator, tail: []const u8, out: *Owned) void {
    out.clear();

    var scratch: [max_text_bytes]u8 = undefined;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    var want_prompt = true;
    var want_reply = true;
    while (it.next()) |line| {
        if (!want_prompt and !want_reply) break;
        if (line.len < 2 or line[0] != '{') continue;
        // 값싼 사전 검사 — tail 안 대부분은 토큰 집계·도구 이벤트라 파싱이 낭비다.
        if (std.mem.indexOf(u8, line, "_message\"") == null) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        switch (obj.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |t| if (!std.mem.eql(u8, t, "event_msg")) continue,
            else => continue,
        }
        const payload = switch (obj.get("payload") orelse std.json.Value{ .null = {} }) {
            .object => |p| p,
            else => continue,
        };
        const kind: []const u8 = switch (payload.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |k| k,
            else => continue,
        };
        const is_user = std.mem.eql(u8, kind, "user_message");
        const is_agent = std.mem.eql(u8, kind, "agent_message");
        if (!is_user and !is_agent) continue;
        if (is_user and !want_prompt) continue;
        if (is_agent and !want_reply) continue;

        const message: []const u8 = switch (payload.get("message") orelse std.json.Value{ .null = {} }) {
            .string => |m| m,
            else => "",
        };
        var text = message;
        if (is_user) {
            text = stripCodexUserPrefix(text);
            // 이미지만 보낸 턴은 본문이 비어 있다 — codex UI가 쓰는 것과 같은 자리표시자를 둔다(state/extract.rs).
            if (text.len == 0) {
                const has_image = payload.get("images") != null or payload.get("local_images") != null;
                if (has_image) text = "[Image]";
            }
        }
        if (text.len == 0) continue;
        const flat = flatten(text, &scratch);
        if (flat.len == 0) continue;
        if (is_user) {
            out.setPrompt(flat);
            want_prompt = false;
        } else {
            out.setReply(flat);
            want_reply = false;
        }
    }
}

/// codex 날짜 계층에서 **파일명이 `suffix`로 끝나는** 파일을 찾는다(`rollout-<ts>-<thread_id>.jsonl`).
///
/// 신원(`CODEX_THREAD_ID`)을 아는 경우의 경로다 — 후보를 열어 `session_meta`를 파싱할 필요도, mtime을 비교할
/// 필요도 없다. 상대 경로를 `out`에 쓰고 반환한다. 없으면 null(아직 파일이 안 생겼거나 다른 기계의 세션).
pub fn findCodexByThreadId(io: std.Io, root: std.Io.Dir, suffix: []const u8, out: []u8) ?[]const u8 {
    var years = root.iterate();
    while ((years.next(io) catch return null)) |y| {
        if (y.kind != .directory) continue;
        var ydir = root.openDir(io, y.name, .{}) catch continue;
        defer ydir.close(io);
        var months = ydir.iterate();
        while ((months.next(io) catch break)) |mo| {
            if (mo.kind != .directory) continue;
            var mdir = ydir.openDir(io, mo.name, .{}) catch continue;
            defer mdir.close(io);
            var days = mdir.iterate();
            while ((days.next(io) catch break)) |d| {
                if (d.kind != .directory) continue;
                var ddir = mdir.openDir(io, d.name, .{}) catch continue;
                defer ddir.close(io);
                var files = ddir.iterate();
                while ((files.next(io) catch break)) |f| {
                    if (f.kind != .file) continue;
                    if (!std.mem.endsWith(u8, f.name, suffix)) continue;
                    const written = std.fmt.bufPrint(out, "{s}/{s}/{s}/{s}", .{ y.name, mo.name, d.name, f.name }) catch return null;
                    return written;
                }
            }
        }
    }
    return null;
}

/// 파일 **끝** `buf.len` 바이트. 첫 줄은 중간에서 잘렸을 수 있으므로 버린다(부분 JSON을 파싱하면 잡음이 된다).
/// 실패는 빈 슬라이스(계약 1).
pub fn readTail(io: std.Io, dir: std.Io.Dir, name: []const u8, buf: []u8) []const u8 {
    const file = dir.openFile(io, name, .{}) catch return "";
    defer file.close(io);
    const size = (file.stat(io) catch return "").size;
    const want: usize = @intCast(@min(size, buf.len));
    if (want == 0) return "";
    const start = size - want;
    const n = file.readPositionalAll(io, buf[0..want], start) catch return "";
    const tail = buf[0..n];
    if (start == 0) return tail; // 파일 전체 — 첫 줄이 온전하다
    const nl = std.mem.indexOfScalar(u8, tail, '\n') orelse return "";
    return tail[nl + 1 ..];
}

/// claude JSONL tail에서 마지막 대화를 뽑는다(순수 — IO 없음).
///
/// **왜 `last-prompt` 레코드인가**: `type == "user"` 레코드는 대부분 도구 결과이고, 사람이 치지 않은 자동 입력
/// (컨텍스트 요약 이어받기, 백그라운드 작업 알림)도 같은 모양으로 섞인다. provider가 따로 남기는 `last-prompt`는
/// **사람이 실제로 친 것만** 담는다(실측: 같은 파일에서 user 후보 77건 중 자동 입력이 섞였고, last-prompt 152건은
/// 전부 실입력). 이 레코드가 없는 버전이면 프롬프트 줄만 빈다(계약 1) — user 레코드를 추측으로 걸러 잘못된 텍스트를
/// 보여주느니 비우는 편이 낫다.
///
/// 뒤에서 앞으로 훑으며 필요한 것을 다 찾으면 멈춘다 — tail 전체를 파싱하지 않는다.
pub fn parseClaudeTail(allocator: std.mem.Allocator, tail: []const u8, out: *Owned) void {
    out.clear();

    var scratch: [max_text_bytes]u8 = undefined;
    var it = std.mem.splitBackwardsScalar(u8, tail, '\n');
    var want_prompt = true;
    var want_reply = true;
    var want_cwd = true;
    while (it.next()) |line| {
        if (!want_prompt and !want_reply and !want_cwd) break;
        if (line.len < 2 or line[0] != '{') continue;

        // JSON 파싱 전에 값싼 문자열 검사로 후보만 거른다 — tail 안 대부분의 줄은 도구 결과라 파싱이 낭비다.
        const is_prompt = want_prompt and std.mem.indexOf(u8, line, "\"last-prompt\"") != null;
        const is_reply = want_reply and std.mem.indexOf(u8, line, "\"assistant\"") != null;
        if (!is_prompt and !is_reply and !(want_cwd and std.mem.indexOf(u8, line, "\"cwd\"") != null)) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        if (want_cwd) {
            if (obj.get("cwd")) |v| switch (v) {
                .string => |s| {
                    out.setCwd(s);
                    want_cwd = false;
                },
                else => {},
            };
        }

        const rec_type: []const u8 = switch (obj.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };

        if (want_prompt and std.mem.eql(u8, rec_type, "last-prompt")) {
            if (obj.get("lastPrompt")) |v| switch (v) {
                .string => |s| {
                    const flat = flatten(s, &scratch);
                    if (flat.len > 0) {
                        out.setPrompt(flat);
                        want_prompt = false;
                    }
                },
                else => {},
            };
            continue;
        }

        if (want_reply and std.mem.eql(u8, rec_type, "assistant")) {
            // 서브에이전트 대화가 같은 파일에 sidechain으로 실릴 수 있다 — 사용자 카드에 내부 대화를 띄우지 않는다.
            if (obj.get("isSidechain")) |v| switch (v) {
                .bool => |b| if (b) continue,
                else => {},
            };
            const msg = switch (obj.get("message") orelse std.json.Value{ .null = {} }) {
                .object => |m| m,
                else => continue,
            };
            const content = switch (msg.get("content") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => continue,
            };
            // 한 응답 안에 thinking·tool_use가 섞이므로 **마지막 text 블록**만 쓴다.
            var found: []const u8 = "";
            for (content.items) |block| {
                const bo = switch (block) {
                    .object => |b| b,
                    else => continue,
                };
                const bt = switch (bo.get("type") orelse std.json.Value{ .null = {} }) {
                    .string => |s| s,
                    else => continue,
                };
                if (!std.mem.eql(u8, bt, "text")) continue;
                switch (bo.get("text") orelse std.json.Value{ .null = {} }) {
                    .string => |s| found = s,
                    else => {},
                }
            }
            if (found.len > 0) {
                const flat = flatten(found, &scratch);
                if (flat.len > 0) {
                    out.setReply(flat);
                    want_reply = false;
                }
            }
        }
    }
}

/// 여러 줄 텍스트를 사이드바 **한 줄**로 눕힌다: 개행·탭을 공백으로, 연속 공백을 하나로, 앞뒤 공백 제거.
/// 마크다운 기호는 그대로 둔다 — 없애면 코드 조각이나 목록이 뜻을 잃고, 잘라 보여주는 미리보기라 원문이 낫다.
///
/// **대화 줄에 담기 전에 반드시 지난다**(두 소스 공통). 이 파일의 파서는 저장 직전에 부르고, 훅 모드는
/// platform 이 같은 자리에서 부른다 — 그 줄은 한 줄 텍스트 run 이라 진짜 개행이 들어가면 글자가 뭉개진다.
/// 그래서 `pub` 이다: 규율을 두 곳에 각자 적으면 한쪽이 먼저 잊는다.
pub fn flatten(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (text) |c| {
        if (n >= buf.len) break;
        const is_space = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (is_space) {
            if (n > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
            pending_space = false;
            if (n >= buf.len) break;
        }
        buf[n] = c;
        n += 1;
    }
    return buf[0..trimToCharBoundary(buf[0..n])];
}

const testing = std.testing;

test "claudeDirName: 실측 규칙(/ · . → -)을 그대로 따른다" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "-Users-yoonhb-Documents-workspace-maru",
        claudeDirName("/Users/yoonhb/Documents/workspace/maru", &buf).?,
    );
    // 점도 치환된다(실측 대조에서 확인된 둘 중 하나) — `.config` 같은 경로가 조용히 빗나가지 않게.
    try testing.expectEqualStrings("-home-me--config-app", claudeDirName("/home/me/.config/app", &buf).?);
    // 하이픈은 원래 이름에 있을 수 있고 그대로 둔다(역변환이 모호한 이유이기도 하다).
    try testing.expectEqualStrings("-a-react-native-mcp", claudeDirName("/a/react-native-mcp", &buf).?);
    // 계약 1: 빈 cwd·버퍼 부족은 error가 아니라 null이다.
    try testing.expect(claudeDirName("", &buf) == null);
    var tiny: [4]u8 = undefined;
    try testing.expect(claudeDirName("/very/long/path", &tiny) == null);
}

test "parseClaudeTail: last-prompt와 마지막 assistant text를 뽑고 cwd를 싣는다" {
    const tail =
        \\{"type":"user","cwd":"/w/maru","message":{"role":"user","content":[{"type":"tool_result","content":"noise"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"속마음"},{"type":"text","text":"네, 수정했습니다"},{"type":"tool_use","name":"Bash"}]}}
        \\{"type":"last-prompt","lastPrompt":"배포 스크립트 고쳐줘","leafUuid":"x"}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("배포 스크립트 고쳐줘", owned.prompt());
    // thinking·tool_use가 아니라 text 블록이어야 한다 — 속마음이 사이드바에 뜨면 안 된다.
    try testing.expectEqualStrings("네, 수정했습니다", owned.reply());
    try testing.expectEqualStrings("/w/maru", owned.cwd());
}

test "parseClaudeTail: 자동 입력을 사용자 프롬프트로 착각하지 않는다" {
    // `type:"user"`인데 사람이 친 게 아닌 것들(백그라운드 알림·컨텍스트 요약 이어받기)만 있고 last-prompt가 없다.
    // 이때 프롬프트 줄은 **비어야** 한다 — 추측으로 자동 입력을 띄우느니 비우는 편이 낫다(계약 1).
    const tail =
        \\{"type":"user","message":{"role":"user","content":"<task-notification>백그라운드 완료</task-notification>"}}
        \\{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation"}}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("", owned.prompt());
    try testing.expect(owned.isEmpty());
}

test "parseClaudeTail: 서브에이전트(sidechain) 응답을 배제한다" {
    const tail =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"사용자 응답"}]}}
        \\{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"서브에이전트 내부"}]}}
        \\
    ;
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("사용자 응답", owned.reply());
}

test "parseClaudeTail: 잘린 줄·깨진 JSON·빈 입력에도 죽지 않는다(계약 1)" {
    var owned: Owned = .{};
    parseClaudeTail(testing.allocator, "", &owned);
    try testing.expect(owned.isEmpty());
    parseClaudeTail(testing.allocator, "{\"type\":\"last-prompt\",\"lastPro", &owned); // 중간에서 잘린 줄
    try testing.expect(owned.isEmpty());
    parseClaudeTail(testing.allocator, "not json at all\n{}\n[]\n", &owned);
    try testing.expect(owned.isEmpty());
    // type이 있어도 기대한 필드가 없으면 그냥 빈다.
    parseClaudeTail(testing.allocator, "{\"type\":\"last-prompt\"}\n{\"type\":\"assistant\",\"message\":{}}\n", &owned);
    try testing.expect(owned.isEmpty());
}

test "parseCodexMeta: thread_source로 사용자 세션과 서브에이전트를 가른다" {
    var buf: [256]u8 = undefined;
    const user_head =
        \\{"timestamp":"2026-07-24T17:42:43.137Z","type":"session_meta","payload":{"id":"x","cwd":"/w/maru","thread_source":"user","originator":"codex-tui"}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"안녕"}]}}
        \\
    ;
    const m1 = parseCodexMeta(testing.allocator, user_head, &buf);
    try testing.expect(m1.is_user);
    try testing.expectEqualStrings("/w/maru", m1.cwd);

    // 서브에이전트는 **같은 계층에 섞이므로** 이 필드가 유일한 구분선이다(실측: 최근 40개 중 32개가 서브에이전트).
    const sub_head =
        \\{"type":"session_meta","payload":{"id":"y","cwd":"/w/maru","thread_source":"subagent"}}
        \\
    ;
    const m2 = parseCodexMeta(testing.allocator, sub_head, &buf);
    try testing.expect(!m2.is_user);

    // session_meta가 없거나 깨진 앞부분은 빈 결과 — 호출부가 그 후보를 건너뛴다(계약 1).
    const m3 = parseCodexMeta(testing.allocator, "not json\n{}\n", &buf);
    try testing.expect(!m3.is_user);
    try testing.expectEqualStrings("", m3.cwd);
}

test "parseCodexTail: event_msg의 user_message/agent_message를 뽑는다" {
    // codex 자신의 추출기(state/extract.rs)와 같은 레코드를 본다 — response_item의 role=user에는 환경 컨텍스트·
    // 규칙 파일이 섞여 들어오지만 event_msg는 UI에 보여줄 원문이라 그 필터가 필요 없다.
    const tail =
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"고쳤습니다"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"빌드 고쳐줘"}}
        \\{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>주입</environment_context>"}]}}
        \\
    ;
    var owned: Owned = .{};
    parseCodexTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("빌드 고쳐줘", owned.prompt());
    try testing.expectEqualStrings("고쳤습니다", owned.reply());
    // response_item은 보지 않으므로 주입 블록이 프롬프트를 덮지 않는다.
    try testing.expect(std.mem.indexOf(u8, owned.prompt(), "environment_context") == null);
}

test "parseCodexTail: 사용자 요청 마커 뒤만 남기고 이미지 전용 턴을 표시한다" {
    const tail =
        \\{"type":"event_msg","payload":{"type":"user_message","message":"컨텍스트 잔뜩…\n## My request for Codex: 이것만 실제 요청"}}
        \\
    ;
    var owned: Owned = .{};
    parseCodexTail(testing.allocator, tail, &owned);
    try testing.expectEqualStrings("이것만 실제 요청", owned.prompt());

    // 이미지만 보낸 턴은 본문이 비어 codex UI가 자리표시자를 쓴다 — 빈 줄로 두면 그 턴이 없던 일이 된다.
    const img =
        \\{"type":"event_msg","payload":{"type":"user_message","message":"","images":["data:…"]}}
        \\
    ;
    parseCodexTail(testing.allocator, img, &owned);
    try testing.expectEqualStrings("[Image]", owned.prompt());
}

test "parseCodexTail: 토큰 집계·도구 이벤트는 대화가 아니다" {
    const tail =
        \\{"type":"event_msg","payload":{"type":"token_count","info":{}}}
        \\{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"속마음"}]}}
        \\{"type":"response_item","payload":{"type":"function_call","name":"shell"}}
        \\
    ;
    var owned: Owned = .{};
    parseCodexTail(testing.allocator, tail, &owned);
    try testing.expect(owned.isEmpty());
}

test "mergeKeepingMissing: 못 찾은 항목은 이전 값을 지킨다" {
    // codex는 긴 턴에서 프롬프트가 tail 밖(실측 최악 22MB)으로 밀린다. 그때 응답만 갱신하고 프롬프트는 지켜야
    // 한다 — 안 그러면 턴이 길어지는 순간 "무엇을 시켰는지"가 화면에서 사라진다.
    var dst: Owned = .{};
    dst.setPrompt("배포 스크립트 고쳐줘");
    dst.setReply("작업 시작합니다");

    var fresh: Owned = .{};
    fresh.setReply("다 고쳤습니다"); // 프롬프트는 tail 밖이라 못 찾음
    mergeKeepingMissing(&dst, &fresh);
    try testing.expectEqualStrings("배포 스크립트 고쳐줘", dst.prompt());
    try testing.expectEqualStrings("다 고쳤습니다", dst.reply());

    // 복사가 안전해야 한다 — 슬라이스 기반이었다면 여기서 dangling이다.
    var copy = dst;
    try testing.expectEqualStrings("배포 스크립트 고쳐줘", copy.prompt());
    copy.setPrompt("새 프롬프트");
    try testing.expectEqualStrings("배포 스크립트 고쳐줘", dst.prompt()); // 원본 불변
}

test "clampUtf8: 상한을 넘으면 글자 경계에서 자른다" {
    try testing.expectEqualStrings("가나", clampUtf8("가나", 6));
    try testing.expectEqualStrings("가나", clampUtf8("가나다", 8)); // 8바이트 = 2글자 + 2바이트 → 세 번째 글자를 버린다
    try testing.expectEqualStrings("ab", clampUtf8("abc", 2));
}

test "Owned: 상한을 넘겨도 넘치지 않고 앞부분을 남긴다" {
    var owned: Owned = .{};
    const long = "x" ** (max_text_bytes * 2);
    owned.setReply(long);
    try testing.expectEqual(max_text_bytes, owned.reply().len);
}

test "Owned: 같은 버퍼에 거듭 써도 값이 사라지지 않는다" {
    // **훅 모드가 이 자리에서 깨졌다.** 그 경로는 Term이 든 `Owned`에 턴마다 직접 쓰는데, 예전 `store`는
    // `used`를 앞으로만 밀어 몇 턴 만에 자리가 말랐다 — 실측으로 5턴째에 프롬프트가 잘리고 6턴째부터
    // 프롬프트·응답이 통째로 비었다. 사용자에게는 «사이드바 대화 줄과 알림 본문이 갑자기 사라진다»로
    // 보였고, `agent_kind`가 바뀌기 전에는 회복되지 않았다.
    //
    // **자리마다 따로 본다.** 섞어 쓰는 순서만 확인하면 셋 중 **하나만** 압축을 되돌려도 통과한다 —
    // 다른 자리의 압축이 `used`를 리셋해 주기 때문이다(실제로 그 약한 테스트를 먼저 썼고, 뮤테이션이
    // 그것을 드러냈다).
    const long = "x" ** 400;
    {
        var owned: Owned = .{};
        var i: usize = 0;
        while (i < 20) : (i += 1) owned.setReply(long);
        try testing.expectEqualStrings(long, owned.reply());
    }
    {
        var owned: Owned = .{};
        var i: usize = 0;
        while (i < 20) : (i += 1) owned.setPrompt(long);
        try testing.expectEqualStrings(long, owned.prompt());
    }
    {
        var owned: Owned = .{};
        var i: usize = 0;
        while (i < 20) : (i += 1) owned.setCwd(long);
        try testing.expectEqualStrings(long, owned.cwd());
    }

    // 훅 모드의 실제 순서(프롬프트 → 지난 응답 비우기 → 새 응답)로도 셋이 함께 살아 있어야 한다.
    var owned: Owned = .{};
    const reply = "x" ** 300;
    var turn: usize = 0;
    while (turn < 20) : (turn += 1) {
        owned.setPrompt("배포 스크립트 고쳐줘 — 사용자가 친 문장이 이만큼 길 수 있다");
        owned.setReply("");
        owned.setReply(reply);
    }
    try testing.expectEqualStrings("배포 스크립트 고쳐줘 — 사용자가 친 문장이 이만큼 길 수 있다", owned.prompt());
    try testing.expectEqualStrings(reply, owned.reply());
}

test "트랜스크립트 절대경로: claude 는 cwd 슬러그 아래다" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "/h/.claude/projects/-Users-me-work/abc.jsonl",
        claudeTranscriptPath(&buf, "/h/.claude", "/Users/me/work", "abc.jsonl").?,
    );
    // 점도 슬러그에서 하이픈이 된다(`claudeDirName` 규칙을 그대로 쓴다 — 여기서 다시 구현하지 않는다).
    try testing.expectEqualStrings(
        "/h/.claude/projects/-a-b-c-d/x.jsonl",
        claudeTranscriptPath(&buf, "/h/.claude", "/a/b.c/d", "x.jsonl").?,
    );
}

test "트랜스크립트 절대경로: codex 는 이름이 상대경로다(날짜 계층 포함)" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "/home/me/.codex/sessions/2026/08/29/rollout-x-y.jsonl",
        codexTranscriptPath(&buf, "/home/me", "2026/08/29/rollout-x-y.jsonl").?,
    );
}

test "트랜스크립트 절대경로: 빈 입력과 좁은 버퍼는 null — 반쯤 만든 경로를 돌려주지 않는다" {
    var buf: [512]u8 = undefined;
    try testing.expect(claudeTranscriptPath(&buf, "", "/a", "x") == null);
    try testing.expect(claudeTranscriptPath(&buf, "/h", "", "x") == null);
    try testing.expect(claudeTranscriptPath(&buf, "/h", "/a", "") == null);
    try testing.expect(codexTranscriptPath(&buf, "", "x") == null);
    try testing.expect(codexTranscriptPath(&buf, "/h", "") == null);
    // 버퍼가 모자라면 자르지 않고 포기한다.
    var tiny: [8]u8 = undefined;
    try testing.expect(claudeTranscriptPath(&tiny, "/home/me/.claude", "/a", "x.jsonl") == null);
    try testing.expect(codexTranscriptPath(&tiny, "/home/me", "a/b/c.jsonl") == null);
}

test "codex 부모 신원: session_meta 첫 줄에서만 읽는다" {
    var buf: [64]u8 = undefined;
    const forked =
        \\{"type":"session_meta","payload":{"id":"child-1","parent_thread_id":"parent-9","cwd":"/x"}}
        \\{"type":"response_item","payload":{"parent_thread_id":"NOT-MINE"}}
    ;
    try testing.expectEqualStrings("parent-9", parseCodexParentId(forked, &buf));

    // `forked_from_id` 만 있어도 읽는다.
    const only_forked =
        \\{"type":"session_meta","payload":{"id":"c","forked_from_id":"p-2"}}
    ;
    try testing.expectEqualStrings("p-2", parseCodexParentId(only_forked, &buf));

    // 부모가 없으면 빈 값 — 독립 세션이다(실측 296 중 124개).
    const plain =
        \\{"type":"session_meta","payload":{"id":"solo","cwd":"/x"}}
    ;
    try testing.expectEqualStrings("", parseCodexParentId(plain, &buf));

    // **첫 줄이 session_meta 가 아니면 안 본다.** 뒤 레코드의 같은 키를 집으면 남의 부모가 붙는다.
    const not_meta =
        \\{"type":"response_item","payload":{"parent_thread_id":"NOT-MINE"}}
    ;
    try testing.expectEqualStrings("", parseCodexParentId(not_meta, &buf));
    try testing.expectEqualStrings("", parseCodexParentId("", &buf));
}

test "codex rollout 이름 판정: 접미사이고 앞이 구분자여야 한다" {
    try testing.expect(isCodexRolloutOf("rollout-2026-07-25T02-26-31-abc-123.jsonl", "abc-123"));
    // 앞이 구분자가 아니면 남의 파일이다(`Xabc-123` 이 `abc-123` 으로 읽히면 안 된다).
    try testing.expect(!isCodexRolloutOf("rollout-2026-07-25T02-26-31-Xabc-123.jsonl", "abc-123"));
    // 가운데에 있는 것도 아니다.
    try testing.expect(!isCodexRolloutOf("rollout-abc-123-more.jsonl", "abc-123"));
    try testing.expect(!isCodexRolloutOf("rollout-abc-123.txt", "abc-123"));
    try testing.expect(!isCodexRolloutOf("rollout-abc-123.jsonl", ""));
    // id 만으로 된 이름도 받는다(이름 규칙이 바뀌어도 id 가 맞으면 그 파일이다).
    try testing.expect(isCodexRolloutOf("abc-123.jsonl", "abc-123"));
}
