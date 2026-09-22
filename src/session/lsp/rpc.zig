//! JSON-RPC 2.0 위의 LSP 메시지(docs/editor-surface-tooling.md §8.2a) — **만드는 쪽**(initialize·didOpen·didChange·didClose·shutdown·
//! exit)과 **읽는 쪽**(응답·알림·서버 요청을 가른다). 순수 계산이라 여기 산다. 1단이 보내는 요청은 `initialize`·`shutdown` 둘뿐이라
//! id 대조표가 필요 없다 — 응답의 id 가 그 둘 중 무엇인지만 안다.
//!
//! **서버 → 클라이언트 요청은 전부 거부한다**(§8.2a 「하지 않는 것」): `window/workDoneProgress/create`·`workspace/configuration`·
//! `client/registerCapability`·`workspace/applyEdit`… 어느 것이든 `MethodNotFound`(-32601) 로 답한다 — 승인 UI 가 없는 동안은 거부만.

const std = @import("std");

/// 우리가 보내는 요청의 id. 알림은 id 가 없다. `initialize`·`shutdown` 은 고정 번호, `hover`(2단 ①, §8.2b)는 `hover_id_base + seq` —
/// 응답을 「지금 기다리는 seq」와 대조해 낡은 것을 버린다(`$/cancelRequest` 는 안 보낸다).
pub const RequestId = union(enum) {
    initialize,
    shutdown,
    hover: u32,
    definition: u32,
    signature: u32,
    formatting: u32,
    rename: u32,
    completion: u32,
    code_action: u32,
    code_action_resolve: u32,
    completion_resolve: u32,
    semantic_tokens: u32,
    folding_range: u32,
    references: u32,
    implementation: u32,
    type_definition: u32,
    declaration: u32,
    inlay_hint: u32,
    document_symbol: u32,
};
/// 요청 id 는 **i32 안**이어야 한다(2026-09-20 실측): rust-analyzer·ruff 가 쓰는 Rust `lsp-server` 크레이트는 정수 id 를 i32 로만 읽고,
/// 넘치면 그 메시지를 **알림으로 오인해 버린다**(`6_000_000_001` 짜리 completion 이 stderr 에 `unhandled notification` 으로만 남고 응답이
/// 없었다 — hover·definition 만 i32 안이라 그 둘만 됐다). 종류마다 `id_span`(1e8) 칸을 갖고 seq 는 칸 안에서 돈다(`nextSeq`) —
/// 가장 큰 칸(16e8+1e8-1) 도 i32 최대(2_147_483_647) 아래. `classify` 는 칸으로 가른다.
pub const id_span: u32 = 100_000_000;
pub const initialize_id: u32 = 1;
pub const shutdown_id: u32 = 2;
/// `hover`(2단 ①, §8.2b)
pub const hover_id_base: u32 = 1 * id_span;
/// `definition`(2단 ②, §8.2c)
pub const definition_id_base: u32 = 2 * id_span;
/// `signatureHelp`(2단 ③, §8.2d)
pub const signature_id_base: u32 = 3 * id_span;
/// `formatting`(2단 ④, §8.2e)
pub const formatting_id_base: u32 = 4 * id_span;
/// `rename`(2단 ⑤, §8.2f)
pub const rename_id_base: u32 = 5 * id_span;
/// `completion`(2단 ⑥, §8.2g)
pub const completion_id_base: u32 = 6 * id_span;
/// `codeAction`(2단 ⑦, §8.2h)
pub const code_action_id_base: u32 = 7 * id_span;
/// `codeAction/resolve`(§8.2h)
pub const code_action_resolve_id_base: u32 = 8 * id_span;
/// `completionItem/resolve`(§8.2g-b)
pub const completion_resolve_id_base: u32 = 9 * id_span;
/// `semanticTokens/range`·`full`(§8.2i)
pub const semantic_tokens_id_base: u32 = 10 * id_span;
/// `textDocument/foldingRange`(§8.2j)
pub const folding_range_id_base: u32 = 11 * id_span;
/// `textDocument/references`(§8.2l)
pub const references_id_base: u32 = 12 * id_span;
/// `textDocument/implementation`·`typeDefinition`·`declaration`(§8.2m)
pub const implementation_id_base: u32 = 13 * id_span;
pub const type_definition_id_base: u32 = 14 * id_span;
pub const declaration_id_base: u32 = 15 * id_span;
/// `textDocument/inlayHint`(§8.2n)
pub const inlay_hint_id_base: u32 = 16 * id_span;
/// 심볼 2층(§8.2o).
pub const document_symbol_id_base: u32 = 17 * id_span;
comptime {
    std.debug.assert(@as(u64, document_symbol_id_base) + id_span - 1 <= std.math.maxInt(i32));
}
/// 종류별 seq 의 다음 값 — 칸 안에서 돈다(0 은 안 쓴다: 처음 보내는 요청이 `base + 1`).
pub fn nextSeq(seq: u32) u32 {
    const n = (seq + 1) % id_span;
    return if (n == 0) 1 else n;
}
/// 칸 → 종류. `id` 가 어느 칸에도 없으면 null.
fn requestIdOf(id_num: i64) ?RequestId {
    if (id_num == initialize_id) return .initialize;
    if (id_num == shutdown_id) return .shutdown;
    if (id_num < hover_id_base or id_num >= @as(i64, document_symbol_id_base) + id_span) return null;
    const slot: u32 = @intCast(@divTrunc(id_num, id_span));
    const seq: u32 = @intCast(@mod(id_num, id_span));
    return switch (slot) {
        1 => .{ .hover = seq },
        2 => .{ .definition = seq },
        3 => .{ .signature = seq },
        4 => .{ .formatting = seq },
        5 => .{ .rename = seq },
        6 => .{ .completion = seq },
        7 => .{ .code_action = seq },
        8 => .{ .code_action_resolve = seq },
        9 => .{ .completion_resolve = seq },
        10 => .{ .semantic_tokens = seq },
        11 => .{ .folding_range = seq },
        12 => .{ .references = seq },
        13 => .{ .implementation = seq },
        14 => .{ .type_definition = seq },
        15 => .{ .declaration = seq },
        16 => .{ .inlay_hint = seq },
        17 => .{ .document_symbol = seq },
        else => null,
    };
}

/// 위치 인코딩 — `initialize` 에서 utf-8 을 먼저 제안하고 서버가 고른 것을 쓴다(§8.2a).
pub const PositionEncoding = enum { utf8, utf16 };

pub fn initializeRequest(allocator: std.mem.Allocator, root_uri: []const u8, pid: i64) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = initialize_id,
        .method = "initialize",
        .params = .{
            .processId = pid,
            .rootUri = root_uri,
            .workspaceFolders = [_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root_uri, .name = "root" }},
            .capabilities = .{
                .general = .{ .positionEncodings = [_][]const u8{ "utf-8", "utf-16" } },
                .textDocument = .{
                    .synchronization = .{ .dynamicRegistration = false, .didSave = true }, // §8.2k — rustc 진단은 저장에만 다시 돈다
                    .publishDiagnostics = .{ .versionSupport = true },
                    .hover = .{ .contentFormat = [_][]const u8{ "markdown", "plaintext" } },
                    // 자동완성(§8.2g) — 스니펫은 받지 않는다(`snippetSupport = false` 면 서버가 평문 insertText 를 낸다). resolve 도 아직.
                    .completion = .{
                        .completionItem = .{
                            .snippetSupport = false,
                            .insertReplaceSupport = false,
                            // §8.2g-c — 서버가 label 의 꼬리(시그니처·import)와 설명을 `labelDetails` 로 따로 낸다; 선언했으니 행이 그린다.
                            .labelDetailsSupport = true,
                            .documentationFormat = [_][]const u8{ "markdown", "plaintext" }, // §8.2g-d — 패널이 호버와 같은 축소로 읽는다
                            // §8.2g-b — resolve 로 지연해 받는 속성.
                            .resolveSupport = .{ .properties = [_][]const u8{ "additionalTextEdits", "detail", "documentation" } },
                        },
                        .contextSupport = true,
                    },
                    // code action(§8.2h) — 리터럴 CodeAction 을 받고, `edit` 을 resolve 로 지연할 수 있으며 `data` 를 되돌려 준다.
                    .codeAction = .{
                        .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = [_][]const u8{ "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports" } } },
                        .resolveSupport = .{ .properties = [_][]const u8{"edit"} },
                        .dataSupport = true,
                        .isPreferredSupport = true,
                        .disabledSupport = true,
                    },
                    // semantic tokens 2층(§8.2i) — 범위·전체 둘 다 선언(clangd 는 전체만 낸다), 표준 종류 23·수식자 10, 한 줄 토큰만.
                    .semanticTokens = .{
                        .requests = .{ .range = true, .full = true },
                        .tokenTypes = semantic_token_types,
                        .tokenModifiers = semantic_token_modifiers,
                        .formats = [_][]const u8{"relative"},
                        .multilineTokenSupport = false,
                        .overlappingTokenSupport = false,
                    },
                    .references = .{ .dynamicRegistration = false }, // 참조 피커(§8.2l)
                    .inlayHint = .{ .dynamicRegistration = false }, // 인레이 힌트(§8.2n) — resolve 는 안 한다
                    // 심볼 2층(§8.2o) — 계층 꼴을 받는다(세 서버 모두 그것을 낸다). `symbolKind.valueSet` 은 「이 정수들을 안다」는 선언이다.
                    .documentSymbol = .{
                        .dynamicRegistration = false,
                        .hierarchicalDocumentSymbolSupport = true,
                        // **`u8` 배열은 JSON 문자열이 된다**(Zig `Stringify` 의 규칙) — tsgo 가 `cannot unmarshal JSON string into []SymbolKind` 로
                        // `initialize` 를 통째로 거부했고 세션 전체가 죽었다(2026-09-22 tee 실측 — `initialized` params 사고와 같은 부류). `i32` 로 낸다.
                        .symbolKind = .{ .valueSet = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 } },
                    },
                    // 구현·타입 정의·선언(§8.2m) — 같은 피커. `linkSupport` 로 `LocationLink[]` 를 받는다(tsgo 가 그것을 낸다).
                    .implementation = .{ .dynamicRegistration = false, .linkSupport = true },
                    .typeDefinition = .{ .dynamicRegistration = false, .linkSupport = true },
                    .declaration = .{ .dynamicRegistration = false, .linkSupport = true },
                    // 접힘 3층(§8.2j) — 줄 접힘만, 종류 셋을 안다고 선언한다(쓰지는 않는다 — 서버가 종류 때문에 범위를 빼지 않게).
                    .foldingRange = .{
                        .lineFoldingOnly = true,
                        .foldingRangeKind = .{ .valueSet = [_][]const u8{ "comment", "imports", "region" } },
                    },
                    .signatureHelp = .{
                        .contextSupport = true,
                        .signatureInformation = .{
                            .documentationFormat = [_][]const u8{ "markdown", "plaintext" },
                            .parameterInformation = .{ .labelOffsetSupport = true },
                            .activeParameterSupport = true,
                        },
                    },
                },
                // `inlayHint.refreshSupport` — rust-analyzer 는 색인이 끝나기 전엔 `[]` 를 내고 끝나면 `workspace/inlayHint/refresh` 를
                // 보낸다(§8.2n 실측 2026-09-22). 이것을 안 받으면 서버가 뜬 뒤 연 파일의 힌트가 **영영** 안 온다.
                .workspace = .{ .applyEdit = false, .configuration = false, .workspaceFolders = false, .inlayHint = .{ .refreshSupport = true } },
            },
        },
    }, .{});
}

