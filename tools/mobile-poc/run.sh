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
    zig build-lib -target aarch64-ios-simulator -OReleaseFast -static \
        -femit-bin="$OUT/libchrome.a" \
        --dep chrome -Mroot="$POC/chrome_probe.zig" -Mchrome="$ROOT/src/chrome.zig"
    APP="$OUT/MaruChrome.app"
    rm -rf "$APP" && mkdir -p "$APP"
    sed 's/@@NAME@@/MaruChrome/; s/dev.maru.poc/dev.maru.chrome/' "$POC/Info.plist.in" > "$APP/Info.plist"
    xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc \
        "$POC/chrome_app.m" "$OUT/libchrome.a" \
        -framework UIKit -framework Metal -framework QuartzCore -framework Foundation \
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
    zig build-lib -target aarch64-linux-android -OReleaseFast -static -fPIC \
        -femit-bin="$OUT/libchrome-android.a" \
        --dep chrome -Mroot="$POC/chrome_probe.zig" -Mchrome="$ROOT/src/chrome.zig"
    for s in chrome.vert chrome.frag; do
        "$GLSLC" -o "$POC/shaders/$s.spv" "$POC/shaders/$s"
        $ADB push "$POC/shaders/$s.spv" "/data/local/tmp/$s.spv" >/dev/null
    done
    "$TC/aarch64-linux-android30-clang" "$POC/chrome_vk.c" "$OUT/libchrome-android.a" \
        -lvulkan -o "$OUT/chrome-vk"
    $ADB push "$OUT/chrome-vk" /data/local/tmp/chrome-vk >/dev/null
    $ADB shell chmod 755 /data/local/tmp/chrome-vk
    $ADB shell /data/local/tmp/chrome-vk
    $ADB pull /data/local/tmp/maru-chrome-android.ppm "$OUT/maru-chrome-android.ppm" >/dev/null 2>&1 \
        && python3 "$POC/ppm2png.py" "$OUT/maru-chrome-android.ppm" "$OUT/maru-chrome-android.png"
    ;;
*)
    echo "usage: $0 [ios|ios-app|android|features-ios|features-android|chrome-ios|chrome-android]" >&2
    exit 2
    ;;
esac
