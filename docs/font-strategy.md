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
- **growable atlas(grow on full)**: 한 프레임의 고유 글리프가 현재 텍스처에 안 들어가면 `GlyphAtlas.grow()`가 텍스처를 max(8192²)까지 2배씩 키운 뒤 (0,0)부터 다시 배치한다(Ghostty식). 이게 충돌의 근본 차단책이다 — 좌표가 모자라 두 글리프가 같은 아틀라스 좌표를 받으면(GPU 업로드가 앞 글리프를 덮어써) 보더라인 `─`가 나중 글리프 `?`의 비트맵을 샘플하는 간헐적 깨짐이 났다. grow된 현재 크기는 `config.atlas_*_px`에 반영돼 렌더러(app_session→metal_frame→`set_atlas`)가 GPU 텍스처를 재할당한다. **멀티 페인은 한 atlas를 공유**(아래 *통합 멀티 페인 빌드*로 한 세대에 배치)하므로, 그 세대 안에서 grow가 텍스처를 키우면 먼저 배치된 페인의 baked UV(배치 시점 dims ÷)가 어긋날 수 있으므로, `metal_frame.replace`가 최종 atlas 크기를 알게 된 시점에 **셀 UV를 최종 dims로 다시 정규화**한다(`renormalizeGlyphCellUvs` — atlas 픽셀 좌표는 grow에 불변; px→UV 나눗셈은 `glyph_quads.uvRectForPx` 단일 출처 재사용, 배경·컬러 sentinel(+2.0) 보존, non-grow엔 bit-exact no-op). 이 수치 계산은 테스트 가능한 Zig에 둔다(렌더러 `.m`은 UV를 그대로 소비 — host-boundary 규칙).
- **통합 멀티 페인 빌드(cross-pane 재업로드 누락의 근본 수정)**: 한 frame에서 활성 페인·사이드바·분할 페인·오버레이가 한 atlas를 공유하는데, **각 페인을 개별 빌드**하면 뒤 페인이 좌표를 소진해 `invalidate`/grow를 일으킬 때 앞 페인 슬롯이 무효화된다. 그런데 GPU 업로드는 "이번 빌드에서 **miss**인 글리프(`frame.uploads`)"만 한다(`buildNativeRasterUploads`) — 앞 페인 글리프는 그 빌드에서 hit이라 `uploads`에 없어 **재업로드되지 않고**, 무효화된 자리(덮인 좌표 / `set_atlas`의 빈 텍스처)를 샘플해 깨진다(분할+탭 빠른 전환에서 폰트 폴백 글리프가 다른 글자/빈 칸으로). **근본 수정 = 통합 빌드**: `prepareMultiPaneGlyphFrame`(순수 함수)이 모든 페인의 `GlyphRunList`를 **한 atlas 세대로** 배치한다 — 어느 페인이 소진을 일으켜도 전체를 재시작해 atlas가 비고 전부 miss가 되어 **전부 `uploads`**에 들어간다. app_session은 페인을 `shapeOnly`로 모아(`collectShaped`) 한 번의 `placeMultiPane`으로 배치·분배한다(`placeAndDistribute` — sidebar/header/overlay/grip/label/탭바/비활성/floating + 활성 panel(`shapeOnlyBuild`)까지 합류). **활성 panel이 atlas에 가장 먼저·크게 쓰므로 합류해야** 깨짐이 사라진다. 활성 shape/place가 드물게(OOM) 실패하면 frame을 통째로 포기해(`active_failed` — replace 스킵, `metal_dirty` 유지로 다음 tick 재시도) chrome만으로 blank terminal을 합성하지 않는다. 정확성은 GPU 없이 단위로 증명(`prepareMultiPaneGlyphFrame` distinct/공유/빈 페인 + `placeAndDistribute` dest 분배·소진·소유권), 실제 텍셀 cross-pane은 visible GPU smoke(atlas readback `atlas_sample_missing_cells=0`)가 검증한다.
- **좌표 회수(coordinate reclamation) — 보류(deferred)**: eviction이 비운 아틀라스 자리를 free-list에 넣어 다음에 재사용하는 packer. **정확성엔 grow로 충분**하고, 회수는 *churn*(고유 글리프가 텍스처 용량을 넘게 계속 바뀌는 경우 — 예: 수천 개 고유 CJK·이모지 문서를 끊임없이 스크롤)에서 좌표가 monotonic하게 증가해 일어나는 **주기적 전체 재업로드를 줄이는 성능 최적화**일 뿐이다. 안전하게 켜려면 **모든 글리프 빌드를 덮는 단일 frame-epoch 경계**가 필요한데, 위 *통합 멀티 페인 빌드*가 이미 모든 페인을 한 `placeMultiPane` 세대로 묶어 그 경계(한 세대)를 세웠다. 좌표 회수는 그 위에 epoch를 *렌더 프레임당 1회* 올리고 "**이전 epoch에 freed된 자리만 재사용**"하는 규칙만 더하면 된다 — 같은 프레임이 방금 비운 자리를 다른 페인이 재사용하면 `─→?` 충돌(grow가 막은 그 버그)이 재발하고, 경계를 잘못 놓으면 고친 버그가 그대로 돌아온다(실제로 첫 시도에서 발생, 리뷰가 잡음). **결정: 보류.** 글리프 많은 화면 스크롤에서 **측정된 끊김**이 생기고 프로파일이 atlas 재업로드/invalidate를 원인으로 가리킬 때만 착수한다. 그때도 1순위 레버는 회수가 아니라 **atlas 초기 크기/`max_slots`를 키워 소진 빈도를 낮추는 것**(free-list·epoch 없이 거의 무위험)이고, 그래도 부족할 때만 회수 packer로 간다. **회수 packer/atlas packer를 실제로 손대는 PR은 split 멀티 surface GPU readback smoke를 먼저 만들어(red→green) cross-pane 재발을 자동으로 가드한다** — frame-epoch 경계를 잘못 놓아 `─→?`가 재발한 첫 시도 이력이 있고, atlas readback은 "업로드한 byte와 일치 + 샘플 셀이 atlas에 존재"라 OS 폰트 모양과 무관(pixel-perfect ink과 달리 flaky 아님)이라 CI 안전망으로 안정적이다. 지금 독립 제작하지 않는 이유는 지킬 회귀(좌표 회수) 자체가 보류라 한동안 가드할 대상이 없는 큰 harness(Metal/macOS 의존)를 유지하게 되기 때문(YAGNI) — 착수 시점에 그 PR의 첫 단계로 함께 만든다.
- **불변식**: 한 프레임 안에서 서로 다른 글리프(cache_key가 다른)는 절대 같은 아틀라스 좌표를 공유하지 않는다 — 공유하면 한쪽이 다른 쪽 텍셀을 샘플해 잘못된 글자가 그려진다. 회귀 테스트로 고정한다.
- renderer backend가 바뀌어도 cache key와 glyph run 의미가 흔들리지 않게 한다.
- 현재 구현은 `GlyphCacheKey -> AtlasSlot` domain cache/placement 계약, `GlyphRunList -> GlyphFrame` 준비 계약, `GlyphFrame -> GlyphQuadFrame` UV 변환 계약, `GlyphFrame -> GlyphRasterFrame` upload byte/skip 계약, macOS CoreText CPU bitmap smoke, CPU bitmap -> Metal texture upload smoke, 그리고 제품 Metal atlas upload/readback/shader sampling smoke까지 고정한다. 남은 검증 갭은 device-scale별 atlas eviction/upload **성능 예산**, split 동시 멀티 surface + 강제 grow의 실제 GPU readback smoke, 그리고 보류된 좌표 회수 packer다.

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
- 글리프 합성(cell-snapping, 폰트 대신 셀에 직접 — nearest 샘플 + alpha coverage라 1:1 픽셀-퍼펙트):
  - **Block Elements(U+2580~259F **전체**) 완료**(`renderer/block_glyph.zig` — eighth/half/full/quadrant 사각형 + **shade ░▒▓**(U+2591~2593, 셀 전체 균일 alpha 0x40/0x80/0xC0 = ¼/½/¾ — dither가 아니라 부분 coverage라 어느 크기든 깔끔, `glyph_pixels.fillUniformAlpha`)).
  - **Box-drawing(U+2500~257F **전체** 완료)**(`renderer/box_glyph.zig` — **per-arm 굵기** arm 모델, Ghostty linesChar식). U+2500~254B 직선·모서리·T·사거리를 팔마다 굵기(light/heavy)로 그려 **혼합 굵기**(┍=down light+right heavy·┞=up heavy·╀ 등)까지 한 함수(fillLines)로 — 각 팔이 자기 두께로 셀 경계까지 뻗고 중앙 교차(가장 굵은 세로폭×가로높이)를 모두 덮어 이어진다. 둥근 ╭╮╰╯는 **실제 quarter-arc**. **dashed** ┄…┋·╌╍╎╏(2·3·4점선, light·heavy) — 각 주기 앞 2/3만 칠해 셀 너머로 연결. **double** ═║·╔╗╚╝·╠╣╦╩·╬ — 두 평행선(gap=t), 모서리 **outer/inner 코너**·T 통과방향 full+분기 spine·╬ 네 선 full. **반선·두께전이** ╴╵╶╷╸╹╺╻╼╽╾╿(단일 팔 또는 좌우 다른 굵기). **대각선** ╱╲╳(코너↔코너 거리 기반 선, 대각 이웃 셀과 연결). **single↔double 혼합** ╒╓ ╞╟ ╤╥ ╪╫ …(일반 band 모델 fillMixed — 한 축 single·다른 축 double, double과 선 위치 일치해 이중 박스와 연결. 이중-T ╟╢╤╧는 single 가지가 **통과 이중벽의 안쪽 선**에 부착해 두 평행선 사이 gap을 유지). 이중선 두께/gap은 fillDouble·fillMixed가 `doubleBandParams` 단일 출처로 공유. U+2500~257F 빈틈 없이 전부(테스트로 고정).
  - **Powerline(U+E0B0~E0BF) 완료**(`renderer/powerline_glyph.zig`). 삼각형 separator(E0B0 우·E0B2 좌 solid, E0B1·E0B3 thin chevron — point-in-triangle), 모서리 삼각형(E0B8 좌하·E0BA 우하·E0BC 좌상·E0BE 우상 solid, E0B9·E0BB·E0BD·E0BF thin 대각선), 반원(E0B4 우·E0B6 좌 solid D-shape, E0B5·E0B7 thin arc — 경계까지 **부호거리** bd로 그려 solid=내부(bd≤0)·thin=안쪽 균일 밴드(−ft≤bd≤0)라 둘레가 호에 **수직**인 일정 두께, 극에서 안 가늘어짐). 셀에 꽉 차 다음 세그먼트 배경과 이음매 없이 맞물린다. **Powerline-extra 사다리꼴**(E0D2 우·E0D4 좌 — 위·아래 두 사다리꼴, 가운데 t 가로 gap, 반대쪽-중앙이 대각으로 깎임; `glyph_pixels.fillPolygon`)도 포함(E0D4=E0D2 좌우 반전). 베이스 = powerline-symbols·powerline-extra 표준 모양, Ghostty draw/powerline.zig 동작만 비교(clean-room). 나머지 E0C0~(불꽃·고드름 등)은 **Ghostty도 합성 안 함**(Nerd Font 의존) → 폰트 폴백.
  - **Braille(U+2800~28FF) 완료**(`renderer/braille_glyph.zig`). 한 셀에 2열×4행 8점, 코드포인트 **하위 8비트가 점 비트마스크**(점1~8)다. 켜진 점마다 둥근 점(거리 ≤ r, pitch의 ~0.38배라 분리)을 셀 하위 격자(열 ¼·¾, 행 ⅛·⅜·⅝·⅞)에 스냅해 찍는다. btop·plotille 류 TUI 그래프가 흐려지지 않고 정렬된다. U+2800(빈 패턴)은 빈 셀. 베이스 = Unicode Braille Patterns dot 번호.
  - **Legacy Computing 블록 모자이크 완료**(`renderer/legacy_mosaic_glyph.zig`). **sextant**(U+1FB00~1FB3B, 2열×3행 6칸)·**octant**(U+1CD00~1CDE5, 2열×4행 8칸) — 각 코드포인트의 하위 칸 패턴을 셀 하위 격자 사각형으로 채운다(Teletext·PETSCII식 그래픽, block quadrant를 더 잘게). sextant는 64패턴 중 이미 인코딩된 {0,21,42,63}(space·▌·▐·█)을 건너뛴 60개라 `pattern = idx + idx/20 + 1` 공식. octant는 256패턴 중 이미 인코딩된 26개(space·반칸·4분면·full)를 건너뛴 230개를 **마스크 오름차순**으로 배정(Unicode BLOCK OCTANT-* 순서가 그러함 확인) → skip 26개만 데이터로 두고 표는 comptime 생성.
  - **Legacy Computing edge wedge 완료**(`renderer/legacy_wedge_glyph.zig`). U+1FB68~1FB6F = 한 변을 밑변·셀 중앙을 꼭짓점으로 하는 삼각형(solid 4 🭬🭭🭮🭯 + 반전 4 🭨🭩🭪🭫), bowtie U+1FB9A/1FB9B = 두 wedge가 중앙에서 맞닿은 모래시계. point-in-triangle 채움(`glyph_pixels.fillTriangle`, invert로 반전). 대각 반쪽 **corner 삼각형**도 같은 모듈: solid ◢◣◤◥(U+25E2~25E5, Geometric Shapes)·50% 음영 🮜🮝🮞🮟(U+1FB9C~9F) — 셀 대각선으로 가른 반쪽을 `fillTriangleAlpha`로(음영=alpha 0x80).
  - **Legacy Computing smooth mosaic 완료**(`renderer/legacy_smooth_glyph.zig`). U+1FB3C~1FB67 44개 — 셀 둘레 10정점(모서리 4 + 좌·우변 1/3·2/3 4 + 상·하변 중점 2) 중 글자별 부분집합을 둘레 순으로 이은 대각 폴리곤(block 모자이크의 빗변 버전). Unicode 형상에서 정점 집합(10비트 마스크)을 독립 디코더로 산출해 마스크 44개만 임베드(레퍼런스 패턴표 미복사), 채움은 공유 `glyph_pixels.fillPolygon`(scanline even-odd).
  - **Legacy Computing 대각선 stroke 완료**(`renderer/legacy_diagonal_glyph.zig`). 코너 대각선 U+1FBA0~1FBAE(중앙선↔모서리중점 4선분 다이아몬드 변 조합 15개)·cell 대각선 U+1FBD0~1FBDF(셀 정렬점 사이 대각 선분 16개). 채움이 아니라 **light 두께 선분 stroke**(공유 `glyph_pixels.fillSegment`). 모든 끝점이 3×3 정렬 격자의 한 점이라 코너·cell이 점-쌍 선분으로 통일된다. 코드포인트↔선분 매핑은 Unicode 이름에서 유도. **대각 hatch** U+1FB98/99(🮘╲·🮙╱)도 같은 모듈: 평행 전셀 대각선을 stride(≈2t) 간격으로 stripe(선이 셀 밖으로 뻗고 fillSegment가 셀 안만 칠해 이웃 셀과 이어짐). **나머지**: Powerline-extra(U+E0C0~ 불꽃·고드름, PUA·Nerd Font 의존)만 후속.
  - **공유 프리미티브**(`renderer/glyph_pixels.zig`): 위 합성 모듈들이 슬롯 계약 검증(`slotFits`)·clear·setPixel(+alpha)·fillRect(교차 dedup 회계)·균일 alpha·코너 대각선·삼각형(invert·alpha 포함)·선분 stroke(`distSeg`/`fillSegment`)·폴리곤(scanline)을 단일 출처로 공유한다(Powerline·wedge·diagonal 등 중복·드리프트 제거).
  - **합성 글리프 cache_key**: 폰트 글리프(`font_id+glyph_id`)와 달리 **codepoint로 키잉**한다 — 네이티브 셰이퍼(`coretext_smoke.m`)가 폰트가 글리프를 제공해도(`glyph!=0`) `glyph_id=0`으로 정규화해 보내므로, 합성 글자는 `font_id=0`(합성 전용 공간)·`glyph_id=codepoint`로 모인다. 그래야 primary/fallback이 한 atlas 슬롯에 모이고(중복 슬롯 방지) 폰트 glyph_id와 안 겹친다(aliasing 방지).
