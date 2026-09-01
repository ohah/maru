//! 스크롤 컨테이너의 좌표계다 — backing pixel 하나가 단위이고, 이 모듈 밖으로 분수 좌표가 나가지 않는다.
//!
//! 단일 출처: docs/scroll-area.md. 소비처(도크·파일 탐색기·소스 컨트롤·...)는 상태를 자기가 소유하고
//! 그 값의 legal range와 전이만 여기서 받는다. 이 모듈은 tree·paint·host를 읽지 않는다.
//!
//! **`project`가 build보다 먼저 온다**는 것이 CSS `overflow: auto`와 갈라지는 지점이다(§2.1). 브라우저는
//! 자식을 다 만든 뒤 넘치는 부분을 자르지만, 여기서는 보이지 않는 항목의 노드도 텍스트도 만들지 않는다.
//! 그래서 창(window)을 정하는 것이 자르는 것보다 앞선다.
//!
//! §2가 ScrollArea 소유라고 적은 것은 여기 또는 `ui/tree.zig`에 있다 — 좌표계·투영·스크롤바 기하와
//! 드래그 수명·분수 휠 잔여는 이 파일이, entry 발행과 viewport clip은 `tree.build`가 그 선언을 보고
//! 한다. 남은 것은 selection follow(§4.5) 하나이고, 그것은 "무엇이 같은 항목인가"를 domain이 알아야
//! 해서 seam만 제공한다.

const std = @import("std");
const continuous_drag = @import("continuous_drag.zig");

/// 소비처가 소유하는 상태다. 이 모듈은 legal range와 전이만 정한다.
pub const State = struct {
    /// 발행되는 값은 언제나 정수 backing pixel이다 — tree rect와 GPU draw rect가 정수여야 셀 경계에서
    /// 흔들리지 않는다.
    offset_y_px: u32 = 0,
    /// 아직 1픽셀을 못 채운 분수 wheel 입력. 여기 남아 있다가 다음 틱과 합쳐져 정수가 되면 소비된다.
    /// **이 값은 밖으로 나가지 않는다** — 발행·hit-test는 `offset_y_px`만 본다.
    wheel_residue_px: f64 = 0,

    pub fn scrollByPx(self: *State, delta_px: i64, max_offset_px: u32) bool {
        const current: u64 = self.offset_y_px;
        const maximum: u64 = max_offset_px;
        const next: u64 = if (delta_px >= 0)
            @min(maximum, current +| @as(u64, @intCast(delta_px)))
        else
            current -| (@as(u64, @intCast(-(delta_px + 1))) + 1);
        const clamped: u32 = @intCast(next);
        if (clamped == self.offset_y_px) return false;
        self.offset_y_px = clamped;
        return true;
    }

    pub fn clamp(self: *State, max_offset_px: u32) void {
        self.offset_y_px = @min(self.offset_y_px, max_offset_px);
    }

    /// 유지 중인 offset을 wheel 입력과 **같은** 유계 좌표계로만 교체한다. refresh/resize anchor는
    /// 새로 삽입된 그룹 헤더 밑으로 카드가 밀리면 clamp 전에 음수일 수 있으므로 입력이 부호 있는 값이다.
    pub fn setOffsetPx(self: *State, requested_offset_px: i64, max_offset_px: u32) bool {
        const clamped: u32 = @intCast(std.math.clamp(requested_offset_px, @as(i64, 0), @as(i64, max_offset_px)));
        if (clamped == self.offset_y_px) return false;
        self.offset_y_px = clamped;
        // 다른 입구가 위치를 확정했다 — 가는 도중의 잔여는 의미가 없다.
        self.wheel_residue_px = 0;
        return true;
    }

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    /// 분수 wheel 델타를 흡수해 정수 픽셀이 찰 때마다 offset을 옮긴다.
    ///
    /// 세 가지가 여기 모여 있다. **방향이 뒤집히면 이전 잔여를 버린다** — 남겨 두면 첫 반대 틱이
    /// 상쇄돼 방향 전환이 굼뜨게 느껴진다. **소비한 정수부는 잔여에서 뺀다** — 안 빼면 같은 픽셀을
    /// 반복해 쓰면서 가속한다. 그리고 유한하지 않거나 넘치는 입력은 흘려보내지 않는다 — 자동화된
    /// 입력이 `@intFromFloat`에서 main thread를 트랩시킬 수 있다.
    ///
    /// 반환값은 offset이 실제로 움직였는지다(리페인트 신호).
    pub fn scrollByWheel(self: *State, delta: f64, unit_px: f64, max_offset_px: u32) bool {
        if (!std.math.isFinite(delta) or !std.math.isFinite(unit_px)) return false;
        if (delta * self.wheel_residue_px < 0) self.wheel_residue_px = 0;
        const next = self.wheel_residue_px + delta * unit_px;
        if (!std.math.isFinite(next)) return false;
        const safe_limit: f64 = @floatFromInt(std.math.maxInt(i64) - 1);
        self.wheel_residue_px = std.math.clamp(next, -safe_limit, safe_limit);
        const whole: i64 = @intFromFloat(std.math.trunc(self.wheel_residue_px));
        self.wheel_residue_px -= @as(f64, @floatFromInt(whole));
        if (whole == 0) return false;
        return self.scrollByPx(-whole, max_offset_px);
    }

    /// 잔여만 버린다. 포인터가 이 스크롤 영역을 떠났거나 다른 입구(키보드·드래그)가 위치를 확정했을
    /// 때 부른다 — 잔여는 그 위치로 **가는 도중**의 상태라, 위치가 확정되면 의미가 없다.
    pub fn dropWheelResidue(self: *State) void {
        self.wheel_residue_px = 0;
    }
};

pub const Projection = struct {
    content_height_px: u32,
    max_offset_px: u32,
    offset_y_px: u32,
    first_index: usize,
    /// 반환된 첫 항목이 시작하는 local y다. 0이거나 음수이며, 분수가 아니다.
    first_origin_y_px: i32,
    end_exclusive: usize,
};

/// `project`의 비-항목 입력. 항목 높이는 소비처가 comptime 함수로 준다.
pub const Extent = struct {
    /// `itemHeightPx`가 `[0, count)`의 **모든** index에 답할 수 있어야 한다. 항목 열과 이 수는
    /// 별개 인자라 어긋날 수 있으므로, 소비처는 둘을 한 자리에서 만든다 — 도크의
    /// `ArchiveScrollItems.extent()`가 그 형태다. 여기서 범위를 다시 검사하지 않는 것은 검사를
    /// 잊어서가 아니라, 항목 열을 소유한 쪽이 유일하게 그 답을 알기 때문이다.
    count: usize,
    gap_px: u32,
    viewport_h_px: u32,
};

/// Page 키는 일부러 카드 하나를 화면에 남긴다. viewport가 0에 가까우면 page step이 의미가 없으므로
/// 고정 chrome 치수에서 움직임을 만들어내지 않는다.
pub fn pageStepPx(viewport_h_px: u32, item_h_px: u32) u32 {
    return viewport_h_px -| item_h_px;
}

/// 목록을 굴리는 키 넷. **키 타입이 아니라 뜻**을 받는다 — 호스트마다 물리 키가 다른 자리에서 오고
/// (Win32 는 VK, AppKit 은 `NSEvent`), 그 둘을 여기까지 끌고 오면 중립이 입력 스택을 알게 된다.
/// 호출자가 자기 키 타입에서 이 넷으로 옮긴다.
pub const KeyStep = enum { page_up, page_down, home, end };

/// 키 하나를 offset 변화로 옮긴다(docs/scroll-area.md §4.5 — *"키보드 스크롤도 같은 offset 을 움직이는
/// 동작이므로 ScrollArea 가 제공한다"*).
///
/// **반환값은 「픽셀이 움직였는가」이지 「키를 먹었는가」가 아니다.** 둘을 뭉치면 목록 맨 위에서 친
/// PageUp 이 뒤의 터미널로 새어 스크롤백이 감긴다 — 보이는 목록을 겨눈 키다. *소비했는가*는 소유권
/// 질문이라 host 가 답한다(누가 키를 들고 있는지는 ScrollArea 밖이다 — 같은 문서 §4.6).
///
/// 잔여(`wheel_residue_px`)는 여기서 버린다. 다른 입구가 위치를 확정했으므로 가던 조각은 뜻이 없다.
pub fn applyKeyStep(
    state: *State,
    step: KeyStep,
    viewport_h_px: u32,
    item_h_px: u32,
    max_offset_px: u32,
) bool {
    const page = pageStepPx(viewport_h_px, item_h_px);
    const changed = switch (step) {
        .page_up => state.scrollByPx(-@as(i64, page), max_offset_px),
        .page_down => state.scrollByPx(@as(i64, page), max_offset_px),
        .home => state.setOffsetPx(0, max_offset_px),
        .end => state.setOffsetPx(max_offset_px, max_offset_px),
    };
    state.dropWheelResidue();
    return changed;
}

