/**
 * 파일 패널 콘텐츠 영역의 React UI 루트(docs/file-panel.md §2.1).
 *
 * **여기 들어오는 것은 "문서 콘텐츠 위에 뜨는 UI"뿐이다** — 컨텍스트 메뉴, 리치 툴바, 앞으로의 다이얼로그.
 * 탭·헤더 밴드·파일 트리 같은 chrome은 계속 Zig+GPU가 그리므로 이 트리에 들어오지 않는다.
 *
 * CM6·문서모델 편집기는 DOM 마운트 라이브러리라 React 트리 안의 한 노드에 그대로 붙는다 — 편집기 자체를
 * React 컴포넌트로 다시 쓰지 않는다.
 */

import { StrictMode } from "react";
import { createRoot, type Root } from "react-dom/client";

export type ShellUiHandle = {
  destroy: () => void;
};

/** 지금은 마운트 경로만 세운다. 실제 컴포넌트(컨텍스트 메뉴 등)는 뒤 슬라이스에서 이 루트에 붙는다. */
export function mountShellUi(host: HTMLElement): ShellUiHandle {
  const root: Root = createRoot(host);
  root.render(
    <StrictMode>
      <div data-testid="shell-ui-root" className="contents" />
    </StrictMode>,
  );
  return {
    destroy: () => root.unmount(),
  };
}
