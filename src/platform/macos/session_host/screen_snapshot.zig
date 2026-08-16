//! screen_snapshot — 실 `TerminalCore` 화면을 §12 `maru.screen-stream.v1` snapshot 레코드 스트림으로 투영한다(P3-e2d).
//!
//! `screen_stream.zig`는 snapshot/delta 레코드의 **codec**(바이트 ↔ 구조체)만 갖는다 — 그 레코드를 실제 화면에서
//! **만들어 내는** 투영기(조립기)는 여기다. host가 client attach에 첫 snapshot을 보낼 때(P3-e2d-2) 이 투영기로 현재
//! 화면을 레코드 스트림으로 바꾸고, 그 바이트를 `snapshot_chunk` MRSH frame으로 나눠 흘려 보낸다.
//!
//! 왜 별도 파일인가(레이어): 투영은 `maru.terminal`(TerminalCore/Cell/Style/Color)을 읽어야 하므로 `@import("maru")`가
//! 필요하다. 그래서 codec 순수 계층(screen_stream 등, platform-import-0)과 달리 이 파일은 macOS 전용(barrel 조건부)이고,
//! app 스택을 재사용하는 `runtime_manager`와 같은 부류다. 투영 자체는 OS 중립 순수 로직(syscall 없음)이라 실 core만 있으면
//! 테스트한다. §8 ANSI CLI client도 같은 중립 레코드를 소비하므로(새 parser 금지) 이 투영이 그 단일 출처다.
//!
//! 색 해석: host는 색을 **굽지 않고 Color intent를 실어 보낸다**(`packColorIntent` → 태그드 u32, §screen_stream.ColorTag).
//! `.default`/`.indexed`/`.rgb`를 그대로 실어, client가 자기 theme로 in-process와 **동일하게** 푼다(config 16색 base·
//! bold-is-bright·min-contrast·default 색). 예외: OSC4 override(`paletteOverride`)된 indexed는 override가 host per-terminal
//! 상태(client가 못 가짐)라 host가 그 rgb로 구워 실어 회귀를 막는다. reverse/dim/blink/conceal도 RGB에 안 굽고
//! `StyleFlags`(inverse/dim/blink/invisible)로 실어 client 표시층이 적용한다(§9 표시 정책은 client).
//!
//! 동시성: 이 투영은 순수 함수다(입력 `*const TerminalCore` → 소유 바이트). reader 스레드가 core를 쓰는 host 경로에선
//! **caller가 `Surface.core_mutex`를 잡은 채** 이 함수를 부르고(투영 동안 lock 유지, ~0.12ms), 반환된 소유 바이트만
//! unlock 뒤 전송한다(docs/io-render-threading.md — snapshot 슬라이스는 core 메모리 alias라 lock 밖으로 새면 안 됨).
//! 이 함수는 grapheme·색을 전부 소유 버퍼로 복사하므로 반환값은 core와 독립이다.

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const screen_stream = @import("screen_stream.zig");
const screen_assembler = @import("screen_assembler.zig");

const Run = screen_stream.Run;

comptime {
    // terminal enum을 늘리고 wire codec 범위를 갱신하지 않으면 producer가 새 값을 만들어 current decoder가 거부한다.
    // 두 계층을 직접 import할 수 있는 projection 경계에서 모든 값의 0-based 연속성과 case 수를 함께 고정한다.
    for (std.meta.fields(terminal.LinkKind), 0..) |field, i|
        if (field.value != i) @compileError("LinkKind wire values must be contiguous from zero");
    for (std.meta.fields(terminal.LinkScope), 0..) |field, i|
        if (field.value != i) @compileError("LinkScope wire values must be contiguous from zero");
    if (@intFromEnum(terminal.LinkKind.url) != 0 or @intFromEnum(terminal.LinkKind.file_path) != 1)
        @compileError("LinkKind wire meanings must not be reordered");
    if (@intFromEnum(terminal.LinkScope.web) != 0 or
        @intFromEnum(terminal.LinkScope.extra_schemes) != 1 or
        @intFromEnum(terminal.LinkScope.absolute_path) != 2 or
        @intFromEnum(terminal.LinkScope.home_path) != 3 or
        @intFromEnum(terminal.LinkScope.dot_relative) != 4 or
        @intFromEnum(terminal.LinkScope.bare_relative) != 5 or
        @intFromEnum(terminal.LinkScope.osc8) != 6)
        @compileError("LinkScope wire meanings must not be reordered");
    if (@intFromEnum(terminal.LinkKind.file_path) != screen_stream.link_kind_max or
        std.meta.fields(terminal.LinkKind).len != @as(usize, screen_stream.link_kind_max) + 1)
        @compileError("LinkKind and screen-stream wire range must change together");
    if (@intFromEnum(terminal.LinkScope.osc8) != screen_stream.link_scope_max or
        std.meta.fields(terminal.LinkScope).len != @as(usize, screen_stream.link_scope_max) + 1)
        @compileError("LinkScope and screen-stream wire range must change together");
}

/// `ScreenMeta.modes` 비트 배치(§9 mode bitmask). core에 단일 u32 mode가 없어 개별 필드를 여기서 조립한다. 값은 wire
/// 약속이라 고정 — client가 같은 비트로 해석한다(예: app_cursor_keys면 화살표를 SS3로 인코딩).
pub const ModeBit = screen_stream.ModeBit;

/// 투영 정책. `generation`은 이 snapshot의 base generation(client가 이후 delta의 base로 대조 — 보통 runtime의 resize
/// generation 등 host가 정한 단조 값). `default_fg`/`default_bg`는 이제 **미사용**이다 — host가 색을 굽지 않고 `.default`
/// intent를 실어(§packColorIntent) client가 자기 theme 기본 fg/bg로 풀기 때문이다. 필드는 wire/caller 호환을 위해 남긴다.
pub const ProjectOptions = struct {
    generation: u64 = 0,
    /// 한 projection batch의 host-issued frontier다. snapshot은 0에서 시작하고 delta는
    /// subscription owner가 commit한 직전 값의 exact +1만 발행한다.
    sequence: u64 = 0,
    default_fg: u32 = 0xFFFFFF,
    default_bg: u32 = 0x000000,
};

/// Projection-only bounded builder. It keeps amortized growth, but clamps the next capacity to the
/// codec ceiling instead of asking the allocator for a geometric capacity above it. This avoids
/// both near-cap O(N²) exact reallocations and unconditional 16 MiB preallocation on small deltas.
fn appendProjectedRecord(
    stream: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    record: []const u8,
) screen_stream.DecodeError!void {
    if (record.len > std.math.maxInt(u32)) return error.LengthOverflow;
    const total = std.math.add(usize, stream.items.len, 4 + record.len) catch
        return error.LengthOverflow;
    if (total > screen_stream.max_record_stream_bytes) return error.OutOfMemory;
    if (stream.capacity < total) {
        const geometric = stream.capacity +| stream.capacity / 2 +| 8;
        const target = @min(
            screen_stream.max_record_stream_bytes,
            @max(total, geometric),
        );
        stream.ensureTotalCapacityPrecise(allocator, target) catch
            return error.OutOfMemory;
    }
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(record.len), .big);
    stream.appendSliceAssumeCapacity(&len_buf);
    stream.appendSliceAssumeCapacity(record);
}

