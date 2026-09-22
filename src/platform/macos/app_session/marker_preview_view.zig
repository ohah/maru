//! 터미널의 `[Image #N]` 마커를 눌렀을 때 뜨는 **프리뷰** — 열기·닫기·배치·그리기, 그리고
//! 그 안의 마커 번호·히트 수집.
//!
//! **`marker_preview.zig`(세션 층)와 다르다.** 그쪽은 프리뷰의 «상태 기계»(무엇이 열려 있나,
//! 무엇을 기다리나)를 갖고, 여기는 그 상태를 **macOS 세션에 붙이는 자리**다 — Term 좌표를 셀로
//! 풀고, 도크 점프를 라우팅하고, draw list 에 그린다.
//!
//! `app_session.zig` 에서 목적별로 떼어낸 그룹이다(docs/plans/app-session-decomposition.md §4.1).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const renderer = maru.renderer;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const marker_preview_decode_key = app_session_mod.marker_preview_decode_key;
const agent_image_decode_backend = app_session_mod.agent_image_decode_backend;
const marker_preview_diag = app_session_mod.marker_preview_diag;
const pane_ops = app_session_mod.pane_ops;
const MarkerPreviewOwner = AppSession.MarkerPreviewOwner;
const diag_gate = app_session_mod.diag_gate;
const idle_marker_scan_ticks = app_session_mod.idle_marker_scan_ticks;
const marker_preview_ops = app_session_mod.marker_preview_ops;
const packOpaqueRgb = app_session_mod.packOpaqueRgb;
const Term = app_session_mod.Term;
const agent_ops = @import("agent.zig");
const term_ops = @import("term.zig");
const dock_ops = @import("dock.zig");
const tab_ops = @import("tab.zig");
const agent_activity_ops = @import("agent_activity.zig");

/// 붙여넣은 PNG를 마커 프리뷰 스테이징에 건다(§4.2). **paste가 나가기 전에** 불려야 한다 —
/// 관찰 기준선이 마커가 뜬 뒤에 찍히면 그 마커가 「새로 나타난 것」이 아니게 되어 영영 안 묶인다.
pub fn stageMarkerPreviewImage(self: *AppSession, term: *Term, temp_path: []const u8, bytes: []const u8) void {
    const surface_id = term.surface.id;
    var visible: std.ArrayList(u32) = .empty;
    defer visible.deinit(self.allocator);
    collectMarkerNumbers(self, term, .viewport, &visible) catch return;
    const png = self.allocator.dupe(u8, bytes) catch return;
    const path = self.allocator.dupe(u8, temp_path) catch {
        self.allocator.free(png);
        return;
    };
    marker_preview_ops.onImagePasted(&self.marker_preview, self.allocator, surface_id, visible.items, png, path) catch {
        self.allocator.free(png);
        self.allocator.free(path);
    };
}

/// Cmd+클릭이 마커 위였나 — 맞으면 프리뷰를 토글하고 참을 돌린다(클릭 소비).
///
/// **기록에 없는 N이면 아무 일도 안 한다**(§3.1) — 화면에 글자로 쓰인 `[Image #1]`은 우리 것이
/// 아니므로 클릭을 먹지 않고 링크 경로로 흘려보낸다.
pub fn toggleMarkerPreviewAt(self: *AppSession, term: *Term, surface_id: u64, cell: maru.session.layout_math.CellHit) bool {
    if (term.kind != .terminal) return false;
    // **뷰포트 전부를 후보로 본다.** 전송된 마커는 커서 위(대화 영역)로 올라가므로 커서 블록만
    // 보면 영영 못 찾는다(사용자 제보 2026-09-14 — 「채팅창에 올라간 건 안 열린다」).
    var hits: std.ArrayList(maru.session.agent_image_markers.Hit) = .empty;
    defer hits.deinit(self.allocator);
    collectMarkerHits(self, term, .viewport, &hits) catch return false;
    // `CellHit.row`는 **이미 뷰포트 행**이고 마커 스캔도 뷰포트 행으로 답한다 — 변환이 없다.
    const m = maru.session.agent_image_markers.hitAt(hits.items, cell.row, cell.col) orelse return false;
    // ⚠️ **소스는 「어디에 있나」가 아니라 「누가 답할 수 있나」로 고른다.**
    //
    // 한 판에서는 범위(커서 블록 안/밖)로 갈랐는데 그것이 **회귀를 냈다**(사용자 제보): 커서
    // 블록 스캔은 스크롤된 뷰포트에서 **빈 목록**이라(§3.3) 전송 전 마커까지 인덱스로 보내졌고,
    // 인덱스는 **갤러리 도크를 연 적이 있어야** 채워지므로(`refreshForFocus`) 아무것도 안 열렸다.
    // 범위는 같은 번호가 두 곳에 있을 때의 **동점 규칙**이지 게이트가 아니다.
    //
    // 그래서 **스테이징을 먼저 묻는다.** 거기 있으면 이번 실행에 우리가 직접 실어 둔 것이라
    // 가장 확실하고, 전송된 뒤에도 `sent` 로 남아 있다(§4.2 A11). 없을 때만 인덱스로 간다.
    const staged_known = if (self.marker_preview.stagingFor(surface_id)) |st| st.lookup(m.n) != null else false;
    if (diag_gate.maruDebugEnabled()) marker_preview_diag.info(
        "click n={d} row={d} col={d} staged={} surface={d}",
        .{ m.n, m.row, m.start_col, staged_known, surface_id },
    );
    if (!staged_known) return toggleSentMarkerPreview(self, surface_id, m, hits.items, self.viewportScrolled(term));
    const next = marker_preview_ops.toggle(&self.marker_preview, self.marker_preview_open, surface_id, m);
    const changed = (next == null) != (self.marker_preview_open == null) or
        (next != null and self.marker_preview_open != null and next.?.n != self.marker_preview_open.?.n);
    if (!changed) return next != null or self.marker_preview_open != null;
    // **닫는 길에서 텍스처 회수 표시를 세운다**(§5). 안 세우면 다시 열 때 그 한 장이 빈다.
    if (self.marker_preview_open) |*o| o.deinit(self.allocator);
    self.marker_preview_open = next;
    self.metal_dirty = true;
    return next != null;
}

