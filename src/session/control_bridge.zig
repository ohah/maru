//! Track C 5b: 신뢰 웹 브리지(`window.maru.*`) 디스패치 코어 — **L2 순수·헤드리스**([control-plane.md] §8.1.1).
//!
//! Swift(L4)가 신뢰(markdown) 패널의 isolated `WKContentWorld` 메시지 핸들러 진입에서 **`frameInfo.isMainFrame` +
//! `securityOrigin`(=`maru-app://app`) exact-pin**을 **먼저** 검증(신뢰 게이트 = transport 층, §8.1.1 ②)한 뒤, 통과한
//! 요청 한 줄을 이 함수로 넘긴다. 따라서 이 코어엔 **capability auth가 없다** — 신뢰는 origin/frame으로 이미 확립돼
//! 있고, 소켓 경로(control_dispatch/control_browser)의 peer-cred·capability와 달리 브리지는 in-process 신뢰 채널이다
//! (§8.1 "웹 브리지는 신뢰 콘텐츠에만 노출"). 이 부재는 실수가 아니라 신뢰 모델의 명시적 결과다.
//!
//! **5b 최소 표면**: round-trip 증명 `maru.hello()` → `{protocol, server_version}` 1개. 핸들러 도달 + 신뢰 게이트 통과를
//! E2E로 증명하는 최소 method다. 실 `window.maru.*` API 표면(navigate/read 등)은 5d+/Phase 7.
//!
//! **범위 밖**: `WKContentWorld`·메시지 핸들러·`window.maru` shim·origin 검증(Swift L4 어댑터), 소켓 transport
//! (control_server), `browser.*`(control_browser). wire 스키마는 소켓과 동일 JSON-RPC 2.0(§8.1 "메시지 스키마 하나").

const std = @import("std");
const cp = @import("control_plane.zig");
const file_policy = @import("file_panel_bridge.zig");
const mermaid_protocol = @import("mermaid_protocol.zig");

/// 브리지 method 이름(5b 최소: `hello` 1개). `window.maru` shim의 `maru.hello()`가 이 method 요청으로 매핑된다.
/// 소켓 핸드셰이크의 `hello` notification(cp.hello_method)과 이름은 같지만 문맥이 다르다 — 이건 id 있는 **request**로
/// reply를 받고, 소켓 hello는 id 없는 notification이다(별개 dispatch라 충돌 없음).
pub const hello_method = "hello";
pub const file_read_method = "maru.file.read";
pub const file_begin_document_method = "maru.file.beginDocument";
pub const file_read_asset_method = "maru.file.readAsset";
/// FP14: 이미지 패널이 **자기 자신의 파일**을 base64로 읽는다(경로 인자 없음 — capability는 자기 파일 1개로 최소).
/// raster 이미지는 바이너리라 텍스트 `read`(UTF-8 검증)로 못 읽어 별도 메서드가 필요하다. mime는 native가 결정.
pub const file_write_method = "maru.file.write";
pub const file_set_dirty_method = "maru.file.setDirty";
pub const file_resolve_external_change_method = "maru.file.resolveExternalChange";
pub const file_open_link_method = "maru.file.openLink";
pub const file_render_mermaid_method = "maru.file.renderMermaid";
pub const file_revoke_mermaid_method = "maru.file.revokeMermaid";
pub const file_live_preview_ready_method = "maru.file.livePreviewReady";
/// 모든 bridge 정수는 JavaScript `Number`를 왕복하므로 이 상한 안에서만 identity가 정확하다.
pub const max_js_safe_integer: u64 = 9_007_199_254_740_991;

pub const DirtyReport = struct {
    dirty: bool,
    editor_epoch: u64 = 0,
    revision: u64,
    request_id: u64 = 0,
};

pub const MermaidRenderRequest = struct {
    renderer: mermaid_protocol.RendererCapability,
    fence_id: u64,
    source_hash: [32]u8,
    source: []const u8,
};