/// Projection uses several temporary buffers, but no single one may grow beyond the negotiated
/// viewport snapshot ceiling. In particular this stops the output ArrayList growth before the
/// parent allocator receives an oversized request. Returned memory is still parent-owned because
/// this adapter delegates allocation/free without adding headers.
const AllocationCap = struct {
    parent: std.mem.Allocator,
    max: usize,

    fn allocator(self: *AllocationCap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        if (len > self.max) return null;
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return false;
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return null;
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

/// Same projection contract with an allocation-time ceiling. The returned slice can be freed with
/// `allocator`, not the adapter, because AllocationCap is transparent.
pub fn projectSnapshotBounded(
    allocator: std.mem.Allocator,
    core: *terminal.TerminalCore,
    opts: ProjectOptions,
    max_allocation: usize,
) screen_stream.DecodeError![]u8 {
    var capped = AllocationCap{ .parent = allocator, .max = max_allocation };
    return projectSnapshot(capped.allocator(), core, opts);
}

/// 현재 화면을 length-prefixed 레코드 스트림(screen_meta + row*)으로 투영한다(caller 소유 바이트). client는 이 바이트를
/// `screen_stream.RecordStream`으로 순회해 화면을 조립한다. **동시 core 쓰기가 있으면 caller가 core lock을 잡고 부른다.**
/// `renderSnapshot`(뷰포트 인지 — view_offset>0이면 스크롤백 윈도 합성)을 쓴다 = in-process 렌더와 같은 화면(#6a 원격
/// 스크롤백: host가 스크롤 명령을 자기 core에 적용하면 그 뷰포트가 client에 투영된다). core를 mutate(viewport 합성 lazy
/// 할당)하므로 `*`(non-const) — caller가 core lock 아래 부른다(단일 mutator).
pub fn projectSnapshot(allocator: std.mem.Allocator, core: *terminal.TerminalCore, opts: ProjectOptions) screen_stream.DecodeError![]u8 {
    const snap = core.renderSnapshot();
    const palette = core.paletteOverride();

    var stream: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stream.deinit(allocator);

    // screen_meta 레코드(snapshot의 첫 레코드).
    const meta = screen_stream.ScreenMeta{
        .cols = snap.size.cols,
        .rows = snap.size.rows,
        .active_screen = if (core.alt_active) 1 else 0,
        .cursor = .{
            .col = snap.cursor.col,
            .row = snap.cursor.row,
            .visible = snap.cursor.visible,
            .shape = @intFromEnum(snap.cursor_shape),
        },
        .modes = composeModes(core),
        // 스크롤바 thumb 근거(§12) — client는 화면만 받으므로 길이/오프셋을 알 방법이 없다.
        .scrollback_len = @intCast(@min(core.scrollbackLen(), std.math.maxInt(u32))),
        .view_offset = @intCast(@min(core.viewOffset(), std.math.maxInt(u32))),
    };
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = opts.generation }, meta);
    defer allocator.free(meta_rec);
    try appendProjectedRecord(&stream, allocator, meta_rec);

    // 각 행을 run으로 압축해 row 레코드로 담는다.
    var row: u16 = 0;
    while (row < snap.size.rows) : (row += 1) {
        try appendRowRecord(allocator, snap, palette, opts, row, &stream);
    }

    // 이미지 방출(#1 원격 이미지 전송, I2): blob(디코드 픽셀, ≤max_image_blob 청크) + placement(뷰포트 상대). renderSnapshot이
    // 이미 buildImageViews 픽셀과 뷰포트 상대 placement를 줬다 — client는 이 두 record로 이미지를 in-process와 동일하게 렌더한다
    // (렌더러가 image_id/generation으로 GPU 텍스처 캐시). delta에서의 이미지 dedup/방출은 후속(I4) — 지금은 full snapshot만 싣는다.
    for (snap.images) |img| try appendImageBlobRecords(allocator, &stream, opts.generation, img);
    for (snap.placements) |p| try appendImagePlacementRecord(allocator, &stream, opts.generation, p);
    try appendPromptMarks(allocator, &stream, opts.generation, snap, true); // OSC 133 prompt 마크(있을 때만).
    // 뷰포트 링크(있을 때만) — client가 Cmd+hover 밑줄을 그릴 유일한 근거다(client core는 빈 placeholder).
    var links: std.ArrayList(terminal.ViewportLink) = .empty;
    defer links.deinit(allocator);
    core.collectViewportLinks(allocator, terminal.link_scopes_full, &links) catch return error.OutOfMemory;
    try appendLinkSpans(allocator, &stream, opts.generation, links.items, true);
    const owned = stream.toOwnedSlice(allocator) catch return error.OutOfMemory;
    stampRecordSequence(owned, opts.sequence) catch {
        allocator.free(owned);
        return error.Truncated;
    };
    return owned;
}

/// Projection helpers intentionally keep generation-focused signatures. The batch owner stamps the
/// bounded stream once so one atomic output batch cannot contain multiple frontier values.
fn stampRecordSequence(bytes: []u8, sequence: u64) screen_stream.DecodeError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 4) return error.Truncated;
        const record_len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (record_len < screen_stream.record_header_size) return error.Truncated;
        const record_start = offset + 4;
        const record_end = std.math.add(usize, record_start, record_len) catch return error.LengthOverflow;
        if (record_end > bytes.len) return error.Truncated;
        std.mem.writeInt(u64, bytes[record_start + 12 ..][0..8], sequence, .big);
        offset = record_end;
    }
}

/// 한 이미지의 디코드 픽셀을 per-record cap(≤max_image_blob) 청크로 나눠 image_blob 레코드로 방출한다. 빈 픽셀도 메타
/// 전달용 1개는 낸다. 메타(image_id/generation/w/h/bpp)는 자기서술 위해 매 청크 반복한다(재조립은 소비자 몫, §ImageBlob).
fn appendImageBlobRecords(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, img: terminal.KittyImageView) screen_stream.DecodeError!void {
    const cap = screen_stream.max_image_blob;
    const total = img.pixels.len;
    const chunk_count: u32 = if (total == 0) 1 else @intCast((total + cap - 1) / cap);
    var idx: u32 = 0;
    var off: usize = 0;
    while (idx < chunk_count) : (idx += 1) {
        const end = @min(off + cap, total);
        const rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = generation, .chunk_index = idx, .chunk_count = chunk_count }, .{
            .image_id = img.image_id,
            .generation = img.generation,
            .width = img.width,
            .height = img.height,
            .bpp = img.bpp,
            .pixels = img.pixels[off..end],
        });
        defer allocator.free(rec);
        try appendProjectedRecord(stream, allocator, rec);
        off = end;
    }
}

/// computeDelta의 **base(new_base)** 전용 이미지 메타 방출(리뷰 #11): base는 host-side에서 다음 diff의 prev로만 쓰이고(computeDelta가
/// image_id/generation만 읽어 dedup) client로 가지 않으며, resync는 projectSnapshot으로 core에서 재투영한다. 그러므로 base엔
/// **픽셀을 싣지 않는다**(pixel_len=0) — 매 ~20ms tick마다 수 MiB 픽셀을 재인코딩하던 낭비를 없앤다. 픽셀 전달은 delta(변경분)와
/// projectSnapshot(attach/resync)이 맡는다.
fn appendImageBaseMeta(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, img: terminal.KittyImageView) screen_stream.DecodeError!void {
    const rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = generation }, .{
        .image_id = img.image_id,
        .generation = img.generation,
        .width = img.width,
        .height = img.height,
        .bpp = img.bpp,
        .pixels = &.{}, // base는 dedup 메타만 — 픽셀은 delta/resync가 나른다.
    });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

/// delta용 placement 방출: full-set 교체라 **clear 센티넬(image_place, image_id=0)** 뒤에 현재 placement 전체를 image_place로
/// 싣는다. client(applyDelta)는 센티넬에 placement_list를 비우고 이후 image_place를 append한다 — 집합이 비게 바뀐 경우도
/// 센티넬만으로 표현된다. snapshot-band `image_placement`(kind 3)와 달리 delta-band `image_place`(kind 15)를 쓴다.
fn appendImagePlaceDelta(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, placements: []const terminal.KittyPlacement) screen_stream.DecodeError!void {
    const clear = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = generation }, .{ .image_id = 0, .row = 0, .col = 0 });
    defer allocator.free(clear);
    try appendProjectedRecord(stream, allocator, clear);
    for (placements) |p| {
        const rec = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_place, .generation = generation }, .{
            .image_id = p.image_id,
            .placement_id = p.placement_id,
            .row = p.row,
            .col = p.col,
            .cell_x_offset = p.cell_x_offset,
            .cell_y_offset = p.cell_y_offset,
            .src_x = p.src_x,
            .src_y = p.src_y,
            .src_width = p.src_width,
            .src_height = p.src_height,
            .columns = p.columns,
            .rows = p.rows,
            .z = p.z,
        });
        defer allocator.free(rec);
        try appendProjectedRecord(stream, allocator, rec);
    }
}

/// 이전 placement 집합(wire)과 현재(core)가 다른가 — 순서·개수·모든 필드 비교. 다르면 delta에 clear+set를 낸다.
fn placementsChanged(prev: []const screen_stream.ImagePlacement, cur: []const terminal.KittyPlacement) bool {
    if (prev.len != cur.len) return true;
    for (prev, cur) |a, b| {
        if (a.image_id != b.image_id or a.placement_id != b.placement_id or a.row != b.row or a.col != b.col or
            a.cell_x_offset != b.cell_x_offset or a.cell_y_offset != b.cell_y_offset or
            a.src_x != b.src_x or a.src_y != b.src_y or a.src_width != b.src_width or a.src_height != b.src_height or
            a.columns != b.columns or a.rows != b.rows or a.z != b.z) return true;
    }
    return false;
}

