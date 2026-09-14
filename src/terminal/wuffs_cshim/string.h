// wuffs 셰임 — README.md 참조. wuffs 가 실제로 부르는 것만 적는다.
// 이 여섯은 Zig 의 compiler-rt 가 모든 타깃에서 제공한다(wasm 포함).
#ifndef MARU_WUFFS_CSHIM_STRING_H
#define MARU_WUFFS_CSHIM_STRING_H
#include <stddef.h>
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
int strcmp(const char *a, const char *b);
size_t strlen(const char *s);
#endif
