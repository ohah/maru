# 시맨틱 토큰 호환성 회귀 검증

현재 계약은 [에디터 툴링](../../docs/editor-surface-tooling.md) §8.2i에 있다.
이 문서는 2026-10-25 수정의 재현 조건과 적대적 검증 증거를 기록한다.

기존 캡처에서 Rust·Kotlin·Dart는 EOF 다음 줄의 0열을 요청해 오류가 났다.
`position.lineRange`는 중간 줄에서만 다음 줄의 0열을 쓰고, EOF에서는 실제 마지막 줄의 길이를 협상 인코딩으로 보낸다.
동일 범위를 쓰던 인레이 힌트도 같은 계산을 사용한다.
gopls v0.20.0은 provider를 알리지만 기본 설정에서는 빈 토큰을 내므로 내장 서버 항목에서만 활성화 옵션을 보낸다.
Metals는 초기 설정 알림이 없으면 시맨틱 토큰 응답을 완료하지 않았다. `initialized` 뒤 `settings.metals.enableSemanticHighlighting: true`를 보내 설정 대기를 완료한다. `window/showMessageRequest`는 실행 승인이 없는 `null`로 답한다. 초기화를 프로토콜 오류로 중단하지 않지만 빌드 가져오기를 자동 승인하지도 않는다.

## 자동 검증

```sh
mise exec -- zig build test-editor-semantic-recovery -j2
mise exec -- zig build test-editor-semantic-recovery -Doptimize=ReleaseFast -j2
```

중립 31개(행동 3개, 모듈 탐색 28개), macOS 제품 7개(SMT 행동 3개, 모듈 탐색 4개)를 강제한다.
`SMT1`·`SMT2`는 스크롤·편집·낡은 version·range/full·provider 없음·오류 재시도의 기존 대조군이다.
`SMT3`는 EOF를 엄격히 검사하는 fake 서버를 통해 실제 제품 요청·색 적용·refresh·유실 복구를 확인한다.
fake 서버의 EOF 검사는 실제 서버 오류의 재현이며 응답 데이터를 꾸며 실제 서버 캡처로 주장하지 않는다.

| 회차 | 공격 가설 / 재현 조건 | 기대 및 확인한 결과 | 판정자 |
| --- | --- | --- | --- |
| 1 | 빈 문서에서 다음 줄을 만든다 | 끝 0:0, 유효 줄 안 | range endpoints |
| 2 | 끝 LF 없는 한 줄의 마지막 글자를 빼먹는다 | 끝 0:3 | range endpoints |
| 3 | 끝 LF를 중복으로 센다 | 마지막 빈 줄 1:0 | range endpoints |
| 4 | CRLF를 두 줄로 센다 | `a\r\nb` 끝 1:1 | range endpoints |
| 5 | 끝 CRLF 뒤에 가짜 줄을 더 만든다 | 끝 1:0 | range endpoints |
| 6 | UTF-16에서 한글·이모지를 byte로 센다 | `가😀` 끝 character 3 | range endpoints |
| 7 | UTF-8 협상에서도 UTF-16 길이를 쓴다 | 동일 텍스트 character 7 | range endpoints |
| 8 | 중간 줄까지 EOF로 넓힌다 | 요청한 다음 줄 0열에서 끝 | range endpoints |
| 9 | viewport 시작이 문서 밖이다 | 시작과 끝을 마지막 줄로 제한 | range endpoints |
| 10 | 역전된 viewport가 음수 범위를 만든다 | 끝이 시작보다 앞서지 않음 | range endpoints |
| 11 | idle 요청을 타임아웃으로 센다 | 상태·오류 수 불변 | timeout boundaries |
| 12 | 시계가 뒤로 가면 즉시 만료한다 | 포화 뺄셈으로 미만료 | timeout boundaries |
| 13 | deadline 직전에 응답을 포기한다 | deadline-1 대기 유지 | timeout boundaries |
| 14 | 정확한 deadline에도 영원히 기다린다 | 대기 해제·dirty·오류 수 1 | timeout boundaries |
| 15 | 만료 후 매 프레임 요청 폭주 | quiet 간격 전 재요청 없음 | timeout boundaries |
| 16 | 늦은 이전 응답이 새 대기를 해제한다 | 이전 seq 무시, 새 seq는 정상 수신 | timeout boundaries / SMT3 |
| 17 | 이미 완료한 요청을 다시 만료한다 | 만료 없음 | timeout boundaries |
| 18 | Go 옵션을 다른 서버에도 보내거나 Go에는 빠뜨린다 | Go opt-in만 initializationOptions 포함, Scala만 초기 설정 알림 추가 | gopls opt-in |
| 19 | 읽기 예외가 파일 편집·명령 실행 승인으로 번진다 | applyEdit·executeCommand 기본 거부, showMessageRequest만 선택 없음 | gopls opt-in / passiveRequest |
| 20 | 유효 EOF도 제품에서 잘못 직렬화하거나 refresh·유실 후 색이 안 온다 | 엄격한 fake에서 오류 0, 같은 revision 재적용, 유실 뒤 새 seq 응답 적용 | SMT3 |

