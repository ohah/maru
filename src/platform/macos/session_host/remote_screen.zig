//! remote_screen — 조립기(`screen_assembler`)의 runs 모델을 renderer가 소비하는 `terminal.RenderSnapshot`(cells)로
//! 변환한다(P3-e2e-2a). §8 "중립 screen DTO" = `RenderSnapshot`이다: Metal renderer도 ANSI CLI도 같은 `RenderSnapshot`을
//! 본다. 그래서 **원격 runtime의 화면도 이 변환을 거쳐 in-process와 똑같은 DTO로 렌더**된다 — 렌더 경로가 로컬/원격에서
//! 갈리지 않는 SSOT다(host TerminalCore.snapshot()도, 이 조립기도 같은 `RenderSnapshot`을 만든다).
//!
//! 레이어: `terminal.Cell/Style/Color`를 만들어야 해서 `@import("maru")`가 필요하다(macOS 전용, barrel 조건부 —
//! screen_snapshot과 같은 부류). 조립기(순수)는 wire-native run 형태로 화면을 들고, 이 파일이 렌더 시점에 그것을 cell
//! 격자로 편다. run 색은 host가 굽지 않은 **태그드 Color intent**(§screen_stream.ColorTag·StyleFlags)라, 여기선 그 intent를
//! 풀어(unpackColorIntent) cell Color에 그대로 실어 렌더가 자기 theme로 해석하게 한다(config 16색·bold-is-bright·min-contrast·
//! default 색 — in-process와 동일). 여기서 색을 다시 "파싱"하는 게 아니라 wire intent→core Color 1:1 매핑이다(§8 "새 parser 금지").

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const screen_stream = @import("maru").session.screen_stream;
const screen_assembler = @import("maru").session.screen_assembler;
const catchup_barrier_contract = @import("catchup_barrier_contract.zig");

const Run = screen_stream.Run;
const ScreenSource = maru.session.surface.ScreenSource;

/// 조립기에서 편 소유 cell 격자. `RenderSnapshot`이 이 `cells`/`graphemes`를 빌려 렌더러에 노출한다(cells·cluster store를
/// 이 격자가 소유 — snapshot은 alias). 원격 화면이 바뀌면(delta 적용) 렌더 시점에 다시 `build`한다.
pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    cells: []terminal.Cell,
    graphemes: std.ArrayListUnmanaged([]u21),
    size: terminal.Size,
    cursor: terminal.Cursor,
    cursor_shape: terminal.CursorShape,
    viewport_scrolled: bool = false,
    ambiguous_wide: bool = false,
    // kitty 이미지(#1 I4). placements=이 격자가 소유(값 복사), images=이 격자가 배열은 소유하되 각 view의 `pixels`는
    // **조립기 픽셀을 빌린다**(zero-copy — 매 프레임 MB 복사 회피). 격자는 apply마다 재구축되고 render는 mutex 아래
    // 읽으므로(RemoteScreen), 빌린 픽셀은 격자 수명 동안 유효하다(조립기가 mutex 밖에서 안 바뀜).
    placements: []terminal.KittyPlacement = &.{},
    images: []terminal.KittyImageView = &.{},
    // 행별 OSC 133 prompt 마크(dense; 마크 없으면 empty). 이 격자가 소유(조립기 wire → terminal 타입 값 복사).
    prompt_marks: []terminal.RowPrompt = &.{},
    // host가 해석한 뷰포트 링크(없으면 empty). 이 격자가 소유(조립기 wire → terminal 타입 값 복사).
    // client는 이것만으로 Cmd+hover 밑줄을 그린다 — 로컬 core는 빈 placeholder라 스스로 감지할 수 없다.
    links: []terminal.ViewportLink = &.{},
    // 스크롤바 thumb 근거(host ScreenMeta → 조립기 → 여기). 로컬 core가 채우는 같은 이름 필드와 짝이다.
    scrollback_len: usize = 0,
    view_offset: usize = 0,

    pub fn deinit(self: *CellGrid) void {
        if (self.cells.len != 0) self.allocator.free(self.cells); // len 가드 — emptyGrid(cells=&.{})도 안전히 deinit(리뷰 #2).
        for (self.graphemes.items) |g| self.allocator.free(g);
        self.graphemes.deinit(self.allocator);
        if (self.placements.len != 0) self.allocator.free(self.placements);
        if (self.images.len != 0) self.allocator.free(self.images); // 배열만 — 픽셀은 조립기 소유.
        if (self.prompt_marks.len != 0) self.allocator.free(self.prompt_marks);
        if (self.links.len != 0) self.allocator.free(self.links);
        self.* = undefined;
    }

    /// 렌더러가 소비하는 중립 DTO. cells/graphemes는 이 격자를 빌린다(격자 수명 안에서 유효). in-process
    /// `TerminalCore.snapshot()`이 돌려주는 것과 같은 타입이라, 렌더 경로가 로컬/원격에서 동일하다.
    pub fn renderSnapshot(self: *const CellGrid) terminal.RenderSnapshot {
        return .{
            .size = self.size,
            .cursor = self.cursor,
            .viewport_scrolled = self.viewport_scrolled,
            .ambiguous_wide = self.ambiguous_wide,
            .cursor_shape = self.cursor_shape,
            .cursor_blink = true, // wire는 blink를 따로 싣지 않는다(ScreenMeta.cursor=visible+shape). 정적 렌더라 무해.
            .cells = self.cells,
            .graphemes = self.graphemes.items,
            // 이미지(#1 I4): placement + view(픽셀은 조립기 빌림)를 노출한다 — 렌더러 buildGpuImages가 image_id/generation으로
            // GPU 텍스처를 캐시해 in-process와 동일하게 그린다.
            .placements = self.placements,
            .images = self.images,
            .prompt_marks = self.prompt_marks, // OSC 133 거터(✓/✗)·prompt 네비 입력.
            .links = self.links, // Cmd+hover 밑줄·링크 커서 입력(host 해석 — docs/link-detection.md §원격(host-backed) 세션).
            .scrollback_len = self.scrollback_len, // 스크롤바 thumb(로컬은 core가 같은 필드를 채운다)
            .view_offset = self.view_offset,
            // **dirty는 반드시 세운다**(리뷰 #1): draw 경로(draw_list.zig)가 셀·커서·거터 방출 전체를 `if (snapshot.dirty)`로
            // 게이트하므로 null이면 host-backed 패널이 통째로 blank로 그려진다. 원격은 apply마다 격자를 전부 다시 뜨므로(부분
            // dirty 추적 없음) 매 프레임 전체 화면을 dirty로 노출한다(in-process가 macOS live 경로에서 fullDirty를 유지하는 것과 동형).
            .dirty = if (self.size.rows == 0) null else .{ .start_row = 0, .end_row = self.size.rows - 1 },
        };
    }
};