/// 서버 → 클라이언트 요청 `workspace/inlayHint/refresh`(§8.2n) — 받으면 `nullResult` 로 답하고 힌트를 다시 묻는다.
pub const inlay_refresh_method = "workspace/inlayHint/refresh";

/// 서버 요청에 대한 **빈 성공 응답**(`result: null`) — refresh 류 요청의 유일한 답.
pub fn nullResult(allocator: std.mem.Allocator, id: std.json.Value) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = null }, .{});
}

/// `initialized` — `params` 는 **빈 객체 `{}`** 여야 한다(`InitializedParams`). 초판은 `.{}`(빈 튜플) 이라 `[]` 로 나갔고 tsgo 가
/// *"cannot unmarshal JSON array into InitializedParams"* 로 거부한 뒤 **모든 것을 `ServerNotInitialized` 로 버렸다** — 2026-09-22 인레이
/// 캡처에서 tee 로 잡았다(§8.2a 되먹임 ⑦). 너그러운 서버(rust-analyzer·clangd·typescript-language-server)는 그것을 받아 줘 그동안 안 보였다.
pub fn initializedNotification(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .method = "initialized", .params = struct {}{} }, .{});
}

pub fn didOpen(allocator: std.mem.Allocator, uri: []const u8, language_id: []const u8, version: i64, text: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = version, .text = text } },
    }, .{});
}

/// Full sync(§8.2a): 변경 하나에 전문. 증분은 2단.
pub fn didChangeFull(allocator: std.mem.Allocator, uri: []const u8, version: i64, text: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = [_]struct { text: []const u8 }{.{ .text = text }},
        },
    }, .{});
}

/// 저장 통지(§8.2k) — 서버가 `includeText` 를 냈으면 저장한 본문을 싣는다(`text`), 아니면 uri 만.
pub fn didSave(allocator: std.mem.Allocator, uri: []const u8, text: ?[]const u8) error{OutOfMemory}![]u8 {
    if (text) |t| {
        return std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .method = "textDocument/didSave",
            .params = .{ .textDocument = .{ .uri = uri }, .text = t },
        }, .{});
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didSave",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

/// 서버의 저장 통지 지원(§8.2k) — `textDocumentSync` 가 **객체**이고 `save` 가 `true` 또는 객체일 때만. 숫자(옛 `TextDocumentSyncKind`)·없음·`false` 는 미지원.
pub const SaveCaps = struct { supported: bool = false, include_text: bool = false };

pub fn saveCapsFromResult(result: ?std.json.Value) SaveCaps {
    const r = result orelse return .{};
    if (r != .object) return .{};
    const caps = r.object.get("capabilities") orelse return .{};
    if (caps != .object) return .{};
    const sync = caps.object.get("textDocumentSync") orelse return .{};
    if (sync != .object) return .{}; // 숫자 꼴 — save 선언이 없다
    const save = sync.object.get("save") orelse return .{};
    return switch (save) {
        .bool => |b| .{ .supported = b },
        .object => |o| .{ .supported = true, .include_text = if (o.get("includeText")) |v| (v == .bool and v.bool) else false },
        else => .{},
    };
}

pub fn didClose(allocator: std.mem.Allocator, uri: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didClose",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

/// `textDocument/hover`(§8.2b). `line`·`character` 는 서버 인코딩의 단위(`position.characterOf`).
pub fn hoverRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = hover_id_base + seq,
        .method = "textDocument/hover",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
    }, .{});
}

/// `textDocument/signatureHelp`(§8.2d). `trigger_char` 는 `triggerKind == 2` 일 때의 그 글자.
pub const SignatureTriggerKind = enum(u8) { invoked = 1, trigger_character = 2, content_change = 3 };
pub fn signatureHelpRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32, kind: SignatureTriggerKind, trigger_char: ?u8, is_retrigger: bool) error{OutOfMemory}![]u8 {
    var ch_buf: [1]u8 = undefined;
    const tc: ?[]const u8 = if (trigger_char) |c| blk: {
        ch_buf[0] = c;
        break :blk ch_buf[0..1];
    } else null;
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = signature_id_base + seq,
        .method = "textDocument/signatureHelp",
        .params = .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = line, .character = character },
            .context = .{ .triggerKind = @intFromEnum(kind), .triggerCharacter = tc, .isRetrigger = is_retrigger },
        },
    }, .{ .emit_null_optional_fields = false });
}

/// `initialize` 응답의 `signatureHelpProvider` — 트리거·재트리거 글자(첫 byte, ASCII 만). 없으면 `supported = false`.
pub const SignatureTriggers = struct {
    supported: bool = false,
    chars: [16]u8 = undefined,
    len: usize = 0,
    retrigger: [8]u8 = undefined,
    retrigger_len: usize = 0,

    pub fn isTrigger(self: SignatureTriggers, c: u8) bool {
        return std.mem.indexOfScalar(u8, self.chars[0..self.len], c) != null;
    }
    pub fn isRetrigger(self: SignatureTriggers, c: u8) bool {
        return std.mem.indexOfScalar(u8, self.retrigger[0..self.retrigger_len], c) != null;
    }
};

pub fn signatureTriggersFromResult(result: ?std.json.Value) SignatureTriggers {
    var out: SignatureTriggers = .{};
    const r = result orelse return out;
    if (r != .object) return out;
    const caps = r.object.get("capabilities") orelse return out;
    if (caps != .object) return out;
    const prov = caps.object.get("signatureHelpProvider") orelse return out;
    switch (prov) {
        .object => |o| {
            out.supported = true;
            collectChars(o.get("triggerCharacters"), &out.chars, &out.len);
            collectChars(o.get("retriggerCharacters"), &out.retrigger, &out.retrigger_len);
        },
        .bool => |b| out.supported = b,
        else => {},
    }
    return out;
}

/// `completionProvider` 의 트리거 글자(§8.2g).
pub const CompletionTriggers = struct {
    supported: bool = false,
    /// `resolveProvider`(§8.2g-b) — 강조된 항목을 미리 `completionItem/resolve` 한다.
    resolve: bool = false,
    chars: [16]u8 = undefined,
    len: usize = 0,

    pub fn isTrigger(self: CompletionTriggers, c: u8) bool {
        return std.mem.indexOfScalar(u8, self.chars[0..self.len], c) != null;
    }
};

pub fn completionTriggersFromResult(result: ?std.json.Value) CompletionTriggers {
    var out: CompletionTriggers = .{};
    const r = result orelse return out;
    if (r != .object) return out;
    const caps = r.object.get("capabilities") orelse return out;
    if (caps != .object) return out;
    const prov = caps.object.get("completionProvider") orelse return out;
    switch (prov) {
        .object => |o| {
            out.supported = true;
            collectChars(o.get("triggerCharacters"), &out.chars, &out.len);
            if (o.get("resolveProvider")) |rp| out.resolve = rp == .bool and rp.bool;
        },
        .bool => |b| out.supported = b,
        else => {},
    }
    return out;
}

/// `completionItem/resolve`(§8.2g-b) — 고른 항목의 JSON 그대로.
pub fn completionResolveRequest(allocator: std.mem.Allocator, seq: u32, item_json: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"completionItem/resolve\",\"params\":{s}}}", .{ completion_resolve_id_base + seq, item_json });
}

/// `textDocument/completion`(§8.2g). `trigger_char` 가 있으면 `triggerKind = 2`(TriggerCharacter), 아니면 1(Invoked).
pub fn completionRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32, trigger_char: ?u8) error{OutOfMemory}![]u8 {
    var tc_buf: [1]u8 = undefined;
    const tc: ?[]const u8 = if (trigger_char) |c| blk: {
        tc_buf[0] = c;
        break :blk tc_buf[0..1];
    } else null;
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = completion_id_base + seq,
        .method = "textDocument/completion",
        .params = .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = line, .character = character },
            .context = .{ .triggerKind = @as(u8, if (trigger_char != null) 2 else 1), .triggerCharacter = tc },
        },
    }, .{});
}

fn collectChars(v: ?std.json.Value, buf: []u8, len: *usize) void {
    const arr = v orelse return;
    if (arr != .array) return;
    for (arr.array.items) |it| {
        if (it != .string or it.string.len == 0 or len.* >= buf.len) continue;
        if (it.string[0] >= 0x80) continue; // ASCII 만 — 트리거 글자는 관례상 구두점이다
        buf[len.*] = it.string[0];
        len.* += 1;
    }
}

