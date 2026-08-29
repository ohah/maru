//! control_surface — 컨트롤 플레인 **Surface 엔티티 DTO** + 직렬화 + **read-only 디스패치 코어**(L2 순수, OS-중립).
//! Track C slice 1c. 단일 출처: docs/control-plane.md §3(엔티티 모델)·§6(sessions.list·session.get)·§8.3(균일
//! unauthorized)·§11(slice 1c)·§16(코어 L2 = src/session/).
//!
//! **1a(control_plane.zig)와의 관계**: 1a는 wire 프로토콜 프리미티브(JSON-RPC 스키마/parser/framer/error-model)만
//! 담는다. 1c는 그 위에 §3 **Surface 엔티티**(cwd·git_branch·agent·at_prompt / url·panel_kind·loading·trust)와
//! read-only 응답(sessions.list·session.get)을 얹는다. 별도 모듈로 두는 이유: 1a는 "message 봉투", 1c는 "그 안에
//! 실리는 도메인 엔티티 + scope 판정"이라 관심사가 다르고, control_plane.zig가 이미 크다(§11 코드배치 gate는
//! src/session/ 중립 모듈을 허용). error 코드(unauthorized·process_exited)는 error-model 단일 출처인
//! control_plane.zig `ErrorCode`에 두고 여기서 재사용한다.
//!
//! **이름 주의(drift)**: 이 `SurfaceDto`는 컨트롤 플레인 wire 엔티티(§3)다 — `session/surface.zig`의 `Surface`
//! (live TerminalCore + core_mutex를 든 런타임 타입)와 **다르다**. wire DTO는 collector(L4)가 live 트리를 읽어
//! 채우는 중립 스냅샷일 뿐, 코어/락/PTY를 참조하지 않는다. 이름 충돌을 피하려 `SurfaceDto`로 둔다.
//!
//! **범위(1c, 순수·헤드리스)**:
//!   1. Surface 엔티티 DTO(§3): 공통 메타 `{surface_id, generation}`·kind·title·좌표(window/tab/pane)·focused +
//!      terminal 전용(cwd·git_branch·agent{kind,state}·at_prompt 3상) / web 전용(url·panel_kind·loading·trust).
//!      **tagged**: `detail: union(SurfaceKind)`이라 kind에 따라 필드가 타입 수준에서 분기한다.
//!   2. 직렬화: Surface → JSON-RPC result value(session.get), `[Surface]` → sessions.list result. 1a
//!      `writeId`/JSON 스타일 재사용. at_prompt는 **3상**(true→JSON true, false→JSON false, unknown→JSON null).
//!   3. read-only 디스패치 코어(순수 함수): fake collector snapshot + caller surface_id + granted scope를 받아
//!      - `sessions.list`: M0b `scopeAllowsSurface`로 필터한 `[Surface]` 직렬화.
//!      - `session.get`: **§8.3대로 scope 판정을 존재·generation 확인보다 먼저** — 볼 수 없으면 존재 여부와
//!        무관하게 균일 `unauthorized`(oracle 방지), 볼 수 있고 존재하면 Surface, 인가됐으나 없으면 process_exited.
//!   4. collector seam: 실제 collector(L4, Swift가 라이브 트리를 읽음)가 주입할 **중립 snapshot DTO**(`CollectorSnapshot`).
//!      1c 테스트는 손으로 만든 fake snapshot으로만 돈다.
//!
//! **범위 밖(구현 금지)**: 실제 collector(Swift 트리 순회·core_mutex read), 소켓 accept·메인 marshal(1b/§5),
//! capability/auth 발급(1e), CLI parser/--help(1d), write/lifecycle(2·3).
//!
//! **at_prompt 3상 wire 인코딩 결정(document-basis-and-decision)**: §3은 `true|false|unknown` 세 토큰을 요구하고,
//! unknown(OSC 133 미통합 셸)을 known-not-prompt(false)와 **구별해야** 한다(bool로 접지 않음 — 닫기 확인의
//! `cursorIsAtPrompt`와 다른 경로). wire는 이를 **nullable boolean**으로 인코딩한다: at_prompt=true→JSON `true`,
//! false→JSON `false`, unknown→JSON `null`. 세 값이 JSON에서 구조적으로 구별되고(JS: `x===true`/`x===false`/
//! `x===null`), false와 null이 절대 같지 않아 "unknown 보존" 불변식을 wire에서 지킨다. 이 필드는 terminal surface에
//! **항상** 실린다(생략이 곧 null과 헷갈리지 않도록). cwd·git_branch·url은 반대로 **없으면 필드 생략**(absent=미가용).
//!
//! **agent/at_prompt/panel_kind/trust wire enum 결정**: 이 DTO는 collector가 채우는 **wire 스키마**라, 내부 상태머신
//! (session_model.AgentKind·agent_observer.State)에 의존하지 않고 자체 wire enum을 둔다 — 내부 enum을 리팩터해도
//! wire가 조용히 바뀌지 않게(경계 격리). L4 collector가 내부 상태 → 이 wire enum으로 매핑한다(§3 상태 수집 문단).
//! wire 문자열은 exhaustive switch로 못박아(내부 rename이 wire를 안 흔들게) 고정한다.
//!
//! **generation은 M0b/M0a 정책을 따른다**: DTO는 `{surface_id, generation}`을 직렬화하지만, scope 판정(§8.3)은
//! `window_membership.scopeAllowsSurface`가 surface_id 동일성으로만 한다(generation 매칭은 M1 — window_membership.zig
//! 헤더 참조). session.get의 selector도 1c에선 surface_id로 받는다(generation 기반 in-flight 거부는 후속).
//!
//! **L2 순수:** std + control_plane(1a) + window_membership(M0b)만 import한다(app/pty/platform import 0 —
//! tests/boundary/imports.zig가 강제). OS 타입 0.

const std = @import("std");
const cp = @import("control_plane.zig");
const wm = @import("window_membership.zig");

// ── Surface 엔티티 DTO(§3) ────────────────────────────────────────────────────────────────────────────────

/// surface 종류 판별자(§3 `surface.kind = terminal | web`). `detail` union의 tag이자 wire `kind` 필드.
/// surface의 종류. **닫힌 열거다** — 새 값은 사용자 승인 사안이고(`app_session.zig` 묘비 주석),
/// 값마다 `SurfaceDetail`·`LiveSurface` arm이 따라온다.
///
/// `editor`는 N1 네이티브 편집기다([native-editor.md](../../docs/native-editor.md)). **`web`과 갈리는
/// 이유**: 기존 `kind == .web` 분기들이 "PTY 없음"과 "터미널 셀 렌더 안 함"을 함께 뜻하는데, 편집기는
/// **PTY는 없지만 렌더는 한다**(자기 셀 프레임을 그린다). 그 조합을 `web`에 얹으면 웹 전용 경로(URL·
/// trust·WKWebView 부착)까지 딸려 오므로 자기 값을 갖는다.
pub const SurfaceKind = enum { terminal, web, editor };

