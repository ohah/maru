//! screen_assembler — snapshot/delta 레코드를 소비해 **client 쪽 화면 모델**을 조립한다(§8 재접속 client 렌더의 중립
//! DTO 소비자). `screen_snapshot`(투영)의 **역**이다: host가 `TerminalCore`를 records로 투영하고(screen_snapshot),
//! client가 그 records를 이 조립기로 화면으로 되돌린다. 재접속한 GUI/CLI는 이 조립기가 든 화면(runs)을 렌더한다.
//!
//! 순수 계층(screen_stream codec만 의존 — platform-import-0)이라 non-macOS에서도 테스트한다. **새 terminal parser를
//! 만들지 않는다**(§8): host가 이미 파싱한 화면 상태(runs)를 grid에 반영할 뿐, raw PTY 바이트를 다시 파싱하지 않는다.
//! 즉 이 조립기는 VT 파서가 아니라 "이미 해석된 화면 record → grid" 재구성기다.
//!
//! generation 규율(§9): snapshot은 base generation을 세우고, delta는 그 base 위에서만 적용한다. delta의 `base_generation`이
//! 현재와 다르면 `GenerationGap`을 내 caller가 fresh snapshot을 재요청하게 한다. host가 resize 등으로 generation을 올리면
//! fresh snapshot(새 generation)으로 base가 교체된다. 그래서 gap이 조용히 화면을 어긋나게 두지 않는다.

const std = @import("std");
const screen_stream = @import("screen_stream.zig");

const Run = screen_stream.Run;

/// 다중 청크 이미지 재조립 총량 절대 상한(리뷰 #8). 선언 w*h*bpp가 이보다 크거나 오버플로면 이 값으로 클램프한다.
///
/// **소비자가 정할 수 있어야 한다.** 이 값은 데스크톱 예산이고, 폰에서 그대로 쓰면 손상된 delta
/// 하나가 앱을 통째로 죽인다(S11-5). 그래서 기본값은 여기 두되 조립기마다 낮출 수 있게 한다.
const max_reassembled_image: usize = 512 * 1024 * 1024; // 512 MiB

pub const ApplyError = screen_stream.DecodeError || error{
    /// delta의 `base_generation`이 현재 화면 generation과 다르다 — gap이라 fresh snapshot을 재요청해야 한다(§9).
    GenerationGap,
    /// delta가 조립기와 다른 grid(행 범위)를 전제한다 — snapshot부터 다시 받아야 한다.
    GeometryMismatch,
    /// 부분 열 set_runs(start_col>0)는 아직 지원하지 않는다. 현재 producer(`computeDelta`)는 항상 전체 행(start_col=0)만
    /// 낸다 — 열 splice는 producer가 부분 갱신을 최적화할 때의 forward 확장이다.
    PartialRowUnsupported,
    /// 받은 행의 Σ(width*count)가 cols와 다르다(§12: wide-cell continuation 불일치·손상·버전 스큐) — 조용히 truncate/blank로
    /// 렌더하지 않고 reject해 caller가 fresh snapshot을 재요청하게 한다.
    MalformedRow,
};

/// 한 행의 소유 runs(grapheme는 `pool`을 참조). record 버퍼는 일시적이라 조립기가 grapheme을 복사해 delta 사이에 유지한다.
const OwnedRow = struct {
    runs: []Run = &.{},
    pool: []u8 = &.{},
    fn deinit(self: OwnedRow, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.pool);
    }
};

/// 조립기가 소유한 kitty 이미지 한 장(디코드된 raw 픽셀). remote_screen(macOS)이 이걸 `terminal.KittyImageView`로 환산해
/// 렌더러에 넘긴다. `generation`은 렌더러 GPU 텍스처 업로드 캐시 무효화 키(host storage가 (재)transmit마다 올린 값).
pub const StoredImage = struct {
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    bpp: u8 = 0,
    pixels: []u8 = &.{}, // 조립기 소유(deinit/replace가 free).
};

/// 여러 image_blob 청크를 재조립하는 중간 버퍼. 청크는 chunk_index 0..count-1로 연속 도착하므로 순서대로 누적하고,
/// 마지막(next_index==count)에 커밋한다. 어긋난 순서/카운트면 폐기(손상 방어).
const PendingImage = struct {
    generation: u64,
    width: u32,
    height: u32,
    bpp: u8,
    next_index: u32,
    count: u32,
    buf: std.ArrayListUnmanaged(u8) = .empty,
};

