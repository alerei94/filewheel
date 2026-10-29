# Pagewright

One native Mac app for the everyday file jobs, **working offline on your own Mac**: PDF tools (merge, split,
compress, OCR, redact…), picture tools (compress, resize, crop, convert…), audio and video conversion, and
document conversion. Nothing is uploaded anywhere.

It is written entirely in **Swift** with the frameworks that come with macOS (PDFKit, Vision, ImageIO,
AVFoundation, AppKit, SwiftUI): no Python, no libraries to install, a small app.

> **Status: first version.** It was written without access to a Mac compiler. The syntax of every file has been
> checked, but it has never been compiled or run, so the first `bash build.sh` may report errors to fix. After it
> builds, run the built-in check (`--self-test`, see below): it exercises the main tools on files it creates and
> tells you exactly what works.

## Platforms

| Platform | Folder | Status |
|---|---|---|
| macOS 13 or later | [`mac/`](mac/) | First version (Swift): written, not yet compiled |
| Windows | `windows/` | Planned |

Each platform is a separate app with its own code. This document describes the macOS one.

## Tools (35)

| Group | Tools |
|---|---|
| **Organize** | Merge PDF · Split PDF · Extract pages · Remove pages · Reorder pages · Rotate PDF |
| **Optimize** | Compress PDF · Repair PDF · OCR PDF (Apple's Vision, no extra program) |
| **Convert to PDF** | Images to PDF · Office to PDF (needs LibreOffice) |
| **Convert from PDF** | PDF to images (JPG/PNG) · PDF to text · PDF to Word · PDF to PowerPoint (both need LibreOffice) |
| **Edit** | Add page numbers · Add watermark · Add image / signature · Crop PDF |
| **Review & security** | Protect PDF (password) · Unlock PDF · Redact PDF · Compare PDF |
| **Images** | Compress · Resize · Crop · Rotate / flip · Convert (JPG, PNG, TIFF, GIF, BMP, ICO, HEIC) · Watermark · Remove photo data (location, camera) |
| **Audio & video** | Convert audio · Convert video · Compress video · Video to audio |
| **Documents** | Convert document (Word, OpenDocument, RTF, HTML, text, PDF) |

### What needs an extra program

| Program | Needed for | Install |
|---|---|---|
| *(none)* | Everything in the table above except the next two rows, including OCR | |
| [LibreOffice](https://www.libreoffice.org) | Office to PDF, PDF to Word, PDF to PowerPoint | `brew install --cask libreoffice` |
| [ffmpeg](https://ffmpeg.org) | MP3, OGG, Opus, MKV, WebM, AVI, animated GIF, and more input formats | `brew install ffmpeg` |

Without ffmpeg, audio converts to M4A, WAV, AIFF and FLAC, and video to MP4, MOV and M4V, using what macOS has
built in. When ffmpeg is installed, Pagewright uses it automatically (restart the app after installing it).
Tools that need a missing program show a grey card that tells you what to install.

### Differences from the Python version

This version has no *Extract images from a PDF* tool, can't write WebP (macOS can read but not write it), and its
PDF compression only re-encodes the pictures inside (it can't shrink a text-only PDF). It also has no menu bar icon and no Shift-drag wheel.

## Build and run (macOS)

You need macOS 13 or later and the Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

```bash
cd mac
bash build.sh                                       # creates mac/Pagewright.app
Pagewright.app/Contents/MacOS/Pagewright --self-test   # checks the tools (prints PASS / FAIL for each)
open Pagewright.app
```

Then drag `Pagewright.app` into Applications. It is signed only locally, so on another Mac macOS will warn you:
right-click the app and choose **Open**.

If `build.sh` prints errors, copy the complete message: each one points to a file and a line.

## Using the window

Pick a tool on the home page (or type in the search box), drop files on the window or press **Add files…**, set the
options, and press the big button. Results are saved next to the originals, or in the folder you choose, and
nothing is ever overwritten (an existing name becomes `name 2.pdf`). Tools where the order matters (Merge, Images
to PDF, Compare) let you drag the rows. Long jobs run in the background and can be cancelled.

**Page ranges:** `3` · `1,3,5-8` · `5-` (to the end) · `-3` (the first three) · `last` · `8-1` (reversed) · empty = all.

## Updating the app

Choose **Pagewright → Check for Updates…** in the menu bar.

- It looks in your project folder for files changed after the app was built, and, if that folder is a git
  repository with a remote, for new commits (it runs `git fetch`).
- If something is new, **Update and restart** gets it (`git pull --ff-only`, only when there are new commits), builds
  a new app with `build.sh` into a temporary folder (a minute or two: the current app keeps working meanwhile),
  then replaces the running app and reopens it.
- If the build fails, nothing is touched: the log is shown, with a button to copy it.
- The previous app is kept in `~/Library/Application Support/Pagewright/Previous/Pagewright.app`.
- **Rebuild anyway** forces a build when nothing new was found.

You need the Command Line Tools, the project folder (Pagewright remembers where it was built; if you moved it,
press **Choose…**), and an app located in a folder you can write to (Applications is fine). It only connects to the
internet when you press the button, and only to the repository you already use.

## Notes on specific tools

- **Redact PDF** searches the text you can select, and every page with a match becomes **a picture with black
  bars**, so the words are really gone, not just covered. Rotated pages must be straightened first (Rotate PDF).
  Scanned pages have no selectable text: run OCR PDF first.
- **OCR PDF** uses Apple's Vision: language codes look like `en-US`, `it-IT`, `de-DE`.
- **Page numbers and watermark** are drawn on the page; on rotated pages they may sit on a side.
- **Protect PDF** sets a password. If you forget it, it can't be recovered. **Unlock PDF** removes a password you
  already know.
- **Remove photo data** cleans JPEG photos without recompressing them (no quality loss).
- **Convert document** and **document to PDF** use macOS itself (no LibreOffice needed).

## Troubleshooting

**A card says "Needs an extra program".** Install LibreOffice or ffmpeg (table above) and restart the app.

**macOS asks to allow access to Documents or Downloads.** That's normal the first time the app saves there.

## Project layout

```
pagewright/
├── mac/
│   ├── Sources/
│   │   ├── App.swift          app and window
│   │   ├── AppUI.swift        the window (SwiftUI): home, tool pages
│   │   ├── Catalog.swift      the list of tools, their options
│   │   ├── PdfOps.swift       PDF tools (PDFKit, Vision)
│   │   ├── ImageOps.swift     picture tools (ImageIO)
│   │   ├── MediaOps.swift     audio, video, documents (AVFoundation, ffmpeg, textutil, LibreOffice)
│   │   ├── Support.swift      shared helpers (page ranges, file names, processes)
│   │   ├── Updater.swift      the Update button
│   │   └── SelfTest.swift     --self-test
│   ├── Resources/icon.png
│   └── build.sh
├── windows/                   (planned)
├── .gitignore
├── LICENSE
└── README.md
```

To add a tool on macOS: write a function with the signature
`(files: [URL], options: Options, outDir: URL?, progress: Progress) throws -> [URL]` and add one `Tool(...)` entry in
`mac/Sources/Catalog.swift`; the window builds its page and options form from that entry.

## Windows

Planned. It will live in the `windows/` folder as its own app, with the same tools.

## License

MIT: see the `LICENSE` file.