/// signatureHelp 결과의 **활성 시그니처** 하나(§8.2d 「결과」). 슬라이스는 응답 트리 안(파싱 결과가 사는 동안 유효) — 호출자가 복사한다.
pub const SignatureView = struct {
    label: []const u8,
    /// 활성 파라미터의 label 안 **byte** 범위(반열림). 없으면 `null`.
    param: ?struct { lo: u32, hi: u32 } = null,
    doc: ?[]const u8 = null,
    param_doc: ?[]const u8 = null,
    index: u32 = 0,
    count: u32 = 1,
};

pub fn signatureView(result: ?std.json.Value, enc: PositionEncoding) ?SignatureView {
    const r = result orelse return null;
    if (r != .object) return null;
    const sigs = r.object.get("signatures") orelse return null;
    if (sigs != .array or sigs.array.items.len == 0) return null;
    const count: u32 = @intCast(sigs.array.items.len);
    var index: u32 = u32Of(r.object.get("activeSignature")) orelse 0;
    if (index >= count) index = 0;
    const sig = sigs.array.items[index];
    if (sig != .object) return null;
    const label_v = sig.object.get("label") orelse return null;
    if (label_v != .string) return null;
    const label = label_v.string;
    var out: SignatureView = .{ .label = label, .index = index, .count = count, .doc = markupText(sig.object.get("documentation")) };
    // 활성 파라미터: 시그니처의 것 → 전체의 것 → 0.
    const active_param: u32 = u32Of(sig.object.get("activeParameter")) orelse (u32Of(r.object.get("activeParameter")) orelse 0);
    if (sig.object.get("parameters")) |params| if (params == .array and active_param < params.array.items.len) {
        const p = params.array.items[active_param];
        if (p == .object) {
            out.param_doc = markupText(p.object.get("documentation"));
            if (p.object.get("label")) |pl| switch (pl) {
                .string => |sub| if (std.mem.indexOf(u8, label, sub)) |at| {
                    out.param = .{ .lo = @intCast(at), .hi = @intCast(at + sub.len) };
                },
                .array => |pair| if (pair.items.len == 2) {
                    const a = u32Of(pair.items[0]) orelse 0;
                    const b = u32Of(pair.items[1]) orelse a;
                    // offset 은 **협상한 인코딩** 단위 — label 안의 byte 로 옮긴다(§8.2d ⑤).
                    const lo = @import("position.zig").byteInLine(label, a, enc);
                    const hi = @import("position.zig").byteInLine(label, b, enc);
                    if (hi > lo) out.param = .{ .lo = lo, .hi = hi };
                },
                else => {},
            };
        }
    };
    return out;
}

/// `string | MarkupContent` → 텍스트(마크다운이든 평문이든 축소 규칙은 무해하다).
fn markupText(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| if (s.len > 0) s else null,
        .object => |o| if (o.get("value")) |val| (if (val == .string and val.string.len > 0) val.string else null) else null,
        else => null,
    };
}

/// `textDocument/formatting`(§8.2e). 들여쓰기 단위는 이 편집기의 탭 문자(`insertSpaces = false`), `tabSize = editor.tab-width`.
pub fn formattingRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, tab_size: u32, insert_spaces: bool) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = formatting_id_base + seq,
        .method = "textDocument/formatting",
        .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = tab_size, .insertSpaces = insert_spaces } },
    }, .{});
}

/// 오류 응답의 `error.message`(문자열일 때만) — 알림에 싣는다(§8.2f 「이름을 바꿀 수 없습니다 — {0}」).
/// `-32801 ContentModified`·`-32802 ServerCancelled` — 「지금은 못 답한다, 다시 물어라」(LSP 3.17). 사용자가 부른 요청은 잠시 뒤 다시 보낸다(§8.2l).
pub const err_content_modified: i64 = -32801;
pub const err_server_cancelled: i64 = -32802;

pub fn isRetryableError(code: ?i64) bool {
    const c = code orelse return false;
    return c == err_content_modified or c == err_server_cancelled;
}

fn errorCode(obj: std.json.ObjectMap) ?i64 {
    const e = obj.get("error") orelse return null;
    if (e != .object) return null;
    const c = e.object.get("code") orelse return null;
    return if (c == .integer) c.integer else null;
}

fn errorMessage(obj: std.json.ObjectMap) ?[]const u8 {
    const e = obj.get("error") orelse return null;
    if (e != .object) return null;
    const m = e.object.get("message") orelse return null;
    return if (m == .string) m.string else null;
}

/// `textDocument/rename`(§8.2f).
pub fn renameRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32, new_name: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = rename_id_base + seq,
        .method = "textDocument/rename",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character }, .newName = new_name },
    }, .{});
}

/// `codeActionProvider`(§8.2h) — 지원 여부와 `resolveProvider`.
pub const CodeActionCaps = struct { supported: bool = false, resolve: bool = false };

pub fn codeActionCapsFromResult(result: ?std.json.Value) CodeActionCaps {
    var out: CodeActionCaps = .{};
    const r = result orelse return out;
    if (r != .object) return out;
    const caps = r.object.get("capabilities") orelse return out;
    if (caps != .object) return out;
    const prov = caps.object.get("codeActionProvider") orelse return out;
    switch (prov) {
        .object => |o| {
            out.supported = true;
            if (o.get("resolveProvider")) |rp| out.resolve = rp == .bool and rp.bool;
        },
        .bool => |b| out.supported = b,
        else => {},
    }
    return out;
}

pub const Pos = struct { line: u32, character: u32 };
/// LSP `Range` 모양 그대로(요청에 싣는다). 응답의 `hoverRange` 는 평평한 `Range` 를 쓴다 — 이름이 다르다.
pub const LspRange = struct { start: Pos, end: Pos };
/// 문맥으로 되돌려 주는 진단(§8.2h ③ — clangd 는 이 넷으로 fix 를 찾는다). `code` 는 글자로 든 것을 그대로 낸다(없으면 생략).
pub const ContextDiagnostic = struct { range: LspRange, message: []const u8, severity: u8, code: ?[]const u8 = null };

/// `textDocument/codeAction`(§8.2h). `triggerKind` 1(Invoked).
pub fn codeActionRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, range: LspRange, diagnostics: []const ContextDiagnostic) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = code_action_id_base + seq,
        .method = "textDocument/codeAction",
        .params = .{ .textDocument = .{ .uri = uri }, .range = range, .context = .{ .diagnostics = diagnostics, .triggerKind = @as(u8, 1) } },
    }, .{ .emit_null_optional_fields = false });
}

/// `codeAction/resolve`(§8.2h) — 고른 항목의 JSON 을 **그대로** 되돌려 준다(`data` 가 서버의 것이라 다시 만들지 않는다).
pub fn codeActionResolveRequest(allocator: std.mem.Allocator, seq: u32, item_json: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"codeAction/resolve\",\"params\":{s}}}", .{ code_action_resolve_id_base + seq, item_json });
}

/// LSP 3.17 표준 `SemanticTokenTypes`·`SemanticTokenModifiers`(§8.2i capability).
pub const semantic_token_types = [_][]const u8{ "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator" };
pub const semantic_token_modifiers = [_][]const u8{ "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary" };

/// `textDocument/semanticTokens/range`(§8.2i).
pub fn semanticTokensRangeRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, range: LspRange) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = semantic_tokens_id_base + seq,
        .method = "textDocument/semanticTokens/range",
        .params = .{ .textDocument = .{ .uri = uri }, .range = range },
    }, .{});
}

/// `textDocument/references`(§8.2l) — caret 자리, 선언 포함.
pub fn referencesRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = references_id_base + seq,
        .method = "textDocument/references",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character }, .context = .{ .includeDeclaration = true } },
    }, .{});
}

/// 위치 목록을 내는 요청의 종류(§8.2m) — 참조 피커가 그대로 쓴다. `references` 만 `context` 를 싣는다.
pub const LocationKind = enum {
    references,
    implementation,
    type_definition,
    declaration,

    pub fn method(self: LocationKind) []const u8 {
        return switch (self) {
            .references => "textDocument/references",
            .implementation => "textDocument/implementation",
            .type_definition => "textDocument/typeDefinition",
            .declaration => "textDocument/declaration",
        };
    }
    pub fn idBase(self: LocationKind) u32 {
        return switch (self) {
            .references => references_id_base,
            .implementation => implementation_id_base,
            .type_definition => type_definition_id_base,
            .declaration => declaration_id_base,
        };
    }
    /// `initialize` 응답의 provider 이름.
    pub fn providerKey(self: LocationKind) []const u8 {
        return switch (self) {
            .references => "referencesProvider",
            .implementation => "implementationProvider",
            .type_definition => "typeDefinitionProvider",
            .declaration => "declarationProvider",
        };
    }
};

/// 위치 요청(§8.2m) — `references` 는 `referencesRequest` 와 같은 바이트, 나머지 셋은 `context` 없이.
pub fn locationRequest(allocator: std.mem.Allocator, kind: LocationKind, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    if (kind == .references) return referencesRequest(allocator, seq, uri, line, character);
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = kind.idBase() + seq,
        .method = kind.method(),
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
    }, .{});
}

/// 서버가 그 종류의 provider 를 냈는가(bool 또는 객체). tsgo 는 `declarationProvider` 가 없고 그래도 물으면 `-32600` 이라 **안 물어야** 한다(§8.2m ②).
pub fn locationProviderSupported(result: ?std.json.Value, kind: LocationKind) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get(kind.providerKey()) orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// 응답의 위치 **전부**(§8.2l) — `Location[]`·`LocationLink[]`·단일 `Location`. 각 항목은 `definitionTarget` 과 같은 규칙(LocationLink 는
/// `targetSelectionRange` 우선). 모양이 아닌 항목은 뺀다. 돌려주는 것은 호출자 소유(문자열은 `result` 를 빌린다).
pub fn locationsFromResult(allocator: std.mem.Allocator, result: ?std.json.Value) error{OutOfMemory}![]Target {
    const r = result orelse return &.{};
    var out: std.ArrayList(Target) = .empty;
    errdefer out.deinit(allocator);
    switch (r) {
        .object => if (definitionTarget(r)) |t| try out.append(allocator, t),
        .array => |a| for (a.items) |it| {
            if (definitionTarget(it)) |t| try out.append(allocator, t);
        },
        else => {},
    }
    return try out.toOwnedSlice(allocator);
}

