//! 파일 탐색기 트리 행 Chrome component의 facade다.
//!
//! 도메인 데이터는 `types.Props`로 들어오고, geometry 투영은 `build`가, semantic paint/text emission은
//! `view`가 소유한다. 이 facade에는 AppSession/filesystem/Metal import를 의도적으로 두지 않는다 —
//! 트리가 무엇을 여는지·어떤 경로인지는 host만 안다.
//!
//! `ids`는 FT2에서 생겼다 — 행이 action을 발행하고 히트테스트가 published tree로 옮겨 오면서
//! intent에 소비자가 생겼기 때문이다(docs/plans/file-tree-component.md §4).

pub const types = @import("file_tree/types.zig");
pub const ids = @import("file_tree/ids.zig");
pub const build = @import("file_tree/build.zig");
pub const view = @import("file_tree/view.zig");
