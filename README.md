# Markdown Reader

A fast, lightweight, native macOS Markdown reader and editor. Double-click a
`.md` file and it opens in a clean, rendered reading view; press ⌘2 to edit the
source, ⌘S to save, ⌘1 to go back to reading.

- Native Swift / AppKit / TextKit app (SwiftUI for the outline sidebar)
- No Electron, no WebKit, no JavaScript, no dependencies; no network access
  unless you turn on remote images
- GitHub-flavored Markdown plus footnotes, math, Mermaid diagrams, definition
  lists, emoji shortcodes and collapsible `<details>`, all rendered natively
- 3.9 MB universal app (Apple Silicon + Intel), macOS 14 Sonoma or later
- Works on plain `.md` files: no proprietary format, no telemetry, no accounts

## Building

Requirements: macOS 14+ and Xcode 16 or later (developed and tested with
Xcode 27 on macOS 27, Apple Silicon).

In Xcode: open `MarkdownReader.xcodeproj`, choose the **MarkdownReader** scheme
and press ⌘R. To produce a standalone app from the command line:

```bash
xcodebuild -project MarkdownReader.xcodeproj -scheme MarkdownReader -configuration Release -derivedDataPath build/DerivedData build
```

The app is written to `build/DerivedData/Build/Products/Release/Markdown Reader.app`.
Copy it to `/Applications`. To make it the default for Markdown files, select
any `.md` file in Finder, choose **File ▸ Get Info**, pick *Markdown Reader*
under **Open with**, then click **Change All…**.

Run the test suite:

```bash
xcodebuild test -project MarkdownReader.xcodeproj -scheme MarkdownReader -destination 'platform=macOS'
```

The project is signed ad hoc ("Sign to Run Locally"), so it runs on the Mac
that built it. The bundle identifier `com.local.MarkdownReader` can be changed
in the target's build settings.

### Sandboxed build and distribution

There are two release configurations:

| Configuration | App Sandbox | Use |
|---|---|---|
| `Release` | no | Local use; relative images and links just work |
| `Release-Sandboxed` | yes (`Config/MarkdownReader-Sandboxed.entitlements`) | Distribution, Mac App Store-style security |

```bash
xcodebuild -project MarkdownReader.xcodeproj -scheme MarkdownReader -configuration Release-Sandboxed -derivedDataPath build/DerivedData build
```

A sandboxed app may only read the file you opened, so in that build
**File ▸ Grant Folder Access…** (also offered when a relative link or image is
blocked) asks for permission to the document's folder. Granted folders are
remembered as security-scoped bookmarks. The sandbox entitlements allow
user-selected files, those bookmarks, printing, and outgoing connections (used
only for remote images, which stay off by default).

To give the app to other Macs without Gatekeeper warnings it has to be signed
with *your* Developer ID and notarized by Apple. `Tools/notarize.sh` does the
whole chain (signed build with hardened runtime and secure timestamp,
`notarytool` submission, stapling, Gatekeeper check) once you have an Apple
Developer account:

```bash
xcrun notarytool store-credentials MarkdownReaderNotary --apple-id you@example.com --team-id ABCDE12345
```

```bash
TEAM_ID=ABCDE12345 ./Tools/notarize.sh Release-Sandboxed
```

A pre-built copy is attached to the GitHub Releases (zip plus
`SHA256SUMS.txt`). It is ad-hoc signed, so on another Mac Gatekeeper refuses
to open it directly; build from source, or run the notarization script above.

## Using it

| Action | Shortcut |
|---|---|
| Reader / Editor / Split View | ⌘1 / ⌘2 / ⌘3 (also the toolbar control) |
| Show / hide the heading outline | ⌃⌘S (toolbar button) |
| Find, Find and Replace | ⌘F, ⌥⌘F (⌘G / ⇧⌘G next/previous) |
| Bigger / smaller / actual text size | ⌘+ / ⌘− / ⌘0 (applies to the focused pane) |
| Bold, italic, inline code, strikethrough, link | ⌘B, ⌘I, ⇧⌘K, ⇧⌘X, ⌘K (editor) |
| Save, Save As, Revert, Export as PDF, Print | ⌘S, ⇧⌘S, File menu, File menu, ⌘P |

`Samples/Showcase.md` shows the basic elements and `Samples/Extensions.md`
every extension (math, diagrams, footnotes, details, CSS, wide content).

