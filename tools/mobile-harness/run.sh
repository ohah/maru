#!/bin/sh
# 모바일 어댑터 **기기 하네스** — 설치·실행·캡쳐·계측만 한다.
#
# 빌드는 `build.zig` 가 소유한다(`zig build mobile-libs`). 제품 코드는
# `src/platform/{mobile,ios,android}` 에 있고 이 스크립트는 앱 소스를 갖지 않는다.
#
#   sh tools/mobile-harness/run.sh features-ios      Metal 로 여섯 기능 판정
#   sh tools/mobile-harness/run.sh features-android  Vulkan 으로 같은 여섯 기능 판정
#   sh tools/mobile-harness/run.sh chrome-ios       실제 chrome 컴포넌트를 시뮬레이터에
#
# **판정 기준**: 화면이 뜨는 것으로는 부족하다. 픽셀을 읽거나 디바이스 수를 세어
# "실제로 그려졌다"를 확인한다.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HARNESS="$ROOT/tools/mobile-harness"
# 제품 코드는 `src/platform/` 이 소유한다. 이 스크립트는 그것을 빌드·실행·계측하는
# 하네스일 뿐이고, 앱 소스를 따로 갖지 않는다(양쪽에 두면 하나가 조용히 낡는다).
IOS="$ROOT/src/platform/ios"
ANDROID="$ROOT/src/platform/android"
MOBILE="$ROOT/src/platform/mobile"
OUT="$HARNESS/out"
mkdir -p "$OUT"

# Zig 는 .a 까지만 만든다. iOS 용 libSystem 링크를 Zig 가 못 해서(실측) 링크는
# 플랫폼 툴체인(clang/NDK)이 맡는다 — 실제 앱에서도 이 구조가 된다.
# 호스트에서 한글·영어 글리프 아틀라스를 만든다. Android NDK 에는 폰트 래스터가 없고,
# 두 플랫폼이 **같은 아틀라스**를 쓰면 렌더 결과를 1:1 로 비교할 수 있다. 실제 제품에서는
# 각 플랫폼이 자기 폰트 스택으로 래스터한다(iOS CoreText, Android FreeType/HarfBuzz).

# 코어 라이브러리는 build.zig 가 만든다. 여기서는 산출물 경로만 안다.
LIB_OUT="$ROOT/zig-out/lib"
mobile_lib() {
    # $1 = build.zig 스텝 이름(mobile-lib-ios-sim | mobile-lib-ios | mobile-lib-android)
    # Debug 는 iOS 에서 링크가 깨진다 — std 의 스택 트레이스 경로가 시뮬레이터
    # SDK 에 없는 `_dyld_get_image_header_containing_address` 를 참조한다.
    # ReleaseSafe 는 `simple_panic` 덕에 서고 **안전 검사도 그대로 산다**.
    (cd "$ROOT" && zig build "$1" -Doptimize=ReleaseSafe)
}

