using System;
using System.Collections.Generic;
using System.IO;

namespace FileWheel
{
    public enum Category { Image, Audio, Video, Document, Pdf }

    /// <summary>Which file types exist, and which formats each one can be converted to.</summary>
    public static class Formats
    {
        static readonly string[] ImageExts = { "png", "jpg", "bmp", "gif", "tiff", "webp", "heic", "heif", "ico" };
        static readonly string[] AudioExts = { "mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg", "opus", "wma" };
        static readonly string[] VideoExts = { "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "3gp", "flv", "wmv" };
        static readonly string[] DocExts = { "txt", "md", "rtf", "html", "doc", "docx", "odt" };

        /// <summary>Maps equivalent extensions to a single form (jpeg to jpg, tif to tiff, ...).</summary>
        public static string Normalize(string ext)
        {
            if (ext == null) return "";
            string e = ext.TrimStart('.').ToLowerInvariant();
            switch (e)
            {
                case "jpeg": return "jpg";
                case "tif": return "tiff";
                case "aif": return "aiff";
                case "htm": return "html";
                case "mpeg": return "mpg";
                default: return e;
            }
        }

        public static bool TryDetect(string ext, out Category category)
        {
            string e = Normalize(ext);
            if (Array.IndexOf(ImageExts, e) >= 0) { category = Category.Image; return true; }
            if (Array.IndexOf(AudioExts, e) >= 0) { category = Category.Audio; return true; }
            if (Array.IndexOf(VideoExts, e) >= 0) { category = Category.Video; return true; }
            if (Array.IndexOf(DocExts, e) >= 0) { category = Category.Document; return true; }
            if (e == "pdf") { category = Category.Pdf; return true; }
            category = Category.Image;
            return false;
        }

        public static string Title(Category c)
        {
            switch (c)
            {
                case Category.Image: return "Image";
                case Category.Audio: return "Audio";
                case Category.Video: return "Video";
                case Category.Document: return "Document";
                default: return "PDF";
            }
        }

        /// <summary>Output formats available on this PC (some need ffmpeg, Word or LibreOffice).</summary>
        public static List<string> Targets(Category c)
        {
            bool ff = Tools.Ffmpeg != null;
            List<string> list = new List<string>();
            switch (c)
            {
                case Category.Image:
                    list.AddRange(new string[] { "png", "jpg", "bmp", "gif", "tiff", "pdf" });
                    if (ff) list.Add("webp");
                    break;
                case Category.Audio:
                    list.AddRange(new string[] { "mp3", "m4a", "wav", "flac", "wma" });
                    if (ff) list.AddRange(new string[] { "ogg", "opus", "aiff" });
                    break;
                case Category.Video:
                    list.AddRange(new string[] { "mp4", "wmv" });
                    if (ff) list.AddRange(new string[] { "mp3", "m4a", "mov", "mkv", "webm", "avi", "gif" });
                    break;
                case Category.Document:
                    if (Tools.HasDocumentEngine)
                        list.AddRange(new string[] { "pdf", "docx", "doc", "odt", "rtf", "html", "txt" });
                    break;
                case Category.Pdf:
                    list.AddRange(new string[] { "png", "jpg" });
                    break;
            }
            return list;
        }

        /// <summary>
        /// Picks the most sensible target format among the available ones.
        /// If the user already chose a format for that category, it is reused.
        /// </summary>
        public static string SmartTarget(Category c, string sourceExt)
        {
            List<string> options = Targets(c);
            string src = Normalize(sourceExt);

            string saved = Settings.Get("last_" + Title(c));
            if (saved != null && options.Contains(saved) && saved != src) return saved;

            string[] preferred;
            switch (c)
            {
                case Category.Image: preferred = src == "jpg" ? new string[] { "png" } : new string[] { "jpg", "png" }; break;
                case Category.Audio: preferred = src == "mp3" ? new string[] { "m4a", "wav" } : new string[] { "mp3", "m4a" }; break;
                case Category.Video: preferred = src == "mp4" ? new string[] { "mp3", "m4a", "wmv" } : new string[] { "mp4" }; break;
                case Category.Document: preferred = new string[] { "pdf" }; break;
                default: preferred = new string[] { "png", "jpg" }; break;
            }
            foreach (string p in preferred)
                if (options.Contains(p) && p != src) return p;
            foreach (string o in options)
                if (o != src) return o;
            return options.Count > 0 ? options[0] : null;
        }
    }