/// record로부터 조립되는 client 화면 모델. runs를 host wire와 같은 형태로 들고(렌더러가 Run→cell 변환), snapshot으로
/// 리셋하고 delta로 증분 갱신한다. 소유는 caller(init/deinit).
pub const ScreenAssembler = struct {
    allocator: std.mem.Allocator,
    expected_codec_version: u16 = screen_stream.codec_version,
    cols: u16 = 0,
    rows_count: u16 = 0,
    active_screen: u8 = 0,
    cursor: screen_stream.Cursor = .{},
    modes: u32 = 0,
    generation: u64 = 0,
    /// 마지막으로 완전히 적용한 host-issued screen frontier.
    sequence: u64 = 0,
    sequenced_deltas_required: bool = false,
    frontier_initialized: bool = false,
    rows: []OwnedRow = &.{}, // len == rows_count
    // kitty 이미지 상태(#1 원격 이미지 전송, I3). image_store=완성된 이미지(id→픽셀), placement_list=표시 목록,
    // pending_images=재조립 중인 청크. snapshot은 이 셋을 리셋하고 record로 다시 채운다(host가 full snapshot에 전량 재송).
    image_store: std.AutoHashMapUnmanaged(u32, StoredImage) = .{},
    placement_list: std.ArrayListUnmanaged(screen_stream.ImagePlacement) = .empty,
    pending_images: std.AutoHashMapUnmanaged(u32, PendingImage) = .{},
    // 행별 OSC 133 prompt 마크(dense, positional; 마크 없으면 empty). remote_screen이 terminal.RowPrompt로 환산.
    prompt_marks: []screen_stream.RowPromptWire = &.{},
    // 뷰포트 링크(자동 감지 + OSC 8; 없으면 empty). host가 해석해 실어 준 것으로, client는 이것만으로 Cmd+hover
    // 밑줄을 그린다 — client core는 빈 placeholder라 스스로 감지할 수 없다(docs/link-detection.md §원격(host-backed) 세션).
    link_spans: []screen_stream.LinkSpanWire = &.{},
    // 스크롤바 thumb 근거(host가 ScreenMeta로 실어 준다). 구 host면 0으로 남아 스크롤바 미표시(기존 동작).
    scrollback_len: u32 = 0,
    view_offset: u32 = 0,

    /// 이 조립기의 이미지 재조립 상한. 기본은 데스크톱 예산이고 소비자가 낮출 수 있다.
    image_cap: usize = max_reassembled_image,

    pub fn init(allocator: std.mem.Allocator) ScreenAssembler {
        return .{ .allocator = allocator };
    }

    pub fn initForCodec(allocator: std.mem.Allocator, expected_codec_version: u16) ScreenAssembler {
        return .{ .allocator = allocator, .expected_codec_version = expected_codec_version };
    }

    /// 이미지 재조립 상한을 **이 조립기에 한해** 낮춘다. 폰은 데스크톱 예산(512 MiB)을 못 든다 —
    /// 손상되거나 악의적인 delta 하나가 앱을 죽인다. 기본보다 큰 값은 받지 않는다.
    pub fn limitReassembledImage(self: *ScreenAssembler, cap: usize) void {
        self.image_cap = @min(cap, max_reassembled_image);
    }

    /// CR4 staged reconnect만 호출한다. 일반 old-host rendering은 sequence=0 compatibility를
    /// 유지하지만, 권위 receipt를 만드는 candidate는 snapshot 뒤 exact +1을 강제한다.
    pub fn requireSequencedDeltas(self: *ScreenAssembler) void {
        self.sequenced_deltas_required = true;
    }

    pub fn prepareRecoveryFrontierFrom(self: *ScreenAssembler, current: *const ScreenAssembler) void {
        self.sequenced_deltas_required = current.sequenced_deltas_required;
        self.frontier_initialized = current.frontier_initialized;
        self.sequence = current.sequence;
    }

    pub fn deinit(self: *ScreenAssembler) void {
        self.clearRows();
        self.clearImages();
        self.image_store.deinit(self.allocator);
        self.placement_list.deinit(self.allocator);
        self.pending_images.deinit(self.allocator);
        if (self.prompt_marks.len != 0) self.allocator.free(self.prompt_marks);
        if (self.link_spans.len != 0) self.allocator.free(self.link_spans);
        self.* = undefined;
    }

    fn clearRows(self: *ScreenAssembler) void {
        for (self.rows) |row| row.deinit(self.allocator);
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.rows = &.{};
    }

    /// 이미지 상태를 비운다(snapshot 리셋·deinit 공용) — 완성 이미지 픽셀·placement·재조립 중 청크 버퍼를 모두 해제한다.
    /// 맵/리스트 자체(capacity)는 재사용을 위해 `clearRetainingCapacity`로 두고, 최종 해제는 deinit이 한다.
    fn clearImages(self: *ScreenAssembler) void {
        var it = self.image_store.valueIterator();
        while (it.next()) |img| self.allocator.free(img.pixels);
        self.image_store.clearRetainingCapacity();
        self.placement_list.clearRetainingCapacity();
        var pit = self.pending_images.valueIterator();
        while (pit.next()) |p| p.buf.deinit(self.allocator);
        self.pending_images.clearRetainingCapacity();
    }

    /// 완성된 이미지 픽셀(소유권 이전 — caller가 dupe/toOwnedSlice로 넘긴다)을 image_store에 넣는다(같은 id 교체 시 옛 픽셀 free).
    fn putImage(self: *ScreenAssembler, id: u32, gen: u64, w: u32, h: u32, bpp: u8, owned_pixels: []u8) ApplyError!void {
        const gop = self.image_store.getOrPut(self.allocator, id) catch {
            self.allocator.free(owned_pixels);
            return error.OutOfMemory;
        };
        if (gop.found_existing) self.allocator.free(gop.value_ptr.pixels);
        gop.value_ptr.* = .{ .generation = gen, .width = w, .height = h, .bpp = bpp, .pixels = owned_pixels };
    }

    /// image_store에서 이미지를 제거하고 픽셀을 free한다(리뷰 #12 — host가 evict/delete한 이미지를 client도 회수). 없으면 no-op.
    fn removeImage(self: *ScreenAssembler, id: u32) void {
        if (self.image_store.fetchRemove(id)) |kv| self.allocator.free(kv.value.pixels);
    }

    /// 다중 청크 재조립 pending 버퍼 상한(리뷰 #8, DoS 방어): 선언된 w*h*bpp(오버플로/과대 시 절대 상한)를 넘으면 폐기한다.
    /// per-record 1 MiB cap은 청크 하나만 막고 재조립 총량은 안 막으므로, 손상/악성 delta가 큰 chunk_count로 GB를 누적하는 걸 차단.
    fn reassembleCap(self: *const ScreenAssembler, width: u32, height: u32, bpp: u8) usize {
        const limit = self.image_cap;
        const wh = std.math.mul(u64, width, height) catch return limit;
        const total = std.math.mul(u64, wh, bpp) catch return limit;
        return @intCast(@min(total, @as(u64, limit)));
    }

    /// image_blob record 하나를 재조립한다. 단일 청크(count<=1)면 바로 저장, 다중 청크면 chunk_index 순서대로 누적하고
    /// 마지막에 커밋한다. 순서/카운트가 어긋나거나 상한(§reassembleCap)을 넘으면 그 이미지 pending을 폐기(손상 방어, 다음 fresh snapshot 복구).
    fn handleImageBlob(self: *ScreenAssembler, header: screen_stream.RecordHeader, body: []const u8) ApplyError!void {
        const blob = try screen_stream.decodeImageBlob(body);
        if (header.chunk_count <= 1) {
            const owned = self.allocator.dupe(u8, blob.pixels) catch return error.OutOfMemory;
            return self.putImage(blob.image_id, blob.generation, blob.width, blob.height, blob.bpp, owned);
        }
        if (header.chunk_index == 0) {
            if (self.pending_images.getPtr(blob.image_id)) |old| {
                old.buf.deinit(self.allocator); // 재시작 — 이전 미완 폐기.
                old.buf = .empty; // 리뷰 #4: free 후 빈 상태로 — 아래 appendSlice/put이 OOM으로 실패해도 map에 freed buf가 남아 double-free 되지 않게.
            }
            var pend = PendingImage{ .generation = blob.generation, .width = blob.width, .height = blob.height, .bpp = blob.bpp, .next_index = 0, .count = header.chunk_count };
            pend.buf.appendSlice(self.allocator, blob.pixels) catch {
                pend.buf.deinit(self.allocator);
                return error.OutOfMemory;
            };
            if (pend.buf.items.len > self.reassembleCap(blob.width, blob.height, blob.bpp)) { // 리뷰 #8: 상한 초과면 재조립 폐기.
                pend.buf.deinit(self.allocator);
                return;
            }
            pend.next_index = 1;
            self.pending_images.put(self.allocator, blob.image_id, pend) catch {
                pend.buf.deinit(self.allocator);
                return error.OutOfMemory;
            };
        } else {
            const p = self.pending_images.getPtr(blob.image_id) orelse return; // 0번 없이 온 청크 — 스킵.
            if (header.chunk_index != p.next_index or header.chunk_count != p.count) { // 순서/카운트 어긋남 — 폐기.
                p.buf.deinit(self.allocator);
                _ = self.pending_images.remove(blob.image_id);
                return;
            }
            p.buf.appendSlice(self.allocator, blob.pixels) catch return error.OutOfMemory;
            if (p.buf.items.len > self.reassembleCap(blob.width, blob.height, blob.bpp)) { // 리뷰 #8: 상한 초과면 폐기.
                p.buf.deinit(self.allocator);
                _ = self.pending_images.remove(blob.image_id);
                return;
            }
            p.next_index += 1;
        }
        // 마지막 청크면 커밋(소유권을 image_store로 이전).
        const p = self.pending_images.getPtr(blob.image_id) orelse return;
        if (p.next_index == p.count) {
            const owned = p.buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            _ = self.pending_images.remove(blob.image_id);
            try self.putImage(blob.image_id, blob.generation, blob.width, blob.height, blob.bpp, owned);
        }
    }

    /// 현재 표시 중인 이미지 placement 목록(렌더 입력). remote_screen이 각 placement의 image_id로 `imageById`를 찾아 그린다.
    pub fn imagePlacements(self: *const ScreenAssembler) []const screen_stream.ImagePlacement {
        return self.placement_list.items;
    }

    /// image_id로 저장된 이미지를 찾는다(없으면 null — placement가 아직 안 온 blob을 가리키는 경우).
    pub fn imageById(self: *const ScreenAssembler, id: u32) ?StoredImage {
        return self.image_store.get(id);
    }

    /// 저장된 **모든** 이미지 순회자(remote_screen이 in-process `buildImageViews`처럼 placement 미참조 이미지까지 전량
    /// 노출하려고 쓴다 — 리뷰 #10 divergence 해소). 맵 키가 unique라 별도 dedup 불요.
    pub fn imageStoreIterator(self: *const ScreenAssembler) std.AutoHashMapUnmanaged(u32, StoredImage).Iterator {
        return self.image_store.iterator();
    }

    /// 현재 행별 prompt 마크(dense; 마크 없으면 empty). remote_screen이 terminal.RowPrompt로 환산해 노출.
    pub fn promptMarks(self: *const ScreenAssembler) []const screen_stream.RowPromptWire {
        return self.prompt_marks;
    }

    /// prompt_marks record 전체를 교체한다(full-replace — 소유권 이전). 옛 배열 free.
    fn setPromptMarks(self: *ScreenAssembler, pm: screen_stream.PromptMarks) void {
        if (self.prompt_marks.len != 0) self.allocator.free(self.prompt_marks);
        self.prompt_marks = pm.rows;
    }

    /// 현재 뷰포트 링크(없으면 empty). remote_screen이 terminal.ViewportLink로 환산해 노출한다.
    pub fn linkSpans(self: *const ScreenAssembler) []const screen_stream.LinkSpanWire {
        return self.link_spans;
    }

    /// link_spans record 전체를 교체한다(full-replace — 소유권 이전). 빈 목록도 유효한 상태다("이제 링크 없음").
    fn setLinkSpans(self: *ScreenAssembler, ls: screen_stream.LinkSpans) void {
        if (self.link_spans.len != 0) self.allocator.free(self.link_spans);
        self.link_spans = ls.spans;
    }

    /// 화면의 행 수. **그리는 쪽이 «아래 몇 행» 을 고르려면 전체를 알아야 한다** — 창보다 높은
    /// 화면에서 위부터 그리면 프롬프트가 있는 아래쪽이 안 보인다.
    pub fn rowCount(self: *const ScreenAssembler) u16 {
        return self.rows_count;
    }

    /// 이 행의 runs(렌더 입력). 범위를 벗어나면 빈 슬라이스.
    pub fn rowRuns(self: *const ScreenAssembler, row: u16) []const Run {
        if (row >= self.rows_count) return &.{};
        return self.rows[row].runs;
    }

    /// snapshot record 스트림으로 화면을 **리셋**한다(첫 record는 screen_meta, 이후 row*). generation·크기·커서·mode를 세우고
    /// 모든 행을 새로 채운다. 이후 delta는 이 base 위에서 적용된다.
    pub fn applySnapshot(self: *ScreenAssembler, bytes: []const u8) ApplyError!void {
        var rs = screen_stream.RecordStream{ .bytes = bytes };
        const first = (try rs.next()) orelse return error.Truncated;
        const fs = try screen_stream.RecordStream.splitExact(first, self.expected_codec_version);
        if (fs.header.kind != .screen_meta) return error.Truncated; // snapshot의 첫 record는 반드시 screen_meta.
        const meta = try screen_stream.decodeScreenMeta(fs.body);

        // Snapshot도 한 batch 안의 frontier를 mutation 전에 전수 확인한다. 첫 record만 신뢰하고
        // 뒤의 mixed sequence에서 실패하면 이미 기존 화면을 지운 뒤라 복구 권위를 잃는다.
        var preflight = screen_stream.RecordStream{ .bytes = bytes };
        while (try preflight.next()) |rec| {
            const split = try screen_stream.RecordStream.splitExact(rec, self.expected_codec_version);
            if (split.header.sequence != fs.header.sequence) return error.GenerationGap;
        }
        if (self.sequenced_deltas_required) {
            if (!self.frontier_initialized) {
                if (fs.header.sequence != 0) return error.GenerationGap;
            } else {
                const expected = std.math.add(u64, self.sequence, 1) catch return error.GenerationGap;
                if (fs.header.sequence != expected) return error.GenerationGap;
            }
        }

        self.clearRows();
        self.clearImages(); // snapshot은 이미지도 리셋 — host가 full snapshot에 현재 이미지/placement를 전량 재송한다.
        if (self.prompt_marks.len != 0) { // prompt 마크도 리셋(record 없으면 = 마크 없음).
            self.allocator.free(self.prompt_marks);
            self.prompt_marks = &.{};
        }
        if (self.link_spans.len != 0) { // 링크도 리셋(record 없으면 = 링크 없음) — stale 밑줄 방지.
            self.allocator.free(self.link_spans);
            self.link_spans = &.{};
        }
        const new_rows = self.allocator.alloc(OwnedRow, meta.rows) catch return error.OutOfMemory;
        for (new_rows) |*row| row.* = .{}; // 빈 행으로 초기화(누락 row record 대비).
        self.rows = new_rows;
        self.cols = meta.cols;
        self.rows_count = meta.rows;
        self.active_screen = meta.active_screen;
        self.cursor = meta.cursor;
        self.scrollback_len = meta.scrollback_len;
        self.view_offset = meta.view_offset;
        self.modes = meta.modes;
        self.generation = fs.header.generation;
        self.sequence = fs.header.sequence;

        while (try rs.next()) |rec| {
            const s = try screen_stream.RecordStream.splitExact(rec, self.expected_codec_version);
            switch (s.header.kind) {
                .row => {
                    const dr = try screen_stream.decodeRow(self.allocator, s.body);
                    defer dr.deinit(self.allocator);
                    if (dr.row_index >= self.rows_count) continue; // 범위 밖 row_index 무시.
                    if (!screen_stream.rowWidthMatches(dr, self.cols)) return error.MalformedRow; // §12 계약 검증(reject-and-request-fresh).
                    // ownRuns를 **먼저** — 실패해도 기존 슬롯이 불변이라, 중복 row_index + OOM에서 해제된 포인터 재해제(double free)를 막는다.
                    const owned = try ownRuns(self.allocator, dr.runs);
                    self.rows[dr.row_index].deinit(self.allocator);
                    self.rows[dr.row_index] = owned;
                },
                .image_blob => try self.handleImageBlob(s.header, s.body), // 청크 재조립 → image_store.
                .image_placement => {
                    const p = try screen_stream.decodeImagePlacement(s.body);
                    self.placement_list.append(self.allocator, p) catch return error.OutOfMemory;
                },
                .prompt_marks => self.setPromptMarks(try screen_stream.decodePromptMarks(self.allocator, s.body)),
                .link_spans => self.setLinkSpans(try screen_stream.decodeLinkSpans(self.allocator, s.body)),
                else => {}, // 미래 record는 건너뛴다.
            }
        }
        self.frontier_initialized = true;
    }

    /// delta record 스트림을 현재 화면에 적용한다: set_runs(전체 행 교체), cursor, modes. base_generation이 어긋나면
    /// `GenerationGap`(caller가 fresh snapshot 재요청). scroll_rect/clear_rect/image는 현재 producer 미방출이라 건너뛴다.
    pub fn applyDelta(self: *ScreenAssembler, bytes: []const u8) ApplyError!void {
        const expected_sequence = std.math.add(u64, self.sequence, 1) catch return error.GenerationGap;
        // Frontier 전체를 먼저 검사해 stale/mixed batch가 화면 일부를 바꾼 뒤 실패하지 못하게 한다.
        var preflight = screen_stream.RecordStream{ .bytes = bytes };
        var batch_sequence: ?u64 = null;
        while (try preflight.next()) |rec| {
            const split = try screen_stream.RecordStream.splitExact(rec, self.expected_codec_version);
            if (batch_sequence) |seen| {
                if (split.header.sequence != seen) return error.GenerationGap;
            } else {
                batch_sequence = split.header.sequence;
            }
        }
        const admitted_sequence = batch_sequence orelse return error.GenerationGap;
        // sequence=0은 이전 host wire의 compatibility mode다. 새 host가 1을 발행한 뒤에는
        // exact contiguous만 허용하므로 reconnect catch-up이 legacy idle과 섞이지 않는다.
        if (!self.sequenced_deltas_required and self.sequence == 0 and admitted_sequence == 0) {
            // 구 host 화면 표시 전용. 이 assembler에서는 CR4 staged receipt를 발행하지 않는다.
        } else if (admitted_sequence != expected_sequence)
            return error.GenerationGap;

        var rs = screen_stream.RecordStream{ .bytes = bytes };
        while (try rs.next()) |rec| {
            const s = try screen_stream.RecordStream.splitExact(rec, self.expected_codec_version);
            switch (s.header.kind) {
                .set_runs => {
                    const sr = try screen_stream.decodeSetRuns(self.allocator, s.body);
                    defer sr.deinit(self.allocator);
                    if (sr.base_generation != self.generation) return error.GenerationGap;
                    if (sr.row_index >= self.rows_count) return error.GeometryMismatch;
                    if (sr.start_col != 0) return error.PartialRowUnsupported; // 현재 producer는 전체 행만 낸다.
                    if (!screen_stream.rowWidthMatches(.{ .row_index = sr.row_index, .runs = sr.runs }, self.cols)) return error.MalformedRow; // §12 검증.
                    const owned = try ownRuns(self.allocator, sr.runs);
                    self.rows[sr.row_index].deinit(self.allocator);
                    self.rows[sr.row_index] = owned;
                },
                .cursor => {
                    const cd = try screen_stream.decodeCursor(s.body);
                    if (cd.base_generation != self.generation) return error.GenerationGap;
                    self.cursor = cd.cursor;
                },
                .scroll_state => {
                    const sd = try screen_stream.decodeScrollState(s.body);
                    if (sd.base_generation != self.generation) return error.GenerationGap;
                    self.scrollback_len = sd.scrollback_len;
                    self.view_offset = sd.view_offset;
                },
                .modes => {
                    const md = try screen_stream.decodeModes(s.body);
                    if (md.base_generation != self.generation) return error.GenerationGap;
                    self.modes = md.modes;
                },
                // 이미지/prompt delta(#1 I4b). 이 record들은 body에 base_generation이 없어 **header.generation**으로 base를 대조한다
                // (리뷰 #5 — set_runs/cursor/modes와 동형; producer가 header.generation=base로 방출하므로 어긋나면 stale delta다).
                // blob은 additive(재조립→store), image_place는 full-set 교체(센티넬 clear+append), image_remove는 host storage에서
                // 사라진 이미지 회수(리뷰 #12), prompt_marks는 full-replace.
                .image_blob => {
                    if (s.header.generation != self.generation) return error.GenerationGap;
                    try self.handleImageBlob(s.header, s.body);
                },
                .image_place => {
                    if (s.header.generation != self.generation) return error.GenerationGap;
                    const p = try screen_stream.decodeImagePlacement(s.body);
                    if (p.image_id == 0) {
                        self.placement_list.clearRetainingCapacity(); // clear 센티넬.
                    } else {
                        self.placement_list.append(self.allocator, p) catch return error.OutOfMemory;
                    }
                },
                .image_remove => {
                    if (s.header.generation != self.generation) return error.GenerationGap;
                    const rm = try screen_stream.decodeImageRemove(s.body);
                    self.removeImage(@intCast(rm.blob_id)); // 리뷰 #12: host가 evict/delete한 이미지를 client도 회수(무한증가 방지).
                },
                .prompt_marks => {
                    if (s.header.generation != self.generation) return error.GenerationGap;
                    self.setPromptMarks(try screen_stream.decodePromptMarks(self.allocator, s.body));
                },
                // link_spans도 full-replace다. **빈 목록도 유효한 전이**("링크가 사라졌다")이므로 record가 오면
                // 그대로 반영해야 client에 stale 밑줄이 남지 않는다.
                .link_spans => {
                    if (s.header.generation != self.generation) return error.GenerationGap;
                    self.setLinkSpans(try screen_stream.decodeLinkSpans(self.allocator, s.body));
                },
                else => {}, // scroll_rect/clear_rect — 현재 producer 미방출, 조립기는 무시(후속 확장).
            }
        }
        // 리뷰 #7: delta 적용 후 placement가 참조하는 이미지가 모두 있어야 한다. 없으면 그 이미지의 blob 배치가 유실됐거나
        // (host는 blob을 placement보다 먼저 보냄) 불일치 상태다 — MalformedRow로 알려 caller가 fresh snapshot을 재요청하게 한다
        // (base는 현재 이미지 전량을 담으므로 복원됨). 이 덕에 dedup으로 재전송 안 되던 blob 유실이 영구 blank로 남지 않는다.
        try self.checkPlacementsResolved();
        self.sequence = admitted_sequence;
    }

    /// 모든 placement가 참조하는 이미지가 image_store에 있는지 검사한다(리뷰 #7). 없으면 배송 손실/불일치 → `MalformedRow`로
    /// resync를 유도한다. host가 blob을 placement보다 먼저 보내므로 정상 apply 후엔 항상 통과한다(단일 apply 내 blob 완결).
    fn checkPlacementsResolved(self: *const ScreenAssembler) ApplyError!void {
        for (self.placement_list.items) |p| {
            if (self.image_store.get(p.image_id) == null) return error.MalformedRow;
        }
    }

    /// 현재 화면을 snapshot record 스트림으로 다시 직렬화한다(caller 소유). fresh snapshot 재요청 응답을 만들거나, 조립
    /// 결과를 round-trip 검증하는 데 쓴다. `screen_snapshot.projectSnapshot`과 같은 레코드 형태다.
    pub fn toSnapshot(self: *const ScreenAssembler, allocator: std.mem.Allocator) screen_stream.DecodeError![]u8 {
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        errdefer stream.deinit(allocator);
        const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = self.generation, .sequence = self.sequence }, .{
            .cols = self.cols,
            .rows = self.rows_count,
            .active_screen = self.active_screen,
            .cursor = self.cursor,
            .modes = self.modes,
        });
        defer allocator.free(meta_rec);
        try screen_stream.appendRecord(&stream, allocator, meta_rec);
        for (self.rows, 0..) |row, i| {
            const rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = self.generation, .sequence = self.sequence }, .{ .row_index = @intCast(i), .runs = row.runs });
            defer allocator.free(rec);
            try screen_stream.appendRecord(&stream, allocator, rec);
        }
        return stream.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
};