/// at_prompt 3상(§3, OSC 133 기반). wire: `.at_prompt`→JSON true, `.not_at_prompt`→JSON false, `.unknown`→JSON null.
/// unknown의 주 출처는 OSC 133 미통합 셸(대다수)이라 known-not-prompt(false)와 절대 접지 않는다(§3).
pub const AtPrompt = enum {
    /// OSC 133 semantic prompt가 커서=프롬프트라고 알림 → wire `true`.
    at_prompt,
    /// 통합 셸이 프롬프트가 아니라고 알림, 또는 alt-screen 중(§3 alt 오버라이드) → wire `false`.
    not_at_prompt,
    /// OSC 133 미통합(대다수) → wire `null`. false로 접지 않는다.
    unknown,
};

/// 신뢰 등급(§8.1). `panel_kind=browser`(임의 URL)는 untrusted다.
pub const TrustLevel = enum { trusted, untrusted };

/// web 패널 종류(§3 `panel_kind`). web-panel.md의 "닫힌 열거"(마크다운 편집·인앱 브라우저) — 새 종류는 사용자
/// 승인이 필요하다(§1 line 22). 지금 열린 값만 둔다.
pub const PanelKind = enum { markdown, browser };

/// 포그라운드 에이전트 종류(wire). 내부 `session_model.AgentKind`의 `none`은 여기 없다 — 에이전트가 없으면
/// `TerminalMeta.agent`가 null(필드 생략)이라 kind가 항상 실제 에이전트다(collector가 none이면 null로 매핑).
pub const AgentKind = enum { claude, codex };

/// 에이전트 상태(wire). `blocked`는 사용자 입력/승인을 기다리는 보이는 UI, `idle`은 입력 가능한 UI다.
pub const AgentState = enum { unknown, running, blocked, idle };

/// 포그라운드 에이전트 정보(§3 `agent(kind/state)`). 에이전트가 있을 때만 `TerminalMeta.agent`에 실린다.
pub const AgentInfo = struct {
    kind: AgentKind,
    state: AgentState,
};

/// terminal surface 전용 메타(§3). collector가 app_session Model 트리 + termCwdForDisplay + termGitBranch +
/// agent observer의 터미널 관측 결과에서 채운다(수집 로직은 L4, 여긴 스키마만).
pub const TerminalMeta = struct {
    /// **이 터미널이 서 있는 작업 디렉터리** — GUI의 사이드바·소스 컨트롤·파일 탐색기·상태바 폴더줄과
    /// **같은 값**이다. 규칙의 단일 출처는 docs/editor-surface-dock.md §3.5(OSC 7 → 커널 조회 2단)다.
    ///
    /// 예전에는 OSC 7만 봤다. 그래서 셸 통합이 없는 셸(bash/fish)이나 프롬프트를 한 번도 그리지 않는
    /// 재개 Term에서는 **화면에 폴더가 보이는데 이 필드만 비는** 상태가 상시였고, 반대로 maru ssh 세션에서
    /// 원격 셸이 OSC 7을 안 보내면 ssh 이전의 **낡은 로컬 경로**가 원격 세션의 cwd인 양 실렸다.
    ///
    /// 원격은 `cwd_host` authority로 가른다 — 원격 authority가 보고한 경로는 그대로 싣고(host 접두는
    /// 붙이지 않는다. 이 구조체에 host 필드가 없고 접두는 GUI 표기 규약이다), 커널 조회로 대체하지
    /// 않는다(커널은 로컬 ssh 클라이언트의 cwd를 답한다).
    ///
    /// **여전히 없을 수 있다.** 영속 세션 호스트로 연 Term은 PTY가 데몬 프로세스 소유라 커널 조회가 닿지
    /// 않아 OSC 7이 유일한 출처다(editor-surface-dock.md §3.5). 클라이언트는 이 필드의 존재를 가정하면
    /// 안 된다 — 그때는 GUI 폴더줄도 함께 비므로 wire만 모르는 상태는 아니다. 값이 없으면 생략.
    cwd: ?[]const u8 = null,
    /// git 브랜치. 위 `cwd`(표시용)가 아니라 **저장소 판정용 축**(`termGitBranch` → 원격·ssh면 null)에서
    /// 파생한다. 원격 세션에 브랜치가 없는 것은 예나 지금이나 같다 — 로컬 `.git`을 원격 경로로 읽지 않도록
    /// 파생 함수가 이미 끊는다(ssh-integration.md §9.4). 없으면 생략.
    git_branch: ?[]const u8 = null,
    /// 포그라운드 에이전트(있을 때만). null이면 wire에서 생략.
    agent: ?AgentInfo = null,
    /// 프롬프트 위치 3상. terminal surface엔 항상 실린다(true/false/null).
    at_prompt: AtPrompt = .unknown,
};

/// 편집기 surface의 컨트롤 플레인 메타. **web과 달리 URL·trust가 없다** — 여는 대상이 로컬 파일
/// 하나이고 신뢰 경계가 파일 시스템 권한이라(§3.5 읽기 전용 판정) 웹의 축이 그대로 오지 않는다.
pub const EditorMeta = struct {
    /// 열려 있는 파일의 절대 경로. 없으면 생략(아직 파일이 안 붙은 편집기).
    path: ?[]const u8 = null,
    /// 쓸 수 없는 파일이라 읽기 전용으로 열렸는가(§3.5 — 여는 것을 막지는 않는다).
    read_only: bool = false,
    /// 저장하지 않은 편집이 있는가([file-panel.md](../../docs/file-panel.md) §1이 계약을 소유한다 —
    /// **내용 동등성**이라 undo로 저장 시점 내용에 돌아오면 false다).
    ///
    /// **타입 있는 필드로 싣는 이유**: 이 값은 사람이 보는 제목에 `●` 접두로도 나간다. 그것만 두면
    /// 소비자가 **제목 문자열을 뜯어** dirty를 알아내야 하고, 표식을 바꾸는 순간 조용히 깨진다
    /// (적대적 검증 2026-08-26이 그 상태를 잡았다).
    dirty: bool = false,
};

