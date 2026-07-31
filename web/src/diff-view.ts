//! diff 파일 Term의 **본문 화면**(E1, docs/editor-surface.md §3·§6).
//!
//! 도크 소스 컨트롤 목록에서 행을 누르면 열리는 화면이다. `maru.diff.open`이 준 두 쪽을 `@codemirror/merge`
//! MergeView로 나란히 보여 준다 — 그 조합이 제품 WebKit에서 도는 것은 E0.5A 게이트가 확인했다(§7.4).
//!
//! **읽기 전용이다.** v1은 리뷰만 한다. 편집·스테이지는 write capability라 이 화면에 손잡이를 두지 않는다(§10.14 —
//! 누를 수 없는 버튼을 띄우는 것보다 없는 편이 정직하다).
//!
//! 상태를 넷으로 가른다: 읽는 중 · 보여 줄 수 없음(이유와 함께) · 변경 없음 · 비교. 네이티브가 그 넷을 그대로
//! 내려주므로(§6 typed 결과) 화면은 판단하지 않고 말하기만 한다.

import { EditorState } from "@codemirror/state";
import { MergeView } from "@codemirror/merge";
import { requestFileBridge } from "./viewer";

/// 네이티브가 아직 읽는 중일 때 다시 묻는 간격과 한도. git 읽기는 보통 수십 ms라 첫 재시도에서 끝나지만,
/// 큰 저장소를 위해 여유를 둔다. **무한 재시도는 하지 않는다** — 끝나지 않으면 그 사실을 화면에 말한다.
export const retry_interval_ms = 120;
export const retry_limit = 50;

export type DiffPayload =
  | { kind: "ready"; original: string; modified: string; truncated_lines: boolean }
  | { kind: "pending" }
  | { kind: "rejected"; reason: string };

/// 브리지 응답(JSON-RPC result)을 화면이 쓸 형태로 좁힌다. 모르는 모양은 거절로 접는다 —
/// 빈 문서를 정상 결과로 삼으면 "변경 없음"을 보여 주게 된다.
export function parseDiffResult(value: unknown): DiffPayload {
  if (typeof value !== "object" || value === null) return { kind: "rejected", reason: "invalid" };
  const record = value as Record<string, unknown>;
  if (record.pending === true) return { kind: "pending" };
  if (typeof record.rejected === "string") return { kind: "rejected", reason: record.rejected };
  if (typeof record.original === "string" && typeof record.modified === "string") {
    return {
      kind: "ready",
      original: record.original,
      modified: record.modified,
      truncated_lines: record.truncated_lines === true,
    };
  }
  return { kind: "rejected", reason: "invalid" };
}

/// 거절 이유를 사용자 문장으로. 모르는 이유는 그대로 노출하지 않고 일반 문장으로 접는다(내부 값 노출 금지).
export function rejectionText(reason: string): string {
  switch (reason) {
    case "too_large":
      return "파일이 너무 커서 비교를 표시하지 않습니다";
    case "binary":
      return "바이너리 파일이라 텍스트 비교가 없습니다";
    default:
      return "비교를 표시할 수 없습니다";
  }
}

export type DiffScreen = {
  render: (payload: DiffPayload) => void;
  destroy: () => void;
};

/// 화면 하나를 만든다. `host` 아래에 상태 문구와 MergeView를 번갈아 둔다(둘이 동시에 보이지 않는다).
export function createDiffScreen(host: HTMLElement): DiffScreen {
  const doc = host.ownerDocument;
  const notice = doc.createElement("p");
  notice.className = "diff-notice";
  notice.setAttribute("role", "status");
  const mount = doc.createElement("div");
  mount.className = "diff-merge";
  host.append(notice, mount);

  let view: MergeView | null = null;
  const clearView = () => {
    view?.destroy();
    view = null;
    mount.replaceChildren();
  };

  return {
    render: (payload) => {
      switch (payload.kind) {
        case "pending":
          clearView();
          notice.textContent = "비교를 읽는 중…";
          notice.hidden = false;
          return;
        case "rejected":
          clearView();
          notice.textContent = rejectionText(payload.reason);
          notice.hidden = false;
          return;
        case "ready": {
          if (payload.original === payload.modified) {
            // 같은 내용을 MergeView로 그리면 빈 화면처럼 보인다 — 그 사실을 말한다.
            clearView();
            notice.textContent = "이 파일에는 변경이 없습니다";
            notice.hidden = false;
            return;
          }
          clearView();
          // 잘렸으면 숨기지 않고 함께 보여 준다(조용히 일부만 보여 주지 않는다 — §6).
          notice.textContent = payload.truncated_lines ? "앞부분만 표시합니다" : "";
          notice.hidden = !payload.truncated_lines;
          view = new MergeView({
            a: { doc: payload.original, extensions: [EditorState.readOnly.of(true)] },
            b: { doc: payload.modified, extensions: [EditorState.readOnly.of(true)] },
            parent: mount,
            orientation: "a-b",
            gutter: true,
          });
          return;
        }
      }
    },
    destroy: () => {
      clearView();
      notice.remove();
      mount.remove();
    },
  };
}

/// 네이티브에 본문을 묻고, 아직이면 정해진 횟수만큼 다시 묻는다. 화면 갱신은 매 응답마다 한다 —
/// 사용자가 "읽는 중"을 보고 있다가 결과로 바뀐다.
export async function loadDiff(
  document: Document,
  screen: DiffScreen,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms)),
  // 브리지 호출을 인자로 받는 이유: 재시도·상태 전환 **정책**을 DOM mailbox 왕복 없이 검증하기 위해서다.
  // 제품 경로에서는 기본값(실제 브리지)이 그대로 쓰인다.
  fetchDiff: (doc: Document) => Promise<unknown> = (doc) => requestFileBridge(doc, "diffOpen"),
): Promise<DiffPayload> {
  for (let attempt = 0; attempt <= retry_limit; attempt += 1) {
    let payload: DiffPayload;
    try {
      payload = parseDiffResult(await fetchDiff(document));
    } catch {
      // 브리지 자체가 실패했다(권한 없음·surface 사라짐). 이유를 지어내지 않는다.
      payload = { kind: "rejected", reason: "invalid" };
    }
    screen.render(payload);
    if (payload.kind !== "pending") return payload;
    if (attempt < retry_limit) await sleep(retry_interval_ms);
  }
  const timed_out: DiffPayload = { kind: "rejected", reason: "invalid" };
  screen.render(timed_out);
  return timed_out;
}

/// `?kind=diff` shell의 진입점.
export function bootDiff(document: Document): void {
  const host = document.querySelector<HTMLElement>("#editor") ?? document.body;
  host.hidden = false;
  const screen = createDiffScreen(host);
  screen.render({ kind: "pending" });
  void loadDiff(document, screen);
}
