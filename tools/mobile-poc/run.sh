#!/bin/sh
# maru 모바일 이식 PoC — iOS/Android 에서 Zig 코어와 GPU 가 실제로 도는지 확인한다.
#
#   sh tools/mobile-poc/run.sh ios       오프스크린 Metal + PNG
#   sh tools/mobile-poc/run.sh ios-app   시뮬레이터에 설치·실행 + 스크린샷
#   sh tools/mobile-poc/run.sh android   에뮬레이터 실행 + Vulkan 오프스크린 → PNG
#   sh tools/mobile-poc/run.sh features-ios      Metal 로 여섯 기능 판정
#   sh tools/mobile-poc/run.sh features-android  Vulkan 으로 같은 여섯 기능 판정
#   sh tools/mobile-poc/run.sh chrome-ios       실제 chrome 컴포넌트를 시뮬레이터에
#   sh tools/mobile-poc/run.sh chrome-android   같은 draw-list 를 Vulkan 으로
#
# **판정 기준**: 화면이 뜨는 것으로는 부족하다. 픽셀을 읽거나 디바이스 수를 세어
# "실제로 그려졌다"를 확인한다.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
POC="$ROOT/tools/mobile-poc"
OUT="$POC/out"
mkdir -p "$OUT"

# Zig 는 .a 까지만 만든다. iOS 용 libSystem 링크를 Zig 가 못 해서(실측) 링크는
# 플랫폼 툴체인(clang/NDK)이 맡는다 — 실제 앱에서도 이 구조가 된다.
# 호스트에서 한글·영어 글리프 아틀라스를 만든다. Android NDK 에는 폰트 래스터가 없고,
# 두 플랫폼이 **같은 아틀라스**를 쓰면 렌더 결과를 1:1 로 비교할 수 있다. 실제 제품에서는
# 각 플랫폼이 자기 폰트 스택으로 래스터한다(iOS CoreText, Android FreeType/HarfBuzz).
ATLAS_CHARS='$ zig build test All 11 passed.git status --shortM src/chrome/ui/tree.zigmaru 0.1.0 (arm64)zshvimlogswebdocsinfrascratch한글 터미널 세션 목록 설정 검색 알림'
make_atlas() {
    [ -f "$OUT/atlas.idx" ] && return 0
    clang -fobjc-arc "$POC/make_atlas.m" -framework Foundation -framework CoreText \
        -framework CoreGraphics -o "$OUT/make_atlas"
    "$OUT/make_atlas" "$OUT" "$ATLAS_CHARS"
}

build_lib() {
    target=$1
    extra=$2
    # ReleaseSafe 는 panic 핸들러의 스택 트레이스가 iOS 시뮬레이터에 없는 심볼
    # (_dyld_get_image_header_containing_address)을 참조해 링크가 깨진다.
    # 제품에서 ReleaseSafe 를 쓰려면 panic 핸들러를 직접 정의해야 한다.
    zig build-lib -target "$target" -OReleaseFast -static $extra \
        -femit-bin="$OUT/libmaru-$target.a" \
        --dep terminal -Mroot="$POC/probe.zig" -Mterminal="$ROOT/src/terminal.zig"
}

case "${1:-ios}" in
ios)
    build_lib aarch64-ios-simulator ""
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/main.m" "$OUT/libmaru-aarch64-ios-simulator.a" \
        -framework Foundation -framework Metal -framework CoreGraphics \
        -framework ImageIO -framework UniformTypeIdentifiers \
        -o "$OUT/poc-offscreen"
    DEV=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    xcrun simctl boot "$DEV" 2>/dev/null || true
    xcrun simctl spawn "$DEV" "$OUT/poc-offscreen"
    ;;
ios-app)
    build_lib aarch64-ios-simulator ""
    APP="$OUT/MaruPoC.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruPoC/' "$POC/Info.plist.in" > "$APP/Info.plist"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/app.m" "$OUT/libmaru-aarch64-ios-simulator.a" \
        -framework UIKit -framework Metal -framework QuartzCore -framework Foundation \
        -o "$APP/MaruPoC"
    codesign --force --sign - "$APP"
    DEV=$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([A-F0-9-]*\)).*/\1/')
    xcrun simctl boot "$DEV" 2>/dev/null || true
    xcrun simctl install "$DEV" "$APP"
    xcrun simctl launch "$DEV" dev.maru.poc
    sleep 4
    xcrun simctl io "$DEV" screenshot "$OUT/maru-ios-app.png"
    echo "스크린샷: $OUT/maru-ios-app.png"
    ;;