/// web surface 전용 메타(§3). collector가 WKWebView 상태에서 채운다(Phase 4·5, 여긴 스키마만).
pub const WebMeta = struct {
    /// 현재 URL. 없으면 생략.
    url: ?[]const u8 = null,
    /// 패널 종류(markdown|browser).
    panel_kind: PanelKind,
    /// 로딩 중인가.
    loading: bool = false,
    /// 신뢰 등급(§8.1).
    trust: TrustLevel,
};

/// kind에 따라 분기하는 전용 메타(tagged). terminal이면 web 필드를, web이면 terminal 필드를 **타입 수준에서**
/// 가질 수 없다(§3 "tagged(kind에 따라 필드 분기)").
pub const SurfaceDetail = union(SurfaceKind) {
    terminal: TerminalMeta,
    web: WebMeta,
    editor: EditorMeta,
};

/// 컨트롤 플레인 Surface 엔티티(§3). 공통 메타 + kind-분기 detail. 슬라이스(title/cwd/…)는 collector 소유 버퍼를
/// 빌린다(DTO는 소유 안 함) — 직렬화가 snapshot 수명 안에서 즉시 일어난다.
pub const SurfaceDto = struct {
    /// 외부 ID의 surface_id 절반(앱 전역 unique opaque u64, M0a `SurfaceIdAllocator` 발급). 비재사용(§3).
    surface_id: u64,
    /// 외부 ID의 generation 절반(defense-in-depth, §3). 대개 0. scope 매칭엔 미사용(M1 — 모듈 헤더).
    generation: u64 = 0,
    /// 표시 제목(§3). custom_name 우선 해석은 collector가 이미 접어서 넣는다(app.label.pick).
    title: []const u8 = "",
    /// 위치 좌표: 어느 window(§3 `window_token`=위치 메타, `WindowMembershipSnapshot.window_id`와 같은 opaque u64).
    window: u64 = 0,
    /// 위치 좌표: window 안 tab의 0-based 위치(collector가 트리에서 계산).
    tab: u32 = 0,
    /// 위치 좌표: tab split 안 pane의 0-based 위치(collector 계산).
    pane: u32 = 0,
    /// 앱 포커스가 이 surface에 있는가(§3 공통 메타).
    focused: bool = false,
    /// 영속 세션 호스트의 runtime id(32 소문자 hex). **그 surface 가 host-backed 일 때만** 있다 —
    /// in-process Term·웹 패널·편집기에는 runtime 이 없다. 값이 없으면 wire 에서 생략한다.
    ///
    /// **`surface_id` 와 다른 축이다**(§3): 이쪽은 GUI 를 껐다 켜도 PTY 가 사는 동안 유지되고,
    /// 프로세스 밖에서 그 터미널에 붙는 키다(`maru attach`). 단일 출처는 세션 호스트이고 collector
    /// 는 그것을 옮겨 적을 뿐이다. **이 필드가 곧 "붙을 수 있는가" 다.**
    runtime_id: ?[]const u8 = null,
    /// kind-분기 detail.
    detail: SurfaceDetail,

    /// surface 종류(detail의 tag).
    pub fn kind(self: SurfaceDto) SurfaceKind {
        return self.detail;
    }
};

// ── collector seam(§2·§4.7 중립 DTO 주입) ─────────────────────────────────────────────────────────────────

/// 실제 collector(L4)가 한 dispatch tick에 주입하는 **중립 스냅샷**. 코어는 이 seam으로만 라이브 상태를 본다
/// (런타임/OS 타입 0 — §2·§17). 1c 테스트는 손으로 만든 fake로 이 struct를 채운다.
///   - `surfaces`: collector가 모든 AppSession을 순회해 평탄화한 Surface 엔티티(응답 데이터).
///   - `windows`: window↔surface membership(M0b) — **scope 판정의 권위**다(어느 surface를 볼 수 있는가는 여기서).
/// 둘은 collector가 같은 tick에서 일관되게 채운다(불일치 시 §8.3의 process_exited 경로가 방어).
pub const CollectorSnapshot = struct {
    surfaces: []const SurfaceDto,
    windows: []const wm.WindowMembershipSnapshot,

    /// surfaces에서 surface_id로 조회(없으면 null). 앱 전역 unique라 첫 매치가 유일.
    pub fn find(self: CollectorSnapshot, surface_id: u64) ?SurfaceDto {
        for (self.surfaces) |s| {
            if (s.surface_id == surface_id) return s;
        }
        return null;
    }
};

// ── read-only 디스패치 코어(§6·§8.3) ─────────────────────────────────────────────────────────────────────

/// granted `scope` 하에서 caller가 `surface_id`를 볼 수 있는가(§8.3의 pointwise 술어). M0b
/// `scopeAllowsSurface`를 그대로 쓴다 — membership(`snapshot.windows`)이 권위다. sessions.list 필터와
/// session.get scope 판정이 이 한 술어를 공유한다(단일 출처).
pub fn surfaceVisible(
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
    surface_id: u64,
) bool {
    return wm.scopeAllowsSurface(snapshot.windows, caller_surface_id, scope, surface_id);
}

/// session.get 판정 결과(§8.3). serialize와 분리해 순수 판정을 단위 테스트로 못박는다.
pub const GetOutcome = union(enum) {
    /// 인가됐고 존재 → 이 Surface를 result로.
    surface: SurfaceDto,
    /// **§8.3 균일 unauthorized**: granted scope로 대상 surface를 볼 수 없음. 존재 여부와 무관(oracle 방지).
    unauthorized,
    /// 인가는 됐으나 snapshot에 없음(§5·§8.3 "없음/process-exited"). oracle 아님(호출자는 볼 권한 보유).
    process_exited,
};

/// `session.get {id}` 판정(§6·§8.3). **scope 판정을 존재·generation 확인보다 먼저** 한다:
///   1. `surfaceVisible`가 false면 — 대상이 snapshot에 있든 없든 — **균일 `.unauthorized`**(surface_id 열거
///      oracle 방지, §8.3). `surfaceVisible`가 존재검사를 겸하지 않는 scope(.self)에서도 인가 우선이라 안전하다.
///   2. 인가됐으면 snapshot에서 찾아 `.surface`, 없으면 `.process_exited`.
/// 이 순서 덕에 self-scope caller가 남의 id를 probe하면 그 id의 존재/부재가 응답으로 새지 않는다(둘 다 unauthorized).
pub fn getSurface(
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
    requested_surface_id: u64,
) GetOutcome {
    // §8.3: 존재검사 이전에 scope 판정.
    if (!surfaceVisible(snapshot, caller_surface_id, scope, requested_surface_id)) return .unauthorized;
    // 인가됨 → 이제서야 존재 확인.
    if (snapshot.find(requested_surface_id)) |dto| return .{ .surface = dto };
    return .process_exited;
}

