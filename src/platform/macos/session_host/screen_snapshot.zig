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
const screen_stream = @import("maru").session.screen_stream;
const screen_assembler = @import("maru").session.screen_assembler;

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
    /// **이미지 blob 이 이 투영에서 몇 바이트를 차지했는지** 적어 둘 자리(선택, 계측 전용).
    ///
    /// 왜 여기냐 — 스트림을 나중에 다시 훑어 세면 방출과 계측이 **두 번 순회**가 되고, 레코드
    /// 모양이 바뀔 때 한쪽만 따라가 조용히 어긋난다. 방출하는 그 자리에서 더한다.
    /// `null` 이면 아무 일도 안 한다(기본).
    image_bytes_out: ?*u64 = null,
};

/// Projection-only bounded builder. It keeps amortized growth, but clamps the next capacity to the
/// codec ceiling instead of asking the allocator for a geometric capacity above it. This avoids
/// both near-cap O(N²) exact reallocations and unconditional 16 MiB preallocation on small deltas.
/// 투영이 낼 수 있는 오류. `DecodeError` 에 **상한 초과**를 더한다.
///
/// 2026-09-14 실측: 런타임 하나가 attach 를 못 해 세션 19 개가 전부 안 붙었다. host 는
/// `err=OutOfMemory` 를 남겼지만 계측을 넣어 보니 `refused=0 parent_fail=0 peak=1 MB` —
/// **할당은 하나도 실패하지 않았다.** 아래 상한 검사가 할당자를 거치기도 전에
/// `OutOfMemory` 를 직접 돌려주고 있었고, 그 거짓 이름 때문에 host 가 「자원이 없다」로 읽어
/// **공유 연결 전체**를 끊었다. 이름을 갈라 「그 화면이 크다」로 말하게 한다.
pub const ProjectError = screen_stream.DecodeError || error{SnapshotTooLarge};

fn appendProjectedRecord(
    stream: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    record: []const u8,
) ProjectError!void {
    if (record.len > std.math.maxInt(u32)) return error.LengthOverflow;
    const total = std.math.add(usize, stream.items.len, 4 + record.len) catch
        return error.LengthOverflow;
    // **할당 실패가 아니다.** 레코드 하나가(대개 이미지 픽셀 블롭) 스트림 상한을 넘은 것이다.
    if (total > screen_stream.max_record_stream_bytes) return error.SnapshotTooLarge;
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
    /// **상한이 거절했는가.** allocator vtable 은 `null`(또는 `false`) 하나만 돌려줄 수 있어,
    /// 호출자에게는 「상한 초과」와 「진짜 메모리 부족」이 똑같은 `error.OutOfMemory` 로 보인다.
    ///
    /// 2026-09-14 실측: host 가 `site=attach_snapshot err=OutOfMemory` 로 연결을 끊었는데
    /// 시스템 여유 메모리는 51%, host RSS 는 93 MB 였다. 진짜 부족이 아니라 **화면 하나가
    /// 16 MiB 상한을 넘은 것**이었고, 그 뭉개짐 때문에 그 attach 하나가 아니라 **공유 연결
    /// 전체**가 끊겨 세션 19 개가 전부 안 붙었다. 여기 남겨 둘을 가른다.
    refused: bool = false,
    /// **거절당한 요청의 바이트 수.** 오류 이름만으로는 「크다」와 「시스템이 못 준다」가 안 갈린다 —
    /// 2026-09-14 에 그 둘을 소거법으로만 좁히다 세 번 틀렸다. 숫자가 있으면 한 번에 갈린다.
    last_refused_len: usize = 0,
    /// **부모가 거절한 요청의 바이트 수.** 상한이 통과시켰는데도 실패한 크기다. 이 값이 작으면
    /// 시스템 압박이고, 상한에 가까우면 그 화면이 실제로 큰 것이다.
    last_parent_fail_len: usize = 0,
    /// 성공한 요청 중 가장 큰 것. 실패 직전까지 얼마나 자랐는지 보여 준다.
    peak_len: usize = 0,

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
        if (len > self.max) {
            self.refused = true;
            self.last_refused_len = len;
            return null;
        }
        const got = self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
        if (got == null) self.last_parent_fail_len = len else if (len > self.peak_len) {
            self.peak_len = len;
        }
        return got;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) {
            self.refused = true;
            self.last_refused_len = new_len;
            return false;
        }
        const ok = self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
        // **제자리 성장도 «큰 크기» 다.** 이것을 안 세면 버퍼가 `remap` 으로 16 MiB 까지 자라도
        // `peak` 은 처음 `alloc` 값에 머문다 — 2026-09-14 에 실제로 1 MB 로 보고돼, 「작은데 왜
        // 상한을 넘지」로 한참 헤맸다. 성장 경로를 빠뜨린 계측은 사람을 틀린 데로 보낸다.
        if (ok and new_len > self.peak_len) self.peak_len = new_len;
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) {
            self.refused = true;
            self.last_refused_len = new_len;
            return null;
        }
        const got = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
        if (got == null) self.last_parent_fail_len = new_len else if (new_len > self.peak_len) {
            self.peak_len = new_len;
        }
        return got;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocationCap = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

/// `projectSnapshotBounded` 가 낼 수 있는 오류. `DecodeError` 에 **상한 초과**를 더한다 —
/// 그 둘은 호출자가 완전히 다르게 다뤄야 한다. 상한 초과는 「이 runtime 의 화면이 크다」라서
/// 그 요청 하나만 typed error 로 거절하면 되고, 진짜 `OutOfMemory` 는 host 자원 문제다.
pub const BoundedProjectError = screen_stream.DecodeError || error{SnapshotTooLarge};

/// Same projection contract with an allocation-time ceiling. The returned slice can be freed with
/// `allocator`, not the adapter, because AllocationCap is transparent.
///
/// **상한이 거절한 실패는 `SnapshotTooLarge` 로 낸다.** 앞 판은 그것을 `OutOfMemory` 로 흘려보냈고,
/// 그래서 attach 가 「메모리가 없다」로 읽혀 공유 연결을 끊었다(2026-09-14).
pub fn projectSnapshotBounded(
    allocator: std.mem.Allocator,
    core: *terminal.TerminalCore,
    opts: ProjectOptions,
    max_allocation: usize,
) BoundedProjectError![]u8 {
    var unused: Diagnostics = .{};
    return projectSnapshotBoundedDiag(allocator, core, opts, max_allocation, &unused);
}

/// 실패가 **얼마나 큰 요청**이었는지 밖으로 내는 판. 호출자가 그 숫자를 로그에 실어야
/// 다음 재현이 「크다」와 「시스템이 못 준다」를 스스로 말한다.
pub const Diagnostics = struct {
    /// 상한이 거절한 바이트(0 = 그런 일 없음).
    refused_len: usize = 0,
    /// 부모 할당자가 거절한 바이트(0 = 그런 일 없음).
    parent_fail_len: usize = 0,
    /// 성공한 요청 중 최대 바이트. 실패 직전까지의 성장 흔적이다.
    peak_len: usize = 0,
};

pub fn projectSnapshotBoundedDiag(
    allocator: std.mem.Allocator,
    core: *terminal.TerminalCore,
    opts: ProjectOptions,
    max_allocation: usize,
    diag: *Diagnostics,
) BoundedProjectError![]u8 {
    var capped = AllocationCap{ .parent = allocator, .max = max_allocation };
    defer diag.* = .{
        .refused_len = capped.last_refused_len,
        .parent_fail_len = capped.last_parent_fail_len,
        .peak_len = capped.peak_len,
    };
    return projectSnapshot(capped.allocator(), core, opts) catch |err| switch (err) {
        // 할당자 쪽 상한이 거절한 경우. 스트림 상한(`appendProjectedRecord`)은 이미
        // `SnapshotTooLarge` 로 와서 아래 `else` 로 그대로 지나간다.
        error.OutOfMemory => if (capped.refused) error.SnapshotTooLarge else error.OutOfMemory,
        else => err,
    };
}

