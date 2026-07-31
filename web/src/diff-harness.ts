//! E0.5A 게이트용 **diff 하니스**(docs/editor-surface.md §7.4).
//!
//! 제품 WKWebView·`maru-app://`·app origin CSP 위에서 `@codemirror/merge`가 실제로 도는지 처음 확인하는 자리다.
//! 제품 번들에는 들어가지 않는다 — 전용 asset root로만 빌드해 스모크가 로드한다(scripts/build-editor-smoke.ts).
//!
//! **두 형태를 다 태운다.** 나란히 보기(`MergeView`)는 렌더·chunk 마커를, 통합 보기(`unifiedMergeView`)는 accept/reject
//! 상호작용을 담당한다 — `acceptChunk`/`rejectChunk`는 통합 뷰 전용이라 한 형태로는 §7.4 항목을 덮지 못한다.
//!
//! **하니스는 UI가 아니라 계측이다.** 화면은 커밋된 fixture 하나이고 스모크가 읽을 값(`probe()`)이 산출물이다. 그래서
//! 마운트·조작·관측을 순수 함수로 노출해 jsdom에서 같은 코드를 테스트한다(§7.3 oracle 2·3).

import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import {
  MergeView,
  getChunks,
  unifiedMergeView,
  acceptChunk,
  rejectChunk,
} from "@codemirror/merge";

/// 저장소에 커밋된 synthetic fixture. 실제 파일 내용을 쓰지 않는다(§7.4 — DOM artifact·screenshot에 source text 금지).
/// 변경 종류를 하나씩 담는다: 수정(`beta`→`BETA`), 삭제(`delta`), 추가(`eta`·`theta`).
export const fixture = {
  original: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"].join("\n"),
  modified: ["alpha", "BETA", "gamma", "epsilon", "zeta", "eta", "theta"].join("\n"),
};

export type SideProbe = {
  /** chunk 개수 — 0이면 마운트만 되고 비교가 안 된 상태다(둘을 구분해야 "돌았다"고 말할 수 있다). */
  chunk_count: number;
  /** 변경 강조가 실제 DOM 요소로 나왔는가. 클래스명 몇 개를 세되 존재 여부만 판정에 쓴다. */
  changed_elements: number;
  /** gutter 마커가 그려졌는가(§7.4 "diff decoration, marker"). */
  gutter_markers: number;
  /** non-zero layout으로 실제 표시되는가(§7.4 첫 항목). jsdom은 0이라 제품 WKWebView에서만 참이 된다. */
  layout: { width: number; height: number };
};

export type DiffProbe = {
  split: SideProbe & { text: { a: string; b: string } };
  unified: SideProbe & { text: string };
  /** 문서 전체 `<style>` 수와 소유 문서 일치 여부 — MergeView 스타일이 app origin 밖으로 새는지 본다(§7.2 불변식 1). */
  style_elements: number;
  styles_all_in_this_document: boolean;
  /** 격리 렌더 문서(iframe)가 이 하니스에 없다는 확인 — 스타일이 샐 대상 자체가 없어야 판정이 성립한다. */
  iframe_count: number;
};

export type Harness = {
  split: MergeView;
  unified: EditorView;
  probe: () => DiffProbe;
  /** 통합 뷰 첫 chunk를 받아들인다 → 그 구간이 수정본으로 확정되고 강조가 사라진다. */
  acceptFirstChunk: () => boolean;
  /** 통합 뷰 첫 chunk를 되돌린다 → 그 구간이 원본 내용으로 돌아간다. */
  rejectFirstChunk: () => boolean;
  destroy: () => void;
};

/// fixture로 두 형태를 `parent` 아래에 마운트한다. 하니스는 문서당 하나만 둔다(스모크가 개수를 센다).
export function mount(parent: HTMLElement, doc = fixture): Harness {
  const splitHost = parent.ownerDocument.createElement("div");
  splitHost.id = "diff-split";
  const unifiedHost = parent.ownerDocument.createElement("div");
  unifiedHost.id = "diff-unified";
  parent.append(splitHost, unifiedHost);

  const split = new MergeView({
    a: { doc: doc.original, extensions: [EditorState.readOnly.of(true)] },
    b: { doc: doc.modified, extensions: [EditorState.readOnly.of(true)] },
    parent: splitHost,
    // 나란히 보기 — 목업의 diff 본문 형태이고 양쪽 layout을 각각 잴 수 있다.
    orientation: "a-b",
    gutter: true,
  });

  const unified = new EditorView({
    doc: doc.modified,
    parent: unifiedHost,
    extensions: [unifiedMergeView({ original: doc.original, gutter: true })],
  });

  return {
    split,
    unified,
    probe: () => probe(split, unified, parent),
    acceptFirstChunk: () => withFirstChunk(unified, acceptChunk),
    rejectFirstChunk: () => withFirstChunk(unified, rejectChunk),
    destroy: () => {
      split.destroy();
      unified.destroy();
      splitHost.remove();
      unifiedHost.remove();
    },
  };
}

/// accept/rejectChunk는 인덱스가 아니라 **문서 위치**로 chunk를 고른다 — 첫 chunk의 시작 위치를 넘긴다.
function withFirstChunk(
  view: EditorView,
  apply: (view: EditorView, pos?: number) => boolean,
): boolean {
  const chunks = getChunks(view.state);
  if (chunks === null || chunks.chunks.length === 0) return false;
  return apply(view, chunks.chunks[0]!.fromB);
}

function sideProbe(view: EditorView): SideProbe {
  const chunks = getChunks(view.state);
  return {
    chunk_count: chunks === null ? 0 : chunks.chunks.length,
    changed_elements: view.dom.querySelectorAll(
      ".cm-changedLine, .cm-changedText, .cm-deletedChunk",
    ).length,
    gutter_markers: view.dom.querySelectorAll(".cm-changedLineGutter").length,
    layout: { width: view.dom.clientWidth, height: view.dom.clientHeight },
  };
}

export function probe(split: MergeView, unified: EditorView, parent: HTMLElement): DiffProbe {
  const doc = parent.ownerDocument;
  const styles = Array.from(doc.querySelectorAll("style"));
  const a = sideProbe(split.a);
  const b = sideProbe(split.b);
  return {
    split: {
      // 나란히 보기의 chunk는 양쪽이 같은 집합을 본다 — 큰 쪽을 싣되 마커·layout은 각각의 합·b 기준으로 남긴다.
      chunk_count: Math.max(a.chunk_count, b.chunk_count),
      changed_elements: a.changed_elements + b.changed_elements,
      gutter_markers: a.gutter_markers + b.gutter_markers,
      layout: b.layout,
      text: { a: split.a.state.doc.toString(), b: split.b.state.doc.toString() },
    },
    unified: { ...sideProbe(unified), text: unified.state.doc.toString() },
    style_elements: styles.length,
    // style-mod는 문서 루트에 `<style>`을 넣는다. 다른 문서(격리 렌더 iframe)로 새면 여기서 걸린다.
    styles_all_in_this_document: styles.every((el) => el.ownerDocument === doc),
    iframe_count: doc.querySelectorAll("iframe").length,
  };
}