// ── 직렬화(§6, 1a JSON 스타일 재사용) ─────────────────────────────────────────────────────────────────────
// 모든 직렬화는 minified 한 줄(1a와 동일 — ndjson frame 경계 안전). 종단 `\n`은 프레이밍(1b)이 붙인다.

fn agentKindWire(k: AgentKind) []const u8 {
    return switch (k) {
        .claude => "claude",
        .codex => "codex",
    };
}

fn agentStateWire(s: AgentState) []const u8 {
    return switch (s) {
        .unknown => "unknown",
        .running => "running",
        .blocked => "blocked",
        .idle => "idle",
    };
}

fn panelKindWire(p: PanelKind) []const u8 {
    return switch (p) {
        .markdown => "markdown",
        .browser => "browser",
    };
}

fn trustWire(t: TrustLevel) []const u8 {
    return switch (t) {
        .trusted => "trusted",
        .untrusted => "untrusted",
    };
}

fn kindWire(k: SurfaceKind) []const u8 {
    return switch (k) {
        .terminal => "terminal",
        .web => "web",
        .editor => "editor",
    };
}

/// Surface 엔티티 하나를 JSON 객체로 쓴다(§3). 공통 메타 → kind-분기 detail 순. at_prompt는 3상 nullable bool,
/// optional 문자열(cwd/git_branch/url)·agent는 없으면 필드 생략.
fn writeSurface(s: *std.json.Stringify, dto: SurfaceDto) !void {
    try s.beginObject();

    // 외부 ID = {surface_id, generation}(§3).
    try s.objectField("id");
    try s.beginObject();
    try s.objectField("surface_id");
    try s.write(dto.surface_id);
    try s.objectField("generation");
    try s.write(dto.generation);
    try s.endObject();

    try s.objectField("kind");
    try s.write(kindWire(dto.detail));
    try s.objectField("title");
    try s.write(dto.title);
    // 좌표(window/tab/pane).
    try s.objectField("window");
    try s.write(dto.window);
    try s.objectField("tab");
    try s.write(dto.tab);
    try s.objectField("pane");
    try s.write(dto.pane);
    try s.objectField("focused");
    try s.write(dto.focused);
    // **있을 때만 싣는다**(§3). 빈 문자열을 실으면 소비자가 그것을 "붙을 수 있는데 id 가 빈 세션"
    // 으로 읽는다 — 없는 것과 다른 말이다.
    if (dto.runtime_id) |id| {
        try s.objectField("runtime_id");
        try s.write(id);
    }

    switch (dto.detail) {
        .terminal => |t| {
            if (t.cwd) |c| {
                try s.objectField("cwd");
                try s.write(c);
            }
            if (t.git_branch) |b| {
                try s.objectField("git_branch");
                try s.write(b);
            }
            if (t.agent) |a| {
                try s.objectField("agent");
                try s.beginObject();
                try s.objectField("kind");
                try s.write(agentKindWire(a.kind));
                try s.objectField("state");
                try s.write(agentStateWire(a.state));
                try s.endObject();
            }
            // at_prompt는 항상 실린다 — 3상 nullable bool(true/false/null). unknown을 false로 접지 않는다(§3).
            try s.objectField("at_prompt");
            switch (t.at_prompt) {
                .at_prompt => try s.write(true),
                .not_at_prompt => try s.write(false),
                .unknown => try s.write(null),
            }
        },
        .web => |w| {
            if (w.url) |u| {
                try s.objectField("url");
                try s.write(u);
            }
            try s.objectField("panel_kind");
            try s.write(panelKindWire(w.panel_kind));
            try s.objectField("loading");
            try s.write(w.loading);
            try s.objectField("trust");
            try s.write(trustWire(w.trust));
        },
        // **web의 축(url·trust·loading)을 그대로 쓰지 않는다.** 편집기가 여는 것은 로컬 파일 하나이고
        // 신뢰 경계가 파일 시스템 권한이라, 있는 값만 낸다 — 없는 축을 null로 채우면 소비자가 웹과
        // 같은 것으로 오인한다.
        .editor => |e| {
            if (e.path) |pth| {
                try s.objectField("path");
                try s.write(pth);
            }
            try s.objectField("read_only");
            try s.write(e.read_only);
        },
    }

    try s.endObject();
}

/// Surface 하나를 단독 JSON 객체 바이트로 직렬화한다(session.get result value·round-trip 테스트용). caller가 free.
pub fn serializeSurface(gpa: std.mem.Allocator, dto: SurfaceDto) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    writeSurface(&s, dto) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// `{"jsonrpc":"2.0","id":<id>,"result":<surface>}` 한 줄 응답(session.get 성공). 1a `writeId` 재사용. caller free.
fn serializeGetResult(gpa: std.mem.Allocator, id: cp.Id, dto: SurfaceDto) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeGetResult(&s, id, dto)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeGetResult(s: *std.json.Stringify, id: cp.Id, dto: SurfaceDto) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("id");
    try cp.writeId(s, id);
    try s.objectField("result");
    try writeSurface(s, dto);
    try s.endObject();
}

/// `session.get` 디스패치 코어 엔트리(§6·§8.3). scope 판정 → 성공이면 Surface result, 실패면 §8.3 균일
/// unauthorized / process_exited **에러 응답**(1a `serializeError` 재사용). L4 marshal(1b/§5)이 부른다. caller free.
pub fn serializeSessionGet(
    gpa: std.mem.Allocator,
    id: cp.Id,
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
    requested_surface_id: u64,
) std.mem.Allocator.Error![]u8 {
    switch (getSurface(snapshot, caller_surface_id, scope, requested_surface_id)) {
        .surface => |dto| return serializeGetResult(gpa, id, dto),
        .unauthorized => return cp.serializeError(gpa, id, .unauthorized, cp.ErrorCode.unauthorized.defaultMessage(), null),
        .process_exited => return cp.serializeError(gpa, id, .process_exited, cp.ErrorCode.process_exited.defaultMessage(), null),
    }
}

/// `sessions.list` 디스패치 코어 엔트리(§6·§8.3). `{"jsonrpc":"2.0","id":<id>,"result":[<visible surface>,...]}`.
/// snapshot.surfaces를 순회하며 `surfaceVisible`(M0b scope 필터)를 통과한 것만 result 배열에 싣는다. caller free.
/// 할당은 출력 버퍼(aw)뿐 — 중간 collect 버퍼 없이 필터+직렬화를 한 패스로(무제한 surface 수 안전).
pub fn serializeSessionsList(
    gpa: std.mem.Allocator,
    id: cp.Id,
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
) std.mem.Allocator.Error![]u8 {
    // window 필터 없는 기본 경로 = filtered(null). 필터 로직 단일 출처는 아래 Filtered.
    return serializeSessionsListFiltered(gpa, id, snapshot, caller_surface_id, scope, null);
}

