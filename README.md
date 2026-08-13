# MemoryClip

A local-first, privacy-focused menu-bar clipboard manager for macOS. MemoryClip keeps
a history of everything you copy and gives you keyboard-first access to it.
**Zero network calls**: no sync, no analytics, no accounts. All data stays in a local
SwiftData store on your Mac — including the text read out of your screenshots and the
on-device model that tidies it up.

Requires macOS 26 on Apple silicon.

## Screenshots

<table>
  <tr>
    <td colspan="2"><img src="docs/screenshots/panel.png" alt="The clipboard panel: search field, filter chips and a row of clip cards with keyboard shortcuts"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><em>The panel — <strong>⇧⌘V</strong> from anywhere.</em></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/preview.svg" alt="A JSON clip open in the preview pane, with detection badges and transform actions"></td>
    <td width="50%"><img src="docs/screenshots/menu-bar.svg" alt="The menu-bar dropdown listing recent clips and app commands"></td>
  </tr>
  <tr>
    <td align="center"><em>Preview pane — <code>Space</code> to toggle.</em></td>
    <td align="center"><em>Menu-bar dropdown — the last five clips.</em></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="docs/screenshots/settings.svg" alt="The Settings window showing its sidebar of preference panes" width="620"></td>
  </tr>
  <tr>
    <td colspan="2" align="center"><em>Settings — eight panes behind a sidebar, no Dock icon anywhere.</em></td>
  </tr>
</table>

## Install