/// 조립기 상태를 소유 cell 격자로 편다(caller가 `CellGrid.deinit`). run(태그드 Color intent·StyleFlags)을 cell(Color intent·
/// Style bool·codepoint/grapheme_id)로 옮긴다 — 색은 host가 굽지 않은 의도라 client 렌더가 자기 theme로 푼다(theme-aware).
/// wide run(width>=2)은 lead cell(width=2) + continuation cell(width=0)로 편다.
pub fn build(allocator: std.mem.Allocator, asm_: *const screen_assembler.ScreenAssembler) error{OutOfMemory}!CellGrid {
    const cols = asm_.cols;
    const rows = asm_.rows_count;
    const cells = try allocator.alloc(terminal.Cell, @as(usize, cols) * rows);
    errdefer allocator.free(cells);
    for (cells) |*c| c.* = .{}; // blank(안 쓴 칸 codepoint=0, width=1, default style)로 채운다(누락 열 대비).

    var graphemes: std.ArrayListUnmanaged([]u21) = .empty;
    errdefer {
        for (graphemes.items) |g| allocator.free(g);
        graphemes.deinit(allocator);
    }

    var cps: std.ArrayListUnmanaged(u21) = .empty; // run별 grapheme 코드포인트 임시.
    defer cps.deinit(allocator);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const runs = asm_.rowRuns(row);
        const base = @as(usize, row) * cols;
        var col: usize = 0;
        for (runs) |run| {
            const style = runStyle(run);
            try decodeCodepoints(&cps, allocator, run.grapheme);
            const cp0: u21 = if (cps.items.len > 0) cps.items[0] else ' ';
            // cluster 본체(base 뒤 코드포인트)는 store에 한 번 담고, 이 run의 모든 반복이 같은 grapheme_id를 공유한다.
            var gid: u32 = 0;
            if (cps.items.len > 1) {
                const owned = try allocator.dupe(u21, cps.items[1..]);
                graphemes.append(allocator, owned) catch {
                    allocator.free(owned);
                    return error.OutOfMemory;
                };
                gid = @intCast(graphemes.items.len); // 1-based(grapheme_id 규약).
            }
            const wide = run.width >= 2;
            var rep: u32 = 0;
            while (rep < run.count) : (rep += 1) {
                if (col >= cols) break; // 행 overflow 방어.
                cells[base + col] = .{ .codepoint = cp0, .style = style, .width = if (wide) 2 else 1, .grapheme_id = gid };
                col += 1;
                if (wide and col < cols) {
                    cells[base + col] = .{ .style = style, .width = 0, .continuation = true }; // wide의 2번째 셀.
                    col += 1;
                }
            }
        }
    }

    // 이미지(#1 I4): placement를 terminal 타입으로 1:1 복사하고, 참조된 image_id마다 저장 이미지를 KittyImageView로 빌린다
    // (픽셀 zero-copy — 조립기 소유). 렌더러(buildGpuImages)가 이 둘로 in-process와 동일하게 그린다.
    const src_placements = asm_.imagePlacements();
    const placements: []terminal.KittyPlacement = if (src_placements.len == 0) &.{} else pl: {
        const arr = try allocator.alloc(terminal.KittyPlacement, src_placements.len);
        for (src_placements, 0..) |p, i| arr[i] = .{
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
        };
        break :pl arr;
    };
    errdefer if (placements.len != 0) allocator.free(placements);

    // 저장된 **모든** 이미지를 노출한다(in-process buildImageViews와 동일 — placement 미참조도 포함, 리뷰 #10). 맵 키가
    // unique라 dedup 불요(placement별 O(n²) 스캔 제거, 리뷰 #13). 픽셀은 조립기 소유를 빌린다(zero-copy).
    var images: std.ArrayListUnmanaged(terminal.KittyImageView) = .empty;
    errdefer images.deinit(allocator);
    var img_it = asm_.imageStoreIterator();
    while (img_it.next()) |entry| {
        const img = entry.value_ptr;
        images.append(allocator, .{
            .image_id = entry.key_ptr.*,
            .width = img.width,
            .height = img.height,
            .bpp = img.bpp,
            .generation = img.generation,
            .pixels = img.pixels,
        }) catch return error.OutOfMemory;
    }

    // prompt_marks: 조립기의 wire(RowPromptWire)를 core terminal.RowPrompt로 1:1 환산(kind u8→SemanticPrompt, 손상 방어로 clamp).
    const src_pm = asm_.promptMarks();
    const prompt_marks: []terminal.RowPrompt = if (src_pm.len == 0) &.{} else pm: {
        const arr = try allocator.alloc(terminal.RowPrompt, src_pm.len);
        for (src_pm, 0..) |w, i| arr[i] = .{
            .kind = if (w.kind <= 3) @enumFromInt(w.kind) else .unknown,
            .exit = w.exit,
        };
        break :pm arr;
    };
    errdefer if (prompt_marks.len != 0) allocator.free(prompt_marks);

    // links: 조립기의 wire(LinkSpanWire)를 core terminal.ViewportLink로 1:1 환산. kind/scope의 닫힌 범위는
    // screen_stream.decodeLinkSpans가 먼저 검증하므로 여기서 미래 값을 현재 의미로 다시 추측하지 않는다.
    // 좌표는 host가 뷰포트 상대로 이미 클립해 보냈다(§12).
    //
    // 여기서 관용 클램프(범위 밖 → .url/.web)를 걷어낸 것이 **혼합 빌드를 죽이지 않는 이유**(code-review max에서 제기됨):
    // 연결은 `validateExactClient`가 `screen_codec_version`·`wire_major`·`build_id`를 **정확히** 일치시킬 때만 성립하고
    // (`findCurrentManifestHost`도 같은 codec 일치를 요구한다), enum 확장은 codec_version bump를 동반한다. 즉 "같은 codec인데
    // 모르는 scope 값"은 새 빌드가 아니라 **정의상 손상**이고, 손상은 §12대로 record를 reject한다(조용한 degrade 금지).
    const src_links = asm_.linkSpans();
    const links: []terminal.ViewportLink = if (src_links.len == 0) &.{} else ln: {
        const arr = try allocator.alloc(terminal.ViewportLink, src_links.len);
        for (src_links, 0..) |w, i| arr[i] = .{
            .span = .{
                .start = .{ .row = w.start_row, .col = w.start_col },
                .end = .{ .row = w.end_row, .col = w.end_col },
                .block = false, // 링크 밑줄은 항상 선형(types.zig §SelectionSpan.block 주석).
            },
            .kind = @enumFromInt(w.kind),
            .scope = @enumFromInt(w.scope),
        };
        break :ln arr;
    };
    errdefer if (links.len != 0) allocator.free(links);

    // images.toOwnedSlice를 **마지막 fallible 연산**으로 둔다 — 이후 return은 실패하지 않으므로, prompt_marks/links alloc(위)이
    // 실패해도 images ArrayList의 errdefer가 그대로 덮어 누수가 없다(리뷰 #9: toOwnedSlice 뒤 prompt OOM 시 images_slice 누수 해소).
    const images_slice = images.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .allocator = allocator,
        .cells = cells,
        .graphemes = graphemes,
        .size = .{ .cols = cols, .rows = rows },
        .cursor = .{ .col = asm_.cursor.col, .row = asm_.cursor.row, .visible = asm_.cursor.visible },
        .cursor_shape = if (asm_.cursor.shape <= 2) @enumFromInt(asm_.cursor.shape) else .block, // 0=block/1=underline/2=bar.
        .viewport_scrolled = (asm_.modes & screen_stream.ModeBit.viewport_scrolled) != 0,
        .ambiguous_wide = (asm_.modes & screen_stream.ModeBit.ambiguous_wide) != 0,
        .placements = placements,
        .images = images_slice,
        .prompt_marks = prompt_marks,
        .links = links,
        .scrollback_len = asm_.scrollback_len,
        .view_offset = asm_.view_offset,
    };
}

/// grapheme UTF-8을 코드포인트 목록으로 푼다(첫 = base, 이후 = cluster 본체). 잘못된 UTF-8은 U+FFFD 하나로 대체한다(방어).
fn decodeCodepoints(out: *std.ArrayListUnmanaged(u21), allocator: std.mem.Allocator, g: []const u8) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    const view = std.unicode.Utf8View.init(g) catch {
        try out.append(allocator, 0xFFFD);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(allocator, cp);
    if (out.items.len == 0) try out.append(allocator, ' ');
}

/// Run wire의 태그드 u32 Color intent를 core `Color`로 **옮긴다**. 비트 규칙을 푸는 것은
/// `screen_stream.decodeColor` 가 하고(인코딩을 정의한 자리가 해석도 소유한다) 여기서는 그 결과를
/// 코어 타입에 담기만 한다. host 가 구운 RGB 가 아니라 의도라, client 렌더가 이 intent 를 자기
/// theme 로 해석한다(config 16색 base·bold-is-bright·min-contrast·default 색 — in-process 동일).
fn unpackColorIntent(v: u32) terminal.Color {
    return switch (screen_stream.decodeColor(v)) {
        .default => .default,
        .indexed => |index| .{ .indexed = index },
        .rgb => |c| .{ .rgb = .{ .r = c.r, .g = c.g, .b = c.b } },
    };
}

