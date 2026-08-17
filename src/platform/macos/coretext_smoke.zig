const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;
const coretext_probe = @import("coretext_probe.zig");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");
const coretext_frame_builder = @import("coretext_frame_builder.zig"); // chrome 셀 텍스트 생산자(CG1 cluster 방출) — 실-CoreText 합성 확인용
const coretext_bridge = @import("coretext_smoke_bridge.zig");
// shape/raster native bridge 시그니처는 coretext_smoke_bridge.zig가 단일 출처로 소유한다.
// Metal smoke와 같은 선언을 공유해 ABI 드리프트를 한 곳에서만 관리한다.
const maru_macos_coretext_shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list;
const maru_macos_coretext_smoke_rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph;

const artifact_dir = "zig-out/maru-macos-coretext-smoke";
const renderer_probe_shaper = "coretext_shaped_records";
const NativeCoreTextSmokeResult = coretext_probe.NativeCoreTextSmokeResult;
const NativeGlyphCategory = coretext_probe.NativeGlyphCategory;
const NativeGlyphRecord = coretext_probe.NativeGlyphRecord;
const emptyNativeResult = coretext_probe.emptyNativeResult;
const emptyGlyphRecord = coretext_probe.emptyGlyphRecord;
const nativeGlyphRecordForTest = coretext_probe.nativeGlyphRecordForTest;

extern fn maru_macos_coretext_smoke_run(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    result: *NativeCoreTextSmokeResult,
    glyph_records: [*]NativeGlyphRecord,
    glyph_record_capacity: usize,
) void;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const appearance = try config.resolveAppearance(.{});
    var native: NativeCoreTextSmokeResult = emptyNativeResult();
    var glyph_records = [_]NativeGlyphRecord{emptyGlyphRecord()} ** coretext_probe.glyph_record_capacity;
    maru_macos_coretext_smoke_run(
        appearance.font.family.ptr,
        appearance.font.family.len,
        @floatCast(appearance.font.size),
        &native,
        &glyph_records,
        glyph_records.len,
    );

    const smoke_status = deriveSmokeStatus(native);
    const record_count = @min(@as(usize, @intCast(native.glyph_record_count)), glyph_records.len);

    // 이 smoke의 가치는 실패 위치(font/shape/raster/frame)를 summary로 좁히는 것이다. probe
    // build가 throw로 빠져나가면 정작 실패한 경로의 진단 artifact가 안 남는다. 그래서 probe
    // 실패를 error로 흘리지 않고 summary에 기록한 뒤, artifact를 쓴 다음 종료 코드로 보고한다.
    var fixed_probe_error: ?anyerror = null;
    const glyph_frame_probe = buildGlyphFrameProbe(
        allocator,
        appearance,
        native,
        glyph_records[0..record_count],
    ) catch |err| blk: {
        fixed_probe_error = err;
        break :blk emptyGlyphFrameProbe(coretext_raster.CoreTextGlyphRasterizer.name);
    };

    var draw_list_probe_error: ?anyerror = null;
    const draw_list_probe = buildDrawListGlyphFrameProbe(allocator, appearance) catch |err| blk: {
        draw_list_probe_error = err;
        var empty = emptyGlyphFrameProbe(coretext_raster.CoreTextGlyphRasterizer.name);
        empty.renderer_shaper = coretext_shaper.CoreTextDrawListShaper.name;
        break :blk empty;
    };

    const face_cache_probe = probeFaceCacheReuse(appearance);
    const shape_leak_probe = probeShapeLeak(appearance);

    const summary = try renderSummary(
        allocator,
        appearance,
        smoke_status,
        native,
        glyph_frame_probe,
        draw_list_probe,
        face_cache_probe,
        shape_leak_probe,
        fixed_probe_error,
        draw_list_probe_error,
    );
    defer allocator.free(summary);

    try writeSummary(io, summary);
    try stdout.writeAll(summary);
    try stdout.print("\nartifacts written to {s}/\n", .{artifact_dir});
    try stdout.flush();

    // 요약을 먼저 남긴 뒤 실패를 보고한다.
    if (fixed_probe_error) |err| return err;
    if (draw_list_probe_error) |err| return err;
    if (!smoke_status.shaped_text or !smoke_status.glyph_rasterized) return error.MacosCoreTextSmokeFailed;
    // 헤드라인인 실제 TerminalCore -> DrawList 경로도 exit gate에 포함한다. 요약에만 출력하고
    // 게이팅하지 않으면, DrawList 프레임이 조용히 unprepared여도 smoke가 통과한다.
    if (!draw_list_probe.renderer_frame_prepared or
        !draw_list_probe.renderer_glyph_raster_ready) return error.MacosCoreTextSmokeFailed;
    // face 재사용도 exit gate다. 요약에만 남기고 게이팅하지 않으면 "프레임마다 face를 다시 만든다"는
    // 회귀가 화면상 아무 증상 없이 통과하고, 그 대가는 몇 시간 뒤의 수십 GB로만 나타난다.
    // 셰이핑 실패를 캐시 회귀로 이름 붙이지 않는다 — 원인을 잘못 가리키는 실패가 가장 나쁘다.
    if (!face_cache_probe.shaped) return error.MacosCoreTextFaceCacheProbeFailed;
    if (!face_cache_probe.covered) return error.MacosCoreTextFaceCacheProbeNotCovering;
    if (!face_cache_probe.reused) return error.MacosCoreTextFaceCacheNotReused;
    // 누수 게이트. face 캐시 게이트와 **다른 것**을 지킨다 — 저쪽은 "몇 번 만들었나", 이쪽은 "만든 것을
    // 놓아줬나"다. 2026-08-18 사건의 실제 원인은 후자였고, 그 분기(합자 OFF)는 다른 probe가 타지 않는다.
    // status 도 함께 본다. 셰이핑이 실패하면 아무것도 할당되지 않아 grew 가 0 이 되고, 그러면 게이트가
    // **아무것도 태우지 않은 채 green** 이 된다 — 이 PR 이 막으려는 "게이트가 조용히 죽는" 그 실패다.
    // **못 쟀으면 실패다.** `measured`로 두 검사를 다 감싸 놓고 `measured` 자체를 안 보면, footprint 를
    // 못 읽는 러너에서 스모크가 메모리에 대해 아무것도 확인하지 않은 채 green 이 된다 — 이 PR 이 막으려는
    // "게이트가 조용히 죽는" 바로 그 실패다. 못 재는 것은 통과가 아니라 고쳐야 할 상태다.
    if (!shape_leak_probe.measured) return error.MacosCoreTextShapeLeakNotMeasured;
    // **status 를 먼저 본다.** 셰이핑이 실패하면 할당이 거의 없어 델타가 0 근처로 떨어지는데, 그때
    // 누수 이름으로 실패하면 원인이 셰이핑 실패라는 사실이 가려진다(옆 face 캐시 게이트도 `shaped` 를
    // 먼저 본다).
    if (shape_leak_probe.status != 0) {
        return error.MacosCoreTextShapeLeakProbeFailed;
    }
    if (!shape_leak_probe.within_limit) {
        return error.MacosCoreTextShapeLeaked;
    }
}

/// face 캐시 재사용 계약을 **실제 CoreText**로 확인한다.
///
/// 같은 (family, fallback, bold/italic family, size, ligatures)로 두 번 셰이핑하면 두 번째는 **face를 하나도
/// 새로 만들지 않아야** 한다. face 해석은 같은 설정이면 결과가 같은데, 그것을 shape 호출(=dirty 프레임)마다
/// 반복하면 메인 스레드가 CoreText face 생성에 잠긴다(2026-08-18 실측: 메인 스레드 샘플의 46%가
/// `CTFontCopyDefaultCascadeListForLanguages` 아래 malloc 락 경합). 화면에는 아무 증상이 없어서, 이 회귀는
/// 눈이 아니라 여기서 잡혀야 한다.
///
/// 판정은 `face_builds_delta == 0`이 소유한다. hit/miss만 보면 부족하다 — 조회가 hit여도 그 뒤에서 face를
/// 다시 만들면 hits/misses는 그대로고 회귀만 살아나기 때문이다.
const FaceCacheProbe = struct {
    /// 두 번째 호출이 face를 하나도 새로 만들지 않았는가(이 smoke의 exit gate).
    reused: bool = false,
    hits_delta: u64 = 0,
    misses_delta: u64 = 0,
    /// 첫 호출이 face를 새로 해석한 횟수. `min_first_call_face_builds` 이상이어야 한다 — 그보다 적으면
    /// 프로브가 style face 경로를 못 태운 것이라 아래 delta 0이 아무것도 증명하지 못한다.
    first_call_face_builds: u64 = 0,
    min_first_call_face_builds: u64 = 0,
    /// 첫 호출이 style face 경로를 실제로 태웠는가. **`reused`와 따로 둔다** — 못 태웠다면 캐시가 회귀한
    /// 것이 아니라 이 프로브가 아무것도 증명하지 못하는 상태다. 둘을 한 불리언에 접으면 러너의 face
    /// 구성 때문에 **캐시가 멀쩡한데** 캐시 회귀라는 이름으로 실패한다.
    /// 기본값은 **false**다. 게이트를 소유한 필드는 fail-closed 여야 한다 — 언젠가 이른 return 이
    /// `.{}` 를 돌려주면 기본값이 true 인 필드는 아무것도 확인하지 않은 채 게이트를 통과시킨다.
    covered: bool = false,
    /// 두 shape 호출이 모두 성공했는가. **`reused`와 따로 둔다** — 셰이핑이 실패하면 face를 만들 일이
    /// 없어 지표가 전부 0이 되는데, 그것을 캐시 회귀로 보고하면 진단이 엉뚱한 층으로 간다. 옆의 누수
    /// 프로브가 같은 조건에 전용 에러를 쓰는 것과 같은 이유다.
    shaped: bool = false,
    /// 두 shape 호출의 native status. 0이 아니면 위 수치는 회귀가 아니라 셰이핑 실패의 결과다.
    first_status: c_int = 0,
    second_status: c_int = 0,
    /// 두 번째 호출이 face를 새로 해석한 횟수(regular 집합 + style face). 0이어야 한다.
    face_builds_delta: u64 = 0,
    entries: u32 = 0,
};

/// 이 프로브만 쓰는 폰트 크기 오프셋.
///
/// face 캐시 키에는 size가 들어간다. 프로브가 앱과 **같은** 크기를 쓰면 앞선 probe들이 이미 만들어 둔
/// 항목을 물려받아 프로브의 첫 호출조차 hit가 되고, 그러면 "첫 호출이 face를 만들었는가"라는 판정 근거가
/// 사라진다(실측: 그 상태에서 `first_call_face_builds=0`). 지금은 앞선 probe들이 bold/italic을 쓰지 않아
/// 우연히 성립하지만, draw list probe에 bold 글자가 하나 추가되는 순간 게이트가 **코드는 멀쩡한데** 거짓
/// 실패한다. 전용 크기를 써서 그 순서 의존성을 없앤다.
const face_cache_probe_size_offset: f64 = 0.5;

