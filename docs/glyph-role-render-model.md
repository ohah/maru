# 글리프 역할(role) 렌더 모델

글리프를 셀(atlas 슬롯) 안에 그릴 때 **자연 메트릭+baseline으로 둘지, 셀에 맞춰 축소/중앙정렬할지**를 정하는 단일 출처 문서다. `font.letter-spacing` 자연폭 모델(→ [폰트 전략](font-strategy.md) "Cell Width와 Font Metric")과 함께 maru의 글리프 배치 정책을 이룬다.

## 결론

글리프 배치는 **글리프의 역할(role)** 로 정한다 — 런타임 픽셀 측정이 아니라.

- **텍스트**(letter/digit/punctuation, 모든 스크립트) → **자연 메트릭 + 공통 baseline**. 절대 스케일·세로 재정렬하지 않는다. ink가 advance를 미세하게 넘어도(타이트한 폰트의 `w`·`m`·`@` 등) 그대로 둔다(이웃 셀로의 미세 overflow는 모노스페이스 bearing의 정상 동작).
- **wide-render-symbol**(폰트가 셀보다 넓게 그리는 기호 — Enclosed Alphanumerics ①②③ U+2460~24FF) → 셀에 안 들어가면 **cover-fit**(종횡비 유지 축소).
- **emoji**(컬러 글리프) → cover-fit + **ink-center**(보이는 픽셀 세로중앙).
- **legacy centred symbol**(◧ U+25E7·⚙ U+2699 — **터미널 콘텐츠 전용**) → ink-center. 래스터의 `center_symbol`은 이 **두 codepoint만** 매칭한다. maru 헤더 아이콘은 2026-08 이후 등록 PUA라 이 역할이 아니라 합성(synthesized) 경로다.
- **synthesized**(box/block/powerline/braille/legacy + **등록 chrome 아이콘**(maru PUA) — `glyph_id==0`) → zig 렌더러가 절차적으로 그린다(slot=셀폭, 타일링). 이 경로(rasterize-glyph) 자체에 **안 온다** — chrome 아이콘은 `maru_is_synthesized_glyph`로 분류돼 합성되므로 header-icon 게이트가 아니다.

핵심: **텍스트는 어떤 폰트에서도 스케일/ink-center되지 않는다(correctness by construction).** 셀에 맞춤(fit) 또는 중앙정렬(center)은 역할로 명시된 비-텍스트 글리프에만 적용한다.

## 배경: 왜 역할 기반인가 (해결한 버그)

이전 구현은 래스터(`coretext_smoke.m`)에서 **모든 글리프에 `ink_width > slot_width`** 를 측정해, 넘으면 cover-fit + `maru_center_ink_vertically`(ink 세로중앙) 경로로 보냈다. 이는 두 가지가 근본적으로 약했다.

1. **잡음 기반 거짓 트리거**: 모노스페이스 글리프의 ink폭이 advance와 같거나 거의 같으면(예: **Hack `w`는 ink폭 == advance**), slot=`round(advance)`이 내림될 때 ink가 slot을 ~0.5px 넘어 거짓 트리거됐다. descender 없는 `w`가 ink-center되면 baseline보다 위로 떠 보였다(Hack에서만 보고 — JetBrains Mono `w`는 ink<advance라 여유가 있어 안 걸림). 폰트 크기의 반올림 방향에 따라 떴다 안 떴다 했다.
2. **레이어 불일치**: maru의 폭 정책(`src/width.zig`)은 EAW Ambiguous 중 **isWideRenderSymbol(①②③)만** "셀보다 넓음"으로 인정한다(`cellWidthAmbiguous`·`draw_list` constraintWidth). 그런데 래스터의 bare `ink>slot`은 폭 레이어가 narrow라 한 텍스트 `w`까지 멋대로 스케일했다 — 폭 레이어와 렌더 레이어가 어긋났다.

역할 기반은 cover-fit 게이트를 **maru의 기존 폭 정책에 일치**시킨다: 래스터가 셀에 맞추는 대상 = 폭 레이어가 "셀보다 넓음"으로 인정한 집합(`isWideRenderSymbol`) + emoji + header icon. 텍스트는 구조적으로 제외된다.

## 레퍼런스 조사

