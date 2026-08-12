#!/usr/bin/env python3
"""두 플랫폼이 **같은 폰트로** 구운 글리프 아틀라스의 픽셀 차이를 잰다.

번들 폰트(Jetendard)를 쓰면 글자 모양·advance 는 같아진다. 그래도 남는 차이는
**래스터라이저 차이**뿐이다 — iOS 는 CoreText/CoreGraphics, Android 는 Skia 다.
그 크기를 알아야 "래스터까지 우리가 가져와야 하는가"를 판단할 수 있다.

판정에 쓰는 값:
  - ink 픽셀(둘 중 하나라도 0 이 아닌 칸)만 센다. 배경이 대부분이라 전체 평균은 의미가 없다.
  - |Δ|>32 는 **눈에 보이는** 차이로 친다(8bit coverage 의 12.5%).
  - 글리프가 통째로 밀렸는지 보려면 셀별 무게중심 차이를 본다 — 그건 폰트가 다를 때 생기고,
    같은 폰트라면 0 에 가까워야 한다.

대조 그림도 함께 낸다(`out/atlas-diff.png`) — README 가 보여주는 그림을 **커밋된
스크립트로 다시 만들 수 있어야** 한다.

사용: python3 tools/mobile-poc/atlas_diff.py out/atlas-ios.gray out/atlas-android.gray 384 128 24 32
"""
import pathlib
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 7:
        print(__doc__)
        return 2
    a_path, b_path = sys.argv[1], sys.argv[2]
    W, H, CW, CH = (int(x) for x in sys.argv[3:7])
    a = open(a_path, "rb").read()
    b = open(b_path, "rb").read()
    if len(a) != W * H or len(b) != W * H:
        print(f"크기 불일치: {len(a)} vs {len(b)} (기대 {W * H})")
        return 1

    ink = 0
    diff_any = 0
    diff_visible = 0
    total_abs = 0
    max_abs = 0
    a_ink = 0
    b_ink = 0
    for i in range(W * H):
        av, bv = a[i], b[i]
        if av:
            a_ink += 1
        if bv:
            b_ink += 1
        if av == 0 and bv == 0:
            continue
        ink += 1
        d = abs(av - bv)
        if d:
            diff_any += 1
            total_abs += d
            max_abs = max(max_abs, d)
            if d > 32:
                diff_visible += 1

    print(f"아틀라스 {W}x{H}, 셀 {CW}x{CH}")
    print(f"ink 픽셀      A={a_ink}  B={b_ink}  합집합={ink}")
    print(f"값이 다른 칸  {diff_any} ({diff_any / ink * 100:.1f}% of ink)")
    print(f"눈에 띄는 차이(|Δ|>32)  {diff_visible} ({diff_visible / ink * 100:.1f}% of ink)")
    print(f"평균 |Δ| (ink 기준)  {total_abs / ink:.1f} / 255")
    print(f"최대 |Δ|  {max_abs}")

    # 셀별 무게중심 — 글리프가 통째로 밀렸다면 여기서 드러난다(같은 폰트면 ~0).
    cols, rows = W // CW, H // CH
    worst = (0.0, -1, -1)
    shifted = 0
    for r in range(rows):
        for c in range(cols):
            sa = sb = 0
            ax = ay = bx = by = 0.0
            for y in range(r * CH, (r + 1) * CH):
                base = y * W
                for x in range(c * CW, (c + 1) * CW):
                    av, bv = a[base + x], b[base + x]
                    if av:
                        sa += av
                        ax += x * av
                        ay += y * av
                    if bv:
                        sb += bv
                        bx += x * bv
                        by += y * bv
            if sa == 0 or sb == 0:
                continue
            dx = ax / sa - bx / sb
            dy = ay / sa - by / sb
            d = (dx * dx + dy * dy) ** 0.5
            if d > 0.5:
                shifted += 1
            if d > worst[0]:
                worst = (d, c, r)
    print(f"무게중심 0.5px 초과로 밀린 셀  {shifted}/{cols * rows}")
    print(f"최대 밀림  {worst[0]:.2f}px (셀 {worst[1]},{worst[2]})")

    write_diff_png(a, b, W, H, pathlib.Path(a_path).parent / "atlas-diff.png")
    return 0


def write_diff_png(a: bytes, b: bytes, W: int, H: int, out: pathlib.Path) -> None:
    """위=A(초록) · 가운데=B(자홍) · 아래=차이(3배 증폭).

    차이를 증폭하는 이유는 **안 증폭하면 안 보이기 때문**이다 — 그게 결론이기도 하다.
    """
    scale, gap = 2, 8
    ow, oh = W * scale, (H * 3 + gap * 2) * scale
    px = bytearray(ow * oh * 3)

    def put(x: int, y: int, r: int, g: int, bl: int) -> None:
        for dy in range(scale):
            row = (y * scale + dy) * ow
            for dx in range(scale):
                o = (row + x * scale + dx) * 3
                px[o], px[o + 1], px[o + 2] = r, g, bl

    for y in range(H):
        for x in range(W):
            av, bv = a[y * W + x], b[y * W + x]
            put(x, y, av // 3, av, av // 3)
            put(x, y + H + gap, bv, bv // 3, bv)
            d = min(255, abs(av - bv) * 3)
            put(x, y + (H + gap) * 2, d, d, d)

    ppm = out.with_suffix(".ppm")
    ppm.write_bytes(b"P6\n%d %d\n255\n" % (ow, oh) + bytes(px))
    here = pathlib.Path(__file__).parent
    subprocess.run(["python3", str(here / "ppm2png.py"), str(ppm), str(out)], check=True)
    ppm.unlink()
    print(f"대조 그림  {out}")


if __name__ == "__main__":
    raise SystemExit(main())
