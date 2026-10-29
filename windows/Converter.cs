using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace FileWheel
{
    public class ConvertException : Exception
    {
        public ConvertException(string message) : base(message) { }
    }

    /// <summary>The conversion engine: picks the right tool for every file type.</summary>
    public static class Converter
    {
        public static async Task<string> ConvertAsync(string input, string ext, Category category, string outputDir)
        {
            string baseName = Path.GetFileNameWithoutExtension(input);

            if (category == Category.Pdf)
                return await WinRt.PdfToImagesAsync(input, outputDir, baseName, ext);

            string output = UniqueName(outputDir, baseName, ext);
            try
            {
                switch (category)
                {
                    case Category.Image: await ConvertImageAsync(input, output, ext); break;
                    case Category.Audio: await ConvertAudioAsync(input, output, ext); break;
                    case Category.Video: await ConvertVideoAsync(input, output, ext); break;
                    case Category.Document: await ConvertDocumentAsync(input, output, ext); break;
                }
            }
            catch
            {
                TryDelete(output);   // never leave a half-written file behind
                throw;
            }
            return output;
        }

        /// <summary>name.ext, or "name 2.ext", "name 3.ext"... so nothing is ever overwritten.</summary>
        public static string UniqueName(string dir, string baseName, string ext)
        {
            string path = Path.Combine(dir, baseName + "." + ext);
            int n = 2;
            while (File.Exists(path))
            {
                path = Path.Combine(dir, baseName + " " + n + "." + ext);
                n++;
            }
            return path;
        }

        // ---------------------------------------------------------------- Images

        static async Task ConvertImageAsync(string input, string output, string ext)
        {
            string srcExt = Formats.Normalize(Path.GetExtension(input));

            if (ext == "webp")
            {
                await ProcessRunner.RunAsync(RequireFfmpeg("WebP"),
                    "-y -loglevel error -i " + Q(input) + " " + Q(output));
                return;
            }

            // HEIC / HEIF / WebP can't be read by GDI+: decode them to a temporary PNG first.
            string readable = input;
            string temp = null;
            if (srcExt == "heic" || srcExt == "heif" || srcExt == "webp")
            {
                temp = Path.Combine(Path.GetTempPath(), "filewheel-" + Guid.NewGuid().ToString("N") + ".png");
                if (srcExt == "webp" && Tools.Ffmpeg != null)
                    await ProcessRunner.RunAsync(Tools.Ffmpeg, "-y -loglevel error -i " + Q(input) + " " + Q(temp));
                else
                    await WinRt.DecodeToPngAsync(input, temp);
                readable = temp;
            }

            try
            {
                string source = readable;
                if (ext == "pdf")
                    await Task.Run(delegate { PdfWriter.FromImage(source, output); });
                else
                    await Task.Run(delegate { ImageIo.Convert(source, output, ext); });
            }
            finally
            {
                if (temp != null) TryDelete(temp);
            }
        }

        // ---------------------------------------------------------------- Audio / video

        static async Task ConvertAudioAsync(string input, string output, string ext)
        {
            string ff = Tools.Ffmpeg;
            if (ff != null)
            {
                await ProcessRunner.RunAsync(ff, "-y -loglevel error -threads " + Threads() + " -i " + Q(input) + " -vn " + Q(output));
                return;
            }
            if (ext != "mp3" && ext != "m4a" && ext != "wav" && ext != "flac" && ext != "wma")
                throw new ConvertException(ext.ToUpperInvariant() + " requires ffmpeg (winget install Gyan.FFmpeg)");
            await WinRt.TranscodeAsync(input, output, ext);
        }

        static async Task ConvertVideoAsync(string input, string output, string ext)
        {
            string ff = Tools.Ffmpeg;
            if (ff != null)
            {
                string extra = "";
                switch (ext)
                {
                    case "mp3":
                    case "m4a": extra = "-vn "; break;
                    case "gif": extra = "-vf fps=12,scale=640:-1:flags=lanczos "; break;
                    case "mp4":
                    case "mov":
                    case "mkv": extra = "-preset veryfast "; break;
                }
                string t = Threads();
                await ProcessRunner.RunAsync(ff, "-y -loglevel error -threads " + t + " -i " + Q(input) + " " + extra + "-threads " + t + " " + Q(output));
                return;
            }
            if (ext != "mp4" && ext != "wmv")
                throw new ConvertException(ext.ToUpperInvariant() + " requires ffmpeg (winget install Gyan.FFmpeg)");
            await WinRt.TranscodeAsync(input, output, ext);
        }

        static string RequireFfmpeg(string what)
        {
            string ff = Tools.Ffmpeg;
            if (ff == null) throw new ConvertException(what + " requires ffmpeg (winget install Gyan.FFmpeg)");
            return ff;
        }

        /// <summary>Half of the cores: keeps the PC responsive during heavy conversions.</summary>
        static string Threads()
        {
            return Math.Max(1, Environment.ProcessorCount / 2).ToString(CultureInfo.InvariantCulture);
        }

        // ---------------------------------------------------------------- Documents

        static async Task ConvertDocumentAsync(string input, string output, string ext)
        {
            Exception wordError = null;
            if (Tools.WordAvailable)
            {
                try
                {
                    await RunOnStaAsync(delegate { ConvertWithWord(input, output, ext); });
                    return;
                }
                catch (Exception ex)
                {
                    wordError = ex;
                    TryDelete(output);
                }
            }
            if (Tools.LibreOffice != null)
            {
                await ConvertWithLibreOfficeAsync(input, output, ext);
                return;
            }
            if (wordError != null)
                throw new ConvertException("Word could not convert this file: " + wordError.Message);
            throw new ConvertException("Documents need Microsoft Word or LibreOffice");
        }

        static Task RunOnStaAsync(Action action)
        {
            TaskCompletionSource<bool> tcs = new TaskCompletionSource<bool>();
            Thread thread = new Thread(delegate ()
            {
                try { action(); tcs.SetResult(true); }
                catch (Exception ex) { tcs.SetException(ex); }
            });
            thread.SetApartmentState(ApartmentState.STA);   // Word's COM interface needs an STA thread
            thread.IsBackground = true;
            thread.Start();
            return tcs.Task;
        }

        static int WordFormat(string ext)
        {
            switch (ext)
            {
                case "pdf": return 17;    // wdFormatPDF
                case "docx": return 16;   // wdFormatDocumentDefault
                case "doc": return 0;     // wdFormatDocument
                case "odt": return 23;    // wdFormatOpenDocumentText
                case "rtf": return 6;     // wdFormatRTF
                case "html": return 10;   // wdFormatFilteredHTML
                case "txt": return 7;     // wdFormatUnicodeText
                default: throw new ConvertException("Unsupported format: " + ext);
            }
        }

        static void ConvertWithWord(string input, string output, string ext)
        {
            Type type = Type.GetTypeFromProgID("Word.Application");
            if (type == null) throw new ConvertException("Microsoft Word is not installed");
            dynamic word = Activator.CreateInstance(type);
            try
            {
                word.Visible = false;
                word.DisplayAlerts = 0;
                dynamic doc = word.Documents.Open(input, false, true);   // no conversion dialog, read-only
                try { doc.SaveAs2(output, WordFormat(ext)); }
                finally { doc.Close(false); }
            }
            finally
            {
                word.Quit(false);
            }
        }

        static async Task ConvertWithLibreOfficeAsync(string input, string output, string ext)
        {
            string work = Path.Combine(Path.GetTempPath(), "filewheel-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            try
            {
                string outDir = Path.Combine(work, "out");
                Directory.CreateDirectory(outDir);
                // A private profile folder lets this run even if LibreOffice is already open.
                string profile = new Uri(Path.Combine(work, "profile")).AbsoluteUri;
                string filter = ext == "txt" ? "txt:Text" : ext;
                await ProcessRunner.RunAsync(Tools.LibreOffice,
                    "-env:UserInstallation=" + profile + " --headless --norestore --convert-to " + filter +
                    " --outdir " + Q(outDir) + " " + Q(input));
                string produced = Path.Combine(outDir, Path.GetFileNameWithoutExtension(input) + "." + ext);
                if (!File.Exists(produced)) throw new ConvertException("LibreOffice did not produce a file");
                File.Move(produced, output);
            }
            finally
            {
                try { Directory.Delete(work, true); } catch { }
            }
        }

        // ---------------------------------------------------------------- Helpers

        static string Q(string s)
        {
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        }

        static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }

    /// <summary>Runs an external program at low priority and reports its error output on failure.</summary>
    public static class ProcessRunner
    {
        public static Task RunAsync(string file, string arguments)
        {
            TaskCompletionSource<bool> tcs = new TaskCompletionSource<bool>();
            StringBuilder err = new StringBuilder();

            ProcessStartInfo info = new ProcessStartInfo(file, arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardError = true;
            info.RedirectStandardOutput = true;

            Process p = new Process();
            p.StartInfo = info;
            p.EnableRaisingEvents = true;
            p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e)
            {
                if (e.Data != null)
                    lock (err) { if (err.Length < 4000) err.AppendLine(e.Data); }
            };
            p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { };
            p.Exited += delegate (object s, EventArgs e)
            {
                int code;
                try { p.WaitForExit(); code = p.ExitCode; }
                catch { code = -1; }
                string text;
                lock (err) { text = err.ToString().Trim(); }
                if (code == 0)
                    tcs.TrySetResult(true);
                else
                    tcs.TrySetException(new ConvertException(
                        text.Length == 0 ? "Conversion failed (code " + code + ")" : Tail(text, 300)));
                try { p.Dispose(); } catch { }
            };

            try
            {
                p.Start();
            }
            catch (Exception ex)
            {
                tcs.TrySetException(new ConvertException("Could not start " + Path.GetFileName(file) + ": " + ex.Message));
                return tcs.Task;
            }
            try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            p.BeginErrorReadLine();
            p.BeginOutputReadLine();
            return tcs.Task;
        }

        static string Tail(string s, int max)
        {
            return s.Length <= max ? s : s.Substring(s.Length - max);
        }
    }

    /// <summary>Image reading/writing with GDI+, which is built into Windows.</summary>
    public static class ImageIo
    {
        public static void Convert(string input, string output, string ext)
        {
            // JPEG and BMP don't support transparency: flatten onto a white background.
            using (Bitmap bmp = Load(input, ext == "jpg" || ext == "bmp"))
            {
                switch (ext)
                {
                    case "png": bmp.Save(output, ImageFormat.Png); break;
                    case "jpg": SaveJpeg(bmp, output, 90L); break;
                    case "bmp": bmp.Save(output, ImageFormat.Bmp); break;
                    case "gif": bmp.Save(output, ImageFormat.Gif); break;   // animated GIFs keep only the first frame
                    case "tiff": bmp.Save(output, ImageFormat.Tiff); break;
                    default: throw new ConvertException("Unsupported format: " + ext);
                }
            }
        }

        /// <summary>Loads an image into a fresh 32-bit bitmap, applying the camera rotation (EXIF).</summary>
        public static Bitmap Load(string path, bool flattenOnWhite)
        {
            Image src;
            try { src = Image.FromFile(path); }
            catch (Exception) { throw new ConvertException("Unreadable image"); }

            using (src)
            {
                RotateFlipType rotation = ExifRotation(src);
                if (rotation != RotateFlipType.RotateNoneFlipNone) src.RotateFlip(rotation);

                Bitmap result = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
                // Some files declare a resolution of 0 dpi, which GDI+ rejects: only copy valid values.
                if (src.HorizontalResolution > 0f && src.VerticalResolution > 0f)
                    result.SetResolution(src.HorizontalResolution, src.VerticalResolution);
                using (Graphics g = Graphics.FromImage(result))
                {
                    if (flattenOnWhite) g.Clear(Color.White);
                    g.CompositingMode = CompositingMode.SourceOver;
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;   // exact 1:1 copy
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.DrawImage(src, new Rectangle(0, 0, src.Width, src.Height),
                        0, 0, src.Width, src.Height, GraphicsUnit.Pixel);
                }
                return result;
            }
        }

        static RotateFlipType ExifRotation(Image img)
        {
            try
            {
                if (Array.IndexOf(img.PropertyIdList, 0x0112) < 0) return RotateFlipType.RotateNoneFlipNone;
                int orientation = img.GetPropertyItem(0x0112).Value[0];
                switch (orientation)
                {
                    case 2: return RotateFlipType.RotateNoneFlipX;
                    case 3: return RotateFlipType.Rotate180FlipNone;
                    case 4: return RotateFlipType.Rotate180FlipX;
                    case 5: return RotateFlipType.Rotate90FlipX;
                    case 6: return RotateFlipType.Rotate90FlipNone;
                    case 7: return RotateFlipType.Rotate270FlipX;
                    case 8: return RotateFlipType.Rotate270FlipNone;
                    default: return RotateFlipType.RotateNoneFlipNone;
                }
            }
            catch
            {
                return RotateFlipType.RotateNoneFlipNone;
            }
        }

        static EncoderParameters QualityParams(long quality)
        {
            EncoderParameters p = new EncoderParameters(1);
            p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
            return p;
        }

        static ImageCodecInfo JpegCodec()
        {
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders())
                if (c.FormatID == ImageFormat.Jpeg.Guid) return c;
            throw new ConvertException("JPEG encoder not available");
        }

        public static void SaveJpeg(Image img, string path, long quality)
        {
            using (EncoderParameters p = QualityParams(quality))
                img.Save(path, JpegCodec(), p);
        }

        public static byte[] EncodeJpeg(Image img, long quality)
        {
            using (MemoryStream ms = new MemoryStream())
            using (EncoderParameters p = QualityParams(quality))
            {
                img.Save(ms, JpegCodec(), p);
                return ms.ToArray();
            }
        }
    }

    /// <summary>Writes a one-page PDF that contains a picture (Windows has no built-in PDF writer).</summary>
    public static class PdfWriter
    {
        public static void FromImage(string imagePath, string output)
        {
            byte[] jpeg;
            int w;
            int h;
            using (Bitmap bmp = ImageIo.Load(imagePath, true))
            {
                w = bmp.Width;
                h = bmp.Height;
                jpeg = ImageIo.EncodeJpeg(bmp, 92L);
            }

            string pageW = Num(w * 0.75);   // pixels at 96 dpi to PDF points
            string pageH = Num(h * 0.75);

            using (MemoryStream ms = new MemoryStream())
            {
                List<long> offsets = new List<long>();
                Ascii(ms, "%PDF-1.4\n");
                Obj(ms, offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>");
                Obj(ms, offsets, 2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
                Obj(ms, offsets, 3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + pageW + " " + pageH + "] " +
                    "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>");

                offsets.Add(ms.Position);
                Ascii(ms, "4 0 obj\n<< /Type /XObject /Subtype /Image /Width " + w + " /Height " + h +
                    " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " + jpeg.Length + " >>\nstream\n");
                ms.Write(jpeg, 0, jpeg.Length);
                Ascii(ms, "\nendstream\nendobj\n");

                string content = "q " + pageW + " 0 0 " + pageH + " 0 0 cm /Im0 Do Q";
                Obj(ms, offsets, 5, "<< /Length " + content.Length + " >>\nstream\n" + content + "\nendstream");

                long xref = ms.Position;
                StringBuilder sb = new StringBuilder();
                sb.Append("xref\n0 6\n0000000000 65535 f \n");
                foreach (long offset in offsets)
                    sb.Append(offset.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
                sb.Append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n")
                  .Append(xref.ToString(CultureInfo.InvariantCulture)).Append("\n%%EOF\n");
                Ascii(ms, sb.ToString());

                File.WriteAllBytes(output, ms.ToArray());
            }
        }

        static void Obj(MemoryStream ms, List<long> offsets, int number, string body)
        {
            offsets.Add(ms.Position);
            Ascii(ms, number + " 0 obj\n" + body + "\nendobj\n");
        }

        static void Ascii(MemoryStream ms, string text)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(text);
            ms.Write(bytes, 0, bytes.Length);
        }

        static string Num(double value)
        {
            return value.ToString("0.##", CultureInfo.InvariantCulture);
        }
    }
}
