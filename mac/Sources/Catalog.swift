import Foundation

// MARK: - What a tool is

struct Choice {
    let value: String
    let label: String
    init(_ value: String, _ label: String) { self.value = value; self.label = label }
}

enum FieldKind { case text, multiline, int, choice, bool, password, file }

struct Field {
    let key: String
    let label: String
    var kind: FieldKind = .text
    var defaultValue: String = ""
    var choices: [Choice] = []
    var placeholder: String = ""
    var help: String = ""
    var showIf: (String, String)? = nil      // only shown when the other field has that value
}

struct Tool {
    let id: String
    let name: String
    let category: String
    let summary: String
    let icon: String
    let accepts: [String]
    let run: ([URL], Options, URL?, Progress) throws -> [URL]
    var fields: [Field] = []
    var minFiles: Int = 1
    var maxFiles: Int? = nil
    var ordered: Bool = false
    var unavailable: (() -> String?)? = nil     // returns a message when an extra program is missing
    var askPassword: Bool = false               // PDF inputs may be protected
    var keywords: String = ""
    var hint: String = ""

    func missingMessage() -> String? { return unavailable?() }
}

let categories = ["Organize", "Optimize", "Convert to PDF", "Convert from PDF", "Edit", "Review & security",
                  "Images", "Audio & video", "Documents"]

let pdfExts = ["pdf"]
let pictureExts = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp", "ico"]
let audioExts = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg", "opus", "wma", "caf"]
let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "flv", "wmv"]
let textDocExts = ["doc", "docx", "odt", "rtf", "txt", "html", "htm"]
let officeOtherExts = ["xls", "xlsx", "ods", "csv", "ppt", "pptx", "odp"]

let positions: [Choice] = ["bottom center", "bottom right", "bottom left", "top center", "top right", "top left",
                           "center", "middle left", "middle right"].map { Choice($0, $0.capitalized) }

let pagesField = Field(key: "pages", label: "Pages", kind: .text, placeholder: "All pages, or for example 1,3,5-8",
                       help: "Leave empty for all pages. Use commas and dashes: 1,3,5-8 (or 5- for page 5 to the end).")

// MARK: - The catalog

