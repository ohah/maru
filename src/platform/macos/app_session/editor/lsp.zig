//! LSP seam 1단의 제품 쪽(docs/editor-surface-tooling.md §8.2a) — 서버 수명·신뢰 프롬프트·문서 동기화·진단 합치기·상태바 상태.
//!
//! 한 클라이언트 = `(root, 서버 실행 파일)`. 세션 tick 마다 `pump` 가 ① 죽은 자식·재시작 예약 ② 밀린 쓰기 ③ 비차단 읽기 → 프레임 →
//! JSON-RPC 갈래 ④ 열린 편집기 Term 의 동기화(didOpen / 이 프레임에 바뀐 문서의 didChange 한 번)를 돈다. 스레드는 없다 — 원격
//! 에이전트 스트리머와 같은 결이다.
//!
//! **신뢰가 먼저다.** 서버를 찾아도 그 저장소의 결정이 없으면 신뢰 시트(confirm 모달)로 묻고(`pending_confirm = .lsp_trust`), 답을
//! 앱 전역 표에 둔다(`trust_store` — 키는 실제 경로·볼륨, 파일은 Application Support). 거부한 저장소는 안 띄우고 안 묻는다 — 상태바
//! 항목을 누르면 다시 묻는다. 한 창의 결정은 다른 창에도 선다(`applyTrustChanges`), 한 저장소는 한 창만 묻는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const lsp_process = @import("../../lsp_process.zig");
const tool_env = @import("../../tool_env.zig");
const lsp = maru.session.editor.lsp;
const diagnostic = maru.session.editor.diagnostic;
const language = maru.session.editor.language;
const pane_ops = @import("../pane.zig");
const tab_ops = @import("../tab.zig");
const input_ops = @import("../input.zig");
const term_ops = @import("../term.zig");
const file_tree_backend = @import("../../file_tree_backend.zig");
const trust_store = @import("trust_store.zig");
const editor_hover = @import("hover.zig");
const editor_ops = @import("mod.zig");
const editor_definition = @import("definition.zig");
const editor_signature = @import("signature.zig");
const editor_format = @import("format.zig");
const editor_rename = @import("rename.zig");
const editor_completion = @import("completion.zig");
const editor_semantic = @import("semantic.zig");
const editor_fold_lsp = @import("fold_lsp.zig");
const editor_references = @import("references.zig");
const editor_inlay = @import("inlay.zig");
const editor_symbols = @import("symbols.zig");
const editor_highlight = @import("highlight.zig");
const editor_smart_select = @import("smart_select.zig");
const editor_code_action = @import("code_action.zig");

pub const Phase = enum {
    /// 실행 파일을 못 찾았다(PATH·통상 설치 위치) — 상태바 「설치」. 사용자 셸 환경을 못 읽었으면(`tool_env` 실패) 그렇다고 보이고
    /// 누르면 다시 읽는다.
    missing,
    /// 사용자 셸 환경을 담는 중(계획 workspace-trust WT3b) — 그동안은 「없음」을 판정하지 않는다(앱의 짧은 PATH 로 먼저 「없음」을 정해
    /// 신뢰를 묻지도 않던 것). 담으면 다시 찾는다.
    preparing,
    /// 신뢰를 묻는 중(모달이 떠 있다).
    asking,
    /// 사용자가 거부했다(기억됨) — 상태바 「거부됨 — 다시 묻기」.
    denied,
    /// 띄웠고 `initialize` 응답을 기다린다.
    starting,
    /// 연결됐다.
    ready,
    /// 죽어서 재시작을 기다린다(backoff).
    restarting,
    /// 세 번 죽었다 — 클릭으로 재시도.
    failed,
    /// 묻지 않는 root(계획 WT2b): 홈이거나 그 위(`/` 포함) — 홈의 dotfiles `.git` 이 홈 아래 모든 파일의 root 가 된다. 홈 전체를 한 번의
    /// 허락으로 열지 않는다. 클릭하면 다시 본다.
    home_root,
    /// 신뢰 결정을 잊었다(계획 WT4 「잊기」) — 서버를 내리고 묻지 않은 채 둔다. 클릭하면 묻는다(다음에 앱을 열면 열 때 묻는다).
    unasked,
    /// 묻지 않는 root(계획 WT2b): git 저장소 밖 — 가장 가까운 `.git` 이 없어 파일의 부모 폴더가 root 가 됐다. 클릭하면 다시 본다
    /// (그 사이 `git init` 했으면 묻는다).
    outside_repo,
};

pub const max_restarts: u8 = 3;
pub const backoff_ms = [_]u64{ 1000, 2000, 4000 };
/// 한 tick 에 읽는 상한 — 서버가 폭주해도 프레임을 안 잡아먹는다(§8.2 「bounded push」).
const read_budget_per_tick: usize = 1 << 20;
/// 마지막 문서가 닫힌 뒤 서버를 얼마나 살려 두나(§8.2a).
pub const idle_shutdown_ms: u64 = 30_000;
const kill_grace_ms: u64 = 5_000;
/// `initialize` 응답을 기다리는 상한(§8.2a 「수명·재시작」). 실서버는 색인을 응답 **뒤에** 하므로 응답 자체는 빠르다 — 넘기면 멈춘
/// 서버로 보고 재시작 경로(backoff → 「실패」)를 탄다. 없으면 답하지 않는 서버가 상태바 「시작 중」에 영원히 남고, 그 상태는
/// 클릭으로도 못 푼다.
pub const initialize_timeout_ms: u64 = 30_000;
/// 세션 종료(창 닫기·앱 종료)·`lsp.enabled` 끄기에서 서버가 stdin EOF 를 보고 스스로 내려가기를 기다리는 상한 — 그 세션의 서버
/// **합쳐서**. 넘기면 그룹째 SIGKILL 한다(그 뒤 거두기는 서버마다 `lsp_process.reap_after_kill_ms`). 이 기다림은 거두기 스레드가
/// 하고(`lowerOffMain`), 앱 종료가 확정됐을 때만 이 자리에서 한다(§8.2a).
pub const quit_grace_ms: u64 = 500;

comptime {
    // 밀린 쓰기 상한은 바쁜 서버가 못 읽는 사이의 편집 몇 번(위치 요청 직전 동기화는 편집마다 전문을 보낸다)을 담아야 한다 —
    // 문서 상한의 몇 배여야 정상 서버를 「멈췄다」로 오판하지 않는다(`lsp_process.max_pending_bytes`).
    std.debug.assert(lsp_process.max_pending_bytes >= 8 * max_sync_bytes);
}

const OpenDoc = struct {
    surface_id: u64,
    /// 등록된 문서는 서버 연결 동안 read pin으로 살린다. 대표 뷰는 바뀔 수 있다.
    document: ?maru.session.editor.document_registry.Lease = null,
    uri: []u8,
    /// 서버에 보낸 마지막 version.
    sent_version: u64,

    fn matches(self: OpenDoc, term: *Term) bool {
        if (term.kind != .editor or term.rt.editor_diff != null) return false;
        if (self.document) |pin| {
            const lease = term.rt.editor_document_lease orelse return false;
            return pin.owner == lease.owner and std.meta.eql(pin.document, lease.document);
        }
        return self.surface_id == term.surfaceId();
    }

    fn release(self: OpenDoc, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        if (self.document) |pin| _ = @constCast(pin.owner).release(pin) catch false;
    }
};

pub const Client = struct {
    root: []u8,
    server: lsp.servers.Server,
    phase: Phase = .missing,
    proc: ?lsp_process.Process = null,
    inbuf: std.ArrayList(u8) = .empty,
    encoding: lsp.rpc.PositionEncoding = .utf16,
    restarts: u8 = 0,
    retry_at_ms: u64 = 0,
    docs: std.ArrayList(OpenDoc) = .empty,
    /// 마지막 문서가 닫힌 시각(0 = 열린 문서가 있다).
    idle_since_ms: u64 = 0,
    /// `shutdown` 을 보낸 시각(0 = 아니다). 응답이 오거나 시간이 지나면 `exit`/SIGKILL.
    shutdown_at_ms: u64 = 0,
    /// 이번 프로세스를 띄운 시각 — `.starting` 이 `initialize_timeout_ms` 를 넘기는지 잰다.
    started_at_ms: u64 = 0,
    /// 신뢰 결정을 기다린다(이 root 의 모달이 떠 있거나, 다른 root 의 모달이 먼저거나, 다른 창이 같은 저장소를 묻는다) — 띄우지 않는다.
    trust_pending: bool = false,
    /// 이 root 의 신뢰 키(실제 경로·볼륨 — `trust_store.keyFor`). 처음 신뢰를 볼 때 구해 굳힌다.
    trust_key: ?OwnedKey = null,
    /// 묻는 root 임을 이미 봤다(`refusalFor` — root 는 클라이언트마다 고정이라 한 번이면 된다; 기다리는 클라이언트가 tick 마다
    /// 파일 시스템을 다시 보지 않게). 거부된 클라이언트는 거짓으로 남아, 상태바를 누르면 다음 gate 가 다시 본다.
    scope_checked: bool = false,
    /// 기억된 결정을 두고 다시 묻는다(상태바 「거부됨 — 다시 묻기」). 이 창이 답하거나(`answerTrust` — 같은 저장소의 클라이언트 전부)
    /// 다른 창의 답이 그 뒤에 서면(`applyTrustChanges` — `reask_gen` 보다 늦게 바뀐 결정) 내린다. 답 없이 닫힌 모달(다른 오버레이가
    /// 덮었다)은 답이 아니라 그대로 두어 다음 gate 가 다시 묻는다.
    reask: bool = false,
    /// 「다시 묻기」를 누른 때의 앱 전역 표 세대.
    reask_gen: u64 = 0,
    /// 마지막으로 보낸 hover 요청의 seq(§8.2b — 응답은 `editor_hover` 가 「지금 기다리는 seq」와 대조한다).
    hover_seq: u32 = 0,
    /// 마지막으로 보낸 definition 요청의 seq(§8.2c).
    definition_seq: u32 = 0,
    references_seq: u32 = 0,
    /// 구현·타입 정의·선언(§8.2m) — seq 는 종류마다, provider 도 종류마다.
    implementation_seq: u32 = 0,
    type_definition_seq: u32 = 0,
    declaration_seq: u32 = 0,
    implementation_supported: bool = false,
    type_definition_supported: bool = false,
    declaration_supported: bool = false,
    /// 마지막으로 보낸 signatureHelp 요청의 seq(§8.2d)와 서버가 준 트리거 글자.
    signature_seq: u32 = 0,
    signature_triggers: lsp.rpc.SignatureTriggers = .{},
    /// 마지막으로 보낸 formatting 요청의 seq(§8.2e)와 서버의 지원 여부.
    formatting_seq: u32 = 0,
    formatting_supported: bool = false,
    /// rename(§8.2f).
    rename_seq: u32 = 0,
    rename_supported: bool = false,
    /// completion(§8.2g).
    completion_seq: u32 = 0,
    completion_resolve_seq: u32 = 0,
    completion_triggers: lsp.rpc.CompletionTriggers = .{},
    /// code action(§8.2h).
    code_action_seq: u32 = 0,
    code_action_resolve_seq: u32 = 0,
    code_action_caps: lsp.rpc.CodeActionCaps = .{},
    /// 이 클라이언트를 만든 문법(후보가 여럿인 언어에서 「없음」일 때 다시 고르는 데 쓴다 — §8.2a 「서버 찾기」).
    grammar: maru.session.editor.language.Grammar = .none,
    /// semantic tokens(§8.2i) — legend 를 우리 색으로 옮긴 표를 든다(소유).
    semantic_seq: u32 = 0,
    semantic_caps: lsp.semantic.Caps = .{},
    /// 접힘 3층(§8.2j) — `foldingRangeProvider`.
    fold_seq: u32 = 0,
    fold_supported: bool = false,
    /// 저장 통지(§8.2k) — `textDocumentSync.save`.
    save_caps: lsp.rpc.SaveCaps = .{},
    /// 인레이 힌트(§8.2n) — `inlayHintProvider`.
    inlay_seq: u32 = 0,
    /// 심볼 2층(§8.2o).
    symbols_seq: u32 = 0,
    symbols_supported: bool = false,
    /// 같은 낱말 강조(§8.2p).
    highlight_seq: u32 = 0,
    highlight_supported: bool = false,
    /// 구조 기반 선택 확장(§8.2q).
    selection_range_seq: u32 = 0,
    selection_range_supported: bool = false,
    inlay_supported: bool = false,

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        if (self.proc) |*p| lsp_process.stopNow(p, allocator); // 그룹째 — 서버가 띄운 빌드까지(보통은 `lowerServers` 가 먼저 내렸다)
        self.semantic_caps.deinit(allocator);
        for (self.docs.items) |d| d.release(allocator);
        self.docs.deinit(allocator);
        self.inbuf.deinit(allocator);
        if (self.trust_key) |k| k.deinit(allocator);
        allocator.free(self.root);
    }

    fn findDoc(self: *Client, term: *Term) ?*OpenDoc {
        for (self.docs.items) |*d| if (d.matches(term)) return d;
        return null;
    }
};

/// 신뢰 키의 소유본(`lsp.trust.Key` 는 경로를 빌린다).
pub const OwnedKey = struct {
    volume: u64,
    path: []u8,

    pub fn key(self: OwnedKey) lsp.trust.Key {
        return .{ .volume = self.volume, .path = self.path };
    }

    fn dupe(allocator: std.mem.Allocator, k: lsp.trust.Key) !OwnedKey {
        return .{ .volume = k.volume, .path = try allocator.dupe(u8, k.path) };
    }

    fn deinit(self: OwnedKey, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const State = struct {
    clients: std.ArrayList(Client) = .empty,
    /// 문법마다 고른 서버(§8.2a 「서버 찾기」 — 찾아지는 첫 후보). 세션 동안 기억하고, 「없음」이면 gate 가 다시 고른다.
    resolved: std.EnumArray(maru.session.editor.language.Grammar, ?lsp.servers.Server) = .initFill(null),
    /// 묻는 중인 root(모달의 주인 — 시트의 경로 줄)와 그 신뢰 키. 답이 오면 그 키의 클라이언트가 움직인다.
    asking_root: ?[]u8 = null,
    asking_key: ?OwnedKey = null,
    /// 마지막으로 적용한 앱 전역 신뢰 표의 세대(`applyTrustChanges`).
    seen_trust_generation: u64 = 0,
    /// 마지막으로 본 도구 환경의 바뀐 횟수(`tool_env.changeCount` — 읽기 시작·다 됨에 이 창의 상태바를 다시 그린다).
    seen_env_change: u64 = 0,
    /// 신뢰 관리 확인 상자(계획 WT4)의 대상과 두 자리의 동작 — 상자가 떠 있는 동안만. 안내 줄은 상자가 빌려 그린다.
    manage_key: ?OwnedKey = null,
    manage_primary: ManageAction = .forget,
    manage_alternate: ?ManageAction = null,
    manage_root_note_buf: [std.fs.max_path_bytes + 64]u8 = undefined,
    manage_notes: [5]maru.chrome.components.confirm.Note = undefined,
    /// 신뢰 시트의 안내 줄(`setTrustSheetNotes`) — 모달이 빌려 그리므로 모달이 떠 있는 동안 여기 산다. 경로 줄만 버퍼를 쓰고
    /// 나머지는 번역 표의 정적 문장이다.
    trust_root_note_buf: [std.fs.max_path_bytes + 64]u8 = undefined,
    trust_notes: [5]maru.chrome.components.confirm.Note = undefined,
    /// 판정자가 켜는 스위치 — 프롬프트 없이 이 답으로 간주한다. **테스트 빌드에서만 읽는다**(`gateTrust`) — 제품에서는 이 값이
    /// 무엇이든 신뢰는 사용자의 클릭으로만 선다(계획 WT2, LSPB23). `null` 이면 정상(모달).
    auto_trust_answer: ?lsp.trust.Decision = null,
    /// 판정자 관측: 보낸 didChange 수·받은 publishDiagnostics 수·거부한 서버 요청 수.
    sent_changes: u64 = 0,
    received_diagnostics: u64 = 0,
    rejected_requests: u64 = 0,
    /// 판정자 관측: 보낸 hover 요청 수·받은 hover 응답 수(§8.2b).
    sent_hovers: u64 = 0,
    received_hovers: u64 = 0,
    sent_definitions: u64 = 0,
    received_definitions: u64 = 0,
    sent_references: u64 = 0,
    received_references: u64 = 0,
    sent_signatures: u64 = 0,
    received_signatures: u64 = 0,
    sent_formattings: u64 = 0,
    received_formattings: u64 = 0,
    sent_renames: u64 = 0,
    received_renames: u64 = 0,
    sent_completions: u64 = 0,
    received_completions: u64 = 0,
    sent_completion_resolves: u64 = 0,
    sent_code_actions: u64 = 0,
    received_code_actions: u64 = 0,
    sent_code_action_resolves: u64 = 0,
    sent_semantic: u64 = 0,
    received_semantic: u64 = 0,
    sent_folding: u64 = 0,
    received_folding: u64 = 0,
    sent_saves: u64 = 0,
    sent_inlay: u64 = 0,
    received_inlay: u64 = 0,
    /// 서버의 `workspace/inlayHint/refresh` 를 받아 `null` 로 답한 수(§8.2n).
    inlay_refreshes: u64 = 0,
    sent_symbols: u64 = 0,
    received_symbols: u64 = 0,
    sent_highlight: u64 = 0,
    received_highlight: u64 = 0,
    sent_selection_range: u64 = 0,
    received_selection_range: u64 = 0,
    sent_configs: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.clients.items) |*c| c.deinit(allocator);
        self.clients.deinit(allocator);
        if (self.asking_root) |r| allocator.free(r);
        if (self.asking_key) |k| k.deinit(allocator);
        if (self.manage_key) |k| k.deinit(allocator);
        self.* = .{};
    }
};