## 실제 서버와 화면 증거

수정한 앱은 `prepare_lsp.py`가 만든 격리 사본이다. 유일한 Swift fixture 패치는 controlled-smoke의 예제 키 입력을 생략하고 Surface resize를 유지한다.
제품 LSP·색 계산·Metal paint는 수정 코드 그대로 실행한다. 앱에는 사용자 HOME과 provider 설정을 넘기지 않는다.
서버 child는 필요한 SDK 환경만 사용한다. 새 전역 언어 서버 설치나 사용자 프로젝트 빌드 승인은 하지 않는다.

- 수정 전: `/tmp/maru-editor-lsp-review-20261025/result.json`
- 직접 RPC 원인 대조: `/tmp/maru-semantic-audit-20261025/findings.json`
- 최종 앱 캡처의 당시 임시 경로(현재 소실): `/tmp/maru-semantic-recovery-verified-20261025/result.json`
- 실행 당시 `protocol.ndjson`·`server.stderr`·원본 PPM과 PNG·SHA-256으로 검증했다. 후속 검증 중 임시 실행 디렉터리가 사라져 현재 raw protocol·PPM·앱 사본은 없다. 삭제 주체는 확인하지 못했다. 원격 비교 이미지 5개와 남아 있던 테스트 로그는 `/Users/yoonhb/.cache/maru-agent-artifacts/editor-semantic-recovery-20261025`에 회수했다. `validation.json`은 관측 요약과 이 한계를 구분한다.
- `theme-gallery-fixture.json`의 `source_commit`은 기반 커밋이며, `working_tree_product_sha256`이 커밋 전 수정 소스를 식별한다. 캡처 후 커밋 소스와 이 해시를 대조한다.

Scala의 sbt 메타데이터만 둔 맨 파일은 가져온 build target이 없었다. 확인 요청을 정상 취소해도 초기 설정 알림이 없어 시맨틱 토큰은 반환되지 않았다. 별도 BSP 프로젝트에서 알림만 추가하면 53개 토큰이 반환되는 직접 통신 대조를 확인했다.
추가 직접 통신 대조군은 소유한 임시 프로젝트에 Scala CLI BSP 설정을 준비했다. 제품의 자동 빌드 승인을 뜻하지 않는다.
초기 설정 알림만 추가한 뒤에는 원래 sbt 메타데이터와 맨 파일을 그대로 둔 대조군에서도 53개 토큰이 반환됐다.
최종 앱 캡처는 원래 예제와 서버 명세를 사용한다. 정상 반환 여부는 프로젝트 준비와 별개로 초기 설정 알림 유무에 따라 갈렸다.

최종 실제 앱 결과: Rust 48·Kotlin 20·Dart 38·Go 47·Scala 53 토큰. 각 서버의 최종 선택 캡처에서 오류 응답은 0개다.
`working_tree_product_sha256`의 LSP 제품 소스 6개가 캡처 후 체크아웃과 모두 일치했다.
전후 PNG는 `sheets/*-semantic-recovery-before-after.png`이며 PR에 첨부한다.

Clean-room: LSP 공개 명세와 gopls·Metals 공식 설정 문서, 직접 JSON-RPC 대조로 수정했다.
추가 진단 중 `references/metals-semantic-audit-1.6.7`의 읽기 전용 v1.6.7 체크아웃에서 초기 설정 대기를 확인했다.
외부 구현 코드·자료구조를 복사하지 않았으며 Maru의 기존 설정 알림 경로를 확장했다.

최종 코드의 `mise run check`는 exit 0(938.95초), Debug·ReleaseFast 전용 검증은 각각 중립 31/31·제품 7/7이었다. 테스트 로그는 위 보존 경로에 있다. GitHub 제품 required CI 6개는 Draft 정책에 따라 SKIPPED이며 메타데이터만 통과했다.
