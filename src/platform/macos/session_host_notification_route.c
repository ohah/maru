#include "session_host_notification_route.h"

#include <stdio.h>

size_t maru_session_host_notification_format_identifier(
    uint64_t hid_hi,
    uint64_t hid_lo,
    uint64_t rid_hi,
    uint64_t rid_lo,
    uint64_t eid,
    char *out,
    size_t out_cap
) {
    if (out == NULL || out_cap == 0) return 0;
    const int written = snprintf(
        out,
        out_cap,
        "maru-%016llx%016llx-%016llx%016llx-%llu",
        (unsigned long long)hid_hi,
        (unsigned long long)hid_lo,
        (unsigned long long)rid_hi,
        (unsigned long long)rid_lo,
        (unsigned long long)eid
    );
    if (written <= 0 || (size_t)written >= out_cap) {
        out[0] = '\0';
        return 0;
    }
    return (size_t)written;
}
