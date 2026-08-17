#!/usr/bin/env python3
"""데모 대본 끝에 확인용 출력을 붙였다 뗀다.

화면으로만 확인되는 것들이 있다 — 커서 모양(DECSCUSR)과 자리(CUP)는 **이스케이프라
`adb shell input text` 로 못 치고**, 스크롤은 **스크롤백이 있어야** 볼 게 생긴다. 둘 다
대본에 넣어 빌드하는 수밖에 없어서, 그 붙였다 떼는 일을 여기가 맡는다.

`run.sh` 만 부른다. 인라인 heredoc 으로 두었다가 **중첩 이스케이프가 깨져** 앵커를 못 찾은
적이 있어(`\\x1b` 가 ESC 로 접혔다) 파일로 뺐다. 앵커는 여기 한 곳에만 둔다 — 두 파일에
적으면 대본이 바뀔 때 한쪽만 낡는다.

    python3 demo_probe.py cursor <bridge.zig> <DECSCUSR 번호> <행;열>
    python3 demo_probe.py lines  <bridge.zig> <줄 수>
"""
import sys
from pathlib import Path

# 대본의 마지막 줄. 여기가 바뀌면 이 상수도 함께 고쳐야 한다(그래야 조용히 빗나가지 않는다).
# **끝 표시(`;`)를 앵커에 넣지 않는다.** 대본은 계속 자라서 이 줄 뒤에 `++` 가 붙는 일이
# 생기고(실제로 이모지 줄이 붙으며 그렇게 됐다), 그때 도구가 조용히 못 쓰게 된다 —
# "대본 앵커를 못 찾았다" 로 기기 검증이 통째로 막혔다.
ANCHOR = '"\\x1b[53move\\x1b[0m \\x1b[4;58;5;196mucol\\x1b[0m \\x1b[8mhid\\x1b[0m|\\r\\n"'


def append(bridge: str, tail: str) -> int:
    p = Path(bridge)
    src = p.read_text(encoding="utf-8")
    if ANCHOR not in src:
        print("대본 앵커를 못 찾았다 — 대본이 바뀌었으면 demo_probe.py 의 ANCHOR 도 고친다",
              file=sys.stderr)
        return 1
    # 앵커 **바로 뒤에** 끼운다. 뒤에 `++` 가 오든 `;` 가 오든 그 앞자리는 늘 유효하다.
    p.write_text(src.replace(ANCHOR, ANCHOR + " ++\n    " + tail, 1), encoding="utf-8")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode, bridge = sys.argv[1], sys.argv[2]
    if mode == "cursor" and len(sys.argv) == 5:
        shape, pos = sys.argv[3], sys.argv[4]
        return append(bridge, '"\\x1b[' + shape + ' q\\x1b[' + pos + 'H"')
    if mode == "lines" and len(sys.argv) == 4:
        # **스크롤백을 만든다.** 번호를 찍어서 화면이 실제로 어느 줄을 보고 있는지 읽히게 한다 —
        # 같은 글자만 반복하면 스크롤됐는지 눈으로 구분할 수 없다.
        n = int(sys.argv[3])
        body = "".join(f"line {i:03d}\\r\\n" for i in range(1, n + 1))
        return append(bridge, '"' + body + '"')
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
