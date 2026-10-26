# 실제 SDK 다중 파일 이름 바꾸기

`run.py --scenario rename`은 Rust·Go의 실제 언어 서버를 AppSession에 연결한다.
서버 결과를 합성하지 않고 F2·상자 입력·Enter와 `undo_workspace_edit` 명령을 사용한다.
기존 단일 파일 및 의존 진단/autoimport 시나리오는 유지한다.

## 실행

기존 [명시적 서버 설정](README.md)을 사용한다. SDK 설치·실행은 opt-in이다.

```sh
python3 tools/editor-lsp-real/run.py --scenario rename --build --optimize Debug \
  --servers-json /absolute/path/servers.json --output /absolute/new/debug-output
python3 tools/editor-lsp-real/run.py --scenario rename --build --optimize ReleaseFast \
  --servers-json /absolute/path/servers.json --output /absolute/new/fast-output
python3 tools/editor-lsp-real/verify.py /absolute/path/saved-output
```

빌드 타깃은 `editor-real-lsp-rename-judge`, 실행 파일은
`zig-out/bin/maru-real-lsp-rename-test`다. `--judge`로 고정 사본을 지정할 수 있다.
`test-editor-real-lsp-rename`은 명시한 `MARU_REAL_LSP_CASE` 한 건을 실행하며,
실제 사례 하나와 모듈 참조 넷, 총 다섯이 통과해야 한다. 사례 없는 skip을 성공으로 세지 않는다.
rename의 기본 언어는 Rust·Go이며 다른 언어는 출력 생성 전에 거절한다.

## 고정된 범위

세 파일의 `produce` 정의와 호출을 `renamed_produce`로 바꾼다. `main`과 `values`는
열린 문서이고 `other`는 끝까지 닫혀 있어야 한다. 한글·emoji 뒤의 식별자를 사용해
협상된 UTF-8/UTF-16 위치와 서버 편집을 검사한다. 같은 철자의 문자열·주석과
`produce_extra`는 그대로여야 하므로 단순 전체 문자열 치환은 통과할 수 없다.

1. 각 rename 전에 실제 정의 조회가 성공해야 한다. 초기 빈 진단이나 didChange 송신
   완료만으로 인덱싱 완료를 판단하지 않는다. 읽기 요청만 제한 시간 안에서 재시도한다.
2. F2·키 입력·Enter로 실제 rename을 보내고 열린 두 버퍼와 세 디스크 파일이 함께
   바뀌는지 확인한다. 열린 문서마다 Undo 이력이 하나 늘고 dirty가 해소돼야 한다.
   관련 파일 둘 이상 자동 저장이라는 기존 §8.2f 정책을 검증한다.
3. `undo_workspace_edit` 한 번으로 세 파일을 복원하고 열린 문서의 저장도 확인한다.
   서버에 역방향 rename을 보내서 복원하지 않는다.
4. 다음 실제 rename 응답을 wire에서 관측하되 LSP pump는 잠시 진행하지 않는다.
   로컬 주 파일을 편집한 뒤 응답을 처리하여 stale 거절과 로컬 편집 보존을 확인한다.
5. 원문을 복원한 뒤 또 다른 실제 응답을 같은 방식으로 관측한다. nonce 소유의 닫힌
   참조 파일을 잠시 제거한 후 처리하여 전체 검증 단계의 거절과 두 버퍼의 원문 보존을
   확인한다. 참조 파일은 실패 경로에서도 복원한다.

이것은 응답의 **처리 시점**을 제어하는 검사다. proxy의 서버 응답 바이트를 바꾸거나
새 응답을 주입하지 않는다. 서버 응답을 못 얻거나 오류/빈 결과를 얻으면 해당 실행은
실패로 남긴다. 실패한 전체 사례를 자동으로 다시 실행해 성공으로 덮지 않는다.
최대 열여섯 순차 대기의 예산을 외부 프로세스 시한에 포함한다.

## 독립 증거 판정

`rename_oracle.py`는 URI별 원문/version을 추적하고 세 실제 rename 요청·응답을
각각 대응한다. `changes`와 `documentChanges`를 독립 적용하여 세 파일의 실제 결과가
예상한 이름 변경인지 검사한다. 열린 문서 version은 요청 snapshot과 같아야 하며,
gopls가 닫힌 파일에 보내는 version 0은 열린 문서의 version으로 취급하지 않는다.
파일 연산·예상 밖 URI·누락된 참조·빈 결과·겹친 편집은 성공 증거가 될 수 없다.

제품 보고의 before/applied/undone/stale/rejected 다섯 단계 × 세 파일, 총 열다섯
표본을 원문·buffer·disk·version·Undo·dirty로 대조한다. 저장 알림도 해당 적용/복원
구간 안에 있어야 한다. 나중의 수동 저장으로 Undo 자동 저장을 대신 증명할 수 없다.
서버 응답→로컬 무효화→다음 요청의 순서도 원본 wire에서 확인한다.

컴파일된 컨트롤러 열 개의 지문과 도구 여섯 개 사본, 실행 바이너리·원본 wire·stderr를
보존한다. 네이티브 진입점은 `editor/real_lsp/rename.zig`이며 저장 이름은
`sources/rename_judge.zig`다. 제품 `rename.zig`와 `workspace_edit.zig`도 따로 보존한다.
이 지문은 대상 컨트롤러의 대응이며 저장소 전체 재현 빌드의 증거는 아니다.

## 적대적 검증과 한계

SDK 없는 Python 시험은 정상 Rust/Go·두 WorkspaceEdit 모양과 20개 이상의 서로 다른
파손 조건을 검사한다. 잘못된 결과/계수/버전·bool 위장·Undo 누락·닫힌 파일 열림·
부분 적용·서버 응답/참조/정의 조회 누락·다른 이름·저장 시점 위조·잘못된 소스/도구
보관·언어/시나리오 혼합·실패 종료를 거절한다. 합성 단위 fixture는 실물 SDK 결과가 아니다.

검증·준비 단계 실패는 전체 보존한다는 기존 계약을 확인한다. **디스크 쓰기 도중의 실패는
원자적 다중 파일 트랜잭션이 아니다.** 기존 §8.2f는 이미 적용한 파일을 기록하여 되돌릴
수 있게 한다. 닫힌 파일을 읽지 못하는 위 검사를 디스크 쓰기 실패까지 증명한 것으로
확장하지 않는다. 쓰기·할당 실패는 기존 WSE/RNM 제품 회귀의 범위다.

실제 AppSession과 프레임 준비의 headless 증거다. 물리 GUI·IME·화면 픽셀·원격 서버·
파일 생성/이동/삭제 WorkspaceEdit·다른 SDK 버전은 검증 범위 밖이다.
