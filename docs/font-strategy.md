# 폰트 전략

이 문서는 Maru가 터미널 글자를 어떻게 해석하고, 어떤 폰트를 고르고, GPU 렌더러에 어떤 형태로 넘길지 정한다. 렌더링 backend 선택은 [렌더러 전략](renderer-strategy.md)을 따르며, 이 문서는 그중 폰트와 glyph 책임만 다룬다.

## 결론

초기 Maru는 **macOS-first + CoreText-first**로 간다.

```text
RenderSnapshot
-> DrawList
-> TextLayout / FontResolver / TextShaper
-> GlyphRunList
-> GlyphAtlas
-> GlyphFrame
-> GlyphQuadFrame
-> GlyphRasterFrame
-> Metal backend
```

이 선택의 의도는 외부 런타임 의존성을 늘리지 않고 macOS 시스템 폰트 스택을 먼저 믿는 것이다. 터미널에서 어려운 문제는 GPU API 자체보다, cell width, fallback, emoji, glyph cache, atlas upload, dirty region이 서로 어긋나지 않게 만드는 것이다.

## 책임 경계

`TerminalCore`:

- raw bytes와 escape sequence를 해석해 cell/grid/snapshot을 만든다.
- 폰트 파일, CoreText, glyph id, atlas 좌표를 모른다.
- cursor 위치와 cell width 같은 터미널 의미를 소유한다.

`TextLayout`:

- `DrawList`의 cell을 `GlyphRunList` 후보로 바꾼다. `DrawList`는 `RenderSnapshot`에서 온 renderer 입력 계약이다.
- 같은 terminal cell이 같은 layout 결과를 만들도록 deterministic한 입력 계약을 유지한다.
- CoreText 타입을 public contract로 노출하지 않는다.
- native shaper가 준 font id/glyph id 후보는 `coretext_font.zig`의 제품 후보 adapter를 거쳐 `ShapedGlyphRecord` 같은 renderer 중립 record로 한 번 바꾼 뒤 `GlyphRunList`를 만든다. smoke native ABI record는 먼저 `coretext_probe.zig`가 `coretext_font.zig` 입력으로 바꾼다. `coretext_shaper.zig`는 이 record 배열과 `ShapedGlyphSurface`를 받아 제품 `GlyphRunList`로 만드는 macOS 제품 후보 shaper 경계다. 이 adapter들이 필요한 이유는 CoreText smoke, future 제품 CoreText shaper, future HarfBuzz shaper가 같은 frame 준비 계약을 쓰게 하기 위해서다. 제품 shaper 경로는 `DrawList`의 size/cursor/dirty/overlay metadata를 `ShapedGlyphSurface`로 함께 넘겨야 한다. probe처럼 record 위치만 보고 metadata를 유도하면 실제 terminal surface의 빈 행, cursor, overlay가 사라질 수 있다.

`FontResolver / TextShaper`:

- config의 font family를 실제 macOS font face로 해석한다.
- primary font에 없는 문자는 fallback font를 찾는다.
- codepoint cluster를 glyph id와 font id로 바꾼다.
- native font face는 실제 glyph bitmap을 만들 drawable record일 때만 `FontIdentityRegistry`를 거쳐 renderer의 안정적인 `FontId`로 바꾼다.

`FontIdentityRegistry`:

- CoreText의 `CTFont` 같은 platform 타입을 renderer public contract에 노출하지 않는다.
- 대신 PostScript name 같은 안정적인 face identity를 소유 복사하고, 같은 face는 같은 `FontId`로 재사용한다.
- glyph id는 font face 안에서만 의미가 있으므로 `font_id + glyph_id` 쌍으로만 cache key와 raster request를 만든다.
- 제품 CoreText backend는 shaping 때 drawable glyph에 대해 registry에 intern한 font identity를 rasterizer 조회에도 그대로 사용해야 한다. CoreText smoke도 이 경계를 미리 검증하기 위해 native record의 PostScript name을 registry에 intern하고, smoke 전용 rasterizer가 같은 PostScript name으로 CTFont를 만든다. codepoint만 보고 fallback font를 다시 고르면, 같은 glyph id를 다른 font에 그리는 wrong-glyph 버그가 생긴다. 공백처럼 rasterizer에 도달하지 않는 record는 registry count에 넣지 않는다.