In the reader, click a task checkbox to tick or untick it (the source changes;
⌘Z undoes it), click a `<details>` summary to expand or collapse it, and
scroll wide code blocks and tables sideways. Footnote numbers jump to the note
and ↩︎ jumps back.

In the editor, Return continues lists, task lists (`- [ ] `) and block
quotes, and Return on an empty item ends the list. Tab and Shift-Tab indent and
outdent list items. Plain indented lines keep their indentation.

Files open by double-clicking in Finder, with File ▸ Open (⌘O) and Open Recent,
by dropping them on the Dock icon, or by dropping them on a window. Clicking a
relative link to another Markdown file opens it in a new window, and `#anchor`
links scroll to the heading. Every window has its own view mode. Windows
cascade, and they tab natively (Window ▸ Merge All Windows, or the system
"Prefer tabs" setting).

The **View** menu holds the few persisted options: reading width, monospaced
editor font, syntax highlighting, line wrapping, synchronized scrolling in
Split View (on by default; scrolling either pane moves the other),
**Load Remote Images** (off by default) and **Appearance**: *Match System*
(the default; follows the macOS setting and switches with it, including
*Auto*), *Light* or *Dark*. The app also remembers the last view
mode, the window size, the font sizes, the outline visibility and the split
ratio.

## Architecture

```
MarkdownReader/
  App/        main.swift (AppKit entry point), AppDelegate, MainMenu (menus in code)
  Document/   MarkdownDocument (NSDocument), TextDecoding (encodings, BOM)
  Markdown/   BlockParser, InlineParser, AST, scanning helpers, HTML entities
              (full HTML5 table) and tags, DetailsGrouping, EmojiShortcodes
  Rendering/  MarkdownRenderer (AST → NSAttributedString), PreviewController
              (incremental updates), PreviewTextView, attachments, link handling,
              CodeHighlighter, MathRenderer, MermaidRenderer, HTMLStyle (CSS),
              ScrollableBlock (wide content), PreviewFindClient (reader Find),
              RemoteImageLoader
  Editor/     EditorController, EditorTextView (list editing), SyntaxHighlighter,
              ListContinuation, EditorStyle
  Window/     DocumentWindowController (toolbar, sidebar, commands),
              DocumentContentViewController (modes, split view, sync scrolling),
              outline (SwiftUI) and status bar
  Support/    Preferences, UserActivity (slicing while the user interacts), TextKit 1
              helpers, LineIndex, TextStatistics, LaunchTrace,
              FolderAccess (sandbox bookmarks)
Config/       Info.plist, sandbox entitlements
Tools/        icon generator, notarize.sh
MarkdownReaderTests/  116 unit, integration and rendering tests
```

### Decisions and trade-offs

**Document model: AppKit `NSDocument`, not SwiftUI `DocumentGroup`.**
`DocumentGroup` always autosaves in place and offers no Save As, no "Do you want
to save?" prompt and no control over external changes. Classic `NSDocument`
gives native Open / Open Recent / Save / Save As / Revert, the edited dot,
file coordination (`NSFilePresenter`), autosave-elsewhere crash drafts,
window restoration and the built-in "file changed since you opened it" check
before saving. The document's single source of truth is one `NSTextStorage`.
The editor edits it directly (no copies) and the reader observes it.

**Parser: our own CommonMark + GFM parser, no dependencies.** Apple's
`AttributedString(markdown:)` handles inline Markdown well, but it doesn't
provide block structure suitable for layout, tables in a renderable form, task
lists or source positions. Apple's `swift-markdown` package would be an external
dependency with a C library. The parser here is a two-phase CommonMark block
parser (containers, lazy continuation, tight/loose lists, setext headings,
HTML blocks, reference definitions, GFM tables and task items, plus footnote
definitions, `$$` math blocks and definition lists) with a delimiter-stack
inline parser (emphasis rules, links/images, reference links, code spans,
autolinks, GFM strikethrough and bare-URL autolinks, footnote references,
`$…$` math, `:emoji:` shortcodes, the complete HTML5 entity list).
It works on UTF-8 bytes; Markdown syntax is ASCII, so accented and other
non-ASCII text passes through untouched. Inline content is parsed lazily,
per block, only when rendered. Block parsing of a 5 MB document takes about 0.2 s
in a Release build.