- pixel-perfect golden을 기본 CI에서 강제.
- HarfBuzz, FreeType, fontconfig, DirectWrite 같은 외부/타 플랫폼 폰트 스택 추가.

## FontConfig

초기 config는 단순하게 유지한다.

```text
font.family = "JetBrains Mono"
font.size = 14
font.line-height = 1.0
font.letter-spacing = 0.0
font.fallback = "Jetendard"
font.family-bold = ""
font.family-italic = ""
```

해석 규칙:

- `family`는 사용자가 원하는 primary monospace family다.
- ⌘+/⌘-(폰트 키우기/줄이기)는 `font.size`를 **고정 1pt씩** 바꾼다(보폭은 설정 항목이 아니다 — Terminal.app·iTerm2·Ghostty 관례). ⌘0은 config 기본 크기로 복귀.
- `font.line-height`는 행간 배수다(1.0=CoreText 자동 cell 높이 그대로). 기본 1.0.
- `font.letter-spacing`은 자간(논리 pt, 음수 허용 — 칸 좁힘)이다. 기본 0.0.
  - **렌더 모델(자간 적용)**: 자간은 **grid advance(셀 배치 간격)에만** 반영하고, **폰트 글리프 비트맵 폭은 자연폭(자간 무관)**으로 둔다 — `applyFontSpacing`이 `advance_width_px`(spaced, 배치·hit-test·커서)와 `glyph_cell_width_px`(natural, atlas slot·글리프 quad)를 분리 반환하고, `TextLayoutConfig.slotCellWidthPx`가 글리프별로 slot 폭을 고른다. **합성 글리프(box/block/Powerline·notdef = `glyph_id==0`)는 셀에 꽉 차 이음매 없이 타일링돼야 하므로 advance(셀폭) 그대로** 쓴다. 근거: 음수 자간이 폰트 글리프 slot을 좁히면 글리프가 "셀보다 넓다"로 오판→축소+ink세로중앙 경로로 빠져 **글자마다 세로로 흔들리고/찌그러지던** 버그가 났다(code-review). Ghostty도 일반 텍스트를 자연 bearing 좌측정렬로 두고 셀폭 조정은 배치에만 적용한다(`face.zig` "left-aligned within the cell"). 좁힘 시 글리프는 자연폭으로 온전히 그려지고 배치 step만 줄어 이웃과 겹친다.
  - **화면 quad(A, 완료)**: 렌더러(`maru_metal_renderer.m`)가 터미널 셀을 **셀당 2 quad**(인접: 배경 quad[셀폭, UV=-1] + 전경 quad)로 그린다. 같은 cell 인덱스에 인접 배치하므로 **cell 순서가 보존**돼(장식 셀=글리프 뒤=위, 커서 셀의 불투명 배경이 원래 글자를 덮음) draw-pass 구조·모달/scissor/이미지 z·페인터 순서가 불변이다 — 셀당 vertex만 ×2(오프셋 ×12). 전경: **모든 일반 텍스트 글리프(불투명 bg 포함)를 자연폭**(`cell.atlas_width_px`, 좌측정렬, 투명 bg)으로 그린다 → 선택영역·SGR48 색배경·**블록 커서 밑 글자**의 자간 왜곡/breathing이 사라진다(셰이더 premultiplied라 전경이 배경 quad에 over-blend). 장식/커서 바(reserved!=0)·헤더아이콘/종(확대)은 전경 quad에 그 띠/글리프(투명 bg), 빈셀은 전경 없음. **box-drawing 등 합성 글리프는 `glyph_id==0`로 slot이 셀폭**이라 자연폭=셀폭으로 그려져 타일링 보존. 음수 자간=이웃과 겹침·양수=우측 여백, **squish/stretch 없음**. **알려진 한계**: 자연폭 글리프가 불투명 bg 이웃으로 넘칠 때 색 경계서 미세 clip, 그리고 split pane 경계에서 음수 자간 마지막 칸이 divider로 약간 bleed(per-pane scissor 미적용 — 후속).
