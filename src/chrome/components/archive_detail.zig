//! archive 세션 상세 패널 Chrome component의 facade다.
//!
//! 패널은 이미 redaction을 끝낸 표시용 DTO만 받는다. archive parser·AppSession·PTY·provider
//! 실행파일·filesystem·Metal import를 의도적으로 두지 않으며, 이 패널의 opaque action은 후속
//! AS4-b 통합 슬라이스에서 platform host가 해석한다.

pub const types = @import("archive_detail/types.zig");
pub const ids = @import("archive_detail/ids.zig");
pub const build = @import("archive_detail/build.zig");
pub const view = @import("archive_detail/view.zig");
