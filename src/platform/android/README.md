# `src/platform/android`

Android 전용 bridge를 담는 폴더다. 계약은 [모바일 플랫폼](../../../docs/mobile-platform.md)이
단일 출처다.

| 파일 | 무엇 |
|---|---|
| `android_app_host.c` | `NativeActivity` host — 창·생명주기·터치, Vulkan 백엔드, JNI `Paint` 폰트 래스터 |
| `MaruActivity.java` | **IME shim** — 소프트 키보드가 만든 조합 중/확정 문자열을 JNI로 넘긴다 |
| `AndroidManifest.xml` | `dev.maru.MaruActivity` 선언 |
| `shaders/` | SPIR-V 소스 |

**IME는 NDK가 아니라 Java shim이 받는다.** NDK에는 `InputConnection`에 해당하는 것이 없고,
`NativeActivity`만으로는 소프트 키보드가 ASCII 물리 키 이벤트를 줄 때만 입력이 된다 —
한글 조합이 안 된다. 이유와 대안 비교는 계약 §1이 소유한다.

**Vulkan 백엔드를 Linux와 공유할지는 아직 정하지 않았다.** Linux 백엔드가 생길 때 공통분모가
드러나므로, 그전에 추상 층을 만들면 사용처가 하나뿐인 잘못된 경계가 된다.

빌드는 `build.zig`(`zig build mobile-lib-android`)가, 기기 조작은
[모바일 하네스](../../../tools/mobile-poc/README.md)가 소유한다.
