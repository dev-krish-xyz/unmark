# Unmark

Unmark is a small native macOS utility. It removes invisible Unicode characters and look-alike spaces from text you copy. Copy something, move the cursor to the MacBook notch, click **Paste & Clean**, then press ⌘V anywhere.

- **Native**: Swift, SwiftUI and AppKit. A 270 KB download, no dependencies, about 19 MB of memory and effectively zero CPU when idle.
- **Offline**: runs in the App Sandbox without any network entitlement, so macOS itself blocks network access. No telemetry.
- **Deliberate**: hovering only opens the popup. The clipboard changes only when you click **Paste & Clean** (or choose *Clean Clipboard* in the menu bar).
- **Careful**: rich text keeps its formatting, and emoji, scripts that need joiners, bidirectional text and the Apple logo stay intact.

## How it works

1. Copy text in any app. A small dot appears beside the notch.
2. Move the cursor up to the notch. A large popup opens with a single **Paste & Clean** button. A cursor that only passes through doesn't open it.
3. Click the button. The copied text appears in the popup with hidden characters highlighted (`•` hidden character, `␣` unusual space), and a live activity bar runs along the bottom of the island.
4. When it finishes, the cleaned text is already on your clipboard. The highlights disappear from the preview and the popup says how many characters were removed. Press ⌘V in any app.
5. Move the cursor away and the popup closes. **Undo** in the popup (or the menu bar) puts back the exact original clipboard as long as you haven't copied anything else since.

The popup never takes keyboard focus, so ⌘V goes to the app you were working in. Cleaning usually takes milliseconds. The clipboard is written the moment it finishes, and the activity bar stays visible for about half a second so you can see it.

On Macs without a notch, on external displays, or with the lid closed, use **Clean Clipboard** in the menu bar item instead.

## What gets removed

The cleaning rules are a Swift port of the deterministic "Layer A" cleaner from [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover). The port passes that project's cleaning test vectors, except that Private Use Area stripping is opt-in (see below).

| Removed | Examples |
| --- | --- |
| Zero-width and invisible format characters | U+200B zero width space, U+2060 word joiner, U+FEFF BOM, U+00AD soft hyphen, invisible math operators |
| Unicode tag characters | U+E0000–U+E007F (except inside valid flag emoji such as 🏴󠁧󠁢󠁳󠁣󠁴󠁿) |
| Stray variation selectors and joiners | U+FE00–U+FE0F and U+E0100–U+E01EF when not attached to an emoji or ideograph |
| Bidi overrides and unpaired embeddings | U+202D, U+202E, orphaned U+202A–U+202C |
| Noncharacters and reserved default-ignorables | U+FDD0–U+FDEF, U+nFFFE/U+nFFFF, unassigned ignorable ranges |
| Unusual spaces → regular space | U+00A0, U+202F narrow no-break space, U+2000–U+200A, U+3000 … (toggle: *Normalize Unusual Spaces*) |

What is preserved, because removing it would change visible or meaningful text:

- Emoji sequences: ❤️‍🔥, 👨‍👩‍👧, ⚖️, keycaps, skin tones and subdivision flags
- Orthographic joiners in Arabic, Persian, Indic, Khmer and Mongolian text, plus Mongolian variation selectors, Khmer inherent vowels and Hangul fillers in context
- Bidi marks, isolates and paired embeddings in mixed right-to-left and left-to-right text
- CJK ideographic variation sequences, Egyptian hieroglyph, Duployan and musical layout controls
- **Private Use Area characters**, such as the Apple logo (U+F8FF), SF Symbols and Nerd Font glyphs. watermarks-remover strips these. Unmark keeps them because they turn up in real Mac and terminal text.
- `&nbsp;` and literal no-break spaces in **HTML**, where they control layout

Tabs, line breaks, trailing whitespace and ordinary text are never modified. If nothing needs removing, Unmark leaves the clipboard untouched and shows *Already clean*.