case "${1:-ios}" in
ime-ios)
    # **한글 조합을 재현한다.** 시뮬레이터 키보드가 한글일 때 두벌식 `gksrmf` = "한글" 이다.
    # 계약(§IME)은 확정 전 자모를 코어에 넣지 말라고 한다 — `UITextInput` 의 marked text 가
    # 그 자리다. 로그가 판정자다:
    #   MARU_IME marked=…   조합 중(코어에 안 감)
    #   MARU_IME commit=…   확정(코어로 감)
    #   MARU_INPUT text=…   코어에 들어간 것
    # `MARU_INPUT` 이 조합 단계마다 나오면 계약 위반이다(예전 `UIKeyInput` 이 그랬다).
    DEV=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
    [ -n "$DEV" ] || { echo "부팅된 시뮬레이터가 없다 — 먼저 chrome-ios 를 돌려라"; exit 1; }

    # **하드웨어 키보드가 붙어 있으면 iOS 가 소프트 키보드를 숨긴다.** 앱이 강제할 공개 API 는
    # 없다(실기기에는 하드웨어 키보드가 없어 늘 뜬다). 시뮬레이터 설정을 끄고 다시 띄운다 —
    # 이 단계를 사람 손에 맡기면 "왜 로그가 안 나오지" 로 한 시간을 쓴다(실제로 그랬다).
    #
    # **`defaults` 만으로는 부족하다(실측).** 값이 이미 0 이어도 실행 중인 시뮬레이터는 여전히
    # 하드웨어 키보드를 붙들고 있어 소프트 키보드가 안 뜬다 — 시뮬레이터를 껐다 켜도 그랬고,
    # 같은 상태에서 **Safari 조차 키보드가 안 떴다**(앱 결함이 아니라는 증거). 지배권은
    # I/O ▸ Keyboard 메뉴에 있으므로 아래에서 메뉴를 직접 누른다.
    if [ "$(defaults read com.apple.iphonesimulator ConnectHardwareKeyboard 2>/dev/null)" != "0" ]; then
        echo "하드웨어 키보드를 끄고 시뮬레이터를 다시 띄운다"
        defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
        osascript -e 'tell application "Simulator" to quit' 2>/dev/null || true
        sleep 4
        open -a Simulator
        # 부팅과 앱 재설치를 기다린다
        until xcrun simctl list devices booted | grep -q "$DEV"; do sleep 2; done
        sleep 8
        "$0" chrome-ios >/dev/null 2>&1
        sleep 3
    fi
    # **소프트 키보드를 두드린다.** `idb ui text` 는 하드웨어 키보드 경로라 IME 를 안 거친다 —
    # 조합 대신 "지웠다 다시 쓰기" 로 와서 우리 계약을 검증하지 못한다(바이트 델타가 3,4,4…로
    # backspace 가 섞여 나온다). 화면 키를 눌러야 진짜 IME 가 `setMarkedText` 를 보낸다.
    #
    # 좌표는 접근성에서 뽑았다(`idb ui describe-all` 의 AXLabel). 두벌식 ㅎ+ㅏ+ㄴ = "한".
    #
    # **소프트 키보드를 메뉴로 켠다.** `defaults` 가 안 통하는 경우가 있어(위 주석) 여기서
    # I/O ▸ Keyboard ▸ Toggle Software Keyboard 를 직접 누른다. 토글이라 이미 떠 있으면 내려간다 —
    # 그래서 아래 탭이 실패하면 한 번 더 돌리면 된다.
    osascript -e 'tell application "System Events" to tell process "Simulator" to click menu item "Toggle Software Keyboard" of menu 1 of menu item "Keyboard" of menu 1 of menu bar item "I/O" of menu bar 1' >/dev/null 2>&1 || true
    sleep 1
    for xy in "202 671" "320 671" "83 671"; do
        idb ui tap $xy --udid "$DEV" >/dev/null 2>&1
        sleep 1
    done
    sleep 2
    echo "--- IME 로그 ---"
    xcrun simctl spawn booted log show --last 30s --predicate 'process == "MaruChrome"' 2>/dev/null \
        | grep -E "MARU_IME|MARU_INPUT text=" | tail -12
    xcrun simctl io "$DEV" screenshot --type png "$OUT/ime-ios.png" >/dev/null 2>&1
    echo "스크린샷: $OUT/ime-ios.png"
    ;;

