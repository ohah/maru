//! kitty graphics — 이미지 transmit(디코드+저장)·display(placement)·delete·render-view 합성.
//!
//! `TerminalCore`(core.zig)가 VT 파서 + 화면 storage + host-reply + 선택 + kitty graphics를 한 struct에 섞은
//! 구조 위반(docs/project-rules.md "구조와 파일 분리")을 목적별 파일로 떼어낸 결과다. parser는 이미 APC 파싱
//! (parseKittyGraphicsCommand·dispatchApc, 분할 7/N)만 갖고, 여기는 그 파싱 결과(KittyGraphicsCommand)를 받아
//! 픽셀을 디코드·저장(KittyImageStorage)하고 placement(StoredPlacement)를 관리하며 렌더용 view(types.KittyPlacement/
//! KittyImageView)로 합성하는 "graphics 본체"를 모은다. 각 함수는 `*TerminalCore`를 받는 free 함수다(필드 직접
//! 접근 — Zig는 필드 privacy가 없다; osc/parser/screen/selection와 동형). 저장 struct 4개는 self-contained라
//! (TerminalCore 미참조) 여기 두고 core가 필드로 보유한다(Scrollback 선례 — core가 `const X = kitty.X` 별칭).
//!
//! 좌표계: placement anchor_row는 절대 행(스크롤백 0..sb_count-1, 이어서 활성 화면)이라 selection/find와 같은
//! 좌표계로 스크롤·eviction에 따라 보정된다(shiftPlacementsForEviction). render-view 합성(buildPlacementViews/
//! buildImageViews)은 외부 점-호출이 아니라 screen.snapshot이 부르므로 core facade로 잔류(screen→kitty 역전 방지).
//!
//! 키보드 protocol(KittyFlags/KittyFlagStack)은 별개 subsystem이라 core에 남는다(parser가 씀). kitty graphics
//! protocol을 베이스로 하되 image storage(map+total_bytes·LRU evict·320MB 한계)는 maru 단순 설계다 — 단일 출처:
//! docs/plans/terminal-core-decomposition.md §8.

const std = @import("std");
const core = @import("core.zig");
const types = @import("types.zig");
const png = @import("png.zig"); // f=100 PNG 디코드 + zlib(o=z) inflateExact

const TerminalCore = core.TerminalCore;

/// kitty graphics APC control의 파싱 결과(주요 key). transmit(s/v/f/o)와 display(나머지) 양쪽 키를
/// 한 구조체에 담는다 — a 값(t/T/p/d)이 어느 필드를 쓰는지 정한다. 렌더는 후속이다.
/// parser.parseKittyGraphicsCommand의 결과 DTO이자 exec/storage 입력 — parser가 cross-file로 이름을 쓰므로 pub.
pub const KittyGraphicsCommand = struct {
    action: u8 = 't', // a: t=transmit / T=transmit+display / q=query / p=display / d=delete
    format: u16 = 32, // f: 24=RGB / 32=RGBA / 100=PNG
    width: u32 = 0, // s: 이미지 픽셀 폭
    height: u32 = 0, // v: 이미지 픽셀 높이
    image_id: u32 = 0, // i
    // I: client 가 정하는 image **number**. 터미널이 여기에 image id 를 배정하고 응답에 둘 다 싣는다.
    // `i=` 가 함께 오면 그쪽이 이긴다(명세: id 가 더 구체적인 지정이다).
    image_number: u32 = 0,
    more: bool = false, // m: 1이면 chunk가 이어짐
    compression: u8 = 0, // o: 'z'=zlib
    // --- display(placement) 키 — a=p/T에서 쓴다. 베이스: kitty graphics protocol display data. ---
    placement_id: u32 = 0, // p: placement 식별자(0=default)
    src_x: u32 = 0, // x: source 사각형 좌상단 x(이미지 픽셀)
    src_y: u32 = 0, // y: source 사각형 좌상단 y
    src_width: u32 = 0, // w: source 사각형 폭(0=전체)
    src_height: u32 = 0, // h: source 사각형 높이(0=전체)
    cell_x_offset: u32 = 0, // X: 첫 셀 내 픽셀 x 오프셋
    cell_y_offset: u32 = 0, // Y: 첫 셀 내 픽셀 y 오프셋
    columns: u32 = 0, // c: 표시할 열 수(0=auto)
    rows: u32 = 0, // r: 표시할 행 수(0=auto)
    z: i32 = 0, // z: z-index(부호 있음)
    no_cursor_move: bool = false, // C=1이면 표시 후 커서를 옮기지 않음
    // P/Q: **relative placement** 의 부모(이미지 id·placement id). 0 이면 절대 배치다.
    // H/V: 부모 좌상단 셀에서의 변위(셀 단위, 부호 있음 — 양수는 오른쪽·아래).
    // 베이스: kitty graphics protocol "relative placements".
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    delete_what: u8 = 'a', // d: 삭제 타깃(a=d일 때). 기본 'a'(전체). 대문자=이미지 데이터도 free, 소문자=placement만
    // q: 응답 억제 수준(0=OK와 에러 모두, 1=에러만, 2=침묵). 베이스: kitty graphics protocol의 quiet.
    quiet: u8 = 0,
    // U=1: unicode placeholder(virtual placement) — 커서 자리에 그리지 않고 등록만 하고, 실제 배치는
    // 화면의 U+10EEEE placeholder 셀이 정한다. 베이스: kitty graphics protocol "Unicode placeholders".
    virtual: bool = false,
    // t: 전송 매체(d=direct base64, f=파일, t=임시파일, s=공유메모리). **maru는 direct만 구현한다** —
    // 파일/공유메모리는 payload가 픽셀이 아니라 **경로/이름**이라, 파싱하지 않으면 그것을 픽셀로 오인해
    // 조용히 버린다(실측 2026-09-08: t=f 전송이 무음 폐기됐다). 여기서 값을 읽어 `ENOTSUPP`로 **명시
    // 거부**해야 앱이 direct로 폴백한다(terminal-browser는 t=s→t=f→inline 순으로 물어본다).
    medium: u8 = 'd',
};

/// kitty graphics 명령의 처리 결과 — 응답(`ESC _ G i=<id>;<코드> ESC \`)의 본문이 된다.
/// 베이스: kitty graphics protocol "Control data — responses"(OK 또는 `<ERRCODE>:<msg>`).
pub const KittyStatus = enum {
    ok,
    einval, // control/payload가 잘못됐다(형식·치수·base64·디코드 실패)
    enoent, // 참조한 이미지가 없다(display)
    enotsupp, // maru가 구현하지 않은 기능(전송 매체·애니메이션)
    enomem, // 저장 실패(한 장이 한도 초과, evict로도 자리 부족)

    /// 응답 본문. 에러는 `<코드>:<사람이 읽는 짧은 이유>` 형식이다(kitty 명세).
    pub fn text(self: KittyStatus) []const u8 {
        return switch (self) {
            .ok => "OK",
            .einval => "EINVAL:bad graphics command",
            .enoent => "ENOENT:no such image",
            .enotsupp => "ENOTSUPP:unsupported graphics feature",
            .enomem => "ENOMEM:image storage full",
        };
    }
};

/// 저장된 kitty graphics placement(표시 중인 이미지 인스턴스). anchor_row는 절대 행(스크롤백
/// 0..sb_count-1, 이어서 활성 화면)이라 selection/find와 같은 좌표계로 스크롤·eviction에 따라
/// 보정돼 내용과 함께 움직인다. 렌더 시 renderSnapshot이 뷰포트 상대 types.KittyPlacement로 환산한다.
/// 셀 단위 크기는 담지 않는다(코어는 셀 픽셀 크기를 모름 — 렌더러가 환산).
pub const StoredPlacement = struct {
    image_id: u32,
    placement_id: u32,
    anchor_row: usize, // 절대 행
    anchor_col: u16,
    cell_x_offset: u32,
    cell_y_offset: u32,
    src_x: u32,
    src_y: u32,
    src_width: u32,
    src_height: u32,
    columns: u32,
    rows: u32,
    z: i32,
    /// 부모 placement(relative placement) — 0 이면 절대 배치다. 부모가 지워지면 **이 placement 도
    /// 함께 지워진다**(명세: "The lifetime of a relative placement is tied to the lifetime of its
    /// parent"). 위치는 저장 시점에 굳히지 않고 **렌더 뷰를 만들 때** 부모에서 푼다 — 부모가
    /// 움직이면 따라가야 하기 때문이다.
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_offset_x: i32 = 0,
    parent_offset_y: i32 = 0,
    /// **이 placement 가 속한 화면.** kitty 명세에서 그래픽은 화면에 귀속된다 — alt 화면(vim 이
    /// 쓰는 그것)으로 넘어가면 primary 의 이미지는 보이지 않아야 하고, 돌아오면 다시 보여야 한다.
    /// `anchor_row` 는 그 화면 기준 절대 행이라 화면이 다르면 **좌표계 자체가 다르다** — 섞어
    /// 그리면 엉뚱한 자리에 찍힌다(실측: vim 화면 위에 셸의 이미지가 그대로 떴다).
    on_alt: bool = false,
};

/// 디코드된 kitty graphics 이미지(픽셀 버퍼를 소유). bpp=3(RGB)/4(RGBA). generation은 storage가
/// (재)transmit마다 단조 증가로 찍어 주는 업로드 캐시 무효화 키다(렌더러가 image_id별 텍스처를
/// 이 값이 바뀔 때만 다시 업로드 — K2d).
/// 애니메이션 프레임 하나. **완전한 픽셀을 굳혀 담는다** — 「베이스 프레임 + 델타」로 두면 매 frame
/// 마다 합성을 다시 해야 하고, 그 합성이 렌더 경로에 들어온다. kitty 도 프레임을 합성해 굳힌다.
const KittyFrame = struct {
    data: []u8,
    /// 이 프레임을 보여 줄 시간(ms). 0 이면 기본값(`default_frame_gap_ms`)을 쓴다 — 명세가 `z=0` 을
    /// 「기본」으로 정한다. **음수 gap(`z<0`)은 「건너뛴다」**는 뜻이라 여기서는 `skip` 으로 표현한다.
    gap_ms: u32 = 0,
    /// 이 프레임을 재생에서 건너뛰는가(`z<0`). 지우는 것과 다르다 — 번호는 유지되고 합성 베이스로는
    /// 여전히 쓸 수 있다.
    skip: bool = false,
};

/// `z=0`(또는 미지정) 프레임이 머무는 기본 시간. 명세가 값을 정하지 않아 kitty 의 관례를 따른다.
pub const default_frame_gap_ms: u32 = 40;