/// core의 뷰포트 상대 kitty placement를 image_placement 레코드로 방출한다(필드 1:1 — crop/offset/columns/rows 보존).
fn appendImagePlacementRecord(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, p: terminal.KittyPlacement) screen_stream.DecodeError!void {
    const rec = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_placement, .generation = generation }, .{
        .image_id = p.image_id,
        .placement_id = p.placement_id,
        .row = p.row,
        .col = p.col,
        .cell_x_offset = p.cell_x_offset,
        .cell_y_offset = p.cell_y_offset,
        .src_x = p.src_x,
        .src_y = p.src_y,
        .src_width = p.src_width,
        .src_height = p.src_height,
        .columns = p.columns,
        .rows = p.rows,
        .z = p.z,
    });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

/// 행별 OSC 133 semantic prompt(분류+종료코드)를 prompt_marks record로 방출한다(#1 이후 prompt_marks 패리티). `skip_if_none`이면
/// 마크가 전혀 없을 때(전 행 unknown+exit null) 생략한다 — snapshot은 common case 무비용, delta는 clear 전달 위해 skip_if_none=false.
/// dense(행당 1개, positional)라 full-replace다. renderSnapshot이 뷰포트 상대 prompt_marks(길이=rows)를 이미 줬다.
fn appendPromptMarks(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, snap: terminal.RenderSnapshot, skip_if_none: bool) screen_stream.DecodeError!void {
    if (snap.prompt_marks.len == 0) return; // core는 항상 length-rows지만 방어.
    if (skip_if_none) {
        var any = false;
        for (snap.prompt_marks) |m| {
            if (m.kind != .unknown or m.exit != null) {
                any = true;
                break;
            }
        }
        if (!any) return;
    }
    const rows = allocator.alloc(screen_stream.RowPromptWire, snap.prompt_marks.len) catch return error.OutOfMemory;
    defer allocator.free(rows);
    for (snap.prompt_marks, 0..) |m, i| rows[i] = .{ .kind = @intFromEnum(m.kind), .exit = m.exit };
    const rec = try screen_stream.encodePromptMarks(allocator, .{ .kind = .prompt_marks, .generation = generation }, .{ .rows = rows });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

/// 현재 뷰포트 링크(자동 감지 + OSC 8)를 link_spans record로 방출한다. host가 콘텐츠를 소유하므로 링크 **해석**도
/// host가 한다 — client의 core는 빈 placeholder라 스스로 감지할 수 없다(docs/link-detection.md §원격(host-backed) 세션).
/// client config(`input.link-detection`)를 host는 모르므로 **최대 집합으로 계산**하고 span마다 scope를 실어, 무엇을 그릴지는
/// client가 정하게 한다. `skip_if_none`이면 링크가 하나도 없을 때 생략한다(snapshot은 common case 무비용, delta는 "이제
/// 링크 없음"을 전달해야 하므로 false). prompt_marks와 같은 full-replace 규율.
fn appendLinkSpans(
    allocator: std.mem.Allocator,
    stream: *std.ArrayListUnmanaged(u8),
    generation: u64,
    links: []const terminal.ViewportLink,
    skip_if_none: bool,
) screen_stream.DecodeError!void {
    if (skip_if_none and links.len == 0) return;
    const spans = allocator.alloc(screen_stream.LinkSpanWire, links.len) catch return error.OutOfMemory;
    defer allocator.free(spans);
    for (links, 0..) |l, i| spans[i] = .{
        .start_row = l.span.start.row,
        .start_col = l.span.start.col,
        .end_row = l.span.end.row,
        .end_col = l.span.end.col,
        .kind = @intFromEnum(l.kind),
        .scope = @intFromEnum(l.scope),
    };
    const rec = try screen_stream.encodeLinkSpans(allocator, .{ .kind = .link_spans, .generation = generation }, .{ .spans = spans });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

/// 이전 link_spans(wire)와 현재(core 계산)가 다른가 — 둘 다 링크 없음이면 같음. delta 방출 여부 판정.
fn linkSpansChanged(prev: ?screen_stream.LinkSpans, cur: []const terminal.ViewportLink) bool {
    const prev_spans: []const screen_stream.LinkSpanWire = if (prev) |p| p.spans else &.{};
    if (prev_spans.len != cur.len) return true;
    for (cur, prev_spans) |c, p| {
        if (c.span.start.row != p.start_row or c.span.start.col != p.start_col or
            c.span.end.row != p.end_row or c.span.end.col != p.end_col or
            @intFromEnum(c.kind) != p.kind or @intFromEnum(c.scope) != p.scope) return true;
    }
    return false;
}

/// 이전 prompt_marks(wire)와 현재(core)가 다른가 — 둘 다 마크 없음이면 같음. delta 방출 여부 판정.
fn promptMarksChanged(prev: ?screen_stream.PromptMarks, cur: []const terminal.RowPrompt) bool {
    const prev_rows: []const screen_stream.RowPromptWire = if (prev) |p| p.rows else &.{};
    var cur_any = false;
    for (cur) |m| if (m.kind != .unknown or m.exit != null) {
        cur_any = true;
        break;
    };
    var prev_any = false;
    for (prev_rows) |m| if (m.kind != 0 or m.exit != null) {
        prev_any = true;
        break;
    };
    if (!cur_any and !prev_any) return false; // 둘 다 마크 없음.
    if (cur.len != prev_rows.len) return true;
    for (cur, prev_rows) |c, p| {
        if (@intFromEnum(c.kind) != p.kind or c.exit != p.exit) return true;
    }
    return false;
}

/// core의 개별 mode 필드를 §9 mode bitmask로 조립한다.
pub fn composeModes(core: *const terminal.TerminalCore) u32 {
    var m: u32 = 0;
    if (core.application_cursor_keys) m |= ModeBit.app_cursor_keys;
    if (core.application_keypad) m |= ModeBit.app_keypad;
    if (core.bracketed_paste) m |= ModeBit.bracketed_paste;
    if (core.alternate_scroll) m |= ModeBit.alternate_scroll;
    if (core.focus_events) m |= ModeBit.focus_events;
    if (core.origin_mode) m |= ModeBit.origin_mode;
    if (core.mouse_tracking != .none) m |= ModeBit.mouse_tracking;
    if (core.sync_output) m |= ModeBit.sync_output;
    if (core.grapheme_cluster_mode) m |= ModeBit.grapheme_cluster;
    if (core.viewOffset() != 0) m |= ModeBit.viewport_scrolled;
    if (core.ambiguous_wide) m |= ModeBit.ambiguous_wide;
    return m;
}

/// 임시 run(grapheme는 pool 오프셋으로 참조 — pool realloc이 슬라이스를 무효화하지 않게 offset/len으로 든다).
const RunTmp = struct { g_off: usize, g_len: usize, width: u8, count: u32, fg: u32, bg: u32, ul: u32, flags: u32 };

/// 한 행의 runs(소유 — grapheme는 pool을 참조). caller가 `deinit`으로 runs 슬라이스와 grapheme pool을 함께 해제한다.
/// snapshot(encodeRow)과 delta(runsEqual 비교 + encodeSetRuns) 둘 다 이 빌더를 재사용해 같은 압축 규칙을 공유한다.
const RowRuns = struct {
    runs: []Run,
    pool: []u8,
    fn deinit(self: RowRuns, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.pool);
    }
};

/// 한 행 셀을 RLE run으로 압축해 소유 `RowRuns`를 만든다(wide=width2·continuation 생략·태그드 Color intent·StyleFlags).
fn buildRowRuns(
    allocator: std.mem.Allocator,
    snap: terminal.RenderSnapshot,
    palette: *const [256]?terminal.Rgb,
    row: u16,
) screen_stream.DecodeError!RowRuns {
    const cols = snap.size.cols;
    var tmp: std.ArrayListUnmanaged(RunTmp) = .empty;
    defer tmp.deinit(allocator);
    var pool: std.ArrayListUnmanaged(u8) = .empty; // run별 grapheme 바이트 풀(offset으로 참조).
    errdefer pool.deinit(allocator);
    var cur: std.ArrayListUnmanaged(u8) = .empty; // 현재 셀 grapheme 임시(coalesce 비교용).
    defer cur.deinit(allocator);

    const base = @as(usize, row) * cols;
    var col: usize = 0;
    while (col < cols) {
        const cell = snap.cells[base + col];
        if (cell.continuation) { // wide glyph의 2번째 셀 — 앞선 width=2 run이 이미 덮는다.
            col += 1;
            continue;
        }
        const width: u8 = if (cell.width >= 2) 2 else 1;
        try encodeCellGrapheme(&cur, allocator, cell, snap.graphemes);
        const fg = packColorIntent(cell.style.foreground, palette);
        const bg = packColorIntent(cell.style.background, palette);
        // underline은 intent를 그대로 싣는다 — `.default`면 client가 전경색으로 푼다(draw_list.lineOverlay).
        const ul = packColorIntent(cell.style.underline_color, palette);
        const flags = styleFlags(cell.style);

        // 직전 run과 grapheme·width·색·스타일이 모두 같으면 count만 늘린다(RLE — 공백/반복 문자 압축).
        if (tmp.items.len > 0) {
            const last = &tmp.items[tmp.items.len - 1];
            if (last.width == width and last.fg == fg and last.bg == bg and last.ul == ul and last.flags == flags and
                std.mem.eql(u8, pool.items[last.g_off..][0..last.g_len], cur.items))
            {
                last.count += 1;
                col += width;
                continue;
            }
        }
        const g_off = pool.items.len;
        pool.appendSlice(allocator, cur.items) catch return error.OutOfMemory;
        tmp.append(allocator, .{ .g_off = g_off, .g_len = cur.items.len, .width = width, .count = 1, .fg = fg, .bg = bg, .ul = ul, .flags = flags }) catch return error.OutOfMemory;
        col += width;
    }

    // pool을 소유 슬라이스로 확정한 뒤 RunTmp를 실 Run으로 실체화한다(grapheme = 안정 pool 슬라이스).
    const runs = allocator.alloc(Run, tmp.items.len) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    const pool_slice = pool.toOwnedSlice(allocator) catch return error.OutOfMemory;
    for (tmp.items, 0..) |t, i| {
        runs[i] = .{ .grapheme = pool_slice[t.g_off..][0..t.g_len], .width = t.width, .count = t.count, .fg = t.fg, .bg = t.bg, .underline_color = t.ul, .style_flags = t.flags };
    }
    return .{ .runs = runs, .pool = pool_slice };
}

fn appendRowRecord(
    allocator: std.mem.Allocator,
    snap: terminal.RenderSnapshot,
    palette: *const [256]?terminal.Rgb,
    opts: ProjectOptions,
    row: u16,
    stream: *std.ArrayListUnmanaged(u8),
) screen_stream.DecodeError!void {
    const rr = try buildRowRuns(allocator, snap, palette, row);
    defer rr.deinit(allocator);
    const rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = opts.generation }, .{ .row_index = row, .runs = rr.runs });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

