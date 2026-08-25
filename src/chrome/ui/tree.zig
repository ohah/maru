//! 중첩 native chrome component tree를 ML1 flex solver의 한 sibling line으로 내리는 순수 seam이다.
//!
//! 이 모듈은 TUI cell/ANSI, Metal draw, `ChromeHost` effect dispatch를 읽지 않는다. caller가 준
//! backing-pixel root size와 bounded frame buffers만 써서 `UiNode`를 flat `UiRectTree`로 만든다.
//! draw/hit/focus/virtualization은 이 tree를 공유해야 하며, caller는 성공한 tree만 publish한다.
//! 단일 출처: docs/metal-ui-layout.md §2 ML2a(tree 경계), docs/metal-ui-layout-paint.md §5(Metal
//! paint·입력 정합), docs/plans/metal-ui-layout.md §8(구현 순서).

const std = @import("std");
const layout = @import("layout.zig");
const ui_style = @import("style.zig");
const scroll_area = @import("scroll_area.zig");
const ui_semantics = @import("semantics.zig");

/// 접근성 서술자 — 계약은 `ui/semantics.zig` 가 소유한다(CIM §3).
pub const Semantics = ui_semantics.Semantics;
pub const SemanticRole = ui_semantics.Role;

pub const UiId = u64;
pub const UiActionId = u64;

pub const UiAction = struct {
    id: UiActionId,
    enabled: bool = true,
};

pub const CardVariant = ui_style.CardVariant;
pub const CursorHint = ui_style.CursorHint;
pub const ButtonVariant = ui_style.ButtonVariant;
pub const TextTone = ui_style.TextTone;
pub const ShadowKind = ui_style.ShadowKind;
pub const PaintStyle = ui_style.PaintStyle;
pub const CardVisual = ui_style.CardVisual;
pub const TextVisual = ui_style.TextVisual;
pub const VisualProps = ui_style.VisualProps;

pub const ContainerOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    /// `Container`는 제품 component가 아니라 내부 flex solver의 구조 노드다. Column/Row라는
    /// 별도 공개 component를 만들지 않고 방향을 이 한 값으로 제한해, layout API가
    /// shadcn식 의미 component(`Card`/`Text`)와 섞이지 않게 한다.
    direction: layout.Direction = .column,
    justify: layout.Justify = .start,
    align_items: layout.Align = .stretch,
    overflow: layout.Overflow = .visible,
};

pub const CardOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    variant: CardVariant = .surface,
    paint: PaintStyle = .{},
    action: ?UiAction = null,
    /// 이 면 위의 커서 모양. 기본 `auto`는 "할 말이 없다"이고, 그때는 host의 상위 규칙이 정한다.
    cursor: CursorHint = .auto,
    direction: layout.Direction = .column,
    justify: layout.Justify = .start,
    align_items: layout.Align = .stretch,
    /// 이 면의 접근성 서술자(CIM §3 — `ui/semantics.zig`). 안 주면 이 node 는 접근성에 아무 말도
    /// 하지 않는다.
    semantics: ?Semantics = null,
    overflow: layout.Overflow = .visible,
};

pub const TextOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    value: []const u8,
    tone: TextTone = .primary,
    paint: PaintStyle = .{},
    measure_context: ?*const anyopaque = null,
    measure: ?layout.MeasureFn = null,
};

/// Button은 상호작용 Card의 별칭이 아니라 명시적 command 대상이다. 텍스트나 provider payload를
/// 의도적으로 싣지 않는다 — 불변 label은 component view가 따로 내고, 이 node는 paint와 input이 함께
/// 쓰는 단 하나의 published border-box/action capability다.
/// Button이 선언하는 아이콘 슬롯. 정의는 `ui/style.zig`가 소유한다 — published visual props와
/// node props가 같은 타입을 써야 둘이 갈리지 않는다. 등록 판정은 `ui/button.zig`가 주입받은
/// predicate로 후보 단계에서 한다(chrome은 renderer를 import할 수 없다).
pub const LeadingIconProps = ui_style.LeadingIcon;

pub const ButtonOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    variant: ButtonVariant = .secondary,
    paint: PaintStyle = .{},
    action: UiAction,
    overflow: layout.Overflow = .visible,
    /// 이 면 위의 커서 모양. 기본 `auto`는 "할 말이 없다"이고, 그때는 host의 상위 규칙이 정한다.
    cursor: CursorHint = .auto,
    /// 이 면의 접근성 서술자(CIM §3 — `ui/semantics.zig`). 안 주면 이 node 는 접근성에 아무 말도
    /// 하지 않는다.
    semantics: ?Semantics = null,
    leading_icon: ?LeadingIconProps = null,
};

/// 스크롤바 한 조각(track 또는 thumb)이 발행될 때 실릴 것들. tree는 색·의미를 모르므로 소비처가
/// 준 값을 그대로 옮긴다.
pub const ScrollbarPart = struct {
    id: UiId,
    action: UiAction,
    paint: PaintStyle,
};

/// 스크롤해도 컨테이너 상단에 남는 노드(§4.7). **무엇이** sticky인지는 소비처가 정하고, 여기서는 그
/// 위치를 clamp하기만 한다 — 가상화 때문에 그 헤더는 창 밖일 수 있고, 창 밖 항목이 어느 그룹인지는
/// domain만 안다.
pub const StickyDeclaration = struct {
    id: UiId,
    action: ?UiAction = null,
    paint: PaintStyle = .{},
    height_px: f32,
    /// content-space top(스크롤 offset을 빼기 전). 소비처가 자기 좌표계에서 계산해 준다.
    top_px: f32,
    /// **다음** sticky 후보의 content-space top. 그것이 올라오면 이 헤더를 밀어낸다. 마지막이면
    /// 기본값(무한대)이라 밀어내는 것이 없다.
    next_top_px: f32 = std.math.floatMax(f32),
};

/// `scrollArea` 선언에 실리는 스크롤 상태. 이 값들이 있어야 `build`가 가상화 평행이동과 track/thumb
/// 발행을 **소비처 대신** 할 수 있다(docs/scroll-area.md §4.1).
pub const ScrollDeclaration = struct {
    /// 지금 스크롤 위치. 스크롤바 thumb의 자리를 정한다.
    offset_px: u32 = 0,
    /// 가상화 때문에 자식은 보이는 창뿐이므로, 전체가 얼마나 긴지는 이 값으로만 알 수 있다.
    content_h_px: u32 = 0,
    /// 창의 첫 자식이 시작하는 local y(0이거나 음수). 자식 subtree 전체가 이만큼 평행이동한다.
    first_item_origin_y_px: i32 = 0,
    /// 컨테이너 오른쪽에 확보된 여백. 스크롤바는 **그 안에** 놓여 목록 위에 겹치지 않는다.
    gutter_px: f32 = 0,
    metrics: scroll_area.ScrollbarMetrics = .{ .width_px = 0, .inset_x_px = 0, .min_thumb_px = 0 },
    /// 둘 다 있어야 스크롤바를 발행한다. 없으면 가상화 평행이동만 한다.
    track: ?ScrollbarPart = null,
    thumb: ?ScrollbarPart = null,
    /// track/thumb이 함께 선언하는 drag payload. tree는 이 값의 의미를 모른다.
    drag: ?DragDeclaration = null,
    /// 상단에 고정할 노드(§4.7). 자식 슬롯이 아닌 이유는 `build`가 자식을 전부 평행이동하기 때문이다 —
    /// 자식으로 선언하면 목록과 함께 흘러내린다.
    sticky: ?StickyDeclaration = null,
};

pub const ScrollAreaOptions = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    direction: layout.Direction = .column,
    justify: layout.Justify = .start,
    align_items: layout.Align = .stretch,
    scroll: ScrollDeclaration = .{},
};