/// 소비처가 항목의 content-space top과 그 안에서의 비음수 변위를 계산해 넘기면, 스냅샷이 통째로
/// 교체되는 순간에도 같은 자리를 유지한다. 포화·clamp 산술을 여기 두어 재정렬된 anchor가 유계
/// 좌표를 넘지 못하게 한다.
pub fn anchorOffsetPx(item_top_px: u32, intra_item_y_px: u32, max_offset_px: u32) u32 {
    const requested = @as(u64, item_top_px) + @as(u64, intra_item_y_px);
    return @intCast(@min(requested, @as(u64, max_offset_px)));
}

/// Scrollbar의 logical 치수. terminal cell이 아니라 소비처의 metrics가 backing scale에서 resolve한다.
pub const ScrollbarMetrics = struct {
    width_px: u32,
    /// track의 오른쪽 끝과 scroll-area content edge 사이 여백.
    inset_x_px: u32,
    /// content가 아무리 길어도 thumb이 이보다 얇아지지 않는다 — 집을 수 없는 thumb은 affordance가 아니다.
    min_thumb_px: u32,

    /// 컨테이너가 자기 폭에서 상시 예약하는 자리. **잡는 폭이기도 하다**(`ScrollbarGeometry.hit_w`) —
    /// 막대는 이 안에 가운데로 뜬다. 소비처마다 손으로 더하면 예약한 폭과 잡는 폭이 갈라지므로 여기 둔다.
    pub fn gutterPx(self: ScrollbarMetrics) u32 {
        return self.width_px + self.inset_x_px;
    }
};

/// track/thumb의 backing-pixel 기하. 상태가 없으므로 매 프레임 같은 입력에서 같은 결과가 나온다.
///
/// **그리는 폭과 잡는 폭은 다르다.** 한때 `track_w` 하나가 둘을 겸했는데, 막대가 8 backing px(2×에서
/// 화면상 4pt ≈ 1mm)라 보이는 띠를 정확히 찍어야만 잡혔다. 얇게 보이는 것은 의도한 디자인이지만 조준
/// 난이도까지 그 값에 묶인 것은 의도가 아니었다.
///
/// 베이스: xterm.js(VS Code scrollable element)가 `verticalScrollbarSize`(포인터를 받는 트랙)와
/// `verticalSliderSize`(보이는 thumb)를 나누고 slider를 트랙 안에 가운데 정렬한다
/// (`verticalScrollbar.ts` `_createSlider(0, floor((scrollbarSize - sliderSize) / 2), sliderSize)`).
/// 같은 모델을 쓰되 hit 영역은 **거터 밖으로 나가지 않는다** — 거터는 컨테이너가 상시 비워 둔 자리라
/// 그 안은 뺏을 콘텐츠가 없지만, 안쪽으로 넓히면 목록 행 클릭을 가져간다(탐색기는 스크롤바를 행보다
/// 먼저 판정한다). 조준을 더 키우려면 소비처가 거터를 넓힌다.
pub const ScrollbarGeometry = struct {
    /// 그리는 자리(막대 자체).
    track_x: f32,
    track_y: f32,
    track_w: f32,
    track_h: f32,
    /// 잡는 자리(거터 전체). 세로 범위는 track과 같으므로 x축만 따로 든다.
    hit_x: f32,
    hit_w: f32,
    thumb_y: f32,
    thumb_h: f32,
    max_offset_px: u32,

    /// thumb을 잡은 지점(`grab_dy` = 누른 y - thumb top)을 유지한 채 pointer를 따라가는 offset.
    /// 반환값은 이미 [0, max_offset_px]로 clamp되어 있다.
    pub fn offsetForPointer(self: ScrollbarGeometry, pointer_y: f64, grab_dy: f32) u32 {
        if (!std.math.isFinite(pointer_y) or !std.math.isFinite(grab_dy)) return 0;
        const travel = self.track_h - self.thumb_h;
        if (travel <= 0 or self.max_offset_px == 0) return 0;
        const thumb_top = std.math.clamp(
            pointer_y - @as(f64, grab_dy),
            @as(f64, self.track_y),
            @as(f64, self.track_y + travel),
        );
        const ratio = (thumb_top - @as(f64, self.track_y)) / @as(f64, travel);
        const scaled = @round(ratio * @as(f64, @floatFromInt(self.max_offset_px)));
        return @intFromFloat(std.math.clamp(scaled, 0, @as(f64, @floatFromInt(self.max_offset_px))));
    }

    /// thumb 바깥 track click은 그 지점에 thumb 중앙을 놓는다. 이후 드래그와 같은 매핑을 쓰므로
    /// 눌렀다 끌기 시작하는 순간 위치가 튀지 않는다.
    pub fn offsetForTrackClick(self: ScrollbarGeometry, pointer_y: f64) u32 {
        return self.offsetForPointer(pointer_y, self.thumb_h / 2);
    }

    pub fn thumbContains(self: ScrollbarGeometry, y: f64) bool {
        return y >= self.thumb_y and y < self.thumb_y + self.thumb_h;
    }

    /// 발행된 tree에서 되읽은 track rect로부터 잡는 자리를 채운다.
    ///
    /// tree entry에는 **그린 rect만** 실린다(그것이 "보이는 것과 눌리는 것의 단일 출처"인 이유다).
    /// 그래서 hit 폭은 여기서 역산한다 — 막대는 거터 안에 가운데로 뜨므로 좌우 여백이 각각
    /// `(gutter - track) / 2`이고, 그만큼 왼쪽으로 물리면 거터의 왼쪽 끝이 나온다. `scrollbarGeometry`가
    /// 정방향으로 쓰는 식과 같은 관계라 두 경로가 갈라지지 않는다.
    pub fn withHitSpan(self: ScrollbarGeometry, gutter_w: f32) ScrollbarGeometry {
        var next = self;
        const pad = (gutter_w - self.track_w) / 2;
        next.hit_x = self.track_x - pad;
        next.hit_w = gutter_w;
        return next;
    }

    /// 포인터가 스크롤바를 잡는가 — **보이는 막대가 아니라 거터 전체**로 판정한다(위 주석의 이유).
    pub fn trackContains(self: ScrollbarGeometry, x: f64, y: f64) bool {
        return x >= self.hit_x and x < self.hit_x + self.hit_w and
            y >= self.track_y and y < self.track_y + self.track_h;
    }

    /// 같은 track에서 offset만 바뀐 기하. track click이 목록을 옮긴 **직후**의 thumb 위치를 알아야
    /// 이어지는 드래그의 grab 지점이 튀지 않는데, 그 시점에는 아직 새 tree가 발행되지 않았다.
    pub fn withOffset(self: ScrollbarGeometry, offset_px: u32) ScrollbarGeometry {
        if (self.max_offset_px == 0) return self;
        var next = self;
        const travel = self.track_h - self.thumb_h;
        const ratio = @as(f32, @floatFromInt(@min(offset_px, self.max_offset_px))) / @as(f32, @floatFromInt(self.max_offset_px));
        next.thumb_y = self.track_y + travel * ratio;
        return next;
    }
};

/// 스크롤바 드래그의 수명. 좌표를 흡수만 하고 **소비 지점은 tick 하나**다(§6) — pointer move는 tick보다
/// 훨씬 자주 오므로 매 move마다 적용하면 한 프레임에 같은 재투영을 여러 번 하고, tick에서 소비하지
/// 않으면 손을 뗄 때까지 목록이 안 움직인다. 두 실패가 각각 실제로 있었다.
///
/// `interaction`을 import하지 않는다 — 그쪽이 `tree`를 쓰고 `tree`가 이 모듈을 쓰므로 순환이 된다.
/// 그래서 이벤트가 아니라 **좌표만** 받고, payload 판정은 소비처가 한다.
pub const Drag = struct {
    /// 잡은 지점(누른 y − thumb top). 드래그 도중 기하가 바뀌어도 이 값을 유지해야 손가락이 잡은
    /// 자리가 미끄러지지 않는다.
    grab_dy: f32 = 0,
    /// **down 시점**의 기하를 고정한다. 매 move마다 새 기하로 다시 계산하면 thumb이 손가락 아래에서
    /// 미끄러진다.
    geometry: ScrollbarGeometry = .{
        .track_x = 0,
        .track_y = 0,
        .track_w = 0,
        .track_h = 0,
        .hit_x = 0,
        .hit_w = 0,
        .thumb_y = 0,
        .thumb_h = 0,
        .max_offset_px = 0,
    },
    coalescer: continuous_drag.Coalescer(u32) = .{},
    active: bool = false,

    /// down이 스크롤바 위인지 판정하고 드래그를 연다. track의 빈 곳이면 그 지점으로 **먼저 점프**할
    /// offset을 돌려주고, 이어지는 드래그는 옮긴 뒤의 기하를 쓴다 — 그래서 눌렀다 그대로 끌 때 위치가
    /// 튀지 않는다. thumb 위면 null을 돌려주고(목록은 그 자리) 잡은 지점만 기억한다.
    /// 스크롤바 밖이면 드래그를 열지 않고 `active`가 false로 남는다.
    pub fn begin(self: *Drag, bar: ScrollbarGeometry, x: f64, y: f64) ?u32 {
        if (!bar.trackContains(x, y)) return null;
        self.coalescer.reset();
        if (bar.thumbContains(y)) {
            self.* = .{ .grab_dy = @floatCast(y - @as(f64, bar.thumb_y)), .geometry = bar, .active = true };
            return null;
        }
        const jumped = bar.offsetForTrackClick(y);
        const moved = bar.withOffset(jumped);
        self.* = .{ .grab_dy = moved.thumb_h / 2, .geometry = moved, .active = true };
        return jumped;
    }

    /// move/drop 좌표를 흡수만 한다. 적용은 tick의 `takeOffset`이 한 번 한다.
    pub fn absorb(self: *Drag, x_px: f64, y_px: f64) void {
        if (!self.active) return;
        self.coalescer.absorb(x_px, y_px);
    }

    /// tick이 부르는 소비 지점. 이 프레임에 쌓인 마지막 좌표 하나만 offset으로 바꾼다. 값이 직전과
    /// 같으면 null이다 — track 끝에 닿은 채 계속 미는 동안 같은 effect를 반복하지 않는다.
    pub fn takeOffset(self: *Drag) ?u32 {
        if (!self.active) return null;
        const point = self.coalescer.take() orelse return null;
        const offset = self.geometry.offsetForPointer(point.y_px, self.grab_dy);
        if (!self.coalescer.commitIfChanged(offset)) return null;
        return offset;
    }

    /// up·cancel·carry 실패. 다음 down이 자기 grab 지점을 새로 잡도록 흡수분까지 비운다.
    pub fn end(self: *Drag) void {
        self.* = .{};
    }
};