    /// <summary>External programs the app can use when they are installed.</summary>
    public static class Tools
    {
        static string ffmpeg;
        static bool ffmpegDone;
        static string soffice;
        static bool sofficeDone;
        static int word = -1;

        /// <summary>ffmpeg is optional: when present, it unlocks many more audio/video formats.</summary>
        public static string Ffmpeg
        {
            get
            {
                if (!ffmpegDone)
                {
                    string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                    ffmpeg = FindOnPath("ffmpeg.exe", new string[]
                    {
                        Path.Combine(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe"),
                        Path.Combine(profile, "scoop", "shims", "ffmpeg.exe"),
                        Path.Combine(programFiles, "ffmpeg", "bin", "ffmpeg.exe"),
                        @"C:\ProgramData\chocolatey\bin\ffmpeg.exe",
                        @"C:\ffmpeg\bin\ffmpeg.exe"
                    });
                    ffmpegDone = true;
                }
                return ffmpeg;
            }
        }

        public static string LibreOffice
        {
            get
            {
                if (!sofficeDone)
                {
                    string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                    string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
                    soffice = FindOnPath("soffice.exe", new string[]
                    {
                        Path.Combine(pf, "LibreOffice", "program", "soffice.exe"),
                        Path.Combine(pf86, "LibreOffice", "program", "soffice.exe")
                    });
                    sofficeDone = true;
                }
                return soffice;
            }
        }

        public static bool WordAvailable
        {
            get
            {
                if (word < 0)
                {
                    try { word = Type.GetTypeFromProgID("Word.Application") != null ? 1 : 0; }
                    catch { word = 0; }
                }
                return word == 1;
            }
        }

        public static bool HasDocumentEngine
        {
            get { return WordAvailable || LibreOffice != null; }
        }

        static string FindOnPath(string exe, string[] extra)
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string dir in path.Split(Path.PathSeparator))
            {
                try
                {
                    if (dir.Length == 0) continue;
                    string candidate = Path.Combine(dir.Trim('"'), exe);
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
            foreach (string candidate in extra)
                if (File.Exists(candidate)) return candidate;
            return null;
        }
    }

    /// <summary>Tiny key=value settings file stored in %APPDATA%\FileWheel.</summary>
    public static class Settings
    {
        static readonly object Gate = new object();
        static Dictionary<string, string> data;

        static string Dir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FileWheel"); }
        }

        static string FilePath
        {
            get { return Path.Combine(Dir, "settings.ini"); }
        }

        static void Load()
        {
            if (data != null) return;
            data = new Dictionary<string, string>();
            try
            {
                if (!File.Exists(FilePath)) return;
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    int i = line.IndexOf('=');
                    if (i > 0) data[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
                }
            }
            catch { }
        }

        static void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                List<string> lines = new List<string>();
                foreach (KeyValuePair<string, string> pair in data)
                    lines.Add(pair.Key + "=" + pair.Value);
                File.WriteAllLines(FilePath, lines.ToArray());
            }
            catch { }
        }

        public static string Get(string key)
        {
            lock (Gate)
            {
                Load();
                string value;
                return data.TryGetValue(key, out value) ? value : null;
            }
        }

        public static void Set(string key, string value)
        {
            lock (Gate)
            {
                Load();
                data[key] = value;
                Save();
            }
        }

        public static void Remove(string key)
        {
            lock (Gate)
            {
                Load();
                if (data.Remove(key)) Save();
            }
        }
    }
}
