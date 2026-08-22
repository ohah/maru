//! 탐색기 트리 행의 opaque action identity다(FT2).
//!
//! 표 자체는 generic이다(`ui/intent_table.zig`). 이 파일이 소유하는 것은 **어떤 intent가 있는가**
//! 하나뿐이며, ID 발급·세대 검증·disabled 거부는 공용 구현이 한 곳에서 한다.

const intent_table = @import("../../ui/intent_table.zig");

/// **모델 인덱스를 싣는다**(창 안의 자리가 아니다). 창은 스크롤로 매 프레임 달라지므로 창 인덱스를
/// 실으면 늦게 도착한 up이 엉뚱한 행을 연다. 그래도 host는 그 인덱스를 **다시 조회**해야 한다 —
/// 비동기 재스캔이 목록 자체를 바꿀 수 있고, 그 방어는 세대 검증만으로는 부족하다.
pub const Intent = union(enum) {
    /// 행을 눌렀다. 파일이면 열고, 폴더면 펼침을 토글한다 — 그 분기는 host의 도메인 지식이다.
    activate_row: usize,
};

pub const Table = intent_table.IntentTable(Intent);
pub const Entry = Table.Entry;
