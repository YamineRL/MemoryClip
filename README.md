<p align="center">
  <img src="docs/logo.png" alt="" width="128" height="128">
</p>

<h1 align="center">MemoryClip</h1>

<p align="center">Your clipboard, remembered. Locally.</p>

<p align="center"><a href="https://github.com/YamineRL/MemoryClip/actions/workflows/ci.yml"><img src="https://github.com/YamineRL/MemoryClip/actions/workflows/ci.yml/badge.svg" alt="CI"></a></p>

A local-first menu-bar clipboard manager for macOS. It keeps a history of everything you
copy and gives you keyboard-first access to it. It also notices the screenshots you take,
reads the text out of them — in 30 languages, translated into English when it is not one
you read — and turns one into a note in **[Obsidian](https://obsidian.md)** or any other
folder of Markdown files, in Apple Notes, or through a Shortcut.

**Zero network calls**: no sync, no analytics, no accounts. Clips live in a local
SwiftData store on your Mac, and the models that read, tidy and translate your screenshots
run here too. The only files MemoryClip writes anywhere else are the notes you ask for, in
the folder you chose.

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
    <td width="50%"><img src="docs/screenshots/preview.svg" alt="A JSON clip open in the preview pane, with its detection badge and JSON transform buttons"></td>
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

```sh
brew tap yaminerl/memoryclip https://github.com/YamineRL/MemoryClip
brew trust yaminerl/memoryclip
brew install --cask memoryclip
```

The tap line carries a URL because this repository *is* the tap: the cask lives in
[`Casks/memoryclip.rb`](Casks/memoryclip.rb), beside the source it installs. The trust
line is Homebrew 6, which refuses casks from third-party taps until you vouch for them —
skip it and you must name the cask in full every time, `brew upgrade` included. After
that, `brew upgrade --cask memoryclip` and `brew uninstall --cask memoryclip` work as
usual; `--zap` takes the clip history and preferences too.

**By hand**: download the `.dmg` from
[Releases](https://github.com/yaminerl/MemoryClip/releases) and drag MemoryClip to
Applications. The app is **ad-hoc signed only** — no Developer ID, no notarisation — so
Gatekeeper blocks the first launch on any Mac that did not build it. Strip the quarantine
flag, which is the one thing the cask does for you:

```sh
xattr -dr com.apple.quarantine /Applications/MemoryClip.app
```

Either way there is no Dock icon: MemoryClip is a menu-bar agent. Look for the clipboard
glyph, or press **⇧⌘V**. First launch gives you a short tour, replayable from
**Settings → About**. To start it with your Mac, turn on **Launch at login** in
**Settings → General**.

## Using it

⇧⌘V opens the panel from whichever app you are in, newest clip first, list already
focused. The menu-bar glyph gives the last five clips plus Pause Capture, Clear All
History, Settings and Quit.

| Key | Does |
| --- | --- |
| `↑` `↓` | Move through the list (`←` `→` as well, while the search field is empty) |
| `Return` | Paste the selected clip |
| `⇧Return` | Paste it as **plain text**, dropping fonts and colours |
| `⌘1`–`⌘9` | Paste any of the first nine results directly |
| `Space` | Toggle the preview pane, while the search field is empty |
| `Esc` | Close the preview, then the panel |

Pasting puts the clip on the clipboard, brings your previous app back to the front and
sends a ⌘V for you. If macOS blocks that synthetic keystroke the clip is still on the
clipboard, so ⌘V yourself and nothing is lost — see [Permissions](#permissions).

**Search** matches clip text, the text recognised inside an image, whatever the on-device
model made of it, colour values, file names and the app a clip came from. Filter chips
narrow to **All, Text, Images, Links, Files, Colors**, or to a single source app. It runs
in the database over an index and fetches a page at a time, so a store of tens of
thousands of clips opens and filters like a nearly empty one; while further pages load the
footer reads `200+ clips`. Paging bounds what is *drawn*, never what is *findable*.

**Along the way** MemoryClip badges emails, URLs, phone numbers, JWTs and JSON; evaluates
copied arithmetic, so `12*7` shows `= 84` (conservatively — `2026-08-07` is not a sum);
and offers a QR code for link clips, generated on-device. Right-click a clip to transform
it on the way out: **UPPERCASE/lowercase/Title Case**, **JSON** format or minify,
**Base64**, **URL** encoding, **sort** or **deduplicate lines**. **Add to Queue** collects
clips and **Paste N** sends the whole queue to your previous app in order.

**Vim navigation** — off by default, **Settings → Panel**. Properly modal, with the
current mode shown in the search bar, so navigation never depends on whether the search
field happens to be empty. In NORMAL:

| Key | Does |
| --- | --- |
| `j` `k` | Move down / up |
| `gg` `G` | Jump to top / bottom |
| `⌃d` `⌃u` | Half-page down / up |
| `o` | Paste (`⇧O` pastes as plain text) |
| `p` | Pin the clip |
| `dd` | Delete the clip, after a confirmation |
| `q` `⇧Q` | Add to the queue / paste the whole queue |
| `/` `i` | Fresh search / edit the existing query → INSERT |

**Housekeeping.** Pin a clip to keep it regardless of the limits; the newest 200 clips are
kept and clips older than 30 days are swept, both adjustable in **Settings → History**,
both exempting pins. Re-copying something you already have bumps it back to the top
instead of duplicating it. Pause capture from the menu bar, clear everything from the
dropdown or the panel (both confirm), and export the lot to JSON or CSV from
**Settings → History** — large histories stream to disk a clip at a time.

## Screenshots into notes

⇧⌘3, ⇧⌘4 and ⇧⌘5 write a *file* and never touch the clipboard, so a clipboard manager is
structurally blind to them. Turn on **Settings → Screenshots → Keep screenshots in
history** and MemoryClip watches the folder `screencapture` writes to instead. It is off
by default because it needs a folder macOS guards, and switching it on marks what is
already there as seen — you get the next screenshot, not the last four years of them.

A screenshot clip is **a link, not a copy**: it points at the file where it already is,
plus a small thumbnail for the row. Deleting the clip, letting it expire or clearing all
history never touches your file, and **Reveal in Finder** opens it where it lives.
Telling a screenshot from any other picture in the folder is Spotlight's job — macOS marks
what `screencapture` writes with `kMDItemIsScreenCapture`.

Text inside images is extracted on-device with Vision and folded into search, so you can
find a screenshot by words that appear *in* it; those rows read `text found`. The language
is detected rather than assumed — 30 of them, Arabic through Ukrainian.

### Notes

Any clip with text in it can become a note: right-click → **Save as Note**. First the
text goes through **Apple's on-device model**, which fixes OCR slips, rejoins wrapped
lines, drops interface chrome and writes a title, a summary and a few tags. The raw
recognition is always kept alongside it — a rewrite that drops or invents too much of the
text is thrown away in favour of it — and where Apple Intelligence is off or unavailable
the note is written from the raw recognition instead, which **Settings → Notes** says
plainly rather than showing a switch that does nothing.

A screenshot that is not in English is read in its own language and **translated on this
Mac**, the note carrying both: the text as it was on screen, and an English translation
underneath. The original is the record. Title, summary and tags come from the English, so
a note captured in Arabic is still findable in a vault you search in English.
**Settings → Notes → Translation** lists the 22 languages Apple can translate into English
on macOS 26; tick the ones you want and macOS fetches any missing assets into the store the
whole system shares. With none ticked it translates whatever this Mac already handles, and
a language whose assets are still missing gets an untranslated note that says so.

Three destinations, in **Settings → Notes**:

| Destination | What it does | Needs |
| --- | --- | --- |
| **Markdown folder** | Writes a `.md` file with YAML front matter — an Obsidian vault, or any folder of Markdown. The screenshot is copied in and embedded, so the note survives you clearing your Desktop. | A folder you pick |
| **Notes** | Creates a note in Apple Notes, in a folder you name. The screenshot goes in as a link — Notes does not accept an image through automation. | Automation permission |
| **Shortcut** | Runs a Shortcut with the note as its input, so Bear, Things, DEVONthink or anything else Shortcuts reaches can be the destination. | A Shortcut name |

Notes are written when you ask. If you would rather not ask, **Write a note for every
screenshot** does it automatically above a text threshold (80 characters by default).
A clip that already has a note reads `Screenshot · noted` and offers **Update Note** and
**Open Note**, which rewrite the same file rather than leaving a second copy beside it —
even one you moved or renamed inside your vault.

### Where notes go

Every note is a plain `.md` file named `2026-08-13 1422 Title.md` — timestamp first, so
the folder sorts chronologically and two screenshots of the same window do not collide —
with front matter above the text:

```markdown
---
title: "Deploy checklist"
created: 2026-08-13T14:22:03Z
source: "Screenshot"
tags: ["deploy", "release"]
lang: "en"
memoryclip-uuid: 5B7C2A19-3E64-4C0F-9A11-8D2F6E0B4A73
screenshot: "/Users/you/Desktop/Screenshot 2026-08-13 at 14.22.01.png"
---

# Deploy checklist

> A four-step release checklist, screenshotted from the team wiki.

![[2026-08-13 1422 Deploy checklist.png]]

1. Freeze the branch and tag it.
…

## Original text

*Exactly as recognised, before the on-device model cleaned it up.*
```

Every string is quoted on purpose: this is text read off a screen, and a heading that
happens to contain a colon would otherwise rewrite the note's own metadata. `screenshot:`
points at the **original** file even when a copy was made, `memoryclip-uuid` is what lets
a re-export find the note it wrote last time, and `created` is UTC because that is what
Dataview parses — while the file name is in your local time, because you are the one who
remembers taking the screenshot at 14:22.

Anything that reads Markdown off disk can open one. Apps differ on two things only —
whether they understand front matter, and whether they resolve wiki-style `![[embeds]]` —
and the **Copy the screenshot into the folder** switch decides which link style a note
gets: on, the picture is copied in and embedded as `![[name.png]]`; off, the note links to
it where it sits with an ordinary `[Screenshot](file://…)` link that every editor renders.

- **[Obsidian](https://obsidian.md)** — your vault, or any folder in it. Keep copying
  **on**: that is what makes the embed resolve. Front matter becomes note properties, so
  tags are tags and `lang`, `source` and `created` are Dataview-queryable.
- **[Logseq](https://logseq.com)** — the `pages` folder of your graph, attachments set to
  `assets`.
- **[iA Writer](https://ia.net/writer)**, **[Typora](https://typora.io)**,
  **[Zettlr](https://www.zettlr.com)**, VS Code — any folder they watch, with copying
  **off**; an embed they cannot resolve shows as literal `![[…]]`.
- **[DEVONthink](https://www.devontechnologies.com/apps/devonthink)** — index the folder,
  so notes stay files MemoryClip can update in place.
- **[Joplin](https://joplinapp.org)** — import it, and re-import after later edits, since
  Joplin copies notes into its own database.
- **iCloud Drive, Dropbox, Syncthing** — notes are written whole, so a half-written file
  is never what syncs.

Bear, Craft, Notion and Things keep no files: use the **Shortcut** destination. The same
guidance is in the app, under **Settings → Notes → Which apps can open these notes?**

## Privacy and security

Everything happens on this Mac — a local SwiftData store, and no network calls at all.

- **The store is owner-only**, at `~/Library/Application Support/app.memoryclip/`, the
  directory `0700` and the files `0600`.
- **Password managers are skipped.** MemoryClip honours the standard pasteboard opt-out
  markers (`org.nspasteboard.TransientType`, `AutoGeneratedType`, `ConcealedType`) and
  skips known credential apps outright.
- **Card numbers are never captured** — Luhn-validated numbers are dropped from plain
  text, rich text, OCR output and translations alike (**Settings → Privacy**).
- **Detection is app-identity based**: the source app's bundle identifier and name, never
  window titles or the screen — which is why no Screen Recording grant is needed.
- **The model and the translator are local.** Foundation Models and Translation run
  on-device with no cloud fallback; when the model is unavailable, refinement is skipped
  rather than sent anywhere.
- **Notes leave the store on purpose** — a note is a file in the folder you chose, with
  that folder's ordinary permissions rather than the `0600` clip store.
- **Optional Touch ID lock** (**Settings → Privacy**) gates the panel behind
  LocalAuthentication, redacts the menu-bar dropdown to clip kinds, and always
  re-authenticates for Export and Clear All History.

MemoryClip is built to be usable with VoiceOver: rows carry labels describing the clip's
kind, content and state, mode and selection changes are announced, and every row action is
reachable from the keyboard.

## Permissions

**None** for the core job: capture, store, search, and copy clips back. No Screen
Recording, no Input Monitoring, no network. Optional, and only with the matching feature:

- **Files and folders** — reading your screenshot folder, writing notes into the folder
  you pick. macOS guards the Desktop, Documents and Downloads and asks the first time;
  choosing the folder yourself in Settings is the other way in. Each grant is remembered
  as a *security-scoped bookmark* rather than a path, so it outlives a relaunch.
  MemoryClip never reaches into a folder you did not point it at.
- **Automation** — only when Apple Notes is your note destination.
- **Accessibility** — only to auto-paste with a synthetic ⌘V. Without it the clip still
  reaches the clipboard; the attempt can be turned off in **Settings → General**.

## Settings

Eight panes, grouped in a sidebar. ↑/↓ move between them, Tab reaches the controls, and
the window reopens wherever you left it.

| Group | Pane | Contains |
| --- | --- | --- |
| General | **General** | Launch at login, theme, auto-paste |
| General | **Shortcuts** | The global hotkey recorder (⇧⌘V is only the default), plus a full key reference |
| Clipboard | **History** | History cap, retention window, export |
| Clipboard | **Panel** | Image OCR, vim navigation |
| Clipboard | **Privacy** | Touch ID lock, sensitive-content filtering, permission notes |
| Screenshots | **Screenshots** | Screenshot capture, the folder to watch, image OCR |
| Screenshots | **Notes** | The on-device model, translation, note destination, automatic notes |
| — | **About** | Version, privacy summary, replay the welcome tour |

## Building from source

```sh
./Scripts/make_app.sh    # release build + dist/MemoryClip.app (ad-hoc signed)
./Scripts/make_dmg.sh    # the above, plus dist/MemoryClip-<version>.dmg
swift build && swift run # debug build, run from it
swift test               # 553 unit tests (benchmarks skipped)
```

`make_app.sh` regenerates `Resources/AppIcon.icns` with `swift Scripts/make_icon.swift`
if it is missing, so that only needs running when the artwork changes. Everything lands in
`dist/`, which is gitignored: **no build output is ever committed.** The benchmarks build
stores of up to 50k clips and are skipped unless `MEMORYCLIP_BENCH=1` is set — a measuring
tool rather than a regression gate.

### Cutting a release

```sh
./Scripts/publish_release.sh            # tag = v<bundle version>
DRAFT=1 ./Scripts/publish_release.sh    # draft, to eyeball first
./Scripts/update_cask.sh 0.2.48         # repair a cask that drifted
```

The script builds the DMG, tags the commit, creates the GitHub release with the `sha256`
in its notes, then points the Homebrew cask at what it just published and pushes that
one-line bump — a tap naming the previous version keeps installing the previous version.
The checksum comes from the asset GitHub serves, not the local copy in `dist/`. It refuses
to run on a dirty tree or an unpushed commit, since a published binary should correspond
to source anyone can fetch. Drafts skip the cask, their assets not being downloadable yet;
`SKIP_CASK=1` opts out. Needs the [GitHub CLI](https://cli.github.com), authenticated.

Version numbers come from `CFBundleShortVersionString` in `Resources/Info.plist`; bump it
there and the app, the DMG name, the tag and the cask all follow.

### Architecture

```
Sources/MemoryClip/
├── App/        AppKit entry, AppDelegate wiring, HotKeys, appearance, logging
├── Capture/    PasteboardWatcher, ContentParser, SensitiveFilter, TextDetector,
│               ScreenshotDetector + ScreenshotWatcher
├── Store/      ClipItem (SwiftData), ClipStore (insert/dedup/fetch, cap, retention)
├── Actions/    PasteService, TransformService, CalcEvaluator, QRService,
│               ExportService, OCRService + OCRCoordinator
├── Notes/      NoteRefiner + FoundationModelsRefiner, NoteTranslator + AppleTranslator,
│               NoteComposer, NoteSink (Markdown / Notes / Shortcut), NoteCoordinator
├── Security/   AppLockService (Touch ID gate)
├── UI/         PanelController + PanelView, ClipCardView, PreviewView, VimNavigator,
│               StatusController, SettingsWindow, Onboarding, DesignSystem
└── Support/    NSColor+Hex, FolderBookmark (security-scoped bookmarks)
```

Screenshot flow: `screencapture` writes a file → `ScreenshotWatcher` debounces the folder
event and `ScreenshotDetector` decides whether it is a screenshot →
`ClipStore.insertScreenshot` records a *reference* → thumbnails and `OCRCoordinator` read
the pixels off disk → `NoteCoordinator` translates when needed, refines under
`RefinementGuard`, and a `NoteSink` writes the note.

Paste flow: selection → `PasteService.write` puts the payload on the pasteboard → the
watcher is told to ignore its own write → the previous app is reactivated → synthetic ⌘V,
when auto-paste is on and permitted.

Scripts and packaging: `make_icon.swift` draws the icon, `make_app.sh` and `make_dmg.sh`
build the artefacts, `publish_release.sh` releases them, and `update_cask.sh` points
[`Casks/memoryclip.rb`](Casks/memoryclip.rb) — this repository doubles as the Homebrew
tap — at the result.

## Prior art

MemoryClip is inspired by [Deck](https://github.com/yuzeguitarist/Deck) — a
**clean-room implementation**, containing **no Deck code**. Where the two diverge it is
deliberate: the design notes in `DesignSystem.swift` and `ClipCardView.swift` record
which of Deck's visual choices were kept and which were not.