/// 두 run 목록이 같은가(같은 grapheme·width·count·색·스타일). delta가 바뀐 행만 골라내는 비교 기준이다.
fn runsEqual(a: []const Run, b: []const Run) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.width != y.width or x.count != y.count or x.fg != y.fg or x.bg != y.bg or
            x.underline_color != y.underline_color or x.style_flags != y.style_flags or
            !std.mem.eql(u8, x.grapheme, y.grapheme)) return false;
    }
    return true;
}

fn cursorsEqual(a: screen_stream.Cursor, b: screen_stream.Cursor) bool {
    return a.col == b.col and a.row == b.row and a.visible == b.visible and a.shape == b.shape;
}

pub const DeltaError = screen_stream.DecodeError || error{
    /// grid 크기나 alt-screen이 바뀌어 delta로 표현할 수 없다 — caller가 fresh snapshot을 보내야 한다(§9). delta는
    /// 같은 grid 위 증분(set_runs/cursor/modes)만 담는다.
    SnapshotRequired,
};

pub fn computeDeltaBounded(
    allocator: std.mem.Allocator,
    prev_bytes: []const u8,
    core: *terminal.TerminalCore,
    opts: ProjectOptions,
    max_allocation: usize,
) DeltaError!DeltaResult {
    var capped = AllocationCap{ .parent = allocator, .max = max_allocation };
    return computeDelta(capped.allocator(), prev_bytes, core, opts);
}

/// `computeDelta` 결과. `delta`는 바뀐 것만(빈 스트림 가능), `snapshot`은 현재 full snapshot(다음 base이자 render용).
/// **같은 row build 한 번에서** 둘 다 도출한다(재투영 없음). 둘 다 caller 소유이고 별개 버퍼다.
pub const DeltaResult = struct {
    delta: []u8,
    snapshot: []u8,

    pub fn deinit(self: DeltaResult, allocator: std.mem.Allocator) void {
        allocator.free(self.delta);
        allocator.free(self.snapshot);
    }
};