/// run의 태그드 Color intent·StyleFlags를 cell `Style`로 옮긴다. 색은 intent 그대로 실어 렌더가 theme로 풀고, flag는 bool로
/// 편다(inverse→reverse, invisible→conceal). curly underline은 wire flag엔 있지만 core Style엔 없어 생략한다.
fn runStyle(run: Run) terminal.Style {
    const SF = screen_stream.StyleFlags;
    const f = run.style_flags;
    return .{
        .foreground = unpackColorIntent(run.fg),
        .background = unpackColorIntent(run.bg),
        .underline_color = unpackColorIntent(run.underline_color),
        .bold = f & SF.bold != 0,
        .dim = f & SF.dim != 0,
        .italic = f & SF.italic != 0,
        .underline = f & SF.underline != 0,
        .underline_double = f & SF.underline_double != 0,
        .strikethrough = f & SF.strikethrough != 0,
        .overline = f & SF.overline != 0,
        .reverse = f & SF.inverse != 0,
        .blink = f & SF.blink != 0,
        .conceal = f & SF.invisible != 0,
    };
}

/// 원격 host runtime의 client 쪽 화면 소스(P3-e2e-2c). 조립기(runs 모델)를 소유하고, snapshot/delta를 적용할 때마다
/// 렌더용 `CellGrid`를 다시 편다. `Surface`에 `screenSource()`로 주입하면 그 Surface의 `renderSnapshot()`/`lockCore`가
/// 로컬 `TerminalCore` 대신 이걸 쓴다 — GUI 렌더는 로컬/원격을 모른다(SSOT, docs/persistent-session-host.md §8).
///
/// 스레딩: delta를 받는 쪽(client read)과 렌더 쪽이 다른 스레드라, 자체 `mutex`로 apply와 render를 직렬화한다(로컬
/// `core_mutex`와 동형 역할 — 단 core가 아니라 조립 화면 캐시라 owner-추적 없이 단순 std.Io.Mutex). `render_snapshot`이
/// 돌려주는 slice는 `grid`를 alias하므로 caller(Surface)가 `lock`/`unlock` 안에서 읽고 복사한다.
/// 흘려보내는 덩어리의 종류. 소비자가 "처음부터 다시" 와 "이어서" 를 갈라야 한다.
pub const ScreenByteKind = enum(u8) { snapshot = 0, delta = 1 };

/// 레코드 원본을 받아가는 자리(`maru attach --stream`). **화면 상태는 그대로 유지된다** —
/// 흘리는 것은 부수 효과이고, 안 적용하면 다음 delta 의 base 가 어긋난다(§8).
pub const ScreenByteSink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8, kind: ScreenByteKind) void,
};

