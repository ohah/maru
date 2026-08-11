# 모바일 이식 PoC

**"Zig 코어 + 네이티브 GPU"가 iOS/Android 에서 성립하는가**를 실측한다. 설계 논의가
추정 위에서 돌지 않게 하려는 것이고, 제품 코드가 아니다.

```sh
sh tools/mobile-poc/run.sh ios               # 오프스크린 Metal → PNG + 픽셀 판정
sh tools/mobile-poc/run.sh ios-app           # 시뮬레이터 설치·실행 + 스크린샷
sh tools/mobile-poc/run.sh android           # 에뮬레이터 실행 + Vulkan 오프스크린 → PNG
sh tools/mobile-poc/run.sh features-ios      # Metal 로 여섯 기능 판정
sh tools/mobile-poc/run.sh features-android  # Vulkan 으로 같은 여섯 기능 판정
```

## 무엇을 판정하는가

**화면이 뜨는 것으로는 부족하다.** 픽셀을 읽어 "실제로 그려졌다"를 확인한다 — 새
경로를 만들고 통과만 보는 것은 그 경로가 동작한다는 증거가 아니다.

## 결과

| 단계 | iOS | Android |
|---|---|---|
| 15개 모듈 컴파일 | OK | OK |
| 정적 라이브러리 | OK (2.9MB, arm64 Mach-O) | OK (1.5MB, ELF PIE) |
| 코어 실행 | OK | OK |
| 렌더 → 픽셀 검증 | OK (Metal) | OK (Vulkan) |
| 화면 표시 | OK (시뮬레이터 스크린샷) | 미확인 |

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
`26,64,39,90px` 가 iOS·Android 에서 동일하다. 6번은 오프스크린 밖(스왑체인·CAMetalLayer
필요)이라 둘 다 미확인이다.

## 실측으로 드러난 제약

**Zig 가 iOS 용 `libSystem` 을 링크하지 못한다.** `--sysroot` 를 줘도 실패한다. Zig 는
`.a` 까지만 만들고 링크는 clang/NDK 가 맡는다 — 실제 앱에서도 이 구조가 되므로 문제가
아니지만 빌드 파이프라인 설계에 영향을 준다.

**ReleaseSafe 는 panic 핸들러를 갈아야 링크된다.** 기본 핸들러가 스택 트레이스를 찍으려고
`_dyld_get_image_header_containing_address` 를 부르는데 시뮬레이터 SDK 에 없다.
`pub const panic = std.debug.simple_panic;` 한 줄로 해결된다 — **안전 검사(overflow·bounds)는
그대로 살고** 스택 트레이스만 빠진다. `probe.zig` 에 그렇게 넣어 두었다.

**Android 는 PIE 가 필수라 `-fPIC` 가 필요하다.** 정적 라이브러리도 위치 독립이어야 한다.

**Vulkan 은 NDC 의 Y 가 아래로 향한다**(Metal 은 위로). 같은 rect·같은 UV 를 주면 텍스처가
상하로 뒤집힌다 — 아틀라스 패치가 화면 반대편에 나와 실측으로 잡았다. 이식할 때 draw-list
투영에서 이 차이를 흡수해야 한다.

## 범위 밖

present 페이싱, 실기기, 입력·IME, 백그라운드 생명주기, Android 화면 표시.
에뮬레이터 GPU 가 `llvmpipe`(소프트웨어 래스터라이저)라 **실제 Android 드라이버에서
같은 결과가 나오는지는 실기기로 확인해야 한다.**
