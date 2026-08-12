#!/usr/bin/env python3
"""데모 대본 끝에 커서 모양·위치 지정을 붙였다 뗀다.

커서 모양(DECSCUSR)과 자리(CUP)는 **이스케이프라 `adb shell input text` 로 못 친다**. 화면으로
확인하려면 대본에 넣어 빌드하는 수밖에 없어서, 그 붙였다 떼는 일을 여기가 맡는다.

`run.sh cursor-android` 만 부른다. 인라인 heredoc 으로 두었다가 **중첩 이스케이프가 깨져**
앵커를 못 찾은 적이 있어(`\\x1b` 가 ESC 로 접혔다) 파일로 뺐다.

    python3 cursor_probe.py set <bridge.zig> <DECSCUSR 번호> <행;열>
    python3 cursor_probe.py                       # 인자 없이 부르면 사용법
"""
import sys
from pathlib import Path

# 대본의 마지막 줄. 여기가 바뀌면 이 상수도 함께 고쳐야 한다(그래야 조용히 빗나가지 않는다).
ANCHOR = '"\\x1b[53move\\x1b[0m \\x1b[4;58;5;196mucol\\x1b[0m \\x1b[8mhid\\x1b[0m|\\r\\n";'


def main() -> int:
    if len(sys.argv) != 5 or sys.argv[1] != "set":
        print(__doc__)
        return 2
    _, _, bridge, shape, pos = sys.argv
    p = Path(bridge)
    src = p.read_text(encoding="utf-8")
    if ANCHOR not in src:
        print("대본 앵커를 못 찾았다 — 대본이 바뀌었으면 cursor_probe.py 의 ANCHOR 도 고친다",
              file=sys.stderr)
        return 1
    added = ANCHOR[:-1] + ' ++\n    "\\x1b[' + shape + ' q\\x1b[' + pos + 'H";'
    p.write_text(src.replace(ANCHOR, added), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
