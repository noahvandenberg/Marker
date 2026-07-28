# Marker

A native macOS Markdown editor. Headings render at their real size while you
type, `**bold**` becomes **bold**, and the syntax markers stay hidden — you edit
the rendered words directly, not the source. The file on disk is still plain
Markdown; nothing is ever rewritten behind your back.

It edits plain `.md` files in place. No account, no sync service, no telemetry,
no network access. The editing surface is one AppKit text view on TextKit 2,
driven by a Markdown parser written for editing rather than for producing an AST.

Diagrams and equations are the exception: KaTeX and Mermaid are vendored into the
bundle and rasterized by an **offscreen** WebKit view that never appears on
screen and never loads a remote URL. Typing stays entirely native.

## Build

```bash
./build.sh release install
```

That compiles, assembles `Marker.app`, ad-hoc signs it, and copies it to
`/Applications`. Drop the `install` argument to leave it in `./build`.

Requires Xcode 16 or newer and macOS 14+. There are no Swift package
dependencies. `Resources/Web/` holds vendored KaTeX 0.16.11 and Mermaid 11.16.0
(both MIT, licenses included alongside them) and `Resources/Tokenizer/` holds
OpenAI's `o200k_base` vocabulary; together they are most of the ~10 MB bundle.

## What it does

**Live rendering.** Headings, bold, italic, inline code, strikethrough,
`==highlight==`, links, images, footnote references, blockquotes (nested),
horizontal rules, setext headings, and task lists all render as you type.

Markers never appear, so the page doesn't flicker between rendered and raw as
the caret moves. Arrow keys and clicks step over the hidden `**` — one key press
moves one *visible* character — and Backspace at the start of an emphasised run
unwraps it rather than eating a single invisible asterisk and leaving broken
syntax. Backspace at the start of a heading, quote or list item removes that
marker. `⌥⌘S` reveals every marker when you need to see or repair the source.

Code, math and Mermaid blocks are the exception: put the caret inside one and it
turns back into editable source, because that is the only sensible way to edit
a diagram.

**Lists.** Return continues the list and increments numbers; Return on an empty
item outdents it, then clears it. Tab and Shift-Tab change nesting. Backspace
right after a marker removes the whole marker. Bullets and numbers are drawn in
the margin so text stays aligned whether markers are showing or hidden. Click a
task checkbox to toggle it.

**Code blocks.** Fenced blocks get a tinted rounded background, the language as
a small label, and syntax highlighting for Swift, C/C++/Objective-C, JavaScript,
TypeScript, Python, Ruby, Go, Rust, Java, Kotlin, C#, PHP, SQL, Lua, shell,
YAML, TOML, JSON, HTML, CSS, and diffs. Spell checking is suppressed inside
code, so identifiers don't pick up red squiggles.

**Math.** `$x^2$` renders inline on the text baseline; `$$…$$` blocks and
```` ```math ```` fences render centered. Full KaTeX, so anything KaTeX supports
works. Put the caret inside a block and it turns back into editable source.
`$5 and $10` stays plain text.

**Diagrams.** ```` ```mermaid ```` blocks render as diagrams — every Mermaid
type, including gantt, state, ER, class and git graphs. Same caret rule: move
into the block to edit the source, move out to see the diagram. Both math and
diagrams follow the light/dark appearance.

**Images.** `![alt](path.png)` on its own line renders as a block image; inline
in a sentence it renders inline, sized to the text. Paths resolve relative to the
document. Remote `http(s)` images are **not** fetched unless you turn that on in
Settings, since a network request would leak that you opened the file.

**Reference links.** `[text][label]`, `[text][]` and the bare `[label]` shortcut
all resolve, for links and images alike. Definition lines are styled quietly out
of the way rather than hidden.

**Tables.** GFM pipe tables are laid out properly: columns sized to fit the
measure, cell text wrapped, rows as tall as their content, per-column alignment
from the delimiter row, and inline formatting inside cells. A wide table fits
the page instead of running off it.