`GlyphAtlas`:

- glyph bitmap을 texture atlas에 캐시한다.
- atlas miss, upload byte, eviction 같은 성능 관측 값을 남긴다.
- renderer backend가 바뀌어도 cache key와 glyph run 의미가 흔들리지 않게 한다.
- 초기 구현은 `GlyphCacheKey -> AtlasSlot` domain cache/placement 계약, `GlyphRunList -> GlyphFrame` 준비 계약, `GlyphFrame -> GlyphQuadFrame` UV 변환 계약, `GlyphFrame -> GlyphRasterFrame` upload byte/skip 계약, macOS CoreText CPU bitmap smoke, CPU bitmap -> Metal texture upload smoke를 먼저 고정한다. 실제 atlas texture packing과 제품 shader sampling은 macOS backend 단계에서 붙인다.

`Metal backend`:

- `GlyphQuadFrame`, `GlyphRasterFrame`, atlas texture만 소비한다.
- 문자열을 직접 shaping하거나 fallback을 찾지 않는다.

## v1 정책

v1에서 지원하는 것:

- macOS CoreText 기반 font resolve.
- primary monospaced font family 설정.
- 설정한 font가 없을 때 system monospaced font로 fallback.
- font size, device scale factor, bold/italic style을 반영한 glyph cache.
- ASCII, 한글/CJK wide character, 기본 emoji fallback을 깨지지 않게 처리.
- `RenderSnapshot -> DrawList` deterministic test.
- fake font backend 기반 `DrawList -> GlyphRunList` deterministic test.
- native shaper 후보 기반 `coretext_probe.zig -> coretext_font.zig -> coretext_shaper.zig -> GlyphRunList -> RendererState -> RenderFrame` deterministic test.
- persistent `RendererState` 기반 `DrawList -> GlyphRunList -> GlyphFrame -> GlyphQuadFrame -> GlyphRasterFrame` deterministic test.
- macOS opt-in screenshot/font/raster smoke artifact.

v1에서 약속하지 않는 것:

- proportional font 품질 보장.
- ligature 최적화.
- subpixel positioning 품질 보장.
- 모든 complex script의 완전한 shaping.
- ZWJ 이모지 시퀀스·국기·skin-tone 같은 다중 코드포인트 grapheme의 완전한 폭/표시 정확도.
- 폰트에 해당 face가 없을 때의 합성 bold/italic(faux) 품질.
- box-drawing(U+2500 블록)/Powerline glyph를 cell에 정확히 맞추는 cell-snapping/stretching.
- pixel-perfect golden을 기본 CI에서 강제.
- HarfBuzz, FreeType, fontconfig, DirectWrite 같은 외부/타 플랫폼 폰트 스택 추가.

## FontConfig

초기 config는 단순하게 유지한다.

```text
font.family = "JetBrains Mono"
font.size = 14
```

해석 규칙:

- `family`는 사용자가 원하는 primary monospace family다.
- raw `FontConfig`는 `ResolvedFontRequest`로 먼저 검증한다. 빈 family와 1px 미만 또는 512px 초과 font size는 renderer로 보내지 않는다.
- family가 설치되어 있지 않으면 앱은 죽지 않고 system monospaced font로 fallback한다.
- fallback이 발생하면 debug artifact와 structured log에 남긴다.
- 사용자가 proportional font를 지정해도 v1은 터미널 품질을 보장하지 않는다. 이 경우 경고 artifact를 남기고, cell metric은 primary monospace fallback 기준으로 잡는다.

이 정책의 의도는 설정 실수 때문에 shell이 열리지 않는 일을 막는 것이다. 터미널은 설정이 조금 틀려도 최소한 사용자가 수정할 수 있는 화면을 보여줘야 한다.

## Cell Width와 Font Metric

터미널의 cursor 위치는 font advance가 아니라 terminal cell width 정책이 결정한다.

```text
codepoint / grapheme
-> Unicode width policy
-> terminal cell count
-> layout cell position
-> glyph drawing bounds
```

