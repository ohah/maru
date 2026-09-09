#!/usr/bin/env python3
"""maru 앱 아이콘 — **앰버 커서 모티프**를 그리는 단일 출처.

**왜 그림 파일이 아니라 생성기인가.** 아이콘은 플랫폼마다 크기가 열 몇 개이고(macOS `.icns`
여덟 · iOS 다섯 · Android 밀도 다섯) 손으로 맞추면 한 자리만 낡는다. 여기서 한 번 그리고
전부 뽑는다 — 그리는 규칙이 한 곳이면 갈릴 수가 없다.

**모티프**: 프롬프트 `❯` 와 블록 커서. 터미널이라는 것을 한눈에 말하고, 40px 에서도 두 덩이가
안 뭉친다(대안 둘을 나란히 그려 보고 골랐다 — 커서만 두면 그냥 사각형이고, 「친 줄」을 옆에
두면 작은 크기에서 붙어 버린다).

**색은 제품에서 온다**: 앰버는 브랜드 강조색(`config/appearance.zig` 의 `accent_default`),
바탕은 기본 다크 배경 계열이다. 여기 숫자를 새로 만들지 않는다.

    python3 assets/icon/render.py            # assets/icon/out/ 에 전부 뽑는다
    python3 assets/icon/render.py --check    # 뽑은 것이 지금 규칙과 같은지만 본다(안 쓴다)
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw

# 브랜드 앰버 — `accent_default` (config/appearance.zig).
AMBER = (0xDD, 0xA1, 0x5E)
# 바탕 — 기본 다크 배경 계열(catppuccin-mocha base, 모바일 기본값과 같은 값).
GROUND = (0x1E, 0x1E, 0x2E)

# **키우고 그린 뒤 줄인다.** 대각선과 둥근 끝이 작은 크기에서 계단지지 않게.
SUPERSAMPLE = 4


def render(size, *, motif=1.15, ground=GROUND, transparent=False):
    """한 장을 그린다.

    `motif` 는 모티프가 화면을 얼마나 채우는가다. **Android 적응형 아이콘의 앞면은 더 작다** —
    런처가 원·둥근사각 등으로 잘라내므로 안전 영역(지름 66/108) 안에 들어가야 한다.
    """
    w = size * SUPERSAMPLE
    mode = "RGBA" if transparent else "RGB"
    fill = (0, 0, 0, 0) if transparent else ground
    im = Image.new(mode, (w, w), fill)
    d = ImageDraw.Draw(im)

    ch = int(w * 0.52 * motif)          # 커서 높이
    cw = int(ch / 1.9)                  # 터미널 셀 비율
    radius = max(1, int(cw * 0.18))
    lw = max(2, int(w * 0.080 * motif))  # 셰브론 두께
    aw = int(w * 0.15 * motif)          # 셰브론 폭
    ah = ch * 0.44                      # 셰브론 반높이
    gap = int(w * 0.09 * motif)

    total = aw + gap + cw
    x0 = (w - total) // 2
    cy = w // 2
    ax = x0 + aw // 2

    p0 = (ax - aw // 2, cy - ah)
    p1 = (ax + aw // 2, cy)
    p2 = (ax - aw // 2, cy + ah)
    d.line([p0, p1], fill=AMBER, width=lw)
    d.line([p1, p2], fill=AMBER, width=lw)
    # **끝을 둥글게 한다.** PIL 의 `joint` 는 이음매만 둥글리고 «끝»은 잘린 채 둔다 — 그러면
    # 큰 크기에서 도끼로 자른 것처럼 보인다(그려 보고 알았다).
    for p in (p0, p1, p2):
        d.ellipse([p[0] - lw // 2, p[1] - lw // 2, p[0] + lw // 2, p[1] + lw // 2], fill=AMBER)

    cx = x0 + aw + gap
    d.rounded_rectangle([cx, cy - ch // 2, cx + cw, cy + ch // 2], radius=radius, fill=AMBER)
    return im.resize((size, size), Image.LANCZOS)


# macOS `.icns` 가 요구하는 자리들(`iconutil` 이 이 이름을 읽는다).
ICONSET = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

# iOS 번들이 직접 드는 크기(`CFBundleIconFiles`). **알파를 안 쓴다** — iOS 는 투명을 검게 깔고
# 모서리를 자기가 자른다.
IOS = [(120, "AppIcon60x60@2x.png"), (180, "AppIcon60x60@3x.png"),
       (152, "AppIcon76x76@2x.png"), (167, "AppIcon83.5x83.5@2x.png"),
       (1024, "AppIcon1024.png")]

# Android 밀도별 런처 아이콘. 적응형(앞면)은 **투명 배경 + 작은 모티프**다.
ANDROID = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
# 적응형 앞면 캔버스는 108dp 이고 안전 영역은 지름 66dp — 모티프를 그 안에 넣는다.
ADAPTIVE_MOTIF = 0.62


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.dirname(__file__))
    ap.add_argument("--check", action="store_true", help="지금 규칙과 같은지만 본다(안 쓴다)")
    a = ap.parse_args()

    want = {}
    for size, name in ICONSET:
        want[os.path.join("Maru.iconset", name)] = render(size)  # `.icns` 재료(임시)
    for size, name in IOS:
        want[os.path.join("ios", name)] = render(size)
    for density, size in ANDROID:
        want[os.path.join("android", f"mipmap-{density}", "ic_launcher.png")] = render(size)
        # 적응형 앞면 — 배경은 XML 이 단색으로 깔고, 여기는 모티프만 투명 위에 얹는다.
        want[os.path.join("android", f"mipmap-{density}", "ic_launcher_foreground.png")] = render(
            int(size * 108 / 48), motif=ADAPTIVE_MOTIF, transparent=True
        )

    bad = 0
    for rel, im in want.items():
        path = os.path.join(a.out, rel)
        if a.check:
            if not os.path.exists(path):
                print(f"없다: {rel}")
                bad += 1
                continue
            cur = Image.open(path).convert(im.mode)
            if cur.tobytes() != im.tobytes():
                print(f"다르다: {rel}")
                bad += 1
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        im.save(path)
    if a.check:
        print("아이콘: 규칙과 같다" if bad == 0 else f"아이콘: {bad} 건 어긋났다")
        return 1 if bad else 0
    print(f"아이콘 {len(want)} 장을 {a.out} 에 뽑았다")
    print("  macOS `.icns` 는 여기서 안 만든다 — `iconutil` 이 macOS 전용이라 아래를 손으로 돈다:")
    print(f"    iconutil -c icns {os.path.join(a.out, 'Maru.iconset')} -o {os.path.join(a.out, 'Maru.icns')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
