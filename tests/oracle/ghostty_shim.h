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

#endif
