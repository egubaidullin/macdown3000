# MacDown 3000 — Pele Edition

A fork of [schuyler/macdown3000](https://github.com/schuyler/macdown3000) that renders
` ```mermaid ` diagram blocks with [Pele](https://github.com/obsidianmd/pele) (MIT, by the
Obsidian team) instead of Mermaid 11. No changes to your documents are needed:
Pele understands Mermaid syntax (flowchart, sequence, class, gantt, pie, and more).

Why Pele: a smaller (0.7 MB vs 3.5 MB), actively maintained engine with CSS-variable
theming and a simple render API — replacing Mermaid-specific workarounds with
caching, error blocks, and light/dark preview themes.

## Download & Install

Download `MacDown-3000-Pele.dmg` from the
[releases page](https://github.com/egubaidullin/macdown3000/releases), open it,
and drag the app to your Applications folder.

- Coexists with stock MacDown 3000 in /Applications under its own name, but note:
  both apps share the same preferences (same application ID), so settings changed
  in one are visible in the other.
- The build is **unsigned and unnotarized** (no Apple developer certificate):
  first launch with right-click → “Open” → confirm.
- Diagrams are enabled by default (Preferences → Rendering → Mermaid).

### System Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon or Intel (universal binary)

> Note: `brew install --cask macdown-3000` installs the *original* MacDown 3000,
> not this edition. Use the DMG above.

## Screenshot

![screenshot](assets/screenshot.png)

## Features

Everything from the original, plus:

### Diagram Rendering (Pele)

` ```mermaid ` fenced blocks render as SVG diagrams in live preview:

- **Many diagram types**: flowchart, sequence, class, gantt, pie, and more
- **On by default**, with per-user opt-out in Preferences → Rendering
- **No flicker while typing**: results are cached by source hash
- **Invalid diagrams** show a red block with the error and the offending source
- **Light/dark themes**: diagram colors follow the preview style
- Diagrams are included in **HTML export** and **PDF printing**; works fully offline

### Live Preview & Markdown Rendering

MacDown 3000 uses Hoedown to convert Markdown to HTML with live preview as you type. It supports:

- **Fenced code blocks** with language identifiers
- **GitHub Flavored Markdown** including tables, strikethrough (enabled by default), and autolinks
- **Task lists** for GFM-style checkboxes, including the `[-]` partly-done (indeterminate) state
- **Customizable rendering options** in Preferences

### Syntax Highlighting

Code blocks get syntax highlighting via Prism, supporting numerous programming and markup languages.

### Additional Rendering Tools

- **Math notation** using TeX-like syntax ($$...$$, \[...\], \(...\), and optional $...$ blocks)
- **Jekyll front-matter** for static site generators
- **Export to HTML or PDF** with customizable styling

### Folder Browsing

Open an entire folder as a workspace with `macdown .` from the terminal or via **File › Open Folder…** in the menu. A sidebar lists subfolders and Markdown files in the chosen directory; double-click a file to open it as a tab in the same window, or, if it is already open elsewhere, to bring that window to the front. Press **⌘\\** to show or hide the sidebar. Right-click any item in the sidebar for quick access to **Reveal in Finder** or **Copy Path**.

### Editor Features

- **Auto-completion**: Automatic bracket and quote pairing, list continuation, and formatting shortcuts (customizable or disable)
- **Universal binary**: Built natively for both Apple Silicon (M-series) and Intel Macs
- **Modern Markdown**: Supports CommonMark and GitHub Flavored Markdown

## Development

### Requirements

- macOS with Xcode 27.2 or later (macOS SDK 12.0+)
- Git
- A modern Ruby via Homebrew (system Ruby 2.6 **cannot** satisfy the bundle):
  `brew install ruby`, then put `/opt/homebrew/opt/ruby/bin` first on `PATH`
- [Bundler](http://bundler.io) 2.7.2 (see `Gemfile.lock`)

> Note: Old versions of CocoaPods are not supported. Please use Bundler to execute CocoaPods, or make sure your CocoaPods is later than shown in `Gemfile.lock`.

### Environment Setup

```bash
git clone --recurse-submodules https://github.com/egubaidullin/macdown3000.git
cd macdown3000
git checkout feat/mermaid-pele
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle install
bundle exec pod install
```

Then open `MacDown 3000.xcworkspace` in Xcode, or build from the terminal
(`CODE_SIGNING_ALLOWED=NO` is required — there is no signing certificate):

```bash
# Build
xcodebuild -workspace "MacDown 3000.xcworkspace" -scheme MacDown \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build

# Tests (runs MacDownTests)
xcodebuild -workspace "MacDown 3000.xcworkspace" -scheme MacDown \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test
```

If you run into build issues later on, try updating dependencies:

    git submodule update
    bundle exec pod install

## License

MacDown 3000 is released under the terms of MIT License. You may find the content of the license [on opensource.org](http://opensource.org/licenses/MIT), or inside the `LICENSE` directory.

You may find full text of licenses about third-party components in the `LICENSE` directory, or the **About MacDown 3000** panel in the application. Diagram rendering uses [Pele](https://github.com/obsidianmd/pele) (MIT, see `LICENSE/pele.txt`).

The following editor themes and CSS files are extracted from [Mou](http://mouapp.com), courtesy of Chen Luo:

* Mou Fresh Air
* Mou Fresh Air+
* Mou Night
* Mou Night+
* Mou Paper
* Mou Paper+
* Tomorrow
* Tomorrow Blue
* Tomorrow+
* Writer
* Writer+
* Clearness
* Clearness Dark
* GitHub
* GitHub2

## Contributing & Support

MacDown 3000 is Free Software under the MIT License. Contributions are welcome!

Please [file an issue](https://github.com/egubaidullin/macdown3000/issues/new) on GitHub for bug reports, feature requests, or questions. **Please search first to make sure no-one has reported the same issue already** before opening one yourself.

This edition depends on other open source projects, such as [Hoedown](https://github.com/hoedown/hoedown) for Markdown-to-HTML rendering, [Prism](http://prismjs.com) for syntax highlighting (in code blocks), [Pele](https://github.com/obsidianmd/pele) for diagram rendering, and [PEG Markdown Highlight](https://github.com/ali-rantakari/peg-markdown-highlight) for editor highlighting. The upstream project lives at [schuyler/macdown3000](https://github.com/schuyler/macdown3000) — please report non-diagram issues there when they reproduce on the original.
