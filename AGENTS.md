# Maru 에이전트 인덱스

이 문서는 Maru에서 작업하는 에이전트가 가장 먼저 읽는 진입점이다. 실제 규칙과 설명은 링크된 문서를 단일 출처로 둔다.

## 먼저 읽을 문서

- [개발 명령](docs/development-commands.md)
- [필수 프로젝트 규칙](docs/project-rules.md)
- [PR 체크리스트](docs/pr-checklist.md)
- [파일/폴더 구조](docs/project-structure.md)
- [검증 매트릭스](docs/verification-matrix.md)

## 설계 문서

- [초기 아키텍처](docs/architecture.md)
- [테스트 원칙](docs/architecture.md#테스트-원칙)
- [관측 가능성 원칙](docs/architecture.md#관측-가능성-원칙)
- [오라클 비교 테스트 전략](docs/oracle-testing.md)
- [메모리 전략](docs/architecture.md#메모리-전략)
- [터미널 전략](terminal-strategy.md)
- [디버깅/로그/리플레이 전략](terminal-strategy.md#12-디버깅로그리플레이-전략)
- [SSH 테스트 전략](terminal-strategy.md#13-ssh-테스트)

## 핵심 원칙

작업자는 [필수 프로젝트 규칙](docs/project-rules.md)을 따라야 한다. 이 문서에 없는 결정이 필요하거나 실제 구현이 설계와 달라지는 경우에는 임의로 진행하지 말고 사용자에게 먼저 보고한다.
