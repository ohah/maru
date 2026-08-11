# 모바일 이식 PoC

**"Zig 코어 + chrome 컴포넌트 + 네이티브 GPU"가 iOS/Android 에서 성립하는가**를 실측한다.
설계 논의가 추정 위에서 돌지 않게 하려는 것이고, 제품 코드가 아니다.

```sh
sh tools/mobile-poc/run.sh ios               # 오프스크린 Metal → PNG + 픽셀 판정
sh tools/mobile-poc/run.sh ios-app           # 시뮬레이터 설치·실행 + 스크린샷
sh tools/mobile-poc/run.sh android           # 에뮬레이터 실행 + Vulkan 오프스크린 → PNG
sh tools/mobile-poc/run.sh features-ios      # Metal 로 여섯 기능 판정
sh tools/mobile-poc/run.sh features-android  # Vulkan 으로 같은 여섯 기능 판정
sh tools/mobile-poc/run.sh chrome-ios        # **실제 chrome 컴포넌트**를 시뮬레이터에
sh tools/mobile-poc/run.sh chrome-android    # 같은 draw-list 를 Vulkan 으로
```

## 무엇을 판정하는가

**화면이 뜨는 것으로는 부족하다.** 픽셀을 읽어 "실제로 그려졌다"를 확인한다 — 새
경로를 만들고 통과만 보는 것은 그 경로가 동작한다는 증거가 아니다.

## 결과

| 단계 | iOS | Android |
|---|---|---|
| 15개 모듈 컴파일 | OK | OK |
| 정적 라이브러리 | OK (arm64 Mach-O) | OK (ELF PIE) |
| 코어 실행 | OK | OK |
| 렌더 → 픽셀 검증 | OK (Metal) | OK (Vulkan) |
| **실제 chrome 컴포넌트 렌더** | **OK** | **OK** |
| 화면 표시 | OK (시뮬레이터) | 오프스크린만 |

### 여섯 기능 — maru 가 Metal 세부를 파고들어 얻은 것들

| | iOS (Metal) | Android (Vulkan) |
|---|---|---|
| 1. per-cell clip (ABI v169) | **PASS** | **PASS** |
| 2. blink opacity uniform | **PASS** | **PASS** |
| 3. per-draw blend (premul↔straight) | **PASS** | **PASS** |
| 4. 아틀라스 부분 업데이트 | **PASS** | **PASS** |
| 5. 자연폭 quad | **PASS** | **PASS** |
| 6. present 페이싱 | 미확인 | 미확인 |

**두 백엔드가 픽셀 단위로 같은 값을 낸다** — opacity `G=64,128,191,255`, 자연폭 구간
`26,64,39,90px` 가 동일하다. 6번은 스왑체인·CAMetalLayer 가 있어야 해 오프스크린 밖이다.

### chrome 컴포넌트 + 텍스트 + 아이콘 (PoC 6)

`chrome_probe.zig` 가 `chrome.ui.tree` 로 탭 바·사이드바·본문·상태바를 조립하고
`tree.build` → `paint` 로 ChromeDraw 를 얻은 뒤, 플랫폼이 그 op 만 그린다.
**플랫폼은 배치를 모른다** — 화면 크기만 넘기고 quad 목록을 받는다.

| | iOS (Metal) | Android (Vulkan) |
|---|---|---|
| chrome 레이아웃 | OK | OK |
| **한글·영어 글리프** | OK | OK |
| **SVG 아이콘 6종** | OK (6/6) | OK (6/6) |
| safe area | 반영 | N/A(오프스크린) |

**아이콘은 Zig 가 만든다.** `renderer/icon_glyph.fillCoverage` 가 등록된 SVG 자산을
coverage 로 펴고 플랫폼은 텍스처로 올려 샘플링만 한다 — **자산이 플랫폼 코드 0줄로
이식된다**는 증거다.

**텍스트는 호스트 아틀라스를 쓴다.** Android NDK 에 폰트 래스터가 없어 macOS CoreText 로
아틀라스를 만들어 양쪽이 같은 것을 읽는다(`make_atlas.m`). 실제 제품은 각 플랫폼이 자기
폰트 스택으로 래스터한다. 한글 폭은 EAW 규칙대로 2셀이다.

## 실측으로 드러난 제약

