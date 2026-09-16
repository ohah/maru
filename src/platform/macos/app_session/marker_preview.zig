//! 터미널 마커 이미지 프리뷰의 **세션 상태와 배선** — 계약은
//! [docs/agent-image-marker-preview.md](../../../../docs/agent-image-marker-preview.md) §3·§4가 소유한다.
//!
//! 순수 코어(`session/agent_image_staging.zig`·`agent_image_markers.zig`)와 배치
//! (`chrome/components/image_preview.zig`)는 각자 자기 문서를 가진다. 이 파일은 그것들을 **세션 수명과
//! 화면에 잇는** 일만 한다.
//!
//! **surface별이다.** N의 네임스페이스가 에이전트 프로세스별이라(§4.3) 세션에 맵 하나를 두면 두 pane의
//! `#1`이 같은 칸을 다툰다. 갤러리의 `agent_activity: State`가 세션에 하나인 것과 **다른 선택**이며,
//! 그 이유는 §4.2가 적고 있다.

const std = @import("std");
const maru = @import("maru");
const staging_mod = maru.session.agent_image_staging;
const markers_mod = maru.session.agent_image_markers;
const chrome = maru.chrome;
const metal_frame = maru.renderer.metal_frame;

/// 붙여넣기 한 번이 관찰을 기다리는 동안의 자리.
///
/// **바이트를 먼저 들고 N은 나중에 안다.** paste가 나가고 TUI가 마커를 그려야 N이 생기므로(실측 ≤ 42 ms,
/// §10) 그 사이 PNG를 여기 둔다. 창 안에 마커가 안 나타나면 **조용히 버린다** — 잘못 묶는 것보다 낫다.
pub const Pending = struct {
    surface_id: u64,
    png: []u8,
    /// 임시 PNG 파일 경로(디코드가 이것으로 건다).
    path: []u8 = &.{},
    /// 붙여넣기 직전 화면의 N 집합(관찰의 기준선).
    observation: staging_mod.Observation = .{},
    /// 이 tick 수를 넘기면 포기한다. **42 ms 근처로 조이지 않는다**(§4.2) — 이 값은 로컬·tmux의 것이고
    /// 원격·부하에서는 느려지는데, 놓치면 그 장은 영영 안 열린다. 길어도 하는 일은 집합 비교뿐이다.
    ticks_left: u16 = default_ticks,

    /// 60 Hz tick 기준 약 2초. 실측 상한(42 ms)의 40배가 넘는 여유다.
    pub const default_ticks: u16 = 120;

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.png);
        if (self.path.len > 0) allocator.free(self.path);
        self.observation.deinit(allocator);
        self.* = undefined;
    }
};

/// 한 surface의 스테이징 + 그 surface를 가리키는 키.
const Slot = struct {
    surface_id: u64,
    staging: staging_mod.Staging = .{},
};

pub const State = struct {
    slots: std.ArrayList(Slot) = .empty,
    pending: std.ArrayList(Pending) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.slots.items) |*s| s.staging.deinit(allocator);
        self.slots.deinit(allocator);
        for (self.pending.items) |*p| p.deinit(allocator);
        self.pending.deinit(allocator);
        self.* = .{};
    }

    fn slotFor(self: *State, allocator: std.mem.Allocator, surface_id: u64) !*Slot {
        for (self.slots.items) |*s| if (s.surface_id == surface_id) return s;
        try self.slots.append(allocator, .{ .surface_id = surface_id });
        return &self.slots.items[self.slots.items.len - 1];
    }

    pub fn stagingFor(self: *State, surface_id: u64) ?*staging_mod.Staging {
        for (self.slots.items) |*s| if (s.surface_id == surface_id) return &s.staging;
        return null;
    }

    /// surface가 죽었다 — 그 스테이징과 대기 중인 붙여넣기를 함께 놓는다.
    ///
    /// **호출자는 같은 자리에서 텍스처 회수 표시도 세워야 한다**(§5). 픽셀만 풀고 「이미 올렸다」가
    /// 참으로 남으면 죽은 pane의 `image_id`가 유령으로 남는다.
    pub fn dropSurface(self: *State, allocator: std.mem.Allocator, surface_id: u64) void {
        var i: usize = 0;
        while (i < self.slots.items.len) {
            if (self.slots.items[i].surface_id != surface_id) {
                i += 1;
                continue;
            }
            self.slots.items[i].staging.deinit(allocator);
            _ = self.slots.orderedRemove(i);
        }
        i = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].surface_id != surface_id) {
                i += 1;
                continue;
            }
            var p = self.pending.orderedRemove(i);
            p.deinit(allocator);
        }
    }
};