/// 실제 파일 시스템 접근을 platform 계층에서 주입한다. 반환 slice는 `gpa` 소유이며 dispatch가 해제한다.
/// callback error는 경로/존재 정보를 노출하지 않는 균일 `internal_error`로 접는다.
pub const FileAccess = struct {
    context: *anyopaque,
    begin_document_fn: *const fn (context: *anyopaque, document_id: u64) anyerror!u64,
    read_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, editor_epoch: u64) anyerror![]u8,
    read_asset_fn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, normalized_path: []const u8) anyerror![]u8,
    write_fn: *const fn (context: *anyopaque, editor_epoch: u64, content: []const u8) anyerror!void,
    set_dirty_fn: *const fn (context: *anyopaque, report: DirtyReport) anyerror!void,
    resolve_external_change_fn: *const fn (context: *anyopaque, editor_epoch: u64, success: bool) anyerror!void,
    open_link_fn: *const fn (context: *anyopaque, editor_epoch: u64, href: []const u8, force_system: bool) anyerror!void,
    render_mermaid_fn: *const fn (context: *anyopaque, request: MermaidRenderRequest) anyerror!u64,
    revoke_mermaid_fn: *const fn (context: *anyopaque, renderer: mermaid_protocol.RendererCapability) anyerror!void,
    live_preview_ready_fn: *const fn (context: *anyopaque, editor_epoch: u64) anyerror!void,

    fn beginDocument(self: FileAccess, document_id: u64) anyerror!u64 {
        return self.begin_document_fn(self.context, document_id);
    }

    fn read(self: FileAccess, gpa: std.mem.Allocator, editor_epoch: u64) anyerror![]u8 {
        return self.read_fn(self.context, gpa, editor_epoch);
    }

    fn readAsset(self: FileAccess, gpa: std.mem.Allocator, normalized_path: []const u8) anyerror![]u8 {
        return self.read_asset_fn(self.context, gpa, normalized_path);
    }

    fn write(self: FileAccess, editor_epoch: u64, content: []const u8) anyerror!void {
        return self.write_fn(self.context, editor_epoch, content);
    }

    fn setDirty(self: FileAccess, report: DirtyReport) anyerror!void {
        return self.set_dirty_fn(self.context, report);
    }

    fn resolveExternalChange(self: FileAccess, editor_epoch: u64, success: bool) anyerror!void {
        return self.resolve_external_change_fn(self.context, editor_epoch, success);
    }

    fn openLink(self: FileAccess, editor_epoch: u64, href: []const u8, force_system: bool) anyerror!void {
        return self.open_link_fn(self.context, editor_epoch, href, force_system);
    }

    fn renderMermaid(self: FileAccess, request: MermaidRenderRequest) anyerror!u64 {
        return self.render_mermaid_fn(self.context, request);
    }

    fn revokeMermaid(self: FileAccess, renderer: mermaid_protocol.RendererCapability) anyerror!void {
        return self.revoke_mermaid_fn(self.context, renderer);
    }

    fn livePreviewReady(self: FileAccess, editor_epoch: u64) anyerror!void {
        return self.live_preview_ready_fn(self.context, editor_epoch);
    }
};

/// bridge `hello` 성공 result 한 줄: `{"jsonrpc":"2.0","id":<id>,"result":{"protocol":..,"server_version":..}}`.
/// minified 한 줄(1a·1c·control_browser와 동일 — ndjson frame 경계 안전). 종단 `\n`은 프레이밍(L4)이 붙인다. caller free.
pub fn serializeHelloResult(gpa: std.mem.Allocator, id: cp.Id, server_version: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    (writeHelloResult(&s, id, server_version)) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeHelloResult(s: *std.json.Stringify, id: cp.Id, server_version: []const u8) !void {
    try cp.beginResult(s, id); // result envelope 단일 출처(control_browser와 공유 — 리뷰12 [4]).
    try s.objectField("protocol");
    try s.write(cp.protocol_id); // 신뢰 브리지도 같은 프로토콜 식별자를 보고(소켓 hello와 정합).
    try s.objectField("server_version");
    try s.write(server_version);
    try cp.endResult(s);
}

/// 신뢰 브리지 요청 한 줄(ndjson frame, 개행 제외)을 처리해 **응답 한 줄 바이트**를 만든다. `server_version`은 L4가
/// 단일 출처(app_host_abi `control_hello_version`)를 넘긴다. OOM만 error로 전파(응답 만들 메모리도 없을 때). caller free.
///
/// **auth 없음**(모듈 헤더): 신뢰는 Swift가 핸들러 진입서 origin/frame으로 이미 확립. 순서:
///   1. parseMessage → request 아니면 `invalid_request`(id=null). parse 실패 → `parseFailureCode`(1a 관례).
///   2. method != `hello`면 `method_not_found`(5b는 hello만; 실 method는 5d+). id는 request의 것으로 응답.
///   3. `hello` → `{protocol, server_version}` 응답.
pub fn dispatchBridge(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    server_version: []const u8,
) std.mem.Allocator.Error![]u8 {
    return dispatchBridgeWithFileAccess(gpa, request_bytes, server_version, null);
}

/// `file_access != null`인 도크 markdown surface에서만 file method를 연다. 일반 신뢰 UI/기존 hello fixture는
/// provider를 넘기지 않아 file method가 `method_not_found`로 닫힌다.
pub fn dispatchBridgeWithFileAccess(
    gpa: std.mem.Allocator,
    request_bytes: []const u8,
    server_version: []const u8,
    file_access: ?FileAccess,
) std.mem.Allocator.Error![]u8 {
    var pm = cp.parseMessage(gpa, request_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorResponse(gpa, .null, cp.parseFailureCode(e)),
    };
    defer pm.deinit();

    // 브리지도 응답에 request id가 필요하므로 request만 디스패치한다(비-request → invalid_request, 소켓 1d/browser와 동일).
    const req = switch (pm.message) {
        .request => |r| r,
        else => return errorResponse(gpa, .null, .invalid_request),
    };

    if (std.mem.eql(u8, req.method, hello_method)) return serializeHelloResult(gpa, req.id, server_version);

    const access = file_access orelse return errorResponse(gpa, req.id, .method_not_found);
    if (std.mem.eql(u8, req.method, file_begin_document_method)) {
        const document_id = positiveIntegerParam(req.params, "document_id") catch return errorResponse(gpa, req.id, .invalid_params);
        const editor_epoch = access.beginDocument(document_id) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileDocumentResult(gpa, req.id, editor_epoch);
    }
    if (std.mem.eql(u8, req.method, file_read_method)) {
        const editor_epoch = positiveIntegerParam(req.params, "editor_epoch") catch return errorResponse(gpa, req.id, .invalid_params);
        const content = access.read(gpa, editor_epoch) catch return errorResponse(gpa, req.id, .internal_error);
        defer gpa.free(content);
        if (!std.unicode.utf8ValidateSlice(content)) return errorResponse(gpa, req.id, .internal_error);
        return serializeFileReadResult(gpa, req.id, content);
    }
    if (std.mem.eql(u8, req.method, file_read_asset_method)) {
        const raw_path = readAssetPath(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
        const normalized = file_policy.normalizeAssetPath(raw_path, &normalized_buf) catch
            return errorResponse(gpa, req.id, .invalid_params);
        const bytes = access.readAsset(gpa, normalized) catch return errorResponse(gpa, req.id, .internal_error);
        defer gpa.free(bytes);
        return serializeFileAssetResult(gpa, req.id, file_policy.mimeForPath(normalized), bytes);
    }
    if (std.mem.eql(u8, req.method, file_write_method)) {
        const write = writeParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        const content = write.content;
        if (content.len > file_policy.max_file_bytes or !std.unicode.utf8ValidateSlice(content))
            return errorResponse(gpa, req.id, .invalid_params);
        access.write(write.editor_epoch, content) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "written_bytes", content.len);
    }
    if (std.mem.eql(u8, req.method, file_set_dirty_method)) {
        const report = dirtyReportParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        access.setDirty(report) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "dirty", report.dirty);
    }
    if (std.mem.eql(u8, req.method, file_resolve_external_change_method)) {
        const resolution = resolveExternalChangeParam(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        access.resolveExternalChange(resolution.editor_epoch, resolution.success) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "success", resolution.success);
    }
    if (std.mem.eql(u8, req.method, file_open_link_method)) {
        const params = openLinkParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        const href = params.href;
        if (href.len == 0 or href.len > std.fs.max_path_bytes)
            return errorResponse(gpa, req.id, .invalid_params);
        access.openLink(params.editor_epoch, href, params.force_system) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "opened", true);
    }
    if (std.mem.eql(u8, req.method, file_render_mermaid_method)) {
        const params = mermaidRenderParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        const job_id = access.renderMermaid(params) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "job_id", job_id);
    }
    if (std.mem.eql(u8, req.method, file_revoke_mermaid_method)) {
        const renderer = mermaidRendererParams(req.params) catch return errorResponse(gpa, req.id, .invalid_params);
        access.revokeMermaid(renderer) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "revoked", true);
    }
    if (std.mem.eql(u8, req.method, file_live_preview_ready_method)) {
        const editor_epoch = positiveIntegerParam(req.params, "editor_epoch") catch return errorResponse(gpa, req.id, .invalid_params);
        access.livePreviewReady(editor_epoch) catch return errorResponse(gpa, req.id, .internal_error);
        return serializeFileMutationResult(gpa, req.id, "ready", true);
    }
    return errorResponse(gpa, req.id, .method_not_found);
}

