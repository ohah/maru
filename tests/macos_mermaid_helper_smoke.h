#ifndef MARU_TESTS_MACOS_MERMAID_HELPER_SMOKE_H
#define MARU_TESTS_MACOS_MERMAID_HELPER_SMOKE_H

#include "../src/platform/macos/app_host_abi.h"

/* Smoke 전용 ABI variant에만 존재하며 제품 header/library에는 노출하지 않는다. */
void maru_macos_mermaid_test_reset(void);

#endif
