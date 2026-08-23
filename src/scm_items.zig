//! 소스 컨트롤 **행 모델 → 컴포넌트 항목**. `session.scm_view.Row` 를 `chrome.components.scm_dock.
//! types.Item` 으로 옮기는 순수 변환이다.
//!
//! ## 왜 최상위인가 — 둘 다 서로를 못 본다
//!
//! 경계 게이트가 이렇게 정해 놨다(docs/layering-and-portability.md §2·§8):
//!
//! ```text
//! session 금지: pty platform session chrome app
//! chrome  금지: pty platform terminal renderer session app
//! ```
//!
//! **session 은 chrome 을, chrome 은 session 을 import 할 수 없다.** 그래서 이 변환은 어느 쪽에도
//! 못 산다 — `src/text_shaper.zig` 가 같은 이유로 `src/chrome/` 밖에 있는 것과 같은 자리다
//! (§2m.18). `scm_dock/types.zig` 의 `sectionOf` 주석이 이미 그 사실을 적어 뒀다:
//! *"component 는 session 모듈을 import 하지 않는다."*
//!
//! ## 왜 뺐나
//!
//! **`platform/macos/app_session/scm_dock.zig` 에 있던 것을 그대로 옮겼다.** Windows 소스 컨트롤
//! 표면이 같은 변환을 필요로 하는데, 다시 쓰면 같은 사실의 두 번째 출처가 된다 — 파일 이름과
//! 디렉터리를 **어디서 자르는가**, 충돌 행에 동작을 붙일 것인가 같은 판정이 갈린다.
//!
//! 옮긴 것은 이 넷뿐이다(전부 순수 — `self` 도 allocator 도 안 쓴다). 다중 저장소·커밋 줄·쓰기 오류를
//! 엮는 **바깥 루프는 그대로 macOS 에 뒀다** — 그것은 그 호스트의 상태이고 옮길 이유가 없다.
//!
//! **문자열은 복사하지 않는다** — 호출자의 git 결과가 프레임 동안 살아 있고, component 는 immutable
//! snapshot 만 읽는다.

const std = @import("std");

const scm_view = @import("session/scm_view.zig");
const types = @import("chrome/components/scm_dock/types.zig");

/// 모델 행 하나를 component 항목으로 옮긴다.
pub fn itemFor(
    row: scm_view.Row,
    repo_index: u32,
    model_index: usize,
    selected_row: ?usize,
    collapsed: [scm_view.section_count]bool,
) types.Item {
    return switch (row) {
        .section => |section| .{
            .section = .{
                .repo_index = repo_index,
                .section = sectionOf(section.section),
                .count = @intCast(section.count),
                .collapsed = collapsed[@intFromEnum(section.section)],
                // 섹션 헤더의 일괄 동작. 모델이 "대상이 하나도 없으면(전부 충돌) `.none`"까지 판정해 둔다.
                .action = actionOf(section.action),
            },
        },
        .file => |file| .{
            .file = .{
                .repo_index = repo_index,
                .model_index = @intCast(model_index),
                .name = std.fs.path.basename(file.path),
                .dir = file.path[0 .. file.path.len - std.fs.path.basename(file.path).len],
                .status = statusOf(file),
                .letter = file.letter,
                .added = file.added,
                .removed = file.removed,
                .has_delta = !file.unknown_delta and !file.binary,
                .binary = file.binary,
                // 행 동작(`+`/`−`). **충돌 행은 모델이 `.none`으로 준다** — `git add`는 충돌을 "해결됨"으로
                // 표시하므로, 그 행에 `+`를 두면 사용자가 의도하지 않은 해결이 일어난다.
                .action = actionOf(file.action),
                .selected = selected_row != null and selected_row.? == model_index,
            },
        },
        .more => |more| .{ .more = .{ .repo_index = repo_index, .section = sectionOf(more.section), .hidden = @intCast(more.hidden) } },
        .notice => |notice| .{ .notice = notice.text() },
    };
}

pub fn sectionOf(section: scm_view.Section) types.Section {
    // 값 집합이 갈리면 이 switch가 컴파일에서 걸린다(component는 session 모듈을 import하지 않는다).
    return switch (section) {
        .staged => .staged,
        .changes => .changes,
    };
}

pub fn statusOf(file: scm_view.FileRow) types.StatusKind {
    if (file.conflicted) return .conflicted;
    if (file.untracked) return .added; // 새로 생긴 것과 같은 계열(§3.5.2)
    return switch (file.letter) {
        'A', 'C' => .added,
        'D' => .deleted,
        else => .modified,
    };
}

pub fn actionOf(action: scm_view.RowAction) types.RowAction {
    return switch (action) {
        .stage => .stage,
        .unstage => .unstage,
        .none => .none,
    };
}

const testing = std.testing;