/// `textDocument/inlayHint`(§8.2n) — 보이는 줄 범위. 끝은 반열림이되 **줄 수를 안 넘긴다**(rust-analyzer 는 넘기면 `-32603`).
pub fn inlayHintRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, range: LspRange) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = inlay_hint_id_base + seq,
        .method = "textDocument/inlayHint",
        .params = .{ .textDocument = .{ .uri = uri }, .range = range },
    }, .{});
}

/// `textDocument/documentSymbol`(§8.2o) — 문서 단위(범위 인자가 없다 — `foldingRange` 와 같은 꼴).
pub fn documentSymbolRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = document_symbol_id_base + seq,
        .method = "textDocument/documentSymbol",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

/// 서버별 설정 블롭(§8.2n 「서버 설정」) — `initialized` 뒤 한 번 보내는 `workspace/didChangeConfiguration`. 없으면 `null`.
/// TS 계열: 힌트를 켠다(안 주면 tsgo 가 `null` 을 낸다 — 실측 2026-09-22).
pub fn didChangeConfigurationFor(allocator: std.mem.Allocator, language_id: []const u8) error{OutOfMemory}!?[]u8 {
    const ts = std.mem.eql(u8, language_id, "typescript") or std.mem.eql(u8, language_id, "typescriptreact") or std.mem.eql(u8, language_id, "javascript");
    if (!ts) return null;
    const hints = .{
        .parameterNames = .{ .enabled = "all" },
        .variableTypes = .{ .enabled = true },
        .functionLikeReturnTypes = .{ .enabled = true },
        .propertyDeclarationTypes = .{ .enabled = true },
    };
    return try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "workspace/didChangeConfiguration",
        .params = .{ .settings = .{ .typescript = .{ .inlayHints = hints }, .javascript = .{ .inlayHints = hints } } },
    }, .{});
}

/// `textDocument/foldingRange`(§8.2j) — 문서 전체(범위 인자가 없다).
pub fn foldingRangeRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = folding_range_id_base + seq,
        .method = "textDocument/foldingRange",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

/// `textDocument/semanticTokens/full`(§8.2i) — `range` 를 안 내는 서버(clangd)에는 처음부터 이것(capability 분기 — 시도 뒤 물러나는 폴백이 아니다).
pub fn semanticTokensFullRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = semantic_tokens_id_base + seq,
        .method = "textDocument/semanticTokens/full",
        .params = .{ .textDocument = .{ .uri = uri } },
    }, .{});
}

/// `initialize` 응답의 `renameProvider`(bool 또는 object).
pub fn renameSupported(result: ?std.json.Value) bool {
    return providerFlag(result, "renameProvider");
}

fn providerFlag(result: ?std.json.Value, name: []const u8) bool {
    const r = result orelse return false;
    if (r != .object) return false;
    const caps = r.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const prov = caps.object.get(name) orelse return false;
    return switch (prov) {
        .bool => |b| b,
        .object => true,
        else => false,
    };
}

/// `initialize` 응답의 `documentFormattingProvider`(bool 또는 object).
pub fn formattingSupported(result: ?std.json.Value) bool {
    return providerFlag(result, "documentFormattingProvider");
}

/// `textDocument/definition`(§8.2c).
pub fn definitionRequest(allocator: std.mem.Allocator, seq: u32, uri: []const u8, line: u32, character: u32) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = definition_id_base + seq,
        .method = "textDocument/definition",
        .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
    }, .{});
}

/// definition 결과의 **첫 항목**(§8.2c 「결과」) — `Location` · `Location[]` · `LocationLink[]`. `LocationLink` 는 `targetSelectionRange`
/// (없으면 `targetRange`)의 시작. `null`·빈 배열·모양이 아니면 `null`. `uri` 는 응답 트리 안의 조각(파싱 결과가 사는 동안 유효).
pub const Target = struct { uri: []const u8, line: u32, character: u32 };
pub fn definitionTarget(result: ?std.json.Value) ?Target {
    const r = result orelse return null;
    const first: std.json.Value = switch (r) {
        .object => r,
        .array => |a| if (a.items.len > 0) a.items[0] else return null,
        else => return null,
    };
    if (first != .object) return null;
    const o = first.object;
    // LocationLink
    if (o.get("targetUri")) |tu| {
        if (tu != .string) return null;
        const range = o.get("targetSelectionRange") orelse o.get("targetRange") orelse return null;
        const st = startOf(range) orelse return null;
        return .{ .uri = tu.string, .line = st.line, .character = st.character };
    }
    const uri = o.get("uri") orelse return null;
    if (uri != .string) return null;
    const st = startOf(o.get("range") orelse return null) orelse return null;
    return .{ .uri = uri.string, .line = st.line, .character = st.character };
}

fn startOf(range: std.json.Value) ?struct { line: u32, character: u32 } {
    if (range != .object) return null;
    const st = range.object.get("start") orelse return null;
    if (st != .object) return null;
    return .{
        .line = u32Of(st.object.get("line")) orelse return null,
        .character = u32Of(st.object.get("character")) orelse return null,
    };
}

/// hover 응답의 `contents` 를 **마크다운 한 덩어리**로 편다(§8.2b) — 세 모양이 있다: `MarkupContent{kind,value}` · `MarkedString`
/// (문자열 또는 `{language,value}` — 후자는 펜스로 친다) · 그 배열(빈 줄로 잇는다). `null` 결과나 빈 내용이면 `null`.
/// 돌려주는 것은 호출자 소유.
pub fn hoverMarkdown(allocator: std.mem.Allocator, result: ?std.json.Value) error{OutOfMemory}!?[]u8 {
    const r = result orelse return null;
    const obj = switch (r) {
        .object => |o| o,
        else => return null,
    };
    const contents = obj.get("contents") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMarked(allocator, &out, contents);
    const text = std.mem.trim(u8, out.items, " \t\r\n");
    if (text.len == 0) {
        out.deinit(allocator);
        return null;
    }
    const owned = try allocator.dupe(u8, text);
    out.deinit(allocator);
    return owned;
}

fn appendMarked(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) error{OutOfMemory}!void {
    switch (v) {
        .string => |s| try out.appendSlice(allocator, s),
        .array => |items| for (items.items, 0..) |it, i| {
            if (i > 0) try out.appendSlice(allocator, "\n\n");
            try appendMarked(allocator, out, it);
        },
        .object => |o| {
            const value: []const u8 = if (o.get("value")) |x| (switch (x) {
                .string => |s| s,
                else => "",
            }) else "";
            if (o.get("language")) |lang| if (lang == .string) {
                try out.appendSlice(allocator, "```");
                try out.appendSlice(allocator, lang.string);
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, value);
                try out.appendSlice(allocator, "\n```");
                return;
            };
            try out.appendSlice(allocator, value); // MarkupContent — kind 가 plaintext 여도 축소 규칙은 무해하다
        },
        else => {},
    }
}

/// hover 응답의 `range`(있으면) → `{start,end}` 의 `{line,character}` 넷. 없으면 `null`.
pub const Range = struct { start_line: u32, start_char: u32, end_line: u32, end_char: u32 };
pub fn hoverRange(result: ?std.json.Value) ?Range {
    const r = result orelse return null;
    if (r != .object) return null;
    const range = r.object.get("range") orelse return null;
    if (range != .object) return null;
    const st = range.object.get("start") orelse return null;
    const en = range.object.get("end") orelse return null;
    if (st != .object or en != .object) return null;
    return .{
        .start_line = u32Of(st.object.get("line")) orelse return null,
        .start_char = u32Of(st.object.get("character")) orelse return null,
        .end_line = u32Of(en.object.get("line")) orelse return null,
        .end_char = u32Of(en.object.get("character")) orelse return null,
    };
}

fn u32Of(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

pub fn shutdownRequest(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = shutdown_id, .method = "shutdown", .params = null }, .{});
}

pub fn exitNotification(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .method = "exit", .params = null }, .{});
}

/// 서버 요청 거부 응답(-32601). `id` 는 서버가 준 값 그대로(숫자 또는 문자열) — 대조는 서버가 한다.
pub fn methodNotFound(allocator: std.mem.Allocator, id: std.json.Value) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = @as(i32, -32601), .message = "method not supported by this client" },
    }, .{});
}

/// 파일 경로 → `file://` URI. 예약 문자는 퍼센트 인코딩(RFC 3986 unreserved 와 `/` 만 그대로).
pub fn fileUri(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    for (path) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~';
        if (keep) {
            try out.append(allocator, c);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, &hex);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `file://` URI → 경로(퍼센트 디코딩). 다른 scheme 이면 `null`. 결과는 `out` 안의 조각.
pub fn pathFromFileUri(uri: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // `file://localhost/x` 는 드물지만 명세상 유효 — host 를 뗀다. `file:///x` 는 host 가 빈 것.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (n >= out.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
            out[n] = v;
            i += 2;
        } else out[n] = rest[i];
        n += 1;
    }
    return out[0..n];
}

/// 들어온 메시지의 갈래.
pub const Incoming = union(enum) {
    /// 우리가 보낸 요청의 응답. `result` 는 트리 안의 값(파싱 결과가 사는 동안 유효).
    response: struct { id: RequestId, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8 = null, error_code: ?i64 = null },
    /// 서버 알림(`publishDiagnostics` 등).
    notification: struct { method: []const u8, params: ?std.json.Value },
    /// 서버 → 클라이언트 요청(id 있음) — 거부 대상.
    request: struct { id: std.json.Value, method: []const u8 },
    /// 모르는 id 의 응답이나 모양이 아닌 것 — 버린다.
    ignore,
};