cursor-android)
    # **커서 세 모양을 글자 위에서** 찍는다. 빈 칸 위에서는 셋 다 잘 보이지만, 블록이 글자를
    # 가리는지는 **글자 위**에 놓아야 알고, 두 칸을 덮는지는 **한글(2셀) 위**에 놓아야 안다.
    # 대본을 잠시 고쳐 빌드하고 원복한다(중간에 죽어도 trap 이 되돌린다).
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    BR="$ROOT/src/platform/mobile/mobile_bridge.zig"
    BAK="$OUT/bridge.bak"
    mkdir -p "$OUT"
    cp "$BR" "$BAK"
    trap 'cp "$BAK" "$BR"' EXIT INT TERM
    # 이름 · DECSCUSR · 커서 자리(행;열). 1;4 = `$ zig build test` 의 `i`, 6;1 = `한`.
    for pair in "block 2 1;4" "underline 4 1;4" "bar 6 1;4" "wide 2 6;1"; do
        set -- $pair
        python3 "$HARNESS/demo_probe.py" cursor "$BR" "$2" "$3" || exit 1
        sh "$0" chrome-android-app >/dev/null 2>&1
        # **앱이 화면에 떠 있을 때만 찍는다.** adb 가 성공해도 앱이 아직 안 떴거나 죽었으면
        # 홈 화면을 `cursor-block.png` 라는 이름으로 남기고 "확인했다" 가 된다 — 이 하네스가
        # 맨 위에 스스로 적어 둔 판정 기준("화면이 뜨는 것으로는 부족하다")이 걸리는 자리다.
        # 고정 sleep 대신 포커스를 기다리면 늦게 뜨는 경우도 같이 덮는다.
        n=0
        while ! "$ADB" shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*dev.maru.chrome"; do
            n=$((n + 1))
            [ "$n" -gt 15 ] && { echo "앱이 화면에 없다 — 캡쳐를 믿을 수 없다" >&2; exit 1; }
            sleep 1
        done
        sleep 2  # 첫 프레임이 아니라 대본이 다 그려진 뒤를 찍는다
        "$ADB" exec-out screencap -p > "$OUT/cursor-$1.png"
        cp "$BAK" "$BR"
        echo "  cursor-$1.png"
    done
    ;;
scroll-android)
    # 스크롤은 **스크롤백이 있어야** 볼 게 생긴다(대본은 화면보다 짧다). 세 상태를 찍는다:
    # 바닥 → 과거로 스크롤 → 입력하면 바닥으로 스냅.
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    BR="$MOBILE/mobile_bridge.zig"
    BAK="$OUT/bridge-scroll.bak"
    mkdir -p "$OUT"
    cp "$BR" "$BAK"
    trap 'cp "$BAK" "$BR"' EXIT INT TERM
    python3 "$HARNESS/demo_probe.py" lines "$BR" 120 || exit 1
    sh "$0" chrome-android-app >/dev/null 2>&1
    cp "$BAK" "$BR"
    n=0
    while ! "$ADB" shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*dev.maru.chrome"; do
        n=$((n + 1))
        [ "$n" -gt 15 ] && { echo "앱이 화면에 없다 — 캡쳐를 믿을 수 없다" >&2; exit 1; }
        sleep 1
    done
    sleep 2
    "$ADB" exec-out screencap -p > "$OUT/scroll-android-bottom.png"
    "$ADB" shell input swipe 500 700 500 1800 300   # 아래로 끄는 손가락 = 과거로
    sleep 2
    "$ADB" exec-out screencap -p > "$OUT/scroll-android-up.png"
    "$ADB" shell input text "x"                     # 입력하면 바닥으로 스냅(브리지 계약)
    sleep 2
    "$ADB" exec-out screencap -p > "$OUT/scroll-android-snap.png"
    "$ADB" logcat -d -s MaruChrome 2>/dev/null | grep MARU_SCROLL | tail -1
    echo "  scroll-android-bottom.png · scroll-android-up.png · scroll-android-snap.png"
    ;;