pub const NodeProps = union(enum) {
    container: struct {
        direction: layout.Direction,
        justify: layout.Justify,
        align_items: layout.Align,
        overflow: layout.Overflow,
    },
    card: struct {
        variant: CardVariant,
        paint: PaintStyle,
        action: ?UiAction,
        /// 이 면 위의 커서 모양(component가 선언한다 — `ui_style.CursorHint`).
        cursor: CursorHint = .auto,
        /// Component가 선언한 drag 능력. 없으면 이 node는 click 전용이다. 의미(payload가 무엇을 옮기는지)는
        /// host의 intent table만 알고, tree와 interaction은 opaque ID로만 다룬다.
        drag: ?DragDeclaration = null,
        direction: layout.Direction,
        justify: layout.Justify,
        align_items: layout.Align,
        overflow: layout.Overflow,
    },
    button: struct {
        variant: ButtonVariant,
        paint: PaintStyle,
        action: UiAction,
        overflow: layout.Overflow,
        /// 이 면 위의 커서 모양(component가 선언한다 — `ui_style.CursorHint`).
        cursor: CursorHint = .auto,
        /// 선언된 leading icon 슬롯. paint/lowering이 final placement를 만들 때 필요하므로 style이
        /// 아니라 props에 실린다. 치수는 `ui/button.zig`가 `ButtonSize`와 token에서 한 번 계산한다.
        leading_icon: ?LeadingIconProps = null,
    },
    text: struct {
        value: []const u8,
        tone: TextTone,
        paint: PaintStyle,
        measure_context: ?*const anyopaque,
        measure: ?layout.MeasureFn,
    },
    /// 스크롤 컨테이너. `container`와 같은 flex 자식 배치를 하되 `overflow`가 **항상** clip이고,
    /// 자식 subtree를 가상화 origin만큼 평행이동하며, 자식들 직후에 스크롤바 entry를 낸다.
    scroll_area: struct {
        direction: layout.Direction,
        justify: layout.Justify,
        align_items: layout.Align,
        scroll: ScrollDeclaration,
    },
};

pub const NodeKind = enum { container, card, button, text, scroll_area };

/// children slice의 수명과 순서는 builder caller가 소유한다. node address나 형제 index는
/// identity가 아니며, 한 build 안에 같은 `id`가 있으면 `DuplicateIdentity`로 끝난다.
pub const UiNode = struct {
    id: UiId,
    style: layout.UiStyle = .{},
    props: NodeProps,
    children: []const UiNode = &.{},
    /// 이 node 의 접근성 서술자(CIM §3). **interactive node 는 이것을 낸다** — `action` 만으로는
    /// 역할·이름·상태를 말할 수 없다. `null` 은 "아직 안 낸다"이고, 그런 consumer 는 접근성 이관을
    /// 완료라고 표시할 수 없다. 계약은 `ui/semantics.zig` 가 소유한다.
    semantics: ?Semantics = null,

    pub fn kind(self: UiNode) NodeKind {
        return switch (self.props) {
            .container => .container,
            .card => .card,
            .button => .button,
            .text => .text,
            .scroll_area => .scroll_area,
        };
    }
};

/// 내부 layout node다. 도메인 component가 semantic 자식을 이걸로 감싸며, 사용자에게 보이는 Chrome
/// 디자인 시스템 컴포넌트가 아니다.
pub fn container(options: ContainerOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .container = .{
            .direction = options.direction,
            .justify = options.justify,
            .align_items = options.align_items,
            .overflow = options.overflow,
        } },
        .children = children,
    };
}

/// 스크롤 컨테이너 선언. 소비처는 이것 하나만 부르고, 평행이동·clip·track/thumb 발행은 `build`가
/// 한다(docs/scroll-area.md §4.1). `overflow`를 받지 않는 것은 의도다 — 스크롤 컨테이너가 자기 자식을
/// 안 자르면 목록이 고정 chrome 위로 새어 나간다.
pub fn scrollArea(options: ScrollAreaOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .scroll_area = .{
            .direction = options.direction,
            .justify = options.justify,
            .align_items = options.align_items,
            .scroll = options.scroll,
        } },
        .children = children,
    };
}

pub fn card(options: CardOptions, children: []const UiNode) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .card = .{
            .variant = options.variant,
            .paint = options.paint,
            .action = options.action,
            .cursor = options.cursor,
            .direction = options.direction,
            .justify = options.justify,
            .align_items = options.align_items,
            .overflow = options.overflow,
        } },
        .children = children,
        .semantics = options.semantics,
    };
}

pub fn text(options: TextOptions) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .text = .{
            .value = options.value,
            .tone = options.tone,
            .paint = options.paint,
            .measure_context = options.measure_context,
            .measure = options.measure,
        } },
    };
}

pub fn button(options: ButtonOptions) UiNode {
    return .{
        .id = options.id,
        .style = options.style,
        .props = .{ .button = .{
            .variant = options.variant,
            .paint = options.paint,
            .action = options.action,
            .cursor = options.cursor,
            .overflow = options.overflow,
            .leading_icon = options.leading_icon,
        } },
        .semantics = options.semantics,
    };
}

/// label을 자식으로 갖는 Button. 호출자는 `ui/button.zig`의 builder를 쓰고, 이 함수는 그 builder가
/// 검증을 마친 뒤 node를 조립하는 자리다 — 자식 개수/종류 계약은 그쪽이 소유한다.
///
/// `children`은 **호출자가 소유한 버퍼의 슬라이스**여야 한다. 값으로 받은 node의 주소를 실으면
/// 반환 즉시 dangling이 된다(스택 슬롯이 사라진다). 다른 `UiNode` builder들과 같은 규율이다.
pub fn buttonWithLabel(options: ButtonOptions, children: []const UiNode) UiNode {
    var node = button(options);
    node.children = children;
    return node;
}

pub const DragAxis = enum { horizontal, vertical, free };

/// Component가 선언하는 drag 능력. `ui/interaction.zig`가 같은 타입을 소비한다.
pub const DragDeclaration = struct {
    payload: u64,
    axis: DragAxis = .free,
    threshold_px: f32 = 3,
};

pub const RectEntry = struct {
    id: UiId,
    parent_index: ?usize,
    kind: NodeKind,
    rect: layout.UiRect,
    /// Parent overflow clip과 own overflow clip을 교차한 backing-pixel rect다. null은
    /// 이 entry와 모든 visible ancestor가 clip하지 않는다는 뜻이다.
    effective_clip: ?layout.UiRect,
    /// 이 entry **자신의** overflow clip(padding box, absolute)이다. `overflow == .clip`이
    /// 아니면 null이다. `effective_clip`은 ancestor 정보까지 접힌 값이라, 완성된 tree를 나중에
    /// 평행이동하는 virtualization이 clip을 정확히 다시 접으려면 이 원본이 필요하다.
    own_clip: ?layout.UiRect = null,
    action: ?UiAction,
    /// Component가 선언한 drag 능력. 없으면 이 node는 click 전용이다. payload가 무엇을 옮기는지는
    /// host의 intent table만 알고, tree와 interaction은 opaque ID로만 다룬다.
    drag: ?DragDeclaration = null,
    /// 이 면 위의 커서 모양. **published tree가 그 사실의 단일 출처다** — host가 "누를 수 있나"를
    /// 다시 추론하면 판정의 주인이 둘이 된다.
    cursor: CursorHint = .auto,
    /// 이것은 불변 semantic props의 정확한 투영이지 두 번째 스타일 출처가 아니다. `ui_paint`가 이
    /// 평탄화된 snapshot을 interaction이 쓰는 같은 rect/action과 함께 소비하므로, 뒤따르는 host/Metal
    /// 단계가 도메인 state에서 variant를 다시 찾아낼 수 없다.
    visual: VisualProps = .none,
    /// 이 면의 접근성 서술자(CIM §3). `cursor` 와 같은 이유로 여기 있다 — **발행된 스냅숏이 그 사실의
    /// 단일 출처**여야 host 가 도메인 state 에서 역할·이름을 다시 추론하지 않는다. 그 추론은 화면과
    /// 조용히 갈린다.
    ///
    /// 문자열은 빌려온 것이고 생명은 이 tree 와 같다(`ui/semantics.zig`).
    semantics: ?Semantics = null,
};