/// scroll-area의 published content rect. scrollbar 기하를 여기서 다시 계산하지 않고 **완성된 tree가
/// 발행한 값**을 읽는 것이 핵심이다 — 그래야 scroll-area가 움직여도 스크롤바가 따라간다(§4).
/// **터치는 콘텐츠를 직접 끈다** — 휠·스크롤바와 다른 모델이다. 손가락이 1px 움직이면 목록도
/// 1px 움직이고, 떼면 그 속도로 미끄러진다(관성). 데스크톱에는 이 모델이 없었고 모바일이
/// 브리지 안에 손으로 갖고 있었다(`set_fling`·`clampSetScroll`) — 두 번째 소비처가 생기면
/// 규칙이 갈리므로 여기로 옮긴다(계획 U1 "폼 컴포넌트는 터치에서 쓸 수 있게 하는 일이다").
///
/// **분수를 여기서 든다.** 발행되는 offset 은 정수 backing pixel 이라(위 `State`) 손가락의
/// 소수점 이동을 그대로 쓰면 매 프레임 반올림이 쌓여 **천천히 끌 때 아예 안 움직인다**.
pub const Touch = struct {
    /// 동시에 추적하는 손가락 수. iOS 11 · Android ~10 이 상한이라 여덟이면 넉넉하다.
    /// **넘치면 새 손가락을 무시한다** — 조용히 덮어쓰면 그 자리의 기준이 남의 것이 된다.
    pub const max_pointers = 8;

    /// 손가락 하나의 상태. **기준과 속도를 손가락마다 둔다** — 하나를 공유하면 소유자가
    /// 바뀔 때 남의 좌표가 그대로 이어져 화면이 점프하고, 그 점프가 속도 계산에 들어가
    /// 상한까지 튄 fling 이 된다(손가락 교체 한 번이 1600px 를 흘려보냈다). AOSP `ScrollView`
    /// 는 기준이 하나라 `onSecondaryPointerUp` 에서 새 기준을 잡고 `VelocityTracker` 를
    /// 비우는데, 그건 **빠뜨릴 수 있는 명시적 처리**다. 손가락마다 두면 그 처리가 없어진다
    /// (Flutter `monodrag.dart` 가 그 모양이다 — `_giveUpPointer` 는 소유자만 넘긴다).
    const Slot = struct {
        used: bool = false,
        id: u32 = 0,
        /// 직전 좌표. 델타는 **직전 대비**다 — down 대비로 재면 임계를 넘는 첫 프레임에
        /// 그동안의 차이가 통째로 적용돼 목록이 툭 뛴다.
        ///
        /// **축은 호출자가 정한다** — 세로 목록이면 y, 가로 키바면 x 를 넘긴다. 규칙이 축과
        /// 무관하므로 두 벌로 두면 한쪽만 고쳐진다(실제로 그랬다).
        last: f32 = 0,
        /// 이번 프레임에 옮긴 거리. **속도는 프레임 경계에서 잰다** — move 하나의 델타로
        /// 잡으면 떼기 직전 한 표본이 느렸다는 이유로 flick 이 죽는다.
        travel: f32 = 0,
        /// px/ms.
        velocity: f32 = 0,
    };

    slots: [max_pointers]Slot = @splat(.{}),
    /// **이 표면의 제스처를 소유한 손가락.** null 이면 닿아 있는 손가락이 없다. 첫 `begin` 이
    /// 잡고, 소유자가 떼면 남은 손가락 중 하나가 이어받는다(계약 §3.1).
    owner: ?u32 = null,
    /// 손을 뗀 뒤 남은 관성(**px/ms**). 손가락이 하나라도 닿아 있으면 0 이다.
    ///
    /// **프레임당이 아니라 밀리초당이다.** 프레임당으로 두면 같은 손짓이 기기마다 다르게
    /// 미끄러진다 — 30Hz Android 와 60Hz iOS 에서 정확히 두 배 차이가 났다(200ms 에 200px 을
    /// 민 손짓이 610px 대 402px).
    fling: f32 = 0,
    /// 1픽셀을 못 채운 이동분. **이것만 면의 것이다** — 손가락이 아니라 offset 에 딸린 값이라
    /// 소유자가 바뀌어도 이어진다.
    residue: f32 = 0,

    /// **밀리초당 감쇠.** 60Hz 에서 프레임당 0.92 이던 것과 같다(`0.92^(1/16.667)`).
    pub const decay_per_ms: f32 = 0.995012;
    /// 이보다 느려지면 멈춘다(px/ms) — 안 그러면 영원히 도는 헛계산이 남는다.
    pub const stop_below: f32 = 0.03;
    /// **속도 상한(px/ms).** 튄 이벤트 하나가 목록을 날리지 않게 한다(≈8000dp/s).
    pub const max_velocity: f32 = 8;
    /// **손가락이 가만히 있다고 보는 폭.** 이보다 크면 밀려던 것이지 누르려던 것이 아니다.
    pub const slop_px: f32 = 10;

    fn find(self: *Touch, id: u32) ?*Slot {
        for (&self.slots) |*s| if (s.used and s.id == id) return s;
        return null;
    }

    fn freeSlot(self: *Touch) ?*Slot {
        for (&self.slots) |*s| if (!s.used) return s;
        return null;
    }

    /// 닿아 있는 손가락 수. **비소유자도 센다** — 핀치(M13)가 이 값을 읽을 자리다.
    pub fn pointerCount(self: *const Touch) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.used) n += 1;
        }
        return n;
    }

    /// 손가락이 닿았다. **관성을 멈춘 것이면 true** — 그 짚음은 "세우려던 것"이지 누른 것이
    /// 아니다. 호출자가 이것을 모르면 멈추려고 짚은 자리의 버튼이 눌린다(실제로 터미널에
    /// 화살표 3바이트가 나갔다).
    pub fn begin(self: *Touch, id: u32, pos: f32) bool {
        const was_flinging = self.fling != 0;
        self.fling = 0;
        if (self.find(id)) |s| {
            // 같은 id 로 down 이 두 번 왔다 — 앞의 것을 못 받은 셈이니 기준만 새로 잡는다.
            s.last = pos;
            s.travel = 0;
            s.velocity = 0;
            if (self.owner == null) self.owner = id;
        } else if (self.freeSlot()) |s| {
            s.* = .{ .used = true, .id = id, .last = pos };
            // **자리를 잡은 손가락만 소유자가 된다.** 밖에서 세우면 슬롯 없는 id 가 소유자가
            // 될 수 있고, 그러면 그 손가락의 `up` 이 슬롯을 못 찾아 **소유권이 영영 안 풀린다**
            // — 그 표면이 "손가락이 닿아 있는" 상태로 굳어 관성도 새 터치도 안 먹는다.
            if (self.owner == null) self.owner = id;
        }
        return was_flinging;
    }

    /// 손가락을 옮긴다. **끄는 방향으로 내용이 따라온다**(세로면 위로 끌 때 목록이 위로).
    /// **소유자가 아닌 손가락은 화면을 안 움직인다** — 기준만 갱신해 둔다(이어받을 때 쓴다).
    pub fn move(self: *Touch, state: *State, id: u32, pos: f32, max_offset_px: u32) void {
        const s = self.find(id) orelse return; // down 을 못 받은 id — 무시한다(계약 §3.1)
        const d = pos - s.last;
        s.last = pos;
        s.travel += d;
        if (self.owner) |o| {
            if (o == id) self.applyDelta(state, -d, max_offset_px);
        }
    }

    /// 손가락 하나를 뗀다. `dt_ms` 는 프레임 간격(`step` 과 같은 값).
    ///
    /// **소유자가 떼져도 남은 손가락이 있으면 관성이 안 붙는다** — 제스처가 이어지는 중이다.
    /// 그 손가락은 자기 `down` 이후로 자기 기준을 갱신해 왔으므로 **재기준할 것이 없다.**
    ///
    /// 속도는 여기서도 잰다 — 손짓이 통째로 한 프레임 안에서 끝나면 프레임 경계 표본이
    /// 0 이 된다(30Hz 에서는 흔하다). **다만 덮어쓰지 않는다**: 떼기 직전 1px 짜리 조각으로
    /// 갈아치우면 속도가 서른 배 준다(실측 -1.875 → -0.0625). 더 빠른 쪽만 취한다.
    pub fn end(self: *Touch, id: u32, dt_ms: f32) void {
        const s = self.find(id) orelse return;
        const dt = std.math.clamp(dt_ms, 1, 100);
        if (s.travel != 0) {
            const tail = std.math.clamp(s.travel / dt, -max_velocity, max_velocity);
            if (@abs(tail) > @abs(s.velocity)) s.velocity = tail;
        }
        const was_owner = if (self.owner) |o| o == id else false;
        const v = s.velocity;
        s.* = .{}; // **슬롯을 비운다** — host 의 id 는 재사용된다(계약 §3.1: down~up 동안만 같다)
        if (!was_owner) return;
        self.owner = null;
        for (self.slots) |o| {
            if (o.used) {
                self.owner = o.id;
                break;
            }
        }
        if (self.owner == null) self.fling = v; // 아무도 안 남았을 때만 관성이 시작된다
    }

    /// 취소(제스처가 뺏겼다·화면이 바뀐다) — **id 와 무관하게 전부 끝난다**(계약 §3.1).
    pub fn cancel(self: *Touch) void {
        self.slots = @splat(.{});
        self.owner = null;
        self.fling = 0;
        self.residue = 0;
    }

    /// 매 프레임 한 번. `dt_ms` 는 **직전 프레임과의 간격**이다(host 가 주는 프레임 시각의 차).
    ///
    /// 손가락이 닿아 있으면 미끄러뜨리지 않고 **이번 프레임의 속도만 잰다** — 떼는 순간 그
    /// 값이 관성이 된다. **비소유자도 잰다**: 그 손가락이 이어받은 뒤 떼면 자기 속도로 흘러야 한다.
    /// **움직였으면 true** — 매 프레임 다시 그리지 않는 화면(데스크톱)은 이걸로 다시 그릴
    /// 자리를 안다.
    pub fn step(self: *Touch, state: *State, max_offset_px: u32, dt_ms: f32) bool {
        const dt = std.math.clamp(dt_ms, 1, 100); // 멈췄다 재개한 프레임이 관성을 날리지 않게
        if (self.owner != null) {
            for (&self.slots) |*s| {
                if (!s.used) continue;
                s.velocity = std.math.clamp(s.travel / dt, -max_velocity, max_velocity);
                s.travel = 0;
            }
            return false;
        }
        if (self.fling == 0) return false;
        const before = state.offset_y_px;
        self.applyDelta(state, -self.fling * dt, max_offset_px);
        // **끝에 닿으면 속도도 죽인다.** 값만 자르면 관성이 계속 돌아 매 프레임 헛계산을 하고,
        // 되돌리려 손을 대면 죽은 속도가 남아 있다가 튄다.
        if (state.offset_y_px == 0 or state.offset_y_px == max_offset_px) {
            self.fling = 0;
            self.residue = 0;
            return state.offset_y_px != before;
        }
        self.fling *= std.math.pow(f32, decay_per_ms, dt);
        if (@abs(self.fling) < stop_below) self.fling = 0;
        return state.offset_y_px != before;
    }

    fn applyDelta(self: *Touch, state: *State, delta_px: f32, max_offset_px: u32) void {
        const total = delta_px + self.residue;
        const whole = @trunc(total);
        self.residue = total - whole;
        if (whole == 0) return;
        _ = state.scrollByPx(@intFromFloat(whole), max_offset_px);
    }
};

