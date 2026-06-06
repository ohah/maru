# 렌더러 전략

이 문서는 Maru의 렌더러가 무엇을 목표로 하고, Wasm과 WebGPU를 어떻게 구분하는지 정한다. 폰트 선택, glyph cache, atlas, fallback 세부 정책은 [폰트 전략](font-strategy.md)을 단일 출처로 둔다.

## 결론

Maru의 초기 실제 backend는 **Metal-first**로 둔다.

다만 `TerminalCore`와 app model은 Metal을 직접 알면 안 된다. 중간에 `RenderSnapshot -> DrawList` 계약을 두고, Metal backend는 그 `DrawList`만 소비한다. 장기적으로 WebGPU backend를 추가하더라도 같은 `DrawList`를 소비하게 만든다.

```text
TerminalCore
-> RenderSnapshot
-> DrawList
-> Metal backend, macOS first
-> future WebGPU backend
```

이렇게 정하는 이유는 현재 Maru의 우선순위가 macOS-first, 가벼운 native shell, 런타임 의존성 0이기 때문이다. WebGPU-only로 시작하면 장기 이식성은 좋아지지만, native WebGPU 구현체(Dawn/wgpu-native/mach 계열)에 의존해야 하거나 직접 많은 glue를 만들어야 한다. 지금 단계에서는 그 비용이 터미널 본질보다 먼저 커진다.

## 결정 기록

2026-06-04 기준 결정:

```text
선택:
  Metal-first

유지할 경계:
  RenderSnapshot -> DrawList -> Backend

나중에 추가할 수 있는 것:
  DrawList -> WebGPU backend

지금 하지 않는 것:
  WebGPU-only renderer
  browser/Wasm target
  native WebGPU runtime dependency
```

이 결정은 "WebGPU를 포기한다"는 뜻이 아니다. 초기 macOS 앱에서 WebGPU를 먼저 선택하지 않는다는 뜻이다.

Maru가 지금 풀어야 할 1차 문제는 GPU API 통일이 아니라, PTY output이 `TerminalCore`, snapshot, artifact, renderer 입력까지 안정적으로 흐르는 것이다. WebGPU-first는 이 문제를 풀기 전에 graphics runtime 선택과 이식성 문제를 앞당긴다.

WebGPU backend를 검토할 조건:

- Metal backend가 `DrawList`만 소비하고 있다는 것이 테스트로 증명되어 있다.
- renderer hot path가 PTY/parser/snapshot과 분리되어 있다.
- Windows/Linux/browser target을 실제로 시작할 단계다.
- 새 native WebGPU dependency를 추가해도 되는지 사용자와 별도 논의했다.

## WebGPU vs Metal

터미널 렌더링은 일반적인 3D 앱보다 단순하다.

- glyph atlas texture
- cell별 quad 또는 instance buffer
- foreground/background color
- cursor, selection, underline
- dirty region redraw

이 workload에서는 Metal과 WebGPU의 순수 GPU 성능 차이보다, font shaping, glyph cache, atlas upload, dirty tracking, PTY/parser backpressure가 더 자주 병목이 된다.

그래도 macOS만 놓고 보면 Metal이 유리하다.

| 선택 | 장점 | 단점 |
| --- | --- | --- |
| Metal-first | macOS에서 가장 직접적이다. 추가 graphics runtime 의존성이 적다. Apple GPU/debug tooling과 잘 맞는다. latency와 presentation 제어가 쉽다. | Windows/Linux/browser backend를 나중에 따로 추가해야 한다. Metal 개념이 코드 안으로 새면 이식성이 나빠진다. |
| WebGPU-first | Windows/Linux/browser까지 같은 API 모델로 갈 수 있다. Wasm target과 잘 맞는다. renderer backend 추상화가 빨리 생긴다. | native macOS 앱에서도 WebGPU 구현체 의존성이 생긴다. 디버깅 stack이 한 겹 늘어난다. WebGPU API 제약 때문에 Metal의 세부 기능을 직접 쓰기 어렵다. |

