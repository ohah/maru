#include "native_cell_rect.h"
/* Plain C ABI lets Zig consume the same policy as Objective-C, without a
 * platform dependency or a second copy of the geometry algorithm. */
void maru_native_cell_rect_ffi(uint16_t kind, float cw, float cell_h,
    uint32_t divider_thickness_px, float rect[4]) {
    float left=rect[0], right=left+rect[2], top=rect[1], bottom=top+rect[3];
    maru_native_cell_edges(kind,cw,cell_h,top,divider_thickness_px,&left,&right,&top,&bottom);
    rect[0]=left; rect[1]=top; rect[2]=right-left; rect[3]=bottom-top;
}