// ── root·문서 ─────────────────────────────────────────────────────────────────

/// 그 Term 의 문서가 속한 root(§8.2a). 파일 트리 root 가 없거나 문서가 그 밖이면 `null` — 서버를 안 띄운다.
fn rootFor(self: *AppSession, term: *Term) ?[]const u8 {
    if (term.rt.editor_lsp_root) |r| return r;
    const path = termPath(term) orelse return null;
    // 파일 트리와 **같은 규칙**(`projectRootForFile`): 가장 가까운 `.git` 의 디렉터리, 없으면 파일의 디렉터리. 한 번 정해 굳힌다.
    const root = file_tree_backend.projectRootForFile(self.allocator, self.io, path) catch return null;
    if (root.len == 0 or !maru.session.repo_path.underRoot(path, root)) {
        self.allocator.free(root);
        return null;
    }
    term.rt.editor_lsp_root = root;
    return root;
}

/// 문서의 절대 경로 — 편집기 Term 이 여는 순간 굳힌 `editor_document.path`(탭 라벨·컨트롤 플레인이 읽는 그것).
fn termPath(term: *const Term) ?[]const u8 {
    return term.rt.editorDocument().path;
}

// ── 신뢰 ──────────────────────────────────────────────────────────────────────

/// 앱 전역 표를 처음 한 번 읽는다 — 옛 자리(설정 파일 옆 `lsp-trust`)가 있으면 이관한다.
fn ensureTrustLoaded(self: *AppSession) void {
    loadTrust(self.io, self.configPath());
}

/// 창 없이도 읽을 수 있게(컨트롤 플레인 — 계획 WT4b) 설정 경로만 받는다. `null` 이면 옛 자리 이관을 건너뛴다.
fn loadTrust(io: std.Io, config_path: ?[]const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    trust_store.ensureLoaded(io, if (config_path) |p| trust_store.legacyPathFor(p, &buf) else null);
}

/// 앱 전역 묻는 자리에서 이 창을 가리키는 값.
fn trustOwner(self: *AppSession) usize {
    return @intFromPtr(self);
}

/// 그 클라이언트의 신뢰 키 — 처음 한 번 구해 굳힌다(작업 root 는 그대로 — URI·표시가 흔들리지 않게). 실제 경로를 못 구하면(root 가
/// 사라졌다·못 연다) `null`.
fn trustKey(self: *AppSession, c: *Client) ?lsp.trust.Key {
    if (c.trust_key) |k| return k.key();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const k = trust_store.keyFor(c.root, &buf) orelse return null;
    rekeyRoot(self, c.root, k); // 같은 root 의 다른 클라이언트가 옛 키를 들고 있으면 함께 맞춘다
    return (c.trust_key orelse return null).key();
}

/// root 의 신뢰 키가 `key` 다 — 그 root 의 이 창 클라이언트를 **모두** 그 키로 맞춘다(키는 root 의 것이지 클라이언트의 것이 아니다).
/// 다른 키를 들고 있던 클라이언트(심링크 대상이 그사이 바뀌었다)는 새 대상의 신뢰를 아직 모르므로: 떠 있던 서버를 내리고(옛 저장소의
/// 허용으로 새 저장소에서 돌면 안 된다) 신뢰를 다시 보게 두며(`trust_pending`), 「다시 묻기」도 내린다(옛 저장소에 대한 물음이었다).
/// 이 창이 옛 키를 묻고 있었으면 그 모달도 내린다 — 답이 옛 대상에 기록되지 않게. 키가 처음 서는 클라이언트는 그냥 받는다.
fn rekeyRoot(self: *AppSession, root: []const u8, key: lsp.trust.Key) void {
    const st = &self.editor_lsp;
    for (st.clients.items) |*o| {
        if (!std.mem.eql(u8, o.root, root)) continue;
        const old = o.trust_key orelse {
            o.trust_key = OwnedKey.dupe(self.allocator, key) catch continue;
            continue;
        };
        if (old.key().eql(key)) continue;
        if (st.asking_key) |ak| if (ak.key().eql(old.key())) dropTrustPrompt(self);
        const owned = OwnedKey.dupe(self.allocator, key) catch continue;
        old.deinit(self.allocator);
        o.trust_key = owned;
        // 옛 대상의 서버·진단·연 문서를 걷는다 — 서버가 이미 죽어 있어도(재시작을 기다리며 문서를 들고 있다) 그 진단은 옛 저장소의 것이다.
        // 새 대상의 결정이 거부이거나 묻지 않는 root 여도 옛 밑줄이 남지 않게.
        dropProcess(self, o);
        clearClientDiagnostics(self, o);
        for (o.docs.items) |d| d.release(self.allocator);
        o.docs.clearRetainingCapacity();
        o.trust_pending = true;
        o.reask = false;
        o.scope_checked = false; // 새 대상이 홈이거나 저장소 밖일 수 있다 — 묻지 않는 root 판정부터 다시(계획 WT2b)
        o.phase = .restarting;
        o.retry_at_ms = 0;
    }
}

/// 묻던 모달을 답 없이 내린다 — 기억하지 않는다(다음에 다시 묻는다).
fn dropTrustPrompt(self: *AppSession) void {
    if (self.pending_confirm == .lsp_trust) {
        self.chrome_host.confirm.dismiss();
        self.pending_confirm = .none;
    }
    dismissTrustPrompt(self);
    self.metal_dirty = true;
}

/// 띄우기·묻기 직전에 신뢰 키를 다시 푼다 — root 가 심링크면 그 대상이 키를 구한 뒤에 바뀌었을 수 있다(`current → releases/…`). 그대로면
/// `true`. 바뀌었으면 그 root 를 새 키로 맞추고(`rekeyRoot`) 신뢰를 다시 보게 한다 — 다음 gate 가 새 키의 결정을 읽거나 묻는다. 못 풀면 「실패」.
fn trustKeyHolds(self: *AppSession, c: *Client) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const now = trust_store.keyFor(c.root, &buf) orelse {
        c.trust_pending = true;
        c.phase = .failed;
        return false;
    };
    if (c.trust_key) |k| if (k.key().eql(now)) return true;
    rekeyRoot(self, c.root, now); // 이 클라이언트도 — 새 키의 신뢰를 다시 본다
    return false;
}

/// 묻지 않는 root(계획 WT2b) — `null` 이면 묻는다. `real` 은 root 의 실제 경로(신뢰 키).
/// - root 에 `.git` 이 없다: 가장 가까운 `.git` 이 없어 파일의 부모 폴더가 root 가 됐다(`projectRootForFile` 의 폴백) — 저장소가 아니다.
///   허락의 단위(저장소)가 없으니 묻지 않는다(예전에는 그 폴더를 root 로 묻고, 허용하면 서버가 떴다 — 동작 변경).
/// - root 가 홈이거나 그 위(`/` 포함): 홈에 dotfiles `.git` 이 있으면 자기 `.git` 이 없는 홈 아래 모든 파일의 root 가 홈이다 — 홈 전체를
///   한 번의 허락으로 열지 않는다.
fn refusalFor(root: []const u8, real: []const u8) ?Phase {
    var gbuf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const git_z = std.fmt.bufPrintZ(&gbuf, "{s}/.git", .{std.mem.trimEnd(u8, root, "/")}) catch return .outside_repo;
    if (std.c.access(git_z.ptr, std.c.F_OK) != 0) return .outside_repo; // 디렉터리든 워크트리의 파일이든
    // HOME 을 못 구하면(없다·없는 경로) 홈 판정은 건너뛰고 묻는다 — `.git` 은 이미 있어 저장소 단위의 보통 묻기로 돌아간다. GUI 앱은
    // launchd 가 HOME 을 세운다.
    const home_z = std.c.getenv("HOME") orelse return null;
    var hbuf: [std.fs.max_path_bytes]u8 = undefined;
    const home = trust_store.keyFor(std.mem.span(home_z), &hbuf) orelse return null;
    if (selfOrAncestor(real, home.path)) return .home_root;
    return null;
}

/// `dir` 가 `path` 자신이거나 그 조상인가(경로 성분 경계에서 — `/Users/x` 는 `/Users/xyz` 의 조상이 아니다).
fn selfOrAncestor(dir: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, dir, path)) return true;
    if (std.mem.eql(u8, dir, "/")) return path.len > 0 and path[0] == '/';
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

test "LSPB28a 묻지 않는 root 의 조상 판정 — 자신·조상은 참, 접두만 같은 형제·자식은 거짓, `/` 는 모든 절대 경로의 조상 (계획 WT2b)" {
    try std.testing.expect(selfOrAncestor("/Users/x", "/Users/x"));
    try std.testing.expect(selfOrAncestor("/Users", "/Users/x"));
    try std.testing.expect(selfOrAncestor("/", "/Users/x"));
    try std.testing.expect(!selfOrAncestor("/Users/x", "/Users/xyz"));
    try std.testing.expect(!selfOrAncestor("/Users/x/proj", "/Users/x"));
    try std.testing.expect(!selfOrAncestor("/Users/xy", "/Users/x"));
}

fn sameKey(c: *const Client, key: lsp.trust.Key) bool {
    const k = c.trust_key orelse return false;
    return k.key().eql(key);
}

fn trustOf(self: *AppSession, key: lsp.trust.Key) ?lsp.trust.Decision {
    ensureTrustLoaded(self);
    return trust_store.get(key);
}

/// 결정을 앱 전역 표에 둔다(파일에 한 줄 — 마지막 줄이 이긴다). 다른 창은 세대를 보고 따른다(`applyTrustChanges`).
/// 파일에 남지 못했으면 `false` — 이번 실행에만 먹는다(`trust_store.decide`).
fn recordTrust(io: std.Io, config_path: ?[]const u8, key: lsp.trust.Key, decision: lsp.trust.Decision) bool {
    loadTrust(io, config_path);
    return trust_store.decide(io, key, decision);
}

/// 묻던 자리를 비운다 — 앱 전역 자리도 놓는다(그 키를 기다리던 다른 창이 다음 gate 에 묻는다).
fn clearAsking(self: *AppSession) void {
    const st = &self.editor_lsp;
    if (st.asking_key) |k| {
        trust_store.release(k.key(), trustOwner(self));
        k.deinit(self.allocator);
        st.asking_key = null;
    }
    if (st.asking_root) |r| {
        self.allocator.free(r);
        st.asking_root = null;
    }
}

/// 다른 창의 결정(앱 전역 표의 세대가 바뀌었다)을 이 창의 클라이언트에 적용한다 — pump 첫머리(`applyDecision`). 이 창이 지금 묻는
/// 저장소는 그 답이 정한다. 「다시 묻기」 중인 클라이언트는 누른 뒤에 그 저장소의 결정이 바뀌었을 때만 따른다(다른 창의 답이 이
/// 창의 물음에 대한 답이다 — 같은 답을 또 묻지 않는다). 키를 아직 안 구한 클라이언트는 gate 가 표를 직접 읽는다.
fn applyTrustChanges(self: *AppSession) void {
    const st = &self.editor_lsp;
    const gen = trust_store.generation();
    if (st.seen_trust_generation == gen) return;
    const prev = st.seen_trust_generation;
    st.seen_trust_generation = gen;
    for (st.clients.items) |*c| {
        const k = c.trust_key orelse continue;
        // 묻는 root 판정을 아직 안 거친 클라이언트(새로 생겼다·키가 바뀌었다·「꺼짐」을 눌렀다)는 gate 가 표를 직접 읽는다 — 여기서
        // 결정을 적용하면 묻지 않는 root 가 옛 결정(WT2b 이전의 거부)으로 「거부됨」이 된다.
        if (!c.scope_checked) continue;
        if (st.asking_key) |ak| if (ak.key().eql(k.key())) continue;
        if (c.reask) {
            if ((trust_store.changedAt(k.key()) orelse 0) <= c.reask_gen) continue;
            c.reask = false;
        }
        const decision = trust_store.get(k.key()) orelse {
            // 잊었다(계획 WT4) — 이 창이 마지막으로 본 뒤에 잊었으면 떠 있는 서버를 내리고 묻지 않은 채 둔다.
            if ((trust_store.changedAt(k.key()) orelse 0) > prev) forgetClient(self, c);
            continue;
        };
        applyDecision(self, c, decision);
    }
    self.metal_dirty = true;
}

/// 결정을 잊은 저장소의 클라이언트 — 서버를 유예 없이 그룹째 내리고(기다리던 요청도 놓는다 — `dropProcess`) 진단·연 문서를 걷어
/// 「결정 없음 — 묻기」로 둔다. 곧바로 묻지 않는다(잊기는 「다시 묻기」가 아니다 — 누르면 묻는다).
fn forgetClient(self: *AppSession, c: *Client) void {
    switch (c.phase) {
        .missing, .home_root, .outside_repo, .unasked => return,
        // 준비 중 — 다시 읽는 사이 죽은 서버는 문서·진단을 든 채 여기 있다(곧바로 묻지 않게 「결정 없음」으로 걷는다). 문서가 없어도
        // 「결정 없음」으로 — 그대로 두면 다 담은 뒤 gate 가 결정 없는 표를 읽고 **곧바로 묻는다**(잊기는 다시 묻기가 아니다 — 8회차; 서버가
        // 없던 클라이언트도 「결정 없음」이 되지만 누르면 root 부터 다시 봐 「없음」이 선다).
        .asking, .starting, .ready, .restarting, .failed, .denied, .preparing => {},
    }
    dropProcess(self, c);
    clearClientDiagnostics(self, c);
    for (c.docs.items) |d| d.release(self.allocator);
    c.docs.clearRetainingCapacity();
    c.trust_pending = false;
    c.reask = false;
    c.phase = .unasked;
}