scroll-video-android)
    # 정지 화면 세 장으로는 **관성이 보이지 않는다** — 손을 뗀 뒤에도 계속 흐르는지는
    # 움직이는 그림이라야 안다. `scroll-android` 와 같은 대본을 쓰고 녹화만 더한다.
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    BR="$MOBILE/mobile_bridge.zig"
    BAK="$OUT/bridge-scroll.bak"
    mkdir -p "$OUT"
    cp "$BR" "$BAK"
    trap 'cp "$BAK" "$BR"' EXIT INT TERM
    python3 "$HARNESS/demo_probe.py" lines "$BR" 200 || exit 1
    sh "$0" chrome-android-app >/dev/null 2>&1
    cp "$BAK" "$BR"
    n=0
    while ! "$ADB" shell dumpsys window 2>/dev/null | grep -q "mCurrentFocus.*dev.maru.chrome"; do
        n=$((n + 1))
        [ "$n" -gt 15 ] && { echo "앱이 화면에 없다 — 녹화를 믿을 수 없다" >&2; exit 1; }
        sleep 1
    done
    sleep 2
    # **길이를 동작에 맞춘다.** 뒤가 정지 화면이면 "안 움직인다" 로 읽힌다.
    "$ADB" shell screenrecord --time-limit 16 --bit-rate 6000000 /sdcard/scroll.mp4 &
    REC=$!
    sleep 1
    # 과거로 네 번(한 번씩 끊어서 관성이 보이게) → 잠깐 멈춤(자리를 지키는지) →
    # 현재로 세 번 → 입력하면 바닥으로 스냅.
    for _ in 1 2 3 4; do "$ADB" shell input swipe 500 700 500 1700 250; sleep 1; done
    sleep 2
    for _ in 1 2 3; do "$ADB" shell input swipe 500 1700 500 700 250; sleep 1; done
    "$ADB" shell input text "typing-snaps-to-bottom"
    sleep 2
    wait $REC 2>/dev/null || true
    sleep 2
    "$ADB" pull /sdcard/scroll.mp4 "$OUT/scroll-android.mp4" >/dev/null 2>&1
    "$ADB" shell rm -f /sdcard/scroll.mp4
    ls -la "$OUT/scroll-android.mp4"
    ;;
scroll-ios)
    # **스크롤은 스크롤백이 있어야 볼 게 생긴다.** 데모 대본은 화면보다 짧아 그대로는
    # `sb.count == 0` 이고 스크롤이 원리상 무동작이다 — 번호 붙은 줄을 넣어 빌드했다 뺀다.
    UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)
    [ -n "$UDID" ] || { echo "부팅된 시뮬레이터가 없다" >&2; exit 1; }
    BR="$MOBILE/mobile_bridge.zig"
    BAK="$OUT/bridge-scroll.bak"
    cp "$BR" "$BAK"
    trap 'cp "$BAK" "$BR"' EXIT INT TERM
    python3 "$HARNESS/demo_probe.py" lines "$BR" 120 || exit 1
    sh "$0" chrome-ios >/dev/null 2>&1
    cp "$BAK" "$BR"
    sleep 3
    xcrun simctl io "$UDID" screenshot "$OUT/scroll-ios-bottom.png" >/dev/null 2>&1
    # **좌표는 포인트다**(402x874) — 스크린샷 픽셀(1206x2622)을 그대로 넣으면 화면 밖을 눌러
    # 아무 일도 안 일어나고, 그것을 "터치가 앱에 안 닿는다" 로 오해했다(실제로 그랬다).
    # 아래로 끄는 손가락 = 과거로. 여러 번 해야 관성까지 눈에 들어온다.
    for _ in 1 2 3; do idb ui swipe 200 250 200 700 --udid "$UDID" >/dev/null 2>&1; done
    sleep 2
    xcrun simctl io "$UDID" screenshot "$OUT/scroll-ios-up.png" >/dev/null 2>&1
    # 입력하면 바닥으로 스냅해야 한다(브리지 계약).
    idb ui text "x" --udid "$UDID" >/dev/null 2>&1
    sleep 1
    xcrun simctl io "$UDID" screenshot "$OUT/scroll-ios-snap.png" >/dev/null 2>&1
    echo "  scroll-ios-bottom.png · scroll-ios-up.png · scroll-ios-snap.png"
    ;;