android)
    NDK=${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.1.12297006}
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    ABI=$($ADB shell getprop ro.product.cpu.abi | tr -d '\r')
    case "$ABI" in
        arm64-v8a) T=aarch64-linux-android; CC="$TC/aarch64-linux-android30-clang" ;;
        x86_64)    T=x86_64-linux-android;  CC="$TC/x86_64-linux-android30-clang" ;;
        *) echo "지원 안 하는 ABI: $ABI"; exit 1 ;;
    esac
    # Android 는 PIE 가 필수라 정적 라이브러리도 위치 독립이어야 한다.
    build_lib "$T" "-fPIC"
    # vulkan_android.c 는 셰이더 없이 vkCmdClearAttachments 로 셀 격자를 그린다.
    "$CC" "$POC/vulkan_android.c" "$OUT/libmaru-$T.a" -lvulkan -o "$OUT/poc-android"
    $ADB push "$OUT/poc-android" /data/local/tmp/poc-android >/dev/null
    $ADB shell chmod 755 /data/local/tmp/poc-android
    $ADB shell /data/local/tmp/poc-android
    $ADB pull /data/local/tmp/maru-android-poc.ppm "$OUT/maru-android-poc.ppm" >/dev/null 2>&1 \
        && python3 "$POC/ppm2png.py" "$OUT/maru-android-poc.ppm" "$OUT/maru-android-poc.png"
    ;;
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
        "$GLSLC" -o "$POC/shaders/$s.spv" "$POC/shaders/$s"
        $ADB push "$POC/shaders/$s.spv" "/data/local/tmp/$s.spv" >/dev/null
    done
    "$TC/aarch64-linux-android30-clang" "$POC/features_vk.c" -lvulkan -o "$OUT/features-vk"
    $ADB push "$OUT/features-vk" /data/local/tmp/features-vk >/dev/null
    $ADB shell chmod 755 /data/local/tmp/features-vk
    $ADB shell /data/local/tmp/features-vk
    ;;