/// 첫 프로브 호출이 만들어야 하는 **최소** face 수.
///
/// 지키려는 성질은 "프로브가 style face 경로를 실제로 태웠다"이다. regular 1 + style 최소 1 = 2 면 그것이
/// 증명된다 — 프로브 셀에서 style 셋을 지우면 1 이 되어 걸린다(그 구멍이 이 조건을 넣은 이유였다).
///
/// **정확히 4 를 요구하지 않는다.** `maru_create_styled_font` 는 그 조합의 face 가 없으면 NULL 을 돌려주고
/// 그때는 build 로 세지 않는다. 즉 italic 이 없는 등폭 폰트(드물지 않다)를 쓰는 러너에서 3 이나 2 가 나오고,
/// 정확 비교는 **캐시가 멀쩡한데** `MacosCoreTextFaceCacheNotReused` 로 거짓 실패한다 — 이름이 원인을
/// 잘못 가리키는 실패가 가장 나쁘다.
///
/// **남는 구멍**: 프로브의 style 셀 셋 중 둘만 지워도 2 라 통과한다. 즉 이 게이트는 "style 경로를 아예
/// 잃었다"만 잡고 "일부만 잃었다"는 못 잡는다. 실제 값(`face_cache_first_call_face_builds`)이 요약에
/// 남으므로 커버리지 변화는 그 수치로 추적한다. 러너별 face 구성이 달라 자동 판정할 수 없는 부분이다.
const face_cache_probe_min_builds: u64 = 2;

/// draw list shape 경로를 한 번 태운다. 셰이핑 결과의 정확성은 위 draw list probe가 이미 보므로, 여기서는
/// face를 다시 만드는지만 보면 된다.
///
/// **네 style 조합을 모두 넣는다**(regular / bold / italic / bold-italic). regular 한 글자만 넣으면
/// `style_index`가 늘 0이라 `maru_term_face_cache_ensure_style`가 아예 호출되지 않고, 그러면 "bold face를
/// 프레임마다 다시 만든다"는 회귀가 이 게이트를 그대로 통과한다(실측 확인 — 캐시를 고의로 파손해도
/// `face_builds_delta=0`이었다). lazy 생성은 **첫 호출에서** 끝나야 하고 두 번째 호출은 넷 다 재사용해야 한다.
fn shapeOnceForFaceCache(appearance: config.ResolvedAppearance) c_int {
    return shapeOnceForProbe(
        appearance,
        @as(f64, @floatCast(appearance.font.size)) + face_cache_probe_size_offset,
        appearance.font.ligatures,
    );
}

/// 프로브용 shape 호출 1회. `size`와 `ligatures`를 **명시로 받는다** — 누수 프로브가 캐시 miss를 강제하고
/// (매번 다른 size) 합자 OFF 분기를 태워야 하기 때문이다. 반환값은 native status(0=성공)로, 호출자가
/// "셰이핑이 실패해서 지표가 0"인 경우와 진짜 회귀를 가를 수 있게 한다.
fn shapeOnceForProbe(appearance: config.ResolvedAppearance, size: f64, ligatures: bool) c_int {
    var cells = [_]coretext_shaper.NativeDrawCell{
        .{ .row = 0, .col = 0, .width = 1, .codepoint = 'M' },
        .{
            .row = 0,
            .col = 1,
            .width = 1,
            .style_flags = coretext_shaper.draw_cell_bold_bit,
            .codepoint = 'B',
        },
        .{
            .row = 0,
            .col = 2,
            .width = 1,
            .style_flags = coretext_shaper.draw_cell_italic_bit,
            .codepoint = 'I',
        },
        .{
            .row = 0,
            .col = 3,
            .width = 1,
            .style_flags = coretext_shaper.draw_cell_bold_bit | coretext_shaper.draw_cell_italic_bit,
            .codepoint = 'X',
        },
    };
    const grapheme_pool: []const u32 = &.{};
    // 셀 수보다 넉넉히 잡는다. 지금 셀 구성(4개)에서는 용량 4로도 넘치지 않지만(실측
    // `glyph_record_overflow=0`), 여유가 정확히 0이라 셀을 하나 늘리거나 한 셀이 글리프 둘을 내는
    // 순간 넘친다. 넘치면 native가 status 7로 **셀 루프를 중단**해 뒤쪽 style 조합이 첫 호출에서
    // 생성되지 않고 두 번째 호출로 밀리고, 그러면 게이트가 코드는 멀쩡한데 거짓 실패한다.
    var records = [_]coretext_shaper.NativeDrawGlyphRecord{
        std.mem.zeroes(coretext_shaper.NativeDrawGlyphRecord),
    } ** 32;
    var native = std.mem.zeroes(coretext_shaper.NativeDrawListShapeResult);
    native.status = -1;
    maru_macos_coretext_shape_draw_list(
        appearance.font.family.ptr,
        appearance.font.family.len,
        size,
        appearance.font.fallback.ptr,
        appearance.font.fallback.len,
        appearance.font.family_bold.ptr,
        appearance.font.family_bold.len,
        appearance.font.family_italic.ptr,
        appearance.font.family_italic.len,
        if (ligatures) 1 else 0,
        &cells,
        cells.len,
        grapheme_pool.ptr,
        grapheme_pool.len,
        &native,
        &records,
        records.len,
    );
    return native.status;
}

/// 셰이핑 경로가 메모리를 새는지 **직접** 재는 게이트.
///
/// **왜 face 캐시 카운터로는 부족한가.** 그 카운터는 "몇 번 만들었나"만 안다. 2026-08-18 사건의 원인
/// (`maru_create_shape_attributes`가 `maru_font_without_contextual_alternates`의 +1을 놓친 것)은 face를
/// 정확히 한 번씩 만들면서 그 한 번을 매번 흘리는 결함이었다 — 카운터로는 완벽해 보인다.
///
/// **왜 합자를 끄는가.** 그 누수 지점은 `maru_create_shape_attributes`의 `ligatures_enabled == false` 분기에만
/// 있다. config 기본값이 `ligatures = true`라 다른 probe들은 그 분기를 **한 번도 타지 않는다** — 이 프로브가
/// 없으면 누수 수정을 되돌려도 모든 게이트가 green이다.
///
/// **왜 매번 다른 size인가.** face 캐시가 miss일 때만 attributes를 만든다. 같은 키로 반복하면 첫 호출 한
/// 번만 타고 누수가 드러나지 않는다. size를 매번 바꿔 miss를 강제한다.
const ShapeLeakProbe = struct {
    iterations: u32 = 0,
    /// **부호 있는** 순증가. 0으로 clamp 하지 않는다 — 정보를 지우면 상한 근처 결과를 진단할 수 없다.
    /// 음수(순 감소)는 통과다(판정 근거는 `within_limit` 주석).
    delta_bytes: i64 = 0,
    limit_bytes: u64 = 0,
    within_limit: bool = false,
    /// footprint 를 못 읽었으면(task_info 실패) 판정하지 않는다 — 못 잰 것을 통과로도 실패로도 치지 않는다.
    measured: bool = false,
    /// 마지막 shape 호출의 native status. 0이 아니면 아래 수치는 회귀가 아니라 셰이핑 실패의 결과다.
    status: c_int = -1,
};

/// 반복 횟수와 상한. **둘 다 실측으로 정했다**(추정이 아니다).
///
/// 반복을 늘려도 정상 경로의 증가는 거의 늘지 않는다 — 대부분 1회성(CoreText 초기화·캐시 채움)이고
/// 회당 몫은 수십 바이트다. 반면 누수는 회당 약 36KB로 반복에 **선형**이다. 그래서 반복을 키울수록
/// 신호 대 잡음이 좋아진다. 4,000회는 0.73초라 CI에서 사실상 공짜다.
///
/// 4,000회 기준(합자 두 설정을 번갈아 태운 현재 구성, 16회 측정):
///
/// | | 값 |
/// |---|---|
/// | 정상 | 272~384 KB (중앙값 304 KB) |
/// | 누수 되돌린 red 실측 | 72,351,792 B |
/// | 상한 | 4 MB — 정상 최대치의 **10.7배**, 누수 신호의 **1/17** |
///
/// 회당 1KB 이상 새는 결함이면 잡힌다. **이 표를 고칠 때 docs/font-strategy.md "터미널 face 캐시"의 같은
/// 수치도 함께 고친다** — 둘이 어긋나면 나중에 상한을 조정하는 사람이 틀린 여유를 근거로 삼는다.
const shape_leak_probe_iterations: u32 = 4000;
const shape_leak_probe_limit_bytes: u64 = 4 * 1024 * 1024;

fn probeShapeLeak(appearance: config.ResolvedAppearance) ShapeLeakProbe {
    const base = @as(f64, @floatCast(appearance.font.size)) + 100.0;
    // 워밍업: 첫 진입의 1회성 비용(폰트 로드·CoreText 내부 초기화)을 기준선에서 뺀다.
    var warm: u32 = 0;
    while (warm < 20) : (warm += 1) {
        _ = shapeOnceForProbe(appearance, base + @as(f64, @floatFromInt(warm)) * 0.01, warm % 2 == 1);
    }

    const before = coretext_bridge.maru_macos_coretext_phys_footprint_bytes();
    const status = runShapeLeakWindow(appearance, base);
    const after = coretext_bridge.maru_macos_coretext_phys_footprint_bytes();

    const measured = before != 0 and after != 0;
    // **부호 있는 순증가.** 0으로 clamp 하지 않는다 — 정보를 지우면 near-limit 결과를 진단할 수 없다.
    const delta: i64 = if (measured)
        @as(i64, @intCast(after)) - @as(i64, @intCast(before))
    else
        0;
    return .{
        .iterations = shape_leak_probe_iterations,
        .delta_bytes = delta,
        .limit_bytes = shape_leak_probe_limit_bytes,
        // 음수(순 감소)는 **통과**다. 이 게이트의 계약은 "순 footprint 가 상한을 넘게 늘지 않는다"이고
        // 감소는 그 계약을 문자 그대로 만족한다 — 계약을 지킨 빌드를 빨갛게 만들면 안 된다.
        //
        // **남는 사각**: `phys_febug`가 아니라 순값이라, 상한 근처의 작은 누수가 같은 창 안의 OS 회수에
        // 정확히 상쇄되면 통과한다. 이 게이트는 할당 원장이 아니라 **순증가 임계값**이다. 실제로 막으려는
        // 크기(회당 수십 KB → 창당 수십 MB)는 회수로 가려질 수 없다(red 실측 72.4MB vs 상한 4MB).
        .within_limit = measured and delta <= @as(i64, @intCast(shape_leak_probe_limit_bytes)),
        .measured = measured,
        .status = status,
    };
}

