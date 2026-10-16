// Cinema kit: what a longer film needs on top of kit.js. A camera over a world
// layer, CSS-style bezier curves, keyframe tracks and masked text reveals. Same
// rule as the kit: every function here is a pure function of t.
import { clamp, lerp } from './kit.js';

// cubic-bezier(x1, y1, x2, y2), solved by bisection so it is exact and the same
// on every machine
export function bezier(x1, y1, x2, y2) {
  const at = (a, b, u) => 3 * a * u * (1 - u) ** 2 + 3 * b * u * u * (1 - u) + u ** 3;
  return (k) => {
    if (k <= 0) return 0;
    if (k >= 1) return 1;
    let lo = 0, hi = 1;
    for (let i = 0; i < 30; i++) { const m = (lo + hi) / 2; if (at(x1, x2, m) < k) lo = m; else hi = m; }
    return at(y1, y2, (lo + hi) / 2);
  };
}
export const curve = {
  // arrives fast, settles long: the default for anything entering
  out: bezier(0.16, 1, 0.3, 1),
  // a camera move with weight at both ends
  move: bezier(0.7, 0, 0.18, 1),
  // gentle both ways, for drifts
  drift: bezier(0.45, 0, 0.55, 1),
  // leaving: starts slow, does not linger
  in: bezier(0.6, 0, 0.9, 0.4),
};
export const prog = (t, t0, t1, e = curve.out) => e(clamp((t - t0) / (t1 - t0)));

// A keyframe track: [[t, value], [t, value, curve], ...]. Between two keys the
// value moves with the later key's curve; before the first and after the last it
// holds. Values are numbers or flat objects of numbers.
export function track(t, keys) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [t1, b, e = curve.move] = keys[i];
    if (t <= t1) {
      const [t0, a] = keys[i - 1];
      const k = e(clamp((t - t0) / (t1 - t0 || 1)));
      if (typeof a === 'number') return lerp(a, b, k);
      const o = {};
      for (const key in a) o[key] = lerp(a[key], b[key], k);
      return o;
    }
  }
  return keys[keys.length - 1][1];
}

// A camera looking at point (x, y) of `world` at scale s, pitched rx, yawed ry
// and rolled rz degrees about that point. The frame is w × h; the parent's
// perspective gives the depth. A world whose content is laid out at CSS zoom z
// is scaled back down by the same z: Chrome rasterises a layer in 3D at about
// its own size, so the content has to be big enough to only ever be shrunk.
export function camera(world, w, h, z = 1) {
  world.style.transformOrigin = '0 0';
  return ({ x, y, s, rx = 0, ry = 0, rz = 0 }) => {
    world.style.transform = `translate(${w / 2}px, ${h / 2}px) rotateX(${rx}deg) rotateY(${ry}deg) rotateZ(${rz}deg) scale(${s / z}) translate(${-x * z}px, ${-y * z}px)`;
  };
}

// Text that rises into a line-high mask and leaves upward: type moving as one
// designed object, not letter by letter.
export function line(parent, text, cls) {
  const m = document.createElement('div'); m.className = 'line ' + (cls || '');
  const i = document.createElement('div'); i.textContent = text; m.append(i); parent.append(m);
  return (t, t0, t1, rise = 0.7) => {
    const a = prog(t, t0, t0 + rise), b = prog(t, t1 - 0.45, t1, curve.in);
    m.style.opacity = t < t0 || t > t1 ? 0 : 1;
    i.style.transform = `translateY(${(1 - a) * 105 - b * 40}%)`;
    i.style.opacity = Math.min(a * 1.4, 1 - b);
  };
}
