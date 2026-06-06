# `src/renderer`

렌더러 내부 구현이 커질 때 사용하는 폴더다.

`src/renderer.zig`는 renderer facade로 유지한다. 초기 구현은 macOS Metal-first로 두되, `RenderSnapshot -> DrawList` 계약을 먼저 고정해서 future WebGPU backend가 같은 입력을 소비할 수 있게 한다.

`DrawList`는 glyph cell과 overlay command를 분리한다. cursor와 underline은 glyph bitmap이 아니라 draw-time overlay이므로 atlas cache key나 glyph bitmap에 섞지 않는다.

font/layout 쪽은 `DrawList -> GlyphRunList` 계약을 먼저 고정한다. 실제 CoreText나 atlas texture는 그 뒤에 붙이고, fake font backend 기반 테스트는 기본 CI에서 deterministic하게 돌린다.

glyph atlas는 먼저 `GlyphCacheKey -> AtlasSlot` domain cache 계약으로 둔다. 실제 GPU texture 좌표나 rasterization은 아직 없지만, hit/miss, upload byte 후보, eviction, invalidation reason은 이 폴더 아래에서 테스트한다. glyph atlas, frame stats, render snapshot 변환은 이 폴더 아래에 책임별로 둔다.

`GlyphFrame`은 `GlyphRunList`와 `GlyphAtlas`를 묶어 backend가 소비할 frame 준비 결과를 만든다. 이 타입은 실제 Metal texture를 만들지 않고, 각 glyph가 어떤 atlas slot을 쓸지와 이번 frame에서 어떤 upload 후보가 생겼는지만 기록한다. cursor/underline overlay도 여기까지 보존해서, 다음 backend가 glyph bitmap과 draw-time overlay를 다시 해석하지 않게 한다.

`RendererState`는 frame 사이에 살아남는 renderer 소유 상태다. 현재는 `GlyphAtlas`를 오래 들고 가며 `RenderSnapshot -> DrawList -> GlyphRunList -> GlyphFrame`을 한 번에 준비한다. app host와 future Metal backend는 이 facade만 호출해야 하고, atlas reuse나 font layout 정책을 각자 다시 구현하면 안 된다.

현재 atlas의 선형 scan/FIFO eviction은 실제 제품 성능 정책이 아니라 contract-stage placeholder다. 실제 texture atlas가 붙을 때 HashMap, LRU/clock, overflow check, texture limit 처리는 [폰트 전략](../../docs/font-strategy.md)의 구현 메모를 다시 확인하고 별도 PR에서 결정한다.
