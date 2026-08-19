#!/usr/bin/env python3
"""`tests/boundary/imports.zig`의 external source digest를 실측값으로 갱신한다.

`check-boundaries`의 external reflection inventory는 대상 파일의 **비-test 토큰 전체**를
SHA-256으로 잠근다. 그래서 그 파일을 건드리는 거의 모든 PR이 digest 한 줄을 다시 써야 하고,
main이 같은 파일을 건드리면 리베이스마다 또 다시 써야 한다(실측: 하루에 리베이스 4회·수동
재계산 6회). 지금까지는 실패 메시지의 해시를 눈으로 읽어 붙여넣었다 — 기계가 할 일이다.

**이 도구는 게이트를 무력화하지 않는다.** 두 종류의 불일치를 구분한다.

- `digest`만 다름 → 토큰이 바뀐 것(평범한 코드 편집). 자동 갱신한다.
- `count`가 다름 → `@field` 반사 접근이 실제로 **늘거나 줄었다**. 이건 게이트가 잡으려는 바로
  그 신호이므로 **갱신을 거부하고 멈춘다.** 사람이 왜 바뀌었는지 확인하고 직접 고쳐야 한다.

갱신 후에는 그 파일의 관행대로 **사유 주석 한 줄**을 원장에 남기라고 안내한다. 주석 원장은
"이 digest가 왜 또 바뀌었는가"를 추적하는 리뷰 장치라, 도구가 대신 지어내면 안 된다.

사용: mise run update-boundary-digest
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# **인코딩을 로케일에 맡기지 않는다.** 이 저장소의 소스·진단이 전부 UTF-8 한국어인데 한국어 Windows 의
# 기본은 cp949 다. 셋 다 따로 물어야 한다 — 실측(py 3.11, cp949 호스트):
#   read_text()   -> UnicodeDecodeError (원장의 한국어 주석)
#   write_text()  -> LF 를 CRLF 로 번역해, 한 해시 바꾸려다 원장 630 줄이 통째로 CRLF 가 된다
#   print()       -> em-dash 에서 UnicodeEncodeError
# 앞서 `subprocess.run` 만 고치고 "된다" 고 본 것은 **digest 가 최신이라 파일을 읽지도 않고 조기
# 반환하는 경로**를 밟은 것이었다 — 이 도구는 할 일이 없을 때만 돌고 정작 필요할 때 죽었다.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

REPO = Path(__file__).resolve().parent.parent
INVENTORY = REPO / "tests" / "boundary" / "external_source_digests.zig"

# `external source inventory mismatch: <path> count=<n> digest=<hex>`
MISMATCH = re.compile(
    r"external source inventory mismatch: (?P<path>\S+) count=(?P<count>\d+) digest=(?P<digest>[0-9a-f]{64})"
)

# 판정자는 한 번에 한 파일만 보고하고 즉시 실패하므로(imports.zig의 `return error.…`),
# 여러 파일이 동시에 어긋났으면 갱신-재실행을 수렴할 때까지 반복해야 한다.
MAX_ROUNDS = 12


def entry_pattern(path: str) -> re.Pattern[str]:
    """inventory 배열에서 해당 경로의 항목 한 줄을 잡는다."""
    return re.compile(
        r'(?P<head>\.\{ \.path = "' + re.escape(path) + r'", \.count = )'
        r"(?P<count>\d+)"
        r'(?P<mid>, \.digest_hex = ")'
        r"(?P<digest>[0-9a-f]{64})"
    )


def run_gate() -> tuple[int, str]:
    # **인코딩을 명시한다.** 안 주면 Python 이 로케일 기본으로 읽는데, 한국어 Windows 는 cp949 라
    # 게이트가 뱉는 UTF-8 한국어에서 `UnicodeDecodeError` 로 죽는다(실측: 이 저장소의 진단 메시지가
    # 전부 한국어다). `errors="replace"` 는 그래도 못 읽는 바이트가 있을 때 도구가 멈추지 않게 한다 —
    # 여기서 읽는 것은 사람이 볼 진단이지 판정 데이터가 아니다.
    proc = subprocess.run(
        ["zig", "build", "check-boundaries"],
        cwd=REPO,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    if not INVENTORY.is_file():
        print(f"inventory를 찾을 수 없다: {INVENTORY}", file=sys.stderr)
        return 2

    updated: list[tuple[str, str, str]] = []  # (path, old_digest, new_digest)

    for _ in range(MAX_ROUNDS):
        code, output = run_gate()
        if code == 0:
            break

        found = MISMATCH.search(output)
        if not found:
            # digest 불일치가 아닌 다른 경계 위반이다 — 이 도구가 손댈 영역이 아니다.
            print("check-boundaries가 digest 불일치가 아닌 이유로 실패했다:\n", file=sys.stderr)
            print(output.strip()[-3000:], file=sys.stderr)
            return 1

        path = found["path"]
        want_count = int(found["count"])
        want_digest = found["digest"]

        source = INVENTORY.read_text(encoding="utf-8")
        entry = entry_pattern(path).search(source)
        if entry is None:
            print(f"inventory에 '{path}' 항목이 없다 — 새 항목은 손으로 추가해야 한다.", file=sys.stderr)
            return 1

        have_count = int(entry["count"])
        if have_count != want_count:
            # 반사 표면 자체가 바뀌었다. 이건 리뷰 대상이지 기계가 덮을 일이 아니다.
            print(
                f"거부: {path}의 @field 사이트 수가 {have_count} → {want_count}로 바뀌었다.\n"
                f"  digest만이 아니라 **반사 접근 자체**가 늘거나 줄었다는 뜻이라,\n"
                f"  이 게이트가 잡으려는 바로 그 변화다. 어디서 늘었는지 확인하고 손으로 고쳐라.\n"
                f"  (grep -n '@field' {path})",
                file=sys.stderr,
            )
            return 1

        have_digest = entry["digest"]
        if have_digest == want_digest:
            print(f"거부: {path}의 digest가 이미 실측값과 같은데 게이트가 실패한다.", file=sys.stderr)
            print(output.strip()[-2000:], file=sys.stderr)
            return 1

        # 줄 끝 번역을 끈다 — 안 끄면 한 해시 바꾸려다 원장 전체가 CRLF 가 된다.
        #
        # **`Path.write_text(newline=...)`을 쓰지 않는다.** 그 인자는 Python 3.10 에서 생겼고,
        # 이 저장소를 만지는 macOS 기본 python 은 3.9 다 — 거기서는 도구가 `TypeError` 로 죽어
        # 원장을 갱신할 방법이 사라진다(실제로 그렇게 막혔다). `open(newline=...)` 은 같은 일을
        # 하면서 버전을 가리지 않는다.
        with INVENTORY.open("w", encoding="utf-8", newline="\n") as f:
            f.write(
                entry_pattern(path).sub(
                    lambda m: m["head"] + m["count"] + m["mid"] + want_digest, source, count=1
                )
            )
        updated.append((path, have_digest, want_digest))
    else:
        print(f"{MAX_ROUNDS}회 갱신해도 수렴하지 않았다 — 손으로 확인하라.", file=sys.stderr)
        return 1

    if not updated:
        print("digest가 이미 최신이다 — 갱신할 것이 없다.")
        return 0

    print(f"digest {len(updated)}건을 갱신했다:\n")
    for path, old, new in updated:
        print(f"  {path}\n    {old[:16]}… → {new[:16]}…")
    print(
        "\n갱신은 기계적이지만 **사유는 아니다.** tests/boundary/external_source_digests.zig의 해당 항목 위에\n"
        "그 파일의 관행대로 사유 주석을 한 줄 남겨라 — 무엇을 바꿔서 digest가 움직였는지,\n"
        "그리고 count가 그대로인 이유를. 그 원장이 '이 digest가 왜 또 바뀌었나'의 유일한 기록이다."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