/// 애니메이션 재생 상태(`a=a` 의 `s=`). 1=정지, 2=로딩(프레임을 더 기다림), 3=재생.
const KittyAnimState = enum(u8) { stopped = 1, loading = 2, running = 3 };

pub const KittyImage = struct {
    id: u32,
    width: u32,
    height: u32,
    bpp: u8,
    /// **프레임 1(루트)의 픽셀.** 애니메이션이 없으면 이것이 전부다.
    data: []u8,
    generation: u64 = 0, // KittyImageStorage.add가 채운다
    /// 프레임 2..N. 비어 있으면 정지 이미지다 — 그 경우 아래 애니메이션 필드는 전부 무의미하다.
    frames: []KittyFrame = &.{},
    /// 프레임 1 의 gap/skip(프레임 2..N 은 `frames` 가 들고 있다).
    root_gap_ms: u32 = 0,
    root_skip: bool = false,
    anim_state: KittyAnimState = .stopped,
    /// 지금 보여 주는 프레임(**1-based**). 명세가 프레임 번호를 1 부터 센다.
    current_frame: u32 = 1,
    /// 남은 반복 수. 0 이면 무한이다(명세: `v=0` 이 기본이자 무한).
    loops_left: u32 = 0,
    /// 현재 프레임에 머문 시간(ms). `advanceAnimations` 가 쌓고 gap 을 넘으면 다음으로 넘긴다.
    elapsed_ms: u64 = 0,

    /// 프레임 개수(루트 포함).
    pub fn frameCount(self: KittyImage) u32 {
        return 1 + @as(u32, @intCast(self.frames.len));
    }

    /// 1-based 프레임 번호의 픽셀. 범위 밖이면 루트를 준다 — 렌더가 빈 화면이 되는 것보다 낫다.
    pub fn framePixels(self: KittyImage, n: u32) []const u8 {
        if (n <= 1 or n > self.frameCount()) return self.data;
        return self.frames[n - 2].data;
    }

    pub fn frameGapMs(self: KittyImage, n: u32) u32 {
        const raw = if (n <= 1 or n > self.frameCount()) self.root_gap_ms else self.frames[n - 2].gap_ms;
        return if (raw == 0) default_frame_gap_ms else raw;
    }

    pub fn frameSkipped(self: KittyImage, n: u32) bool {
        if (n <= 1 or n > self.frameCount()) return self.root_skip;
        return self.frames[n - 2].skip;
    }

    /// 이 이미지가 차지하는 바이트(루트 + 모든 프레임). 총량 회계·evict 가 이 값을 쓴다 — 프레임을
    /// 빼먹으면 애니메이션 하나가 상한을 우회해 메모리를 무한히 먹는다.
    pub fn totalBytes(self: KittyImage) usize {
        var n = self.data.len;
        for (self.frames) |f| n += f.data.len;
        return n;
    }

    pub fn freeAll(self: KittyImage, alloc: std.mem.Allocator) void {
        for (self.frames) |f| alloc.free(f.data);
        if (self.frames.len > 0) alloc.free(self.frames);
        alloc.free(self.data);
    }
};

/// kitty graphics 이미지 저장소(image_id → KittyImage). 총량 한계로 악의적/대량 전송을 막는다.
/// 같은 id 교체 + 총량 한계. 한계 초과 시 거부가 아니라 LRU evict(generation 기준, placement 없는·
/// 오래된 것 우선)를 `addKittyImageEvicting`가 수행한다(K4b 완료). 베이스: kitty graphics protocol
/// image storage. struct 자체는 map + total_bytes만 담고 evict 결정·placement는 바깥(kitty.zig)이다.
pub const KittyImageStorage = struct {
    map: std.AutoHashMapUnmanaged(u32, KittyImage) = .{},
    total_bytes: usize = 0,
    /// 세션 내 단조 증가 카운터 — add마다 다음 generation을 찍는다. clear/RIS에서 **리셋하지
    /// 않는다**(같은 image_id가 비운 뒤 재전송돼도 새 generation을 받아 렌더러 캐시가 stale을
    /// 재사용하지 않게). u64라 현실적으로 wrap 없음.
    gen_counter: u64 = 0,
    /// 한 세션이 kitty graphics 이미지로 잡을 수 있는 메모리 상한 — maru가 정한 실용 값이다(kitty
    /// 명세는 상한을 규정하지 않으므로 과대/악의적 전송 폭주를 막는 방어선으로 둔다). 대형 이미지
    /// 수십~수백 장을 담되 무한 누적을 차단하는 선에서 320MB로 잡았다. 한도 초과 시 evict(K4b)로
    /// 자리를 만든다. 필드라 테스트가 작게 설정할 수 있다(Ghostty total_limit과 동형).
    limit: usize = 320 * 1000 * 1000,

    pub fn deinit(self: *KittyImageStorage, alloc: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |img| img.freeAll(alloc);
        self.map.deinit(alloc);
    }
    pub fn clear(self: *KittyImageStorage, alloc: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |img| img.freeAll(alloc);
        self.map.clearRetainingCapacity();
        self.total_bytes = 0;
    }
    /// 이미지를 저장한다 — img.data의 소유권을 가져간다(성공=map 보관, 거부/실패=즉시 free).
    /// 성공 시 새 generation을 찍어(같은 id 교체도 새 값) 렌더러 업로드 캐시를 무효화한다.
    fn add(self: *KittyImageStorage, alloc: std.mem.Allocator, img: KittyImage) void {
        if (self.map.fetchRemove(img.id)) |old| { // 같은 id는 교체(기존 free — 프레임까지)
            self.total_bytes -= old.value.totalBytes();
            old.value.freeAll(alloc);
        }
        if (self.total_bytes + img.totalBytes() > self.limit) { // 한계 초과면 거부
            img.freeAll(alloc);
            return;
        }
        var stored = img;
        self.gen_counter += 1;
        stored.generation = self.gen_counter;
        self.map.put(alloc, stored.id, stored) catch {
            stored.freeAll(alloc);
            return;
        };
        self.total_bytes += stored.totalBytes();
    }
    fn remove(self: *KittyImageStorage, alloc: std.mem.Allocator, id: u32) void {
        if (self.map.fetchRemove(id)) |old| {
            self.total_bytes -= old.value.totalBytes();
            old.value.freeAll(alloc);
        }
    }
};

// ── placement·render-view leaf (다른 kitty fn 호출 없음 — 필드·types만) ────────────────────────────

/// display(cmd.rows 미지정)에서 이미지 셀 높이를 자동 환산한다. 셀 메트릭(cell_height_px) 없으면 0.
fn kittyAdvanceRows(self: *const TerminalCore, cmd: KittyGraphicsCommand) u16 {
    if (cmd.rows > 0) return @intCast(@min(cmd.rows, @as(u32, std.math.maxInt(u16))));
    if (self.cell_height_px == 0) return 0; // 셀 메트릭 미보유 — 자동 크기 환산 불가
    const img = self.kitty_images.map.get(cmd.image_id) orelse return 0;
    const geom = types.PlacementGeometry.compute(
        img.width,
        img.height,
        cmd.src_x,
        cmd.src_y,
        cmd.src_width,
        cmd.src_height,
        cmd.columns,
        cmd.rows,
        self.cell_width_px,
        self.cell_height_px,
    ) orelse return 0;
    const span = @ceil(geom.dest_h / @as(f32, @floatFromInt(self.cell_height_px)));
    return @intFromFloat(@min(span, 65535.0));
}

/// placement를 추가하거나 같은 (image_id, placement_id, 화면)이면 교체한다. 상한 초과면 거부(graceful),
/// OOM이면 표시를 포기한다(절대 panic 없음 — 출력 경로 견고성).
///
/// **화면이 키에 들어간다.** alt 화면의 TUI 가 같은 (image_id, placement_id) 를 쓰면 primary 의
/// placement 를 덮어써 버리고, alt 를 떠난 뒤 셸 화면의 이미지가 사라진다 — 두 화면은 좌표계도
/// 수명도 다르므로 자리도 따로 쓴다.
fn addOrReplacePlacement(self: *TerminalCore, p: StoredPlacement) void {
    for (self.kitty_placements.items) |*existing| {
        if (existing.image_id == p.image_id and existing.placement_id == p.placement_id and
            existing.on_alt == p.on_alt)
        {
            existing.* = p;
            return;
        }
    }
    if (self.kitty_placements.items.len >= core.TerminalCore.max_kitty_placements) return; // 폭주 방어선
    self.kitty_placements.append(self.allocator, p) catch {};
}

/// alt 화면에서 만들어진 placement 를 전부 버린다(`leaveAltScreen` 이 부른다). 이미지는 건드리지
/// 않는다 — 픽셀은 세션 소유이고 primary 에서 다시 배치될 수 있다.
pub fn dropAltScreenPlacements(self: *TerminalCore) void {
    var i: usize = 0;
    while (i < self.kitty_placements.items.len) {
        if (self.kitty_placements.items[i].on_alt) {
            _ = self.kitty_placements.orderedRemove(i);
        } else i += 1;
    }
}

/// 특정 image_id의 placement를 모두 제거한다(delete 시 이미지와 함께). 순서를 보존해(orderedRemove)
/// 노출 순서를 결정적으로 둔다 — placement 수는 작아 비용이 무시할 만하다.
fn removePlacementsForImage(self: *TerminalCore, image_id: u32) void {
    var i: usize = 0;
    while (i < self.kitty_placements.items.len) {
        if (self.kitty_placements.items[i].image_id == image_id) {
            _ = self.kitty_placements.orderedRemove(i);
        } else i += 1;
    }
}

/// (image_id, placement_id) 한 placement만 제거한다(delete d=i + p 지정).
fn removeOnePlacement(self: *TerminalCore, image_id: u32, placement_id: u32) void {
    for (self.kitty_placements.items, 0..) |p, i| {
        if (p.image_id == image_id and p.placement_id == placement_id) {
            _ = self.kitty_placements.orderedRemove(i);
            return;
        }
    }
}

/// 가장 오래된 n개 행이 빠질 때 placement anchor(abs 행)를 n칸 당긴다(eviction n=1, 하향 트림 n=drop).
/// 빠진 행 범위 [0, n)에 anchor가 걸린 placement는 제거한다. selection의 shiftSelectionForEviction과 같은 규율.
pub fn shiftPlacementsForEviction(self: *TerminalCore, n: usize) void {
    if (n == 0) return;
    var i: usize = 0;
    while (i < self.kitty_placements.items.len) {
        const p = &self.kitty_placements.items[i];
        if (p.anchor_row < n) {
            _ = self.kitty_placements.orderedRemove(i);
        } else {
            p.anchor_row -= n;
            i += 1;
        }
    }
}

