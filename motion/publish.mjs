// Copy what the site and README use out of motion/ into docs/, which is all
// GitHub Pages serves:
//   out/<scene>.{mp4,webm,jpg}  -> docs/media/
//   out/<scene>.gif             -> docs/media/gif/
//   live.html, kit/, icons/, fixtures.json -> docs/demo/   (byte-for-byte; the
//   leak check fails if docs/demo/fixtures.json ever drifts from this one)
import { cp, mkdir, readdir, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const docs = join(root, '..', 'docs');
const GIF_LIMIT = 3 * 1024 * 1024;

await mkdir(join(docs, 'media', 'gif'), { recursive: true });
let failed = false;
for (const f of await readdir(join(root, 'out'))) {
  if (f.endsWith('.master.mkv')) continue;
  const src = join(root, 'out', f);
  if (f.endsWith('.gif')) {
    const { size } = await stat(src);
    if (size > GIF_LIMIT) { console.error(`${f} is ${(size / 1048576).toFixed(1)} MB, over the 3 MB README budget`); failed = true; }
    await cp(src, join(docs, 'media', 'gif', f));
  } else await cp(src, join(docs, 'media', f));
}
const demo = join(docs, 'demo');
await mkdir(demo, { recursive: true });
for (const f of ['live.html', 'kit/kit.js', 'kit/kit.css', 'fixtures.json', 'icons']) {
  await cp(join(root, f), join(demo, f), { recursive: true });
}
console.log(failed ? 'published, with GIFs over budget' : 'published to docs/media and docs/demo');
process.exit(failed ? 1 : 0);