pub const ContentRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// scroll-area 오른쪽에 남아 있는 컨테이너 padding 폭. 스크롤바는 **그 여백 안에** 놓여 content와
    /// 겹치지 않는다. 여백이 모자라면 아예 그리지 않는다 — 목록 위에 겹쳐 그리는 대안은 사용자가
    /// "UI랑 겹쳐 보인다"고 보고한 바로 그 상태다.
    gutter_w: f32,
};

/// 축 하나에서 thumb이 **얼마나 길고 어디서 시작하는가**. track 위 좌표가 아니라 **길이와 오프셋**만
/// 낸다 — 그래야 세로·가로가 같은 규칙을 쓴다.
///
/// **규칙을 한 곳에 두려고 뽑았다.** 비율(`track × viewport / content`)·최소 두께·travel 매핑 셋은
/// 축과 무관한데, 축마다 다시 적으면 한쪽만 고쳐질 자리가 된다(이 저장소가 반복해서 겪은 부류다).
pub const ThumbSpan = struct {
    /// thumb 길이(px).
    len: f32,
    /// track 시작점에서 thumb 시작까지의 거리(px).
    start_offset: f32,
    /// 스크롤 가능한 최대 오프셋(px). 0이면 스크롤할 것이 없다.
    max_offset_px: u32,
};

/// 넘치지 않으면 `null`. 그 경우 호출자는 아무것도 그리지 않는다 — 넘치지 않는데 막대를 두면
/// 사용자에게 없는 여백을 있다고 말하는 셈이다.
pub fn thumbSpan(
    /// 막대가 움직일 수 있는 전체 길이(= 뷰포트의 그 축 길이).
    track_len: f32,
    /// 문서 전체가 그 축에서 차지하는 길이(px).
    content_len_px: u32,
    /// 지금 스크롤 위치(px).
    offset_px: u32,
    min_thumb_px: u32,
) ?ThumbSpan {
    if (track_len <= 0) return null;
    const viewport_len_px: u32 = @intFromFloat(@max(track_len, 0));
    const max_offset = content_len_px -| viewport_len_px;
    if (max_offset == 0) return null;

    const proportional = track_len * track_len / @as(f32, @floatFromInt(content_len_px));
    const len = @min(track_len, @max(@as(f32, @floatFromInt(min_thumb_px)), proportional));
    const travel = track_len - len;
    const clamped = @min(offset_px, max_offset);
    const ratio = @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(max_offset));
    return .{ .len = len, .start_offset = travel * ratio, .max_offset_px = max_offset };
}

/// 스크롤할 것이 없거나 자리가 안 나오면 `null`이며, 그 경우 어떤 track/thumb도 발행하지 않는다 —
/// 넘치지 않는 목록에 스크롤바를 그리면 사용자에게 없는 여백을 있다고 말하는 셈이다.
pub fn scrollbarGeometry(
    content: ContentRect,
    content_height_px: u32,
    offset_px: u32,
    m: ScrollbarMetrics,
) ?ScrollbarGeometry {
    if (content.w <= 0 or content.h <= 0 or m.width_px == 0) return null;
    const width: f32 = @floatFromInt(m.width_px);
    if (content.gutter_w < width) return null;

    // **길이 계산은 축 중립 헬퍼가 한다**(`thumbSpan`) — 가로 막대와 같은 규칙을 쓰게 하려고 뽑았다.
    const track_h = content.h;
    const span = thumbSpan(track_h, content_height_px, offset_px, m.min_thumb_px) orelse return null;
    const thumb_h = span.len;
    const max_offset = span.max_offset_px;
    return .{
        // 여백 안에서 가운데. 컨테이너 바깥 edge에 붙이면 rounded clip에 닿아 잘려 보이고, content에
        // 붙이면 다시 카드와 겹친다.
        .track_x = content.x + content.w + (content.gutter_w - width) / 2,
        .track_y = content.y,
        .track_w = width,
        .track_h = track_h,
        // 잡는 자리는 거터 전체 — content edge에서 거터 끝까지. 막대는 그 안에 가운데로 뜬다.
        .hit_x = content.x + content.w,
        .hit_w = content.gutter_w,
        .thumb_y = content.y + span.start_offset,
        .thumb_h = thumb_h,
        .max_offset_px = max_offset,
    };
}