/// 현재 화면을 length-prefixed 레코드 스트림(screen_meta + row*)으로 투영한다(caller 소유 바이트). client는 이 바이트를
/// `screen_stream.RecordStream`으로 순회해 화면을 조립한다. **동시 core 쓰기가 있으면 caller가 core lock을 잡고 부른다.**
/// `renderSnapshot`(뷰포트 인지 — view_offset>0이면 스크롤백 윈도 합성)을 쓴다 = in-process 렌더와 같은 화면(#6a 원격
/// 스크롤백: host가 스크롤 명령을 자기 core에 적용하면 그 뷰포트가 client에 투영된다). core를 mutate(viewport 합성 lazy
/// 할당)하므로 `*`(non-const) — caller가 core lock 아래 부른다(단일 mutator).
pub fn projectSnapshot(allocator: std.mem.Allocator, core: *terminal.TerminalCore, opts: ProjectOptions) ProjectError![]u8 {
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
    var drawable: DrawableImages = .{};
    defer drawable.deinit(allocator);
    try appendVisibleImageBlobs(allocator, &stream, opts.generation, core, snap.images, opts.image_bytes_out, null, &drawable);
    // **픽셀을 안 실은 이미지의 placement 도 안 싣는다**(`DrawableImages` 머리말). 그리지도 못할 자리를
    // 알려 주는 것은 클라이언트에게도, 그것을 세는 계측에게도 거짓이다.
    for (snap.placements) |p| if (drawable.contains(p.image_id))
        try appendImagePlacementRecord(allocator, &stream, opts.generation, p);
    for (snap.virtual_placements) |vp| if (drawable.contains(vp.image_id))
        try appendImageVirtualRecord(allocator, &stream, opts.generation, vp);
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
fn stampRecordSequence(bytes: []u8, sequence: u64) ProjectError!void {
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

/// 이미지 픽셀이 스트림 상한을 다 먹지 못하게 남겨 두는 자리. 이미지 뒤에도 placement·prompt·link
/// 레코드가 붙는데, 이미지가 천장까지 차지하면 **그 화면이 그려질 자리**를 잃는다.
const image_budget_reserve: usize = 256 * 1024;

comptime {
    // 예비분이 상한을 먹으면 **이미지가 조용히 하나도 안 실린다** — 화면은 건너므로 판정자도 초록이고,
    // 「이미지가 안 뜬다」로만 보여 원인을 찾기 어렵다. 상한이 줄어드는 변경에서 여기가 먼저 시끄럽게
    // 죽는다. 4배는 임의가 아니라 「예비분이 예산의 주인공이 되면 안 된다」는 뜻이다.
    if (image_budget_reserve * 4 >= screen_stream.max_record_stream_bytes)
        @compileError("image budget reserve must stay a small fraction of the record stream ceiling");
}

/// 이 이미지가 스트림에서 차지할 바이트(청크 헤더 포함 근사·상계). 청크마다 레코드 헤더와 자기서술
/// 메타가 반복되므로 픽셀 길이만으로는 모자란다 — 넘치게 잡아야 방어선이 뚫리지 않는다.
fn projectedBlobSize(pixels_len: usize) usize {
    const cap = screen_stream.max_image_blob;
    const chunks = if (pixels_len == 0) 1 else (pixels_len + cap - 1) / cap;
    return pixels_len +| chunks *| 128;
}

/// **투영에 실을 이미지를 고른다.** 둘을 거른다.
///
/// ① **화면에 안 보이는 이미지**(placeholder 셀도 placement 도 그 이미지를 가리키지 않는 상태). 코어의
///    이미지 저장 한도는 320 MB 이고 투영 스트림 상한은 16 MiB 다 — **서로를 모르는 두 숫자**라, 코어가
///    「저장해도 된다」고 본 상태를 투영이 통째로 거절할 수 있다. 그러면 이미지만이 아니라 **그 화면
///    전체**가 못 건넌다(attach·resync 가 이 경로다). 클라이언트가 그릴 수 없는 픽셀을 그 예산으로
///    나르는 것은 어느 쪽으로도 이득이 없다.
///
/// ② 보이더라도 **남은 예산을 넘는 이미지**. 한 장이 상한을 넘는 화면(큰 창·고해상도)에서는 ①만으로는
///    여전히 화면이 막힌다. 이미지 때문에 화면 갱신이 멈추면 안 된다 — 이미지를 포기하고 화면을 보낸다.
///    빠진 이미지는 다음 투영에서 `have=false` 로 다시 후보가 된다(delta 경로).
///
/// 실측(2026-09-15): tmux 안 terminal-browser pane 하나가 `s=1003,v=2183` RGBA(프레임당 8.75 MB)를 그려,
/// **두 장째에** `SnapshotTooLarge` 로 그 화면이 통째로 막혔다. 화면에는 이미지 없는 placeholder 셀만
/// 남아 박스 문자로 덮였다(그 박스 자체는 `draw_list` 가 고친 다른 결함이다).
///
/// **알려진 한계**: ②가 걸리는 경계에서 **어느 장이 빠지는지는 결정적이지 않다** — `snap.images` 는
/// 저장소 해시 순서라 프레임마다 같다는 보장이 없다. 「보이는 이미지들의 합이 16 MiB 를 넘는」 화면은
/// 그 자체가 극단이고 그때도 화면은 건너므로 지금은 순서를 정하지 않는다. 이 경계가 실제로 아프면
/// (한 장은 뜨고 한 장은 깜빡이는 화면) 그때 결정적 우선순위를 정한다 — 추측으로 고르지 않는다.
/// **클라이언트가 그릴 수 있는 이미지 id 들.** placement 는 이 목록에 있는 것만 싣는다.
///
/// 픽셀을 안 실은 이미지의 placement 만 보내면 클라이언트는 「그려야 하는데 픽셀이 없는」 상태가 된다.
/// 화면은 그래도 멀쩡하다 — 렌더가 그 quad 를 그릴 수 없으니 넘어간다. **그런데 계측이 못 속는다**:
/// `buildGpuImages` 는 `findImage(...) orelse { recordPlacementWithoutBlob(); continue; }` 를 CPU cull
/// **앞에** 두고(이미지가 없으면 dest 크기를 몰라 cull 을 못 한다), 그 카운터가 「전송이 떨어졌다」를
/// 세는 자리다. 미투영이 거기 섞이면 그 숫자가 **「떨어짐」과 「의도적으로 안 보냄」을 못 가른다**
/// (2026-09-15, `image reconciliation` 계측을 넣은 쪽에서 지적받았다).
///
/// 그래서 픽셀과 placement 를 **같이** 뺀다. 「그릴 수 있는가」가 둘의 단일 기준이다.
const DrawableImages = struct {
    ids: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *DrawableImages, allocator: std.mem.Allocator) void {
        self.ids.deinit(allocator);
    }

    fn add(self: *DrawableImages, allocator: std.mem.Allocator, id: u32) ProjectError!void {
        self.ids.append(allocator, id) catch return error.OutOfMemory;
    }

    /// 이미지 수는 한 자릿수가 보통이라 선형으로 찾는다(해시는 그 크기에서 오히려 느리다).
    fn contains(self: *const DrawableImages, id: u32) bool {
        return std.mem.indexOfScalar(u32, self.ids.items, id) != null;
    }
};

fn appendVisibleImageBlobs(
    allocator: std.mem.Allocator,
    stream: *std.ArrayListUnmanaged(u8),
    generation: u64,
    core: *terminal.TerminalCore,
    images: []const terminal.KittyImageView,
    image_bytes_out: ?*u64,
    already_sent: ?*const std.AutoHashMapUnmanaged(u32, u64),
    drawable: *DrawableImages,
) ProjectError!void {
    for (images) |img| {
        if (already_sent) |sent| {
            if (sent.get(img.image_id)) |g| if (g == img.generation) {
                // **client 가 이미 가진 판.** 픽셀을 안 보내는 이유가 「없어서」가 아니라 「이미 줬으니까」다 —
                // 여기서 placement 까지 빼면 **멀쩡히 뜨던 이미지가 사라진다.** 그릴 수 있는 쪽에 넣는다.
                try drawable.add(allocator, img.image_id);
                continue;
            };
        }
        if (!core.kittyImageVisibleInViewport(img.image_id)) continue; // ① 화면이 안 가리킨다
        const ceiling = screen_stream.max_record_stream_bytes -| image_budget_reserve;
        if (stream.items.len +| projectedBlobSize(img.pixels.len) > ceiling) continue; // ② 예산 밖
        try appendImageBlobRecords(allocator, stream, generation, img, image_bytes_out);
        try drawable.add(allocator, img.image_id);
    }
}

/// 한 이미지의 디코드 픽셀을 per-record cap(≤max_image_blob) 청크로 나눠 image_blob 레코드로 방출한다. 빈 픽셀도 메타
/// 전달용 1개는 낸다. 메타(image_id/generation/w/h/bpp)는 자기서술 위해 매 청크 반복한다(재조립은 소비자 몫, §ImageBlob).
fn appendImageBlobRecords(
    allocator: std.mem.Allocator,
    stream: *std.ArrayListUnmanaged(u8),
    generation: u64,
    img: terminal.KittyImageView,
    image_bytes_out: ?*u64,
) ProjectError!void {
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
        if (image_bytes_out) |out| out.* +|= rec.len;
        off = end;
    }
}

