//! Codex/Claude가 로컬에 남긴 JSONL을 도크용 **세션 요약**으로 낮춘다.
//!
//! 이 모듈은 파일을 찾거나 열지 않는다. provider 포맷에서 사용자 세션인지와 표시 가능한 최소 metadata를
//! 추출하는 L2 경계라, 개인 transcript를 UI/worker/테스트가 각자 다르게 해석하지 않게 한다.

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처

pub const Provider = enum {
    claude,
    codex,

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
        };
    }
};

/// 재개할 때 **원래 세션의 권한 모드를 그대로 되살리기 위해** transcript 에서 읽어 두는 provider-native 값.
///
/// 중립 3단계로 뭉개지 않는다. Claude 는 축이 하나(`permissionMode`)고 Codex 는 둘(승인 정책 · 샌드박스)이라,
/// 뭉개면 되살린 세션이 원래와 **다른 권한**으로 뜬다 — 그게 이 값이 존재하는 이유 자체를 없앤다.
///
/// 모르는 철자는 `.unknown` 으로 떨어뜨리고 플래그를 **안 붙인다**. transcript 문자열을 그대로 argv 로
/// 흘리면 ① provider 가 철자를 바꾸는 날 재개가 통째로 실패하고 ② transcript 텍스트가 명령 인자가 되어
/// [agent-session-list.md §5](../../docs/agent-session-list.md) 의 "parse 한 내용은 실행 인자로 절대 넣지
/// 않는다" 가 깨진다. 여기서 enum 으로 받으면 argv 에 나가는 것은 **이 모듈의 리터럴**뿐이다.
pub const Permission = union(enum) {
    /// transcript 가 모드를 한 번도 말하지 않았다(옛 파일 · 손상 · 해당 줄이 잘림). provider 기본값으로 연다.
    unknown,
    claude: ClaudeMode,
    codex: CodexPolicy,
};

/// Claude Code `--permission-mode` 의 값. 필드 이름을 **CLI 철자 그대로** 둔다 — transcript 가 적는 철자와
/// CLI 가 받는 철자가 같아서(실측 2026-09-14), 사이에 번역표를 두면 쓸모 없이 그 표만 낡는다.
pub const ClaudeMode = enum {
    default,
    acceptEdits,
    auto,
    bypassPermissions,
    manual,
    dontAsk,
    plan,

    pub fn fromTranscript(text: []const u8) ?ClaudeMode {
        return std.meta.stringToEnum(ClaudeMode, text);
    }

    /// `--permission-mode` 에 실을 값. `default` 만 `null` 이다 — provider 기본값이라 붙일 이유가 없고,
    /// `claude --help` 의 choices 목록에도 없다(현재 판은 받아 주지만, 문서에 없는 관용에 기대면 그게
    /// 사라지는 날 재개가 죽는다). 붙이지 않는 쪽이 같은 결과이면서 약속에만 기댄다.
    pub fn flagValue(self: ClaudeMode) ?[]const u8 {
        return switch (self) {
            .default => null,
            .acceptEdits => "acceptEdits",
            .auto => "auto",
            .bypassPermissions => "bypassPermissions",
            .manual => "manual",
            .dontAsk => "dontAsk",
            .plan => "plan",
        };
    }
};

/// Codex rollout 의 `turn_context` 가 매 턴 싣는 두 축. 한쪽만 읽힐 수 있으므로 각각 optional 이다 —
/// 못 읽은 축에 기본값을 **채워 넣으면** 그 순간 "기록된 모드를 그대로" 가 거짓이 된다.
pub const CodexPolicy = struct {
    approval: ?CodexApproval = null,
    sandbox: ?CodexSandbox = null,
};

/// `codex --ask-for-approval` 의 값. rollout 은 하이픈(`on-request`)으로 적고 Zig enum 은 하이픈을 못 써서
/// 양방향 표가 불가피하다. 아래 왕복 테스트가 두 방향이 갈리는 것을 막는다.
pub const CodexApproval = enum {
    untrusted,
    on_failure,
    on_request,
    never,

    pub fn fromTranscript(text: []const u8) ?CodexApproval {
        if (std.mem.eql(u8, text, "untrusted")) return .untrusted;
        if (std.mem.eql(u8, text, "on-failure")) return .on_failure;
        if (std.mem.eql(u8, text, "on-request")) return .on_request;
        if (std.mem.eql(u8, text, "never")) return .never;
        return null;
    }

    pub fn flagValue(self: CodexApproval) []const u8 {
        return switch (self) {
            .untrusted => "untrusted",
            .on_failure => "on-failure",
            .on_request => "on-request",
            .never => "never",
        };
    }
};

/// `codex --sandbox` 의 값. rollout 은 `sandbox_policy.type` 에 같은 철자를 적는다.
///
/// `workspace_write` 의 하위 설정(쓰기 가능 root 목록 · 네트워크 허용)까지는 되살리지 못한다 — CLI 플래그
/// 하나로 표현되지 않고 config 파일 축이다. 그 한계는 docs 가 소유한다.
pub const CodexSandbox = enum {
    read_only,
    workspace_write,
    danger_full_access,

    pub fn fromTranscript(text: []const u8) ?CodexSandbox {
        if (std.mem.eql(u8, text, "read-only")) return .read_only;
        if (std.mem.eql(u8, text, "workspace-write")) return .workspace_write;
        if (std.mem.eql(u8, text, "danger-full-access")) return .danger_full_access;
        return null;
    }

    pub fn flagValue(self: CodexSandbox) []const u8 {
        return switch (self) {
            .read_only => "read-only",
            .workspace_write => "workspace-write",
            .danger_full_access => "danger-full-access",
        };
    }
};

/// 재개 argv 에 실을 수 있는 **모델 토큰**의 최대 길이. 실측된 값은 `claude-opus-5`(13)·`gpt-5.6-sol`(11)·
/// 별칭 `opus`(4) 수준이고, 이 선은 그보다 넉넉하면서 `model_buf`(= `max_title_bytes`) 안에 들어와
/// **잘린 값이 플래그로 나가는 일이 없게** 한다.
pub const max_model_bytes: usize = 64;

/// 재개 argv 에 실을 수 있는 **세션 id** 의 최대 길이. 실측은 전부 36 바이트 UUID 다(2026-09-15, Claude 300 ·
/// Codex 229 표본에서 예외 0). 그보다 넉넉히 잡는 이유는 Codex `resume` 이 UUID 말고 **세션 이름**도 받기
/// 때문이다 — 지금 우리가 읽는 `session_meta.payload.id` 는 UUID 지만, 그 자리에 이름이 오는 날
/// 전부를 못 쓰게 만들 이유는 없다. UUID 모양을 강제하지 않는 이유이기도 하다.
pub const max_session_id_bytes: usize = 128;