pub const RemoteScreen = struct {
    allocator: std.mem.Allocator,
    assembler: screen_assembler.ScreenAssembler,
    /// 기본은 없음 — 기존 경로는 이 필드를 모른 채 그대로 돈다.
    byte_sink: ?ScreenByteSink = null,
    grid: CellGrid, // 현재 조립 상태를 편 cell 격자(apply마다 재구축, render가 읽음).
    // hello_ack capability가 없는 구 live host는 mode bit 0을 "live bottom"으로 신뢰할 수 없다.
    // attach를 소유한 RemoteRuntime이 협상 결과를 주입한다. 직접/현재 프로토콜 테스트는 true가 기본이다.
    viewport_scrolled_known: bool = true,
    mutex: std.Io.Mutex = .init,

    const source_vtable = ScreenSource.VTable{ .render_snapshot = srcRenderSnapshot, .lock = srcLock, .unlock = srcUnlock };

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!RemoteScreen {
        return initForCodec(allocator, screen_stream.codec_version);
    }

    pub fn initForCodec(allocator: std.mem.Allocator, expected_codec_version: u16) error{OutOfMemory}!RemoteScreen {
        var assembler = screen_assembler.ScreenAssembler.initForCodec(allocator, expected_codec_version);
        errdefer assembler.deinit();
        const grid = try build(allocator, &assembler); // 빈 조립기 → 0x0 격자.
        return .{ .allocator = allocator, .assembler = assembler, .grid = grid };
    }

    pub fn deinit(self: *RemoteScreen) void {
        self.grid.deinit();
        self.assembler.deinit();
        self.* = undefined;
    }

    /// `Surface.remote`에 넣을 화면 소스 핸들. Surface는 이 vtable만 알고 RemoteScreen 구체타입을 모른다(레이어 경계).
    pub fn screenSource(self: *RemoteScreen) ScreenSource {
        return .{ .ctx = self, .vtable = &source_vtable };
    }

    /// host의 snapshot record로 화면을 리셋한다(attach 첫 화면·gap 복구). 조립기를 갱신하고 렌더 격자를 다시 편다.
    pub fn applySnapshot(self: *RemoteScreen, bytes: []const u8, io: std.Io) (screen_assembler.ApplyError || error{OutOfMemory})!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        errdefer self.rebuildOrEmpty(); // 리뷰 #2: apply가 이미지 free 후 에러나면 옛 grid가 freed 픽셀을 빌려 UAF — 실패해도 grid를 현재 조립기로 재구축.
        self.emitBytes(bytes, .snapshot);
        try self.assembler.applySnapshot(bytes);
        try self.rebuildGrid();
    }

    pub fn requireSequencedDeltas(self: *RemoteScreen) void {
        self.assembler.requireSequencedDeltas();
    }

    pub fn catchupFrontier(self: *const RemoteScreen) catchup_barrier_contract.ScreenFrontier {
        return .{
            .generation = self.assembler.generation,
            .sequence = self.assembler.sequence,
        };
    }

    pub fn prepareRecoveryFrontierFrom(self: *RemoteScreen, current: *const RemoteScreen) void {
        self.assembler.prepareRecoveryFrontierFrom(&current.assembler);
    }

    /// host의 delta record를 적용한다(화면 증분). base_generation gap이면 `GenerationGap`(caller가 fresh snapshot 재요청).
    pub fn applyDelta(self: *RemoteScreen, bytes: []const u8, io: std.Io) (screen_assembler.ApplyError || error{OutOfMemory})!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        errdefer self.rebuildOrEmpty(); // 리뷰 #2: 위와 동형(delta가 putImage로 옛 픽셀 free 후 손상 record면 dangling).
        self.emitBytes(bytes, .delta);
        try self.assembler.applyDelta(bytes);
        try self.rebuildGrid();
    }

    /// 지금 조립 상태를 **snapshot 레코드 스트림으로 다시 직렬화**한다(`--stream` 의 첫 덩어리).
    /// caller 가 소유한다. 락 아래에서 만든다 — 그리는 쪽과 같은 규칙이다.
    pub fn snapshotBytes(self: *RemoteScreen, allocator: std.mem.Allocator, io: std.Io) screen_stream.DecodeError![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.assembler.toSnapshot(allocator);
    }

    /// **레코드 원본을 그대로 넘겨보는 자리**(`maru attach --stream`, §8). 여기 하나만 두는 이유는
    /// apply 호출처가 다섯 곳이라 그쪽에 심으면 하나를 빠뜨리기 때문이다 — 초기 snapshot 도 같은
    /// 경로로 온다. sink 가 없으면(기본) 아무 일도 안 한다.
    ///
    /// **적용보다 먼저 부른다.** 조립이 실패해도 소비자는 그 바이트를 봐야 같은 실패를 자기 쪽에서
    /// 재현할 수 있고, 성공한 것만 흘리면 두 조립기의 상태가 조용히 갈린다.
    fn emitBytes(self: *RemoteScreen, bytes: []const u8, kind: ScreenByteKind) void {
        const sink = self.byte_sink orelse return;
        sink.write(sink.ctx, bytes, kind);
    }

    /// Publishes a fully assembled recovery snapshot without exposing its fallible construction.
    /// `prepared` is private to the consumer until its transport authority has survived release
    /// and post-release mark; swapping only the owned model/grid keeps this screen's stable mutex
    /// and `ScreenSource.ctx` address intact.
    pub fn publishPreparedSnapshot(
        self: *RemoteScreen,
        prepared: *RemoteScreen,
        io: std.Io,
    ) void {
        std.debug.assert(self.allocator.ptr == prepared.allocator.ptr);
        std.debug.assert(self.allocator.vtable == prepared.allocator.vtable);
        std.debug.assert(
            self.assembler.expected_codec_version ==
                prepared.assembler.expected_codec_version,
        );
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.mem.swap(screen_assembler.ScreenAssembler, &self.assembler, &prepared.assembler);
        std.mem.swap(CellGrid, &self.grid, &prepared.grid);
        std.mem.swap(
            bool,
            &self.viewport_scrolled_known,
            &prepared.viewport_scrolled_known,
        );
    }

    /// agent observer용 최근 화면 UTF-8. host raw PTY를 다시 보내지 않고 이미 조립된 row run을 같은 mutex 아래 읽는다.
    /// local `TerminalCore.dumpRecentTextUtf8`와 같이 마지막 256 blank row를 역스캔해 마지막 text anchor에서 max_rows를
    /// 선택하고, 행 전체 공백과 UTF-8 grapheme 경계를 보존한다.
    pub fn dumpRecentTextUtf8(self: *RemoteScreen, allocator: std.mem.Allocator, io: std.Io, max_rows: usize, max_bytes: usize) error{OutOfMemory}![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        if (max_rows == 0 or max_bytes == 0 or self.assembler.rows_count == 0)
            return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
        const rows: usize = self.assembler.rows_count;
        var last_row_exclusive = rows;
        const scan_floor = rows - @min(rows, 256);
        var found_text = false;
        while (last_row_exclusive > scan_floor) {
            const runs = self.assembler.rowRuns(@intCast(last_row_exclusive - 1));
            for (runs) |run| {
                for (run.grapheme) |byte| {
                    if (byte != ' ') {
                        found_text = true;
                        break;
                    }
                }
                if (found_text) break;
            }
            if (found_text) break;
            last_row_exclusive -= 1;
        }
        if (!found_text) last_row_exclusive = rows;
        const worst_row_bytes = @as(usize, self.assembler.cols) *| 4 +| 1;
        const byte_bounded_rows = @max(1, max_bytes / @max(1, worst_row_bytes));
        const selected_rows = @min(last_row_exclusive, @min(max_rows, byte_bounded_rows));
        const start = last_row_exclusive - selected_rows;
        var row = start;
        var capped = false;
        while (row < last_row_exclusive and !capped) : (row += 1) {
            if (row != start) {
                if (out.items.len == max_bytes) break;
                out.append(allocator, '\n') catch return error.OutOfMemory;
            }
            for (self.assembler.rowRuns(@intCast(row))) |run| {
                var rep: u32 = 0;
                while (rep < run.count) : (rep += 1) {
                    if (run.grapheme.len > max_bytes -| out.items.len) {
                        capped = true;
                        break;
                    }
                    out.appendSlice(allocator, run.grapheme) catch return error.OutOfMemory;
                }
                if (capped) break;
            }
        }
        return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// 같은 MRSH major지만 `runtime_selected_text_v1` 이전인 host를 위한 제한적 호환 adapter. 이미 수신해 렌더 중인
    /// viewport cell projection에서만 선택을 추출한다. 이 wire에는 행별 soft-wrap bit가 없으므로 multi-row 선형 선택은
    /// 각 화면 행 사이에 명시적으로 `\n`을 넣는다. 단일 행·block은 cell/grapheme projection만으로 정확히 복원된다.
    pub fn extractVisibleSelection(
        self: *RemoteScreen,
        allocator: std.mem.Allocator,
        io: std.Io,
        span: terminal.SelectionSpan,
    ) error{OutOfMemory}!?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const cols: usize = self.grid.size.cols;
        const rows: usize = self.grid.size.rows;
        if (cols == 0 or rows == 0 or self.grid.cells.len < cols * rows) return null;
        if (span.start.row >= rows or span.end.row >= rows) return null;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (span.block) {
            const start_row: usize = @min(span.start.row, span.end.row);
            const end_row: usize = @max(span.start.row, span.end.row);
            const lo: usize = @min(span.start.col, span.end.col);
            const hi: usize = @min(@max(span.start.col, span.end.col), cols - 1);
            var row = start_row;
            while (row <= end_row) : (row += 1) {
                const cells = self.grid.cells[row * cols ..][0..cols];
                const from = @min(lo, cols);
                const to = @max(from, @min(hi + 1, terminal.textTrimmedLen(cells)));
                try appendCellsUtf8(&out, allocator, cells, self.grid.graphemes.items, from, to);
                if (row != end_row) try out.append(allocator, '\n');
            }
        } else {
            const reversed = span.start.row > span.end.row or
                (span.start.row == span.end.row and span.start.col > span.end.col);
            const start_row = if (reversed) span.end.row else span.start.row;
            const start_col = if (reversed) span.end.col else span.start.col;
            const end_row = if (reversed) span.start.row else span.end.row;
            const end_col = if (reversed) span.start.col else span.end.col;
            var row: usize = start_row;
            while (row <= end_row) : (row += 1) {
                const cells = self.grid.cells[row * cols ..][0..cols];
                const from: usize = if (row == start_row) @min(start_col, cols) else 0;
                const full_to: usize = if (row == end_row) @min(@as(usize, end_col) + 1, cols) else cols;
                const to = @max(from, @min(full_to, terminal.textTrimmedLen(cells)));
                try appendCellsUtf8(&out, allocator, cells, self.grid.graphemes.items, from, to);
                // 구 screen wire에는 soft-wrap bit가 없다. 줄을 임의로 붙여 clipboard 내용을 변조하지 않고, 보이는
                // viewport 행 경계를 그대로 보존하는 보수적 정책을 쓴다.
                if (row != end_row) try out.append(allocator, '\n');
            }
        }
        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    fn rebuildGrid(self: *RemoteScreen) error{OutOfMemory}!void {
        const new_grid = try build(self.allocator, &self.assembler);
        self.grid.deinit();
        self.grid = new_grid;
    }

    /// apply 실패 경로용(리뷰 #2): grid를 현재 조립기 상태로 다시 뜬다. 재구축까지 OOM이면 **빈 grid**로 대체해 dangling
    /// 픽셀을 확실히 끊는다(옛 grid는 deinit으로 회수 — 픽셀은 조립기 소유라 grid deinit이 안 만짐). 절대 dangling을 안 남긴다.
    fn rebuildOrEmpty(self: *RemoteScreen) void {
        self.rebuildGrid() catch {
            self.grid.deinit();
            self.grid = .{ .allocator = self.allocator, .cells = &.{}, .graphemes = .empty, .size = .{ .cols = 0, .rows = 0 }, .cursor = .{}, .cursor_shape = .block };
        };
    }

    fn srcRenderSnapshot(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        var snapshot = self.grid.renderSnapshot();
        // Legacy MRSH v2 host에는 viewport mode bit이 없지만, 그 wire는 live bottom에서만
        // visible cursor를 보내고 scrollback에서는 cursor를 숨긴다. 따라서 visible=true인
        // 이 snapshot 하나에 한해 live bottom임을 안전하게 증명할 수 있다. 이 증거를
        // RemoteScreen 상태에 latch하면 다음 hidden/scrolled snapshot을 live로 오인하므로,
        // 파생 snapshot에만 적용한다. hidden은 DECTCEM-hidden live와 scrollback을 구분할 수
        // 없어 계속 unknown/fail-closed다.
        snapshot.viewport_scrolled_known = self.viewport_scrolled_known or snapshot.cursor.visible;
        return snapshot;
    }
    fn srcLock(ctx: *anyopaque, io: std.Io) void {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
    }
    fn srcUnlock(ctx: *anyopaque, io: std.Io) void {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        self.mutex.unlock(io);
    }
};

