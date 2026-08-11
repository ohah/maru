# `src/platform/android`

Android 전용 bridge를 담는 폴더다.

Vulkan 백엔드, NDK host(창·터치·IME), 앱 생명주기를 이곳에 둔다. Metal이 없으므로
GPU 백엔드는 `platform/macos`와 공유되지 않고 **Linux와 공유된다** — Vulkan 백엔드
하나가 두 타깃을 덮는다.

이식 가능성은 [모바일 PoC](../../../tools/mobile-poc/README.md)에서 실측했다 — 코어가
에뮬레이터에서 실행되고 Vulkan 오프스크린 렌더까지 확인했다.