/// 열린 프리뷰의 앵커를 재검증하고 디코드를 편다 — tick마다.
pub fn pumpMarkerPreviewOpen(self: *AppSession) void {
    const open = &(self.marker_preview_open orelse return);
    if (!self.surface_initialized or self.tabs.items.len == 0) {
        closeMarkerPreview(self);
        return;
    }
    // **그 프리뷰가 속한 pane 을 찾는다** — 활성 pane 이 아닐 수 있다(`markerPreviewTarget`).
    // 이름이 `target` 이 아닌 것은 이 함수 아래에 디코드 **목표 변**(`target`)이 이미 있어서다.
    const owner = markerPreviewTarget(self) orelse return; // 다른 탭이다 — 그리지도 닫지도 않는다
    const term = owner.term;
    if (term.kind != .terminal) return;
    // **앵커 재검증**(§3) — TUI가 그 자리를 덮어도 통보가 없으므로 매 프레임 확인한다. 어긋나면
    // **따라가고**(같은 N 이 화면에 있다), 그 N 이 아예 없을 때만 조용히 닫는다(2026-09-15 개정 —
    // 좌표 고정은 리페인트마다 프리뷰를 죽여 「눌러도 안 열린다」가 됐다. `reanchor` 주석이 계측과
    // 근거를 들고 있다).
    //
    // ⚠️ **`viewport` 로 본다.** 한 판에서는 `cursor_block` 이었는데, 전송된 마커는 커서 블록 **밖**이라
    // 매번 「앵커가 사라졌다」로 판정돼 **열리자마자 다음 tick 에 닫혔다**(사용자 제보 — 「전송 후는
    // 여전히 안 된다」). 여는 쪽은 뷰포트 전체를 보는데 재검증만 좁게 보면 둘이 어긋난다.
    // **규율**: 여는 스캔과 유지하는 스캔은 **같은 범위**여야 한다.
    var hits: std.ArrayList(maru.session.agent_image_markers.Hit) = .empty;
    defer hits.deinit(self.allocator);
    collectMarkerHits(self, term, .viewport, &hits) catch return;
    switch (marker_preview_ops.reanchor(open.*, hits.items)) {
        .unchanged => {},
        .moved => |h| {
            // 좌표만 따라간다 — 이미지·디코드 상태는 **그대로**다(같은 마커, 같은 그림).
            open.row = h.row;
            open.start_col = h.start_col;
            open.end_col = h.end_col;
            self.metal_dirty = true;
            if (diag_gate.maruDebugEnabled()) marker_preview_diag.info(
                "reanchor n={d} -> row={d} col={d}",
                .{ open.n, h.row, h.start_col },
            );
        },
        .lost => {
            // 그 번호가 화면에서 아예 사라졌다 — 따라갈 자리가 없어 닫는다(§3).
            if (diag_gate.maruDebugEnabled()) marker_preview_diag.info(
                "closed n={d} reason=marker-gone",
                .{open.n},
            );
            closeMarkerPreview(self);
            return;
        },
    }
    if (open.pixels.len > 0 or open.failed) return;
    if (open.decode_generation != 0) return;
    // 디코드를 **한 번만** 건다. 결과는 `agent_activity_decode_backend` 의 take 루프가 가져간다.
    const backend = &(self.agent_activity_decode_backend orelse return);
    // 목표 변은 workspace 절반이면 충분하다(§2.3) — 원본을 통째로 올릴 이유가 없다.
    const target: u32 = @max(256, self.backing_width_px / 2);
    if (open.sent_hit_index) |hit_index| {
        // **전송된 것** — 트랜스크립트 안의 base64 구간을 푼다(갤러리와 같은 잡).
        const indexed = self.agent_activity.hits.items;
        if (hit_index >= indexed.len) {
            open.failed = true; // 인덱스가 다시 만들어져 자리가 밀렸다
            return;
        }
        const h = indexed[hit_index];
        // **그 자리가 여전히 같은 이미지인가.** 인덱스가 다시 만들어지면 배열 인덱스는 남의 것을
        // 가리킬 수 있다 — 내용 키가 어긋나면 **틀린 그림 대신 못 연다**로 접는다.
        if (h.file_index != open.sent_file_index or h.data_offset != open.sent_data_offset) {
            open.failed = true;
            return;
        }
        const path = self.agent_activity.chain.get(h.file_index) orelse {
            open.failed = true;
            return;
        };
        // **원격이면 그 구간을 저쪽에서 당겨온다**(P3 · RAV6). 저쪽 오프셋을 이쪽 `openFile` 에
        // 넘기면 같은 모양의 로컬 경로가 열려 **남의 그림**이 뜬다 — 갤러리가 §13.6 N1 에서
        // 잡은 그 사고이고, 여기서도 같은 규율을 진다.
        //
        // 목적지는 **활성 Term 의 관측**에서 온다(업로드·SCM·갤러리 스캔과 같은 출처 — 두 벌을
        // 만들지 않는다). 원격인데 못 얻으면 **안 건다**: 로컬로 떨어뜨리면 위 사고가 난다.
        var remote_ctx: ?@TypeOf(self.remoteUploadContextFor(term).?) = null;
        defer if (remote_ctx) |ctx| ctx.deinit(self.allocator);
        var remote: ?agent_image_decode_backend.Backend.RemoteTarget = null;
        if (self.agent_activity.source_remote) {
            remote_ctx = self.remoteUploadContextFor(term);
            const ctx = remote_ctx orelse {
                open.failed = true;
                return;
            };
            remote = .{ .ctl = ctx.ctl, .dest = ctx.dest };
        }
        if (backend.submit(path, h.data_offset, h.data_len, target, marker_preview_decode_key, remote)) |gen| {
            open.decode_generation = gen;
            if (diag_gate.maruDebugEnabled()) marker_preview_diag.info(
                "decode sent n={d} hit={d} file={d} off={d} gen={d}",
                .{ open.n, hit_index, h.file_index, h.data_offset, gen },
            );
        }
        return;
    }
    // **전송 전** — maru 가 저장한 그 파일을 그대로 푼다(base64 단계가 없다).
    const st = self.marker_preview.stagingFor(open.surface_id) orelse return;
    const e = st.lookup(open.n) orelse return;
    if (e.path.len == 0) {
        open.failed = true;
        return;
    }
    const size = std.Io.Dir.cwd().statFile(self.io, e.path, .{}) catch {
        open.failed = true;
        return;
    };
    const len: u32 = std.math.cast(u32, size.size) orelse {
        open.failed = true;
        return;
    };
    if (backend.submitRawFile(e.path, len, target, marker_preview_decode_key)) |gen| {
        open.decode_generation = gen;
        if (diag_gate.maruDebugEnabled()) marker_preview_diag.info(
            "decode staged n={d} path={s} gen={d}",
            .{ open.n, e.path, gen },
        );
    }
}