/// 이전 snapshot(`projectSnapshot`이 낸 record 바이트)과 현재 화면을 비교해 `delta`(바뀐 것만: `set_runs` 전체 행·`cursor`·
/// `modes`)와 `snapshot`(현재 full snapshot)을 **한 번의 row build로** 함께 만든다(caller 소유, length-prefixed). 안 바뀌면
/// delta는 빈 스트림. grid 크기/alt-screen이 바뀌면 `error.SnapshotRequired`(delta 불가 — caller가 fresh snapshot 전송).
/// **동시 core 쓰기가 있으면 caller가 core lock을 잡고 부른다**(`projectSnapshot`과 동일). base_generation은 `opts.generation`.
/// `projectSnapshot`과 같이 `renderSnapshot`(뷰포트 인지)을 써서 스크롤(view_offset 변화)이 delta에 반영된다(#6a). core를
/// mutate하므로 `*`(non-const).
pub fn computeDelta(allocator: std.mem.Allocator, prev_bytes: []const u8, core: *terminal.TerminalCore, opts: ProjectOptions) DeltaError!DeltaResult {
    // 이전 snapshot을 decode한다: screen_meta + rows.
    var rs = screen_stream.RecordStream{ .bytes = prev_bytes };
    const first = (try rs.next()) orelse return error.SnapshotRequired; // 빈 prev면 delta base가 없다.
    const fs = try screen_stream.RecordStream.split(first);
    if (fs.header.kind != .screen_meta) return error.SnapshotRequired;
    const prev_meta = try screen_stream.decodeScreenMeta(fs.body);

    const prev_rows = allocator.alloc(?[]Run, prev_meta.rows) catch return error.OutOfMemory;
    @memset(prev_rows, null);
    defer {
        for (prev_rows) |maybe| if (maybe) |r| allocator.free(r);
        allocator.free(prev_rows);
    }
    // 이미지 delta 계산용 prev 상태(#1 I4b): 이전 snapshot의 placement 집합과 image_id→generation(client가 이미 가진 것).
    var prev_placements: std.ArrayListUnmanaged(screen_stream.ImagePlacement) = .empty;
    defer prev_placements.deinit(allocator);
    var prev_image_gens: std.AutoHashMapUnmanaged(u32, u64) = .{};
    defer prev_image_gens.deinit(allocator);
    var prev_pm: ?screen_stream.PromptMarks = null;
    defer if (prev_pm) |p| p.deinit(allocator);
    var prev_ls: ?screen_stream.LinkSpans = null;
    defer if (prev_ls) |p| p.deinit(allocator);
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        switch (s.header.kind) {
            .row => {
                const dr = try screen_stream.decodeRow(allocator, s.body);
                if (dr.row_index < prev_meta.rows) {
                    if (prev_rows[dr.row_index]) |old| allocator.free(old); // 중복 row_index 방어.
                    prev_rows[dr.row_index] = dr.runs;
                } else {
                    dr.deinit(allocator);
                }
            },
            .image_placement => prev_placements.append(allocator, try screen_stream.decodeImagePlacement(s.body)) catch return error.OutOfMemory,
            .image_blob => {
                const blob = try screen_stream.decodeImageBlob(s.body);
                prev_image_gens.put(allocator, blob.image_id, blob.generation) catch return error.OutOfMemory;
            },
            .prompt_marks => {
                if (prev_pm) |p| p.deinit(allocator); // 중복 방어.
                prev_pm = null; // 리뷰 #6: free 후 null — 아래 decode가 실패하면 함수 defer가 이미-해제된 PM을 다시 free하지 않게.
                prev_pm = try screen_stream.decodePromptMarks(allocator, s.body);
            },
            .link_spans => {
                if (prev_ls) |p| p.deinit(allocator); // 중복 방어(prompt_marks와 같은 규율).
                prev_ls = null; // free 후 null — decode 실패 시 함수 defer가 이미-해제된 목록을 다시 free하지 않게.
                prev_ls = try screen_stream.decodeLinkSpans(allocator, s.body);
            },
            else => {},
        }
    }

    // 현재 화면을 읽는다(뷰포트 인지 — 스크롤 반영, #6a). grid/alt-screen이 바뀌면 delta로는 못 잇는다 → fresh snapshot 필요.
    const snap = core.renderSnapshot();
    const palette = core.paletteOverride();
    const cur_active: u8 = if (core.alt_active) 1 else 0;
    const cur_modes = composeModes(core);
    if (snap.size.cols != prev_meta.cols or snap.size.rows != prev_meta.rows or cur_active != prev_meta.active_screen) {
        return error.SnapshotRequired;
    }

    var delta: std.ArrayListUnmanaged(u8) = .empty;
    errdefer delta.deinit(allocator);
    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    errdefer snapshot.deinit(allocator);

    // snapshot의 screen_meta(현재 커서/모드) — projectSnapshot과 같은 첫 레코드.
    const cur_cursor = screen_stream.Cursor{ .col = snap.cursor.col, .row = snap.cursor.row, .visible = snap.cursor.visible, .shape = @intFromEnum(snap.cursor_shape) };
    {
        const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = opts.generation }, .{
            .cols = snap.size.cols,
            .rows = snap.size.rows,
            .active_screen = cur_active,
            .cursor = cur_cursor,
            .modes = cur_modes,
            .scrollback_len = @intCast(@min(core.scrollbackLen(), std.math.maxInt(u32))),
            .view_offset = @intCast(@min(core.viewOffset(), std.math.maxInt(u32))),
        });
        defer allocator.free(meta_rec);
        try appendProjectedRecord(&snapshot, allocator, meta_rec);
    }

    // 각 행을 **한 번만** build해서 (a) snapshot의 row 레코드로 담고 (b) prev와 다르면 delta의 set_runs로 담는다(재투영 제거).
    var row: u16 = 0;
    while (row < snap.size.rows) : (row += 1) {
        const rr = try buildRowRuns(allocator, snap, palette, row);
        defer rr.deinit(allocator);
        const row_rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = opts.generation }, .{ .row_index = row, .runs = rr.runs });
        defer allocator.free(row_rec);
        try appendProjectedRecord(&snapshot, allocator, row_rec);

        const prev = prev_rows[row] orelse &[_]Run{};
        if (!runsEqual(rr.runs, prev)) {
            const rec = try screen_stream.encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = opts.generation }, .{ .base_generation = opts.generation, .row_index = row, .start_col = 0, .runs = rr.runs });
            defer allocator.free(rec);
            try appendProjectedRecord(&delta, allocator, rec);
        }
    }

    // 이미지: snapshot(base)엔 현재 전체를 싣고(projectSnapshot과 동형 — 재접속/resync가 이 base로 이미지 복원), delta엔
    // client가 없는 것만 싣는다(#1 I4b). blob은 prev generation과 다른 이미지만, placement는 집합이 바뀌었을 때 clear+set.
    for (snap.images) |img| try appendImageBaseMeta(allocator, &snapshot, opts.generation, img); // 리뷰 #11: base엔 픽셀 없이 메타만.
    for (snap.placements) |p| try appendImagePlacementRecord(allocator, &snapshot, opts.generation, p);
    for (snap.images) |img| {
        const have = if (prev_image_gens.get(img.image_id)) |g| g == img.generation else false;
        if (!have) try appendImageBlobRecords(allocator, &delta, opts.generation, img); // client가 없는/바뀐 이미지만.
    }
    // 리뷰 #12: prev에 있었으나 현재 없는 이미지 = host storage에서 evict/delete됨 → image_remove로 client도 회수(무한증가 방지).
    {
        var it = prev_image_gens.keyIterator();
        while (it.next()) |prev_id| {
            var present = false;
            for (snap.images) |img| if (img.image_id == prev_id.*) {
                present = true;
                break;
            };
            if (!present) {
                const rec = try screen_stream.encodeImageRemove(allocator, .{ .kind = .image_remove, .generation = opts.generation }, .{ .base_generation = opts.generation, .blob_id = prev_id.* });
                defer allocator.free(rec);
                try appendProjectedRecord(&delta, allocator, rec);
            }
        }
    }
    if (placementsChanged(prev_placements.items, snap.placements)) {
        try appendImagePlaceDelta(allocator, &delta, opts.generation, snap.placements);
    }
    // prompt_marks: snapshot(base)엔 있을 때만, delta엔 바뀌었을 때만(clear 전달 위해 skip_if_none=false로 full-replace).
    try appendPromptMarks(allocator, &snapshot, opts.generation, snap, true);
    if (promptMarksChanged(prev_pm, snap.prompt_marks)) {
        try appendPromptMarks(allocator, &delta, opts.generation, snap, false);
    }
    // link_spans: prompt_marks와 같은 규율(base엔 있을 때만, delta엔 바뀌었을 때만 full-replace). 링크가 사라진
    // 전이(있음→없음)도 delta로 보내야 client의 stale 밑줄이 남지 않으므로 skip_if_none=false다.
    var links: std.ArrayList(terminal.ViewportLink) = .empty;
    defer links.deinit(allocator);
    core.collectViewportLinks(allocator, terminal.link_scopes_full, &links) catch return error.OutOfMemory;
    try appendLinkSpans(allocator, &snapshot, opts.generation, links.items, true);
    if (linkSpansChanged(prev_ls, links.items)) {
        try appendLinkSpans(allocator, &delta, opts.generation, links.items, false);
    }

    // 커서/모드 변화 → delta.
    if (!cursorsEqual(cur_cursor, prev_meta.cursor)) {
        const rec = try screen_stream.encodeCursor(allocator, .{ .kind = .cursor, .generation = opts.generation }, .{ .base_generation = opts.generation, .cursor = cur_cursor });
        defer allocator.free(rec);
        try appendProjectedRecord(&delta, allocator, rec);
    }
    // 스크롤 상태: snapshot(base)엔 screen_meta로 이미 실렸고, delta엔 **바뀌었을 때만** 별도 record로 보낸다.
    // 이게 없으면 스크롤만 한 프레임에서 client 값이 stale이라 스크롤바가 화면과 어긋난다(재동기화 전까지).
    {
        const cur_sb: u32 = @intCast(@min(core.scrollbackLen(), std.math.maxInt(u32)));
        const cur_vo: u32 = @intCast(@min(core.viewOffset(), std.math.maxInt(u32)));
        if (cur_sb != prev_meta.scrollback_len or cur_vo != prev_meta.view_offset) {
            const rec = try screen_stream.encodeScrollState(allocator, .{ .kind = .scroll_state, .generation = opts.generation }, .{
                .base_generation = opts.generation,
                .scrollback_len = cur_sb,
                .view_offset = cur_vo,
            });
            defer allocator.free(rec);
            try appendProjectedRecord(&delta, allocator, rec);
        }
    }
    if (cur_modes != prev_meta.modes) {
        const rec = try screen_stream.encodeModes(allocator, .{ .kind = .modes, .generation = opts.generation }, .{ .base_generation = opts.generation, .modes = cur_modes });
        defer allocator.free(rec);
        try appendProjectedRecord(&delta, allocator, rec);
    }

    const delta_owned = delta.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(delta_owned);
    const snapshot_owned = snapshot.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(snapshot_owned);
    try stampRecordSequence(delta_owned, opts.sequence);
    try stampRecordSequence(snapshot_owned, opts.sequence);
    return .{ .delta = delta_owned, .snapshot = snapshot_owned };
}

/// 셀의 표시 grapheme을 UTF-8로 만든다(base codepoint + grapheme_store cluster 본체). 빈 셀(codepoint 0)은 공백.
fn encodeCellGrapheme(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cell: terminal.Cell, graphemes: []const []const u21) screen_stream.DecodeError!void {
    cur.clearRetainingCapacity();
    const base_cp: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
    try appendUtf8(cur, allocator, base_cp);
    if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
        for (graphemes[cell.grapheme_id - 1]) |extra| try appendUtf8(cur, allocator, extra);
    }
}

fn appendUtf8(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cp: u21) screen_stream.DecodeError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        cur.appendSlice(allocator, "\u{FFFD}") catch return error.OutOfMemory; // surrogate 등 잘못된 코드포인트 → U+FFFD
        return;
    };
    cur.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
}

/// terminal 색을 Run wire의 **태그드 u32 Color intent**로 싣는다(§screen_stream.ColorTag). host는 색을 굽지 않고 의도를
/// 실어 client가 자기 theme로 해석하게 한다(config 16색 base·bold-is-bright·min-contrast·default 색 — in-process와 동일).
/// 예외: `.indexed`에 OSC4 override(`palette[n]`)가 있으면 그 rgb로 구워 실는다 — override는 host per-terminal 상태라
/// client가 못 가지므로, 굽지 않으면 회귀한다(그 셀은 bold-is-bright/config-base 적용 대상에서 빠지지만 OSC4 원색은 보존).
fn packColorIntent(c: terminal.Color, palette: *const [256]?terminal.Rgb) u32 {
    const Tag = screen_stream.ColorTag;
    return switch (c) {
        .default => Tag.default << Tag.shift, // == 0
        .rgb => |v| (Tag.rgb << Tag.shift) | packRgb(v),
        .indexed => |n| if (palette[n]) |ov|
            (Tag.rgb << Tag.shift) | packRgb(ov)
        else
            (Tag.indexed << Tag.shift) | @as(u32, n),
    };
}