pub fn classify(root: std.json.Value) Incoming {
    const obj = switch (root) {
        .object => |o| o,
        else => return .ignore,
    };
    const method: ?[]const u8 = if (obj.get("method")) |m| (switch (m) {
        .string => |s| s,
        else => null,
    }) else null;
    const id = obj.get("id");
    if (method) |m| {
        if (id != null and id.? != .null) return .{ .request = .{ .id = id.?, .method = m } };
        return .{ .notification = .{ .method = m, .params = obj.get("params") } };
    }
    const id_val = id orelse return .ignore;
    const id_num: i64 = switch (id_val) {
        .integer => |n| n,
        else => return .ignore,
    };
    const rid: RequestId = requestIdOf(id_num) orelse return .ignore;
    const is_error = obj.get("error") != null;
    return .{ .response = .{ .id = rid, .result = obj.get("result"), .is_error = is_error, .error_message = errorMessage(obj), .error_code = errorCode(obj) } };
}

/// `initialize` 응답에서 서버가 고른 위치 인코딩. 없으면 명세 기본(utf-16).
pub fn positionEncodingFromResult(result: ?std.json.Value) PositionEncoding {
    const r = result orelse return .utf16;
    const caps = switch (r) {
        .object => |o| o.get("capabilities") orelse return .utf16,
        else => return .utf16,
    };
    const enc = switch (caps) {
        .object => |o| o.get("positionEncoding") orelse return .utf16,
        else => return .utf16,
    };
    return switch (enc) {
        .string => |s| if (std.mem.eql(u8, s, "utf-8")) .utf8 else .utf16,
        else => .utf16,
    };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}

test "LSJ1 initialize 는 id 1·rootUri·utf-8 먼저인 positionEncodings·applyEdit false 를 싣는다 (§8.2a)" {
    const a = testing.allocator;
    const msg = try initializeRequest(a, "file:///r", 42);
    defer a.free(msg);
    var p = try parse(a, msg);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqual(@as(i64, 1), o.get("id").?.integer);
    try testing.expectEqualStrings("initialize", o.get("method").?.string);
    const params = o.get("params").?.object;
    try testing.expectEqualStrings("file:///r", params.get("rootUri").?.string);
    try testing.expectEqual(@as(i64, 42), params.get("processId").?.integer);
    const enc = params.get("capabilities").?.object.get("general").?.object.get("positionEncodings").?.array;
    try testing.expectEqualStrings("utf-8", enc.items[0].string);
    try testing.expectEqualStrings("utf-16", enc.items[1].string);
    try testing.expect(!params.get("capabilities").?.object.get("workspace").?.object.get("applyEdit").?.bool);
    try testing.expect(params.get("capabilities").?.object.get("textDocument").?.object.get("publishDiagnostics").?.object.get("versionSupport").?.bool);
}

test "LSJ2 didOpen/didChange/didClose — uri·version·전문, didChange 는 contentChanges 하나(Full) (§8.2a)" {
    const a = testing.allocator;
    const o1 = try didOpen(a, "file:///a.c", "c", 3, "int x;\n");
    defer a.free(o1);
    var p1 = try parse(a, o1);
    defer p1.deinit();
    const td = p1.value.object.get("params").?.object.get("textDocument").?.object;
    try testing.expectEqualStrings("c", td.get("languageId").?.string);
    try testing.expectEqual(@as(i64, 3), td.get("version").?.integer);
    try testing.expectEqualStrings("int x;\n", td.get("text").?.string);
    try testing.expect(p1.value.object.get("id") == null); // 알림

    const c1 = try didChangeFull(a, "file:///a.c", 4, "int y;\n");
    defer a.free(c1);
    var p2 = try parse(a, c1);
    defer p2.deinit();
    const changes = p2.value.object.get("params").?.object.get("contentChanges").?.array;
    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expect(changes.items[0].object.get("range") == null); // Full — range 없음
    try testing.expectEqualStrings("int y;\n", changes.items[0].object.get("text").?.string);

    const cl = try didClose(a, "file:///a.c");
    defer a.free(cl);
    try testing.expect(std.mem.indexOf(u8, cl, "textDocument/didClose") != null);
}

test "LSJ3 들어온 메시지를 가른다 — 응답(우리 id 만)·알림·서버 요청(거부 대상)·모르는 것 (§8.2a)" {
    const a = testing.allocator;
    var r = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"positionEncoding\":\"utf-8\"}}}");
    defer r.deinit();
    const c1 = classify(r.value);
    try testing.expect(c1 == .response and c1.response.id == .initialize and !c1.response.is_error);
    try testing.expectEqual(PositionEncoding.utf8, positionEncodingFromResult(c1.response.result));

    var n = try parse(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a\"}}");
    defer n.deinit();
    const c2 = classify(n.value);
    try testing.expect(c2 == .notification);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", c2.notification.method);

    var q = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":\"srv-7\",\"method\":\"workspace/configuration\",\"params\":{}}");
    defer q.deinit();
    const c3 = classify(q.value);
    try testing.expect(c3 == .request);
    try testing.expectEqualStrings("workspace/configuration", c3.request.method);
    const rej = try methodNotFound(a, c3.request.id);
    defer a.free(rej);
    try testing.expect(std.mem.indexOf(u8, rej, "\"id\":\"srv-7\"") != null);
    try testing.expect(std.mem.indexOf(u8, rej, "-32601") != null);

    var u = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":null}");
    defer u.deinit();
    try testing.expect(classify(u.value) == .ignore); // 우리가 보낸 적 없는 id
    var e = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-1,\"message\":\"x\"}}");
    defer e.deinit();
    const c5 = classify(e.value);
    try testing.expect(c5 == .response and c5.response.id == .shutdown and c5.response.is_error);
    var arr = try parse(a, "[1,2]");
    defer arr.deinit();
    try testing.expect(classify(arr.value) == .ignore);
    // 인코딩 기본은 utf-16 — 없으면·모르면.
    var r2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{}}}");
    defer r2.deinit();
    try testing.expectEqual(PositionEncoding.utf16, positionEncodingFromResult(classify(r2.value).response.result));
}

test "LSJ5 hover — 요청 id 는 1000+seq·contentFormat 에 markdown, 응답은 seq 로 대조, contents 세 모양이 마크다운 한 덩어리 (§8.2b)" {
    const a = testing.allocator;
    const req = try hoverRequest(a, 7, "file:///a.c", 3, 5);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":100000007") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/hover\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"line\":3,\"character\":5") != null);
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"hover\":{\"contentFormat\":[\"markdown\",\"plaintext\"]}") != null);
    // 응답 대조 — 1007 은 hover seq 7, 999 는 모르는 id.
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":100000007,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .hover and c1.response.id.hover == 7);
    try testing.expect((try hoverMarkdown(a, c1.response.result)) == null); // null 결과 = 내용 없음
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value) == .ignore);
    // contents 세 모양.
    var m1 = try parse(a, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"**x**\"},\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5}}}");
    defer m1.deinit();
    const t1 = (try hoverMarkdown(a, m1.value)).?;
    defer a.free(t1);
    try testing.expectEqualStrings("**x**", t1);
    const rg = hoverRange(m1.value).?;
    try testing.expectEqual(@as(u32, 2), rg.start_char);
    try testing.expectEqual(@as(u32, 5), rg.end_char);
    var m2 = try parse(a, "{\"contents\":[{\"language\":\"c\",\"value\":\"int x\"},\"doc\"]}");
    defer m2.deinit();
    const t2 = (try hoverMarkdown(a, m2.value)).?;
    defer a.free(t2);
    try testing.expectEqualStrings("```c\nint x\n```\n\ndoc", t2);
    try testing.expect(hoverRange(m2.value) == null);
    var m3 = try parse(a, "{\"contents\":\"  \"}");
    defer m3.deinit();
    try testing.expect((try hoverMarkdown(a, m3.value)) == null); // 공백뿐이면 없음
}

test "LSJ6 definition — 요청 id 는 2e8+seq, 응답은 seq 로 대조(hover 와 안 겹침), 결과 세 모양의 첫 항목·LocationLink 는 selection range (§8.2c)" {
    const a = testing.allocator;
    const req = try definitionRequest(a, 3, "file:///a.c", 1, 2);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":200000003") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/definition\"") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":200000003,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .definition and c1.response.id.definition == 3);
    try testing.expect(definitionTarget(c1.response.result) == null);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":100000003,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .hover); // 1003 은 hover 3 — definition 이 아니다
    // Location 하나.
    var l1 = try parse(a, "{\"uri\":\"file:///b.c\",\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":5}}}");
    defer l1.deinit();
    const t1 = definitionTarget(l1.value).?;
    try testing.expectEqualStrings("file:///b.c", t1.uri);
    try testing.expectEqual(@as(u32, 4), t1.line);
    try testing.expectEqual(@as(u32, 2), t1.character);
    // Location[] — 첫 항목. LocationLink[] — targetSelectionRange 가 targetRange 보다 먼저.
    var l2 = try parse(a, "[{\"uri\":\"file:///c.c\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}},{\"uri\":\"file:///d.c\",\"range\":{\"start\":{\"line\":9,\"character\":9},\"end\":{\"line\":9,\"character\":9}}}]");
    defer l2.deinit();
    try testing.expectEqualStrings("file:///c.c", definitionTarget(l2.value).?.uri);
    var l3 = try parse(a, "[{\"targetUri\":\"file:///e.c\",\"targetRange\":{\"start\":{\"line\":10,\"character\":0},\"end\":{\"line\":20,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":10,\"character\":8}}}]");
    defer l3.deinit();
    const t3 = definitionTarget(l3.value).?;
    try testing.expectEqualStrings("file:///e.c", t3.uri);
    try testing.expectEqual(@as(u32, 4), t3.character);
    var l4 = try parse(a, "[{\"targetUri\":\"file:///f.c\",\"targetRange\":{\"start\":{\"line\":3,\"character\":1},\"end\":{\"line\":3,\"character\":2}}}]");
    defer l4.deinit();
    try testing.expectEqual(@as(u32, 3), definitionTarget(l4.value).?.line); // selection 이 없으면 targetRange
    var l5 = try parse(a, "[]");
    defer l5.deinit();
    try testing.expect(definitionTarget(l5.value) == null);
}