- `font.fallback`은 폴백 폰트 패밀리 목록(쉼표 구분)이다. primary `family`에 없는 글리프(한글·이모지·기호 등)를 그릴 때 이 목록을 앞에 두고 CoreText 자동 cascade(`kCTFontCascadeListAttribute`)를 뒤에 잇는다. 빈 값이면 CoreText 기본 cascade만 쓴다.
  - **기본값은 번들 `Jetendard`다**(2026-08-10 사용자 결정). 이유는 한글 자간이다 — 시스템 cascade는 한글을 Apple SD Gothic Neo(비례 폰트)로 그리고 그 advance는 등폭 격자와 무관해서, 13pt 실측에서 한글 `가`가 11.24px인데 격자는 2칸 16px이라 **글자당 4.76px이 빈다**(ASCII는 0.20px). Jetendard는 한글을 라틴 2배 폭으로 디자인해 **15.60px = cell_w의 정확히 2.00배**라 여백이 0.40px로 준다. 근거와 대안 검토는 [native-editor-visual-mapping.md](native-editor-visual-mapping.md) §4.2가 소유한다.
  - **글리프를 키워 맞추는 길은 없다.** 폭을 격자에 맞추려면 1.42배가 필요하고 그러면 세로가 셀 높이를 30% 넘는다(실측) — 비례 폰트의 종횡비가 셀과 달라 종횡비를 유지하는 한 둘 다 만족할 수 없다.
  - **적용 범위는 터미널만이 아니다.** 이 설정은 chrome UI 텍스트에도 흘러가므로 도크·사이드바 라벨의 한글도 이 폰트로 그려진다(골든 `expanded-actions`가 그 변화를 잡는다). 한글만 등폭이 되는 셈이라, UI에서 분리하려면 chrome 텍스트 face가 이 값을 상속하지 않게 해야 한다 — 지금은 **일관성을 택해 상속시킨다**.
  - **Jetendard는 한글만 가져간다.** 한자·가나·이모지·동그란 번호에는 글리프가 없어 자동 cascade로 넘어간다(실측). 즉 CJK 자간은 여전히 벌어지며, 그것까지 맞추려면 한자를 담은 등폭 폰트가 따로 필요하다.
