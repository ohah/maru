/**
 * 리치 편집기 툴바의 표현 계층(docs/file-panel.md §2.1).
 *
 * **Radix 프리미티브를 쓰지 않는다.** `@radix-ui/react-toolbar`는 제품(WKWebView)에서 예외도 남기지 않고
 * 빈 결과를 렌더했다 — 같은 번들의 React는 정상이었고(독립 root probe로 확인) 이 컴포넌트만 비었다.
 * 로빙 포커스 하나를 위해 원인 불명의 무동작을 안고 갈 이유가 없어, 필요한 접근성 속성(`role`,
 * `aria-pressed`)은 직접 단다. shadcn은 "복사해서 소유"하는 방식이라 이 선택과 어긋나지 않는다.
 *
 * **편집기 명령을 알지 않는다.** 무엇을 실행할지는 호출자가 `items`로 넘기고 이 컴포넌트는 그리기만 한다 —
 * 문서모델 API가 바뀌어도 이 파일은 그대로다.
 */

import { cn } from "./cn";

export type ToolbarItem = {
  id: string;
  label: string;
  title: string;
  /** 토글 버튼일 때만 준다. **`undefined`는 "꺼진 토글"이 아니라 "토글이 아님"** — 구분선 삽입처럼 상태가 없는
   *  명령에 `aria-pressed="false"`를 달면 보조기술이 토글로 읽어 주고, 눌러도 눌림 상태가 안 바뀌니 사용자는
   *  실패로 여겨 같은 명령을 반복 실행한다. */
  active?: boolean;
  run: () => void;
};

export type RichToolbarProps = {
  /** 그룹 사이에는 구분선이 들어간다. */
  groups: ToolbarItem[][];
};

export function RichToolbar({ groups }: RichToolbarProps): React.JSX.Element {
  return (
    <div
      role="toolbar"
      aria-orientation="horizontal"
      aria-label="리치 편집 서식"
      className="border-border bg-muted flex flex-wrap items-center gap-0.5 border-b px-1.5 py-1"
    >
      {groups.map((group, index) => (
        <div key={group[0]?.id ?? index} className="contents">
          {index > 0 ? <span aria-hidden="true" className="bg-border mx-1 h-4 w-px" /> : null}
          {group.map((item) => (
            <button
              key={item.id}
              type="button"
              // 눌렀을 때 편집기 selection을 빼앗으면 명령이 엉뚱한 위치에 걸린다.
              onMouseDown={(event) => event.preventDefault()}
              onClick={item.run}
              title={item.title}
              aria-label={item.title}
              // 테스트·스모크가 잡는 안정 훅. Tailwind 클래스는 스타일이라 선택자로 쓰면 디자인을 바꿀 때마다 깨진다.
              data-toolbar-button={item.id}
              aria-pressed={item.active}
              data-active={item.active === undefined ? undefined : item.active ? "true" : "false"}
              className={cn(
                "min-w-7 rounded-sm border border-transparent px-1.5 py-0.5 font-editor text-[0.8125rem] leading-tight",
                // preflight를 빼서 UA 기본 `background: ButtonFace`가 그대로 남는다(app.css 첫 주석 참고).
                // 명시하지 않으면 버튼이 회색 칩으로 그려지고, 라이트 모드에서는 그 회색이 활성 하이라이트보다
                // 진해 **활성 표시가 반전돼 보인다**(빌드된 CSS로 WebKit에서 측정).
                "bg-transparent text-foreground cursor-pointer transition-colors",
                "hover:bg-accent focus-visible:ring-ring focus-visible:ring-2 focus-visible:outline-none",
                item.active && "border-accent-selected-border bg-accent-selected text-foreground",
              )}
            >
              {item.label}
            </button>
          ))}
        </div>
      ))}
    </div>
  );
}