/// 이미지를 붙여넣었다 — PNG를 들고 관찰을 건다. `png`의 소유권을 가져간다.
///
/// **paste가 나가기 전에 불려야 한다.** 기준선(`observation.arm`)이 마커가 뜬 뒤에 찍히면 그 마커가
/// 「새로 나타난 것」이 아니게 되어 영영 안 묶인다.
pub fn onImagePasted(
    state: *State,
    allocator: std.mem.Allocator,
    surface_id: u64,
    visible_now: []const u32,
    png: []u8,
    path: []u8,
) !void {
    var p: Pending = .{ .surface_id = surface_id, .png = png, .path = path };
    errdefer p.deinit(allocator);
    try p.observation.arm(allocator, visible_now);
    try state.pending.append(allocator, p);
}

/// 한 surface의 화면을 보고 상태를 맞춘다 — tick마다 불린다.
///
/// ⑴ 대기 중인 붙여넣기에 **새로 나타난 N**을 묶고, ⑵ 화면에서 사라진 `staged`를 `sent`로 옮긴다.
/// 새 N이 여럿이면 **오름차순**으로 큐 순서에 대응시킨다(연속 붙여넣기가 한꺼번에 나타난다, §10 실측).
pub fn observe(
    state: *State,
    allocator: std.mem.Allocator,
    surface_id: u64,
    visible_now: []const u32,
) !void {
    var fresh: std.ArrayList(u32) = .empty;
    defer fresh.deinit(allocator);
    // ⚠️ **이번 관찰에서 이미 묶은 N** — 없으면 두 장이 **같은 번호를 다툰다.** 간격 없이 두 장을 넣으면
    // `#2 #3` 이 **한꺼번에** 나타나는데(§10 실측), 대기 둘의 기준선에 둘 다 없으므로 각자 `fresh[0]`(=`#2`)
    // 을 집어 뒤엣것이 앞엣것을 `put` 으로 덮어썼다 — `#3` 은 아무 그림도 없어 **한 장만 열렸다**
    // (사용자 제보 2026-09-15). 「오름차순으로 큐 순서에 대응시킨다」는 이 함수의 계약이 여기서 지켜진다.
    var claimed: std.ArrayList(u32) = .empty;
    defer claimed.deinit(allocator);
    // ⚠️ **이미 «화면에 보이는 채로» 들고 있는 N 도 주인이 있다.** 한 관찰 안의 중복만 막으면 tick 을
    // 넘어선 중복이 남는다: A 가 `#1` 에 묶인 다음 tick 에 `#2` 가 떠도, 아직 기다리던 B 의 기준선에는
    // `#1` 도 없으므로 B 가 **다시 `#1`** 을 집어 A 를 덮었다(이 파일의 회귀 테스트가 그 자리다).
    //
    // `sent` 는 제외한다 — Codex 는 입력창을 비우면 번호를 `#1` 부터 다시 쓰므로(§4.3), 화면에서 사라진
    // 항목의 번호는 **재사용될 수 있는 자리**다.
    if (state.stagingFor(surface_id)) |st| {
        for (st.entries.items) |e| {
            if (e.phase != .staged) continue;
            try claimed.append(allocator, e.n);
        }
    }

    var i: usize = 0;
    while (i < state.pending.items.len) {
        const p = &state.pending.items[i];
        if (p.surface_id != surface_id) {
            i += 1;
            continue;
        }
        fresh.clearRetainingCapacity();
        try p.observation.fresh(allocator, visible_now, &fresh);
        // 가장 작은 **아직 안 묶인** 새 N이 큐에서 가장 먼저 붙여넣은 것이다 — 번호가 단조 증가하므로.
        if (firstUnclaimed(fresh.items, claimed.items)) |n| {
            const slot = try state.slotFor(allocator, surface_id);
            try claimed.append(allocator, n); // put 전에 — 실패해도 이 N 을 다시 집지 않는다
            var done = state.pending.orderedRemove(i);
            try slot.staging.put(allocator, n, done.png, done.path); // png·path 소유권 이전
            done.png = &.{};
            done.path = &.{};
            done.observation.deinit(allocator);
            continue; // 같은 인덱스에 다음 항목이 왔다
        }
        if (p.ticks_left == 0) {
            var dropped = state.pending.orderedRemove(i);
            dropped.deinit(allocator);
            continue;
        }
        p.ticks_left -= 1;
        i += 1;
    }

    if (state.stagingFor(surface_id)) |s| s.syncVisible(visible_now);
}

