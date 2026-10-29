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
| Windows 10 / 11 | [`windows/`](windows/) | Beta |

---

## Repository layout

```
filewheel/
├── mac/
│   ├── FileWheel.swift     the whole app, in a single file
│   ├── build.sh            compiles it and creates FileWheel.app
│   └── AppIcon.png         app icon (1024×1024)
├── windows/
│   ├── FileWheel.csproj    project file
│   ├── build.ps1           builds dist\FileWheel.exe
│   ├── app.manifest        per-monitor DPI awareness
│   ├── app.ico             app and tray icon
│   ├── Program.cs          entry point, tray icon, menu
│   ├── WheelForm.cs        the wheel (drawing, drag and drop, conversion flow)
│   ├── Native.cs           Win32 calls and the mouse hook
│   ├── Formats.cs          file types, available formats, optional tools, settings
│   ├── Converter.cs        conversion engine (images, PDF writer, ffmpeg, Word, LibreOffice)
│   └── WinRt.cs            Windows Runtime parts (HEIC/WebP, transcoding, PDF pages)
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

The Windows version works like the Mac one: hold Shift while dragging a file, drop it on a format of the wheel.
It lives in the system tray (the icon is next to the clock; it may be inside the **^** overflow menu).

> **Beta.** The code is new and has been type-checked and partly tested, but not yet used on many real PCs.
> If something doesn't work, the troubleshooting section below covers the likely causes.

### Requirements

- Windows 10 (version 1809 or later) or Windows 11
- To **build**: the .NET 8 SDK

  ```powershell
  winget install Microsoft.DotNet.SDK.8
  ```

- To **run**: the .NET 8 Desktop Runtime (`winget install Microsoft.DotNet.DesktopRuntime.8`),
  unless you build a self-contained version (see below)

### Build and run

In PowerShell:

```powershell
git clone https://github.com/YOUR-USER/filewheel.git
cd filewheel\windows
.\build.ps1
.\dist\FileWheel.exe
```

If PowerShell refuses to run the script, allow it for this session first:
`Set-ExecutionPolicy -Scope Process Bypass`.

Build options:

| Command | Result |
|---|---|
| `.\build.ps1` | Small `.exe`; needs the .NET 8 Desktop Runtime installed |
| `.\build.ps1 -SelfContained` | About 70 MB, runs on any Windows 10/11 PC with nothing installed |
| `.\build.ps1 -Arch arm64` | Build for ARM PCs (default is `x64`) |

The result is a single file, `windows\dist\FileWheel.exe`. Copy it wherever you like, for example to
`C:\Program Files\FileWheel`, and create a shortcut. To start it with Windows, use **Launch at login** in the
tray menu.

### How to use it

**By dragging (the main way)**

1. Select a file in File Explorer or on the Desktop.
2. Start dragging it **while holding Shift**.
3. The wheel opens next to the cursor, with your file in the center and the possible formats around it.
4. Drop the file on the format you want. The center shows progress, then a checkmark.
5. The result is saved **next to the original file** (or in the folder you chose). Click the center when it's
   done to show it in File Explorer.

The star marks the recommended format, always at the top. You can drag several files at once; if they are of
different types, each format shows how many files it can convert. Nothing is ever overwritten: an existing name
becomes `name 2.ext`.

**From the tray menu** (right-click the icon; double-click opens the file picker)

- **Convert files…**: pick files and click a format on the wheel.
- **Save next to the original file** / **Choose a destination folder…**
- **Launch at login**
- **Quit**

### Supported formats

| Type | Input | Output |
|---|---|---|
| **Images** | PNG, JPG, BMP, GIF, TIFF, ICO, and HEIC, HEIF, WebP (see below) | PNG, JPG, BMP, GIF, TIFF, PDF (+ WebP with ffmpeg) |
| **Audio** | MP3, M4A, WAV, AIFF, FLAC, AAC, WMA, OGG, Opus (what Windows or ffmpeg can read) | MP3, M4A, WAV, FLAC, WMA (+ OGG, Opus, AIFF with ffmpeg) |
| **Video** | MP4, MOV, M4V, AVI, MKV, WebM, MPG, 3GP, FLV, WMV (depends on the installed codecs) | MP4, WMV (+ MP3, M4A, MOV, MKV, WebM, AVI, GIF with ffmpeg) |
| **Documents** | TXT, MD, RTF, HTML, DOC, DOCX, ODT | PDF, DOCX, DOC, ODT, RTF, HTML, TXT (needs Word or LibreOffice) |
| **PDF** | PDF | PNG, JPG (one image per page) |

Notes:

- Photos keep their orientation (the camera's rotation is applied). Transparency becomes white in JPG and BMP.
- **HEIC / HEIF / WebP** images are read through Windows' own codecs: install *HEIF Image Extensions* and
  *WebP Image Extensions* from the Microsoft Store if Windows doesn't have them yet.
- Image → PDF creates a one-page PDF containing the picture.
- A multi-page PDF becomes `name_page1`, `name_page2`, …
- PDF → TXT is not available on Windows.
- Documents are converted with **Microsoft Word** if it is installed, otherwise with **LibreOffice**. Without
  either, document formats simply don't appear on the wheel and a message explains why.
- Without ffmpeg, audio and video are converted with the codecs built into Windows (Media Foundation), which
  cover the formats listed without "+ ffmpeg".

The recommended format works as on the Mac (images to JPG, audio to MP3, video to MP4, documents to PDF, PDF to
PNG) and the app remembers the last format you chose for each type.

### ffmpeg (optional)

```powershell
winget install Gyan.FFmpeg
```

Restart FileWheel afterwards. It is detected automatically (PATH, WinGet, Chocolatey, Scoop). ffmpeg runs at low
priority and uses half of the CPU cores.

### Changing the icon

Replace `windows\app.ico` with your own multi-size `.ico` file (16 to 256 pixels) and run `.\build.ps1` again.

### Troubleshooting

**The wheel doesn't appear.**
- Hold Shift *while* dragging (before or after the drag starts both work). Drag **files**, not text or images
  from a web page.
- Make sure the app is running: look for the icon in the system tray, including the **^** overflow menu.
- Programs running **as administrator** (including an elevated File Explorer) can't be watched by a normal
  program, and can't drop files onto it. Run FileWheel as administrator too, or drag from a normal window.
- Some security software warns about programs that watch the mouse system-wide. FileWheel only looks at
  button presses and movement, only reads files while Shift is held, and never sends anything anywhere.
- In the meantime, **Convert files…** from the tray menu works without drag detection.

**Windows SmartScreen says "Windows protected your PC".**
The `.exe` is not signed. Click **More info → Run anyway**. Signing requires a code-signing certificate.

**A format is missing from the wheel, or a conversion fails.**
The message under the wheel says why. Usually you need ffmpeg (audio/video), Word or LibreOffice (documents),
or the HEIF/WebP extensions (images).

**`build.ps1` shows errors.**
- *.NET SDK not found*: install it with `winget install Microsoft.DotNet.SDK.8`, then open a new PowerShell window.
- Other errors: copy the complete message so it can be analyzed.

### Settings and uninstalling

Settings (destination folder, remembered formats) are stored in `%APPDATA%\FileWheel\settings.ini`.
To uninstall: choose **Quit** from the tray menu, turn off **Launch at login**, delete `FileWheel.exe`
and, if you like, the `%APPDATA%\FileWheel` folder.

### Technical notes

- C# on .NET 8 with Windows Forms; no third-party libraries. The wheel is a borderless, layered window drawn
  with GDI+ (per-pixel transparency), which makes it light and lets it be the drop target of the drag.
- Windows doesn't let a program ask what is being dragged, so FileWheel installs a low-level mouse hook:
  Shift + left button held + the mouse moving shows an almost invisible window under the cursor. If the drag
  carries files, that window receives the OLE drag-and-drop events, reads the file list and reveals the wheel.
  For drags that don't carry files, it disappears when the button is released.
- Conversions use what Windows provides: GDI+ (images), Windows Runtime codecs (HEIC, WebP), Media Foundation
  (audio, video) and the Windows PDF renderer (PDF pages). ffmpeg, Word and LibreOffice are optional.
- Per-monitor DPI awareness is declared in `app.manifest`.

---

## Development

The repository only holds the sources: build output (`FileWheel.app`, `windows/dist/`, `bin/`, `obj/`) is
regenerated by the build scripts and ignored by git. The usual flow: edit the source of one platform, build,
test, and save the change.

```bash
# macOS
cd mac && bash build.sh && open FileWheel.app
```

```powershell
# Windows
cd windows; .\build.ps1; .\dist\FileWheel.exe
```

```bash
git add -A && git commit -m "Describe the change"
```

## License

MIT: see the [`LICENSE`](LICENSE) file.