/// 이미지에 살아있는 placement가 있는지(evict 우선순위 판정용).
pub fn kittyImageHasPlacement(self: *const TerminalCore, image_id: u32) bool {
    for (self.kitty_placements.items) |p| {
        if (p.image_id == image_id) return true;
    }
    return false;
}

/// 이 이미지가 **지금 뷰포트에 한 줄이라도 걸쳐 있는가.** placement 가 있기만 한 것과 다르다 —
/// 위로 스크롤해 지나간 이미지도 placement 는 남는다(스크롤백을 되짚으면 다시 보여야 하므로 옳다).
///
/// 애니메이션 전진이 이것을 묻는 이유: 안 보이는 프레임은 CPU 만 쓰는 게 아니라 **대역폭을 쓴다**.
/// 프레임이 넘어가면 `generation` 이 오르고, 화면 스트리밍은 generation 이 바뀐 이미지의 픽셀을
/// 통째로 다시 싣는다. 실측(적대적 검증 3회차): 100 줄 밖으로 스크롤된 32x32 애니메이션이 delta 에
/// placement **없이** blob 4,153 바이트를 매 프레임 실었다 — client 가 그릴 수 없는 픽셀이다.
///
/// virtual placement(U=1)는 화면 위치를 코어가 모른다(placeholder 셀이 정한다). 그래서 그런
/// 이미지는 「보인다」고 본다 — 모르는 것을 안 보인다고 단정해 멈추면 도는 애니메이션이 죽는다.
pub fn kittyImageVisibleInViewport(self: *TerminalCore, image_id: u32) bool {
    for (self.kitty_virtual_placements.items) |v| {
        if (v.image_id == image_id) return true;
    }
    const rows: i64 = @intCast(self.size.rows);
    const top_abs: i64 = @intCast(self.screen.sb.count - @min(self.view_offset, self.screen.sb.count));
    for (self.kitty_placements.items) |p| {
        if (p.image_id != image_id) continue;
        if (p.on_alt != self.alt_active) continue; // 다른 화면 = 안 보인다 = 돌 필요 없다
        // 상대 placement 는 부모가 정한다 — 부모를 못 풀면 렌더도 그리지 않으므로 여기서도 뺀다
        // (`buildPlacementViews` 와 같은 판단이라야 「보이는데 안 돈다」가 생기지 않는다).
        var anchor_row = p.anchor_row;
        if (p.parent_image_id != 0) {
            const resolved = resolveRelativeAnchor(self, p) orelse continue;
            anchor_row = resolved.row;
        }
        const start = @as(i64, @intCast(anchor_row)) - top_abs;
        const span: i64 = @intCast(placementCellSpan(self, p).rows);
        if (start < rows and start + span > 0) return true; // 한 줄이라도 겹치면 보인다
    }
    return false;
}

/// 저장된 placement(절대 행)를 뷰포트 상대 types.KittyPlacement로 환산해 재사용 버퍼에 담아 돌려준다.
/// placement가 없으면 빈 슬라이스(할당 없음). 화면 위/아래로 벗어났는지의 판단은 셀 span을 아는 렌더러 몫이라
/// 코어는 모든 placement를 그대로 환산해 노출한다(row는 i32 — 음수 가능). top_abs는 뷰포트 최상단의 절대 행이다.
pub fn buildPlacementViews(self: *TerminalCore, top_abs: usize) []const types.KittyPlacement {
    const n = self.kitty_placements.items.len;
    if (n == 0) return &.{};
    if (self.placement_views.len != n) {
        if (self.placement_views.len > 0) self.allocator.free(self.placement_views);
        self.placement_views = self.allocator.alloc(types.KittyPlacement, n) catch {
            self.placement_views = &.{};
            return &.{}; // OOM이면 placement 노출만 포기(렌더는 후속이라 영향 없음)
        };
    }
    var out: usize = 0;
    for (self.kitty_placements.items) |p| {
        // **다른 화면의 placement 는 그리지 않는다.** 지우지도 않는다 — alt 를 떠나면 primary 의
        // 이미지가 그 자리에 다시 나타나야 한다(vim 을 닫으면 그 전 화면이 그대로 돌아오는 것과 같다).
        if (p.on_alt != self.alt_active) continue;
        // relative placement 는 **여기서** 부모 위치를 푼다 — 저장 시점에 굳히면 부모가 움직여도
        // 안 따라간다(명세는 따라가야 한다고 정한다). 부모가 없거나 virtual(화면 위치를 코어가
        // 모른다)이면 **그리지 않는다** — 엉뚱한 자리에 놓는 것보다 낫다.
        var anchor_row = p.anchor_row;
        var anchor_col = p.anchor_col;
        if (p.parent_image_id != 0) {
            const resolved = resolveRelativeAnchor(self, p) orelse continue;
            anchor_row = resolved.row;
            anchor_col = resolved.col;
        }
        const row_i64 = @as(i64, @intCast(anchor_row)) - @as(i64, @intCast(top_abs));
        self.placement_views[out] = .{
            .image_id = p.image_id,
            .placement_id = p.placement_id,
            // 행 오프셋은 작은 값이라 i32에 들지만, 극단값은 포화시켜 안전하게 둔다.
            .row = std.math.cast(i32, row_i64) orelse (if (row_i64 < 0) std.math.minInt(i32) else std.math.maxInt(i32)),
            .col = anchor_col,
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
        out += 1;
    }
    return self.placement_views[0..out];
}

/// 저장된 kitty graphics 이미지를 KittyImageView로 빌려 재사용 버퍼에 담아 돌려준다. 이미지가 없으면 빈
/// 슬라이스(할당 없음). 픽셀은 복사하지 않고 storage 버퍼를 가리킨다(zero-copy). map 순회 순서는 비결정적이지만
/// 렌더러는 image_id로 찾으므로 무관하다.
pub fn buildImageViews(self: *TerminalCore) []const types.KittyImageView {
    const n = self.kitty_images.map.count();
    if (n == 0) return &.{};
    if (self.image_views.len != n) {
        if (self.image_views.len > 0) self.allocator.free(self.image_views);
        self.image_views = self.allocator.alloc(types.KittyImageView, n) catch {
            self.image_views = &.{};
            return &.{}; // OOM이면 이미지 노출만 포기(렌더는 후속이라 영향 없음)
        };
    }
    var i: usize = 0;
    var it = self.kitty_images.map.valueIterator();
    while (it.next()) |img| : (i += 1) {
        self.image_views[i] = .{
            .image_id = img.id,
            .width = img.width,
            .height = img.height,
            .bpp = img.bpp,
            .generation = img.generation,
            // **현재 프레임의 픽셀**을 노출한다 — 애니메이션은 여기서 프레임을 갈아 끼우고
            // `generation` 을 올리는 것으로 끝난다(렌더러 텍스처 캐시가 그 키로 무효화된다).
            .pixels = img.framePixels(img.current_frame),
        };
    }
    return self.image_views[0..i];
}

// ── storage/evict mid (leaf 위에 빌드 — orchestrator가 호출) ───────────────────────────────────────

/// 이미지를 저장하되, 320MB 한도를 넘기면 먼저 evict해 자리를 만든다(K4b). 한 장이 한도보다 크면 거부.
/// 같은 id 교체분은 회수되니 계산에서 뺀다. evict 정책은 evictKittyImagesFor — placement 없는 것·오래된
/// 것 우선(kitty 명세 권장). evict 후에도 못 들어가면 add가 한도 체크로 거부한다(graceful, img.data free).
/// 저장에 성공했으면 true. 실패(한 장이 한도 초과, evict로도 자리 부족)는 호출자가 `ENOMEM`으로 회신한다.
fn storeKittyImage(self: *TerminalCore, img: KittyImage) bool {
    if (img.data.len > self.kitty_images.limit) { // 한 장이 전체 한도 초과 — 불가
        self.allocator.free(img.data);
        return false;
    }
    const existing: usize = if (self.kitty_images.map.get(img.id)) |old| old.data.len else 0;
    const after = self.kitty_images.total_bytes - existing + img.data.len;
    if (after > self.kitty_images.limit) {
        evictKittyImagesFor(self, after - self.kitty_images.limit, img.id); // 부족분만큼 자리 확보
    }
    self.kitty_images.add(self.allocator, img); // 같은-id 교체 + 최종 한도 체크(evict 후 통과)
    // add가 한도로 거부하면 같은 id의 기존 이미지는 이미 제거됐고(같은-id 교체 규칙) 새 것도 안 들어가
    // map에 그 id가 없다 — 그 id를 가리키던 placement가 orphan으로 남지 않게 함께 정리한다(code review #8).
    if (!self.kitty_images.map.contains(img.id)) {
        removePlacementsForImage(self, img.id);
        return false;
    }
    return true;
}

/// 한도 초과 시 부족분(needed 바이트) 이상을 비우도록 이미지를 evict한다(exclude_id·그 이미지는 제외 —
/// 지금 넣으려는 새 이미지). 한 번에 한 장씩, **placement 없는(안 쓰이는) 것 중 오래된(generation 작은) 것**
/// 만 고른다(kitty 명세 "unused first"; Ghostty 동작 비교). 화면 표시 중(used)인 이미지는 보호한다 —
/// 모두 쓰이면 후보가 없어 멈추고(이후 add가 새 이미지를 거부), 화면 이미지를 조용히 지우지 않는다
/// (code review #9). placement/이미지 수가 작아 비용은 무시할 만하다.
fn evictKittyImagesFor(self: *TerminalCore, needed: usize, exclude_id: u32) void {
    var freed: usize = 0;
    while (freed < needed) {
        const victim = pickKittyEvictionVictim(self, exclude_id) orelse break;
        const sz = if (self.kitty_images.map.get(victim)) |im| im.data.len else 0;
        removePlacementsForImage(self, victim); // 안전망(victim은 unused라 보통 placement 없음)
        self.kitty_images.remove(self.allocator, victim);
        freed += sz;
    }
}

/// evict 후보를 고른다 — **placement 없는(안 쓰이는) 이미지 중** generation 작은(오래된) 것. exclude_id
/// 제외. 화면 표시 중(placement 있는)인 이미지는 후보에서 빼 보호한다 — 모두 쓰이면 null을 돌려 새 transmit이
/// 거부되게 한다(화면 이미지를 조용히 지우지 않음, code review #9). 베이스: kitty 명세 "unused first"
/// (Ghostty graphics_storage evictImage 동작) — maru는 used를 evict하지 않고 보호를 우선한다.
fn pickKittyEvictionVictim(self: *TerminalCore, exclude_id: u32) ?u32 {
    var best: ?u32 = null;
    var best_gen: u64 = std.math.maxInt(u64);
    var it = self.kitty_images.map.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        if (id == exclude_id) continue;
        if (kittyImageHasPlacement(self, id)) continue; // 화면 표시 중인 이미지는 보호(evict 안 함)
        const gen = kv.value_ptr.generation;
        if (best == null or gen < best_gen) {
            best = id;
            best_gen = gen;
        }
    }
    return best;
}