- `font.family-bold`/`font.family-italic`은 bold(SGR 1)/italic(SGR 3) 글자에 쓸 별도 패밀리다. 빈 값(기본)이면 primary `family`의 bold/italic variant를 쓰고, variant가 없으면 regular로 대체한다(합성/faux 안 함).
- raw `FontConfig`는 `ResolvedFontRequest`로 먼저 검증한다. 빈 family와 1px 미만 또는 512px 초과 font size는 renderer로 보내지 않는다.
- family가 설치되어 있지 않으면 앱은 죽지 않고 system monospaced font로 fallback한다.
- fallback이 발생하면 debug artifact와 structured log에 남긴다.
- 사용자가 proportional font를 지정해도 v1은 터미널 품질을 보장하지 않는다. 이 경우 경고 artifact를 남기고, cell metric은 primary monospace fallback 기준으로 잡는다.

이 정책의 의도는 설정 실수 때문에 shell이 열리지 않는 일을 막는 것이다. 터미널은 설정이 조금 틀려도 최소한 사용자가 수정할 수 있는 화면을 보여줘야 한다.

## 번들 폰트(self-contained)

앱은 개발자들이 즐겨 쓰는 monospace 폰트 몇 종을 **번들에 동봉**한다. 시스템에 따로 설치하지 않아도 `font.family`에 패밀리명만 적으면 바로 쓸 수 있다(self-contained). 동봉 목록:

| 패밀리명(`font.family`에 그대로) | 변종 | 라이선스 | 특징 |
| --- | --- | --- | --- |
| `JetBrains Mono` | Regular/Bold/Italic/BoldItalic | OFL 1.1 | **기본값**. 모던·고가독성 |
| `Jetendard` | Regular/Bold/Italic/BoldItalic | OFL 1.1 (RFN "Jetendard") | JetBrains Mono Nerd Font Mono 라틴 글리프 + Pretendard 한글/CJK를 결합한 균형형 모노스페이스 |
| `Fira Code` | Regular/Bold | OFL 1.1 | 합자(ligature) 매니아층 — 단, maru는 합자 렌더 보류라 모양만 쓰임(아래 "Ligature" 참고) |
| `Cascadia Code` | Regular/Bold/Italic/BoldItalic | OFL 1.1 | Windows Terminal 출신, 크로스플랫폼 친화 |
| `Hack` | Regular/Bold/Italic/BoldItalic | MIT(+DejaVu/Bitstream Vera) | 합자 없는 순수 가독성, `0/O`·`1/l/I` 구분 명확 |

동봉/등록 메커니즘:

