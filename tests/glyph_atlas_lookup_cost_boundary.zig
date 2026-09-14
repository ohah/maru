//! 글리프 캐시 **조회 비용이 캐시 크기에 비례하지 않는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-14 실측. 앱 메인 스레드 표본 3997 개 중 **706 개(17.7%)** 가
//! `app_session.AppSession.placeAndDistribute` 한 곳이었고, 그 안에서 자식 호출로 나가는 몫은
//! 사실상 없었다(self 97.9%). 즉 인라인된 몸통이 전부였다.
//!
//! 오프셋이 **+1464~+1580 의 120 바이트 창**에 몰려 있어 그 자리를 디스어셈블했다.
//!
//! ```text
//! +1464  add   x13, x13, #0x40      ← 64 바이트 stride 로 배열을 훑는다
//! +1468  subs  x14, x14, #0x1       ← 원소 개수만큼 카운트다운
//! +1496  cmp   w28, w10, uxth       ┐
//! +1528  cmeq.4h v0, v0, v3         │ 키를 필드별로 비교
//! +1572  and   w10, w9, #0x7        │
//! +1592  tst   w11, #0x1010101      ┘
//! +1596  b.ne  0x1006cd978          ← 어긋나면 루프 처음으로
//! ```
//!
//! 64 바이트는 `AtlasSlot` 의 크기이고, 비교 패턴은 `GlyphCacheKey` 와 정확히 맞는다 —
//! u16 필드 일곱 개(스칼라 셋 + `cmeq.4h` 로 넷), u32 둘, `cell_width: u3`(`#0x7`),
//! bool·enum 꼬리 네 바이트(`#0x1010101`). `GlyphAtlas.findSlot` 의 선형 탐색이었다.
//!
//! 이 조회는 **글리프 하나마다 · 페인마다 · 프레임마다** 일어난다. 캐시가 1024 항목까지 차므로
//! 비용이 화면이 붐빌수록 커졌다.
//!
//! ## 무엇을 재는가
//!
//! **시간을 재지 않는다.** CI 러너 부하에 흔들리는 게이트는 빨간 불을 무시하게 만든다. 대신
//! `GlyphAtlas` 의 키 동등성 판정이 몇 번 불렸는지(`probe_count`)를 센다 — 결정론적이고,
//! 구현이 무엇이든 「크기와 무관한가」를 직접 말한다.
//!
//! - **하한 1**: 키를 한 번은 실제로 비교해야 한다. 0 이면 동등성이 이 경로를 안 거친 것이다
//!   (예: 선형 탐색으로 되돌림) — 재는 대상 자체가 사라진 것이라 통과시키면 안 된다.
//! - **상한 4**: 항목이 1024 개여도 비교는 상수 번이다. 선형 탐색이면 수백~1024 가 된다.

const std = @import("std");
const maru = @import("maru");

const glyph_atlas = maru.renderer.glyph_atlas;
const glyph_layout = maru.renderer.glyph_layout;

fn keyFor(glyph_id: u32) glyph_layout.GlyphCacheKey {
    return .{
        .font_id = 1,
        .glyph_id = glyph_id,
        .font_size_px = 14,
        .device_scale = 1,
        .cell_width_px = 8,
        .cell_height_px = 16,
        .cell_width = 1,
    };
}

fn runFor(key: glyph_layout.GlyphCacheKey) glyph_layout.GlyphRun {
    return .{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = 'A',
        .font_id = key.font_id,
        .glyph_id = key.glyph_id,
        .style = .{},
        .cache_key = key,
    };
}

test "판정: 캐시 조회 비용이 캐시 크기에 비례하지 않는다" {
    const max_slots = 1024;
    var atlas = glyph_atlas.GlyphAtlas.init(std.testing.allocator, .{
        .max_slots = max_slots,
        .atlas_width_px = 8192,
        .atlas_height_px = 8192,
        .max_atlas_width_px = 8192,
        .max_atlas_height_px = 8192,
    });
    defer atlas.deinit();

    var i: u32 = 0;
    while (i < max_slots) : (i += 1) {
        _ = try atlas.ensureGlyph(runFor(keyFor(i)));
    }
    // 축출이 돌았다면 «가장 먼저 넣은 키» 가 이미 없다 — 그러면 아래가 조회가 아니라 삽입을 잰다.
    try std.testing.expectEqual(@as(usize, max_slots), atlas.entryCount());

    // 맨 앞과 맨 뒤 — 선형 탐색에서 최선과 최악. 둘 다 상수여야 «크기와 무관» 이다.
    for ([_]u32{ 0, max_slots - 1 }) |glyph_id| {
        glyph_atlas.probe_count = 0;
        const lookup = try atlas.ensureGlyph(runFor(keyFor(glyph_id)));
        try std.testing.expect(!lookup.uploaded); // 적중이어야 조회를 잰 것이다
        try std.testing.expectEqual(keyFor(glyph_id), lookup.slot.key);

        try std.testing.expect(glyph_atlas.probe_count >= 1);
        try std.testing.expect(glyph_atlas.probe_count <= 4);
    }
}
