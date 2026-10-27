# 이름 없는 문서 첫 저장의 실제 IME 검증

상태: 실제 GUI 6개 장면과 독립 파일/모델 검사 완료. 제품 입력·저장 소스 변경 없음.

## 범위와 계약

U1~U4 및 첫 저장 비동기 연결은 이미 완료됐다. 기존 성능 하네스는 모델 begin/setText/commit을 사용했고,
#4583은 workspace 이름 변경, #4630은 이름 있는 문서의 NSSavePanel을 확인했다. 이번에는 동일한 공용
rename 입력 문맥의 `untitled_save` owner를 실제 OS 두벌식·한자 후보 선택으로 검증한다.
제품 저장 정책·원격 경로·이름 규칙을 새로 정하지 않는다.

사유 root 아래 fixture가 새 문서와 본문 `first save body\n`를 준비한다. 이후 입력은 기존 guarded HID
relay와 실제 텍스트 입력 클라이언트를 통한다. 후보 취소·선택 후에도 이름 없는 문서·본문·dirty와
목적지 미생성을 확인하며, 별도 Enter 뒤에만 저장·경로 채택·clean이 가능한지 검사한다.
한글·한자 저장, 모달 취소, 기존 이름 충돌 수락/거부, 쓰기 권한 실패를 구분한다.
실패는 읽기 전용 사유 디렉터리의 실제 I/O 오류로 재현하며 사용자 파일·권한은 바꾸지 않는다.

## 도구와 판정

기존 rename IME 하네스의 입력·입력 소스 복원·GPU capture를 재사용하되 private observer를
새 문서의 path/untitled/body/dirty/pending·이력 관측으로 교체한다. 입력 결과를 모델에 직접 쓰거나
fixture에서 저장 commit을 호출해 GUI 성공으로 대신하지 않는다. 사유 fixture 준비는 별도 export다.
기존 허용된 화면 캡처 앱으로 native 창을 촬영하며 앱 재빌드에 따른 권한 재설정을 요구하지 않는다.
PNG와 원시 자료는 저장소 밖에 보존하고 이미지는 PR 본문에만 업로드한다.

독립 검사기는 단계별 후보/이름/문서 불변, 디스크 bytes, 결과 경로·dirty·untitled·pending, Undo/Redo와
입력 소스 복원을 대조한다. Unicode 원문과 NFC 비교를 구분한다. 합성 증거 손상과 검사기 판정 제거
대조군은 실제 GUI/물리 입력 증거로 세지 않는다. 서로 다른 20개 이상 공격 조건을 포함한다.
원격 저장·VoiceOver·타 OS/파일시스템은 범위 밖이며 확인하지 않은 영역을 성공으로 확대하지 않는다.

## 확인 결과

같은 고정 앱에서 아래 장면을 각각 새 사유 root로 실행했다. 한자 장면은 후보를 한 번 취소하고
다시 열어 선택하며, 후보 Return 직후에도 이름 없음·dirty·pending=0·목적지 미생성을 확인한다.
다음 Enter에서만 첫 저장 또는 충돌 확인으로 넘어간다. 파일명은 확장자 없는 `한`·`韓`이며 실제 키로만 입력했다.

| 장면 | 결과 |
| --- | --- |
| 한글 첫 저장 | 조합 확정 Return 뒤 이름 입력 유지, 별도 Return 뒤 `한` 생성·경로 채택·clean |
| 한자 첫 저장 | 후보 취소/선택 뒤 입력 유지, 별도 Return 뒤 `韓` 생성·경로 채택·clean |
| 이름 입력 취소 | 파일 미생성, 이름 없음·본문·dirty 보존 |
| 기존 대상 덮어쓰기 수락 | 별도 확인창 후 기존 파일이 저장 본문으로 교체됨 |
| 기존 대상 덮어쓰기 거부 | sentinel bytes 보존, 이름 없음·본문·dirty 보존 |
| 쓰기 권한 실패 | 파일 미생성, 실패 안내 표시, 이름 없음·본문·dirty 보존 |

모든 장면에서 본문 `first save body\n`·surface 신원·pending 정산·Undo/Redo·입력 소스 복원을 확인했다.
`maru_palette_ime_witness`는 읽기 전용이다. 별도 `maru_untitled_model` 테스트 export는 저장 결과가
정산된 뒤 Undo/Redo를 실행하고 그 후 모델을 기록한다. Undo/Redo 전의 `settled` 관측과 그 후 모델을
독립 대조하므로 history 조작으로 저장 실패나 조기 저장을 가리지 않는다.
실제 후보 창·이름 필드·덮어쓰기 확인·실패 안내 이미지도 확인했다. PNG 검사는 창 ID·소유 PID·해시·
IHDR 크기를 검사하며 완전한 디코더나 OCR 판정자가 아니다. dirty 해제는 모델에 근거한다.

## 도구에서 발견·수정한 문제

- 초기 root 선택이 앱 시작의 자동 root 선택과 경합해 fixture가 입력 전에 기다렸다.
  사유 `workspace.root`를 명시하고, root 검증의 pending owner가 끝난 후에만 재제출한다.
- workspace rename의 sidebar 범위를 새 문서의 떠 있는 이름 입력창에도 쓰면 caret 판정이 틀린다.
  해당 owner의 실제 `renameCaretRect`를 사용한다.
- 후보 선택 후 ASCII 확장자를 `insertText`로 직접 넣는 실험은 키 해석 밖 콜백 소유권 방어에 거절됐다.
  제품 방어를 우회하지 않고, 검증에 필요 없는 확장자 입력을 제거해 파일명 전체를 실제 키로 입력한다.

이 장면들에서 제품 첫 저장 결함은 발견되지 않았다. 위 수정은 모두 private 검증 도구의 수정이다.
검사기는 정상 6개 장면과 PID·surface·owner·조기 저장/확인·본문·dirty·pending·이력·입력 소스·
후보 선택/조합·경로·디스크·창/PNG 손상을 거절하는 대조군을 갖는다. 첫 저장 전 불변, pending/history,
모델 본문, 디스크 bytes, 입력 소스 복원 판정을 각각 제거한 문법 유효 사본 5개도 모두 테스트가 실패시켰다.
원본 검사기의 전후 정상 대조군은 통과했다. 이들은 실제 제품 결함 주입이나 GUI 횟수가 아니다.

## 원시 자료와 재검증

`~/Library/Caches/maru-verification/untitled-first-save-ime-20261028-final-*`에 6개 실제 실행을 보존했다.
`...-final-matrix.json`과 최종 검사기로 다시 대조한 `...-independent-final.json`은 각 실행 위치·검사기 해시를
기록한다. `...-oracle-mutations-v2`는 검사기 판정 제거 사본과 결과다. 초기 fixture 시간 초과
`...-control{,-v2,-v3}`와 직접 확장자 입력 거절 `...-control-v4`도 별도로 남긴다.
실행 방법은 [도구 설명](../../tools/untitled-save-ime/README.md)을 따른다.

기존 첫 저장·rename IME 회귀, 독립 검사기·문서 링크·Zig 형식·Python 문법 검사를 통과했다.
후보 OCR·공용 five-window reducer·VoiceOver·원격 저장·다른 OS/파일시스템 검증으로 확대하지 않는다.