test "LSJ7 signatureHelp — 요청 id 3e8+seq·context, capability, 트리거 글자, 활성 시그니처/파라미터 기본값과 label 세 모양 (§8.2d)" {
    const a = testing.allocator;
    const req = try signatureHelpRequest(a, 5, "file:///a.c", 2, 7, .trigger_character, '(', false);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":300000005") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/signatureHelp\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"context\":{\"triggerKind\":2,\"triggerCharacter\":\"(\",\"isRetrigger\":false}") != null);
    const req2 = try signatureHelpRequest(a, 6, "file:///a.c", 2, 7, .content_change, null, true);
    defer a.free(req2);
    try testing.expect(std.mem.indexOf(u8, req2, "\"context\":{\"triggerKind\":3,\"isRetrigger\":true}") != null); // 글자 없음 → 키 생략
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"labelOffsetSupport\":true") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"contextSupport\":true") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":300000005,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .signature and c1.response.id.signature == 5);
    try testing.expect(signatureView(c1.response.result, .utf8) == null);
    // capability — 트리거·재트리거 글자, 없으면 supported=false, `true` 도 지원.
    var cap = try parse(a, "{\"capabilities\":{\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\",\"가\"],\"retriggerCharacters\":[\")\"]}}}");
    defer cap.deinit();
    const tr = signatureTriggersFromResult(cap.value);
    try testing.expect(tr.supported and tr.isTrigger('(') and tr.isTrigger(',') and !tr.isTrigger(')') and tr.isRetrigger(')'));
    try testing.expectEqual(@as(usize, 2), tr.len); // 비ASCII 는 버린다
    var cap2 = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer cap2.deinit();
    try testing.expect(!signatureTriggersFromResult(cap2.value).supported);
    // 결과 — activeSignature 1, 시그니처의 activeParameter 가 전체 것보다 먼저, [start,end] 는 인코딩 단위 → byte.
    var r1 = try parse(a,
        \\{"signatures":[
        \\ {"label":"int add(int a, int b)","documentation":"adds","parameters":[{"label":[8,13],"documentation":{"kind":"markdown","value":"first"}},{"label":"int b"}]},
        \\ {"label":"int 가(int c)","activeParameter":0,"parameters":[{"label":[6,11]}]}
        \\],"activeSignature":1,"activeParameter":1}
    );
    defer r1.deinit();
    const v1 = signatureView(r1.value, .utf16).?;
    try testing.expectEqualStrings("int 가(int c)", v1.label);
    try testing.expectEqual(@as(u32, 1), v1.index);
    try testing.expectEqual(@as(u32, 2), v1.count);
    try testing.expectEqual(@as(u32, 8), v1.param.?.lo); // utf-16 6 → byte 8(가 = 3 byte)
    try testing.expectEqual(@as(u32, 13), v1.param.?.hi);
    try testing.expect(v1.doc == null);
    // activeSignature 없음 → 0, 전체 activeParameter 1 → 문자열 label 은 부분 문자열 위치.
    var r2 = try parse(a,
        \\{"signatures":[{"label":"int add(int a, int b)","documentation":{"kind":"plaintext","value":"adds"},"parameters":[{"label":[8,13]},{"label":"int b","documentation":"second"}]}],"activeParameter":1}
    );
    defer r2.deinit();
    const v2 = signatureView(r2.value, .utf8).?;
    try testing.expectEqual(@as(u32, 0), v2.index);
    try testing.expectEqual(@as(u32, 15), v2.param.?.lo);
    try testing.expectEqual(@as(u32, 20), v2.param.?.hi);
    try testing.expectEqualStrings("adds", v2.doc.?);
    try testing.expectEqualStrings("second", v2.param_doc.?);
    // 빈 signatures → null; activeSignature 가 범위 밖이면 0.
    var r3 = try parse(a, "{\"signatures\":[]}");
    defer r3.deinit();
    try testing.expect(signatureView(r3.value, .utf8) == null);
    var r4 = try parse(a, "{\"signatures\":[{\"label\":\"f()\"}],\"activeSignature\":9}");
    defer r4.deinit();
    try testing.expectEqual(@as(u32, 0), signatureView(r4.value, .utf8).?.index);
}

test "LSJ8 formatting — 요청 id 4e8+seq·options(tabSize·insertSpaces false), capability bool/object (§8.2e)" {
    const a = testing.allocator;
    const req = try formattingRequest(a, 2, "file:///a.c", 4, false);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":400000002") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/formatting\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"options\":{\"tabSize\":4,\"insertSpaces\":false}") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":400000002,\"result\":[]}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .formatting and c1.response.id.formatting == 2);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":300000002,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .signature); // 3e9 대는 signature
    var c_true = try parse(a, "{\"capabilities\":{\"documentFormattingProvider\":true}}");
    defer c_true.deinit();
    var c_obj = try parse(a, "{\"capabilities\":{\"documentFormattingProvider\":{\"workDoneProgress\":false}}}");
    defer c_obj.deinit();
    var c_no = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer c_no.deinit();
    var c_false = try parse(a, "{\"capabilities\":{\"documentFormattingProvider\":false}}");
    defer c_false.deinit();
    try testing.expect(formattingSupported(c_true.value) and formattingSupported(c_obj.value));
    try testing.expect(!formattingSupported(c_no.value) and !formattingSupported(c_false.value) and !formattingSupported(null));
}

test "LSJ9 rename — 요청 id 5e8+seq·newName, capability, 오류 응답의 message (§8.2f)" {
    const a = testing.allocator;
    const req = try renameRequest(a, 3, "file:///a.c", 1, 4, "add2");
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":500000003") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/rename\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"position\":{\"line\":1,\"character\":4}") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"newName\":\"add2\"") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":500000003,\"result\":null}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .rename and c1.response.id.rename == 3 and !c1.response.is_error);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":400000003,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .formatting); // 4e9 대는 formatting 그대로
    var p3 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":500000003,\"error\":{\"code\":-32602,\"message\":\"cannot rename\"}}");
    defer p3.deinit();
    const c3 = classify(p3.value);
    try testing.expect(c3.response.is_error);
    try testing.expectEqualStrings("cannot rename", c3.response.error_message.?);
    var p4 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":500000003,\"error\":{\"code\":1}}");
    defer p4.deinit();
    try testing.expect(classify(p4.value).response.is_error and classify(p4.value).response.error_message == null);
    // 오류 코드 — content modified(-32801)·server cancelled(-32802) 는 되물을 수 있는 것, 그 밖은 아니다(§8.2l).
    var p5 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1200000001,\"error\":{\"code\":-32801,\"message\":\"content modified\"}}");
    defer p5.deinit();
    try testing.expectEqual(@as(?i64, -32801), classify(p5.value).response.error_code);
    try testing.expect(isRetryableError(classify(p5.value).response.error_code));
    try testing.expect(isRetryableError(-32802));
    try testing.expect(!isRetryableError(-32601) and !isRetryableError(null));
    try testing.expectEqual(@as(?i64, -32602), classify(p3.value).response.error_code);
    try testing.expectEqual(@as(?i64, 1), classify(p4.value).response.error_code);
    var c_true = try parse(a, "{\"capabilities\":{\"renameProvider\":true}}");
    defer c_true.deinit();
    var c_obj = try parse(a, "{\"capabilities\":{\"renameProvider\":{\"prepareProvider\":true}}}");
    defer c_obj.deinit();
    var c_false = try parse(a, "{\"capabilities\":{\"renameProvider\":false}}");
    defer c_false.deinit();
    var c_no = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer c_no.deinit();
    try testing.expect(renameSupported(c_true.value) and renameSupported(c_obj.value));
    try testing.expect(!renameSupported(c_false.value) and !renameSupported(c_no.value) and !renameSupported(null));
}

test "LSJ10 completion — 요청 id 6e8+seq·context(triggerKind 1/2·글자), capability triggerCharacters, snippetSupport=false (§8.2g)" {
    const a = testing.allocator;
    const req = try completionRequest(a, 4, "file:///a.c", 2, 7, null);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":600000004") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/completion\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"triggerKind\":1") != null);
    const req2 = try completionRequest(a, 5, "file:///a.c", 2, 7, '.');
    defer a.free(req2);
    try testing.expect(std.mem.indexOf(u8, req2, "\"triggerKind\":2,\"triggerCharacter\":\".\"") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":600000004,\"result\":[]}");
    defer p1.deinit();
    const c1 = classify(p1.value);
    try testing.expect(c1 == .response and c1.response.id == .completion and c1.response.id.completion == 4);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":500000004,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .rename); // 5e9 대는 rename 그대로
    var caps = try parse(a, "{\"capabilities\":{\"completionProvider\":{\"triggerCharacters\":[\".\",\"->\",\"::\"]}}}");
    defer caps.deinit();
    const t = completionTriggersFromResult(caps.value);
    try testing.expect(t.supported and t.isTrigger('.') and t.isTrigger('-') and t.isTrigger(':') and !t.isTrigger('a'));
    var none = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer none.deinit();
    try testing.expect(!completionTriggersFromResult(none.value).supported);
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"snippetSupport\":false") != null);
}

