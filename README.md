# Unmark

Unmark is a small native macOS utility. It removes invisible Unicode characters and look-alike spaces from text you copy. Copy something, move the cursor to the MacBook notch, click **Paste & Clean**, then press ⌘V anywhere.

It also strips metadata from images: drop a JPEG, PNG or WebP on the notch to remove C2PA "made with AI" credentials, EXIF, GPS location, XMP and embedded prompts, without re-encoding a single pixel.

It can also **Reword** copied text with Apple's on-device model (Apple Intelligence, macOS 26 and later). Rewording changes word choice, which is the only thing that weakens statistical text watermarks. It is best-effort, and nothing leaves your Mac.

- **Native**: Swift, SwiftUI and AppKit. A 270 KB download, no dependencies, about 19 MB of memory and effectively zero CPU when idle.
- **Offline**: runs in the App Sandbox without any network entitlement, so macOS itself blocks network access. No telemetry. Its only file access is to images you drop and to Downloads.
- **Deliberate**: hovering only opens the popup. The clipboard changes only when you click **Paste & Clean** or **Reword** (or choose them in the menu bar).
- **Careful**: rich text keeps its formatting, and emoji, scripts that need joiners, bidirectional text and the Apple logo stay intact.

## How it works

1. Copy text in any app. A small dot appears beside the notch.
2. Move the cursor up to the notch. A large popup opens with a single **Paste & Clean** button. A cursor that only passes through doesn't open it.
3. Click the button. The copied text appears in the popup with hidden characters highlighted (`•` hidden character, `␣` unusual space), and a live activity bar runs along the bottom of the island.
4. When it finishes, the cleaned text is already on your clipboard. The highlights disappear from the preview and the popup says how many characters were removed. Press ⌘V in any app.
5. Move the cursor away and the popup closes. **Undo** in the popup (or the menu bar) puts back the exact original clipboard as long as you haven't copied anything else since.

The popup never takes keyboard focus, so ⌘V goes to the app you were working in. Cleaning usually takes milliseconds. The clipboard is written the moment it finishes, and the activity bar stays visible for about half a second so you can see it.

On Macs without a notch, on external displays, or with the lid closed, use **Clean Clipboard** in the menu bar item instead.

## Strip image metadata

Drag one or more images onto the notch. The popup opens and turns into a drop zone. Drop them, and Unmark saves a clean copy of each to **Downloads** as `name (clean).jpg` and puts the copies on the clipboard, so ⌘V attaches them in X, Slack, Mail and so on. Originals are never changed. Without a notch, use **Strip Image Metadata…** in the menu bar, which reveals the copies in Finder.

| Removed | Where it lives |
| --- | --- |
| **C2PA Content Credentials**, the provenance manifest that ChatGPT/DALL·E, Gemini, Firefly and others attach | JPEG APP11 (JUMBF), PNG `caBX`, WebP `C2PA` |
| EXIF, including camera, serial numbers, timestamps and **GPS location** | JPEG APP1, PNG `eXIf`, WebP `EXIF` |
| XMP (often names the AI tool, e.g. `trainedAlgorithmicMedia`) | JPEG APP1, PNG `iTXt`, WebP `XMP ` |
| IPTC / Photoshop data, comments | JPEG APP13, COM |
| Text chunks, where Stable Diffusion and ComfyUI store the full prompt and settings | PNG `tEXt` / `zTXt` / `iTXt` |
| Data after the end of the image (thumbnails, HDR gain maps, trailers) | after JPEG EOI / PNG IEND |

How it stays safe:

- **Lossless.** Unmark walks the file's segments and copies the compressed image data byte for byte. Nothing is decoded or re-encoded, and tests check the decoded pixels are identical.
- Kept on purpose: colour profiles (ICC), JFIF and Adobe colour info, PNG gamma/sRGB/transparency/DPI, and animation chunks.
- A rotated photo keeps its orientation: Unmark writes a minimal EXIF block holding only the orientation flag.
- The popup says when the removed metadata identified an AI generator ("Removed AI provenance").
- Verified against the C2PA project's own signed sample images: credentials gone, pixels identical, and a second pass changes nothing.

Limits: JPEG, PNG and WebP only (HEIC, TIFF, PDF and video are not yet supported). An HDR photo's gain map is removed with the other appended data, so it shows as standard range. **Invisible pixel watermarks** such as Google's SynthID for images, which are baked into the pixels, are not touched. Removing provenance doesn't change who made an image. Follow the rules of wherever you post it.

## Reword

**Reword** sits next to **Paste & Clean** in the popup (and in the menu bar as *Reword Clipboard*). It rewrites the copied text with Apple's on-device language model, streams the new text into the popup as it is written, and puts the result on the clipboard as plain text. **Cancel** stops it without touching the clipboard. **Undo** restores the original, formatting included.