/// 측정 창 하나. 마지막 shape 호출의 native status 를 돌려준다.
fn runShapeLeakWindow(appearance: config.ResolvedAppearance, base: f64) c_int {
    var status: c_int = -1;
    var i: u32 = 0;
    while (i < shape_leak_probe_iterations) : (i += 1) {
        // 20.00 부터 이어 붙여 워밍업 구간과 겹치지 않게 한다.
        //
        // **합자 두 설정을 번갈아 태운다.** 누수를 낸 자리(`calt` 사본)는 OFF 분기에만 있지만, ON 분기도
        // dictionary 를 만들어 폰트를 담는다 — 거기 소유권 실수가 새로 생기면 **기본 설정을 쓰는 모든**
        // 사용자에게 프레임마다 샌다. OFF 만 재면 그 회귀에 눈이 먼다(라운드 3에서 잡힌 "게이트가 정작
        // 그 분기를 안 탄다"의 거울상). 캐시 키에 ligatures 가 들어가므로 두 설정 모두 miss 가 강제된다.
        const ligatures_on = i % 2 == 1;
        status = shapeOnceForProbe(appearance, base + 20.0 + @as(f64, @floatFromInt(i)) * 0.01, ligatures_on);
    }
    return status;
}

fn probeFaceCacheReuse(appearance: config.ResolvedAppearance) FaceCacheProbe {
    // 앞선 probe들이 이미 이 설정의 항목을 만들어 뒀을 수도, 아닐 수도 있다. 계약은 "**두 번째** 호출이
    // hit"이므로 기준선은 첫 호출 뒤에 잡는다.
    // 첫 호출 **전** 상태. 이 기준선이 있어야 "첫 호출이 face를 몇 개 만들었나"를 알 수 있고, 그래야
    // 두 번째 호출의 delta 0이 "재사용했다"인지 "애초에 아무것도 안 만들었다"인지 갈린다. 후자면 게이트에
    // 이빨이 없다.
    var hits_start: u64 = 0;
    var misses_start: u64 = 0;
    var builds_start: u64 = 0;
    var entries_start: u32 = 0;
    coretext_bridge.maru_macos_coretext_face_cache_stats(&hits_start, &misses_start, &builds_start, &entries_start);

    const first_status = shapeOnceForFaceCache(appearance);
    var hits_before: u64 = 0;
    var misses_before: u64 = 0;
    var builds_before: u64 = 0;
    var entries_before: u32 = 0;
    coretext_bridge.maru_macos_coretext_face_cache_stats(&hits_before, &misses_before, &builds_before, &entries_before);

    const second_status = shapeOnceForFaceCache(appearance);
    var hits_after: u64 = 0;
    var misses_after: u64 = 0;
    var builds_after: u64 = 0;
    var entries_after: u32 = 0;
    coretext_bridge.maru_macos_coretext_face_cache_stats(&hits_after, &misses_after, &builds_after, &entries_after);

    return .{
        // 판정의 소유자는 face_builds다. hit/miss는 진단용 보조 신호로만 남긴다.
        //
        // `first_call_face_builds >= min`도 함께 요구한다 — 첫 호출이 style face 경로를 못 태웠다면
        // delta 0은 재사용의 증거가 아니라 게이트가 죽었다는 뜻이다. 왜 정확 비교가 아닌지와 그때 남는
        // 구멍은 `face_cache_probe_min_builds` 주석이 단일 출처다.
        //
        // 셰이핑 성공 여부(status)는 **여기 섞지 않고** `shaped`로 따로 낸다 — 아래 주석 참고.
        .reused = builds_after == builds_before and hits_after > hits_before,
        .covered = builds_before - builds_start >= face_cache_probe_min_builds,
        .shaped = first_status == 0 and second_status == 0,
        .first_call_face_builds = builds_before - builds_start,
        .min_first_call_face_builds = face_cache_probe_min_builds,
        .first_status = first_status,
        .second_status = second_status,
        .hits_delta = hits_after - hits_before,
        .misses_delta = misses_after - misses_before,
        .face_builds_delta = builds_after - builds_before,
        .entries = entries_after,
    };
}

const SmokeStatus = struct {
    font_resolved: bool,
    shaped_text: bool,
    glyph_rasterized: bool,
    fallback_observed: bool,
};

fn deriveSmokeStatus(native: NativeCoreTextSmokeResult) SmokeStatus {
    // 이 smoke는 glyph atlas나 Metal을 검증하지 않는다. CoreText가 macOS 기본
    // monospace font를 찾고 probe 문자열을 glyph run으로 나누는지 검증한다.
    // glyph_count만 보면 .notdef도 glyph로 세기 때문에, probe의 ASCII/CJK/emoji가
    // 각각 실제 glyph id로 매핑됐는지까지 pass 조건에 넣는다.
    // 이렇게 쪼개야 나중에 화면이 비었을 때 원인이 font resolve인지 GPU draw인지
    // summary만 보고 분리할 수 있다.
    const font_resolved = native.primary_font_found != 0;
    const shaped_text = hasNativeShapeFields(native);
    const glyph_rasterized = shaped_text and
        native.status == 0 and
        native.glyph_rasterized != 0 and
        native.raster_width > 0 and
        native.raster_height > 0 and
        native.raster_non_clear_pixels > 0 and
        native.raster_failures == 0;

    return .{
        .font_resolved = font_resolved,
        .shaped_text = shaped_text,
        .glyph_rasterized = glyph_rasterized,
        .fallback_observed = native.fallback_run_count > 0,
    };
}

fn hasNativeShapeFields(native: NativeCoreTextSmokeResult) bool {
    // shape 완료 판정은 CoreText smoke와 Metal smoke가 같은 probe result를 해석하므로
    // `coretext_probe.zig`를 단일 출처로 둔다. status 6(raster 실패)은 shape와 무관하므로
    // 그대로 통과시켜 shape/raster 신호 분리를 유지한다.
    return coretext_probe.hasCompleteShapeFields(native);
}

