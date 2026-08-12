#!/bin/sh
# 모바일 어댑터 **기기 하네스** — 설치·실행·캡쳐·계측만 한다.
#
# 빌드는 `build.zig` 가 소유한다(`zig build mobile-libs`). 제품 코드는
# `src/platform/{mobile,ios,android}` 에 있고 이 스크립트는 앱 소스를 갖지 않는다.
#
#   sh tools/mobile-poc/run.sh features-ios      Metal 로 여섯 기능 판정
#   sh tools/mobile-poc/run.sh features-android  Vulkan 으로 같은 여섯 기능 판정
#   sh tools/mobile-poc/run.sh chrome-ios       실제 chrome 컴포넌트를 시뮬레이터에
#
# **판정 기준**: 화면이 뜨는 것으로는 부족하다. 픽셀을 읽거나 디바이스 수를 세어
# "실제로 그려졌다"를 확인한다.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
POC="$ROOT/tools/mobile-poc"
# 제품 코드는 `src/platform/` 이 소유한다. 이 스크립트는 그것을 빌드·실행·계측하는
# 하네스일 뿐이고, 앱 소스를 따로 갖지 않는다(양쪽에 두면 하나가 조용히 낡는다).
IOS="$ROOT/src/platform/ios"
ANDROID="$ROOT/src/platform/android"
MOBILE="$ROOT/src/platform/mobile"
OUT="$POC/out"
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
features-ios)
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/features_ios.m" -framework Foundation -framework Metal -o "$OUT/features-ios"
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
    "$TC/aarch64-linux-android30-clang" "$POC/features_vk.c" -lvulkan -o "$OUT/features-vk"
    $ADB push "$OUT/features-vk" /data/local/tmp/features-vk >/dev/null
    $ADB shell chmod 755 /data/local/tmp/features-vk
    $ADB shell /data/local/tmp/features-vk
    ;;
chrome-ios)
    mobile_lib mobile-lib-ios-sim
    APP="$OUT/MaruChrome.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruChrome/; s/dev.maru.poc/dev.maru.chrome/' "$POC/Info.plist.in" > "$APP/Info.plist"
    # 동봉 폰트를 앱 번들에 넣는다 — 시스템 폰트를 쓰면 플랫폼마다 글자가 갈린다.
    # 굵게·기울임은 **다른 글리프**라 폰트 파일도 따로 필요하다(SGR 1/3).
    for f in Regular Bold Italic BoldItalic; do
        cp "$ROOT/assets/fonts/Jetendard/Jetendard-$f.ttf" "$APP/"
    done
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$IOS/ios_app_host.m" "$LIB_OUT/libmaru-mobile-ios-sim.a" \
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
    sed 's/@@NAME@@/MaruPace/; s/dev.maru.poc/dev.maru.pace/' "$POC/Info.plist.in" > "$APP/Info.plist"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/present_ios.m" \
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
    "$TC/bin/clang" -target aarch64-linux-android29 -fPIC -shared -O2 \
        "$ANDROID/android_app_host.c" "$OUT/glue.o" "$LIB_OUT/libmaru-mobile-android.a" \
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
    javac -source 8 -target 8 -nowarn -bootclasspath "$SDK/platforms/android-35/android.jar" \
        -d "$OUT/java" "$ANDROID/MaruActivity.java"
    "$BT/d8" --min-api 29 --output "$OUT" $(find "$OUT/java" -name '*.class')
    python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"a",zipfile.ZIP_DEFLATED);z.write(sys.argv[2],"lib/arm64-v8a/libmaruchrome.so");z.write(sys.argv[3],"classes.dex");z.close()' \
        "$OUT/base.apk" "$OUT/libmaruchrome.so" "$OUT/classes.dex"
    [ -f "$OUT/debug.keystore" ] || keytool -genkeypair -keystore "$OUT/debug.keystore" \
        -alias a -storepass android -keypass android -keyalg RSA -validity 3650 -dname CN=maru
    "$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/maru-chrome.apk"
    "$BT/apksigner" sign --ks "$OUT/debug.keystore" --ks-pass pass:android \
        --key-pass pass:android "$OUT/maru-chrome.apk"
    $ADB install -r "$OUT/maru-chrome.apk"
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
