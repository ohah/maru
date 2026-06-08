#ifndef MARU_PLATFORM_MACOS_APP_HOST_BRIDGING_H
#define MARU_PLATFORM_MACOS_APP_HOST_BRIDGING_H

/* Swift 제품 host가 보는 Objective-C/C 표면을 한 곳에 모은다. ABI 계약 헤더와 제품 Metal
   renderer를 함께 노출하되, app_host_abi.h 자체는 Metal에 의존하지 않게 분리해 둔다(Zig
   ABI 계약 테스트의 @cImport가 Metal/QuartzCore를 끌어오지 않도록). */
#include "app_host_abi.h"
#include "maru_metal_renderer.h"

#endif