fn appendCellsUtf8(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cells: []const terminal.Cell,
    graphemes: []const []const u21,
    from: usize,
    to: usize,
) error{OutOfMemory}!void {
    var it: terminal.RowCodepoints = .{ .cells = cells[from..to], .graphemes = graphemes };
    var buf: [4]u8 = undefined;
    while (it.next()) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        out.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트 (macOS — terminal.Cell/Style 필요)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 원격 runtime의 화면이 in-process와 **같은 RenderSnapshot**으로
// 렌더돼야 렌더 경로가 하나로 유지된다(SSOT). 조립기가 든 run을 cell로 펴서 텍스트·wide 셀·색·커서·grapheme cluster가
// 정확한지, 그리고 실 화면을 투영→조립→cell로 펴면 원본 화면의 텍스트·레이아웃과 일치하는지 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_snapshot = @import("screen_snapshot.zig");

test "remote screen: build converts runs to cells (text, wide cell, rgb color, style, cluster)" {
    const allocator = testing.allocator;
    const SF = screen_stream.StyleFlags;
    const Tag = screen_stream.ColorTag;
    // row 0: bold rgb빨강 "h", wide "한"(2셀, indexed 2), 결합 문자 "e\u{0301}"(cluster, default fg), 공백.
    // 색은 태그드 Color intent다 — build가 이 intent를 풀어 셀 Color에 그대로 실어야 렌더가 theme로 해석한다.
    // Σ(width*count)=1+2+1+1=5=cols.
    var runs0 = [_]Run{
        .{ .grapheme = "h", .width = 1, .count = 1, .fg = (Tag.rgb << Tag.shift) | 0xFF0000, .style_flags = SF.bold },
        .{ .grapheme = "한", .width = 2, .count = 1, .fg = (Tag.indexed << Tag.shift) | 2 },
        .{ .grapheme = "e\u{0301}", .width = 1, .count = 1 }, // fg 미지정 = 0 = default intent.
        .{ .grapheme = " ", .width = 1, .count = 1 },
    };
    const row0: screen_stream.Row = .{ .row_index = 0, .runs = &runs0 };
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    {
        const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 5, .rows = 1, .cursor = .{ .col = 4, .row = 0 } });
        defer allocator.free(meta_rec);
        try screen_stream.appendRecord(&stream, allocator, meta_rec);
        const row_rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = 1 }, row0);
        defer allocator.free(row_rec);
        try screen_stream.appendRecord(&stream, allocator, row_rec);
    }

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);

    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const snap = grid.renderSnapshot();

    try testing.expectEqual(@as(u16, 5), snap.size.cols);
    try testing.expectEqual(@as(u16, 4), snap.cursor.col);
    // cell 0: "h", width 1, bold, fg = rgb intent(0xFF0000) → `.rgb` Color 그대로.
    try testing.expectEqual(@as(u21, 'h'), snap.cells[0].codepoint);
    try testing.expectEqual(@as(u2, 1), snap.cells[0].width);
    try testing.expect(snap.cells[0].style.bold);
    try testing.expectEqual(terminal.Color{ .rgb = .{ .r = 0xFF, .g = 0, .b = 0 } }, snap.cells[0].style.foreground);
    // cell 1: "한"(U+D55C), width 2, fg = indexed intent(2) → `.indexed` 유지(렌더가 config 16색으로 푼다); cell 2: continuation.
    try testing.expectEqual(@as(u21, 0xD55C), snap.cells[1].codepoint);
    try testing.expectEqual(@as(u2, 2), snap.cells[1].width);
    try testing.expectEqual(terminal.Color{ .indexed = 2 }, snap.cells[1].style.foreground);
    try testing.expect(snap.cells[2].continuation);
    // cell 3: "e" + 결합 acute(U+0301) → codepoint 'e' + grapheme_id로 cluster 본체 참조. fg = default intent(0) → `.default`.
    try testing.expectEqual(terminal.Color.default, snap.cells[3].style.foreground);
    try testing.expectEqual(@as(u21, 'e'), snap.cells[3].codepoint);
    try testing.expect(snap.cells[3].grapheme_id != 0);
    try testing.expectEqual(@as(u21, 0x0301), snap.graphemes[snap.cells[3].grapheme_id - 1][0]);
}

test "remote screen: projection→assembler→cells preserves a real screen's text and layout" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("한A bc"); // wide + narrow 혼합.

    const p = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 2 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const remote = grid.renderSnapshot();

    // 조립→cell 결과가 원본 core 화면과 셀별 codepoint·width·continuation이 같다(색은 표현이 달라 텍스트·레이아웃만 대조).
    const local = core.snapshot();
    try testing.expectEqual(local.size.cols, remote.size.cols);
    try testing.expectEqual(local.size.rows, remote.size.rows);
    try testing.expectEqual(local.cells.len, remote.cells.len);
    for (local.cells, remote.cells, 0..) |lc, rc, i| {
        // 빈 칸은 양쪽 다 "안 쓴 칸"(codepoint 0)이거나 공백으로 나올 수 있다 — 표현이 아니라 **보이는
        // 글자**가 같은지를 본다. 한쪽만 정규화하면 셀 모델이 바뀔 때 거짓 실패한다.
        const lcp: u21 = if (lc.codepoint == 0) ' ' else lc.codepoint;
        const rcp: u21 = if (rc.codepoint == 0) ' ' else rc.codepoint;
        try testing.expectEqual(lcp, rcp);
        try testing.expectEqual(lc.width, rc.width);
        try testing.expectEqual(lc.continuation, rc.continuation);
        _ = i;
    }
    try testing.expectEqual(local.cursor.col, remote.cursor.col);
    try testing.expectEqual(local.cursor.row, remote.cursor.row);
}

test "remote screen: legacy visible selection reads the assembled projection with explicit row boundaries" {
    const allocator = testing.allocator;
    const io = testing.io;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 3 });
    defer core.deinit();
    try core.write("abcde\r\nxy\r\ne\u{0301}한Z");
    const projected = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(projected);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(projected, io);

    const linear = (try rs.extractVisibleSelection(allocator, io, .{
        .start = .{ .row = 0, .col = 1 },
        .end = .{ .row = 1, .col = 1 },
    })).?;
    defer allocator.free(linear);
    try testing.expectEqualStrings("bcde\nxy", linear);

    const block = (try rs.extractVisibleSelection(allocator, io, .{
        .start = .{ .row = 0, .col = 1 },
        .end = .{ .row = 1, .col = 3 },
        .block = true,
    })).?;
    defer allocator.free(block);
    try testing.expectEqualStrings("bcd\ny", block);

    const cluster = (try rs.extractVisibleSelection(allocator, io, .{
        .start = .{ .row = 2, .col = 0 },
        .end = .{ .row = 2, .col = 0 },
    })).?;
    defer allocator.free(cluster);
    try testing.expectEqualStrings("e\u{0301}", cluster);

    const wide = (try rs.extractVisibleSelection(allocator, io, .{
        .start = .{ .row = 2, .col = 1 },
        .end = .{ .row = 2, .col = 3 },
    })).?;
    defer allocator.free(wide);
    try testing.expectEqualStrings("한Z", wide);
}