test "LSJ11 codeAction — 요청 id 7e8+seq·range·context.diagnostics(code 없으면 생략)·triggerKind, resolve 요청은 항목 JSON 그대로(8e8+seq), capability resolveProvider (§8.2h)" {
    const a = testing.allocator;
    const diags = [_]ContextDiagnostic{
        .{ .range = .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 5 } }, .message = "Expected ';'", .severity = 1, .code = "-Wexpected-semi" },
        .{ .range = .{ .start = .{ .line = 3, .character = 0 }, .end = .{ .line = 3, .character = 1 } }, .message = "unused", .severity = 2 },
    };
    const req = try codeActionRequest(a, 9, "file:///a.c", .{ .start = .{ .line = 1, .character = 2 }, .end = .{ .line = 1, .character = 2 } }, &diags);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":700000009") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"method\":\"textDocument/codeAction\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"range\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":2}}") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"code\":\"-Wexpected-semi\"") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\"message\":\"unused\",\"severity\":2}") != null); // code 없는 것은 생략
    try testing.expect(std.mem.indexOf(u8, req, "\"triggerKind\":1") != null);
    const res = try codeActionResolveRequest(a, 4, "{\"title\":\"x\",\"data\":{\"id\":7}}");
    defer a.free(res);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":800000004,\"method\":\"codeAction/resolve\",\"params\":{\"title\":\"x\",\"data\":{\"id\":7}}}", res);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":700000009,\"result\":[]}");
    defer p1.deinit();
    try testing.expect(classify(p1.value).response.id == .code_action and classify(p1.value).response.id.code_action == 9);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":800000004,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .code_action_resolve and classify(p2.value).response.id.code_action_resolve == 4);
    var p3 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":600000004,\"result\":null}");
    defer p3.deinit();
    try testing.expect(classify(p3.value).response.id == .completion); // 6e9 대는 completion 그대로
    var c1 = try parse(a, "{\"capabilities\":{\"codeActionProvider\":{\"codeActionKinds\":[\"quickfix\"],\"resolveProvider\":true}}}");
    defer c1.deinit();
    const k1 = codeActionCapsFromResult(c1.value);
    try testing.expect(k1.supported and k1.resolve);
    var c2 = try parse(a, "{\"capabilities\":{\"codeActionProvider\":true}}");
    defer c2.deinit();
    const k2 = codeActionCapsFromResult(c2.value);
    try testing.expect(k2.supported and !k2.resolve);
    var c3 = try parse(a, "{\"capabilities\":{\"hoverProvider\":true}}");
    defer c3.deinit();
    try testing.expect(!codeActionCapsFromResult(c3.value).supported);
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"resolveSupport\":{\"properties\":[\"edit\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"dataSupport\":true") != null);
}

test "LSJ12 completionItem/resolve — 요청은 항목 JSON 그대로(9e8+seq), capability resolveProvider, initialize 의 resolveSupport (§8.2g-b)" {
    const a = testing.allocator;
    const req = try completionResolveRequest(a, 6, "{\"label\":\"lazy\",\"data\":{\"id\":3}}");
    defer a.free(req);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":900000006,\"method\":\"completionItem/resolve\",\"params\":{\"label\":\"lazy\",\"data\":{\"id\":3}}}", req);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":900000006,\"result\":{}}");
    defer p1.deinit();
    try testing.expect(classify(p1.value).response.id == .completion_resolve and classify(p1.value).response.id.completion_resolve == 6);
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":800000006,\"result\":null}");
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .code_action_resolve); // 8e9 대는 그대로
    var caps = try parse(a, "{\"capabilities\":{\"completionProvider\":{\"triggerCharacters\":[\".\"],\"resolveProvider\":true}}}");
    defer caps.deinit();
    try testing.expect(completionTriggersFromResult(caps.value).resolve);
    var caps2 = try parse(a, "{\"capabilities\":{\"completionProvider\":{}}}");
    defer caps2.deinit();
    try testing.expect(completionTriggersFromResult(caps2.value).supported and !completionTriggersFromResult(caps2.value).resolve);
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"resolveSupport\":{\"properties\":[\"additionalTextEdits\",\"detail\",\"documentation\"]}") != null);
}

test "LSJ4 file URI — 공백·한글은 퍼센트, 되읽으면 같은 경로 (§8.2a)" {
    const a = testing.allocator;
    const uri = try fileUri(a, "/tmp/a b/가.c");
    defer a.free(uri);
    try testing.expectEqualStrings("file:///tmp/a%20b/%EA%B0%80.c", uri);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/tmp/a b/가.c", pathFromFileUri(uri, &buf).?);
    try testing.expect(pathFromFileUri("http://x/y", &buf) == null);
    try testing.expectEqualStrings("/x", pathFromFileUri("file://localhost/x", &buf).?);
}

test "LSJ13 요청 id 는 i32 안 — 종류마다 1e8 칸, seq 는 칸 안에서 돌고(0 건너뜀), classify 는 칸 경계에서 갈리며 칸 밖은 무시 (lsp-server 호환, §8.2a)" {
    const a = testing.allocator;
    try testing.expect(@as(u64, completion_resolve_id_base) + id_span - 1 <= std.math.maxInt(i32));
    try testing.expectEqual(@as(u32, 1), nextSeq(0));
    try testing.expectEqual(@as(u32, 1), nextSeq(id_span - 1)); // 칸 끝에서 1 로(0 은 건너뛴다)
    try testing.expectEqual(@as(u32, 5), nextSeq(4));
    const Case = struct { id: i64, want: std.meta.Tag(RequestId), seq: u32 };
    const cases = [_]Case{
        .{ .id = hover_id_base + 7, .want = .hover, .seq = 7 },
        .{ .id = definition_id_base, .want = .definition, .seq = 0 },
        .{ .id = @as(i64, signature_id_base) + id_span - 1, .want = .signature, .seq = id_span - 1 }, // 칸 끝
        .{ .id = formatting_id_base, .want = .formatting, .seq = 0 }, // signature 칸 끝 + 1 = formatting 시작
        .{ .id = rename_id_base + 3, .want = .rename, .seq = 3 },
        .{ .id = completion_id_base + 1, .want = .completion, .seq = 1 },
        .{ .id = code_action_id_base + 9, .want = .code_action, .seq = 9 },
        .{ .id = code_action_resolve_id_base + 4, .want = .code_action_resolve, .seq = 4 },
        .{ .id = @as(i64, completion_resolve_id_base) + id_span - 1, .want = .completion_resolve, .seq = id_span - 1 },
    };
    for (cases) |c| {
        const body = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{c.id});
        defer a.free(body);
        var p = try parse(a, body);
        defer p.deinit();
        const inc = classify(p.value);
        try testing.expect(inc == .response);
        try testing.expectEqual(c.want, std.meta.activeTag(inc.response.id));
        const got: u32 = switch (inc.response.id) {
            .initialize, .shutdown => 0,
            inline else => |v| v,
        };
        try testing.expectEqual(c.seq, got);
    }
    // 칸 밖 — 1e9 이상(옛 1e9 배수 base)·hover 칸 앞은 무시(우리 것이 아니다).
    var q1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":6000000001,\"result\":null}");
    defer q1.deinit();
    try testing.expect(classify(q1.value) == .ignore);
    var q2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1000,\"result\":null}");
    defer q2.deinit();
    try testing.expect(classify(q2.value) == .ignore);
    // 실제 요청 하나가 i32 안의 id 를 싣는다.
    const req = try completionRequest(a, 1, "file:///a.c", 0, 0, null);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":600000001,") != null);
}

test "LSJ14 initialize 가 completionItem.labelDetailsSupport 를 선언한다 (§8.2g-c)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"labelDetailsSupport\":true") != null);
    // §8.2g-d — completion 의 `completionItem` 블록 안에서(시그니처 쪽에도 같은 키가 있어 전체 검색은 헛것).
    const ci = std.mem.indexOf(u8, init, "\"completionItem\":{").?;
    const block = init[ci .. ci + @min(init.len - ci, 400)];
    try testing.expect(std.mem.indexOf(u8, block, "\"documentationFormat\":[\"markdown\",\"plaintext\"]") != null);
}

test "LSJ20 capability 의 JSON «모양» — symbolKind.valueSet 은 정수 배열이고 initialized 의 params 는 객체다(둘 다 문자열·배열로 나가 tsgo 세션을 죽였다) (§8.2o·§8.2a)" {
    // **이 판정자는 「모양」을 잰다.** 가짜 서버는 무엇이든 받아 주므로 값 자체를 구조로 확인해야 한다 —
    // `[_]u8{…}` 은 Zig 가 **JSON 문자열**로 내고(tsgo: `cannot unmarshal JSON string into []SymbolKind`),
    // `.{}`(빈 튜플)는 **`[]`** 로 나간다(tsgo: `cannot unmarshal JSON array into InitializedParams`). 둘 다 세션 전체를 죽였다.
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    var p = try parse(a, init);
    defer p.deinit();
    const caps = p.value.object.get("params").?.object.get("capabilities").?;
    const ds = caps.object.get("textDocument").?.object.get("documentSymbol").?;
    try testing.expect(ds.object.get("hierarchicalDocumentSymbolSupport").?.bool);
    const vs = ds.object.get("symbolKind").?.object.get("valueSet").?;
    try testing.expect(vs == .array); // **문자열이면 여기서 죽는다**
    try testing.expectEqual(@as(usize, 26), vs.array.items.len);
    for (vs.array.items, 1..) |v, want| {
        try testing.expect(v == .integer);
        try testing.expectEqual(@as(i64, @intCast(want)), v.integer);
    }
    const msg = try initializedNotification(a);
    defer a.free(msg);
    var q = try parse(a, msg);
    defer q.deinit();
    try testing.expect(q.value.object.get("params").? == .object); // **`[]` 면 여기서 죽는다**
}

