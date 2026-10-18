//! Zig 0.17 stores container reflection in parallel name/type/attribute arrays.
//! This adapter exposes the former field-record view while call sites migrate,
//! preserving compile-time defaults and enum discriminants.

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    value: comptime_int,
    alignment: comptime_int,
    is_comptime: bool,
    default_value: ?*const anyopaque,
};

pub fn fieldsFromInfo(comptime info: anytype) [info.field_names.len]Field {
    @setEvalBranchQuota(100_000);
    const Info = @TypeOf(info);
    comptime var result: [info.field_names.len]Field = undefined;
    inline for (info.field_names, 0..) |name, i| {
        if (@hasField(Info, "field_types")) {
            const field_type = info.field_types[i];
            const attrs = info.field_attrs[i];
            result[i] = .{
                .name = name,
                .type = field_type,
                .value = 0,
                .alignment = if (@hasField(@TypeOf(attrs), "align")) attrs.@"align" orelse @alignOf(field_type) else @alignOf(field_type),
                .is_comptime = if (@hasField(@TypeOf(attrs), "comptime")) attrs.@"comptime" else false,
                .default_value = if (@hasField(@TypeOf(attrs), "default_value_ptr")) attrs.default_value_ptr else null,
            };
        } else {
            result[i] = .{
                .name = name,
                .type = void,
                .value = info.field_values[i],
                .alignment = 0,
                .is_comptime = false,
                .default_value = null,
            };
        }
    }
    return result;
}

pub fn fields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => [@typeInfo(T).@"struct".field_names.len]Field,
    .@"enum" => [@typeInfo(T).@"enum".field_names.len]Field,
    .@"union" => [@typeInfo(T).@"union".field_names.len]Field,
    else => @compileError("expected struct, enum, or union type"),
} {
    return switch (@typeInfo(T)) {
        .@"struct" => structFields(T),
        .@"enum" => enumFields(T),
        .@"union" => unionFields(T),
        else => unreachable,
    };
}

pub fn structFields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]Field {
    return fieldsFromInfo(@typeInfo(T).@"struct");
}

pub fn enumFields(comptime T: type) [@typeInfo(T).@"enum".field_names.len]Field {
    return fieldsFromInfo(@typeInfo(T).@"enum");
}

pub fn unionFields(comptime T: type) [@typeInfo(T).@"union".field_names.len]Field {
    return fieldsFromInfo(@typeInfo(T).@"union");
}