/// `fresh`(오름차순)에서 이번 관찰에 아직 안 묶인 첫 N. 전부 묶였으면 null — 그 대기는 **다음 tick 을
/// 기다린다**(포기하지 않는다: 마커는 아직 안 뜬 것일 수 있다).
fn firstUnclaimed(fresh: []const u32, claimed: []const u32) ?u32 {
    outer: for (fresh) |n| {
        for (claimed) |c| if (c == n) continue :outer;
        return n;
    }
    return null;
}

/// 열린 프리뷰 하나. **한 번에 하나만** 열린다(§2.2) — 여럿이면 서로를 가리고 닫는 법이 불분명하다.
pub const Open = struct {
    surface_id: u64,
    n: u32,
    /// 마커의 뷰포트 좌표. 매 프레임 **재검증**한다 — TUI가 그 자리를 덮어도 통보가 없다(§3).
    row: u16,
    start_col: u16,
    end_col: u16,
    /// **전송된** 마커면 갤러리 인덱스의 몇 번째 이미지인가(§4.4). null 이면 전송 전(스테이징) 것이다.
    /// 디코드 소스가 이 값으로 갈린다 — 인덱스는 트랜스크립트 안의 base64 구간이고, 스테이징은 파일이다.
    sent_hit_index: ?usize = null,
    /// 그 자리가 **여전히 같은 이미지인가**를 확인할 내용 키(`file_index`·`data_offset`).
    ///
    /// ⚠️ 배열 인덱스만 들면 **인덱스가 다시 만들어질 때 남의 이미지를 가리킨다** — 스캔은 파일이 자라면
    /// 이어 읽고(§4.2) 필터·접기가 자리를 바꾼다. 갤러리가 타일 재연결에 `(file_index, data_offset)` 을
    /// 쓰는 것과 같은 키다.
    sent_file_index: u8 = 0,
    sent_data_offset: u64 = 0,
    /// 디코드 결과(RGBA8). 비어 있으면 아직 안 풀렸거나 못 풀었다.
    pixels: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// 건 디코드의 generation(0 = 안 걸었다).
    ///
    /// ⚠️ **빗장만으로는 부족하다.** 예전에는 `submitted: bool` 하나였는데, 그러면 A 마커를 열어
    /// 디코드를 걸고 → 닫고 → B 마커를 열었을 때 **A 의 결과가 B 에 붙는다**(워커는 취소를 모른다).
    /// 갤러리가 `op.decoding == r.generation` 으로 가르는 것과 같은 이유다.
    decode_generation: u64 = 0,
    /// 못 풀었다 — 다시 걸지 않는다(같은 파일은 다음에도 안 풀린다).
    failed: bool = false,
    /// **이 텍스처를 올렸나.** ⚠️ 프리뷰가 사라지는 **모든** 길에서 거짓으로 되돌려야 한다
    /// (§5 · 갤러리 §5.4). `live_image_ids`에서 한 프레임 빠진 텍스처는 회수되는데 이 값이 참으로
    /// 남으면 다음에 그릴 때 업로드 없이 id만 실려 **그 한 장이 빈다** — 갤러리의 「도크 접기」가
    /// 정확히 그 결함이었고, 토글은 그 길 자체다.
    uploaded: bool = false,

    pub fn deinit(self: *Open, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// 프리뷰 전용 `image_id`. 갤러리가 `0xFFF0_0000`부터 격자(`+n`)와 크게 보기(`+0x10000`)를 쓰므로
/// **겹치지 않는 자리**를 잡는다(§5 A12) — 같은 id를 쓰면 도크와 프리뷰가 동시에 열렸을 때 서로의
/// 텍스처를 덮고, 증상이 「가끔 다른 그림이 뜬다」라 원인을 못 찾는다.
pub const preview_image_id: u32 = 0xFFF2_0000;

/// 마커를 눌렀다 — 열려 있으면 닫고, 아니면 연다. 기록에 없는 N이면 **열지 않는다**(§3.1).
///
/// 반환값이 새 `Open` 상태다(null = 닫힘). 호출자가 텍스처 회수 표시를 세운다.
pub fn toggle(
    state: *State,
    current: ?Open,
    surface_id: u64,
    hit: markers_mod.Hit,
) ?Open {
    if (current) |c| {
        if (c.surface_id == surface_id and c.n == hit.n and c.row == hit.row and c.start_col == hit.start_col) {
            return null; // 같은 마커를 다시 눌렀다 = 닫기
        }
    }
    const s = state.stagingFor(surface_id) orelse return current;
    if (s.lookup(hit.n) == null) return current; // 화면에 글자로 쓰인 마커 — 우리 것이 아니다
    return .{
        .surface_id = surface_id,
        .n = hit.n,
        .row = hit.row,
        .start_col = hit.start_col,
        .end_col = hit.end_col,
    };
}

/// 앵커 재검증의 답(§3). **좌표가 어긋났다고 곧바로 닫지 않는다** — 같은 N 이 화면에 있으면 거기로 따라간다.
pub const Reanchor = union(enum) {
    /// 그 자리에 그대로 있다.
    unchanged,
    /// 움직였다 — 호출자가 좌표를 이 값으로 갱신한다.
    moved: markers_mod.Hit,
    /// 화면에서 사라졌다 — 호출자가 조용히 닫는다.
    lost,
};

/// 열린 프리뷰의 앵커를 화면에 **다시 맞춘다** — 매 프레임(§3).
///
/// ⚠️ **좌표 고정은 프리뷰를 못 쓰게 만들었다**(사용자 제보 2026-09-15). 옛 판정(`stillAnchored`)은 앵커
/// 셀에 같은 마커가 없으면 곧바로 닫았는데, 두 provider 의 TUI 는 출력·스피너·상태줄 때문에 입력창을
/// **수시로 한두 줄 밀어 올린다**. 그러면 누른 다음 tick 에 이미 닫혀 디코드조차 안 걸렸고 — 화면에는
/// 테두리만 스쳐 「눌러도 안 열린다」로 보였다(계측: 클릭 7 연속에 `decode` 0 건).
///
/// **따라가는 것은 추정이 아니라 관찰이다.** 우리는 이미 매 tick 뷰포트를 스캔하고 있고, 그 스캔이
/// 「같은 N 이 지금 어디 있나」를 그대로 답한다. §9 M6 이 「TUI 레이아웃을 추정해야 한다」며 닫기를
/// 정상 동작으로 뒀던 것은 **추정 없이 답이 나온다는 것을 못 본** 판단이었다(2026-09-15 개정).
///
/// 같은 N 이 여럿이면 **원래 자리에서 가장 가까운 것**을 고른다 — 리페인트는 입력창을 통째로 몇 줄
/// 옮길 뿐이라 그 규칙이 같은 마커를 집는다. 화면에 그 N 이 아예 없으면 그때는 닫는다(§3 의 방어는
/// 그대로다 — 프리뷰가 엉뚱한 글자 위에 남지 않는다).
pub fn reanchor(open: Open, hits: []const markers_mod.Hit) Reanchor {
    if (markers_mod.hitAt(hits, open.row, open.start_col)) |h| {
        if (h.n == open.n and h.end_col == open.end_col) return .unchanged;
    }
    var best: ?markers_mod.Hit = null;
    var best_dist: u64 = std.math.maxInt(u64);
    for (hits) |h| {
        if (h.n != open.n) continue;
        const d = anchorDistance(h, open);
        if (d < best_dist) {
            best_dist = d;
            best = h;
        }
    }
    return if (best) |h| .{ .moved = h } else .lost;
}

/// 옛 자리에서 얼마나 멀어졌나. **행이 열보다 훨씬 무겁다** — 리페인트가 옮기는 축이 행이고, 같은 행
/// 안에서 나란한 마커(`[Image #1] [Image #2]`)는 N 이 다르므로 애초에 후보가 아니다.
fn anchorDistance(h: markers_mod.Hit, open: Open) u64 {
    const row_delta: u64 = @abs(@as(i64, h.row) - @as(i64, open.row));
    const col_delta: u64 = @abs(@as(i64, h.start_col) - @as(i64, open.start_col));
    return row_delta * 1024 + col_delta;
}

/// 열린 프리뷰 한 장을 프레임에 싣는다 — 갤러리의 `appendGpuImages`와 **같은 채널**(§2.1).
///
/// ⚠️ **안 그리고 나가는 길에서는 `uploaded`를 반드시 되돌린다**(§5). `live_ids`에서 한 프레임 빠진
/// 텍스처는 회수되는데 그 표시가 참으로 남으면 다음에 업로드 없이 id만 실려 **그 한 장이 빈다**.
pub fn appendGpuImage(
    open: *Open,
    allocator: std.mem.Allocator,
    place: chrome.components.image_preview.Placement,
    images: *[]metal_frame.GpuImage,
    uploads: *[]metal_frame.GpuImageUpload,
    pixels: *[]u8,
    live_ids: *std.ArrayList(u32),
) void {
    if (open.pixels.len == 0 or open.width == 0 or open.height == 0) {
        open.uploaded = false;
        return;
    }
    const id = preview_image_id;
    const img: metal_frame.GpuImage = .{
        .image_id = id,
        .dest_x = @floatFromInt(place.image.x),
        .dest_y = @floatFromInt(place.image.y),
        .dest_w = @floatFromInt(place.image.w),
        .dest_h = @floatFromInt(place.image.h),
        .origin_x = 0,
        .origin_y = 0,
        .src_u0 = 0,
        .src_v0 = 0,
        .src_u1 = 1,
        .src_v1 = 1,
        .z = 0,
        .pass = 2, // above_text — 텍스트 앞에 떠야 가리는 것이 보인다(§2.1)
    };
    live_ids.append(allocator, id) catch {};

    const merged = allocator.alloc(metal_frame.GpuImage, images.len + 1) catch {
        open.uploaded = false;
        return;
    };
    @memcpy(merged[0..images.len], images.*);
    merged[images.len] = img;
    allocator.free(images.*);
    images.* = merged;

    if (open.uploaded) return;
    const merged_uploads = allocator.alloc(metal_frame.GpuImageUpload, uploads.len + 1) catch return;
    const merged_pixels = std.mem.concat(allocator, u8, &.{ pixels.*, open.pixels }) catch {
        allocator.free(merged_uploads);
        return;
    };
    @memcpy(merged_uploads[0..uploads.len], uploads.*);
    merged_uploads[uploads.len] = .{
        .image_id = id,
        .width = open.width,
        .height = open.height,
        .bpp = 4,
        .generation = 1,
        .pixels_offset = pixels.len,
        .pixels_len = open.pixels.len,
    };
    allocator.free(uploads.*);
    allocator.free(pixels.*);
    uploads.* = merged_uploads;
    pixels.* = merged_pixels;
    open.uploaded = true;
}

const testing = std.testing;

fn dup(bytes: []const u8) ![]u8 {
    return try testing.allocator.dupe(u8, bytes);
}

test "MP1 배선: 붙여넣고 마커가 뜨면 그 N 에 묶인다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("PNG"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    const s = st.stagingFor(7) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("PNG", s.lookup(1).?.png);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 간격 없이 두 장 — 한 tick 에 `#2 #3` 이 함께 떠도 서로를 덮지 않는다 (§10)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    // 두 붙여넣기의 기준선이 **똑같다**(첫 마커가 뜨기 전에 둘째를 넣었다 — 실측 42 ms 안쪽).
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("FIRST"), &.{});
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("SECOND"), &.{});
    try observe(&st, testing.allocator, 7, &.{ 1, 2, 3 }); // 둘이 한꺼번에 나타났다
    const s = st.stagingFor(7) orelse return error.TestUnexpectedResult;
    // 큐 순서 그대로 오름차순 대응 — 덮어쓰기(둘 다 `#2`)면 `#3` 이 비어 **한 장만 열린다**.
    try testing.expectEqualStrings("FIRST", s.lookup(2).?.png);
    try testing.expectEqualStrings("SECOND", s.lookup(3).?.png);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 새 N 이 하나뿐인데 대기가 둘이면 — 뒤엣것은 앞엣것을 덮지 않고 **다음 tick 을 기다린다**" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("B"), &.{});
    try observe(&st, testing.allocator, 7, &.{1}); // 첫 마커만 떴다
    try testing.expectEqualStrings("A", st.stagingFor(7).?.lookup(1).?.png);
    try testing.expectEqual(@as(usize, 1), st.pending.items.len); // B 는 아직 대기
    try observe(&st, testing.allocator, 7, &.{ 1, 2 }); // 둘째 마커가 뒤따라 떴다
    try testing.expectEqualStrings("B", st.stagingFor(7).?.lookup(2).?.png);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 기준선에 이미 있던 N 은 새것이 아니다 — Claude 가 #3 으로 건너뛰어도 맞는다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("B"), &.{});
    try observe(&st, testing.allocator, 7, &.{ 1, 3 });
    const s = st.stagingFor(7) orelse return error.TestUnexpectedResult;
    try testing.expect(s.lookup(1) == null); // 기준선의 #1 은 남의 것
    try testing.expectEqualStrings("B", s.lookup(3).?.png);
}

