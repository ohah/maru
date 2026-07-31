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

import { EditorView } from "@codemirror/view";
import { original_side_extensions, side_extensions, syncMergeScroll } from "./diff-layout";
import {
  MergeView,
  getChunks,
  unifiedMergeView,
  acceptChunk,
  rejectChunk,
} from "@codemirror/merge";

/// 저장소에 커밋된 synthetic fixture. 실제 파일 내용을 쓰지 않는다(§7.4 — DOM artifact·screenshot에 source text 금지).
/// 변경 종류를 하나씩 담는다: 수정(`beta`→`BETA`), 삭제(`delta`), 추가(`eta`·`theta`).
/// 변경 종류를 하나씩 담고, **뷰 높이를 넘길 만큼 길다** — 넘치지 않으면 "스크롤이 안 된다"와 "스크롤할 게
/// 없다"가 구분되지 않아 스크롤 계약을 잴 수 없다.
const filler = Array.from({ length: 60 }, (_, i) => `line ${i + 1}`);
/// **가로로도 넘치는 줄.** 없으면 "가로 스크롤이 안 된다"와 "가로로 넘칠 게 없다"가 구분되지 않는다.
const long_line = `const wide = "${"x".repeat(400)}";`;
export const fixture = {
  original: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", long_line, ...filler].join("\n"),
  modified: [
    "alpha",
    "BETA",
    "gamma",
    "epsilon",
    "zeta",
    "eta",
    "theta",
    long_line,
    ...filler,
  ].join("\n"),
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
  /** 스크롤 상자의 보이는 크기와 전체 크기. `scroll_* > client_*`면 실제로 스크롤이 가능한 상태다. */
  scroll: {
    client_height: number;
    scroll_height: number;
    client_width?: number;
    scroll_width?: number;
  };
  /** 줄 번호 gutter 요소 수(0이면 줄 번호가 없다). */
  line_number_elements: number;
  /** 높이 사슬 진단(편집기 → 조상): `클래스:높이:배치:계산된높이`. 레이아웃이 깨지면 어디서 끊겼는지 여기서 본다. */
  chain: string[];
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

  // 제품 diff-view와 **같은 모듈**을 쓴다(레이아웃 계약이 갈리면 게이트 초록이 제품을 대표하지 못한다).
  const side = side_extensions;
  const split = new MergeView({
    a: { doc: doc.original, extensions: original_side_extensions },
    b: { doc: doc.modified, extensions: side },
    parent: splitHost,
    // 나란히 보기 — 목업의 diff 본문 형태이고 양쪽 layout을 각각 잴 수 있다.
    orientation: "a-b",
    gutter: true,
  });

  const stop_sync = syncMergeScroll(split);

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
      stop_sync();
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
    // 스크롤은 편집기가 아니라 바깥 상자가 한다 — 그 값은 probe()가 host를 직접 재서 채운다.
    scroll: { client_height: 0, scroll_height: 0 },
    line_number_elements: view.dom.querySelectorAll(".cm-lineNumbers .cm-gutterElement").length,
    // 높이 사슬 진단: 어느 단계에서 박스가 안 정해지는지 본다(하나라도 내용 높이면 그 위가 끊긴 것이다).
    chain: chainHeights(view.dom),
  };
}

/// 편집기 자체 스크롤러의 보이는 높이·전체 높이·가로 넘침. 각 편집기가 스스로 스크롤하는 구조라 여기를 잰다.
function scrollerMetrics(view: EditorView): {
  client_height: number;
  scroll_height: number;
  client_width: number;
  scroll_width: number;
} {
  const el = view.dom.querySelector<HTMLElement>(".cm-scroller");
  return {
    client_height: el?.clientHeight ?? 0,
    scroll_height: el?.scrollHeight ?? 0,
    client_width: el?.clientWidth ?? 0,
    scroll_width: el?.scrollWidth ?? 0,
  };
}

/// 편집기에서 위로 올라가며 각 조상의 높이·배치를 기록한다. 계산된 스타일까지 봐야 "규칙이 안 맞은 것"과
/// "규칙은 맞았는데 값이 그런 것"을 구분할 수 있다.
function chainHeights(from: HTMLElement): string[] {
  const out: string[] = [];
  let node: HTMLElement | null = from;
  for (let depth = 0; depth < 6 && node !== null; depth += 1) {
    const cls = (node.className || node.tagName).toString().split(" ")[0] ?? "?";
    const style = node.ownerDocument.defaultView?.getComputedStyle(node);
    out.push(`${cls}:${node.clientHeight}:${style?.position ?? "?"}:${style?.height ?? "?"}`);
    node = node.parentElement;
  }
  return out;
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
      scroll: scrollerMetrics(split.b),
      line_number_elements: b.line_number_elements,
      chain: b.chain,
      text: { a: split.a.state.doc.toString(), b: split.b.state.doc.toString() },
    },
    unified: {
      ...sideProbe(unified),
      // 통합 뷰도 편집기 자체가 스크롤한다(제품 규칙과 같은 구조).
      scroll: scrollerMetrics(unified),
      text: unified.state.doc.toString(),
    },
    style_elements: styles.length,
    // style-mod는 문서 루트에 `<style>`을 넣는다. 다른 문서(격리 렌더 iframe)로 새면 여기서 걸린다.
    styles_all_in_this_document: styles.every((el) => el.ownerDocument === doc),
    iframe_count: doc.querySelectorAll("iframe").length,
  };
}
