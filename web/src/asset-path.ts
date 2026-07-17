// Markdown 상대 asset은 파일 패널 브리지의 핀 디렉터리 capability로만 읽는다. URL parser가 외부 URL을
// 관대하게 보정하지 않도록 문자열 단계에서 명시적으로 거부하고, percent decode 뒤 `..`를 다시 검사한다.
export function normalizeAssetReference(raw: string): string | null {
  const withoutSuffix = raw.split(/[?#]/, 1)[0];
  if (withoutSuffix.length === 0 || withoutSuffix.startsWith("/") || withoutSuffix.includes("\\")) {
    return null;
  }
  if (/^[a-z][a-z0-9+.-]*:/i.test(withoutSuffix)) return null;

  let decoded: string;
  try {
    decoded = decodeURIComponent(withoutSuffix);
  } catch {
    return null;
  }
  const hasControl = Array.from(decoded).some((char) => {
    const code = char.codePointAt(0) ?? 0;
    return code < 0x20 || code === 0x7f;
  });
  if (decoded.startsWith("/") || decoded.includes("\\") || hasControl) {
    return null;
  }

  const segments: string[] = [];
  for (const segment of decoded.split("/")) {
    if (segment.length === 0 || segment === ".") continue;
    if (segment === "..") return null;
    segments.push(segment);
  }
  return segments.length === 0 ? null : segments.join("/");
}