**Rendering: native TextKit 1, not a web view.** A `WKWebView` would mean an
extra web content process, slower first paint and a JavaScript/HTML security
surface. Instead the AST is turned into an `NSAttributedString`. Code blocks
and block quotes use `NSTextBlock`, tables use `NSTextTable`, and images and
horizontal rules use attachment cells that scale with the window width.
Colors are semantic or dynamic, so Light and Dark Mode switch without
re-rendering. Selection, copy, printing and PDF export come from
`NSTextView`. Find in the reader uses `NSTextFinder` with its own client, which
also searches the text of wide code blocks and tables shown in horizontally
scrolling views, and scrolls a match into view inside the block. Embedded HTML is never executed. A safe subset is mapped to text
attributes: line and paragraph structure, headings, alignment, lists, block
quotes, tables (`colspan`/`rowspan`), `<details>`/`<summary>`, emphasis and
code tags, links and anchors, images, and inline CSS (`style="…"`: color,
background, weight, style, decoration, size, alignment, `display:none`) and
`<font>`. Scripts, forms, frames and `<style>` sheets are dropped.

**Math and diagrams: native renderers, not KaTeX or Mermaid.js.** Both would
need a JavaScript engine. `MathRenderer` parses the TeX subset used in
documents (fractions, roots, scripts and limits, big operators, stretchy
`\left…\right` delimiters, accents, `matrix`/`pmatrix`/`cases`/`aligned`
environments, fonts like `\mathbb` and `\mathcal`, colors, `\text`) into boxes
with TeX-style spacing and draws them as vectors with the system's STIX Two
Math font. `MermaidRenderer` parses flowcharts (all directions, node shapes,
edge styles and labels, subgraphs, `style`/`classDef`), sequence diagrams and
pie charts, lays flowcharts out with a layered (Sugiyama-style) algorithm, and
draws them with AppKit. Both scale down to fit narrow windows and print sharp.

**Code: language-aware highlighting.** A table-driven tokenizer colors about
40 languages (Swift, C family, Java/Kotlin, JavaScript/TypeScript, Python,
Ruby, Go, Rust, shell, SQL, JSON/YAML/TOML, HTML/XML, CSS, diff and more)
with Xcode-like light and dark themes.

**Wide content: horizontal scrolling.** TextKit cannot lay out one block wider
than its text container, so a code block or table wider than the reading
column is placed in a horizontally scrolling view on top of an attachment
that reserves its space (vertical scrolling passes through to the page).
Blocks that fit stay ordinary text, and resizing the window switches only the
blocks whose width threshold was crossed.

**Remote images: only when asked.** With View ▸ Load Remote Images off (the
default) the app makes no network requests; remote images show a placeholder.
When it is on, images are fetched in the background (ephemeral session, no
cookies, 25 MB limit) and only the blocks that contain them are re-rendered.

**Live preview: incremental.** Each top-level block is keyed by a hash of its
source. After an edit, only the blocks between the unchanged prefix and suffix
are re-rendered and spliced into the text storage, so scroll position and
layout of the rest of the document are preserved. Updates are debounced by
document size (60 ms to 600 ms). Large documents are parsed off the main thread
and rendered in ~35 ms time slices, so the first screen appears immediately.
While the user scrolls, drags or types (the last 0.5 s), rendering and the
editor's highlighting pass switch to 3 ms slices with a 10 ms pause between
them, so the run loop goes idle and AppKit can draw every frame; scrolling a
document that is still being rendered stays smooth, and rendering finishes at
full speed when the user stops. A re-render requested while rendering (such as
the first width change when a window opens) reuses the current parse.

**Editor: TextKit 1 `NSTextView`** with non-contiguous layout. Syntax
highlighting is incremental: block structure is tracked line by line (each
line stores its state: open fence, indented code, paragraph and list context),
and inline markup is matched per paragraph, so emphasis spanning several lines
and indented code blocks are colored. Re-highlighting after an edit starts at
the edited paragraph and stops as soon as the stored state matches again.
Full passes (on open or after a preference change) run in short main-thread
slices (shorter still while the user interacts, see above).

**Safety of user data.** Saves are atomic (NSDocument safe-save). Files are
written back in the encoding they were read with (UTF-8, UTF-8 with BOM,
UTF-16, or a detected legacy encoding such as Windows-1250), and line endings
are never changed. When the file changes on disk (`NSFilePresenter`
notifications plus a cheap modification-date check when a window becomes
key; no polling):

- If there are no local changes, the document reloads silently.
- If there are local changes, the app asks: *Keep My Version* or *Reload from Disk*.
- Saving over a newer file still triggers NSDocument's "Save anyway?" warning.