fn renderSummary(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    smoke_status: SmokeStatus,
    native: NativeCoreTextSmokeResult,
    glyph_frame_probe: GlyphFrameProbe,
    draw_list_probe: GlyphFrameProbe,
    face_cache_probe: FaceCacheProbe,
    shape_leak_probe: ShapeLeakProbe,
    fixed_probe_error: ?anyerror,
    draw_list_probe_error: ?anyerror,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.macos-coretext-smoke.v1\n");
    try writer.print("artifact_dir={s}\n", .{artifact_dir});
    try writer.writeAll("resolved_appearance=true\n");
    try writer.print("requested_font_family={s}\n", .{appearance.font.family});
    try writer.print("requested_font_size={d:.1}\n", .{@as(f64, @floatCast(appearance.font.size))});
    try writer.print("requested_font_size_px={d}\n", .{fontSizePxForAtlas(appearance.font.size)});
    try writer.print("font_resolved={}\n", .{smoke_status.font_resolved});
    try writer.print("requested_font_matched={d}\n", .{native.requested_font_matched});
    try writer.print("shaped_text={}\n", .{smoke_status.shaped_text});
    try writer.print("fallback_observed={}\n", .{smoke_status.fallback_observed});
    try writer.print("glyph_rasterized={}\n", .{smoke_status.glyph_rasterized});
    try writer.writeAll("ui_note=coretext_font_shape_and_cpu_raster_no_window_no_metal_no_texture\n");
    try writer.writeAll("probe=ascii_cjk_emoji\n");
    try writer.print("native_status={d}\n", .{native.status});
    try writer.print("primary_font_found={d}\n", .{native.primary_font_found});
    try writer.print("line_created={d}\n", .{native.line_created});
    try writer.print("run_count={d}\n", .{native.run_count});
    try writer.print("glyph_count={d}\n", .{native.glyph_count});
    try writer.print("fallback_run_count={d}\n", .{native.fallback_run_count});
    try writer.print("ascii_glyph_present={d}\n", .{native.ascii_glyph_present});
    try writer.print("cjk_glyph_present={d}\n", .{native.cjk_glyph_present});
    try writer.print("emoji_glyph_present={d}\n", .{native.emoji_glyph_present});
    try writer.print("missing_glyph_count={d}\n", .{native.missing_glyph_count});
    try writer.print("glyph_record_count={d}\n", .{native.glyph_record_count});
    try writer.print("glyph_record_overflow={d}\n", .{native.glyph_record_overflow});
    try writer.print("font_identity_ready={}\n", .{glyph_frame_probe.font_identity_ready});
    try writer.print("font_identity_count={d}\n", .{glyph_frame_probe.font_identity_count});
    try writer.print("raster_width={d}\n", .{native.raster_width});
    try writer.print("raster_height={d}\n", .{native.raster_height});
    try writer.print("raster_non_clear_pixels={d}\n", .{native.raster_non_clear_pixels});
    try writer.print("raster_failures={d}\n", .{native.raster_failures});
    try writer.print("atlas_keys_ready={}\n", .{glyph_frame_probe.atlas_keys_ready});
    try writer.print("atlas_drawable_glyph_count={d}\n", .{glyph_frame_probe.drawable_glyph_count});
    try writer.print("atlas_entry_count={d}\n", .{glyph_frame_probe.entry_count});
    try writer.print("atlas_upload_candidates={d}\n", .{glyph_frame_probe.upload_candidates});
    try writer.print("atlas_upload_bytes={d}\n", .{glyph_frame_probe.upload_bytes});
    try writer.print("atlas_color_glyph_count={d}\n", .{glyph_frame_probe.color_glyph_count});
    try writer.print("glyph_frame_ready={}\n", .{glyph_frame_probe.glyph_frame_ready});
    try writer.print("glyph_frame_glyph_count={d}\n", .{glyph_frame_probe.glyph_count});
    try writer.print("glyph_frame_upload_count={d}\n", .{glyph_frame_probe.upload_count});
    try writer.print("glyph_frame_reused_count={d}\n", .{glyph_frame_probe.reused_count});
    try writer.print("glyph_frame_evicted_count={d}\n", .{glyph_frame_probe.evicted_count});
    try writer.print("glyph_frame_fallback_count={d}\n", .{glyph_frame_probe.fallback_count});
    try writer.print("glyph_frame_replacement_count={d}\n", .{glyph_frame_probe.replacement_count});
    try writer.writeAll("renderer_input=coretext_shaped_glyph_run_list\n");
    try writer.print("renderer_frame_prepared={}\n", .{glyph_frame_probe.renderer_frame_prepared});
    try writer.print("renderer_frame_consistent={}\n", .{glyph_frame_probe.renderer_frame_consistent});
    try writer.print("renderer_surface_cols={d}\n", .{glyph_frame_probe.renderer_surface_cols});
    try writer.print("renderer_surface_rows={d}\n", .{glyph_frame_probe.renderer_surface_rows});
    try writer.print("renderer_glyph_uv_ready={}\n", .{glyph_frame_probe.renderer_glyph_uv_ready});
    try writer.print("renderer_glyph_raster_ready={}\n", .{glyph_frame_probe.renderer_glyph_raster_ready});
    try writer.print("renderer_rasterizer={s}\n", .{glyph_frame_probe.renderer_rasterizer});
    try writer.print("renderer_glyph_raster_upload_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_upload_count});
    try writer.print("renderer_glyph_raster_skipped_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_skipped_count});
    try writer.print("renderer_glyph_raster_error_skip_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_error_skip_count});
    try writer.print("renderer_glyph_raster_zero_ink_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_zero_ink_count});
    try writer.print("renderer_glyph_raster_non_clear_pixels={d}\n", .{glyph_frame_probe.renderer_glyph_raster_non_clear_pixels});
    try writer.print("renderer_glyph_raster_byte_count={d}\n", .{glyph_frame_probe.renderer_glyph_raster_byte_count});
    try writer.print("renderer_draw_cells={d}\n", .{glyph_frame_probe.renderer_draw_cells});
    try writer.print("renderer_draw_overlays={d}\n", .{glyph_frame_probe.renderer_draw_overlays});
    try writer.print("renderer_shaper={s}\n", .{glyph_frame_probe.renderer_shaper});
    try writer.writeAll("drawlist_input=terminal_core_draw_list\n");
    try writer.print("drawlist_frame_prepared={}\n", .{draw_list_probe.renderer_frame_prepared});
    try writer.print("drawlist_frame_consistent={}\n", .{draw_list_probe.renderer_frame_consistent});
    try writer.print("drawlist_font_identity_count={d}\n", .{draw_list_probe.font_identity_count});
    try writer.print("drawlist_surface_cols={d}\n", .{draw_list_probe.renderer_surface_cols});
    try writer.print("drawlist_surface_rows={d}\n", .{draw_list_probe.renderer_surface_rows});
    try writer.print("drawlist_draw_cells={d}\n", .{draw_list_probe.renderer_draw_cells});
    try writer.print("drawlist_draw_overlays={d}\n", .{draw_list_probe.renderer_draw_overlays});
    try writer.print("drawlist_glyph_count={d}\n", .{draw_list_probe.glyph_count});
    try writer.print("drawlist_fallback_count={d}\n", .{draw_list_probe.fallback_count});
    try writer.print("drawlist_glyph_raster_ready={}\n", .{draw_list_probe.renderer_glyph_raster_ready});
    try writer.print("drawlist_glyph_raster_upload_count={d}\n", .{draw_list_probe.renderer_glyph_raster_upload_count});
    try writer.print("drawlist_glyph_raster_error_skip_count={d}\n", .{draw_list_probe.renderer_glyph_raster_error_skip_count});
    try writer.print("drawlist_renderer_shaper={s}\n", .{draw_list_probe.renderer_shaper});
    try writer.print("drawlist_renderer_rasterizer={s}\n", .{draw_list_probe.renderer_rasterizer});
    // 같은 설정의 반복 shape가 face를 하나도 다시 만들지 않는지. 판정은 face_builds_delta가 소유한다.
    try writer.print("face_cache_reused={}\n", .{face_cache_probe.reused});
    try writer.print("face_cache_first_call_face_builds={d}\n", .{face_cache_probe.first_call_face_builds});
    try writer.print("face_cache_face_builds_delta={d}\n", .{face_cache_probe.face_builds_delta});
    try writer.print("face_cache_hits_delta={d}\n", .{face_cache_probe.hits_delta});
    try writer.print("face_cache_misses_delta={d}\n", .{face_cache_probe.misses_delta});
    try writer.print("face_cache_min_first_call_face_builds={d}\n", .{face_cache_probe.min_first_call_face_builds});
    try writer.print("face_cache_first_status={d}\n", .{face_cache_probe.first_status});
    try writer.print("face_cache_second_status={d}\n", .{face_cache_probe.second_status});
    try writer.print("face_cache_entries={d}\n", .{face_cache_probe.entries});
    // 셰이핑 경로가 메모리를 새는지 직접 잰다. face 캐시 카운터는 "만든 것을 놓아줬나"를 모른다.
    try writer.print("shape_leak_measured={}\n", .{shape_leak_probe.measured});
    try writer.print("shape_leak_within_limit={}\n", .{shape_leak_probe.within_limit});
    try writer.print("shape_leak_iterations={d}\n", .{shape_leak_probe.iterations});
    try writer.print("shape_leak_delta_bytes={d}\n", .{shape_leak_probe.delta_bytes});
    try writer.print("shape_leak_limit_bytes={d}\n", .{shape_leak_probe.limit_bytes});
    try writer.print("shape_leak_status={d}\n", .{shape_leak_probe.status});
    // probe build가 던진 Zig error를 summary로 남겨, native 신호가 정상이어도 제품 후보 경계
    // (shaper/raster/frame 조립)에서 실패한 경우를 artifact만 보고 분리할 수 있게 한다.
    try writer.print("fixed_probe_error={s}\n", .{if (fixed_probe_error) |err| @errorName(err) else "none"});
    try writer.print("drawlist_probe_error={s}\n", .{if (draw_list_probe_error) |err| @errorName(err) else "none"});
    try writer.print("primary_font_name={s}\n", .{coretext_probe.cStringField(&native.primary_font_name)});
    try writer.print("first_fallback_font_name={s}\n", .{coretext_probe.cStringField(&native.first_fallback_font_name)});

    return output.toOwnedSlice();
}

const GlyphFrameProbe = struct {
    font_identity_ready: bool,
    font_identity_count: usize,
    atlas_keys_ready: bool,
    glyph_frame_ready: bool,
    drawable_glyph_count: usize,
    entry_count: usize,
    upload_candidates: usize,
    upload_bytes: usize,
    color_glyph_count: usize,
    glyph_count: usize,
    upload_count: usize,
    reused_count: usize,
    evicted_count: usize,
    fallback_count: usize,
    replacement_count: usize,
    renderer_frame_prepared: bool,
    renderer_frame_consistent: bool,
    renderer_surface_cols: u16,
    renderer_surface_rows: u16,
    renderer_glyph_uv_ready: bool,
    renderer_glyph_raster_ready: bool,
    renderer_rasterizer: []const u8,
    renderer_glyph_raster_upload_count: usize,
    renderer_glyph_raster_skipped_count: usize,
    renderer_glyph_raster_error_skip_count: usize,
    renderer_glyph_raster_zero_ink_count: usize,
    renderer_glyph_raster_non_clear_pixels: usize,
    renderer_glyph_raster_byte_count: usize,
    renderer_draw_cells: usize,
    renderer_draw_overlays: usize,
    renderer_shaper: []const u8 = renderer_probe_shaper,
};

fn buildGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
) !GlyphFrameProbe {
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    return buildGlyphFrameProbeWithRasterizer(
        allocator,
        appearance,
        native,
        records,
        &font_registry,
        coretext_raster.CoreTextGlyphRasterizer{
            .appearance = appearance,
            .font_registry = &font_registry,
            .rasterize_glyph = maru_macos_coretext_smoke_rasterize_glyph,
        },
        coretext_raster.CoreTextGlyphRasterizer.name,
    );
}

fn buildGlyphFrameProbeWithRasterizer(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
    font_registry: *renderer.FontIdentityRegistry,
    rasterizer: anytype,
    rasterizer_name: []const u8,
) !GlyphFrameProbe {
    const shape_complete = hasNativeShapeFields(native);
    if (!shape_complete) return emptyGlyphFrameProbe(rasterizer_name);

    // 이 단계는 아직 제품 CoreText bitmap을 Metal cell renderer에 연결하지 않는다. 대신
    // CoreText가 준 실제 font_id/glyph_id 후보를 Maru의 제품 renderer state 계약인
    // `ShapedGlyphRecord -> GlyphRunList -> RendererState -> RenderFrame` 경로에 태운다.
    // 그래야 다음 Metal text draw에서 "폰트는 됐는데 frame/atlas/UV/raster 준비가 안 됐다"
    // 같은 원인을 summary로 분리할 수 있다.
    var coretext_records: std.ArrayList(coretext_probe.CoreTextGlyphRecord) = .empty;
    defer coretext_records.deinit(allocator);
    try coretext_records.ensureTotalCapacity(allocator, records.len);
    for (records) |*record| {
        coretext_records.appendAssumeCapacity(coretext_probe.coreTextGlyphRecord(record));
    }

    const probe_surface = coretext_shaper.deriveProbeSurfaceFromCoreTextGlyphs(coretext_records.items);
    var shaped = try coretext_shaper.buildGlyphRunListFromCoreTextGlyphs(
        allocator,
        coretext_records.items,
        renderer.textConfigFromFontSize(appearance.font.size, 1),
        probe_surface,
        font_registry,
    );
    defer shaped.deinit(allocator);
    var probe_draw_list = try coretext_shaper.buildProbeDrawListFromCoreTextGlyphs(
        allocator,
        coretext_records.items,
        probe_surface,
    );
    var probe_draw_list_owned = true;
    errdefer if (probe_draw_list_owned) probe_draw_list.deinit(allocator);

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();

    var frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
        allocator,
        probe_draw_list,
        shaped.runs,
        rasterizer,
    );
    probe_draw_list_owned = false;
    defer frame.deinit(allocator);

    return glyphFrameProbeFromRenderFrame(
        font_registry,
        frame,
        &renderer_state,
        shaped.color_glyph_count,
        rasterizer_name,
        renderer_probe_shaper,
    );
}

fn buildDrawListGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
) !GlyphFrameProbe {
    // 이 경로는 fixed CoreText probe 문자열이 아니라 실제 TerminalCore snapshot에서 나온
    // DrawList를 CoreText runtime shaper로 넘긴다. 아직 Metal smoke 입력으로 쓰지는 않지만,
    // 다음 PR에서 probe-derived surface를 제거하기 전에 제품 shaper 경계를 독립적으로
    // 검증하기 위한 세로 슬라이스다.
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    core.clearDirty();
    try core.write("Maru 한");

    var draw_list = try renderer.buildDrawList(allocator, core.snapshot());
    var draw_list_owned = true;
    errdefer if (draw_list_owned) draw_list.deinit(allocator);

    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    var shaped = try shaper.shape(allocator, draw_list, &font_registry);
    defer shaped.deinit(allocator);

    var renderer_state = renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
        .appearance = appearance,
        .font_registry = &font_registry,
        .rasterize_glyph = maru_macos_coretext_smoke_rasterize_glyph,
    };
    var frame = try renderer_state.buildFrameFromGlyphRunListWithRasterizer(
        allocator,
        draw_list,
        shaped.runs,
        rasterizer,
    );
    draw_list_owned = false;
    defer frame.deinit(allocator);

    return glyphFrameProbeFromRenderFrame(
        &font_registry,
        frame,
        &renderer_state,
        shaped.color_glyph_count,
        coretext_raster.CoreTextGlyphRasterizer.name,
        coretext_shaper.CoreTextDrawListShaper.name,
    );
}