fn mermaidRenderParams(params: ?std.json.Value) error{InvalidParams}!MermaidRenderRequest {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |value| value,
        else => return error.InvalidParams,
    };
    if (obj.count() != 9) return error.InvalidParams;
    const source = switch (obj.get("source") orelse return error.InvalidParams) {
        .string => |value| value,
        else => return error.InvalidParams,
    };
    if (source.len == 0 or source.len > mermaid_protocol.max_source_bytes or !std.unicode.utf8ValidateSlice(source))
        return error.InvalidParams;
    const hash_hex = switch (obj.get("source_hash") orelse return error.InvalidParams) {
        .string => |value| value,
        else => return error.InvalidParams,
    };
    if (hash_hex.len != 64) return error.InvalidParams;
    var source_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&source_hash, hash_hex) catch return error.InvalidParams;
    return .{
        .renderer = try rendererCapability(obj),
        .fence_id = try positiveInteger(obj.get("fence_id") orelse return error.InvalidParams),
        .source_hash = source_hash,
        .source = source,
    };
}

fn mermaidRendererParams(params: ?std.json.Value) error{InvalidParams}!mermaid_protocol.RendererCapability {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |value| value,
        else => return error.InvalidParams,
    };
    if (obj.count() != 6) return error.InvalidParams;
    return rendererCapability(obj);
}

fn rendererCapability(obj: std.json.ObjectMap) error{InvalidParams}!mermaid_protocol.RendererCapability {
    return .{
        .editor_epoch = try positiveInteger(obj.get("editor_epoch") orelse return error.InvalidParams),
        .document_revision = try nonNegativeInteger(obj.get("document_revision") orelse return error.InvalidParams),
        .projection_generation = try positiveInteger(obj.get("projection_generation") orelse return error.InvalidParams),
        .widget_id = try positiveInteger(obj.get("widget_id") orelse return error.InvalidParams),
        .widget_generation = try positiveInteger(obj.get("widget_generation") orelse return error.InvalidParams),
        .renderer_instance = try positiveInteger(obj.get("renderer_instance") orelse return error.InvalidParams),
    };
}

