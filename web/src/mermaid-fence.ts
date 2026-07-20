/**
 * Worker가 넘긴 exact fenced source에서 body만 꺼낸다. CM6이 Mermaid range를 소유하지만
 * helper는 프로토콜 경계에서 raw source를 다시 신뢰할 수 없으므로, CommonMark의 두 fence
 * 문자와 closing-length 규칙만 fail-closed로 확인한다.
 */
export function mermaidFenceBody(source: string): string | null {
  const lines = source.replaceAll("\r\n", "\n").split("\n");
  if (lines.length < 3) return null;
  const opening = /^ {0,3}(`{3,}|~{3,})[ \t]*mermaid[ \t]*$/i.exec(lines[0] ?? "");
  const closing = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(lines.at(-1) ?? "");
  if (opening === null || closing === null) return null;
  const openingFence = opening[1] ?? "";
  const closingFence = closing[1] ?? "";
  if (
    openingFence.length < 3 ||
    openingFence[0] !== closingFence[0] ||
    closingFence.length < openingFence.length
  )
    return null;
  return lines.slice(1, -1).join("\n");
}
