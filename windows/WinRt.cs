using System;
using System.IO;
using System.Threading.Tasks;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;

namespace FileWheel
{
    /// <summary>
    /// Parts that use the Windows Runtime APIs built into Windows 10/11:
    /// image codecs (HEIC, WebP), Media Foundation transcoding, and PDF page rendering.
    /// </summary>
    internal static class WinRt
    {
        // ---------------------------------------------------------------- HEIC / WebP decoding

        public static async Task DecodeToPngAsync(string input, string pngPath)
        {
            try
            {
                StorageFile file = await StorageFile.GetFileFromPathAsync(input);
                using (IRandomAccessStream stream = await file.OpenReadAsync())
                {
                    BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream);
                    using (SoftwareBitmap bitmap = await decoder.GetSoftwareBitmapAsync(
                        BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, new BitmapTransform(),
                        ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage))
                    {
                        StorageFolder folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(pngPath));
                        StorageFile outFile = await folder.CreateFileAsync(Path.GetFileName(pngPath), CreationCollisionOption.ReplaceExisting);
                        using (IRandomAccessStream outStream = await outFile.OpenAsync(FileAccessMode.ReadWrite))
                        {
                            BitmapEncoder encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, outStream);
                            encoder.SetSoftwareBitmap(bitmap);
                            await encoder.FlushAsync();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                throw new ConvertException("Could not decode this image. For HEIC or WebP, install the " +
                    "HEIF or WebP image extensions from the Microsoft Store. (" + ex.Message + ")");
            }
        }

        // ---------------------------------------------------------------- Audio / video (Media Foundation)

        static MediaEncodingProfile ProfileFor(string ext)
        {
            switch (ext)
            {
                case "mp4": return MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Auto);
                case "wmv": return MediaEncodingProfile.CreateWmv(VideoEncodingQuality.Auto);
                case "mp3": return MediaEncodingProfile.CreateMp3(AudioEncodingQuality.High);
                case "m4a": return MediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
                case "wav": return MediaEncodingProfile.CreateWav(AudioEncodingQuality.High);
                case "flac": return MediaEncodingProfile.CreateFlac(AudioEncodingQuality.High);
                case "wma": return MediaEncodingProfile.CreateWma(AudioEncodingQuality.High);
                default: throw new ConvertException("Unsupported format: " + ext);
            }
        }

        public static async Task TranscodeAsync(string input, string output, string ext)
        {
            MediaEncodingProfile profile = ProfileFor(ext);
            StorageFile source;
            StorageFile target;
            try
            {
                source = await StorageFile.GetFileFromPathAsync(input);
                StorageFolder folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(output));
                target = await folder.CreateFileAsync(Path.GetFileName(output), CreationCollisionOption.ReplaceExisting);
            }
            catch (Exception ex)
            {
                throw new ConvertException("Could not open the file: " + ex.Message);
            }

            MediaTranscoder transcoder = new MediaTranscoder();
            PrepareTranscodeResult prepared = await transcoder.PrepareFileTranscodeAsync(source, target, profile);
            if (!prepared.CanTranscode)
            {
                throw new ConvertException("This file can't be converted to " + ext.ToUpperInvariant() +
                    " with the codecs built into Windows (" + prepared.FailureReason + "). Install ffmpeg for more formats.");
            }
            await prepared.TranscodeAsync();
        }

        // ---------------------------------------------------------------- PDF to images

        public static async Task<string> PdfToImagesAsync(string input, string dir, string baseName, string ext)
        {
            PdfDocument document;
            try
            {
                StorageFile file = await StorageFile.GetFileFromPathAsync(input);
                document = await PdfDocument.LoadFromFileAsync(file);
            }
            catch (Exception)
            {
                throw new ConvertException("Unreadable PDF (it may be password-protected)");
            }

            StorageFolder folder = await StorageFolder.GetFolderFromPathAsync(dir);
            string last = null;
            uint count = document.PageCount;
            for (uint i = 0; i < count; i++)
            {
                using (PdfPage page = document.GetPage(i))
                {
                    PdfPageRenderOptions options = new PdfPageRenderOptions();
                    options.DestinationWidth = (uint)(page.Size.Width * 2.0);   // 2x for a sharp result
                    options.BitmapEncoderId = ext == "png" ? BitmapEncoder.PngEncoderId : BitmapEncoder.JpegEncoderId;

                    string name = count > 1 ? baseName + "_page" + (i + 1) : baseName;
                    string path = Converter.UniqueName(dir, name, ext);
                    StorageFile outFile = await folder.CreateFileAsync(Path.GetFileName(path), CreationCollisionOption.ReplaceExisting);
                    using (IRandomAccessStream stream = await outFile.OpenAsync(FileAccessMode.ReadWrite))
                    {
                        await page.RenderToStreamAsync(stream, options);
                    }
                    last = path;
                }
            }
            if (last == null) throw new ConvertException("No pages were converted");
            return last;
        }
    }
}