/// record에서 빌린 runs를 소유 `OwnedRow`로 복사한다(grapheme을 pool에 모아 slice를 pool로 다시 가리킨다).
fn ownRuns(allocator: std.mem.Allocator, src: []const Run) ApplyError!OwnedRow {
    var pool_len: usize = 0;
    for (src) |r| pool_len += r.grapheme.len;
    const pool = allocator.alloc(u8, pool_len) catch return error.OutOfMemory;
    errdefer allocator.free(pool);
    const runs = allocator.alloc(Run, src.len) catch return error.OutOfMemory;
    var off: usize = 0;
    for (src, 0..) |r, i| {
        @memcpy(pool[off..][0..r.grapheme.len], r.grapheme);
        runs[i] = r;
        runs[i].grapheme = pool[off..][0..r.grapheme.len];
        off += r.grapheme.len;
    }
    return .{ .runs = runs, .pool = pool };
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트 (순수 — 전 플랫폼)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속한 client가 host 화면을 **똑같이** 재구성해야 §8 attach가
// 성립한다. host가 투영한 record를 이 조립기가 받아, snapshot으로 화면을 세우고 delta로 증분 갱신한 뒤 다시 직렬화하면
// 원본과 같아야 한다(record → grid → record round-trip). generation gap은 조용히 어긋나지 않고 fresh snapshot을 요구한다.
// screen_stream codec만 쓰는 순수 재구성기라 실 socket·core 없이 wire 대칭을 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 테스트 helper: screen_meta + row들을 length-prefixed snapshot 스트림으로 만든다(caller free).
fn buildSnapshot(allocator: std.mem.Allocator, generation: u64, meta: screen_stream.ScreenMeta, rows: []const screen_stream.Row) ![]u8 {
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = generation }, meta);
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    for (rows) |row| {
        const rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = generation }, row);
        defer allocator.free(rec);
        try screen_stream.appendRecord(&stream, allocator, rec);
    }
    return stream.toOwnedSlice(allocator);
}