/// computeDelta의 **base(new_base)** 전용 이미지 메타 방출(리뷰 #11): base는 host-side에서 다음 diff의 prev로만 쓰이고(computeDelta가
/// image_id/generation만 읽어 dedup) client로 가지 않으며, resync는 projectSnapshot으로 core에서 재투영한다. 그러므로 base엔
/// **픽셀을 싣지 않는다**(pixel_len=0) — 매 ~20ms tick마다 수 MiB 픽셀을 재인코딩하던 낭비를 없앤다. 픽셀 전달은 delta(변경분)와
/// projectSnapshot(attach/resync)이 맡는다.
fn appendImageBaseMeta(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, img: terminal.KittyImageView) ProjectError!void {
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
fn appendImagePlaceDelta(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, placements: []const terminal.KittyPlacement) ProjectError!void {
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
/// delta용 virtual placement(U=1) 방출. `image_place` 와 같은 규율 — **clear 센티넬(image_id=0)** 뒤에
/// 현재 전체를 싣는다. 집합이 비게 바뀐 경우도 센티넬만으로 표현된다.
///
/// **이게 없으면 attach 이후에 등록된 U=1 격자가 client 에 영영 안 닿는다.** `image_virtual` 은 레코드
/// 정의가 「full-replace 라 snapshot·delta 공용」이라고 선언하는데도 delta 로는 한 번도 나가지 않았고,
/// client 의 `applyDelta` 에도 분기가 없었다. 그 결과 placeholder 셀이 타일 크기를 못 정해 이미지가
/// 아예 안 뜨고 **두부 글리프로** 그려졌다(적대적 검증 7회차, 라이브 실측).
fn appendImageVirtualDelta(
    allocator: std.mem.Allocator,
    stream: *std.ArrayListUnmanaged(u8),
    generation: u64,
    vps: []const terminal.KittyVirtualPlacement,
) ProjectError!void {
    const clear = try screen_stream.encodeImageVirtual(allocator, .{ .kind = .image_virtual, .generation = generation }, .{
        .image_id = 0,
        .placement_id = 0,
        .columns = 0,
        .rows = 0,
        .z = 0,
    });
    defer allocator.free(clear);
    try appendProjectedRecord(stream, allocator, clear);
    for (vps) |vp| try appendImageVirtualRecord(allocator, stream, generation, vp);
}

fn virtualsChanged(prev: []const screen_stream.ImageVirtualPlacement, cur: []const terminal.KittyVirtualPlacement) bool {
    if (prev.len != cur.len) return true;
    for (prev, cur) |a, b| {
        if (a.image_id != b.image_id or a.placement_id != b.placement_id or
            a.columns != b.columns or a.rows != b.rows or a.z != b.z) return true;
    }
    return false;
}

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
fn appendImageVirtualRecord(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, vp: terminal.KittyVirtualPlacement) ProjectError!void {
    const rec = try screen_stream.encodeImageVirtual(allocator, .{ .kind = .image_virtual, .generation = generation }, .{
        .image_id = vp.image_id,
        .placement_id = vp.placement_id,
        .columns = vp.columns,
        .rows = vp.rows,
        .z = vp.z,
    });
    defer allocator.free(rec);
    try appendProjectedRecord(stream, allocator, rec);
}

fn appendImagePlacementRecord(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, p: terminal.KittyPlacement) ProjectError!void {
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
fn appendPromptMarks(allocator: std.mem.Allocator, stream: *std.ArrayListUnmanaged(u8), generation: u64, snap: terminal.RenderSnapshot, skip_if_none: bool) ProjectError!void {
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
) ProjectError!void {
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
) ProjectError!RowRuns {
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
) ProjectError!void {
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

pub const DeltaError = ProjectError || error{
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
    var prev_virtuals: std.ArrayListUnmanaged(screen_stream.ImageVirtualPlacement) = .empty;
    defer prev_virtuals.deinit(allocator);
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
            .image_virtual => prev_virtuals.append(allocator, try screen_stream.decodeImageVirtual(s.body)) catch return error.OutOfMemory,
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
    // (base 대역은 아래 blob 방출이 `drawable` 을 채운 뒤에 쓴다 — 순서가 뜻을 만든다.)
    // ⚠️ **여기가 애니메이션의 대역폭 병목이다.** kitty 애니메이션은 프레임이 넘어갈 때마다
    // `generation` 을 올리므로 「client 가 가진 판과 다르다」가 **매 프레임 참**이 되어 이미지 blob
    // 전체가 다시 나간다(실측: 64x64 RGBA 한 프레임에 16,441 바이트 — `screen delta: generation 이
    // 바뀐 이미지는 blob 전체가 다시 실린다` 판정자가 그 숫자를 고정한다).
    //
    // host tick 이 `advanceAnimations` 를 부른다(#3623). 지금 감당할 수 있는 이유는 host 와 app 이
    // 같은 기계의 유닉스 소켓으로 붙어 있고, **안 보이는 애니메이션은 아예 안 돌기** 때문이다
    // (뷰포트 밖·다른 화면·placeholder 없음 → `kittyImageVisibleInViewport` 가 막는다).
    // host 가 원격 기계로 가면 이 계약 위에 그대로 둘 수 없다 — 프레임을 미리 보내고 인덱스만
    // 나르는 레코드가 먼저다(docs/persistent-session-host.md §12).
    //
    // 그 가시성 판정을 **투영도 함께 쓴다**(`appendVisibleImageBlobs` §① — 안 그러면 그리지도 못할
    // 픽셀이 16 MiB 예산을 먹고 화면이 통째로 막힌다).
    var drawable: DrawableImages = .{};
    defer drawable.deinit(allocator);
    try appendVisibleImageBlobs(allocator, &delta, opts.generation, core, snap.images, opts.image_bytes_out, &prev_image_gens, &drawable);

    // **base 대역은 그릴 수 있는 것만 싣는다.** base 의 메타(`appendImageBaseMeta`)는 픽셀이 없지만
    // 「client 가 이 generation 을 가졌다」는 **기록**이다 — 다음 delta 가 그것을 보고 재전송을 건너뛴다.
    // 그래서 픽셀을 안 실은 이미지의 메타를 남기면 **그 기록이 거짓말이 된다**: client 는 픽셀이 없는데
    // 다음 프레임은 「이미 줬다」고 판단해 영영 안 보낸다(2026-09-15 적대적 검증에서 잡혔다 —
    // 필터가 통째로 무력해지는 자리였고, 판정자가 처음엔 그 갈래를 못 봤다).
    //
    // 그래서 blob 방출 **뒤에** 쓴다 — `drawable` 이 채워진 다음이라야 같은 기준으로 거를 수 있다.
    for (snap.images) |img| if (drawable.contains(img.image_id))
        try appendImageBaseMeta(allocator, &snapshot, opts.generation, img);
    for (snap.placements) |p| if (drawable.contains(p.image_id))
        try appendImagePlacementRecord(allocator, &snapshot, opts.generation, p);
    for (snap.virtual_placements) |vp| if (drawable.contains(vp.image_id))
        try appendImageVirtualRecord(allocator, &snapshot, opts.generation, vp);
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
    // **픽셀을 안 실은 이미지의 placement 도 안 싣는다**(`DrawableImages` 머리말).
    //
    // delta 의 placement 는 **full-set 교체**라(clear 센티넬 + 전체) 「바뀌었는가」 비교도 **거른 목록끼리**
    // 해야 한다 — `prev_*` 는 이전에 **보낸** 것을 파싱한 값이므로, 한쪽만 거르면 매 프레임 「바뀌었다」가
    // 되어 full-set 이 계속 나간다.
    var drawable_placements: std.ArrayListUnmanaged(terminal.KittyPlacement) = .empty;
    defer drawable_placements.deinit(allocator);
    for (snap.placements) |p| if (drawable.contains(p.image_id))
        drawable_placements.append(allocator, p) catch return error.OutOfMemory;
    var drawable_virtuals: std.ArrayListUnmanaged(terminal.KittyVirtualPlacement) = .empty;
    defer drawable_virtuals.deinit(allocator);
    for (snap.virtual_placements) |vp| if (drawable.contains(vp.image_id))
        drawable_virtuals.append(allocator, vp) catch return error.OutOfMemory;

    if (placementsChanged(prev_placements.items, drawable_placements.items)) {
        try appendImagePlaceDelta(allocator, &delta, opts.generation, drawable_placements.items);
    }
    if (virtualsChanged(prev_virtuals.items, drawable_virtuals.items)) {
        try appendImageVirtualDelta(allocator, &delta, opts.generation, drawable_virtuals.items);
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
fn encodeCellGrapheme(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cell: terminal.Cell, graphemes: []const []const u21) ProjectError!void {
    cur.clearRetainingCapacity();
    const base_cp: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
    try appendUtf8(cur, allocator, base_cp);
    if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
        for (graphemes[cell.grapheme_id - 1]) |extra| try appendUtf8(cur, allocator, extra);
    }
}

fn appendUtf8(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cp: u21) ProjectError!void {
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

test "screen snapshot: U=1 virtual placement 가 host 스트림에 실린다(그리고 일반 placement 로 새지 않는다)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 5 });
    defer core.deinit();
    // **회귀 판정**: 이 방출이 빠지면 client 는 격자를 못 받아 placeholder 셀이 타일 크기를 못 정한다
    // → host-backed 세션에서 tmux 경유 이미지가 통째로 안 보인다. **client 쪽만 테스트하면 이 결함이
    // 그대로 통과한다** — 적대적 검증에서 실제로 그랬다(방출을 지워도 client 판정자는 초록이었다).
    var raw = [_]u8{0} ** 16;
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [128]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=7,U=1,c=4,r=2,z=-1,q=2;{s}\x1b\\", .{b64s}));
    // **placeholder 셀을 함께 찍는다.** 투영은 「화면이 가리키는 이미지」만 싣는다(2026-09-15) —
    // 격자만 등록하고 셀이 없으면 그릴 자리가 없으므로 안 싣는 것이 맞다. 실제 tmux 경유
    // terminal-browser 는 전송과 placeholder 셀을 **같은 프레임에** 보내므로, 픽스처도 그 형태여야
    // 이 판정자가 지키려는 사고(격자를 못 받아 타일 크기를 못 정함)를 실제로 겨눈다.
    // 전경색 rgb(0,0,7) = image_id 7, 결합문자 둘 = 타일 (0,0).
    try core.write("\x1b[38;2;0;0;7m\u{10EEEE}\u{0305}\u{0305}");

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 3 });
    defer allocator.free(bytes);

    var found_virtual = false;
    var placement_count: usize = 0;
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    while (try rs.next()) |rec| {
        const s2 = try screen_stream.RecordStream.split(rec);
        switch (s2.header.kind) {
            .image_virtual => {
                const vp = try screen_stream.decodeImageVirtual(s2.body);
                try testing.expectEqual(@as(u32, 7), vp.image_id);
                try testing.expectEqual(@as(u32, 4), vp.columns);
                try testing.expectEqual(@as(u32, 2), vp.rows);
                try testing.expectEqual(@as(i32, -1), vp.z);
                found_virtual = true;
            },
            .image_placement => placement_count += 1,
            else => {},
        }
    }
    try testing.expect(found_virtual);
    try testing.expectEqual(@as(usize, 0), placement_count); // U=1 은 일반 placement 로 새면 안 된다
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

/// 테스트 전용 부모 allocator. 한 블록을 계속 돌려주어 `resize`·`remap` 이 **반드시** 성립하게
/// 만든다. 실제 allocator 는 크기에 따라 제자리 확장을 거절할 수 있어, 성장 갈래를 확정적으로
/// 지나가게 하려면 이렇게 고정해야 한다.
const FixedBlockParent = struct {
    block: []u8,

    fn allocator(self: *FixedBlockParent) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = fpAlloc,
            .resize = fpResize,
            .remap = fpRemap,
            .free = fpFree,
        } };
    }

    fn fpAlloc(ctx: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *FixedBlockParent = @ptrCast(@alignCast(ctx));
        return if (len <= self.block.len) self.block.ptr else null;
    }
    fn fpResize(ctx: *anyopaque, _: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *FixedBlockParent = @ptrCast(@alignCast(ctx));
        return new_len <= self.block.len;
    }
    fn fpRemap(ctx: *anyopaque, _: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        const self: *FixedBlockParent = @ptrCast(@alignCast(ctx));
        return if (new_len <= self.block.len) self.block.ptr else null;
    }
    fn fpFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
};

test "상한이 거절한 투영은 진짜 메모리 부족과 다른 오류로 나온다" {
    // 2026-09-14 실측이 만든 판정자. allocator vtable 은 `null` 하나만 돌려줄 수 있어 「16 MiB
    // 상한 초과」가 호출자에게 `OutOfMemory` 로 보였고, host 는 그것을 자원 문제로 읽어 **공유
    // 연결 전체**를 끊었다 — 세션 19 개가 전부 안 붙었고 시스템 여유 메모리는 51% 였다.
    //
    // 재는 것은 「둘이 갈린다」이다. 한쪽만 재면 갈림이 사라져도 초록이다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    try core.write("ABCD");

    // ① 상한이 거절하면 `SnapshotTooLarge` 다. 1 바이트짜리 천장은 어떤 화면도 못 담는다.
    try std.testing.expectError(
        error.SnapshotTooLarge,
        projectSnapshotBounded(allocator, &core, .{ .generation = 1 }, 1),
    );

    // ①-b **거절당한 «바이트 수»가 밖으로 나온다.** 오류 이름만 나오면 다음 재현이 또
    //      소거법으로 돌아간다 — 숫자가 있어야 「크다」와 「시스템이 못 준다」가 갈린다.
    var diag: Diagnostics = .{};
    try std.testing.expectError(
        error.SnapshotTooLarge,
        projectSnapshotBoundedDiag(allocator, &core, .{ .generation = 1 }, 1, &diag),
    );
    try std.testing.expect(diag.refused_len > 1);
    try std.testing.expectEqual(@as(usize, 0), diag.parent_fail_len);

    // **제자리 성장도 `peak` 에 잡힌다.** `alloc` 만 세면 `remap`·`resize` 로 자란 버퍼가 안 보이고,
    // 16 MiB 까지 자란 스트림이 «1 MB» 로 보고된다 — 2026-09-14 에 실제로 그렇게 보고돼, 「작은데
    // 왜 상한을 넘지」로 한참 헤맸다.
    //
    // **성장 경로를 직접 겨눈다.** 실제 투영으로 재려 하면 작은 화면은 첫 `alloc` 만으로 끝나
    // 이 갈래를 안 지난다(그 판을 돌연변이로 확인했더니 초록이었다). 그래서 부모를 고정해
    // `resize`·`remap` 이 반드시 일어나게 만든다.
    {
        const backing = try allocator.alloc(u8, 1 << 16);
        defer allocator.free(backing);
        var parent: FixedBlockParent = .{ .block = backing };
        var cap: AllocationCap = .{ .parent = parent.allocator(), .max = 1 << 20 };
        const capped = cap.allocator();

        const first = try capped.alloc(u8, 64);
        try std.testing.expectEqual(@as(usize, 64), cap.peak_len);

        // 제자리 확장(resize) — peak 이 따라와야 한다.
        try std.testing.expect(capped.rawResize(first[0..64], .fromByteUnits(1), 4096, @returnAddress()));
        try std.testing.expectEqual(@as(usize, 4096), cap.peak_len);

        // 재배치(remap) — 역시 따라와야 한다. `first` 는 아직 길이 64 짜리 슬라이스이므로
        // 확장된 실제 길이로 다시 만들어 넘긴다(부모가 같은 블록을 돌려주는 고정 블록이다).
        const grown_slice = first.ptr[0..4096];
        _ = capped.rawRemap(grown_slice, .fromByteUnits(1), 16384, @returnAddress()) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 16384), cap.peak_len);
    }

    // ②-b 부모가 거절하면 그쪽 숫자가 찬다.
    var starved_diag: Diagnostics = .{};
    var starved_probe = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        projectSnapshotBoundedDiag(
            starved_probe.allocator(),
            &core,
            .{ .generation = 1 },
            screen_stream.max_record_stream_bytes,
            &starved_diag,
        ),
    );
    try std.testing.expect(starved_diag.parent_fail_len > 0);
    try std.testing.expectEqual(@as(usize, 0), starved_diag.refused_len);

    // ③ **스트림 상한 초과도 `SnapshotTooLarge` 다.** 이 갈래가 실제 사고의 원인이었다 —
    //    `appendProjectedRecord` 의 상한 검사는 할당자를 거치기 «전» 에 돌아가므로
    //    AllocationCap 이 아예 못 본다. 그래서 refused=0·parent_fail=0 인데 OutOfMemory 가
    //    나왔고, host 가 자원 문제로 읽어 세션 19 개의 공유 연결을 끊었다(2026-09-14).
    //    상한을 **실제로** 넘겨 재지 않으면 이 갈래는 안 지나간다.
    {
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        defer stream.deinit(allocator);
        const oversized = try allocator.alloc(u8, screen_stream.max_record_stream_bytes + 1);
        defer allocator.free(oversized);
        try std.testing.expectError(
            error.SnapshotTooLarge,
            appendProjectedRecord(&stream, allocator, oversized),
        );
        // 상한 **이하** 는 그대로 들어간다 — 검사가 전부를 막아 버리면 그것도 회귀다.
        const fits = try allocator.alloc(u8, 1024);
        defer allocator.free(fits);
        try appendProjectedRecord(&stream, allocator, fits);
        try std.testing.expectEqual(@as(usize, 4 + fits.len), stream.items.len);
    }

    // ② **진짜 부족은 여전히 `OutOfMemory` 다.** 천장은 넉넉히 두고 부모 allocator 를 굶긴다 —
    //    그래야 「상한이 거절한 것이 아니다」가 참이고, 두 갈래가 실제로 갈린다.
    var starved = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        projectSnapshotBounded(
            starved.allocator(),
            &core,
            .{ .generation = 1 },
            screen_stream.max_record_stream_bytes,
        ),
    );
}

