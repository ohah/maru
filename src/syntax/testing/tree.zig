//! 실제 C 노드의 종류·구조·필드·byte/point를 비교하는 테스트 전용 oracle이다.
const std = @import("std");
const c = @import("tree_sitter_c");
pub fn equal(left: *c.TSTree, right: *c.TSTree) ?usize {
    var lc = c.ts_tree_cursor_new(c.ts_tree_root_node(left));
    defer c.ts_tree_cursor_delete(&lc);
    var rc = c.ts_tree_cursor_new(c.ts_tree_root_node(right));
    defer c.ts_tree_cursor_delete(&rc);
    var nodes: usize = 0;
    while (true) {
        const ln = c.ts_tree_cursor_current_node(&lc);
        const rn = c.ts_tree_cursor_current_node(&rc);
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(ln)), std.mem.span(c.ts_node_type(rn)))) return null;
        if (c.ts_node_start_byte(ln) != c.ts_node_start_byte(rn) or c.ts_node_end_byte(ln) != c.ts_node_end_byte(rn)) return null;
        if (!std.meta.eql(c.ts_node_start_point(ln), c.ts_node_start_point(rn)) or
            !std.meta.eql(c.ts_node_end_point(ln), c.ts_node_end_point(rn))) return null;
        if (c.ts_node_is_named(ln) != c.ts_node_is_named(rn) or c.ts_node_is_missing(ln) != c.ts_node_is_missing(rn) or
            c.ts_node_is_extra(ln) != c.ts_node_is_extra(rn) or c.ts_node_has_error(ln) != c.ts_node_has_error(rn) or
            c.ts_node_child_count(ln) != c.ts_node_child_count(rn)) return null;
        if (c.ts_tree_cursor_current_field_id(&lc) != c.ts_tree_cursor_current_field_id(&rc)) return null;
        nodes += 1;
        const child = c.ts_tree_cursor_goto_first_child(&lc);
        if (child != c.ts_tree_cursor_goto_first_child(&rc)) return null;
        if (child) continue;
        while (true) {
            const sibling = c.ts_tree_cursor_goto_next_sibling(&lc);
            if (sibling != c.ts_tree_cursor_goto_next_sibling(&rc)) return null;
            if (sibling) break;
            const parent = c.ts_tree_cursor_goto_parent(&lc);
            if (parent != c.ts_tree_cursor_goto_parent(&rc)) return null;
            if (!parent) return nodes;
        }
    }
}
