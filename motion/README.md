# motion: drawn demos of the panel

The GIFs in the README and the videos on the site are not screen recordings. Each is
an HTML page that draws the panel with the app's own measurements and colours, and
is rendered frame by frame. The real panel can't be filmed for a public repo without
filming someone's clipboard; this one has nothing on it but [`fixtures.json`](fixtures.json).

```
motion/
├── fixtures.json        every string any scene shows: clips, times, search text
├── kit/kit.css          the panel: tokens, cards, preview pane, keycaps, toasts
├── kit/kit.js           buildPanel(), makeCard(), easing, typed(), Motion.at()
├── kit/node.mjs         static server + headless browser, shared by the scripts
├── scenes/*.html        one scene per file: hero, search, note, pinboards, secret
├── live.html            the same panel driven by the keyboard (the site's demo)
├── icons/               app icons at card size
├── render.mjs           scenes → out/<scene>.{master.mkv,mp4,webm,gif,jpg}
├── publish.mjs          out/ → docs/media/, and live.html + kit → docs/demo/
└── check-fixtures.mjs   the leak guard
```

## Render

Needs Node 20+, `ffmpeg` on `PATH`, and a Chromium-family browser. It uses Brave at
its default path; point `BROWSER` at another binary (Chrome, Chromium, Edge) to switch.

```sh
cd motion
npm install                 # puppeteer-core only; it drives the browser you have
node render.mjs             # every scene → out/
node render.mjs hero search # just those
node check-fixtures.mjs     # must print PASS
node publish.mjs            # → docs/media/, docs/media/gif/, docs/demo/
```

`publish.mjs` refuses a GIF over 3 MB, so the README stays light. Rendering is
deterministic: a scene is a pure function of time, so the same commit gives the same
frames on any machine, at any speed.

| Flag | Default | |
| --- | --- | --- |
| `--fps` | `30` | frames per second sampled from the scene |
| `--scale` | `2` | device pixel ratio: Retina-sharp frames, so text stays readable |
| `--formats` | `gif,mp4,webm` | which deliveries to encode from the master |
| `--gif-width` / `--gif-fps` | `1600` / `15` | 2x the ~800 px the README shows it at; the videos are not downscaled |
| `--out` | `out/` | where everything lands |

## A master for a motion-design edit

```sh
node render.mjs --fps 60 --formats mp4
```

Every render writes `out/<scene>.master.mkv` first: lossless RGB (`libx264rgb -crf 0`),
which Final Cut, Premiere, DaVinci Resolve and After Effects all import. At
`--fps 60` that is a 2400 px wide, 60 fps source with no compression
artefacts: cut it, grade it, slow it down. The MP4 next to it is for a quick look.
Masters are big and stay out of git (`out/` is ignored).

For a different frame, change the scene's height (`Motion.size(…)`) or the viewport
width in `render.mjs`; for a transparent background, drop the wallpaper in `kit.css`
and render PNGs instead of piping to ffmpeg.

## Add a scene

1. Put any new text in `fixtures.json` first. A scene never writes a string of its own.
2. Copy the smallest existing scene (`secret.html`) to `scenes/<name>.html`.
3. Set `Motion.duration` and `Motion.size(height)`, build with
   `buildPanel(fx, { clipIds: [...] })`, and describe the motion inside
   `Motion.at((t) => { ... })` using `prog(t, start, end, ease.out)` and `lerp`.
   No timers, no `requestAnimationFrame`, no CSS transitions: whatever is on screen
   must follow from `t` alone, or frames will differ between runs.
4. End with `window.__ready = true;`.
5. Preview it: `node -e "import('./kit/node.mjs').then(async m => console.log((await m.serve('.')).base))"`,
   open `/scenes/<name>.html`, and call `seek(2.5)` in the console.
6. `node render.mjs <name>`, then `node check-fixtures.mjs`.

## The fixtures-only rule

`check-fixtures.mjs` is the gate, and it exits non-zero on any failure:

- It loads every scene, seeks through it every 0.25 s and reads each visible line of
  text. Every line must be a string in `fixtures.json`, a prefix of one (text being
  typed), or one of a short list of panel chrome (`All`, `Text`, `Search clips`, `⌘1`…).
- It drives the published `docs/demo/live.html` through a script of keystrokes and holds
  what it shows to the same rule.
- It checks that `docs/demo/fixtures.json` is byte-for-byte the file here.
- It scans `docs/`, this directory and the README for a home-directory path, the
  account name and email addresses.

Panel chrome is listed in `CHROME` at the top of the script. Add to it only words the
real app shows to everyone, never data.