- 자산은 `assets/fonts/<Family>/`에 둔다(`.ttf` + 라이선스 파일 `OFL.txt`/`LICENSE.md`). **재배포 의무상 라이선스 동봉은 필수.**
- `build.zig`의 `macos-app-bundle` 단계가 모든 `assets/fonts/*/*.ttf`를 `Maru.app/Contents/Resources/Fonts/`에 평평하게 복사하고, 라이선스는 패밀리명 프리픽스로 충돌 없이 함께 넣는다.
- `MaruAppHost-Info.plist`의 `ATSApplicationFontsPath = Fonts`가 그 디렉터리를 스캔해 **앱 실행 시 자동 등록**한다. 그래서 폰트 추가에는 Zig/Swift 코드 변경이 필요 없다.
- **새 패밀리 추가** = `assets/fonts/<NewFamily>/`에 `.ttf` + 라이선스를 넣기만 하면 된다(빌드가 자동 포함). 이 표와 [third-party 라이선스](third-party-licenses.md)를 갱신한다.
- **GUI 폰트 피커**: 세팅 GUI의 `font.family` 행은 이 번들 목록을 **열리는 드롭다운 팝업**으로 고른다(Enter/클릭으로 열고 ↑↓ 라이브 미리보기·Enter 확정·Esc 원복). 목록 끝의 **"직접 입력…"** 항목을 고르면 인라인 편집이 열려 목록 밖 시스템 폰트를 타이핑한다. 목록의 단일 출처는 `theme.bundled_font_families`(config) — 새 번들 폰트를 추가하면 이 상수도 함께 갱신한다(첫 항목=기본 `font.family`). 세부는 [config GUI](config-gui.md) §폰트 피커.

각 폰트의 라이선스·버전·저작권과 **재배포 의무(라이선스 동봉·단독판매 금지·RFN 등)·동봉 자산 추가 규칙**은 [third-party-licenses.md](third-party-licenses.md)를 단일 출처로 둔다. 모두 재배포·임베드가 허용된 라이선스(OFL 1.1 / MIT)이고, 의무인 라이선스 파일 동봉은 위 메커니즘으로 충족한다.

결정과 근거(`document-basis-and-decision`):