/// 열린 프리뷰를 프레임에 싣는다. 자리는 `image_preview.place`가, 픽셀 채널은 갤러리와 같은
/// `gpu_images`가 소유한다(§2.1·§2.3).
pub fn appendMarkerPreviewImage(
    self: *AppSession,
    images: *[]renderer.metal_frame.GpuImage,
    uploads: *[]renderer.metal_frame.GpuImageUpload,
    pixels: *[]u8,
    /// `pixels` 가 호출자 소유인지. kitty 픽셀은 프레임마다 AppSession 재사용 버퍼를 가리킬 수 있는데,
    /// 아래 `marker_preview_ops.appendGpuImage` 는 `pixels.*` 를 **free 하고 교체**한다 — 그대로 넘기면
    /// 남의 버퍼를 해제한다. 그래서 **실제로 건드리기 직전에** owned 사본으로 승격한다(조기 반환
    /// 경로는 승격하지 않는다 — 미리보기가 닫힌 프레임에서 수 MB 를 헛복사하지 않기 위해서다).
    pixels_owned: *bool,
    live_ids: *std.ArrayList(u32),
) void {
    const open = &(self.marker_preview_open orelse return);
    const target = markerPreviewTarget(self) orelse {
        open.uploaded = false; // 다른 탭이라 이 프레임엔 안 실린다
        return;
    };
    const place = markerPreviewPlacement(self, target, open.*) orelse {
        open.uploaded = false;
        return;
    };
    // **테두리를 여기서 그린다 — 이미지와 같은 프레임 자리다.** 예전에는 chrome draws 조립부에서
    // 넣었는데, `gpu_quads` 는 **매 프레임 비워지는데 그 조립부는 매 프레임 돌지 않는다**. 그래서
    // 테두리가 유지되지 않았다 — Cmd 를 누르면 단축키 힌트 때문에 chrome 이 다시 조립돼 살아나고,
    // 떼면 그 프레임부터 quad 가 비어 사라졌다(사용자 제보 2026-09-14).
    // **규율**: 매 프레임 있어야 하는 것은 매 프레임 도는 자리에서 넣는다 — 이미지(`gpu_images`)가
    // 이미 그 자리를 쓰고 있었고, 테두리만 다른 생명주기에 얹은 것이 어긋남의 원인이었다.
    appendMarkerPreviewFrameQuads(self, place, open.sent_hit_index != null);
    if (open.pixels.len == 0) {
        open.uploaded = false; // 아직 안 풀렸다 — 「안 그리고 나가는 길」이라 표시를 되돌린다(§5)
        return; // 테두리(자리)는 이미 그렸다
    }
    // 여기서부터 pixels 를 free/교체한다 — 비소유면 지금 승격한다(위 pixels_owned 주석). 실패(OOM)면 이번
    // 프레임엔 미리보기를 안 싣는다(`uploaded` 가 안 올라가 다음 프레임에 다시 온다).
    if (!self.promoteKgPixelsOwned(pixels, pixels_owned)) return;
    marker_preview_ops.appendGpuImage(open, self.allocator, place, images, uploads, pixels, live_ids);
}

