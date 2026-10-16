// Motion kit: a scene is a pure function of time. Nothing here uses timers or
// requestAnimationFrame, so the renderer can ask for any frame, in any order, at
// any frame rate, and get the same pixels. That is what makes the output
// reusable for a later, longer video.

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, k) => a + (b - a) * k;
export const ease = {
  linear: (k) => k,
  out: (k) => 1 - (1 - k) ** 3,
  inOut: (k) => (k < 0.5 ? 4 * k ** 3 : 1 - (-2 * k + 2) ** 3 / 2),
  back: (k) => 1 + 2.2 * (k - 1) ** 3 + 1.2 * (k - 1) ** 2,
};
// progress of t through [t0, t1], eased, clamped
export const prog = (t, t0, t1, e = ease.inOut) => e(clamp((t - t0) / (t1 - t0)));
// value moving from a to b over [t0, t1]
export const tween = (t, t0, t1, a, b, e) => lerp(a, b, prog(t, t0, t1, e));
// the first n characters of s, typed from t0 at cps characters per second
export const typed = (s, t, t0, cps = 14) => [...s].slice(0, Math.max(0, Math.floor((t - t0) * cps))).join('');

export const Motion = { duration: 6, height: 720, width: 1200, fns: [] };
// a scene with no preview pane needs less than the full stage; the renderer
// reads Motion.height (and Motion.width, for a film frame) for the viewport
Motion.size = (h, w = Motion.width) => {
  Motion.height = h; Motion.width = w;
  document.documentElement.style.setProperty('--h', h + 'px');
  document.documentElement.style.setProperty('--w', w + 'px');
};
Motion.at = (fn) => Motion.fns.push(fn);
window.Motion = Motion;
window.seek = (t) => { for (const fn of Motion.fns) fn(t); };

export const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };

// Paths are relative to this module, not the page, so the same kit works from
// motion/scenes/ and from the copy the site serves in docs/demo/.
export async function loadFixtures() {
  return (await fetch(new URL('../fixtures.json', import.meta.url))).json();
}

// ---- card ----
export function makeCard(clip, { time, key, cjk } = {}) {
  const c = el('div', 'card');
  c.append(el('div', 'hd'), el('div', 'sel'));
  const ic = el('img', 'ic'); ic.src = new URL(`../icons/${clip.icon}-sm.png`, import.meta.url).href; c.append(ic);
  c.append(el('div', 'app', clip.app), el('div', 'time', time || ''));
  if (clip.receipt) {
    const r = el('div', 'receipt', `<div class="shop">${clip.receipt.shop}</div>`);
    clip.receipt.rows.forEach(([n, p], i) => r.append(el('div', 'row', `<span>${n}</span><span>${p}</span>`)));
    [...r.querySelectorAll('.row')].forEach((row, i) => (row.style.top = 34 + i * 13 + 'px'));
    r.append(el('div', 'rule'), el('div', 'tot', `<span>TOTAL</span><span>${clip.receipt.total}</span>`));
    c.append(r, el('div', 'scan'));
  } else if (clip.secret) {
    c.append(el('div', 'mask'));
  } else {
    c.append(el('div', 'txt' + (clip.cjk ? ' cjk' : ''), clip.lines.join('\n')));
  }
  if (clip.result) c.append(el('div', 'calc', clip.result));
  c.append(el('div', 'stat', clip.stat), el('div', 'key', key || ''), el('div', 'flash'));
  c._ = { sel: c.querySelector('.sel'), flash: c.querySelector('.flash'), time: c.querySelector('.time'), key: c.querySelector('.key'),
          stat: c.querySelector('.stat'), txt: c.querySelector('.txt'), mask: c.querySelector('.mask'), scan: c.querySelector('.scan') };
  return c;
}
// place / fade / select a card in one call
export function put(c, { x = 0, y = 0, s = 1, o = 1, sel = 0, flash = 0 }) {
  c.style.transform = `translate(${x}px, ${y}px) scale(${s})`;
  c.style.opacity = o;
  c._.sel.style.opacity = sel;
  c._.flash.style.opacity = flash;
}
export const slotX = (i) => 16 + i * 216;
export const clips = (n) => `${n} clip${n === 1 ? '' : 's'}`;