/// 유계 항목 열을 allocation 없이 창으로 자른다.
///
/// 높이를 **나눗셈이 아니라 walk로** 구하는 것이 계약이다(§3). 항목 높이가 같다는 보장이 없기
/// 때문이다 — 도크는 그룹 헤더와 카드가 다르고 펼친 카드는 또 다르다. `first_index * item_h`는
/// 그 순간 틀린 답을 낸다. `itemHeightPx`가 comptime인 덕에 이 알고리즘은 소비처의 레코드 타입을
/// 모른 채로 남는다.
pub fn project(
    context: anytype,
    comptime itemHeightPx: fn (@TypeOf(context), usize) u32,
    extent: Extent,
    requested_offset_px: u32,
) Projection {
    const count = extent.count;
    var content_height: u32 = 0;
    for (0..count) |index| {
        content_height +|= itemHeightPx(context, index);
        if (index + 1 < count) content_height +|= extent.gap_px;
    }
    const max_offset = content_height -| extent.viewport_h_px;
    const offset = @min(requested_offset_px, max_offset);

    var cursor: u32 = 0;
    var first = count;
    for (0..count) |index| {
        const h = itemHeightPx(context, index);
        const end = cursor +| h;
        if (end > offset) {
            first = index;
            break;
        }
        cursor = end +| if (index + 1 < count) extent.gap_px else 0;
    }
    if (first == count) return .{
        .content_height_px = content_height,
        .max_offset_px = max_offset,
        .offset_y_px = offset,
        .first_index = count,
        .first_origin_y_px = 0,
        .end_exclusive = count,
    };

    var end = first;
    const first_origin: i64 = @as(i64, cursor) - @as(i64, offset);
    var y = first_origin;
    while (end < count and y < @as(i64, extent.viewport_h_px)) : (end += 1) {
        y += @as(i64, itemHeightPx(context, end));
        if (end + 1 < count) y += extent.gap_px;
    }
    return .{
        .content_height_px = content_height,
        .max_offset_px = max_offset,
        .offset_y_px = offset,
        .first_index = first,
        .first_origin_y_px = @intCast(std.math.clamp(first_origin, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)))),
        .end_exclusive = end,
    };
}

const FixtureKind = enum { group, card };

const Fixture = struct {
    kinds: []const FixtureKind,
    group_h_px: u32,
    card_h_px: u32,
    expanded_index: ?usize = null,
    expanded_h_px: u32 = 0,
};

fn fixtureHeight(fixture: Fixture, index: usize) u32 {
    if (fixture.kinds[index] == .card and fixture.expanded_index != null and fixture.expanded_index.? == index)
        return fixture.expanded_h_px;
    return switch (fixture.kinds[index]) {
        .group => fixture.group_h_px,
        .card => fixture.card_h_px,
    };
}

test "project clips partial first and last item without a trailing gap" {
    const kinds = [_]FixtureKind{ .group, .card, .card };
    const fixture = Fixture{ .kinds = &kinds, .group_h_px = 20, .card_h_px = 50 };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 10, .viewport_h_px = 60 }, 35);
    try std.testing.expectEqual(@as(u32, 140), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 80), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -5), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 3), result.end_exclusive);
}

test "project reserves one expanded item in the same scroll coordinate" {
    const kinds = [_]FixtureKind{ .group, .card, .card };
    const fixture = Fixture{
        .kinds = &kinds,
        .group_h_px = 20,
        .card_h_px = 50,
        .expanded_index = 1,
        .expanded_h_px = 170,
    };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 0, .viewport_h_px = 100 }, 60);
    // group 20 + 펼친 카드 170 + 보통 카드 50. viewport가 펼침 안에서 시작하므로 그 원점과 다음
    // 카드가 같은 170px 사각형을 써야 한다.
    try std.testing.expectEqual(@as(u32, 240), result.content_height_px);
    try std.testing.expectEqual(@as(u32, 140), result.max_offset_px);
    try std.testing.expectEqual(@as(usize, 1), result.first_index);
    try std.testing.expectEqual(@as(i32, -40), result.first_origin_y_px);
    try std.testing.expectEqual(@as(usize, 2), result.end_exclusive);
}

test "project walks heights instead of dividing by a uniform item height" {
    // 높이가 섞이면 나눗셈 근사(`offset / item_h`)와 답이 갈린다. 이 case가 그 차이를 고정한다.
    const kinds = [_]FixtureKind{ .group, .card, .group, .card };
    const fixture = Fixture{ .kinds = &kinds, .group_h_px = 20, .card_h_px = 100 };
    const result = project(fixture, fixtureHeight, .{ .count = kinds.len, .gap_px = 0, .viewport_h_px = 100 }, 130);
    // 누적: group [0,20) card [20,120) group [120,140) card [140,240).
    // offset 130은 세 번째 항목 안이다. 균일 높이 100으로 나눴다면 index 1이 나왔을 것이다.
    try std.testing.expectEqual(@as(usize, 2), result.first_index);
    try std.testing.expectEqual(@as(i32, -10), result.first_origin_y_px);
}

test "scroll state clamps each backing pixel boundary" {
    var state = State{};
    try std.testing.expect(state.scrollByPx(1, 9));
    try std.testing.expectEqual(@as(u32, 1), state.offset_y_px);
    _ = state.scrollByPx(100, 9);
    try std.testing.expectEqual(@as(u32, 9), state.offset_y_px);
    _ = state.scrollByPx(-100, 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
    _ = state.scrollByPx(std.math.maxInt(i64), 9);
    try std.testing.expectEqual(@as(u32, 9), state.offset_y_px);
    _ = state.scrollByPx(std.math.minInt(i64), 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
    try std.testing.expect(state.setOffsetPx(7, 9));
    try std.testing.expectEqual(@as(u32, 7), state.offset_y_px);
    _ = state.setOffsetPx(-1, 9);
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
}

test "a move that changes nothing reports false so it cannot force a repaint" {
    // 이 bool은 세 호출부에서 전부 리페인트 신호다 — 휠은 `if (scrollByPx(...))`로 metal_dirty를
    // 세우고, 드래그는 false면 조기 반환하며, 키보드는 changed로 같은 판단을 한다. 그래서 "안
    // 움직였는데 true"는 무해한 값이 아니라, 끝에 닿은 채 휠을 굴리는 동안 매 이벤트마다 프레임을
    // 다시 그리게 만드는 결함이다.
    var state = State{};
    try std.testing.expect(!state.scrollByPx(0, 100)); // 델타 0
    try std.testing.expect(!state.scrollByPx(-5, 100)); // 이미 맨 위
    try std.testing.expect(state.scrollByPx(100, 100)); // 맨 아래까지 이동
    try std.testing.expect(!state.scrollByPx(1, 100)); // 이미 맨 아래
    try std.testing.expect(!state.setOffsetPx(100, 100)); // 같은 값
    try std.testing.expect(!state.setOffsetPx(999, 100)); // clamp 후 같은 값
    try std.testing.expect(state.setOffsetPx(0, 100)); // 실제 이동
}

test "clamp and reset are the two ways an offset shrinks without pointer input" {
    // 그룹을 접으면 content가 짧아지고 max offset이 줄어든다. `clamp`가 그때 offset을 끌어내리는
    // 유일한 지점이라, 이것이 no-op이면 목록이 빈 공간에 스크롤된 채 남는다 — 이 계약을 보는
    // 판정자가 없어서 clamp를 통째로 비워도 전체 스위트가 초록이었다.
    var state = State{};
    _ = state.setOffsetPx(400, 400);
    state.clamp(400); // 상한이 그대로면 움직이지 않는다.
    try std.testing.expectEqual(@as(u32, 400), state.offset_y_px);
    state.clamp(120); // 짧아진 목록: 새 상한까지 끌어내린다.
    try std.testing.expectEqual(@as(u32, 120), state.offset_y_px);
    state.clamp(0); // 전부 접혀 스크롤할 것이 없어졌다.
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);

    // reset은 상한과 무관하게 맨 위다(검색어 변경처럼 목록의 의미 자체가 바뀔 때).
    _ = state.setOffsetPx(300, 400);
    state.reset();
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
}

test "project stays bounded when there is nothing to show or nowhere to show it" {
    const kinds = [_]FixtureKind{ .card, .card };
    const empty = Fixture{ .kinds = &kinds, .group_h_px = 20, .card_h_px = 50 };

    // 검색 결과가 0개인 도크. 창은 비어야 하고 offset은 0으로 눌린다.
    const none = project(empty, fixtureHeight, .{ .count = 0, .gap_px = 10, .viewport_h_px = 400 }, 999);
    try std.testing.expectEqual(@as(u32, 0), none.content_height_px);
    try std.testing.expectEqual(@as(u32, 0), none.max_offset_px);
    try std.testing.expectEqual(@as(u32, 0), none.offset_y_px);
    try std.testing.expectEqual(@as(usize, 0), none.first_index);
    try std.testing.expectEqual(@as(usize, 0), none.end_exclusive);

    // 도크를 끝까지 줄여 스크롤 영역 높이가 0인 상태. 그릴 항목이 없어야지, 전부여서는 안 된다.
    const flat = project(empty, fixtureHeight, .{ .count = kinds.len, .gap_px = 10, .viewport_h_px = 0 }, 0);
    try std.testing.expectEqual(@as(u32, 110), flat.content_height_px);
    try std.testing.expectEqual(@as(usize, 0), flat.first_index);
    try std.testing.expectEqual(@as(usize, 0), flat.end_exclusive);

    // offset이 상한을 넘겨 들어와도 창은 마지막 항목 안에 머문다.
    const past_end = project(empty, fixtureHeight, .{ .count = kinds.len, .gap_px = 10, .viewport_h_px = 50 }, 999);
    try std.testing.expectEqual(@as(u32, 60), past_end.max_offset_px);
    try std.testing.expectEqual(@as(u32, 60), past_end.offset_y_px);
    try std.testing.expectEqual(@as(usize, 1), past_end.first_index);
    try std.testing.expectEqual(@as(usize, 2), past_end.end_exclusive);
}

test "page and anchor helpers preserve bounded pixel semantics" {
    try std.testing.expectEqual(@as(u32, 0), pageStepPx(0, 72));
    try std.testing.expectEqual(@as(u32, 0), pageStepPx(72, 72));
    try std.testing.expectEqual(@as(u32, 128), pageStepPx(200, 72));
    try std.testing.expectEqual(@as(u32, 145), anchorOffsetPx(120, 25, 400));
    try std.testing.expectEqual(@as(u32, 400), anchorOffsetPx(399, 9, 400));
    try std.testing.expectEqual(@as(u32, 400), anchorOffsetPx(std.math.maxInt(u32), std.math.maxInt(u32), 400));
}

test "applyKeyStep: 한 항목을 남기고 넘기며 · 끝과 처음에 정확히 닿는다" {
    const viewport: u32 = 200;
    const item: u32 = 72;
    const max_offset: u32 = 500;
    var state: State = .{};

    // PageDown 은 **한 항목을 남긴다** — 한 화면을 통째로 넘기면 읽던 자리가 끊긴다(`pageStepPx` 계약).
    try std.testing.expect(applyKeyStep(&state, .page_down, viewport, item, max_offset));
    try std.testing.expectEqual(viewport - item, state.offset_y_px);
    try std.testing.expect(applyKeyStep(&state, .page_up, viewport, item, max_offset));
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);

    // End 는 정확히 상한, Home 은 0 이다 — 한 걸음 모자라면 마지막 항목에 영영 못 닿는다.
    try std.testing.expect(applyKeyStep(&state, .end, viewport, item, max_offset));
    try std.testing.expectEqual(max_offset, state.offset_y_px);
    try std.testing.expect(applyKeyStep(&state, .home, viewport, item, max_offset));
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);
}

