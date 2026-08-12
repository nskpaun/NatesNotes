# Nate's Notes

A native macOS note-taking app: markdown that formats itself as you type, and a
hand-drawn diagram canvas embedded right in the page.

Midnight-navy, editorial serif, and one accent colour that follows your working
mode — cool blue for **Chill**, warm amber for **Locked-In**. Switching modes
(`⇧⌘M`, or the chip in the title bar) re-tints the whole app, and Locked-In
lights a slow comet around the window edge and along the dividers.

Written in Swift with SwiftUI for the chrome and AppKit/TextKit for the two
things that had to be built from scratch — the live-preview editor and the
sketch canvas.

```bash
./build.sh run      # build NatesNotes.app and launch it
./build.sh          # release build only
./build.sh debug    # debug build
```

Requires macOS 14+ and an Xcode toolchain. No dependencies.

The app icon is generated from `Resources/AppIcon-source.png`. The artwork sits
on an opaque black field, so it can't ship as-is — this finds the icon body,
re-lays it out on Apple's grid (an 824pt body in a 1024pt canvas) and clips it
to the system squircle so the corners are transparent:

```bash
swift Tools/make-icon.swift Resources/AppIcon-source.png /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

`build.sh` copies the resulting `.icns` into the bundle.

## Writing

The buffer always holds plain markdown. Nothing is rewritten behind your back —
formatting comes entirely from how it's drawn, and the syntax characters
collapse to zero width until your caret lands on their line, then reappear so
you can edit them.

| | |
|---|---|
| Headings | `# `, `## `, `### ` — sized, weighted, spaced |
| Emphasis | `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `==highlight==` |
| Lists | `- ` bullets with real glyphs, `1. ` ordered, `Tab` / `⇧Tab` to nest |
| To-dos | `- [ ] ` renders a checkbox — click it to toggle |
| Quotes | `> ` gets a bar and a lighter voice |
| Code | ` ``` ` fences become a padded slab |
| Dividers | `---` draws a rule |
| Links | `[label](url)` collapses to just the label |

`Return` continues the list you're in; pressing it on an empty item ends the
list instead of extending it.

Type `/` for the block menu — headings, lists, to-dos, quotes, dividers, code,
tables, links and drawings, filtered as you type.

### Shortcuts

`⌘K` command palette · `⇧⌘M` switch mode · `⌘\` toggle sidebar ·
`⌘N` new note · `⇧⌘D` insert drawing · `⌘B` bold · `⌘I` italic · `⇧⌘E` code ·
`⇧⌘X` strikethrough · `⇧⌘H` highlight · `⌥⌘1/2/3` headings · `⌥⌘0` body ·
`⇧⌘8` bullets · `⇧⌘9` to-do · `⇧⌘'` quote

## Motion

Animation is used to explain, not decorate:

- **The sketch modal grows out of the card you clicked.** The panel morphs from
  that exact rectangle to full size, so you never lose track of what you opened.
- **Drawings draw themselves.** As the modal expands, every shape is re-inked
  stroke by stroke — outlines trim along their real path length, fills come up
  underneath, and the pen flows between shapes on overlapping windows.
- **The chrome arrives in order** — toolbar, then properties, then the zoom and
  history islands, each tool button popping in on a short stagger.
- **Locked-In mode is alive**: a rotating conic sweep traces the window border
  and comets run the sidebar, title bar and status bar hairlines.
- **⌘K springs open** with rows rising on a stagger and a selection highlight
  that slides between them rather than cutting.
- Note switches cross-fade and lift; sidebar rows, buttons and pills all have
  press and hover states.

All timing lives in one place (`Motion` in `Theme.swift`) so the whole app moves
with the same character.

## Drawing

`⇧⌘D`, or `/drawing`, drops a canvas into the note. Everything is rendered with
a seeded hand-drawn wobble — the same shape always redraws identically, so the
canvas doesn't shimmer while you pan.

Rectangles, diamonds, ellipses, arrows, lines, freehand ink and text, each with
stroke colour, fill (none / hachure / cross-hatch / solid), stroke width and
style, sloppiness, sharp or round corners, and opacity.

- Tools: `1`–`0`, or `V R O D A L P T E H`
- `⇧` constrains to squares and 15° angles
- Drag the handles to resize; straight lines get endpoint handles
- `⌘Z` / `⇧⌘Z` undo · `⌘D` duplicate · `⌘C`/`⌘V` copy · `⌫` delete ·
  `⌘]` / `⌘[` reorder · arrows nudge (`⇧` for 10pt)
- Scroll to pan, `⌘`-scroll or pinch to zoom, space-drag to pan

Click any drawing in a note to reopen it.

## Where your notes live

`~/Documents/NatesNotes/` — one `.md` file per note with a small YAML front
matter block, plus a `.drawings.json` sidecar when a note contains sketches.
Plain files, no database. The folder button at the bottom of the sidebar opens
it in Finder.

