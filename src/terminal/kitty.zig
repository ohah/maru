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
    delete_what: u8 = 'a', // d: 삭제 타깃(a=d일 때). 기본 'a'(전체). 대문자=이미지 데이터도 free, 소문자=placement만
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
    for (self.kitty_placements.items, 0..) |p, i| {
        const row_i64 = @as(i64, @intCast(p.anchor_row)) - @as(i64, @intCast(top_abs));
        self.placement_views[i] = .{
            .image_id = p.image_id,
            .placement_id = p.placement_id,
            // 행 오프셋은 작은 값이라 i32에 들지만, 극단값은 포화시켜 안전하게 둔다.
            .row = std.math.cast(i32, row_i64) orelse (if (row_i64 < 0) std.math.minInt(i32) else std.math.maxInt(i32)),
            .col = p.anchor_col,
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
    }
    return self.placement_views;
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
fn storeKittyImage(self: *TerminalCore, img: KittyImage) void {
    if (img.data.len > self.kitty_images.limit) { // 한 장이 전체 한도 초과 — 불가
        self.allocator.free(img.data);
        return;
    }
    const existing: usize = if (self.kitty_images.map.get(img.id)) |old| old.data.len else 0;
    const after = self.kitty_images.total_bytes - existing + img.data.len;
    if (after > self.kitty_images.limit) {
        evictKittyImagesFor(self, after - self.kitty_images.limit, img.id); // 부족분만큼 자리 확보
    }
    self.kitty_images.add(self.allocator, img); // 같은-id 교체 + 최종 한도 체크(evict 후 통과)
    // add가 한도로 거부하면 같은 id의 기존 이미지는 이미 제거됐고(같은-id 교체 규칙) 새 것도 안 들어가
    // map에 그 id가 없다 — 그 id를 가리키던 placement가 orphan으로 남지 않게 함께 정리한다(code review #8).
    if (!self.kitty_images.map.contains(img.id)) removePlacementsForImage(self, img.id);
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

/// 파싱된 kitty graphics command를 실행한다. transmit(디코드+저장)·display(placement)·delete까지 —
/// query 응답·애니메이션은 후속. payload는 control(';' 전) 다음 base64다.
/// parser.dispatchApc가 파싱한 command를 실행 — parser가 cross-file 호출하므로 pub.
pub fn execKittyGraphics(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
    switch (cmd.action) {
        't' => kittyTransmit(self, cmd, payload),
        'T' => { // transmit + display(한 command로 저장 후 placement까지)
            kittyTransmit(self, cmd, payload);
            kittyDisplay(self, cmd);
        },
        'p' => kittyDisplay(self, cmd), // 기존 이미지를 placement로 표시
        'd' => kittyDelete(self, cmd), // delete: d= 타깃에 따라 placement(소문자)/이미지까지(대문자) 제거
        else => {}, // q(query)·f/a/c(애니메이션)는 후속
    }
}

/// kitty graphics display(a=p/T): 저장된 이미지를 현재 커서 셀에 placement로 건다. 이미지가 없으면
/// 무시한다(graceful — transmit 실패/미전송 이미지). (image_id, placement_id) 같은 키는 교체한다.
/// 커서 이동 정책(C): 기본(C≠1)은 이미지 아래로 커서를 내린다 — 단 행 수(r)가 명시됐을 때만이다.
/// 자동 크기(r 미지정)는 setCellMetrics로 주입된 셀 메트릭이 있으면 이미지 픽셀 높이를 행 span으로 환산해
/// 내리고(kittyAdvanceRows — 렌더러 buildGpuImages와 같은 `PlacementGeometry` 공유), 메트릭이 없으면
/// (헤드리스) 옮기지 않는다(K1 fallback). 화면 끝을 넘기는 이동은 스크롤 없이 마지막 행으로 clamp한다(이미지 표시가
/// 스크롤을 유발하지 않게). 베이스: kitty graphics protocol display.
fn kittyDisplay(self: *TerminalCore, cmd: KittyGraphicsCommand) void {
    if (cmd.image_id == 0) return;
    if (!self.kitty_images.map.contains(cmd.image_id)) return; // 없는 이미지는 표시 안 함
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
    });
    if (!cmd.no_cursor_move) {
        const rows_span = kittyAdvanceRows(self, cmd);
        if (rows_span > 0) {
            const target = @as(usize, self.screen.cursor.row) + rows_span;
            self.screen.cursor.row = @intCast(@min(target, self.size.rows - 1));
        }
    }
}