let allTools: [Tool] = [
    // Organize
    Tool(id: "merge", name: "Merge PDF", category: "Organize", summary: "Combine several PDF files into one, in the order you choose.", icon: "🧩",
         accepts: pdfExts, run: opMerge, minFiles: 2, ordered: true, askPassword: true, keywords: "join combine"),
    Tool(id: "split", name: "Split PDF", category: "Organize", summary: "Cut a PDF into several files by ranges, every N pages, or page by page.", icon: "✂️",
         accepts: pdfExts, run: opSplit, fields: [
            Field(key: "mode", label: "Split", kind: .choice, defaultValue: "ranges",
                  choices: [Choice("ranges", "At page ranges"), Choice("every", "Every N pages"), Choice("each", "Every page separately")]),
            Field(key: "ranges", label: "Ranges", kind: .text, placeholder: "For example 1-3, 4-6, 7-", help: "Each range becomes its own file.", showIf: ("mode", "ranges")),
            Field(key: "every", label: "Pages per file", kind: .int, defaultValue: "1", showIf: ("mode", "every")),
         ], askPassword: true, keywords: "divide separate"),
    Tool(id: "extract", name: "Extract pages", category: "Organize", summary: "Keep only the pages you want, in a new PDF.", icon: "📄",
         accepts: pdfExts, run: opExtract, fields: [Field(key: "pages", label: "Pages to keep", placeholder: "For example 1,3,5-8")],
         askPassword: true, keywords: "select pick"),
    Tool(id: "remove", name: "Remove pages", category: "Organize", summary: "Delete the pages you don't need.", icon: "🗑️",
         accepts: pdfExts, run: opRemove, fields: [Field(key: "pages", label: "Pages to remove", placeholder: "For example 2,5-7")],
         askPassword: true, keywords: "delete"),
    Tool(id: "reorder", name: "Reorder pages", category: "Organize", summary: "Put the pages in a new order (you can also repeat a page).", icon: "🔀",
         accepts: pdfExts, run: opReorder, fields: [
            Field(key: "order", label: "New order", placeholder: "For example 3,1,2 or 8-1 to reverse"),
            Field(key: "append_rest", label: "Keep the other pages at the end", kind: .bool, defaultValue: "true"),
         ], askPassword: true, keywords: "organize arrange sort move"),
    Tool(id: "rotate", name: "Rotate PDF", category: "Organize", summary: "Turn all pages, or only some, to the right orientation.", icon: "🔄",
         accepts: pdfExts, run: opRotate, fields: [
            Field(key: "angle", label: "Rotate", kind: .choice, defaultValue: "90",
                  choices: [Choice("90", "90° clockwise"), Choice("180", "180°"), Choice("270", "90° counter-clockwise")]),
            pagesField,
         ], askPassword: true, keywords: "turn orientation landscape portrait"),

    // Optimize
    Tool(id: "compress", name: "Compress PDF", category: "Optimize", summary: "Make the file smaller, keeping it readable.", icon: "🗜️",
         accepts: pdfExts, run: opCompressPDF, fields: [
            Field(key: "level", label: "Compression", kind: .choice, defaultValue: "medium",
                  choices: [Choice("low", "Light: best quality"), Choice("medium", "Balanced"), Choice("high", "Strong: smallest file")]),
         ], askPassword: true, keywords: "reduce size shrink smaller email"),
    Tool(id: "repair", name: "Repair PDF", category: "Optimize", summary: "Try to recover a PDF that won't open or is damaged.", icon: "🛟",
         accepts: pdfExts, run: opRepair, askPassword: true, keywords: "fix corrupt damaged broken recover"),
    Tool(id: "ocr", name: "OCR PDF", category: "Optimize", summary: "Turn a scanned PDF into one where the text can be searched and copied.", icon: "🔍",
         accepts: pdfExts, run: opOCR, fields: [
            Field(key: "language", label: "Language", kind: .text, defaultValue: "en-US", placeholder: "en-US",
                  help: "Language codes such as en-US, it-IT, de-DE, fr-FR, es-ES. Separate several with commas."),
            Field(key: "dpi", label: "Quality", kind: .choice, defaultValue: "300",
                  choices: [Choice("200", "200 dpi (faster)"), Choice("300", "300 dpi (recommended)"), Choice("400", "400 dpi (small print)")]),
         ], askPassword: true, keywords: "scan text recognition searchable"),

    // Convert to PDF
    Tool(id: "images_to_pdf", name: "Images to PDF", category: "Convert to PDF", summary: "Put JPG, PNG and other pictures into one PDF.", icon: "🖼️",
         accepts: pictureExts, run: opImagesToPdf, fields: [
            Field(key: "page_size", label: "Page size", kind: .choice, defaultValue: "A4",
                  choices: [Choice("A4", "A4"), Choice("Letter", "US Letter"), Choice("fit", "Same shape as the image")]),
            Field(key: "margin", label: "Margin (points)", kind: .int, defaultValue: "18", showIf: ("page_size", "A4")),
         ], ordered: true, keywords: "jpg png photo picture scan heic"),
    Tool(id: "office_to_pdf", name: "Office to PDF", category: "Convert to PDF", summary: "Word, Excel, PowerPoint, text and web pages to PDF.", icon: "📝",
         accepts: textDocExts + officeOtherExts, run: opOfficeToPDF, unavailable: officeMessage, keywords: "word excel powerpoint docx xlsx pptx odt txt html"),

    // Convert from PDF
    Tool(id: "pdf_to_images", name: "PDF to images", category: "Convert from PDF", summary: "Save each page as a JPG or PNG picture.", icon: "📷",
         accepts: pdfExts, run: opPdfToImages, fields: [
            Field(key: "format", label: "Format", kind: .choice, defaultValue: "png", choices: [Choice("png", "PNG (sharp)"), Choice("jpg", "JPG (smaller)")]),
            Field(key: "dpi", label: "Resolution", kind: .choice, defaultValue: "150",
                  choices: [Choice("72", "72 dpi (screen)"), Choice("150", "150 dpi"), Choice("200", "200 dpi"), Choice("300", "300 dpi (print)")]),
            pagesField,
         ], askPassword: true, keywords: "jpg png picture export"),
    Tool(id: "pdf_to_text", name: "PDF to text", category: "Convert from PDF", summary: "Copy all the text of a PDF into a .txt file.", icon: "🔤",
         accepts: pdfExts, run: opPdfToText, fields: [Field(key: "page_marks", label: "Mark where each page starts", kind: .bool, defaultValue: "true")],
         askPassword: true, keywords: "txt extract copy"),
    Tool(id: "pdf_to_word", name: "PDF to Word", category: "Convert from PDF", summary: "Make an editable .docx. The layout is approximate.", icon: "📘",
         accepts: pdfExts, run: opPdfToWord, unavailable: officeMessage, keywords: "docx editable"),
    Tool(id: "pdf_to_powerpoint", name: "PDF to PowerPoint", category: "Convert from PDF", summary: "Make a .pptx. The layout is approximate.", icon: "📙",
         accepts: pdfExts, run: opPdfToPowerPoint, unavailable: officeMessage, keywords: "pptx slides"),

    // Edit
    Tool(id: "page_numbers", name: "Add page numbers", category: "Edit", summary: "Number the pages, wherever you like.", icon: "🔢",
         accepts: pdfExts, run: opPageNumbers, fields: [
            Field(key: "position", label: "Position", kind: .choice, defaultValue: "bottom center", choices: positions),
            Field(key: "format", label: "Text", kind: .text, defaultValue: "{n}", help: "{n} is the page number and {total} the number of pages. Example: Page {n} of {total}"),
            Field(key: "start", label: "Start at", kind: .int, defaultValue: "1"),
            Field(key: "skip_first", label: "Don't number the first page (cover)", kind: .bool, defaultValue: "false"),
            Field(key: "size", label: "Font size", kind: .int, defaultValue: "11"),
            pagesField,
         ], askPassword: true, keywords: "numbering footer header"),
    Tool(id: "watermark", name: "Add watermark", category: "Edit", summary: "Stamp a text such as CONFIDENTIAL or DRAFT on the pages.", icon: "💧",
         accepts: pdfExts, run: opWatermarkPDF, fields: [
            Field(key: "text", label: "Text", kind: .text, defaultValue: "CONFIDENTIAL"),
            Field(key: "color", label: "Color", kind: .choice, defaultValue: "gray",
                  choices: [Choice("gray", "Gray"), Choice("red", "Red"), Choice("blue", "Blue"), Choice("black", "Black"), Choice("green", "Green")]),
            Field(key: "opacity", label: "Opacity (%)", kind: .int, defaultValue: "25"),
            Field(key: "size", label: "Font size", kind: .int, defaultValue: "64"),
            Field(key: "angle", label: "Angle (degrees)", kind: .int, defaultValue: "45"),
            Field(key: "position", label: "Position", kind: .choice, defaultValue: "center", choices: positions),
            pagesField,
         ], askPassword: true, keywords: "stamp draft confidential text"),
    Tool(id: "stamp_image", name: "Add image / signature", category: "Edit", summary: "Place a picture, such as your signature or a logo, on the pages.", icon: "✍️",
         accepts: pdfExts, run: opStampImage, fields: [
            Field(key: "image", label: "Image", kind: .file, help: "A PNG with a transparent background works best for signatures."),
            Field(key: "position", label: "Position", kind: .choice, defaultValue: "bottom right", choices: positions),
            Field(key: "width", label: "Width (% of the page)", kind: .int, defaultValue: "25"),
            Field(key: "opacity", label: "Opacity (%)", kind: .int, defaultValue: "100"),
            pagesField,
         ], askPassword: true, keywords: "sign signature logo picture stamp"),
    Tool(id: "crop", name: "Crop PDF", category: "Edit", summary: "Cut away margins from the pages.", icon: "📐",
         accepts: pdfExts, run: opCropPDF, fields: [
            Field(key: "top", label: "Top (mm)", kind: .int, defaultValue: "0"),
            Field(key: "bottom", label: "Bottom (mm)", kind: .int, defaultValue: "0"),
            Field(key: "left", label: "Left (mm)", kind: .int, defaultValue: "0"),
            Field(key: "right", label: "Right (mm)", kind: .int, defaultValue: "0"),
            pagesField,
         ], askPassword: true, keywords: "trim margins cut"),

    // Review & security
    Tool(id: "protect", name: "Protect PDF", category: "Review & security", summary: "Lock a PDF with a password.", icon: "🔒",
         accepts: pdfExts, run: opProtect, fields: [
            Field(key: "new_password", label: "Password to open the file", kind: .password),
            Field(key: "owner_password", label: "Owner password (optional)", kind: .password, help: "Needed to change the permissions. If empty, the same password is used."),
            Field(key: "allow_print", label: "Allow printing", kind: .bool, defaultValue: "true"),
            Field(key: "allow_copy", label: "Allow copying text", kind: .bool, defaultValue: "true"),
         ], askPassword: true, keywords: "password encrypt lock secure"),
    Tool(id: "unlock", name: "Unlock PDF", category: "Review & security", summary: "Remove the password from a PDF you have the password for.", icon: "🔓",
         accepts: pdfExts, run: opUnlock, fields: [
            Field(key: "password", label: "Current password", kind: .password, help: "Leave empty if the file only has restrictions (printing, copying) but opens freely."),
         ], keywords: "remove password decrypt"),
    Tool(id: "redact", name: "Redact PDF", category: "Review & security", summary: "Black out words for good, removing them from the file.", icon: "⬛",
         accepts: pdfExts, run: opRedact, fields: [
            Field(key: "terms", label: "Words to black out", kind: .multiline, placeholder: "One per line, or separated by commas"),
            Field(key: "match_case", label: "Match upper/lower case", kind: .bool, defaultValue: "false"),
            Field(key: "dpi", label: "Quality of redacted pages", kind: .choice, defaultValue: "200",
                  choices: [Choice("150", "150 dpi"), Choice("200", "200 dpi"), Choice("300", "300 dpi")]),
         ], askPassword: true, keywords: "censor hide black out remove words names",
         hint: "Pages with redactions become pictures, so the hidden text can't be recovered."),
    Tool(id: "compare", name: "Compare PDF", category: "Review & security", summary: "See what changed in the text between two versions.", icon: "🆚",
         accepts: pdfExts, run: opCompare, minFiles: 2, maxFiles: 2, ordered: true, askPassword: true, keywords: "diff differences versions",
         hint: "Opens as a web page: green is new, red is removed."),

    // Images
    Tool(id: "compress_images", name: "Compress image", category: "Images", summary: "Make photos and pictures smaller, keeping them looking good.", icon: "🗜️",
         accepts: pictureExts, run: opCompressImages, fields: [
            Field(key: "level", label: "Compression", kind: .choice, defaultValue: "medium",
                  choices: [Choice("low", "Light: best quality"), Choice("medium", "Balanced"), Choice("high", "Strong: smallest file")]),
            Field(key: "max_side", label: "Also limit the longest side to", kind: .choice, defaultValue: "0",
                  choices: [Choice("0", "Keep the size"), Choice("4000", "4000 pixels"), Choice("3000", "3000 pixels"), Choice("2000", "2000 pixels"),
                            Choice("1600", "1600 pixels"), Choice("1080", "1080 pixels")]),
         ], keywords: "reduce size shrink smaller jpg png photo"),
    Tool(id: "resize_images", name: "Resize image", category: "Images", summary: "Change the size of pictures by percentage or in pixels.", icon: "↔️",
         accepts: pictureExts, run: opResizeImages, fields: [
            Field(key: "mode", label: "Resize", kind: .choice, defaultValue: "percent",
                  choices: [Choice("percent", "By percentage"), Choice("width", "To a width"), Choice("height", "To a height"), Choice("fit", "To fit inside a box")]),
            Field(key: "percent", label: "Percentage", kind: .int, defaultValue: "50", showIf: ("mode", "percent")),
            Field(key: "width", label: "Width (pixels)", kind: .int, defaultValue: "1280"),
            Field(key: "height", label: "Height (pixels)", kind: .int, defaultValue: "720"),
            Field(key: "no_enlarge", label: "Never make a picture bigger than it is", kind: .bool, defaultValue: "true"),
         ], keywords: "scale dimensions pixels smaller bigger"),
    Tool(id: "crop_images", name: "Crop image", category: "Images", summary: "Cut pictures to a shape like 1:1 or 16:9, or trim the edges.", icon: "✂️",
         accepts: pictureExts, run: opCropImages, fields: [
            Field(key: "mode", label: "Crop", kind: .choice, defaultValue: "ratio",
                  choices: [Choice("ratio", "To a shape (aspect ratio)"), Choice("margins", "By trimming the edges")]),
            Field(key: "ratio", label: "Shape", kind: .choice, defaultValue: "1:1",
                  choices: [Choice("1:1", "Square 1:1"), Choice("4:3", "4:3"), Choice("3:2", "3:2"), Choice("16:9", "Wide 16:9"),
                            Choice("3:4", "Portrait 3:4"), Choice("2:3", "Portrait 2:3"), Choice("9:16", "Tall 9:16")], showIf: ("mode", "ratio")),
            Field(key: "anchor", label: "Keep the", kind: .choice, defaultValue: "center",
                  choices: [Choice("center", "Center"), Choice("top", "Top"), Choice("bottom", "Bottom"), Choice("left", "Left"), Choice("right", "Right")], showIf: ("mode", "ratio")),
            Field(key: "top", label: "Top (pixels)", kind: .int, defaultValue: "0", showIf: ("mode", "margins")),
            Field(key: "bottom", label: "Bottom (pixels)", kind: .int, defaultValue: "0", showIf: ("mode", "margins")),
            Field(key: "left", label: "Left (pixels)", kind: .int, defaultValue: "0", showIf: ("mode", "margins")),
            Field(key: "right", label: "Right (pixels)", kind: .int, defaultValue: "0", showIf: ("mode", "margins")),
         ], keywords: "trim square ratio cut"),
    Tool(id: "rotate_images", name: "Rotate / flip image", category: "Images", summary: "Turn pictures or mirror them.", icon: "🔄",
         accepts: pictureExts, run: opRotateImages, fields: [
            Field(key: "angle", label: "Rotate", kind: .choice, defaultValue: "90",
                  choices: [Choice("0", "Don't rotate"), Choice("90", "90° clockwise"), Choice("180", "180°"), Choice("270", "90° counter-clockwise")]),
            Field(key: "flip", label: "Flip", kind: .choice, defaultValue: "none",
                  choices: [Choice("none", "Don't flip"), Choice("horizontal", "Left to right"), Choice("vertical", "Top to bottom")]),
         ], keywords: "turn mirror flip orientation"),
    Tool(id: "convert_images", name: "Convert image", category: "Images", summary: "Change the format: JPG, PNG, TIFF, GIF, BMP, ICO, HEIC.", icon: "🖼️",
         accepts: pictureExts, run: opConvertImages, fields: [
            Field(key: "target", label: "Convert to", kind: .choice, defaultValue: "jpg", choices: convertTargets()),
            Field(key: "quality", label: "Quality (JPG, HEIC)", kind: .int, defaultValue: "90"),
         ], keywords: "jpg png heic gif bmp tiff ico format change"),
    Tool(id: "watermark_images", name: "Watermark image", category: "Images", summary: "Write your name or a text on pictures.", icon: "💧",
         accepts: pictureExts, run: opWatermarkImages, fields: [
            Field(key: "text", label: "Text", kind: .text, defaultValue: "© My name"),
            Field(key: "position", label: "Position", kind: .choice, defaultValue: "bottom right", choices: positions),
            Field(key: "size", label: "Text size (% of the width)", kind: .int, defaultValue: "6"),
            Field(key: "opacity", label: "Opacity (%)", kind: .int, defaultValue: "60"),
            Field(key: "color", label: "Color", kind: .choice, defaultValue: "white",
                  choices: [Choice("white", "White"), Choice("black", "Black"), Choice("gray", "Gray"), Choice("red", "Red"), Choice("blue", "Blue")]),
            Field(key: "angle", label: "Angle (degrees)", kind: .int, defaultValue: "0"),
         ], keywords: "text stamp copyright protect"),
    Tool(id: "strip_metadata", name: "Remove photo data", category: "Images", summary: "Erase location, camera and date information hidden in photos.", icon: "🧹",
         accepts: pictureExts, run: opStripMetadata, keywords: "exif gps location privacy metadata clean",
         hint: "JPEG photos are cleaned without any loss of quality."),

    // Audio & video
    Tool(id: "convert_audio", name: "Convert audio", category: "Audio & video", summary: "M4A, WAV, AIFF, FLAC (and MP3, OGG, Opus with ffmpeg).", icon: "🎵",
         accepts: audioExts, run: opConvertAudio, fields: [
            Field(key: "target", label: "Convert to", kind: .choice, defaultValue: "m4a", choices: audioTargets()),
            Field(key: "bitrate", label: "Quality (MP3, M4A, OGG, Opus)", kind: .choice, defaultValue: "192k",
                  choices: [Choice("128k", "128 kbps"), Choice("192k", "192 kbps"), Choice("256k", "256 kbps"), Choice("320k", "320 kbps")]),
         ], keywords: "mp3 wav flac m4a ogg opus music sound"),
    Tool(id: "convert_video", name: "Convert video", category: "Audio & video", summary: "MP4, MOV, M4V (and MKV, WebM, AVI, GIF with ffmpeg).", icon: "🎬",
         accepts: videoExts, run: opConvertVideo, fields: [
            Field(key: "target", label: "Convert to", kind: .choice, defaultValue: "mp4", choices: videoTargets()),
            Field(key: "quality", label: "Quality (with ffmpeg)", kind: .choice, defaultValue: "balanced",
                  choices: [Choice("small", "Smaller file"), Choice("balanced", "Balanced"), Choice("high", "Best quality")]),
            Field(key: "max_height", label: "Maximum height", kind: .choice, defaultValue: "keep",
                  choices: [Choice("keep", "Keep the size"), Choice("1080", "1080p"), Choice("720", "720p"), Choice("480", "480p")]),
         ], keywords: "mp4 mkv webm mov avi gif film movie clip", hint: "Videos can take a while: the progress bar shows how far it is."),
    Tool(id: "compress_video", name: "Compress video", category: "Audio & video", summary: "Make a video much smaller to send or share.", icon: "📉",
         accepts: videoExts, run: opCompressVideo, fields: [
            Field(key: "level", label: "Compression", kind: .choice, defaultValue: "medium",
                  choices: [Choice("light", "Light"), Choice("medium", "Balanced"), Choice("strong", "Strong: smallest file")]),
            Field(key: "max_height", label: "Maximum height", kind: .choice, defaultValue: "keep",
                  choices: [Choice("keep", "Keep the size"), Choice("1080", "1080p"), Choice("720", "720p"), Choice("480", "480p")]),
         ], keywords: "reduce size shrink smaller email whatsapp"),
    Tool(id: "extract_audio", name: "Video to audio", category: "Audio & video", summary: "Save the sound of a video as M4A, WAV or FLAC (MP3 with ffmpeg).", icon: "🎧",
         accepts: videoExts, run: opExtractAudio, fields: [
            Field(key: "target", label: "Save as", kind: .choice, defaultValue: "m4a", choices: [Choice("m4a", "M4A (AAC)"), Choice("wav", "WAV"), Choice("flac", "FLAC"), Choice("mp3", "MP3 (needs ffmpeg)")]),
            Field(key: "bitrate", label: "Quality (MP3, M4A)", kind: .choice, defaultValue: "192k",
                  choices: [Choice("128k", "128 kbps"), Choice("192k", "192 kbps"), Choice("256k", "256 kbps"), Choice("320k", "320 kbps")]),
         ], keywords: "mp3 soundtrack extract rip"),

    // Documents
    Tool(id: "convert_document", name: "Convert document", category: "Documents", summary: "Word, OpenDocument, RTF, HTML, text and PDF: change the format.", icon: "📄",
         accepts: textDocExts, run: opConvertDocument, fields: [
            Field(key: "target", label: "Convert to", kind: .choice, defaultValue: "pdf",
                  choices: [Choice("pdf", "PDF"), Choice("docx", "Word (.docx)"), Choice("doc", "Word 97 (.doc)"), Choice("odt", "OpenDocument (.odt)"),
                            Choice("rtf", "RTF"), Choice("html", "Web page (.html)"), Choice("txt", "Plain text (.txt)")]),
         ], keywords: "docx doc odt rtf html txt word format"),
]

func audioTargets() -> [Choice] {
    return [Choice("m4a", "M4A (AAC)"), Choice("wav", "WAV"), Choice("aiff", "AIFF"), Choice("flac", "FLAC"),
            Choice("mp3", "MP3 (needs ffmpeg)"), Choice("ogg", "OGG (needs ffmpeg)"), Choice("opus", "Opus (needs ffmpeg)")]
}

func videoTargets() -> [Choice] {
    return [Choice("mp4", "MP4"), Choice("mov", "MOV"), Choice("m4v", "M4V"), Choice("mkv", "MKV (needs ffmpeg)"),
            Choice("webm", "WebM (needs ffmpeg)"), Choice("avi", "AVI (needs ffmpeg)"), Choice("gif", "Animated GIF (needs ffmpeg)")]
}

func toolNamed(_ id: String) -> Tool? {
    return allTools.first { $0.id == id }
}