fn glyphFrameProbeFromRenderFrame(
    font_registry: *const renderer.FontIdentityRegistry,
    frame: renderer.RenderFrame,
    renderer_state: *const renderer.RendererState,
    color_glyph_count: usize,
    rasterizer_name: []const u8,
    shaper_name: []const u8,
) GlyphFrameProbe {
    // 제품 RenderFrame의 prepared/consistent/UV/raster/draw 신호는 renderer가 단일 출처로
    // 소유한다(frame_probe). 이 smoke가 같은 gate를 손으로 다시 조립하면 glyph text/metal
    // smoke와 schema가 갈라지고(예: prepared의 glyph_count>0 절 누락) GlyphFrameStats가 바뀔
    // 때 한 곳만 빠뜨린다. 그래서 같은 renderFrameStats 계약을 그대로 쓴다.
    const render_stats = renderer.renderFrameStats(frame, renderer_state.atlas.entryCount());

    const probe: GlyphFrameProbe = .{
        .font_identity_ready = font_registry.count() > 0,
        .font_identity_count = font_registry.count(),
        .atlas_keys_ready = frame.glyph_frame.stats.glyph_count > 0 and
            renderer_state.atlas.entryCount() > 0,
        .glyph_frame_ready = frame.glyph_frame.glyphs.len == frame.glyph_frame.stats.glyph_count and
            frame.glyph_frame.stats.glyph_count > 0,
        .drawable_glyph_count = frame.glyph_frame.stats.glyph_count,
        .entry_count = renderer_state.atlas.entryCount(),
        .upload_candidates = frame.glyph_frame.stats.upload_count,
        .upload_bytes = frame.glyph_frame.stats.upload_bytes,
        .color_glyph_count = color_glyph_count,
        .glyph_count = frame.glyph_frame.stats.glyph_count,
        .upload_count = frame.glyph_frame.stats.upload_count,
        .reused_count = frame.glyph_frame.stats.reused_count,
        .evicted_count = frame.glyph_frame.stats.evicted_count,
        .fallback_count = frame.glyph_frame.stats.fallback_count,
        .replacement_count = frame.glyph_frame.stats.replacement_count,
        .renderer_frame_prepared = render_stats.prepared(),
        .renderer_frame_consistent = render_stats.consistent,
        .renderer_surface_cols = render_stats.surface_cols,
        .renderer_surface_rows = render_stats.surface_rows,
        .renderer_glyph_uv_ready = render_stats.glyph_uv_ready,
        .renderer_glyph_raster_ready = render_stats.glyph_raster_ready,
        .renderer_rasterizer = rasterizer_name,
        .renderer_glyph_raster_upload_count = render_stats.glyph_raster_upload_count,
        .renderer_glyph_raster_skipped_count = render_stats.glyph_raster_skipped_count,
        .renderer_glyph_raster_error_skip_count = render_stats.glyph_raster_error_skip_count,
        .renderer_glyph_raster_zero_ink_count = render_stats.glyph_raster_zero_ink_count,
        .renderer_glyph_raster_non_clear_pixels = frame.glyph_raster_frame.stats.non_clear_pixels,
        .renderer_glyph_raster_byte_count = render_stats.glyph_raster_byte_count,
        .renderer_draw_cells = render_stats.draw_cells,
        .renderer_draw_overlays = render_stats.draw_overlays,
        .renderer_shaper = shaper_name,
    };
    return probe;
}

fn buildTestGlyphFrameProbe(
    allocator: std.mem.Allocator,
    appearance: config.ResolvedAppearance,
    native: NativeCoreTextSmokeResult,
    records: []const NativeGlyphRecord,
) !GlyphFrameProbe {
    // 단위 계약 테스트는 임의 glyph id를 쓰므로 CoreText native rasterizer에 묶이면
    // OS font implementation detail에 따라 흔들린다. 테스트에서는 fake rasterizer를
    // 명시 주입하고, 실제 native rasterizer는 `mise run macos-coretext-smoke`에서 검증한다.
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    return buildGlyphFrameProbeWithRasterizer(
        allocator,
        appearance,
        native,
        records,
        &font_registry,
        renderer.FakeGlyphRasterizer{},
        "fake_glyph_rasterizer",
    );
}

fn emptyGlyphFrameProbe(rasterizer_name: []const u8) GlyphFrameProbe {
    return .{
        .font_identity_ready = false,
        .font_identity_count = 0,
        .atlas_keys_ready = false,
        .glyph_frame_ready = false,
        .drawable_glyph_count = 0,
        .entry_count = 0,
        .upload_candidates = 0,
        .upload_bytes = 0,
        .color_glyph_count = 0,
        .glyph_count = 0,
        .upload_count = 0,
        .reused_count = 0,
        .evicted_count = 0,
        .fallback_count = 0,
        .replacement_count = 0,
        .renderer_frame_prepared = false,
        .renderer_frame_consistent = false,
        .renderer_surface_cols = 0,
        .renderer_surface_rows = 0,
        .renderer_glyph_uv_ready = false,
        .renderer_glyph_raster_ready = false,
        .renderer_rasterizer = rasterizer_name,
        .renderer_glyph_raster_upload_count = 0,
        .renderer_glyph_raster_skipped_count = 0,
        .renderer_glyph_raster_error_skip_count = 0,
        .renderer_glyph_raster_zero_ink_count = 0,
        .renderer_glyph_raster_non_clear_pixels = 0,
        .renderer_glyph_raster_byte_count = 0,
        .renderer_draw_cells = 0,
        .renderer_draw_overlays = 0,
    };
}

fn fontSizePxForAtlas(font_size: f32) u16 {
    return renderer.textConfigFromFontSize(font_size, 1).font_size_px;
}

fn shapedGlyphRunForTest(
    allocator: std.mem.Allocator,
    record: NativeGlyphRecord,
    font_size: f32,
) !renderer.ShapedGlyphRunList {
    // 테스트가 CoreText private helper의 세부 구현에 직접 매달리지 않도록, native probe
    // record도 제품 renderer의 neutral adapter를 거쳐 cache key까지 확인한다.
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaped = [_]coretext_probe.CoreTextGlyphRecord{coretext_probe.coreTextGlyphRecord(&record)};
    const surface = coretext_shaper.deriveProbeSurfaceFromCoreTextGlyphs(&shaped);
    return coretext_shaper.buildGlyphRunListFromCoreTextGlyphs(
        allocator,
        &shaped,
        renderer.textConfigFromFontSize(font_size, 1),
        surface,
        &font_registry,
    );
}

fn writeSummary(io: std.Io, summary: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, artifact_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = artifact_dir ++ "/coretext.summary.txt",
        .data = summary,
        .flags = .{ .truncate = true },
    });
}

test {
    // coretext_smoke는 bridge에서 extern fn만 개별 alias(maru_macos_coretext_*)해 bridge 컨테이너가
    // 분석되지 않는다 — 그러면 CellMetricsResult ABI 가드 등 bridge가 소유한 native 계약 test가 이
    // coretext 계약 묶음(test-macos-coretext-smoke)에서 조용히 누락된다(coretext_raster는 타입을 직접
    // 써서 이미 수집된다). 컨테이너를 명시 참조해 bridge의 test를 함께 끌어온다.
    _ = coretext_bridge;
}