features-ios)
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$HARNESS/features_ios.m" -framework Foundation -framework Metal -o "$OUT/features-ios"
    DEV=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    xcrun simctl boot "$DEV" 2>/dev/null || true
    xcrun simctl spawn "$DEV" "$OUT/features-ios"
    ;;
features-android)
    NDK=${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.1.12297006}
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    GLSLC="$NDK/shader-tools/darwin-x86_64/glslc"
    for s in quad.vert solid.frag tex.frag; do
        "$GLSLC" -o "$ANDROID/shaders/$s.spv" "$ANDROID/shaders/$s"
        $ADB push "$ANDROID/shaders/$s.spv" "/data/local/tmp/$s.spv" >/dev/null
    done
    # 같은 이유로 16KB 정렬(아래 `chrome-android-app` 참조) — 이것도 기기에서 실행된다.
    "$TC/aarch64-linux-android30-clang" -Wl,-z,max-page-size=16384 \
        "$HARNESS/features_vk.c" -lvulkan -o "$OUT/features-vk"
    $ADB push "$OUT/features-vk" /data/local/tmp/features-vk >/dev/null
    $ADB shell chmod 755 /data/local/tmp/features-vk
    $ADB shell /data/local/tmp/features-vk
    ;;
chrome-ios)
    mobile_lib mobile-lib-ios-sim
    APP="$OUT/MaruChrome.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruChrome/; s/dev.maru.poc/dev.maru.chrome/' "$HARNESS/Info.plist.in" > "$APP/Info.plist"
    # 동봉 폰트를 앱 번들에 넣는다 — 시스템 폰트를 쓰면 플랫폼마다 글자가 갈린다.
    # 굵게·기울임은 **다른 글리프**라 폰트 파일도 따로 필요하다(SGR 1/3).
    for f in Regular Bold Italic BoldItalic; do
        cp "$ROOT/assets/fonts/Jetendard/Jetendard-$f.ttf" "$APP/"
    done
    # **펌프도 같이 링크한다** — 소켓 루프는 두 host 가 함께 쓰는 C 한 벌이다(S9-3).
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$IOS/ios_app_host.m" "$ROOT/src/platform/mobile_host/ssh_pump.c" \
        "$LIB_OUT/libmaru-mobile-ios-sim.a" \
        -framework UIKit -framework Metal -framework QuartzCore -framework Foundation \
        -framework CoreText -framework CoreGraphics \
        -o "$APP/MaruChrome"
    codesign --force --sign - "$APP"
    DEV=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    xcrun simctl boot "$DEV" 2>/dev/null || true
    xcrun simctl install "$DEV" "$APP"
    xcrun simctl launch "$DEV" dev.maru.chrome
    sleep 4
    xcrun simctl io "$DEV" screenshot "$OUT/maru-chrome-ios.png"
    echo "스크린샷: $OUT/maru-chrome-ios.png"
    ;;
present-ios)
    # 여섯 기능 중 마지막. 오프스크린에는 "표시 시각"이 없어 앱으로만 판정된다.
    APP="$OUT/MaruPace.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruPace/; s/dev.maru.poc/dev.maru.pace/' "$HARNESS/Info.plist.in" > "$APP/Info.plist"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$HARNESS/present_ios.m" \
        -framework UIKit -framework Metal -framework QuartzCore -framework Foundation \
        -o "$APP/MaruPace"
    codesign --force --sign - "$APP"
    DEV=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    xcrun simctl boot "$DEV" 2>/dev/null || true
    xcrun simctl install "$DEV" "$APP"
    xcrun simctl launch "$DEV" dev.maru.pace
    sleep 12
    xcrun simctl spawn "$DEV" log show --last 30s --predicate 'eventMessage CONTAINS "MARU_PACE"' \
        --style compact 2>/dev/null | grep -o 'MARU_PACE.*'
    # **끝나면 물러난다.** 이 앱은 측정을 마치면 렌더를 멈춰서 마지막 프레임(붉은 화면)이
    # 그대로 남는다 — 시뮬레이터를 보는 사람에게는 제품이 깨진 것처럼 보인다.
    xcrun simctl terminate "$DEV" dev.maru.pace 2>/dev/null || true
    ;;