fn openLinkParams(params: ?std.json.Value) error{InvalidParams}!struct { editor_epoch: u64, href: []const u8, force_system: bool } {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 3) return error.InvalidParams;
    const href = switch (obj.get("href") orelse return error.InvalidParams) {
        .string => |value| value,
        else => return error.InvalidParams,
    };
    const force_system = switch (obj.get("forceSystem") orelse return error.InvalidParams) {
        .bool => |value| value,
        else => return error.InvalidParams,
    };
    return .{
        .editor_epoch = try positiveInteger(obj.get("editor_epoch") orelse return error.InvalidParams),
        .href = href,
        .force_system = force_system,
    };
}

fn dirtyReportParam(params: ?std.json.Value) error{InvalidParams}!DirtyReport {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 4) return error.InvalidParams;
    const dirty = switch (obj.get("dirty") orelse return error.InvalidParams) {
        .bool => |value| value,
        else => return error.InvalidParams,
    };
    return .{
        .dirty = dirty,
        .editor_epoch = try positiveInteger(obj.get("editor_epoch") orelse return error.InvalidParams),
        .revision = try nonNegativeInteger(obj.get("revision") orelse return error.InvalidParams),
        .request_id = try nonNegativeInteger(obj.get("request_id") orelse return error.InvalidParams),
    };
}

fn nonNegativeInteger(value: std.json.Value) error{InvalidParams}!u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= max_js_safe_integer) @intCast(integer) else error.InvalidParams,
        else => error.InvalidParams,
    };
}

fn positiveInteger(value: std.json.Value) error{InvalidParams}!u64 {
    const integer = try nonNegativeInteger(value);
    return if (integer > 0) integer else error.InvalidParams;
}

fn positiveIntegerParam(params: ?std.json.Value, key: []const u8) error{InvalidParams}!u64 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 1) return error.InvalidParams;
    return positiveInteger(obj.get(key) orelse return error.InvalidParams);
}

test "bridge integer domain matches JavaScript exact integer range" {
    try testing.expectEqual(max_js_safe_integer, try nonNegativeInteger(.{ .integer = max_js_safe_integer }));
    try testing.expectEqual(max_js_safe_integer, try positiveInteger(.{ .integer = max_js_safe_integer }));
    try testing.expectError(error.InvalidParams, nonNegativeInteger(.{ .integer = max_js_safe_integer + 1 }));
    try testing.expectError(error.InvalidParams, positiveInteger(.{ .integer = 0 }));
    try testing.expectError(error.InvalidParams, nonNegativeInteger(.{ .integer = -1 }));
}

test "dispatchBridge: JavaScript safe integer boundary reaches provider exactly once" {
    var fake: FakeFileAccess = .{};
    const valid = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"editor_epoch\":9007199254740991,\"revision\":9007199254740991,\"request_id\":9007199254740991}}";
    const valid_resp = try dispatchBridgeWithFileAccess(testing.allocator, valid, "0.1.0", fake.access());
    defer testing.allocator.free(valid_resp);
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls);
    try testing.expectEqual(max_js_safe_integer, fake.last_dirty_report.?.editor_epoch);
    try testing.expectEqual(max_js_safe_integer, fake.last_dirty_report.?.revision);
    try testing.expectEqual(max_js_safe_integer, fake.last_dirty_report.?.request_id);

    const invalid = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"editor_epoch\":9007199254740992,\"revision\":0,\"request_id\":0}}";
    const invalid_resp = try dispatchBridgeWithFileAccess(testing.allocator, invalid, "0.1.0", fake.access());
    defer testing.allocator.free(invalid_resp);
    var parsed = try parseValue(testing.allocator, invalid_resp);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), parsed.value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls);
}

fn writeParam(params: ?std.json.Value) error{InvalidParams}!struct { editor_epoch: u64, content: []const u8 } {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 2) return error.InvalidParams;
    const content = switch (obj.get("content") orelse return error.InvalidParams) {
        .string => |value| value,
        else => return error.InvalidParams,
    };
    return .{
        .editor_epoch = try positiveInteger(obj.get("editor_epoch") orelse return error.InvalidParams),
        .content = content,
    };
}

fn resolveExternalChangeParam(params: ?std.json.Value) error{InvalidParams}!struct { editor_epoch: u64, success: bool } {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 2) return error.InvalidParams;
    const success = switch (obj.get("success") orelse return error.InvalidParams) {
        .bool => |value| value,
        else => return error.InvalidParams,
    };
    return .{
        .editor_epoch = try positiveInteger(obj.get("editor_epoch") orelse return error.InvalidParams),
        .success = success,
    };
}

fn readAssetPath(params: ?std.json.Value) error{InvalidParams}![]const u8 {
    const obj = switch (params orelse return error.InvalidParams) {
        .object => |obj| obj,
        else => return error.InvalidParams,
    };
    if (obj.count() != 1) return error.InvalidParams;
    return switch (obj.get("path") orelse return error.InvalidParams) {
        .string => |path| if (path.len > 0) path else error.InvalidParams,
        else => error.InvalidParams,
    };
}