/// **전송된** 마커를 토글한다 — 픽셀은 갤러리 인덱스(트랜스크립트)에서 온다(§4.4).
///
/// 인덱스가 그 N을 모르면 **열지 않는다**. 화면에 글자로 쓰인 `[Image #N]`과 구분할 방법이 그것뿐이고
/// (§3.1), 틀린 그림을 자신 있게 띄우는 것보다 안 뜨는 편이 낫다.
fn toggleSentMarkerPreview(
    self: *AppSession,
    surface_id: u64,
    m: maru.session.agent_image_markers.Hit,
    screen_hits: []const maru.session.agent_image_markers.Hit,
    scrolled: bool,
) bool {
    if (self.marker_preview_open) |c| {
        if (c.surface_id == surface_id and c.n == m.n and c.row == m.row and c.start_col == m.start_col) {
            closeMarkerPreview(self);
            return true;
        }
    }
    const found = findSentMarkerHit(self, m, screen_hits, scrolled) orelse {
        // 인덱스가 아직 없다 — 갤러리 도크를 한 번도 안 열었으면 비어 있다(`refreshForFocus`).
        // **이번 클릭은 조용히 실패**하되 스캔을 걸어 다음 번엔 답할 수 있게 한다.
        agent_activity_ops.refresh(self, false);
        return false;
    };
    const h = self.agent_activity.hits.items[found];
    if (self.marker_preview_open) |*o| o.deinit(self.allocator);
    self.marker_preview_open = .{
        .surface_id = surface_id,
        .n = m.n,
        .row = m.row,
        .start_col = m.start_col,
        .end_col = m.end_col,
        .sent_hit_index = found,
        .sent_file_index = h.file_index,
        .sent_data_offset = h.data_offset,
    };
    self.metal_dirty = true;
    return true;
}