**Cells are edited in place.** Click a cell and type — the table stays a table
and re-lays out as you go. Tab and Shift-Tab move between cells (selecting the
cell, so typing replaces it), Return moves down a row and adds one from the last
row, arrows move within a cell and hop to the neighbour at its edges, and a
double-click selects a whole cell. Emphasis inside a cell renders like anywhere
else, and the caret steps over the hidden markers.

`⌥⌘S` still drops the table to pipe source when you need to change its shape;
`⌃⌘T` normalizes that source when you want the raw file padded for a diff.
Either way the bytes on disk stay ordinary Markdown.

**Writing modes.** Focus mode (`⌃⌘F`) dims everything but the block you're in.
Typewriter mode (`⌃⌘Y`) keeps the caret vertically centered. The measure, text
size, line height, typeface (system sans, New York serif, SF Rounded, or mono),
and light/dark appearance are all adjustable in Settings (`⌘,`).

**Counts.** Words, characters and tokens sit in the window subtitle. The token
count is real byte-pair encoding against OpenAI's `o200k_base` vocabulary — a
port of tiktoken's merge loop, not a chars-per-token estimate — so it is exact
for GPT-4o and GPT-5 and close for other families, whose vocabularies aren't
published. It costs ~3.6 MB on disk and ~30 MB of RAM once loaded, so Settings
can turn it off.

**Updates.** Once a day Marker asks the GitHub Releases API whether a newer
version is tagged, and shows a slim dismissible bar across the top of the window
if so. `Marker ▸ Check for Updates…` runs it on demand. This is the app's only
network request — it sends nothing about your documents and talks to no host but
`api.github.com` — and Settings can turn it off. It stays quiet until the repo
has a published release whose tag is a higher version than the running build.

**The rest.** Document-based: tabs, autosave in place, Versions, Revert.
Original file encoding and CRLF line endings survive a round trip. An Outline
menu jumps to any heading. `⌘`-click opens a link. Export to a self-contained
HTML file.

## Shortcuts

| | |
| --- | --- |
| Bold / Italic | `⌘B` / `⌘I` |
| Inline code | `⌃⌘C` |
| Strikethrough / Highlight | `⇧⌘X` / `⇧⌘H` |
| Link | `⌘K` |
| Heading 1–6 / Body | `⌃⌘1`–`⌃⌘6` / `⌃⌘0` |
| Bullet / Numbered / Task list | `⇧⌘8` / `⇧⌘7` / `⇧⌘9` |
| Toggle task | `⇧⌘D` |
| Blockquote | `⌃⌘'` |
| Code block | `⌥⌘C` |
| Horizontal rule | `⌃⌘-` |
| Insert table / Reformat table | `⌥⌘T` / `⌃⌘T` |
| Show Markdown source | `⌥⌘S` |
| Focus mode / Typewriter mode | `⌃⌘F` / `⌃⌘Y` |
| Bigger / Smaller / Actual size | `⌘+` / `⌘-` / `⌘0` |
| Wider / Narrower measure | `⌥⌘]` / `⌥⌘[` |
| Markdown cheat sheet | Help menu |