Pick a style under the buttons or from *Reword Style* in the menu:

| Style | What it does |
| --- | --- |
| **Paraphrase** (default) | Same meaning with different words, clause order and sentence boundaries |
| **Natural** | Plainer, less formulaic prose. Afterwards it straightens quotes, replaces em dashes with commas, and swaps filler such as "in order to" and "utilize" |
| **Round-trip** | Translates to French (or to English for non-English text) and back |

How it works:

- The text is cleaned of hidden characters first, then split into paragraphs. Each paragraph goes to a fresh model session, so no earlier text is in context.
- Paragraphs longer than about 1,200 characters are split at sentence boundaries.
- Fenced code blocks, blank lines, surrounding whitespace and lines without letters are kept byte for byte and never sent to the model.
- The prompt marks the copied text as a passage to transform, never as instructions to follow.
- Answers that don't look like a rewrite (wrong length, empty, chatty preambles) are tidied up or retried once. If they still fail, the clipboard is left alone.
- The popup shows how much of the phrasing changed: the share of word pairs from the original that no longer appear.
- Prompts and the Natural cleanup are adapted from watermarks-remover's "Layer B" ([`rewrite_text.py`](https://github.com/guillaumemeyer/watermarks-remover/blob/main/service/scripts/rewrite_text.py), [`humanize_pass.py`](https://github.com/guillaumemeyer/watermarks-remover/blob/main/service/scripts/humanize_pass.py)). Unlike that project, Unmark never calls a remote API.

Things to know:

- **Read the result before you use it.** A rewrite can drop nuance, change emphasis or get a fact wrong, especially with Natural, which also tends to shorten text.
- **No guarantee.** Statistical watermarks are detected by the provider with a secret key, so nobody outside the provider can confirm that a mark is gone. Published research shows that heavy paraphrasing lowers detection, but short or lightly reworded text can still be detectable.
- **Use it honestly.** Reword is for text you own or are allowed to edit. Removing a watermark doesn't make AI-written text human-written. Don't use it to get around a school's, employer's or platform's rules on disclosing AI use.
- Rewording needs a Mac with Apple Intelligence turned on. Unmark itself still runs on macOS 14, and the Reword button explains why it's unavailable.
- Formatting is not kept, because the result is plain text. Up to 12,000 characters at a time. Each paragraph takes a few seconds.
- Apple's model supports a limited set of languages and has its own safety filter, which can decline some text. In that case Unmark says so and changes nothing.

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

Tabs, line breaks, trailing whitespace and ordinary text are never modified. If nothing needs removing, Unmark leaves the clipboard untouched and shows *No hidden characters found*.

## Limitations

- Text copied from ChatGPT, Claude and most other assistants usually contains **no** hidden characters, so **Paste & Clean** reports *No hidden characters found*. That is the correct result, not a failure. The text watermarks these providers announced in 2026 (OpenAI's textGrain, Anthropic's SynthID-Text-based mark, Google's SynthID-Text) are **statistical**: they are a pattern in which words the model chose, with no hidden characters, and only the provider's detector can find them. Cleaning cannot see or remove them. **Reword** changes the words themselves, which weakens such patterns but cannot be verified (see [Reword](#reword)).
- **Paste & Clean** never changes visible typography such as curly quotes, em dashes and ellipses, because they are real text. (The Natural reword style does change them.)
- Unmark cannot detect watermarks of either kind and makes no guarantee that any text is free of them.
- Content that isn't text (images, files) and content marked as concealed or transient by password managers ([nspasteboard.org](http://nspasteboard.org)) is never read.
- Clipboards larger than 20 MB are skipped.
- A copied web archive (Safari's richest format) is dropped when its HTML or RTF needs cleaning, because it can't be rewritten safely. Apps then paste the cleaned HTML or RTF instead.
- In HTML, invisible characters that sit between two tags can't be judged in context, so they're treated as stray characters.

## Privacy

- While watching, Unmark reads only the clipboard's change counter and the list of data types. It reads the clipboard's **content** only when you click **Paste & Clean** or **Reword**, or choose them in the menu bar.
- Image metadata stripping reads only the files you drop or pick, and writes only to Downloads (the sandbox allows exactly that folder). It never reads the clipboard; it replaces it with the clean copies, which can't be undone from Unmark.
- **Reword** uses Apple's on-device model through the FoundationModels framework. The text is processed on your Mac. Unmark keeps no copy, and the app still has no network entitlement.
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

Building needs Swift 6 (Xcode 16 or later, or the Command Line Tools). Reword is compiled in only with the macOS 26 SDK or later (Xcode 26); older SDKs build everything else.

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
