#ifndef MARU_SESSION_HOST_NOTIFICATION_ROUTE_H
#define MARU_SESSION_HOST_NOTIFICATION_ROUTE_H

#include <stddef.h>
#include <stdint.h>

enum { MARU_SESSION_HOST_NOTIFICATION_IDENTIFIER_CAP = 92 };

/* Canonical Notification Center request identifier for one host-backed event.
   Returns the byte length excluding NUL, or 0 when the destination is too small/invalid. */
size_t maru_session_host_notification_format_identifier(
    uint64_t hid_hi,
    uint64_t hid_lo,
    uint64_t rid_hi,
    uint64_t rid_lo,
    uint64_t eid,
    char *out,
    size_t out_cap
);

/* Strict decoder for persisted Notification Center userInfo scalars plus request identifier.
   Hex IDs must be exactly 32 lowercase ASCII digits and nonzero; event ID is canonical nonzero
   decimal u64. The identifier must equal the shared formatter output. Returns 1 on success. */
int maru_session_host_notification_parse_route(
    const char *hid,
    size_t hid_len,
    const char *rid,
    size_t rid_len,
    const char *eid,
    size_t eid_len,
    const char *identifier,
    size_t identifier_len,
    uint64_t *hid_hi_out,
    uint64_t *hid_lo_out,
    uint64_t *rid_hi_out,
    uint64_t *rid_lo_out,
    uint64_t *eid_out
);

#endif
