#include "session_host_notification_route.h"

#include <stdio.h>
#include <string.h>

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

static int parse_hex64(const char *text, uint64_t *out) {
    uint64_t value = 0;
    for (size_t i = 0; i < 16; ++i) {
        const unsigned char byte = (unsigned char)text[i];
        uint64_t nibble;
        if (byte >= '0' && byte <= '9') nibble = (uint64_t)(byte - '0');
        else if (byte >= 'a' && byte <= 'f') nibble = (uint64_t)(byte - 'a' + 10);
        else return 0;
        value = (value << 4) | nibble;
    }
    *out = value;
    return 1;
}

static int parse_decimal64(const char *text, size_t len, uint64_t *out) {
    if (len == 0 || (len > 1 && text[0] == '0')) return 0;
    uint64_t value = 0;
    for (size_t i = 0; i < len; ++i) {
        const unsigned char byte = (unsigned char)text[i];
        if (byte < '0' || byte > '9') return 0;
        const uint64_t digit = (uint64_t)(byte - '0');
        if (value > (UINT64_MAX - digit) / 10) return 0;
        value = value * 10 + digit;
    }
    if (value == 0) return 0;
    *out = value;
    return 1;
}

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
) {
    if (hid == NULL || rid == NULL || eid == NULL || identifier == NULL ||
        hid_hi_out == NULL || hid_lo_out == NULL || rid_hi_out == NULL ||
        rid_lo_out == NULL || eid_out == NULL || hid_len != 32 || rid_len != 32) return 0;
    uint64_t hid_hi, hid_lo, rid_hi, rid_lo, event_id;
    if (!parse_hex64(hid, &hid_hi) || !parse_hex64(hid + 16, &hid_lo) ||
        !parse_hex64(rid, &rid_hi) || !parse_hex64(rid + 16, &rid_lo) ||
        (hid_hi == 0 && hid_lo == 0) || (rid_hi == 0 && rid_lo == 0) ||
        !parse_decimal64(eid, eid_len, &event_id)) return 0;
    char canonical[MARU_SESSION_HOST_NOTIFICATION_IDENTIFIER_CAP];
    const size_t canonical_len = maru_session_host_notification_format_identifier(
        hid_hi, hid_lo, rid_hi, rid_lo, event_id, canonical, sizeof(canonical));
    if (canonical_len == 0 || canonical_len != identifier_len ||
        memcmp(canonical, identifier, canonical_len) != 0) return 0;
    *hid_hi_out = hid_hi;
    *hid_lo_out = hid_lo;
    *rid_hi_out = rid_hi;
    *rid_lo_out = rid_lo;
    *eid_out = event_id;
    return 1;
}