/// 한 클라이언트에 결정을 적용한다(이 창의 답·다른 창의 답이 같은 길). 거부면 떠 있는 서버를 내리고 그 진단을 걷어 「거부됨」으로,
/// 허용이면 기다리던·묻던·거부됐던 클라이언트를 **잠든 채로** 둔다 — 열린 문서가 있으면 같은 pump 의 `syncDocuments` 가 깨워 띄우고,
/// 문서가 없는 클라이언트(닫힌 탭의 서버)는 띄우지 않는다. 이미 떠 있거나 재시작을 기다리는 클라이언트는 그대로다.
fn applyDecision(self: *AppSession, c: *Client, decision: lsp.trust.Decision) void {
    switch (decision) {
        .deny => switch (c.phase) {
            .missing, .denied, .home_root, .outside_repo => {},
            // 준비 중도 걷는다 — 다시 읽는 사이 죽은 서버의 클라이언트는 문서·진단을 든 채 여기 있다(거부 아래 옛 밑줄이 남지 않게). 걷을
            // 것이 없으면 그대로 둔다 — 다 담은 뒤 gate 가 표를 직접 읽는다(서버가 없으면 「없음」이 거부보다 먼저다 — 7회차).
            .preparing => if (c.docs.items.len > 0) denyClient(self, c),
            .asking, .starting, .ready, .restarting, .failed, .unasked => denyClient(self, c),
        },
        .allow => if (c.phase == .denied or c.phase == .asking or c.phase == .unasked or (c.phase == .restarting and c.trust_pending)) {
            c.trust_pending = false;
            c.phase = .restarting;
            c.retry_at_ms = std.math.maxInt(u64);
            c.restarts = 0;
        },
    }
}

/// 거부 — 떠 있는 서버를 내리고 진단·연 문서를 걷어 「거부됨」으로.
fn denyClient(self: *AppSession, c: *Client) void {
    dropProcess(self, c);
    clearClientDiagnostics(self, c);
    for (c.docs.items) |d| d.release(self.allocator);
    c.docs.clearRetainingCapacity();
    c.trust_pending = false;
    c.phase = .denied;
}

/// 그 클라이언트의 문서에 선 서버 진단을 걷는다(낡은 밑줄이 남지 않게 — 서버를 내릴 때).
fn clearClientDiagnostics(self: *AppSession, c: *Client) void {
    for (c.docs.items) |d| for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!d.matches(term)) continue;
        const diags = &term.rt.editor_diagnostics;
        diags.lsp.clearRetainingCapacity();
        diags.lsp_messages.clearRetainingCapacity();
        diags.lsp_dirty = true;
    };
}

/// 모달이 **답 없이** 닫혔다(다른 모달이 덮었다·앱이 끝난다) — 기억하지 않는다. 클라이언트는 다시 물을 수 있게 되돌린다.
/// 캡처 하니스가 이것을 잡았다: 종료 경로의 `cancelPendingConfirm` 이 「거부」를 파일에 적어 다음 실행이 서버를 안 띄웠다.
pub fn dismissTrustPrompt(self: *AppSession) void {
    const st = &self.editor_lsp;
    const ak = st.asking_key orelse return;
    defer clearAsking(self);
    for (st.clients.items) |*c| {
        if (!sameKey(c, ak.key()) or c.phase != .asking) continue;
        c.phase = .restarting;
        c.trust_pending = true; // 띄우지 않는다 — 다음 gate 가 다시 묻는다(「다시 묻기」였으면 그것도 그대로 — 답이 아니다)
    }
}

/// 신뢰 시트의 안내 줄(tooling §8.1 「sandbox 하지 못하는 한계를 확인 UX 에 명시」 — 계획 WT1). 무엇을 신뢰하는지(이 저장소의
/// 언어 서버 **전체** + root 경로 — 결정은 root 단위로 기억된다)와 무엇이 일어날 수 있는지(사용자 권한·격리 없음·저장소 밖·빌드
/// 스크립트·툴체인 다운로드·shim)를 밝힌다. 예전 문구(「‹서버› 를 실행할까요? … 설정을 읽고 빌드를 실행할 수 있습니다」)는 서버
/// 하나를 묻는 것처럼, 영향이 저장소 안에 머무는 것처럼 읽혔다. 경로 줄은 모달이 가운데를 줄인다(뿌리·잎을 남긴다).
fn setTrustSheetNotes(self: *AppSession, root: []const u8) void {
    const st = &self.editor_lsp;
    var shown_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_line = maru.i18n.format(&st.trust_root_note_buf, maru.i18n.t(.lsp_trust_note_root), &.{.{ .s = app_session_mod.homeTildeInto(root, &shown_buf) }});
    // **순서가 곧 우선순위다** — 높이가 모자라면 모달이 안내를 끝부터 줄인다. 대가(사용자 권한·격리 없음·저장소 밖)를 맨 앞에,
    // 경로 줄을 맨 끝에 둔다(경로가 먼저 사라지고 경고는 남는다).
    st.trust_notes = .{
        .{ .text = maru.i18n.t(.lsp_trust_note_privileges) },
        .{ .text = maru.i18n.t(.lsp_trust_note_build) },
        .{ .text = maru.i18n.t(.lsp_trust_note_scope) },
        .{ .text = maru.i18n.t(.lsp_trust_note_shim) },
        .{ .text = root_line, .fit = .path },
    };
    self.chrome_host.confirm.notes = &st.trust_notes;
}

/// 신뢰 모달의 답(`confirm_accept` / 사용자의 취소) — `app_session` 의 pending_confirm 갈래가 부른다.
pub fn answerTrust(self: *AppSession, allow: bool) void {
    const st = &self.editor_lsp;
    const ak = st.asking_key orelse return;
    defer clearAsking(self);
    const decision: lsp.trust.Decision = if (allow) .allow else .deny;
    // 파일에 못 남은 답은 말하지 않는다 — 다음 실행이 다시 묻는다(계획 WT4a 「한계」: 「다시 묻기」의 거부만 옛 허용으로 돌아간다).
    _ = recordTrust(self.io, self.configPath(), ak.key(), decision);
    // 같은 저장소의 이 창 클라이언트 **전부** — 묻던 것만이 아니라 「다시 묻기」로 기다리던 것(문서가 닫혀 gate 를 안 지나는 것까지).
    for (st.clients.items) |*c| {
        if (!sameKey(c, ak.key())) continue;
        // 묻는 root 판정을 아직 안 거친 클라이언트(키가 바뀌었다·「꺼짐」을 눌렀다)는 gate 가 표를 직접 읽는다 — 여기서 「거부됨」으로
        // 세우면 다른 창의 허용이 와도 못 깨운다(`applyTrustChanges` 도 건너뛴다).
        if (!c.scope_checked) continue;
        c.reask = false;
        applyDecision(self, c, decision);
    }
    self.metal_dirty = true;
}

// ── 신뢰 관리(계획 WT4) ───────────────────────────────────────────────────────

/// 신뢰 관리 확인 상자의 동작 — **철회**는 거부로 기억(다시 안 묻는다), **잊기**는 결정을 지운다(다음에 열 때 묻는다). 둘 다 그
/// 저장소의 언어 서버를 모든 창에서 바로 내린다(`applyTrustChanges` — 거부·잊기 둘 다 그 길). 허용은 여기 없다 — 신뢰를 주는 것은
/// 신뢰 시트의 답뿐이다(LSPB23).
pub const ManageAction = enum { revoke, forget };

/// 신뢰 관리 확인 상자를 띄운다. `only` 가 없으면 결정에 맞춰 — 허용이면 [철회][잊기][취소], 거부면 [잊기][취소]; 있으면 그 동작
/// 하나만(팔레트의 「이 저장소」 명령).
fn askManage(self: *AppSession, key: lsp.trust.Key, decision: lsp.trust.Decision, only: ?ManageAction) void {
    const owned = OwnedKey.dupe(self.allocator, key) catch return;
    const primary: ManageAction = only orelse if (decision == .allow) .revoke else .forget;
    const alternate: ?ManageAction = if (only == null and decision == .allow) .forget else null;
    if (alternate) |alt| {
        self.showConfirmChoiceKeys(.lsp_trust_manage, .lsp_trust_manage_prompt, .{ .primary = manageLabel(primary), .alternate = manageLabel(alt) });
    } else {
        self.showConfirmText(.lsp_trust_manage, maru.i18n.t(.lsp_trust_manage_prompt), .{ .confirm = manageLabel(primary), .cancel = .common_cancel });
    }
    // **Enter 는 아무것도 바꾸지 않는다** — 두 동작 모두 모든 창의 서버를 내리므로 처음 포커스를 취소에 둔다(확인 상자 규칙: Enter
    // 자리에는 버리지 않는 것만). 고르는 것은 버튼·←/→ 다(Y 는 첫 버튼을 고른다는 명시적 키라 그대로).
    self.chrome_host.confirm.focused = .cancel;
    // `show` 가 앞 상자(같은 주인이면 그 대상까지 — `cancelPendingConfirm`)를 비운 **뒤에** 채운다.
    const st = &self.editor_lsp;
    if (st.manage_key) |k| k.deinit(self.allocator);
    st.manage_key = owned;
    st.manage_primary = primary;
    st.manage_alternate = alternate;
    setManageNotes(self, owned.key(), primary, alternate);
}

fn manageLabel(a: ManageAction) maru.i18n.Key {
    return switch (a) {
        .revoke => .lsp_trust_revoke,
        .forget => .lsp_trust_forget,
    };
}

/// 관리 상자의 안내 줄 — 저장소 경로, 고를 수 있는 동작마다 그 뜻, 모든 창에서 바로 내린다는 것, **되돌리지 않는 것**(서버가 이미
/// 만든 캐시·빌드 산출물, 적용한 포맷·수정, 따로 떠난 데몬). **경로가 맨 앞이다** — 높이가 모자라면 모달이 끝부터 줄이는데, 이 상자의
/// 질문은 「이 저장소의…?」뿐이라 경로가 대상을 알리는 유일한 줄이다(신뢰 시트는 반대로 경고를 앞에 둔다 — 그쪽 질문에는 서버 이름이
/// 있고, 줄어서 안 되는 것은 대가다). 「이 저장소」 명령은 사용자가 대상을 직접 고르지 않았다.
fn setManageNotes(self: *AppSession, key: lsp.trust.Key, primary: ManageAction, alternate: ?ManageAction) void {
    const st = &self.editor_lsp;
    var n: usize = 0;
    var shown_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_line = maru.i18n.format(&st.manage_root_note_buf, maru.i18n.t(.lsp_trust_note_root), &.{.{ .s = app_session_mod.homeTildeInto(key.path, &shown_buf) }});
    st.manage_notes[n] = .{ .text = root_line, .fit = .path };
    n += 1;
    const offers_revoke = primary == .revoke or alternate == .revoke;
    const offers_forget = primary == .forget or alternate == .forget;
    if (offers_revoke) {
        st.manage_notes[n] = .{ .text = maru.i18n.t(.lsp_trust_manage_note_revoke) };
        n += 1;
    }
    if (offers_forget) {
        st.manage_notes[n] = .{ .text = maru.i18n.t(.lsp_trust_manage_note_forget) };
        n += 1;
    }
    st.manage_notes[n] = .{ .text = maru.i18n.t(.lsp_trust_manage_note_lower) };
    n += 1;
    st.manage_notes[n] = .{ .text = maru.i18n.t(.lsp_trust_manage_note_irreversible) };
    n += 1;
    self.chrome_host.confirm.notes = st.manage_notes[0..n];
}

/// 관리 상자의 답 — `primary`(Enter·첫 버튼) 또는 `alternate`.
pub fn answerManage(self: *AppSession, slot: enum { primary, alternate }) void {
    const st = &self.editor_lsp;
    const k = st.manage_key orelse return;
    defer clearManage(self);
    const action = switch (slot) {
        .primary => st.manage_primary,
        .alternate => st.manage_alternate orelse return,
    };
    // 상자를 띄운 뒤 다른 창·컨트롤 플레인(WT4b)이 결정을 바꿨을 수 있다 — **지금** 표로 다시 본다. 결정이 없어졌으면 아무것도 안 하고,
    // 철회인데 허용이 아니면 적지 않는다(결정이 없던 저장소에 거부를 새로 세우지 않는다 — `manageCurrent`·컨트롤 철회와 같은 규칙).
    const now_decision = trustOf(self, k.key()) orelse return self.showNoticeKey(.lsp_trust_current_none);
    if (action == .revoke and now_decision != .allow) return self.showNoticeKey(.lsp_trust_current_not_allowed);
    const saved = switch (action) {
        .revoke => recordTrust(self.io, self.configPath(), k.key(), .deny),
        .forget => forgetTrust(self.io, self.configPath(), k.key()),
    };
    // 파일에 못 남았다 — 표에는 서서 서버는 내렸지만 다음 실행은 파일의 옛 결정을 읽는다(철회했는데 허용이 돌아온다). 말 없이 두면
    // 사용자는 거둔 줄 안다.
    if (!saved) self.showNoticeKey(.lsp_trust_manage_not_saved);
    self.metal_dirty = true;
}

/// 관리 상자가 답 없이 닫혔다(취소·다른 상자가 덮었다) — 대상을 놓는다. 아무것도 안 바꾼다.
pub fn clearManage(self: *AppSession) void {
    const st = &self.editor_lsp;
    if (st.manage_key) |k| k.deinit(self.allocator);
    st.manage_key = null;
}

/// 결정을 잊는다(관리 상자의 답) — 앱 전역 표에 「잊었다」를 남긴다. 각 창이 세대를 보고 제 서버를 내린다(`forgetClient`).
/// 파일에 남지 못했으면 `false`.
fn forgetTrust(io: std.Io, config_path: ?[]const u8, key: lsp.trust.Key) bool {
    loadTrust(io, config_path);
    return trust_store.forget(io, key);
}

/// 팔레트 「이 저장소 신뢰 철회·잊기」 — 지금 편집기 문서의 저장소. 할 것이 없으면(언어 서버를 쓰지 않는 문서·결정이 없다·이미 거부다)
/// 알림으로 말하고 상자를 띄우지 않는다.
pub fn manageCurrent(self: *AppSession, action: ManageAction) void {
    if (!self.loaded_config.config.lsp.enabled) return self.showNoticeKey(.lsp_trust_current_disabled);
    if (self.tabs.items.len == 0) return self.showNoticeKey(.lsp_trust_current_unavailable);
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) return self.showNoticeKey(.lsp_trust_current_unavailable);
    const server = serverFor(self, term.rt.editor_grammar) orelse return self.showNoticeKey(.lsp_trust_current_unavailable);
    const root = rootFor(self, term) orelse return self.showNoticeKey(.lsp_trust_current_unavailable);
    const c = clientFor(self, root, server) orelse return self.showNoticeKey(.lsp_trust_current_unavailable);
    const key = trustKey(self, c) orelse return self.showNoticeKey(.lsp_trust_current_unavailable);
    const decision = trustOf(self, key) orelse return self.showNoticeKey(.lsp_trust_current_none);
    if (action == .revoke and decision != .allow) return self.showNoticeKey(.lsp_trust_current_not_allowed);
    askManage(self, key, decision, action);
}

/// 신뢰 목록에서 고른 저장소의 관리 상자 — **지금** 표의 결정으로 띄운다. 목록은 연 순간의 사본이라 그 사이 다른 창이 잊었거나
/// 바꿨을 수 있다(사본대로 띄우면 결정이 없는 저장소를 「철회」해 거부가 새로 선다 — `manageCurrent` 가 거절하는 것). 결정이 없어졌으면
/// 알림.
pub fn manageListed(self: *AppSession, key: lsp.trust.Key) void {
    const decision = trustOf(self, key) orelse return self.showNoticeKey(.lsp_trust_current_none);
    askManage(self, key, decision, null);
}

/// 신뢰 목록이 그릴 표를 읽어 둔다(앱을 띄운 뒤 아직 아무 문서도 신뢰를 보지 않았을 수 있다).
pub fn loadTrustForList(self: *AppSession) void {
    ensureTrustLoaded(self);
}

// ── 컨트롤 플레인(계획 WT4b) ──────────────────────────────────────────────────

const control_trust = maru.session.control_lsp_trust;

