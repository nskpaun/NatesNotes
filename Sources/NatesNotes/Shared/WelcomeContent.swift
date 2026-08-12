enum WelcomeContent {
    static let markdown = """
# Welcome to Nate's Notes

A native macOS notebook that renders **markdown as you type** and lets you \
sketch **hand-drawn diagrams** right inside a note.

## Writing

Type markdown and it formats itself. The syntax characters stay in the file — \
they just *step out of the way* until your cursor lands on that line. Try \
clicking into this paragraph and watch the `**` reappear.

- Bullet lists get real bullets
- Nested items work too — press `Tab` to indent
- `Return` on an empty item ends the list

1. Numbered lists count themselves
2. Press Return to continue

- [ ] Click this checkbox
- [x] Finished items get struck through
- [ ] Tasks stay plain markdown on disk

> Quotes get a bar and a lighter voice.

Inline styles: **bold**, *italic*, `code`, ~~strikethrough~~ and ==highlight==.

```
// Fenced blocks become a code slab
func greet(_ name: String) -> String {
    "Hello, \\(name)"
}
```

---

## Drawing

Press **⇧⌘D** — or type `/` and pick **Drawing** — to drop a sketch canvas \
into the page. Everything is rendered with a hand-drawn wobble: rectangles, \
diamonds, ellipses, arrows, freehand ink and text.

Inside the canvas:

- `1`–`0` or `V R O D A L P T E H` switch tools
- Drag to draw, `⇧` constrains squares and 15° angles
- Click a shape to select it, then drag the handles to resize
- `⌘Z` undo, `⌘D` duplicate, `⌫` delete
- Scroll to pan, `⌘`-scroll or pinch to zoom

Click any drawing in a note to reopen the canvas.

## The slash menu

Type `/` on an empty line for headings, lists, to-dos, quotes, dividers, code \
blocks, tables and drawings.

## Where your notes live

Every note is a plain `.md` file in **Documents/NatesNotes**, with drawings in \
a JSON sidecar next to it. Nothing is locked in a database — open the folder \
from the bottom of the sidebar any time.
"""
}
