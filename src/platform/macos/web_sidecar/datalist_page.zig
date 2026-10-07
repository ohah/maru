//! 제안 목록(datalist — W6m①)의 CEF 를 모르는 부분 — 대리 스크립트 조각과 렌더러가 보낸 목록 풀기(순수 — `pure_tests.zig`).
//! 규칙과 믿음의 경계는 `datalist.zig`.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const message = protocol.message;

/// 대리 스크립트의 datalist 부분 — `send` 를 꺼낸 바깥 함수 안에서 돈다(`notifications.proxy_script`). 큰따옴표·역슬래시 없이
/// 쓴다(JSON 문자열에 그대로 넣는다). 판정·읽기·넣기에 쓰는 것(`type`·`list`·`value` 의 getter/setter, `options`·길이, 옵션의
/// `value`·`label`·`disabled`, 사각형·`visualViewport` getter, `activeElement`, 사건 getter, `toLowerCase`·`indexOf`,
/// `addEventListener`·`dispatchEvent`·`Event`·`JSON.stringify`)은 먼저 쥔다 — 페이지가 바꿔 놓아도 거르기·넣기가 페이지 코드를
/// 부르지 않는다. 배열은 `push` 대신 길이 자리에 넣는다(페이지가 `Array.prototype.push` 를 바꿀 수 있다). 주 프레임에서만 돈다.
pub const script_part = "(function(){if(window!==window.top)return;" ++
    "var A=Reflect.apply,J=JSON.stringify,S=String,G=Object.getOwnPropertyDescriptor,E=Event,W=window,D=document," ++
    "IP=HTMLInputElement.prototype,TG=G(IP,'type').get,LG=G(IP,'list').get,VD=G(IP,'value'),VG=VD.get,VS=VD.set," ++
    "OG=G(HTMLDataListElement.prototype,'options').get,CL=G(HTMLCollection.prototype,'length').get," ++
    "OP=HTMLOptionElement.prototype,OV=G(OP,'value').get,OL=G(OP,'label').get,OD=G(OP,'disabled').get," ++
    "BR=Element.prototype.getBoundingClientRect,RP=DOMRectReadOnly.prototype,RX=G(RP,'x').get,RY=G(RP,'y').get,RW=G(RP,'width').get,RH=G(RP,'height').get," ++
    "VV=W.visualViewport,VP=VV?VisualViewport.prototype:null,VL=VP&&G(VP,'offsetLeft').get,VT=VP&&G(VP,'offsetTop').get,VC=VP&&G(VP,'scale').get," ++
    "AE=G(Document.prototype,'activeElement').get,ET=G(Event.prototype,'target').get,MB=G(MouseEvent.prototype,'button').get," ++
    "KP=KeyboardEvent.prototype,KK=G(KP,'key').get,KA=G(KP,'altKey').get,KC=G(KP,'ctrlKey').get,KM=G(KP,'metaKey').get," ++
    "AL=EventTarget.prototype.addEventListener,DE=EventTarget.prototype.dispatchEvent,LC=S.prototype.toLowerCase,IX=S.prototype.indexOf," ++
    "K={text:1,search:1,url:1,tel:1,email:1,number:1},cur=null,ver=0,vals=[],busy=false;" ++
    // 제안 목록이 붙은 글 칸이면 그 칸(아니면 null). getter 를 다른 객체에 부르면 던진다 — 그것으로 종류를 가린다.
    "function fieldOf(t){try{return K[A(TG,t,[])]&&A(LG,t,[])?t:null}catch(e){return null}}" ++
    "function hide(){if(!cur)return;cur=null;vals=[];try{send('dl',J({t:0,v:ver}))}catch(e){}}" ++
    "function show(t){try{var l=A(LG,t,[]);if(!l)return hide();var q=A(LC,S(A(VG,t,[])),[]),os=A(OG,l,[]),n=A(CL,os,[]),it=[],vs=[];" ++
    "for(var i=0;i<n&&it.length<256;i++){var o=os[i];if(A(OD,o,[]))continue;var v=S(A(OV,o,[])),b=S(A(OL,o,[]));if(v==='')continue;" ++
    "if(q!==''&&A(IX,A(LC,v,[]),[q])<0&&A(IX,A(LC,b,[]),[q])<0)continue;it[it.length]=[v,b];vs[vs.length]=v}" ++
    "if(!it.length)return hide();" ++
    "var r=A(BR,t,[]),ox=0,oy=0,s=1;if(VV){ox=A(VL,VV,[]);oy=A(VT,VV,[]);s=A(VC,VV,[])}" ++
    "cur=t;vals=vs;ver++;" ++
    "send('dl',J({t:1,v:ver,r:[(A(RX,r,[])-ox)*s,(A(RY,r,[])-oy)*s,A(RW,r,[])*s,A(RH,r,[])*s],i:it}))}catch(e){}}" ++
    "function on(type,f){A(AL,W,[type,f,true])}" ++
    "on('mousedown',function(e){try{if(busy||A(MB,e,[])!==0)return;var t=fieldOf(A(ET,e,[]));if(t)show(t)}catch(x){}});" ++
    "on('input',function(e){try{if(busy)return;var t=fieldOf(A(ET,e,[]));if(!t)return;if(S(A(VG,t,[]))==='')return hide();show(t)}catch(x){}});" ++
    "on('keydown',function(e){try{if(busy||A(KK,e,[])!=='ArrowDown'||A(KA,e,[])||A(KC,e,[])||A(KM,e,[]))return;var t=fieldOf(A(ET,e,[]));if(t)show(t)}catch(x){}});" ++
    "on('focusout',function(e){try{if(cur&&A(ET,e,[])===cur)hide()}catch(x){}});" ++
    "on('scroll',function(){hide()});on('resize',function(){hide()});on('pagehide',function(){hide()});" ++
    // 고르기 — 같은 목록(번호)이고 그 칸에 아직 초점이 있을 때만. 넣는 동안 우리 `input` 처리기는 다시 보이지 않는다.
    "send('dl',function(v,i){try{if(v!==ver||!cur||A(AE,D,[])!==cur||!(i>=0&&i<vals.length))return;var t=cur;busy=true;" ++
    "A(VS,t,[vals[i]]);A(DE,t,[new E('input',{bubbles:true})]);A(DE,t,[new E('change',{bubbles:true})])}catch(x){}finally{busy=false}hide()})" ++
    "})();";