/// z-index가 target과 같은 placement를 제거한다. free_images면 그 placement가 가리키던 이미지도 free하고
/// (그 이미지의 다른 placement까지 제거해 orphan을 막는다). placement 수가 작아 재시작 비용은 무시할 만하다.
fn deleteByZ(self: *TerminalCore, target_z: i32, free_images: bool) void {
    var i: usize = 0;
    while (i < self.kitty_placements.items.len) {
        const p = self.kitty_placements.items[i];
        if (p.z == target_z) {
            if (free_images) {
                const id = p.image_id;
                self.kitty_images.remove(self.allocator, id);
                removePlacementsForImage(self, id); // 그 이미지의 모든 placement 제거(배열 변형)
                i = 0; // 배열이 바뀌었으니 처음부터 다시 스캔
            } else {
                _ = self.kitty_placements.orderedRemove(i);
            }
        } else i += 1;
    }
}

// ── orchestrator(parser dispatchApc 진입점 + transmit/display/delete dispatch) ─────────────────────

/// 파싱된 kitty graphics command를 실행하고 **결과를 앱에 회신한다**(K5). transmit(디코드+저장)·
/// display(placement)·delete·query(a=q)를 처리한다. payload는 control(';' 전) 다음 base64다.
/// parser.dispatchApc가 파싱한 command를 실행 — parser가 cross-file 호출하므로 pub.
///
/// **query(a=q)는 저장하지 않고 검증만 한다**(kitty 명세: "the terminal must not actually store
/// the image"). 앱은 이 응답 하나로 "이 터미널이 kitty graphics를 하는가"를 판정하므로, 무응답은
/// 곧 미지원 선언이다 — 실측(2026-09-08): terminal-browser·icat·timg가 모두 `a=q`로 감지한다.
pub fn execKittyGraphics(self: *TerminalCore, cmd_in: KittyGraphicsCommand, payload: []const u8) void {
    var cmd = cmd_in;
    // `I=`(image number)를 image id 로 푼다 — 같은 번호는 같은 id 를 재사용해 이전 이미지를 교체한다.
    // **`i=` 가 함께 오면 그쪽이 이긴다**(id 가 더 구체적인 지정이다 — 명세). 배정에 실패하면 거부한다.
    if (cmd.image_number != 0 and cmd.image_id == 0) {
        if (cmd.action == 'd') {
            // **delete 는 배정하지 않는다 — 조회만 한다.** 여기서 resolveImageNumber 를 부르면 없는
            // 번호를 지우라는 명령이 새 id 를 배정하고 표를 한 칸 늘린다(지우는 명령이 상태를 만든다).
            cmd.image_id = lookupImageNumber(self, cmd.image_number) orelse 0;
        } else {
            cmd.image_id = resolveImageNumber(self, cmd.image_number);
            if (cmd.image_id == 0) return kittyReply(self, cmd, .enomem);
        }
    }
    const status: KittyStatus = switch (cmd.action) {
        'q' => kittyTransmit(self, cmd, payload, false), // query: 검증만(저장 안 함)
        't' => kittyTransmit(self, cmd, payload, true),
        'T' => blk: { // transmit + display(한 command로 저장 후 placement까지)
            const transmitted = kittyTransmit(self, cmd, payload, true);
            if (transmitted != .ok) break :blk transmitted; // 저장이 실패했으면 display는 무의미
            break :blk kittyDisplay(self, cmd);
        },
        'p' => kittyDisplay(self, cmd), // 기존 이미지를 placement로 표시
        'd' => kittyDelete(self, cmd), // delete: d= 타깃에 따라 placement(소문자)/이미지까지(대문자) 제거
        'f' => kittyTransmitFrame(self, cmd, payload), // 애니메이션 프레임 전송
        'a' => kittyAnimate(self, cmd), // 애니메이션 제어(재생/정지/반복/현재 프레임/gap)
        'c' => kittyCompose(self, cmd), // 프레임 합성
        else => .enotsupp, // 그 밖의 action 은 명세에 없다 — 침묵 대신 명시 거부
    };
    kittyReply(self, cmd, status);
}

/// kitty graphics 응답을 host(PTY)로 보낸다 — `ESC _ G i=<id>[,p=<pid>];<본문> ESC \`.
///
/// **`q`(quiet)를 존중한다**: 0=성공·실패 모두 보고, 1=실패만, 2=침묵. 베이스: kitty graphics
/// protocol. **식별자(`i=`)가 없으면 보내지 않는다** — 앱이 어느 명령의 응답인지 가릴 수 없어서
/// 명세가 응답을 금지한다(그 바이트는 앱의 입력 스트림을 오염시킬 뿐이다).
///
/// **왜 이제 와서 응답을 보내기 시작하나**: 지금까지 maru는 어떤 graphics 명령에도 답하지 않았고,
/// 그래서 앱들은 maru를 "이미지 못 그리는 터미널"로 판정해 왔다. kitty·Ghostty가 같은 자리에서
/// 답하고 앱들이 그 응답을 전제로 만들어졌으므로, 표준 동작을 따르는 것이 맞다.
fn kittyReply(self: *TerminalCore, cmd: KittyGraphicsCommand, status: KittyStatus) void {
    if (cmd.image_id == 0 and cmd.image_number == 0) return; // 식별자(i= 또는 I=) 없는 명령엔 응답하지 않는다(명세)
    if (cmd.quiet >= 2) return; // q=2: 전부 침묵
    if (cmd.quiet == 1 and status == .ok) return; // q=1: 실패만 보고
    var buf: [128]u8 = undefined;
    // **번호로 보냈으면 응답에 `I=` 를 함께 싣는다** — 클라이언트는 그것으로 자기 요청을 짝짓고,
    // `i=` 로 배정된 id 를 알아 이후 display/delete 에 쓴다(명세). 번호를 안 썼으면 `i=` 만.
    const s = if (cmd.image_number != 0)
        (if (cmd.placement_id != 0)
            std.fmt.bufPrint(&buf, "\x1b_GI={d},i={d},p={d};{s}\x1b\\", .{ cmd.image_number, cmd.image_id, cmd.placement_id, status.text() }) catch return
        else
            std.fmt.bufPrint(&buf, "\x1b_GI={d},i={d};{s}\x1b\\", .{ cmd.image_number, cmd.image_id, status.text() }) catch return)
    else if (cmd.placement_id != 0)
        std.fmt.bufPrint(&buf, "\x1b_Gi={d},p={d};{s}\x1b\\", .{ cmd.image_id, cmd.placement_id, status.text() }) catch return
    else
        std.fmt.bufPrint(&buf, "\x1b_Gi={d};{s}\x1b\\", .{ cmd.image_id, status.text() }) catch return;
    self.appendResponse(s);
}

/// kitty graphics display(a=p/T): 저장된 이미지를 현재 커서 셀에 placement로 건다. 이미지가 없으면
/// 무시한다(graceful — transmit 실패/미전송 이미지). (image_id, placement_id) 같은 키는 교체한다.
/// 커서 이동 정책(C): 기본(C≠1)은 이미지 아래로 커서를 내린다 — 단 행 수(r)가 명시됐을 때만이다.
/// 자동 크기(r 미지정)는 setCellMetrics로 주입된 셀 메트릭이 있으면 이미지 픽셀 높이를 행 span으로 환산해
/// 내리고(kittyAdvanceRows — 렌더러 buildGpuImages와 같은 `PlacementGeometry` 공유), 메트릭이 없으면
/// (헤드리스) 옮기지 않는다(K1 fallback). 화면 끝을 넘기는 이동은 스크롤 없이 마지막 행으로 clamp한다(이미지 표시가
/// 스크롤을 유발하지 않게). 베이스: kitty graphics protocol display.
fn kittyDisplay(self: *TerminalCore, cmd: KittyGraphicsCommand) KittyStatus {
    if (cmd.image_id == 0) return .einval;
    if (!self.kitty_images.map.contains(cmd.image_id)) return .enoent; // 없는 이미지는 표시 안 함
    // **virtual 은 relative 일 수 없다**(명세: "Virtual placements created for Unicode placeholder
    // based images cannot also be relative placements"). 반대는 된다 — relative 의 **부모**는 virtual
    // 이어도 좋다. 둘을 함께 주면 어느 규칙을 따를지 알 수 없으므로 거부한다.
    if (cmd.virtual and cmd.parent_image_id != 0) return .einval;
    // relative placement 는 부모가 실재해야 위치를 풀 수 있다. 없으면 그릴 자리가 없다.
    // 부모가 없으면 거부한다. 명세대로이기도 하지만, **이 거부가 `removeOrphanedRelatives` 의 비용
    // 상한을 지탱한다** — 부모가 언제나 자식보다 먼저 등록되므로 배열에서도 앞에 오고, 그래서 고아
    // 연쇄가 **한 패스에** 다 걷힌다(O(n²)). 여기서 관대해지면 자식이 부모보다 앞에 놓일 수 있고,
    // 그러면 패스마다 하나씩만 걷혀 O(n³)이 된다. 실측(2026-09-10, 사슬 1024): 거부하면 3 ms,
    // 거부를 빼면 **1094 ms** — 몇 KB 의 escape 로 터미널이 1초 넘게 멈춘다.
    // 이 결합은 눈에 안 보이므로 판정자로 고정해 두었다("부모 없는 relative placement 는 ENOENT").
    if (cmd.parent_image_id != 0 and findParentPlacement(self, cmd.parent_image_id, cmd.parent_placement_id) == null)
        return .enoent;
    // U=1(unicode placeholder): 커서 자리에 그리지 않는다 — 등록만 하고, 실제 배치는 화면에 찍힌
    // placeholder 셀이 정한다. 격자(c×r)가 없으면 타일 크기를 못 정하므로 거부한다(명세상 필수).
    if (cmd.virtual) {
        if (cmd.columns == 0 or cmd.rows == 0) return .einval;
        return addOrReplaceVirtualPlacement(self, .{
            .image_id = cmd.image_id,
            .placement_id = cmd.placement_id,
            .columns = cmd.columns,
            .rows = cmd.rows,
            .z = cmd.z,
        });
    }
    addOrReplacePlacement(self, .{
        .image_id = cmd.image_id,
        .placement_id = cmd.placement_id,
        .anchor_row = self.screen.sb.count + self.screen.cursor.row, // 커서의 절대 행
        .anchor_col = self.screen.cursor.col,
        .on_alt = self.alt_active, // 지금 화면에 귀속시킨다
        .cell_x_offset = cmd.cell_x_offset,
        .cell_y_offset = cmd.cell_y_offset,
        .src_x = cmd.src_x,
        .src_y = cmd.src_y,
        .src_width = cmd.src_width,
        .src_height = cmd.src_height,
        .columns = cmd.columns,
        .rows = cmd.rows,
        .z = cmd.z,
        .parent_image_id = cmd.parent_image_id,
        .parent_placement_id = cmd.parent_placement_id,
        .parent_offset_x = cmd.parent_offset_x,
        .parent_offset_y = cmd.parent_offset_y,
    });
    // relative placement 는 부모 자리에 그려지므로 커서를 옮기지 않는다 — 커서는 이 명령이 놓인
    // 자리에 그대로 있어야 뒤따르는 출력이 어긋나지 않는다.
    if (!cmd.no_cursor_move and cmd.parent_image_id == 0) {
        const rows_span = kittyAdvanceRows(self, cmd);
        if (rows_span > 0) {
            const target = @as(usize, self.screen.cursor.row) + rows_span;
            self.screen.cursor.row = @intCast(@min(target, self.size.rows - 1));
        }
    }
    return .ok;
}

