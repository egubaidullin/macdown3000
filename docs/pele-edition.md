# Pele edition: what this fork adds and how it differs

This repository is a fork of
[schuyler/macdown3000](https://github.com/schuyler/macdown3000) (branch
`feat/mermaid-pele`). Everything below is the difference from that original; all
other behaviour, licensing and history are unchanged.

## 1. Diagrams are rendered by Pele instead of Mermaid

| | Upstream | This fork |
|---|---|---|
| Engine | Mermaid 11 (≈3.5 MB) | [Pele](https://github.com/obsidianmd/pele) 1.13.0 (≈0.7 MB, MIT, by the Obsidian team) |
| Syntax | ` ```mermaid ` | same — no document changes needed |
| Diagram types | Mermaid set | every type built into Mermaid 12.1.0 (flowchart, sequence, class, state, ER, gantt, pie, journey, mindmap, timeline, and more) |
| Bundle location | `Resources/Extensions/mermaid*.js` | `Resources/Extensions/pele.global.js` + `pele.init.js` (vendored, offline, no CDN) |
| Prism interaction | language class `language-mermaid` | same class name is kept, so existing CSS and Prism behaviour are unchanged |

Implementation: `MPRenderer.m` (`diagramScripts`), `MacDown/Resources/Extensions/pele.init.js`.

## 2. Diagrams are on by default

Upstream ships with Mermaid off, so a fresh install shows the fenced block as code
until the user ticks Preferences → Rendering → Mermaid. This fork enables it on
first launch. An explicit choice is respected: the default is written only when the
`htmlMermaid` preference has never been set.

Implementation: `MPPreferences.m` (`loadDefaultUserDefaults`).

## 3. Live preview is steadier

- rendered SVGs are cached by a hash of their source, so typing in the document does
  not re-run the engine for unchanged diagrams;
- an invalid diagram becomes a red block showing the error *and* the offending source
  (text only — never markup), instead of an empty space;
- diagram colours follow the preview theme through `--pele-*` CSS variables: light and
  dark styles get light and dark diagrams with no Obj-C plumbing.

Implementation: `pele.init.js`; regression tests in `MPMermaidRenderingTests.m` and
`MacDownTests/JavaScript/pele.init.test.js`.

## 4. Export to Word (.docx)

New in this fork. File ▸ Export gains two items:

- **Word (SVG)…** — diagrams are embedded as vector art, with a PNG fallback inside the
  same picture for readers that do not understand SVG;
- **Word (compatible)…** — diagrams are embedded as 2x PNG images.

Both variants preserve headings, lists (real numbering and nesting), tables, code
blocks, quotes, images and hyperlinks; the header carries the file name and the footer
the page number. Images and diagrams are scaled to the printable area, and very small
diagrams are enlarged so they stay readable.

There is no third-party dependency: `MPDocxWriter` writes the OOXML package itself
(stored ZIP, CRC32, `document.xml`, `styles.xml`, `numbering.xml`, `settings.xml`,
header/footer).

Implementation: `MacDown/Code/Document/MPDocxWriter.{h,m}`,
`MacDown/Resources/Extensions/docx.snapshot.js`, `MPDocument.m` (export actions),
`MacDownTests/JavaScript/docx.snapshot.test.js`.

## 5. Minimum macOS is 12.0

Upstream targets 11.0. Xcode 27 no longer supports that deployment target, so the
project, Podfile and the user-facing docs now say 12.0. Runtime `@available(macOS 11.0)`
guards are left as they are; they are harmless.

## 6. Tests and CI

- The DOM-adapter scripts (`pele.init.js`, `docx.snapshot.js`) have Node tests under
  `MacDownTests/JavaScript/`; CI runs them before the Xcode suite.
- Word export has unit tests for the writer and end-to-end tests that render a fixture
  through the real pipeline.

## Not changed (deliberately)

- Hoedown and Prism internals, and the Hoedown code-block patch.
- Quick Look keeps rendering diagrams as code; enabling them there is a separate,
  larger change (JavaScript is disabled in that extension).
- Preferences are shared with stock MacDown 3000 (same application ID), so both builds
  read and write the same settings.

## Build

```bash
git clone --recurse-submodules https://github.com/egubaidullin/macdown3000.git
cd macdown3000 && git checkout feat/mermaid-pele
./setup.sh   # needs Homebrew Ruby; see README
```