/// 이 텍스트를 **provider 플래그의 값으로** 그대로 넘겨도 되는가.
///
/// transcript 내용이 실행 인자가 되는 자리는 둘뿐이다(세션 id · 모델). 둘 다 같은 위험을 지므로 규칙도
/// 하나다 — 규칙이 둘이면 한쪽이 낡는다.
///
/// ⑴ **문자 집합**: 실측된 값이 쓰는 것뿐이다(`gpt-5.6-sol` 의 `.`, UUID 의 `-`). 셸 인용은 이미
///    호출자가 하지만(§6) 인용은 **셸**로부터 지킬 뿐 **provider 의 인자 파서**로부터 지키지 못한다.
/// ⑵ **첫 글자는 `-` 가 아니다**: `--model '-rf'` 는 셸에 안전하게 도착해도 provider 가 그것을 **플래그로**
///    읽는다. 값 자리에 오는 토큰이 플래그로 오인되면 우리가 의도한 것과 다른 명령이 선다.
/// ⑶ **길이 상한**: 호출자가 준다. 표시용 사본이 잘리는 선 아래여야 **잘린 값이 플래그로 나가지 않는다**.
fn isSafeArgvToken(text: []const u8, max_len: usize) bool {
    if (text.len == 0 or text.len > max_len) return false;
    if (text[0] == '-') return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// 이 텍스트가 재개 argv 에 실을 수 있는 모델 토큰인가.
///
/// **거를 것이 실재한다.** Claude Code 는 합성 assistant 줄에 `"model":"<synthetic>"` 를 적는다(사용자
/// 이력 표본 2026-09-15, 최근 60일 200개 파일에서 67건). 모델은 "마지막에 본 값"이 이기므로 그런 줄이
/// 마지막이면 그 값이 카드에도 뜨고 `--model '<synthetic>'` 로 재개까지 간다. 표시와 재개가 같은 필드를
/// 쓰므로 **거르는 자리도 하나**다 — 파서가 아예 기록하지 않는다.
///
/// 새 provider 가 다른 모양을 쓰기 시작하면 조용히 빠지는 게 아니라 `model` 이 비어 재개가 **기본 모델**로
/// 가고 카드에도 모델 줄이 안 뜬다 — 눈에 보이는 실패다.
pub fn isResumableModel(text: []const u8) bool {
    return isSafeArgvToken(text, max_model_bytes);
}

/// 이 텍스트가 재개 argv 에 실을 수 있는 세션 id 인가.
///
/// 못 쓰는 id 는 **그 세션을 목록에 넣지 않는** 사유다. 모델과 다른 판단인데, 이유는 그 값이 하는 일이
/// 다르기 때문이다 — 모델은 없으면 기본값으로 열리지만, **id 는 그 세션을 가리키는 유일한 손잡이**라
/// 못 쓰면 재개도 exact-live 대조도 성립하지 않는다. 파서는 이미 빈 id 를 같은 이유로 떨어뜨리고
/// 있었고(`finishClaude`·`finishCodex`), 이것은 그 규율을 "빈 값"에서 "못 가리키는 값"으로 넓힌 것이다.
pub fn isResumableSessionId(text: []const u8) bool {
    return isSafeArgvToken(text, max_session_id_bytes);
}

pub const max_title_bytes: usize = 120;
pub const max_summary_bytes: usize = 240;
pub const max_cwd_bytes: usize = 1024;

/// Scanner가 파일 identity/mtime을 붙이기 전의 provider-neutral 요약.
/// 모든 텍스트는 allocator-owned이고 `deinit`이 단일 회수점이다.
pub const Parsed = struct {
    provider: Provider,
    session_id: []u8,
    title: []u8,
    summary: []u8,
    cwd: []u8,
    /// Set only by the worker after this provider value resolves to a local
    /// directory.  Raw JSONL cwd text must never be used for scoped
    /// containment because it can be deleted, remote, or a lexical alias.
    cwd_canonical: bool = false,
    model: []u8,
    message_count: u32,
    verified_user: bool,
    /// transcript가 스스로 말하는 마지막 활동 시각(Unix epoch 나노초). 0이면 이 파일에서 하나도 읽지
    /// 못했다는 뜻이고, 호출자가 파일 mtime으로 폴백한다.
    ///
    /// mtime은 대화 외의 이유(복사·도구의 메타 갱신·백업 복원)로도 밀린다. 실측(2026-08-08, 로컬 이력
    /// 362개)에서 mtime으로 정렬하면 257개(70%)가 제자리가 아니었고 Claude 쪽 최대 차이는 144시간이었다.
    last_activity_ns: i96 = 0,
    /// 이 세션이 **마지막으로 돌던 권한 모드**. 재개 argv 가 이것을 그대로 되살린다(`resumeArgv`).
    /// 세션 도중에 모드가 바뀔 수 있으므로(실측: 한 파일 안에 `default`·`plan`·`bypassPermissions` 가
    /// 섞인다) "마지막에 본 값"이 규칙이다 — 재개는 그 다음 턴을 잇는 것이지 첫 턴을 잇는 것이 아니다.
    permission: Permission = .unknown,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.free(self.summary);
        allocator.free(self.cwd);
        allocator.free(self.model);
        self.* = undefined;
    }

    pub fn clone(self: *const Parsed, allocator: std.mem.Allocator) !Parsed {
        var out = try duplicateParsed(allocator, self.provider, self.session_id, self.title, self.summary, self.cwd, self.cwd_canonical, self.model, self.message_count, self.verified_user);
        // `duplicateParsed`는 **인자로 받은 것만** 세운다. Parsed에 스칼라를 더하면 여기에도 더해야
        // 한다 — 캐시 히트와 부분 진행 발행이 모두 이 clone을 지나므로, 빠뜨리면 그 값만 조용히 0이
        // 된다. 아래 "clone은 모든 필드를 보존한다" 테스트가 comptime으로 전 필드를 훑어 막는다.
        out.last_activity_ns = self.last_activity_ns;
        out.permission = self.permission;
        return out;
    }
};