fn packRgb(v: terminal.Rgb) u32 {
    return (@as(u32, v.r) << 16) | (@as(u32, v.g) << 8) | @as(u32, v.b);
}

/// core `Style`을 `screen_stream.StyleFlags` 비트로 옮긴다. reverse→inverse, conceal→invisible. (core Style엔 curly
/// underline이 없어 그 비트는 안 켠다.)
fn styleFlags(s: terminal.Style) u32 {
    const SF = screen_stream.StyleFlags;
    var f: u32 = 0;
    if (s.bold) f |= SF.bold;
    if (s.dim) f |= SF.dim;
    if (s.italic) f |= SF.italic;
    if (s.underline) f |= SF.underline;
    if (s.underline_double) f |= SF.underline_double;
    if (s.blink) f |= SF.blink;
    if (s.reverse) f |= SF.inverse;
    if (s.conceal) f |= SF.invisible;
    if (s.strikethrough) f |= SF.strikethrough;
    if (s.overline) f |= SF.overline;
    return f;
}

// ─────────────────────────────────────────────────────────────────────────────
// 투영 단위 테스트 (실 TerminalCore)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속·`maru attach`는 host의 화면을 client가 **똑같이**
// 재구성할 수 있어야 성립한다(§8 — raw PTY를 중간부터 못 주므로 versioned snapshot을 투영한다). 실제 ANSI를 먹인
// TerminalCore를 snapshot 레코드로 투영하고 다시 decode해, 텍스트·resolved 색·wide cell·커서·mode가 원본 화면과
// 일치하는지 고정한다. 순수 투영이라 실 PTY 없이 core만으로 macOS에서 검증한다(barrel이 non-macOS에서 제외).
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 투영 스트림을 decode해 (meta, rows)로 되돌리는 테스트 helper. rows[i]는 row_index i의 runs다(caller가 deinit).
const Decoded = struct {
    meta: screen_stream.ScreenMeta,
    rows: []screen_stream.Row,

    fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        for (self.rows) |r| r.deinit(allocator);
        allocator.free(self.rows);
    }
};

fn decodeSnapshot(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    const first = (try rs.next()).?;
    const fs = try screen_stream.RecordStream.split(first);
    try testing.expectEqual(screen_stream.RecordKind.screen_meta, fs.header.kind);
    const meta = try screen_stream.decodeScreenMeta(fs.body);

    var rows: std.ArrayListUnmanaged(screen_stream.Row) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        try testing.expectEqual(screen_stream.RecordKind.row, s.header.kind);
        const dr = try screen_stream.decodeRow(allocator, s.body);
        try rows.append(allocator, dr);
    }
    return .{ .meta = meta, .rows = try rows.toOwnedSlice(allocator) };
}

test "screen snapshot: projects a real TerminalCore screen to decodable records (text, color, cursor)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();

    // 빨간 전경으로 "hi", 커서는 그 뒤.
    try core.write("\x1b[31mhi\x1b[0m");

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 7 });
    defer allocator.free(bytes);

    const dec = try decodeSnapshot(allocator, bytes);
    defer dec.deinit(allocator);

    // meta: 크기·generation·커서 col(2, "hi" 뒤).
    try testing.expectEqual(@as(u16, 10), dec.meta.cols);
    try testing.expectEqual(@as(u16, 3), dec.meta.rows);
    try testing.expectEqual(@as(usize, 3), dec.rows.len);
    try testing.expectEqual(@as(u16, 2), dec.meta.cursor.col);

    // row 0: 첫 run "h"는 빨강(SGR 31 → indexed 1). host는 굽지 않고 intent를 실으므로 태그드 u32 = ColorTag.indexed|1.
    const Tag = screen_stream.ColorTag;
    const row0 = dec.rows[0];
    try testing.expect(screen_stream.rowWidthMatches(row0, 10));
    try testing.expectEqualStrings("h", row0.runs[0].grapheme);
    try testing.expectEqual((Tag.indexed << Tag.shift) | 1, row0.runs[0].fg); // 빨강 = indexed 1 intent.
    // 마지막 run은 공백(default fg/bg → ColorTag.default = 0)이고 RLE로 뭉쳐 있다. client가 자기 theme 기본색으로 푼다.
    const last = row0.runs[row0.runs.len - 1];
    try testing.expectEqualStrings(" ", last.grapheme);
    try testing.expectEqual(@as(u32, 0), last.fg);
    try testing.expectEqual(@as(u32, 0), last.bg);
    // 빈 행(row 1,2)은 공백 한 run(count=cols)으로 압축된다.
    try testing.expectEqual(@as(usize, 1), dec.rows[1].runs.len);
    try testing.expectEqual(@as(u32, 10), dec.rows[1].runs[0].count);
}

test "packColorIntent: default/indexed/rgb intent + OSC4 override는 rgb로 굽는다" {
    const Tag = screen_stream.ColorTag;
    var palette = [_]?terminal.Rgb{null} ** 256;

    // default → 태그만(0). indexed(override 없음) → 인덱스 intent 유지(client가 config 16색·bold-is-bright 적용). rgb → 그대로.
    try testing.expectEqual(@as(u32, 0), packColorIntent(.default, &palette));
    try testing.expectEqual((Tag.indexed << Tag.shift) | 5, packColorIntent(.{ .indexed = 5 }, &palette));
    try testing.expectEqual((Tag.rgb << Tag.shift) | 0x123456, packColorIntent(.{ .rgb = .{ .r = 0x12, .g = 0x34, .b = 0x56 } }, &palette));

    // OSC4 override된 indexed는 그 rgb로 구워 싣는다(회귀 방지) — override는 client가 못 가지는 host per-terminal 상태.
    palette[3] = .{ .r = 0xAB, .g = 0xCD, .b = 0xEF };
    try testing.expectEqual((Tag.rgb << Tag.shift) | 0xABCDEF, packColorIntent(.{ .indexed = 3 }, &palette));
}

test "screen snapshot: wide CJK cell projects width=2 and skips the continuation cell" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();
    try core.write("한A"); // 한=wide(2셀), A=narrow(1셀) → 3 cell 소비, 3칸 공백.

    const bytes = try projectSnapshot(allocator, &core, .{});
    defer allocator.free(bytes);
    const dec = try decodeSnapshot(allocator, bytes);
    defer dec.deinit(allocator);

    const row = dec.rows[0];
    try testing.expect(screen_stream.rowWidthMatches(row, 6)); // Σ(width*count)=6 — 연속 검증 통과.
    try testing.expectEqualStrings("한", row.runs[0].grapheme);
    try testing.expectEqual(@as(u8, 2), row.runs[0].width); // wide는 width=2, continuation은 run으로 안 나온다.
    try testing.expectEqualStrings("A", row.runs[1].grapheme);
    try testing.expectEqual(@as(u8, 1), row.runs[1].width);
}

test "screen snapshot: kitty image projects image_blob(디코드 픽셀) + image_placement" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    // 2x2 RGBA 이미지 transmit+display(a=T, i=7) — renderSnapshot에 image(id 7, 16B) + placement 하나가 생긴다.
    var raw = [_]u8{0} ** 16; // 2*2*4
    raw[0] = 0xAB;
    raw[15] = 0xCD;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [96]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=7;{s}\x1b\\", .{b64s}));

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 3 });
    defer allocator.free(bytes);

    // 스트림을 훑어 image_blob(디코드 픽셀 왕복)과 image_placement가 실렸는지 본다.
    var found_blob = false;
    var found_placement = false;
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        switch (s.header.kind) {
            .image_blob => {
                const blob = try screen_stream.decodeImageBlob(s.body);
                try testing.expectEqual(@as(u32, 7), blob.image_id);
                try testing.expectEqual(@as(u32, 2), blob.width);
                try testing.expectEqual(@as(u32, 2), blob.height);
                try testing.expectEqual(@as(u8, 4), blob.bpp);
                try testing.expectEqual(@as(usize, 16), blob.pixels.len);
                try testing.expectEqual(@as(u8, 0xAB), blob.pixels[0]);
                try testing.expectEqual(@as(u8, 0xCD), blob.pixels[15]);
                found_blob = true;
            },
            .image_placement => {
                const p = try screen_stream.decodeImagePlacement(s.body);
                try testing.expectEqual(@as(u32, 7), p.image_id);
                found_placement = true;
            },
            else => {},
        }
    }
    try testing.expect(found_blob);
    try testing.expect(found_placement);
}

