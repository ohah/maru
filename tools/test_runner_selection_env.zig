//! 공용 테스트 러너(`simple_test_runner.zig`)가 **어느 테스트를 돌릴지** 고르는 env 이름 — 단일 출처.
//!
//! 러너와 빌드(`build/support.zig` `uncacheTestRunsWhenNarrowed`)가 둘 다 이 목록을 import 한다. 빌드는 이 중
//! 하나라도 호출자 셸에 걸려 있으면 테스트 바이너리를 도는 run 스텝이 캐시된 «통과»를 재사용하지 못하게 한다 —
//! 좁힌 실행이 앞선 전체 실행의 결과로 끝나거나, 좁힌 실행의 결과가 다음 전체 실행 자리에 남지 않게. 이름이
//! 두 벌이면 러너에 새 선택 변수가 생길 때 빌드 쪽이 모르고 지나간다. 그래서 값이 아니라 목록을 공유한다.
//!
//! 순수 상수만 둔다 — 러너가 import 하므로 테스트를 넣으면 「file exists in modules」로 막힌다(`test_runner_home.zig`
//! 머리 주석과 같은 이유).

/// CSV, 이것으로 시작하는 이름 **만** 돌린다.
pub const keep_only_prefix = "MARU_TEST_KEEP_ONLY_PREFIX";
/// CSV, 이것으로 시작하는 이름은 건너뛴다.
pub const skip_prefix = "MARU_TEST_SKIP_PREFIX";
/// CSV, `skip_prefix` 의 예외.
pub const keep_prefix = "MARU_TEST_KEEP_PREFIX";
/// `i/n`, 이름 해시 mod n 이 i 인 것만 돈다.
pub const shard = "MARU_TEST_SHARD";

pub const names = [_][:0]const u8{ keep_only_prefix, skip_prefix, keep_prefix, shard };