/// Claude 직속 transcript 혹은 Codex rollout 한 파일의 bounded bytes를 분석한다.
/// `null`은 손상/worker/legacy-unknown/무식별 세션으로, 호출자가 목록에 넣지 않아야 한다.
/// 한 파일을 **줄 단위로** 소비해 요약을 만드는 파서.
///
/// 호출자가 파일 전체를 메모리에 올릴 필요가 없다는 것이 요점이다. 예전에는 스캐너가
/// `allocator.alloc(u8, size)`로 파일을 통째로 읽어 넘겼고(피크 463 MB 실측), 그 할당을 방어하려고
/// 파일당·refresh당 read cap이 존재했다. 파서 자체는 처음부터 `splitScalar`로 줄을 훑고 있었으므로
/// 전체 버퍼를 요구한 것은 파서가 아니라 호출자였다 — 이 인터페이스가 그 요구를 없앤다.
///
/// 상태는 고정 버퍼뿐이라 파일 크기와 무관하게 일정하다(약 3 KB).
pub const Parser = struct {
    allocator: std.mem.Allocator,
    provider: Provider,

    session_id_buf: [max_cwd_bytes]u8 = undefined,
    cwd_buf: [max_cwd_bytes]u8 = undefined,
    model_buf: [max_title_bytes]u8 = undefined,
    title_buf: [max_title_bytes]u8 = undefined,
    first_user_buf: [max_summary_bytes]u8 = undefined,
    last_user_buf: [max_summary_bytes]u8 = undefined,
    last_assistant_buf: [max_summary_bytes]u8 = undefined,

    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: []const u8 = "",
    title: []const u8 = "",
    first_user: []const u8 = "",
    last_user: []const u8 = "",
    last_assistant: []const u8 = "",
    count: u32 = 0,

    // Codex 전용 판정 상태. `is_user`는 `session_meta`를 만날 때마다 갱신되며 **마지막 값이 이긴다**
    // (docs/agent-session-list.md §3.1).
    saw_meta: bool = false,
    is_user: bool = false,
    /// 이 파일에서 `user` 신호를 한 번이라도 봤는가. 조기 중단 판정에만 쓴다 — 한 번 본 뒤에는 뒤에
    /// 오는 worker 메타로 뒤집어 중단하지 않는다.
    saw_user_signal: bool = false,
    /// 이 파일에서 본 **가장 늦은** timestamp. 마지막으로 본 값이 아니라 최댓값을 쓴다 — 줄 순서가
    /// 시간 순이라는 보장이 없고(요약·메타 줄이 뒤에 붙는 형식이 있다), "마지막 활동"은 순서가 아니라
    /// 시각으로 정해야 한다.
    last_activity_ns: i96 = 0,
    /// **마지막에 본** 권한 모드(`Parsed.permission` 참조). 최댓값이 아니라 마지막 값인 것이
    /// `last_activity_ns` 와 다른 점이다 — 모드에는 순서 말고 비교할 축이 없다.
    permission: Permission = .unknown,

    pub fn init(allocator: std.mem.Allocator, provider: Provider) Parser {
        return .{ .allocator = allocator, .provider = provider };
    }

    /// 줄 하나를 소비한다. 손상된 줄은 그 줄만 버리고 record를 추측해 만들지 않는다.
    pub fn consumeLine(self: *Parser, line: []const u8) void {
        switch (self.provider) {
            .claude => self.consumeClaudeLine(line),
            .codex => self.consumeCodexLine(line),
        }
    }

    /// 두 provider 모두 각 줄 최상위에 `timestamp`를 싣는다. provider별 소비 함수가 이미 JSON을 열었으므로
    /// 거기서 이 값을 함께 넘긴다 — 정렬 하나 때문에 같은 줄을 두 번 파싱하지 않는다.
    fn observeTimestamp(self: *Parser, obj: std.json.ObjectMap) void {
        const text = string(obj.get("timestamp")) orelse return;
        const ns = parseRfc3339Utc(text) orelse return;
        if (ns > self.last_activity_ns) self.last_activity_ns = ns;
    }

    /// Codex worker로 **확정**됐는가. 확정은 "앞부분을 충분히 읽고도 `user` 신호를 한 번도 못 봤을 때"만
    /// 성립하므로, 호출자가 그 경계(§4-3)에서 한 번만 묻는다. 그 전에 물으면 `첫=subagent 마지막=user`인
    /// 정상 세션(실측 256개 중 118개)을 잘못 버린다.
    pub fn isWorkerSoFar(self: *const Parser) bool {
        return self.provider == .codex and self.saw_meta and !self.saw_user_signal;
    }

    pub fn finish(self: *Parser) !?Parsed {
        return switch (self.provider) {
            .claude => self.finishClaude(),
            .codex => self.finishCodex(),
        };
    }

    fn consumeClaudeLine(self: *Parser, line: []const u8) void {
        const root = parseObject(self.allocator, line) orelse return;
        defer root.deinit();
        const obj = root.value.object;
        self.observeTimestamp(obj);
        if (string(obj.get("sessionId"))) |value| self.session_id = copyInto(&self.session_id_buf, value);
        if (string(obj.get("cwd"))) |value| self.cwd = copyInto(&self.cwd_buf, value);
        if (string(obj.get("custom-title")) orelse string(obj.get("customTitle")) orelse string(obj.get("title"))) |value| {
            if (value.len > 0) self.title = copyInto(&self.title_buf, value);
        }
        // 권한 모드는 **user 줄에만** 실린다. 그래서 키가 없는 줄은 값을 건드리지 않고, 키가 있는데
        // 모르는 철자면 `.unknown` 으로 **되돌린다** — 옛 값을 남기면 provider 가 이름을 바꾼 뒤
        // "그때 그 모드"라며 낡은 권한으로 재개하게 된다. 모르면 안 쓰는 쪽이 안전한 방향이다.
        if (string(obj.get("permissionMode"))) |value| {
            self.permission = if (ClaudeMode.fromTranscript(value)) |mode| .{ .claude = mode } else .unknown;
        }
        const kind = string(obj.get("type")) orelse "";
        if (std.mem.eql(u8, kind, "ai-title")) {
            if (string(obj.get("aiTitle")) orelse string(obj.get("title")) orelse nestedString(obj, "message", "text")) |value| {
                if (value.len > 0) self.title = copyInto(&self.title_buf, value);
            }
        }
        const message = object(obj.get("message"));
        // Current Claude Code writes the invoked model on assistant
        // `message.model`; a top-level model is only a compatibility fallback.
        // 토큰 모양이 아닌 값은 **기록하지 않는다** — `<synthetic>` 이 실재하고, 마지막에 본 값이 이기므로
        // 안 거르면 카드와 재개 argv 에 그대로 실린다(`isResumableModel`).
        if ((if (message) |m| string(m.get("model")) else null) orelse string(obj.get("model"))) |value| {
            if (isResumableModel(value)) self.model = copyInto(&self.model_buf, value);
        }
        const role = if (message) |m| string(m.get("role")) orelse "" else string(obj.get("role")) orelse "";
        const text = if (message) |m| string(m.get("text")) orelse contentText(m) else string(obj.get("text"));
        if (text) |value| {
            if (value.len == 0) return;
            self.count +|= 1;
            if (std.mem.eql(u8, role, "user")) {
                if (self.first_user.len == 0) self.first_user = copyInto(&self.first_user_buf, value);
                self.last_user = copyInto(&self.last_user_buf, value);
            } else if (std.mem.eql(u8, role, "assistant")) self.last_assistant = copyInto(&self.last_assistant_buf, value);
        }
    }

    fn consumeCodexLine(self: *Parser, line: []const u8) void {
        const root = parseObject(self.allocator, line) orelse return;
        defer root.deinit();
        const obj = root.value.object;
        self.observeTimestamp(obj);
        const kind = string(obj.get("type")) orelse "";
        const payload = object(obj.get("payload"));
        if (std.mem.eql(u8, kind, "session_meta")) {
            const p = payload orelse return;
            self.saw_meta = true;
            if (string(p.get("id"))) |value| self.session_id = copyInto(&self.session_id_buf, value);
            if (string(p.get("cwd"))) |value| self.cwd = copyInto(&self.cwd_buf, value);
            self.is_user = codexIsUserThread(p);
            if (self.is_user) self.saw_user_signal = true;
            return;
        }
        if (std.mem.eql(u8, kind, "turn_context")) {
            if (payload) |p| {
                if (string(p.get("model"))) |value| {
                    if (isResumableModel(value)) self.model = copyInto(&self.model_buf, value);
                }
                // 두 축을 **이 줄에서 함께** 읽어 통째로 교체한다. 축을 따로 누적하면 승인 정책은 이번
                // 턴 것이고 샌드박스는 지난 턴 것인 조합이 생길 수 있는데, 그런 턴은 실재하지 않았다.
                self.permission = .{ .codex = .{
                    .approval = if (string(p.get("approval_policy"))) |value| CodexApproval.fromTranscript(value) else null,
                    .sandbox = if (object(p.get("sandbox_policy"))) |sandbox|
                        if (string(sandbox.get("type"))) |value| CodexSandbox.fromTranscript(value) else null
                    else
                        null,
                } };
            }
            return;
        }
        if (!std.mem.eql(u8, kind, "event_msg")) return;
        const p = payload orelse return;
        const event_kind = string(p.get("type")) orelse "";
        const text = string(p.get("message")) orelse return;
        if (text.len == 0) return;
        if (std.mem.eql(u8, event_kind, "user_message")) {
            const clean = stripCodexPrefix(text);
            if (clean.len == 0) return;
            self.count +|= 1;
            if (self.first_user.len == 0) self.first_user = copyInto(&self.first_user_buf, clean);
            self.last_user = copyInto(&self.last_user_buf, clean);
        } else if (std.mem.eql(u8, event_kind, "agent_message")) {
            self.count +|= 1;
            self.last_assistant = copyInto(&self.last_assistant_buf, text);
        }
    }

    fn finishClaude(self: *Parser) !?Parsed {
        if (!isResumableSessionId(self.session_id)) return null;
        const display_title = if (self.title.len > 0) self.title else if (self.first_user.len > 0) self.first_user else i18n.t(.arch_untitled);
        const summary = if (self.last_user.len > 0) self.last_user else self.last_assistant;
        var parsed = try duplicateParsed(self.allocator, .claude, self.session_id, display_title, summary, self.cwd, false, self.model, self.count, true);
        parsed.last_activity_ns = self.last_activity_ns;
        parsed.permission = self.permission;
        return parsed;
    }

    fn finishCodex(self: *Parser) !?Parsed {
        if (!self.saw_meta or !self.is_user or !isResumableSessionId(self.session_id)) return null;
        const title = if (self.first_user.len > 0) self.first_user else i18n.t(.arch_untitled);
        const summary = if (self.last_user.len > 0) self.last_user else self.last_assistant;
        var parsed = try duplicateParsed(self.allocator, .codex, self.session_id, title, summary, self.cwd, false, self.model, self.count, true);
        parsed.last_activity_ns = self.last_activity_ns;
        parsed.permission = self.permission;
        return parsed;
    }
};

/// 재개 argv 가 가질 수 있는 최대 토큰 수 — `codex resume <id> --ask-for-approval <v> --sandbox <v>` 가 7 로
/// 가장 길다. 버퍼 크기를 호출자가 직접 세지 않게 여기가 소유한다.
pub const max_resume_argv: usize = 9;

/// 이 세션을 **원래 권한 모드 그대로** 재개하는 provider-native argv 를 만든다.
///
/// 할당하지 않는다 — 호출자가 준 버퍼를 채우고 그 앞부분을 돌려준다. 그래서 실패 경로가 없고, 토큰은
/// 전부 이 모듈의 정적 리터럴이거나 `parsed` 가 소유한 session id 뿐이다(§5: parse 한 내용은 실행 인자로
/// 넣지 않는다 — session id 만이 예외이고 그건 provider 가 우리에게 준 식별자다).
///
/// 모드를 모르면(`.unknown`) 플래그를 **안 붙인다**. 그러면 provider 자신의 기본값으로 열리는데, 이는
/// 이 기능이 생기기 전의 동작과 같다 — 새 정보가 없을 때 옛 동작으로 떨어지는 것이 안전한 방향이다.
/// 모델도 함께 싣는다 — 두 provider 다 `--model` 을 받는다(`claude --model <name|alias>`,
/// `codex resume <id> --model <MODEL>`). 안 실으면 Opus 로 돌던 세션을 이어할 때 기본 모델로 떨어진다.
/// `parsed.model` 은 파서가 `isResumableModel` 을 통과시킨 값만 담으므로 여기서 다시 재지 않는다.
///
/// 기록된 모델이 지금은 없는 id 일 수 있다(실측: 사용자 Codex 이력에 `maru-nonexistent-model-xyz`).
/// 그 경우 provider 가 스스로 거절하고, **재개가 끝나도 터미널은 남으므로** 사용자가 그 오류를 보고
/// 바로 다시 친다 — 조용히 사라지지 않는다.
pub fn resumeArgv(parsed: *const Parsed, out: *[max_resume_argv][]const u8) [][]const u8 {
    return resumeArgvFor(.{
        .provider = parsed.provider,
        .session_id = parsed.session_id,
        .permission = parsed.permission,
        .model = parsed.model,
    }, out);
}

/// 재개 argv 의 입력 넷. `Parsed` 전체가 없는 자리도 **같은 조립**을 쓰게 하려고 떼어 냈다 — 재부팅 부활(RB2)은
/// 대화 파일의 끝부분만 읽으므로 제목·요약·cwd 가 없다. 조립 규칙이 두 벌이면 「기록된 대로 되살린다」가 한쪽에서
/// 조용히 빠진다.
pub const ResumeTarget = struct {
    provider: Provider,
    session_id: []const u8,
    permission: Permission = .unknown,
    model: []const u8 = "",
};