어려운 렌더 동작은 추론보다 레퍼런스 소스를 직접 읽어 베이스를 잡는다(→ [규칙](project-rules.md)). 모든 주요 터미널이 **텍스트는 자연 메트릭으로 두고, 셀-맞춤/절차적 그리기는 코드포인트 역할/범위로 한정**한다 — 런타임 ink 측정을 모든 글리프에 적용하지 않는다.

| 터미널 | 텍스트 글리프 | 기호/박스 | ink 세로 재정렬 | 근거 |
| --- | --- | --- | --- | --- |
| **Ghostty** | `.none`(자연 메트릭+baseline, 손 안 댐) | `getConstraint(cp)`(Nerd Font 테이블) ‖ `isSymbol(cp) ? .fit : .none` — fit는 축소만 | 안 함("we don't modify the alignment at all") | `renderer/generic.zig:3189`, `font/face.zig` Constraint |
| **xterm.js** | 자연 메트릭 래스터, 넘치면 **클립**(`restrictToCellHeight`) | box/powerline/legacy = **절차적 커스텀 글리프**(`CustomGlyphRasterizer`) | 안 함 | `addon-webgl/src/TextureAtlas.ts`, `customGlyphs/` |
| **Alacritty** | 폰트에서 가져오고 넓은 건 클립 | box(U+2500–259F)·legacy·powerline = **내장 절차 폰트** | 안 함 | 내장 box-drawing 렌더러 |
| **Kitty** | 폰트 래스터 | box/quadrant/powerline = **직접 그림**, emoji 크기 보정 | emoji만 | Kitty 렌더 문서 |
| **Windows Terminal** | 자연 메트릭 | box/line(U+2500–259F)을 **셀에 맞춰 스케일** | 안 함 | PR microsoft/terminal#5743 |
| **WezTerm** | 자연 메트릭 | 심볼 폰트 스케일을 config로 | 안 함 | 폰트 스케일/fallback 설정 |

공통점: **(a) 텍스트는 자연 메트릭+baseline**(아무도 텍스트를 ink-center하지 않는다), **(b) 셀-맞춤/절차 그리기는 특정 범위(box·powerline·legacy·기호)에만**, **(c) 역할/범위로 결정**(전역 ink 측정 아님). maru는 (a)(b)(c)를 모두 따르되, box류는 이미 절차 합성(`maru_is_synthesized_glyph`)하고, 셀-맞춤은 `isWideRenderSymbol`로 한정한다.

## maru의 역할 매핑 (이미 가진 조각들)

maru는 역할 분류 조각을 이미 갖고 있다. 버그는 분류 부재가 아니라 **cover-fit 게이트가 이 정책을 우회**한 것이었다.

| 역할 | 단일 출처 | 래스터 게이트(`coretext_smoke.m`) |
| --- | --- | --- |
| synthesized | `renderer/{box,block,powerline,braille,legacy,icon}_glyph.zig` ↔ `maru_is_synthesized_glyph`(등록 chrome PUA 아이콘 포함) | (이 경로 밖 — `glyph_id==0`) |
| emoji | 폰트 컬러 테이블(sbix/COLR) | `maru_font_is_color(draw_font)` |
| wide-render-symbol | **`width.isWideRenderSymbol`** (U+2460~24FF) | `is_wide_render_symbol`(미러) `&& ink>slot` |
| legacy centred symbol(터미널 콘텐츠) | `0x25E7`(◧)·`0x2699`(⚙) **두 codepoint만** | `center_symbol` |
| text | 위 어디에도 안 듦 | (셋 다 false → 자연+baseline) |

cover-fit 게이트 = `is_emoji ‖ center_symbol ‖ (is_wide_render_symbol && ink>slot)`. 텍스트는 셋 다 거짓이라 자연 메트릭+baseline 경로로 간다.

## SSOT와 미러링

역할은 **codepoint의 순수 함수**이므로 단일 출처는 `src/width.zig`다(`isWideRenderSymbol` 등). 래스터 `coretext_smoke.m`은 이 집합을 **주석-동기 미러**로 둔다 — `maru_is_synthesized_glyph`·`maru_category_for_codepoint`가 이미 같은 방식인 것과 동일한 이유다: 이 `.m`은 여러 최소 smoke 실행파일(`build.zig`의 `macos_metal_smoke`·`macos_app_pty_metal_smoke` 등)에 컴파일되어 **풀 코어를 링크하지 않으므로**, zig 심볼을 직접 호출하면(C-ABI export) smoke 모듈성이 깨진다. 미러는 `width.zig`를 가리키는 동기 주석을 단다.