// ---- panel ----
const CHIPS = [['All', '#98989d'], ['Text', '#0a84ff'], ['Images', '#30d158'], ['Links', '#40c8e0'], ['Files', '#ff375f'], ['Colors', '#ff9f0a']];
export function buildPanel(fx, { clipIds, boardStrip = true } = {}) {
  const stage = $('#stage');
  const panel = el('div'); panel.id = 'panel';
  panel.innerHTML = `
    <div id="topbar">
      <svg id="mag" viewBox="0 0 14 14" fill="none" stroke="#98989d" stroke-width="1.5" stroke-linecap="round"><circle cx="5.5" cy="5.5" r="4.6"/><path d="M9 9l3.2 3.2"/></svg>
      <div id="searchbox"><span id="stext">Search clips</span><span id="caret" style="display:none"></span></div>
      ${CHIPS.map(([n, c], i) => `<span class="chip${i ? '' : ' on'}"><i style="background:${c}"></i>${n}</span>`).join('')}
    </div>
    <div id="strip"></div>
    <div id="cards"></div>
    <div id="pane"></div>
    <div id="footer"><span id="apps">All Apps ⌄</span><span id="count"></span></div>`;
  stage.append(panel);
  const strip = $('#strip', panel);
  if (boardStrip) {
    strip.append(el('span', 'chip on', 'All'));
    strip.append(el('span', 'chip', '<span class="pin">📌</span>Pinned<b>4</b>'));
    fx.boards.forEach((b) => strip.append(el('span', 'chip', `<i style="background:${b.color}"></i>${b.name}<b>${b.count}</b>`)));
    strip.append(el('span', 'chip plus', '+'));
  }
  const cards = clipIds.map((id, i) => {
    const clip = fx.clips[id];
    const c = makeCard(clip, { time: fx.times[i], key: `⌘${i + 1}` });
    $('#cards', panel).append(c);
    c._.id = id;
    return c;
  });
  const api = {
    panel, cards, strip,
    stext: $('#stext', panel), caret: $('#caret', panel), box: $('#searchbox', panel), count: $('#count', panel), pane: $('#pane', panel),
    chips: [...panel.querySelectorAll('#topbar .chip')], boards: [...strip.querySelectorAll('.chip')],
    height(h) { panel.style.height = h + 'px'; },
    search(text, t, blinkPhase = true) {
      // empty field shows the placeholder, a non-empty one the typed text with a caret
      const has = text.length > 0;
      api.stext.textContent = has ? text : 'Search clips';
      api.box.classList.toggle('on', has);
      api.caret.style.display = has && (!blinkPhase || Math.floor(t * 2) % 2 === 0) ? 'inline-block' : 'none';
    },
  };
  return api;
}

// ---- key caps ----
export function keycaps(parts) {
  const k = el('div'); k.id = 'keys'; $('#stage').append(k);
  const caps = parts.map((p) => { const c = el('div', 'kc' + (p.length > 2 ? ' wide' : ''), p); k.append(c); return c; });
  // show(t0, t1): rise and fade over [t0, t1]; the press dips at tp
  return (t, t0, t1, tp = (t0 + t1) / 2) => {
    const inn = prog(t, t0, t0 + 0.25, ease.out), out = 1 - prog(t, t1 - 0.25, t1);
    const dip = Math.exp(-(((t - tp) / 0.09) ** 2));
    caps.forEach((c, i) => {
      c.style.opacity = Math.min(inn, out);
      c.style.transform = `translateY(${(1 - inn) * 14 + dip * 3}px) scale(${1 - dip * 0.06})`;
    });
  };
}

export function toast(title, sub) {
  const t = el('div'); t.id = 'toast'; t.innerHTML = `<div class="t1">${title}</div><div class="t2">${sub}</div>`;
  $('#stage').append(t);
  return (t_, t0, t1) => {
    const a = Math.min(prog(t_, t0, t0 + 0.3, ease.out), 1 - prog(t_, t1 - 0.3, t1));
    t.style.opacity = a; t.style.transform = `translateY(${(1 - a) * -14}px)`;
  };
}