test "MP1 배선: 창 안에 마커가 안 나타나면 조용히 버린다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("X"), &.{});
    st.pending.items[0].ticks_left = 2;
    for (0..4) |_| try observe(&st, testing.allocator, 7, &.{});
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
    try testing.expect(st.stagingFor(7) == null); // 아무것도 안 남겼다
}

test "MP1 배선: 다른 surface 의 화면은 남의 대기를 건드리지 않는다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try observe(&st, testing.allocator, 9, &.{1}); // 9번 pane 에 마커가 떴다
    try testing.expectEqual(@as(usize, 1), st.pending.items.len); // 7번 대기는 그대로
    try testing.expect(st.stagingFor(9) == null);
}

test "MP1 배선: 두 pane 의 #1 이 서로를 덮지 않는다 (§4.2 surface 스코프)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("SEVEN"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 9, &.{}, try dup("NINE"), &.{});
    try observe(&st, testing.allocator, 9, &.{1});
    try testing.expectEqualStrings("SEVEN", st.stagingFor(7).?.lookup(1).?.png);
    try testing.expectEqualStrings("NINE", st.stagingFor(9).?.lookup(1).?.png);
}

test "MP1 배선: surface 가 죽으면 스테이징과 대기가 함께 간다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("B"), &.{}); // 아직 대기 중
    st.dropSurface(testing.allocator, 7);
    try testing.expect(st.stagingFor(7) == null);
    try testing.expectEqual(@as(usize, 0), st.pending.items.len);
}

