# 에이전트 활동 뷰 검색창 IME 범위 문맥

상태: 구현과 자동·실제 입력 진단 완료. 고정 앱의 화면 기록 권한을 기다리며 PNG/OCR 검증은 미완료다.

## 원인과 보존할 계약

활동 뷰 검색은 `agent_activity.State.search`의 OverlayInput을 사용하지만 native chrome
IME generation/projection에는 연결되지 않는다. 범위 콜백이 일반 문자 삽입으로 돌아가므로
중간 재변환이 원래 단어를 교체하는지 먼저 실제 ABI로 검사한다.

[활동 뷰 검색 계약](../agent-activity-view.md)의 두 층을 유지한다. 라벨 필터와 본문 답의 유효성은 확정 query로
판정하고 preedit는 표시만 한다. 후보 확정 Return은 검색 종료/본문 worker 요청으로 재생하지
않으며, 별도로 누른 Return은 기존처럼 검색줄을 닫고 본문 검색을 시작한다.
Escape 두 단계, 검색어 보존, 종류 필터, 크게 보기/펼침, 뷰 이탈 시 받은 본문 답 보존과
source 변경 시 초기화, 로컬/원격 worker 계약을 유지한다. 새 선택·좌우 이동 UX는 추가하지 않는다.
NFD를 정규화하지 않고 기존 `max_query_bytes`와 legacy 문자 입력 정책을 유지한다.
native 편집은 완성될 확정 query가 그 한도를 넘으면 키 전체를 원자적으로 거절한다.
동적 preedit에 임의의 새 고정 길이 제한을 추가하지 않는다.

## 소유와 구현 경계

범위·선택·취소·deep snapshot·OOM·키 소비는 기존 중립 `overlay_input_ime.Projection`과
`Transaction`을 재사용한다. query 한도 판정이 필요하면 중립 입력 계약에 두고 host에
UTF-16 계산이나 편집 정책을 복제하지 않는다.
macOS adapter는 source 입력 owner와 확정 뒤의 filter/body 부수 효과만 소유한다.
owner는 활성 surface와 활동 뷰의 검색 lifecycle epoch를 포함한다. 새 namespace는 bit 54이며
기존 Session Dock 낮은 token 범위를 그 아래로 제한한다. 검색 재진입/clear/이탈·source 초기화·
종류 전환·modal·terminal pin·초기화 전·빈 topology·포화에서 예전 키가 새 owner를 쓰지 않게 한다.

확정 전에 전체 query/preedit와 필터 publication 용량을 준비한다. 준비 실패/범위 오류/한도
초과는 query·preedit·필터·기존 body 답과 worker 권위를 바꾸지 않는다. 성공한 확정 query가
바뀐 경우에만 기존 `cancelBodySearch`와 `rebuildFilter` 경로를 호출한다.
특히 `applyFilter`의 기존 OOM show-all fallback이 native 키를 반쪽 확정하지 않도록 준비 순서를 검증한다.

검색줄 prompt·tail clipping·본문 hint를 보존하고, projected text/selected offset에서 그린
caret과 OS anchor가 같은 기하를 읽게 한다. caret은 grapheme 경계로만 paint snap한다.
본문 hint를 caret 길이에 더하지 않는다. 버퍼 부족으로 검색줄을 통째로 비우지 않는다.

## 검증 순서

1. 공개 ABI `ime_insert_with_range`에서 `a😀z`의 UTF-16 `(1,2)`를 `韓`으로 교체하는
   실패를 제품 변경 전에 재현한다. candidate Return과 독립 Return도 구분한다.
2. 중간/접미사, 비-BMP·surrogate split·NFD·빈/제어 입력, query 경계와 긴 preedit,
   여러 콜백의 전체 rollback, allocation failure와 다음 키 회복을 검사한다.
3. 확정/preview/cancel의 라벨과 body 답 보존, 실제 본문 요청 0/1, 두 단계 Escape,
   종류·source·view·window focus 전환, stale owner·terminal pin·포화·bootstrap을 검사한다.
   서로 다른 20개 이상 조건과 정상 대조군을 유지한다.