test "applyKeyStep: 경계에서는 false 를 내지만 그것은 「안 먹었다」가 아니다" {
    var state: State = .{};
    // 맨 위에서의 PageUp·Home 은 픽셀을 못 움직인다. 반환값은 **움직였는가**이고, 소비 여부는 host 가
    // 따로 판정한다 — 그 둘을 뭉치면 목록을 겨눈 키가 뒤의 터미널로 샌다.
    try std.testing.expect(!applyKeyStep(&state, .page_up, 200, 72, 500));
    try std.testing.expect(!applyKeyStep(&state, .home, 200, 72, 500));

    // 굴릴 것이 없는 목록(상한 0)에서는 넷 다 0 에 머문다.
    try std.testing.expect(!applyKeyStep(&state, .page_down, 200, 72, 0));
    try std.testing.expect(!applyKeyStep(&state, .end, 200, 72, 0));
    try std.testing.expectEqual(@as(u32, 0), state.offset_y_px);

    // 뷰포트가 항목보다 작으면 page step 이 0 이다 — 고정 chrome 치수에서 움직임을 만들지 않는다.
    _ = applyKeyStep(&state, .end, 200, 72, 500);
    try std.testing.expect(!applyKeyStep(&state, .page_up, 40, 72, 500));
    try std.testing.expectEqual(@as(u32, 500), state.offset_y_px);
}

test "applyKeyStep: 가던 휠 조각을 버린다" {
    var state: State = .{ .offset_y_px = 100, .wheel_residue_px = 0.7 };
    // 키가 위치를 확정했으므로 아직 1픽셀을 못 채운 휠 잔여는 뜻이 없다. 안 버리면 다음 눈금이 그만큼
    // 더 움직여, 키로 맞춘 자리가 휠 한 번에 어긋난다(§2m.84 가 표면 사이에서 겪은 그 실패다).
    _ = applyKeyStep(&state, .page_down, 200, 72, 500);
    try std.testing.expectEqual(@as(f64, 0), state.wheel_residue_px);

    // **움직이지 않은 걸음도 버린다** — 상한에 붙어 있어도 잔여는 남기지 않는다.
    state = .{ .offset_y_px = 500, .wheel_residue_px = 0.9 };
    try std.testing.expect(!applyKeyStep(&state, .end, 200, 72, 500));
    try std.testing.expectEqual(@as(f64, 0), state.wheel_residue_px);
}

test "scrollbar geometry only exists when the list actually overflows" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    // 넘치지 않으면 발행하지 않는다 — 없는 여백을 있다고 말하지 않기 위해서다.
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 400, 0, m) == null);
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 300, 0, m) == null);
    // 여백이 track 폭을 못 담으면 그리지 않는다 — 목록 위에 겹쳐 그리는 대안은 두지 않는다.
    try std.testing.expect(scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 4 }, 4000, 0, m) == null);
}

test "scrollbar thumb spans the visible proportion and reaches both ends" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const content = ContentRect{ .x = 10, .y = 20, .w = 200, .h = 400, .gutter_w = 40 };
    const top = scrollbarGeometry(content, 1600, 0, m).?;
    try std.testing.expectEqual(@as(f32, 226), top.track_x); // 10 + 200 + (40 - 8) / 2
    try std.testing.expectEqual(@as(f32, 20), top.track_y);
    try std.testing.expectEqual(@as(u32, 1200), top.max_offset_px);
    // 보이는 비율 400/1600 = 1/4.
    try std.testing.expectEqual(@as(f32, 100), top.thumb_h);
    try std.testing.expectEqual(@as(f32, 20), top.thumb_y);

    const bottom = scrollbarGeometry(content, 1600, 1200, m).?;
    // 맨 아래에서 thumb 밑변이 track 밑변과 정확히 맞는다.
    try std.testing.expectApproxEqAbs(bottom.track_y + bottom.track_h - bottom.thumb_h, bottom.thumb_y, 0.01);
}

test "scrollbar thumb never gets too thin to grab" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    // 아주 긴 목록: 비례 높이는 0.04px지만 최소 높이가 이긴다.
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 0, .w = 200, .h = 400, .gutter_w = 40 }, 4_000_000, 0, m).?;
    try std.testing.expectEqual(@as(f32, 24), geometry.thumb_h);
}

test "scrollbar drag round trips every reachable offset and clamps beyond the track" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 5, .w = 180, .h = 400, .gutter_w = 40 }, 1200, 0, m).?;
    const travel = geometry.track_h - geometry.thumb_h;
    // thumb top을 정확히 그 offset의 위치에 놓으면 같은 offset이 돌아온다.
    for ([_]u32{ 0, 1, 137, 400, 799, 800 }) |wanted| {
        if (wanted > geometry.max_offset_px) continue;
        const y = geometry.track_y + travel * @as(f32, @floatFromInt(wanted)) / @as(f32, @floatFromInt(geometry.max_offset_px));
        try std.testing.expectEqual(wanted, geometry.offsetForPointer(y, 0));
    }
    // track 밖으로 끌어도 범위를 넘지 않는다.
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForPointer(-10_000, 0));
    try std.testing.expectEqual(geometry.max_offset_px, geometry.offsetForPointer(10_000, 0));
    // 비유한 좌표는 기하를 무의미하게 만들므로 흘려보내지 않는다.
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForPointer(std.math.nan(f64), 0));
}

test "withOffset predicts exactly what the next published geometry will be" {
    // 이 함수는 track click이 목록을 옮긴 **직후**, 아직 새 tree가 발행되기 전에 이어지는 드래그의
    // grab 기준점을 만든다. 그러므로 계약은 "그럴듯한 thumb 위치"가 아니라 **다음 프레임이 발행할
    // 바로 그 값**이다. 두 경로가 갈리면 손을 뗐다 잡을 때마다 thumb이 눈에 띄게 튄다.
    //
    // 이 계약을 보는 판정자가 없었다: `withOffset`의 비율을 절반으로 바꿔도 전체 스위트가 초록이었다.
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const content = ContentRect{ .x = 10, .y = 20, .w = 200, .h = 400, .gutter_w = 40 };
    const at_top = scrollbarGeometry(content, 1600, 0, m).?;
    for ([_]u32{ 0, 1, 250, 600, 1199, 1200, 99_999 }) |offset| {
        const published = scrollbarGeometry(content, 1600, offset, m).?;
        try std.testing.expectApproxEqAbs(published.thumb_y, at_top.withOffset(offset).thumb_y, 0.01);
    }
    // 스크롤할 것이 없으면 옮길 곳도 없다.
    const fixed = ScrollbarGeometry{ .track_x = 0, .track_y = 0, .track_w = 8, .track_h = 100, .hit_x = 0, .hit_w = 8, .thumb_y = 0, .thumb_h = 100, .max_offset_px = 0 };
    try std.testing.expectEqual(@as(f32, 0), fixed.withOffset(50).thumb_y);
}