- **후속(이식성)**: 백엔드가 늘면(Linux/Win) 미러 중복을 없애려면 `width.glyphRole`을 C-ABI로 export하고 smoke 하니스를 분리하거나, 역할을 `NativeDrawCell.reserved`에 실어 plumbing한다. 지금은 smoke 모듈성·저위험을 위해 미러 유지(→ [레이어링과 이식성](layering-and-portability.md)).

## 트레이드오프와 한계

- **wide-render-symbol 밖의 기호**(geometric ◆·dingbat ✦ 등 **비합성** 단색 기호): 폰트가 셀보다 넓게 그려도 fit-scale하지 않고 자연 메트릭으로 둔다(이웃으로 미세 overflow 또는 슬롯 경계 클립). 이는 xterm.js·Alacritty(클립)와 일치하고 maru 폭 정책(`isWideRenderSymbol`만 wide)과도 일관된다. **영향 범위는 작다** — box/block/powerline/braille/legacy·chrome 아이콘은 절차 합성(`maru_is_synthesized_glyph`, `glyph_id==0`)이라 이 경로에 안 오고, 번들 폰트(JetBrains Mono·Fira·Cascadia·Hack)는 Nerd Font가 아니라 PUA 아이콘 글리프가 없다. 실제 대상은 폰트가 1칸보다 의미 있게 넓게 그리는 비합성 기호 소수뿐. 특정 기호가 fit이 필요하면 `width.isWideRenderSymbol`에 **한 곳만** 추가한다.
- **왜 `isWideRenderSymbol` 게이트인가(텍스트-제외 게이트 대신)**: Ghostty는 포괄적 Unicode 카테고리(`isSymbol`)로 "기호 전체"를 fit하지만, maru의 `src/width.zig`는 의도적으로 최소 테이블이라 포괄적 text/symbol 분류가 없다. "텍스트면 cover-fit 제외"(`!isText`) 게이트는 **미수록 스크립트**(아르메니아·조지아·태국 등)의 타이트한 글자가 분류에서 빠지면 다시 떠오를 수 있다 — 즉 회귀의 핵심(텍스트 들뜸)을 일부 스크립트에 재도입할 위험. 반면 `isWideRenderSymbol`(U+2460~24FF)은 **어떤 스크립트의 텍스트도 절대 이 집합에 없으므로** 텍스트 들뜸을 전 스크립트에서 0으로 보장한다. 비용은 위의 "비합성 기호 fit 상실"(소수, 문서화된 트레이드오프)이고, 이쪽이 보고된 버그 클래스(텍스트 들뜸)를 더 확실히 막는다. 포괄적 fit이 필요해지면 width.zig에 Unicode symbol 분류를 들이고 게이트를 거기로 확장한다(후속).
- **텍스트의 미세 가장자리**: ink가 advance를 ~0.5px 넘는 타이트한 글리프는 advance-center에서 가장자리 안티앨리어싱이 최대 ~1px 깎일 수 있으나, 세로로 뜨는 것보다 눈에 띄지 않는다(Ghostty·xterm.js도 텍스트 overflow를 허용/클립).

## 검증

- 단위(`src/width.zig`): 역할 분류 테스트 — `w`/ASCII/CJK는 wide-render-symbol 아님(=cover-fit 제외), ①②③은 wide-render-symbol(=cover-fit 대상).
- 헤드리스(`MARU_SCREENSHOT`): Hack `w` 무자간 — baseline 정렬(뜨지 않음), ① 좁은 셀에서 fit. **단 모달/커서/장식 경로는 첫-frame 캡처로 못 봐 라이브 수동 검증 병행**(→ [검증 매트릭스](verification-matrix.md)).
- 라이브: Hack `workspace`의 `w`가 이웃 글자와 baseline 일치, ① 등 동그란 번호가 셀에 온전, 헤더 아이콘(gear·plus·bell·sidebar_collapse — 등록 PUA) 세로 정렬 유지.
