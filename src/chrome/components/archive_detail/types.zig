//! archive 세션 상세 패널의 platform 중립·redaction 완료 입력 DTO다.

const layout = @import("../../ui/layout.zig");

pub const State = enum { loading, ready, stale, unavailable };
pub const Provider = enum { codex, claude };
pub const Role = enum { user, assistant };

pub const Turn = struct {
    role: Role,
    /// 이 DTO를 만들기 전에 host가 저장소 redaction 정책을 이미 적용했다.
    text: []const u8,
};

pub const Props = struct {
    viewport_px: layout.UiSize,
    cell_width_px: u32,
    cell_height_px: u32,
    /// backing scale × dock zoom. Button floor 같은 logical point 치수를 이 값으로 한 번만 환산한다.
    /// 넘기지 않으면 1× 기준이라 고배율에서 hit-target floor가 사실상 사라진다.
    scale_milli: u32 = 1000,
    snapshot_generation: u64,
    state: State,
    provider: Provider,
    title: []const u8,
    metadata: []const u8,
    turns: []const Turn = &.{},
    action_record_count: u32 = 0,
    spinner_phase: u3 = 0,
    /// 이 bool들은 UI 취향이 아니라 host가 인가한 capability다. ready가 아닌 state는 stale DTO가
    /// true라고 말해도 source에 영향을 주는 action을 전부 비활성으로 둬야 한다.
    resume_enabled: bool = false,
    reveal_enabled: bool = false,
    focus_live_enabled: bool = false,
};

pub const Metrics = struct {
    header_h: u32,
    metadata_h: u32,
    section_h: u32,
    turn_h: u32,
    actions_h: u32,
    gap: u32,
    /// 상세 카드의 논리 텍스트 줄이 쓰는 세로 여백이다. renderer 폰트 설정이 아니라 컴포넌트
    /// 메트릭에 두어야 카드 rect·clipping·paint baseline이 어느 backing scale에서도 하나의 layout
    /// 계약으로 남는다.
    line_gap: u32,
    pad: u32,

    pub fn fromCellHeight(cell_height_px: u32) Metrics {
        const ch = @max(cell_height_px, 1);
        return .{
            .header_h = ch * 3 + line_gap(ch),
            // Text baselines are one cell below a card's top edge. Two metadata lines therefore
            // need three cells: 1ch for the first baseline, 1ch between baselines, and a final
            // descender/clip cell. Keeping this in the shared metric prevents a painted count
            // from existing semantically but being clipped by the same rect tree.
            .metadata_h = ch * 3 + line_gap(ch),
            .section_h = ch * 2,
            .turn_h = ch * 4 + line_gap(ch),
            .actions_h = ch * 2,
            .gap = @max(ch / 2, 4),
            .line_gap = line_gap(ch),
            .pad = @max(ch, 8),
        };
    }
};

fn line_gap(cell_height_px: u32) u32 {
    return @max(cell_height_px / 4, 3);
}

pub fn isActionable(props: Props) bool {
    return props.state == .ready;
}
