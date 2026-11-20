//! `browser.upload`(W9c③) 의 격리 world 함수들 — 칸 확인(`check_js`)·듣는 이 떼기(`disarm_js`)·넣은 뒤 읽기(`verify_js`). 차례는
//! `web_cdp_upload.zig` 가 쥐고, 이 파일은 그 JS 글만 둔다 — 판정자(`maru-web-judge --upload` 의 `up-maru-js`)가 **이 글 그대로** 실제 CEF 에 대어
//! (폴더 칸의 속성 바꾸기·되돌리기, 칸 종류 판정) 앱이 보내는 함수를 잰다(사용자 결정 2026-11-20 「iframe·폴더 둘 다」 — 그 전에는 이 JS 를 도는 시험이
//! 스모크뿐이었다). 이 파일은 아무것도 import 하지 않는다(판정자 실행 파일에 따로 싣는다).

/// 확인 함수(격리 world — 프로토타입 getter 로 읽는다: DOM clobbering). 인자 n = 넣을 파일 수, arm = 승인 뒤인가, key = 기록 자리, dir = 폴더 올리기인가.
/// 승인 뒤(arm 참)에는 통과하면 그 칸에 캡처 단계의 `input`·`change` 듣는 이를 달아, 그 칸에 닿은 진짜 이벤트마다(둘까지) 그때의 목록(이름·크기)을
/// 격리 world 의 `globalThis[key]` 에 적는다.
///
/// 폴더(dir 참 — 사용자 결정 2026-11-20): 칸이 `webkitdirectory` 여야 한다. CEF 는 `webkitdirectory` 칸에 `DOM.setFileInputFiles` 로 준 목록을 넣지 않고
/// (Blink 가 첫 경로를 폴더로 펼치게 넘기는데 CEF 는 펼치지 않는다 — 실측 probe-folder-path, 판정 `up-folder-path-silent`), 사람의 고르개도 maru 가
/// 파일들로 펼쳐 답한다. 그래서 승인 뒤 확인이 `webkitdirectory` 를 떼고 없던 `multiple` 을 붙인 뒤(`s.tog`) 넣는다 — 페이지는 진짜 `input`·`change` 로
/// 파일들을 받는다(`webkitRelativePath` 는 빈 글 — 사람의 고르개와 같다). **되돌리기**는 maru 의 캡처 듣는 이가 첫 진짜 이벤트에서 곧(넣기 안에서
/// 동기로 — 칸의 보통 처리기는 `webkitdirectory` 참을 본다; 공격 A2-3·A3-5), 읽기·떼기에서도, 그리고 15 초 안전망(격리 world 의 타이머)으로. 지금 값이
/// 우리가 바꾼 그대로일 때만 되돌린다(페이지가 그 사이 바꾼 값을 덮지 않는다).
pub const check_js =
    "function(n,arm,key,dir){var G=function(p,k){return Object.getOwnPropertyDescriptor(p,k).get};var t=this;" ++
    "if(!(t instanceof Element))return 'not file';" ++
    "if(G(Node.prototype,'ownerDocument').call(t)!==document)return 'frame';" ++
    "if(!G(Node.prototype,'isConnected').call(t))return 'detached';" ++
    "if(!(t instanceof HTMLInputElement)||G(HTMLInputElement.prototype,'type').call(t)!=='file')return 'not file';" ++
    "if(G(HTMLInputElement.prototype,'disabled').call(t)||Element.prototype.matches.call(t,':disabled'))return 'disabled';" ++
    "var wd=G(HTMLInputElement.prototype,'webkitdirectory').call(t);" ++
    "if(dir&&!wd)return 'not directory';" ++
    "if(!dir&&wd)return 'directory';" ++
    "if(!dir&&n>1&&!G(HTMLInputElement.prototype,'multiple').call(t))return 'single';" ++
    "if(arm){var D=G(HTMLInputElement.prototype,'files'),L=G(FileList.prototype,'length'),I=FileList.prototype.item,N=G(File.prototype,'name'),Z=G(Blob.prototype,'size');" ++
    "var HA=Element.prototype.hasAttribute,SA=Element.prototype.setAttribute,RA=Element.prototype.removeAttribute;" ++
    "var s={seen:[]};" ++
    "if(dir){s.tog={mul:HA.call(t,'multiple')};s.back=function(){if(!s.tog||s.tog.done)return;s.tog.done=true;" ++
    "if(!HA.call(t,'webkitdirectory'))SA.call(t,'webkitdirectory','');if(!s.tog.mul&&HA.call(t,'multiple'))RA.call(t,'multiple')};" ++
    "RA.call(t,'webkitdirectory');if(!s.tog.mul)SA.call(t,'multiple','');setTimeout(s.back,15000)}" ++
    "s.h=function(e){if(e.isTrusted!==true||e.target!==t||s.seen.length>=2)return;var f=D.call(t),l=[];" ++
    "if(f)for(var i=0,c=L.call(f);i<c;i++){var x=I.call(f,i);l.push([N.call(x),Z.call(x)])}s.seen.push(l);if(s.back)s.back()};" ++
    "var A=EventTarget.prototype.addEventListener;A.call(t,'input',s.h,true);A.call(t,'change',s.h,true);globalThis[key]=s}" ++
    "return 'ok'}";

/// 읽기를 못 하고 끝날 때 듣는 이를 뗀다(같은 objectId·같은 key — 없으면 아무것도 안 한다). 폴더면 속성도 되돌린다.
pub const disarm_js =
    "function(key){var s=globalThis[key];if(!s)return;if(s.back)s.back();var R=EventTarget.prototype.removeEventListener;" ++
    "R.call(this,'input',s.h,true);R.call(this,'change',s.h,true);delete globalThis[key]}";

/// 넣은 뒤 읽기(같은 objectId) — 듣는 이를 떼고(폴더면 속성을 되돌리고), 넣을 때 적은 목록(받았나)과 지금 칸(그대로 두었나 — 붙어 있고 같은 목록)을 견준다:
/// `ok`(지금 칸이 같다)·`dropped`(넣을 때 같았는데 지금은 아니다 — 페이지가 받은 뒤 비웠다)·`mismatch`(넣을 때 다른 목록)·`removed`(기록 없이
/// 떨어졌다)·`unseen`(기록 없이 다른 목록).
pub const verify_js =
    "function(names,sizes,key){var G=function(p,k){return Object.getOwnPropertyDescriptor(p,k).get};var t=this;var s=globalThis[key];" ++
    "var D=G(HTMLInputElement.prototype,'files'),L=G(FileList.prototype,'length'),I=FileList.prototype.item,N=G(File.prototype,'name'),Z=G(Blob.prototype,'size');" ++
    "if(s){if(s.back)s.back();var R=EventTarget.prototype.removeEventListener;R.call(t,'input',s.h,true);R.call(t,'change',s.h,true);delete globalThis[key]}" ++
    "var same=function(l){if(!l||l.length!==names.length)return false;for(var i=0;i<l.length;i++)if(l[i][0]!==names[i]||l[i][1]!==sizes[i])return false;return true};" ++
    "var now=null;if(G(Node.prototype,'isConnected').call(t)){var f=D.call(t);now=[];if(f)for(var i=0,c=L.call(f);i<c;i++){var x=I.call(f,i);now.push([N.call(x),Z.call(x)])}}" ++
    "if(same(now))return 'ok';" ++
    "if(s&&s.seen.length){for(var j=0;j<s.seen.length;j++)if(same(s.seen[j]))return 'dropped';return 'mismatch'}" ++
    "return now===null?'removed':'unseen'}";