test "screen snapshot: style flags and alt-screen/modes are captured" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // bold+underline "B", 그리고 bracketed paste 모드 on(DECSET 2004), 대체 화면 전환(1049).
    try core.write("\x1b[1;4mB\x1b[0m");
    try core.write("\x1b[?2004h");

    // 대체 화면 전 modes/flag 확인.
    {
        const bytes = try projectSnapshot(allocator, &core, .{});
        defer allocator.free(bytes);
        const dec = try decodeSnapshot(allocator, bytes);
        defer dec.deinit(allocator);
        const SF = screen_stream.StyleFlags;
        const r0 = dec.rows[0].runs[0];
        try testing.expect((r0.style_flags & SF.bold) != 0 and (r0.style_flags & SF.underline) != 0);
        try testing.expect((dec.meta.modes & ModeBit.bracketed_paste) != 0);
        try testing.expectEqual(@as(u8, 0), dec.meta.active_screen); // 아직 primary.
    }

    try core.write("\x1b[?1049h"); // 대체 화면 진입.
    {
        const bytes = try projectSnapshot(allocator, &core, .{});
        defer allocator.free(bytes);
        const dec = try decodeSnapshot(allocator, bytes);
        defer dec.deinit(allocator);
        try testing.expectEqual(@as(u8, 1), dec.meta.active_screen); // alternate.
    }
}

test "screen snapshot: computeDelta emits set_runs for changed rows and a cursor delta" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    try core.write("hi"); // row0="hi", cursor (row0,col2).
    const a = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(a);

    try core.write("\r\nworld"); // row1="world", cursor (row1,col5). row0은 그대로.
    const result = try computeDelta(allocator, a, &core, .{ .generation = 1 });
    defer result.deinit(allocator);
    const delta = result.delta;
    try testing.expect(delta.len > 0);

    var rs = screen_stream.RecordStream{ .bytes = delta };
    var saw_row0 = false;
    var saw_row1 = false;
    var saw_cursor = false;
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        switch (s.header.kind) {
            .set_runs => {
                const sr = try screen_stream.decodeSetRuns(allocator, s.body);
                defer sr.deinit(allocator);
                if (sr.row_index == 0) saw_row0 = true;
                if (sr.row_index == 1) {
                    saw_row1 = true;
                    try testing.expectEqual(@as(u16, 0), sr.start_col); // 전체 행 교체.
                    try testing.expectEqualStrings("w", sr.runs[0].grapheme);
                }
            },
            .cursor => {
                const cd = try screen_stream.decodeCursor(s.body);
                saw_cursor = true;
                try testing.expectEqual(@as(u16, 1), cd.cursor.row);
                try testing.expectEqual(@as(u16, 5), cd.cursor.col);
            },
            else => {},
        }
    }
    try testing.expect(saw_row1 and saw_cursor);
    try testing.expect(!saw_row0); // row0은 안 바뀌어 set_runs를 내지 않는다(증분만).
}

test "screen snapshot: computeDelta is empty when the screen is unchanged" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("abc");
    const a = try projectSnapshot(allocator, &core, .{ .generation = 3 });
    defer allocator.free(a);
    const result = try computeDelta(allocator, a, &core, .{ .generation = 3 });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), result.delta.len); // 변화 없음 → 빈 delta(caller는 아무것도 안 보낸다).
}

test "screen snapshot: computeDelta requires a fresh snapshot when the grid geometry changes" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("resize me");
    const a = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(a);

    try core.resize(20, 5); // grid가 바뀌면 delta로는 못 잇는다.
    try testing.expectError(error.SnapshotRequired, computeDelta(allocator, a, &core, .{ .generation = 2 }));
}

test "screen snapshot: projection and assembler are inverses on a real screen (snapshot + delta round-trip)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[32mgreen\x1b[0m"); // row0 = 초록 "green".

    // project → assemble → re-serialize == projection(조립기가 화면을 무손실 재구성).
    const p = try projectSnapshot(allocator, &core, .{ .generation = 4 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    {
        const re = try asm_.toSnapshot(allocator);
        defer allocator.free(re);
        try testing.expectEqualSlices(u8, p, re);
    }

    // 화면을 바꾸고 delta를 계산해 조립기에 적용하면, 새 projection과 같아진다(증분 재구성).
    try core.write("\r\nsecond"); // row1 = "second", 커서 이동.
    const result = try computeDelta(allocator, p, &core, .{ .generation = 4 });
    defer result.deinit(allocator);
    try testing.expect(result.delta.len > 0);
    try asm_.applyDelta(result.delta);

    const p2 = try projectSnapshot(allocator, &core, .{ .generation = 4 });
    defer allocator.free(p2);
    const re2 = try asm_.toSnapshot(allocator);
    defer allocator.free(re2);
    try testing.expectEqualSlices(u8, p2, re2); // delta 적용 후 조립기 == 새 화면 projection.
    try testing.expectEqualSlices(u8, p2, result.snapshot); // computeDelta의 snapshot == 별도 projection(#6: 한 번 build 재사용).
}

test "CR4a frontier는 snapshot zero 뒤 exact contiguous delta만 화면에 적용한다" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("A");

    const base = try projectSnapshot(allocator, &core, .{ .generation = 7, .sequence = 0 });
    defer allocator.free(base);
    var assembler = screen_assembler.ScreenAssembler.init(allocator);
    defer assembler.deinit();
    assembler.requireSequencedDeltas();
    try assembler.applySnapshot(base);
    try testing.expectEqual(@as(u64, 0), assembler.sequence);

    try core.write("B");
    const legacy_zero = try computeDelta(allocator, base, &core, .{ .generation = 7, .sequence = 0 });
    defer legacy_zero.deinit(allocator);
    try testing.expect(legacy_zero.delta.len != 0);
    try testing.expectError(error.GenerationGap, assembler.applyDelta(legacy_zero.delta));

    const next = try computeDelta(allocator, base, &core, .{ .generation = 7, .sequence = 1 });
    defer next.deinit(allocator);
    var records = screen_stream.RecordStream{ .bytes = next.delta };
    while (try records.next()) |record| {
        const split = try screen_stream.RecordStream.split(record);
        try testing.expectEqual(@as(u64, 1), split.header.sequence);
    }
    var snapshot_records = screen_stream.RecordStream{ .bytes = next.snapshot };
    while (try snapshot_records.next()) |record| {
        const split = try screen_stream.RecordStream.split(record);
        try testing.expectEqual(@as(u64, 1), split.header.sequence);
    }
    try assembler.applyDelta(next.delta);
    try testing.expectEqual(@as(u64, 1), assembler.sequence);

    const before_replay = try assembler.toSnapshot(allocator);
    defer allocator.free(before_replay);
    try testing.expectError(error.GenerationGap, assembler.applyDelta(next.delta));
    const after_replay = try assembler.toSnapshot(allocator);
    defer allocator.free(after_replay);
    try testing.expectEqualSlices(u8, before_replay, after_replay);
    try testing.expectError(error.GenerationGap, assembler.applySnapshot(base));
    const after_stale_snapshot = try assembler.toSnapshot(allocator);
    defer allocator.free(after_stale_snapshot);
    try testing.expectEqualSlices(u8, before_replay, after_stale_snapshot);

    const mixed = try allocator.dupe(u8, base);
    defer allocator.free(mixed);
    const first_len: usize = std.mem.readInt(u32, mixed[0..4], .big);
    const second_record = 4 + first_len + 4;
    try testing.expect(second_record + screen_stream.record_header_size <= mixed.len);
    std.mem.writeInt(u64, mixed[second_record + 12 ..][0..8], 9, .big);
    try testing.expectError(error.GenerationGap, assembler.applySnapshot(mixed));
    const after_mixed_snapshot = try assembler.toSnapshot(allocator);
    defer allocator.free(after_mixed_snapshot);
    try testing.expectEqualSlices(u8, before_replay, after_mixed_snapshot);

    var prepared_recovery = screen_assembler.ScreenAssembler.init(allocator);
    defer prepared_recovery.deinit();
    prepared_recovery.prepareRecoveryFrontierFrom(&assembler);
    const recovery = try projectSnapshot(allocator, &core, .{ .generation = 7, .sequence = 2 });
    defer allocator.free(recovery);
    try prepared_recovery.applySnapshot(recovery);
    std.mem.swap(screen_assembler.ScreenAssembler, &assembler, &prepared_recovery);
    try testing.expectEqual(@as(u64, 2), assembler.sequence);

    try core.write("C");
    const downgrade_after_recovery = try computeDelta(
        allocator,
        recovery,
        &core,
        .{ .generation = 7, .sequence = 0 },
    );
    defer downgrade_after_recovery.deinit(allocator);
    try testing.expect(downgrade_after_recovery.delta.len != 0);
    try testing.expectError(error.GenerationGap, assembler.applyDelta(downgrade_after_recovery.delta));
    try testing.expectEqual(@as(u64, 2), assembler.sequence);
}