test "MP1 배선: 토글 — 같은 마커를 다시 누르면 닫힌다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    const hit: markers_mod.Hit = .{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 };
    const opened = toggle(&st, null, 7, hit) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), opened.n);
    try testing.expect(toggle(&st, opened, 7, hit) == null);
}

test "MP1 배선: 기록에 없는 N 은 안 열린다 — 화면에 글자로 쓰인 마커(§3.1)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    const stranger: markers_mod.Hit = .{ .row = 3, .start_col = 2, .end_col = 13, .n = 42 };
    try testing.expect(toggle(&st, null, 7, stranger) == null);
}

test "MP1 배선: 앵커 재검증 — 그대로면 unchanged, 그 번호가 사라지면 lost" {
    const open: Open = .{ .surface_id = 7, .n = 1, .row = 3, .start_col = 2, .end_col = 12 };
    const same = [_]markers_mod.Hit{.{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 }};
    try testing.expectEqual(Reanchor.unchanged, reanchor(open, &same));
    // 그 자리에 **다른 번호**가 왔고 내 번호는 화면 어디에도 없다 = 사라졌다(§3 의 방어는 그대로다).
    const other_n = [_]markers_mod.Hit{.{ .row = 3, .start_col = 2, .end_col = 12, .n = 2 }};
    try testing.expect(reanchor(open, &other_n) == .lost);
    try testing.expect(reanchor(open, &.{}) == .lost);
}