test "macOS CoreText smoke summary reports shaping atlas and raster boundary" {
    // native CoreText를 호출하지 않는 테스트에서도 summary 계약은 고정한다.
    // 그래야 폰트 스택 실패와 artifact 포맷 변경을 서로 다른 문제로 다룰 수 있다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.requested_font_matched = 1;
    native.line_created = 1;
    native.run_count = 3;
    native.glyph_count = 8;
    native.fallback_run_count = 2;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;
    native.glyph_rasterized = 1;
    native.raster_width = 512;
    native.raster_height = 128;
    native.raster_non_clear_pixels = 42;
    native.raster_failures = 0;
    @memcpy(native.primary_font_name[0.."Menlo-Regular".len], "Menlo-Regular");
    @memcpy(native.first_fallback_font_name[0.."AppleColorEmoji".len], "AppleColorEmoji");

    const records = [_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
        nativeGlyphRecordForTest(.{
            .native_font_id = 2,
            .glyph_id = 20,
            .string_index = 5,
            .category = .cjk,
            .fallback = true,
            .font_name = "AppleSDGothicNeo-Regular",
        }),
        nativeGlyphRecordForTest(.{
            .native_font_id = 3,
            .glyph_id = 30,
            .string_index = 7,
            .category = .emoji,
            .fallback = true,
            .font_name = "AppleColorEmoji",
        }),
    };
    const appearance = try config.resolveAppearance(.{});
    const glyph_frame_probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    var draw_list_probe = glyph_frame_probe;
    draw_list_probe.renderer_shaper = coretext_shaper.CoreTextDrawListShaper.name;
    draw_list_probe.renderer_rasterizer = coretext_raster.CoreTextGlyphRasterizer.name;
    const summary = try renderSummary(
        std.testing.allocator,
        appearance,
        deriveSmokeStatus(native),
        native,
        glyph_frame_probe,
        draw_list_probe,
        .{
            .reused = true,
            .covered = true,
            .shaped = true,
            .first_call_face_builds = 4,
            .min_first_call_face_builds = 2,
            .hits_delta = 1,
            .misses_delta = 0,
            .face_builds_delta = 0,
            .entries = 2,
        },
        .{ .measured = true, .within_limit = true, .iterations = 4000, .delta_bytes = 1024, .limit_bytes = 4 * 1024 * 1024, .status = 0 },
        null,
        null,
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.macos-coretext-smoke.v1\n") != null);
    // face 재사용 신호는 summary 계약의 일부다 — 필드가 사라지면 회귀 게이트도 조용히 사라진다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "face_cache_reused=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "face_cache_face_builds_delta=0\n") != null);
    // 첫 호출이 face를 실제로 만들었다는 증거도 계약이다 — 없으면 위 delta 0이 게이트가 죽은 것과 구분되지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "face_cache_first_call_face_builds=4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "face_cache_min_first_call_face_builds=2\n") != null);
    // 누수 게이트 신호도 summary 계약이다 — 필드가 사라지면 게이트가 조용히 사라진다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "shape_leak_within_limit=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "shape_leak_iterations=4000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "face_cache_misses_delta=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "fixed_probe_error=none\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_probe_error=none\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "resolved_appearance=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_family=JetBrains Mono\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_size=14.0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_size_px=14\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_resolved=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "requested_font_matched=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "shaped_text=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "fallback_observed=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_rasterized=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "probe=ascii_cjk_emoji\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "run_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_count=8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "ascii_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "cjk_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "emoji_glyph_present=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "missing_glyph_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_record_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_record_overflow=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_identity_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "font_identity_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_width=512\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_height=128\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_non_clear_pixels=42\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "raster_failures=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_keys_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_drawable_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_entry_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_upload_candidates=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "atlas_color_glyph_count=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_reused_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_evicted_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_fallback_count=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "glyph_frame_replacement_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_input=coretext_shaped_glyph_run_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_frame_consistent=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_cols=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_surface_rows=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_uv_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_rasterizer=fake_glyph_rasterizer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_skipped_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_error_skip_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_zero_ink_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_non_clear_pixels=588\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_glyph_raster_byte_count=2352\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_cells=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_draw_overlays=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "renderer_shaper=coretext_shaped_records\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_input=terminal_core_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_frame_prepared=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_frame_consistent=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_font_identity_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_surface_cols=9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_surface_rows=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_draw_cells=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_draw_overlays=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_fallback_count=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_ready=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_upload_count=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_glyph_raster_error_skip_count=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_renderer_shaper=coretext_draw_list\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "drawlist_renderer_rasterizer=coretext_glyph_rasterizer\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "primary_font_name=Menlo-Regular\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "first_fallback_font_name=AppleColorEmoji\n") != null);
}

test "CoreText draw-list shaper normalizes synthesized box glyph to codepoint cache key" {
    // 회귀 고정(#1·#2·#6): box-drawing(U+2500)은 폰트(JetBrains Mono)가 실제 글리프를 줘도(glyph!=0)
    // rasterizer가 코드포인트로 합성하므로, 네이티브 셰이퍼가 glyph_id=0으로 정규화해야 한다. 그래야
    // cache_key가 codepoint로 키잉돼 primary/fallback이 한 슬롯에 모이고(중복 슬롯 방지), 폰트 glyph_id로
    // 키잉돼 다른 글자와 겹치는 aliasing이 사라진다. 옛 `synth=(glyph==0)&&…` 조건은 폰트 보유 시 일반
    // 경로로 새서 cache_key.glyph_id가 폰트 glyph_id가 됐다 → 이 테스트가 그 회귀를 잡는다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("──"); // U+2500 BOX DRAWINGS LIGHT HORIZONTAL ×2

    var draw_list = try renderer.buildDrawList(allocator, core.snapshot());
    defer draw_list.deinit(allocator);

    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();

    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    var shaped = try shaper.shape(allocator, draw_list, &font_registry);
    defer shaped.deinit(allocator);

    var box_seen: usize = 0;
    for (shaped.runs.glyphs) |glyph| {
        if (glyph.codepoint != 0x2500) continue;
        box_seen += 1;
        // glyph_id는 폰트 보유와 무관하게 0으로 정규화(합성은 codepoint로 그림 → 폰트 glyph 무의미).
        try std.testing.expectEqual(@as(renderer.GlyphId, 0), glyph.glyph_id);
        // cache_key는 codepoint로 키잉(font_id=0 합성 전용 공간, 폰트 glyph_id와 안 겹침).
        try std.testing.expectEqual(@as(renderer.GlyphId, 0x2500), glyph.cache_key.glyph_id);
        try std.testing.expectEqual(@as(renderer.FontId, 0), glyph.cache_key.font_id);
    }
    // drawable한 box glyph가 run에 들어왔어야 한다(글리프가 필터에서 죽었다면 box_seen==0 → 보더 안 보임).
    try std.testing.expect(box_seen >= 1);
}

test "CoreText draw-list shaper composes an NFD Hangul cluster identically to its precomposed syllable (HG3a)" {
    // 회귀 고정(HG3a): macOS 파일명 NFD '한' = 초성 U+1112 + 중성 U+1161 + 종성 U+11AB가 한 셀
    // cluster로 저장된다. DrawList가 grapheme_pool에 [중성, 종성]을 싣고 셰이퍼가 base 뒤에 붙여
    // CoreText에 넘기면, CoreText가 셋을 합성해 완성형 '한'(U+D55C)과 **같은 음절 글리프**를 낸다.
    // 풀 경로가 종성을 못 넘기면 NFD는 '하'로 합성돼 glyph_id가 달라진다 — 그 회귀를 폰트 무관하게 잡는다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };

    // col 0의 drawable 글리프(font_id, glyph_id)를 뽑는 헬퍼 — NFD와 완성형을 같은 방식으로 비교.
    const Probe = struct {
        fn glyphAtCol0(a: std.mem.Allocator, sh: coretext_shaper.CoreTextDrawListShaper, bytes: []const u8) !struct { font_id: renderer.FontId, glyph_id: renderer.GlyphId } {
            var core = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 1 });
            defer core.deinit();
            core.clearDirty();
            try core.write(bytes);
            var dl = try renderer.buildDrawList(a, core.snapshot());
            defer dl.deinit(a);
            var fr = renderer.FontIdentityRegistry.init(a);
            defer fr.deinit();
            var shaped = try sh.shape(a, dl, &fr);
            defer shaped.deinit(a);
            for (shaped.runs.glyphs) |g| {
                if (g.col == 0) return .{ .font_id = g.font_id, .glyph_id = g.glyph_id };
            }
            return error.NoGlyphAtCol0;
        }
    };

    const nfd = try Probe.glyphAtCol0(allocator, shaper, "\u{1112}\u{1161}\u{11AB}"); // NFD 한
    const nfc = try Probe.glyphAtCol0(allocator, shaper, "\u{D55C}"); // 완성형 한

    // 같은 음절로 합성됐다 — 풀이 종성까지 온전히 CoreText에 전달됐다는 증거(아니면 '하'로 달라짐).
    try std.testing.expectEqual(nfc.font_id, nfd.font_id);
    try std.testing.expectEqual(nfc.glyph_id, nfd.glyph_id);
    try std.testing.expect(nfd.glyph_id != 0); // notdef가 아니라 실제 음절 글리프
}

test "CoreText draw-list shaper composes an NFD Hangul chrome label identically to its precomposed form (CG1)" {
    // 회귀 고정(CG1 — docs/grapheme-clustering.md §3.1a): chrome 셀 텍스트(파일 트리 행·사이드바 카드·탭 제목)도
    // 터미널과 **같은 cluster 모델**을 쓴다. 위 HG3a 테스트가 터미널 DrawList로 증명한 것을 chrome DrawList로
    // 증명한다 — 같은 셰이퍼·같은 풀이므로, chrome 생산자가 cluster를 제대로 싣는지만이 변수다.
    //
    // 왜 중요한가: chrome은 codepoint 1개 = 셀 1개라 NFD 파일명이 자모로 흩어져 보였다(사용자 제보). 유닛 테스트는
    // DrawCell/풀 구조만 보므로, "CoreText가 실제로 한 음절 글리프로 합성하는가"는 이 실-CoreText 경로에서만 닫힌다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    const dim: terminal.Color = .{ .rgb = .{ .r = 0x70, .g = 0x70, .b = 0x70 } };

    // 파일 트리 행 라벨을 chrome이 그리는 그대로 DrawList로 만들고, 첫 글자 글리프를 뽑는다.
    const Probe = struct {
        fn labelGlyph(a: std.mem.Allocator, sh: coretext_shaper.CoreTextDrawListShaper, fg: terminal.Color, label: []const u8) !struct { font_id: renderer.FontId, glyph_id: renderer.GlyphId } {
            const rows = [_]maru.session.file_tree.Row{.{ .file = .{
                .path = "/tmp/probe.md",
                .label = label,
                .depth = 0,
                .supported = true,
                .open = false,
                .active = false,
                .dirty = false,
                .external_change = false,
                .symlink = false,
            } }};
            var dl = try coretext_frame_builder.buildFileTreeDrawList(a, &rows, null, 0, 1, 40, fg, fg, null);
            defer dl.deinit(a);
            var fr = renderer.FontIdentityRegistry.init(a);
            defer fr.deinit();
            var shaped = try sh.shape(a, dl, &fr);
            defer shaped.deinit(a);
            // 행 앞머리는 마커·아이콘이라 라벨 첫 글자는 그 뒤에 온다 — 한글 음절(또는 완성형)만 골라 첫 개를 쓴다.
            for (shaped.runs.glyphs) |g| {
                const cp = g.codepoint;
                if (cp == 0x1112 or cp == 0xD55C) return .{ .font_id = g.font_id, .glyph_id = g.glyph_id };
            }
            return error.NoHangulGlyph;
        }
    };

    const nfd = try Probe.labelGlyph(allocator, shaper, dim, "\u{1112}\u{1161}\u{11AB}.md"); // NFD 한.md
    const nfc = try Probe.labelGlyph(allocator, shaper, dim, "\u{D55C}.md"); // 완성형 한.md

    // 같은 음절 글리프 ⇒ 같은 래스터 픽셀. 풀이 중성·종성을 못 넘겼다면 '하' 또는 초성 단독으로 달라진다.
    try std.testing.expectEqual(nfc.font_id, nfd.font_id);
    try std.testing.expectEqual(nfc.glyph_id, nfd.glyph_id);
    try std.testing.expect(nfd.glyph_id != 0); // notdef가 아니라 실제 음절 글리프
}

test "CoreText draw-list shaper shapes a ZWJ emoji family into a color glyph (GB11)" {
    // 회귀 고정(GB11): mode 2027에서 👨‍👩‍👧(👨 ZWJ 👩 ZWJ 👧)가 한 셀 cluster로 저장되고, DrawList가
    // grapheme_pool로 전체 시퀀스를 CoreText에 넘기면 컬러(AppleColorEmoji) 글리프로 셰이핑된다.
    // producer가 ZWJ 가족을 안 묶었으면(셀 분리) 또는 풀이 시퀀스를 못 넘기면 col 0이 비거나 단색이 된다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("\x1b[?2027h"); // grapheme cluster mode — 가족이 한 셀로 묶인다
    try core.write("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"); // 👨‍👩‍👧

    var dl = try renderer.buildDrawList(allocator, core.snapshot());
    defer dl.deinit(allocator);
    var fr = renderer.FontIdentityRegistry.init(allocator);
    defer fr.deinit();
    var shaped = try shaper.shape(allocator, dl, &fr);
    defer shaped.deinit(allocator);

    // col 0이 컬러 글리프로 셰이핑됐다 — 풀로 전달된 ZWJ 시퀀스를 CoreText가 이모지(컬러)로 그린다.
    var saw_color_at_col0 = false;
    for (shaped.runs.glyphs) |g| {
        if (g.col == 0 and g.cache_key.color_glyph_kind == .color) saw_color_at_col0 = true;
    }
    try std.testing.expect(saw_color_at_col0);
}