/// 컨트롤 플레인 `lsp.trust.*` 에 답한다 — 앱 ABI 가 부른다(ABI 는 표를 모른다 — LSPB23). 창이 없어도 표를 읽는다(2026-10-09 사용자
/// 결정 — 옛 자리 이관에 쓸 설정 경로는 첫 창의 것, 창이 없으면 기본 자리). 효과는 관리 상자(WT4a)와 같은 길이다 — 표의 세대가 오르면
/// 각 창의 pump 가 `applyTrustChanges` 로 따른다(거부면 서버를 내리고, 잊으면 「결정 없음」 — 곧바로 묻지 않는다). **부여는 없다**:
/// 철회는 지금 허용인 결정만 거부로 적고, 잊기는 결정을 지울 뿐이다. 응답을 못 만들면(메모리) `null` — 호출자가 응답 없이 닫는다.
pub fn controlTrust(gpa: std.mem.Allocator, io: std.Io, session: ?*AppSession, request_bytes: []const u8) ?[]u8 {
    var owned_path: ?[]const u8 = null;
    defer if (owned_path) |p| gpa.free(p);
    const config_path: ?[]const u8 = if (session) |sess| sess.configPath() else blk: {
        owned_path = maru.config.loader.defaultConfigPath(gpa) catch null;
        break :blk owned_path;
    };
    loadTrust(io, config_path);
    var impl: ControlTrust = .{ .io = io, .config_path = config_path };
    return control_trust.respond(gpa, request_bytes, &impl) catch null;
}

const ControlTrust = struct {
    io: std.Io,
    config_path: ?[]const u8,
    /// 맞은 키의 경로 사본 — 응답(`repository`)을 다 쓸 때까지 산다(`apply` 의 지역 버퍼면 응답을 쓸 때 이미 풀렸다 — 판정자 LSPB38 이
    /// 잡았다). 표를 고치는 동안 표가 빌려 준 경로를 쥐지 않으려고 복사한다.
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    /// 결정이 있는 항목 전부(표가 빌려 준 경로 — 응답을 쓰는 동안만 산다).
    pub fn entries(_: *ControlTrust, gpa: std.mem.Allocator) ![]control_trust.Entry {
        var list: std.ArrayList(control_trust.Entry) = .empty;
        errdefer list.deinit(gpa);
        var it = trust_store.decided();
        while (it.next()) |e| try list.append(gpa, .{ .volume = e.key.volume, .path = e.key.path, .decision = wireDecision(e.decision) });
        return list.toOwnedSlice(gpa);
    }

    pub fn apply(self: *ControlTrust, op: control_trust.Op, target: control_trust.Target) control_trust.Outcome {
        const key = switch (findTrustKey(target, &self.path_buf)) {
            .none => return .{ .none = .{ .containing = containingDecision(target.path) } },
            .ambiguous => return .ambiguous,
            .one => |k| k,
        };
        const previous = trust_store.get(key).?; // `findTrustKey` 는 결정이 있는 키만 낸다
        const prev_wire = wireDecision(previous);
        const matched: control_trust.Key = .{ .volume = key.volume, .path = key.path };
        const saved = switch (op) {
            .list => unreachable, // `respond` 가 목록은 `entries` 로 답한다
            // 철회는 지금 허용인 결정만 거부로 — 이미 거부면 그대로(다시 적지 않는다; 결정이 없던 저장소는 위에서 「없음」이다 — 관리 상자
            // `manageCurrent` 와 같은 규칙).
            .revoke => if (previous == .allow) recordTrust(self.io, self.config_path, key, .deny) else return .{ .done = .{ .previous = prev_wire, .changed = false, .saved = true, .key = matched } },
            .forget => forgetTrust(self.io, self.config_path, key),
        };
        return .{ .done = .{ .previous = prev_wire, .changed = true, .saved = saved, .key = matched } };
    }
};

/// 그 경로를 품은(자신이 아닌 조상인) 저장소의 결정 — 가장 가까운 것. 결정은 저장소 root 단위라 하위 폴더를 준 사용자에게 알려 준다(바꾸지는
/// 않는다). 경로는 실제 경로로 풀어 본다 — 풀리면 같은 볼륨의 것만(같은 접두의 다른 디스크를 알려 주지 않게), 못 풀면 글자 그대로. 표가
/// 빌려 준 경로를 돌려준다 — 응답을 쓰는 동안만 산다(그 사이 표를 고치지 않는다).
fn containingDecision(path: []const u8) ?control_trust.Entry {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = trust_store.keyFor(path, &buf);
    const real = if (resolved) |k| k.path else path;
    var best: ?control_trust.Entry = null;
    var it = trust_store.decided();
    while (it.next()) |e| {
        if (resolved) |k| if (e.key.volume != k.volume) continue;
        if (std.mem.eql(u8, e.key.path, real) or !selfOrAncestor(e.key.path, real)) continue;
        if (best) |b| if (b.path.len >= e.key.path.len) continue;
        best = .{ .volume = e.key.volume, .path = e.key.path, .decision = wireDecision(e.decision) };
    }
    return best;
}

fn wireDecision(d: lsp.trust.Decision) control_trust.Decision {
    return switch (d) {
        .allow => .allow,
        .deny => .deny,
    };
}

/// 요청이 가리키는 표의 키. 먼저 표에 **그 글자 그대로** 있는 결정(목록이 준 경로 — 지워진 저장소도 잊을 수 있게), 없으면 실제 경로로
/// 풀어 본다(심링크·`/tmp`↔`/private/tmp`·대소문자만 다른 이름 — 사용자가 친 경로). 같은 경로가 여러 볼륨에 있으면 `volume` 이 고른다.
/// 키의 경로는 `buf` 에 복사한다 — 표를 고치는 동안 빌린 경로를 쥐지 않는다.
fn findTrustKey(target: control_trust.Target, buf: *[std.fs.max_path_bytes]u8) union(enum) { none, ambiguous, one: lsp.trust.Key } {
    var found: ?lsp.trust.Key = null;
    var n: usize = 0;
    var it = trust_store.decided();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.key.path, target.path)) continue;
        if (target.volume) |v| if (e.key.volume != v) continue;
        found = e.key;
        n += 1;
    }
    if (n > 1) return .ambiguous;
    if (found) |k| {
        if (k.path.len > buf.len) return .none;
        @memcpy(buf[0..k.path.len], k.path);
        return .{ .one = .{ .volume = k.volume, .path = buf[0..k.path.len] } };
    }
    const k = trust_store.keyFor(target.path, buf) orelse return .none;
    if (target.volume) |v| if (k.volume != v) return .none;
    if (trust_store.get(k) == null) return .none;
    return .{ .one = k };
}

// ── 클라이언트 찾기·띄우기 ───────────────────────────────────────────────────

fn clientFor(self: *AppSession, root: []const u8, server: lsp.servers.Server) ?*Client {
    for (self.editor_lsp.clients.items) |*c| {
        if (std.mem.eql(u8, c.root, root) and std.mem.eql(u8, c.server.exe, server.exe)) return c;
    }
    return null;
}

/// 그 문법의 서버 — 후보 중 찾아지는 첫 것(한 번 고르면 세션 동안 그대로). 이름표가 없으면 `null`. `forGrammar` 대신 **여기**를 쓴다 —
/// 후보가 여럿인 언어(TS 계열)에서 찾아보지 않으면 없는 것을 띄우려 든다.
pub fn serverFor(self: *AppSession, g: maru.session.editor.language.Grammar) ?lsp.servers.Server {
    if (self.editor_lsp.resolved.get(g)) |s| return s;
    // 도구 환경을 담기 전에는 기억하지 않는다(짧은 PATH 로 고른 것이 세션 내내 굳지 않게). 처음 담는 중이면 찾아보지 않고 첫 후보를
    // 내고, 다시 읽는 중이면 이미 담아 둔 환경으로 찾는다 — 첫 후보로 세우면 떠 있는 서버를 두고 새 클라이언트가 생겨 버려진다(7회차).
    if (!tool_env.settled()) {
        if (tool_env.path().len == 0) return lsp.servers.forGrammar(g);
        return lsp.servers.resolve(g, {}, struct {
            fn f(_: void, exe: []const u8) bool {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                return lsp_process.locate(exe, tool_env.path(), &buf) != null;
            }
        }.f);
    }
    const picked = lsp.servers.resolve(g, {}, struct {
        fn f(_: void, exe: []const u8) bool {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            return lsp_process.locate(exe, tool_env.path(), &buf) != null;
        }
    }.f) orelse return null;
    self.editor_lsp.resolved.set(g, picked);
    return picked;
}

/// 「없음」인 클라이언트가 다른 후보의 설치를 볼 수 있게 — 다시 골라 달라졌으면 그 서버로 바꾼다(프로세스는 아직 없으니 이름만 바뀐다). 바뀌었으면 true.
fn repickIfMissing(self: *AppSession, c: *Client) bool {
    const g = c.grammar;
    if (g == .none) return false;
    self.editor_lsp.resolved.set(g, null);
    const picked = serverFor(self, g) orelse return false;
    if (std.mem.eql(u8, picked.exe, c.server.exe)) return false;
    // 그 서버의 클라이언트가 이 root 에 이미 있다(다른 문법의 문서가 세웠다 — TS·JS) — 이름을 바꾸면 같은 (root, 서버) 가 둘이 된다
    // (설치하고 다시 읽는 흐름 — 8회차). 이것은 「없음」으로 남고 문서는 다음 sync 가 다시 고른 서버의 클라이언트로 보낸다.
    if (clientFor(self, c.root, picked) != null) return false;
    c.server = picked;
    return true;
}

fn ensureClient(self: *AppSession, root: []const u8, server: lsp.servers.Server, grammar: maru.session.editor.language.Grammar) ?*Client {
    if (clientFor(self, root, server)) |c| return c;
    // 셸 환경을 담기 전에 첫 후보 이름으로 만든 「준비 중」 클라이언트(`serverFor` 는 담기 전에 찾아보지 않는다) — 담은 뒤 고른 서버로
    // 이어 쓴다. 새로 만들면 그것이 gate 를 다시 안 지나 「준비 중」으로 버려진 채 남는다(TS 처럼 후보가 여럿인 언어 — 6회차 적대적 검증).
    // 문법이 아니라 그 **첫 후보 이름**으로 찾는다 — TS·TSX·JS 는 서버를 나눠 써 다른 문법의 문서가 세운 클라이언트일 수 있다(7회차).
    const tentative = lsp.servers.candidatesFor(grammar);
    if (tentative.len > 0) for (self.editor_lsp.clients.items) |*c| if (c.phase == .preparing and c.proc == null and std.mem.eql(u8, c.root, root) and std.mem.eql(u8, c.server.exe, tentative[0].exe)) {
        c.server = server;
        return c;
    };
    const owned = self.allocator.dupe(u8, root) catch return null;
    self.editor_lsp.clients.append(self.allocator, .{ .root = owned, .server = server, .phase = .restarting, .grammar = grammar }) catch {
        self.allocator.free(owned);
        return null;
    };
    return &self.editor_lsp.clients.items[self.editor_lsp.clients.items.len - 1];
}

fn spawnClient(self: *AppSession, c: *Client, now_ms: u64) void {
    if (!trustKeyHolds(self, c)) return;
    // 환경을 담기 전에는 띄우지 않는다(gate 가 먼저 막지만 문서 없이 재시작을 기다리던 클라이언트도 여기로 온다).
    const env = tool_env.envp() orelse {
        c.phase = .preparing;
        return;
    };
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = lsp_process.locate(c.server.exe, tool_env.path(), &pbuf) orelse {
        c.phase = .missing;
        return;
    };
    const proc = lsp_process.spawn(self.allocator, exe, c.server.args, c.root, env) catch {
        scheduleRestart(self, c, now_ms);
        return;
    };
    c.proc = proc;
    c.inbuf.clearRetainingCapacity();
    c.encoding = .utf16;
    c.shutdown_at_ms = 0;
    c.started_at_ms = now_ms;
    c.phase = .starting;
    // 열려 있던 문서는 다시 열어야 한다(새 프로세스는 모른다).
    for (c.docs.items) |*d| d.sent_version = 0;
    var uri_buf: [std.fs.max_path_bytes * 3]u8 = undefined;
    const root_uri = fileUriBuf(c.root, &uri_buf) orelse return;
    const msg = lsp.rpc.initializeRequest(self.allocator, root_uri, @intCast(std.c.getpid())) catch return;
    defer self.allocator.free(msg);
    _ = send(self, c, msg);
}

fn scheduleRestart(self: *AppSession, c: *Client, now_ms: u64) void {
    _ = self;
    if (c.restarts >= max_restarts) {
        c.phase = .failed;
        return;
    }
    c.retry_at_ms = now_ms + backoff_ms[@min(c.restarts, backoff_ms.len - 1)];
    c.restarts += 1;
    c.phase = .restarting;
}

fn dropProcess(self: *AppSession, c: *Client) void {
    if (c.proc) |*p| {
        // 곧바로 그룹째 내린다 — 서버만 죽이면 그 빌드(zig build·cargo check)가 고아로 남는다. 거두기는 메인 스레드 밖에서.
        var l = lsp_process.handOff(p, self.allocator);
        lowerOffMain(self, (&l)[0..1], 0);
        c.proc = null;
        releaseWaiting(self, c);
    }
    c.inbuf.clearRetainingCapacity();
}

/// 떼어 낸 서버들을 내린다. 제품에서는 **메인 스레드를 막지 않는다**(detach 된 거두기 스레드 — 창 닫기·끄기·죽은 서버) — 다만 앱
/// 종료가 확정됐으면 창이 이미 내려갔고 곧 프로세스가 끝나므로 이 자리에서 기다린다(스레드가 끝나기 전에 앱이 끝나면 그룹 SIGKILL 이
/// 안 간다). 판정자도 이 자리에서 기다린다(거두기가 판정자보다 오래 살지 않게 — `detached_worker_wait` 의 규율).
fn lowerOffMain(self: *AppSession, items: []lsp_process.Lowering, grace_ms: u64) void {
    _ = self;
    if (lowerWaitsInPlace(app_session_mod.appQuitting(), builtin.is_test)) lsp_process.lowerAll(items, grace_ms) else lsp_process.lowerDetached(items, grace_ms);
}

/// 내리기를 이 자리에서 기다리나(위 `lowerOffMain` 의 갈림 — 판정자가 앱 종료 갈래를 따로 잴 수 있게 떼어 둔다).
pub fn lowerWaitsInPlace(app_quitting: bool, in_test: bool) bool {
    return app_quitting or in_test;
}

/// 서버가 내려갔다 — 그 서버의 응답을 기다리던 요청을 놓는다. 응답은 오지 않으므로, 안 놓으면 그 문서의 semantic 색·인레이·
/// 심볼·접기·같은 낱말 강조·자동완성이 **다시는 요청되지 않는다**(각 모듈은 기다리는 동안 새 요청을 막고, 응답에서만 그 막음을
/// 푼다). 문서마다 다시 그리는 넷은 `dirty` 로 두어 다음 서버가 뜨면 다시 묻게 하고, 강조는 caret 의 조용 시계가, 자동완성은 다음
/// 타이핑이 다시 묻는다(시한이 있는 hover·smart select, `hide` 가 푸는 signature, 막지 않는 나머지는 해당 없다).
fn releaseWaiting(self: *AppSession, c: *Client) void {
    for (c.docs.items) |d| for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!d.matches(term)) continue;
        const rt = &term.rt;
        if (rt.editor_semantic.waiting) {
            rt.editor_semantic.waiting = false;
            rt.editor_semantic.dirty = true;
        }
        if (rt.editor_inlay.waiting) {
            rt.editor_inlay.waiting = false;
            rt.editor_inlay.dirty = true;
        }
        if (rt.editor_symbols.waiting) {
            rt.editor_symbols.waiting = false;
            rt.editor_symbols.dirty = true;
        }
        if (rt.editor_fold_lsp.waiting) {
            rt.editor_fold_lsp.waiting = false;
            rt.editor_fold_lsp.dirty = true;
        }
        rt.editor_highlight.waiting = false; // 강조는 caret 의 조용 시계가 다시 묻는다
        // 자동완성은 세션에 하나 — 기다리던 것이 **이 문서**의 요청일 때만 놓는다(다른 서버의 응답을 버리지 않게).
        const comp = &self.editor_completion;
        if (comp.waiting and comp.waiting_surface == term.surfaceId()) {
            comp.waiting = false;
            comp.dirty = false;
        }
    };
}