fn serializeFileReadResult(gpa: std.mem.Allocator, id: cp.Id, content: []const u8) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField("content") catch return error.OutOfMemory;
    s.write(content) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeFileDocumentResult(gpa: std.mem.Allocator, id: cp.Id, editor_epoch: u64) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField("editor_epoch") catch return error.OutOfMemory;
    s.write(editor_epoch) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeFileAssetResult(
    gpa: std.mem.Allocator,
    id: cp.Id,
    mime: []const u8,
    bytes: []const u8,
) std.mem.Allocator.Error![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField("mime") catch return error.OutOfMemory;
    s.write(mime) catch return error.OutOfMemory;
    s.objectField("data_base64") catch return error.OutOfMemory;
    s.write(encoded) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn serializeFileMutationResult(gpa: std.mem.Allocator, id: cp.Id, key: []const u8, value: anytype) std.mem.Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    cp.beginResult(&s, id) catch return error.OutOfMemory;
    s.objectField(key) catch return error.OutOfMemory;
    s.write(value) catch return error.OutOfMemory;
    cp.endResult(&s) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// 코드의 default message로 에러 응답 한 줄을 만든다(1a `serializeError` 재사용 — control_browser/1d와 동일 패턴).
fn errorResponse(gpa: std.mem.Allocator, id: cp.Id, code: cp.ErrorCode) std.mem.Allocator.Error![]u8 {
    return cp.serializeError(gpa, id, code, code.defaultMessage(), null);
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·WKWebView/소켓 0) ═══════════════════════════════════════════════
const testing = std.testing;

fn parseValue(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
}

test "dispatchBridge: hello round-trip → protocol + server_version" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"hello\"}";
    const resp = try dispatchBridge(testing.allocator, req, "9.9.9");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
    const result = obj.get("result").?.object;
    try testing.expectEqualStrings("maru.control.v1", result.get("protocol").?.string);
    try testing.expectEqualStrings("9.9.9", result.get("server_version").?.string);
    try testing.expect(obj.get("error") == null);
}

const FakeFileAccess = struct {
    editor_epoch: u64 = 0,
    document_id: u64 = 0,
    read_epoch: u64 = 0,
    read_calls: usize = 0,
    asset_calls: usize = 0,
    last_asset_path: [128]u8 = undefined,
    last_asset_path_len: usize = 0,
    fail: bool = false,
    last_write: [256]u8 = undefined,
    last_write_len: usize = 0,
    write_calls: usize = 0,
    dirty: bool = false,
    dirty_calls: usize = 0,
    last_dirty_report: ?DirtyReport = null,
    external_change_resolved: ?bool = null,
    resolve_calls: usize = 0,
    last_open_link: [std.fs.max_path_bytes]u8 = undefined,
    last_open_link_len: usize = 0,
    last_open_link_editor_epoch: u64 = 0,
    last_open_link_force_system: bool = false,
    mermaid_calls: usize = 0,
    mermaid_revoke_calls: usize = 0,
    live_preview_ready_calls: usize = 0,
    last_mermaid: ?MermaidRenderRequest = null,
    last_mermaid_revoke: ?mermaid_protocol.RendererCapability = null,
    last_mermaid_source_len: usize = 0,

    fn beginDocument(context: *anyopaque, document_id: u64) anyerror!u64 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail) return error.BeginFailed;
        self.document_id = document_id;
        self.editor_epoch += 1;
        return self.editor_epoch;
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, editor_epoch: u64) anyerror![]u8 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        self.read_epoch = editor_epoch;
        if (self.fail) return error.ReadFailed;
        return gpa.dupe(u8, "# fixture\n\n안전한 본문");
    }

    fn readAsset(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.asset_calls += 1;
        if (self.fail) return error.ReadFailed;
        @memcpy(self.last_asset_path[0..path.len], path);
        self.last_asset_path_len = path.len;
        return gpa.dupe(u8, &.{ 0x89, 0x50, 0x4e, 0x47 });
    }

    fn write(context: *anyopaque, _: u64, content: []const u8) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.write_calls += 1;
        if (self.fail or content.len > self.last_write.len) return error.WriteFailed;
        @memcpy(self.last_write[0..content.len], content);
        self.last_write_len = content.len;
    }

    fn setDirty(context: *anyopaque, report: DirtyReport) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.dirty_calls += 1;
        if (self.fail) return error.DirtyFailed;
        self.dirty = report.dirty;
        self.last_dirty_report = report;
    }

    fn resolveExternalChange(context: *anyopaque, _: u64, success: bool) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        self.resolve_calls += 1;
        if (self.fail) return error.ResolveFailed;
        self.external_change_resolved = success;
    }

    fn openLink(context: *anyopaque, editor_epoch: u64, href: []const u8, force_system: bool) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail or href.len > self.last_open_link.len) return error.OpenFailed;
        @memcpy(self.last_open_link[0..href.len], href);
        self.last_open_link_len = href.len;
        self.last_open_link_editor_epoch = editor_epoch;
        self.last_open_link_force_system = force_system;
    }

    fn renderMermaid(context: *anyopaque, request: MermaidRenderRequest) anyerror!u64 {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail) return error.RenderFailed;
        self.mermaid_calls += 1;
        self.last_mermaid = request;
        self.last_mermaid_source_len = request.source.len;
        return 77;
    }

    fn revokeMermaid(context: *anyopaque, renderer: mermaid_protocol.RendererCapability) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail) return error.RevokeFailed;
        self.mermaid_revoke_calls += 1;
        self.last_mermaid_revoke = renderer;
    }

    fn livePreviewReady(context: *anyopaque, _: u64) anyerror!void {
        const self: *FakeFileAccess = @ptrCast(@alignCast(context));
        if (self.fail) return error.ReadyFailed;
        self.live_preview_ready_calls += 1;
    }

    fn access(self: *FakeFileAccess) FileAccess {
        return .{
            .context = self,
            .begin_document_fn = beginDocument,
            .read_fn = read,
            .read_asset_fn = readAsset,
            .write_fn = write,
            .set_dirty_fn = setDirty,
            .resolve_external_change_fn = resolveExternalChange,
            .open_link_fn = openLink,
            .render_mermaid_fn = renderMermaid,
            .revoke_mermaid_fn = revokeMermaid,
            .live_preview_ready_fn = livePreviewReady,
        };
    }
};