test "screen assembler: applySnapshot reconstructs size, cursor, and row runs" {
    const allocator = testing.allocator;
    var runs0 = [_]Run{ .{ .grapheme = "h", .width = 1, .count = 1, .fg = 0xFF0000 }, .{ .grapheme = " ", .width = 1, .count = 3 } };
    var rows = [_]screen_stream.Row{.{ .row_index = 0, .runs = &runs0 }};
    const snap = try buildSnapshot(allocator, 5, .{ .cols = 4, .rows = 1, .cursor = .{ .col = 1, .row = 0 } }, &rows);
    defer allocator.free(snap);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);

    try testing.expectEqual(@as(u16, 4), asm_.cols);
    try testing.expectEqual(@as(u16, 1), asm_.rows_count);
    try testing.expectEqual(@as(u16, 1), asm_.cursor.col);
    try testing.expectEqual(@as(u64, 5), asm_.generation);
    const r = asm_.rowRuns(0);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("h", r[0].grapheme);
    try testing.expectEqual(@as(u32, 0xFF0000), r[0].fg);
    try testing.expectEqual(@as(u32, 3), r[1].count);
}

test "screen assembler binds exact record version to the selected MRSH adapter" {
    const allocator = testing.allocator;
    const current = try buildSnapshot(allocator, 1, .{ .cols = 2, .rows = 1 }, &.{});
    defer allocator.free(current);

    var previous = try allocator.dupe(u8, current);
    defer allocator.free(previous);
    std.mem.writeInt(u16, previous[4..6], 1, .big); // length prefix 뒤 첫 record header version.

    var current_assembler = ScreenAssembler.initForCodec(allocator, screen_stream.codec_version);
    defer current_assembler.deinit();
    try testing.expectError(error.BadCodecVersion, current_assembler.applySnapshot(previous));

    var previous_assembler = ScreenAssembler.initForCodec(allocator, 1);
    defer previous_assembler.deinit();
    try testing.expectError(error.BadCodecVersion, previous_assembler.applySnapshot(current));
    try previous_assembler.applySnapshot(previous);
}