fn fileUriBuf(path: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    const prefix = "file://";
    if (buf.len < prefix.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    n = prefix.len;
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (keep) {
            if (n >= buf.len) return null;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) return null;
            _ = std.fmt.bufPrint(buf[n..], "%{X:0>2}", .{ch}) catch return null;
            n += 3;
        }
    }
    return buf[0..n];
}

/// 프레임을 씌워 보낸다. 자식이 죽었으면 `false`.
fn send(self: *AppSession, c: *Client, body: []const u8) bool {
    const p = &(c.proc orelse return false);
    var hdr: [64]u8 = undefined;
    const hn = lsp.framing.writeHeader(body.len, &hdr) orelse return false;
    if (!(lsp_process.write(p, self.allocator, hdr[0..hn]) catch return false)) return false;
    return lsp_process.write(p, self.allocator, body) catch false;
}

// ── tick ──────────────────────────────────────────────────────────────────────

/// 세션 tick — `AppSession.tick` 이 부른다.
pub fn pump(self: *AppSession) void {
    if (!self.loaded_config.config.lsp.enabled) {
        // 꺼졌다 — 떠 있는 서버를 내린다. 그대로 두면 아무도 stdout 을 안 읽는 서버가 앱 종료까지 남는다.
        if (self.editor_lsp.clients.items.len > 0) stopAll(self);
        return;
    }
    const now_ms = self.awakeMs();
    // 도구 환경(사용자 셸 환경 — 계획 WT3b)의 결과를 받기만 한다. **시작은 gate 가 한다** — 서버가 필요한 문서가 신뢰 범위 안에 생겼을
    // 때만(편집기를 안 쓰는 실행·홈 루트·저장소 밖 문서에서 사용자 셸 설정을 돌리지 않는다 — 계획 「언제」). 따로 다시 판정시킬 것은
    // 없다 — 「준비 중」·「없음」 클라이언트는 문서가 열려 있으면 gate 가 매 tick 다시 찾고(문서가 닫힌 것은 다시 열 때), 기억해 둔
    // 서버가 새 환경에서 없어지면 `repickIfMissing` 이 그 기억을 비운다. 읽기 시작했거나 다 됐으면(어느 창이 시작했든·받았든) 이 창의 상태바를 다시 그린다.
    tool_env.poll();
    if (tool_env.changeCount() != self.editor_lsp.seen_env_change) {
        self.editor_lsp.seen_env_change = tool_env.changeCount();
        self.metal_dirty = true;
    }
    applyTrustChanges(self);
    // 묻던 창이 포커스를 잃었다(다른 창으로 갔다·퀵 터미널이 숨었다) — 자리를 내놓는다(답이 아니다 — 기억하지 않는다). 그 저장소를 기다리는
    // key 창이 다음 pump 에 묻고, 이 창으로 돌아오면 이 창이 다시 묻는다.
    if (self.editor_lsp.asking_key != null and !self.window_focused) dropTrustPrompt(self);
    syncDocuments(self, now_ms);
    var i: usize = 0;
    while (i < self.editor_lsp.clients.items.len) : (i += 1) {
        const c = &self.editor_lsp.clients.items[i];
        pumpClient(self, c, now_ms);
    }
}

/// 스위치 `lsp.shell-environment` — 사용자의 명시 행동(세팅 토글·행 되돌리기·Reload Config(파일 감시 자동 reload 포함)·전체 리셋)만 부른다(앱 전역 — `tool_env.setEnabled`).
pub fn setShellEnvironmentEnabled(value: bool) void {
    tool_env.setEnabled(value);
}

/// 앱 전역 스위치의 지금 값 — 아직 아무도 정하지 않았으면 `null`. 세팅 화면이 창의 설정 미러를 되맞춘다(다른 창에서 바꾼 값).
pub fn shellEnvironmentOverride() ?bool {
    return tool_env.enabledOverride();
}

/// 팔레트 「Language Server: Reload Shell Environment」 — 사용자 셸 환경을 다시 읽는다(셸 설정을 고친 뒤). 떠 있는 서버는 다시 띄울 때
/// 새 환경을 쓴다.
pub fn reloadShellEnvironment(self: *AppSession) void {
    if (!self.loaded_config.config.lsp.enabled) return self.showNoticeKey(.lsp_reload_env_disabled);
    tool_env.reload(self.loaded_config.config.lsp.shell_environment);
    self.metal_dirty = true;
}

fn pumpClient(self: *AppSession, c: *Client, now_ms: u64) void {
    switch (c.phase) {
        .restarting => if (!c.trust_pending and now_ms >= c.retry_at_ms) spawnClient(self, c, now_ms),
        .starting, .ready => {},
        .missing, .preparing, .asking, .denied, .failed, .home_root, .outside_repo, .unasked => return,
    }
    const p = &(c.proc orelse return);
    // 밀린 쓰기가 상한을 넘었다 — 서버가 stdin 을 안 읽는다. 죽은 것으로 보고 재시작 경로로(§8.2a).
    if (p.stalled) {
        onDied(self, c, now_ms);
        return;
    }
    // 유휴 종료(§8.2a): 마지막 문서가 닫힌 지 30 초면 shutdown → exit. 응답이 없으면 5 초 뒤 SIGKILL.
    if (c.docs.items.len == 0 and c.idle_since_ms != 0 and c.shutdown_at_ms == 0 and now_ms - c.idle_since_ms >= idle_shutdown_ms) {
        const msg = lsp.rpc.shutdownRequest(self.allocator) catch return;
        defer self.allocator.free(msg);
        _ = send(self, c, msg);
        c.shutdown_at_ms = now_ms;
    }
    if (c.shutdown_at_ms != 0 and now_ms - c.shutdown_at_ms >= kill_grace_ms) {
        dropProcess(self, c);
        c.phase = .restarting;
        c.retry_at_ms = std.math.maxInt(u64); // 문서가 열리면 다시 띄운다(`syncDocuments` 가 0 으로 되돌린다)
        c.restarts = 0;
        return;
    }
    if (!(lsp_process.flush(p, self.allocator) catch false)) {
        onDied(self, c, now_ms);
        return;
    }
    const r = lsp_process.readInto(p, self.allocator, &c.inbuf, read_budget_per_tick) catch return;
    if (r == .eof or lsp_process.reapIfExited(p)) {
        onDied(self, c, now_ms);
        return;
    }
    drainFrames(self, c, now_ms);
    // `initialize` 에 답이 없다 — 멈춘 서버로 보고 재시작 경로로(`initialize_timeout_ms`). 이 tick 에 읽은 것을 **다 처리한 뒤**
    // 판정한다 — 메인 스레드가 오래 멈췄다 깨어난 tick 에 이미 와 있는 응답을 버리고 죽이지 않게.
    if (c.proc != null and c.phase == .starting and now_ms -| c.started_at_ms >= initialize_timeout_ms) {
        dropProcess(self, c);
        scheduleRestart(self, c, now_ms);
        self.metal_dirty = true;
    }
}

fn onDied(self: *AppSession, c: *Client, now_ms: u64) void {
    const was_shutting_down = c.shutdown_at_ms != 0;
    dropProcess(self, c);
    if (was_shutting_down) {
        // 우리가 끝낸 것 — 재시작 예약 없이 잠든다. 문서가 열리면 `syncDocuments` 가 깨운다.
        c.phase = .restarting;
        c.retry_at_ms = std.math.maxInt(u64);
        c.restarts = 0;
        c.shutdown_at_ms = 0;
        return;
    }
    scheduleRestart(self, c, now_ms);
    self.metal_dirty = true;
}

fn drainFrames(self: *AppSession, c: *Client, now_ms: u64) void {
    _ = now_ms;
    while (true) {
        const frame = lsp.framing.next(c.inbuf.items) catch {
            // 못 믿는 스트림 — 죽이고 재시작 경로로.
            dropProcess(self, c);
            scheduleRestart(self, c, self.awakeMs());
            return;
        } orelse break;
        handleFrame(self, c, frame.body);
        // handleFrame 이 죽였을 수 있다(initialize 거절 등) — 그러면 `inbuf` 도 비었으니 프레임을 당기기 **전에** 나간다.
        if (c.proc == null) return;
        const rest = c.inbuf.items.len - frame.consumed;
        std.mem.copyForwards(u8, c.inbuf.items[0..rest], c.inbuf.items[frame.consumed..]);
        c.inbuf.shrinkRetainingCapacity(rest);
    }
}

fn handleFrame(self: *AppSession, c: *Client, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
    defer parsed.deinit();
    switch (lsp.rpc.classify(parsed.value)) {
        .response => |r| switch (r.id) {
            .initialize => {
                if (r.is_error) {
                    // 서버가 initialize 를 **거절**했다 — 다시 띄워도 같은 답이라 재시작하지 않고 「실패 — 다시」로 선다(클릭으로 재시도).
                    // 그대로 두면 살아 있는 서버가 「시작 중」에 영원히 남는다.
                    dropProcess(self, c);
                    c.phase = .failed;
                    self.metal_dirty = true;
                    return;
                }
                c.encoding = lsp.rpc.positionEncodingFromResult(r.result);
                c.signature_triggers = lsp.rpc.signatureTriggersFromResult(r.result); // §8.2d — 트리거 글자는 서버가 준다
                c.formatting_supported = lsp.rpc.formattingSupported(r.result); // §8.2e
                c.rename_supported = lsp.rpc.renameSupported(r.result); // §8.2f
                c.completion_triggers = lsp.rpc.completionTriggersFromResult(r.result); // §8.2g
                c.code_action_caps = lsp.rpc.codeActionCapsFromResult(r.result); // §8.2h
                c.semantic_caps.deinit(self.allocator); // 재시작이면 옛 표를 놓는다
                c.semantic_caps = lsp.semantic.capsFromResult(self.allocator, r.result) catch .{}; // §8.2i
                c.fold_supported = lsp.fold_range.supportedFromResult(r.result); // §8.2j
                c.implementation_supported = lsp.rpc.locationProviderSupported(r.result, .implementation); // §8.2m
                c.type_definition_supported = lsp.rpc.locationProviderSupported(r.result, .type_definition);
                c.declaration_supported = lsp.rpc.locationProviderSupported(r.result, .declaration);
                c.save_caps = lsp.rpc.saveCapsFromResult(r.result); // §8.2k
                c.inlay_supported = lsp.inlay.supportedFromResult(r.result); // §8.2n
                c.symbols_supported = lsp.symbols.supportedFromResult(r.result); // §8.2o
                c.highlight_supported = lsp.highlight.supportedFromResult(r.result); // §8.2p
                c.selection_range_supported = lsp.selection_range.supportedFromResult(r.result); // §8.2q
                c.phase = .ready;
                c.restarts = 0;
                const msg = lsp.rpc.initializedNotification(self.allocator) catch return;
                defer self.allocator.free(msg);
                _ = send(self, c, msg);
                // 서버별 설정 블롭(§8.2n 「서버 설정」) — TS 계열은 힌트를 켜야 낸다. `initialized` 뒤 한 번.
                if (lsp.rpc.didChangeConfigurationFor(self.allocator, c.server.language_id) catch null) |cfg| {
                    defer self.allocator.free(cfg);
                    if (send(self, c, cfg)) self.editor_lsp.sent_configs += 1;
                }
                self.metal_dirty = true;
            },
            .shutdown => {
                const msg = lsp.rpc.exitNotification(self.allocator) catch return;
                defer self.allocator.free(msg);
                _ = send(self, c, msg);
            },
            .code_action => |seq| {
                self.editor_lsp.received_code_actions += 1;
                editor_code_action.onResponse(self, seq, if (r.is_error) null else r.result, r.is_error, r.error_message);
            },
            .code_action_resolve => |seq| {
                editor_code_action.onResolveResponse(self, seq, if (r.is_error) null else r.result, r.is_error, r.error_message, c.encoding);
            },
            .completion => |seq| {
                self.editor_lsp.received_completions += 1;
                editor_completion.onResponse(self, seq, if (r.is_error) null else r.result, c.encoding);
            },
            // error 응답은 result 가 없다(JSON-RPC) — `is_error` 가드는 둘을 함께 실은 서버에 대한 방어(적대적 3회차 C2: 등가).
            .completion_resolve => |seq| editor_completion.onResolveResponse(self, seq, if (r.is_error) null else r.result, c.encoding),
            .semantic_tokens => |seq| {
                self.editor_lsp.received_semantic += 1;
                // 어느 문서의 것인지는 seq 로 — 문서마다 대기 seq 하나(§8.2i).
                // `is_error` 는 방어 — 오류 응답은 `result` 가 없어 `null` 만으로도 버려진다(적대적 3회차 C2: 등가).
                if (termWaitingSemantic(self, c, seq)) |t| editor_semantic.onResponse(self, t, seq, r.result, r.is_error, c.encoding);
            },
            .inlay_hint => |seq| {
                self.editor_lsp.received_inlay += 1;
                if (termWaitingInlay(self, c, seq)) |t| editor_inlay.onResponse(self, t, seq, r.result, r.is_error, c.encoding);
            },
            .document_highlight => |seq| {
                self.editor_lsp.received_highlight += 1;
                if (termWaitingHighlight(self, c, seq)) |t| editor_highlight.onResponse(self, t, seq, r.result, r.is_error, c.encoding);
            },
            .selection_range => |seq| {
                self.editor_lsp.received_selection_range += 1;
                if (termWaitingSelectionRange(self, c, seq)) |t| editor_smart_select.onResponse(self, t, seq, r.result, r.is_error, c.encoding);
            },
            .document_symbol => |seq| {
                self.editor_lsp.received_symbols += 1;
                if (termWaitingSymbols(self, c, seq)) |t| editor_symbols.onResponse(self, t, seq, r.result, r.is_error, c.encoding);
            },
            .folding_range => |seq| {
                self.editor_lsp.received_folding += 1;
                if (termWaitingFolding(self, c, seq)) |t| editor_fold_lsp.onResponse(self, t, seq, r.result, r.is_error);
            },
            .rename => |seq| {
                self.editor_lsp.received_renames += 1;
                editor_rename.onResponse(self, seq, if (r.is_error) null else r.result, r.is_error, r.error_message, c.encoding);
            },
            .formatting => |seq| {
                self.editor_lsp.received_formattings += 1;
                // 오류 응답은 결과 없음과 같다. JSON-RPC 2.0 은 `error` 가 있으면 `result` 가 **없어야** 한다고 하므로 이 가드를 지워도
                // 동작이 같다(적대적 2회차 B17 등가) — 명세를 어기는 서버에 대한 방어로 남긴다.
                editor_format.onResponse(self, seq, if (r.is_error) null else r.result, c.encoding);
            },
            .signature => |seq| {
                self.editor_lsp.received_signatures += 1;
                const view: ?lsp.rpc.SignatureView = if (r.is_error) null else lsp.rpc.signatureView(r.result, c.encoding);
                editor_signature.onResponse(self, seq, view);
            },
            .references => |seq| {
                self.editor_lsp.received_references += 1;
                editor_references.onLocationsResponse(self, .references, seq, if (r.is_error) null else r.result, r.is_error and lsp.rpc.isRetryableError(r.error_code));
            },
            .implementation => |seq| {
                self.editor_lsp.received_references += 1;
                editor_references.onLocationsResponse(self, .implementation, seq, if (r.is_error) null else r.result, r.is_error and lsp.rpc.isRetryableError(r.error_code));
            },
            .type_definition => |seq| {
                self.editor_lsp.received_references += 1;
                editor_references.onLocationsResponse(self, .type_definition, seq, if (r.is_error) null else r.result, r.is_error and lsp.rpc.isRetryableError(r.error_code));
            },
            .declaration => |seq| {
                self.editor_lsp.received_references += 1;
                editor_references.onLocationsResponse(self, .declaration, seq, if (r.is_error) null else r.result, r.is_error and lsp.rpc.isRetryableError(r.error_code));
            },
            .definition => |seq| {
                self.editor_lsp.received_definitions += 1;
                const target: ?lsp.rpc.Target = if (r.is_error) null else lsp.rpc.definitionTarget(r.result);
                editor_definition.onDefinitionResponse(self, seq, target, c.encoding);
            },
            .hover => |seq| {
                // 낡은 응답(다른 seq)·에러·빈 내용은 전부 「내용 없음」으로 호버 층에 넘긴다 — 판정은 그쪽이 한다(§8.2b 「요청」).
                const md: ?[]u8 = if (r.is_error) null else lsp.rpc.hoverMarkdown(self.allocator, r.result) catch null;
                defer if (md) |m| self.allocator.free(m);
                self.editor_lsp.received_hovers += 1;
                editor_hover.onHoverResponse(self, seq, md, lsp.rpc.hoverRange(r.result), c.encoding);
            },
        },
        .notification => |n| {
            if (std.mem.eql(u8, n.method, "textDocument/publishDiagnostics")) onPublishDiagnostics(self, c, n.params);
        },
        .request => |q| {
            // §8.2n — `workspace/inlayHint/refresh` 는 받는다: `null` 로 답하고 이 클라이언트의 모든 편집기 힌트를 다시 묻게 한다.
            if (std.mem.eql(u8, q.method, lsp.rpc.inlay_refresh_method)) {
                self.editor_lsp.inlay_refreshes += 1;
                const ok = lsp.rpc.nullResult(self.allocator, q.id) catch return;
                defer self.allocator.free(ok);
                _ = send(self, c, ok);
                forEachDocTerm(self, c, editor_inlay.onRefresh);
                self.metal_dirty = true;
                return;
            }
            // §8.2a 「하지 않는 것」 — 나머지는 전부 거부.
            self.editor_lsp.rejected_requests += 1;
            const msg = lsp.rpc.methodNotFound(self.allocator, q.id) catch return;
            defer self.allocator.free(msg);
            _ = send(self, c, msg);
        },
        .ignore => {},
    }
}

