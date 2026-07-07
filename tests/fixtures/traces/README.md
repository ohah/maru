# `tests/fixtures/traces`

replay 가능한 `maru.trace.v1` trace fixture를 담는다. CI가 이걸 replay해 화면이 golden과 일치하는지 고정한다(`tests/oracle/replay.zig` → `test-replay` 스텝, 기본 `test`에 포함).

## 추가/갱신

1. fixture(`*.trace.txt`)를 `maru.trace.v1` 형식으로 쓴다. **사람이 읽도록** `\r\n` escape·UTF-8로(리터럴 제어바이트 없이). 실제 세션 trace(`MARU_TRACE`)를 승격할 때는 cwd·env·host·token·command output 등 민감정보를 반드시 제거한다.
2. `tests/oracle/replay.zig`의 `cases`에 fixture·golden 경로를 추가한다.
3. golden 생성/갱신: `MARU_UPDATE_GOLDEN=1 zig build test-replay` (actual 화면을 golden으로 쓴다). 커밋 전 golden을 눈으로 확인한다.

## 커밋 안전(redaction)

`replay.zig` 테스트가 각 fixture를 `observability.trace.guardFixture`로 검사한다 — 민감 데이터(`<키>=값`·`--api-key` 등, output 재조립 후 스캔)가 있으면 **테스트가 실패**해 커밋을 막는다(deny-by-default, `src/redact.zig` 단일 출처). 즉 민감정보가 남은 fixture는 CI가 거부한다.