/// `I=`(image number)가 가리키는 image id 를 정한다 — 없으면 **새로 배정**한다.
///
/// 같은 번호로 다시 오면 **같은 id 를 재사용**해 이전 이미지를 교체한다(명세: 같은 번호는 이전 것을
/// 대체). 새 번호면 안 쓰이는 id 를 위에서부터 내려오며 고른다 — 클라이언트가 흔히 쓰는 작은 id 와
/// 부딪히지 않게. 배정에 실패하면(표가 꽉 참·OOM) 0 을 돌려주고 호출자가 거부한다.
fn resolveImageNumber(self: *TerminalCore, number: u32) u32 {
    if (lookupImageNumber(self, number)) |id| return id;
    // 안 쓰이는 id 를 찾는다. 이미 저장된 이미지와 다른 번호에 배정된 id 를 모두 피한다.
    var candidate = self.kitty_next_auto_id;
    var tries: u32 = 0;
    while (tries < 4096) : (tries += 1) {
        // 0 은 «없음» 이라 건너뛰고, 바닥까지 내려오면 천장에서 다시 시작한다.
        if (candidate == 0 or candidate > core.kitty_auto_id_top) {
            candidate = core.kitty_auto_id_top;
            continue;
        }
        if (!self.kitty_images.map.contains(candidate) and !imageIdTaken(self, candidate)) break;
        candidate -%= 1;
    }
    if (tries == 4096) return 0; // 배정 실패 — 호출자가 ENOMEM 으로 거부한다
    if (self.kitty_image_numbers.items.len >= TerminalCore.max_kitty_placements) return 0; // 폭주 방어선(placement 와 같은 한도)
    self.kitty_image_numbers.append(self.allocator, .{ .number = number, .image_id = candidate }) catch return 0;
    self.kitty_next_auto_id = candidate -% 1;
    return candidate;
}

/// 번호에 **이미 배정된** id 를 조회한다 — 없으면 null. 배정을 만들지 않는다.
/// delete 경로가 이것을 쓴다: 삭제가 없는 번호를 새로 배정하면 «지우는 명령이 상태를 만드는» 꼴이다.
fn lookupImageNumber(self: *const TerminalCore, number: u32) ?u32 {
    for (self.kitty_image_numbers.items) |entry| {
        if (entry.number == number) return entry.image_id;
    }
    return null;
}

/// 이 id 가 이미 어떤 번호에 배정돼 있는가(저장소에 아직 이미지가 없어도 예약된 것으로 본다).
fn imageIdTaken(self: *TerminalCore, id: u32) bool {
    for (self.kitty_image_numbers.items) |entry| {
        if (entry.image_id == id) return true;
    }
    return false;
}

/// 번호 배정을 지운다 — 이미지가 삭제될 때 함께 정리해 표가 무한히 자라지 않게 한다.
fn forgetImageNumberFor(self: *TerminalCore, image_id: u32) void {
    var i: usize = 0;
    while (i < self.kitty_image_numbers.items.len) {
        if (self.kitty_image_numbers.items[i].image_id == image_id) {
            _ = self.kitty_image_numbers.orderedRemove(i);
            return; // 한 id 는 한 번호에만 배정된다
        }
        i += 1;
    }
}

/// virtual placement(U=1)를 등록한다 — 같은 `(image_id, placement_id)` 키는 교체한다(일반 placement와
/// 같은 규칙). 상한은 일반 placement와 같은 방어선을 쓴다.
fn addOrReplaceVirtualPlacement(self: *TerminalCore, vp: types.KittyVirtualPlacement) KittyStatus {
    for (self.kitty_virtual_placements.items) |*existing| {
        if (existing.image_id == vp.image_id and existing.placement_id == vp.placement_id) {
            existing.* = vp;
            return .ok;
        }
    }
    if (self.kitty_virtual_placements.items.len >= TerminalCore.max_kitty_placements) return .enomem;
    self.kitty_virtual_placements.append(self.allocator, vp) catch return .enomem;
    return .ok;
}

/// image_id 로 virtual placement 를 지운다(delete 경로 공용) — placement_id 가 0 이면 그 이미지의 전부.
fn removeVirtualPlacements(self: *TerminalCore, image_id: u32, placement_id: u32) void {
    var i: usize = 0;
    while (i < self.kitty_virtual_placements.items.len) {
        const vp = self.kitty_virtual_placements.items[i];
        if (vp.image_id == image_id and (placement_id == 0 or vp.placement_id == placement_id)) {
            _ = self.kitty_virtual_placements.orderedRemove(i);
        } else i += 1;
    }
}

/// 지워진 placement 를 부모로 삼던 relative placement 들을 함께 지운다.
///
/// 명세: "The lifetime of a relative placement is tied to the lifetime of its parent. If its parent
/// is deleted, it is deleted as well." 안 지우면 **부모 없는 자식이 남아** 매 frame 위치를 못 풀고
/// 조용히 사라진 것처럼 보인다(목록에는 남아 상한만 먹는다).
///
/// 자식이 또 부모일 수 있으므로 **더 없을 때까지 반복**한다. 목록이 작아(≤1024) 비용은 무시할 만하다.
/// **비용 상한은 여기 없다 — `kittyDisplay` 의 부모 검증이 지탱한다.** 부모가 언제나 자식보다 먼저
/// 등록되므로 배열에서도 앞에 오고, 그래서 연쇄가 한 패스에 다 걷힌다. 자식이 앞에 놓일 수 있게 되면
/// 패스마다 하나씩만 걷혀 세제곱이 된다(실측: 3 ms → 1094 ms).
fn removeOrphanedRelatives(self: *TerminalCore) void {
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < self.kitty_placements.items.len) {
            const p = self.kitty_placements.items[i];
            if (p.parent_image_id != 0 and findParentPlacement(self, p.parent_image_id, p.parent_placement_id) == null) {
                _ = self.kitty_placements.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
    }
}

/// placement 가 덮는 셀 크기(열·행). `c`/`r` 이 명시됐으면 그대로, 아니면 셀 메트릭으로 환산한다.
/// 메트릭이 없으면(헤드리스) 환산할 수 없어 **1×1** 로 본다 — 앵커 셀 하나만 덮는 것으로 취급한다.
/// 그 폴백은 「덜 지우는」 쪽이라, 모르는 채로 남의 이미지를 지우는 것보다 안전하다.
fn placementCellSpan(self: *const TerminalCore, p: StoredPlacement) struct { cols: u16, rows: u16 } {
    if (p.columns > 0 and p.rows > 0)
        return .{ .cols = @intCast(@min(p.columns, 0xFFFF)), .rows = @intCast(@min(p.rows, 0xFFFF)) };
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return .{ .cols = 1, .rows = 1 };
    const img = self.kitty_images.map.get(p.image_id) orelse return .{ .cols = 1, .rows = 1 };
    const geom = types.PlacementGeometry.compute(
        img.width,
        img.height,
        p.src_x,
        p.src_y,
        p.src_width,
        p.src_height,
        p.columns,
        p.rows,
        self.cell_width_px,
        self.cell_height_px,
    ) orelse return .{ .cols = 1, .rows = 1 };
    // 픽셀 → 셀은 **올림**이다. 한 픽셀이라도 걸치면 그 셀을 덮는다.
    const cw: f32 = @floatFromInt(self.cell_width_px);
    const ch: f32 = @floatFromInt(self.cell_height_px);
    const cols = @ceil(geom.dest_w / cw);
    const rows = @ceil(geom.dest_h / ch);
    return .{
        .cols = @intFromFloat(@max(1, @min(cols, 65535))),
        .rows = @intFromFloat(@max(1, @min(rows, 65535))),
    };
}

/// 이 placement 가 주어진 셀(절대 행·열)을 덮는가 — `d=c`(커서 위치) 판정에 쓴다.
fn placementCoversCell(self: *const TerminalCore, p: StoredPlacement, abs_row: usize, col: u16) bool {
    const span = placementCellSpan(self, p);
    if (abs_row < p.anchor_row) return false;
    if (abs_row - p.anchor_row >= span.rows) return false;
    if (col < p.anchor_col) return false;
    return col - p.anchor_col < span.cols;
}

/// 커서가 놓인 셀을 덮는 placement 를 모두 지운다(`d=c`/`d=C`). 대문자면 그 placement 가 마지막
/// 사용처였던 이미지 데이터까지 free 한다. 가상 placement(U=1)는 셀 좌표에 앵커가 없다 — 화면
/// 텍스트의 placeholder 가 위치를 정한다 — 그래서 커서 판정 대상이 아니다.
fn deleteAtCursor(self: *TerminalCore, free_image: bool) void {
    const abs_row = self.screen.sb.count + self.screen.cursor.row;
    const col = self.screen.cursor.col;
    var i: usize = 0;
    while (i < self.kitty_placements.items.len) {
        const p = self.kitty_placements.items[i];
        if (!placementCoversCell(self, p, abs_row, col)) {
            i += 1;
            continue;
        }
        _ = self.kitty_placements.orderedRemove(i);
        if (free_image) {
            removeVirtualPlacements(self, p.image_id, 0);
            self.kitty_images.remove(self.allocator, p.image_id);
            forgetImageNumberFor(self, p.image_id);
        }
    }
}