comptime {
    @setEvalBranchQuota(20_000);
    std.debug.assert(std.mem.indexOfAny(u8, script_part, "\"\\\n") == null);
}

/// 렌더러가 보낸 목록 하나를 풀어 둔 것(순수 — 시험한다).
pub const Parsed = union(enum) {
    hide: i32,
    show: struct { version: i32, field: message.Rect, count: u16, items: []const u8 },
};

/// `{t:0,v}` 는 닫기, `{t:1,v,r:[x,y,w,h],i:[[값,레이블],…]}` 는 보이기. 항목 글이 UTF-8 이 아니면(대리 스크립트가 아닌 것이
/// 보냈다) 목록 전체를 버린다 — 하나만 건너뛰면 고른 번호가 스크립트가 쥔 항목과 어긋난다. `items_buf` 에 덩어리를 쌓는다.
/// view 와 겹치지 않는 칸은 보이지 않는다(null).
pub fn parse(payload: []const u8, view: message.ViewSize, items_buf: []u8) ?Parsed {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    return parseValue(parsed.value, view, items_buf);
}

fn parseValue(root: std.json.Value, view: message.ViewSize, items_buf: []u8) ?Parsed {
    if (root != .object) return null;
    const kind = root.object.get("t") orelse return null;
    const version_value = root.object.get("v") orelse return null;
    if (kind != .integer or version_value != .integer) return null;
    if (version_value.integer < 0 or version_value.integer > std.math.maxInt(i32)) return null;
    const version: i32 = @intCast(version_value.integer);
    if (kind.integer == 0) return .{ .hide = version };
    if (kind.integer != 1) return null;
    const rect = root.object.get("r") orelse return null;
    if (rect != .array or rect.array.items.len != 4) return null;
    var nums: [4]f64 = undefined;
    for (rect.array.items, 0..) |item, i| {
        nums[i] = switch (item) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            else => return null,
        };
        if (!std.math.isFinite(nums[i])) return null;
    }
    // view 와 겹치는 칸만(자리는 view DIP — 겹침은 원래 사각형으로 본다). 그다음 네 변을 view 둘레 한 겹 안으로 묶는다(코덱
    // 상한 안 — 넓은 칸이 왼쪽 밖에서 시작해도 보이는 쪽 끝은 그대로).
    const vw: f64 = @floatFromInt(view.width);
    const vh: f64 = @floatFromInt(view.height);
    if (nums[2] < 0 or nums[3] < 0) return null;
    if (nums[0] >= vw or nums[1] >= vh or nums[0] + nums[2] <= 0 or nums[1] + nums[3] <= 0) return null;
    const x = @max(nums[0], -vw);
    const y = @max(nums[1], -vh);
    const w = @min(nums[0] + nums[2], 2 * vw) - x;
    const h = @min(nums[1] + nums[3], 2 * vh) - y;
    const items = root.object.get("i") orelse return null;
    if (items != .array) return null;
    var builder: protocol.fields.DatalistBuilder = .{ .buf = items_buf };
    for (items.array.items) |item| {
        if (item != .array or item.array.items.len != 2) return null;
        const value = item.array.items[0];
        const label = item.array.items[1];
        if (value != .string or label != .string) return null;
        if (!std.unicode.utf8ValidateSlice(value.string) or !std.unicode.utf8ValidateSlice(label.string)) return null;
        if (!builder.add(value.string, label.string)) break;
    }
    if (builder.count == 0) return null;
    return .{ .show = .{
        .version = version,
        .field = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)), .width = @intFromFloat(@round(w)), .height = @intFromFloat(@round(h)) },
        .count = builder.count,
        .items = builder.items(),
    } };
}