따라서 Maru의 추천 전략은 **Metal-first implementation, backend-neutral DrawList contract**다.

## Ghostty는 어떻게 하는가

Ghostty는 WebGPU를 쓰지 않는다. 로컬 reference 기준으로 renderer facade 아래에 다음 backend를 둔다.

```text
references/ghostty/src/renderer.zig
  Metal
  OpenGL
  WebGL
```

즉 Ghostty의 전략은 "하나의 WebGPU backend로 모든 target을 덮는다"가 아니다. 공통 renderer 로직을 두고, 플랫폼/target별 graphics API backend를 붙인다.

```text
macOS native
  -> Metal

Linux native
  -> OpenGL

browser target
  -> WebGL
```

Maru가 참고할 지점은 특정 코드가 아니라 이 추상화 방향이다.

- terminal core는 graphics API를 모른다.
- renderer facade는 공통 draw contract를 가진다.
- 실제 backend는 platform target에 맞게 고른다.
- browser target은 native target과 다른 backend를 가질 수 있다.

Maru는 Ghostty 코드를 복사하지 않는다. 다만 같은 문제를 풀 때, macOS native terminal에서 Metal-first가 자연스럽고 Web target은 별도 backend로 보는 판단은 참고할 수 있다.

## Wasm과 WebGPU는 다르다

초보자가 헷갈리기 쉬운 부분이다.

- Wasm은 코드를 실행하는 target이다. Zig 코드를 browser에서 실행할 수 있게 만드는 컴파일 결과에 가깝다.
- WebGPU는 GPU에 그림을 그리라고 명령하는 graphics API다.

즉 "Wasm을 쓴다"는 말은 앱 코드가 browser 안에서 돈다는 뜻이고, "WebGPU를 쓴다"는 말은 그림을 그리는 방식이 WebGPU API라는 뜻이다.

Maru의 장기 구조는 다음처럼 생각한다.

```text
Native macOS app, initial
  Zig code
  -> RenderSnapshot
  -> DrawList
  -> Metal backend

Future browser target
  Zig compiled to Wasm
  -> RenderSnapshot
  -> DrawList
  -> WebGPU JavaScript/browser API
  -> browser GPU backend
```

따라서 Wasm은 장기 target이고, WebGPU는 미래 backend 후보다. 지금 당장 Wasm runtime이나 browser build를 구현하지 않는다.

## 텍스트 셰이핑과 dirty region

backend(Metal/WebGPU) 선택과 별개로, 두 가지를 어디서 처리하는지 계약으로 고정해 둔다. 둘 다 `RenderSnapshot -> DrawList` 경계 안쪽 책임이고, `TerminalCore`와 app model은 몰라야 한다.

텍스트 셰이핑:

- 초기에는 macOS-first에 맞춰 **CoreText**로 shaping과 font fallback을 한다. 추가 런타임 의존성이 없고 Apple 글꼴 스택과 가장 잘 맞는다.
- 단, shaping 결과는 backend-neutral한 `GlyphRunList`(코드포인트, glyph id, 셀 좌표, 색)로만 표현한다. CoreText 타입을 `DrawList`나 `GlyphRunList` 공개 계약으로 노출하지 않는다.
- 그래서 나중에 cross-platform이 필요하면 같은 경계 뒤에서 **HarfBuzz** 같은 shaper로 교체할 수 있다. ligature/complex script 최적화는 아래 "지금 선택하지 않는 것"으로 둔다.
- 구체적인 fallback, cell width, glyph atlas cache key, emoji 정책은 [폰트 전략](font-strategy.md)을 따른다.

dirty region 범위:

- 장기 목표는 cell 단위 dirty다. 다만 현재 `TerminalCore`/snapshot 계약은 `start_row/end_row` row 범위만 가진다.
- 초기 `DrawList`는 현재 코드 계약에 맞춰 dirty row 범위만 draw command로 만든다. 한 cell만 바뀌어도 그 row의 셀들이 들어가는 것이 현재 정상 경로다.
- cell 단위 dirty는 `TerminalCore`의 dirty 모델을 확장하는 별도 PR에서 진행한다. renderer가 화면을 스캔해 직접 dirty를 추론하지 않는 원칙은 유지한다.
- cursor 이동과 resize는 각각 dirty 범위를 만든다. 이 범위 산출은 domain 쪽 계약이고 GPU와 무관하다. 현재 `TerminalCore`는 CR/backspace/line feed 같은 cursor-only 이동에서도 old/new cursor row를 dirty로 만든다. selection은 아직 domain data가 없으므로 selection dirty는 selection 모델을 도입할 때 별도 PR에서 고정한다.
- cursor와 underline은 glyph bitmap이 아니라 draw-time overlay다. `DrawList`는 `DrawCell`과 별도로 overlay command를 내보내며, cursor overlay는 dirty row에 cursor가 포함될 때만 생성한다.
- 검증은 아래 "검증 전략"의 "dirty region이 draw command 범위를 줄이는지 확인하는 test"로 고정한다.

## 지금 선택하지 않는 것

초기에는 다음을 하지 않는다.

- Metal 전용 renderer API를 `TerminalCore`, `Surface`, `Snapshot` public contract로 고정하지 않는다.
- browser/Wasm build를 초기 성공 기준에 넣지 않는다.
- WebGL fallback을 넣지 않는다.
- 고급 glyph atlas, ligature shaping, subpixel positioning을 먼저 최적화하지 않는다.

## 초기 구현 순서

1. `RenderSnapshot`을 GPU와 무관한 domain data로 유지한다.
2. `RenderSnapshot -> DrawList` 변환을 먼저 테스트한다.
3. `DrawList`를 Metal backend가 소비하는 형태로 만든다. cursor/underline은 cell overlay로 두고, cursor 이동(old/new cell)이 dirty 범위에 들어오도록 domain 계약을 유지한다.
4. macOS app smoke에서 screenshot artifact를 남긴다.

이 순서가 중요한 이유는 GPU screenshot을 먼저 붙이면 실패 원인이 parser인지, snapshot인지, glyph atlas인지, GPU pipeline인지 구분하기 어렵기 때문이다. 먼저 deterministic한 `DrawList`를 만들면 renderer의 입력 계약을 작은 테스트로 고정할 수 있다.

## 검증 전략

기본 `mise run check`에 넣을 수 있는 것:

- snapshot을 draw command model로 바꾸는 unit/golden test.
- 현재 row dirty region이 draw command 범위를 줄이는지 확인하는 test.
- cursor-only 이동이 dirty row를 만들고, `DrawList`가 cursor/underline overlay command를 내보내는 test.
- fake font backend를 사용한 `DrawList -> GlyphRunList` test.
- GPU 없는 `GlyphCacheKey -> AtlasSlot` cache/invalidation test.
- renderer가 PTY, parser, live platform handle을 import하지 않는 boundary test.

opt-in으로 둘 것:

- macOS window server가 필요한 screenshot smoke.
- 실제 Metal device 생성.
- 실제 AppKit 창 위 CAMetalLayer `DrawList` placeholder present/readback smoke(`mise run macos-metal-smoke`).
- 실제 CoreText font resolve/glyph run/atlas key/CPU glyph raster smoke(`mise run macos-coretext-smoke`).
- 실제 CoreText CPU bitmap -> Metal texture upload/readback smoke(`mise run macos-glyph-texture-smoke`).
- 실제 glyph texture shader sampling/text draw smoke.
- frame pacing, GPU timing, font stack 영향을 받는 성능 측정.

## clean-room 기준

renderer 구현도 reference terminal source를 line-by-line으로 참고하지 않는다. Metal/WebGPU platform 문서, Maru의 독립 설계, 동작 비교 artifact를 근거로 삼는다.