test "dispatchBridge: file.read is epoch-scoped and returns UTF-8 content" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"maru.file.read\",\"params\":{\"editor_epoch\":4}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expectEqualStrings("# fixture\n\n안전한 본문", p.value.object.get("result").?.object.get("content").?.string);
    try testing.expectEqual(@as(usize, 1), fake.read_calls);
    try testing.expectEqual(@as(u64, 4), fake.read_epoch);

    const with_params = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"maru.file.read\",\"params\":{}}";
    const bad = try dispatchBridgeWithFileAccess(testing.allocator, with_params, "0.1.0", fake.access());
    defer testing.allocator.free(bad);
    var bp = try parseValue(testing.allocator, bad);
    defer bp.deinit();
    try testing.expectEqual(@as(i64, -32602), bp.value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 1), fake.read_calls);

    const absent = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(absent);
    var ap = try parseValue(testing.allocator, absent);
    defer ap.deinit();
    try testing.expectEqual(@as(i64, -32601), ap.value.object.get("error").?.object.get("code").?.integer);
}

test "dispatchBridge: file.beginDocument binds a positive document id" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"maru.file.beginDocument\",\"params\":{\"document_id\":9}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var parsed = try parseValue(testing.allocator, resp);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("result").?.object.get("editor_epoch").?.integer);
    try testing.expectEqual(@as(u64, 1), fake.editor_epoch);
    try testing.expectEqual(@as(u64, 9), fake.document_id);
}

test "dispatchBridge: file.readAsset normalizes path and base64 encodes bytes" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"./images//diagram.PNG\"}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const result = p.value.object.get("result").?.object;
    try testing.expectEqualStrings("image/png", result.get("mime").?.string);
    try testing.expectEqualStrings("iVBORw==", result.get("data_base64").?.string);
    try testing.expectEqualStrings("images/diagram.PNG", fake.last_asset_path[0..fake.last_asset_path_len]);
}

test "dispatchBridge: file.readAsset rejects malformed and traversal params before provider" {
    var fake: FakeFileAccess = .{};
    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"../secret\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"maru.file.readAsset\",\"params\":{\"path\":\"a.png\",\"extra\":true}}",
    };
    for (cases) |req| {
        const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
        defer testing.allocator.free(resp);
        var p = try parseValue(testing.allocator, resp);
        defer p.deinit();
        try testing.expectEqual(@as(i64, -32602), p.value.object.get("error").?.object.get("code").?.integer);
    }
    try testing.expectEqual(@as(usize, 0), fake.asset_calls);
}