## Syncing across devices

Nate's Notes talks to a Personal File Sync server. Click the status pill at the
bottom of the sidebar, paste a one-time pairing code, and this Mac starts
syncing. Notes and drawings become individual canonical-JSON documents in an
app-owned space — no database is ever uploaded.

The design decisions, wire format and conflict policy are written up in
[docs/SYNC.md](docs/SYNC.md). In short:

- Every local edit lands in a **durable outbox** before any network work, so
  offline edits survive a crash or a quit and send later.
- Content is **content-addressed**; uploads are resumable (tus) and downloads
  are rejected unless the byte count and SHA-256 both check out.
- Conflicts **never overwrite**. A three-way merge handles independent changes;
  when the same text diverges, this device keeps its version and the other one
  is preserved as a conflict copy that syncs back to every device.
- The device token lives in the **Keychain** only — never in preferences, logs,
  URLs or the app's own state file.
- Notes stay fully usable with sync off, unpaired, or unreachable.

The server is compiled in. `SYNC_BASE_URL` still overrides it for a staging run.
TLS validation is never disabled and no private CA is installed.

```bash
SYNC_BASE_URL=https://my-host swift run NatesNotes
```

To check the whole round trip against the real server, get a one-time code
(`./scripts/personal-sync-admin.sh create-pairing natesnotes write` on the Mac
mini) and run:

```bash
.build/release/NatesNotes --sync-smoke PAIRING-CODE
```

It pairs, pushes a note, proves a second installation pulls back byte-identical
content, edits it, checks the node id survives, forces a **concurrent-edit
conflict** between two installations, snapshots the tree two nodes at a time to
exercise paging, then deletes everything it made and revokes its own device
token — so it leaves nothing behind. Pass `--keep` to leave the test note on the
server.

Last live run: 12 Aug 2026, all checks passed. See
[docs/SYNC.md](docs/SYNC.md#verified-against-the-live-server) for exactly what
is proven live versus against the in-process server.

## Layout

```
Sources/NatesNotes/
  Theme.swift              OKLCH palette, accent modes, motion tokens
  Model/                   Note, Drawing, the file-backed store
  Editor/
    MarkdownStyler.swift   markdown → attributes (the live-preview engine)
    MarkdownTextView.swift TextKit view: glyph hiding, ornaments, input
    SlashMenu.swift        the "/" block picker
  Draw/
    RoughRenderer.swift    seeded sketch primitives, ink outlines, hachure
    ElementPainter.swift   element → pixels; also thumbnails and export
    CanvasView.swift       tools, selection, resize, undo, viewport
  UI/
    Effects.swift          glow ring, running lights, press/rise modifiers
    TitleBar / Sidebar     chrome, mode chip, sectioned navigation
    CommandPalette.swift   ⌘K overlay
  Draw/DrawingModal.swift  the hero morph that opens the canvas
  SelfTest.swift           offscreen render + canvas interaction checks
```

### How the live preview works

Syntax characters get a `.hiddenMD` attribute; a `NSLayoutManager` delegate
turns those into null glyphs, which have no image and no advancement. Character
offsets stay untouched, so the text on disk is exactly what you typed.

One consequence worth knowing if you touch this code: a run of zero-width
glyphs at the start of a line gets absorbed into the *previous* line fragment.
So bullets, checkboxes and rules anchor to each line's first **visible**
character (falling back to its trailing newline for lines that are hidden end
to end, like dividers and drawing embeds) rather than to the paragraph start.

## Development checks

The binary can render its own UI offscreen and exercise the canvas without a
display:

```bash
swift test                                                     # 36 sync tests
.build/release/NatesNotes --render-samples /tmp/shots          # editor.png, canvas.png
.build/release/NatesNotes --render-samples /tmp/shots --dark   # dark variants
.build/release/NatesNotes --test-canvas                        # interaction checks
.build/release/NatesNotes --test-sync-mapping                  # document + merge checks
.build/release/NatesNotes --render-app /tmp/shots               # whole UI, Chill
.build/release/NatesNotes --render-app /tmp/shots --locked      # whole UI, Locked-In
.build/release/NatesNotes --render-app /tmp/shots --modal       # with the sketch modal open
```

`--render-app` hosts the real SwiftUI hierarchy in an offscreen window and
captures it, so the chrome can be inspected without a display or screen-recording
permission.

`swift test` covers the handoff's 14 minimum acceptance tests against an
in-process server that enforces the real semantics (version checks, idempotency,
snapshot/cursor expiry, tus offsets), plus wire-format tests that stub at
`URLProtocol` and assert the exact headers and bytes sent — including that
`Upload-Metadata` carries base64 of the *hex string* while `Upload-Checksum`
carries base64 of the *raw digest*.