test "LSJ15 semanticTokens — initialize capability(range·full·표준 종류)·요청 둘의 id 칸(10e8)·classify (§8.2i)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 1);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"semanticTokens\":{\"requests\":{\"range\":true,\"full\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"tokenTypes\":[\"namespace\",\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"multilineTokenSupport\":false") != null);
    const rr = try semanticTokensRangeRequest(a, 3, "file:///a.rs", .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 40, .character = 0 } });
    defer a.free(rr);
    try testing.expect(std.mem.indexOf(u8, rr, "\"id\":1000000003,\"method\":\"textDocument/semanticTokens/range\"") != null);
    try testing.expect(std.mem.indexOf(u8, rr, "\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":40,\"character\":0}}") != null);
    const fr = try semanticTokensFullRequest(a, 4, "file:///a.c");
    defer a.free(fr);
    try testing.expect(std.mem.indexOf(u8, fr, "\"id\":1000000004,\"method\":\"textDocument/semanticTokens/full\"") != null);
    try testing.expect(std.mem.indexOf(u8, fr, "\"range\"") == null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1000000003,\"result\":{\"data\":[]}}");
    defer p1.deinit();
    try testing.expect(classify(p1.value).response.id == .semantic_tokens and classify(p1.value).response.id.semantic_tokens == 3);
    try testing.expect(@as(u64, semantic_tokens_id_base) + id_span - 1 <= std.math.maxInt(i32));
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1800000000,\"result\":null}"); // 칸 밖(마지막 칸 17e8 의 다음)
    defer p2.deinit();
    try testing.expect(classify(p2.value) == .ignore);
}

test "LSJ16 foldingRange — initialize capability(lineFoldingOnly·종류 셋)·요청·id 칸(11e8)·classify·칸 밖 (§8.2j)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 42);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"foldingRange\":{\"lineFoldingOnly\":true,\"foldingRangeKind\":{\"valueSet\":[\"comment\",\"imports\",\"region\"]}}") != null);
    const fr = try foldingRangeRequest(a, 7, "file:///a.rs");
    defer a.free(fr);
    try testing.expect(std.mem.indexOf(u8, fr, "\"id\":1100000007,\"method\":\"textDocument/foldingRange\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.rs\"}}") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1100000007,\"result\":[]}");
    defer p1.deinit();
    try testing.expect(classify(p1.value).response.id == .folding_range and classify(p1.value).response.id.folding_range == 7);
    try testing.expect(@as(u64, folding_range_id_base) + id_span - 1 <= std.math.maxInt(i32));
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1199999999,\"result\":null}"); // 칸 끝
    defer p2.deinit();
    try testing.expect(classify(p2.value).response.id == .folding_range and classify(p2.value).response.id.folding_range == 99999999);
    var p3 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1800000000,\"result\":null}"); // 칸 밖(마지막 칸 17e8 의 다음)
    defer p3.deinit();
    try testing.expect(classify(p3.value) == .ignore);
}

test "LSJ17 didSave — capability 선언·통지 둘(text 유무)·서버 save 선언 파싱(객체 true·{includeText}·false·숫자·없음) (§8.2k)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 42);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"synchronization\":{\"dynamicRegistration\":false,\"didSave\":true}") != null);
    const bare = try didSave(a, "file:///a.rs", null);
    defer a.free(bare);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.rs\"}}}", bare);
    const with = try didSave(a, "file:///a.rs", "fn main() {}\n");
    defer a.free(with);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.rs\"},\"text\":\"fn main() {}\\n\"}}", with);
    const cases = [_]struct { json: []const u8, supported: bool, include: bool }{
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":true}}}", .supported = true, .include = false }, // tsgo·clangd
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{}}}}", .supported = true, .include = false }, // rust-analyzer
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"save\":{\"includeText\":true}}}}", .supported = true, .include = true },
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"save\":{\"includeText\":false}}}}", .supported = true, .include = false },
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"save\":false}}}", .supported = false, .include = false },
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":1}}}", .supported = false, .include = false },
        .{ .json = "{\"capabilities\":{\"textDocumentSync\":1}}", .supported = false, .include = false }, // 숫자 꼴 — 선언 없음
        .{ .json = "{\"capabilities\":{\"hoverProvider\":true}}", .supported = false, .include = false },
    };
    for (cases) |cse| {
        var p = try parse(a, cse.json);
        defer p.deinit();
        const sc = saveCapsFromResult(p.value);
        try testing.expectEqual(cse.supported, sc.supported);
        try testing.expectEqual(cse.include, sc.include_text);
    }
    try testing.expect(!saveCapsFromResult(null).supported);
}

test "LSJ18 references — capability·요청(includeDeclaration)·id 칸(12e8)·classify·칸 밖·locationsFromResult 세 모양 (§8.2l)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 42);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"references\":{\"dynamicRegistration\":false}") != null);
    const req = try referencesRequest(a, 9, "file:///a.rs", 2, 11);
    defer a.free(req);
    try testing.expect(std.mem.indexOf(u8, req, "\"id\":1200000009,\"method\":\"textDocument/references\",\"params\":{\"textDocument\":{\"uri\":\"file:///a.rs\"},\"position\":{\"line\":2,\"character\":11},\"context\":{\"includeDeclaration\":true}}") != null);
    var p1 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1200000009,\"result\":[]}");
    defer p1.deinit();
    try testing.expect(classify(p1.value).response.id == .references and classify(p1.value).response.id.references == 9);
    try testing.expect(@as(u64, references_id_base) + id_span - 1 <= std.math.maxInt(i32));
    var p2 = try parse(a, "{\"jsonrpc\":\"2.0\",\"id\":1800000000,\"result\":null}"); // 칸 밖
    defer p2.deinit();
    try testing.expect(classify(p2.value) == .ignore);
    // 결과 세 모양: Location[] · LocationLink[](selection range 우선) · 단일 Location; 모양 아닌 항목은 뺀다; null 은 빈 목록.
    var r1 = try parse(a, "[{\"uri\":\"file:///a.rs\",\"range\":{\"start\":{\"line\":8,\"character\":12},\"end\":{\"line\":8,\"character\":17}}},{\"targetUri\":\"file:///b.rs\",\"targetRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":3,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":1,\"character\":4},\"end\":{\"line\":1,\"character\":9}}},7,{\"uri\":3}]");
    defer r1.deinit();
    const locs = try locationsFromResult(a, r1.value);
    defer a.free(locs);
    try testing.expectEqual(@as(usize, 2), locs.len);
    try testing.expectEqualStrings("file:///a.rs", locs[0].uri);
    try testing.expectEqual(@as(u32, 8), locs[0].line);
    try testing.expectEqualStrings("file:///b.rs", locs[1].uri);
    try testing.expectEqual(@as(u32, 1), locs[1].line);
    try testing.expectEqual(@as(u32, 4), locs[1].character);
    var r2 = try parse(a, "{\"uri\":\"file:///c.rs\",\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":1}}}");
    defer r2.deinit();
    const one = try locationsFromResult(a, r2.value);
    defer a.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(usize, 0), (try locationsFromResult(a, null)).len);
}

test "LSJ19 implementation·typeDefinition·declaration — capability 셋(linkSupport)·요청 셋(context 없음)·id 칸 13~15e8·classify·provider 파싱(bool·객체·없음) (§8.2m)" {
    const a = testing.allocator;
    const init = try initializeRequest(a, "file:///r", 42);
    defer a.free(init);
    try testing.expect(std.mem.indexOf(u8, init, "\"implementation\":{\"dynamicRegistration\":false,\"linkSupport\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"typeDefinition\":{\"dynamicRegistration\":false,\"linkSupport\":true}") != null);
    try testing.expect(std.mem.indexOf(u8, init, "\"declaration\":{\"dynamicRegistration\":false,\"linkSupport\":true}") != null);
    const kinds = [_]struct { k: LocationKind, id: []const u8, m: []const u8 }{
        .{ .k = .implementation, .id = "1300000004", .m = "textDocument/implementation" },
        .{ .k = .type_definition, .id = "1400000004", .m = "textDocument/typeDefinition" },
        .{ .k = .declaration, .id = "1500000004", .m = "textDocument/declaration" },
    };
    for (kinds) |kd| {
        const req = try locationRequest(a, kd.k, 4, "file:///a.rs", 1, 7);
        defer a.free(req);
        var expect_buf: [256]u8 = undefined;
        const want = try std.fmt.bufPrint(&expect_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///a.rs\"}},\"position\":{{\"line\":1,\"character\":7}}}}}}", .{ kd.id, kd.m });
        try testing.expectEqualStrings(want, req);
        var resp_buf: [96]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":[]}}", .{kd.id});
        var p = try parse(a, resp);
        defer p.deinit();
        const rid = classify(p.value).response.id;
        try testing.expect(switch (kd.k) {
            .implementation => rid == .implementation and rid.implementation == 4,
            .type_definition => rid == .type_definition and rid.type_definition == 4,
            .declaration => rid == .declaration and rid.declaration == 4,
            .references => false,
        });
    }
    // references 는 같은 함수로도 같은 바이트(context 포함).
    const r1 = try locationRequest(a, .references, 9, "file:///a.rs", 2, 11);
    defer a.free(r1);
    const r2 = try referencesRequest(a, 9, "file:///a.rs", 2, 11);
    defer a.free(r2);
    try testing.expectEqualStrings(r2, r1);
    try testing.expect(@as(u64, declaration_id_base) + id_span - 1 <= std.math.maxInt(i32));
    // provider 파싱 — rust-analyzer(셋 다 true) · tsgo(declaration 없음) · 객체 꼴.
    var ra = try parse(a, "{\"capabilities\":{\"implementationProvider\":true,\"typeDefinitionProvider\":true,\"declarationProvider\":true}}");
    defer ra.deinit();
    try testing.expect(locationProviderSupported(ra.value, .implementation) and locationProviderSupported(ra.value, .type_definition) and locationProviderSupported(ra.value, .declaration));
    var ts = try parse(a, "{\"capabilities\":{\"implementationProvider\":true,\"typeDefinitionProvider\":{\"workDoneProgress\":false}}}");
    defer ts.deinit();
    try testing.expect(locationProviderSupported(ts.value, .implementation) and locationProviderSupported(ts.value, .type_definition));
    try testing.expect(!locationProviderSupported(ts.value, .declaration));
    try testing.expect(!locationProviderSupported(ts.value, .references));
    var f = try parse(a, "{\"capabilities\":{\"declarationProvider\":false}}");
    defer f.deinit();
    try testing.expect(!locationProviderSupported(f.value, .declaration));
    try testing.expect(!locationProviderSupported(null, .implementation));
}