const no_collapse = [_]bool{ false, false };

test "파일 행: 이름과 디렉터리를 나눠 싣는다" {
    // **이 분할이 화면의 모양을 정한다** — 컴포넌트는 경로를 한 덩어리로 안 그리고 파일명(굵게) +
    // 디렉터리(흐리게)로 나눠 그린다. Windows 종단 판정이 처음에 이것을 몰라 `0/1` 을 냈다.
    const row = scm_view.Row{ .file = .{ .section = .changes, .path = "src/main.zig", .letter = 'M', .action = .stage } };
    const item = itemFor(row, 0, 3, null, no_collapse);
    try testing.expectEqualStrings("main.zig", item.file.name);
    try testing.expectEqualStrings("src/", item.file.dir);
    try testing.expectEqual(@as(u32, 3), item.file.model_index);
}

test "디렉터리가 없으면 dir 이 빈다" {
    const row = scm_view.Row{ .file = .{ .section = .changes, .path = "README.md", .letter = 'M', .action = .stage } };
    const item = itemFor(row, 0, 0, null, no_collapse);
    try testing.expectEqualStrings("README.md", item.file.name);
    try testing.expectEqualStrings("", item.file.dir);
}

test "충돌 행은 동작이 없다 — `git add` 가 해결로 표시하기 때문" {
    const row = scm_view.Row{ .file = .{ .section = .changes, .path = "a.txt", .letter = 'U', .action = .none, .conflicted = true } };
    const item = itemFor(row, 0, 0, null, no_collapse);
    try testing.expectEqual(types.StatusKind.conflicted, item.file.status);
    try testing.expectEqual(types.RowAction.none, item.file.action);
}

test "상태 글자 → 색 계열" {
    const cases = [_]struct { letter: u8, want: types.StatusKind }{
        .{ .letter = 'A', .want = .added },
        .{ .letter = 'C', .want = .added },
        .{ .letter = 'D', .want = .deleted },
        .{ .letter = 'M', .want = .modified },
        .{ .letter = 'R', .want = .modified },
    };
    for (cases) |c| {
        const row = scm_view.FileRow{ .section = .changes, .path = "x", .letter = c.letter, .action = .stage };
        try testing.expectEqual(c.want, statusOf(row));
    }
    // 추적되지 않은 파일은 글자와 무관하게 **새로 생긴 것과 같은 계열**이다(§3.5.2).
    const untracked = scm_view.FileRow{ .section = .changes, .path = "x", .letter = '?', .action = .stage, .untracked = true };
    try testing.expectEqual(types.StatusKind.added, statusOf(untracked));
}

test "선택은 모델 인덱스로 판정한다 — 화면 자리가 아니다" {
    // **창 자리를 쓰면 스크롤한 뒤 누른 행과 열리는 행이 어긋난다**(그 필드 doc — P1b 가 그렇게 나갔다).
    const row = scm_view.Row{ .file = .{ .section = .changes, .path = "a", .letter = 'M', .action = .stage } };
    try testing.expect(itemFor(row, 0, 7, 7, no_collapse).file.selected);
    try testing.expect(!itemFor(row, 0, 7, 8, no_collapse).file.selected);
    try testing.expect(!itemFor(row, 0, 7, null, no_collapse).file.selected);
}

test "섹션 행: 접힘 상태를 그 섹션의 자리에서 읽는다" {
    const staged = scm_view.Row{ .section = .{ .section = .staged, .count = 2, .action = .unstage } };
    const changes = scm_view.Row{ .section = .{ .section = .changes, .count = 5, .action = .stage } };
    const collapsed = [_]bool{ true, false }; // staged 만 접힘
    try testing.expect(itemFor(staged, 0, 0, null, collapsed).section.collapsed);
    try testing.expect(!itemFor(changes, 0, 0, null, collapsed).section.collapsed);
    try testing.expectEqual(@as(u32, 5), itemFor(changes, 0, 0, null, collapsed).section.count);
}

test "binary·미지의 증감은 has_delta 를 끈다" {
    const bin = scm_view.Row{ .file = .{ .section = .changes, .path = "a.png", .letter = 'M', .action = .stage, .binary = true } };
    try testing.expect(!itemFor(bin, 0, 0, null, no_collapse).file.has_delta);
    const unknown = scm_view.Row{ .file = .{ .section = .changes, .path = "a.txt", .letter = 'M', .action = .stage, .unknown_delta = true } };
    try testing.expect(!itemFor(unknown, 0, 0, null, no_collapse).file.has_delta);
    const known = scm_view.Row{ .file = .{ .section = .changes, .path = "a.txt", .letter = 'M', .action = .stage, .added = 3, .removed = 1 } };
    try testing.expect(itemFor(known, 0, 0, null, no_collapse).file.has_delta);
}