fn onPublishDiagnostics(self: *AppSession, c: *Client, params: ?std.json.Value) void {
    const p = params orelse return;
    const obj = switch (p) {
        .object => |o| o,
        else => return,
    };
    const uri = switch (obj.get("uri") orelse return) {
        .string => |s| s,
        else => return,
    };
    const doc = for (c.docs.items) |*d| {
        if (std.mem.eql(u8, d.uri, uri)) break d;
    } else return; // 모르는 문서(root 밖·닫힌 것) — 무시(§8.2a)
    var accepted = false;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!doc.matches(term)) continue;
        const opened = term.rt.editorDocument().opened orelse continue;
        if (obj.get("version")) |v| switch (v) {
            .integer => |n| if (n != @as(i64, @intCast(term.rt.editorDocument().notifications.lsp_version))) continue,
            else => {},
        };
        accepted = true;
        const st = &term.rt.editor_diagnostics;
        st.lsp.clearRetainingCapacity();
        st.lsp_messages.clearRetainingCapacity();
        _ = lsp.position.appendDiagnostics(self.allocator, p, opened.file.content, opened.file.lines, c.encoding, &st.lsp, &st.lsp_messages) catch {};
        st.lsp_dirty = true;
    };
    if (accepted) {
        self.editor_lsp.received_diagnostics += 1;
        self.metal_dirty = true;
    }
}

// ── 문서 동기화 ───────────────────────────────────────────────────────────────

fn syncDocuments(self: *AppSession, now_ms: u64) void {
    // 열린 편집기 Term 을 전부 훑는다 — 서버가 필요한 것에 클라이언트를 붙이고(신뢰 거쳐), 문서를 연다/바뀐 것을 보낸다.
    var seen = std.AutoHashMapUnmanaged(u64, void){};
    defer seen.deinit(self.allocator);
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) continue;
                const server = serverFor(self, term.rt.editor_grammar) orelse continue;
                const root = rootFor(self, term) orelse continue;
                const c = ensureClient(self, root, server, term.rt.editor_grammar) orelse continue;
                seen.put(self.allocator, term.surfaceId(), {}) catch return;
                // 시작/재연결·크기 제한 중에도 살아 있는 뷰가 연결의 수명을 유지한다.
                if (c.findDoc(term)) |doc| doc.surface_id = term.surfaceId();
                if (c.docs.items.len == 0 and c.idle_since_ms != 0) c.idle_since_ms = 0;
                if (c.retry_at_ms == std.math.maxInt(u64)) c.retry_at_ms = 0; // 잠들어 있던 서버를 깨운다
                gateTrust(self, c);
                if (c.phase != .ready) continue;
                syncOne(self, c, term, .coalesce);
            }
        }
    }
    // 닫힌 문서 → didClose. 마지막 문서가 닫히면 유휴 시계를 켠다.
    for (self.editor_lsp.clients.items) |*c| {
        var i: usize = 0;
        while (i < c.docs.items.len) {
            const d = c.docs.items[i];
            if (seen.contains(d.surface_id)) {
                i += 1;
                continue;
            }
            if (c.phase == .ready) {
                const msg = lsp.rpc.didClose(self.allocator, d.uri) catch null;
                if (msg) |m| {
                    defer self.allocator.free(m);
                    _ = send(self, c, m);
                }
            }
            d.release(self.allocator);
            _ = c.docs.swapRemove(i);
        }
        if (c.docs.items.len == 0 and c.idle_since_ms == 0) c.idle_since_ms = now_ms;
    }
}

/// 신뢰 게이트(§8.2a): 결정이 없으면 묻고(모달 하나만 — 다른 root 는 기다린다), 거부면 `denied`, 허용이면 띄울 수 있게 둔다.
fn gateTrust(self: *AppSession, c: *Client) void {
    switch (c.phase) {
        .restarting, .missing, .preparing => {},
        else => return,
    }
    if (c.proc != null) return;
    const key = trustKey(self, c) orelse {
        // 실제 경로를 못 구했다(root 가 사라졌다·못 연다) — 무엇을 신뢰하는지 모르므로 띄우지 않는다. 「실패 — 다시」로 세워 tick 마다
        // 다시 풀지 않고, 누르면 다시 시도한다.
        c.trust_pending = true;
        c.phase = .failed;
        return;
    };
    // 묻지 않는 root(계획 WT2b) — 「설치」보다 먼저 이유를 보인다(서버가 있어도 어차피 안 띄운다).
    if (!c.scope_checked) {
        if (refusalFor(c.root, key.path)) |why| {
            // 여기 닿는 클라이언트는 문서가 없다 — 판정 전 클라이언트는 아직 안 떴고, 판정을 다시 하게 된 클라이언트(`rekeyRoot`)는 그때
            // 옛 진단·문서를 걷었다.
            c.trust_pending = false;
            c.reask = false;
            c.phase = why;
            return;
        }
        c.scope_checked = true;
    }
    // 사용자 셸 환경을 담는 중이면 「없음」을 판정하지 않는다(계획 WT3b) — 담으면 다음 gate 가 그 환경으로 찾는다. 처음이면 여기서 시작한다
    // (서버가 필요한 문서가 처음 생긴 순간 — 셸을 안 띄우는 경우는 그 자리에서 정해져 같은 gate 가 바로 이어 간다).
    if (!tool_env.settled()) {
        tool_env.tick(self.loaded_config.config.lsp.shell_environment);
        if (!tool_env.settled()) {
            c.phase = .preparing;
            return;
        }
    }
    // 실행 파일이 없으면 신뢰를 묻지 않는다 — 「설치」가 먼저다. 없는 채면 다른 후보가 생겼는지 다시 고른다(TS 계열 — §8.2a 「서버 찾기」).
    // 사용자 셸 환경의 PATH 로 찾는다. 찾기는 실행이 아니므로 저장소 아래 PATH 항목도 거르지 않는다 — 거르면 저장소 안에 설치한 서버가
    // 늘 「없음」이라 신뢰를 묻지도 못한다(LSPB9 가 드러냈다). 신뢰 전에 실행하는 일(WT5 의 버전 조회)이 `shell_env.pathWithout` 을 쓴다.
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (lsp_process.locate(c.server.exe, tool_env.path(), &pbuf) == null) {
        if (!repickIfMissing(self, c) or lsp_process.locate(c.server.exe, tool_env.path(), &pbuf) == null) {
            c.phase = .missing;
            return;
        }
    }
    if (c.phase == .missing or c.phase == .preparing) c.phase = .restarting; // 설치된 것을 이제 봤다
    const stored = if (c.reask) null else trustOf(self, key);
    const decision = stored orelse {
        if (builtin.is_test) if (self.editor_lsp.auto_trust_answer) |ans| {
            _ = recordTrust(self.io, self.configPath(), key, ans);
            c.trust_pending = false;
            c.reask = false;
            if (ans == .deny) c.phase = .denied;
            return;
        };
        c.trust_pending = true; // 답이 올 때까지 **띄우지 않는다** — 다른 root 의 모달이 먼저라도 같다
        if (self.editor_lsp.asking_key) |asking| {
            if (asking.key().eql(key)) c.phase = .asking; // 같은 저장소의 다른 서버 — 그 모달이 답이다
            return; // 한 번에 하나
        }
        // 묻는 것은 **지금 보고 있는 창(key 창)** 뿐이다 — 뒤쪽 창·숨은 퀵 터미널이 물으면 사용자는 모달을 못 찾고 모든 창이 「허락 대기」로
        // 멈춘다. 다른 창은 그 답을 기다리고, 포커스가 오면 묻는다(묻던 창이 포커스를 잃으면 자리를 내놓는다 — `pump`).
        if (!self.window_focused) return;
        // 다른 창이 같은 저장소를 묻고 있으면 그 답을 기다린다(두 창이 같은 저장소를 동시에 묻지 않게 — 계획 WT2). 할당 전에 본다 —
        // 기다리는 창이 tick 마다 복사했다 버리지 않게.
        if (trust_store.claimant(key)) |o| if (o != trustOwner(self)) return;
        // 다른 오버레이(알림 토스트·팔레트·설정)가 떠 있으면 **기다린다** — 지금 띄우면 그쪽이 우리 모달을 닫고(`showNotice` →
        // `cancelPendingClose`) 다음 tick 에 또 띄워 깜빡인다(캡처 하니스에서 실측: 작업 공간 복원 알림과 겹쳤다).
        if (self.anyOverlayOpen()) return;
        // 묻기 직전에 키를 다시 푼다 — 처음 구한 뒤 심링크 대상이 바뀌었으면 옛 대상을 묻게 되고, 답이 옛 대상에 기록된다(「다시 묻기」가
        // 그렇게 사용자가 거부했던 저장소를 허용으로 뒤집었다).
        if (!trustKeyHolds(self, c)) return;
        const owned_root = self.allocator.dupe(u8, c.root) catch return;
        const owned_key = OwnedKey.dupe(self.allocator, key) catch {
            self.allocator.free(owned_root);
            return;
        };
        // 답이 오면 표에 결정이 서고, 답 없이 닫히면 자리가 비어 다음 gate 가 여기서 묻는다.
        if (!trust_store.claim(key, trustOwner(self))) {
            self.allocator.free(owned_root);
            owned_key.deinit(self.allocator);
            return;
        }
        self.editor_lsp.asking_root = owned_root;
        self.editor_lsp.asking_key = owned_key;
        c.phase = .asking;
        var msg_buf: [512]u8 = undefined;
        const text = maru.i18n.format(&msg_buf, maru.i18n.t(.lsp_trust_prompt), &.{.{ .s = c.server.exe }});
        self.showConfirmText(.lsp_trust, text, .{ .confirm = .lsp_trust_allow, .cancel = .lsp_trust_deny });
        // 이 시트는 **비동기로 뜬다**(문서를 열고 서버를 찾은 뒤) — 사용자가 편집기에 치던 Enter·`y`·화살표가 그대로 「허용」이 되면
        // 안 된다(`guardAsync` — 거부 포커스·글자 단축키 없음·키보드 허용은 한 번 더 묻는다). 잘못 들어간 Enter 는 거부로 기억되고
        // 상태바에서 다시 물을 수 있다(보수적인 쪽 — tooling §8.2a).
        self.chrome_host.confirm.guardAsync(maru.i18n.t(.lsp_trust_recheck));
        setTrustSheetNotes(self, c.root); // `show` 가 안내를 비우므로 그 뒤에 채운다
        return;
    };
    c.trust_pending = false;
    if (decision == .deny) c.phase = .denied;
}

/// 밀린 쓰기가 있을 때 전문 didChange 를 어떻게 하나. `.coalesce` 는 tick 의 동기화 — 밀린 것이 빠질 때까지 **새로 쌓지 않는다**
/// (Full sync 라 나중의 전문 하나가 앞의 것들을 대신한다; §8.2a 「프레임당 한 번 최신 본문」). `.now` 는 위치 요청 직전 — 서버가
/// 지금 본문을 알아야 그 요청의 위치가 맞으므로 밀려 있어도 보낸다.
const SyncMode = enum { coalesce, now };

fn syncOne(self: *AppSession, c: *Client, term: *Term, mode: SyncMode) void {
    const opened = term.rt.editorDocument().opened orelse return;
    if (opened.file.content.len > max_sync_bytes) return; // §8.2a: 상한 넘는 문서는 안 보낸다
    const version: u64 = term.rt.editorDocument().notifications.lsp_version;
    if (c.findDoc(term)) |d| {
        d.surface_id = term.surfaceId(); // 한 뷰 종료 뒤에도 살아 있는 대표를 갱신한다.
        if (d.sent_version == version) return;
        if (mode == .coalesce and d.sent_version != 0) if (c.proc) |p| if (p.pending_out.items.len > 0) return; // 밀린 것이 빠진 뒤의 tick 에 최신 본문으로
        if (d.sent_version == 0) {
            const msg = lsp.rpc.didOpen(self.allocator, d.uri, c.server.language_id, @intCast(version), opened.file.content) catch return;
            defer self.allocator.free(msg);
            if (!send(self, c, msg)) return;
        } else {
            const msg = lsp.rpc.didChangeFull(self.allocator, d.uri, @intCast(version), opened.file.content) catch return;
            defer self.allocator.free(msg);
            if (!send(self, c, msg)) return;
            self.editor_lsp.sent_changes += 1;
        }
        d.sent_version = version;
        return;
    }
    const path = termPath(term) orelse return;
    const uri = lsp.rpc.fileUri(self.allocator, path) catch return;
    if (term.rt.editorDocument().notifications.lsp_version == 0) term.rt.editorDocument().notifications.lsp_version = 1; // version 0 은 「안 보냈다」의 자리
    const v: u64 = term.rt.editorDocument().notifications.lsp_version;
    c.docs.ensureUnusedCapacity(self.allocator, 1) catch {
        self.allocator.free(uri);
        return;
    };
    const pin = if (term.rt.editor_document_lease) |lease|
        @constCast(lease.owner).retain(lease, .read) catch {
            self.allocator.free(uri);
            return;
        }
    else
        null;
    var committed = false;
    defer if (!committed) {
        if (pin) |held| _ = @constCast(held.owner).release(held) catch false;
    };
    const msg = lsp.rpc.didOpen(self.allocator, uri, c.server.language_id, @intCast(v), opened.file.content) catch {
        self.allocator.free(uri);
        return;
    };
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) {
        self.allocator.free(uri);
        return;
    }
    c.docs.appendAssumeCapacity(.{ .surface_id = term.surfaceId(), .document = pin, .uri = uri, .sent_version = v });
    committed = true;
}

/// 문서 크기 상한(§3.0 의 상한과 같은 자리 — Full sync 라 전문이 프레임마다 갈 수 있다).
pub const max_sync_bytes: usize = 4 * 1024 * 1024;

