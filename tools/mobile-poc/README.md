# 모바일 이식 PoC

**"Zig 코어 + 네이티브 GPU"가 iOS/Android 에서 성립하는가**를 실측한다. 설계 논의가
추정 위에서 돌지 않게 하려는 것이고, 제품 코드가 아니다.

```sh
sh tools/mobile-poc/run.sh ios       # 오프스크린 Metal → PNG + 픽셀 판정
sh tools/mobile-poc/run.sh ios-app   # 시뮬레이터 설치·실행 + 스크린샷
sh tools/mobile-poc/run.sh android   # 에뮬레이터 실행 + Vulkan 디바이스 열거
```

## 무엇을 판정하는가

**화면이 뜨는 것으로는 부족하다.** 픽셀을 읽거나 디바이스 수를 세어 "실제로
그려졌다"를 확인한다 — 새 경로를 만들고 통과만 보는 것은 그 경로가 동작한다는
증거가 아니다.

| 확인 | 방법 |
|---|---|
| 코어가 실행되나 | ANSI 시퀀스를 파싱시키고 채워진 셀 수를 센다 |
| Metal 이 그리나 | 오프스크린 텍스처를 읽어 색을 판정하고 PNG 로 남긴다 |
| Vulkan 이 열리나 | `vkCreateInstance` + 물리 디바이스 열거 |

## 실측으로 드러난 제약

**Zig 가 iOS 용 `libSystem` 을 링크하지 못한다.** `--sysroot` 를 줘도 실패한다.
그래서 Zig 는 `.a` 까지만 만들고 링크는 clang/NDK 가 맡는다 — 실제 앱에서도 이
구조가 되므로 문제가 아니지만, 빌드 파이프라인 설계에 영향을 준다.

**ReleaseSafe 가 iOS 시뮬레이터에서 링크되지 않는다.** panic 핸들러의 스택 트레이스가
`_dyld_get_image_header_containing_address` 를 참조하는데 시뮬레이터 SDK 에 없다.
여기서는 ReleaseFast 로 우회했다. **제품에서 ReleaseSafe 를 쓰려면 panic 핸들러를
직접 정의해야 한다.**

**Android 는 PIE 가 필수라 `-fPIC` 가 필요하다.** 정적 라이브러리도 위치 독립이어야
한다.

## 결과

| 단계 | iOS | Android |
|---|---|---|
| 15개 모듈 컴파일 | OK | OK |
| 정적 라이브러리 | OK (2.9MB, arm64 Mach-O) | OK (1.5MB, ELF) |
| 코어 실행 | OK | OK |
| GPU 디바이스 | Metal OK | Vulkan OK (물리 디바이스 1) |
| 렌더 → 픽셀 검증 | OK (87% 점등) | 미확인 — Vulkan 파이프라인은 범위 밖 |
| 화면 표시 | OK (시뮬레이터 스크린샷) | 미확인 |

`out/` 의 이미지가 그 증거다.

## 범위 밖

Vulkan 렌더 파이프라인, 실기기, 입력·IME, 앞서 정리한 여섯 기능(per-cell clip ·
blink opacity uniform · blend 모드 · 아틀라스 부분 업데이트 · 자연폭 quad ·
present 페이싱)은 **확인하지 않았다.** 그 여섯이 진짜 관문이다.