Download the latest `MemoryClip-<version>.dmg` from
[**Releases**](https://github.com/yaminerl/MemoryClip/releases), open it, and drag
MemoryClip to Applications. This repository holds the source; each release carries
the built disk image as an attachment.

MemoryClip is **ad-hoc signed only** — no Developer ID, no notarisation — so
Gatekeeper blocks the first launch on any Mac that did not build it. Right-click the
app → **Open** and confirm, or strip the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/MemoryClip.app
```

It is a menu-bar agent (`LSUIElement`) with no Dock icon: look for the clipboard
glyph in the menu bar, or press **⇧⌘V** to open the panel. Prefer to build it
yourself? See [Building from source](#building-from-source).

## Getting started

MemoryClip is a menu-bar agent: there is no Dock icon and no window until you ask for
one. On first launch you get a short welcome tour covering the panel hotkey, pasting,
the menu-bar dropdown, and the local-only privacy model. It appears once; you can
replay it any time from **Settings → About → Show Introduction Again**.

From then on, MemoryClip captures every copy in the background. Two ways in:

- Press **⇧⌘V** to open the panel from whichever app you are in.
- Click the **clipboard glyph** in the menu bar for the five most recent clips, plus
  Open MemoryClip, Pause, Clear All History, Settings and Quit.

To have it start with your Mac, turn on **Launch at login** in **Settings → General**.

## Pasting a clip

Open the panel and the list is already focused, newest clip first. Everything is
reachable from the keyboard:

| Key | Does |
| --- | --- |
| `↑` `↓` | Move through the list |
| `Return` | Paste the selected clip |
| `⇧Return` | Paste it as **plain text**, dropping fonts and colours |
| `⌘1`–`⌘9` | Paste any of the first nine results directly |
| `Space` | Toggle the preview pane |
| `Esc` | Close the panel |

Pasting puts the clip on the clipboard, brings your previous app back to the front,
and sends a ⌘V for you. If macOS blocks that synthetic keystroke the clip is still on
the clipboard, so ⌘V yourself and nothing is lost — see [Permissions](#permissions)
for why, and **Settings → General** to turn the attempt off entirely.

## Finding a clip

Type in the search field to match across clip text, colour values, file names and the
name of the app a clip came from. Alongside it are filter chips — **All, Text, Images,
Links, Files, Colors** — and you can narrow to a single source app ("copied from
Safari").

Search stays fast on a large history because the database does the work, not an
in-memory list. Results arrive in pages of 200, pulling in more as you reach the end of
the list, so while further pages are still loading the footer reads `200+ clips` rather
than an exact count. Paging bounds what is *drawn*, never what is *findable*.

**Screenshots are searchable too.** Text inside image clips is extracted on-device with
the Vision framework, in the background, and folded into search: copy a screenshot,
then find it later by typing words that appear *in* the picture. Those rows carry a
small `Text` badge. Toggle in **Settings → Panel** (on by default).

## Previewing, and what MemoryClip notices

Press `Space` to open the preview pane, which renders the full clip — text, JSON, rich
text or image — rather than the truncated row. MemoryClip also recognises a few things
as they go past:

- **Type badges** for email addresses, URLs, phone numbers, JWTs and JSON, shown on the
  row and in the preview.
- **Instant arithmetic** — copy `12*7` and the row shows `= 84`. The parser is
  self-contained and deliberately conservative, so date-like strings such as
  `2026-08-07` are never mistaken for sums.
- **QR codes for links** — open a link clip's QR code in a floating window, with a Copy
  Link button. Generated on-device with CoreImage.

## Transforming text

Right-click a clip, or use the preview's actions, to rewrite it on the way out:

- **UPPERCASE**, **lowercase**, **Title Case**
- **JSON** format or minify
- **Base64** encode or decode
- **URL** encode or decode
- **Sort lines** or **deduplicate lines**

## Pasting several clips in a row

Queue mode collects clips and pastes them in order. Add them with right-click →
**Add to Queue** (or `q` in vim mode); the footer then shows **Paste N**, which sends
the whole queue to your previous app in the order you marked them, with a short gap
between each.

## Vim navigation

Off by default; enable it in **Settings → Panel**. It is properly modal, and the
current mode shows as a badge in the search bar, so navigation keys never depend on
whether the search field happens to be empty.

In **NORMAL**, letters navigate:

| Key | Does |
| --- | --- |
| `j` `k` | Move down / up |
| `gg` `G` | Jump to top / bottom |
| `⌃d` `⌃u` | Half-page down / up |
| `o` | Paste (`⇧O` pastes as plain text) |
| `p` | Pin the clip |
| `dd` | Delete the clip, after a confirmation |
| `q` | Add the clip to the queue |
| `⇧Q` | Paste the whole queue |
| `/` | Start a fresh search → INSERT |
| `i` | Edit the existing query → INSERT |

In **INSERT**, typing goes to the search field as usual. `Esc` abandons a half-typed
sequence such as a lone `g`, then leaves INSERT for NORMAL.

## Screenshots, and turning them into notes

⇧⌘3 and ⇧⌘4 save a *file* and never touch the clipboard, so a clipboard manager cannot
see them. Turn on **Settings → Screenshots → Keep screenshots in history** and MemoryClip
watches wherever macOS saves them (it reads that from your system settings; pick a
different folder if you like) and adds each new one to your history.

**A link, not a copy.** The clip points at the screenshot where it already is, plus a
small thumbnail for the row. A day of retina screenshots costs a few kilobytes of
history rather than a few hundred megabytes — and **deleting a clip, letting it expire,
or clearing all history never deletes your file.** Pasting one hands over the file
itself, exactly as copying it in Finder would.

Screenshots go through the same on-device text extraction as image clips, so you can
find one by what it says.

### Notes

Any clip with text in it can become a note: right-click and choose **Save as Note**.
Before it is written, the extracted text is passed through **Apple's on-device model**,
which fixes the usual OCR slips, rejoins wrapped lines, drops interface chrome, and
gives the note a title, a summary and a few tags. This happens on your Mac — nothing is
uploaded, and it needs no account and no permission.

The raw extracted text is always kept alongside the tidied version, in the clip and in
the note. Nothing the model writes replaces what was actually on your screen, and a
rewrite that drops or invents too much of the text is thrown away in favour of the raw
recognition.

Three destinations, in **Settings → Notes**:

| Destination | What it does | Needs |
| --- | --- | --- |
| **Markdown folder** | Writes a `.md` file with YAML front matter — an Obsidian vault, or any folder of Markdown. The screenshot is copied in and embedded, so the note survives you clearing your Desktop. | A folder you pick |
| **Notes** | Creates a note in Apple Notes, in a folder you name. The screenshot goes in as a link — Notes does not accept an image through automation. | Automation permission |
| **Shortcut** | Runs a Shortcut with the note as its input, so Bear, Things, DEVONthink or anything else Shortcuts reaches can be the destination. | A Shortcut name |

Notes are written **when you ask for one**. If you would rather not ask, turn on
**Write a note for every screenshot** and set how much text a screenshot needs before it
earns one — a busy day of screenshots is otherwise a busy day of notes.

## Keeping your history tidy

- **Pin** a clip to keep it regardless of the limits below; **delete** individual clips
  from the row actions or with `dd`.
- **History cap** — the newest 200 clips are kept by default, pinned clips exempt.
  Change it in **Settings → History**.
- **Retention** — clips older than 30 days are swept by default. Also
  **Settings → History**.
- **Pause capture** from the menu bar when you would rather it did not watch; the icon
  switches to a pause glyph while paused.
- **Clear All History** from the menu-bar dropdown, or the nuke-all button in the panel.
  Both confirm first.

Re-copying something you already have does not create a duplicate — it bumps the
existing clip back to the top.

## Exporting your history

Export to **JSON** or **CSV** from the menu-bar dropdown. Large histories stream to
disk one clip at a time rather than being assembled in memory first. With the Touch ID
lock on, exporting always re-authenticates.

## Privacy and security

Everything happens on this Mac. Clips live in a local SwiftData store, and MemoryClip
makes no network calls at all — no sync, no accounts, no analytics.

- **The store is owner-only.** It sits at
  `~/Library/Application Support/app.memoryclip/MemoryClip.store`, with the
  directory at `0700` and the store files at `0600`, so no other local account can read
  your clip history.
- **Password managers are skipped.** MemoryClip respects the standard pasteboard opt-out
  markers (`org.nspasteboard.TransientType`, `AutoGeneratedType`, `ConcealedType`), and
  skips captures from known credential apps outright.
- **Card numbers are never captured.** Luhn-validated card numbers are dropped from
  plain text, from rich text, and from text extracted out of images by OCR. Toggle in
  **Settings → Privacy**.
- **Detection is app-identity based** — MemoryClip matches on the source app's bundle
  identifier and name, and never reads window titles or the screen. That is why it needs
  no Screen Recording or Accessibility permission to do any of this.
- **Screenshots are referenced, not copied.** A screenshot clip holds the path to your
  file and a thumbnail. MemoryClip never moves, rewrites or deletes the file — removing
  the clip removes only the clip.
- **The local model is local.** Text cleanup uses Apple's on-device model through the
  Foundation Models framework. There is no cloud fallback, no request leaves the
  machine, and refinement is skipped entirely when the model is unavailable — the raw
  extracted text is used instead.
- **Notes leave the store on purpose.** A note is a file in the folder you chose, with
  that folder's ordinary permissions — not the `0600` clip store. Card numbers are
  dropped from refined text before it can be written, but everything else in a note is
  as readable as any other document you own.
- **Optional Touch ID lock** (**Settings → Privacy**, off by default) gates the panel
  behind LocalAuthentication, with passcode fallback. With it on, the menu-bar dropdown
  redacts clip previews to their kind ("Text clip", "Link") and pasting from it
  authenticates. One successful unlock covers the panel and the dropdown for a short
  window, but **Export** and **Clear All History** always re-authenticate.

MemoryClip is built to be usable with VoiceOver: clip rows carry labels describing the
clip's kind, content and state, selection changes and mode switches are announced, and
every row action — pin, delete, queue, QR, transforms — is reachable from the keyboard.

## Permissions

MemoryClip requires **no permissions** to do its core job: capture, store, search, and copy
clips back to the clipboard. Nothing else is requested: no Screen Recording, no
Input Monitoring, no network. The Touch ID lock (optional, off by default) uses the
system's built-in LocalAuthentication prompt and needs no grant of its own.

Optional, and only if you use the matching feature:

- **Files and folders** — watching your screenshot folder, and writing notes into the
  folder you pick. Both folders are chosen in a standard open panel, which is what
  grants the access; MemoryClip never reaches into a folder you did not choose.
- **Automation (Notes)** — only when you set Notes as your note destination. macOS asks
  the first time. Every other destination needs no permission at all.

Optional: if you grant MemoryClip **Accessibility** access (System Settings → Privacy &
Security → Accessibility), it will also *auto-paste* the selected clip into your
previous app by posting a synthetic ⌘V. Without the grant, macOS may drop that
synthetic keystroke — the clip is still placed on the clipboard, so you just paste
manually with ⌘V. (The "Auto-paste" toggle in Settings lets you disable the attempt
entirely.)

## Settings

Eight panes, grouped in a sidebar:

| Group | Pane | Contains |
| --- | --- | --- |
| General | **General** | Launch at login, auto-paste |
| General | **Shortcuts** | The global hotkey recorder, plus a full key reference |
| Clipboard | **History** | History cap, retention window |
| Clipboard | **Panel** | Image OCR, vim navigation |
| Clipboard | **Privacy** | Touch ID lock, sensitive-content filtering, permission notes |
| Screenshots | **Screenshots** | Screenshot capture, the folder to watch |
| Screenshots | **Notes** | The on-device model, note destination, automatic notes |
| — | **About** | Version, privacy summary, replay the welcome tour |

↑/↓ move between panes from the keyboard, Tab reaches the controls in the pane, and the
window reopens on whichever pane you left it on.

The panel hotkey is rebindable from **Shortcuts** — ⇧⌘V is only the default.

## With a large history

MemoryClip is built to stay quick with a real history, not just a demo-sized one:

- **Opening the panel and typing in it is instant regardless of how much history you
  have.** Search and filtering run in the database over an index, and the list fetches
  only the page it is showing, so a store with tens of thousands of clips opens and
  filters as fast as a nearly empty one.
- **Image clips do not cost memory just by being in the list.** Rows draw from a small
  thumbnail, so scrolling past hundreds of screenshots does not pull hundreds of
  megabytes into memory. Only the clip you actually open reads its full image.
- **Every ⌘C costs the same** whether your cap is 200 or 5000 — trimming happens in the
  database rather than by loading old clips.
- **Launch is not held up by housekeeping.** Retention sweeps, cap enforcement and image
  processing start a couple of seconds after the menu bar is up, so the app is usable
  immediately even on a big store.
- **Text extraction runs in bounded bursts**, several images at a time with pauses, so a
  backlog of screenshots is worked through without taking the machine over.

## Building from source

```sh
swift Scripts/make_icon.swift   # regenerate Resources/AppIcon.icns (committed; rarely needed)
./Scripts/make_app.sh           # release build + dist/MemoryClip.app (ad-hoc signed)
./Scripts/make_dmg.sh           # the above, plus dist/MemoryClip-<version>.dmg
open dist/MemoryClip.app
```

`make_app.sh` generates the icon itself if `Resources/AppIcon.icns` is missing, so
`make_icon.swift` only needs running when the artwork changes.

Everything lands in `dist/`, which is gitignored: **no build output is ever committed.**
The DMG reaches users through Releases instead.

### Cutting a release

```sh
./Scripts/publish_release.sh            # tag = v<bundle version>
./Scripts/publish_release.sh v0.2.0     # explicit tag
DRAFT=1 ./Scripts/publish_release.sh    # draft, to eyeball first
```

The script builds the DMG, tags the commit, creates the GitHub release, and attaches the
disk image with its `sha256` in the notes. It refuses to run on a dirty tree or on a
commit that has not been pushed — a published binary should always correspond to source
anyone can fetch. Needs the [GitHub CLI](https://cli.github.com), authenticated with
`gh auth login`.

Version numbers come from `CFBundleShortVersionString` in `Resources/Info.plist`;
bump it there and the app, the DMG name and the tag all follow.

### Develop and test

```sh
swift build   # debug build
swift run     # run from the debug build
swift test    # unit tests (store, parser, transforms, detection, calc, QR,
              # sensitive filter, export, OCR, vim keys, settings support,
              # onboarding flow, search predicate, thumbnails, maintenance
              # scheduling, store rename migration — 384 tests)

MEMORYCLIP_BENCH=1 swift test    # the above plus the benchmarks (slow)
```

The benchmarks (`PerformanceBenchmarks`, `PanelQueryBenchmarks`,
`OCRPipelineBenchmarks`, plus a few elsewhere) are skipped unless `MEMORYCLIP_BENCH=1`
is set: they build stores of up to 50k clips and take several minutes. They
mostly report timings and memory rather than asserting fixed thresholds — a
measuring tool rather than a regression gate.

### Architecture

```
Sources/MemoryClip/
├── App/            MemoryClipApp (SwiftUI entry), AppDelegate (wiring), HotKeys, Log
├── Capture/        PasteboardWatcher (changeCount polling), ContentParser (type
│                   detection + SHA-256 hashing), CapturedClip (parsed payload),
│                   SensitiveFilter (card numbers + credential apps),
│                   TextDetector (email/URL/phone/JWT/JSON badges),
│                   ScreenshotDetector (where screenshots land, and what is one),
│                   ScreenshotWatcher (folder watch → referenced clips)
├── Store/          ClipItem (SwiftData model), ClipStore (insert/dedup/fetch,
│                   cap & retention enforcement)
├── Actions/        PasteService (writes clip to pasteboard, posts ⌘V via CGEvent),
│                   TransformService (text transforms), CalcEvaluator (instant
│                   arithmetic), QRService (CoreImage QR), ExportService (JSON/CSV),
│                   OCRService + OCRCoordinator (Vision text extraction)
├── Notes/          NoteRefiner (protocol, passthrough, hallucination guard) +
│                   FoundationModelsRefiner (on-device cleanup), NoteDraft,
│                   NoteComposer (Markdown/HTML/file names), NoteSink +
│                   MarkdownVaultSink / NotesAppSink / ShortcutSink,
│                   NoteCoordinator (refinement drain + export), NoteSettings
├── Security/       AppLockService (optional Touch ID / passcode gate)
├── UI/             PanelController + PanelView (search, smart filters,
│                   keyboard-first list), ClipRowView, PreviewView (Space-toggle
│                   preview pane), QRWindowController, StatusController (menu-bar
│                   dropdown + export), SettingsView (sidebar of eight preference panes) +
│                   SettingsSupport (version info, shortcut reference),
│                   OnboardingController + OnboardingView (first-run tour)
└── Support/        NSColor+Hex, FolderBookmark (user-chosen folders, kept)

Resources/Info.plist    LSUIElement app metadata (bundle id, version, icon name)
Resources/AppIcon.icns  app icon, generated by Scripts/make_icon.swift (committed)
Scripts/make_icon.swift draws the icon set → Resources/AppIcon.icns
Scripts/make_app.sh     release build → dist/MemoryClip.app (ad-hoc signed)
Scripts/make_dmg.sh     make_app.sh + drag-to-install dist/MemoryClip-<version>.dmg
Scripts/publish_release.sh  tag + GitHub release with the DMG attached
```

Screenshot flow: `screencapture` writes a file → `ScreenshotWatcher` debounces the
folder event, waits for the file to stop growing and checks it is a screenshot →
`ClipStore.insertScreenshot` records a *reference* → the thumbnail backfill and
`OCRCoordinator` read the pixels straight off disk → `NoteCoordinator` refines the
recognised text with the on-device model → a `NoteSink` writes the note, on request or
automatically.

Paste flow: panel/dropdown selection → `PasteService.write` puts the payload on the
general pasteboard → watcher is told to ignore its own write → previous app is
reactivated → synthetic ⌘V (when auto-paste is on and permitted).

## Prior art

MemoryClip is inspired by [Deck](https://github.com/yuzeguitarist/Deck) — a
**clean-room implementation**, containing **no Deck code**. Where the two diverge it is
deliberate: the design notes in `DesignSystem.swift` and `ClipCardView.swift` record
which of Deck's visual choices were kept and which were not.