test "screen assembler: applyDelta set_runs/cursor/modes updates the model; toSnapshot round-trips" {
    const allocator = testing.allocator;
    var runs0 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 3 }};
    var runs1 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 3 }};
    var rows = [_]screen_stream.Row{ .{ .row_index = 0, .runs = &runs0 }, .{ .row_index = 1, .runs = &runs1 } };
    const snap = try buildSnapshot(allocator, 9, .{ .cols = 3, .rows = 2 }, &rows);
    defer allocator.free(snap);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);

    // delta: row 1을 "abc"로, 커서를 (row1,col3)으로, modes를 바꾼다.
    var new_runs = [_]Run{ .{ .grapheme = "a", .width = 1, .count = 1 }, .{ .grapheme = "b", .width = 1, .count = 1 }, .{ .grapheme = "c", .width = 1, .count = 1 } };
    var delta: std.ArrayListUnmanaged(u8) = .empty;
    defer delta.deinit(allocator);
    {
        const rec = try screen_stream.encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = 9 }, .{ .base_generation = 9, .row_index = 1, .start_col = 0, .runs = &new_runs });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }
    {
        const rec = try screen_stream.encodeCursor(allocator, .{ .kind = .cursor, .generation = 9 }, .{ .base_generation = 9, .cursor = .{ .col = 3, .row = 1 } });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }
    {
        const rec = try screen_stream.encodeModes(allocator, .{ .kind = .modes, .generation = 9 }, .{ .base_generation = 9, .modes = 0x5 });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }
    try asm_.applyDelta(delta.items);

    try testing.expectEqualStrings("a", asm_.rowRuns(1)[0].grapheme);
    try testing.expectEqualStrings(" ", asm_.rowRuns(0)[0].grapheme); // row 0은 그대로.
    try testing.expectEqual(@as(u16, 3), asm_.cursor.col);
    try testing.expectEqual(@as(u16, 1), asm_.cursor.row);
    try testing.expectEqual(@as(u32, 0x5), asm_.modes);

    // toSnapshot으로 다시 직렬화한 뒤 새 조립기에 넣으면 같은 상태여야 한다(round-trip).
    const re = try asm_.toSnapshot(allocator);
    defer allocator.free(re);
    var asm2 = ScreenAssembler.init(allocator);
    defer asm2.deinit();
    try asm2.applySnapshot(re);
    try testing.expectEqualStrings("a", asm2.rowRuns(1)[0].grapheme);
    try testing.expectEqual(@as(u16, 3), asm2.cursor.col);
    try testing.expectEqual(@as(u32, 0x5), asm2.modes);
}