test "thumb and track containment use half-open bounds so adjacent pixels never both hit" {
    const geometry = ScrollbarGeometry{ .track_x = 100, .track_y = 20, .track_w = 8, .track_h = 400, .hit_x = 100, .hit_w = 8, .thumb_y = 60, .thumb_h = 40, .max_offset_px = 1200 };
    // thumb의 위 경계는 포함, 아래 경계는 제외다. 닫힌 구간이면 thumb 바로 아래 1px이 thumb이자
    // track이라 같은 down이 드래그와 점프 둘 다로 읽힌다.
    try std.testing.expect(geometry.thumbContains(60));
    try std.testing.expect(geometry.thumbContains(99.9));
    try std.testing.expect(!geometry.thumbContains(100));
    try std.testing.expect(!geometry.thumbContains(59.9));
    // track은 x도 본다 — gutter 밖 클릭이 스크롤로 새면 안 된다.
    try std.testing.expect(geometry.trackContains(100, 20));
    try std.testing.expect(geometry.trackContains(107.9, 419.9));
    try std.testing.expect(!geometry.trackContains(108, 200));
    try std.testing.expect(!geometry.trackContains(99.9, 200));
    try std.testing.expect(!geometry.trackContains(104, 420));
    try std.testing.expect(!geometry.trackContains(104, 19.9));
}

// 잡는 폭은 **거터 전체**이고 그리는 폭은 막대뿐이다. 한때 `track_w` 하나가 둘을 겸해, 화면상 4pt
// (8 backing px @2×)짜리 띠를 정확히 찍어야만 스크롤바가 잡혔다.
//
// 고정하는 것 둘: (a) 거터의 왼쪽 끝 — content edge 바로 옆 — 에서도 잡힌다(막대는 거기서 떨어져 있다),
// (b) 그래도 거터 **밖**으로는 새지 않는다. (b)가 없으면 목록 행 클릭을 가져간다.
test "scrollbar hit span covers the whole gutter, not just the painted bar" {
    // content가 [10, 210), 거터 16px(210..226), 막대 8px → 막대는 그 안 가운데(214..222).
    const content = ContentRect{ .x = 10, .y = 0, .w = 200, .h = 100, .gutter_w = 16 };
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 8, .min_thumb_px = 24 };
    const bar = scrollbarGeometry(content, 400, 0, m).?;

    try std.testing.expectEqual(@as(f32, 214), bar.track_x); // 10 + 200 + (16 - 8) / 2
    try std.testing.expectEqual(@as(f32, 8), bar.track_w); // 보이는 굵기는 막대 그대로
    try std.testing.expectEqual(@as(f32, 210), bar.hit_x); // 잡는 자리는 content edge부터
    try std.testing.expectEqual(@as(f32, 16), bar.hit_w); // 거터 전체

    // 막대(214..222)에 닿지 않는 거터 자리에서도 잡힌다 — 이것이 이 슬라이스가 산 것이다.
    try std.testing.expect(bar.trackContains(210, 50)); // 막대 왼쪽 여백
    try std.testing.expect(bar.trackContains(224, 50)); // 막대 오른쪽 여백
    try std.testing.expect(bar.trackContains(225.9, 50));
    // 거터 밖은 여전히 아니다(왼쪽=목록 행, 오른쪽=컨테이너 밖).
    try std.testing.expect(!bar.trackContains(209.9, 50));
    try std.testing.expect(!bar.trackContains(226, 50));

    // 발행된 tree에서 되읽는 경로도 같은 값을 얻는다 — tree에는 그린 rect만 실려서 역산이 필요하고,
    // 그 역산이 정방향과 갈라지면 "보이는 곳 ≠ 눌리는 곳"이 된다.
    const from_tree = (ScrollbarGeometry{
        .track_x = bar.track_x,
        .track_y = bar.track_y,
        .track_w = bar.track_w,
        .track_h = bar.track_h,
        .hit_x = bar.track_x,
        .hit_w = bar.track_w,
        .thumb_y = bar.thumb_y,
        .thumb_h = bar.thumb_h,
        .max_offset_px = bar.max_offset_px,
    }).withHitSpan(@floatFromInt(m.gutterPx()));
    try std.testing.expectEqual(bar.hit_x, from_tree.hit_x);
    try std.testing.expectEqual(bar.hit_w, from_tree.hit_w);
}

test "track click centers the thumb at the pointer" {
    const m = ScrollbarMetrics{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 };
    const geometry = scrollbarGeometry(.{ .x = 0, .y = 0, .w = 180, .h = 400, .gutter_w = 40 }, 1200, 0, m).?;
    // 트랙 정중앙을 누르면 thumb 중앙이 거기 오므로 offset도 대략 절반이다.
    const middle = geometry.offsetForTrackClick(geometry.track_y + geometry.track_h / 2);
    try std.testing.expect(middle > geometry.max_offset_px * 4 / 10);
    try std.testing.expect(middle < geometry.max_offset_px * 6 / 10);
    try std.testing.expectEqual(@as(u32, 0), geometry.offsetForTrackClick(geometry.track_y));
}

// ── 터치 스크롤 ────────────────────────────────────────────────────────────────

test "터치: 손가락을 따라 1:1 로 움직이고 떼면 미끄러진다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 100);
    t.move(&st, 1, 90, 1000); // 위로 10px → 목록이 10px 내려간다
    try std.testing.expectEqual(@as(u32, 10), st.offset_y_px);
    t.end(1, 16);
    // 관성: 마지막 속도(-10)가 감쇠하며 계속 민다.
    _ = t.step(&st, 1000, 16);
    try std.testing.expect(st.offset_y_px > 10);
}

test "터치: 손가락이 닿아 있는 동안에는 관성이 안 돈다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 100);
    t.move(&st, 1, 50, 1000);
    const held = st.offset_y_px;
    _ = t.step(&st, 1000, 16); // 아직 안 뗐다
    try std.testing.expectEqual(held, st.offset_y_px);
}

test "터치: 천천히 끌어도 움직인다(분수 누적)" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 100);
    var i: u32 = 0;
    while (i < 4) : (i += 1) t.move(&st, 1, 100 - @as(f32, @floatFromInt(i + 1)) * 0.3, 1000);
    // 0.3px 씩 네 번 = 1.2px — 반올림으로 버리면 0 이 된다.
    try std.testing.expect(st.offset_y_px >= 1);
}

test "터치: 끝에 닿으면 속도도 죽는다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 100);
    t.move(&st, 1, 0, 50); // 상한(50)을 넘겨 민다
    t.end(1, 16);
    _ = t.step(&st, 50, 16);
    try std.testing.expectEqual(@as(u32, 50), st.offset_y_px);
    try std.testing.expectEqual(@as(f32, 0), t.fling);
}

test "터치: 취소는 관성을 안 남긴다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 100);
    t.move(&st, 1, 50, 1000);
    t.cancel();
    const at = st.offset_y_px;
    _ = t.step(&st, 1000, 16);
    try std.testing.expectEqual(at, st.offset_y_px);
}

// **같은 손짓은 주사율이 달라도 같은 거리를 미끄러져야 한다.** 예전에는 감쇠가 프레임당이라
// 30Hz 기기가 60Hz 기기의 **두 배** 멀리 갔다(같은 200ms·200px 손짓이 610px 대 402px). 두 host
// 가 실제로 30Hz(Android)와 60Hz(iOS)라 사용자가 기기를 바꾸면 손맛이 달라졌다.
test "Touch: 같은 손짓은 주사율이 달라도 같은 거리를 간다" {
    const max: u32 = 100_000;
    const S = struct {
        fn flick(frames: u32, dt: f32) u32 {
            var st: State = .{};
            var t: Touch = .{};
            _ = t.begin(1, 1000);
            var y: f32 = 1000;
            var i: u32 = 0;
            while (i < frames) : (i += 1) {
                y -= 200.0 / @as(f32, @floatFromInt(frames)); // 200ms 동안 200px — 같은 속도
                t.move(&st, 1, y, max);
                _ = t.step(&st, max, dt); // 닿아 있는 동안은 속도만 잰다
            }
            t.end(1, dt);
            var f: u32 = 0;
            while (f < 1000) : (f += 1) _ = t.step(&st, max, dt);
            return st.offset_y_px;
        }
    };
    const slow = S.flick(6, 200.0 / 6.0); // 30Hz
    const fast = S.flick(12, 200.0 / 12.0); // 60Hz
    // 정수 offset·분수 잔여·표본 수 때문에 몇 px 은 갈린다(실측 411 대 402, 2%). **배수로
    // 갈리면 안 된다**는 것이 이 테스트가 지키는 것이다 — 고치기 전에는 610 대 402 였다.
    const diff = if (slow > fast) slow - fast else fast - slow;
    try std.testing.expect(diff * 20 <= fast); // 5% 안
}