4. 컴파일되는 range 무시·rollback 누락·잘못된 filter publication·후보 Return 누출·
   owner pin 제거 등의 제품 변이를 주입해 실제 단언 실패와 원복 통과를 확인한다.
5. 독립 합성 손상 기록 검사와 별도로 실제 두벌식·후보 취소 5회·韓 확정·별도 Enter의
   body 검색·터미널 복귀·입력 소스 복원을 확인한다. 진단 후 최종 앱을 고정하고
   같은 앱에서 독립 후보 창 식별과 PNG/hash/OCR을 검사한다.
6. 기존 activity/remote activity·다른 IME·전체 ABI·경계·Swift·문서 검사를 실행한다.
   이미지와 원시 산출물은 저장소 밖에 두고 이미지는 PR 본문에만 업로드한다.

스캔/검색 worker·원격 I/O·설정 값 편집·다른 picker 전체 이관은 이 범위 밖이다.
저장 상태가 바뀌므로 구현 시 최신 main의 ABI와 크기 pin을 함께 확인한다.

## 구현 중 재현과 설계 대조

실제 ABI의 범위 교체가 `a😀z韓`으로 덧붙는 실패를 재현했고 native 연결 후 `a韓z`가 됐다.
초기 호스트 34개와 중립 모델 10개(Debug/ReleaseFast)를 통과했다.

표시 helper의 작은 byte buffer 검사에서 TextField의 코드포인트 폭과 실제 notice의 grapheme
폭을 섞어 빈칸과 잘못된 경계를 만드는 실패를 발견했다. TextField 전원의 폭 정책을 바꾸지 않고
기존 `inline_edit.composeLineFit`의 순수 clipping 계산을 `fitLineEnd(text, caret_end, cols)`로
추출한다. 원래 인라인 소비자도 이를 호출하고 활동 뷰는 같은 계획과 `text_layout.plan`을 사용한다.
이름 편집·주소창의 기존 회귀를 함께 확인하며, legacy oversized notice fallback은 보존한다.

## 확인된 결과와 남은 증거

공개 ABI의 중간 교체·빈 교체·surrogate split·NFD·잘못된 UTF-8·키 밖 콜백,
preview/cancel/후보 Return/별도 Return·Escape·종류/뷰/소스/모달 전환·terminal pin,
세대 포화·빈 topology·OOM·한도·다음 키 회복과 paint/anchor를 포함한 호스트 artifact 39개가 통과했다.
중립 모델 15개는 Debug/ReleaseFast에서 통과했고 주소창·이름 편집·사이드바 검색 회귀도 통과했다.
합성 기록의 정상 대조군과 서로 다른 30가지 손상은 실제 GUI·픽셀 증거와 별도로 검사한다.

범위 무시, rollback 누락, filter 용량 준비 우회, 기존 body 답 무효화 누락,
후보 Return의 미소비 제품 변이는 각각 컴파일 뒤 단언 실패로 검출됐다. 원복 대조군도 통과했다.
검사 명령은 `python3 tools/activity-search-ime/mutations.py --output <new-external-dir>`이다.

실제 두벌식 입력 진단에서 후보 취소 5회와 韓 선택을 확인했다. 선택까지 body 읽기는 0이고,
별도 실제 Return 뒤 193바이트를 읽어 본문 결과 1개를 찾았다. 실제 터미널 클릭과 `/` 입력 뒤
PTY 증가가 1이며 본문 답은 유지됐다. 입력 소스 복원도 확인했다.
이 진단은 화면 기록 허용 없이 진행하므로 PNG/OCR 통과로 간주하지 않는다.

산출물은 저장소 밖 `../maru-activity-ime-evidence-20261027/diagnostic-run`과 같은 디렉터리의
회귀 로그에 보관한다. 앱은 content hash `07d2c9fabee400961dd7eb836b60e80e16a221ff67327129cd54da5c35c4a965`로
고정했으며 권한 허용 뒤 같은 앱에서 픽셀 검증을 실행한다. 실시간 후보창·이미지는 저장소에 커밋하지 않는다.