/// relative placement 의 부모를 찾는다 — 일반 placement 를 먼저, 없으면 virtual 을 본다.
///
/// **부모는 virtual 이어도 된다**(명세). 다만 virtual 은 화면 위치를 갖지 않고 placeholder 셀이
/// 자리를 정하므로, 코어가 절대 anchor 를 풀 수 없다 — 그 경우 `.virtual_parent` 로 알리고
/// 위치 해석은 **하지 않는다**(아래 resolveRelativeAnchor). 그리지 않을지언정 엉뚱한 자리에
/// 놓지 않는다.
const ParentKind = union(enum) { normal: StoredPlacement, virtual_parent };

fn findParentPlacement(self: *TerminalCore, image_id: u32, placement_id: u32) ?ParentKind {
    for (self.kitty_placements.items) |p| {
        if (p.image_id == image_id and p.placement_id == placement_id) return .{ .normal = p };
    }
    for (self.kitty_virtual_placements.items) |vp| {
        if (vp.image_id == image_id and vp.placement_id == placement_id) return .virtual_parent;
    }
    return null;
}

/// relative placement 의 절대 anchor 를 부모에서 푼다. 부모가 없거나 virtual 이면 null —
/// 호출자가 그 placement 를 렌더 목록에서 뺀다.
///
/// **저장 시점에 굳히지 않고 여기서 푸는 이유**: 부모가 다시 display 되어 자리를 옮기면 자식도
/// 따라가야 한다(명세: "the relative placement moves along with it"). 굳혀 두면 부모만 움직인다.
fn resolveRelativeAnchor(self: *TerminalCore, p: StoredPlacement) ?struct { row: usize, col: u16 } {
    const parent = findParentPlacement(self, p.parent_image_id, p.parent_placement_id) orelse return null;
    const base = switch (parent) {
        .normal => |np| np,
        .virtual_parent => return null, // 화면 위치를 코어가 모른다(placeholder 셀 소유) — 후속
    };
    // 부모가 relative 면 그 부모부터 풀어야 하지만, 한 단계만 본다 — 사슬은 드물고, 순환이면
    // 무한 재귀가 된다. 다단계는 실제 사용례가 나오면 그때 사이클 검사와 함께 넣는다.
    if (base.parent_image_id != 0) return null;
    // **i64 로 더한다.** `H`/`V` 는 APC 에서 상한 없이 오는 i32 라, 좁은 타입으로 더하면 넘친다 —
    // `anchor_col(u16) + 2147483647` 이 i32 를 넘어 **터미널이 패닉했다**(적대적 검증 실측: 살아 있는
    // maru 에 그 한 줄을 보내자 앱이 죽었다). 악의적 스트림 한 줄로 앱을 죽일 수 있는 자리라, 범위를
    // 벗어나면 조용히 «그릴 자리 없음» 으로 떨군다.
    const row_i = @as(i64, @intCast(base.anchor_row)) + @as(i64, p.parent_offset_y);
    if (row_i < 0) return null; // 스크롤백 위로 벗어남 — 그릴 자리가 없다
    const col_i = @as(i64, base.anchor_col) + @as(i64, p.parent_offset_x);
    if (col_i < 0 or col_i > std.math.maxInt(u16)) return null; // 열 범위 밖 — 화면에 닿지 않는다
    return .{ .row = @intCast(row_i), .col = @intCast(col_i) };
}

/// kitty graphics delete(a=d). d= 타깃 문자로 무엇을 지울지 정한다. **소문자=placement만 제거**(이미지
/// 데이터는 남겨 재표시 가능), **대문자=placement + 이미지 데이터까지 free**. 베이스: kitty graphics
/// protocol(deletion). 핵심 부분집합만 지원: a/A(전체)·i/I(image_id[+placement_id])·z/Z(z-index)·n/N(이미지 번호 I=)·
/// c/C(커서를 덮는 placement). 나머지(p/q/x/y/r/f)는 ENOTSUPP 로 명시 거부한다 — 침묵하면 앱이
/// 지워진 줄 알고 계속 그린다 — 앱이 "지웠다"고 믿고 다음 단계로 가지 않게 한다(K5).
fn kittyDelete(self: *TerminalCore, cmd: KittyGraphicsCommand) KittyStatus {
    const c = cmd.delete_what;
    const free_image = (c >= 'A' and c <= 'Z'); // 대문자면 이미지 데이터도 free
    const target = if (free_image) c - 'A' + 'a' else c; // 소문자로 정규화
    switch (target) {
        'a' => { // 전체
            self.kitty_placements.clearRetainingCapacity();
            self.kitty_virtual_placements.clearRetainingCapacity();
            if (free_image) {
                self.kitty_images.clear(self.allocator);
                self.kitty_image_numbers.clearRetainingCapacity(); // 번호 배정도 함께(이미지가 없으면 무의미)
            }
        },
        'i' => { // image_id로(+ 선택적 placement_id)
            if (cmd.image_id == 0) return .einval;
            if (free_image) { // 이미지 + 그 이미지의 모든 placement 제거
                removePlacementsForImage(self, cmd.image_id);
                removeVirtualPlacements(self, cmd.image_id, 0);
                self.kitty_images.remove(self.allocator, cmd.image_id);
                forgetImageNumberFor(self, cmd.image_id); // 번호 배정도 놓아준다(표 무한 증가·stale 재사용 방지)
            } else if (cmd.placement_id != 0) {
                removeOnePlacement(self, cmd.image_id, cmd.placement_id);
                removeVirtualPlacements(self, cmd.image_id, cmd.placement_id);
            } else {
                removePlacementsForImage(self, cmd.image_id);
                removeVirtualPlacements(self, cmd.image_id, 0);
            }
        },
        'z' => deleteByZ(self, cmd.z, free_image), // z-index로
        'n' => { // 이미지 번호(I=)로 — 그 번호에 배정된 id 를 찾아 'i' 와 같은 일을 한다
            if (cmd.image_number == 0) return .einval;
            const image_id = cmd.image_id; // execKittyGraphics 가 조회해 둔다(없는 번호면 0)
            if (image_id == 0) return .ok; // 배정된 적 없는 번호 — 지울 것이 없다(성공)
            if (free_image) {
                removePlacementsForImage(self, image_id);
                removeVirtualPlacements(self, image_id, 0);
                self.kitty_images.remove(self.allocator, image_id);
                forgetImageNumberFor(self, image_id);
            } else if (cmd.placement_id != 0) {
                removeOnePlacement(self, image_id, cmd.placement_id);
                removeVirtualPlacements(self, image_id, cmd.placement_id);
            } else {
                removePlacementsForImage(self, image_id);
                removeVirtualPlacements(self, image_id, 0);
            }
        },
        'c' => deleteAtCursor(self, free_image), // 커서가 놓인 셀을 덮는 placement
        else => return .enotsupp, // p/q/x/y/r/f 는 미지원
    }
    // 부모가 사라졌으면 그것을 기준으로 놓인 relative placement 도 함께 거둔다(명세의 수명 연동).
    removeOrphanedRelatives(self);
    return .ok;
}

/// kitty graphics transmit: base64 payload를 디코드해 RGBA(f=32)/RGB(f=24) 이미지를 저장한다.
/// zlib(o=z) 압축이면 base64 디코드 후 inflate한다(K3b). PNG(f=100)는 kittyTransmitPng. 베이스: kitty
/// graphics protocol transmit — RGBA/RGB 직접 픽셀은 base64만 풀면 되고, zlib은 std.compress로 푼다.
/// `store=false`면 **검증만 하고 저장하지 않는다**(a=q query) — 픽셀을 끝까지 디코드해 같은 판정을
/// 내리고 버린다. 그래야 query가 "이 이미지를 실제로 받을 수 있다"를 증명한다(kitty 명세).
/// ── 애니메이션(a=f / a=a / a=c) ────────────────────────────────────────────────────────────────
///
/// 모델: 이미지 하나가 프레임 1..N 을 갖는다. 프레임 1 은 `data`(루트)이고 2..N 은 `frames` 다.
/// **각 프레임은 완전한 픽셀을 굳혀 담는다** — 「베이스 + 델타」로 두면 합성이 렌더 경로에 들어온다.
///
/// 렌더러는 손대지 않는다: `buildImageViews` 가 **현재 프레임의 픽셀**을 노출하고, 프레임이 넘어갈 때
/// `generation` 을 올린다. 그러면 기존 텍스처 캐시 무효화(generation 키)가 그대로 애니메이션이 된다.
/// 베이스: kitty graphics protocol "Animation".
/// 한 사각형을 프레임 버퍼에 합성한다. `overwrite` 면 그대로 덮고, 아니면 알파 블렌드(source-over).
/// 범위를 벗어나는 행·열은 **잘라 낸다** — APC 좌표는 신뢰 경계 밖이라 그대로 인덱스하면 죽는다.
fn compositeRect(
    dst: []u8,
    dst_w: u32,
    dst_h: u32,
    bpp: u8,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    at_x: u32,
    at_y: u32,
    overwrite: bool,
) void {
    if (bpp == 0 or src_w == 0 or src_h == 0) return;
    var y: u32 = 0;
    while (y < src_h) : (y += 1) {
        const dy = at_y + y;
        if (dy >= dst_h) break;
        var x: u32 = 0;
        while (x < src_w) : (x += 1) {
            const dx = at_x + x;
            if (dx >= dst_w) break;
            const si = (@as(usize, y) * src_w + x) * bpp;
            const di = (@as(usize, dy) * dst_w + dx) * bpp;
            if (si + bpp > src.len or di + bpp > dst.len) return;
            if (overwrite or bpp < 4) {
                @memcpy(dst[di..][0..bpp], src[si..][0..bpp]);
                continue;
            }
            // source-over 알파 블렌드. 정수 산술로 하되 반올림을 위해 128 을 더한다.
            const a: u32 = src[si + 3];
            if (a == 255) {
                @memcpy(dst[di..][0..bpp], src[si..][0..bpp]);
                continue;
            }
            if (a == 0) continue;
            var c: usize = 0;
            while (c < 3) : (c += 1) {
                const sv: u32 = src[si + c];
                const dv: u32 = dst[di + c];
                dst[di + c] = @intCast((sv * a + dv * (255 - a) + 128) / 255);
            }
            const da: u32 = dst[di + 3];
            dst[di + 3] = @intCast(a + da * (255 - a) / 255);
        }
    }
}