test "screen delta: generation 이 바뀐 이미지는 blob 전체가 다시 실린다 (대역폭 계약)" {
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 80, .rows = 24 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    // 64x64 RGBA = 16 KiB 이미지(작은 편) — 실제 앱 이미지는 이보다 훨씬 크다.
    const W = 64;
    const px = try allocator.alloc(u8, W * W * 4);
    defer allocator.free(px);
    @memset(px, 0xAB);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(px.len));
    defer allocator.free(b64);
    const enc = std.base64.standard.Encoder.encode(b64, px);
    const cmd = try std.fmt.allocPrint(allocator, "\x1b_Ga=t,f=32,s={d},v={d},i=1,q=2;{s}\x1b\\", .{ W, W, enc });
    defer allocator.free(cmd);
    try core.write(cmd);
    const frame = try std.fmt.allocPrint(allocator, "\x1b_Ga=f,f=32,s={d},v={d},i=1,z=40,q=2;{s}\x1b\\", .{ W, W, enc });
    defer allocator.free(frame);
    try core.write(frame);
    try core.write("\x1b_Ga=p,i=1,c=10,r=5,q=2\x1b\\");
    try core.write("\x1b_Ga=a,i=1,r=1,z=40,s=3,q=2\x1b\\");

    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);

    // 프레임을 한 번 넘긴다 — 픽셀 크기도 내용도 그대로이고 generation 만 바뀐다.
    try std.testing.expect(core.advanceAnimations(40));
    var res = try computeDelta(allocator, base, &core, .{ .generation = 2 });
    defer res.deinit(allocator);

    // **현재 wire 계약**: `generation` 이 바뀐 이미지는 delta 가 **blob 전체를 다시 싣는다**.
    // 실측(2026-09-12): 64x64 RGBA(16 KiB) 이미지가 프레임 하나 넘어가면 delta 가 16,441 바이트다 —
    // 픽셀은 한 바이트도 안 바뀌었는데(같은 0xAB) 프레임 번호만 달라졌을 뿐이다.
    //
    // 애니메이션이 이 위에서 돌면 그 값에 프레임 레이트가 곱해진다. host cadence 가 20ms 이므로
    // 최대 50fps → 이 작은 이미지도 **822 KB/s**, 실제 크기(400x300 RGBA=480 KiB)면 **24 MB/s** 다.
    // 그래서 원격 애니메이션은 이 계약 위에 **그대로 얹을 수 없다** — 프레임을 미리 보내고 「지금 몇 번
    // 프레임」만 나르는 레코드가 먼저 필요하다. 이 판정자는 그 전제(지금은 통째로 실린다)를 고정한다.
    try std.testing.expect(res.delta.len >= px.len);

    // **계측이 그 양을 실제로 집어낸다.** 「delta 가 크다」만 재면 그 안에서 이미지가 몇 바이트인지
    // 모른다 — 라이브에서 「느리다」를 들었을 때 대역폭인지 다른 것인지 가르려면 그 분해가 필요하다.
    // 여기서 `image_bytes_out` 이 blob 분량을 정확히 집는지 고정한다.
    var image_bytes: u64 = 0;
    var res2 = try computeDelta(allocator, base, &core, .{ .generation = 3, .image_bytes_out = &image_bytes });
    defer res2.deinit(allocator);
    try std.testing.expect(image_bytes >= px.len); // 픽셀 전량이 계측에 잡힌다
    try std.testing.expect(image_bytes <= res2.delta.len); // delta 를 넘지 않는다
    // **그리고 delta 의 대부분이 이미지다** — 이 워크로드에서 병목이 어디인지 판정자가 말한다.
    try std.testing.expect(image_bytes * 2 > res2.delta.len);

    // **음성 대조**: 싱크를 안 주면 아무 일도 안 일어난다(기본 경로에 비용이 없다).
    var res3 = try computeDelta(allocator, base, &core, .{ .generation = 4 });
    defer res3.deinit(allocator);
    try std.testing.expect(res3.delta.len >= px.len);
}