test "remote screen: a Surface backed by RemoteScreen renders the assembled remote screen, updated by delta" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    // host 화면을 투영해 원격 screen에 적용한다("remote!").
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("remote!");
    const snap = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(snap);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(snap, io);
    const recent_first = try rs.dumpRecentTextUtf8(allocator, io, 2, 128);
    defer allocator.free(recent_first);
    const local_recent_first = try core.dumpRecentTextUtf8(allocator, 2, 128);
    defer allocator.free(local_recent_first);
    try testing.expectEqualStrings(local_recent_first, recent_first);

    // Surface에 원격 소스를 주입한다. 로컬 core는 빈 화면 — renderSnapshot이 로컬이 아니라 조립된 원격을 줘야 한다.
    var surface = try Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    const rendered = surface.renderSnapshot();
    const c0 = rendered.cells[0].codepoint; // lock 아래에서 값만 복사(현행 계약).
    const c1 = rendered.cells[1].codepoint;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u21, 'r'), c0); // 로컬 core라면 공백이었을 것 — 원격이 반영됐다.
    try testing.expectEqual(@as(u21, 'e'), c1);

    // host 화면을 바꾸고 delta를 적용하면 Surface.renderSnapshot이 반영한다.
    try core.write("\r\nsecond"); // row1 = "second".
    const d = try screen_snapshot.computeDelta(allocator, snap, &core, .{ .generation = 1 });
    defer d.deinit(allocator);
    try rs.applyDelta(d.delta, io);
    const recent_second = try rs.dumpRecentTextUtf8(allocator, io, 1, 128);
    defer allocator.free(recent_second);
    const local_recent_second = try core.dumpRecentTextUtf8(allocator, 1, 128);
    defer allocator.free(local_recent_second);
    try testing.expectEqualStrings(local_recent_second, recent_second);

    surface.lockCore(io);
    const r2 = surface.renderSnapshot();
    const row1_c0 = r2.cells[10].codepoint; // row1 col0.
    surface.unlockCore(io);
    try testing.expectEqual(@as(u21, 's'), row1_c0);
}

test "remote screen: client-local preedit follows host width policy and latest grid without mutating it" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.ambiguous_wide = true;
    try core.write("ab");
    const initial = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(initial);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(initial, io);

    var surface = try Surface.init(allocator, 1, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    try testing.expect(surface.setPreeditLocked("③")); // EAW ambiguous: host policy=true일 때만 2셀
    const composed = surface.renderSnapshot();
    try testing.expect(composed.ambiguous_wide);
    try testing.expectEqual(@as(u21, 0x2462), composed.cells[2].codepoint);
    try testing.expectEqual(@as(u2, 2), composed.cells[2].width);
    try testing.expect(composed.cells[3].continuation);
    try testing.expect(composed.cells[2].style.reverse);
    try testing.expect(!composed.cursor.visible);
    try testing.expectEqual(@as(u21, ' '), rs.grid.cells[2].codepoint);
    surface.unlockCore(io);

    // preedit 활성 중에도 host delta가 canonical grid를 갱신한다. 다음 render는 저장해 둔 옛
    // 화면이 아니라 최신 base cursor 위에 같은 client-local overlay를 다시 합성해야 한다.
    try core.write("\r\nxy");
    const delta = try screen_snapshot.computeDelta(allocator, initial, &core, .{ .generation = 1 });
    defer delta.deinit(allocator);
    try rs.applyDelta(delta.delta, io);

    surface.lockCore(io);
    const recomposed = surface.renderSnapshot();
    try testing.expectEqual(@as(u21, 0x2462), recomposed.cells[10].codepoint); // row1 col2
    try testing.expect(recomposed.cells[11].continuation);
    try testing.expectEqual(@as(u21, ' '), rs.grid.cells[10].codepoint); // canonical host grid remains unchanged
    try testing.expect(surface.setPreeditLocked(""));
    const cleared = surface.renderSnapshot();
    try testing.expectEqual(@as(u21, ' '), cleared.cells[10].codepoint);
    try testing.expect(cleared.cursor.visible);
    surface.unlockCore(io);
}

test "remote screen: preedit does not render at hidden origin while host viewport is scrolled" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("one\r\ntwo\r\nthree");
    const live_cursor = core.snapshot().cursor;
    core.scrollViewport(1);
    try testing.expect(core.viewOffset() > 0);
    const scrolled_records = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(scrolled_records);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(scrolled_records, io);
    var surface = try Surface.init(allocator, 2, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    try testing.expect(surface.baseViewportScrolledLocked() == true);
    try testing.expect(surface.setPreeditLocked("한"));
    const hidden = surface.renderSnapshot();
    try testing.expect(hidden.viewport_scrolled);
    try testing.expectEqual(rs.grid.cells[0].codepoint, hidden.cells[0].codepoint);
    try testing.expect(hidden.cursor.visible == rs.grid.cursor.visible);
    try testing.expect(!hidden.cursor.visible);
    try testing.expectEqual(live_cursor.row, surface.baseCursorLocked().?.row);
    try testing.expectEqual(live_cursor.col, surface.baseCursorLocked().?.col);
    surface.unlockCore(io);

    // AppSession.imeBegin은 이 flag를 보고 host scroll_to_bottom을 요청한다. 그 결과 delta가
    // 도착하면 같은 overlay가 live base cursor에 처음 나타난다.
    core.scrollToBottom();
    const live_delta = try screen_snapshot.computeDelta(allocator, scrolled_records, &core, .{ .generation = 1 });
    defer live_delta.deinit(allocator);
    try rs.applyDelta(live_delta.delta, io);

    surface.lockCore(io);
    const base_cursor = surface.baseCursorLocked().?;
    const live = surface.renderSnapshot();
    try testing.expect(!live.viewport_scrolled);
    const cursor_index = @as(usize, base_cursor.row) * live.size.cols + base_cursor.col;
    try testing.expectEqual(@as(u21, 0xD55C), live.cells[cursor_index].codepoint);
    surface.unlockCore(io);
}

test "remote screen: old host visible cursor proves live viewport for client-local preedit" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("base");
    const records = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(records);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(records, io);
    rs.viewport_scrolled_known = false;

    var surface = try Surface.init(allocator, 3, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    defer surface.unlockCore(io);
    try testing.expect(surface.setPreeditLocked("한"));
    const rendered = surface.renderSnapshot();
    try testing.expect(rendered.viewport_scrolled_known);
    try testing.expect(!rendered.viewport_scrolled);
    try testing.expectEqual(@as(u21, 'b'), rendered.cells[0].codepoint);
    try testing.expectEqual(@as(u21, 0xD55C), rendered.cells[4].codepoint);
    const base_cursor = surface.baseCursorLocked().?;
    try testing.expectEqual(@as(u16, 0), base_cursor.row);
    try testing.expectEqual(@as(u16, 4), base_cursor.col);
    try testing.expect(surface.baseViewportScrolledLocked() == false);
}

test "remote screen: old host hidden cursor remains ambiguous and live evidence is not latched" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("base");
    const records = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(records);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(records, io);
    rs.viewport_scrolled_known = false;

    // Legacy wire에서 visible cursor는 그 snapshot이 live bottom이라는 증거지만, 이 판정은
    // 상태에 latch하면 안 된다. 다음 snapshot이 hidden이면 scrollback과 DECTCEM-hidden live
    // 화면을 구분할 수 없으므로 다시 unknown으로 내려가야 한다.
    const source = rs.screenSource();
    try testing.expect(source.vtable.render_snapshot(source.ctx).viewport_scrolled_known);
    rs.grid.cursor.row = 0;
    rs.grid.cursor.col = 0;
    rs.grid.cursor.visible = false;

    var surface = try Surface.init(allocator, 4, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    defer surface.unlockCore(io);
    try testing.expect(surface.setPreeditLocked("한"));
    const rendered = surface.renderSnapshot();
    try testing.expect(!rendered.viewport_scrolled_known);
    try testing.expectEqualSlices(terminal.Cell, rs.grid.cells, rendered.cells);
    try testing.expect(surface.baseCursorLocked() == null);
    try testing.expect(surface.baseViewportScrolledLocked() == null);
}