/// `resumeArgv` 의 본체. 규칙은 위 주석 그대로다(모르는 모드·빈 모델이면 플래그를 안 붙인다).
pub fn resumeArgvFor(target: ResumeTarget, out: *[max_resume_argv][]const u8) [][]const u8 {
    var n: usize = 0;
    switch (target.provider) {
        .claude => {
            out[0] = "claude";
            out[1] = "--resume";
            out[2] = target.session_id;
            n = 3;
            if (target.permission == .claude) {
                if (target.permission.claude.flagValue()) |value| {
                    out[n] = "--permission-mode";
                    out[n + 1] = value;
                    n += 2;
                }
            }
            if (target.model.len > 0) {
                out[n] = "--model";
                out[n + 1] = target.model;
                n += 2;
            }
        },
        .codex => {
            out[0] = "codex";
            out[1] = "resume";
            out[2] = target.session_id;
            n = 3;
            if (target.permission == .codex) {
                const policy = target.permission.codex;
                if (policy.approval) |approval| {
                    out[n] = "--ask-for-approval";
                    out[n + 1] = approval.flagValue();
                    n += 2;
                }
                if (policy.sandbox) |sandbox| {
                    out[n] = "--sandbox";
                    out[n + 1] = sandbox.flagValue();
                    n += 2;
                }
            }
            if (target.model.len > 0) {
                out[n] = "--model";
                out[n + 1] = target.model;
                n += 2;
            }
        },
    }
    return out[0..n];
}

/// 재부팅 부활(RB2)이 대화 파일에서 읽는 것은 **파일 끝부분**뿐이다 — 복원은 창을 그리기 전에 돌고 대화 파일은
/// 수백 MB 일 수 있다. 재개가 이어야 할 것은 **마지막** 권한 모드와 모델이므로 끝부분에 있다(도크 규칙: 마지막에
/// 본 값이 이긴다). 끝부분에 없으면 unknown·빈 모델로 남고, 그러면 플래그 없이 provider 기본값으로 연다.
pub const resume_tail_bytes: usize = 1024 * 1024;

/// 끝부분의 **온전한 줄들**을 `parser` 에 먹인다. 결과는 `parser.permission`·`parser.model` 이다(모델은 parser
/// 버퍼를 빌리므로 parser 가 사는 동안만 유효).
///
/// - 끝부분은 `agent_transcript.readTail` 로 읽는다 — 「중간에서 잘라 읽었으면 첫 줄을 버린다」는 **그 함수 하나가
///   소유한다**(대화 줄과 같은 규칙; 두 벌이면 갈린다). 여기서는 다시 자르지 않는다.
/// - `finish` 를 거치지 않는다. codex 는 `session_meta` 가 파일 **머리**에만 있어 끝부분에는 없고, `finish` 는
///   그것이 없으면 세션을 버린다. 필요한 두 값(`turn_context` 의 모드·모델)은 그것 없이도 읽힌다.
pub fn feedResumeTail(parser: *Parser, tail: []const u8) void {
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |line| parser.consumeLine(line);
}