/// entries는 preorder라 parent는 항상 child보다 먼저 나온다. direct child 탐색에는
/// `parent_index`를 쓰며, subtree 전체는 다음 sibling parent boundary까지의 range다.
pub const UiRectTree = struct {
    entries: []const RectEntry,
    /// 이 스냅샷의 published 세대. pointer 이벤트가 자기가 겨냥한 세대를 함께 실어 오므로, 이전
    /// tree를 보고 누른 up이 새 tree의 action을 실행하는 것을 dispatch가 거부할 수 있다.
    /// 기본 0은 "세대를 쓰지 않는 소비자"이며 그 경우 검사가 비활성이다.
    generation: u64 = 0,

    pub fn find(self: UiRectTree, id: UiId) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }
};

pub const BuildOptions = struct {
    root_size: layout.UiSize,
    /// root를 포함한다. zero는 invalid이며 partial publish를 허용하지 않는다.
    max_entries: usize,
    /// root depth=1 기준이다. zero는 invalid이다.
    max_depth: usize,
};

/// 모든 슬라이스는 caller frame arena가 소유하는 *candidate* tree다. 이전 completed tree를
/// 유지하려면 published snapshot과 이 버퍼를 공유하지 않는다. 세 scratch 슬라이스는
/// `max_entries` 이상이어야 한다. `items`/`flex_scratch`는 child flex 계산이 끝나면
/// level마다 재사용하고, `child_rects`만은 활성 조상 sibling을 보존하도록 stack range로
/// 예약한다. 이 방식은 tree build가 heap allocation이나 component-local rect cache를 만들지
/// 못하게 한다.
pub const BuildBuffers = struct {
    entries: []RectEntry,
    items: []layout.Item,
    flex_scratch: []layout.FlexScratch,
    child_rects: []layout.UiRect,
};

pub const BuildError = layout.LayoutError || error{
    InvalidLimit,
    InsufficientBuffer,
    MaxEntriesExceeded,
    MaxDepthExceeded,
    DuplicateIdentity,
    LeafHasChildren,
    RootOuterStyle,
    RebuildCounterOverflow,
};

/// `ChromeHost`가 props/style/size dirty일 때만 호출하는 completed-build 계수다. 실패한
/// build는 tree publish와 이 counter 둘 다 바꾸지 않는다.
pub const RebuildCounter = struct {
    completed: u64 = 0,

    pub fn rebuild(self: *RebuildCounter, root: UiNode, options: BuildOptions, buffers: BuildBuffers) BuildError!UiRectTree {
        if (self.completed == std.math.maxInt(u64)) {
            clearEntries(buffers.entries);
            return error.RebuildCounterOverflow;
        }
        const tree = try build(root, options, buffers);
        self.completed += 1;
        return tree;
    }
};

/// 성공했을 때만 caller가 반환 tree를 publish한다. 실패 시 new-frame entries를 모두
/// zero로 지워 stale rect/action을 실수로 재사용하지 않게 한다.
pub fn build(root: UiNode, options: BuildOptions, buffers: BuildBuffers) BuildError!UiRectTree {
    clearEntries(buffers.entries);
    try validateBuildInputs(options, buffers);

    var state = BuildState{ .options = options, .buffers = buffers };
    errdefer clearEntries(buffers.entries);
    try state.appendSubtree(root, null, .{
        .x = 0,
        .y = 0,
        .width = options.root_size.width,
        .height = options.root_size.height,
    }, null, 1, 0);
    return .{ .entries = buffers.entries[0..state.entry_count] };
}

