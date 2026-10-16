// Render motion scenes to GIF / MP4 / WebM, one frame at a time.
//
//   node render.mjs                         every scene, default sizes
//   node render.mjs hero search             just those
//   node render.mjs hero --fps 60 --scale 2 --formats mp4     video-grade master
//
// A scene exposes window.seek(t) and Motion.duration (see kit/kit.js); this steps
// t = frame / fps and screenshots each one, so output never depends on how fast
// the machine is. Needs ffmpeg on PATH and a Chromium-family browser
// (BROWSER=/path/to/binary to override Brave).
import { mkdir, readdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve, launch } from './kit/node.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf('--' + name); return i < 0 ? dflt : args.splice(i, 2)[1]; };
const fps = +opt('fps', 30);
const scale = +opt('scale', 1);
const formats = opt('formats', 'gif,mp4,webm').split(',');
const outDir = opt('out', join(root, 'out'));
const gifWidth = +opt('gif-width', 800);
const gifFps = +opt('gif-fps', 15);

const all = (await readdir(join(root, 'scenes'))).filter((f) => f.endsWith('.html')).map((f) => f.slice(0, -5));
const scenes = args.filter((a) => !a.startsWith('--')).length ? args.filter((a) => !a.startsWith('--')) : all;

const { base, close } = await serve(root);

await mkdir(outDir, { recursive: true });
const browser = await launch();
try {
  for (const name of scenes) {
    const page = await browser.newPage();
    await page.setViewport({ width: 1200, height: 720, deviceScaleFactor: scale });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e));
    await page.goto(`${base}/scenes/${name}.html`);
    await page.waitForFunction('window.__ready === true', { timeout: 10000 }).catch(() => {
      throw new Error(`${name} never became ready: ${errors.join('; ') || 'no page error'}`);
    });
    const duration = await page.evaluate('Motion.duration');
    await page.setViewport({ width: 1200, height: await page.evaluate('Motion.height'), deviceScaleFactor: scale });
    const frames = Math.round(duration * fps);
    // frames go straight into one ffmpeg that writes the lossless master; the
    // delivery formats are re-encoded from it so each sees identical pixels
    const master = join(outDir, `${name}.master.mkv`);
    const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
      '-c:v', 'libx264rgb', '-crf', '0', '-preset', 'ultrafast', master], { stdio: ['pipe', 'ignore', 'inherit'] });
    for (let f = 0; f < frames; f++) {
      await page.evaluate(`seek(${f / fps})`);
      const png = await page.screenshot({ type: 'png' });
      if (!ff.stdin.write(png)) await new Promise((r) => ff.stdin.once('drain', r));
    }
    ff.stdin.end(); await new Promise((r) => ff.on('close', r));
    await page.close();

    const enc = (argv) => new Promise((res, rej) => {
      const p = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-i', master, ...argv], { stdio: ['ignore', 'ignore', 'inherit'] });
      p.on('close', (c) => (c ? rej(new Error('ffmpeg failed: ' + argv.join(' '))) : res()));
    });
    const out = (ext) => join(outDir, `${name}.${ext}`);
    if (formats.includes('gif')) {
      const vf = `fps=${gifFps},scale=${gifWidth}:-1:flags=lanczos`;
      await enc(['-vf', `${vf},split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`, '-loop', '0', out('gif')]);
    }
    if (formats.includes('mp4')) await enc(['-c:v', 'libx264', '-crf', '20', '-preset', 'slow', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', out('mp4')]);
    if (formats.includes('webm')) await enc(['-c:v', 'libvpx-vp9', '-crf', '32', '-b:v', '0', '-pix_fmt', 'yuv420p', '-an', out('webm')]);
    // the poster the site shows before the video loads; frame 0 is an empty
    // desktop in every scene, so take one from the middle where the panel is up
    const enc2 = (argv) => new Promise((res, rej) => {
      const p = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-ss', String(duration * 0.6), '-i', master, ...argv], { stdio: ['ignore', 'ignore', 'inherit'] });
      p.on('close', (c) => (c ? rej(new Error('poster failed')) : res()));
    });
    await enc2(['-frames:v', '1', '-q:v', '3', out('jpg')]);
    console.log(`${name}: ${frames} frames @ ${fps}fps, ${scale}x -> ${formats.join(', ')}`);
  }
} finally {
  await browser.close(); close();
}