test "dispatchBridge: file.write and revision-scoped dirty are pinned provider mutations with exact params" {
    var fake: FakeFileAccess = .{};
    const dirty_req = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"editor_epoch\":3,\"revision\":7,\"request_id\":9}}";
    const dirty_resp = try dispatchBridgeWithFileAccess(testing.allocator, dirty_req, "0.1.0", fake.access());
    defer testing.allocator.free(dirty_resp);
    try testing.expect(fake.dirty);
    try testing.expectEqual(DirtyReport{ .dirty = true, .editor_epoch = 3, .revision = 7, .request_id = 9 }, fake.last_dirty_report.?);

    const write_req = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"maru.file.write\",\"params\":{\"editor_epoch\":3,\"content\":\"# 저장\\n\"}}";
    const write_resp = try dispatchBridgeWithFileAccess(testing.allocator, write_req, "0.1.0", fake.access());
    defer testing.allocator.free(write_resp);
    try testing.expectEqualStrings("# 저장\n", fake.last_write[0..fake.last_write_len]);
    try testing.expect(fake.dirty); // write와 dirty ack는 별도 직렬 mutation이다.

    const resolve_req = "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"maru.file.resolveExternalChange\",\"params\":{\"editor_epoch\":3,\"success\":false}}";
    const resolve_resp = try dispatchBridgeWithFileAccess(testing.allocator, resolve_req, "0.1.0", fake.access());
    defer testing.allocator.free(resolve_resp);
    try testing.expectEqual(@as(?bool, false), fake.external_change_resolved);
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls);
    try testing.expectEqual(@as(usize, 1), fake.write_calls);
    try testing.expectEqual(@as(usize, 1), fake.resolve_calls);

    const bad = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"maru.file.write\",\"params\":{\"editor_epoch\":3,\"content\":\"x\",\"path\":\"/tmp/escape.md\"}}";
    const bad_resp = try dispatchBridgeWithFileAccess(testing.allocator, bad, "0.1.0", fake.access());
    defer testing.allocator.free(bad_resp);
    var parsed = try parseValue(testing.allocator, bad_resp);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), parsed.value.object.get("error").?.object.get("code").?.integer);

    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true}}",
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"revision\":7}}",
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"revision\":-1,\"request_id\":0}}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"revision\":7,\"request_id\":0,\"extra\":false}}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"revision\":7.5,\"request_id\":0}}",
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"maru.file.setDirty\",\"params\":{\"dirty\":true,\"editor_epoch\":0,\"revision\":7,\"request_id\":0}}",
    }) |invalid| {
        const invalid_resp = try dispatchBridgeWithFileAccess(testing.allocator, invalid, "0.1.0", fake.access());
        defer testing.allocator.free(invalid_resp);
        var invalid_parsed = try parseValue(testing.allocator, invalid_resp);
        defer invalid_parsed.deinit();
        try testing.expectEqual(@as(i64, -32602), invalid_parsed.value.object.get("error").?.object.get("code").?.integer);
    }

    const bad_resolve = "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"maru.file.resolveExternalChange\",\"params\":{\"editor_epoch\":3,\"success\":true,\"extra\":false}}";
    const bad_resolve_resp = try dispatchBridgeWithFileAccess(testing.allocator, bad_resolve, "0.1.0", fake.access());
    defer testing.allocator.free(bad_resolve_resp);
    var bad_resolve_parsed = try parseValue(testing.allocator, bad_resolve_resp);
    defer bad_resolve_parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), bad_resolve_parsed.value.object.get("error").?.object.get("code").?.integer);

    const zero_write = "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"maru.file.write\",\"params\":{\"editor_epoch\":0,\"content\":\"x\"}}";
    const zero_write_resp = try dispatchBridgeWithFileAccess(testing.allocator, zero_write, "0.1.0", fake.access());
    defer testing.allocator.free(zero_write_resp);
    var zero_write_parsed = try parseValue(testing.allocator, zero_write_resp);
    defer zero_write_parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), zero_write_parsed.value.object.get("error").?.object.get("code").?.integer);

    const zero_resolve = "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"maru.file.resolveExternalChange\",\"params\":{\"editor_epoch\":0,\"success\":true}}";
    const zero_resolve_resp = try dispatchBridgeWithFileAccess(testing.allocator, zero_resolve, "0.1.0", fake.access());
    defer testing.allocator.free(zero_resolve_resp);
    var zero_resolve_parsed = try parseValue(testing.allocator, zero_resolve_resp);
    defer zero_resolve_parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), zero_resolve_parsed.value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 1), fake.dirty_calls);
    try testing.expectEqual(@as(usize, 1), fake.write_calls);
    try testing.expectEqual(@as(usize, 1), fake.resolve_calls);
}

test "dispatchBridge: live preview ready is exact and epoch scoped" {
    var fake: FakeFileAccess = .{};
    const response = try dispatchBridgeWithFileAccess(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"maru.file.livePreviewReady\",\"params\":{\"editor_epoch\":7}}",
        "0.1.0",
        fake.access(),
    );
    defer testing.allocator.free(response);
    try testing.expectEqual(@as(usize, 1), fake.live_preview_ready_calls);

    const invalid = try dispatchBridgeWithFileAccess(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"maru.file.livePreviewReady\",\"params\":{\"editor_epoch\":0}}",
        "0.1.0",
        fake.access(),
    );
    defer testing.allocator.free(invalid);
    try testing.expectEqual(@as(usize, 1), fake.live_preview_ready_calls);
}

test "dispatchBridge: file.openLink is an exact-parameter pinned provider mutation" {
    var fake: FakeFileAccess = .{};
    const req = "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"maru.file.openLink\",\"params\":{\"editor_epoch\":7,\"href\":\"https://example.com/guide\",\"forceSystem\":true}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var parsed = try parseValue(testing.allocator, resp);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expectEqualStrings("https://example.com/guide", fake.last_open_link[0..fake.last_open_link_len]);
    try testing.expectEqual(@as(u64, 7), fake.last_open_link_editor_epoch);
    try testing.expect(fake.last_open_link_force_system);

    const bad = "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"maru.file.openLink\",\"params\":{\"editor_epoch\":7,\"href\":\"next.md\",\"forceSystem\":false,\"path\":\"/tmp/escape.md\"}}";
    const bad_resp = try dispatchBridgeWithFileAccess(testing.allocator, bad, "0.1.0", fake.access());
    defer testing.allocator.free(bad_resp);
    var bad_parsed = try parseValue(testing.allocator, bad_resp);
    defer bad_parsed.deinit();
    try testing.expectEqual(@as(i64, -32602), bad_parsed.value.object.get("error").?.object.get("code").?.integer);

    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"maru.file.openLink\",\"params\":{\"href\":\"https://example.com\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"maru.file.openLink\",\"params\":{\"href\":\"https://example.com\",\"forceSystem\":\"true\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"maru.file.openLink\",\"params\":{\"editor_epoch\":0,\"href\":\"https://example.com\",\"forceSystem\":false}}",
    }) |invalid| {
        const invalid_resp = try dispatchBridgeWithFileAccess(testing.allocator, invalid, "0.1.0", fake.access());
        defer testing.allocator.free(invalid_resp);
        var invalid_parsed = try parseValue(testing.allocator, invalid_resp);
        defer invalid_parsed.deinit();
        try testing.expectEqual(@as(i64, -32602), invalid_parsed.value.object.get("error").?.object.get("code").?.integer);
    }
}

