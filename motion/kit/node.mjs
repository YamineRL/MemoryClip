// What render.mjs and check-fixtures.mjs share: a static server (scenes fetch
// fixtures.json, which file:// URLs cannot) and the headless browser.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, sep } from 'node:path';
import puppeteer from 'puppeteer-core';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.webm': 'video/webm', '.gif': 'image/gif' };

export async function serve(root) {
  const server = createServer(async (req, res) => {
    try {
      let path = join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
      if (path !== root && !path.startsWith(root + sep)) throw new Error('outside root');
      if (path.endsWith(sep)) path = join(path, 'index.html');
      res.setHeader('content-type', MIME[extname(path)] || 'application/octet-stream');
      res.end(await readFile(path));
    } catch { res.statusCode = 404; res.end(); }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { base: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

export const launch = () => puppeteer.launch({
  executablePath: process.env.BROWSER || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  headless: true,
  args: ['--hide-scrollbars', '--force-color-profile=srgb'],
});