/// `sessions.list {window?}` 디스패치 코어(§6). 기본 `serializeSessionsList`에 **선택적 window_id 좁힘**을 더한다
/// (Track C 1d: `--window <id>`). `window_filter`가 있으면 그 window에 속한 surface만(그러나 scope로도 가려야 한다 —
/// scope는 인가 상한, window는 요청 좁힘이라 **교집합**이다). scope 필터가 여전히 존재/oracle의 권위(§8.3).
/// null이면 window 좁힘 없음(= 기본 sessions.list). caller free.
pub fn serializeSessionsListFiltered(
    gpa: std.mem.Allocator,
    id: cp.Id,
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
    window_filter: ?u64,
) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeSessionsList(&s, id, snapshot, caller_surface_id, scope, window_filter)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSessionsList(
    s: *std.json.Stringify,
    id: cp.Id,
    snapshot: CollectorSnapshot,
    caller_surface_id: u64,
    scope: wm.MetadataScope,
    window_filter: ?u64,
) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write(cp.jsonrpc_version);
    try s.objectField("id");
    try cp.writeId(s, id);
    try s.objectField("result");
    try s.beginArray();
    for (snapshot.surfaces) |dto| {
        // scope(인가 상한)를 먼저, 그다음 window(요청 좁힘) — 둘 다 통과해야 결과에 실린다(교집합).
        if (!surfaceVisible(snapshot, caller_surface_id, scope, dto.surface_id)) continue;
        if (window_filter) |wf| {
            if (dto.window != wf) continue;
        }
        try writeSurface(s, dto);
    }
    try s.endArray();
    try s.endObject();
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓 0) ═══════════════════════════════════════════════════
const testing = std.testing;

// ── fake collector snapshot 조립 헬퍼 ────────────────────────────────────────────────────────────────────
// 창 A(normal, window_id=1)={10 terminal, 11 web}, 창 B(normal, window_id=2)={20 terminal}, quick(window_id=3)={30 terminal}.
// caller 기본은 창 A의 surface 10. 실제 population은 Phase 1 collector — 여긴 손으로.

fn termSurface(sid: u64, title: []const u8, meta: TerminalMeta) SurfaceDto {
    return .{ .surface_id = sid, .title = title, .detail = .{ .terminal = meta } };
}

fn webSurface(sid: u64, title: []const u8, meta: WebMeta) SurfaceDto {
    return .{ .surface_id = sid, .title = title, .detail = .{ .web = meta } };
}

const fx_surfaces = [_]SurfaceDto{
    .{ .surface_id = 10, .generation = 0, .title = "shell-a", .window = 1, .tab = 0, .pane = 0, .focused = true, .detail = .{ .terminal = .{ .cwd = "/home/a", .git_branch = "main", .agent = .{ .kind = .claude, .state = .running }, .at_prompt = .not_at_prompt } } },
    .{ .surface_id = 11, .generation = 0, .title = "docs", .window = 1, .tab = 1, .pane = 0, .focused = false, .detail = .{ .web = .{ .url = "https://x/y", .panel_kind = .markdown, .loading = false, .trust = .trusted } } },
    .{ .surface_id = 20, .generation = 2, .title = "shell-b", .window = 2, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .cwd = "/srv/b", .at_prompt = .at_prompt } } },
    .{ .surface_id = 30, .generation = 0, .title = "quick", .window = 3, .tab = 0, .pane = 0, .focused = false, .detail = .{ .terminal = .{ .at_prompt = .unknown } } },
};
const fx_a_ids = [_]u64{ 10, 11 };
const fx_b_ids = [_]u64{20};
const fx_q_ids = [_]u64{30};
const fx_windows = [_]wm.WindowMembershipSnapshot{
    .{ .window_id = 1, .window_kind = .normal, .surface_ids = &fx_a_ids },
    .{ .window_id = 2, .window_kind = .normal, .surface_ids = &fx_b_ids },
    .{ .window_id = 3, .window_kind = .quick, .surface_ids = &fx_q_ids },
};
const fx: CollectorSnapshot = .{ .surfaces = &fx_surfaces, .windows = &fx_windows };

// result 배열에서 surface_id 집합을 뽑는 헬퍼(순서 무관 검증용).
fn resultSurfaceIds(alloc: std.mem.Allocator, wire: []const u8, out: *std.ArrayList(u64)) !void {
    var pm = try cp.parseMessage(alloc, wire);
    defer pm.deinit();
    const arr = pm.message.response.result.?.array;
    for (arr.items) |item| {
        const id_obj = item.object.get("id").?.object;
        try out.append(alloc, @intCast(id_obj.get("surface_id").?.integer));
    }
}

// ── 1) DTO 직렬화 round-trip(terminal) ──
test "surface DTO round-trip: terminal 공통 메타 + 전용 필드가 보존된다" {
    const dto = termSurface(10, "shell-a", .{ .cwd = "/home/a", .git_branch = "main", .agent = .{ .kind = .claude, .state = .running }, .at_prompt = .not_at_prompt });
    var d = dto;
    d.generation = 7;
    d.window = 1;
    d.tab = 2;
    d.pane = 3;
    d.focused = true;

    const wire = try serializeSurface(testing.allocator, d);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOfScalar(u8, wire, '\n') == null); // 한 줄.

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    // 외부 ID = {surface_id, generation}.
    const id_obj = o.get("id").?.object;
    try testing.expectEqual(@as(i64, 10), id_obj.get("surface_id").?.integer);
    try testing.expectEqual(@as(i64, 7), id_obj.get("generation").?.integer);
    try testing.expectEqualStrings("terminal", o.get("kind").?.string);
    try testing.expectEqualStrings("shell-a", o.get("title").?.string);
    try testing.expectEqual(@as(i64, 1), o.get("window").?.integer);
    try testing.expectEqual(@as(i64, 2), o.get("tab").?.integer);
    try testing.expectEqual(@as(i64, 3), o.get("pane").?.integer);
    try testing.expect(o.get("focused").?.bool);
    try testing.expectEqualStrings("/home/a", o.get("cwd").?.string);
    try testing.expectEqualStrings("main", o.get("git_branch").?.string);
    const ag = o.get("agent").?.object;
    try testing.expectEqualStrings("claude", ag.get("kind").?.string);
    try testing.expectEqualStrings("running", ag.get("state").?.string);
    // at_prompt=not_at_prompt → JSON false(생략도 null도 아님).
    try testing.expect(o.get("at_prompt").?.bool == false);
    // web 전용 필드는 terminal엔 없어야 한다(tagged).
    try testing.expect(o.get("url") == null);
    try testing.expect(o.get("panel_kind") == null);
    try testing.expect(o.get("trust") == null);
}

