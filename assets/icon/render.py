#!/usr/bin/env python3
"""maru 앱 아이콘 — **앰버 커서 모티프**를 그리는 단일 출처.

**왜 그림 파일이 아니라 생성기인가.** 아이콘은 플랫폼마다 크기가 열 몇 개이고(macOS `.icns`
여덟 · iOS 다섯 · Android 밀도 다섯) 손으로 맞추면 한 자리만 낡는다. 여기서 한 번 그리고
전부 뽑는다 — 그리는 규칙이 한 곳이면 갈릴 수가 없다.

**모티프**: 프롬프트 `❯` 와 블록 커서. 터미널이라는 것을 한눈에 말하고, 40px 에서도 두 덩이가
안 뭉친다(대안 둘을 나란히 그려 보고 골랐다 — 커서만 두면 그냥 사각형이고, 「친 줄」을 옆에
두면 작은 크기에서 붙어 버린다).

**자리는 커서가 앞이다** — 「마루」의 「마」 느낌이 나라고(사용자 확정 2026-09-10). 두 덩이는
앞선 판과 **똑같다**: 셀 비율(1:1.9) 블록 커서와 같은 셰브론이고, 좌우만 맞바꿨다. 글자를
또박또박 쓰지 않는 것이 요점이다 — `ㅏ` 획을 실제로 그려 봤더니 「마」는 선명해졌지만 `❯` 가
사라져 **터미널이라는 뜻이 통째로 빠졌다**. 알아보는 사람만 알아보면 된다.

**색은 제품에서 온다**: 앰버는 브랜드 강조색(`config/appearance.zig` 의 `accent_default`),
바탕은 기본 다크 배경 계열이다. 여기 숫자를 새로 만들지 않는다.

    python3 assets/icon/render.py            # assets/icon/out/ 에 전부 뽑는다
    python3 assets/icon/render.py --check    # 뽑아 둔 것(`.icns` 안까지)이 규칙과 같은지 본다
    python3 assets/icon/render.py --selftest # 작은 크기·안전 영역을 «재어» 본다
"""
import argparse
import os
import sys