/// 문서 편집 통지 — `notifyDocumentEdit`가 revision마다 한 번 부른다. version 을 올려 다음 pump 가 didChange 를 보내게.
pub fn noteEdited(term: *Term) void {
    if (term.rt.editorDocument().notifications.lsp_version == 0) term.rt.editorDocument().notifications.lsp_version = 1;
    term.rt.editorDocument().notifications.lsp_version += 1;
}

/// 상태바 문구(§8.2a) — phase 마다 하나. 보간은 i18n §6.3 진입점 `i18n.format` 하나다. 넘치면 `format` 이 「…」로 자른다(서버
/// 이름은 고정 표 `session/lsp/servers.zig` 의 짧은 이름이다). 버퍼는 `status_text_cap` 로 **타입에 박는다** — 부르는 쪽이 다른 크기를
/// 쓰면 컴파일되지 않아, 판정자(LSPB10)가 잰 크기가 곧 제품 크기다.
pub fn statusText(view: StatusView, buf: *[status_text_cap]u8) []const u8 {
    const key: maru.i18n.Key = switch (view.phase) {
        .missing => if (!view.env_failed) .lsp_status_missing else if (view.env_retried) .lsp_status_missing_env_install else .lsp_status_missing_env,
        .preparing => .lsp_status_preparing,
        .asking => .lsp_status_asking,
        .starting => .lsp_status_starting,
        .restarting => .lsp_status_restarting,
        .failed => .lsp_status_failed,
        .denied => .lsp_status_denied,
        .home_root => .lsp_status_home_root,
        .outside_repo => .lsp_status_outside_repo,
        .unasked => .lsp_status_unasked,
        .ready => return maru.i18n.format(buf, "{0}", &.{.{ .s = view.exe }}),
    };
    return maru.i18n.format(buf, maru.i18n.t(key), &.{.{ .s = view.exe }});
}

// ── 상태바·클릭 ───────────────────────────────────────────────────────────────

pub const StatusView = struct {
    phase: Phase,
    exe: []const u8,
    /// 사용자 셸 환경을 못 읽어 앱 환경으로 대신했다(`tool_env.usingAppFallback` — 앞서 담은 셸 환경을 지킨 실패는 아니다). 「없음」이
    /// 그 탓일 수 있어 문구가 그렇게 말하고 클릭이 다시 읽는다.
    env_failed: bool = false,
    /// 사용자가 다시 읽었는데도 못 읽었다 — 클릭은 다시 읽기 대신 설치로(문구는 셸 환경 실패를 그대로 말한다).
    env_retried: bool = false,
};

/// 상태바 문구 버퍼 크기 — `statusText` 의 인자 타입이다(상태바·판정자가 같은 크기를 쓸 수밖에 없다).
pub const status_text_cap = 128;

/// 활성 편집기 Term 의 서버 상태(상태바 항목 — §8.2a). 서버 이름표가 없거나 root 밖이면 `null`(항목 없음).
pub fn statusFor(self: *AppSession, term: *Term) ?StatusView {
    if (!self.loaded_config.config.lsp.enabled) return null;
    if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) return null;
    const server = serverFor(self, term.rt.editor_grammar) orelse return null;
    const root = rootFor(self, term) orelse return null;
    // 다시 읽었는데도 못 읽었으면 다시 읽기를 더 권하지 않는다 — 클릭은 설치로 가되 문구는 셸 환경 실패를 그대로 말한다(설치 위치가
    // 셸 설정에만 있으면 설치해도 못 찾는다 — 원인을 지우면 사용자가 짐작할 길이 없다, 9회차).
    const env_failed = tool_env.usingAppFallback();
    const env_retried = tool_env.failedAfterReload();
    const c = clientFor(self, root, server) orelse return .{ .phase = if (tool_env.settled()) .missing else .preparing, .exe = server.exe, .env_failed = env_failed, .env_retried = env_retried };
    // 답을 기다리는 동안(모달이 다른 오버레이 뒤에서 순서를 기다리거나 떠 있는 동안)은 「허락 대기」다 — 「다시 시작 중」이 아니다.
    if (c.trust_pending and c.phase == .restarting) return .{ .phase = .asking, .exe = server.exe };
    return .{ .phase = c.phase, .exe = server.exe, .env_failed = env_failed, .env_retried = env_retried };
}

/// **요청 전에 문서를 먼저 맞춘다** — 위치를 싣는 요청(hover·definition·signatureHelp)이 그 프레임의 편집보다 먼저 서버에 닿으면
/// 서버는 옛 본문의 자리를 본다(SIG1 실측: `add(` 를 친 직후의 요청이 didChange 보다 먼저 가서 `null` 이 왔다). 동기화는 프레임 끝에 한
/// 번이지만(§8.2a), 요청이 나가는 순간에는 밀린 didChange 를 그 자리에서 보낸다.
fn flushDocument(self: *AppSession, c: *Client, term: *Term) void {
    if (c.phase != .ready) return;
    syncOne(self, c, term, .now);
}

/// 그 Term 의 문서를 연 **ready** 클라이언트(있으면). 호버(§8.2b)가 「서버가 있는가」를 이것으로 묻는다.
pub fn readyClientFor(self: *AppSession, term: *Term) ?*Client {
    if (!self.loaded_config.config.lsp.enabled) return null;
    if (term.kind != .editor or term.rt.editorDocument().opened == null or term.rt.editor_diff != null) return null;
    const server = serverFor(self, term.rt.editor_grammar) orelse return null;
    const root = rootFor(self, term) orelse return null;
    const c = clientFor(self, root, server) orelse return null;
    if (c.phase != .ready or c.proc == null) return null;
    if (c.findDoc(term) == null) return null;
    return c;
}

/// 그 Term 의 서버가 준 시그니처 트리거 글자(서버가 없거나 ready 아니면 `null`).
pub fn signatureTriggersFor(self: *AppSession, term: *Term) ?lsp.rpc.SignatureTriggers {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.signature_triggers.supported) return null;
    return c.signature_triggers;
}

/// `textDocument/formatting` 을 보낸다(§8.2e). 서버가 없거나 지원하지 않으면 `null`. 요청 전에 밀린 didChange 를 먼저 보낸다.
pub fn requestFormatting(self: *AppSession, term: *Term) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.formatting_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    c.formatting_seq = lsp.rpc.nextSeq(c.formatting_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.formattingRequest(self.allocator, c.formatting_seq, d.uri, @max(1, term.rt.editor_tab_width), false) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_formattings += 1;
    return c.formatting_seq;
}

/// `textDocument/signatureHelp` 를 보낸다(§8.2d). 보냈으면 그 seq.
pub fn requestSignatureHelp(self: *AppSession, term: *Term, offset: usize, kind: lsp.rpc.SignatureTriggerKind, trigger_char: ?u8, is_retrigger: bool) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    flushDocument(self, c, term); // 위치 요청은 지금 본문 기준이어야 한다
    if (!c.signature_triggers.supported) return null;
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    c.signature_seq = lsp.rpc.nextSeq(c.signature_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.signatureHelpRequest(self.allocator, c.signature_seq, d.uri, @intCast(line_idx), character, kind, trigger_char, is_retrigger) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_signatures += 1;
    return c.signature_seq;
}

/// `textDocument/definition` 을 보낸다(§8.2c). 위치 변환은 hover 와 같다. 보냈으면 그 seq.
pub fn requestDefinition(self: *AppSession, term: *Term, offset: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    flushDocument(self, c, term); // 위치 요청은 지금 본문 기준이어야 한다
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    c.definition_seq = lsp.rpc.nextSeq(c.definition_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.definitionRequest(self.allocator, c.definition_seq, d.uri, @intCast(line_idx), character) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_definitions += 1;
    return c.definition_seq;
}

/// `textDocument/references` 를 보낸다(§8.2l) — 정의 요청과 같은 자리 계산. 서버가 없거나 ready 아니면 `null`.
pub fn requestReferences(self: *AppSession, term: *Term, offset: usize) ?u32 {
    return requestLocations(self, term, .references, offset);
}

/// 그 종류의 provider 가 있는가(ready 클라이언트 기준). 없으면 요청하지 않는다(§8.2m ② — tsgo 는 없는 것을 물으면 `-32600`).
pub fn locationKindSupported(self: *AppSession, term: *Term, kind: lsp.rpc.LocationKind) bool {
    const c = readyClientFor(self, term) orelse return false;
    return switch (kind) {
        .references => true, // §8.2l — referencesProvider 는 따로 읽지 않는다(셋 다 낸다)
        .implementation => c.implementation_supported,
        .type_definition => c.type_definition_supported,
        .declaration => c.declaration_supported,
    };
}

/// 위치 요청(§8.2m) — 종류만 다르고 자리 계산·flush·seq 규율은 같다. 서버가 없거나 ready 아니면 `null`.
pub fn requestLocations(self: *AppSession, term: *Term, kind: lsp.rpc.LocationKind, offset: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    // 종류마다 seq 를 따로 든다 — 응답 대조는 `(칸, seq)` 로 하고 `waiting_kind` 가 종류를 가르므로 하나를 나눠 써도 관측은 같다(적대적 C1: 등가).
    // 그래도 가르는 이유는 id 표의 뜻이다: 칸마다 자기 seq 가 돈다(§8.2a).
    const seq_slot: *u32 = switch (kind) {
        .references => &c.references_seq,
        .implementation => &c.implementation_seq,
        .type_definition => &c.type_definition_seq,
        .declaration => &c.declaration_seq,
    };
    seq_slot.* = lsp.rpc.nextSeq(seq_slot.*);
    const msg = lsp.rpc.locationRequest(self.allocator, kind, seq_slot.*, d.uri, @intCast(line_idx), character) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_references += 1;
    return seq_slot.*;
}

/// `textDocument/rename` 을 보낸다(§8.2f). 서버가 없거나 `renameProvider` 가 없으면 `null`. 요청 전에 밀린 didChange 를 먼저 보낸다.
pub fn requestRename(self: *AppSession, term: *Term, offset: usize, new_name: []const u8) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.rename_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    c.rename_seq = lsp.rpc.nextSeq(c.rename_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.renameRequest(self.allocator, c.rename_seq, d.uri, @intCast(line_idx), character, new_name) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_renames += 1;
    return c.rename_seq;
}

/// `textDocument/completion` 을 보낸다(§8.2g). 서버가 없거나 `completionProvider` 가 없으면 `null`. 요청 전에 밀린 didChange 를 먼저 보낸다.
pub fn requestCompletion(self: *AppSession, term: *Term, offset: usize, trigger_char: ?u8) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.completion_triggers.supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    c.completion_seq = lsp.rpc.nextSeq(c.completion_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.completionRequest(self.allocator, c.completion_seq, d.uri, @intCast(line_idx), character, trigger_char) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_completions += 1;
    return c.completion_seq;
}

/// `textDocument/codeAction` 을 보낸다(§8.2h). `range` 는 byte 반열림 — 서버 인코딩의 줄·글자로 옮기고, 그 범위와 겹치는 `.lsp` 진단을
/// 문맥으로 싣는다(넷: range·message·severity·code). 서버가 없거나 `codeActionProvider` 가 없으면 `null`.
pub fn requestCodeAction(self: *AppSession, term: *Term, start: usize, end: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.code_action_caps.supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const s = @min(start, content.len);
    const e = @min(@max(end, s), content.len);
    const range: lsp.rpc.LspRange = .{ .start = lspPos(opened, s, c.encoding), .end = lspPos(opened, e, c.encoding) };
    var diags: std.ArrayList(lsp.rpc.ContextDiagnostic) = .empty;
    defer diags.deinit(self.allocator);
    for (term.rt.editor_diagnostics.lsp.items) |dg| {
        // 겹침(반열림) — caret 하나(s == e)는 그 자리를 덮는 진단.
        const overlaps = if (s == e) (dg.start <= s and s < @max(dg.end, dg.start + 1)) else (dg.start < e and s < dg.end);
        if (!overlaps) continue;
        diags.append(self.allocator, .{
            .range = .{ .start = lspPos(opened, dg.start, c.encoding), .end = lspPos(opened, dg.end, c.encoding) },
            .message = dg.message,
            .severity = switch (dg.severity) {
                .@"error" => 1,
                .warning => 2,
                .info => 3,
                .hint => 4,
            },
            .code = if (dg.code.len > 0) dg.code else null,
        }) catch return null;
    }
    c.code_action_seq = lsp.rpc.nextSeq(c.code_action_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.codeActionRequest(self.allocator, c.code_action_seq, d.uri, range, diags.items) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_code_actions += 1;
    return c.code_action_seq;
}

/// `semanticTokens/range`(보이는 원본 줄 `[lo, hi]`) 또는 `full`(§8.2i). 보내기 전 `flushDocument`. 서버가 없거나 provider 가 없으면 `null`.
pub fn requestSemanticTokens(self: *AppSession, term: *Term, full: bool, lo: usize, hi: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.semantic_caps.supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    c.semantic_seq = lsp.rpc.nextSeq(c.semantic_seq); // 한 번에 하나라 응답 대조에는 안 올려도 같다(적대적 3회차 C5: 등가) — 낡은 응답을 가르는 규율은 다른 요청들과 같이 둔다
    const msg = if (full)
        lsp.rpc.semanticTokensFullRequest(self.allocator, c.semantic_seq, d.uri) catch return null
    else
        lsp.rpc.semanticTokensRangeRequest(self.allocator, c.semantic_seq, d.uri, .{ .start = .{ .line = @intCast(lo), .character = 0 }, .end = .{ .line = @intCast(hi + 1), .character = 0 } }) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_semantic += 1;
    return c.semantic_seq;
}

/// `textDocument/inlayHint`(보이는 원본 줄 `[lo, hi]` — 끝은 줄 수를 안 넘긴다)(§8.2n). 보내기 전 `flushDocument`. 서버가 없거나 provider 가 없으면 `null`.
pub fn requestInlayHints(self: *AppSession, term: *Term, lo: usize, hi: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.inlay_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const line_count = opened.file.lines.lineCount();
    const end_line: u32 = @intCast(@min(hi + 1, line_count -| 1)); // 반열림이되 줄 수를 안 넘긴다(rust-analyzer 는 넘기면 -32603)
    const end_char: u32 = if (hi + 1 < line_count) 0 else blk: {
        const last = opened.file.lines.line(line_count - 1) orelse break :blk 0;
        break :blk @intCast(last.contentEnd() - last.start);
    };
    c.inlay_seq = lsp.rpc.nextSeq(c.inlay_seq);
    const msg = lsp.rpc.inlayHintRequest(self.allocator, c.inlay_seq, d.uri, .{ .start = .{ .line = @intCast(lo), .character = 0 }, .end = .{ .line = end_line, .character = end_char } }) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_inlay += 1;
    return c.inlay_seq;
}

/// 이 클라이언트의 문서마다 편집기 Term 을 찾아 `f` 를 부른다.
fn forEachDocTerm(self: *AppSession, c: *Client, f: *const fn (*Term) void) void {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (c.findDoc(term) != null) f(term);
    };
}

/// `textDocument/documentSymbol`(§8.2o) — 문서 단위. 서버가 없거나 provider 가 없으면 `null`(묻지 않는다).
pub fn requestDocumentSymbols(self: *AppSession, term: *Term) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.symbols_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    c.symbols_seq = lsp.rpc.nextSeq(c.symbols_seq);
    const msg = lsp.rpc.documentSymbolRequest(self.allocator, c.symbols_seq, d.uri) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_symbols += 1;
    return c.symbols_seq;
}

/// `textDocument/documentHighlight`(§8.2p) — caret 자리. 서버가 없거나 provider 가 없으면 `null`(묻지 않는다).
pub fn requestDocumentHighlight(self: *AppSession, term: *Term, line: u32, character_byte: u32) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.highlight_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const ln = opened.file.lines.line(line) orelse return null;
    const text = opened.file.content[ln.start..ln.contentEnd()];
    const character = lsp.position.characterOf(text, character_byte, c.encoding);
    c.highlight_seq = lsp.rpc.nextSeq(c.highlight_seq);
    const msg = lsp.rpc.documentHighlightRequest(self.allocator, c.highlight_seq, d.uri, line, character) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_highlight += 1;
    return c.highlight_seq;
}