test "dispatchBridge Mermaid admission keeps exact renderer identity and SHA-256" {
    var fake: FakeFileAccess = .{};
    const req =
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"maru.file.renderMermaid\",\"params\":{" ++
        "\"editor_epoch\":7,\"document_revision\":0,\"projection_generation\":2," ++
        "\"widget_id\":3,\"widget_generation\":4,\"renderer_instance\":5,\"fence_id\":6," ++
        "\"source_hash\":\"2151a7a6ec2eaff56c93602c3b07382d7bd484e8e572852da1ffe6b874656bd8\"," ++
        "\"source\":\"```mermaid\\ngraph TD\\n```\"}}";
    const response = try dispatchBridgeWithFileAccess(testing.allocator, req, "1", fake.access());
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"job_id\":77") != null);
    try testing.expectEqual(@as(usize, 1), fake.mermaid_calls);
    const captured = fake.last_mermaid.?;
    try testing.expectEqual(@as(u64, 7), captured.renderer.editor_epoch);
    try testing.expectEqual(@as(u64, 0), captured.renderer.document_revision);
    try testing.expectEqual(@as(u64, 6), captured.fence_id);
    try testing.expectEqual(@as(usize, "```mermaid\ngraph TD\n```".len), fake.last_mermaid_source_len);

    const revoke =
        "{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"maru.file.revokeMermaid\",\"params\":{" ++
        "\"editor_epoch\":7,\"document_revision\":0,\"projection_generation\":2," ++
        "\"widget_id\":3,\"widget_generation\":4,\"renderer_instance\":5}}";
    const revoke_response = try dispatchBridgeWithFileAccess(testing.allocator, revoke, "1", fake.access());
    defer testing.allocator.free(revoke_response);
    try testing.expect(std.mem.indexOf(u8, revoke_response, "\"revoked\":true") != null);
    try testing.expectEqual(@as(usize, 1), fake.mermaid_revoke_calls);
    try testing.expect(std.meta.eql(captured.renderer, fake.last_mermaid_revoke.?));

    const bad =
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"maru.file.renderMermaid\",\"params\":{" ++
        "\"editor_epoch\":0,\"document_revision\":0,\"projection_generation\":2," ++
        "\"widget_id\":3,\"widget_generation\":4,\"renderer_instance\":5,\"fence_id\":6," ++
        "\"source_hash\":\"2151a7a6ec2eaff56c93602c3b07382d7bd484e8e572852da1ffe6b874656bd8\"," ++
        "\"source\":\"```mermaid\\ngraph TD\\n```\"}}";
    const rejected = try dispatchBridgeWithFileAccess(testing.allocator, bad, "1", fake.access());
    defer testing.allocator.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "-32602") != null);
    try testing.expectEqual(@as(usize, 1), fake.mermaid_calls);

    const bad_revoke =
        "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"maru.file.revokeMermaid\",\"params\":{" ++
        "\"editor_epoch\":7,\"document_revision\":0,\"projection_generation\":2," ++
        "\"widget_id\":3,\"widget_generation\":4,\"renderer_instance\":0}}";
    const bad_revoke_response = try dispatchBridgeWithFileAccess(testing.allocator, bad_revoke, "1", fake.access());
    defer testing.allocator.free(bad_revoke_response);
    try testing.expect(std.mem.indexOf(u8, bad_revoke_response, "-32602") != null);
    try testing.expectEqual(@as(usize, 1), fake.mermaid_revoke_calls);
}

test "dispatchBridge: provider failures are uniform internal errors" {
    var fake: FakeFileAccess = .{ .fail = true };
    const req = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"maru.file.read\",\"params\":{\"editor_epoch\":1}}";
    const resp = try dispatchBridgeWithFileAccess(testing.allocator, req, "0.1.0", fake.access());
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expectEqual(@as(i64, -32603), p.value.object.get("error").?.object.get("code").?.integer);
}

test "dispatchBridge: 미지원 method → method_not_found(요청 id 보존)" {
    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"navigate\"}";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqual(@as(i64, 3), obj.get("id").?.integer);
    try testing.expectEqual(@as(i64, -32601), obj.get("error").?.object.get("code").?.integer); // method_not_found
    try testing.expect(obj.get("result") == null);
}

test "dispatchBridge: notification(id 없음) → invalid_request(id=null)" {
    const req = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    const obj = p.value.object;
    try testing.expect(obj.get("id").? == .null);
    try testing.expectEqual(@as(i64, -32600), obj.get("error").?.object.get("code").?.integer); // invalid_request
}

test "dispatchBridge: 깨진 JSON → parse 에러 응답(OOM 아님)" {
    const req = "{not json";
    const resp = try dispatchBridge(testing.allocator, req, "0.1.0");
    defer testing.allocator.free(resp);
    var p = try parseValue(testing.allocator, resp);
    defer p.deinit();
    try testing.expect(p.value.object.get("error") != null);
}

test "serializeHelloResult: minified 한 줄(개행 없음 — ndjson frame 안전)" {
    const resp = try serializeHelloResult(testing.allocator, .{ .number = 1 }, "0.1.0");
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOfScalar(u8, resp, '\n') == null);
}
