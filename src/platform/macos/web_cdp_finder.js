function(KIND, Q, EXACT, NTH, ACTION) {
  // W9b2-2 text/label finder - isolated world, Runtime.callFunctionOn + serializationOptions {serialization:"deep", maxDepth:2}.
  // Q is already normalized by Zig (web_cdp_locate.normalize); NTH is null or an integer; ACTION: click|hover|type|press|scroll.
  // Returns {err:"too_large",elements} | {err:"budget",ms} | {n:0,hidden} | {n:1,el,name} | {n:k,cands,names,more}.
  var CAP = 100000, BUDGET_MS = 300, MAX_NAME = 256, MAX_CANDS = 5;
  var G = function (p, k) { return Object.getOwnPropertyDescriptor(p, k).get; };
  var EP = Element.prototype, NP = Node.prototype, HP = HTMLElement.prototype, DP = Document.prototype, FP = DocumentFragment.prototype;
  var perf = performance, pnow = Performance.prototype.now, t0 = pnow.call(perf);
  var srG = G(EP, 'shadowRoot'), tagG0 = G(EP, 'tagName'), kidsE = G(EP, 'children'), kidsF = G(FP, 'children'), ga = EP.getAttribute,
    tcG = G(NP, 'textContent'), itG = G(HP, 'innerText'), pnG = G(NP, 'parentNode'), ntG = G(NP, 'nodeType'), hostG = G(ShadowRoot.prototype, 'host'),
    slotG = G(EP, 'assignedSlot'), cv = EP.checkVisibility, gbr = EP.getBoundingClientRect, valG = G(HTMLInputElement.prototype, 'value'),
    typG = G(HTMLInputElement.prototype, 'type'), docElG = G(DP, 'documentElement'), cwG = G(EP, 'clientWidth'), swG = G(EP, 'scrollWidth'),
    ctlG = G(HTMLLabelElement.prototype, 'control'), cnG = G(NP, 'childNodes'), dataG = G(CharacterData.prototype, 'data'),
    grn = NP.getRootNode, qsaD = DP.querySelectorAll, qsaF = FP.querySelectorAll, gebiD = DP.getElementById, gebiF = FP.getElementById,
    ceG = G(HP, 'isContentEditable'), S = String.prototype, sIdx = S.indexOf, sRep = S.replace, sLow = S.toLowerCase;
  var INV = /[\u00AD\u200B-\u200D\u2060\uFEFF]/g, WS = /[ \t\n\r\v\f\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+/g, UP = /[A-Z]+/g;
  var lowF = function (m) { return sLow.call(m); };
  var sUp = S.toUpperCase, tagG = { call: function (e) { return sUp.call(tagG0.call(e)); } }; // XHTML gives lower-case tagName
  var lowA = function (s) { return sRep.call(s, UP, lowF); }; // ASCII only - same as std.ascii.eqlIgnoreCase
  var norm = function (s) { // = web_cdp_locate.normalize
    s = sRep.call(sRep.call(s, INV, ''), WS, ' ');
    var a = s.length > 0 && s.charCodeAt(0) === 32 ? 1 : 0, b = s.length > a && s.charCodeAt(s.length - 1) === 32 ? s.length - 1 : s.length;
    return a === 0 && b === s.length ? s : s.slice(a, b);
  };
  var key = function (s) { return lowA(sRep.call(sRep.call(s, INV, ''), WS, '')); };
  var QL = lowA(Q), QK = key(Q);
  var match = function (s) { var n = norm(s); return n.length > 0 && (EXACT ? n === Q : sIdx.call(lowA(n), QL) >= 0) ? n : null; };
  var ticks = 0;
  var tick = function () { ticks++; if (pnow.call(perf) - t0 > BUDGET_MS) throw 'budget'; };
  // flat-tree parent (assigned slot, then parent, shadow root -> host)
  var up = function (n) {
    var s = ntG.call(n) === 1 ? slotG.call(n) : null; if (s) return s;
    var p = pnG.call(n); if (p && ntG.call(p) === 11) p = hostG.call(p);
    return p && ntG.call(p) === 1 ? p : null;
  };
  var ariaHidden = function (e) { for (var n = e; n; n = up(n)) { var v = ga.call(n, 'aria-hidden'); if (v !== null && lowA(v) === 'true') return true; } return false; };
  var docEl = docElG.call(document);
  var minX = null, maxX, sx, sy;
  var visible = function (e) {
    if (minX === null) { // lazily - reading layout forces the page's pending layout; the too_large answer must not
      // the scrollable area in document coordinates - RTL scrolls to the left of the initial viewport (the unreachable side is the right)
      var rtl = getComputedStyle(docEl).direction === 'rtl', se = document.scrollingElement || docEl, cw = cwG.call(se), sw = Math.max(swG.call(se), cw);
      minX = rtl ? cw - sw : 0; maxX = rtl ? cw : sw; sx = scrollX; sy = scrollY;
    }
    if (!cv.call(e, { visibilityProperty: true })) return false;
    var r = gbr.call(e);
    if (!(r.width > 0 && r.height > 0)) return false;
    if (r.right + sx <= minX || r.left + sx >= maxX || r.bottom + sy <= 0) return false; // honeypot: wholly outside the scrollable area
    return true;
  };
  var boxed = function (e) { var r = gbr.call(e); return r.width > 0 && r.height > 0; };
  var ROLES = { button: 1, link: 1, tab: 1, menuitem: 1, menuitemcheckbox: 1, menuitemradio: 1, option: 1, checkbox: 1, radio: 1, switch: 1, treeitem: 1 };
  var actionable = function (e) {
    var t = tagG.call(e);
    if (t === 'BUTTON' || t === 'LABEL' || t === 'SUMMARY' || t === 'INPUT' || t === 'SELECT' || t === 'TEXTAREA') return true;
    if (t === 'A' && ga.call(e, 'href') !== null) return true;
    var r = ga.call(e, 'role');
    if (r) { r = lowA(sRep.call(r, /^\s+/, '')); var sp = r.search(/\s/); if (ROLES[sp < 0 ? r : r.slice(0, sp)] === 1) return true; }
    return false; // contenteditable is never a retarget (round 2: clicked the middle of an editor)
  };
  // where the action goes: scroll -> itself; type/press -> a label's control; type -> otherwise itself (never an editor host: type
  // replaces the target's whole text); click/hover/press -> nearest actionable ancestor with a box (press: a span in a button is not focusable)
  var viaLabel = false;
  var target = function (e) {
    viaLabel = false;
    if (ACTION === 'scroll') return e;
    if (ACTION === 'type' || ACTION === 'press') {
      for (var n = e; n; n = up(n)) if (tagG.call(n) === 'LABEL') { var c = ctlG.call(n); viaLabel = !!c; return c || n; }
      if (ACTION === 'type') return e;
    }
    // click/hover: only a tiny hit (sr-only 1x1, clipped) moves to its actionable ancestor - pressing an ancestor's center hits whatever is
    // there (a card's delete button, review round 1); a normal hit is pressed itself and the event bubbles. press: always (focus).
    if (ACTION !== 'press') { var hr = gbr.call(e); if (hr.width > 2 && hr.height > 2) return e; }
    for (var m = e, i = 0; m && i < 4096; m = up(m), i++) if (actionable(m)) return boxed(m) ? m : e;
    return e;
  };
  var clip = function (s) { if (s.length <= MAX_NAME) return s; var k = MAX_NAME; var c = s.charCodeAt(k - 1); if (c >= 0xD800 && c <= 0xDBFF) k--; return s.slice(0, k); };
  // ---- pre-scan: count elements (document + open shadow roots, tree order with each shadow tree at its host), stop over CAP
  var count = 0, roots = [], force = new Set(), order = KIND === 'label' ? [] : null;
  var isBtnInput = function (e) { if (tagG.call(e) !== 'INPUT') return false; var ty = typG.call(e); return ty === 'submit' || ty === 'reset' || ty === 'button'; };
  // rendered text without aria-hidden, unrendered, off-page or tiny parts (and svg title/desc/style) - for shadow hosts, non-HTML elements and
  // ancestors of such parts (review round 1: a host's textContent carried its hidden menu items; an aria-hidden icon hid its button).
  // Walks the flat tree: a host's shadow content, a slot's assigned nodes; unslotted light children of a host are not rendered.
  var cnG2 = G(NP, 'childNodes'), anodes = HTMLSlotElement.prototype.assignedNodes, tslot = G(Text.prototype, 'assignedSlot'), FLAT = { flatten: true };
  var NOTEXT = { SCRIPT: 1, STYLE: 1, TEMPLATE: 1, NOSCRIPT: 1, TITLE: 1, DESC: 1, HEAD: 1 };
  var INLINE = { inline: 1, contents: 1, 'inline-block': 1, 'inline-flex': 1, 'inline-grid': 1 };
  var renderedText = function (root) {
    var out = [], stk = [], push = function (n) { var s0 = ntG.call(n) === 1 ? srG.call(n) : null; stk.push([s0 ? cnG2.call(s0) : cnG2.call(n), 0, !!s0]); };
    push(root);
    while (stk.length) {
      tick();
      var top = stk[stk.length - 1];
      if (top[1] >= top[0].length) { stk.pop(); continue; }
      var ch = top[0][top[1]++], nt = ntG.call(ch);
      if (nt === 3) { var p0 = pnG.call(ch); if (p0 && ntG.call(p0) === 1 && srG.call(p0) && !tslot.call(ch)) continue; out.push(dataG.call(ch)); continue; }
      if (nt !== 1) continue;
      var tg = tagG.call(ch);
      if (NOTEXT[tg] === 1) continue;
      if (tg === 'SLOT') { var an = anodes.call(ch, FLAT); stk.push([an.length ? an : cnG2.call(ch), 0, false]); continue; }
      var ah = ga.call(ch, 'aria-hidden');
      if ((ah !== null && lowA(ah) === 'true') || !visible(ch)) continue;
      var blk = INLINE[getComputedStyle(ch).display] !== 1;
      if (blk) out.push(' ');
      push(ch);
      if (blk) stk.push([[], 0, false]), out.push(' ');
    }
    return out.join('');
  };
  var textOf = function (e, masked) {
    if (tagG.call(e) === 'INPUT') return isBtnInput(e) ? valG.call(e) : '';
    if (e instanceof HTMLElement && !srG.call(e) && !masked) return itG.call(e);
    return renderedText(e);
  };
  var mark = function (e) { for (var n = e; n && !force.has(n); n = up(n)) force.add(n); };
  var scan = function (root) {
    var all = (root === document ? qsaD : qsaF).call(root, '*');
    count += all.length;
    if (count > CAP) throw 'too_large';
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (order) order.push(el);
      var s = srG.call(el);
      if (KIND === 'text') {
        if (s || isBtnInput(el)) mark(el); // their text is not in an ancestor's textContent (slotted text matches at the host)
      }
      if (s) { roots.push(s); scan(s); }
    }
  };
  var hits = [], seen = new Set(), hidden = 0, stopped = false, picked = null;
  var accept = function (hit, name) {
    var t = target(hit);
    if (t !== hit) {
      if (!viaLabel) name = norm(textOf(t)); // matched = the text of what is pressed
      else if (ariaHidden(t) || !visible(t)) { hidden++; return; } // a label whose control is hidden (custom checkbox)
    }
    if (seen.has(t)) return;
    seen.add(t);
    if (NTH !== null && NTH !== undefined) { if (hits.length === NTH) { picked = [t, name]; throw 'enough'; } hits.push(null); return; }
    hits.push([t, name]);
    if (hits.length > MAX_CANDS) { stopped = true; throw 'enough'; }
  };
  try {
    try { scan(document); } catch (x) { if (x === 'too_large') return { err: 'too_large', elements: count }; throw x; }
    gbr.call(docEl); // the page's own pending style/layout (378 ms after a style change at 100k elements) is not our walk's budget
    t0 = pnow.call(perf);
    if (KIND === 'text') {
      var SKIP = { SCRIPT: 1, STYLE: 1, TEMPLATE: 1, NOSCRIPT: 1, HEAD: 1, SELECT: 1, OPTION: 1, OPTGROUP: 1, DATALIST: 1, TEXTAREA: 1 };
      var pass = function (c) {
        if (force.has(c)) return true;
        var k = key(tcG.call(c) || '');
        if (sIdx.call(k, QK) >= 0) return true;
        // innerText may drop hidden descendants inside the run (Del<span hidden>XX</span>ete) - a subsequence is still necessary
        for (var i = 0, p = -1; i < QK.length; i++) { p = sIdx.call(k, QK.charAt(i), p + 1); if (p < 0) return false; }
        return true;
      };
      var lists = function (e) { var s = srG.call(e); return s ? [kidsF.call(s), kidsE.call(e)] : [kidsE.call(e)]; };
      // 0 = no match, 1 = accepted (ancestors are not judged - innermost only), 2 = a hidden match (aria-hidden, unrendered, off-page or
      // tiny): counted, and its ancestors are judged on their rendered text without it (review round 1 - hidden copies, aria-hidden icon
      // text and off-page "read more about ..." spans no longer hide a visible match, and no longer make an ancestor match either)
      var judge = function (e, masked) {
        var tg = tagG.call(e);
        if (tg === 'HTML' || tg === 'BODY') return 0;
        var n = match(textOf(e, masked));
        if (n === null) return 0;
        if (ariaHidden(e) || !visible(e)) { hidden++; return 2; }
        accept(e, n);
        return 1;
      };
      // iterative post-order (deep DOMs must not overflow the stack): [element, child lists, list index, child index, got, masked below]
      var st = [[docEl, lists(docEl), 0, 0, false, false]];
      while (st.length) {
        var f = st[st.length - 1], L = f[1], down = false;
        while (f[2] < L.length) {
          var K = L[f[2]];
          if (f[3] >= K.length) { f[2]++; f[3] = 0; continue; }
          var c = K[f[3]++];
          tick();
          var ct = tagG.call(c);
          if (SKIP[ct] === 1) { if (ct === 'SELECT' && match(itG.call(c)) !== null) f[4] = true; continue; } // option text shows in the parent's innerText - the select owns it
          if (!pass(c)) continue;
          st.push([c, lists(c), 0, 0, false, false]); down = true; break;
        }
        if (down) continue;
        st.pop();
        tick(); // the way up re-reads innerText per ancestor - the budget covers it too (review round 1: 1 s on a deep page)
        var res = f[4] ? 1 : judge(f[0], f[5]);
        if (st.length) { var pf = st[st.length - 1]; if (res === 1) pf[4] = true; else if (res === 2 || f[5]) pf[5] = true; }
      }
    } else {
      var SEL = 'input,textarea,select,button,meter,output,progress,[role],[contenteditable]';
      var FORM = { textbox: 1, searchbox: 1, combobox: 1, checkbox: 1, radio: 1, switch: 1, slider: 1, spinbutton: 1, listbox: 1 };
      var LM = new Map(), isT = new Set(), rts = [document].concat(roots);
      for (var ri = 0; ri < rts.length; ri++) {
        var rr = rts[ri], qa = rr === document ? qsaD : qsaF, ts = qa.call(rr, SEL), lbs = qa.call(rr, 'label');
        for (var z = 0; z < ts.length; z++) isT.add(ts[z]);
        for (var z2 = 0; z2 < lbs.length; z2++) { tick(); var cc = ctlG.call(lbs[z2]); if (cc) { var a = LM.get(cc); if (!a) LM.set(cc, a = []); a.push(lbs[z2]); } }
      }
      var isTarget = function (t) {
        var tg = tagG.call(t);
        if (tg === 'INPUT') return typG.call(t) !== 'hidden';
        if (tg === 'TEXTAREA' || tg === 'SELECT' || tg === 'BUTTON' || tg === 'METER' || tg === 'OUTPUT' || tg === 'PROGRESS') return true;
        var r = ga.call(t, 'role');
        if (r) { var toks = lowA(r).split(WS); for (var i = 0; i < toks.length; i++) if (toks[i]) { if (FORM[toks[i]] === 1) return true; break; } }
        return t instanceof HTMLElement && ga.call(t, 'contenteditable') !== null && ceG.call(t);
      };
      // label text without the control itself, aria-hidden and unrendered parts (AccName-ish); whole = aria-labelledby of a hidden node
      var textExcl = function (root, ctl, whole) {
        var out = [], stk = [cnG.call(root)], idx = [0];
        while (stk.length) {
          var ks = stk[stk.length - 1], j = idx[idx.length - 1];
          if (j >= ks.length) { stk.pop(); idx.pop(); continue; }
          idx[idx.length - 1] = j + 1;
          tick();
          var ch = ks[j], nt = ntG.call(ch);
          if (nt === 3) { out.push(dataG.call(ch)); continue; }
          if (nt !== 1 || ch === ctl) continue;
          var tg = tagG.call(ch);
          if (tg === 'SCRIPT' || tg === 'STYLE' || tg === 'TEMPLATE') continue;
          if (!whole) { var ah = ga.call(ch, 'aria-hidden'); if ((ah !== null && lowA(ah) === 'true') || !cv.call(ch, { visibilityProperty: true })) continue; }
          stk.push(cnG.call(ch)); idx.push(0);
        }
        return out.join('');
      };
      for (var i = 0; i < order.length; i++) {
        var t = order[i];
        tick();
        if (!isT.has(t) || !isTarget(t)) continue;
        var cands = [], ls = LM.get(t);
        if (ls) { var parts = []; for (var k = 0; k < ls.length; k++) { var tx = textExcl(ls[k], t, false); parts.push(tx); cands.push(tx); } if (parts.length > 1) cands.push(parts.join(' ')); }
        var lb = ga.call(t, 'aria-labelledby');
        if (lb) {
          var rt = grn.call(t), ids = lb.split(WS), p2 = [];
          for (var q = 0; q < ids.length; q++) { if (!ids[q]) continue; var el = (rt === document ? gebiD : gebiF).call(rt, ids[q]); if (el) p2.push(textExcl(el, t, !visible(el))); }
          cands.push(p2.join(' '));
        }
        var al = ga.call(t, 'aria-label'); if (al) cands.push(al);
        var hit = null;
        for (var c2 = 0; c2 < cands.length && hit === null; c2++) hit = match(cands[c2]);
        if (hit === null) continue;
        if (ariaHidden(t) || !visible(t)) { hidden++; continue; }
        var seenBefore = seen.has(t); if (!seenBefore) { seen.add(t); if (NTH !== null && NTH !== undefined) { if (hits.length === NTH) { picked = [t, hit]; throw 'enough'; } hits.push(null); } else { hits.push([t, hit]); if (hits.length > MAX_CANDS) { stopped = true; throw 'enough'; } } }
      }
    }
  } catch (x) {
    if (x === 'budget') return { err: 'budget', ms: Math.round(pnow.call(perf) - t0) };
    if (x !== 'enough') throw x;
  }
  if (NTH !== null && NTH !== undefined) return picked ? { n: 1, el: picked[0], name: clip(picked[1]) } : { n: 0, hidden: hidden };
  if (hits.length === 0) return { n: 0, hidden: hidden };
  if (hits.length === 1) return { n: 1, el: hits[0][0], name: clip(hits[0][1]) };
  var nodes = [], names = [];
  for (var h = 0; h < hits.length && h < MAX_CANDS; h++) { nodes.push(hits[h][0]); names.push(clip(hits[h][1])); }
  return { n: nodes.length, cands: nodes, names: names, more: stopped };
}