test "screen 계측: 이미지가 없으면 image_bytes 는 0 이다 (공허하지 않은지)" {
    // 위 판정자가 「언제나 참」이 아님을 보인다 — 이미지가 없는 화면에서는 0 이어야 한다.
    // 이게 없으면 `image_bytes_out` 이 delta 전체 길이를 세도 그 판정자가 통과한다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    try core.write("hello");
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);
    try core.write(" world");
    var image_bytes: u64 = 0;
    var res = try computeDelta(allocator, base, &core, .{ .generation = 2, .image_bytes_out = &image_bytes });
    defer res.deinit(allocator);
    try std.testing.expect(res.delta.len > 0); // delta 는 있는데
    try std.testing.expectEqual(@as(u64, 0), image_bytes); // 이미지 분량은 0 이다
}

// **attach 이후에 등록된 U=1 격자가 client 에 닿는가.**
//
// 이 판정자가 생긴 이유(적대적 검증 7회차): 라이브에서 placeholder 이미지가 **두부 글리프로** 떴다.
// 코어는 정확했고(codepoint 0x10EEEE·grapheme·rgb 전부 맞음) 렌더러의 placeholder 판정자도 초록인데
// 제품에서만 안 됐다. 원인은 그 사이 — `image_virtual` 은 레코드 정의가 「full-replace 라 snapshot·delta
// 공용」이라고 **선언해 두고** delta 로는 한 번도 안 나갔고, client 의 `applyDelta` 에도 분기가 없었다.
// 그래서 attach 시점 snapshot 에 없던 격자는 영영 안 들어오고, placeholder 셀은 타일 크기를 못 정한다.
//
// 기존 U=1 패리티 판정자는 **snapshot 경로만** 태워서 이 구멍을 못 봤다. 실제 셸은 attach 뒤에 이미지를
// 띄우므로 delta 경로가 진짜 경로다.
test "screen delta: attach 뒤에 등록된 U=1 격자가 delta 로 client 에 닿는다 (적대적 검증)" {
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 6 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    // ① attach 시점: 이미지도 격자도 없다.
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(base);
    try std.testing.expectEqual(@as(usize, 0), asm_.imageVirtualPlacements().len);

    // ② 셸이 그 뒤에 이미지를 띄운다 — U=1 등록 + placeholder 셀.
    var b64: [32]u8 = undefined;
    var seq: [96]u8 = undefined;
    const raw = [_]u8{ 9, 9, 9, 255 } ** 4;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=7,q=2;{s}\x1b\\", .{b64s}));
    try core.write("\x1b_Ga=p,i=7,U=1,c=2,r=1,q=2\x1b\\");
    try core.write("\r\n\x1b[38;2;0;0;7m\u{10EEEE}\u{0305}\u{0305}\x1b[0m");

    var res = try computeDelta(allocator, base, &core, .{ .generation = 1, .sequence = 1 });
    defer res.deinit(allocator);
    try asm_.applyDelta(res.delta);

    // client 가 격자를 받았는가 — 이게 없으면 placeholder 는 타일 크기를 못 정하고 글리프로 떨어진다.
    const vps = asm_.imageVirtualPlacements();
    try std.testing.expectEqual(@as(usize, 1), vps.len);
    try std.testing.expectEqual(@as(u32, 7), vps[0].image_id);
    try std.testing.expectEqual(@as(u32, 2), vps[0].columns);
    try std.testing.expectEqual(@as(u32, 1), vps[0].rows);

    // ③ 격자가 사라지면(a=d) client 도 비워야 한다 — clear 센티넬이 그 일을 한다.
    try core.write("\x1b_Ga=d,d=I,i=7,q=2\x1b\\");
    var res2 = try computeDelta(allocator, res.snapshot, &core, .{ .generation = 1, .sequence = 2 });
    defer res2.deinit(allocator);
    try asm_.applyDelta(res2.delta);
    try std.testing.expectEqual(@as(usize, 0), asm_.imageVirtualPlacements().len);

    // ④ **안 바뀌면 안 싣는다** — 매 tick 격자를 다시 보내면 조용한 화면이 계속 바이트를 쓴다.
    var res3 = try computeDelta(allocator, res2.snapshot, &core, .{ .generation = 1, .sequence = 3 });
    defer res3.deinit(allocator);
    var rs = screen_stream.RecordStream{ .bytes = res3.delta };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        try std.testing.expect(s.header.kind != .image_virtual);
    }
}

fn deltaHasKind(bytes: []const u8, want: screen_stream.RecordKind) !bool {
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind == want) return true;
    }
    return false;
}

// **attach 뒤에 움직인 축은 전부 delta 로 client 에 닿아야 한다.**
//
// 이 판정자가 생긴 이유: `image_virtual`(U=1 격자)이 레코드 정의에 「snapshot·delta 공용」이라고
// **선언돼 있는데도** delta 로는 한 번도 안 나갔다. attach 시점 snapshot 에 없던 격자는 영영 안
// 들어와서, 라이브에서 placeholder 이미지가 두부 글리프로 떴다(#3640). 축 하나가 조용히 빠져도
// 다른 판정자는 전부 초록이었다 — 각 축을 **따로** 보는 판정자만 있었기 때문이다.
//
// 그래서 축을 **한자리에서 전수로** 몬다. 새 레코드 종류를 더하면 이 표에 줄을 더해야 하고,
// 안 더하면 「delta 로 흐르는가」를 아무도 안 묻는 축이 다시 생긴다.
//
// **byte 등가로 보지 않는다.** `ScreenAssembler.toSnapshot` 은 meta+row 만 재방출하는 부분
// 재구성이고(설계상 그렇다), 헤더의 generation/sequence 도 섞인다 — 그걸로 비교하면 멀쩡한 축이
// 빨갛게 나온다(실측으로 확인하고 이 방식으로 바꿨다). 축마다 그 축의 상태를 직접 읽는다.
test "screen delta: attach 뒤 움직인 모든 축이 delta 로 client 에 닿는다 (전수)" {
    const allocator = std.testing.allocator;
    const Axis = enum { text, cursor, modes, scroll, image_pixels, placement, virtual_placement, prompt, link, image_gone };
    const expect_kind = std.EnumArray(Axis, screen_stream.RecordKind).init(.{
        .text = .set_runs,
        .cursor = .cursor,
        .modes = .modes,
        .scroll = .scroll_state,
        .image_pixels = .image_blob,
        .placement = .image_place,
        .virtual_placement = .image_virtual,
        .prompt = .prompt_marks,
        .link = .link_spans,
        .image_gone = .image_remove,
    });

    // **새 레코드 종류가 생기면 이 표에 줄이 하나 늘어야 한다.** 안 그러면 「delta 로 흐르는가」를
    // 아무도 안 묻는 축이 조용히 또 생긴다 — `image_virtual` 이 정확히 그렇게 빠져 있었다.
    // 여기 없는 종류는 **왜 없는지**를 아래 목록이 이름으로 밝혀야 한다.
    {
        const not_producer_emitted = [_]screen_stream.RecordKind{
            .screen_meta, // snapshot 전용(delta 는 scroll_state 로 나른다)
            .row, // snapshot 전용(delta 는 set_runs)
            .image_placement, // snapshot 대역(delta 는 image_place)
            .image_blob, // 아래 image_pixels 축이 본다 — snapshot·delta 공용이라 두 대역에 다 있다
            .clear_rect, // producer 미방출(§12 — 지금은 set_runs 가 전부를 덮는다)
            .scroll_rect, // producer 미방출(같은 이유)
        };
        for (std.enums.values(screen_stream.RecordKind)) |kind| {
            var classified = false;
            for (std.enums.values(Axis)) |axis| {
                if (expect_kind.get(axis) == kind) classified = true;
            }
            for (not_producer_emitted) |k| {
                if (k == kind) classified = true;
            }
            if (!classified) {
                std.debug.print("\n레코드 종류 {s} 가 축 표에도 예외 목록에도 없다 — delta 로 흐르는지 아무도 안 묻는다\n", .{@tagName(kind)});
                return error.TestUnexpectedResult;
            }
        }
    }

    for (std.enums.values(Axis)) |axis| {
        var core = try terminal.TerminalCore.init(allocator, .{ .cols = 40, .rows = 8 });
        defer core.deinit();
        core.setCellMetrics(10, 20);
        var b64: [32]u8 = undefined;
        var seq: [128]u8 = undefined;
        const raw = [_]u8{ 3, 4, 5, 255 } ** 4;
        const b64s = std.base64.standard.Encoder.encode(&b64, &raw);

        // attach 시점 사전 상태(축마다 다르다 — 「사라짐」을 보려면 먼저 있어야 한다).
        switch (axis) {
            .image_pixels, .placement, .virtual_placement, .image_gone => {
                try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=4,q=2;{s}\x1b\\", .{b64s}));
                if (axis == .image_gone) try core.write("\x1b_Ga=p,i=4,c=1,r=1,q=2\x1b\\");
            },
            else => {},
        }
        const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
        defer allocator.free(base);
        var asm_ = screen_assembler.ScreenAssembler.init(allocator);
        defer asm_.deinit();
        try asm_.applySnapshot(base);

        // attach **뒤에** 그 축을 움직인다 — 실제 셸이 하는 일의 순서다.
        switch (axis) {
            .text => try core.write("hello axis"),
            .cursor => try core.write("\x1b[4;9H"),
            .modes => try core.write("\x1b[?1h"),
            .scroll => {
                for (0..20) |_| try core.write("line\r\n");
                core.view_offset = 3;
            },
            // **표시까지 한다(`a=T`).** 투영은 화면이 실제로 가리키는 이미지의 픽셀만 싣는다 —
            // 그리지도 못할 픽셀이 16 MiB 예산을 먹으면 그 화면이 통째로 막히기 때문이다(2026-09-15,
            // docs/persistent-session-host.md). 그래서 `a=t`(전송만)로는 이 축이 움직이지 않는다.
            // 대가는 **표시 시점까지의 지연**이다: 미리 올려 둔 이미지는 `a=p` 가 오는 프레임에 비로소
            // 실린다(그때 `prev_image_gens` 에 없으므로 후보가 된다).
            .image_pixels => try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=9,c=1,r=1,q=2;{s}\x1b\\", .{b64s})),
            .placement => try core.write("\x1b_Ga=p,i=4,c=1,r=1,q=2\x1b\\"),
            // 격자와 **placeholder 셀을 함께** 찍는다 — 투영은 화면이 가리키는 이미지만 싣는다(2026-09-15).
            // 격자만 등록하면 그릴 자리가 없어 이 축이 안 움직인다(실제 앱도 둘을 같이 보낸다).
            // 전경색 rgb(0,0,4) = image_id 4, 결합문자 둘 = 타일 (0,0).
            .virtual_placement => {
                try core.write("\x1b_Ga=p,i=4,U=1,c=1,r=1,q=2\x1b\\");
                try core.write("\x1b[38;2;0;0;4m\u{10EEEE}\u{0305}\u{0305}");
            },
            .prompt => try core.write("\x1b]133;A\x1b\\prompt"),
            .link => try core.write("see https://example.com/x here"),
            .image_gone => try core.write("\x1b_Ga=d,d=I,i=4,q=2\x1b\\"),
        }

        var res = try computeDelta(allocator, base, &core, .{ .generation = 1, .sequence = 1 });
        defer res.deinit(allocator);
        // ① 그 축의 레코드가 delta 에 실렸는가.
        try std.testing.expect(try deltaHasKind(res.delta, expect_kind.get(axis)));
        try asm_.applyDelta(res.delta);

        // ② client 상태가 실제로 그 변화를 반영하는가 — 「실렸다」는 값이 맞다는 뜻이 아니다.
        switch (axis) {
            .text => {
                var found = false;
                for (asm_.rowRuns(0)) |run| {
                    if (std.mem.indexOf(u8, run.grapheme, "h") != null) found = true;
                }
                try std.testing.expect(found);
            },
            .cursor => {
                try std.testing.expectEqual(@as(u16, 3), asm_.cursor.row);
                try std.testing.expectEqual(@as(u16, 8), asm_.cursor.col);
            },
            .modes => try std.testing.expect(asm_.modes != 0),
            .scroll => try std.testing.expectEqual(@as(u32, 3), asm_.view_offset),
            .image_pixels => try std.testing.expect(asm_.imageById(9) != null),
            .placement => try std.testing.expectEqual(@as(usize, 1), asm_.imagePlacements().len),
            .virtual_placement => try std.testing.expectEqual(@as(usize, 1), asm_.imageVirtualPlacements().len),
            .prompt => {
                var marked = false;
                for (asm_.promptMarks()) |m| if (m.kind != 0) {
                    marked = true;
                };
                try std.testing.expect(marked);
            },
            .link => try std.testing.expect(asm_.linkSpans().len > 0),
            .image_gone => try std.testing.expect(asm_.imageById(4) == null),
        }
    }
}