/// 갤러리 인덱스에서 그 마커 번호의 이미지를 찾는다. **최근 것이 이긴다** — Codex는 N이 메시지
/// 안에서만 유일해 같은 번호가 여럿일 수 있는데(§4.3), 화면에서 누른 것은 대개 최근 대화다.
fn findSentMarkerHit(
    self: *AppSession,
    m: maru.session.agent_image_markers.Hit,
    screen_hits: []const maru.session.agent_image_markers.Hit,
    scrolled: bool,
) ?usize {
    if (m.n == 0) return null;
    // **화면에서 뒤에서 몇 번째인가**를 세어 인덱스에서도 같은 순번을 고른다.
    //
    // 그냥 「가장 최근 것」을 고르면 Codex 에서 틀린 그림이 뜬다 — N 이 메시지마다 1 로 돌아가므로
    // (§4.3) 대화가 길면 `#1` 이 수십 개이고, 화면 **위쪽**(오래된) 마커를 눌러도 최근 것이 열린다.
    // §3.1 이 「틀린 이미지를 자신 있게 보여주는 것이 아무것도 안 보여주는 것보다 나쁘다」고 한 그것이다.
    //
    // 화면의 마커도 인덱스의 이미지도 **시간순**이라, 뒤에서부터 세면 맞는다.
    // **§4.2 가 금한 「순서로 세기」와는 다른 축이다** — 그쪽은 빈 번호를 건너뛰는 스테이징
    // 순번이었고, 이것은 같은 번호의 **발생 순서**다.
    //
    // ⚠️ **다만 화면이 스크롤돼 «최근 쪽»이 잘려 나가면 이 셈이 무너진다**(적대적 A31). 위로
    // 스크롤해 오래된 마커만 보이는 상태에서 그것을 누르면 `from_end = 0` 이 되어 인덱스의
    // **가장 최근** 것을 집는다 — A21 이 고치려던 그 결함이 그대로 되살아난다.
    // 그래서 아래 `ambiguous` 게이트가 있다.
    var from_end: usize = 0;
    var seen_click = false;
    var i = screen_hits.len;
    while (i > 0) {
        i -= 1;
        const sh = screen_hits[i];
        if (sh.n != m.n) continue;
        if (sh.row == m.row and sh.start_col == m.start_col) {
            seen_click = true;
            break;
        }
        from_end += 1;
    }
    if (!seen_click) return null;

    const hits = self.agent_activity.hits.items;
    // 같은 번호가 인덱스에 **하나뿐이면** 셈이 필요 없다 — 스크롤 여부와 무관하게 그것이 답이다.
    // Claude 는 N 이 프로세스 누적이라(§4.3) 대개 이 길로 간다.
    var same_n: usize = 0;
    for (hits) |h| {
        if (h.kind.isImage() and h.marker_n == m.n) same_n += 1;
    }
    if (same_n == 0) return null;
    // 여럿인데 화면이 잘려 있으면 **열지 않는다.** 틀린 그림을 자신 있게 띄우는 것보다 낫다(§3.1).
    if (same_n > 1 and scrolled) return null;

    var skipped: usize = 0;
    var j = hits.len;
    while (j > 0) {
        j -= 1;
        const h = hits[j];
        if (!h.kind.isImage()) continue;
        if (h.marker_n != m.n) continue;
        if (skipped == from_end) return j;
        skipped += 1;
    }
    return null;
}

