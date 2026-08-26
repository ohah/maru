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

#endif