// ── 2) DTO 직렬화 round-trip(web) ──
test "surface DTO round-trip: web 전용 필드(url·panel_kind·loading·trust), terminal 필드 부재" {
    const dto = webSurface(11, "docs", .{ .url = "https://x/y", .panel_kind = .browser, .loading = true, .trust = .untrusted });
    const wire = try serializeSurface(testing.allocator, dto);
    defer testing.allocator.free(wire);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("web", o.get("kind").?.string);
    try testing.expectEqualStrings("https://x/y", o.get("url").?.string);
    try testing.expectEqualStrings("browser", o.get("panel_kind").?.string);
    try testing.expect(o.get("loading").?.bool);
    try testing.expectEqualStrings("untrusted", o.get("trust").?.string);
    // terminal 전용 필드는 web엔 없다(tagged). at_prompt도 web엔 실리지 않는다.
    try testing.expect(o.get("cwd") == null);
    try testing.expect(o.get("git_branch") == null);
    try testing.expect(o.get("agent") == null);
    try testing.expect(o.get("at_prompt") == null);
}

// ── 3) at_prompt 3상 인코딩(load-bearing: unknown≠false) ──
test "at_prompt 3상: true→JSON true, false→JSON false, unknown→JSON null(false로 접지 않음)" {
    const cases = [_]struct { st: AtPrompt, expect: enum { t, f, n } }{
        .{ .st = .at_prompt, .expect = .t },
        .{ .st = .not_at_prompt, .expect = .f },
        .{ .st = .unknown, .expect = .n },
    };
    for (cases) |c| {
        const dto = termSurface(1, "s", .{ .at_prompt = c.st });
        const wire = try serializeSurface(testing.allocator, dto);
        defer testing.allocator.free(wire);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
        defer parsed.deinit();
        const v = parsed.value.object.get("at_prompt").?;
        switch (c.expect) {
            .t => try testing.expect(v == .bool and v.bool == true),
            .f => try testing.expect(v == .bool and v.bool == false),
            .n => try testing.expect(v == .null), // unknown은 null — 절대 false가 아니다.
        }
        // 필드는 세 경우 모두 **존재**해야 한다(생략이 곧 unknown과 헷갈리지 않게).
        try testing.expect(parsed.value.object.contains("at_prompt"));
    }
}

// ── 4) agent 생략(에이전트 없으면 필드 자체가 없다) ──
test "runtime_id 는 있을 때만 실린다 — 그 유무가 붙을 수 있는가다" {
    // 빈 문자열을 실으면 소비자가 "붙을 수 있는데 id 가 빈 세션" 으로 읽는다 — 없는 것과 다른
    // 말이다(§3). in-process Term 은 runtime 이 없으므로 필드 자체가 없어야 한다.
    const gpa = std.testing.allocator;
    const dtos = [_]SurfaceDto{
        .{
            .surface_id = 10,
            .window = 1,
            .title = "host-backed",
            .runtime_id = "0123456789abcdef0123456789abcdef",
            .detail = .{ .terminal = .{ .at_prompt = .unknown } },
        },
        .{
            .surface_id = 11,
            .window = 1,
            .title = "in-process",
            .detail = .{ .terminal = .{ .at_prompt = .unknown } },
        },
    };
    // **membership 이 있어야 scope 판정을 지난다** — 빈 `windows` 로는 `.all` 이어도 아무것도 안
    // 실린다(그렇게 짰다가 이 테스트가 그것을 잡았다).
    const ids = [_]u64{ 10, 11 };
    const windows = [_]wm.WindowMembershipSnapshot{.{ .window_id = 1, .window_kind = .normal, .surface_ids = &ids }};
    const wire = try serializeSessionsListFiltered(gpa, .{ .number = 1 }, .{ .surfaces = &dtos, .windows = &windows }, 10, .all, null);
    defer gpa.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"runtime_id\":\"0123456789abcdef0123456789abcdef\"") != null);
    // 두 줄인데 필드는 하나뿐이다.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wire, "runtime_id"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"runtime_id\":\"\"") == null);
}

test "agent 없는 terminal surface는 agent 필드를 생략한다(none을 wire에 싣지 않음)" {
    const dto = termSurface(1, "s", .{ .at_prompt = .unknown }); // agent=null 기본.
    const wire = try serializeSurface(testing.allocator, dto);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("agent") == null);
    // optional 문자열도 생략.
    try testing.expect(parsed.value.object.get("cwd") == null);
    try testing.expect(parsed.value.object.get("git_branch") == null);
}

// ── 5) generation 직렬화(0 아닌 값 보존) ──
test "generation 직렬화: 외부 ID의 generation 절반이 그대로 실린다" {
    const dto: SurfaceDto = .{ .surface_id = 42, .generation = 5, .detail = .{ .terminal = .{ .at_prompt = .unknown } } };
    const wire = try serializeSurface(testing.allocator, dto);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    const id_obj = parsed.value.object.get("id").?.object;
    try testing.expectEqual(@as(i64, 42), id_obj.get("surface_id").?.integer);
    try testing.expectEqual(@as(i64, 5), id_obj.get("generation").?.integer);
}

// ── 6) sessions.list scope 필터: self ──
test "sessions.list self scope: caller 자기 surface 하나만 응답(§8.3 self 필터)" {
    const wire = try serializeSessionsList(testing.allocator, .{ .number = 1 }, fx, 10, .self);
    defer testing.allocator.free(wire);
    // 유효한 JSON-RPC 응답인지 1a parser로 확인(response·result 배열).
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expect(idEqlNum(pm.message.response.id, 1));

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try resultSurfaceIds(testing.allocator, wire, &ids);
    try testing.expectEqualSlices(u64, &.{10}, ids.items);
}

// ── 7) sessions.list scope 필터: window ──
test "sessions.list window scope: caller 창(A)의 surface만 — 다른 창·quick 제외" {
    const wire = try serializeSessionsList(testing.allocator, .{ .number = 2 }, fx, 10, .window);
    defer testing.allocator.free(wire);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(testing.allocator);
    try resultSurfaceIds(testing.allocator, wire, &ids);
    // 창 A = {10 terminal, 11 web}. 20(창 B)·30(quick) 제외.
    try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
}