If a file in a legacy encoding gains characters that encoding cannot
represent (for example an emoji in a Windows-1250 file), saving asks before
converting it to UTF-8; crash-protection drafts never change the encoding.

"Local changes" is decided by both the undo-driven edited state and a hash of
the last loaded or saved text, so no edit path can be mistaken for unchanged.

**SwiftUI vs AppKit.** SwiftUI is used for the outline sidebar, and it is created
lazily the first time the sidebar is shown. Measurements showed that hosting
SwiftUI views on the launch path added about 55 ms to time-to-window. Since
speed is the top priority, the always-visible status bar uses plain AppKit
labels. The text views are AppKit because TextKit is the only way to get this
editing and rendering performance.

**App Sandbox: optional build.** A sandboxed app opening a file only gets
access to that one file, so relative images (`![](images/a.png)`) and links
need folder access. The default `Release` build is not sandboxed, which is the
smoother trade-off for a locally built utility; `Release-Sandboxed` is
sandboxed and asks for folder access when needed (see Building). Both use the
hardened runtime.

**Memory.** Code blocks, quotes and heading rules with the same settings share
one `NSTextBlock`, and paragraph styles are shared too, so large documents do
not hold hundreds of thousands of equal objects.

## Implemented features

- Reader, Editor and Split View per window, switchable instantly (⌘1/2/3).
  Switching keeps the reading position.
- GFM rendering: headings, paragraphs, emphasis, strikethrough, inline code,
  fenced and indented code, block quotes (nested), ordered/unordered/nested
  lists, task lists (clickable), tables with column alignment, horizontal
  rules, links, reference links, autolinks, local images (relative paths,
  percent-encoded names, `data:` URIs), remote images (opt-in), HTML subset
  with inline CSS, HTML tables, collapsible `<details>`, all HTML5 entities,
  hard line breaks.
