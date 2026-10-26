// 별도 진단 바이너리에서만 센다. reader가 제시한 길이는 C 파서가 소비한 길이가 아니다.
// 제품 편집과 프레임 직후 기록하며, 전수 대조가 더한 호출은 다음 입력 전에 비운다.
pub const NativeParseProbe = struct {
__NATIVE_COUNTER_FIELDS__
};
pub var native_parse_probe: NativeParseProbe = .{};