test "screen assembler: delta with a mismatched base_generation is a gap" {
    const allocator = testing.allocator;
    var runs0 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 2 }};
    var rows = [_]screen_stream.Row{.{ .row_index = 0, .runs = &runs0 }};
    const snap = try buildSnapshot(allocator, 1, .{ .cols = 2, .rows = 1 }, &rows);
    defer allocator.free(snap);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);

    // base_generation=2인 delta는 조립기(gen 1)와 안 맞아 gap이다 — caller가 fresh snapshot을 재요청해야 한다.
    var new_runs = [_]Run{.{ .grapheme = "x", .width = 1, .count = 2 }};
    var delta: std.ArrayListUnmanaged(u8) = .empty;
    defer delta.deinit(allocator);
    const rec = try screen_stream.encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = 2 }, .{ .base_generation = 2, .row_index = 0, .start_col = 0, .runs = &new_runs });
    defer allocator.free(rec);
    try screen_stream.appendRecord(&delta, allocator, rec);
    try testing.expectError(error.GenerationGap, asm_.applyDelta(delta.items));
}

/// 테스트 helper: meta + image_blob(단일 청크) + image_placement를 하나의 snapshot 스트림으로 만든다(caller free).
fn buildImageSnapshot(allocator: std.mem.Allocator, image_id: u32, gen: u64, w: u32, h: u32, bpp: u8, pixels: []const u8, col: u16) ![]u8 {
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 4, .rows = 1 });
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    const blob_rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 1 }, .{ .image_id = image_id, .generation = gen, .width = w, .height = h, .bpp = bpp, .pixels = pixels });
    defer allocator.free(blob_rec);
    try screen_stream.appendRecord(&stream, allocator, blob_rec);
    const pl_rec = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_placement, .generation = 1 }, .{ .image_id = image_id, .placement_id = 0, .row = 0, .col = col, .columns = w, .rows = h });
    defer allocator.free(pl_rec);
    try screen_stream.appendRecord(&stream, allocator, pl_rec);
    return stream.toOwnedSlice(allocator);
}

