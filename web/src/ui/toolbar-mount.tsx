/**
 * React 툴바를 non-React 호출자(`rich-editor.ts`)가 쓰도록 감싸는 어댑터.
 *
 * **초기 렌더는 동기다.** 호출자는 `createRichEditor`가 돌아온 시점에 툴바가 DOM에 있다고 가정한다(shell을 그린
 * 직후 `focus()`가 이어진다). concurrent root의 기본 렌더는 다음 tick이라 그 가정이 깨져, rich 모드로 들어갈 때
 * 툴바 행 높이가 0으로 그려졌다가 한 tick 뒤 한 행 늘어나는 콘텐츠 점프가 생기고, 마운트 직후를 들여다보는 진단은
 * "아직 안 그려짐"과 "렌더 실패"를 구분할 수 없다. 그래서 `flushSync`로 첫 렌더를 동기화한다.
 *
 * 과거 이 파일은 `flushSync`를 피했다 — `react-dom`과 `react-dom/client`가 번들에서 렌더러 상태를 공유하지 못하면
 * `flushSync`가 **에러 없이 아무 일도 하지 않는다**는 우려였다. 실제 원인은 그것이 아니라 Radix 프리미티브였고
 * (toolbar.tsx 참고), 두 진입점은 번들에 react-dom 한 벌만 들어가 상태를 공유한다(빌드 산출물에서 확인). 그래도
 * 그 실패 모드는 조용하므로, 동기 렌더 뒤 호스트가 비어 있으면 진단 breadcrumb를 남겨 **다음에는 소리 나게** 한다.
 */

import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { RichToolbar, type ToolbarItem } from "./toolbar";

export type ToolbarMount = {
  /** 편집기 상태가 바뀌었을 때 활성 표시를 다시 계산한다. */
  sync: () => void;
  destroy: () => void;
};

export function mountRichToolbar(
  host: HTMLElement,
  getGroups: () => ToolbarItem[][],
): ToolbarMount {
  // React 19는 렌더 중 예외를 밖으로 던지지 않고 트리를 비운 뒤 리포트한다. 훅을 걸지 않으면 "예외 없이 빈
  // 결과"로만 보여 원인을 못 잡는다(실제로 그 상태로 오래 헤맸다).
  const root: Root = createRoot(host, {
    onUncaughtError: (error: unknown) => {
      host.ownerDocument.body.dataset.richToolbarRenderError = String(error).slice(0, 300);
    },
    onCaughtError: (error: unknown) => {
      host.ownerDocument.body.dataset.richToolbarRenderError = String(error).slice(0, 300);
    },
  } as Parameters<typeof createRoot>[1]);
  const render = () => {
    root.render(<RichToolbar groups={getGroups()} />);
  };
  flushSync(render);
  if (host.childElementCount === 0) {
    host.ownerDocument.body.dataset.richToolbarRenderError =
      "동기 렌더 뒤에도 툴바 호스트가 비어 있습니다";
  }
  return {
    // 갱신은 동기일 필요가 없다 — 활성 표시가 한 tick 늦게 반영돼도 레이아웃이 바뀌지 않는다. 편집 중 매
    // selection 변화마다 렌더를 강제 flush하면 입력 지연만 늘어난다.
    sync: render,
    destroy: () => {
      root.unmount();
    },
  };
}