test "CoreText draw-list shaper marks keycap and VS16 clusters as color, plain text as monochrome" {
    // 회귀 고정: color_glyph_kind는 base 코드포인트 category가 아니라 **실제 셰이핑된 run 폰트의 컬러 여부**
    // (sbix/COLR)로 정해야 한다. base category(0x1F300~1FAFF만 Emoji)로 판정하면 키캡(base ASCII '2')·
    // VS16 표현(❤️ base U+2764)이 mono로 잘못 판정돼 컬러 글리프가 회색 틴트로 렌더된다(HG3b 회귀). CoreText가
    // AppleColorEmoji로 셰이핑한 cluster는 color여야 하고, 일반 텍스트('A')는 monochrome이어야 한다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };

    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 16, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("\x1b[?2027h"); // grapheme cluster mode
    try core.write("2\u{FE0F}\u{20E3}"); // 키캡 2️⃣ (base '2' + VS16 + U+20E3)
    try core.write(" \u{2764}\u{FE0F}"); // ❤️ (base U+2764 + VS16)
    try core.write(" A"); // 일반 텍스트 — mono여야 한다

    var dl = try renderer.buildDrawList(allocator, core.snapshot());
    defer dl.deinit(allocator);
    var fr = renderer.FontIdentityRegistry.init(allocator);
    defer fr.deinit();
    var shaped = try shaper.shape(allocator, dl, &fr);
    defer shaped.deinit(allocator);

    var keycap_color = false; // base '2' (0x32) cluster
    var heart_color = false; // base ❤ (0x2764) cluster
    var saw_ascii_a = false;
    var ascii_a_color = false; // base 'A' (0x41)
    for (shaped.runs.glyphs) |g| {
        const is_color = g.cache_key.color_glyph_kind == .color;
        switch (g.codepoint) {
            '2' => if (is_color) {
                keycap_color = true;
            },
            0x2764 => if (is_color) {
                heart_color = true;
            },
            'A' => {
                saw_ascii_a = true;
                if (is_color) ascii_a_color = true;
            },
            else => {},
        }
    }
    try std.testing.expect(keycap_color); // 키캡 = AppleColorEmoji = color
    try std.testing.expect(heart_color); // ❤️ = AppleColorEmoji = color
    try std.testing.expect(saw_ascii_a); // 'A' glyph가 실제로 났는지(테스트 자체 건전성)
    try std.testing.expect(!ascii_a_color); // 일반 텍스트는 monochrome
}

test "CoreText smoke does not treat fallback as required for shaping" {
    // fallback 관측은 유용한 진단 신호지만, OS와 설치 폰트에 따라 run 분리가 달라질 수
    // 있다. smoke의 pass/fail은 "글자를 glyph run으로 만들 수 있는가"에 둔다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 1;
    native.glyph_count = 8;
    native.fallback_run_count = 0;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 1;
    native.glyph_record_overflow = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);
    try std.testing.expect(!status.fallback_observed);
}

test "CoreText smoke keeps shaping and rasterization failures separate" {
    // CoreText smoke는 font shaping과 glyph bitmap rasterization을 같은 native 호출에서
    // 실행하지만, 두 신호를 섞으면 디버깅이 어려워진다. 이 테스트는 "shape는 성공,
    // CPU bitmap은 실패"인 상태가 summary에서 분리되어 보이는지 고정한다.
    var native = emptyNativeResult();
    native.status = 6;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;
    native.glyph_rasterized = 0;
    native.raster_width = 512;
    native.raster_height = 128;
    native.raster_non_clear_pixels = 0;
    native.raster_failures = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);

    // raster가 실패해도(shape는 성공) GlyphFrame 준비는 raster와 독립이다.
    // 그래서 glyph_frame_ready와 atlas_keys_ready는 그대로 true여야 한다. 이렇게 분리해야
    // summary만 보고 "shape/frame 준비는 됐고 CPU raster에서 막혔다"를 집어낼 수 있다.
    const appearance = try config.resolveAppearance(.{});
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &[_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
    });
    try std.testing.expect(probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.font_identity_count);
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
    try std.testing.expect(probe.renderer_frame_prepared);
    try std.testing.expect(probe.renderer_frame_consistent);
    try std.testing.expect(probe.renderer_glyph_uv_ready);
    try std.testing.expect(probe.renderer_glyph_raster_ready);
}

test "CoreText smoke treats native glyph-buffer overflow as incomplete shaping" {
    // status 7은 한 run의 glyph 수가 native 고정 버퍼를 넘어 그 run을 기록하지 못한
    // 상태다. 먼저 기록된 다른 run만 보면 shape가 성공한 것처럼 보일 수 있으므로,
    // summary가 shape를 성공으로 잘못 보고하지 않는지 고정한다. 그래야 화면이 빈 원인을
    // "shape는 됐는데 다음 단계 실패"로 오인하지 않는다.
    var native = emptyNativeResult();
    native.status = 7;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;
    native.glyph_record_overflow = 0;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(!status.shaped_text);
    try std.testing.expect(!status.glyph_rasterized);

    // GlyphFrame 준비도 overflow run을 정상 shape로 취급하면 안 된다.
    const appearance = try config.resolveAppearance(.{});
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &[_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
    });
    try std.testing.expect(!probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 0), probe.font_identity_count);
    try std.testing.expect(!probe.atlas_keys_ready);
    try std.testing.expect(!probe.glyph_frame_ready);
    try std.testing.expect(!probe.renderer_frame_prepared);
    try std.testing.expect(!probe.renderer_frame_consistent);
}

test "CoreText smoke rejects missing font or empty glyph output" {
    // 성공 조건이 너무 느슨하면 "CoreText를 호출했다"만으로 shaped_text=true가 된다.
    // 실제 텍스트 렌더링의 선행 조건은 font, line, run, glyph가 모두 존재하는 것이다.
    var no_font = emptyNativeResult();
    no_font.status = 1;
    try std.testing.expect(!deriveSmokeStatus(no_font).shaped_text);

    var no_glyph = emptyNativeResult();
    no_glyph.status = 0;
    no_glyph.primary_font_found = 1;
    no_glyph.line_created = 1;
    no_glyph.run_count = 1;
    no_glyph.glyph_count = 0;
    try std.testing.expect(!deriveSmokeStatus(no_glyph).shaped_text);
}

test "CoreText smoke rejects probe categories that map to missing glyphs" {
    // 리뷰에서 지적된 핵심 회귀다. glyph_count는 .notdef도 세므로 ASCII만 성공한
    // 상태를 "CJK/emoji도 shape됐다"고 부르면 안 된다.
    var missing_cjk = emptyNativeResult();
    missing_cjk.status = 0;
    missing_cjk.primary_font_found = 1;
    missing_cjk.line_created = 1;
    missing_cjk.run_count = 2;
    missing_cjk.glyph_count = 8;
    missing_cjk.ascii_glyph_present = 1;
    missing_cjk.cjk_glyph_present = 0;
    missing_cjk.emoji_glyph_present = 1;
    missing_cjk.missing_glyph_count = 1;
    missing_cjk.glyph_record_count = 2;
    try std.testing.expect(!deriveSmokeStatus(missing_cjk).shaped_text);

    var missing_emoji = missing_cjk;
    missing_emoji.cjk_glyph_present = 1;
    missing_emoji.emoji_glyph_present = 0;
    try std.testing.expect(!deriveSmokeStatus(missing_emoji).shaped_text);
}

test "CoreText smoke glyph frame probe filters spaces and requires records" {
    // CoreText는 space도 glyph run에 포함할 수 있지만, atlas가 bitmap으로 굽는 대상은
    // 실제로 그릴 glyph다. space record는 glyph upload에서 제외하되 probe DrawList에는
    // 남긴다. 그래서 renderer surface는 drawable glyph만이 아니라 space 위치까지 덮어야
    // 한다. 그렇지 않으면 col=4 space가 width=1 surface 밖에 놓이는 거짓 artifact가 된다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.line_created = 1;
    native.run_count = 1;
    native.glyph_count = 2;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.glyph_record_count = 2;

    const records = [_]NativeGlyphRecord{
        nativeGlyphRecordForTest(.{ .glyph_id = 10, .string_index = 0, .category = .ascii }),
        nativeGlyphRecordForTest(.{ .glyph_id = 5, .string_index = 4, .category = .space }),
    };

    const appearance = try config.resolveAppearance(.{ .font = .{ .family = "Menlo", .size = 16.4 } });
    const probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    try std.testing.expect(probe.font_identity_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.font_identity_count);
    try std.testing.expect(probe.atlas_keys_ready);
    try std.testing.expect(probe.glyph_frame_ready);
    try std.testing.expectEqual(@as(usize, 1), probe.drawable_glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.entry_count);
    try std.testing.expectEqual(@as(usize, 1), probe.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), probe.upload_count);
    try std.testing.expect(probe.renderer_frame_prepared);
    try std.testing.expectEqual(@as(u16, 5), probe.renderer_surface_cols);
    try std.testing.expectEqual(@as(u16, 1), probe.renderer_surface_rows);
    try std.testing.expectEqualStrings("fake_glyph_rasterizer", probe.renderer_rasterizer);
    try std.testing.expectEqual(@as(usize, 1), probe.renderer_glyph_raster_upload_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_skipped_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_error_skip_count);
    try std.testing.expectEqual(@as(usize, 0), probe.renderer_glyph_raster_zero_ink_count);
    try std.testing.expectEqual(@as(usize, 256), probe.renderer_glyph_raster_non_clear_pixels);
    try std.testing.expectEqual(@as(usize, 1024), probe.renderer_glyph_raster_byte_count);
    try std.testing.expectEqual(@as(usize, 2), probe.renderer_draw_cells);
    try std.testing.expectEqualStrings(renderer_probe_shaper, probe.renderer_shaper);

    native.glyph_record_overflow = 1;
    const overflow_probe = try buildTestGlyphFrameProbe(std.testing.allocator, appearance, native, &records);
    try std.testing.expect(!overflow_probe.atlas_keys_ready);
    try std.testing.expect(!overflow_probe.glyph_frame_ready);
    try std.testing.expect(!overflow_probe.renderer_frame_prepared);
}

test "CoreText smoke rounds resolved font size into atlas cache key" {
    // CoreText는 fractional size를 받을 수 있지만, 현재 Maru glyph cache key는 정수 px를
    // 쓴다. bridge smoke가 hardcoded 14로 되돌아가면 설정 변경 후 atlas miss/hit 진단이
    // 틀어지므로 resolved size가 cache key까지 들어가는지 고정한다.
    const appearance = try config.resolveAppearance(.{ .font = .{ .family = "Menlo", .size = 16.6 } });
    var shaped = try shapedGlyphRunForTest(
        std.testing.allocator,
        nativeGlyphRecordForTest(.{ .glyph_id = 42, .string_index = 0, .category = .ascii }),
        appearance.font.size,
    );
    defer shaped.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), shaped.runs.glyphs.len);
    try std.testing.expectEqual(@as(u16, 17), shaped.runs.glyphs[0].cache_key.font_size_px);
}