/// 프리뷰의 배경·테두리 quad 두 장. 바깥을 테두리 색으로 채우고 안쪽을 배경색으로 덮어 테를 만든다
/// (quad 하나가 `border_widths` 를 안 받는 경로라 — 셰이더 분기를 늘리지 않는다).
fn appendMarkerPreviewFrameQuads(
    self: *AppSession,
    place: chrome.components.image_preview.Placement,
    /// 「도크에서 보기」가 가능한가 — 전송된 마커에만 자리가 있다(§2.3). 참일 때만 모서리 표식을
    /// 그린다. 없는 길을 알리는 표식은 **거짓말**이고, 눌러도 아무 일이 없으면 고장으로 읽힌다.
    dock_jump: bool,
) void {
    const tk = self.buildChromeTokens();
    const border = packOpaqueRgb(tk.palette.get(.focus_accent));
    // **불투명하게 둔다.** 사이드바 같은 chrome 은 `chromeQuadBg` 로 `window.opacity` 를 함께 먹어
    // 창이 반투명하면 같이 비쳐야 맞지만, 팝업은 **떠 있는 것**이라 뒤가 비치면 그림이 배경 글자와
    // 섞여 읽히지 않는다(사용자 제보 2026-09-14). 그래서 창 투명도를 따르지 않는다.
    const bg = packOpaqueRgb(tk.palette.get(.surface_bg));
    const b: f32 = @floatFromInt(chrome.components.image_preview.border_px);
    const bx: f32 = @floatFromInt(place.box.x);
    const by: f32 = @floatFromInt(place.box.y);
    const bw: f32 = @floatFromInt(place.box.w);
    const bh: f32 = @floatFromInt(place.box.h);
    // **뒤판** — 상자 전체를 불투명하게 깐다(`image_backdrop`: 터미널 셀 앞·그림 뒤).
    //
    // 한때는 「셀보다 위이면서 이미지보다 아래인 자리가 없다」고 적고 테두리만 그렸다. 그 진단은
    // 맞았지만 결론이 틀렸다 — 없으면 **여는 것이 정공법**이었고(문서가 그렇게 적어 두기까지 했다),
    // 그 자리가 없는 동안 사용자는 디코드를 기다리는 빈 액자와 투명 PNG 뒤로 **터미널 글자가 비치는**
    // 화면을 봤다(제보 2026-09-15). 이제 렌더러가 그 패스를 가지므로 판을 깐다.
    self.appendSolidQuad(bx, by, bw, bh, bg, renderer.metal_frame.quad_layer.image_backdrop);
    // 테두리 네 변은 **그림 위**(layer 1)에 남는다 — 그림이 판을 꽉 채우므로 액자는 그 앞이라야 보인다.
    self.appendSolidQuad(bx, by, bw, b, border, 1); // 위
    self.appendSolidQuad(bx, by + bh - b, bw, b, border, 1); // 아래
    self.appendSolidQuad(bx, by + b, b, bh - 2 * b, border, 1); // 왼쪽
    self.appendSolidQuad(bx + bw - b, by + b, b, bh - 2 * b, border, 1); // 오른쪽
    // **우하단 모서리 표식** — 「여기 눌러 도크에서 볼 것이 있다」. 테두리와 같은 색·이어진
    // 덩어리라 「모서리가 두껍다」로 읽힌다(흔한 모서리 접힘 관용구). 글자를 못 쓰는 이유는
    // `image_preview.dock_jump_mark_px` 주석에 있다 — `gpu_glyphs` 는 이 자리에서 못 채운다.
    if (dock_jump) {
        const mark: f32 = @floatFromInt(chrome.components.image_preview.dock_jump_mark_px);
        // 자리 판정은 `image_preview.dockMarkFits` 가 한다(순수 — 적대 6회차에 뺐다).
        if (chrome.components.image_preview.dockMarkFits(place.box.w, place.box.h)) {
            self.appendSolidQuad(bx + bw - b - mark, by + bh - b - mark, mark, mark, border, 1);
        }
    }
}

/// 「도크에서 보기」 — 프리뷰 상자를 누르면 갤러리의 크게 보기로 간다(§2.3).
///
/// **판정은 `image_preview.dockJumpTarget` 이 한다**(순수). 여기는 배선만이다 — 도크를 열고,
/// 그 자리를 크게 열고, 프리뷰를 닫는다. 셋이 이어져 있어 부수효과로 남으면 「어느 조건에서
/// 점프하는가」를 판정자가 물을 수 없으므로 조건을 저쪽에 두었다.
pub fn markerPreviewDockJumpAt(self: *AppSession, x_px: f64, y_px: f64) bool {
    const open = self.marker_preview_open orelse return false;
    if (!self.surface_initialized or self.tabs.items.len == 0) return false;
    const target = markerPreviewTarget(self) orelse return false;
    if (target.term.kind != .terminal) return false;
    const place = markerPreviewPlacement(self, target, open) orelse return false;
    const hit_index = chrome.components.image_preview.dockJumpTarget(open.sent_hit_index, place.box, x_px, y_px) orelse return false;
    // **도크를 연다** — 접혀 있거나 다른 뷰를 보고 있을 수 있다. `enterDockView` 만 부르면 뷰만
    // 바뀌고 화면에는 아무 변화가 없다(접힌 채로 남는다).
    dock_ops.openDockTo(self, .agent_activity);
    agent_activity_ops.openAt(self, hit_index);
    // 프리뷰는 닫는다 — 같은 그림이 도크에서 더 크게 떠 있는데 위에 겹쳐 둘 이유가 없다.
    closeMarkerPreview(self);
    self.metal_dirty = true;
    return true;
}

pub fn markerPreviewTarget(self: *AppSession) ?MarkerPreviewOwner {
    const open = self.marker_preview_open orelse return null;
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    self.pane_target_rects_scratch.clearRetainingCapacity();
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &self.pane_target_rects_scratch) catch return null;
    for (self.pane_target_rects_scratch.items) |lr| {
        const t = lr.leaf.activeTerm();
        if (t.surface.id == open.surface_id) return .{ .term = t, .leaf = lr.rect };
    }
    return null;
}