- **Nerd Font 미동봉**: 풀 패치 Nerd Font는 패밀리당 ~8.7MB(아이콘이 본문의 ~7배)로 5종이면 ~40MB까지 부푼다. maru의 chrome 아이콘은 SVG 합성(`icon_glyph`)으로 폰트와 무관하게 그리고, 터미널 콘텐츠의 Nerd Font 아이콘은 Powerline separator를 합성(`powerline_glyph`)으로 커버한다. 그 밖의 심볼은 향후 "Symbols-Only Nerd Font" 폴백(단일 ~2MB) 한 개로 모든 폰트가 공유하게 두는 방향이 효율적이다(풀 패치 중복 동봉 대비 ~1/15). Jetendard는 한글/CJK 품질을 위한 예외적인 번들 폰트로, R/B/I/BI 4종이 약 18MB를 차지한다.
- **Iosevka 미동봉**: 후보였으나 글리프 커버리지가 방대해 변종당 ~10.5MB(4변종 ~43MB)로 "용량 절감" 의도와 충돌해 제외했다. compact 니치가 필요하면 Latin 서브셋(비라틴은 폴백) 또는 더 가벼운 대안을 별도 검토.
- **변종 범위**: SGR 1(bold)/3(italic) 지원을 위해 가능한 한 R/B/I/BI 4종을 넣는다. Fira Code는 italic face가 존재하지 않아 R/B만 동봉(italic 요청 시 regular 대체 — 위 해석 규칙). Jetendard는 릴리스의 16종 중 R/B/I/BI만 동봉하며, italic의 한글/CJK는 원본 정책상 upright 글리프를 사용한다.

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
- grapheme cluster는 UAX#29 기준으로 분절하고, ZWJ 시퀀스·국기·skin-tone modifier, **그리고 NFD(분해형) 한글 conjoining 자모(초성 L+중성 V+종성 T)** 는 하나의 cluster로 묶어 폭을 width policy로 정한다(한글은 base 초성이 wide라 음절 cluster=2칸). 완전한 처리는 fixture로 확장한다 — 다중 코드포인트 cluster의 저장·셰이핑 정공법은 [Grapheme Cluster 저장·렌더링 전략](grapheme-clustering.md)이 단일 출처다.
- ambiguous width(UAX#11 'A')는 config 키 `text.ambiguous-width`로 정한다(값 `narrow`(기본)/`wide`). 기본 `narrow`는 1 cell(정렬 안전·Ghostty/xterm.js 호환), `wide`는 로케일/CJK 맥락에서 폰트가 전각으로 그리는 심볼(`width.isWideRenderSymbol` — Enclosed Alphanumerics U+2460~U+24FF)을 2 cell로 올린다(advance 2). box/block·PUA(Nerd Font)는 제외한다. live-reload로 즉시 반영된다.
- unsupported/ambiguous width는 보수적으로 1 cell로 시작하고 fixture로 확장한다.
- emoji는 표시 폭과 실제 glyph bounds가 다를 수 있으므로, cursor advance는 width policy를 따른다.

wide/combining 처리는 [검증 매트릭스](verification-matrix.md)의 `wide-character(East-Asian width)` 항목과 연결한다. 현재 구현은 width table, continuation cell에 더해 **다중 코드포인트 grapheme cluster 저장**(`Cell.grapheme_id` + 전역 grapheme store)을 제공한다 — combining mark 1개만 저장하던 옛 `combining` 필드 한계(NFD 한글 자모가 분리돼 `ls` 폭이 음절당 2배로 깨지던 문제)는 grapheme 저장으로 해소돼 필드 자체가 제거됐다. 저장·셰이핑 세부는 [Grapheme Cluster 저장·렌더링 전략](grapheme-clustering.md)이 단일 출처다. ambiguous width 설정(`text.ambiguous-width`)과 ZWJ emoji 클러스터(mode 2027)는 구현됐고, UAX#11 전체 커버리지는 fixture를 추가하며 확장한다.

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

## Chrome 텍스트 face (measured chrome이 어떤 폰트로 그려지는가)

Chrome에는 텍스트를 그리는 경로가 **둘**이고, 이 절은 그중 measured 경로의 face 단일 출처다.

| 경로 | 누가 쓰나 | face |
| --- | --- | --- |
| cell lowering | 사이드바 카드·파일 트리·SCM·notice·palette·find | 터미널과 같은 셀 그리드라 `font.family`를 그대로 쓴다 |
| measured chrome text | Session Dock·archive detail (`platform/macos/chrome/system_text.zig`) | **이 절이 정한다** |

measured 경로도 `font.family`(+`font.fallback` cascade)를 쓴다. 근거는 두 경로가 **한 화면에
동시에 보인다**는 것이다. 도크가 시스템 UI face(SF)로, 바로 옆 사이드바가 사용자 monospace로
그려지면 사용자가 고른 폰트를 앱이 절반만 따르는 셈이 된다(사용자 결정 2026-08-08).

**이 결정이 바꾸지 않는 것 — Chrome scale의 독립성은 그대로다.**

- `chrome/ui/typography.zig`의 role→pt/weight 토큰은 `font.size`와 무관하게 고정이다.
- `DockMetrics`의 카드 높이·여백·hit rect는 `lineHeightPx(role)` 파생이라 face와 직교다.
- 중립 chrome 레이어(`src/chrome/**`)는 여전히 face를 모른다. face 해석이 platform adapter
  책임이라는 `typography.zig` 헤더의 기존 계약을 그대로 따른다 — 바뀐 것은 그 adapter가
  해석 결과를 **어디서 얻는가**뿐이다(하드코딩된 `kCTFontUIFontSystem` → resolved appearance).

**face 해석 규칙**(`maru_chrome_font_for`, `coretext_smoke.m`):

1. family가 비어 있으면 시스템 UI face(`kCTFontUIFontSystem`). 이 경로가 남아 있는 이유는
   Chrome Lab·단위 테스트처럼 resolved appearance가 없는 호출자 때문이다.
2. family가 있으면 `CTFontCreateWithName` 뒤 **PostScript 이름을 대조**한다. CoreText는 없는
   폰트에 Helvetica 같은 대체 face를 조용히 돌려주므로, 대조 없이 쓰면 "설정한 폰트가 아닌데
   설정한 폰트인 척"하는 face가 캐시에 눌러앉는다. 대조 실패는 시스템 UI face로 폴백하고
   `primary_font_found=0`으로 관측 가능하게 남긴다. 이 대조 규칙은 터미널 경로의
   `maru_create_primary_font`와 같은 근거·같은 헬퍼(`maru_font_matches_requested`)다.
3. `font.fallback` CSV가 있으면 터미널과 **같은** `maru_apply_cascade_list`로 cascade를 박는다.
   같은 헬퍼를 쓰는 이유는 한글·이모지가 두 경로에서 다른 폰트로 떨어지면 face를 맞춘 의미가
   없어지기 때문이다. cascade는 face 캐시 **안에서** 한 번만 만든다(run마다 만들면 아래 성능
   계약이 깨진다).
4. weight는 지금처럼 symbolic bold trait로 얻는다.

**한계 (v1 범위 밖, 의도적)**

- `font.family-bold`/`family-italic`은 measured chrome에 전달하지 않는다. 터미널은 bold가 1단계인데
  chrome role weight는 regular/medium/semibold 3단계라 1:1 매핑이 없다. 사용자가 별도 bold family를
  설정하면 사이드바 활성 카드의 bold와 도크의 semibold가 다른 face가 될 수 있다. 매핑 축을 새로
  만들 이유가 생기면(두 번째 소비처) 그때 정한다.
- monospace는 같은 폭에 들어가는 글자 수가 시스템 UI face보다 적다. 도크 폭은 고정이므로 카드
  제목/요약의 `…` 잘림이 늘어난다. **기하는 불변이고 표시 정보량만 준다** — 이건 face 선택의
  대가이지 결함이 아니다.

**성능 계약 유지**: face 캐시 키가 `(size, weight)`에서 `(size, weight, family, fallback)`으로
넓어지지만, 한 프레임의 모든 run이 같은 family를 쓰므로 "run마다 face를 다시 만들지 않는다"는
기존 테스트의 전제는 그대로다. 캐시 항목 수도 늘지 않는다(같은 family 안에서 role×weight 조합).

**무효화**: family가 바뀌는 경로는 `applyAppearance` 하나뿐이고, 그것이 부르는
`applyMetricsPipeline`이 이미 measured chrome 캐시를 버린다. 셰이핑 fingerprint에는 face가 없으므로
이 무효화가 유일한 안전장치다 — 새 face 경로를 추가할 때 이 초크포인트를 우회하면 옛 face의
glyph가 재생된다.

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

`font_id`는 임의 증가 숫자가 아니라 `FontIdentityRegistry`가 소유한 face identity를 뜻한다. 이 구분이 필요한 이유는 CoreText의 `CGGlyph` 값이 전역 glyph 번호가 아니라 해당 `CTFont` 안에서만 유효한 번호이기 때문이다. 예를 들어 primary font와 CJK fallback font가 둘 다 glyph id `42`를 낼 수 있지만, 두 bitmap은 서로 다른 atlas entry여야 한다. 단, `FontId`는 face가 registry에 처음 등장한 순서로 매기는 **지역 순번**이라 registry가 atlas보다 짧게 살면 이 보장이 깨진다: registry를 frame·pane마다 새로 만들면 같은 순번(예: `42`가 아니라 `font_id` 쪽)이 frame마다 다른 face를 가리켜, frame 간 살아남는 atlas가 이전 face의 slot을 다음 face에 오인 HIT한다(순번 뒤집힘에만 터져 간헐적 — 조합 중 '놔'에 번개). 그래서 registry는 **atlas와 같은 수명**으로 `RendererState`가 소유하는 단일 공유 registry여야 하고, 모든 pane의 shape가 여기 intern한다(상세: `src/renderer/README.md`의 `FontIdentityRegistry` 절).

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

### 슬롯 안 세로 정렬(텍스트 baseline vs 이모지 ink-center)

글리프를 atlas 슬롯(`cell_width_px × span` 폭 × `cell_height_px` 높이) 안에 **세로로 어디에 앉히는지**는 글리프의 **역할(role)** 로 정한다(런타임 픽셀 측정이 아니라 — 자세한 정책·레퍼런스 조사·SSOT는 [글리프 역할 렌더 모델](glyph-role-render-model.md)). 구현은 `coretext_smoke.m`의 `maru_macos_coretext_smoke_rasterize_glyph`가 단일 출처다.

- **일반 텍스트(한글/CJK 포함)**: 모든 글리프를 **공통 baseline**에 앉힌다(baseline = descent + 위아래 여백/2, 정수 픽셀로 스냅). 글자마다 ink 위치가 달라도 같은 줄에 정렬돼야 `m`·`a`가 위아래로 흔들리지 않는다. 수평은 advance 폭 기준 가운데(ink 폭이 아니라 — 폰트가 의도한 칸 위치). **ink가 advance를 미세하게 넘어도(타이트한 폰트의 `w` 등) 스케일·ink-center하지 않는다** — 안 그러면 descender 없는 `w`가 위로 떴다(Hack `w`, ink폭==advance).
- **emoji·wide-render-symbol(`width.isWideRenderSymbol` — ①②③)·헤더 심볼(◧/⚙)**: **cover-fit**(종횡비 유지하며 슬롯을 꽉 채우게 확대/축소) 후 **보이는 ink를 슬롯 세로 중앙에 앉힌다**. 심볼은 글리프마다 baseline 대비 ink 위치가 달라 공통 baseline이면 서로 어긋나 보이므로 ink-center가 자연스럽다. 게이트는 역할로 한정한다(`is_emoji ‖ center_symbol ‖ is_wide_render_symbol && ink>slot`) — 일반 텍스트는 이 셋에 안 들어 baseline 경로로 간다.

여기서 "ink 중앙"은 **`CTFontGetBoundingRectsForGlyphs`가 주는 design bbox 중앙이 아니라, 실제로 색이 칠해진 픽셀(alpha>0)의 중앙**이다. 컬러 이모지(sbix/COLR — 예: 알림 종 🔔)는 폰트가 design bbox 안에 비대칭 여백을 두고 artwork를 얹어, design bbox 중앙과 보이는 artwork 중앙이 다르다. design bbox만 중앙에 맞추면 종이 위로 떠 보였고, 예전에는 렌더러가 종에만 별도 보정 상수(`py_nudge` 0.40ch vs 단색 0.30ch)를 손으로 맞춰야 했다 — 폰트/DPI마다 다시 틀어지는 근사다. 그래서 cover-fit으로 그린 **뒤** 실제 픽셀의 세로 범위를 측정해 슬롯 중앙으로 옮긴다(`maru_center_ink_vertically`, 정수-행 이동). 단색 윤곽 글리프(◧/⚙)는 design bbox가 곧 ink라 이동량이 0에 가까워 안전하다.

이 ink-center 덕분에 렌더러(`maru_metal_renderer.m`)는 **모든 헤더 아이콘(◧/⚙/+/🔔)에 같은 `py_nudge`(0.30ch)만** 적용하면 자동으로 세로 정렬된다 — 글리프별 보정 상수가 없다. `py_nudge`는 줄0이 창 top에 붙어 위로 쏠리는 것을 신호등/타이틀바 중앙에 맞추는 **줄 단위 레이아웃 오프셋**일 뿐이고, 글리프 정렬은 atlas 래스터가 책임진다. 검증: 폰트 11/14/22pt(셀 높이 ~17→36px)에서 종의 세로 중심이 ⚙와 0.5px 이내로 유지됨을 화면 캡처로 확인했다(폰트-독립).

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
- 제품 renderer screenshot artifact. macOS Metal smoke는 제품 atlas sampling frame을 `zig-out/maru-macos-metal-smoke/metal-frame.ppm`으로 남기고, live PTY Metal smoke는 controlled PTY output과 AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key event roundtrip이 같은 visible path를 탄 frame을 `zig-out/maru-macos-app-pty-metal-smoke/app-pty-metal-frame.ppm`으로 남긴다. 같은 live PTY Metal smoke는 마지막 frame 뒤 같은 Metal terminal window의 AppKit close delegate callback을 통해 `FrameLoop.closeActiveLivePty -> LivePtyRegistry.closeActive -> LivePtySession.closeAndDetach`도 호출해 app host close lifecycle과 registry mapping 제거 gate를 summary에 남긴다. `mise run macos-app-pty-interactive-metal-smoke`는 같은 visible path에 실제 `$MARU_INTERACTIVE_SHELL` 또는 `$SHELL -i`를 태우고 `zig-out/maru-macos-app-pty-interactive-metal-smoke/app-pty-metal-frame.ppm`을 남긴다. 기본은 synthetic event이고, opt-in manual mode는 사용자가 직접 누른 `Cmd+B` payload를 같은 path로 검증한다.
- 제품 atlas slot 기반 glyph rasterization pixel comparison.

CoreText/font/raster/upload smoke들은 단계를 나눠 실패 원인을 분리한다. CoreText smoke는 창/GPU 없이 font resolve, shaping, 실제 `TerminalCore -> DrawList` 입력의 CoreText runtime shaping, raster bytes를 확인하고, Metal smoke는 같은 CoreText glyph bytes가 제품 `GlyphQuadFrame/GlyphRasterFrame`을 거쳐 실제 AppKit/CAMetalLayer 창에서 atlas shader sampling되는지 확인하며, 같은 frame을 PPM screenshot artifact로 남긴다. live PTY Metal smoke는 controlled PTY output과 같은 Metal terminal window의 AppKit `keyDown:`에서 얻은 key event를 `FrameLoop.handleKeyEvent -> KeyBindingResolver -> SurfaceRuntime.writeInput` 경로에 태운다. 기본은 자동 synthetic `Cmd+B`이고, opt-in manual mode는 사용자가 같은 Metal terminal window에서 직접 누른 `Cmd+B`를 같은 경로에 태운다. interactive Metal smoke는 실제 `$SHELL -i` startup과 marker command를 같은 visible renderer 경로에 한 번 태운다. glyph text smoke는 별도 fixture texture와 PPM screenshot artifact로 기존 shader sampling 경계를 유지한다. 아직 남은 핵심 한계는 사용자가 지속적으로 조작하는 제품 interactive shell/input loop가 이 renderer loop에 연결되지 않았다는 점이다.

현재 native CoreText DrawList shaper는 cell 단위 경계 검증 단계라 두 가지 알려진 한계가 있다. 첫째, 한 cell이 여러 glyph(base + combining mark, ligature)로 분해되면 그 glyph들이 모두 같은 `(row, col)`에 매핑되어 겹쳐 그려진다. 결합 문자/리거처의 cluster 위치 보정은 line-level shaper 단계로 미룬다. 둘째, 한 cell이라도 `.notdef`(glyph 0)로 매핑되면 native가 실패 status로 닫아 `CoreTextDrawListShapeFailed`로 frame 전체가 실패한다. 즉 폰트+fallback 체인에 없는 코드포인트는 아직 해당 cell만 tofu(`.notdef` placeholder)로 그리는 게 아니라 frame 전체를 떨어뜨린다. 임의의 셸 출력을 받는 단계에서는 이 두 한계를 line-level shaper와 per-cell tofu 대체로 풀어야 한다.

기본 CI에서 pixel-perfect font test를 강제하지 않는 이유는 font stack이 OS 업데이트와 설치 폰트에 영향을 받기 때문이다. 대신 기본 CI는 Maru가 만든 domain data와 cache/invalidation 계약을 검증하고, 실제 픽셀은 opt-in artifact로 추적한다. macOS CoreText smoke는 `ResolvedAppearance`의 font 요청이 native bridge까지 전달되는지, 요청 font가 실제 이름/family와 일치했는지를 `requested_font_matched` 진단값으로 남기는지, CoreText가 준 drawable glyph id/font face 후보가 `coretext_probe.zig -> coretext_font.zig -> FontIdentityRegistry -> coretext_shaper.zig -> GlyphRunList`를 거쳐 제품 `RendererState -> RenderFrame` 준비 계약까지 들어가는지, 실제 `TerminalCore -> DrawList` fixture가 `CoreTextDrawListShaper -> FontIdentityRegistry -> GlyphRunList -> RendererState -> RenderFrame` 경로를 통과하는지, 제품 후보 `coretext_raster.zig` wrapper가 같은 PostScript name으로 smoke native bridge를 호출해 제품 `GlyphRasterFrame` byte buffer를 만들 수 있는지, 같은 `CTLine` CPU bitmap까지 나오는지 확인한다. 이 smoke는 summary에 `font_identity_ready`, `font_identity_count`, `renderer_input=coretext_shaped_glyph_run_list`, `renderer_shaper=coretext_shaped_records`, `renderer_rasterizer=coretext_glyph_rasterizer`, `renderer_frame_prepared`, `renderer_surface_cols/rows`, `renderer_glyph_raster_*`, `drawlist_input=terminal_core_draw_list`, `drawlist_renderer_shaper=coretext_draw_list`, `drawlist_frame_prepared`, `drawlist_glyph_raster_*` 통계를 남긴다. `font_identity_count`는 공백 같은 비-drawable record를 제외하고 실제 rasterizer가 조회할 drawable glyph face 수를 뜻한다. native CoreText raster 구현은 아직 smoke bridge에 있다. probe record 변환 계약은 `coretext_probe.zig` 단위 테스트가 맡고, surface metadata 보존 및 DrawList shaper bridge 계약은 `coretext_shaper.zig` 단위 테스트와 shaped-input `RendererState` unit test가 맡고, rasterizer wrapper 계약은 `coretext_raster.zig` 단위 테스트가 맡는다. `coretext_frame_builder.zig` 단위 테스트는 active surface snapshot이 `CoreTextDrawListShaper -> CoreTextGlyphRasterizer -> RendererState`를 지나 prepared `AppHostFrame`으로 조립되는 계약을 Objective-C 없이 검증한다. glyph texture smoke는 CPU bitmap이 Metal texture에 byte-preserving upload/readback되는지 확인한다. glyph text smoke는 fixture texture가 실제 AppKit/CAMetalLayer 창에서 shader sampling되어 glyph ink pixel로 보이는지 확인하고, PPM screenshot artifact와 제품 `RendererState/RenderFrame` probe 통계도 남긴다. Metal smoke는 실제 `TerminalCore -> DrawList -> CoreTextDrawListShaper -> RendererState -> RenderFrame -> coretext_raster.zig` 경로가 만든 CoreText atlas slot id와 placement 후보를 native 경계까지 전달하고, `GlyphQuadFrame`이 slot pixel rect를 shader UV로 바꿨는지도 `renderer_glyph_uv_ready`로 남긴다. Metal smoke의 `GlyphRasterFrame`은 `coretext_raster.zig` wrapper를 쓰며, upload 후보가 byte buffer 또는 skip으로 회계 처리됐는지는 `renderer_glyph_raster_ready`, `renderer_glyph_raster_upload_count`, `renderer_glyph_raster_skipped_count`로 남긴다. 같은 Metal smoke는 그 `GlyphRasterFrame.uploads/pixels`를 Metal atlas texture에 올리고 readback byte 비교가 성공했을 때 `product_atlas_uploaded=true`, fragment shader가 같은 atlas를 샘플링해 drawable readback이 source raster의 non-clear texel과 일치하고 `atlas_sample_missing_cells=0`일 때 `product_atlas_sampled=true`를 남기며, 전체 drawable screenshot을 `metal-frame.ppm`으로 썼을 때 `screenshot_artifact=true`를 남긴다. live PTY Metal smoke는 controlled PTY output과 같은 Metal terminal window의 AppKit `keyDown:`에서 app host keybinding resolver를 통과한 scripted key event response에서 만든 `DrawList`가 `FrameLoop.tickAfterDrainWithFrameBuilder -> coretext_frame_builder.zig -> CoreText/Metal` path를 타는지 `renderer_input=surface_runtime_live_pty_frame_loop_coretext_render_frame`, `input_source=appkit_keydown_to_app_host_keybinding_resolver`, `native_key_event_source=metal_terminal_synthetic_keydown` 또는 `metal_terminal_manual_keydown`, `app-pty-metal-frame.ppm`으로 확인한다. interactive Metal smoke는 prompt/dotfile 영향을 받는 실제 shell을 같은 경로에 한 번 연결해 별도 artifact directory에 남긴다. `glyph_text`는 `product_atlas_sampled`이고 그 frame이 실제 CoreText glyph bytes를 쓴 경우에만 참인 증거 기반 라벨이다. upload가 0개인 all-skip frame은 upload/readback 실패가 아니라 sample source 누락으로 기록한다. `AtlasSlot`은 backend UV를 위한 deterministic `x_px/y_px` 좌표 후보를 가진다. manual mode는 물리 키 한 번을 받지만, 사용자가 계속 타이핑하는 제품 interactive shell loop는 아직 별도 단계다.

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
- user-installed font 파일 경로를 직접 지정하게 할지.

다음은 결정·구현 완료다(이력 기록):

- ambiguous width(UAX#11 'A'): config 키 `text.ambiguous-width`(`narrow`(기본)/`wide`)로 노출 완료. 기본 narrow(1 cell), wide opt-in으로 전각 심볼을 2 cell로(`width.cellWidthAmbiguous`/`isWideRenderSymbol`). 위 "Cell Width와 Font Metric" 참고.
- 폰트에 bold/italic face가 없을 때: **regular로 대체**(합성/faux 안 함)로 결정. bold/italic 패밀리는 `font.family-bold`/`font.family-italic`로 따로 지정 가능.
- font config의 fallback family list: `font.fallback`(쉼표 구분)으로 노출 완료 — primary 앞에 두고 CoreText cascade를 잇는다. 위 "FontConfig" 참고.