/// `a=f` — 프레임을 전송한다.
///
/// 키: `r`=대상 프레임 번호(0/미지정이면 **새 프레임을 덧붙인다**), `c`=합성 베이스 프레임(없으면 배경),
/// `x`/`y`=이 데이터를 놓을 좌상단, `z`=gap(ms, 음수면 건너뛰는 프레임), `X`=합성 모드(1=덮어쓰기),
/// `Y`=베이스가 없을 때 채울 배경색(0xRRGGBBAA). `s`/`v` 는 **전송하는 사각형**의 크기이고
/// 프레임 자체는 언제나 이미지 전체 크기다.
fn kittyTransmitFrame(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) KittyStatus {
    if (cmd.medium != 'd') return .enotsupp; // 파일·공유메모리 매체는 transmit 과 같은 이유로 거부
    if (cmd.format == 100) return .enotsupp; // PNG 프레임은 후속(루트 이미지는 지원)
    if (cmd.image_id == 0) return .einval;
    const img = self.kitty_images.map.getPtr(cmd.image_id) orelse return .enoent;
    const bpp: u8 = switch (cmd.format) {
        24 => 3,
        32 => 4,
        else => return .einval,
    };
    if (bpp != img.bpp) return .einval; // 프레임은 루트와 같은 픽셀 형식이어야 합성이 성립한다
    const rect_w = if (cmd.width == 0) img.width else cmd.width;
    const rect_h = if (cmd.height == 0) img.height else cmd.height;
    if (rect_w == 0 or rect_h == 0) return .einval;
    const rect_px = std.math.mul(usize, rect_w, rect_h) catch return .einval;
    const expected = std.math.mul(usize, rect_px, bpp) catch return .einval;
    const frame_bytes = img.data.len;

    // 프레임 수 상한 — `a=f` 만 반복하는 스트림이 메모리를 무한히 먹지 못하게 한다(총량 한계와 같은 결).
    if (cmd.rows == 0 and img.frames.len >= max_animation_frames) return .enomem;

    const src = decodeDirectPixels(self, cmd.compression, payload, expected) catch |e| return switch (e) {
        error.OutOfMemory => .enomem,
        else => .einval,
    };
    defer self.allocator.free(src);

    // 대상 프레임 버퍼를 만든다: 베이스 프레임 복사, 없으면 `Y` 배경색으로 채운다.
    const buf = self.allocator.alloc(u8, frame_bytes) catch return .enomem;
    if (cmd.columns != 0) { // c=<base frame>
        const base = img.framePixels(cmd.columns);
        if (base.len != frame_bytes) {
            self.allocator.free(buf);
            return .einval;
        }
        @memcpy(buf, base);
    } else fillBackground(buf, bpp, cmd.cell_y_offset); // Y=0xRRGGBBAA(미지정이면 투명/검정)

    compositeRect(buf, img.width, img.height, bpp, src, rect_w, rect_h, cmd.src_x, cmd.src_y, cmd.cell_x_offset == 1);

    const gap = frameGapFromZ(cmd.z);
    if (cmd.rows == 0) return appendFrame(self, img, buf, gap); // r 미지정 → 덧붙이기
    return replaceFrame(self, img, cmd.rows, buf, gap);
}

/// `Y=` 배경색(0xRRGGBBAA)으로 프레임을 채운다. 0 이면 투명(RGBA) 또는 검정(RGB)이다.
fn fillBackground(buf: []u8, bpp: u8, rgba: u32) void {
    if (rgba == 0) {
        @memset(buf, 0);
        return;
    }
    const r: u8 = @intCast((rgba >> 24) & 0xFF);
    const g: u8 = @intCast((rgba >> 16) & 0xFF);
    const b: u8 = @intCast((rgba >> 8) & 0xFF);
    const a: u8 = @intCast(rgba & 0xFF);
    var i: usize = 0;
    while (i + bpp <= buf.len) : (i += bpp) {
        buf[i] = r;
        buf[i + 1] = g;
        buf[i + 2] = b;
        if (bpp >= 4) buf[i + 3] = a;
    }
}

/// `z` → (gap_ms, skip). **음수는 「건너뛴다」**는 뜻이고 지우는 것이 아니다(명세).
const FrameGap = struct { ms: u32, skip: bool };

fn frameGapFromZ(z: i32) FrameGap {
    if (z < 0) return .{ .ms = 0, .skip = true };
    return .{ .ms = @intCast(@min(z, std.math.maxInt(u32))), .skip = false };
}

/// **프레임은 evict 하지 않는다.** 루트 이미지는 한도를 넘으면 LRU evict 로 자리를 만들지만(K4b),
/// 프레임은 그럴 수 없다 — 한 애니메이션의 프레임을 골라 버리면 그 애니메이션이 **조용히 이상해진다**
/// (프레임이 빠진 채 돈다). 거부하면 앱이 ENOMEM 을 보고 줄이거나 포기할 수 있다.
///
/// 한 이미지가 가질 수 있는 프레임 수 상한. `a=f` 만 반복하는 스트림 방어선이다(총량 한계와 같은 결).
pub const max_animation_frames: usize = 512;

fn appendFrame(self: *TerminalCore, img: *KittyImage, buf: []u8, gap: FrameGap) KittyStatus {
    // **한도를 강제한다.** 세기만 하면 예산이 지켜지지 않는다 — 프레임 수 상한(512)은 이걸 못 막는다.
    // 프레임 크기가 이미지 크기를 따라가므로 큰 이미지면 512 장이 수십 GB 다(적대적 검증 실측:
    // 320MB 예산이 애니메이션 하나로 통째로 우회됐다). 여기서 evict 하지 않는 이유는 아래 참조.
    if (self.kitty_images.total_bytes + buf.len > self.kitty_images.limit) {
        self.allocator.free(buf);
        return .enomem;
    }
    const grown = self.allocator.realloc(img.frames, img.frames.len + 1) catch {
        self.allocator.free(buf);
        return .enomem;
    };
    grown[grown.len - 1] = .{ .data = buf, .gap_ms = gap.ms, .skip = gap.skip };
    img.frames = grown;
    self.kitty_images.total_bytes += buf.len;
    return .ok;
}

fn replaceFrame(self: *TerminalCore, img: *KittyImage, n: u32, buf: []u8, gap: FrameGap) KittyStatus {
    if (n > img.frameCount()) { // 없는 프레임 번호 — 지어내지 않는다
        self.allocator.free(buf);
        return .enoent;
    }
    // 교체도 한도를 본다 — 작은 프레임을 큰 것으로 바꾸는 것도 예산을 늘리는 일이다.
    const old_len = if (n <= 1) img.data.len else img.frames[n - 2].data.len;
    if (self.kitty_images.total_bytes - old_len + buf.len > self.kitty_images.limit) {
        self.allocator.free(buf);
        return .enomem;
    }
    if (n <= 1) { // 루트 교체
        self.kitty_images.total_bytes -= img.data.len;
        self.allocator.free(img.data);
        img.data = buf;
        img.root_gap_ms = gap.ms;
        img.root_skip = gap.skip;
        self.kitty_images.total_bytes += buf.len;
    } else {
        const f = &img.frames[n - 2];
        self.kitty_images.total_bytes -= f.data.len;
        self.allocator.free(f.data);
        f.* = .{ .data = buf, .gap_ms = gap.ms, .skip = gap.skip };
        self.kitty_images.total_bytes += buf.len;
    }
    bumpGeneration(self, img);
    return .ok;
}

/// 프레임이 바뀌었음을 렌더러에 알린다 — `generation` 이 텍스처 캐시 무효화 키다.
fn bumpGeneration(self: *TerminalCore, img: *KittyImage) void {
    self.kitty_images.gen_counter += 1;
    img.generation = self.kitty_images.gen_counter;
}

/// `a=a` — 애니메이션 제어. `s`=상태(1 정지·2 로딩·3 재생), `v`=반복 수(0=무한),
/// `r`=편집할 프레임, `z`=그 프레임의 gap, `c`=지금 보여 줄 프레임.
fn kittyAnimate(self: *TerminalCore, cmd: KittyGraphicsCommand) KittyStatus {
    if (cmd.image_id == 0) return .einval;
    const img = self.kitty_images.map.getPtr(cmd.image_id) orelse return .enoent;

    if (cmd.rows != 0) { // r= 프레임의 gap 편집
        if (cmd.rows > img.frameCount()) return .enoent;
        const gap = frameGapFromZ(cmd.z);
        if (cmd.rows <= 1) {
            img.root_gap_ms = gap.ms;
            img.root_skip = gap.skip;
        } else {
            img.frames[cmd.rows - 2].gap_ms = gap.ms;
            img.frames[cmd.rows - 2].skip = gap.skip;
        }
    }
    if (cmd.columns != 0) { // c= 현재 프레임 지정
        if (cmd.columns > img.frameCount()) return .enoent;
        img.current_frame = cmd.columns;
        img.elapsed_ms = 0;
        bumpGeneration(self, img);
    }
    if (cmd.height != 0) img.loops_left = cmd.height; // v= 반복 수(0=무한이라 «미지정»과 같다)
    if (cmd.width != 0) { // s= 상태
        img.anim_state = switch (cmd.width) {
            1 => .stopped,
            2 => .loading,
            3 => .running,
            else => return .einval,
        };
        img.elapsed_ms = 0;
    }
    return .ok;
}