/// 열린 프리뷰의 자리 — 그리는 쪽과 안내를 얹는 쪽이 **같은 계산**을 쓰게 하는 단일 출처다.
pub fn markerPreviewPlacement(
    self: *AppSession,
    owner: MarkerPreviewOwner,
    open: marker_preview_ops.Open,
) ?chrome.components.image_preview.Placement {
    const anchor_rect = markerAnchorRect(self, owner, open);
    const p = chrome.props.ChromeProps{ .metrics = self.buildCellMetrics() };
    // 아직 못 푼 동안에도 **자리는 잡아 둔다** — 클릭했는데 아무것도 안 뜨면 「먹혔나」로 읽힌다.
    const w: u32 = if (open.width > 0) open.width else 24 * @max(p.metrics.cell_width_px, 1);
    const h: u32 = if (open.height > 0) open.height else @max(p.metrics.cell_height_px, 1);
    return chrome.components.image_preview.place(anchor_rect, w, h, p);
}

/// 열린 프리뷰의 **테두리와 실패 안내**를 chrome ops에 싣는다. 픽셀은 `gpu_images`가 따로 싣는다
/// (갤러리 §5.4 분업). 문구는 여기서 i18n에서 고른다 — 컴포넌트는 `ui.language`를 모른다.
/// 열린 프리뷰의 **실패 안내 글자**만 chrome ops 에 싣는다. 배경·테두리는 `appendMarkerPreviewFrameQuads`
/// 가 프레임 조립에서 그린다 — 이 조립부는 **매 프레임 돌지 않아** quad 를 넣으면 유지되지 않는다
/// (위 주석의 사고). 글자는 chrome draws 의 생명주기를 따르므로 여기 남는다.
pub fn collectMarkerPreviewDraws(
    self: *AppSession,
    arena: std.mem.Allocator,
    out: *std.ArrayList(chrome.draw.ChromeDraw),
) !void {
    const open = self.marker_preview_open orelse return;
    if (!open.failed) return; // 안내가 필요한 경우는 「못 풀었다」 하나뿐이다
    const target = markerPreviewTarget(self) orelse return;
    const place = markerPreviewPlacement(self, target, open) orelse return;
    const p = chrome.props.ChromeProps{ .metrics = self.buildCellMetrics() };
    const tk = self.buildChromeTokens();
    var ops: std.ArrayList(chrome.draw.Op) = .empty;
    try chrome.components.image_preview.view(
        place,
        maru.i18n.t(.app_marker_preview_undecodable),
        p,
        &tk,
        arena,
        &ops,
    );
    if (ops.items.len > 0) try out.append(arena, .{
        .layer = chrome.components.image_preview.layer,
        .ops = ops.items,
    });
}

/// 마커 span의 화면 사각형(px) — 셀 → px 변환은 여기서 한다(배치 모듈은 px만 안다).
/// ⚠️ **그 프리뷰가 «속한» pane 의 leaf 에서 뽑는다.** `self.termRect()` 는 모든 pane 을 합친
/// 터미널 영역이라 분할하면 오른쪽·아래 pane 의 origin 이 통째로 빠지고(제보 2026-09-15),
/// 활성 pane 의 leaf 를 쓰면 **비활성 pane 에 뜬 프리뷰**가 엉뚱한 자리를 가리킨다
/// (제보 2026-09-20 — `markerPreviewTarget` 주석). 마커 좌표는 그 pane 격자 기준이다.
///
/// **owner 를 인자로 받는다 — 여기서 다시 찾지 않는다.** 찾는 일(`activeTabLeafRects`)은 할당을
/// 하는데, 호출자가 이미 한 것을 프레임마다 두세 번 되풀이하고 있었다(적대 1회차).
pub fn markerAnchorRect(self: *AppSession, owner: MarkerPreviewOwner, open: marker_preview_ops.Open) chrome.draw.Rect {
    const rect = pane_ops.paneTermRect(self, owner.leaf);
    const m = self.buildCellMetrics();
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const cols = open.end_col -| open.start_col;
    return .{
        .x = @as(i32, @intCast(rect.x)) + @as(i32, open.start_col) * @as(i32, @intCast(cw)),
        .y = @as(i32, @intCast(rect.y)) + @as(i32, open.row) * @as(i32, @intCast(ch)),
        .w = @as(u32, cols) * cw,
        .h = ch,
    };
}

/// 프리뷰를 닫는 **단일 자리** — 픽셀을 놓고 회수 표시를 세운다(§5).
pub fn closeMarkerPreview(self: *AppSession) void {
    if (self.marker_preview_open) |*o| o.deinit(self.allocator);
    self.marker_preview_open = null;
    self.metal_dirty = true;
}

