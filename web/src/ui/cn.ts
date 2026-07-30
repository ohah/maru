/**
 * Tailwind 클래스 병합 유틸. 뒤에 온 유틸리티가 앞의 같은 축 유틸리티를 이기게 한다
 * (`px-2` + `px-4` → `px-4`) — 조건부 클래스를 섞을 때 CSS 우선순위가 아니라 순서로 판정되도록.
 */

import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