chrome-ios)
    make_atlas
    # 모듈 루트는 maru.zig 하나다 — chrome·renderer 를 따로 주면 icons.zig 가 두 모듈에 걸린다.
    zig build-lib -target aarch64-ios-simulator -OReleaseFast -static \
        -femit-bin="$OUT/libchrome.a" \
        --dep maru -Mroot="$POC/chrome_probe.zig" -Mmaru="$ROOT/src/maru.zig"
    APP="$OUT/MaruChrome.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruChrome/; s/dev.maru.poc/dev.maru.chrome/' "$POC/Info.plist.in" > "$APP/Info.plist"
    cp "$OUT/atlas.gray" "$OUT/atlas.idx" "$APP/"
    # 동봉 폰트를 앱 번들에 넣는다 — 시스템 폰트를 쓰면 플랫폼마다 글자가 갈린다.
    cp "$ROOT/assets/fonts/Jetendard/Jetendard-Regular.ttf" "$APP/"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/chrome_app.m" "$OUT/libchrome.a" \
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
chrome-android)
    NDK=${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.1.12297006}
    ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
    TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    GLSLC="$NDK/shader-tools/darwin-x86_64/glslc"
    make_atlas
    zig build-lib -target aarch64-linux-android -OReleaseFast -static -fPIC \
        -femit-bin="$OUT/libchrome-android.a" \
        --dep maru -Mroot="$POC/chrome_probe.zig" -Mmaru="$ROOT/src/maru.zig"
    for s in chrome.vert chrome.frag; do
        "$GLSLC" -o "$POC/shaders/$s.spv" "$POC/shaders/$s"
        $ADB push "$POC/shaders/$s.spv" "/data/local/tmp/$s.spv" >/dev/null
    done
    $ADB push "$OUT/atlas.gray" /data/local/tmp/atlas.gray >/dev/null
    $ADB push "$OUT/atlas.idx" /data/local/tmp/atlas.idx >/dev/null
    "$TC/aarch64-linux-android30-clang" "$POC/chrome_vk.c" "$OUT/libchrome-android.a" \
        -lvulkan -o "$OUT/chrome-vk"
    $ADB push "$OUT/chrome-vk" /data/local/tmp/chrome-vk >/dev/null
    $ADB shell chmod 755 /data/local/tmp/chrome-vk
    $ADB shell /data/local/tmp/chrome-vk
    $ADB pull /data/local/tmp/maru-chrome-android.ppm "$OUT/maru-chrome-android.ppm" >/dev/null 2>&1 \
        && python3 "$POC/ppm2png.py" "$OUT/maru-chrome-android.ppm" "$OUT/maru-chrome-android.png"
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
    make_atlas
    zig build-lib -target aarch64-linux-android -OReleaseFast -static -fPIC \
        -femit-bin="$OUT/libchrome-android.a" \
        --dep maru -Mroot="$POC/chrome_probe.zig" -Mmaru="$ROOT/src/maru.zig"
    "$TC/bin/clang" -target aarch64-linux-android29 -fPIC -c "$GLUE/android_native_app_glue.c" \
        -o "$OUT/glue.o" -I"$GLUE"
    # `-u ANativeActivity_onCreate` 가 없으면 glue 의 진입점이 --gc-sections 로 잘려
    # 앱이 "네이티브 진입점 없음"으로 죽는다.
    "$TC/bin/clang" -target aarch64-linux-android29 -fPIC -shared -O2 \
        "$POC/chrome_android_app.c" "$OUT/glue.o" "$OUT/libchrome-android.a" \
        -I"$GLUE" -u ANativeActivity_onCreate -lvulkan -llog -landroid -ljnigraphics -lm \
        -o "$OUT/libmaruchrome.so"
    for s in chrome.vert chrome.frag; do
        "$GLSLC" -o "$POC/shaders/$s.spv" "$POC/shaders/$s"
        $ADB push "$POC/shaders/$s.spv" "/data/local/tmp/$s.spv" >/dev/null
    done
    $ADB push "$OUT/atlas.gray" /data/local/tmp/atlas.gray >/dev/null
    $ADB push "$OUT/atlas.idx" /data/local/tmp/atlas.idx >/dev/null
    # iOS 번들과 **같은 폰트 파일**을 올린다 — 그래야 래스터 차이만 남는다.
    $ADB push "$ROOT/assets/fonts/Jetendard/Jetendard-Regular.ttf" /data/local/tmp/ >/dev/null
    # Java 코드가 0줄이라 dex 단계가 없다 — aapt2 로 매니페스트만 링크하고 .so 를 넣는다.
    "$BT/aapt2" link -I "$SDK/platforms/android-35/android.jar" \
        --manifest "$POC/AndroidManifest.xml" -o "$OUT/base.apk" --auto-add-overlay
    python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],"a",zipfile.ZIP_DEFLATED);z.write(sys.argv[2],"lib/arm64-v8a/libmaruchrome.so");z.close()' \
        "$OUT/base.apk" "$OUT/libmaruchrome.so"
    [ -f "$OUT/debug.keystore" ] || keytool -genkeypair -keystore "$OUT/debug.keystore" \
        -alias a -storepass android -keypass android -keyalg RSA -validity 3650 -dname CN=maru
    "$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/maru-chrome.apk"
    "$BT/apksigner" sign --ks "$OUT/debug.keystore" --ks-pass pass:android \
        --key-pass pass:android "$OUT/maru-chrome.apk"
    $ADB install -r "$OUT/maru-chrome.apk"
    $ADB logcat -c
    $ADB shell am start -n dev.maru.chrome/android.app.NativeActivity >/dev/null
    sleep 5
    $ADB exec-out screencap -p > "$OUT/maru-chrome-android-app.png"
    $ADB logcat -d -s MaruChrome | tail -6
    echo "스크린샷: $OUT/maru-chrome-android-app.png"
    ;;
*)
    echo "usage: $0 [ios|ios-app|android|features-ios|features-android|chrome-ios|chrome-android|chrome-android-app]" >&2
    exit 2
    ;;
esac
