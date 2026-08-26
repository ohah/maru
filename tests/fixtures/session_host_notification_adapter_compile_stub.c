#include "session_host_notification_adapter.h"

uint32_t maru_session_host_notification_submit(
    uint64_t hid_hi,
    uint64_t hid_lo,
    uint64_t rid_hi,
    uint64_t rid_lo,
    uint64_t eid,
    const uint8_t *title,
    size_t title_len,
    const uint8_t *body,
    size_t body_len,
    const uint8_t *label,
    size_t label_len
) {
    (void)hid_hi;
    (void)hid_lo;
    (void)rid_hi;
    (void)rid_lo;
    (void)eid;
    (void)title;
    (void)title_len;
    (void)body;
    (void)body_len;
    (void)label;
    (void)label_len;
    return MARU_NOTIFICATION_BUNDLE_MISSING;
}

void maru_session_host_notification_expire(
    uint64_t hid_hi,
    uint64_t hid_lo,
    uint64_t rid_hi,
    uint64_t rid_lo,
    uint64_t eid
) {
    (void)hid_hi;
    (void)hid_lo;
    (void)rid_hi;
    (void)rid_lo;
    (void)eid;
}