// ── 8) sessions.list scope 필터: all(quick 포함) ──
test "sessions.list all scope: quick 포함 전체 surface — quick은 all에서만 보인다" {
    // all: 전부.
    {
        const wire = try serializeSessionsList(testing.allocator, .{ .number = 3 }, fx, 10, .all);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try resultSurfaceIds(testing.allocator, wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11, 20, 30 }, ids.items); // quick(30) 포함.
    }
    // 대조: 같은 caller가 window scope면 quick(30)은 안 보인다(quick은 all에만).
    {
        const wire = try serializeSessionsList(testing.allocator, .{ .number = 4 }, fx, 10, .window);
        defer testing.allocator.free(wire);
        try testing.expect(std.mem.indexOf(u8, wire, "\"surface_id\":30") == null);
    }
}

// ── 8b) sessions.list {window?} 필터: window 좁힘은 scope와 교집합(Track C 1d) ──
test "sessions.list window_filter: scope∩window 교집합 — all+window=1 → 창 A만, window 없으면 전체" {
    // all scope + window=1 → 창 A={10,11}만(20·30 제외).
    {
        const wire = try serializeSessionsListFiltered(testing.allocator, .{ .number = 1 }, fx, 10, .all, 1);
        defer testing.allocator.free(wire);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try resultSurfaceIds(testing.allocator, wire, &ids);
        try testing.expectEqualSlices(u64, &.{ 10, 11 }, ids.items);
    }
    // window_filter=null → 기본 sessions.list와 동일(전체).
    {
        const a = try serializeSessionsListFiltered(testing.allocator, .{ .number = 1 }, fx, 10, .all, null);
        defer testing.allocator.free(a);
        const b = try serializeSessionsList(testing.allocator, .{ .number = 1 }, fx, 10, .all);
        defer testing.allocator.free(b);
        try testing.expectEqualStrings(a, b); // null 필터는 무동작(기본 경로와 바이트 동일)
    }
    // self scope caller 10 + window=1 → 10만(11은 self 밖). window=2 → self가 window를 이겨 빈 목록.
    {
        const w1 = try serializeSessionsListFiltered(testing.allocator, .{ .number = 1 }, fx, 10, .self, 1);
        defer testing.allocator.free(w1);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(testing.allocator);
        try resultSurfaceIds(testing.allocator, w1, &ids);
        try testing.expectEqualSlices(u64, &.{10}, ids.items);

        const w2 = try serializeSessionsListFiltered(testing.allocator, .{ .number = 1 }, fx, 10, .self, 2);
        defer testing.allocator.free(w2);
        var pm = try cp.parseMessage(testing.allocator, w2);
        defer pm.deinit();
        try testing.expectEqual(@as(usize, 0), pm.message.response.result.?.array.items.len);
    }
}

// ── 9) session.get self: 자기만 Surface ──
test "session.get self scope: 자기 surface는 Surface, 결과는 tagged 필드까지 실린다" {
    const wire = try serializeSessionGet(testing.allocator, .{ .number = 9 }, fx, 10, .self, 10);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expect(pm.message == .response);
    try testing.expect(pm.message.response.err == null);
    const o = pm.message.response.result.?.object;
    try testing.expectEqual(@as(i64, 10), o.get("id").?.object.get("surface_id").?.integer);
    try testing.expectEqualStrings("terminal", o.get("kind").?.string);
    try testing.expect(o.get("at_prompt").?.bool == false); // surface 10은 not_at_prompt.
}

// ── 10) §8.3 균일 unauthorized(oracle 방지) — 핵심 불변식 ──
test "session.get §8.3: self scope caller가 남의 id를 물으면 존재/부재와 무관하게 균일 unauthorized(oracle 방지)" {
    // (a) 존재하는 남의 surface(20, 창 B) — self scope엔 안 보임.
    const wire_exists = try serializeSessionGet(testing.allocator, .{ .number = 1 }, fx, 10, .self, 20);
    defer testing.allocator.free(wire_exists);
    // (b) 아예 존재하지 않는 surface(999).
    const wire_absent = try serializeSessionGet(testing.allocator, .{ .number = 1 }, fx, 10, .self, 999);
    defer testing.allocator.free(wire_absent);

    // 결정 수준: 둘 다 .unauthorized(존재검사 이전 scope 판정).
    try testing.expect(getSurface(fx, 10, .self, 20) == .unauthorized);
    try testing.expect(getSurface(fx, 10, .self, 999) == .unauthorized);

    // wire 수준: **바이트 동일**이어야 oracle이 없다(존재/부재가 응답으로 새지 않음).
    try testing.expectEqualStrings(wire_exists, wire_absent);
    // 그리고 그 응답은 unauthorized 에러다(process_exited/method 다름 아님).
    var pm = try cp.parseMessage(testing.allocator, wire_exists);
    defer pm.deinit();
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.unauthorized)), pm.message.response.err.?.code);
}

// ── 11) process_exited: 인가됐으나 snapshot에 없음(unauthorized와 구별) ──
test "session.get: 인가된 surface가 snapshot에 없으면 process_exited(unauthorized와 다른 코드)" {
    // membership엔 창 A={10,11}이 있지만 surfaces 리스트에서 11을 뺀 스냅샷 — 인가는 되나 존재 안 함.
    const partial_surfaces = [_]SurfaceDto{fx_surfaces[0]}; // 10만 있고 11 없음.
    const snap: CollectorSnapshot = .{ .surfaces = &partial_surfaces, .windows = &fx_windows };

    // caller=10, window scope로 11을 요청: 11은 창 A membership에 있어 인가됨. 그러나 surfaces엔 없음.
    try testing.expect(getSurface(snap, 10, .window, 11) == .process_exited);
    const wire = try serializeSessionGet(testing.allocator, .{ .number = 1 }, snap, 10, .window, 11);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expectEqual(@as(i64, @intFromEnum(cp.ErrorCode.process_exited)), pm.message.response.err.?.code);

    // 대조: 인가 안 된 id(창 B의 20)를 window scope로 물으면 process_exited가 아니라 **unauthorized**
    // (존재하더라도 — scope 판정이 존재검사보다 먼저라 oracle 없음).
    try testing.expect(getSurface(snap, 10, .window, 20) == .unauthorized);
}