With text selected, typing `*`, `_`, `` ` ``, `~`, `=`, `[`, `(` or `"` wraps
the selection instead of replacing it.

## How it works

```
Sources/Marker/
├── Markdown/      line-oriented parser, inline scanner, table formatter, HTML export
├── Styling/       theme, styler (parse → NSTextStorage attributes), syntax highlighter, table layout
├── Editor/        NSTextView subclass, input handling, TextKit 2 layout fragments
├── Rendering/     offscreen KaTeX/Mermaid rasterizer, image loader
├── Tokenizer/     byte-pair encoder for the token count
├── Document/      NSDocument and its window controller
└── App/           menu bar, preferences, SwiftUI settings
```

Three decisions carry most of the design:

**The parser is line-oriented, not an AST.** A live editor needs source ranges
tied to editing and has to classify half-typed syntax gracefully — a fence with
no closing fence, a table missing its delimiter row. `MarkdownParser` does one
pass over a `unichar` buffer and returns a `LineInfo` per line, plus code and
table regions. Parsing 576 KB / 11k lines takes about 2.5 ms, so a keystroke can
reparse the whole document and still land well inside a frame.

**Markers are concealed, never deleted.** A hidden `#` or `**` is still in the
text storage; it just gets a 0.01 pt font and a clear color. That keeps the
backing store byte-identical to the file, so selection, find, copy, and save all
operate on real Markdown rather than on a rendered projection. The cost is that
the caret would otherwise step through zero-width characters, so
`MarkerNavigation.swift` maps every horizontal movement and deletion onto
visible text.

**A drawn block can still be edited.** A table is a picture, but the text under
it is ordinary Markdown, so the selection stays a normal range in the document.
Each cell keeps the map from the characters it *displays* back to their offsets
in the source, which is what lets a click find the right character and the caret
sit between the right two letters. That map is also the set of positions worth
stopping at, so arrow keys skip pipes, padding and hidden emphasis markers
without any special cases.

**Block chrome is drawn, not inserted.** Code backgrounds, quote bars, rules,
bullets, checkboxes, table grids, diagrams, equations and images all come from an
`NSTextLayoutFragment` subclass that reads a decoration object off a text
attribute. Nothing is injected into the document to make it look right — a block
image reserves height through `minimumLineHeight`, and an inline image or
equation reserves width by kerning the concealed source it replaces.

Restyling is scoped: an edit repaints the affected lines, widened to whole code
and table regions and to wherever the line classifications actually diverge from
the previous parse (so opening a fence correctly repaints everything below it).
Layout is then invalidated for **only** those characters — invalidating the
whole document on every keystroke is what made scrolling stutter in long files.

**Nothing is tied to scrolling.** No observer, no debounced repaint, no geometry
query in `draw`. Restyling invalidates layout, and re-laid-out lines can land a
point or two from where they were, which reads as the view settling and then
clicking up or down the moment you stop. Content that isn't ready yet is handled
by remembering it instead: a styling pass records whether it painted anything
still resolving, and when the render or image lands those lines are repainted —
when the content arrives, not when it happens to scroll past. Repaints that do
change heights measure an anchor line before and after and compensate the scroll
offset, so a diagram finishing above the viewport doesn't yank the page.

## The icon

`Resources/AppIcon-source.png` is the generated artwork; `Tools/makeicon.swift`
turns it into `AppIcon.icns`. It finds the icon shape in the source, crops inside
its antialiased edge, rebuilds the shape's gradient across the whole canvas so
the corners are filled, composites the artwork on top clipped to its own
outline, and emits all ten sizes.

The output is deliberately **full-bleed and opaque** — no rounded corners of its
own, no padding, no shadow. Recent macOS masks and shadows app icons itself; an
icon that arrives pre-shaped on a transparent canvas gets treated as loose
artwork and inset into a grey plate. To swap the artwork, drop in a new square
PNG and run:

```bash
swiftc -O -o /tmp/makeicon Tools/makeicon.swift && /tmp/makeicon Resources/AppIcon-source.png Resources/AppIcon.icns
```

## Limitations

- Because markers are hidden, malformed syntax can be hard to spot; `⌥⌘S` is
  the way out.
- Rendered diagrams and equations are raster images, so they don't reflow with
  the measure until re-rendered, and they aren't selectable as text.
- A selection can't span table cells; it clamps to the cell it started in.
  Select the whole table from outside it, or use `⌥⌘S`, to work across cells.
- Adding or removing a column means editing the pipe source (`⌥⌘S`); the cell
  editor changes contents, not the table's shape.
- HTML export keeps math as TeX (`\(…\)`) and Mermaid as `<pre class="mermaid">`
  rather than embedding the rendered images.
- Remote images are off by default (Settings turns them on).
- The update check only notices *published GitHub releases*; a plain commit or
  an unreleased tag won't trigger it.
- Single-document: one file per window. No folder sidebar or vault-wide search
  (find within a document works).
- Very long single lines in a table can push it past the measure; wrapping is
  clipped rather than reflowed for table rows.