/// tick마다 마커 프리뷰 상태를 화면에 맞춘다(§4.2). 대기 중인 붙여넣기가 없고 스테이징도 비어
/// 있으면 **화면을 읽지 않는다** — 관찰이 걸리지 않은 세션에 비용을 물리지 않는다.
pub fn pollMarkerPreview(self: *AppSession) void {
    if (self.marker_preview.pending.items.len == 0 and self.marker_preview.slots.items.len == 0) return;
    // ⚠️ **매 tick 화면을 풀지 않는다.** 이 함수는 뷰포트 전체를 UTF-8 로 풀고 마커를 훑는데,
    // 60 Hz 로 돌면 셀 수천 개를 초당 수십 번 변환한다 — §3.2 가 「스캔은 수식키를 누른 동안에만」
    // 이라고 세운 규율을 관찰 폴링만 비껴가고 있었다(적대적 3회차).
    //
    // 붙여넣기를 기다리는 동안(`pending`)은 매 tick 봐야 한다 — 마커는 42 ms 안에 뜬다(§10).
    // 기다릴 것이 없으면 `syncVisible`(전송 감지)만 남는데 그것은 늦어도 기능이 안 깨지므로
    // **드물게** 본다. 픽셀은 `sent` 로 옮겨도 계속 들고 있기 때문이다(§4.2 A11).
    const waiting = self.marker_preview.pending.items.len > 0;
    if (!waiting) {
        self.marker_preview_idle_tick +%= 1;
        if (self.marker_preview_idle_tick % idle_marker_scan_ticks != 0) return;
    }
    if (!self.surface_initialized or self.tabs.items.len == 0) return;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .terminal or term.rt.ended_placeholder) return;
    const surface_id = term.surface.id;
    var visible: std.ArrayList(u32) = .empty;
    defer visible.deinit(self.allocator);
    collectMarkerNumbers(self, term, .viewport, &visible) catch return;
    const pending_before = self.marker_preview.pending.items.len;
    marker_preview_ops.observe(&self.marker_preview, self.allocator, surface_id, visible.items) catch {};
    // **묶임은 여기서만 일어난다** — 어느 N 에 어느 파일이 들어갔는지는 사후에 재구성할 수 없다.
    if (diag_gate.maruDebugEnabled() and self.marker_preview.pending.items.len != pending_before) {
        if (self.marker_preview.stagingFor(surface_id)) |st| for (st.entries.items) |e|
            marker_preview_diag.info(
                "staged n={d} phase={s} bytes={d} path={s}",
                .{ e.n, @tagName(e.phase), e.png.len, e.path },
            );
    }
    self.releaseIndexedStaging(surface_id);
}

/// 인덱스가 그 마커 번호의 이미지를 들고 있나.
pub fn indexHasMarker(self: *AppSession, n: u32) bool {
    if (n == 0) return false;
    for (self.agent_activity.hits.items) |h| {
        if (h.kind.isImage() and h.marker_n == n) return true;
    }
    return false;
}

/// 그 term의 화면에서 마커 N을 모은다.
///
/// ⚠️ **관찰은 `viewport` 로 넓게 본다.** 한 판에서는 `cursor_block` 을 썼는데, 그 스코프는 스크롤된
/// 뷰포트에서 **빈 목록**이라(§3.3) 새 N 을 못 보고 그 장이 영영 안 묶였다. 관찰은 「새로 나타난 것」
/// 차분이라 범위가 넓어도 정확하다 — 오히려 스크롤·원격에 강하다. **락 아래에서** 읽는다 — 스냅샷이 코어 메모리를 alias한다
/// (hover 경로가 `lockCore`를 잡는 것과 같은 규율).
pub fn collectMarkerNumbers(
    self: *AppSession,
    term: *Term,
    scope: maru.session.agent_image_markers.Scope,
    out: *std.ArrayList(u32),
) !void {
    var hits: std.ArrayList(maru.session.agent_image_markers.Hit) = .empty;
    defer hits.deinit(self.allocator);
    try collectMarkerHits(self, term, scope, &hits);
    try maru.session.agent_image_markers.numbersOf(self.allocator, hits.items, out);
}

/// 그 term의 화면에서 마커를 셀 열까지 함께 모은다.
fn collectMarkerHits(
    self: *AppSession,
    term: *Term,
    scope: maru.session.agent_image_markers.Scope,
    out: *std.ArrayList(maru.session.agent_image_markers.Hit),
) !void {
    term.surface.lockCore(self.io);
    defer term.surface.unlockCore(self.io);
    try maru.session.agent_image_markers.scan(self.allocator, term.surface.renderSnapshot(), scope, out);
}
