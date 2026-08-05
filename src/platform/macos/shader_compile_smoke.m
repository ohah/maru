/* 제품 Metal 셰이더 4종이 실제로 컴파일되는지만 확인하는 최소 스모크.
 *
 * 왜 필요한가: 제품 renderer는 셰이더를 **런타임에** 컴파일한다(`newLibraryWithSource:`). 그래서 MSL
 * 문법이 깨져도 `zig build`도, 단위 테스트도, 기존 Metal 계약 테스트(실제 GPU를 만들지 않는다)도 전부
 * 통과하고, 앱을 실제로 띄워야만 드러난다. 셰이더를 고치는 변경에서 그 사각지대는 곧 "CI 초록인데 화면이
 * 비어 있음"이다.
 *
 * 이 스모크는 GPU device를 만들고 같은 소스를 같은 API로 컴파일해 그 갭만 닫는다. 렌더 결과·픽셀·성능은
 * 보지 않는다(그건 chrome lab / archive 스모크의 몫이다). 그래서 CI의 macOS job에 얹어도 수 초다.
 */

#import <Metal/Metal.h>
#import "maru_metal_shader.h"

#include <stdio.h>

static int maru_compile_one(id<MTLDevice> device, const char *name, NSString *source) {
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) {
        const char *reason = error != nil ? error.localizedDescription.UTF8String : "unknown";
        fprintf(stderr, "shader_compile_smoke: %s FAILED: %s\n", name, reason);
        return 1;
    }
    /* 컴파일만으로는 함수 이름 오타를 못 잡는다. 제품이 실제로 찾는 두 진입점이 존재하는지까지 본다. */
    char vertex_name[128];
    char fragment_name[128];
    snprintf(vertex_name, sizeof(vertex_name), "maru_%s_vertex", name);
    snprintf(fragment_name, sizeof(fragment_name), "maru_%s_fragment", name);
    id<MTLFunction> vertex_fn = [library newFunctionWithName:[NSString stringWithUTF8String:vertex_name]];
    id<MTLFunction> fragment_fn = [library newFunctionWithName:[NSString stringWithUTF8String:fragment_name]];
    if (vertex_fn == nil || fragment_fn == nil) {
        fprintf(stderr, "shader_compile_smoke: %s MISSING ENTRY: vertex=%d fragment=%d\n", name, vertex_fn != nil, fragment_fn != nil);
        return 1;
    }
    printf("shader_compile_smoke: %s ok\n", name);
    return 0;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            /* CI 러너에 GPU가 없으면 실패가 아니라 skip이다 — 이 스모크의 목적은 셰이더 문법 회귀를 잡는
             * 것이지 러너 하드웨어를 요구하는 게 아니다. 다만 조용히 통과하지 않도록 표식을 남긴다. */
            printf("shader_compile_smoke=skipped_no_device\n");
            return 0;
        }
        int failures = 0;
        failures += maru_compile_one(device, "cell", MARU_METAL_CELL_SHADER_SOURCE);
        failures += maru_compile_one(device, "quad", MARU_METAL_QUAD_SHADER_SOURCE);
        failures += maru_compile_one(device, "shadow", MARU_METAL_SHADOW_SHADER_SOURCE);
        failures += maru_compile_one(device, "image", MARU_METAL_IMAGE_SHADER_SOURCE);
        if (failures != 0) {
            fprintf(stderr, "shader_compile_smoke=failed count=%d\n", failures);
            return 1;
        }
        printf("shader_compile_smoke=ok\n");
        return 0;
    }
}