const BuildState = struct {
    options: BuildOptions,
    buffers: BuildBuffers,
    entry_count: usize = 0,

    fn appendSubtree(
        self: *BuildState,
        node: UiNode,
        parent_index: ?usize,
        rect: layout.UiRect,
        parent_clip: ?layout.UiRect,
        depth: usize,
        rect_stack_start: usize,
    ) BuildError!void {
        if (depth > self.options.max_depth) return error.MaxDepthExceeded;
        if (self.entry_count == self.options.max_entries) return error.MaxEntriesExceeded;
        if (hasIdentity(self.buffers.entries[0..self.entry_count], node.id)) return error.DuplicateIdentity;
        if (node.kind() == .text and node.children.len != 0) return error.LeafHasChildren;
        if (parent_index == null) try validateRootOuterStyle(node.style);
        if (node.children.len > self.options.max_entries - self.entry_count - 1) return error.MaxEntriesExceeded;

        const flex_container = try containerFor(node, rect);
        const child_count = node.children.len;
        const child_items = self.buffers.items[0..child_count];
        const child_scratch = self.buffers.flex_scratch[0..child_count];
        if (rect_stack_start > self.buffers.child_rects.len or
            child_count > self.buffers.child_rects.len - rect_stack_start) return error.MaxEntriesExceeded;
        const child_rects = self.buffers.child_rects[rect_stack_start..][0..child_count];
        for (node.children, child_items) |child, *item| item.* = itemFor(child);
        const result = try layout.layoutFlex(flex_container, child_items, child_scratch, child_rects);

        const own_clip = if (result.clip_rect) |content_rect| blk: {
            var clip = try offsetRect(content_rect, rect.x, rect.y);
            // `layoutFlex`의 clip은 padding을 **제외한** content box다(CSS의 padding box와 다르다).
            // 스크롤바는 방금 예약한 gutter에 놓이므로 그 폭을 clip에 돌려준다 — CSS에서 스크롤바가
            // padding box 안이라 자기 컨테이너에 잘리지 않는 것과 같은 자리를 여기서 만든다.
            // 이 한 줄 덕분에 스크롤바에 **clip 예외가 없다**: 자기 컨테이너의 clip을 그대로 받고,
            // 중첩에서는 바깥 뷰포트에 정확히 잘린다.
            if (node.props == .scroll_area) clip.width += node.props.scroll_area.scroll.gutter_px;
            break :blk clip;
        } else null;
        const effective_clip = try intersectClip(parent_clip, own_clip);
        const own_index = self.entry_count;
        self.buffers.entries[own_index] = .{
            .id = node.id,
            .parent_index = parent_index,
            .kind = node.kind(),
            .rect = rect,
            .effective_clip = effective_clip,
            .own_clip = own_clip,
            .action = actionFor(node),
            .cursor = cursorFor(node),
            .visual = visualFor(node),
            .semantics = node.semantics,
        };
        self.entry_count += 1;

        // 가상화 평행이동은 **자식 rect를 만들 때** 적용한다. 사후에 완성된 entry를 옮기면 그때마다
        // clip을 손으로 다시 접어야 하는데(도크가 그렇게 하고 있었다), 여기서 더하면 자식의 own_clip이
        // 옮겨진 rect에서 나오고 `effective_clip`도 그 자리에서 정확히 접힌다.
        const child_origin_y = rect.y + switch (node.props) {
            .scroll_area => |value| @as(f32, @floatFromInt(value.scroll.first_item_origin_y_px)),
            else => 0,
        };
        for (node.children, child_rects) |child, child_rect| {
            try self.appendSubtree(child, own_index, try offsetRect(child_rect, rect.x, child_origin_y), effective_clip, depth + 1, rect_stack_start + child_count);
        }

        // sticky 헤더는 자식들보다 뒤(위)이고 스크롤바보다 앞(아래)이다(§4.7). z는 emit 순서이고
        // `hitAction`은 reverse z라, 카드는 헤더 밑으로 지나가고 gutter 클릭은 헤더로 새지 않는다.
        if (node.props == .scroll_area) try self.appendSticky(
            node.props.scroll_area.scroll,
            own_index,
            try offsetRect(result.content_rect, rect.x, rect.y),
            effective_clip,
        );

        // 스크롤바는 **자식들을 낸 뒤, 부모로 돌아가기 전**에 낸다(§4). 배열 끝에 붙이면 preorder와
        // subtree-range 불변식이 깨지고 root가 여럿이 된다. 여기서 내면 `parent_index`가 이 컨테이너라
        // 두 불변식이 유지되고 z도 저절로 맞는다 — 자식들보다 뒤(위)이고 다음 sibling보다 앞(아래)이다.
        if (node.props == .scroll_area) try self.appendScrollbar(
            node.props.scroll_area.scroll,
            own_index,
            // 스크롤바 기하의 기준은 **자식이 놓인 영역**이다(gutter 제외). 그 오른쪽이 gutter다.
            try offsetRect(result.content_rect, rect.x, rect.y),
            effective_clip,
        );
    }

    /// sticky entry. 세 상태가 clamp 한 줄에서 나온다(§4.7) — 헤더 앞이면 흐름 그대로, 지나쳤으면
    /// 상단 고정, 다음 헤더가 올라오면 밀려 나간다. 높이는 스크롤 좌표계에서 그대로 자리를 차지하고
    /// 여기서는 **그리는 y만** 옮기므로 `project`의 창 계산과 anchor 규칙이 바뀌지 않는다.
    fn appendSticky(
        self: *BuildState,
        scroll: ScrollDeclaration,
        container_index: usize,
        content_rect: layout.UiRect,
        container_clip: ?layout.UiRect,
    ) BuildError!void {
        const head = scroll.sticky orelse return;
        if (self.entry_count == self.options.max_entries) return error.MaxEntriesExceeded;

        const offset: f32 = @floatFromInt(scroll.offset_px);
        const natural_y = head.top_px - offset;
        const next_y = head.next_top_px - offset;
        const local_y = @min(@max(natural_y, 0), next_y - head.height_px);

        const rect: layout.UiRect = .{
            .x = content_rect.x,
            .y = content_rect.y + local_y,
            .width = content_rect.width,
            .height = head.height_px,
        };
        // 헤더는 흐름 위의 그룹 행과 같은 규율을 따른다(`overflow = .clip`) — 밀려 나가는 동안 컨테이너
        // clip이 위를 자르고, 자기 rect가 아래를 자른다. 그래야 소비처가 `clipRectOf`로 같은 값을 얻는다.
        const clip = if (container_clip) |outer| layout.intersectRect(rect, outer) else rect;

        self.buffers.entries[self.entry_count] = .{
            .id = head.id,
            .parent_index = container_index,
            .kind = .card,
            .rect = rect,
            .effective_clip = clip,
            .own_clip = clip,
            .action = head.action,
            .drag = null,
            .visual = .{ .card = .{ .variant = .surface, .paint = head.paint } },
        };
        self.entry_count += 1;
    }

    /// track/thumb entry. `content_rect`는 자식이 놓인 영역이고 그 오른쪽 `gutter_px`가 스크롤바
    /// 자리다. clip은 이 컨테이너의 `effective_clip`이며 위에서 gutter를 되돌려 놓았으므로 스크롤바가
    /// 그 안에 있다 — CSS에서 스크롤바가 padding box 안이라 자기 컨테이너에 안 잘리는 것과 같다(§4).
    fn appendScrollbar(
        self: *BuildState,
        scroll: ScrollDeclaration,
        container_index: usize,
        content_rect: layout.UiRect,
        container_clip: ?layout.UiRect,
    ) BuildError!void {
        const track_part = scroll.track orelse return;
        const thumb_part = scroll.thumb orelse return;
        const bar = scroll_area.scrollbarGeometry(.{
            .x = content_rect.x,
            .y = content_rect.y,
            .w = content_rect.width,
            .h = content_rect.height,
            .gutter_w = scroll.gutter_px,
        }, scroll.content_h_px, scroll.offset_px, scroll.metrics) orelse return;

        if (self.entry_count + 2 > self.options.max_entries) return error.MaxEntriesExceeded;
        // track이 먼저, thumb이 나중이다 — `hitAction`이 reverse z-order라 마지막 entry가 이기고,
        // 순서가 뒤집히면 thumb 위 down이 track click으로 판정돼 드래그 대신 점프가 일어난다.
        self.appendScrollbarPart(track_part, container_index, container_clip, scroll.drag, .{
            .x = bar.track_x,
            .y = bar.track_y,
            .width = bar.track_w,
            .height = bar.track_h,
        });
        self.appendScrollbarPart(thumb_part, container_index, container_clip, scroll.drag, .{
            .x = bar.track_x,
            .y = bar.thumb_y,
            .width = bar.track_w,
            .height = bar.thumb_h,
        });
    }

    fn appendScrollbarPart(
        self: *BuildState,
        part: ScrollbarPart,
        container_index: usize,
        clip: ?layout.UiRect,
        drag: ?DragDeclaration,
        rect: layout.UiRect,
    ) void {
        self.buffers.entries[self.entry_count] = .{
            .id = part.id,
            .parent_index = container_index,
            .kind = .card,
            .rect = rect,
            .effective_clip = clip,
            .own_clip = null,
            .action = part.action,
            .drag = drag,
            .visual = .{ .card = .{ .variant = .surface, .paint = part.paint } },
        };
        self.entry_count += 1;
    }
};

fn validateBuildInputs(options: BuildOptions, buffers: BuildBuffers) BuildError!void {
    if (options.max_entries == 0 or options.max_depth == 0) return error.InvalidLimit;
    if (buffers.entries.len < options.max_entries or
        buffers.items.len < options.max_entries or
        buffers.flex_scratch.len < options.max_entries or
        buffers.child_rects.len < options.max_entries) return error.InsufficientBuffer;
    if (!std.math.isFinite(options.root_size.width) or !std.math.isFinite(options.root_size.height) or
        options.root_size.width < 0 or options.root_size.height < 0) return error.InvalidNumber;
}

fn validateRootOuterStyle(style: layout.UiStyle) BuildError!void {
    if (!isAuto(style.width) or !isAuto(style.height) or
        style.min_width != null or style.max_width != null or
        style.min_height != null or style.max_height != null or
        style.margin.top != 0 or style.margin.right != 0 or
        style.margin.bottom != 0 or style.margin.left != 0 or
        style.flex.grow != 0 or style.flex.shrink != 1 or style.flex.basis != null or
        style.align_self != null) return error.RootOuterStyle;
}

fn isAuto(length: layout.UiLength) bool {
    return switch (length) {
        .auto => true,
        else => false,
    };
}

/// 스크롤 컨테이너의 오른쪽 padding에 gutter를 더한 style. 원본을 바꾸지 않고 복사해 돌려준다.
fn gutterInset(style: layout.UiStyle, gutter_px: f32) layout.UiStyle {
    if (!(gutter_px > 0)) return style;
    var inset = style;
    inset.padding.right += gutter_px;
    return inset;
}