/// `a=c` — 프레임 합성. `r`=대상 프레임, `c`=원본 프레임, `x`/`y`=대상 안의 좌상단,
/// `w`/`h`=원본에서 잘라 올 사각형(0=전체), `X`=합성 모드(1=덮어쓰기).
fn kittyCompose(self: *TerminalCore, cmd: KittyGraphicsCommand) KittyStatus {
    if (cmd.image_id == 0) return .einval;
    const img = self.kitty_images.map.getPtr(cmd.image_id) orelse return .enoent;
    const dst_n = if (cmd.rows == 0) img.current_frame else cmd.rows;
    if (dst_n > img.frameCount() or cmd.columns == 0 or cmd.columns > img.frameCount()) return .enoent;
    if (dst_n == cmd.columns) return .einval; // 자기 자신에 겹쳐 쓰면 결과가 정의되지 않는다

    const w = if (cmd.src_width == 0) img.width else cmd.src_width;
    const h = if (cmd.src_height == 0) img.height else cmd.src_height;
    if (w == 0 or h == 0 or w > img.width or h > img.height) return .einval;

    // 원본에서 사각형을 떼어 낸다(대상과 겹치지 않는 임시 버퍼 — 별칭 문제를 원천 차단).
    const px = std.math.mul(usize, w, h) catch return .einval;
    const bytes = std.math.mul(usize, px, img.bpp) catch return .einval;
    const tmp = self.allocator.alloc(u8, bytes) catch return .enomem;
    defer self.allocator.free(tmp);
    const src = img.framePixels(cmd.columns);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const so = (@as(usize, row) * img.width) * img.bpp;
        const to = (@as(usize, row) * w) * img.bpp;
        const n = @as(usize, w) * img.bpp;
        if (so + n > src.len or to + n > tmp.len) return .einval;
        @memcpy(tmp[to..][0..n], src[so..][0..n]);
    }

    const dst: []u8 = if (dst_n <= 1) img.data else img.frames[dst_n - 2].data;
    compositeRect(dst, img.width, img.height, img.bpp, tmp, w, h, cmd.src_x, cmd.src_y, cmd.cell_x_offset == 1);
    bumpGeneration(self, img);
    return .ok;
}

/// 벽시계가 흐른 만큼 애니메이션을 진행한다. platform tick 이 매 frame 부른다 — 커서 깜빡임
/// (`blink_phase_ns`)과 같은 결이다. **코어는 시계를 갖지 않는다**(테스트가 결정적이어야 한다).
///
/// 넘어갈 프레임이 없으면(정지·로딩·프레임 하나) 아무 일도 안 한다. 반복 수가 다 되면 정지한다.
pub fn advanceAnimations(self: *TerminalCore, elapsed_ms: u64) bool {
    if (elapsed_ms == 0) return false;
    var changed = false;
    var it = self.kitty_images.map.valueIterator();
    while (it.next()) |img| {
        if (img.anim_state != .running or img.frameCount() < 2) continue;
        // **뷰포트에 안 보이면 진행하지 않는다.** 셋을 함께 막는다 — ① 아무도 못 보는 프레임에 CPU 를
        // 쓴다. ② evict 는 최저 `generation` 을 고르는데 애니메이션이 매 tick 그것을 올리므로, 숨은
        // 애니메이션 이미지가 **영원히 「가장 새것」** 이 되어 evict 순서가 뒤집힌다(정작 쓸모 있는
        // 정지 이미지가 먼저 밀려난다). ③ generation 이 오르면 화면 스트리밍이 그 이미지의 픽셀을
        // **통째로 다시 싣는다** — 스크롤해 지나간 애니메이션이 매 프레임 대역폭을 먹는다.
        // 다시 화면에 걸리면 그 자리에서 이어 돈다 — 상태는 남는다.
        if (!kittyImageVisibleInViewport(self, img.id)) continue;
        // **이 이미지가 움직였는가를 따로 센다.** 예전엔 함수 전역 `changed` 하나로 판정해서, 앞의
        // 이미지가 한 번 넘어가면 그 뒤로 **안 움직인 이미지까지** generation 이 올라갔다.
        // generation 은 렌더러의 텍스처 재업로드 키다 — 픽셀은 그대로인데 GPU 업로드만 늘어나고,
        // 애니메이션이 여럿이면 그만큼 곱해진다(적대적 검증 실측: 안 움직인 이미지가 매 tick +2).
        var img_changed = false;
        img.elapsed_ms += elapsed_ms;
        var guard: u32 = 0; // 아주 긴 elapsed 나 gap=0 에서도 유한하게 끝난다
        while (guard < 1024) : (guard += 1) {
            const gap = img.frameGapMs(img.current_frame);
            if (img.elapsed_ms < gap) break;
            img.elapsed_ms -= gap;
            var next = img.current_frame + 1;
            if (next > img.frameCount()) {
                // 한 바퀴 돌았다 — 반복 수가 정해져 있으면 하나 깎고, 다 되면 멈춘다.
                if (img.loops_left > 0) {
                    img.loops_left -= 1;
                    if (img.loops_left == 0) {
                        img.anim_state = .stopped;
                        break;
                    }
                }
                next = 1;
            }
            img.current_frame = next;
            img_changed = true;
            changed = true;
            if (!img.frameSkipped(next)) break; // 건너뛰는 프레임이면 곧바로 다음으로
            img.elapsed_ms = img.frameGapMs(next); // skip 은 시간을 쓰지 않는다
        }
        // **밀린 시간을 쌓아 두지 않는다.** 위 루프는 호출 한 번에 *보이는* 프레임을 한 장만 넘긴다
        // (skip 프레임만 연달아 지난다). 그래서 남은 시간을 그대로 들고 있으면 두 가지가 생긴다 —
        // ① 늦은 tick 하나가 그 뒤 수십 tick 을 「밀려 나오는 프레임」으로 채운다(실측: 2 초가 밀리면
        // 1ms tick 100 회에서 27 장이 나왔다. 실시간이면 2~3 장이다). ② gap 이 tick 간격보다 짧으면
        // 남는 시간이 **매 tick 쌓여**, 이미지를 숨겼다 다시 걸 때 그 은행이 통째로 쏟아진다.
        // 늦은 프레임은 쌓지 말고 **버린다** — 영상의 frame drop 과 같은 선택이다.
        const owed = img.frameGapMs(img.current_frame);
        if (img.elapsed_ms > owed) img.elapsed_ms = owed;
        if (img_changed) bumpGeneration(self, img);
    }
    return changed;
}

/// base64 payload 를 **정확히 `expected` 바이트**의 픽셀로 푼다. transmit(`a=t`)과 프레임 전송(`a=f`)이
/// 같은 규칙을 쓰므로 한 곳에 둔다 — 규칙이 갈리면 프레임만 다르게 검증되는 사고가 난다.
///
/// 비압축은 디코드 크기가 곧 선언 크기여야 하고(early reject), `o=z` 는 zlib inflate 하되 `expected` 로
/// 바운드해 zlib bomb 을 막는다. 어느 쪽이든 **길이가 정확히 맞지 않으면 거부**한다.
fn decodeDirectPixels(
    self: *TerminalCore,
    compression: u8,
    payload: []const u8,
    expected: usize,
) error{ OutOfMemory, Invalid }![]u8 {
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload) catch return error.Invalid;
    if (decoded_len == 0) return error.Invalid;
    if (compression == 0 and decoded_len != expected) return error.Invalid;
    const raw = self.allocator.alloc(u8, decoded_len) catch return error.OutOfMemory;
    dec.decode(raw, payload) catch {
        self.allocator.free(raw);
        return error.Invalid;
    };
    const data: []u8 = switch (compression) {
        0 => raw,
        'z' => blk: {
            defer self.allocator.free(raw);
            break :blk png.inflateExact(self.allocator, raw, expected) catch return error.Invalid;
        },
        else => {
            self.allocator.free(raw);
            return error.Invalid;
        },
    };
    if (data.len != expected) {
        self.allocator.free(data);
        return error.Invalid;
    }
    return data;
}

fn kittyTransmit(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8, store: bool) KittyStatus {
    // 전송 매체: direct(base64 픽셀)만 구현한다. f/t/s는 payload가 경로·이름이라 픽셀로 오인하면
    // 쓰레기를 디코드한다 — 명시 거부해야 앱이 direct로 폴백한다.
    if (cmd.medium != 'd') return .enotsupp;
    if (cmd.image_id == 0) return .einval; // 필수 control 누락(저장 키)
    if (cmd.format == 100) return kittyTransmitPng(self, cmd, payload, store); // PNG는 별도 경로(s/v는 PNG가 자기기술)
    const bpp: u8 = switch (cmd.format) {
        24 => 3,
        32 => 4,
        else => return .einval, // 알 수 없는 format
    };
    if (cmd.width == 0 or cmd.height == 0) return .einval; // raw 픽셀은 치수가 필수
    // 치수(s/v)는 APC에서 상한 없이 오는 u32라 곱이 usize를 넘을 수 있다(악의적 대형 값) — 오버플로면
    // 거부한다(graceful). 안 그러면 Debug/ReleaseSafe에서 panic, ReleaseFast에선 wrap된다(code review).
    const wh = std.math.mul(usize, cmd.width, cmd.height) catch return .einval;
    const expected = std.math.mul(usize, wh, bpp) catch return .einval;

    const data = decodeDirectPixels(self, cmd.compression, payload, expected) catch |e| return switch (e) {
        error.OutOfMemory => .enomem,
        else => .einval,
    };
    if (!store) { // query: 여기까지 왔으면 받을 수 있다는 뜻이고, 저장은 하지 않는다
        self.allocator.free(data);
        return .ok;
    }
    return if (storeKittyImage(self, .{
        .id = cmd.image_id,
        .width = cmd.width,
        .height = cmd.height,
        .bpp = bpp,
        .data = data,
    })) .ok else .enomem;
}

/// kitty graphics transmit PNG(f=100): base64 디코드 후 PNG 디코더로 RGB/RGBA 픽셀을 푼다. 치수·bpp는
/// PNG가 자기기술하므로 s/v control은 안 본다. 8-bit truecolor만 지원(미지원 변종·malformed는 graceful
/// 거부 — png.zig). PNG에 추가 압축(o=z)은 미지원(PNG는 이미 압축됨, 실사용 없음). 베이스: kitty graphics
/// protocol(f=100) + PNG 명세.
fn kittyTransmitPng(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8, store: bool) KittyStatus {
    if (cmd.compression != 0) return .enotsupp; // PNG + 추가 압축은 미지원(rare)
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload) catch return .einval;
    if (decoded_len == 0) return .einval;
    const png_bytes = self.allocator.alloc(u8, decoded_len) catch return .enomem;
    defer self.allocator.free(png_bytes); // PNG 파일 바이트는 디코드 후 불필요
    dec.decode(png_bytes, payload) catch return .einval;
    const img = png.decode(self.allocator, png_bytes) catch return .einval; // 미지원/malformed는 graceful 거부
    if (!store) { // query: 디코드까지 되면 받을 수 있다 — 픽셀은 버린다
        self.allocator.free(img.data);
        return .ok;
    }
    return if (storeKittyImage(self, .{
        .id = cmd.image_id,
        .width = img.width,
        .height = img.height,
        .bpp = img.bpp,
        .data = img.data, // storeKittyImage→add가 소유권 가져감
    })) .ok else .enomem;
}