// 튄 이벤트 하나(예: 배경에서 돌아오며 좌표가 통째로 바뀐 경우)가 화면을 날리지 않는다.
test "Touch: 속도에 상한이 있다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 0);
    t.move(&st, 1, -100_000, 1_000_000); // 한 이벤트에 10만 px
    t.end(1, 16);
    try std.testing.expect(@abs(t.fling) <= Touch.max_velocity);
}

// **떼기 직전의 작은 표본 하나가 flick 을 죽이면 안 된다.** 프레임 경계에서 잰 속도가 있는데
// 그 뒤에 1~2px 짜리 move 하나가 더 오고 손을 떼면, 그 조각으로 덮어쓰면 속도가 열 배 넘게
// 준다(꼬리가 충분히 작으면 `stop_below` 아래로 떨어져 관성이 아예 안 붙는다). 세게 민 손짓일수록
// 이 모양이 나온다. Flutter·RN 이 창(window) 위에서 재는 이유가 이것이다.
test "Touch: 떼기 직전 작은 표본이 flick 을 죽이지 않는다" {
    // **꼬리 표본이 있고 없고가 결과를 바꾸면 안 된다.** 프레임 경계에서 이미 잰 속도가 있는데
    // 떼기 직전 1px 짜리 move 가 하나 더 오면, 그 조각으로 갈아치울 때 속도가 열 배 넘게 준다
    // (꼬리가 충분히 작으면 `stop_below` 아래로 떨어져 관성이 아예 안 붙는다). 세게 민 손짓일수록
    // 이 모양이 나온다. **내부를 읽지 않고 결과로 잰다.**
    const S = struct {
        fn flingAfter(tail: bool) f32 {
            var st: State = .{};
            var t: Touch = .{};
            _ = t.begin(1, 1000);
            t.move(&st, 1, 985, 100_000); // 한 프레임에 30px
            t.move(&st, 1, 970, 100_000);
            _ = t.step(&st, 100_000, 16); // 프레임 경계 — 여기서 1.875px/ms 로 잰다
            if (tail) t.move(&st, 1, 969, 100_000); // 떼기 직전 1px 짜리 꼬리
            t.end(1, 16);
            return t.fling;
        }
    };
    try std.testing.expect(@abs(S.flingAfter(false)) > 1.5);
    try std.testing.expectEqual(S.flingAfter(false), S.flingAfter(true));
}

// 반대쪽도 지킨다: **가만히 들고 있다 떼면 안 미끄러진다.** 위 규칙을 "큰 쪽을 남긴다" 로
// 잘못 만들면 옛 속도가 살아남아 손을 멈췄는데도 흘러간다.
test "Touch: 멈춘 채로 떼면 관성이 없다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(1, 1000);
    t.move(&st, 1, 950, 100_000);
    _ = t.step(&st, 100_000, 16);
    var f: u32 = 0;
    while (f < 10) : (f += 1) _ = t.step(&st, 100_000, 16); // 손가락은 가만히
    t.end(1, 16);
    try std.testing.expectEqual(@as(f32, 0), t.fling);
}

// ── 손가락 소유권 (계약 §3.1) ──────────────────────────────────────────────────

test "Touch: 첫 손가락이 소유하고 둘째는 화면을 안 움직인다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    _ = t.begin(9, 500); // 둘째 손가락
    try std.testing.expectEqual(@as(usize, 2), t.pointerCount());
    try std.testing.expectEqual(@as(?u32, 7), t.owner);

    t.move(&st, 9, 400, 100_000); // 비소유자가 100px 움직여도
    try std.testing.expectEqual(@as(u32, 0), st.offset_y_px); // 화면은 그대로다
    t.move(&st, 7, 950, 100_000); // 소유자는 움직인다
    try std.testing.expectEqual(@as(u32, 50), st.offset_y_px);
}

test "Touch: 비소유자가 떼도 제스처는 이어진다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    _ = t.begin(9, 500);
    t.end(9, 16); // 비소유자가 뗀다
    try std.testing.expectEqual(@as(?u32, 7), t.owner); // 소유자 그대로
    try std.testing.expectEqual(@as(f32, 0), t.fling); // 관성도 안 붙는다
    t.move(&st, 7, 950, 100_000);
    try std.testing.expectEqual(@as(u32, 50), st.offset_y_px); // 계속 끌린다
}

// **이것이 이 슬라이스의 핵심이다.** 소유자가 떼질 때 남은 손가락의 좌표가 그대로 이어지면
// 화면이 점프하고, 그 점프가 px/ms 속도에 들어가 **상한까지 튄 fling** 이 된다(교체 한 번이
// 1600px). 손가락마다 기준을 두면 새 소유자는 자기 기준을 이미 갖고 있어 **할 일이 없다.**
test "Touch: 소유자가 떼지면 남은 손가락이 점프 없이 이어받는다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    _ = t.begin(9, 300); // 700px 떨어진 자리에 둘째
    t.move(&st, 7, 990, 100_000); // 소유자가 10px
    try std.testing.expectEqual(@as(u32, 10), st.offset_y_px);

    t.end(7, 16); // 소유자가 뗀다 — 9 가 이어받는다
    try std.testing.expectEqual(@as(?u32, 9), t.owner);
    try std.testing.expectEqual(@as(f32, 0), t.fling); // 손가락이 남았으니 관성은 없다
    try std.testing.expectEqual(@as(u32, 10), st.offset_y_px); // **점프가 없다**

    t.move(&st, 9, 290, 100_000); // 새 소유자가 자기 기준(300)에서 10px
    try std.testing.expectEqual(@as(u32, 20), st.offset_y_px); // 딱 10px 만 더 간다
}

test "Touch: 마지막 손가락이 떼질 때만 관성이 붙는다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    t.move(&st, 7, 970, 100_000);
    _ = t.step(&st, 100_000, 16);
    t.end(7, 16);
    try std.testing.expect(t.fling != 0);
    try std.testing.expectEqual(@as(?u32, null), t.owner);
}

test "Touch: 모르는 id 의 move 는 무시한다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    t.move(&st, 99, 0, 100_000); // down 을 못 받은 id
    try std.testing.expectEqual(@as(u32, 0), st.offset_y_px);
    try std.testing.expectEqual(@as(usize, 1), t.pointerCount());
}

test "Touch: 취소는 id 와 무관하게 전부 끝낸다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(7, 1000);
    _ = t.begin(9, 500);
    t.move(&st, 7, 900, 100_000);
    t.cancel();
    try std.testing.expectEqual(@as(usize, 0), t.pointerCount());
    try std.testing.expectEqual(@as(?u32, null), t.owner);
    try std.testing.expectEqual(@as(f32, 0), t.fling);
}

// **슬롯을 안 비우면 재사용된 id 가 옛 손가락의 기준을 물려받는다.** host 의 id 는 `down` 부터
// 그 손가락의 `up` 까지만 같다는 것이 계약이고(Android 슬롯 id 는 실제로 재사용된다),
// Flutter 처럼 "재사용 안 하는 id" 를 우리가 만들지는 않는다.
test "Touch: 떼면 슬롯이 비어 같은 id 가 새로 시작한다" {
    var st: State = .{};
    var t: Touch = .{};
    _ = t.begin(3, 1000);
    t.move(&st, 3, 900, 100_000); // 100px
    t.end(3, 16);
    const after_first = st.offset_y_px;

    _ = t.begin(3, 200); // 같은 id 가 전혀 다른 자리에서 다시 닿는다
    t.move(&st, 3, 190, 100_000); // 10px 만 움직였다
    try std.testing.expectEqual(after_first + 10, st.offset_y_px); // 옛 기준(900)을 안 물려받는다
}

// **상한을 두면 늘 그 언저리가 샌다.** 자리가 없어 등록 못 한 손가락이 소유자가 되면, 그
// 손가락의 `up` 이 슬롯을 못 찾아 **소유권이 영영 안 풀린다** — 그 표면이 굳는다.
test "Touch: 슬롯이 꽉 차도 소유권이 굳지 않는다" {
    var t: Touch = .{};
    var i: u32 = 0;
    while (i < Touch.max_pointers + 2) : (i += 1) _ = t.begin(i, 1000);
    try std.testing.expectEqual(Touch.max_pointers, t.pointerCount()); // 넘치는 것은 무시
    try std.testing.expectEqual(@as(?u32, 0), t.owner); // 첫 손가락이 소유자다

    i = 0;
    while (i < Touch.max_pointers + 2) : (i += 1) t.end(i, 16);
    try std.testing.expectEqual(@as(usize, 0), t.pointerCount());
    try std.testing.expectEqual(@as(?u32, null), t.owner); // **풀린다**
}