test "screen snapshot: computeDelta emits image_blob + image_place when an image is transmitted (I4b)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();

    // base(이미지 없음).
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);

    // 2x2 이미지 transmit+display(i=3).
    var raw = [_]u8{0} ** 16;
    raw[0] = 0x7A;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [96]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=3;{s}\x1b\\", .{b64s}));

    const result = try computeDelta(allocator, base, &core, .{ .generation = 1 });
    defer result.deinit(allocator);

    // delta: image_blob(id 3) + image_place clear 센티넬(id 0) + image_place(id 3).
    var found_blob = false;
    var found_clear = false;
    var found_place = false;
    var rs = screen_stream.RecordStream{ .bytes = result.delta };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        switch (s.header.kind) {
            .image_blob => {
                if ((try screen_stream.decodeImageBlob(s.body)).image_id == 3) found_blob = true;
            },
            .image_place => {
                const p = try screen_stream.decodeImagePlacement(s.body);
                if (p.image_id == 0) found_clear = true else if (p.image_id == 3) found_place = true;
            },
            else => {},
        }
    }
    try testing.expect(found_blob);
    try testing.expect(found_clear);
    try testing.expect(found_place);

    // 같은 이미지가 그대로면(재계산) blob은 이미 client가 가졌으니 delta에 다시 안 실린다(dedup).
    const base2 = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base2);
    const result2 = try computeDelta(allocator, base2, &core, .{ .generation = 1 });
    defer result2.deinit(allocator);
    var blob_again = false;
    var rs2 = screen_stream.RecordStream{ .bytes = result2.delta };
    while (try rs2.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind == .image_blob) blob_again = true;
    }
    try testing.expect(!blob_again); // 변화 없으니 blob 재송 안 함.
}

test "screen snapshot: computeDelta emits prompt_marks when an OSC 133 mark appears" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 }); // 마크 없음.
    defer allocator.free(base);

    try core.write("\x1b]133;A\x1b\\$ "); // OSC 133 A: prompt 마크 생성.
    const result = try computeDelta(allocator, base, &core, .{ .generation = 1 });
    defer result.deinit(allocator);

    var found = false;
    var rs = screen_stream.RecordStream{ .bytes = result.delta };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind == .prompt_marks) found = true;
    }
    try testing.expect(found); // 마크가 생겼으니 delta에 prompt_marks record가 실린다.
}

// 스크롤바는 스크롤 상태(스크롤백 길이·view offset)로 thumb을 그리는데, screen_meta는 **snapshot에만** 실린다.
// 그래서 스크롤만 바뀐 프레임에서는 client 값이 stale로 남아 스크롤바가 안 뜨거나 위치가 화면과 어긋났다
// (재동기화가 일어나야 겨우 맞았다 — 사용자 보고: "처음엔 안 나오다 vim 갔다 오니 보이는데 위치가 안 맞음").
test "screen snapshot: computeDelta emits scroll_state when scrollback or view offset changes" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    try core.write("a\r\nb\r\nc\r\n");
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);

    // 변화 없음 → scroll_state 없음(무의미한 재전송 방지).
    {
        const same = try computeDelta(allocator, base, &core, .{ .generation = 1 });
        defer same.deinit(allocator);
        try testing.expect(!try hasRecordKind(same.delta, .scroll_state));
    }

    // 출력으로 스크롤백이 늘면 delta에 실린다.
    try core.write("d\r\ne\r\nf\r\n");
    const grown = try computeDelta(allocator, base, &core, .{ .generation = 1 });
    defer grown.deinit(allocator);
    try testing.expect(try hasRecordKind(grown.delta, .scroll_state));

    // 위로 스크롤하면 view_offset 변화도 실린다 — thumb 위치 동기화의 근거.
    core.scrollViewport(2);
    const scrolled = try computeDelta(allocator, grown.snapshot, &core, .{ .generation = 1 });
    defer scrolled.deinit(allocator);
    var seen_offset: ?u32 = null;
    var rs = screen_stream.RecordStream{ .bytes = scrolled.delta };
    while (try rs.next()) |rec| {
        const sp = try screen_stream.RecordStream.split(rec);
        if (sp.header.kind != .scroll_state) continue;
        seen_offset = (try screen_stream.decodeScrollState(sp.body)).view_offset;
    }
    try testing.expectEqual(@as(u32, 2), seen_offset orelse return error.TestUnexpectedResult);
}

// host가 링크를 해석해 싣지 않으면 원격 client는 Cmd+hover 밑줄을 그릴 근거가 전혀 없다(client core는 빈
// placeholder). snapshot이 화면 링크를 좌표·종류·scope와 함께 싣는지, 링크가 없으면 record를 생략하는지 고정한다.
test "screen snapshot: projects viewport links with kind and scope" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 3 });
    defer core.deinit();

    // 링크가 없으면 record 자체를 내지 않는다(common case 무비용 — prompt_marks와 같은 규율).
    {
        const bare = try projectSnapshot(allocator, &core, .{ .generation = 1 });
        defer allocator.free(bare);
        try testing.expect(!try hasRecordKind(bare, .link_spans));
    }

    try core.write("go https://example.com/page now");
    const snapshot = try projectSnapshot(allocator, &core, .{ .generation = 2 });
    defer allocator.free(snapshot);

    var seen: ?screen_stream.LinkSpans = null;
    defer if (seen) |s| s.deinit(allocator);
    var rs = screen_stream.RecordStream{ .bytes = snapshot };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind == .link_spans) seen = try screen_stream.decodeLinkSpans(allocator, s.body);
    }
    const ls = seen orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), ls.spans.len);
    try testing.expectEqual(@as(u16, 0), ls.spans[0].start_row);
    try testing.expectEqual(@as(u16, 3), ls.spans[0].start_col); // "go " 다음부터 밑줄
    try testing.expectEqual(@as(u16, 26), ls.spans[0].end_col);
    try testing.expectEqual(@as(u8, 0), ls.spans[0].kind); // url
    try testing.expectEqual(@as(u8, 0), ls.spans[0].scope); // web
}

// 링크가 생기거나 사라지면 client의 밑줄이 따라가야 한다. 생겼을 때 delta가 나가는지, **사라졌을 때도**
// 빈 full-replace가 나가는지 고정한다 — 후자가 없으면 client에 stale 밑줄이 남는다.
test "screen snapshot: computeDelta emits link_spans when links appear and when they disappear" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 3 });
    defer core.deinit();
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 }); // 링크 없음.
    defer allocator.free(base);

    try core.write("see https://example.com/a here");
    const appeared = try computeDelta(allocator, base, &core, .{ .generation = 1 });
    defer appeared.deinit(allocator);
    try testing.expect(try hasRecordKind(appeared.delta, .link_spans));

    // 변화가 없으면 delta에 다시 싣지 않는다(무의미한 재전송 방지).
    const same = try computeDelta(allocator, appeared.snapshot, &core, .{ .generation = 1 });
    defer same.deinit(allocator);
    try testing.expect(!try hasRecordKind(same.delta, .link_spans));

    // 화면을 지우면 링크가 사라진다 → 빈 목록 full-replace가 delta로 나가야 client가 밑줄을 거둔다.
    try core.write("\x1b[2J\x1b[H");
    const gone = try computeDelta(allocator, appeared.snapshot, &core, .{ .generation = 1 });
    defer gone.deinit(allocator);
    var cleared = false;
    var rs = screen_stream.RecordStream{ .bytes = gone.delta };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind != .link_spans) continue;
        const ls = try screen_stream.decodeLinkSpans(allocator, s.body);
        defer ls.deinit(allocator);
        cleared = ls.spans.len == 0;
    }
    try testing.expect(cleared);
}

/// 레코드 스트림에 특정 kind가 있는지 — 링크 테스트들이 공유하는 작은 헬퍼.
fn hasRecordKind(bytes: []const u8, kind: screen_stream.RecordKind) !bool {
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind == kind) return true;
    }
    return false;
}

test "bounded projector uses a transparent exact allocation ceiling" {
    const allocator = std.testing.allocator;
    var cap = AllocationCap{ .parent = allocator, .max = 64 };
    const capped = cap.allocator();
    const exact_allocation = try capped.alloc(u8, 64);
    allocator.free(exact_allocation);
    try std.testing.expectError(error.OutOfMemory, capped.alloc(u8, 65));

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("ABCD");
    const expected = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(expected);

    const exact = try projectSnapshotBounded(
        allocator,
        &core,
        .{ .generation = 1 },
        screen_stream.max_record_stream_bytes,
    );
    defer allocator.free(exact);
    try std.testing.expectEqualSlices(u8, expected, exact);
}