test "TBPROBE 원격 왕복: unicode placeholder 화면이 투영·조립을 건너 타일 quad 로 나온다" {
    // **계측용 판정자**(2026-09-15). 로컬 경로(파서→코어→렌더)는 초록인데 tmux 안 terminal-browser
    // 화면이 박스 문자로 깨졌다 — 그 pane 은 session host 경유라 투영·조립을 한 번 더 건넌다.
    // 이미지·격자·placeholder 셀(전경색 RGB + 결합문자) 중 **무엇이 그 다리를 못 건너는지**를 센다.
    const metal_frame = maru.renderer.metal_frame;
    const remote_screen = @import("remote_screen.zig");
    const allocator = std.testing.allocator;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();

    const grid_cols: u32 = 4;
    const grid_rows: u32 = 2;
    const img_w: usize = 32;
    const img_h: usize = 16;
    const image_id: u32 = 87364; // 실측 캡처의 i= 값. 0x015544 → 전경색 rgb(1, 85, 68).

    const rgba = try allocator.alloc(u8, img_w * img_h * 4);
    defer allocator.free(rgba);
    for (rgba, 0..) |*b, i| b.* = @intCast(i % 251);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(rgba.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, rgba);

    var head: [192]u8 = undefined;
    try core.write(try std.fmt.bufPrint(
        &head,
        "\x1b_Ga=T,f=32,s={d},v={d},t=d,i={d},U=1,c={d},r={d},q=2;",
        .{ img_w, img_h, image_id, grid_cols, grid_rows },
    ));
    try core.write(b64);
    try core.write("\x1b\\");

    // placeholder 셀 — 전경색 RGB 에 id 하위 24비트, 결합문자에 타일 좌표(한 행 4칸).
    try core.write("\x1b[38;2;1;85;68m");
    var utf8: [8]u8 = undefined;
    const diacritics = [_]u21{ 0x0305, 0x030D, 0x030E, 0x0310 }; // 표의 0..3 — 명세가 정한 데이터다
    var tile_col: usize = 0;
    while (tile_col < grid_cols) : (tile_col += 1) {
        var n = try std.unicode.utf8Encode(terminal.unicode_placeholder_codepoint, &utf8);
        try core.write(utf8[0..n]);
        n = try std.unicode.utf8Encode(diacritics[0], &utf8); // 타일 행 0
        try core.write(utf8[0..n]);
        n = try std.unicode.utf8Encode(diacritics[tile_col], &utf8);
        try core.write(utf8[0..n]);
    }

    // 로컬 쪽은 이미 초록임을 이 자리에서 다시 확인한다 — 왕복이 깨졌을 때 「애초에 없었다」와
    // 「건너다 잃었다」가 구분되어야 한다(공허 통과 방지).
    try std.testing.expect(core.kitty_images.map.contains(image_id));
    try std.testing.expectEqual(@as(usize, 1), core.kitty_virtual_placements.items.len);

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(bytes);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(bytes);

    // ① 이미지 픽셀이 건넜는가.
    try std.testing.expect(asm_.imageById(image_id) != null);
    // ② 격자 정의(U=1)가 건넜는가 — 없으면 타일 크기를 못 정해 렌더가 통째로 건너뛴다.
    try std.testing.expectEqual(@as(usize, 1), asm_.imageVirtualPlacements().len);

    // ③ placeholder 셀이 전경색 RGB 와 결합문자를 지킨 채 건넜는가.
    var grid = try remote_screen.build(allocator, &asm_);
    defer grid.deinit();
    const snapshot = grid.renderSnapshot();
    try std.testing.expectEqual(terminal.unicode_placeholder_codepoint, snapshot.cells[0].codepoint);
    switch (snapshot.cells[0].style.foreground) {
        .rgb => |v| try std.testing.expectEqual([3]u8{ 1, 85, 68 }, [3]u8{ v.r, v.g, v.b }),
        else => return error.ForegroundNotRgb,
    }
    try std.testing.expect(snapshot.cells[0].grapheme_id != 0);

    // ④ 그래서 화면에 이미지가 뜨는가.
    const out = try metal_frame.buildGpuImages(
        allocator,
        snapshot.placements,
        snapshot.images,
        snapshot.size,
        10,
        20,
        snapshot.cells,
        snapshot.graphemes,
        snapshot.virtual_placements,
    );
    defer allocator.free(out);
    try std.testing.expect(out.len > 0);
    try std.testing.expectEqual(image_id, out[0].image_id);
}

test "TBPROBE 가시성: 화면이 안 가리키는 이미지는 예산이 남아돌아도 안 싣는다" {
    // **회귀 판정**(2026-09-15). 아래 「규모」 판정자와 **일부러 갈라 둔다** — 그쪽은 실측 크기라
    // 가시성 필터를 지워도 **예산 검사가 대신 막아** 초록이었다(돌연변이로 확인). 두 방어선이
    // 겹치는 구간에서는 어느 쪽이 일하는지 구분되지 않으므로, 여기서는 **예산이 남아도는 크기**로
    // 재서 가시성 필터만 시험한다.
    //
    // 이 판정자가 처음 빨갛게 드러낸 것은 필터가 아니라 **판정 자체의 성김**이었다: 코어의
    // `kittyImageVisibleInViewport` 가 「placeholder 셀이 하나라도 있는가」만 보고 어느 이미지인지는
    // 안 물어서, 아무도 안 가리키는 장까지 「보인다」가 됐다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();

    const img_w: usize = 256;
    const img_h: usize = 256; // 256 KiB — 두 장이어도 예산(약 15.75 MiB)에 한참 못 미친다
    const rgba = try allocator.alloc(u8, img_w * img_h * 4);
    defer allocator.free(rgba);
    @memset(rgba, 0x33);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(rgba.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, rgba);

    var head: [192]u8 = undefined;
    for ([_]u8{ '1', '2' }) |id_char| {
        try core.write(try std.fmt.bufPrint(
            &head,
            "\x1b_Ga=T,f=32,s={d},v={d},t=d,i={c},U=1,c=20,r=4,q=2;",
            .{ img_w, img_h, id_char },
        ));
        try core.write(b64);
        try core.write("\x1b\\");
    }
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count());

    // 화면은 1번만 가리킨다 — 전경색 rgb(0,0,1).
    try core.write("\x1b[38;2;0;0;1m");
    var utf8: [8]u8 = undefined;
    var n = try std.unicode.utf8Encode(terminal.unicode_placeholder_codepoint, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    try std.testing.expect(core.kittyImageVisibleInViewport(1));
    try std.testing.expect(!core.kittyImageVisibleInViewport(2)); // 성긴 판정이면 여기서 빨개진다

    var image_bytes: u64 = 0;
    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 1, .image_bytes_out = &image_bytes });
    defer allocator.free(bytes);
    // 예산은 남아돈다 — 그런데도 한 장치만 실렸다면 그것을 막은 것은 **가시성 판정뿐**이다.
    try std.testing.expect(bytes.len < screen_stream.max_record_stream_bytes / 2);
    try std.testing.expect(image_bytes < 2 * img_w * img_h * 4);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(bytes);
    try std.testing.expect(asm_.imageById(1) != null);
    try std.testing.expect(asm_.imageById(2) == null);
}