test "MP1 배선: 입력창이 밀려도 **따라간다** — 좌표 고정이 프리뷰를 죽였던 자리(2026-09-15)" {
    // TUI 가 출력 한 줄을 내면 입력창이 통째로 올라간다. 옛 판정은 그 tick 에 닫아 버려 **디코드조차
    // 안 걸렸다**(계측: 클릭 7 연속에 decode 0 건).
    const open: Open = .{ .surface_id = 7, .n = 1, .row = 34, .start_col = 2, .end_col = 12 };
    const moved = [_]markers_mod.Hit{.{ .row = 33, .start_col = 2, .end_col = 12, .n = 1 }};
    switch (reanchor(open, &moved)) {
        .moved => |h| {
            try testing.expectEqual(@as(u16, 33), h.row);
            try testing.expectEqual(@as(u16, 2), h.start_col);
            try testing.expectEqual(@as(u16, 12), h.end_col);
        },
        else => return error.TestUnexpectedResult,
    }
    // 폭이 바뀌어도(마커 뒤 글자가 늘어 열이 밀렸다) 같은 번호면 따라간다.
    const widened = [_]markers_mod.Hit{.{ .row = 34, .start_col = 6, .end_col = 16, .n = 1 }};
    switch (reanchor(open, &widened)) {
        .moved => |h| try testing.expectEqual(@as(u16, 6), h.start_col),
        else => return error.TestUnexpectedResult,
    }
}