// ── 순수 시험 ─────────────────────────────────────────────────────────────────────────────────────────────

const test_view: message.ViewSize = .{ .width = 800, .height = 600, .scale = 2 };

test "datalist payload: show keeps order, blanks a label equal to the value, and rounds the field into view DIP" {
    var buf: [message.max_datalist_bytes]u8 = undefined;
    const got = parse("{\"t\":1,\"v\":3,\"r\":[0.4,10.6,300,40],\"i\":[[\"apple\",\"apple\"],[\"banana\",\"yellow fruit\"]]}", test_view, &buf).?;
    try std.testing.expectEqual(@as(i32, 3), got.show.version);
    try std.testing.expectEqual(message.Rect{ .x = 0, .y = 11, .width = 300, .height = 40 }, got.show.field);
    try std.testing.expectEqual(@as(u16, 2), got.show.count);
    var it: protocol.fields.DatalistItems = .{ .bytes = got.show.items };
    try std.testing.expectEqualStrings("", (try it.next()).?.label);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("banana", second.value);
    try std.testing.expectEqualStrings("yellow fruit", second.label);
    try std.testing.expectEqual(Parsed{ .hide = 4 }, parse("{\"t\":0,\"v\":4}", test_view, &buf).?);
}

test "datalist payload: malformed, out of view, empty, or non-UTF-8 lists are not shown" {
    var buf: [message.max_datalist_bytes]u8 = undefined;
    const bad = [_][]const u8{
        "[]",
        "{\"t\":2,\"v\":1}",
        "{\"t\":1,\"v\":-1,\"r\":[0,0,1,1],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,1],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,1,\"1\"],\"i\":[[\"a\",\"\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"\",\"only an empty value\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\"]]}",
        "{\"t\":1,\"v\":1,\"r\":[800,0,10,10],\"i\":[[\"a\",\"\"]]}", // view 오른쪽 밖
        "{\"t\":1,\"v\":1,\"r\":[-20,0,10,10],\"i\":[[\"a\",\"\"]]}", // view 왼쪽 밖
        "{\"t\":1,\"v\":1,\"r\":[0,0,10,10],\"i\":[[\"a\\ud800\",\"\"]]}", // 짝 없는 대리 — 하나라도 있으면 목록 전체를 버린다
    };
    for (bad) |payload| try std.testing.expect(parse(payload, test_view, &buf) == null);
    // 걸친 칸은 보인다 — 자리는 view 둘레 한 겹 안으로.
    const edge = parse("{\"t\":1,\"v\":1,\"r\":[-5000,590,6000,40],\"i\":[[\"a\",\"\"]]}", test_view, &buf).?;
    try std.testing.expectEqual(@as(i32, -800), edge.show.field.x);
    try std.testing.expectEqual(@as(u32, 1800), edge.show.field.width); // 오른쪽 끝 1000 은 그대로
    try std.testing.expect(parse("{\"t\":1,\"v\":1,\"r\":[0,0,-1,10],\"i\":[[\"a\",\"\"]]}", test_view, &buf) == null); // 음수 크기
}