test "screen assembler: applySnapshot stores single-chunk image + placement" {
    const allocator = testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2x1 RGBA
    const snap = try buildImageSnapshot(allocator, 9, 4, 2, 1, 4, &px, 1);
    defer allocator.free(snap);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);

    try testing.expect(asm_.imageById(9) != null);
    const img = asm_.imageById(9).?;
    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u8, 4), img.bpp);
    try testing.expectEqual(@as(u64, 4), img.generation); // host storage generation(렌더러 캐시 키).
    try testing.expectEqualSlices(u8, &px, img.pixels);

    const pls = asm_.imagePlacements();
    try testing.expectEqual(@as(usize, 1), pls.len);
    try testing.expectEqual(@as(u32, 9), pls[0].image_id);
    try testing.expectEqual(@as(u16, 1), pls[0].col);
}

test "screen assembler: multi-chunk image_blob reassembles into one image" {
    const allocator = testing.allocator;
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 2, .rows = 1 });
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    // 6바이트 이미지를 3청크로 나눠 보낸다 — chunk_index 0..2, count 3.
    const chunks = [_][]const u8{ &[_]u8{ 0xA, 0xB }, &[_]u8{ 0xC, 0xD }, &[_]u8{ 0xE, 0xF } };
    for (chunks, 0..) |ch, i| {
        const rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 1, .chunk_index = @intCast(i), .chunk_count = 3 }, .{ .image_id = 7, .generation = 2, .width = 3, .height = 1, .bpp = 2, .pixels = ch });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&stream, allocator, rec);
    }

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);

    try testing.expect(asm_.imageById(7) != null);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xA, 0xB, 0xC, 0xD, 0xE, 0xF }, asm_.imageById(7).?.pixels);
}

test "screen assembler: applySnapshot resets prior images and placements" {
    const allocator = testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4 };
    const snap1 = try buildImageSnapshot(allocator, 9, 1, 1, 1, 4, &px, 0);
    defer allocator.free(snap1);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap1);
    try testing.expect(asm_.imageById(9) != null);
    try testing.expectEqual(@as(usize, 1), asm_.imagePlacements().len);

    // 이미지 없는 snapshot을 다시 적용하면 이전 이미지/placement가 비워진다(누수 없이).
    var runs0 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 4 }};
    var rows = [_]screen_stream.Row{.{ .row_index = 0, .runs = &runs0 }};
    const snap2 = try buildSnapshot(allocator, 2, .{ .cols = 4, .rows = 1 }, &rows);
    defer allocator.free(snap2);
    try asm_.applySnapshot(snap2);
    try testing.expect(asm_.imageById(9) == null);
    try testing.expectEqual(@as(usize, 0), asm_.imagePlacements().len);
}