test "remote screen: current host capability keeps hidden live cursor authoritative" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("base");
    const records = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(records);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(records, io);
    try testing.expect(rs.viewport_scrolled_known);
    rs.grid.cursor.visible = false; // DECTCEM hidden at live bottom, not scrollback.

    var surface = try Surface.init(allocator, 5, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    defer surface.unlockCore(io);
    try testing.expect(surface.setPreeditLocked("한"));
    const rendered = surface.renderSnapshot();
    try testing.expect(rendered.viewport_scrolled_known);
    try testing.expect(!rendered.viewport_scrolled);
    try testing.expectEqual(@as(u21, 0xD55C), rendered.cells[4].codepoint);
    const base_cursor = surface.baseCursorLocked().?;
    try testing.expectEqual(@as(u16, 0), base_cursor.row);
    try testing.expectEqual(@as(u16, 4), base_cursor.col);
    try testing.expect(!base_cursor.visible);
    try testing.expect(surface.baseViewportScrolledLocked() == false);
}

test "remote screen: build exposes kitty images + placements from the assembler (I4)" {
    const allocator = testing.allocator;
    // 이미지가 실린 snapshot 스트림: meta + image_blob(2x1 RGBA) + image_placement(row 1, col 2, z 3).
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 4, .rows = 2 });
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    const px = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const blob_rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 1 }, .{ .image_id = 5, .generation = 9, .width = 2, .height = 1, .bpp = 4, .pixels = &px });
    defer allocator.free(blob_rec);
    try screen_stream.appendRecord(&stream, allocator, blob_rec);
    const pl_rec = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_placement, .generation = 1 }, .{ .image_id = 5, .placement_id = 0, .row = 1, .col = 2, .columns = 2, .rows = 1, .z = 3 });
    defer allocator.free(pl_rec);
    try screen_stream.appendRecord(&stream, allocator, pl_rec);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);

    // build가 조립기의 이미지/placement를 renderSnapshot에 노출한다(픽셀은 조립기 빌림 — zero-copy).
    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const snap = grid.renderSnapshot();

    try testing.expectEqual(@as(usize, 1), snap.placements.len);
    try testing.expectEqual(@as(u32, 5), snap.placements[0].image_id);
    try testing.expectEqual(@as(u16, 2), snap.placements[0].col);
    try testing.expectEqual(@as(i32, 1), snap.placements[0].row);
    try testing.expectEqual(@as(i32, 3), snap.placements[0].z);
    try testing.expectEqual(@as(u32, 2), snap.placements[0].columns);

    try testing.expectEqual(@as(usize, 1), snap.images.len);
    try testing.expectEqual(@as(u32, 5), snap.images[0].image_id);
    try testing.expectEqual(@as(u32, 2), snap.images[0].width);
    try testing.expectEqual(@as(u8, 4), snap.images[0].bpp);
    try testing.expectEqual(@as(u64, 9), snap.images[0].generation); // 렌더러 GPU 캐시 키.
    try testing.expectEqualSlices(u8, &px, snap.images[0].pixels);
}

/// **원격 파이프라인 parity 인프라(#1 이후 드리프트 방어).** in-process `renderSnapshot`과 원격 파이프라인
/// (`projectSnapshot`→`ScreenAssembler`→`build`)의 결과가 **렌더 관점에서 동등**한지 단언한다. 원격이 싣기로 한 축
/// (size·cursor·cursor_shape·cells[style·색 intent·grapheme 해석]·graphemes·placements·images·prompt_marks·**dirty**[전체화면
/// 불변식])을 비교하고, 의도적 드롭(cursor_blink 하드코딩·last_command_exit)은 제외한다. **comptime로 `RenderSnapshot`의 모든
/// 필드가 "비교" 또는 "드롭"으로 분류됐는지 강제**한다 — 새 필드가 추가되면 여기서 **컴파일 에러**가 나 원격 경로 배선(투영/
/// 조립/노출)을 잊지 않게 한다. 색·이미지·dirty가 조용히 유실됐던(리뷰 #1 blank 렌더) 재발을 막는 안전망이다.
fn expectSnapshotParity(local_core: *const terminal.TerminalCore, local: terminal.RenderSnapshot, remote: terminal.RenderSnapshot) !void {
    // ── comptime 필드 커버리지: RenderSnapshot 새 필드는 반드시 아래 둘 중 하나로 분류돼야 한다 ──
    const compared = [_][]const u8{ "size", "cursor", "cursor_shape", "viewport_scrolled", "viewport_scrolled_known", "ambiguous_wide", "cells", "graphemes", "placements", "images", "prompt_marks", "links", "scrollback_len", "view_offset", "dirty" };
    const dropped = [_][]const u8{ "cursor_blink", "last_command_exit" };
    comptime {
        for (@typeInfo(terminal.RenderSnapshot).@"struct".fields) |f| {
            var classified = false;
            for (compared) |c| {
                if (std.mem.eql(u8, f.name, c)) classified = true;
            }
            for (dropped) |d| {
                if (std.mem.eql(u8, f.name, d)) classified = true;
            }
            if (!classified) @compileError("RenderSnapshot 필드 '" ++ f.name ++ "'가 parity 테스트에서 미분류다 — 원격 경로에 실었으면 `compared`에, 의도적 드롭이면 `dropped`에 추가하라(드리프트 방어).");
        }
    }

    // size.
    try testing.expectEqual(local.size.cols, remote.size.cols);
    try testing.expectEqual(local.size.rows, remote.size.rows);
    // cursor(+shape). cursor_blink는 원격이 항상 true(의도적 드롭)라 제외.
    try testing.expectEqual(local.cursor.col, remote.cursor.col);
    try testing.expectEqual(local.cursor.row, remote.cursor.row);
    try testing.expectEqual(local.cursor.visible, remote.cursor.visible);
    try testing.expectEqual(local.cursor_shape, remote.cursor_shape);
    try testing.expectEqual(local.viewport_scrolled, remote.viewport_scrolled);
    try testing.expectEqual(local.viewport_scrolled_known, remote.viewport_scrolled_known);
    try testing.expectEqual(local.ambiguous_wide, remote.ambiguous_wide);
    // cells: codepoint(0→space 정규화)·width·continuation·style(색 Color intent 포함 전 필드)·grapheme cluster(store id 번호는
    // 다를 수 있어 해석된 본체로 대조).
    try testing.expectEqual(local.cells.len, remote.cells.len);
    for (local.cells, remote.cells) |lc, rc| {
        // 빈 칸은 양쪽 다 "안 쓴 칸"(codepoint 0)이거나 공백으로 나올 수 있다 — 표현이 아니라 **보이는
        // 글자**가 같은지를 본다. 한쪽만 정규화하면 셀 모델이 바뀔 때 거짓 실패한다.
        const lcp: u21 = if (lc.codepoint == 0) ' ' else lc.codepoint;
        const rcp: u21 = if (rc.codepoint == 0) ' ' else rc.codepoint;
        try testing.expectEqual(lcp, rcp);
        try testing.expectEqual(lc.width, rc.width);
        try testing.expectEqual(lc.continuation, rc.continuation);
        try testing.expectEqual(lc.style, rc.style); // foreground/background/underline_color(Color intent) + bold/dim/italic/… 전부.
        if (lc.grapheme_id != 0) {
            try testing.expect(rc.grapheme_id != 0);
            try testing.expectEqualSlices(u21, local.graphemes[lc.grapheme_id - 1], remote.graphemes[rc.grapheme_id - 1]);
        } else {
            try testing.expectEqual(@as(u32, 0), rc.grapheme_id);
        }
    }
    // placements: 순서·전 필드 동일(원격 placement_list = 투영 순서 = local buildPlacementViews 순서).
    try testing.expectEqual(local.placements.len, remote.placements.len);
    for (local.placements, remote.placements) |lp, rp| try testing.expectEqual(lp, rp);
    // images: local은 전체(map 순), remote는 placement 참조분(placement 순)이라 image_id로 매칭 비교(순서 무관).
    for (remote.images) |ri| {
        var matched = false;
        for (local.images) |li| {
            if (li.image_id != ri.image_id) continue;
            try testing.expectEqual(li.width, ri.width);
            try testing.expectEqual(li.height, ri.height);
            try testing.expectEqual(li.bpp, ri.bpp);
            try testing.expectEqual(li.generation, ri.generation);
            try testing.expectEqualSlices(u8, li.pixels, ri.pixels);
            matched = true;
        }
        try testing.expect(matched); // 원격이 노출한 이미지는 로컬에 반드시 있다.
    }
    // 원격 placement가 참조하는 이미지가 원격 images에 다 있는지(누락 방어).
    for (remote.placements) |rp| {
        if (rp.image_id == 0) continue;
        var have = false;
        for (remote.images) |ri| {
            if (ri.image_id == rp.image_id) have = true;
        }
        try testing.expect(have);
    }
    // prompt_marks(OSC 133): local은 항상 length-rows(core), remote는 마크 없으면 empty이므로 행별 의미로 대조(범위 밖=default).
    var pr: u16 = 0;
    while (pr < local.size.rows) : (pr += 1) {
        const lm: terminal.RowPrompt = if (pr < local.prompt_marks.len) local.prompt_marks[pr] else .{};
        const rm: terminal.RowPrompt = if (pr < remote.prompt_marks.len) remote.prompt_marks[pr] else .{};
        try testing.expectEqual(lm.kind, rm.kind);
        try testing.expectEqual(lm.exit, rm.exit);
    }
    // links(Cmd+hover 밑줄): local snapshot은 이 필드를 **항상 비워 둔다**(로컬은 hover 시점에 core를 직접 분류).
    // 그래서 값 대조 대신, 원격이 실은 목록이 **같은 화면을 로컬 분류기로 돌린 결과와 동일**한지 본다 — 이게 진짜
    // parity다(host 해석과 client 로컬 해석이 갈리면 "밑줄 보이는 곳 ≠ 열리는 곳"이 된다).
    try testing.expectEqual(@as(usize, 0), local.links.len);
    {
        var expected: std.ArrayList(terminal.ViewportLink) = .empty;
        defer expected.deinit(testing.allocator);
        try local_core.collectViewportLinks(testing.allocator, terminal.link_scopes_full, &expected);
        try testing.expectEqual(expected.items.len, remote.links.len);
        for (expected.items, remote.links) |e, r| {
            try testing.expectEqual(e.span.start.row, r.span.start.row);
            try testing.expectEqual(e.span.start.col, r.span.start.col);
            try testing.expectEqual(e.span.end.row, r.span.end.row);
            try testing.expectEqual(e.span.end.col, r.span.end.col);
            try testing.expectEqual(e.kind, r.kind);
            try testing.expectEqual(e.scope, r.scope);
        }
    }
    // 스크롤 상태: 로컬 core가 채우는 값과 원격이 wire로 받은 값이 같아야 스크롤바 thumb이 동일하게 그려진다.
    // (예전엔 원격이 이 값을 아예 못 받아 client가 placeholder의 0을 읽었고, 그래서 스크롤바가 안 떴다.)
    try testing.expectEqual(local.scrollback_len, remote.scrollback_len);
    try testing.expectEqual(local.view_offset, remote.view_offset);
    // dirty(리뷰 #1): 원격은 반드시 non-null·전체 화면이어야 draw 경로가 셀/커서/거터를 방출한다(null이면 blank 렌더).
    // local과의 값 비교보다 이 **불변식**을 못박아, 누가 remote.dirty를 null로 되돌리면 여기서 실패하게 한다.
    try testing.expect(remote.dirty != null);
    try testing.expectEqual(@as(u16, 0), remote.dirty.?.start_row);
    if (remote.size.rows > 0) try testing.expectEqual(remote.size.rows - 1, remote.dirty.?.end_row);
}