test "MP1 배선: 같은 번호가 둘이면 **원래 자리에서 가까운 쪽**을 따라간다 (Codex 번호 재사용 §4.3)" {
    const open: Open = .{ .surface_id = 7, .n = 1, .row = 30, .start_col = 2, .end_col = 12 };
    const two = [_]markers_mod.Hit{
        .{ .row = 4, .start_col = 2, .end_col = 12, .n = 1 }, // 대화 영역에 남은 옛 마커
        .{ .row = 29, .start_col = 2, .end_col = 12, .n = 1 }, // 한 줄 밀린 입력창
    };
    switch (reanchor(open, &two)) {
        .moved => |h| try testing.expectEqual(@as(u16, 29), h.row),
        else => return error.TestUnexpectedResult,
    }
}

test "MP1 배선: 바이트 없이 **경로만** 든 항목도 찾아진다 — 드롭 경로가 그 모양이다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    const path = try dup("/tmp/shot.png");
    try onImagePasted(&st, testing.allocator, 7, &.{}, &.{}, path);
    try observe(&st, testing.allocator, 7, &.{1});
    const e = st.stagingFor(7).?.lookup(1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), e.png.len); // 바이트는 안 든다
    try testing.expectEqualStrings("/tmp/shot.png", e.path); // 디코드는 이 경로로 건다
}

test "MP1 배선: 경로만 든 항목은 예산을 거의 안 문다 — 드롭은 원본을 복사하지 않는다" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, &.{}, try dup("/tmp/a.png"));
    try observe(&st, testing.allocator, 7, &.{1});
    try testing.expectEqual(@as(usize, 0), st.stagingFor(7).?.bytes);
}

test "MP1 배선: 닫고 다른 마커를 열면 옛 디코드 generation 이 안 맞는다 (A29)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), &.{});
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 7, &.{1}, try dup("B"), &.{});
    try observe(&st, testing.allocator, 7, &.{ 1, 2 });

    const h1: markers_mod.Hit = .{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 };
    const h2: markers_mod.Hit = .{ .row = 3, .start_col = 13, .end_col = 23, .n = 2 };
    var open = toggle(&st, null, 7, h1) orelse return error.TestUnexpectedResult;
    open.decode_generation = 11; // #1 의 디코드를 걸었다
    const next = toggle(&st, open, 7, h2) orelse return error.TestUnexpectedResult;
    // 다른 마커로 옮겼으면 generation 이 비어 있다 — 옛 결과(11)가 도착해도 받지 않는다.
    try testing.expectEqual(@as(u64, 0), next.decode_generation);
    try testing.expectEqual(@as(u32, 2), next.n);
}

test "MP1 배선: surface 가 죽으면 그 스테이징이 남지 않는다 (A30 — 제품 경로가 부르는 함수)" {
    var st: State = .{};
    defer st.deinit(testing.allocator);
    try onImagePasted(&st, testing.allocator, 7, &.{}, try dup("A"), try dup("/tmp/a.png"));
    try observe(&st, testing.allocator, 7, &.{1});
    try onImagePasted(&st, testing.allocator, 9, &.{}, try dup("B"), &.{});
    st.dropSurface(testing.allocator, 7);
    try testing.expect(st.stagingFor(7) == null);
    try testing.expectEqual(@as(usize, 1), st.pending.items.len); // 9 번 것은 안 건드린다
}