- Extensions: footnotes (numbered, collected at the end, with backlinks),
  math (`$…$`, `$$…$$`, ```` ```math ````), Mermaid flowcharts, sequence
  diagrams and pie charts, definition lists, `:emoji:` shortcodes.
- Code blocks with language-specific highlighting; wide code blocks and
  tables scroll horizontally.
- Native file handling: Open, Open Recent, double-click from Finder (document
  type and UTI declared), drop on Dock icon or window, multiple windows, native
  tabs, Save, Save As, Revert to Saved, unsaved-changes prompts, crash-safe
  autosave drafts, window restoration.
- External modification detection without polling, with conflict handling.
- Encoding detection and round-trip (UTF-8 ± BOM, UTF-16, Windows-1250,
  ISO 8859-2, Windows-1252, Mac Roman). Hungarian text works in all of them.
- Editor: monospaced or proportional font, incremental syntax highlighting
  (including multi-line emphasis, indented code and math),
  undo/redo, Find and Replace, list/quote continuation, list indentation,
  Markdown formatting commands, optional line wrapping, unsaved-change
  indicator.
- Split View: resizable divider (ratio remembered), live preview,
  synchronized scrolling in both directions.
- Outline sidebar from headings; click to jump (both panes in Split View).
- Status bar: words, characters, lines, cursor line and column, file encoding.
- Adjustable reader and editor font size, reading width (narrow, medium, wide,
  full).
- Print and Export as PDF of the rendered document (always in light colors,
  `<details>` expanded).
- Optional App Sandbox build with folder access, and a notarization script.
- Light and Dark Mode: following the system automatically, or fixed to Light or Dark (View ▸ Appearance).

## Known limitations

Every limitation listed for the first version has been addressed. What
remains are deliberate scope boundaries of the native renderers:

- **Mermaid:** flowcharts, sequence diagrams and pie charts are drawn; other
  diagram types (class, state, Gantt, ER, …) are shown as source with a note.
- **Math:** the TeX subset documents use is supported; user macros
  (`\newcommand`), `\href` and packages beyond the listed environments are not.
  Unknown commands are shown in red rather than breaking the formula.
- **HTML:** inline CSS only; `<style>` sheets and class selectors are not
  applied, and interactive or embedded content (forms, frames, video) is never
  shown.
- **Signing:** distributing to other Macs needs your own Developer ID and
  notarization (`Tools/notarize.sh`); the pre-built copy is ad-hoc signed.

## Verification performed

On macOS 27.0.1 (Apple Silicon) with Xcode 27.0, for version 1.1:

- **Builds:** clean Debug, Release and Release-Sandboxed builds with no
  warnings. The Release app is universal (arm64 and x86_64), 3.9 MB (the full
  HTML5 entity table, emoji names and the new renderers account for the
  growth), hardened runtime, ad-hoc signed. The sandboxed build carries only
  the listed entitlements and launches with its own container.
- **Automated tests:** 116 pass. In addition to the areas below they cover
  footnotes, definition lists, math parsing and layout, emoji shortcodes,
  `<details>` grouping and toggling, Mermaid parsing and layout, code
  highlighting, inline CSS and HTML tables, wide blocks switching to
  horizontal scrolling, reader Find inside horizontally scrolling blocks
  (search text, selection, match rectangles, scrolling, overlay placement),
  short work slices while the user interacts, a width change during rendering,
  the Appearance setting, clickable tasks (including undo), multi-line emphasis
  and indented code in the editor, the legacy-encoding save rules, the
  CommonMark specification examples for tabs and HTML blocks, the full entity
  table, and an offscreen rendering of `Samples/Extensions.md` in light and
  dark mode (inspected visually).
  - block and inline parsing
  - rendering (including a layout regression test)
  - links and images
  - safe HTML
  - encodings
  - document open → edit → save → reopen with CRLF and Hungarian text
  - legacy-encoding round trip, revert
  - print and PDF export
  - list continuation, Tab indentation, bold toggling, incremental fence highlighting
  - incremental preview equal to a full render
  - line index, statistics, dark-mode colors
- **Memory:** on the same 5 MB document (`Samples/Showcase.md` repeated), the
  rendered reader needs about 130–150 MB instead of 160–170 MB in a test
  harness, and the Release app's footprint in Reader mode was 220–300 MB
  instead of 245–330 MB for version 1.0 (several runs; the spread comes from
  how much has been laid out). Memory still grows with the number of tables,
  since every table cell is its own text block.
- **Scrolling while a document opens** (Release build, Split View, the
  reader scrolled programmatically at 120 Hz right after opening; frame times
  measured in the app): with a 1 MB document, the 0.5–1 s window used to get
  3 frames of ~270 ms each; it now gets 37 frames (median 15 ms), and 1–2 s
  runs at a median of 9–10 ms. With a 100 KB document scrolling is smooth from
  the first half second. What remains is one pause of ~0.2–0.4 s while the
  window first appears.
- **Not exercised interactively in this round:** two-way scroll sync, the
  "Save as UTF-8" sheet, the reader's find bar with the system `NSTextFinder`
  UI (highlighting, dimming; the find client itself is tested), switching
  View ▸ Appearance by hand (the setting and its effect are tested). Build 4
  crashed once when switching to Match System, inside AppKit's scroller
  appearance handling; it could not be reproduced (several hundred switches
  while scrolling, also through the real menu). Since build 5 the switch is
  applied after the menu has closed. Remote
  image downloads and the notarization script (it needs a Developer ID).
  Their logic is covered by the tests above where possible.
- **Manually, in the running app (version 1.0):**
  - rendering of every element in `Samples/Showcase.md`, in light and dark mode
  - Reader, Editor and Split View, and that each mode switch keeps the reading position
  - live preview while typing
  - saving with Hungarian characters (verified on disk as UTF-8)
  - silent reload on external change, and the conflict prompt when there are unsaved edits
  - NSDocument's "changed by another application" warning on save
  - Revert to Saved
  - outline navigation
  - a relative `.md` link opening in a new window, with windows cascading
  - opening through LaunchServices (`open -a … file.md`, the same path as a
    Finder double-click), including the first launch of a freshly copied app
  - a 5 MB document: window in ~0.33 s, scrolling and Editor mode stay responsive
- **Performance (Release, warm, version 1.0):** about 0.35 s from process
  start to a visible window, 0% CPU when idle, and a memory footprint of about
  53 MB with a small document. The first launch after a fresh build is slower
  because macOS scans the new binary.

Diagnostics: run the binary with `MDR_TRACE=1` to print launch timings, or
with `MDR_APPEARANCE=dark` / `light` to force an appearance without changing
the system setting. To get PNG snapshots of the rendered sample, run the
snapshot test with an output folder:

```bash
TEST_RUNNER_MDR_SNAPSHOT_DIR=/tmp xcodebuild test -project MarkdownReader.xcodeproj -scheme MarkdownReader -destination 'platform=macOS' -only-testing:MarkdownReaderTests/SnapshotTests
```

## License

MIT, see [LICENSE](LICENSE).