from io import BytesIO
import struct

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

    total = cw + gap + aw
    x0 = (w - total) // 2
    cy = w // 2

    d.rounded_rectangle([x0, cy - ch // 2, x0 + cw, cy + ch // 2], radius=radius, fill=AMBER)

    ax = x0 + cw + gap + aw // 2
    p0 = (ax - aw // 2, cy - ah)
    p1 = (ax + aw // 2, cy)
    p2 = (ax - aw // 2, cy + ah)
    d.line([p0, p1], fill=AMBER, width=lw)
    d.line([p1, p2], fill=AMBER, width=lw)
    # **끝을 둥글게 한다.** PIL 의 `joint` 는 이음매만 둥글리고 «끝»은 잘린 채 둔다 — 그러면
    # 큰 크기에서 도끼로 자른 것처럼 보인다(그려 보고 알았다).
    for p in (p0, p1, p2):
        d.ellipse([p[0] - lw // 2, p[1] - lw // 2, p[0] + lw // 2, p[1] + lw // 2], fill=AMBER)
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

# **작은 크기에서 두 덩이가 붙으면 그림이 얼룩이 된다.** 제품이 싣는 **모든** 크기에서 잰다 —
# 제일 작은 16px(macOS 메뉴막대 자리)까지. 「40px 에서도 안 뭉친다」가 이 모티프를 고른 이유라
# 그 말을 그대로 계약으로 만든다.
SELFTEST_MIN = 16

# `.icns` 안에 든 PNG 토막이 덮는 크기들. `ic04`/`ic05`(16·32)는 RLE 로 눌린 ARGB 라 여기서
# 안 읽는다 — 나머지 여덟 자리가 제품이 실제로 보여 주는 크기다.
ICNS_PNG_SIZES = [32, 64, 128, 256, 256, 512, 512, 1024]


def checkIcns(path):
    """**`.icns` 를 열어 화소로 댄다.**

    이 파일만은 `iconutil`(macOS 전용)이 손으로 굽는 산출물이라, 생성기를 고치고 다시 안 구우면
    **데스크톱 앱만 조용히 옛 그림을 싣는다** — 있는지 세는 판정으로는 절대 안 잡힌다. 형식이
    「네 글자 이름 + 길이 + 알맹이」의 나열이라 어느 OS 에서나 열어 볼 수 있다.
    """
    if not os.path.exists(path):
        print(f"없다: {os.path.basename(path)}")
        return 1
    blob = open(path, "rb").read()
    if blob[:4] != b"icns":
        print(f"icns 가 아니다: {os.path.basename(path)}")
        return 1
    bad, sizes, off = 0, [], 8
    while off + 8 <= len(blob):
        name = blob[off:off + 4].decode("ascii", "replace")
        n = struct.unpack(">I", blob[off + 4:off + 8])[0]
        if n < 8:
            print(f"토막 길이가 이상하다: {name} {n}")
            return 1
        payload = blob[off + 8:off + n]
        off += n
        if payload[:8] != b"\x89PNG\r\n\x1a\n":
            continue
        im = Image.open(BytesIO(payload)).convert("RGB")
        sizes.append(im.size[0])
        if im.tobytes() != render(im.size[0]).convert("RGB").tobytes():
            print(f"다르다: Maru.icns 의 {name}({im.size[0]}px)")
            bad += 1
    if sorted(sizes) != ICNS_PNG_SIZES:
        print(f"Maru.icns 가 든 크기가 다르다: {sorted(sizes)} (바라는 것 {ICNS_PNG_SIZES})")
        bad += 1
    return bad


def inkBounds(im):
    """모티프가 실제로 든 자리. 투명 앞면은 알파로, 불투명 판은 바탕과 다른 화소로 잡는다."""
    if im.mode == "RGBA":
        return im.getchannel("A").getbbox()
    diff = Image.new("L", im.size)
    diff.putdata([255 if sum(abs(a - b) for a, b in zip(px, GROUND)) > 60 else 0
                  for px in im.convert("RGB").getdata()])
    return diff.getbbox()


def groundRuns(im):
    """가운데 가로줄에서 «바탕» 이 이어지는 토막들. `ㅁ` 과 `ㅏ` 가 안 붙었으면 셋이다."""
    rgb = im.convert("RGB")
    y = im.size[1] // 2
    runs, cur = [], 0
    for x in range(im.size[0]):
        if sum(abs(a - b) for a, b in zip(rgb.getpixel((x, y)), GROUND)) < 60:
            cur += 1
        elif cur:
            runs.append(cur)
            cur = 0
    if cur:
        runs.append(cur)
    return runs


def selftest():
    """그림을 **재어** 본다 — 눈으로 「괜찮다」고 하는 대신."""
    bad = 0
    sizes = sorted({s for s, _ in ICONSET} | {s for s, _ in IOS} | {s for _, s in ANDROID})
    for size in sizes:
        if size < SELFTEST_MIN:
            continue
        runs = groundRuns(render(size))
        if len(runs) != 3:
            print(f"붙었다: {size}px 의 가운데 줄에 바탕 토막이 {len(runs)} 개다(셋이어야 한다)")
            bad += 1
    # **적응형 앞면은 원 안에 들어야 한다.** 런처가 지름 66/108 로 잘라내므로, 넘으면 «잘린 줄
    # 모르고» 배포된다 — `ㅁ` 을 넓히면 제일 먼저 여기가 깨진다.
    for _, size in ANDROID:
        canvas = int(size * 108 / 48)
        im = render(canvas, motif=ADAPTIVE_MOTIF, transparent=True)
        x0, y0, x1, y1 = inkBounds(im)
        c = canvas / 2.0
        r = canvas * 66.0 / 108.0 / 2.0
        worst = max((dx - c) ** 2 + (dy - c) ** 2 for dx in (x0, x1) for dy in (y0, y1)) ** 0.5
        if worst > r:
            print(f"안전 영역 밖: {canvas}px 앞면의 모서리가 중심에서 {worst:.1f} (한계 {r:.1f})")
            bad += 1
    print("그림: 재어 보니 맞다" if bad == 0 else f"그림: {bad} 건 어긋났다")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.dirname(__file__))
    ap.add_argument("--check", action="store_true", help="지금 규칙과 같은지만 본다(안 쓴다)")
    ap.add_argument("--selftest", action="store_true", help="작은 크기·안전 영역을 재어 본다")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    want = {}
    material = set()
    for size, name in ICONSET:
        rel = os.path.join("Maru.iconset", name)
        want[rel] = render(size)  # `.icns` 재료 — 굽고 나면 버린다(`.gitignore`)
        material.add(rel)
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
            if rel in material:
                continue  # 재료는 커밋하지 않는다 — 대신 구워 낸 `.icns` 를 아래에서 연다
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
        bad += checkIcns(os.path.join(a.out, "Maru.icns"))
        print("아이콘: 규칙과 같다" if bad == 0 else f"아이콘: {bad} 건 어긋났다")
        return 1 if bad else 0
    print(f"아이콘 {len(want)} 장을 {a.out} 에 뽑았다")
    print("  macOS `.icns` 는 여기서 안 만든다 — `iconutil` 이 macOS 전용이라 아래를 손으로 돈다:")
    print(f"    iconutil -c icns {os.path.join(a.out, 'Maru.iconset')} -o {os.path.join(a.out, 'Maru.icns')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
