// The leak guard. Exits non-zero if anything a viewer can see did not come from
// fixtures.json.
//
//   1. Every scene, sampled every 0.25 s: each visible line of text must be a
//      fixture string, a typed prefix of one, or a piece of the panel's own chrome.
//   2. The published live demo (docs/demo/live.html), driven through a script of
//      keystrokes, held to the same rule.
//   3. docs/demo/fixtures.json must be byte-identical to this directory's.
//   4. No personal markers anywhere in docs/, README.md or the motion sources:
//      a home path, the account name, an email address.
import { readFile, readdir } from 'node:fs/promises';
import { homedir, userInfo } from 'node:os';
import { dirname, join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve, launch } from './kit/node.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const repo = join(root, '..');
const fx = JSON.parse(await readFile(join(root, 'fixtures.json'), 'utf8'));

// ---- what may appear
const FIXTURE = new Set();
(function walk(v) {
  if (typeof v === 'string') { FIXTURE.add(v.trim()); v.split('\n').forEach((l) => FIXTURE.add(l.trim())); }
  else if (v && typeof v === 'object') Object.entries(v).forEach(([k, x]) => (k.startsWith('_') ? null : walk(x)));
})(fx);
const CHROME = new Set([
  'All', 'Text', 'Images', 'Links', 'Files', 'Colors', 'Pinned', 'Search clips', 'Original', 'English', 'TOTAL', 'All Apps ⌄',
  '◎', '▏', '+', '📌', 'Space', 'Return', '⇧', '⌘', '⌥', '→', '←', 'V', 'T', 'S', 'P', 'No clips match',
  // the live demo's hint line, split by its <kbd>s
  'Type to search ·', 'to move ·', 'to preview · try', 'or', 'app:saf', 'type:image',
]);
const PATTERNS = [/^⌘[1-9]$/, /^\d+ clips?$/, /^\d+$/];
const fixtureList = [...FIXTURE];
function allowed(line) {
  const s = line.replace(/▏$/, '').trim();
  if (!s || CHROME.has(s) || FIXTURE.has(s) || PATTERNS.some((p) => p.test(s))) return true;
  return fixtureList.some((f) => f.startsWith(s));   // typed so far
}

// ---- what must never appear
const user = userInfo().username;
const FORBIDDEN = [
  [new RegExp(homedir().replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'), 'home directory'],
  [/\/Users\/(?!you\/)/, '/Users/ path'],
  [new RegExp(`\\b${user}\\b(?!RL)`, 'i'), `account name "${user}"`],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, 'email address'],
];
const failures = [];
const forbid = (where, text) => {
  for (const [re, what] of FORBIDDEN) if (re.test(text)) failures.push(`${where}: contains ${what}: "${text.match(re)[0]}"`);
};

// visible text lines in the stage, skipping anything faded to nothing
const VISIBLE_TEXT = `(() => {
  const out = [];
  const w = document.createTreeWalker(document.getElementById('stage'), NodeFilter.SHOW_TEXT);
  while (w.nextNode()) {
    const n = w.currentNode; let e = n.parentElement, op = 1, shown = true;
    for (let x = e; x; x = x.parentElement) {
      const cs = getComputedStyle(x);
      op *= +cs.opacity; if (cs.display === 'none' || cs.visibility === 'hidden') shown = false;
    }
    if (!shown || op < 0.02) continue;
    n.textContent.split('\\n').forEach((l) => l.trim() && out.push(l.trim()));
  }
  return out;
})()`;

const { base, close } = await serve(repo);
const browser = await launch();
const report = (where, lines) => {
  for (const l of lines) { if (!allowed(l)) failures.push(`${where}: "${l}" is not from fixtures.json`); forbid(where, l); }
};
try {
  // 1. scenes
  const scenes = (await readdir(join(root, 'scenes'))).filter((f) => f.endsWith('.html'));
  for (const f of scenes) {
    const page = await browser.newPage();
    await page.goto(`${base}/motion/scenes/${f}`);
    await page.waitForFunction('window.__ready === true', { timeout: 10000 });
    const dur = await page.evaluate('Motion.duration');
    let seen = 0;
    for (let t = 0; t <= dur; t += 0.25) {
      await page.evaluate(`seek(${t})`);
      const lines = await page.evaluate(VISIBLE_TEXT);
      seen += lines.length; report(`${f} @${t.toFixed(2)}s`, lines);
    }
    console.log(`scene ${f}: ${Math.round(dur / 0.25) + 1} samples, ${seen} text lines checked`);
    await page.close();
  }
  // 2. live demo, the published copy
  const page = await browser.newPage();
  await page.setViewport({ width: 1200, height: 720 });
  await page.goto(`${base}/docs/demo/live.html`);
  await page.waitForFunction('window.__ready === true', { timeout: 10000 });
  const steps = [[], ['ArrowRight', 'ArrowRight', ' '], [' '], [...fx.search.sentence], ['Escape'], [...'app:saf'], ['ArrowRight', ' '],
    ['Escape', 'Escape'], [...'type:image'], ['Escape'], [...'zzzz'], ['Escape'], ...Array(9).fill(['ArrowRight', ' ', ' '])];
  let n = 0;
  for (const keys of steps) {
    for (const k of keys) await page.keyboard.press(k === ' ' ? 'Space' : k);
    await new Promise((r) => setTimeout(r, 120));
    const lines = await page.evaluate(VISIBLE_TEXT); n += lines.length;
    // what this script typed is on screen too; it is not data, so let it through
    report(`live.html after [${keys.join('')}]`, lines.filter((l) => l.replace(/▏$/, '') !== 'zzzz'));
  }
  // ⌘T on the translated clip
  await page.keyboard.press('Escape');
  await page.evaluate(`dispatchEvent(new KeyboardEvent('keydown', { key: 't', metaKey: true }))`);
  report('live.html translated', await page.evaluate(VISIBLE_TEXT));
  console.log(`live demo: ${steps.length + 1} states, ${n} text lines checked`);
  await page.close();
} finally {
  await browser.close(); close();
}

// 3. the published fixtures are the same file
const a = await readFile(join(root, 'fixtures.json')), b = await readFile(join(repo, 'docs', 'demo', 'fixtures.json')).catch(() => null);
if (!b || !a.equals(b)) failures.push('docs/demo/fixtures.json differs from motion/fixtures.json — run node publish.mjs');

// 4. every text file the site, README and kit ship
const TEXT = new Set(['.html', '.js', '.mjs', '.css', '.json', '.md', '.svg', '.xml', '.atom']);
async function* files(dir) {
  for (const d of await readdir(dir, { withFileTypes: true })) {
    // this file holds the patterns themselves
    if (['node_modules', 'out', '.git', 'check-fixtures.mjs'].includes(d.name)) continue;
    const p = join(dir, d.name);
    if (d.isDirectory()) yield* files(p); else if (TEXT.has(extname(d.name))) yield p;
  }
}
let scanned = 0;
for (const dir of [join(repo, 'docs'), root]) for await (const p of files(dir)) { forbid(p.slice(repo.length + 1), await readFile(p, 'utf8')); scanned++; }
forbid('README.md', await readFile(join(repo, 'README.md'), 'utf8')); scanned++;
console.log(`files: ${scanned} scanned for personal markers`);

if (failures.length) {
  console.error(`\nFAIL — ${failures.length} problem(s):`);
  [...new Set(failures)].slice(0, 60).forEach((f) => console.error('  ' + f));
  process.exit(1);
}
console.log('\nPASS — every visible string is fixture data or panel chrome; no personal markers found.');