/// RFC 3339 UTC 시각(`YYYY-MM-DDTHH:MM:SS[.fff]Z`)을 Unix epoch 나노초로 바꾼다. 형태가 조금이라도
/// 다르면 **추측하지 않고** null을 돌려 호출자가 mtime으로 폴백하게 한다 — 틀린 시각으로 정렬하느니
/// 파일 시각이 낫다.
///
/// 실측(2026-08-08): 두 provider의 timestamp 200,025건이 모두 밀리초 3자리 `Z` 한 형태였다. 그래도
/// 소수부는 없거나 최대 9자리까지 받는다. 형태가 하나뿐이라고 파서를 그 하나에 못 박으면 provider가
/// 자릿수를 바꾸는 날 목록 순서가 조용히 mtime으로 돌아간다.
pub fn parseRfc3339Utc(text: []const u8) ?i96 {
    // `YYYY-MM-DDTHH:MM:SSZ`가 최소 형태다.
    if (text.len < 20 or text[text.len - 1] != 'Z') return null;
    if (text[4] != '-' or text[7] != '-' or text[13] != ':' or text[16] != ':') return null;
    if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return null;

    const year = twoWayInt(text[0..4]) orelse return null;
    const month = twoWayInt(text[5..7]) orelse return null;
    const day = twoWayInt(text[8..10]) orelse return null;
    const hour = twoWayInt(text[11..13]) orelse return null;
    const minute = twoWayInt(text[14..16]) orelse return null;
    // 윤초(60)를 허용한다. 거부하면 그 한 줄 때문에 파일 전체가 mtime으로 떨어진다.
    const second = twoWayInt(text[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var nanos: i96 = 0;
    const fraction = text[19 .. text.len - 1];
    if (fraction.len > 0) {
        if (fraction[0] != '.' or fraction.len > 10) return null;
        var scale: i96 = std.time.ns_per_s;
        for (fraction[1..]) |digit| {
            if (digit < '0' or digit > '9') return null;
            scale = @divTrunc(scale, 10);
            nanos += @as(i96, digit - '0') * scale;
        }
    }

    const days = daysFromCivil(year, month, day);
    const secs: i96 = days * std.time.s_per_day + @as(i96, hour) * 3600 + @as(i96, minute) * 60 + second;
    return secs * std.time.ns_per_s + nanos;
}

fn twoWayInt(text: []const u8) ?i32 {
    var value: i32 = 0;
    for (text) |digit| {
        if (digit < '0' or digit > '9') return null;
        value = value * 10 + (digit - '0');
    }
    return value;
}

/// 그레고리력 날짜를 1970-01-01 기준 일수로. Howard Hinnant의 `days_from_civil`이며 윤년·세기 규칙을
/// 분기 없이 처리한다.
fn daysFromCivil(year: i32, month: i32, day: i32) i96 {
    const y: i96 = @as(i96, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (@as(i96, month) + (if (month > 2) @as(i96, -3) else 9)) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// 버퍼 하나를 통째로 받는 진입점. `Parser`를 줄 단위로 돌린 것과 **결과가 같다** — fixture·테스트와
/// 부분 입력 비교가 이 등가성에 의존한다.
pub fn parse(allocator: std.mem.Allocator, provider: Provider, bytes: []const u8) !?Parsed {
    var parser = Parser.init(allocator, provider);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| parser.consumeLine(line);
    return parser.finish();
}

fn duplicateParsed(allocator: std.mem.Allocator, provider: Provider, session_id: []const u8, title: []const u8, summary: []const u8, cwd: []const u8, cwd_canonical: bool, model: []const u8, message_count: u32, verified_user: bool) !Parsed {
    // 필드 초기화식 안에 `try`를 늘어놓으면 앞서 성공한 dupe를 되돌릴 자리가 없다 — 뒤쪽 할당이
    // 실패할 때마다 문자열이 통째로 샜다. 한 단계씩 잡고 각자 errdefer를 건다.
    const session_copy = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_copy);
    const title_copy = try displayCopy(allocator, title, max_title_bytes);
    errdefer allocator.free(title_copy);
    const summary_copy = try displayCopy(allocator, summary, max_summary_bytes);
    errdefer allocator.free(summary_copy);
    const cwd_copy = try displayCopy(allocator, cwd, max_cwd_bytes);
    errdefer allocator.free(cwd_copy);
    const model_copy = try displayCopy(allocator, model, max_title_bytes);
    return .{
        .provider = provider,
        .session_id = session_copy,
        .title = title_copy,
        .summary = summary_copy,
        .cwd = cwd_copy,
        .cwd_canonical = cwd_canonical,
        .model = model_copy,
        .message_count = message_count,
        .verified_user = verified_user,
    };
}

fn displayCopy(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    var cleaned: [max_cwd_bytes]u8 = undefined;
    var n: usize = 0;
    for (text) |byte| {
        if (n == max_len or n == cleaned.len) break;
        const normalized = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        cleaned[n] = normalized;
        n += 1;
    }
    return allocator.dupe(u8, std.mem.trim(u8, cleaned[0..n], " \t\r\n"));
}

fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

fn parseObject(allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(std.json.Value) {
    if (line.len < 2 or line[0] != '{') return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

fn object(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn nestedString(obj: std.json.ObjectMap, key: []const u8, nested: []const u8) ?[]const u8 {
    const child = object(obj.get(key)) orelse return null;
    return string(child.get(nested));
}

fn contentText(obj: std.json.ObjectMap) ?[]const u8 {
    const content = obj.get("content") orelse return null;
    return switch (content) {
        .string => |text| text,
        .array => |items| for (items.items) |item| {
            const part = object(item) orelse continue;
            if (string(part.get("text"))) |text| break text;
        } else null,
        else => null,
    };
}

fn stripCodexPrefix(text: []const u8) []const u8 {
    const marker = "## My request for Codex:";
    const start = if (std.mem.indexOf(u8, text, marker)) |index| text[index + marker.len ..] else text;
    return std.mem.trim(u8, start, " \t\r\n");
}

/// Codex `session_meta.payload` 하나에서 "사용자 세션인가"를 판정한다(docs/agent-session-list.md §3.1).
///
/// 신호가 없으면 **포함**한다. `thread_source`는 최근 Codex가 추가한 필드라, 없다고 버리면 구버전에 남은
/// 실제 사용자 대화가 통째로 사라진다(실측: 개발자 머신에서 67개가 전부 사용자 대화였고 모두
/// `payload.id`를 갖고 있었다). 목록에서 조용히 사라진 세션은 사용자가 알아챌 방법이 없지만, worker가
/// 섞이면 보고 무시할 수 있다 — 그래서 기본을 "제외"가 아니라 "포함"으로 둔다.
///
/// 호출자는 `session_meta`를 만날 때마다 이 값을 갱신한다. **한 파일에 `session_meta`가 여러 번 나오고**
/// (실측 256개 중 123개), 그중 118개는 첫 메타가 `subagent`지만 마지막이 `user`인 정상 세션이다.
/// 따라서 판정은 **마지막으로 관측한 메타**가 이긴다.
fn codexIsUserThread(payload: std.json.ObjectMap) bool {
    if (string(payload.get("thread_source")) orelse string(payload.get("threadSource"))) |value| {
        return std.mem.eql(u8, value, "user");
    }
    if (object(payload.get("source"))) |source| return object(source.get("subagent")) == null;
    return true;
}

// 스트리밍 소비가 **전체 버퍼 파싱과 같은 결과**를 내는가. 스캐너가 파일을 64 KiB 청크로 읽어
// `consumeLine`에 넘기므로, 줄이 청크 경계에 걸치거나 마지막 줄에 개행이 없어도 값을 잃으면 안 된다.
// 이 등가성이 깨지면 목록이 조용히 틀린 요약을 보인다.
test "Parser 스트리밍: 어떤 청크 경계로 잘라도 전체 파싱과 같다" {
    const a = std.testing.allocator;
    const fixtures = [_]struct { provider: Provider, bytes: []const u8 }{
        .{ .provider = .claude, .bytes =
        \\{"sessionId":"c-1","cwd":"/repo","type":"user","message":{"role":"user","content":[{"type":"text","text":"첫 요청"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"m-old","content":[{"type":"text","text":"응답1"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"m-new","content":[{"type":"text","text":"응답2"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"마지막 요청"}]}}
        },
        .{ .provider = .codex, .bytes =
        \\{"type":"session_meta","payload":{"id":"x-1","thread_source":"subagent"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"worker turn"}}
        \\{"type":"session_meta","payload":{"id":"x-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt-x"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"사용자 요청"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"응답"}}
        },
    };

    for (fixtures) |fx| {
        var whole = (try parse(a, fx.provider, fx.bytes)).?;
        defer whole.deinit(a);

        // 1바이트부터 전체 길이까지 모든 청크 크기로 잘라 넣어도 결과가 같아야 한다. 줄 중간, 개행
        // 직전/직후 등 모든 경계가 이 스윕에 포함된다.
        var chunk: usize = 1;
        while (chunk <= fx.bytes.len) : (chunk += 1) {
            var parser = Parser.init(a, fx.provider);
            var pending: std.ArrayList(u8) = .empty;
            defer pending.deinit(a);
            var offset: usize = 0;
            while (offset < fx.bytes.len) {
                const end = @min(offset + chunk, fx.bytes.len);
                var rest: []const u8 = fx.bytes[offset..end];
                offset = end;
                while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                    const piece = rest[0..nl];
                    rest = rest[nl + 1 ..];
                    if (pending.items.len == 0) {
                        parser.consumeLine(piece);
                    } else {
                        try pending.appendSlice(a, piece);
                        parser.consumeLine(pending.items);
                        pending.clearRetainingCapacity();
                    }
                }
                if (rest.len > 0) try pending.appendSlice(a, rest);
            }
            if (pending.items.len > 0) parser.consumeLine(pending.items); // 개행 없는 마지막 줄
            var streamed = (try parser.finish()).?;
            defer streamed.deinit(a);

            try std.testing.expectEqualStrings(whole.session_id, streamed.session_id);
            try std.testing.expectEqualStrings(whole.title, streamed.title);
            try std.testing.expectEqualStrings(whole.summary, streamed.summary);
            try std.testing.expectEqualStrings(whole.cwd, streamed.cwd);
            try std.testing.expectEqualStrings(whole.model, streamed.model);
            try std.testing.expectEqual(whole.message_count, streamed.message_count);
        }
    }
}

// Codex worker 조기 중단 판정. 스캐너는 앞부분을 충분히 읽은 **뒤 한 번만** 이 값을 묻는다 — 그 전에
// 물으면 `첫=subagent 마지막=user`인 정상 세션(실측 256개 중 118개)을 잘못 버린다.
test "Parser: worker 확정은 user 신호를 한 번도 못 봤을 때만" {
    const a = std.testing.allocator;

    // 첫 메타가 subagent여도, user 신호를 본 뒤에는 worker로 확정하지 않는다.
    var flip = Parser.init(a, .codex);
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"subagent"}}
    );
    try std.testing.expect(flip.isWorkerSoFar()); // 아직 user를 못 봤다
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"user"}}
    );
    try std.testing.expect(!flip.isWorkerSoFar()); // user를 봤으니 확정하지 않는다
    // 뒤에 다시 worker 메타가 와도 뒤집어 중단하지 않는다(읽기를 끝까지 하고 finish가 판정한다).
    flip.consumeLine(
        \\{"type":"session_meta","payload":{"id":"f","thread_source":"subagent"}}
    );
    try std.testing.expect(!flip.isWorkerSoFar());

    // 메타를 아직 못 본 파일은 worker로 확정하지 않는다 — 판정 불가는 제외가 아니다.
    var none = Parser.init(a, .codex);
    none.consumeLine(
        \\{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    );
    try std.testing.expect(!none.isWorkerSoFar());

    // Claude는 이 판정의 대상이 아니다.
    var claude = Parser.init(a, .claude);
    claude.consumeLine(
        \\{"sessionId":"c","type":"user","message":{"role":"user","text":"x"}}
    );
    try std.testing.expect(!claude.isWorkerSoFar());
}

// 정렬 키가 여기서 나온다. 형태를 잘못 읽으면 목록 순서가 조용히 틀리고, 거부해야 할 것을 받아들이면
// 엉뚱한 시각으로 정렬된다 — 둘 다 눈에 잘 띄지 않으므로 경계를 고정한다.
test "parseRfc3339Utc: epoch 변환과 거부 경계" {
    // 기준점들. epoch, 윤년(2000은 400의 배수라 윤년), 세기 비윤년(1900), 실측 형태.
    try std.testing.expectEqual(@as(?i96, 0), parseRfc3339Utc("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(?i96, 1_000_000_000 * std.time.ns_per_s), parseRfc3339Utc("2001-09-09T01:46:40Z"));
    try std.testing.expectEqual(@as(?i96, 951_782_400 * std.time.ns_per_s), parseRfc3339Utc("2000-02-29T00:00:00Z"));
    // 1900-03-01은 1900이 윤년이 아니어야 나오는 값이다(400 규칙).
    try std.testing.expectEqual(@as(?i96, -2_203_891_200 * std.time.ns_per_s), parseRfc3339Utc("1900-03-01T00:00:00Z"));

    // 실측 형태: 밀리초 3자리.
    try std.testing.expectEqual(
        @as(?i96, 1_754_652_783 * std.time.ns_per_s + 657 * std.time.ns_per_ms),
        parseRfc3339Utc("2025-08-08T11:33:03.657Z"),
    );
    // 소수부 자릿수는 provider가 바꿀 수 있다. 없는 것부터 나노초 9자리까지 받는다.
    try std.testing.expectEqual(@as(?i96, 1 * std.time.ns_per_s + 5 * std.time.ns_per_ms), parseRfc3339Utc("1970-01-01T00:00:01.005Z"));
    try std.testing.expectEqual(@as(?i96, 1 * std.time.ns_per_s + 123_456_789), parseRfc3339Utc("1970-01-01T00:00:01.123456789Z"));
    // 윤초를 거부하면 그 한 줄 때문에 파일 전체가 mtime으로 떨어진다.
    try std.testing.expect(parseRfc3339Utc("2016-12-31T23:59:60Z") != null);

    // 거부: 추측하지 않는다. 잘못 읽은 시각으로 정렬하느니 mtime이 낫다.
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03")); // Z 없음
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03+09:00")); // 오프셋
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08 11:33Z")); // 짧음
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-13-08T11:33:03Z")); // 13월
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T24:33:03Z")); // 24시
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("20xx-08-08T11:33:03Z")); // 숫자 아님
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc("2025-08-08T11:33:03.1234567890Z")); // 소수 10자리
    try std.testing.expectEqual(@as(?i96, null), parseRfc3339Utc(""));
}

// 정렬 키는 "마지막으로 본 줄"이 아니라 **가장 늦은 시각**이다. 요약·메타 줄이 뒤에 붙는 형식에서
// 마지막 줄의 시각이 더 이르면 세션이 목록 아래로 잘못 밀린다.
test "Parser: last_activity_ns는 줄 순서가 아니라 최댓값을 따른다" {
    const a = std.testing.allocator;
    var parsed = (try parse(a, .claude,
        \\{"sessionId":"s-1","cwd":"/repo","type":"user","timestamp":"2025-08-08T10:00:00Z","message":{"role":"user","text":"첫"}}
        \\{"type":"assistant","timestamp":"2025-08-08T12:00:00Z","message":{"role":"assistant","text":"응답"}}
        \\{"type":"summary","timestamp":"2025-08-08T11:00:00Z"}
        \\{"type":"assistant","message":{"role":"assistant","text":"시각 없는 줄"}}
    )).?;
    defer parsed.deinit(a);
    try std.testing.expectEqual(parseRfc3339Utc("2025-08-08T12:00:00Z").?, parsed.last_activity_ns);

    // 하나도 읽지 못하면 0으로 남아 호출자가 mtime으로 폴백한다.
    var none = (try parse(a, .claude,
        \\{"sessionId":"s-2","type":"user","message":{"role":"user","text":"시각 없음"}}
    )).?;
    defer none.deinit(a);
    try std.testing.expectEqual(@as(i96, 0), none.last_activity_ns);
}

// clone이 필드 하나를 빠뜨리면 캐시 히트와 부분 진행 발행에서만 값이 사라진다 — 첫 스캔은 멀쩡하고
// 두 번째부터 틀리므로 눈으로 잡기 어렵다. 필드 목록을 comptime으로 훑어 새 필드가 자동으로 검사에
// 들어오게 한다.
test "clone은 Parsed의 모든 필드를 보존한다" {
    const a = std.testing.allocator;
    var origin = try duplicateParsed(a, .codex, "s-1", "제목", "요약", "/repo", true, "gpt-x", 42, true);
    defer origin.deinit(a);
    origin.last_activity_ns = 1_234_567_890_123_456_789;
    // 기본값(.unknown)으로 두면 clone 이 이 필드를 안 옮겨도 테스트가 통과한다 — 감시하려는 것이
    // "옮겼는가"이므로 **기본값이 아닌 값**을 넣어야 한다.
    origin.permission = .{ .codex = .{ .approval = .never, .sandbox = .danger_full_access } };

    var copy = try origin.clone(a);
    defer copy.deinit(a);

    inline for (@typeInfo(Parsed).@"struct".fields) |field| {
        const lhs = @field(origin, field.name);
        const rhs = @field(copy, field.name);
        const is_text = comptime blk: {
            const info = @typeInfo(field.type);
            break :blk info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
        };
        if (comptime is_text) {
            try std.testing.expectEqualStrings(lhs, rhs);
        } else {
            try std.testing.expectEqual(lhs, rhs);
        }
    }
}

test "Codex user session parses and worker is rejected" {
    const user =
        \\{"type":"session_meta","payload":{"id":"codex-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt-test"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"## My request for Codex: fix it"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
    ;
    var parsed = (try parse(std.testing.allocator, .codex, user)).?;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("codex-1", parsed.session_id);
    try std.testing.expectEqualStrings("fix it", parsed.title);
    try std.testing.expectEqual(@as(u32, 2), parsed.message_count);
    try std.testing.expect(!parsed.cwd_canonical); // worker boundary owns filesystem canonicalization

    const worker = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"thread_source\":\"subagent\"}}\n";
    try std.testing.expect((try parse(std.testing.allocator, .codex, worker)) == null);
}

test "Codex worker 판정: 신호 순서와 마지막 session_meta 우선" {
    const a = std.testing.allocator;

    // ① thread_source가 있으면 그 값이 이긴다.
    const explicit_worker = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"thread_source\":\"subagent\"}}\n";
    try std.testing.expect((try parse(a, .codex, explicit_worker)) == null);

    // ② 필드가 없으면 2차 신호 source.subagent로 가른다.
    const source_worker =
        \\{"type":"session_meta","payload":{"id":"x","source":{"subagent":{"name":"w"}}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"hi"}}
    ;
    try std.testing.expect((try parse(a, .codex, source_worker)) == null);

    // ③ 둘 다 없으면 **사용자 세션으로 포함**한다. 구버전 Codex가 여기 해당하며, 예전에는 통째로
    //    버려졌다(실측 67개 소실). 목록에서 조용히 사라지는 쪽이 worker가 섞이는 쪽보다 나쁘다.
    const legacy =
        \\{"type":"session_meta","payload":{"id":"legacy-1","cwd":"/repo"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"오래된 요청"}}
    ;
    var legacy_parsed = (try parse(a, .codex, legacy)).?;
    defer legacy_parsed.deinit(a);
    try std.testing.expectEqualStrings("legacy-1", legacy_parsed.session_id);
    try std.testing.expectEqualStrings("오래된 요청", legacy_parsed.title);

    // ④ source는 있지만 subagent 키가 없으면 worker가 아니다.
    const source_not_worker =
        \\{"type":"session_meta","payload":{"id":"s1","source":{"cli":{}}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
    ;
    var s1 = (try parse(a, .codex, source_not_worker)).?;
    defer s1.deinit(a);
    try std.testing.expectEqualStrings("s1", s1.session_id);

    // ⑤ **마지막 session_meta가 이긴다.** 한 파일에 메타가 여러 번 나오고 첫 것이 subagent, 마지막이
    //    user인 경우가 실측 256개 중 118개다. 첫 메타로 확정하면 그 118개가 전부 사라진다.
    const flip =
        \\{"type":"session_meta","payload":{"id":"f1","thread_source":"subagent"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"worker turn"}}
        \\{"type":"session_meta","payload":{"id":"f1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"사용자 요청"}}
    ;
    var flipped = (try parse(a, .codex, flip)).?;
    defer flipped.deinit(a);
    try std.testing.expectEqualStrings("f1", flipped.session_id);
    try std.testing.expectEqualStrings("사용자 요청", flipped.summary);

    // ⑥ 반대 방향도 마지막이 이긴다 — user로 시작해 worker로 끝나면 제외다.
    const flip_back =
        \\{"type":"session_meta","payload":{"id":"f2","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
        \\{"type":"session_meta","payload":{"id":"f2","thread_source":"subagent"}}
    ;
    try std.testing.expect((try parse(a, .codex, flip_back)) == null);

    // ⑦ session_meta가 아예 없으면 식별 근거가 없어 제외한다(포함 기본값의 예외).
    const no_meta = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"고아\"}}\n";
    try std.testing.expect((try parse(a, .codex, no_meta)) == null);
}

test "Claude 파서: content 배열·모델 변경·손상 줄·개행 없는 마지막 줄" {
    const a = std.testing.allocator;

    // message.text가 없고 content 배열만 있는 형태(실제 Claude transcript의 주 형태).
    // 손상된 줄은 그 줄만 버리고 나머지는 계속 읽는다 — record를 추측해 만들지 않는다.
    // 모델은 마지막으로 본 assistant message.model이 이긴다(세션 중 모델을 바꾸면 최신이 표시돼야 한다).
    // 마지막 줄에 개행이 없어도 값을 잃지 않는다.
    const fixture =
        \\{"sessionId":"c-1","cwd":"/repo","type":"user","message":{"role":"user","content":[{"type":"text","text":"첫 요청"}]}}
        \\{"type":"assistant","message":{"role":"assistant","model":"model-old","content":[{"type":"text","text":"응답1"}]}}
        \\이건 JSON이 아니다
        \\{"type":"assistant","message":{"role":"assistant","model":"model-new","content":[{"type":"text","text":"응답2"}]}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"마지막 요청"}]}}
    ;
    var parsed = (try parse(a, .claude, fixture)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("c-1", parsed.session_id);
    try std.testing.expectEqualStrings("첫 요청", parsed.title); // 명시 제목이 없으면 첫 사용자 메시지
    try std.testing.expectEqualStrings("마지막 요청", parsed.summary);
    try std.testing.expectEqualStrings("model-new", parsed.model);
    try std.testing.expectEqual(@as(u32, 4), parsed.message_count); // 손상 줄은 세지 않는다

    // sessionId가 없으면 안정 identity가 없으므로 제외한다.
    const no_id = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"text\":\"x\"}}\n";
    try std.testing.expect((try parse(a, .claude, no_id)) == null);
}

test "Claude title prefers explicit title then latest user summary" {
    const fixture =
        \\{"sessionId":"claude-1","cwd":"/repo","type":"ai-title","aiTitle":"명시 제목"}
        \\{"type":"user","message":{"role":"user","text":"첫 요청"}}
        \\{"type":"assistant","message":{"role":"assistant","model":"claude-test","text":"응답"}}
        \\{"type":"user","message":{"role":"user","text":"마지막 요청"}}
    ;
    var parsed = (try parse(std.testing.allocator, .claude, fixture)).?;
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("명시 제목", parsed.title);
    try std.testing.expectEqualStrings("마지막 요청", parsed.summary);
    try std.testing.expectEqualStrings("claude-test", parsed.model);
}

// 재개가 되살려야 하는 것은 세션 id 만이 아니다 — 권한 모드가 안 따라오면 `--dangerously-skip-permissions`
// 로 돌던 세션이 매 명령마다 묻는 세션으로 되살아난다(반대로도 마찬가지고, 그쪽이 더 위험하다).
// 아래 테스트들은 transcript 에서 그 모드를 읽는 규칙과, 그것이 argv 로 나가는 형태를 고정한다.

test "Claude 권한 모드: 마지막 턴의 값이 이기고 argv 에 실린다" {
    const a = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"c-1","cwd":"/repo","type":"user","permissionMode":"default","message":{"role":"user","text":"첫 요청"}}
        \\{"sessionId":"c-1","type":"assistant","message":{"role":"assistant","text":"답"}}
        \\{"sessionId":"c-1","type":"user","permissionMode":"bypassPermissions","message":{"role":"user","text":"두 번째 요청"}}
    ;
    var parsed = (try parse(a, .claude, jsonl)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqual(Permission{ .claude = .bypassPermissions }, parsed.permission);

    var buf: [max_resume_argv][]const u8 = undefined;
    const argv = resumeArgv(&parsed, &buf);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("--resume", argv[1]);
    try std.testing.expectEqualStrings("c-1", argv[2]);
    try std.testing.expectEqualStrings("--permission-mode", argv[3]);
    try std.testing.expectEqualStrings("bypassPermissions", argv[4]);
}

test "Claude 권한 모드: default 는 플래그를 안 붙이고, 모르는 철자는 옛 값을 지운다" {
    const a = std.testing.allocator;

    // `default` 는 provider 기본값이라 붙일 이유가 없다. `claude --help` 의 choices 에도 없다.
    const plain =
        \\{"sessionId":"c-2","type":"user","permissionMode":"default","message":{"role":"user","text":"요청"}}
    ;
    var parsed = (try parse(a, .claude, plain)).?;
    defer parsed.deinit(a);
    var buf: [max_resume_argv][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), resumeArgv(&parsed, &buf).len);

    // provider 가 새 철자를 도입하면 우리는 그 세션의 모드를 **모르는 것**이다. 앞 줄에서 본 옛 값을
    // 남기면 "그때 그 모드" 라며 틀린 권한으로 재개한다.
    const renamed =
        \\{"sessionId":"c-3","type":"user","permissionMode":"bypassPermissions","message":{"role":"user","text":"하나"}}
        \\{"sessionId":"c-3","type":"user","permissionMode":"someFutureMode","message":{"role":"user","text":"둘"}}
    ;
    var future = (try parse(a, .claude, renamed)).?;
    defer future.deinit(a);
    try std.testing.expectEqual(Permission.unknown, future.permission);
    try std.testing.expectEqual(@as(usize, 3), resumeArgv(&future, &buf).len);
}

// 재개는 모델도 되살린다. 안 그러면 Opus 로 돌던 세션을 이어할 때 기본 모델로 조용히 떨어진다.
// 아래 셋이 ⑴ 무엇을 모델로 인정하는지 ⑵ 그것이 표시와 argv 양쪽에 같은 값으로 가는지를 고정한다.

test "argv 토큰 규칙: 첫 자리는 «허용된 64 개», 그 뒤는 65 개다" {
    // 「금지된 모양이 없다」로 재면 갈아입을 때마다 샌다. 허용된 자리를 **세어** 못 박는다.
    // 두 자리를 따로 세는 것이 요점이다 — `-` 는 값 안에서는 쓰이지만(UUID·모델 이름) 맨 앞에 오면
    // provider 가 플래그로 읽는다.
    var first: usize = 0;
    var later: usize = 0;
    var byte: u8 = 0;
    while (true) : (byte += 1) {
        if (isResumableModel(&[_]u8{byte})) first += 1;
        if (isResumableModel(&[_]u8{ 'a', byte })) later += 1;
        if (byte == 255) break;
    }
    try std.testing.expectEqual(@as(usize, 26 + 26 + 10 + 2), first); // `-` 빠짐
    try std.testing.expectEqual(@as(usize, 26 + 26 + 10 + 3), later);
    try std.testing.expect(!isResumableModel("-rf"));
    try std.testing.expect(!isResumableSessionId("-x"));

    // 실측된 값들은 전부 통과한다(모델 별칭·UUID 세션 id 포함).
    for ([_][]const u8{ "claude-opus-5", "claude-fable-5-1", "opus", "gpt-5.6-sol", "gpt-6-astra" }) |value|
        try std.testing.expect(isResumableModel(value));
    for ([_][]const u8{ "b7078fe1-119e-4bd7-92c3-eee2a477922d", "fixture-codex-session" }) |value|
        try std.testing.expect(isResumableSessionId(value));

    // 길이 경계는 **자리마다 다르다**. 각자 상한까지는 통과하고 한 바이트만 넘어도 떨어진다 —
    // 그래야 잘린 값이 플래그로 안 나간다. 상한이 하나로 뭉치면 그 구분이 사라진다.
    const model_at = [_]u8{'a'} ** max_model_bytes;
    const model_over = [_]u8{'a'} ** (max_model_bytes + 1);
    try std.testing.expect(isResumableModel(&model_at));
    try std.testing.expect(!isResumableModel(&model_over));
    const id_at = [_]u8{'a'} ** max_session_id_bytes;
    const id_over = [_]u8{'a'} ** (max_session_id_bytes + 1);
    try std.testing.expect(isResumableSessionId(&id_at));
    try std.testing.expect(!isResumableSessionId(&id_over));
    // 세션 id 상한이 모델 상한보다 넓다는 것도 못 박는다 — 하나로 합치려는 변경이 여기서 걸린다.
    try std.testing.expect(!isResumableModel(&id_at));

    try std.testing.expect(!isResumableModel(""));
    try std.testing.expect(!isResumableSessionId(""));
}

test "가리킬 수 없는 세션 id 는 목록에 넣지 않는다 — 두 provider 다" {
    const a = std.testing.allocator;
    // `-` 로 시작하는 id 는 `--resume '-x'` 로 나가 provider 가 플래그로 읽는다. 셸 인용은 셸로부터만
    // 지켜 준다. 빈 id 를 떨어뜨리던 규율을 "못 가리키는 값"까지 넓힌 자리다.
    const claude_flagish =
        \\{"sessionId":"-x","cwd":"/repo","type":"user","message":{"role":"user","text":"요청"}}
    ;
    try std.testing.expect((try parse(a, .claude, claude_flagish)) == null);

    const codex_flagish =
        \\{"type":"session_meta","payload":{"id":"--repo","cwd":"/repo","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
    ;
    try std.testing.expect((try parse(a, .codex, codex_flagish)) == null);

    // 제어문자가 섞인 id 도 마찬가지다. 세션 id 는 표시용 정제(`displayCopy`)를 **안 거치고** 그대로
    // 복사되므로, 여기서 막지 않으면 어디에도 막는 자리가 없다.
    const claude_control =
        \\{"sessionId":"a\u0007b","cwd":"/repo","type":"user","message":{"role":"user","text":"요청"}}
    ;
    try std.testing.expect((try parse(a, .claude, claude_control)) == null);

    // 정상 UUID 는 그대로 통과한다 — 이 게이트가 실제 이력을 떨어뜨리지 않는다는 반대편 증거다.
    const ok =
        \\{"sessionId":"b7078fe1-119e-4bd7-92c3-eee2a477922d","cwd":"/repo","type":"user","message":{"role":"user","text":"요청"}}
    ;
    var parsed = (try parse(a, .claude, ok)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("b7078fe1-119e-4bd7-92c3-eee2a477922d", parsed.session_id);
}

test "모델 상한은 표시용 절단선 «안»이라야 한다 — 잘린 이름이 플래그로 나가면 안 된다" {
    const a = std.testing.allocator;
    // `Parsed.model` 은 표시용 사본이라 `max_title_bytes` 에서 잘린다. 그 선보다 긴 모델을 허용하면
    // **조용히 잘린 이름**이 `--model` 로 나간다 — 표시로는 견딜 만해도 argv 로는 틀린 값이다.
    // 그래서 상한까지의 모델이 파싱 왕복에서 **한 바이트도 안 변하는 것**을 제품 경로로 못 박는다.
    // (`max_model_bytes` 를 `max_title_bytes` 위로 올리면 여기서 깨진다.)
    const token = [_]u8{'m'} ** max_model_bytes;
    const jsonl = try std.fmt.allocPrint(
        a,
        "{{\"sessionId\":\"c-len\",\"type\":\"assistant\",\"message\":{{\"role\":\"assistant\",\"model\":\"{s}\",\"text\":\"답\"}}}}",
        .{token},
    );
    defer a.free(jsonl);
    var parsed = (try parse(a, .claude, jsonl)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings(&token, parsed.model);

    var buf: [max_resume_argv][]const u8 = undefined;
    const argv = resumeArgv(&parsed, &buf);
    try std.testing.expectEqualStrings("--model", argv[argv.len - 2]);
    try std.testing.expectEqualStrings(&token, argv[argv.len - 1]);
}

test "Claude 모델: <synthetic> 은 기록하지 않고 마지막 «진짜» 모델이 남는다" {
    const a = std.testing.allocator;
    // 실재하는 모양이다 — 사용자 이력 표본(2026-09-15, 최근 60일 200개 파일)에서 67건.
    // 마지막에 본 값이 이기는 규칙이라, 안 거르면 이 줄 때문에 카드와 argv 가 둘 다 오염된다.
    const jsonl =
        \\{"sessionId":"c-m","cwd":"/repo","type":"user","permissionMode":"plan","message":{"role":"user","text":"요청"}}
        \\{"sessionId":"c-m","type":"assistant","message":{"role":"assistant","model":"claude-opus-5","text":"답"}}
        \\{"sessionId":"c-m","type":"assistant","message":{"role":"assistant","model":"<synthetic>","text":"합성"}}
    ;
    var parsed = (try parse(a, .claude, jsonl)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("claude-opus-5", parsed.model);

    var buf: [max_resume_argv][]const u8 = undefined;
    const argv = resumeArgv(&parsed, &buf);
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("--permission-mode", argv[3]);
    try std.testing.expectEqualStrings("plan", argv[4]);
    try std.testing.expectEqualStrings("--model", argv[5]);
    try std.testing.expectEqualStrings("claude-opus-5", argv[6]);
}

test "모델을 못 읽었으면 플래그를 안 붙인다 — 기본 모델로 가는 것이 맞다" {
    const a = std.testing.allocator;
    // 모델 줄이 아예 없는 transcript(옛 기록·요약만 남은 파일)와, 토큰 모양이 아닌 값만 있는 경우.
    const none =
        \\{"sessionId":"c-n","type":"user","message":{"role":"user","text":"요청"}}
    ;
    var parsed = (try parse(a, .claude, none)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings("", parsed.model);
    var buf: [max_resume_argv][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), resumeArgv(&parsed, &buf).len);

    const only_synthetic =
        \\{"type":"session_meta","payload":{"id":"x-n","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt 5 with space"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
    ;
    var codex = (try parse(a, .codex, only_synthetic)).?;
    defer codex.deinit(a);
    try std.testing.expectEqualStrings("", codex.model);
    try std.testing.expectEqual(@as(usize, 3), resumeArgv(&codex, &buf).len);
}

test "Codex 권한 모드: turn_context 의 두 축을 함께 읽어 argv 에 싣는다" {
    const a = std.testing.allocator;
    const jsonl =
        \\{"type":"session_meta","payload":{"id":"x-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"model":"gpt-x","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
        \\{"type":"turn_context","payload":{"model":"gpt-x","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}
    ;
    var parsed = (try parse(a, .codex, jsonl)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqual(
        Permission{ .codex = .{ .approval = .never, .sandbox = .danger_full_access } },
        parsed.permission,
    );

    var buf: [max_resume_argv][]const u8 = undefined;
    const argv = resumeArgv(&parsed, &buf);
    try std.testing.expectEqual(@as(usize, 9), argv.len);
    try std.testing.expectEqualStrings("codex", argv[0]);
    try std.testing.expectEqualStrings("resume", argv[1]);
    try std.testing.expectEqualStrings("x-1", argv[2]);
    try std.testing.expectEqualStrings("--ask-for-approval", argv[3]);
    try std.testing.expectEqualStrings("never", argv[4]);
    try std.testing.expectEqualStrings("--sandbox", argv[5]);
    try std.testing.expectEqualStrings("danger-full-access", argv[6]);
}

test "RB2-3 끝부분 먹이기: 마지막 권한 모드·모델이 이긴다" {
    const a = std.testing.allocator;
    // 잘린 첫 줄을 버리는 것은 `agent_transcript.readTail` 이 소유한다(그쪽 판정자) — 여기는 온전한 줄만 받는다.
    const tail =
        \\{"sessionId":"c-1","type":"user","permissionMode":"plan","message":{"role":"user","text":"x"}}
        \\{"sessionId":"c-1","type":"user","permissionMode":"default","message":{"role":"user","text":"y"}}
        \\{"sessionId":"c-1","type":"assistant","message":{"role":"assistant","model":"claude-opus-4-1","text":"z"}}
        \\{"sessionId":"c-1","type":"user","permissionMode":"bypassPermissions","message":{"role":"user","text":"w"}}
    ;
    var p = Parser.init(a, .claude);
    feedResumeTail(&p, tail);
    try std.testing.expectEqual(Permission{ .claude = .bypassPermissions }, p.permission);
    try std.testing.expectEqualStrings("claude-opus-4-1", p.model);

    // 모드·모델 줄이 끝부분에 없으면 unknown·빈 모델 — 그러면 플래그 없이 provider 기본값으로 연다(도크 규칙).
    var none = Parser.init(a, .claude);
    feedResumeTail(&none, "{\"sessionId\":\"c-1\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"text\":\"z\"}}");
    try std.testing.expectEqual(Permission.unknown, none.permission);
    try std.testing.expectEqualStrings("", none.model);
}

test "RB2-4 codex 끝부분은 session_meta 없이도 모드·모델을 읽고, 도크와 같은 argv 를 만든다" {
    const a = std.testing.allocator;
    const tail =
        \\{"type":"turn_context","payload":{"model":"gpt-x","approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
        \\{"type":"turn_context","payload":{"model":"gpt-y","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}
    ;
    var p = Parser.init(a, .codex);
    feedResumeTail(&p, tail);
    try std.testing.expectEqual(Permission{ .codex = .{ .approval = .never, .sandbox = .danger_full_access } }, p.permission);
    try std.testing.expectEqualStrings("gpt-y", p.model);

    // 같은 입력 넷이면 `Parsed` 경로(도크)와 `ResumeTarget` 경로(부활)가 **바이트까지 같은** argv 를 낸다.
    const full =
        \\{"type":"session_meta","payload":{"id":"x-1","cwd":"/repo","thread_source":"user"}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
        \\{"type":"turn_context","payload":{"model":"gpt-y","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}
    ;
    var parsed = (try parse(a, .codex, full)).?;
    defer parsed.deinit(a);
    var dock_buf: [max_resume_argv][]const u8 = undefined;
    const dock = resumeArgv(&parsed, &dock_buf);
    var revive_buf: [max_resume_argv][]const u8 = undefined;
    const revive = resumeArgvFor(.{ .provider = .codex, .session_id = "x-1", .permission = p.permission, .model = p.model }, &revive_buf);
    try std.testing.expectEqual(dock.len, revive.len);
    for (dock, revive) |x, y| try std.testing.expectEqualStrings(x, y);
}

test "Codex 권한 모드: 못 읽은 축은 채워 넣지 않는다" {
    const a = std.testing.allocator;
    // 샌드박스만 적힌 턴. 승인 정책에 기본값을 끼워 넣으면 그 순간 "기록된 대로" 가 거짓이 된다.
    const jsonl =
        \\{"type":"session_meta","payload":{"id":"x-2","cwd":"/repo","thread_source":"user"}}
        \\{"type":"turn_context","payload":{"sandbox_policy":{"type":"read-only"}}}
        \\{"type":"event_msg","payload":{"type":"user_message","message":"요청"}}
    ;
    var parsed = (try parse(a, .codex, jsonl)).?;
    defer parsed.deinit(a);
    try std.testing.expectEqual(
        Permission{ .codex = .{ .approval = null, .sandbox = .read_only } },
        parsed.permission,
    );

    var buf: [max_resume_argv][]const u8 = undefined;
    const argv = resumeArgv(&parsed, &buf);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("--sandbox", argv[3]);
    try std.testing.expectEqualStrings("read-only", argv[4]);
}

test "권한 모드 표: 모든 값이 왕복하고, 재개 argv 상한을 넘지 않는다" {
    // rollout 철자(하이픈)와 Zig enum 이름(밑줄)이 달라 표가 양방향으로 둘이다. 한쪽만 고치면 그 값만
    // 조용히 재개에서 빠진다 — **허용된 자리 전부**를 세어서 두 방향이 갈리는 것을 막는다.
    inline for (@typeInfo(CodexApproval).@"enum".fields) |field| {
        const value: CodexApproval = @enumFromInt(field.value);
        try std.testing.expectEqual(value, CodexApproval.fromTranscript(value.flagValue()).?);
    }
    inline for (@typeInfo(CodexSandbox).@"enum".fields) |field| {
        const value: CodexSandbox = @enumFromInt(field.value);
        try std.testing.expectEqual(value, CodexSandbox.fromTranscript(value.flagValue()).?);
    }
    // Claude 는 transcript 철자와 CLI 철자가 같으므로 왕복이 enum 이름 자체와 맞는지까지 본다.
    inline for (@typeInfo(ClaudeMode).@"enum".fields) |field| {
        const value: ClaudeMode = @enumFromInt(field.value);
        try std.testing.expectEqual(value, ClaudeMode.fromTranscript(field.name).?);
        if (value.flagValue()) |flag| try std.testing.expectEqualStrings(field.name, flag);
    }

    // 상한은 "가장 긴 조합" 에서 실제로 재 본다. 상수만 크게 적어 두면 버퍼가 넘칠 때까지 아무도 모른다.
    var parsed: Parsed = .{
        .provider = .codex,
        .session_id = @constCast("x"),
        .title = @constCast(""),
        .summary = @constCast(""),
        .cwd = @constCast(""),
        .model = @constCast("gpt-5.6-sol"),
        .message_count = 0,
        .verified_user = true,
        .permission = .{ .codex = .{ .approval = .never, .sandbox = .danger_full_access } },
    };
    var buf: [max_resume_argv][]const u8 = undefined;
    try std.testing.expectEqual(max_resume_argv, resumeArgv(&parsed, &buf).len);
}