**Zig 가 iOS 용 `libSystem` 을 링크하지 못한다.** Zig 는 `.a` 까지만 만들고 링크는
clang/NDK 가 맡는다 — 실제 앱에서도 이 구조가 된다.

**ReleaseSafe 는 panic 핸들러를 갈아야 링크된다.** 기본 핸들러가
`_dyld_get_image_header_containing_address` 를 부르는데 시뮬레이터 SDK 에 없다.
`pub const panic = std.debug.simple_panic;` 한 줄로 해결된다 — **안전 검사는 그대로 살고**
스택 트레이스만 빠진다.

**Android 는 PIE 가 필수라 `-fPIC` 가 필요하다.**

**Vulkan 은 NDC 의 Y 가 아래로 향한다**(Metal 은 위로). 같은 rect·UV 로 텍스처가 상하
반전된다 — 아틀라스 패치가 화면 반대편에 나와 잡았다.

**Metal 셰이더 구조체와 C 구조체의 정렬이 다르다.** `float2` 가 8바이트 정렬을 요구해
필드가 밀리고 NDC 변환이 깨졌다 — quad 26개가 생성되는데 화면은 검은 상태였다.
**전부 `float4` 로 맞춰 해결했다.** draw-list 를 C ABI 로 넘기는 구조에서 반복될 종류다.

**자식 노드 슬라이스의 수명을 놓치기 쉽다.** `&.{tree.text(...)}` 는 임시 배열의 주소라
루프를 벗어나면 dangling 이고, `build` 가 그 쓰레기를 읽어 **`DuplicateIdentity` 로**
튄다 — 증상이 원인을 안 가리키는 종류라 값을 찍어 보고서야 알았다.

**`ui.paint` 는 텍스트 op 을 내지 않는다.** `resolveText` 결과를 버리고 typography/lowering
이 따로 맡는 구조다. PoC 는 레이아웃 트리의 text entry rect 를 읽어 그 자리에 글리프를 그린다.

**아이콘 coverage 는 RGBA8 버퍼를 요구한다.** `glyph_pixels.slotFits` 가
`bytes_per_row >= width*4` 를 검사하는데, 단일 채널을 주면 **조용히 0을 돌려준다** —
`filled=0/6` 이 나와도 오류가 아니라 성공처럼 보인다. 셰이더는 alpha 를 coverage 로 읽는다.

**모듈 루트는 `maru.zig` 하나여야 한다.** `chrome` 과 `renderer` 를 따로 주면 둘 다
`icons.zig` 를 상대 경로로 끌어와 "file exists in two modules" 로 깨진다.

**글리프 폭은 셀이 아니라 폰트 advance 로 정한다.** 셀 폭(24px)을 진행 폭으로 쓰면 영문이
그 칸에 갇혀 **자간이 벌어진다**. quad 크기도 셀 종횡비(24:32)를 지켜야 글자가 안 늘어난다.

**폭을 늘릴 때는 `.fill` 이 아니라 `flex.grow` 다.** `card` 의 기본 `direction` 은 `column`
이라 자기 기준으로 width 가 **cross axis** 가 되고, `.fill` 은 main axis 전용이라
`FillOnCrossAxis` 로 거부된다. 부모(row)가 폭을 나눠 주게 하려면 grow 를 쓴다.

**아이콘 크기는 자산마다 다르다.** `fillCoverage` 는 모두 같은 슬롯에 중앙 배치하지만 SVG
여백이 달라 시각 크기가 갈린다. maru 는 이걸 `icons.Fit`(standard/tight)으로 다루고
`search-tight` 같은 별도 자산이 그 증거다 — 모바일에서도 같은 축이 필요하다.

**iOS 는 safe area 를 반영해야 한다.** 창 전체에 그리면 상태바·다이내믹 아일랜드 밑으로
UI 가 들어간다. 데스크톱에서 타이틀바 inset 을 다루는 것과 같은 종류이고, 실제 이식에서는
이 inset 을 L1 DTO 로 chrome 에 전달해야 한다.

## 범위 밖

present 페이싱, **각 플랫폼의 자체 폰트 래스터**(지금은 호스트 아틀라스를 공유한다),
실기기, 입력·IME, 백그라운드 생명주기, Android 화면 표시(오프스크린까지만).

에뮬레이터 GPU 가 `llvmpipe`(소프트웨어)라 **실제 Android 드라이버에서 같은 결과가
나오는지는 실기기로 확인해야 한다.**