chrome-android-app)
    # 앞의 chrome-android 는 오프스크린 텍스처를 PPM 으로 뽑는다. 이건 **에뮬레이터 화면에**
    # 그린다 — NativeActivity + Vulkan swapchain 이라 iOS 시뮬레이터와 같은 조건이 되고,
    # 남아 있던 present 페이싱(FIFO=vsync)도 이 경로에서만 판정된다.
    NDK=${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.1.12297006}
    SDK=${ANDROID_SDK:-$HOME/Library/Android/sdk}
    ADB=${ADB:-$SDK/platform-tools/adb}
    BT="$SDK/build-tools/34.0.0"
    TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
    GLUE="$NDK/sources/android/native_app_glue"
    GLSLC="$NDK/shader-tools/darwin-x86_64/glslc"
    # apksigner·keytool 은 JVM 이 필요하다. 별도 JDK 없이 Android Studio 번들 JBR 을 쓴다.
    JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    [ -d "$JBR" ] && { JAVA_HOME="$JBR"; export JAVA_HOME; PATH="$JBR/bin:$PATH"; export PATH; }
    mobile_lib mobile-lib-android
    "$TC/bin/clang" -target aarch64-linux-android29 -fPIC -c "$GLUE/android_native_app_glue.c" \
        -o "$OUT/glue.o" -I"$GLUE"
    # `-u ANativeActivity_onCreate` 가 없으면 glue 의 진입점이 --gc-sections 로 잘려
    # 앱이 "네이티브 진입점 없음"으로 죽는다.
    # **펌프도 같이 링크한다.** 소켓 루프는 두 host 가 함께 쓰는 C 한 벌이다
    # (`src/platform/mobile_host/ssh_pump.c` — 데스크톱 스모크가 같은 파일을 링크해 증명한다).
    # **16KB 페이지로 정렬한다.** Android 15+ 는 16KB 페이지 기기를 허용하는데, 4KB 정렬 ELF 는
    # 그 커널에서 **로드 자체가 안 된다**(앱이 안 뜬다). NDK r27 은 16KB 가 기본이지만 그 기본값은
    # ndk-build/CMake 가 넣어 주는 것이라, 여기처럼 clang 을 직접 부르는 경로에는 안 들어온다 —
    # 실측으로 LOAD 정렬이 전부 `0x1000` 이었고 기기가 "ELF 정렬 검사 실패" 를 띄웠다.
    "$TC/bin/clang" -target aarch64-linux-android29 -fPIC -shared -O2 \
        -Wl,-z,max-page-size=16384 \
        "$ANDROID/android_app_host.c" "$ROOT/src/platform/mobile_host/ssh_pump.c" \
        "$OUT/glue.o" "$LIB_OUT/libmaru-mobile-android.a" \
        -I"$GLUE" -u ANativeActivity_onCreate -lvulkan -llog -landroid -ljnigraphics -lm \
        -o "$OUT/libmaruchrome.so"
    # 셰이더·폰트는 **APK asset** 으로 들어간다 — /data/local/tmp 는 개발 스크립트 자리라
    # push 를 안 한 기기에서는 앱이 검은 화면이 된다.
    rm -rf "$OUT/assets" && mkdir -p "$OUT/assets"
    for s in chrome.vert chrome.frag; do
        "$GLSLC" -o "$OUT/assets/$s.spv" "$ANDROID/shaders/$s"
    done
    for f in Regular Bold Italic BoldItalic; do
        cp "$ROOT/assets/fonts/Jetendard/Jetendard-$f.ttf" "$OUT/assets/"
    done
    # Java 코드가 0줄이라 dex 단계가 없다 — aapt2 로 매니페스트만 링크하고 .so 를 넣는다.
    "$BT/aapt2" link -I "$SDK/platforms/android-35/android.jar" \
        --manifest "$ANDROID/AndroidManifest.xml" -A "$OUT/assets" \
        -o "$OUT/base.apk" --auto-add-overlay
    # IME shim 하나만 컴파일한다. `android.*` 만 써서 AndroidX 도 kotlin-stdlib 도 없다 —
    # 그래서 javac + d8 로 끝나고 Gradle 이 필요 없다(docs/mobile-platform.md §1).
    mkdir -p "$OUT/java"
    # IME shim 과 **SSH 포그라운드 서비스** 둘뿐이다. `android.*` 만 써서 AndroidX 도
    # kotlin-stdlib 도 없다 — 그래서 javac + d8 로 끝나고 Gradle 이 필요 없다(§1).
    javac -source 8 -target 8 -nowarn -bootclasspath "$SDK/platforms/android-35/android.jar" \
        -d "$OUT/java" "$ANDROID/MaruActivity.java" "$ANDROID/MaruSshService.java" \
        "$ANDROID/MaruKeyStore.java"
    # **`--lib` 를 준다.** 라이브러리 추상 클래스를 상속하고 `super` 를 부르는 클래스가 생기면
    # (접근성 `AccessibilityNodeProvider`) d8 이 상위 사슬을 못 찾아 **내부 오류로 죽는다**
    # (실측: "Cannot invoke String.length()" NPE). 그 전까지는 그런 클래스가 없어 안 드러났다.
    "$BT/d8" --min-api 29 --lib "$SDK/platforms/android-35/android.jar" \
        --output "$OUT" $(find "$OUT/java" -name '*.class')
    python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"a",zipfile.ZIP_DEFLATED);z.write(sys.argv[2],"lib/arm64-v8a/libmaruchrome.so");z.write(sys.argv[3],"classes.dex");z.close()' \
        "$OUT/base.apk" "$OUT/libmaruchrome.so" "$OUT/classes.dex"
    [ -f "$OUT/debug.keystore" ] || keytool -genkeypair -keystore "$OUT/debug.keystore" \
        -alias a -storepass android -keypass android -keyalg RSA -validity 3650 -dname CN=maru
    "$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/maru-chrome.apk"
    "$BT/apksigner" sign --ks "$OUT/debug.keystore" --ks-pass pass:android \
        --key-pass pass:android "$OUT/maru-chrome.apk"
    # **`adb install` 은 실패해도 exit 0 이다.** "Failure [...]" 를 찍고 0 을 내므로 `set -e`
    # 가 못 잡고, 스크립트는 옛 APK 가 그대로 깔린 채로 성공을 보고한다 — 실제로 그 상태에서
    # "고쳤는데 화면이 그대로" 를 한참 봤다. 출력을 판정한다.
    out=$($ADB install -r "$OUT/maru-chrome.apk" 2>&1) || true
    case "$out" in
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
        # 서명이 다르다 = 키스토어가 새로 만들어졌다(`out/` 을 비우면 그렇게 된다).
        echo "  서명 불일치 — 기존 앱을 지우고 다시 설치한다"
        $ADB uninstall dev.maru.chrome >/dev/null 2>&1 || true
        out=$($ADB install -r "$OUT/maru-chrome.apk" 2>&1) || true
        ;;
    esac
    case "$out" in
    *Failure*) echo "설치 실패: $out" >&2; exit 1 ;;
    esac
    $ADB logcat -c
    $ADB shell am start -n dev.maru.chrome/dev.maru.MaruActivity >/dev/null
    sleep 5
    $ADB exec-out screencap -p > "$OUT/maru-chrome-android-app.png"
    $ADB logcat -d -s MaruChrome | tail -6
    echo "스크린샷: $OUT/maru-chrome-android-app.png"
    ;;
*)
    echo "usage: $0 [chrome-ios|chrome-android-app|present-ios|features-ios|features-android]" >&2
    exit 2
    ;;
esac