test "screen assembler: applyDelta applies image_blob + image_place(clear sentinel replaces placements)" {
    const allocator = testing.allocator;
    // base: image 9가 표시된 화면(placement 1개).
    const base_px = [_]u8{ 1, 2, 3, 4 };
    const snap = try buildImageSnapshot(allocator, 9, 1, 1, 1, 4, &base_px, 0);
    defer allocator.free(snap);
    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);
    try testing.expectEqual(@as(usize, 1), asm_.imagePlacements().len); // image 9 placement.

    // delta: image_blob(id 4) + clear 센티넬 + image_place(id 4). → image 9 placement 치워지고 image 4로 교체.
    var delta: std.ArrayListUnmanaged(u8) = .empty;
    defer delta.deinit(allocator);
    const px = [_]u8{ 9, 8, 7, 6 };
    {
        const rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 1 }, .{ .image_id = 4, .generation = 2, .width = 1, .height = 1, .bpp = 4, .pixels = &px });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }
    {
        const clear = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = 1 }, .{ .image_id = 0, .row = 0, .col = 0 });
        defer allocator.free(clear);
        try screen_stream.appendRecord(&delta, allocator, clear);
    }
    {
        const pl = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = 1 }, .{ .image_id = 4, .row = 0, .col = 1 });
        defer allocator.free(pl);
        try screen_stream.appendRecord(&delta, allocator, pl);
    }
    try asm_.applyDelta(delta.items);

    // image 4 blob 저장(additive), image 9 blob은 그대로(placement만 치워짐).
    try testing.expect(asm_.imageById(4) != null);
    try testing.expectEqualSlices(u8, &px, asm_.imageById(4).?.pixels);
    try testing.expect(asm_.imageById(9) != null); // blob은 안 지운다.
    // placement는 clear+set으로 image 4 하나만(image 9 placement는 센티넬로 치워짐).
    try testing.expectEqual(@as(usize, 1), asm_.imagePlacements().len);
    try testing.expectEqual(@as(u32, 4), asm_.imagePlacements()[0].image_id);
    try testing.expectEqual(@as(u16, 1), asm_.imagePlacements()[0].col);
}

test "screen assembler: prompt_marks record sets per-row marks; snapshot without it resets" {
    const allocator = testing.allocator;
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 2, .rows = 3 });
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    var pm_rows = [_]screen_stream.RowPromptWire{ .{}, .{ .kind = 3, .exit = 5 }, .{} }; // row1 = command, exit 5.
    const pm_rec = try screen_stream.encodePromptMarks(allocator, .{ .kind = .prompt_marks, .generation = 1 }, .{ .rows = &pm_rows });
    defer allocator.free(pm_rec);
    try screen_stream.appendRecord(&stream, allocator, pm_rec);

    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);
    try testing.expectEqual(@as(usize, 3), asm_.promptMarks().len);
    try testing.expectEqual(@as(u8, 3), asm_.promptMarks()[1].kind);
    try testing.expectEqual(@as(?i16, 5), asm_.promptMarks()[1].exit);
    try testing.expectEqual(@as(u8, 0), asm_.promptMarks()[0].kind);

    // prompt_marks 없는 snapshot 다시 적용 → 리셋(empty, 누수 없이).
    var runs0 = [_]Run{.{ .grapheme = " ", .width = 1, .count = 2 }};
    var rows = [_]screen_stream.Row{.{ .row_index = 0, .runs = &runs0 }};
    const snap2 = try buildSnapshot(allocator, 2, .{ .cols = 2, .rows = 1 }, &rows);
    defer allocator.free(snap2);
    try asm_.applySnapshot(snap2);
    try testing.expectEqual(@as(usize, 0), asm_.promptMarks().len);

    // delta로 prompt_marks 교체.
    var delta: std.ArrayListUnmanaged(u8) = .empty;
    defer delta.deinit(allocator);
    var d_rows = [_]screen_stream.RowPromptWire{.{ .kind = 1, .exit = null }}; // prompt.
    const d_rec = try screen_stream.encodePromptMarks(allocator, .{ .kind = .prompt_marks, .generation = 2 }, .{ .rows = &d_rows });
    defer allocator.free(d_rec);
    try screen_stream.appendRecord(&delta, allocator, d_rec);
    try asm_.applyDelta(delta.items);
    try testing.expectEqual(@as(usize, 1), asm_.promptMarks().len);
    try testing.expectEqual(@as(u8, 1), asm_.promptMarks()[0].kind);
}

test "screen assembler: image/prompt deltas enforce generation gap and missing-image resync (review #5/#7)" {
    const allocator = testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4 };
    const snap = try buildImageSnapshot(allocator, 9, 1, 1, 1, 4, &px, 0); // gen 1, image 9 placed.
    defer allocator.free(snap);
    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);

    // #5: stale generation(2 != 1)인 image_blob delta는 GenerationGap.
    {
        var d: std.ArrayListUnmanaged(u8) = .empty;
        defer d.deinit(allocator);
        const rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 2 }, .{ .image_id = 4, .generation = 1, .width = 1, .height = 1, .bpp = 4, .pixels = &px });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&d, allocator, rec);
        try testing.expectError(error.GenerationGap, asm_.applyDelta(d.items));
    }

    // #7: 이미지 없이 placement만 오면(blob 유실) MalformedRow로 resync 유도. image 7을 place하되 blob은 안 보낸다.
    {
        var d: std.ArrayListUnmanaged(u8) = .empty;
        defer d.deinit(allocator);
        const pl = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = 1 }, .{ .image_id = 7, .row = 0, .col = 0 });
        defer allocator.free(pl);
        try screen_stream.appendRecord(&d, allocator, pl);
        try testing.expectError(error.MalformedRow, asm_.applyDelta(d.items));
    }
}

test "screen assembler: image_remove delta evicts the image (review #12)" {
    const allocator = testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4 };
    const snap = try buildImageSnapshot(allocator, 9, 1, 1, 1, 4, &px, 0); // image 9, placed.
    defer allocator.free(snap);
    var asm_ = ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(snap);
    try testing.expect(asm_.imageById(9) != null);

    // clear placements(센티넬) + image_remove(9) → 이미지 회수(placement 없어 #7 검사도 통과).
    var d: std.ArrayListUnmanaged(u8) = .empty;
    defer d.deinit(allocator);
    const clear = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = 1 }, .{ .image_id = 0, .row = 0, .col = 0 });
    defer allocator.free(clear);
    try screen_stream.appendRecord(&d, allocator, clear);
    const rm = try screen_stream.encodeImageRemove(allocator, .{ .kind = .image_remove, .generation = 1 }, .{ .base_generation = 1, .blob_id = 9 });
    defer allocator.free(rm);
    try screen_stream.appendRecord(&d, allocator, rm);
    try asm_.applyDelta(d.items);

    try testing.expect(asm_.imageById(9) == null); // 회수됨(무한증가 방지).
    try testing.expectEqual(@as(usize, 0), asm_.imagePlacements().len);
}
