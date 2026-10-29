# FileWheel

A tiny file converter that runs in the background and opens no window.
**Hold Shift while dragging a file**, and a **wheel of the available formats** appears next to your cursor.
Drop the file on the format you need, and it's converted.

- Works offline: your files never leave your computer.
- Lightweight: no window, no Dock icon, and it does practically nothing while idle.
- No required dependencies: it uses tools already built into the operating system.

| Platform | Folder | Status |
|---|---|---|
| macOS 13 or later | [`mac/`](mac/) | Available |
| Windows | `windows/` | Planned |

---

## Repository layout

```
filewheel/
├── mac/
│   ├── FileWheel.swift     the whole app, in a single file
│   ├── build.sh            compiles it and creates FileWheel.app
│   └── AppIcon.png         app icon (1024×1024)
├── windows/                (planned)
├── LICENSE
└── README.md
```

The platform versions are independent: they share the idea and the look, not the code.

---

## macOS

### Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel
- Xcode Command Line Tools (full Xcode is not needed). If you don't have them:

  ```bash
  xcode-select --install
  ```

### Build and run

```bash
git clone https://github.com/YOUR-USER/filewheel.git
cd filewheel/mac
bash build.sh
open FileWheel.app
```

Optionally, drag `FileWheel.app` into **Applications**. To rebuild and relaunch after changing the code
(quit the app first from its menu):

```bash
bash build.sh && open FileWheel.app
```

The app is compiled and signed locally on your Mac, so macOS usually shows no security warning.
If one appears, right-click the app and choose **Open**.

### How to use it

**By dragging (the main way)**

1. Drag a file from the Finder or the Desktop **while holding Shift (⇧)**.
2. The wheel opens next to the cursor: your file in the center and the possible formats all around it.
3. Drop the file on the format you want.
4. The center shows progress, then a checkmark. The result is saved **next to the original file**
   (or in the folder you chose).
5. Click the center once it's done to reveal the converted file in the Finder.

Good to know:

- The **star** marks the recommended format for that kind of file, and it's always at the top of the wheel.
- You can drag **several files at once**. If they are of different types, each format shows a small number:
  how many of the files it can convert. The others are skipped.
- If you release the file outside the formats, the wheel disappears and nothing happens.
- The original file is never modified or moved.
- If a file with the same name already exists, the new one is named `name 2.ext`. Nothing is overwritten.

**From the menu bar**

Click the icon with the two arrows in the menu bar:

- **Convert files…**: pick files with the file selector and click a format on the wheel
  (handy when you don't want to drag).
- **Save next to the original file**: the default behavior.
- **Choose a destination folder…**: save every conversion to a fixed folder.
- **Quit**

A short welcome message explaining the usage appears the first time you launch the app.

### Supported formats

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
- A multi-page PDF becomes several images named `name_page1`, `name_page2`, …
- **PDF → TXT** extracts the text already present in the PDF: scanned PDFs (images only) are not recognized.
- Without ffmpeg, some less common input formats (OGG, Opus, WMA, MKV, WebM, AVI…) may not be readable.

**The recommended format**

The app suggests a sensible format based on the file and the most common choice:

| Type | Recommended |
|---|---|
| Images | JPG (JPGs go to PNG) |
| Audio | MP3 if you have ffmpeg, otherwise M4A (MP3s go to M4A) |
| Video | MP4 (MP4s go to audio: MP3 or M4A) |
| Documents | PDF |
| PDF | PNG |

If you pick a different format, the app **remembers it** for that file type and suggests it next time.

### ffmpeg (optional)

To unlock more formats (MP3, OGG, Opus, WebP, MKV, WebM, GIF from video…), install ffmpeg with Homebrew:

```bash
brew install ffmpeg
```

The app detects it on its own, with no configuration (it looks in `/opt/homebrew/bin`, `/usr/local/bin`
and `/usr/bin`). Restart the app after installing it. To keep your Mac responsive, ffmpeg is limited to half
of the cores and runs at low priority.

### Changing the icon

`build.sh` turns `AppIcon.png` into the app icon. To use your own:

1. Replace `mac/AppIcon.png` with a square image of at least 1024×1024 pixels, keeping the same name.
   Leave roughly 10% of transparent margin around the artwork.
2. Run `bash build.sh` again.
3. If the Finder still shows the old one (icon cache): `touch FileWheel.app && killall Finder`.

The icon shows up in the Finder, in Applications, in Spotlight and in the welcome message. It does not appear
in the Dock because the app lives only in the menu bar. The menu bar icon is a system symbol and adapts
automatically to the light or dark theme.

### Launch at login

**System Settings → General → Login Items** → press **+** and choose `FileWheel.app`.

### Sharing the app

The app is only signed locally. On another Mac, macOS will warn about an unidentified developer: the user can
right-click the app and choose **Open**. To avoid the warning you need to sign it with a Developer ID
certificate and notarize it with Apple, which requires an Apple Developer Program membership. Also change the
bundle identifier (`local.filewheel`, set in `build.sh`) to one of your own.

### Troubleshooting

**The wheel doesn't appear when I drag.**
- Hold Shift *while* dragging (pressing it midway works too).
- It only works with **files**, not folders, text, or images dragged from a web page.
- Check that the app is running (icon in the menu bar) and restart it: menu → **Quit**, then `open FileWheel.app`.
- If macOS asked for a permission, check **System Settings → Privacy & Security** (for example
  *Input Monitoring*) and enable `FileWheel`.
- In the meantime you can use **Convert files…** from the menu: it works without drag detection.

**A format doesn't show up in the wheel, or a conversion fails.**
You probably need ffmpeg: see its section above. The error message appears under the wheel.

**macOS asks for permission to access Desktop, Documents or Downloads.**
That's normal the first time the app saves a file in those folders: allow the access.

**Converting a video is slow or my Mac gets hot.**
Video conversion is naturally heavy. The app uses low priority and half of the cores, but very large files
still take time.

**`build.sh` shows errors.**
- `swiftc not found`: install the Command Line Tools with `xcode-select --install`.
- Other compile errors: make sure `FileWheel.swift` and `build.sh` are the latest versions
  and copy the complete message so it can be analyzed.

### Resetting settings

To clear the destination folder, remembered formats and the welcome message:

```bash
defaults delete local.filewheel
```

### Uninstalling

Choose **Quit** from the app's menu, then delete `FileWheel.app`
(and, if you like, run the command above to remove the settings).

### Technical notes

- Written in Swift using only **AppKit**, in a single file, with no external libraries.
- Conversions are done with macOS tools: ImageIO (images), `afconvert` (audio), AVFoundation (video),
  `textutil` and a PDF print engine (documents), PDFKit (PDF). ffmpeg is optional.
- Drag detection observes system-wide mouse events and reads the files from the drag in progress
  only while Shift is held.
- `build.sh` compiles for your Mac's architecture (`arm64` or `x86_64`) optimized for size,
  strips debug symbols and applies a local signature.
- Preferences are stored under `local.filewheel`: destination folder, last format chosen per file type,
  and whether the welcome message has already been shown.

---

## Windows

Planned. It will live in the `windows/` folder, with the same idea: hold Shift while dragging a file and pick the
format from a wheel.

---

## Development

The repository only holds the sources: `FileWheel.app` is regenerated each time with `bash build.sh`
and ignored by git. The usual flow: edit `mac/FileWheel.swift`, test with

```bash
cd mac && bash build.sh && open FileWheel.app
```

and then save the change with

```bash
git add -A && git commit -m "Describe the change"
```

## License

MIT: see the [`LICENSE`](LICENSE) file.
