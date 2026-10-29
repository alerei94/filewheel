# Converti

A small Mac app that converts files from one format to another **without opening any window**.
It lives in the menu bar: hold **Shift (⇧)** while dragging a file, and a **wheel of the available formats**
appears next to your cursor. Just drop the file on the format you need.

- No required dependencies: it uses tools already built into macOS.
- Lightweight: no window, no Dock icon, and it does practically nothing while idle.
- Works offline: your files never leave your Mac.

> The app's interface text (menu items, welcome message, status messages) is in Italian.
> Menu items are shown below with their Italian label followed by the English meaning.

---

## What's in the folder

| File | Purpose |
|---|---|
| `ConvertiMac.swift` | The app's source code (a single file) |
| `build.sh` | Compiles the code and creates `Converti.app` |
| `AppIcon.png` | The app icon (1024×1024), embedded by `build.sh` |
| `README.md` / `README.en.md` | This documentation (Italian / English) |
| `LICENSE` | Project license (MIT) |
| `.gitignore` | What git should ignore (the built app, system files) |
| `setup-repo.sh` | Turns the folder into a git repository (run once) |

---

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- Xcode Command Line Tools (full Xcode is not needed)

If you don't have them, install them from Terminal:

```bash
xcode-select --install
```

---

## Installation

1. Put `ConvertiMac.swift`, `build.sh` and `AppIcon.png` in the same folder.
2. In Terminal, from that folder:

   ```bash
   bash build.sh
   ```

3. When it finishes, `Converti.app` is in the same folder. Launch it:

   ```bash
   open Converti.app
   ```

4. (Optional) Drag `Converti.app` into **Applications**.

To update the app after changing the code, just run `bash build.sh` again
(quit the app first from its menu, **Esci** = Quit).

One command to rebuild and relaunch:

```bash
bash build.sh && open Converti.app
```

> The app is compiled and signed locally on your Mac, so macOS usually shows no security warning.
> If one appears, right-click the app and choose **Open**.

---

## How to use it

### By dragging (main way)

1. Drag a file from the Finder or the Desktop **while holding Shift (⇧)**.
2. The wheel opens next to the cursor: your file in the center and the possible formats all around it.
3. Drop the file on the format you want.
4. The center shows progress, then a checkmark. The result is saved **next to the original file**
   (or in the folder you chose, see below).
5. Click the center once it's done to reveal the converted file in the Finder.

Good to know:

- The **star** marks the recommended format for that kind of file, and it's always at the top of the wheel.
- You can drag **several files at once**. If they are of different types, each format shows a small number:
  how many of the files it can convert. The others are skipped.
- If you release the file outside the formats, the wheel disappears and nothing happens.
- The original file is never modified or moved.
- If a file with the same name already exists, the new one is named `name 2.ext` — nothing is overwritten.

### From the menu bar

Click the icon with the two arrows in the menu bar:

- **Converti file…** (Convert files…) — pick files with the file selector and click a format on the wheel
  (handy when you don't want to drag).
- **Salva accanto al file originale** (Save next to the original file) — the default behavior.
- **Scegli una cartella di destinazione…** (Choose a destination folder…) — save every conversion to a fixed folder.
- **Esci** (Quit)

A short welcome message explaining the usage appears the first time you launch the app.

---

## Supported formats

| Type | Input formats | Output formats |
|---|---|---|
| **Images** | PNG, JPG, HEIC, HEIF, TIFF, GIF, BMP, WebP, JP2 | PNG, JPG, HEIC, TIFF, GIF, BMP, PDF (+ WebP with ffmpeg) |
| **Audio** | MP3, M4A, WAV, AIFF, CAF, FLAC, AAC, OGG, Opus, WMA | M4A, WAV, AIFF, CAF, FLAC (+ MP3, OGG, Opus with ffmpeg) |
| **Video** | MP4, MOV, M4V, AVI, MKV, WebM, MPG, 3GP, FLV, WMV | MP4, MOV, M4V, M4A (audio only) (+ MKV, WebM, GIF, MP3 with ffmpeg) |
| **Documents** | TXT, MD, RTF, HTML, DOC, DOCX, ODT | PDF, DOCX, DOC, ODT, RTF, HTML, TXT |
| **PDF** | PDF | TXT, PNG, JPG (one image per page) |

Notes:

- When converting to **JPG** or **BMP**, transparency is replaced with a white background.
- An **animated GIF** is converted using only its first frame.
- A multi-page PDF becomes several images named `name_pagina1`, `name_pagina2`, …
- **PDF → TXT** extracts the text already present in the PDF: scanned PDFs (images only) are not recognized.
- Without ffmpeg, some less common input formats (OGG, Opus, WMA, MKV, WebM, AVI…) may not be readable.

### The recommended format

The app suggests a sensible format based on the file and the most common choice:

| Type | Recommended |
|---|---|
| Images | JPG (JPGs go to PNG) |
| Audio | MP3 if you have ffmpeg, otherwise M4A (MP3s go to M4A) |
| Video | MP4 (MP4s go to audio: MP3 or M4A) |
| Documents | PDF |
| PDF | PNG |

If you pick a different format, the app **remembers it** for that file type and suggests it next time.

---

## ffmpeg (optional)

To unlock more formats (MP3, OGG, Opus, WebP, MKV, WebM, GIF from video…), install ffmpeg with Homebrew:

```bash
brew install ffmpeg
```

The app detects it on its own, with no configuration (it looks in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`).
Restart the app after installing it. To keep your Mac responsive, ffmpeg is limited to half of the cores
and runs at low priority.

---

## Changing the icon

`build.sh` turns `AppIcon.png` into the app icon. To use your own:

1. Replace `AppIcon.png` with a square image of at least 1024×1024 pixels, keeping the same name.
   Leave roughly 10% of transparent margin around the artwork.
2. Run `bash build.sh` again.
3. If the Finder still shows the old one (icon cache): `touch Converti.app && killall Finder`.

The icon shows up in the Finder, in Applications, in Spotlight and in the welcome message. It does not appear in the
Dock because the app lives only in the menu bar. The menu bar icon is a system symbol and adapts automatically
to the light or dark theme.

---

## Launch at login

**System Settings → General → Login Items** → press **+** and choose `Converti.app`.

---

## Troubleshooting

**The wheel doesn't appear when I drag.**
- Hold Shift *while* dragging (pressing it midway works too).
- It only works with **files**, not folders, text, or images dragged from a web page.
- Check that the app is running (icon in the menu bar) and restart it: menu → **Esci** → `open Converti.app`.
- If macOS asked for a permission, check **System Settings → Privacy & Security** (for example
  *Input Monitoring*) and enable `Converti`.
- In the meantime you can use **Converti file…** from the menu: it works without drag detection.

**A format doesn't show up in the wheel, or a conversion fails.**
You probably need ffmpeg: see its section above. The error message appears under the wheel.

**macOS asks for permission to access Desktop, Documents or Downloads.**
That's normal the first time the app saves a file in those folders: allow the access.

**Converting a video is slow or my Mac gets hot.**
Video conversion is naturally heavy. The app uses low priority and half of the cores, but very large files
still take time.

**`build.sh` shows errors.**
- `swiftc non trovato` (swiftc not found): install the Command Line Tools with `xcode-select --install`.
- Other compile errors: make sure `ConvertiMac.swift` and `build.sh` are the latest versions
  and copy the complete message so it can be analyzed.

---

## Resetting settings

To clear the destination folder, remembered formats and the welcome message:

```bash
defaults delete it.local.converti
```

## Uninstalling

Choose **Esci** (Quit) from the app's menu, then delete `Converti.app`
(and, if you like, run the command above to remove the settings).

---

## Technical notes

- Written in Swift using only **AppKit**, in a single file, with no external libraries.
- Conversions are done with macOS tools: ImageIO (images), `afconvert` (audio), AVFoundation (video),
  `textutil` and a PDF print engine (documents), PDFKit (PDF). ffmpeg is optional.
- Drag detection observes system-wide mouse events and reads the files from the drag in progress
  only while Shift is held.
- `build.sh` compiles for your Mac's architecture (`arm64` or `x86_64`) optimized for size,
  strips debug symbols and applies a local signature.
- Preferences are stored under `it.local.converti`: destination folder, last format chosen per file type,
  and whether the welcome message has already been shown.

---

## Development with git

The folder is meant to be a git project: the repository only holds the sources, while `Converti.app`
is regenerated each time with `bash build.sh` and ignored by git.

```bash
bash setup-repo.sh        # once: .gitignore, LICENSE and first commit
```

Then the usual flow: edit `ConvertiMac.swift`, test with `bash build.sh && open Converti.app`, and save with

```bash
git add -A && git commit -m "Describe the change"
```

To publish it on GitHub, create an **empty** repository (no README) and run:

```bash
git remote add origin https://github.com/YOUR-USER/converti.git
git push -u origin main
```

## License

MIT: see the `LICENSE` file.
