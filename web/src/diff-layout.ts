//! diff 두 편집기의 **레이아웃·스크롤 계약**(제품 diff-view와 스모크 하니스가 공유).
//!
//! 왜 공유 모듈인가: 이 계약이 어긋나면 화면이 조용히 망가진다(높이 0으로 아무것도 안 보이거나, 스크롤이 안 되거나,
//! 가로 막대가 내용 맨 끝에만 생겨 못 찾는다). 제품과 게이트가 **같은 코드**를 써야 게이트 초록이 제품을 대표한다.
//!
//! **왜 각 편집기가 스스로 스크롤하나**: `@codemirror/merge`는 `.cm-mergeView & { height: auto !important }`로
//! 편집기를 내용 높이만큼 늘리고 바깥 상자가 스크롤하도록 만든다. 그러면 가로 스크롤 막대가 **문서 맨 아래**에
//! 생겨 긴 줄을 보려면 세로로 끝까지 내려가야 한다. 그래서 우리 쪽에서 높이를 되돌리고(app.css의 `!important`),
//! 세로 위치만 두 편집기 사이에서 맞춘다 — 나란한 비교가 어긋나지 않게.

import { EditorState } from "@codemirror/state";
import { EditorView, lineNumbers } from "@codemirror/view";
import type { MergeView } from "@codemirror/merge";
import { diff_theme } from "./diff-theme";

/// 양쪽 편집기 공통 확장. 줄 번호는 비교를 읽는 데 필수다(몇 번째 줄이 바뀌었는지 못 보면 diff가 아니다).
export const side_extensions = [EditorState.readOnly.of(true), lineNumbers(), diff_theme];

/// 원본 쪽도 같은 확장을 쓴다 — 색은 테마가 `cm-merge-a/b` 클래스로 스스로 가른다(diff-theme).
export const original_side_extensions = side_extensions;

/// 두 편집기의 **세로 스크롤을 서로 맞춘다**. 각자 스크롤하게 두면 같은 줄이 다른 높이에 놓여 비교가 깨진다.
/// 되돌아오는 이벤트로 무한 반복하지 않도록 반영 중에는 반대쪽 처리를 건너뛴다. 정리 함수를 돌려준다.
export function syncMergeScroll(view: MergeView): () => void {
  const a = scrollerOf(view.a);
  const b = scrollerOf(view.b);
  if (a === null || b === null) return () => {};

  let applying = false;
  const mirror = (from: HTMLElement, to: HTMLElement) => () => {
    if (applying) return;
    applying = true;
    to.scrollTop = from.scrollTop;
    // 가로는 **맞추지 않는다** — 양쪽 줄 길이가 다르므로 한쪽을 따라가면 다른 쪽이 엉뚱한 곳을 본다.
    applying = false;
  };
  const onA = mirror(a, b);
  const onB = mirror(b, a);
  a.addEventListener("scroll", onA);
  b.addEventListener("scroll", onB);
  return () => {
    a.removeEventListener("scroll", onA);
    b.removeEventListener("scroll", onB);
  };
}

function scrollerOf(view: EditorView): HTMLElement | null {
  return view.dom.querySelector<HTMLElement>(".cm-scroller");
}