fn termWaitingHighlight(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_highlight.waiting and t.rt.editor_highlight.waiting_seq == seq) return t;
    };
    return null;
}

/// 구조 기반 선택 확장(§8.2q) — 커서 전부의 **물을 자리**(문서 byte)를 한 요청에. 준비된 서버가 없거나 provider 가 없으면 `null`.
pub fn requestSelectionRange(self: *AppSession, term: *Term, queries: []const u32) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.selection_range_supported) return null;
    if (queries.len == 0) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const positions = self.allocator.alloc(lsp.rpc.Position, queries.len) catch return null;
    defer self.allocator.free(positions);
    for (queries, positions) |q, *p| {
        const off = @min(@as(usize, q), opened.file.content.len);
        const line = opened.file.lines.lineAt(off);
        const ln = opened.file.lines.line(line) orelse return null;
        const text = opened.file.content[ln.start..ln.contentEnd()];
        p.* = .{ .line = @intCast(line), .character = lsp.position.characterOf(text, @intCast(@min(off - ln.start, text.len)), c.encoding) };
    }
    c.selection_range_seq = lsp.rpc.nextSeq(c.selection_range_seq);
    const msg = lsp.rpc.selectionRangeRequest(self.allocator, c.selection_range_seq, d.uri, positions) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_selection_range += 1;
    return c.selection_range_seq;
}

fn termWaitingSelectionRange(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_smart_select.waiting and t.rt.editor_smart_select.waiting_seq == seq) return t;
    };
    return null;
}

fn termWaitingSymbols(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_symbols.waiting and t.rt.editor_symbols.waiting_seq == seq) return t;
    };
    return null;
}

fn termWaitingInlay(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_inlay.waiting and t.rt.editor_inlay.waiting_seq == seq) return t;
    };
    return null;
}

/// 이 클라이언트의 문서 중 `seq` 를 기다리는 편집기 Term.
fn termWaitingSemantic(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_semantic.waiting and t.rt.editor_semantic.waiting_seq == seq) return t;
    };
    return null;
}

/// 저장 통지(§8.2k) — `saveDocument` 가 디스크 쓰기에 **성공한 뒤** 부른다. 밀린 didChange 를 먼저 보내고(서버가 저장된 본문을 든 채 통지를
/// 받아야 한다) `didSave` 한 통(`includeText` 면 `saved_text` 를 싣는다). 서버가 없거나 ready 가 아니거나 문서를 안 열었거나(크기 상한) 미지원이면
/// 아무것도 안 한다 — **줄 서지 않는다**(저장은 사실이지 요청이 아니다; 서버가 뜨면 didOpen 이 지금 내용을 통째로 보낸다). 보냈으면 true.
pub fn noteSaved(self: *AppSession, term: *Term, saved_text: []const u8) bool {
    const c = readyClientFor(self, term) orelse return false;
    if (!c.save_caps.supported) return false;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return false;
    const msg = lsp.rpc.didSave(self.allocator, d.uri, if (c.save_caps.include_text) saved_text else null) catch return false;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return false;
    self.editor_lsp.sent_saves += 1;
    return true;
}

/// `textDocument/foldingRange`(§8.2j) — 문서 전체. 보내기 전 `flushDocument`. 서버가 없거나 provider 가 없으면 `null`.
pub fn requestFoldingRange(self: *AppSession, term: *Term) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.fold_supported) return null;
    flushDocument(self, c, term);
    const d = c.findDoc(term) orelse return null;
    c.fold_seq = lsp.rpc.nextSeq(c.fold_seq);
    const msg = lsp.rpc.foldingRangeRequest(self.allocator, c.fold_seq, d.uri) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_folding += 1;
    return c.fold_seq;
}

/// 이 클라이언트의 문서 중 접힘 `seq` 를 기다리는 편집기 Term.
fn termWaitingFolding(self: *AppSession, c: *Client, seq: u32) ?*Term {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (c.findDoc(t) == null) continue;
        if (t.rt.editor_fold_lsp.waiting and t.rt.editor_fold_lsp.waiting_seq == seq) return t;
    };
    return null;
}

/// `codeAction/resolve`(§8.2h) — 고른 항목의 JSON 그대로. 보냈으면 seq.
pub fn requestCodeActionResolve(self: *AppSession, term: *Term, item_json: []const u8) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    // 등가다(적대적 2회차 B13) — `code_action.parse` 가 resolve 불가 서버의 data-only 항목을 이미 숨겨 이 길로 못 온다. 방어로 남긴다.
    if (!c.code_action_caps.resolve) return null;
    c.code_action_resolve_seq = lsp.rpc.nextSeq(c.code_action_resolve_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.codeActionResolveRequest(self.allocator, c.code_action_resolve_seq, item_json) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_code_action_resolves += 1;
    return c.code_action_resolve_seq;
}

pub fn codeActionCapsFor(self: *AppSession, term: *Term) ?lsp.rpc.CodeActionCaps {
    const c = readyClientFor(self, term) orelse return null;
    return c.code_action_caps;
}

fn lspPos(opened: editor_ops.Opened, off: usize, enc: lsp.rpc.PositionEncoding) lsp.rpc.Pos {
    const content = opened.file.content;
    const o = @min(off, content.len);
    const line_idx = opened.file.lines.lineAt(o);
    const line = opened.file.lines.line(line_idx) orelse return .{ .line = 0, .character = 0 };
    const text = content[line.start..line.contentEnd()];
    return .{ .line = @intCast(line_idx), .character = lsp.position.characterOf(text, @intCast(o -| line.start), enc) };
}

/// `completionItem/resolve`(§8.2g-b) — 항목 JSON 그대로. 보냈으면 seq.
pub fn requestCompletionResolve(self: *AppSession, term: *Term, item_json: []const u8) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    if (!c.completion_triggers.resolve) return null;
    c.completion_resolve_seq = lsp.rpc.nextSeq(c.completion_resolve_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.completionResolveRequest(self.allocator, c.completion_resolve_seq, item_json) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_completion_resolves += 1;
    return c.completion_resolve_seq;
}

/// 서버의 완성 트리거 글자(없으면 `supported = false`).
pub fn completionTriggersFor(self: *AppSession, term: *Term) ?lsp.rpc.CompletionTriggers {
    const c = readyClientFor(self, term) orelse return null;
    return c.completion_triggers;
}

/// 서버가 `renameProvider` 를 냈는가 — 상자를 열기 전에 본다(§8.2f: 없으면 무동작).
pub fn renameSupportedFor(self: *AppSession, term: *Term) bool {
    const c = readyClientFor(self, term) orelse return false;
    return c.rename_supported;
}

/// `textDocument/hover` 를 보낸다(§8.2b). 문서 byte `offset` 을 서버 인코딩의 `{line, character}` 로 옮긴다. 보냈으면 그 seq.
pub fn requestHover(self: *AppSession, term: *Term, offset: usize) ?u32 {
    const c = readyClientFor(self, term) orelse return null;
    flushDocument(self, c, term); // 위치 요청은 지금 본문 기준이어야 한다
    const d = c.findDoc(term) orelse return null;
    const opened = term.rt.editorDocument().opened orelse return null;
    const content = opened.file.content;
    const off = @min(offset, content.len);
    const line_idx = opened.file.lines.lineAt(off);
    const line = opened.file.lines.line(line_idx) orelse return null;
    const text = content[line.start..line.contentEnd()];
    const character = lsp.position.characterOf(text, @intCast(off -| line.start), c.encoding);
    c.hover_seq = lsp.rpc.nextSeq(c.hover_seq); // i32 칸 안에서 돈다(§8.2a id)
    const msg = lsp.rpc.hoverRequest(self.allocator, c.hover_seq, d.uri, @intCast(line_idx), character) catch return null;
    defer self.allocator.free(msg);
    if (!send(self, c, msg)) return null;
    self.editor_lsp.sent_hovers += 1;
    return c.hover_seq;
}

/// 상태바 항목 클릭(§8.2a): 없음 → 새 탭에 설치 명령 입력 · 거부됨 → 다시 묻기 · 실패 → 재시작 · 꺼짐(홈·저장소 밖) → root 부터 다시 본다.
/// 나머지는 무동작.
pub fn activateStatus(self: *AppSession) void {
    const pane = pane_ops.activePane(self);
    if (pane.terms.items.len == 0) return;
    const term = pane.activeTerm();
    const view = statusFor(self, term) orelse return;
    const server = serverFor(self, term.rt.editor_grammar) orelse return;
    switch (view.phase) {
        .missing => {
            // 셸 환경을 못 읽어 대신한 환경에서 못 찾았다 — 설치를 권하기 전에 다시 읽는다(셸 설정을 고쳤을 수 있다).
            if (view.env_failed and !view.env_retried) return reloadShellEnvironment(self);
            // §8.1a 흐름 4: **새 탭**에 입력만 — Enter 는 사용자.
            _ = tab_ops.newTab(self) catch return;
            input_ops.sendTextAsKeys(self, server.install);
        },
        .denied => {
            const root = rootFor(self, term) orelse return;
            const c = clientFor(self, root, server) orelse return;
            // 기억된 거부는 그대로 두고 **이 창에서** 다시 묻는다 — 답하면 표가 바뀌어 다른 창도 따르고, 모달이 답 없이 닫히면(다른
            // 오버레이가 덮었다) 다음 gate 가 또 묻는다. 같은 저장소의 이 창 클라이언트가 함께 기다린다(한 모달이 답이다). **띄우지
            // 않는다**(`trust_pending`) — 문서가 닫힌 클라이언트는 gate 를 안 지나 그대로면 묻지도 않고 뜬다.
            const key = (c.trust_key orelse return).key();
            const gen = trust_store.generation();
            for (self.editor_lsp.clients.items) |*o| {
                if (!sameKey(o, key) or o.phase != .denied) continue;
                o.reask = true;
                o.reask_gen = gen;
                o.trust_pending = true;
                o.phase = .restarting;
                o.retry_at_ms = 0;
            }
        },
        .failed => {
            const root = rootFor(self, term) orelse return;
            const c = clientFor(self, root, server) orelse return;
            c.restarts = 0;
            c.phase = .restarting;
            c.retry_at_ms = 0;
        },
        .unasked => {
            // 잊은 저장소를 이제 묻는다 — 같은 저장소의 이 창 클라이언트가 함께 기다린다(띄우지 않는다 — 문서 닫힌 것까지).
            const root = rootFor(self, term) orelse return;
            const c = clientFor(self, root, server) orelse return;
            const key = (c.trust_key orelse return).key();
            for (self.editor_lsp.clients.items) |*o| {
                if (!sameKey(o, key) or o.phase != .unasked) continue;
                o.trust_pending = true;
                // 묻지 않는 root 판정부터 다시(`rekeyRoot` 와 같다) — 잊은 뒤 `.git` 을 지웠으면 이제 저장소가 아니다. 문서가 닫힌
                // 것은 gate 를 안 지나 판정 전으로 남고, 다시 열 때 판정·표를 처음부터 본다.
                o.scope_checked = false;
                o.phase = .restarting;
                o.retry_at_ms = 0;
            }
        },
        .home_root, .outside_repo => {
            // 다시 본다 — **root 부터** 다시 푼다: 그 사이 상위 폴더에서 `git init` 했으면 root 가 바뀐다(굳힌 root 의 `.git` 만 보면 영영
            // 안 풀린다). 문서마다 굳힌 root 를 비우면 다음 pump 가 `projectRootForFile` 로 다시 정하고, 그 root 의 클라이언트가 판정·신뢰를
            // 처음부터 거친다. 거부돼 있던 이 root 의 클라이언트는 **띄우지 않고**(`trust_pending`) 다시 판정을 기다린다 — 문서가 닫힌
            // 것은 gate 를 안 지나 그대로면 다음 pump 가 신뢰 없이 띄운다(「다시 묻기」와 같은 함정).
            const root = self.allocator.dupe(u8, rootFor(self, term) orelse return) catch return;
            defer self.allocator.free(root);
            for (self.tabs.items) |tab| for (tab.panes.items) |p| for (p.terms.items) |t| {
                const r = t.rt.editor_lsp_root orelse continue;
                if (!std.mem.eql(u8, r, root)) continue;
                self.allocator.free(r);
                t.rt.editor_lsp_root = null;
            };
            for (self.editor_lsp.clients.items) |*o| {
                if (!std.mem.eql(u8, o.root, root) or (o.phase != .home_root and o.phase != .outside_repo)) continue;
                // 굳힌 키도 버린다 — root 가 심링크면 그 대상이 바뀌었을 수 있다(홈이던 대상이 이제 저장소). 다음 gate 가 다시 푼다.
                if (o.trust_key) |k| k.deinit(self.allocator);
                o.trust_key = null;
                o.trust_pending = true;
                o.phase = .restarting;
                o.retry_at_ms = 0;
            }
        },
        .asking, .starting, .ready, .restarting, .preparing => {},
    }
    self.metal_dirty = true;
}

/// Term 이 닫힐 때 — 그 문서를 서버에서 닫는다(다음 pump 가 `seen` 에 없어 didClose 를 보낸다). 여기서는 진단 저장소만.
pub fn noteTermClosing(self: *AppSession, term: *Term) void {
    _ = self;
    _ = term;
}

/// 세션 종료(창 닫기·앱 종료) — 서버들을 내린다(§8.2a). stdin 을 닫아 스스로 내려가게 하고(서버가 제 자식을 정리할 기회) **합쳐**
/// `quit_grace_ms` 뒤 남은 것을 그룹째 죽인다 — 거두기 스레드가(`lowerOffMain`), 앱 종료가 확정됐으면 이 자리에서. `shutdown` 요청은
/// 보내지 않는다 — 응답을 기다리는 왕복이 종료 경로를 늘린다.
pub fn deinit(self: *AppSession) void {
    lowerServers(self);
    trust_store.release(null, trustOwner(self)); // 이 창이 잡은 묻는 자리 — 기다리던 다른 창이 묻게
    self.editor_lsp.deinit(self.allocator);
}

fn lowerServers(self: *AppSession) void {
    var items: std.ArrayList(lsp_process.Lowering) = .empty;
    defer items.deinit(self.allocator);
    for (self.editor_lsp.clients.items) |*c| if (c.proc) |*p| {
        const l = lsp_process.handOff(p, self.allocator); // stdin 을 닫는다 — 스스로 내려갈 기회
        c.proc = null;
        c.inbuf.clearRetainingCapacity();
        releaseWaiting(self, c);
        items.append(self.allocator, l) catch {
            var one = l;
            lowerOffMain(self, (&one)[0..1], 0); // 목록을 못 늘리면 이것만 곧바로 내린다
            continue;
        };
    };
    lowerOffMain(self, items.items, quit_grace_ms);
}

/// `lsp.enabled` 가 꺼졌다 — 서버를 전부 내리고(세션 종료와 같이 EOF 먼저, 합쳐 `quit_grace_ms` 까지) 클라이언트를 버린다. 그 서버가 낸 진단도 걷는다(낡은 밑줄이 남지 않게). 신뢰
/// 결정·서버 선택은 남긴다(다시 켜면 묻지 않고 같은 서버로 뜬다).
fn stopAll(self: *AppSession) void {
    const st = &self.editor_lsp;
    lowerServers(self); // 세션 종료와 같은 길 — stdin 을 닫아 스스로 내려가게 하고 남은 것을 그룹째, 기다림을 놓는다
    for (st.clients.items) |*c| {
        clearClientDiagnostics(self, c);
        c.deinit(self.allocator);
    }
    st.clients.clearRetainingCapacity();
    dropTrustPrompt(self); // 묻던 모달도 내린다 — 답할 서버가 없다. 기억하지 않는다(다시 켜면 다시 묻는다)
}
