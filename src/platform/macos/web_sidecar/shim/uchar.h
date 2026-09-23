/* Zig translate-c 는 __has_include(<uchar.h>) 를 참으로 보면서 실제 파일은 못 찾는다. CEF 헤더가 쓰는 것은
 * char16_t/char32_t 뿐이라 그 둘만 채운다(웹 OSR sidecar W1b — src/platform/macos/web_sidecar/cef.zig). */
#ifndef MARU_WEB_SIDECAR_UCHAR_SHIM_H
#define MARU_WEB_SIDECAR_UCHAR_SHIM_H
#include <stdint.h>
#ifndef __cplusplus
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
#endif
#endif