test "TBPROBE 규모: 실측 크기 두 장이어도 화면은 건넌다(예전에는 통째로 막혔다)" {
    // **회귀 판정**(2026-09-15). 실측 캡처의 크기 그대로 잰다 — terminal-browser pane 하나가
    // `s=1003,v=2183` RGBA 를 보낸다(프레임당 8.75 MB). 코어 저장 한도는 320 MB, 투영 스트림 상한은
    // 16 MiB 로 **서로를 모르는 두 숫자**라, 예전에는 코어가 보관한 둘째 장이 투영을 통째로
    // 거절시켰다(`SnapshotTooLarge`). 그러면 이미지만이 아니라 **그 화면 전체**가 못 건넌다.
    //
    // 고친 뒤 계약: 화면이 가리키지 않는 이미지는 애초에 싣지 않는다. 그래서 두 장째에도 화면은 건너고,
    // **보이는 한 장만** 건넌다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 59, .rows = 59 });
    defer core.deinit();

    const img_w: usize = 1003; // 실측 s=
    const img_h: usize = 2183; // 실측 v=
    const rgba = try allocator.alloc(u8, img_w * img_h * 4);
    defer allocator.free(rgba);
    @memset(rgba, 0x7F);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(rgba.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, rgba);

    var head: [192]u8 = undefined;
    for ([_]u8{ '1', '2' }) |id_char| {
        try core.write(try std.fmt.bufPrint(
            &head,
            "\x1b_Ga=T,f=32,s={d},v={d},t=d,i={c},U=1,c=59,r=59,q=2;",
            .{ img_w, img_h, id_char },
        ));
        try core.write(b64);
        try core.write("\x1b\\");
    }
    try std.testing.expectEqual(@as(usize, 2), core.kitty_images.map.count()); // 코어는 둘 다 보관한다

    // 화면은 **1번만** 가리킨다 — 전경색 rgb(0,0,1) = image_id 1.
    try core.write("\x1b[38;2;0;0;1m");
    var utf8: [8]u8 = undefined;
    var n = try std.unicode.utf8Encode(terminal.unicode_placeholder_codepoint, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8); // 타일 행 0
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8); // 타일 열 0
    try core.write(utf8[0..n]);

    var image_bytes: u64 = 0;
    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 1, .image_bytes_out = &image_bytes });
    defer allocator.free(bytes);

    // 한 장치(8.75 MB)는 실렸고 두 장치(17.5 MB)는 아니다 — 예산을 숫자로 고정한다.
    try std.testing.expect(image_bytes > 8 * 1024 * 1024);
    try std.testing.expect(image_bytes < 16 * 1024 * 1024);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(bytes);
    try std.testing.expect(asm_.imageById(1) != null); // 화면이 가리키는 장은 건넜다
    try std.testing.expect(asm_.imageById(2) == null); // 아무도 안 가리키는 장은 안 건넜다
}

test "TBPROBE 예산: 한 장이 상한을 넘어도 화면은 건넌다 — 이미지를 포기하지 화면을 버리지 않는다" {
    // **회귀 판정**(2026-09-15). 위 판정자는 「안 보이는 장을 거른다」만 잰다 — 그것만으로는 **보이는
    // 한 장이 혼자 상한을 넘는** 화면(큰 창·고해상도)에서 여전히 투영 전체가 거절된다.
    //
    // 규칙은 문서가 이미 정한 것과 같은 결이다(persistent-session-host.md «자기 쪽 cap 초과로 공유
    // 연결을 죽이지 않는다»): 이미지가 예산을 넘으면 **이미지를 포기하고 화면을 보낸다.** 화면이
    // 멈추는 것이 더 나쁜 오답이다 — 그 pane 은 갱신을 통째로 잃는다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();

    const side: usize = 2048; // 2048x2048 RGBA = 16.78 MB — 혼자서 16 MiB 상한을 넘는다
    const rgba = try allocator.alloc(u8, side * side * 4);
    defer allocator.free(rgba);
    @memset(rgba, 0x11);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(rgba.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, rgba);

    var head: [192]u8 = undefined;
    try core.write(try std.fmt.bufPrint(
        &head,
        "\x1b_Ga=T,f=32,s={d},v={d},t=d,i=9,U=1,c=20,r=4,q=2;",
        .{ side, side },
    ));
    try core.write(b64);
    try core.write("\x1b\\");
    try std.testing.expect(core.kitty_images.map.contains(9)); // 코어는 받아 뒀다(코어 한도는 320 MB)

    // 화면이 그 이미지를 **가리킨다** — 가시성 필터로는 안 걸러지는 경우다.
    try core.write("\x1b[38;2;0;0;9m");
    var utf8: [8]u8 = undefined;
    var n = try std.unicode.utf8Encode(terminal.unicode_placeholder_codepoint, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    try std.testing.expect(core.kittyImageVisibleInViewport(9)); // 보이는 이미지가 맞다

    // 화면은 건넌다(예전에는 여기서 `SnapshotTooLarge` 로 통째로 막혔다).
    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(bytes);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(bytes);
    try std.testing.expect(asm_.imageById(9) == null); // 픽셀을 포기했고
    // **격자도 함께 포기한다**(2026-09-15 에 바뀐 계약). 앞 판은 격자만 보냈는데, 그러면 클라이언트가
    // 「그려야 하는데 픽셀이 없는」 상태가 되고 그것을 세는 계측이 「떨어짐」과 「의도적 미투영」을
    // 못 가른다(`DrawableImages` 머리말). 픽셀과 placement 는 **같이** 빠진다.
    try std.testing.expectEqual(@as(usize, 0), asm_.imageVirtualPlacements().len);
}

test "TBPROBE 실물: 캡처한 terminal-browser 출력이 quad 로 그려지고 텍스트로 새지 않는다" {
    // **실물 검증**(2026-09-15). 위 판정자는 실측과 «같은 형식»을 합성해 먹인다. 이 판정자는 살아 있는
    // maru 안 tmux pane 에서 `tmux pipe-pane` 으로 **실제로 받아 적은 바이트**를 먹인다(tmux passthrough 는
    // 벗겨 둔 것 — 터미널이 실제로 보는 형태). 경로는 env 로 받고, 없으면 건너뛴다: 캡처는 사람이 브라우저를
    // 띄워야 만들어지므로 CI 가 가질 수 없다. 그래서 이것은 **CI 그물이 아니라 재현 하네스**다 —
    // 합성 판정자들이 그물 역할을 진다.
    const allocator = std.testing.allocator;
    // env 는 libc `getenv` 로 읽는다 — 이 저장소의 다른 하네스(`MARU_FUZZ_SEED`)와 같은 방식이고,
    // Zig 0.16 은 `std.process.getEnvVarOwned`/`std.posix.getenv` 를 이 그래프에 안 내준다.
    const path_z = std.c.getenv("MARU_TBPROBE_CAPTURE") orelse return;
    const path = std.mem.span(path_z);

    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);

    var core_state = try terminal.TerminalCore.init(allocator, .{ .cols = 135, .rows = 47 });
    defer core_state.deinit();
    core_state.setCellMetrics(10, 20);
    try core_state.write(bytes);

    const snapshot = core_state.renderSnapshot();

    // ① 화면이 placeholder 로 덮였는가 — 캡처가 실제로 그 축을 만들었다는 증거(공허 통과 방지).
    var placeholder_cells: usize = 0;
    for (snapshot.cells) |cell| {
        if (cell.codepoint == terminal.unicode_placeholder_codepoint) placeholder_cells += 1;
    }
    try std.testing.expect(placeholder_cells > 100);

    // ② 이미지와 격자가 코어에 있는가.
    try std.testing.expect(snapshot.images.len > 0);
    try std.testing.expect(snapshot.virtual_placements.len > 0);

    // ③ 그 셀들이 타일 quad 로 바뀌는가 — 여기까지 와야 화면에 그림이 뜬다.
    const out = try maru.renderer.metal_frame.buildGpuImages(
        allocator,
        snapshot.placements,
        snapshot.images,
        snapshot.size,
        10,
        20,
        snapshot.cells,
        snapshot.graphemes,
        snapshot.virtual_placements,
    );
    defer allocator.free(out);
    try std.testing.expect(out.len > 0);

    // ④ **그리고 그 셀이 텍스트로는 새지 않는가.** 이것이 사용자가 본 증상(박스 문자로 덮인 화면)의 자리다.
    var dl = try maru.renderer.draw_list.buildDrawList(allocator, snapshot);
    defer dl.deinit(allocator);
    var leaked: usize = 0;
    for (dl.cells) |c| {
        if (c.codepoint == terminal.unicode_placeholder_codepoint) leaked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), leaked);
}

test "TBPROBE 정합 ①: 화면이 안 가리키는 이미지는 픽셀도 placement 도 안 싣는다" {
    // **회귀 판정**(2026-09-15). 앞 판은 픽셀만 빼고 placement 는 그대로 실었다. 화면은 그래도 멀쩡했지만
    // (렌더가 그릴 수 없으니 넘어간다) **계측이 못 속았다** — `buildGpuImages` 의
    // `findImage(...) orelse { recordPlacementWithoutBlob(); continue; }` 가 CPU cull **앞에** 있어서,
    // 그 카운터가 「전송이 떨어졌다」와 「의도적으로 안 보냈다」를 못 가르게 됐다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    var b64: [64]u8 = undefined;
    const rgba = [_]u8{ 9, 9, 9, 255 } ** 4;
    const encoded = std.base64.standard.Encoder.encode(&b64, &rgba);
    var seq: [192]u8 = undefined;
    // 두 장을 전송한다 — 1 은 표시(`a=T`)하고 2 는 **격자만 등록**해 화면이 안 가리키게 둔다.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=1,c=2,r=1,q=2;{s}\x1b\\", .{encoded}));
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=2,q=2;{s}\x1b\\", .{encoded}));
    try core.write("\x1b_Ga=p,i=2,U=1,c=2,r=1,q=2\x1b\\"); // virtual 격자만 — placeholder 셀은 안 찍는다
    try std.testing.expect(core.kittyImageVisibleInViewport(1));
    try std.testing.expect(!core.kittyImageVisibleInViewport(2));

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(bytes);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(bytes);

    try std.testing.expect(asm_.imageById(1) != null); // 보이는 장은 픽셀이 건넜다
    try std.testing.expect(asm_.imageById(2) == null); // 안 보이는 장은 안 건넜다

    // **그리고 그 장의 placement 도 안 건넜다** — 이 줄이 이 판정자의 못이다.
    for (asm_.imagePlacements()) |p| try std.testing.expect(p.image_id != 2);
    for (asm_.imageVirtualPlacements()) |vp| try std.testing.expect(vp.image_id != 2);
    // 보이는 장의 placement 는 그대로 있다(같이 빼 버리면 화면이 빈다).
    var saw_one = false;
    for (asm_.imagePlacements()) |p| {
        if (p.image_id == 1) saw_one = true;
    }
    try std.testing.expect(saw_one);
}

