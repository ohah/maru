/**
 * 파일 패널 콘텐츠 영역의 React UI 루트(docs/file-panel.md §2.1).
 *
 * **여기 들어오는 것은 문서와 함께 사는 UI뿐이다** — 리치 편집 툴바, 앞으로의 인라인 위젯.
 * 탭·헤더 밴드·파일 트리 같은 chrome과 **컨텍스트 메뉴**는 Zig+GPU가 그리므로 이 트리에 들어오지 않는다
 * (§2.1a 부분 정정 — 메뉴는 웹뷰 밖으로 나가야 하고 이미 있는 메뉴들과 같은 생김새여야 한다).
 *
 * **루트는 편집기당 하나다.** UI를 각자 마운트하면 React 트리가 갈려 뒤에 붙일 것마다 루트가 하나씩 늘어난다.
 * 하나로 두면 그 전부가 같은 트리 안에서 만난다.
 *
 * CM6·문서모델 편집기는 DOM 마운트 라이브러리라 이 트리 **밖의** 형제 노드에 그대로 붙는다 — 편집기 자체를
 * React 컴포넌트로 다시 쓰지 않는다.
 */

import { StrictMode } from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { RichToolbar, type ToolbarItem } from "./ui/toolbar";

export type ShellUiHandle = {
  /** 편집기 상태가 바뀌었을 때 툴바 활성 표시를 다시 계산한다. */
  sync: () => void;
  destroy: () => void;
};

export type ShellUiProps = {
  groups: ToolbarItem[][];
};

function ShellUi({ groups }: ShellUiProps): React.JSX.Element {
  return <RichToolbar groups={groups} />;
}

export function mountShellUi(host: HTMLElement, getGroups: () => ToolbarItem[][]): ShellUiHandle {
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
    root.render(
      <StrictMode>
        <ShellUi groups={getGroups()} />
      </StrictMode>,
    );
  };

  // **초기 렌더는 동기다.** 호출자는 `createRichEditor`가 돌아온 시점에 툴바가 DOM에 있다고 가정한다(shell을
  // 그린 직후 `focus()`가 이어진다). concurrent root의 기본 렌더는 다음 tick이라 그 가정이 깨져, 리치 모드로
  // 들어갈 때 툴바 행 높이가 0으로 그려졌다가 한 tick 뒤 한 행 늘어나는 콘텐츠 점프가 생긴다.
  flushSync(render);
  if (host.childElementCount === 0) {
    // 이 실패 모드는 조용하다(예외 없이 빈 결과) — 사실을 DOM에 남겨 native 진단이 읽게 한다.
    host.ownerDocument.body.dataset.richToolbarRenderError =
      "동기 렌더 뒤에도 UI 호스트가 비어 있습니다";
  }

  return {
    // 갱신은 동기일 필요가 없다 — 활성 표시가 한 tick 늦게 반영돼도 레이아웃이 바뀌지 않는다. 편집 중 매
    // selection 변화마다 렌더를 강제 flush하면 입력 지연만 늘어난다.
    sync: render,
    destroy: () => root.unmount(),
  };
}