이 경계가 중요한 이유는 폰트마다 advance가 다르기 때문이다. font metric을 cursor 이동에 직접 쓰면 한글, 이모지, fallback glyph에서 grid가 밀리고 `vim`, `tmux`, `htop` 정렬이 깨진다.

초기 정책:

- ASCII printable은 1 cell.
- East Asian wide 문자는 2 cell.
- combining mark는 이전 cell cluster에 붙인다.
- grapheme cluster는 UAX#29 기준으로 분절하고, ZWJ 시퀀스·국기·skin-tone modifier는 하나의 cluster로 묶어 폭을 width policy로 정한다. 완전한 처리는 fixture로 확장한다.
- ambiguous width(UAX#11 'A')는 기본 1 cell로 시작한다. 로케일/CJK 맥락에서 2 cell이 필요한 경우의 설정화는 구현 전에 다시 논의한다.
- unsupported/ambiguous width는 보수적으로 1 cell로 시작하고 fixture로 확장한다.
- emoji는 표시 폭과 실제 glyph bounds가 다를 수 있으므로, cursor advance는 width policy를 따른다.

wide/combining 처리는 [검증 매트릭스](verification-matrix.md)의 `wide-character(East-Asian width)` 항목과 연결한다. 현재 구현은 최소 width table, continuation cell, combining mark 1개 저장을 제공한다. UAX#11 전체, ambiguous width 설정, ZWJ emoji 폭 처리는 fixture를 추가하며 확장한다.

## Fallback 전략

fallback은 매 frame마다 찾지 않는다.

```text
codepoint cluster
-> primary font 지원 확인
-> fallback font resolve
-> fallback cache
-> glyph id
```

cache key:

```text
cluster
font family request
font size
style
locale hint later
```

fallback cache가 필요한 이유는 대량 로그와 emoji가 섞일 때 CoreText 조회 비용이 hot path로 들어오는 것을 막기 위해서다.

## Glyph Atlas Cache Key

`GlyphAtlas`는 glyph bitmap을 다시 굽지 않기 위해 cache key를 명확히 가져야 한다.

초기 cache key:

```text
font_id
glyph_id
font_size
device_scale_factor
style_flags
color_glyph_kind
```

`style_flags`는 rasterize(glyph bitmap)를 바꾸는 style만 포함한다(bold/italic). underline·strikethrough와 fg/bg 색은 glyph가 아니라 draw-time 오버레이/tint로 처리하므로 cache key에 넣지 않는다(밑줄 유무로 같은 glyph를 중복 캐시하지 않기 위해서다). 코드에서는 `RasterStyleFlags`가 이 경계를 표현하고, `DrawList`는 underline을 glyph cell과 별도 overlay command로 내보낸다.

`font_id`는 임의 증가 숫자가 아니라 `FontIdentityRegistry`가 소유한 face identity를 뜻한다. 이 구분이 필요한 이유는 CoreText의 `CGGlyph` 값이 전역 glyph 번호가 아니라 해당 `CTFont` 안에서만 유효한 번호이기 때문이다. 예를 들어 primary font와 CJK fallback font가 둘 다 glyph id `42`를 낼 수 있지만, 두 bitmap은 서로 다른 atlas entry여야 한다.

이 중 하나라도 빠지면 다음 버그가 난다.

- Retina scale 전환 뒤 흐릿한 glyph가 재사용된다.
- bold/italic glyph가 regular glyph와 섞인다.
- fallback font의 같은 glyph id가 primary font glyph처럼 그려진다.
- emoji color glyph와 monochrome glyph가 같은 atlas slot을 공유한다.

atlas invalidation 조건:

- font family 변경.
- font size 변경.
- device scale factor 변경.
- theme 색상 변경 중 glyph bitmap 자체가 색을 포함하는 경우.
- atlas eviction policy 변경.

현재 domain cache는 invalidation reason과 제거된 slot 수를 남긴다. 이 정보가 있어야 나중에 "왜 frame 전체가 다시 업로드됐는지"를 screenshot이나 성능 숫자만 보고 추측하지 않아도 된다.

현재 atlas 구현 메모:

- combining cluster cache 충돌은 지금 fake backend에서 고치지 않는다. Maru의 cache key는 `glyph_id` 기반이고, cluster가 어떤 `glyph_id`가 되는지는 실제 shaper(CoreText later)의 책임이다. fake backend에서 combining mark를 임의의 새 glyph id로 바꾸면 stub의 편의 구현이 제품 계약처럼 굳을 수 있다.
- 현재 `GlyphAtlas`의 선형 scan, `orderedRemove`, FIFO eviction은 실제 제품 성능 정책이 아니라 contract-stage placeholder다. 이 단계의 목적은 cache hit/miss, upload 후보, eviction 발생, invalidation reason을 검증하는 것이다. 실제 texture atlas 압력이 보이면 HashMap + LRU/clock 같은 정책을 별도 PR에서 사용자와 논의한 뒤 바꾼다.
- 테스트 artifact writer나 index helper를 바로 재사용하지 않는다. test -> production 의존 방향 역전이나 renderer -> observability 내부 구현 의존이 생길 수 있기 때문이다. 공용화가 필요하면 먼저 책임이 맞는 shared module로 승격한다.
- 현재 upload byte 추정은 실제 raster bitmap이 아니므로 overflow 가능성이 작다. 하지만 실제 rasterizer/texture packer가 들어오면 `font_size * scale * bytes_per_pixel`, atlas dimension, backend texture limit은 checked arithmetic과 관측 가능한 error로 검증해야 한다. `assert` 정책은 프로젝트 전역 결정이므로 이 PR에서 renderer만 따로 바꾸지 않는다.
- 기본 unit test의 `GlyphRasterFrame`은 test rasterizer로 RGBA upload byte 계약을 고정한다. 이 단계의 목적은 글자 품질이 아니라, backend가 복사할 contiguous byte buffer, `bytes_offset`, `bytes_per_row`, zero-ink 진단값, 그리고 upload 후보별 skip 이유가 frame 안에 들어오는지 확인하는 것이다. atlas texture 경계 밖 slot은 실제 byte buffer를 만들지 않고 `GlyphRasterSkip`으로 남긴다. 단일 glyph rasterizer 실패도 frame 전체 실패가 아니라 skip으로 남긴다. macOS CoreText smoke와 Metal smoke는 같은 `RendererState -> RenderFrame -> GlyphRasterFrame` 경로에 제품 후보 `coretext_raster.zig` wrapper와 smoke native bridge를 주입해 실제 glyph id/font identity 후보가 native CoreText bitmap byte까지 갈 수 있는지 확인한다. native CoreText raster 구현은 아직 smoke bridge에 있지만, FontId -> PostScript name 조회와 renderer 실패 매핑 정책은 smoke 파일 밖의 제품 후보 경계가 소유한다.
- 현재 raster upload buffer는 tightly-packed row(`bytes_per_row = width * 4`)를 renderer domain의 canonical byte 계약으로 둔다. Metal의 `replaceRegion` 경로는 이 계약을 직접 소비할 수 있다. 미래 WebGPU backend는 `writeTexture`의 `bytesPerRow` 256-byte alignment 요구가 있으므로, backend adapter에서 repack할지 renderer 계약 자체를 padded row로 바꿀지 WebGPU 구현 PR 전에 다시 결정한다. 지금 단계에서 WebGPU 요구를 조용히 가정하면 Metal-first 계약과 테스트 의미가 흐려진다.

## Emoji와 Color Glyph

emoji는 v1에서 "완벽한 typography"가 아니라 "grid를 깨지 않는 표시"가 목표다.

초기 정책:

- emoji width는 terminal width policy가 정한다.
- color glyph는 가능한 경우 별도 `color_glyph_kind`로 cache한다.
- emoji가 렌더링 실패하면 replacement glyph로 표시하고 artifact에 남긴다.
- emoji pixel-perfect 비교는 기본 CI에 넣지 않는다.

이 결정을 보수적으로 두는 이유는 macOS 버전과 Apple Color Emoji 버전에 따라 픽셀 결과가 달라질 수 있기 때문이다.

## Ligature와 Complex Script

ligature는 터미널에서 매력적인 기능이지만 v1 기본 품질 기준으로 넣지 않는다.

이유:

- cursor 위치, selection, hit testing, cell dirty region과 충돌하기 쉽다.
- 사용자는 terminal grid의 예측 가능성을 더 크게 체감한다.
- ligature shaping을 먼저 넣으면 parser/core 버그와 renderer 버그를 구분하기 어려워진다.

나중에 추가하려면 다음 계약이 먼저 필요하다.

- glyph cluster가 여러 cell을 덮는 표현.
- selection/cursor가 cluster 내부에 있을 때의 표시 규칙.
- ligature off 설정.
- DrawList fixture와 screenshot smoke.

## Dirty Region과 폰트

dirty region의 장기 목표는 cell 단위지만, 현재 `TerminalCore`/snapshot 계약은 row 범위(`start_row`/`end_row`)다. 단위와 무관하게 폰트 레이어가 임의로 dirty 범위를 넓히면 안 된다.

예외적으로 다음 상황은 renderer/app layer가 명시적으로 전체 또는 넓은 범위를 dirty 처리할 수 있다.

- font family 변경.
- font size 변경.
- device scale factor 변경.
- atlas eviction으로 기존 atlas 좌표가 무효화된 경우.

이 경우에도 원인은 artifact에 남긴다. 예를 들어 "font size changed, full redraw"처럼 남겨야 나중에 성능 회귀를 추적할 수 있다.

## 검증 전략

기본 `mise run check`에 넣을 수 있는 것:

- fake font backend를 사용한 `DrawList -> GlyphRunList` deterministic test.
- ASCII, CJK, combining mark, emoji replacement에 대한 cell advance test.
- fallback cache가 같은 cluster를 반복 조회하지 않는 unit test.
- glyph atlas cache key가 size/scale/font id와 raster에 영향을 주는 style(bold/italic)을 구분하는 test.
- GPU 없는 `GlyphCacheKey -> AtlasSlot` cache가 hit/miss, upload byte 후보, row-packed texture 좌표 후보, eviction, invalidation reason을 기록하는 test.
- GPU 없는 `GlyphRunList -> GlyphFrame` 준비 test가 atlas slot, upload 후보, eviction, cursor/underline overlay 보존을 기록하는 test.
- GPU 없는 `GlyphFrame -> GlyphQuadFrame` test가 slot pixel rect를 normalized UV로 바꾸고, atlas texture bounds 오류를 backend 전에 실패시키는 test.
- GPU 없는 `GlyphFrame -> GlyphRasterFrame` test가 upload 후보를 contiguous RGBA bytes 또는 명시적 skip으로 바꾸고, zero-ink glyph를 실패가 아닌 진단값으로 남기는 test.
- font 변경이 전체 redraw/invalidation event를 만드는 test.
- raw config의 font/theme/cursor 값이 `ResolvedAppearance`로 검증되는 test.
- renderer가 `TerminalCore`, `PtySession`, platform handle을 직접 import하지 않는 boundary test.
- native shaper 결과를 `ShapedGlyphRecord -> GlyphRunList`로 변환하는 adapter test. 이 테스트는 space/.notdef 필터링, CJK/emoji cell width, fallback/color glyph count, cache key size/scale 전달을 GPU 없이 고정한다. 제품 경로용 adapter는 `ShapedGlyphSurface`를 받아 `DrawList`의 size/cursor/dirty/overlay가 보존되는지도 검증한다.
- 제품 shaper entrypoint test. `RendererState`가 `GlyphRunList`를 직접 받아 `RenderFrame`을 만들 수 있어야 한다. 이 테스트가 필요한 이유는 macOS CoreText 제품 shaper를 fake backend의 `shape(cell)` 모양으로 억지로 끼워 넣지 않고, 줄/런 단위 shaping 결과를 renderer 준비 단계에 넣기 위해서다. 성공하면 `DrawList` ownership은 `RenderFrame`으로 이동하고, 실패하면 caller가 그대로 정리할 수 있어야 한다.

macOS opt-in으로 둘 것:

- `ResolvedAppearance`의 font family/size 요청이 CoreText smoke bridge까지 전달되고, CoreText로 실제 font family를 resolve하는 smoke.
- CoreText가 ASCII/CJK/emoji probe를 glyph run으로 shape하고, 각 probe 구간이 `.notdef`가 아닌 glyph로 매핑되는지 확인하는 smoke.
- CoreText smoke native record의 PostScript name이 `coretext_probe.zig -> coretext_font.zig -> FontIdentityRegistry`를 거쳐 renderer 중립 `ShapedGlyphRecord -> GlyphRunList -> RendererState -> RenderFrame` 경로를 타고, Maru `GlyphAtlas` cache key, UV, `coretext_raster.zig` wrapper가 만든 CoreText raster bytes까지 들어가는 smoke.
- 같은 `CTLine`을 CPU bitmap에 그려 non-clear pixel이 생기는 smoke.
- CoreText CPU bitmap을 Metal texture에 업로드하고 readback 결과가 source bitmap과 같은지 확인하는 smoke.
- CoreText glyph texture를 실제 AppKit/CAMetalLayer 창에서 fragment shader로 샘플링하고, source glyph ink 위치의 drawable pixel이 clear 색이 아닌지 readback하며, 같은 drawable을 PPM screenshot artifact로 남기는 smoke. 이 smoke는 제품 `RendererState -> RenderFrame/GlyphQuadFrame/GlyphRasterFrame` probe도 함께 남겨, visible text smoke가 native fixture 검증으로만 고립되지 않게 한다.
- 제품 `GlyphRasterFrame.uploads/pixels`를 Metal atlas texture에 업로드하고 blit readback으로 source bytes와 일치하는지 확인한 뒤, 같은 atlas texture를 terminal cell shader가 샘플링해 drawable readback 픽셀이 source raster의 non-clear texel과 일치하는지 확인하는 smoke. 이 smoke는 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> RenderFrame -> coretext_raster.zig` 경로를 쓰므로 실제 glyph bitmap이 terminal cell atlas shader까지 이어졌는지 검증한다.
- 설치되지 않은 font가 system monospace fallback으로 가는 smoke.
- Retina scale factor별 atlas smoke.
- 제품 renderer screenshot artifact. macOS Metal smoke는 제품 atlas sampling frame을 `zig-out/maru-macos-metal-smoke/metal-frame.ppm`으로 남기고, live PTY Metal smoke는 controlled PTY output과 AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key event roundtrip이 같은 visible path를 탄 frame을 `zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal-frame.ppm`으로 남긴다. 같은 live PTY Metal smoke는 마지막 frame 뒤 작은 AppKit close delegate callback을 통해 `FrameLoop.closeActiveLivePty -> LivePtyRegistry.closeActive -> LivePtySession.closeAndDetach`도 호출해 app host close lifecycle과 registry mapping 제거 gate를 summary에 남긴다. 기본은 synthetic event이고, opt-in manual mode는 사용자가 직접 누른 `Cmd+B` payload를 같은 path로 검증한다.
- 제품 atlas slot 기반 glyph rasterization pixel comparison.

CoreText/font/raster/upload smoke들은 단계를 나눠 실패 원인을 분리한다. CoreText smoke는 창/GPU 없이 font resolve, shaping, 실제 `TerminalCore -> DrawList` 입력의 CoreText runtime shaping, raster bytes를 확인하고, Metal smoke는 같은 CoreText glyph bytes가 제품 `GlyphQuadFrame/GlyphRasterFrame`을 거쳐 실제 AppKit/CAMetalLayer 창에서 atlas shader sampling되는지 확인하며, 같은 frame을 PPM screenshot artifact로 남긴다. live PTY Metal smoke는 controlled PTY output과 AppKit `keyDown:`에서 얻은 key event를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경로에 태운다. 기본은 자동 synthetic `Cmd+B`이고, opt-in manual mode는 사용자가 직접 누른 `Cmd+B`를 같은 경로에 태운다. glyph text smoke는 별도 fixture texture와 PPM screenshot artifact로 기존 shader sampling 경계를 유지한다. 아직 남은 핵심 한계는 사용자가 지속적으로 조작하는 interactive shell/input loop가 이 renderer loop에 연결되지 않았다는 점이다.

현재 native CoreText DrawList shaper는 cell 단위 경계 검증 단계라 두 가지 알려진 한계가 있다. 첫째, 한 cell이 여러 glyph(base + combining mark, ligature)로 분해되면 그 glyph들이 모두 같은 `(row, col)`에 매핑되어 겹쳐 그려진다. 결합 문자/리거처의 cluster 위치 보정은 line-level shaper 단계로 미룬다. 둘째, 한 cell이라도 `.notdef`(glyph 0)로 매핑되면 native가 실패 status로 닫아 `CoreTextDrawListShapeFailed`로 frame 전체가 실패한다. 즉 폰트+fallback 체인에 없는 코드포인트는 아직 해당 cell만 tofu(`.notdef` placeholder)로 그리는 게 아니라 frame 전체를 떨어뜨린다. 임의의 셸 출력을 받는 단계에서는 이 두 한계를 line-level shaper와 per-cell tofu 대체로 풀어야 한다.

기본 CI에서 pixel-perfect font test를 강제하지 않는 이유는 font stack이 OS 업데이트와 설치 폰트에 영향을 받기 때문이다. 대신 기본 CI는 Maru가 만든 domain data와 cache/invalidation 계약을 검증하고, 실제 픽셀은 opt-in artifact로 추적한다. macOS CoreText smoke는 `ResolvedAppearance`의 font 요청이 native bridge까지 전달되는지, 요청 font가 실제 이름/family와 일치했는지를 `requested_font_matched` 진단값으로 남기는지, CoreText가 준 drawable glyph id/font face 후보가 `coretext_probe.zig -> coretext_font.zig -> FontIdentityRegistry -> coretext_shaper.zig -> GlyphRunList`를 거쳐 제품 `RendererState -> RenderFrame` 준비 계약까지 들어가는지, 실제 `TerminalCore -> DrawList` fixture가 `CoreTextDrawListShaper -> FontIdentityRegistry -> GlyphRunList -> RendererState -> RenderFrame` 경로를 통과하는지, 제품 후보 `coretext_raster.zig` wrapper가 같은 PostScript name으로 smoke native bridge를 호출해 제품 `GlyphRasterFrame` byte buffer를 만들 수 있는지, 같은 `CTLine` CPU bitmap까지 나오는지 확인한다. 이 smoke는 summary에 `font_identity_ready`, `font_identity_count`, `renderer_input=coretext_shaped_glyph_run_list`, `renderer_shaper=coretext_shaped_records`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared`, `renderer_surface_cols/rows`, `renderer_glyph_raster_*`, `drawlist_input=terminal_core_draw_list`, `drawlist_renderer_shaper=coretext_draw_list`, `drawlist_frame_prepared`, `drawlist_glyph_raster_*` 통계를 남긴다. `font_identity_count`는 공백 같은 비-drawable record를 제외하고 실제 rasterizer가 조회할 drawable glyph face 수를 뜻한다. native CoreText raster 구현은 아직 smoke bridge에 있다. probe record 변환 계약은 `coretext_probe.zig` 단위 테스트가 맡고, surface metadata 보존 및 DrawList shaper bridge 계약은 `coretext_shaper.zig` 단위 테스트와 shaped-input `RendererState` unit test가 맡고, rasterizer wrapper 계약은 `coretext_raster.zig` 단위 테스트가 맡는다. `coretext_frame_builder.zig` 단위 테스트는 active surface snapshot이 `CoreTextDrawListShaper -> CoreTextGlyphRasterizer -> RendererState`를 지나 prepared `AppHostFrame`으로 조립되는 계약을 Objective-C 없이 검증한다. glyph texture smoke는 CPU bitmap이 Metal texture에 byte-preserving upload/readback되는지 확인한다. glyph text smoke는 fixture texture가 실제 AppKit/CAMetalLayer 창에서 shader sampling되어 glyph ink pixel로 보이는지 확인하고, PPM screenshot artifact와 제품 `RendererState/RenderFrame` probe 통계도 남긴다. Metal smoke는 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> RenderFrame -> coretext_raster.zig` 경로가 만든 CoreText atlas slot id와 placement 후보를 native 경계까지 전달하고, `GlyphQuadFrame`이 slot pixel rect를 shader UV로 바꿨는지도 `renderer_glyph_uv_ready`로 남긴다. Metal smoke의 `GlyphRasterFrame`은 `coretext_raster.zig` wrapper를 쓰며, upload 후보가 byte buffer 또는 skip으로 회계 처리됐는지는 `renderer_glyph_raster_ready`, `renderer_glyph_raster_upload_count`, `renderer_glyph_raster_skipped_count`로 남긴다. 같은 Metal smoke는 그 `GlyphRasterFrame.uploads/pixels`를 Metal atlas texture에 올리고 readback byte 비교가 성공했을 때 `product_atlas_uploaded=true`, fragment shader가 같은 atlas를 샘플링해 drawable readback이 source raster의 non-clear texel과 일치하고 `atlas_sample_missing_cells=0`일 때 `product_atlas_sampled=true`를 남기며, 전체 drawable screenshot을 `metal-frame.ppm`으로 썼을 때 `screenshot_artifact=true`를 남긴다. live PTY Metal smoke는 controlled PTY output과 AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key event response에서 만든 `DrawList`가 `FrameLoop.tickAfterDrainWithFrameBuilder -> coretext_frame_builder.zig -> CoreText/Metal` path를 타는지 `renderer_input=surface_runtime_live_pty_frame_loop_coretext_render_frame`, `input_source=appkit_keydown_to_app_host_keybinding_resolver`, `native_key_event_source=appkit_synthetic_keydown` 또는 `appkit_manual_keydown`, `app-pty-metal-frame.ppm`으로 확인한다. `glyph_text`는 `product_atlas_sampled`이고 그 frame이 실제 CoreText glyph bytes를 쓴 경우에만 참인 증거 기반 라벨이다. upload가 0개인 all-skip frame은 upload/readback 실패가 아니라 sample source 누락으로 기록한다. `AtlasSlot`은 backend UV를 위한 deterministic `x_px/y_px` 좌표 후보를 가진다. manual mode는 물리 키 한 번을 받지만, prompt/dotfile 영향을 받는 interactive shell 검증은 다음 단계에서 별도로 확인한다.

## 관측 가능성

폰트 관련 실패는 화면만 보면 원인을 찾기 어렵다. 따라서 다음 정보는 debug snapshot 또는 failure artifact 후보로 남긴다.

```text
requested_family
resolved_primary_font
fallback_fonts_used
font_identity_count
font_size
device_scale_factor
atlas_miss_count
atlas_upload_bytes
atlas_eviction_count
full_redraw_reason
replacement_glyph_count
```

민감정보 주의:

- font 경로나 사용자 홈 디렉터리가 artifact에 그대로 들어갈 수 있다.
- git fixture로 올릴 때는 로컬 경로를 제거하거나 family 이름만 남긴다.

## 성능 예산 후보

renderer가 붙은 뒤 다음 숫자를 성능 예산에 추가한다.

- first glyph resolve 시간.
- frame당 glyph atlas miss 수.
- frame당 atlas upload bytes.
- font size 변경 후 첫 frame 시간.
- 대량 CJK/emoji 출력 시 frame drop 여부.

이 값들은 초기에는 실패 기준보다 관측 지표로 시작한다. 실제 app host와 Metal backend가 붙기 전부터 엄격한 숫자를 정하면 잘못된 목표를 최적화할 위험이 있다.

## Clean-room 기준

폰트 구현도 reference terminal source를 line-by-line으로 참고하지 않는다.

허용:

- Apple CoreText/Metal 공식 문서.
- Unicode width 관련 공개 명세.
- Maru의 독립 fixture와 동작 비교 artifact.
- reference terminal의 외부 동작 결과 비교.

금지:

- Ghostty/Alacritty/WezTerm의 font/glyph atlas 구현을 복사.
- reference terminal의 내부 타입을 Maru public API로 노출.
- "reference가 이렇게 했으니 그대로"라는 이유만으로 cache key나 fallback 정책을 결정.

## 구현 전 다시 논의할 것

다음은 코드 구현 전에 사용자와 다시 확인한다.

- ligature를 v1 이후 어느 단계에서 다룰지.
- emoji 품질 기준을 replacement 허용으로 둘지, color glyph 필수로 둘지.
- ambiguous width(UAX#11 'A')를 1 cell 고정으로 둘지, 로케일/설정으로 2 cell을 허용할지.
- 폰트에 bold/italic face가 없을 때 합성(faux bold/italic)할지, regular로 대체할지.
- font config에 fallback family list를 노출할지.
- user-installed font 파일 경로를 직접 지정하게 할지.