// ── 12) self scope caller가 자기 surface가 사라지면 process_exited(자기 것이라 oracle 아님) ──
test "session.get self: 자기 surface가 snapshot에 없으면 process_exited(자기 것 → oracle 아님)" {
    const empty_surfaces = [_]SurfaceDto{};
    const snap: CollectorSnapshot = .{ .surfaces = &empty_surfaces, .windows = &fx_windows };
    // self scope는 id==caller면 membership과 무관하게 인가 → 존재 확인 → 없음 → process_exited.
    try testing.expect(getSurface(snap, 10, .self, 10) == .process_exited);
    // 하지만 남의 id는 여전히 unauthorized(자기 것만 존재-누설 허용).
    try testing.expect(getSurface(snap, 10, .self, 11) == .unauthorized);
}

// ── 13) 빈 snapshot ──
test "빈 snapshot: sessions.list는 빈 배열, session.get(self 자기)은 process_exited" {
    const empty_surfaces = [_]SurfaceDto{};
    const empty_windows = [_]wm.WindowMembershipSnapshot{};
    const snap: CollectorSnapshot = .{ .surfaces = &empty_surfaces, .windows = &empty_windows };

    const wire = try serializeSessionsList(testing.allocator, .{ .number = 1 }, snap, 10, .all);
    defer testing.allocator.free(wire);
    var pm = try cp.parseMessage(testing.allocator, wire);
    defer pm.deinit();
    try testing.expectEqual(@as(usize, 0), pm.message.response.result.?.array.items.len); // [].

    // all scope로 아무 id나 물으면 membership이 비어 unauthorized.
    try testing.expect(getSurface(snap, 10, .all, 10) == .unauthorized);
    // self scope 자기 id는 인가되나 surfaces가 비어 process_exited.
    try testing.expect(getSurface(snap, 10, .self, 10) == .process_exited);
}

// ── 14) membership이 scope 권위: surfaces엔 있으나 membership엔 없는 surface는 all에서도 안 보인다 ──
test "membership이 scope 권위: surfaces에만 있고 어느 window membership에도 없으면 all scope에서도 제외" {
    const orphan_surface = termSurface(77, "orphan", .{ .at_prompt = .unknown });
    const surfaces = [_]SurfaceDto{ fx_surfaces[0], orphan_surface }; // 10 + membership 없는 77.
    const snap: CollectorSnapshot = .{ .surfaces = &surfaces, .windows = &fx_windows };

    const wire = try serializeSessionsList(testing.allocator, .{ .number = 1 }, snap, 10, .all);
    defer testing.allocator.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"surface_id\":77") == null); // orphan 제외.
    try testing.expect(std.mem.indexOf(u8, wire, "\"surface_id\":10") != null);
    // get도 마찬가지: all scope로 77을 물으면 membership에 없어 unauthorized(not process_exited).
    try testing.expect(getSurface(snap, 10, .all, 77) == .unauthorized);
}

// ── 15) 좌표(window/tab/pane) 직렬화 ──
test "좌표: window/tab/pane이 응답 surface에 실린다" {
    const dto: SurfaceDto = .{ .surface_id = 1, .window = 9, .tab = 4, .pane = 2, .detail = .{ .terminal = .{ .at_prompt = .unknown } } };
    const wire = try serializeSurface(testing.allocator, dto);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqual(@as(i64, 9), o.get("window").?.integer);
    try testing.expectEqual(@as(i64, 4), o.get("tab").?.integer);
    try testing.expectEqual(@as(i64, 2), o.get("pane").?.integer);
}

// ── 16) surfaceVisible 술어가 M0b scope 필터와 일치(단일 출처) ──
test "surfaceVisible: self/window/all이 window_membership.scopeAllowsSurface와 동치" {
    for ([_]u64{ 10, 11, 20, 30, 999 }) |sid| {
        for ([_]wm.MetadataScope{ .self, .window, .all }) |scope| {
            try testing.expectEqual(
                wm.scopeAllowsSurface(fx.windows, 10, scope, sid),
                surfaceVisible(fx, 10, scope, sid),
            );
        }
    }
}

// ── 17) kind() tag 헬퍼 ──
test "SurfaceDto.kind()는 detail tag를 돌려준다" {
    try testing.expectEqual(SurfaceKind.terminal, termSurface(1, "s", .{}).kind());
    try testing.expectEqual(SurfaceKind.web, webSurface(2, "w", .{ .panel_kind = .markdown, .trust = .trusted }).kind());
}

fn idEqlNum(id: cp.Id, n: i64) bool {
    return cp.idEql(id, .{ .number = n });
}

// ── 커버리지 보강(test/foundation-coverage-gaps) ──────────────────────────────────────────────────────────

// 모듈 헤더 계약: "wire 문자열은 exhaustive switch로 못박아(내부 rename이 wire를 안 흔들게) 고정한다". 기존
// 테스트는 agent kind=claude·state=running만 실었다 — agentKindWire(.codex)·agentStateWire(.idle|.unknown)
// 분기는 어떤 테스트도 안 밟아, 내부 enum rename이 이 wire 문자열을 조용히 바꿔도 잡히지 않았다. 그 wire 상수를 못박는다.
test "wire enum 안정성: agent state=blocked가 별도 문자열로 실린다" {
    const dto = termSurface(7, "s", .{ .agent = .{ .kind = .claude, .state = .blocked }, .at_prompt = .unknown });
    const wire = try serializeSurface(testing.allocator, dto);
    defer testing.allocator.free(wire);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
    defer parsed.deinit();
    const ag = parsed.value.object.get("agent").?.object;
    try testing.expectEqualStrings("claude", ag.get("kind").?.string);
    try testing.expectEqualStrings("blocked", ag.get("state").?.string);
}

test "wire enum 안정성: agent kind=codex, state=idle/unknown이 문서화된 wire 문자열로 직렬화된다" {
    // codex + idle.
    {
        const dto = termSurface(1, "s", .{ .agent = .{ .kind = .codex, .state = .idle }, .at_prompt = .unknown });
        const wire = try serializeSurface(testing.allocator, dto);
        defer testing.allocator.free(wire);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
        defer parsed.deinit();
        const ag = parsed.value.object.get("agent").?.object;
        try testing.expectEqualStrings("codex", ag.get("kind").?.string);
        try testing.expectEqualStrings("idle", ag.get("state").?.string);
    }
    // agent state=unknown(내부 3상 중 running/idle 아닌 나머지 — false로 접히지 않고 "unknown" 문자열).
    {
        const dto = termSurface(2, "s", .{ .agent = .{ .kind = .claude, .state = .unknown }, .at_prompt = .unknown });
        const wire = try serializeSurface(testing.allocator, dto);
        defer testing.allocator.free(wire);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, wire, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("unknown", parsed.value.object.get("agent").?.object.get("state").?.string);
    }
}