test "CoreText smoke treats requested font mismatch as a diagnostic fallback" {
    // JetBrains Mono는 기본 요청값이지만 사용자의 Mac에 없을 수 있다. 그 경우 앱을
    // 시작하지 못하게 하기보다 system monospace fallback으로 화면을 띄우고,
    // requested_font_matched=0을 남겨 설정/폰트 문제를 숨기지 않는다.
    var native = emptyNativeResult();
    native.status = 0;
    native.primary_font_found = 1;
    native.requested_font_matched = 0;
    native.line_created = 1;
    native.run_count = 2;
    native.glyph_count = 8;
    native.ascii_glyph_present = 1;
    native.cjk_glyph_present = 1;
    native.emoji_glyph_present = 1;
    native.missing_glyph_count = 0;
    native.glyph_record_count = 3;

    const status = deriveSmokeStatus(native);
    try std.testing.expect(status.font_resolved);
    try std.testing.expect(status.shaped_text);
}

// ── S2: 글리프 선명도 측정(slot-stretch 폐기 근거) ─────────────────────────────
// anti-alias 번짐의 proxy로 "partial-alpha 픽셀 비율"(0<α<255 픽셀 / ink 픽셀)을 쓴다. 글리프가
// 또렷할수록 solid(α=255) 픽셀이 많고 partial이 적다. 셀 크기로 굽고 GPU에서 확대하면(slot-stretch)
// bilinear 보간이 edge를 번지게 해 partial이 늘고, 목표 px로 직접 래스터하면 native AA만 남아 적다.

const InkMetrics = struct {
    ink: usize = 0,
    partial: usize = 0,
    solid: usize = 0,
    top: usize = 0,
    bottom: usize = 0,
    left: usize = 0,
    right: usize = 0,

    fn partialRatio(self: InkMetrics) f64 {
        if (self.ink == 0) return 0;
        return @as(f64, @floatFromInt(self.partial)) / @as(f64, @floatFromInt(self.ink));
    }
};

fn measureInk(pixels: []const u8, w: u32, h: u32) InkMetrics {
    var m: InkMetrics = .{ .top = h, .left = w };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const a = pixels[(@as(usize, y) * w + x) * 4 + 3];
            if (a == 0) continue;
            m.ink += 1;
            if (a == 255) {
                m.solid += 1;
            } else {
                m.partial += 1;
            }
            if (y < m.top) m.top = y;
            if (y > m.bottom) m.bottom = y;
            if (x < m.left) m.left = x;
            if (x > m.right) m.right = x;
        }
    }
    return m;
}

fn rasterizeGlyphToBuf(
    allocator: std.mem.Allocator,
    rasterizer: coretext_raster.CoreTextGlyphRasterizer,
    run: renderer.GlyphRun,
    w: u32,
    h: u32,
) ![]u8 {
    // atlas를 거치지 않고 직접 slot을 구성해 원하는 px로 래스터한다(rasterize는 slot.width/height_px만
    // native에 넘긴다). 합성 글리프(braille 등)는 codepoint로, 폰트 글리프는 glyph_id로 그려진다.
    const slot = renderer.AtlasSlot{
        .id = 1,
        .key = run.cache_key,
        .x_px = 0,
        .y_px = 0,
        .width_px = w,
        .height_px = h,
        .upload_bytes = @as(usize, w) * @as(usize, h) * 4,
        .generation = 0,
    };
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    _ = try rasterizer.rasterize(.{
        .run = run,
        .slot = slot,
        .pixels = pixels,
        .bytes_per_row = @as(usize, w) * 4,
    });
    return pixels;
}

fn bilinearUpscaleRgba(
    allocator: std.mem.Allocator,
    src: []const u8,
    sw: u32,
    sh: u32,
    dw: u32,
    dh: u32,
) ![]u8 {
    // 현재 GPU slot-stretch(maru_fill_cell_quad의 중앙 기준 affine scale + bilinear sampling)의 CPU
    // 등가. dw,dh > 1 가정(고정 측정 크기). edge를 보간으로 번지게 해 partial 픽셀을 늘린다.
    const dst = try allocator.alloc(u8, @as(usize, dw) * @as(usize, dh) * 4);
    errdefer allocator.free(dst);
    const xr = @as(f64, @floatFromInt(sw - 1)) / @as(f64, @floatFromInt(dw - 1));
    const yr = @as(f64, @floatFromInt(sh - 1)) / @as(f64, @floatFromInt(dh - 1));
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const fy = @as(f64, @floatFromInt(dy)) * yr;
        const y0: u32 = @intFromFloat(fy);
        const y1 = @min(y0 + 1, sh - 1);
        const ty = fy - @as(f64, @floatFromInt(y0));
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const fx = @as(f64, @floatFromInt(dx)) * xr;
            const x0: u32 = @intFromFloat(fx);
            const x1 = @min(x0 + 1, sw - 1);
            const tx = fx - @as(f64, @floatFromInt(x0));
            var c: usize = 0;
            while (c < 4) : (c += 1) {
                const p00 = @as(f64, @floatFromInt(src[(@as(usize, y0) * sw + x0) * 4 + c]));
                const p10 = @as(f64, @floatFromInt(src[(@as(usize, y0) * sw + x1) * 4 + c]));
                const p01 = @as(f64, @floatFromInt(src[(@as(usize, y1) * sw + x0) * 4 + c]));
                const p11 = @as(f64, @floatFromInt(src[(@as(usize, y1) * sw + x1) * 4 + c]));
                const top = p00 * (1 - tx) + p10 * tx;
                const bot = p01 * (1 - tx) + p11 * tx;
                dst[(@as(usize, dy) * dw + dx) * 4 + c] = @intFromFloat(@round(top * (1 - ty) + bot * ty));
            }
        }
    }
    return dst;
}

test "글리프 목표크기 직접 래스터가 1.7× 확대보다 선명하다(partial-alpha 비율) — slot-stretch 폐기 근거" {
    // S2 자동 회귀 측정(방어): 헤더 아이콘 ◧(U+25E7)을 ① 목표 px로 직접 native 래스터 vs ② 셀 크기로
    // 래스터 후 1.7× bilinear 확대(현재 GPU slot-stretch의 CPU 모사)했을 때 anti-alias 번짐(partial)
    // 비율을 비교한다. 직접 래스터가 더 낮아야(=선명) S3(목표크기 래스터)의 효과가 증명된다. 절대값이
    // 아니라 상대 비교라 설치 폰트에 독립적이다.
    const allocator = std.testing.allocator;
    const appearance = try config.resolveAppearance(.{});

    // ◧을 실제 native 셰이퍼로 shape해 GlyphRun(font_id/glyph_id)을 얻는다(box-drawing 회귀와 같은 경로).
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    core.clearDirty();
    try core.write("\u{25E7}");
    var draw_list = try renderer.buildDrawList(allocator, core.snapshot());
    defer draw_list.deinit(allocator);
    var font_registry = renderer.FontIdentityRegistry.init(allocator);
    defer font_registry.deinit();
    const shaper = coretext_shaper.CoreTextDrawListShaper{
        .appearance = appearance,
        .shape_draw_list = maru_macos_coretext_shape_draw_list,
    };
    var shaped = try shaper.shape(allocator, draw_list, &font_registry);
    defer shaped.deinit(allocator);

    var glyph_run: ?renderer.GlyphRun = null;
    for (shaped.runs.glyphs) |g| {
        if (g.col == 0) {
            glyph_run = g;
            break;
        }
    }
    try std.testing.expect(glyph_run != null);

    const rasterizer = coretext_raster.CoreTextGlyphRasterizer{
        .appearance = appearance,
        .font_registry = &font_registry,
        .rasterize_glyph = maru_macos_coretext_smoke_rasterize_glyph,
    };

    const cell_w: u32 = 9;
    const cell_h: u32 = 18;
    const baked_w: u32 = 15; // ≈ cell × 1.7
    const baked_h: u32 = 31;

    // ① 목표 px로 직접 래스터(S3가 만들 것).
    const baked = try rasterizeGlyphToBuf(allocator, rasterizer, glyph_run.?, baked_w, baked_h);
    defer allocator.free(baked);
    // ② 셀 크기로 래스터 후 1.7× bilinear 확대(현재 GPU slot-stretch의 CPU 모사).
    const cell = try rasterizeGlyphToBuf(allocator, rasterizer, glyph_run.?, cell_w, cell_h);
    defer allocator.free(cell);
    const stretched = try bilinearUpscaleRgba(allocator, cell, cell_w, cell_h, baked_w, baked_h);
    defer allocator.free(stretched);

    const m_baked = measureInk(baked, baked_w, baked_h);
    const m_stretched = measureInk(stretched, baked_w, baked_h);

    try std.testing.expect(m_baked.ink > 0);
    try std.testing.expect(m_stretched.ink > 0);
    // 핵심 단언: 목표 px 직접 래스터가 1.7× 확대보다 anti-alias 번짐(partial-alpha 비율)이 뚜렷이 적다
    // (=선명). slot-stretch 폐기의 근거. 측정 실측: 직접 ≈0.33 vs 확대 ≈0.69(JetBrains Mono/system).
    // 폰트별로 절대값은 달라도 "직접 < 확대"는 보간 특성상 항상 성립하므로 상대 비교로 고정한다.
    try std.testing.expect(m_baked.partialRatio() < m_stretched.partialRatio());

    // 대조: grip ⠿(U+283F)는 합성 글리프(braille_glyph)라 셀 크기에 coverage로 직접 그려져 이미 선명하다.
    // partial 비율을 참고 출력해, stretch 흐림 문제가 폰트 글리프(◧)에만 있고 합성 글리프엔 없음을 보인다.
    const braille_run = renderer.GlyphRun{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = 0x283F,
        .font_id = 0,
        .glyph_id = 0,
        .cache_key = .{ .font_id = 0, .glyph_id = 0x283F, .font_size_px = 14, .device_scale = 1 },
    };
    const braille_cell = try rasterizeGlyphToBuf(allocator, rasterizer, braille_run, cell_w, cell_h);
    defer allocator.free(braille_cell);
    const m_braille = measureInk(braille_cell, cell_w, cell_h);
    try std.testing.expect(m_braille.ink > 0);
    // 합성 글리프(braille)는 셀 크기에 coverage로 직접 그려져 anti-alias 번짐이 거의 없다(실측 ratio≈0.0).
    // 폰트 글리프 ◧의 stretch 흐림(≈0.69)과 달리 grip ⠿는 선명화가 불필요함을 못박는다(maru 코드라 폰트 독립).
    try std.testing.expect(m_braille.partialRatio() < 0.1);
}