/// kitty graphics delete(a=d). d= 타깃 문자로 무엇을 지울지 정한다. **소문자=placement만 제거**(이미지
/// 데이터는 남겨 재표시 가능), **대문자=placement + 이미지 데이터까지 free**. 베이스: kitty graphics
/// protocol(deletion). 핵심 부분집합만 지원: a/A(전체)·i/I(image_id[+placement_id])·z/Z(z-index).
/// 나머지(c 커서·n 이미지번호·p/q/x/y/r 위치·f 애니메이션)는 셀 span/이미지번호가 필요해 graceful 무시.
fn kittyDelete(self: *TerminalCore, cmd: KittyGraphicsCommand) void {
    const c = cmd.delete_what;
    const free_image = (c >= 'A' and c <= 'Z'); // 대문자면 이미지 데이터도 free
    const target = if (free_image) c - 'A' + 'a' else c; // 소문자로 정규화
    switch (target) {
        'a' => { // 전체
            self.kitty_placements.clearRetainingCapacity();
            if (free_image) self.kitty_images.clear(self.allocator);
        },
        'i' => { // image_id로(+ 선택적 placement_id)
            if (cmd.image_id == 0) return;
            if (free_image) { // 이미지 + 그 이미지의 모든 placement 제거
                removePlacementsForImage(self, cmd.image_id);
                self.kitty_images.remove(self.allocator, cmd.image_id);
            } else if (cmd.placement_id != 0) {
                removeOnePlacement(self, cmd.image_id, cmd.placement_id);
            } else {
                removePlacementsForImage(self, cmd.image_id);
            }
        },
        'z' => deleteByZ(self, cmd.z, free_image), // z-index로
        else => {}, // c/n/p/q/x/y/r/f는 미지원(graceful) — 셀 span·이미지번호 필요
    }
}

/// kitty graphics transmit: base64 payload를 디코드해 RGBA(f=32)/RGB(f=24) 이미지를 저장한다.
/// zlib(o=z) 압축이면 base64 디코드 후 inflate한다(K3b). PNG(f=100)는 kittyTransmitPng. 베이스: kitty
/// graphics protocol transmit — RGBA/RGB 직접 픽셀은 base64만 풀면 되고, zlib은 std.compress로 푼다.
fn kittyTransmit(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
    if (cmd.image_id == 0) return; // 필수 control 누락(저장 키)
    if (cmd.format == 100) return kittyTransmitPng(self, cmd, payload); // PNG는 별도 경로(s/v는 PNG가 자기기술)
    const bpp: u8 = switch (cmd.format) {
        24 => 3,
        32 => 4,
        else => return, // 알 수 없는 format
    };
    if (cmd.width == 0 or cmd.height == 0) return; // raw 픽셀은 치수가 필수
    // 치수(s/v)는 APC에서 상한 없이 오는 u32라 곱이 usize를 넘을 수 있다(악의적 대형 값) — 오버플로면
    // 거부한다(graceful). 안 그러면 Debug/ReleaseSafe에서 panic, ReleaseFast에선 wrap된다(code review).
    const wh = std.math.mul(usize, cmd.width, cmd.height) catch return;
    const expected = std.math.mul(usize, wh, bpp) catch return;

    // base64 디코드 → raw 바이트(압축이면 압축 데이터, 아니면 곧 픽셀).
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload) catch return; // 잘못된 base64
    if (decoded_len == 0) return;
    if (cmd.compression == 0 and decoded_len != expected) return; // 비압축은 디코드 크기 = 선언 크기여야(early reject)
    const raw = self.allocator.alloc(u8, decoded_len) catch return;
    dec.decode(raw, payload) catch {
        self.allocator.free(raw);
        return;
    };

    // 압축 해제. o=z(zlib)만 지원, 그 외 압축은 거부. 없으면 raw가 곧 픽셀.
    const data: []u8 = switch (cmd.compression) {
        0 => raw,
        'z' => blk: {
            defer self.allocator.free(raw); // 압축 입력은 inflate 후 불필요
            // PNG IDAT 경로와 같은 exact-inflate 공유(중복 제거) — expected로 바운드하고 over-long 거부.
            break :blk png.inflateExact(self.allocator, raw, expected) catch return;
        },
        else => {
            self.allocator.free(raw); // 알 수 없는 압축
            return;
        },
    };
    if (data.len != expected) { // 선언 크기 ≠ 실제 픽셀(inflate가 보장하지만 비압축 경로 가드)
        self.allocator.free(data);
        return;
    }
    storeKittyImage(self, .{
        .id = cmd.image_id,
        .width = cmd.width,
        .height = cmd.height,
        .bpp = bpp,
        .data = data,
    });
}

/// kitty graphics transmit PNG(f=100): base64 디코드 후 PNG 디코더로 RGB/RGBA 픽셀을 푼다. 치수·bpp는
/// PNG가 자기기술하므로 s/v control은 안 본다. 8-bit truecolor만 지원(미지원 변종·malformed는 graceful
/// 거부 — png.zig). PNG에 추가 압축(o=z)은 미지원(PNG는 이미 압축됨, 실사용 없음). 베이스: kitty graphics
/// protocol(f=100) + PNG 명세.
fn kittyTransmitPng(self: *TerminalCore, cmd: KittyGraphicsCommand, payload: []const u8) void {
    if (cmd.compression != 0) return; // PNG + 추가 압축은 미지원(rare)
    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload) catch return;
    if (decoded_len == 0) return;
    const png_bytes = self.allocator.alloc(u8, decoded_len) catch return;
    defer self.allocator.free(png_bytes); // PNG 파일 바이트는 디코드 후 불필요
    dec.decode(png_bytes, payload) catch return;
    const img = png.decode(self.allocator, png_bytes) catch return; // 미지원/malformed는 graceful 거부
    storeKittyImage(self, .{
        .id = cmd.image_id,
        .width = img.width,
        .height = img.height,
        .bpp = img.bpp,
        .data = img.data, // storeKittyImage→add가 소유권 가져감
    });
}
