# `src/renderer`

렌더러 내부 구현이 커질 때 사용하는 폴더다.

`src/renderer.zig`는 renderer facade로 유지한다. 초기 구현은 macOS Metal-first로 두되, `RenderSnapshot -> DrawList` 계약을 먼저 고정해서 future WebGPU backend가 같은 입력을 소비할 수 있게 한다.

font/layout 쪽은 `DrawList -> GlyphRunList` 계약을 먼저 고정한다. 실제 CoreText나 atlas texture는 그 뒤에 붙이고, fake font backend 기반 테스트는 기본 CI에서 deterministic하게 돌린다.

glyph atlas는 먼저 `GlyphCacheKey -> AtlasSlot` domain cache 계약으로 둔다. 실제 GPU texture 좌표나 rasterization은 아직 없지만, hit/miss, upload byte 후보, eviction, invalidation reason은 이 폴더 아래에서 테스트한다. glyph atlas, frame stats, render snapshot 변환은 이 폴더 아래에 책임별로 둔다.
