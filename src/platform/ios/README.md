# `src/platform/ios`

iOS 전용 bridge를 담는 폴더다.

CoreText shaper, Metal 백엔드, UIKit host(창·터치·소프트 키보드·IME), 앱 생명주기를
이곳에 둔다. `platform/macos`와 Metal·CoreText를 공유할 수 있으므로 그 둘의 공통분모를
어디에 둘지는 실제 이식 때 정한다.

이식 가능성은 [모바일 PoC](../../../tools/mobile-poc/README.md)에서 실측했다 — 코어
15개 모듈이 컴파일되고, 시뮬레이터에서 Metal 렌더까지 확인했다.