fn containerFor(node: UiNode, rect: layout.UiRect) BuildError!layout.FlexContainer {
    const flex_container: layout.FlexContainer = switch (node.props) {
        .container => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = value.direction,
            .justify = value.justify,
            .align_items = value.align_items,
            .overflow = value.overflow,
        },
        .scroll_area => |value| .{
            // gutter는 padding과 같은 층이다 — 자식이 놓일 영역을 그만큼 안쪽으로 민다
            // (CSS `scrollbar-gutter`, taffy `content_box_inset.right += scrollbar_gutter`).
            // **컨테이너가 자기 폭에서** 떼어 놓으므로 조상에 padding이 있든 없든 같게 동작한다.
            .style = gutterInset(node.style, value.scroll.gutter_px),
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = value.direction,
            .justify = value.justify,
            .align_items = value.align_items,
            // 스크롤 컨테이너는 언제나 자른다. 선택지로 두면 소비처가 잊는 날 목록이 고정 chrome
            // 위로 새어 나간다.
            .overflow = .clip,
        },
        .card => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = value.direction,
            .justify = value.justify,
            .align_items = value.align_items,
            .overflow = value.overflow,
        },
        .button => |value| .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = .column,
            .overflow = value.overflow,
        },
        .text => .{
            .style = node.style,
            .size = .{ .width = rect.width, .height = rect.height },
            .direction = .column,
        },
    };
    try layout.validateItemStyle(node.style, flex_container.direction);
    return flex_container;
}

fn itemFor(node: UiNode) layout.Item {
    return switch (node.props) {
        .text => |value| .{
            .style = node.style,
            .measure_context = value.measure_context,
            .measure = value.measure,
        },
        else => .{ .style = node.style },
    };
}

fn actionFor(node: UiNode) ?UiAction {
    return switch (node.props) {
        .card => |value| value.action,
        .button => |value| value.action,
        else => null,
    };
}

/// 이 노드가 선언한 커서. 구조 노드(container·scroll_area)와 글자는 할 말이 없다.
fn cursorFor(node: UiNode) CursorHint {
    return switch (node.props) {
        .card => |value| value.cursor,
        .button => |value| value.cursor,
        .container, .scroll_area, .text => .auto,
    };
}

fn visualFor(node: UiNode) VisualProps {
    return switch (node.props) {
        .container, .scroll_area => .none,
        .card => |value| .{ .card = .{ .variant = value.variant, .paint = value.paint } },
        // `leading_icon`도 함께 실어야 한다. 빠뜨리면 builder가 검증·계산한 슬롯이 published entry에
        // 도달하지 못해, paint/lowering이 placement를 만들 길이 없다(화면에 영원히 안 나온다).
        .button => |value| .{ .button = .{ .variant = value.variant, .paint = value.paint, .leading_icon = value.leading_icon } },
        .text => |value| .{ .text = .{ .tone = value.tone, .paint = value.paint } },
    };
}

fn hasIdentity(entries: []const RectEntry, id: UiId) bool {
    for (entries) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

fn offsetRect(rect: layout.UiRect, x: f32, y: f32) BuildError!layout.UiRect {
    const result: layout.UiRect = .{
        .x = x + rect.x,
        .y = y + rect.y,
        .width = rect.width,
        .height = rect.height,
    };
    try validateRect(result);
    return result;
}

fn intersectClip(parent: ?layout.UiRect, own: ?layout.UiRect) BuildError!?layout.UiRect {
    if (parent == null) return own;
    if (own == null) return parent;
    const result = layout.intersectRect(parent.?, own.?);
    if (!std.math.isFinite(result.x) or !std.math.isFinite(result.y) or
        !std.math.isFinite(result.width) or !std.math.isFinite(result.height)) return error.InvalidNumber;
    return result;
}

fn validateRect(rect: layout.UiRect) BuildError!void {
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or
        !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidNumber;
    if (rect.width < 0 or rect.height < 0) return error.NegativeValue;
}

fn clearEntries(entries: []RectEntry) void {
    for (entries) |*entry| entry.* = emptyRectEntry();
}

fn emptyRectEntry() RectEntry {
    return .{
        .id = 0,
        .parent_index = null,
        .kind = .container,
        .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .effective_clip = null,
        .own_clip = null,
        .action = null,
        .visual = .none,
    };
}

fn measuredText(_: ?*const anyopaque, _: layout.MeasureConstraint) layout.UiSize {
    return .{ .width = 20, .height = 10 };
}

test "nested UiNode produces one preorder rect tree for cards and text" {
    const root = container(.{ .id = 1, .style = .{ .padding = .{ .top = 4, .left = 3 }, .gap = 2 }, .overflow = .clip }, &.{
        card(.{ .id = 2, .style = .{ .height = .{ .px = 24 }, .padding = .{ .left = 2 } }, .action = .{ .id = 90 } }, &.{
            text(.{ .id = 3, .value = "adsf", .measure = measuredText }),
        }),
        text(.{ .id = 4, .value = "tail", .measure = measuredText }),
    });
    var entries: [4]RectEntry = undefined;
    var items: [4]layout.Item = undefined;
    var scratch: [4]layout.FlexScratch = undefined;
    var child_rects: [4]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 100, .height = 80 }, .max_entries = 4, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectEqual(@as(usize, 4), tree.entries.len);
    try std.testing.expectEqual(@as(?usize, null), tree.entries[0].parent_index);
    try std.testing.expectEqual(@as(?usize, 0), tree.entries[1].parent_index);
    try std.testing.expectEqual(@as(?usize, 1), tree.entries[2].parent_index);
    try std.testing.expectEqual(@as(?usize, 0), tree.entries[3].parent_index);
    try std.testing.expectEqual(NodeKind.card, tree.entries[1].kind);
    try std.testing.expectEqual(@as(?UiAction, .{ .id = 90, .enabled = true }), tree.entries[1].action);
    try std.testing.expectApproxEqAbs(@as(f32, 3), tree.entries[1].rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), tree.entries[1].rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 24), tree.entries[1].rect.height, 0.001);
    try std.testing.expect(tree.entries[2].effective_clip != null);
    try std.testing.expectEqual(@as(?usize, 2), tree.find(3));
}

test "Button projects its explicit action and visual independently from Card" {
    const root = container(.{ .id = 1 }, &.{button(.{
        .id = 2,
        .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 28 } },
        .variant = .primary,
        .action = .{ .id = 42 },
        .overflow = .clip,
    })});
    var entries: [2]RectEntry = undefined;
    var items: [2]layout.Item = undefined;
    var flex_scratch: [2]layout.FlexScratch = undefined;
    var child_rects: [2]layout.UiRect = undefined;
    const built = try build(root, .{ .root_size = .{ .width = 100, .height = 40 }, .max_entries = 2, .max_depth = 2 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
    });
    const entry = built.entries[built.find(2).?];
    try std.testing.expectEqual(NodeKind.button, entry.kind);
    try std.testing.expectEqual(@as(?UiAction, .{ .id = 42 }), entry.action);
    try std.testing.expectEqual(VisualProps{ .button = .{ .variant = .primary, .paint = .{} } }, entry.visual);
}

