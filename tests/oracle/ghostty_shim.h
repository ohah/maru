#ifndef MARU_GHOSTTY_SHIM_H
#define MARU_GHOSTTY_SHIM_H

#include <stddef.h>
#include <stdint.h>

// libghostty-vt로 input을 렌더한 뒤 cols×rows 그리드를 UTF-8 텍스트로 out에 쓴다
// (행은 '\n'으로 연결, 빈 셀은 space). 이는 maru.terminal의 dumpUtf8 및 libvterm
// 오라클과 같은 규약이라 동일 golden으로 비교할 수 있다.
// 반환: 쓴 바이트 수, 실패/버퍼 부족이면 -1.
long maru_ghostty_dump(uint16_t cols, uint16_t rows,
                       const uint8_t *input, size_t input_len,
                       uint8_t *out, size_t out_cap);

// cols0×rows0로 input을 처리한 뒤 cols1×rows1로 resize(reflow)하고 그 그리드를 덤프한다.
// reflow 동작을 Maru와 비교하기 위한 오라클 경로다. resize 후 커서 위치(cursor_x/cursor_y,
// 0-indexed)와 pending-wrap(0/1)을 out 파라미터로 함께 돌려준다(NULL이면 무시). 그리드 덤프
// 반환 규약은 maru_ghostty_dump와 같다.
long maru_ghostty_dump_resize(uint16_t cols0, uint16_t rows0,
                              uint16_t cols1, uint16_t rows1,
                              const uint8_t *input, size_t input_len,
                              uint8_t *out, size_t out_cap,
                              uint16_t *cursor_x, uint16_t *cursor_y,
                              int *pending_wrap);

#endif