test "remote screen: full RenderSnapshot parity with in-process (styles, colors, wide, grapheme, cursor shape, image)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();
    core.ambiguous_wide = true; // renderer policy bit도 host→client parity 대상으로 태운다.

    // 다양한 스타일·색축을 한 화면에 태운다 — 하나라도 원격 경로에서 유실되면 parity가 깨진다.
    try core.write("\x1b[1;31mB\x1b[0m"); // bold + indexed(ANSI 1 red)
    try core.write("\x1b[3;38;5;120mI\x1b[0m"); // italic + 256색(120)
    try core.write("\x1b[4;38;2;10;20;30mU\x1b[0m"); // underline + truecolor rgb
    try core.write("\x1b[7mR\x1b[0m"); // reverse
    try core.write("\x1b[2;9mD\x1b[0m"); // dim + strikethrough
    try core.write("한"); // wide CJK(width 2 + continuation)
    try core.write("e\u{0301}"); // grapheme cluster(e + combining acute)
    try core.write("\x1b[4 q"); // DECSCUSR: underline 커서 모양
    try core.write("\r\n\x1b]133;A\x1b\\$ x"); // OSC 133 A: 다음 행을 prompt로 마킹 — prompt_marks 축을 실제로 태운다.
    try core.write("\r\ngo https://example.com/p"); // 링크 축(자동 감지) — links parity가 all-empty로 헛통과하지 않게.

    // kitty 이미지 transmit+display(2x2 RGBA, i=1).
    var raw = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x11 };
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [96]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));

    // 원격 파이프라인: 투영 → 조립 → 격자.
    const p = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 7 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    var grid = try build(allocator, &asm_);
    defer grid.deinit();

    // in-process 기준 화면(뷰포트 인지 — projectSnapshot과 같은 소스)과 렌더 관점 동등성 단언.
    const local = core.renderSnapshot();
    // fixture가 실제로 prompt 마크를 만들었는지(=prompt_marks 경로를 태우는지) 보장 — 안 그러면 all-default parity로 헛통과.
    var has_mark = false;
    for (local.prompt_marks) |m| if (m.kind != .unknown) {
        has_mark = true;
    };
    try testing.expect(has_mark);
    // 링크 축도 같은 이유로 non-empty를 보장한다 — 원격이 링크를 통째로 안 실어도 "둘 다 0개"로 헛통과하면
    // 이 회귀(host-backed에서 밑줄 무동작)를 parity가 못 잡는다.
    try testing.expect(grid.renderSnapshot().links.len > 0);
    try expectSnapshotParity(&core, local, grid.renderSnapshot());
}

test "remote screen: host-backed snapshot renders drawable cells via the real draw path (review #1)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();
    try core.write("hi");

    // 원격 파이프라인으로 격자 구성(host 투영 → 조립 → 격자).
    const p = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    var grid = try build(allocator, &asm_);
    defer grid.deinit();

    // **실제 draw 경로**에 원격 renderSnapshot을 태운다 — CellGrid가 dirty=null을 냈다면(리뷰 #1) buildDrawList가 빈 DrawList를
    // 내 host-backed 패널이 blank로 그려진다. 여기서 cells 방출 + 내용('h')이 실림을 단언해, parity가 DTO만 검증하던 갭을
    // **실 렌더 게이트(draw_list.zig의 if(snapshot.dirty))**까지 확장한다(이 테스트가 #1 재발을 컴파일/CI로 잡는다).
    var dl = try maru.renderer.buildDrawList(allocator, grid.renderSnapshot());
    defer dl.deinit(allocator);
    try testing.expect(dl.cells.len > 0); // blank 아님(dirty가 전체화면으로 세워져 셀이 방출됨).
    var found_h = false;
    for (dl.cells) |c| {
        if (c.codepoint == 'h') found_h = true;
    }
    try testing.expect(found_h); // 원격 격자 내용이 실제 draw cell로 렌더된다.
}