test "semantic paint props project once into the completed rect snapshot" {
    const root = container(.{ .id = 1 }, &.{
        card(.{ .id = 2, .variant = .raised, .paint = .{ .background = .accent_bar, .corner_radii_px = .{ 1, 2, 3, 4 }, .shadow = .none } }, &.{
            text(.{ .id = 3, .value = "title", .tone = .muted, .paint = .{ .foreground = .accent_bar } }),
        }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 80, .height = 40 }, .max_entries = 3, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expect(tree.entries[1].visual == .card);
    try std.testing.expectEqual(CardVariant.raised, tree.entries[1].visual.card.variant);
    try std.testing.expectEqual(.accent_bar, tree.entries[1].visual.card.paint.background.?);
    try std.testing.expectEqual(@as(?ShadowKind, .none), tree.entries[1].visual.card.paint.shadow);
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, tree.entries[1].visual.card.paint.corner_radii_px.?);
    try std.testing.expect(tree.entries[2].visual == .text);
    try std.testing.expectEqual(TextTone.muted, tree.entries[2].visual.text.tone);
    try std.testing.expectEqual(.accent_bar, tree.entries[2].visual.text.paint.foreground.?);
}

test "build fails closed for duplicate identity and leaves no new rect entries" {
    const root = container(.{ .id = 1 }, &.{
        text(.{ .id = 2, .value = "first" }),
        text(.{ .id = 2, .value = "duplicate" }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    try std.testing.expectError(error.DuplicateIdentity, build(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(emptyRectEntry(), entry);
}

test "build rejects depth, capacity, and leaf children without partial tree" {
    const nested = container(.{ .id = 1 }, &.{
        card(.{ .id = 2 }, &.{
            text(.{ .id = 3, .value = "deep" }),
        }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const buffers: BuildBuffers = .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    };
    try std.testing.expectError(error.MaxDepthExceeded, build(nested, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));
    try std.testing.expectError(error.MaxEntriesExceeded, build(nested, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 2, .max_depth = 3 }, buffers));

    const invalid_leaf = UiNode{
        .id = 8,
        .props = .{ .text = .{ .value = "leaf", .tone = .primary, .paint = .{}, .measure_context = null, .measure = null } },
        .children = &.{text(.{ .id = 9, .value = "child" })},
    };
    try std.testing.expectError(error.LeafHasChildren, build(invalid_leaf, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));

    const invalid_root = container(.{ .id = 10, .style = .{ .width = .{ .px = 10 } } }, &.{});
    try std.testing.expectError(error.RootOuterStyle, build(invalid_root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));

    const invalid_root_padding = container(.{ .id = 11, .style = .{ .padding = .{ .left = -1 } } }, &.{});
    try std.testing.expectError(error.NegativeValue, build(invalid_root_padding, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 }, buffers));
}

test "nested overflow clips intersect and horizontal container children use parent rect origin" {
    const root = container(.{ .id = 1, .direction = .row, .style = .{ .padding = .{ .left = 5 }, .gap = 3 }, .overflow = .clip }, &.{
        card(.{ .id = 2, .style = .{ .width = .{ .px = 30 } }, .overflow = .clip }, &.{
            text(.{ .id = 3, .value = "clip" }),
        }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 50, .height = 20 }, .max_entries = 3, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 5), tree.entries[1].rect.x, 0.001);
    try std.testing.expect(tree.entries[1].effective_clip != null);
    try std.testing.expect(tree.entries[2].effective_clip != null);
    try std.testing.expectApproxEqAbs(tree.entries[1].effective_clip.?.x, tree.entries[2].effective_clip.?.x, 0.001);
}

test "deep first sibling cannot overwrite later parent sibling rect" {
    const root = container(.{ .id = 1, .style = .{ .gap = 2 } }, &.{
        card(.{ .id = 2, .style = .{ .height = .{ .px = 30 } } }, &.{
            text(.{ .id = 3, .value = "one", .measure = measuredText }),
            text(.{ .id = 4, .value = "two", .measure = measuredText }),
        }),
        text(.{ .id = 5, .value = "later", .measure = measuredText }),
    });
    var entries: [5]RectEntry = undefined;
    var items: [5]layout.Item = undefined;
    var scratch: [5]layout.FlexScratch = undefined;
    var child_rects: [5]layout.UiRect = undefined;
    const tree = try build(root, .{ .root_size = .{ .width = 80, .height = 80 }, .max_entries = 5, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    });

    try std.testing.expectEqual(@as(?usize, 0), tree.entries[4].parent_index);
    try std.testing.expectApproxEqAbs(@as(f32, 32), tree.entries[4].rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), tree.entries[4].rect.height, 0.001);
}

test "nested rect offset overflow fails closed instead of publishing infinity" {
    const max = std.math.floatMax(f32);
    const root = container(.{ .id = 1, .direction = .row }, &.{
        card(.{
            .id = 2,
            .style = .{ .width = .{ .px = 0 }, .margin = .{ .left = max / 2 }, .padding = .{ .left = max } },
            .overflow = .clip,
        }, &.{}),
    });
    var entries: [2]RectEntry = undefined;
    var items: [2]layout.Item = undefined;
    var scratch: [2]layout.FlexScratch = undefined;
    var child_rects: [2]layout.UiRect = undefined;
    try std.testing.expectError(error.InvalidNumber, build(root, .{ .root_size = .{ .width = max, .height = 10 }, .max_entries = 2, .max_depth = 2 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(emptyRectEntry(), entry);
}

const scroll_fixture = struct {
    const track_id: UiId = 0x5000;
    const thumb_id: UiId = 0x5001;
    const payload: u64 = 0x5342;

    fn node(children: []const UiNode, origin_y: i32, offset_px: u32) UiNode {
        return scrollArea(.{
            .id = 0x100,
            .style = .{ .width = .{ .percent = 1 }, .height = .{ .fill = 1 } },
            .scroll = .{
                .offset_px = offset_px,
                .content_h_px = 4000,
                .first_item_origin_y_px = origin_y,
                .gutter_px = 20,
                .metrics = .{ .width_px = 8, .inset_x_px = 4, .min_thumb_px = 24 },
                .track = .{ .id = track_id, .action = .{ .id = 71 }, .paint = .{} },
                .thumb = .{ .id = thumb_id, .action = .{ .id = 72 }, .paint = .{} },
                .drag = .{ .payload = payload, .axis = .vertical, .threshold_px = 0 },
            },
        }, children);
    }

    fn run(root: UiNode, storage: anytype) BuildError!UiRectTree {
        return build(root, .{
            .root_size = .{ .width = 200, .height = 300 },
            .max_entries = 16,
            .max_depth = 4,
        }, .{
            .entries = &storage.entries,
            .items = &storage.items,
            .flex_scratch = &storage.flex_scratch,
            .child_rects = &storage.child_rects,
        });
    }
};

const ScrollStorage = struct {
    entries: [16]RectEntry = undefined,
    items: [16]layout.Item = undefined,
    flex_scratch: [16]layout.FlexScratch = undefined,
    child_rects: [16]layout.UiRect = undefined,
};

test "scrollArea emits its scrollbar inside preorder, not appended at the array end" {
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 60 }, .flex = .{ .shrink = 0 } } }, &.{}),
        container(.{ .id = 0x202, .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 60 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var storage = ScrollStorage{};
    const root = container(.{ .id = 1 }, &.{scroll_fixture.node(&children, 0, 0)});
    const tree = try scroll_fixture.run(root, &storage);

    const view_index = tree.find(0x100) orelse return error.TestUnexpectedResult;
    const track_index = tree.find(scroll_fixture.track_id) orelse return error.TestUnexpectedResult;
    const thumb_index = tree.find(scroll_fixture.thumb_id) orelse return error.TestUnexpectedResult;

    // `parent_index`가 스크롤 컨테이너다. `null`로 배열 끝에 붙이면 root가 여럿이 되어 preorder와
    // subtree-range 불변식이 함께 깨진다(도크가 SV1b 전에 그렇게 하고 있었다).
    try std.testing.expectEqual(@as(?usize, view_index), tree.entries[track_index].parent_index);
    try std.testing.expectEqual(@as(?usize, view_index), tree.entries[thumb_index].parent_index);
    // 자식들 **뒤**, 그리고 preorder가 유지된다(부모가 항상 먼저).
    try std.testing.expect(track_index > tree.find(0x202).?);
    try std.testing.expect(view_index < track_index);
    // track이 먼저, thumb이 나중 — `hitAction`은 reverse z-order라 마지막이 이긴다.
    try std.testing.expectEqual(track_index + 1, thumb_index);
    // 이 tree의 root는 하나뿐이다.
    var roots: usize = 0;
    for (tree.entries) |entry| {
        if (entry.parent_index == null) roots += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), roots);

    // drag 선언이 두 조각 모두에 실린다 — track을 눌러 점프한 뒤 그대로 끌 수 있어야 한다.
    try std.testing.expectEqual(scroll_fixture.payload, tree.entries[track_index].drag.?.payload);
    try std.testing.expectEqual(scroll_fixture.payload, tree.entries[thumb_index].drag.?.payload);
}

test "scrollArea reserves the gutter inside itself and its scrollbar survives its own clip" {
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 60 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var storage = ScrollStorage{};
    const root = container(.{ .id = 1 }, &.{scroll_fixture.node(&children, 0, 0)});
    const tree = try scroll_fixture.run(root, &storage);

    const view = tree.entries[tree.find(0x100).?];
    const track = tree.entries[tree.find(scroll_fixture.track_id).?];

    // 스크롤바는 컨테이너 rect **안**이다 — gutter를 자기 폭에서 예약했기 때문이다(CSS
    // `scrollbar-gutter`와 같은 자리). 밖에 두면 자기 clip에 잘려 사라진다.
    try std.testing.expect(track.rect.x >= view.rect.x);
    try std.testing.expect(track.rect.x + track.rect.width <= view.rect.x + view.rect.width);
    // clip은 gutter를 포함하므로 스크롤바가 그 안에 살아남는다.
    const clip = track.effective_clip orelse return error.TestUnexpectedResult;
    try std.testing.expect(track.rect.x >= clip.x);
    try std.testing.expect(track.rect.x + track.rect.width <= clip.x + clip.width);
    // 그리고 자식은 gutter만큼 좁다 — 스크롤바가 목록 위에 겹치지 않는다.
    const child = scrolled_child: {
        const idx = tree.find(0x201) orelse return error.TestUnexpectedResult;
        break :scrolled_child tree.entries[idx];
    };
    try std.testing.expect(child.rect.x + child.rect.width <= track.rect.x);

    // gutter를 되돌린 clip이 **컨테이너를 넘지는 않는다.** clip은 "여기까지만 그린다"는 약속이라
    // 넓히기만 하고 상한을 안 보면 그 약속이 깨진다 — `layout.zig`가 "자식 clip은 항상 부모 clip 안"
    // 이라고 적은 불변식이 여기서 무너지고, 스크롤 자식이 컨테이너 밖으로 새어도 아무도 못 본다.
    const own = view.own_clip orelse return error.TestUnexpectedResult;
    try std.testing.expect(own.x >= view.rect.x);
    try std.testing.expect(own.x + own.width <= view.rect.x + view.rect.width);
    // 자식의 clip도 그 안이다(gutter 확장이 자식에게 새지 않는다).
    const child_clip = child.effective_clip orelse return error.TestUnexpectedResult;
    try std.testing.expect(child_clip.x + child_clip.width <= own.x + own.width);
}

test "scrollArea translates its subtree and refolds each clip at the moved position" {
    const nested = [_]UiNode{
        container(.{ .id = 0x301, .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 30 } } }, &.{}),
    };
    const children = [_]UiNode{
        container(.{
            .id = 0x201,
            .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 60 }, .flex = .{ .shrink = 0 } },
            .overflow = .clip,
        }, &nested),
    };
    var storage = ScrollStorage{};
    const flat = try scroll_fixture.run(container(.{ .id = 1 }, &.{scroll_fixture.node(&children, 0, 0)}), &storage);
    const flat_child_y = flat.entries[flat.find(0x201).?].rect.y;
    const flat_nested_y = flat.entries[flat.find(0x301).?].rect.y;
    const flat_track_y = flat.entries[flat.find(scroll_fixture.track_id).?].rect.y;

    var scrolled_storage = ScrollStorage{};
    const scrolled = try scroll_fixture.run(container(.{ .id = 1 }, &.{scroll_fixture.node(&children, -25, 900)}), &scrolled_storage);

    // 자식과 **그 자손**이 함께 움직인다. 직계 자식만 옮기면 펼친 카드의 detail이 제자리에 남아
    // 이웃 카드 위에 겹쳐 그려진다(사용자 보고 회귀).
    const child = scrolled.entries[scrolled.find(0x201).?];
    const nested_entry = scrolled.entries[scrolled.find(0x301).?];
    try std.testing.expectEqual(flat_child_y - 25, child.rect.y);
    try std.testing.expectEqual(flat_nested_y - 25, nested_entry.rect.y);

    // clip도 옮겨진 자리에서 다시 접힌다 — 반쯤 걸친 자식은 그 보이는 부분만 남는다.
    const view = scrolled.entries[scrolled.find(0x100).?];
    const child_clip = child.effective_clip orelse return error.TestUnexpectedResult;
    const view_clip = view.own_clip orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(view_clip.y, child_clip.y);
    try std.testing.expect(child_clip.height < child.rect.height);

    // 스크롤바는 평행이동을 받지 않는다 — 받으면 스크롤할 때 목록과 같이 흘러내린다.
    try std.testing.expectEqual(flat_track_y, scrolled.entries[scrolled.find(scroll_fixture.track_id).?].rect.y);
    // 그러나 thumb은 offset을 따라 내려간다.
    const thumb = scrolled.entries[scrolled.find(scroll_fixture.thumb_id).?];
    try std.testing.expect(thumb.rect.y > flat.entries[flat.find(scroll_fixture.thumb_id).?].rect.y);
}

test "sticky head clamps through its three states and never leaves the container" {
    // clamp가 한 줄이라 세 상태가 같은 식에서 나온다(§4.7). 하나만 보면 나머지 둘이 무판정으로 남는다.
    const sticky_id: UiId = 0x6000;
    const head_h: f32 = 40;
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .height = .{ .px = 500 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };

    const Case = struct { name: []const u8, offset: u32, want: f32 };
    // 헤더는 content-space 100에 있고 다음 헤더는 400에 있다.
    for ([_]Case{
        // ① 아직 안 지남 — 흐름 그대로(100 - 60 = 40).
        .{ .name = "at rest", .offset = 60, .want = 40 },
        // ② 지나침 — 상단 고정. next는 400-200=200이라 아직 안 밀어낸다.
        .{ .name = "pinned", .offset = 200, .want = 0 },
        // ③ 다음 헤더가 올라옴 — 밀려 나간다(400-380=20, 20-40=-20).
        .{ .name = "pushed", .offset = 380, .want = -20 },
    }) |case| {
        var storage = ScrollStorage{};
        var node = scroll_fixture.node(&children, 0, case.offset);
        node.props.scroll_area.scroll.sticky = .{
            .id = sticky_id,
            .height_px = head_h,
            .top_px = 100,
            .next_top_px = 400,
        };
        // root에 padding을 준다 — content 원점이 0이면 "원점을 무시한다"는 변이가 판정되지 않는다.
        const tree = try scroll_fixture.run(container(.{ .id = 1, .style = .{ .padding = .{ .left = 12, .top = 6 } } }, &.{node}), &storage);

        const view = tree.entries[tree.find(0x100).?];
        const head = tree.entries[tree.find(sticky_id) orelse return error.TestUnexpectedResult];
        const own = view.own_clip orelse return error.TestUnexpectedResult;
        // 컨테이너 content 원점 기준 local y.
        try std.testing.expectApproxEqAbs(case.want, head.rect.y - own.y, 0.01);

        // 어느 상태에서도 자기 컨테이너 clip 안이고 폭은 자식 영역과 같다.
        try std.testing.expectEqual(own.x, head.rect.x);
        try std.testing.expectEqual(@as(?usize, tree.find(0x100).?), head.parent_index);
        const clip = head.effective_clip orelse return error.TestUnexpectedResult;
        try std.testing.expect(head.rect.x >= clip.x);
        try std.testing.expect(head.rect.x + head.rect.width <= clip.x + clip.width);
    }
}

test "sticky head sits above the list and below the scrollbar" {
    const sticky_id: UiId = 0x6000;
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .height = .{ .px = 500 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var storage = ScrollStorage{};
    var node = scroll_fixture.node(&children, 0, 200);
    // 높이는 40이 **아니어야** 한다 — clamp 테스트가 전부 40이라, 여기서도 40이면 "높이를 상수로
    // 박는다"는 회귀가 아무 데서도 안 잡힌다.
    node.props.scroll_area.scroll.sticky = .{ .id = sticky_id, .height_px = 44, .top_px = 100, .next_top_px = 400 };
    const tree = try scroll_fixture.run(container(.{ .id = 1, .style = .{ .padding = .{ .left = 12, .top = 6 } } }, &.{node}), &storage);

    const child_index = tree.find(0x201) orelse return error.TestUnexpectedResult;
    const head_index = tree.find(sticky_id) orelse return error.TestUnexpectedResult;
    const track_index = tree.find(scroll_fixture.track_id) orelse return error.TestUnexpectedResult;

    // z는 emit 순서이고 `hitAction`은 reverse z라 뒤가 이긴다. 카드는 헤더 밑으로 지나가야 하고,
    // gutter 클릭은 헤더로 새지 않아야 한다.
    try std.testing.expect(child_index < head_index);
    try std.testing.expect(head_index < track_index);

    // 순서만으로는 부족하다 — 컨테이너 clip은 gutter를 되돌려 포함하므로(§4) 헤더가 gutter까지
    // 넓어져도 clip 단언은 통과한다. 헤더는 자식과 같은 content 폭에서 멈춰야 스크롤바를 안 덮는다.
    try std.testing.expect(tree.entries[head_index].rect.x + tree.entries[head_index].rect.width <=
        tree.entries[track_index].rect.x);
    try std.testing.expectEqual(tree.entries[child_index].rect.width, tree.entries[head_index].rect.width);
    try std.testing.expectEqual(@as(f32, 44), tree.entries[head_index].rect.height);
}

test "sticky counts against the entry cap instead of writing past the buffer" {
    // root + scrollArea + 자식 = 3. sticky는 네 번째라 상한을 넘겨야 하고, 넘기면 **버퍼 밖으로
    // 쓰는 대신** fail-close 해야 한다.
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .height = .{ .px = 500 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var node = scroll_fixture.node(&children, 0, 200);
    node.props.scroll_area.scroll.sticky = .{ .id = 0x6000, .height_px = 40, .top_px = 100, .next_top_px = 400 };

    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    try std.testing.expectError(error.MaxEntriesExceeded, build(
        container(.{ .id = 1 }, &.{node}),
        .{ .root_size = .{ .width = 200, .height = 300 }, .max_entries = 3, .max_depth = 4 },
        .{ .entries = &entries, .items = &items, .flex_scratch = &scratch, .child_rects = &child_rects },
    ));
    for (entries) |entry| try std.testing.expectEqual(emptyRectEntry(), entry);
}

test "no sticky declaration means no sticky entry" {
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .height = .{ .px = 500 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var storage = ScrollStorage{};
    const tree = try scroll_fixture.run(container(.{ .id = 1 }, &.{scroll_fixture.node(&children, 0, 200)}), &storage);
    try std.testing.expect(tree.find(0x6000) == null);
}

test "scrollArea publishes no scrollbar when nothing overflows or the gutter is too narrow" {
    const children = [_]UiNode{
        container(.{ .id = 0x201, .style = .{ .width = .{ .percent = 1 }, .height = .{ .px = 60 }, .flex = .{ .shrink = 0 } } }, &.{}),
    };
    var storage = ScrollStorage{};
    var fits = scroll_fixture.node(&children, 0, 0);
    fits.props.scroll_area.scroll.content_h_px = 10; // viewport보다 짧다
    const fits_tree = try scroll_fixture.run(container(.{ .id = 1 }, &.{fits}), &storage);
    try std.testing.expect(fits_tree.find(scroll_fixture.track_id) == null);

    var narrow_storage = ScrollStorage{};
    var narrow = scroll_fixture.node(&children, 0, 0);
    narrow.props.scroll_area.scroll.gutter_px = 2; // track 폭(8)을 못 담는다
    const narrow_tree = try scroll_fixture.run(container(.{ .id = 1 }, &.{narrow}), &narrow_storage);
    // 목록 위에 겹쳐 그리는 대안은 두지 않는다 — 아예 안 그린다.
    try std.testing.expect(narrow_tree.find(scroll_fixture.track_id) == null);
}

test "rebuild counter advances only after completed tree build" {
    const valid = text(.{ .id = 1, .value = "ready" });
    const duplicate = container(.{ .id = 2 }, &.{
        text(.{ .id = 3, .value = "one" }),
        text(.{ .id = 3, .value = "two" }),
    });
    var entries: [3]RectEntry = undefined;
    var items: [3]layout.Item = undefined;
    var scratch: [3]layout.FlexScratch = undefined;
    var child_rects: [3]layout.UiRect = undefined;
    const options: BuildOptions = .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 3, .max_depth = 2 };
    const buffers: BuildBuffers = .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    };
    var counter: RebuildCounter = .{};
    _ = try counter.rebuild(valid, options, buffers);
    try std.testing.expectEqual(@as(u64, 1), counter.completed);
    try std.testing.expectError(error.DuplicateIdentity, counter.rebuild(duplicate, options, buffers));
    try std.testing.expectEqual(@as(u64, 1), counter.completed);
}

test "active sibling scratch beyond tree cap reports max entries, not buffer failure" {
    const root = container(.{ .id = 1 }, &.{
        card(.{ .id = 2 }, &.{
            text(.{ .id = 3, .value = "one" }),
            text(.{ .id = 4, .value = "two" }),
        }),
        text(.{ .id = 5, .value = "three" }),
        text(.{ .id = 6, .value = "four" }),
    });
    var entries: [4]RectEntry = undefined;
    var items: [4]layout.Item = undefined;
    var scratch: [4]layout.FlexScratch = undefined;
    var child_rects: [4]layout.UiRect = undefined;
    try std.testing.expectError(error.MaxEntriesExceeded, build(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 4, .max_depth = 3 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    for (entries) |entry| try std.testing.expectEqual(emptyRectEntry(), entry);
}

test "rebuild counter overflow clears candidate entries before fail-close" {
    const root = text(.{ .id = 1, .value = "ready" });
    var entries: [1]RectEntry = .{.{
        .id = 99,
        .parent_index = null,
        .kind = .text,
        .rect = .{ .width = 1, .height = 1 },
        .effective_clip = null,
        .action = .{ .id = 77 },
    }};
    var items: [1]layout.Item = undefined;
    var scratch: [1]layout.FlexScratch = undefined;
    var child_rects: [1]layout.UiRect = undefined;
    var counter: RebuildCounter = .{ .completed = std.math.maxInt(u64) };
    try std.testing.expectError(error.RebuildCounterOverflow, counter.rebuild(root, .{ .root_size = .{ .width = 20, .height = 20 }, .max_entries = 1, .max_depth = 1 }, .{
        .entries = &entries,
        .items = &items,
        .flex_scratch = &scratch,
        .child_rects = &child_rects,
    }));
    try std.testing.expectEqual(emptyRectEntry(), entries[0]);
}