test "TBPROBE 정합 ③: client 가 이미 가진 판은 픽셀을 안 보내도 placement 를 지킨다" {
    // **회귀 판정**(2026-09-15). 픽셀을 안 싣는 이유가 셋인데 **하나는 성격이 다르다.**
    // ①화면이 안 가리킴·②예산 초과는 「클라이언트가 그릴 수 없다」라 placement 도 빼야 하지만,
    // ③「이미 줬으니까」는 **그릴 수 있다**. 여기서 placement 까지 빼면 **멀쩡히 뜨던 이미지가 사라진다** —
    // 셋을 한 덩어리로 다루면 그게 진짜 회귀이므로 갈래를 따로 못 박는다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    var b64: [64]u8 = undefined;
    const rgba = [_]u8{ 7, 7, 7, 255 } ** 4;
    const encoded = std.base64.standard.Encoder.encode(&b64, &rgba);
    var seq: [192]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=5,c=2,r=1,q=2;{s}\x1b\\", .{encoded}));

    // 1) 첫 투영 — 픽셀과 placement 가 함께 간다.
    const first = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(first);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(first);
    try std.testing.expect(asm_.imageById(5) != null);

    // 2) 화면 글자만 바꾼다 — 이미지는 그대로다. 그래서 delta 는 픽셀을 **다시 보내지 않는다**.
    try core.write("hello");
    var res = try computeDelta(allocator, first, &core, .{ .generation = 1, .sequence = 1 });
    defer res.deinit(allocator);
    try std.testing.expect(!try deltaHasKind(res.delta, .image_blob)); // 픽셀 재전송 없음(이미 가졌다)

    // 3) **그런데 placement 는 사라지면 안 된다.** delta 를 적용해도 그 이미지가 계속 그려져야 한다.
    try asm_.applyDelta(res.delta);
    try std.testing.expect(asm_.imageById(5) != null); // 픽셀은 여전히 client 가 쥐고 있다
    var still_placed = false;
    for (asm_.imagePlacements()) |p| {
        if (p.image_id == 5) still_placed = true;
    }
    try std.testing.expect(still_placed);
}

test "TBPROBE 정합 ②: 거른 집합끼리 비교한다 — 안 그러면 full-set 이 매 프레임 나간다" {
    // **회귀 판정**(2026-09-15). delta 의 placement 는 **full-set 교체**다(clear 센티넬 + 전체).
    // 「바뀌었는가」 비교의 두 쪽이 서로 다른 기준이면 **매 프레임 「바뀌었다」**가 되어, 조용한 화면에도
    // 그 목록이 계속 나간다. `prev_*` 는 이전에 **보낸** 것을 파싱한 값이므로 — 즉 이미 거른 목록이므로 —
    // 현재 쪽도 **거른 목록**으로 비교해야 짝이 맞는다.
    //
    // 이 판정자가 없으면 그 어긋남이 **조용하다**: 화면은 멀쩡하고(같은 목록을 다시 보낼 뿐) 판정자도
    // 초록이며, 늘어난 바이트만 로그에 남는다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    var b64: [64]u8 = undefined;
    const rgba = [_]u8{ 3, 3, 3, 255 } ** 4;
    const encoded = std.base64.standard.Encoder.encode(&b64, &rgba);
    var seq: [192]u8 = undefined;
    // **둘 다 일반 placement 로 만든다.** 안 보이는 쪽을 virtual 격자로 두면 거른 목록이 **비어서**
    // 어긋남이 겉으로 안 드러난다(빈 목록도 clear 센티넬 하나는 나가므로 양쪽 결과가 같아진다) —
    // 실측으로 그 픽스처가 돌연변이를 못 잡았다. 거른 목록이 **비지 않아야** 차이가 보인다.
    //
    // 2 를 먼저 놓고 스크롤로 **뷰포트 위로 밀어낸다** — placement 는 남지만 화면에는 안 걸린다.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=2,c=2,r=1,q=2;{s}\x1b\\", .{encoded}));
    for (0..6) |_| try core.write("\r\n");
    try std.testing.expect(!core.kittyImageVisibleInViewport(2)); // 밀려나 안 보인다
    // 1 은 지금 화면에 놓는다 — 거른 목록에 **남는 쪽**이다.
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=1,c=2,r=1,q=2;{s}\x1b\\", .{encoded}));
    try std.testing.expect(core.kittyImageVisibleInViewport(1));

    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);
    // 1) 첫 delta — 집합이 서기 때문에 place 가 나갈 수 있다(여기서는 그 여부를 묻지 않는다).
    var first = try computeDelta(allocator, base, &core, .{ .generation = 1, .sequence = 1 });
    defer first.deinit(allocator);

    // 2) **이미지는 그대로 두고 글자만 바꾼다.** placement 집합은 안 바뀌었으므로 다시 나가면 안 된다.
    try core.write("hello");
    var second = try computeDelta(allocator, first.snapshot, &core, .{ .generation = 1, .sequence = 2 });
    defer second.deinit(allocator);
    try std.testing.expect(try deltaHasKind(second.delta, .set_runs)); // 글자는 실제로 바뀌었다(공허 통과 방지)
    try std.testing.expect(!try deltaHasKind(second.delta, .image_place));
    try std.testing.expect(!try deltaHasKind(second.delta, .image_virtual));

    // 3) 한 번 더 — 어긋남은 **매 프레임** 나타나므로 두 번째 무변화에서도 조용해야 한다.
    try core.write("!");
    var third = try computeDelta(allocator, second.snapshot, &core, .{ .generation = 1, .sequence = 3 });
    defer third.deinit(allocator);
    try std.testing.expect(!try deltaHasKind(third.delta, .image_place));
    try std.testing.expect(!try deltaHasKind(third.delta, .image_virtual));
}

test "TBPROBE 정합 ④: 한 번 보낸 이미지는 안 보이게 돼도 다시 안 보낸다" {
    // **회귀 판정**(2026-09-15, 적대적 검증). 「안 보이면 안 싣는다」가 스크롤과 만나면 위험한 모양이
    // 될 수 있었다 — 이미지가 뷰포트를 들락날락할 때마다 픽셀을 다시 보내면, 터미널 브라우저처럼
    // 한 장이 8.75 MB 인 화면에서 **스크롤이 곧 대역폭 폭발**이 된다.
    //
    // 그렇게 되지 않는 이유는 **검사 순서**다: `appendVisibleImageBlobs` 가 「client 가 이미 가진 판」을
    // **가시성보다 먼저** 보고, 그때 `drawable` 에 넣는다. 그래서 한 번 건넌 이미지는 안 보이게 돼도
    // 기록이 유지되고 재전송 후보가 되지 않는다. 그 순서가 뒤집히면 이 판정자가 빨개진다.
    const allocator = std.testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    core.setCellMetrics(10, 20);

    var b64: [64]u8 = undefined;
    const rgba = [_]u8{ 6, 6, 6, 255 } ** 4;
    const encoded = std.base64.standard.Encoder.encode(&b64, &rgba);
    var seq: [192]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=1,c=2,r=1,q=2;{s}\x1b\\", .{encoded}));
    try std.testing.expect(core.kittyImageVisibleInViewport(1));

    // 1) 보이는 동안 픽셀이 건넌다.
    const base = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(base);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(base);
    try std.testing.expect(asm_.imageById(1) != null);

    // 2) **스크롤로 밀어낸다** — 이제 화면이 그 이미지를 안 가리킨다.
    for (0..6) |_| try core.write("\r\n");
    try std.testing.expect(!core.kittyImageVisibleInViewport(1));

    // 3) 그래도 픽셀을 **다시 보내지 않는다**(client 가 이미 쥐고 있다).
    var res = try computeDelta(allocator, base, &core, .{ .generation = 1, .sequence = 1 });
    defer res.deinit(allocator);
    try std.testing.expect(!try deltaHasKind(res.delta, .image_blob));

    // 4) 그리고 그 이미지는 client 에서 사라지지도 않는다 — 회수(`image_remove`)는 코어에서 실제로
    //    없어졌을 때만이다. 안 보이는 것과 없어진 것은 다르다.
    try std.testing.expect(!try deltaHasKind(res.delta, .image_remove));
    try asm_.applyDelta(res.delta);
    try std.testing.expect(asm_.imageById(1) != null);

    // 5) **다시 보이게 해도 재전송이 없다.** 재전송은 「안 보이는 동안 기록이 지워졌는가」로 갈리므로
    //    그 다음 프레임까지 봐야 한다 — 3) 만 재면 「그 프레임에 안 보내는 것」만 확인하고 끝난다
    //    (적대적 검증에서 실제로 그 구멍을 밟았다: 검사 순서를 뒤집어도 3) 은 초록이었다).
    core.view_offset = 6; // 스크롤백을 되짚어 그 이미지가 다시 뷰포트에 걸린다
    try std.testing.expect(core.kittyImageVisibleInViewport(1));
    var back = try computeDelta(allocator, res.snapshot, &core, .{ .generation = 1, .sequence = 2 });
    defer back.deinit(allocator);
    try std.testing.expect(!try deltaHasKind(back.delta, .image_blob));
}
