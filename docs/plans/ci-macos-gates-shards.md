# macOS 전용 게이트 분할과 신뢰된 캐시 보충

상태: 구현 및 로컬 검증 중. 사용자가 60분 지연 원인 설명 뒤 캐시 경로 복구·집계 분할을 승인했다.

## 문제와 유지할 계약

PR #4694의 macOS-only gates는 Zig 캐시의 모든 복원 키가 미스였고 전용 집계가
58분 52초를 썼다. 후속 SSH 검사 중 잡의 60분 제한으로 취소됐다. 현재 그룹 캐시는
0개였고, PR은 저장하지 않으며 검증된 main은 잡 전체를 건너뛰어 정상 경로의 캐시
보충이 사라졌다. 원본 run/job과 로그는 외부 pr-4694-macos-only-timeout 기록에 보존한다.

기존 native 게이트·SSH/캡처/원격 SCM 검사의 범위·단언·개별 timeout을 유지한다.
필수 체크 이름 macOS-only gates를 유지하며 worker 하나의 실패/취소/누락도 성공으로
바꾸지 않는다. 기본 로컬 test-macos-only는 계속 전체를 실행한다. 캐시 writer는 신뢰된
main push만 허용하고 PR 캐시를 main에 승격하지 않는다.

## 설계

- macOS worker 세 개가 기존 집계의 실제 빌드 그래프 root를 분담한다. 등록은 기존 집계에
  그대로 두고 모든 등록이 끝난 뒤 안정된 논리 이름으로 분할한다. 옵션 오류·빈 샤드는 거절한다.
  root ID·전체 목록·선택 목록의 manifest를 남기고 독립 집계가 세 목록의 정확한 합집합을 확인한다.
  공유 빌드/생성 prerequisites는 각 runner에서 필요할 수 있으며 root 개수를 test passed로 세지 않는다.
- 원래 잡의 SSH/진단/원격 SCM 추가 검사도 세 worker에 빠짐없이 분배한다. 실행 receipt를
  manifest와 묶어 검증한다. fail-fast는 끄고 실패 진단을 샤드별로 보존한다.
- Linux 집계 잡이 기존 필수 체크 이름을 소유한다. 분류 실패는 전체 실행 쪽으로 기울며,
  비 runtime/draft 건너뛰기와 검증된 main의 compile-only만 명시적으로 구분한다.
- PR/수동/미검증 main은 실제 검사를 실행한다. 같은 tree의 PR 성공으로 증명된 main은
  선택 root가 필요로 하는 Zig compile artifacts만 빌드하는 별도 warm target을 실행한다.
  test 실행 node를 warm target에 넣지 않고 실제 Build 그래프에서 검증한다. 생성기 등 컴파일
  prerequisite는 유지한다. Python 등 외부 하네스 내부의 숨은 빌드까지 warm했다고 주장하지 않는다.
- 캐시는 OS·세 샤드 ID·의존성/도구 버전·prune 계약으로 나눠 main만 저장한다. 같은 tree 검증은
  테스트 재실행만 생략하며 trusted compile/save는 계속 실행해 캐시를 보충한다. main proof 판정은
  기존 도구를 재사용한다. 샤드별 캐시 예산을 제한하고 기존 세대 정리 정책을 유지한다.

PR의 기존 file explorer/AppKit 두 worker와 합쳐 macOS 5개 범위다. 실제 런너 대기와 main 전용
잡의 경쟁은 별도로 관측한다. 분할 비율만으로 3배 단축을 주장하지 않고 cold CI 결과로 확인한다.

## 검증

실제 그래프의 전체/세 plan manifest를 대조하고 warm 그래프가 test 실행을 포함하지 않는지
확인한다. 잘못된 옵션·중복/누락·다른 catalog/head/mode·worker 실패·허용되지 않은 compile-only·
추가 검사 누락·캐시 writer 조건 등 서로 다른 20조건 이상을 공격하고 정상 대조를 둔다.
기존 pr-proven·캐시/샤드 경계, 전체 경계·문서·포맷을 실행한다. CI의 세 cold worker와 필수 집계,
머지 뒤 trusted main의 캐시 보충을 별도로 확인한다. 정책·검사 범위를 줄여 시간을 맞추지 않는다.

## 로컬 그래프 확인

리베이스 전 macOS 그래프의 고유 root는 192개이며 세 샤드가 66·66·60개를 선택했다.
compile artifact 수는 67·60·58개다. 전체 plan과 세 plan의 catalog가 같고 선택 목록의
합집합이 중복 없이 전체와 일치한다. root는 테스트 개수가 아니며 실행 시간 비율도 아니다.
부분 재실행은 같은 workflow run/head의 샤드별 최신 attempt를 선택한다. 최신 보고서가
불완전하면 이전 성공으로 대체하지 않는다. manifest·receipt·로그는 같은 artifact root에 보존한다.

최신 main `27e0173c9`에는 native spawn 검사가 추가돼 root는 193개, 샤드는
66·67·60개, compile artifact는 67·61·58개다. 전체와 세 plan의 정확한 합집합을
리베이스 뒤 다시 확인했다. 이 main은 기존 단일 잡 상한도 90분으로 조정했다. 리베이스 후 각 샤드도
이 상한을 보존한다. 60분 지연을 해결했다는 판단은 상한 증가가 아니라 실제 샤드 실행 결과로 한다.