## Limitations

- Unmark removes **character-level** markers only. It does **not** detect or remove statistical watermarks such as SynthID-Text, which are embedded in word choice, and it does not rewrite or paraphrase anything. There is no guarantee that cleaned text is free of every watermark.
- Content that isn't text (images, files) and content marked as concealed or transient by password managers ([nspasteboard.org](http://nspasteboard.org)) is never read.
- Clipboards larger than 20 MB are skipped.
- A copied web archive (Safari's richest format) is dropped when its HTML or RTF needs cleaning, because it can't be rewritten safely. Apps then paste the cleaned HTML or RTF instead.
- In HTML, invisible characters that sit between two tags can't be judged in context, so they're treated as stray characters.

## Privacy

- While watching, Unmark reads only the clipboard's change counter and the list of data types. It reads the clipboard's **content** only when you click **Paste & Clean** or choose **Clean Clipboard**.
- The original clipboard is kept in memory for undo. It is discarded when you copy something else, after 10 minutes, or when the screen locks, and is never written to disk.
- On macOS 15.4 and later, macOS may ask whether Unmark can paste from other apps. You can set this under **System Settings › Privacy & Security › Paste from Other Apps**. If access is denied, Unmark shows *Clipboard access denied* and changes nothing.

## Install

Requires macOS 14 Sonoma or later. The notch interaction needs a MacBook with a notch, and every other Mac can use the menu bar.

Download `Unmark-<version>.zip` from [Releases](../../releases), unzip it, and move **Unmark.app** to `/Applications`.

Releases are signed with a Developer ID and notarized only when the project's signing secrets are configured. Each release's notes say which applies. To open a build that isn't notarized, Control-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Unmark.app
```

The menu bar item has toggles for **Watch Clipboard**, **Open on Notch Hover**, **Normalize Unusual Spaces** and **Launch at Login**.

## Development

Building needs Swift 6 (Xcode 16 or later, or the Command Line Tools).

```sh
Scripts/test.sh                  # unit tests (Swift Testing)
Scripts/build-app.sh             # build/Unmark.app for this Mac, ad-hoc signed
open build/Unmark.app
UNIVERSAL=1 Scripts/build-app.sh # arm64 + x86_64
```

`Scripts/test.sh` wraps `swift test`. With only the Command Line Tools installed, it points the compiler at the swift-testing macro plugin, which SwiftPM otherwise fails to pass along.

```
Sources/UnmarkCore/   cleaning engine and clipboard layer (no UI, fully tested)
  UnicodeTables.swift      code point tables
  TextCleaner.swift        context-aware cleaning, edits addressed in UTF-16
  PasteboardContent.swift  plain / RTF / RTFD / HTML representations
  ClipboardCleaner.swift   snapshot, clean, race checks, undo
  ClipboardMonitor.swift   change-count watcher
Sources/Unmark/       app: notch panels, SwiftUI island, menu bar item, lifecycle
Tests/UnmarkCoreTests/
```

### Releasing

```sh
VERSION=1.2.0 Scripts/release.sh
```

This builds a universal app and writes `dist/Unmark-<version>.zip` with a SHA-256 checksum. Archive timestamps come from the last commit, so the same toolchain and sources give an identical zip. Set `CODESIGN_IDENTITY` to sign with a Developer ID, and set `NOTARY_PROFILE` (or `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`) to notarize and staple. Without these, the build is ad-hoc signed and the script reports `notarized: no`.

Pushing a `v*` tag runs `.github/workflows/release.yml`. That workflow signs and notarizes when the repository secrets `MACOS_CERTIFICATE` (a base64-encoded .p12), `MACOS_CERTIFICATE_PASSWORD`, `CODESIGN_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` are set.

## License

MIT, see [LICENSE](LICENSE). The cleaning rules and test vectors come from watermarks-remover (MIT, © 2026 Guillaume Meyer and contributors), see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
