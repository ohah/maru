import type { KeyInput } from "../types";

const NAMED: Record<string, KeyInput["key"]> = {
  Enter: "enter",
  Escape: "escape",
  Tab: "tab",
  Backspace: "backspace",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  Insert: "insert",
  Delete: "delete",
  PageUp: "pageUp",
  PageDown: "pageDown",
};

/**
 * 브라우저 `KeyboardEvent`를 코어의 `KeyInput`으로 옮긴다.
 *
 * **완전성을 약속하지 않는다.** `base_codepoint`·`keypad`는 네이티브에서 플랫폼이 채우는
 * 값이고(`terminal/input.zig`), 브라우저는 레이아웃·IME에 따라 다르게 준다. 여기서는 합리적인
 * 기본 매핑만 하고, 더 정확한 매핑이 필요하면 소비자가 직접 `Terminal.key()`를 부른다.
 */
export function toKeyInput(ev: KeyboardEvent): KeyInput | null {
  const mods = {
    shift: ev.shiftKey,
    ctrl: ev.ctrlKey,
    alt: ev.altKey,
    meta: ev.metaKey,
  };
  const named = NAMED[ev.key];
  if (named) return { key: named, ...mods };

  const fn = /^F([1-9]|1[0-2])$/.exec(ev.key);
  if (fn) return { key: "f", fn: Number(fn[1]), ...mods };

  if ([...ev.key].length === 1) {
    // ⌘+문자는 브라우저에 양보한다(복사·붙여넣기·새 탭).
    if (ev.metaKey) return null;
    return { key: "char", codepoint: ev.key.codePointAt(0)!, ...mods };
  }
  return null;
}
