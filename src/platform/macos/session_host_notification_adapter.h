#ifndef MARU_SESSION_HOST_NOTIFICATION_ADAPTER_H
#define MARU_SESSION_HOST_NOTIFICATION_ADAPTER_H

#include <stddef.h>
#include <stdint.h>

enum {
    MARU_NOTIFICATION_ACCEPTED = 0,
    MARU_NOTIFICATION_DENIED = 1,
    MARU_NOTIFICATION_BUNDLE_MISSING = 2,
    MARU_NOTIFICATION_ENTITLEMENT_MISSING = 3,
    MARU_NOTIFICATION_TRANSIENT = 4,
    MARU_NOTIFICATION_PENDING = 5,
};

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
);

void maru_session_host_notification_expire(
    uint64_t hid_hi,
    uint64_t hid_lo,
    uint64_t rid_hi,
    uint64_t rid_lo,
    uint64_t eid
);

#endif
