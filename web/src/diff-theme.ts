//! diff 본문의 **시각 언어**(제품과 스모크 게이트가 공유하는 CM6 테마).
//!
//! 기준은 GitHub의 diff다 — 리뷰어가 이미 그 규칙에 익숙하므로 새 언어를 배우게 하지 않는다:
//! ⑴ 줄 전체에 옅은 색을 깔고 **바뀐 글자만 진하게** 겹친다(어느 줄인지와 어디가 바뀌었는지를 한 번에 준다),
//! ⑵ 추가는 초록·삭제는 빨강, ⑶ 줄 번호는 본문보다 흐리게 두고 얇은 세로선으로 본문과 나눈다.
//!
//! **색은 알파로 얹는다**(불투명 색을 박지 않는다). 이 패널은 사용자의 터미널 테마 위에 뜨고 밝은·어두운 배경이
//! 모두 가능하므로, 배경색을 가정하면 한쪽에서 글자가 안 읽힌다. 알파면 어느 배경에서도 같은 의미로 보인다.

import { EditorView } from "@codemirror/view";

/// **색은 maru 터미널 테마에서 온다**(native가 `--maru-diff-*`를 주입한다 — session/syntax_theme.zig). 편집기
/// 하이라이트가 터미널 팔레트를 따르는 것과 같은 규율이다: 사용자가 테마를 바꾸면 diff도 같이 바뀌어야 한 창
/// 안에서 색 언어가 갈리지 않는다. 폴백은 GitHub 색 — 변수가 없는 환경(스모크 하니스 기본값)에서도 의미가 선다.
const added = "var(--maru-diff-added, #3fb950)";
const removed = "var(--maru-diff-removed, #f85149)";

const line_alpha = "16%";
const text_alpha = "34%";
const gutter_alpha = "60%";

/// **쪽별로 색이 갈린다.** merge는 편집기 루트에 `cm-merge-a`(원본)·`cm-merge-b`(수정본)를 붙이므로 그 클래스로
/// 가른다 — 왼쪽의 "바뀐 줄"은 삭제, 오른쪽은 추가다. merge 기본 테마가 바뀐 글자에 2px 그라데이션(밑줄처럼 보이는
/// 것)을 깔고 그 선택자가 `&light.cm-merge-a .cm-changedText`처럼 특이도가 높으므로, 여기서도 같은 형태로 써야
/// 덮인다(단순히 `.cm-changedText`로 쓰면 조용히 무시된다 — 실측).
export const diff_theme = EditorView.theme({
  "&": {
    // 본문 글꼴은 앱 터미널과 같은 계열로 — 같은 코드가 두 화면에서 다른 모양이면 대조가 어렵다.
    fontFamily:
      "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace",
    fontSize: "12px",
    backgroundColor: "transparent",
  },
  ".cm-scroller": { lineHeight: "1.5" },
  ".cm-content": { padding: "4px 0" },

  // ── 줄 번호: 본문보다 흐리고, 얇은 선으로 본문과 나눈다. 숫자는 폭이 일정해야 자리가 안 흔들린다.
  ".cm-gutters": {
    backgroundColor: "transparent",
    border: "none",
    borderRight: "1px solid color-mix(in srgb, CanvasText 12%, transparent)",
    color: "color-mix(in srgb, CanvasText 45%, transparent)",
  },
  ".cm-lineNumbers .cm-gutterElement": {
    padding: "0 8px 0 12px",
    fontVariantNumeric: "tabular-nums",
    minWidth: "2.5em",
  },

  // ── 바뀐 줄: 옅은 배경 + 왼쪽 색 띠(색만으로 구분하지 않게 위치 신호를 함께 준다).
  "&.cm-merge-a .cm-changedLine, & .cm-deletedChunk": {
    backgroundColor: `color-mix(in srgb, ${removed} ${line_alpha}, transparent)`,
    boxShadow: `inset 2px 0 0 color-mix(in srgb, ${removed} ${gutter_alpha}, transparent)`,
  },
  "&.cm-merge-b .cm-changedLine, & .cm-inlineChangedLine": {
    backgroundColor: `color-mix(in srgb, ${added} ${line_alpha}, transparent)`,
    boxShadow: `inset 2px 0 0 color-mix(in srgb, ${added} ${gutter_alpha}, transparent)`,
  },

  // ── 바뀐 글자: 줄 색 위에 한 겹 더. merge의 2px 그라데이션(밑줄처럼 보인다)을 **면 색으로** 바꾼다.
  // `!important`를 쓰는 이유: merge의 규칙이 `&dark.cm-merge-a .cm-changedText`처럼 테마(밝음/어두움)까지 끼워
  // 더 구체적이고, 그 형태는 baseTheme에서만 쓸 수 있어 여기서 같은 특이도를 만들 수 없다. 덮지 못하면 바뀐 글자에
  // 2px 그라데이션이 남아 밑줄처럼 보인다(실측).
  "&.cm-merge-a .cm-changedText, & .cm-deletedChunk .cm-deletedText": {
    background: `color-mix(in srgb, ${removed} ${text_alpha}, transparent) !important`,
    borderRadius: "2px",
  },
  "&.cm-merge-b .cm-changedText": {
    background: `color-mix(in srgb, ${added} ${text_alpha}, transparent) !important`,
    borderRadius: "2px",
  },
  "&.cm-merge-b .cm-deletedText": {
    background: `color-mix(in srgb, ${removed} ${text_alpha}, transparent)`,
  },

  // ── 변경 표시 gutter: 쪽에 맞는 색의 얇은 막대.
  "&.cm-merge-a .cm-changedLineGutter": {
    backgroundColor: `color-mix(in srgb, ${removed} ${gutter_alpha}, transparent)`,
  },
  "&.cm-merge-b .cm-changedLineGutter": {
    backgroundColor: `color-mix(in srgb, ${added} ${gutter_alpha}, transparent)`,
  },
  ".cm-changeGutter": { width: "3px" },

  // ── 접힌 동일 구간: 눌러서 펼 수 있다는 것이 보이게 한다.
  ".cm-collapsedLines": {
    color: "color-mix(in srgb, CanvasText 55%, transparent)",
    backgroundColor: "color-mix(in srgb, CanvasText 6%, transparent)",
    padding: "2px 12px",
  },

  ".cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, CanvasText 18%, transparent)",
  },
});
