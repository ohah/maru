# `tests/artifacts`

테스트 실패 시 생성되는 로컬 산출물을 담는 폴더다.

trace, snapshot, config, 로그 같은 실패 분석 자료가 들어갈 수 있다. 기본적으로 git에 커밋하지 않는다.

테스트는 가능한 경우 성공/실패와 무관하게 snapshot artifact를 남긴다. 실패했을 때만 출력되는 로그에 의존하면, UI/터미널 상태 버그를 비교하기 어렵기 때문이다.

GitHub `CI` workflow는 `tests/artifacts/**`를 업로드한다. 그래서 로컬에서만 보는 파일이 아니라, PR 실패 시 GitHub Actions 화면에서도 같은 screen/snapshot/summary를 내려받아 확인할 수 있다.

GitHub `Performance` workflow의 일반 microbenchmark는 `tests/artifacts/perf/**`를 장기 추적용 artifact로 업로드한다.
다만 문서화된 구조 guardrail인 core performance, file explorer, live preview와
`session-host-slow-observer-macos.json`은 각 required job의 typed validator가 판정한다.
이 session-host artifact의 v4 schema는 실제 host의 observation materialization·core-lock hold, runtime metadata
sampler/producer visit, screen projector의 누적값과 1·10·100 runtime idle 구간 증분을 포함하며,
누락/unknown/duplicate field를 허용하지 않는다.
required 여부의 단일 출처는 `docs/performance-budget.md`의 필수 CI 체크 표다.

현재 생성되는 예시는 다음과 같다.

```text
tests/artifacts/e2e/headless/*.screen.txt
tests/artifacts/e2e/headless/*.snapshot.txt
tests/artifacts/e2e/headless/*.stdout.txt
tests/artifacts/oracle/*/*.actual.txt
tests/artifacts/oracle/*/*.expected.txt
tests/artifacts/oracle/*/input.decoded.txt
tests/artifacts/oracle/*/*.snapshot.txt
tests/artifacts/stress/*/*.screen.txt
tests/artifacts/stress/*/*.snapshot.txt
tests/artifacts/stress/*/*.summary.txt
tests/artifacts/perf/*.txt
tests/artifacts/perf/mermaid-macos.json
tests/artifacts/integration/pty/*.raw.txt
tests/artifacts/integration/pty/*.screen.txt
tests/artifacts/integration/pty/*.snapshot.txt
tests/artifacts/integration/pty/*.surface.txt
```
