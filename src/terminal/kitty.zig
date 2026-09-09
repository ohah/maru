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
};

/// 디코드된 kitty graphics 이미지(픽셀 버퍼를 소유). bpp=3(RGB)/4(RGBA). generation은 storage가
/// (재)transmit마다 단조 증가로 찍어 주는 업로드 캐시 무효화 키다(렌더러가 image_id별 텍스처를
/// 이 값이 바뀔 때만 다시 업로드 — K2d).
const KittyImage = struct {
    id: u32,
    width: u32,
    height: u32,
    bpp: u8,
    data: []u8,
    generation: u64 = 0, // KittyImageStorage.add가 채운다
};

/// kitty graphics 이미지 저장소(image_id → KittyImage). 총량 한계로 악의적/대량 전송을 막는다.
/// 같은 id 교체 + 총량 한계. 한계 초과 시 거부가 아니라 LRU evict(generation 기준, placement 없는·
/// 오래된 것 우선)를 `addKittyImageEvicting`가 수행한다(K4b 완료). 베이스: kitty graphics protocol
/// image storage. struct 자체는 map + total_bytes만 담고 evict 결정·placement는 바깥(kitty.zig)이다.
/// 애니메이션 프레임(a=a/c/f)은 미지원(Ghostty도 미구현 — 후속).
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
        while (it.next()) |img| alloc.free(img.data);
        self.map.deinit(alloc);
    }
    pub fn clear(self: *KittyImageStorage, alloc: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |img| alloc.free(img.data);
        self.map.clearRetainingCapacity();
        self.total_bytes = 0;
    }
    /// 이미지를 저장한다 — img.data의 소유권을 가져간다(성공=map 보관, 거부/실패=즉시 free).
    /// 성공 시 새 generation을 찍어(같은 id 교체도 새 값) 렌더러 업로드 캐시를 무효화한다.
    fn add(self: *KittyImageStorage, alloc: std.mem.Allocator, img: KittyImage) void {
        if (self.map.fetchRemove(img.id)) |old| { // 같은 id는 교체(기존 free)
            self.total_bytes -= old.value.data.len;
            alloc.free(old.value.data);
        }
        if (self.total_bytes + img.data.len > self.limit) { // 한계 초과면 거부
            alloc.free(img.data);
            return;
        }
        var stored = img;
        self.gen_counter += 1;
        stored.generation = self.gen_counter;
        self.map.put(alloc, stored.id, stored) catch {
            alloc.free(stored.data);
            return;
        };
        self.total_bytes += stored.data.len;
    }
    fn remove(self: *KittyImageStorage, alloc: std.mem.Allocator, id: u32) void {
        if (self.map.fetchRemove(id)) |old| {
            self.total_bytes -= old.value.data.len;
            alloc.free(old.value.data);
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

/// placement를 추가하거나 같은 (image_id, placement_id)면 교체한다. 상한 초과면 거부(graceful),
/// OOM이면 표시를 포기한다(절대 panic 없음 — 출력 경로 견고성).
fn addOrReplacePlacement(self: *TerminalCore, p: StoredPlacement) void {
    for (self.kitty_placements.items) |*existing| {
        if (existing.image_id == p.image_id and existing.placement_id == p.placement_id) {
            existing.* = p;
            return;
        }
    }
    if (self.kitty_placements.items.len >= core.TerminalCore.max_kitty_placements) return; // 폭주 방어선
    self.kitty_placements.append(self.allocator, p) catch {};
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
            .pixels = img.data,
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
        else => .enotsupp, // 애니메이션(a=a/c/f)은 미구현 — 침묵 대신 명시 거부
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
        // 0 은 «없음» 이고 0xFFFF_FFFF 는 배경 이미지 예약이라 건너뛴다.
        if (candidate == 0 or candidate == 0xFFFF_FFFF) {
            candidate = 0xFFFF_FFFE;
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
/// 지워진 줄 알고 계속 그린다.
/// 나머지(c 커서·n 이미지번호·p/q/x/y/r 위치·f 애니메이션)는 셀 span/이미지번호가 필요해 미지원인데,
/// **무음 무시가 아니라 `ENOTSUPP`로 답한다**(K5) — 앱이 "지웠다"고 믿고 다음 단계로 가지 않게.
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

    // base64 디코드 → raw 바이트(압축이면 압축 데이터, 아니면 곧 픽셀).
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload) catch return .einval; // 잘못된 base64
    if (decoded_len == 0) return .einval;
    if (cmd.compression == 0 and decoded_len != expected) return .einval; // 비압축은 디코드 크기 = 선언 크기여야(early reject)
    const raw = self.allocator.alloc(u8, decoded_len) catch return .enomem;
    dec.decode(raw, payload) catch {
        self.allocator.free(raw);
        return .einval;
    };

    // 압축 해제. o=z(zlib)만 지원, 그 외 압축은 거부. 없으면 raw가 곧 픽셀.
    const data: []u8 = switch (cmd.compression) {
        0 => raw,
        'z' => blk: {
            defer self.allocator.free(raw); // 압축 입력은 inflate 후 불필요
            // PNG IDAT 경로와 같은 exact-inflate 공유(중복 제거) — expected로 바운드하고 over-long 거부.
            break :blk png.inflateExact(self.allocator, raw, expected) catch return .einval;
        },
        else => {
            self.allocator.free(raw); // 알 수 없는 압축
            return .einval;
        },
    };
    if (data.len != expected) { // 선언 크기 ≠ 실제 픽셀(inflate가 보장하지만 비압축 경로 가드)
        self.allocator.free(data);
        return .einval;
    }
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
