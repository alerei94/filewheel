using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FileWheel
{
    public enum WheelState { Hidden, Probing, Choosing, Working, Finished }

    public sealed class DraggedFile
    {
        public string FullPath;
        public Category Category;
    }

    public sealed class FormatOption
    {
        public string Ext;
        public int Count;
    }

    /// <summary>
    /// The wheel: a borderless, transparent window that appears next to the cursor. It is hand-drawn
    /// (GDI+ into a per-pixel-alpha layered window), so it is very light, and it is also the drop target.
    /// </summary>
    public sealed class WheelForm : Form
    {
        // Everything is laid out in "logical" pixels and scaled by the monitor's DPI.
        const float LogicalW = 320f;
        const float LogicalH = 350f;
        const float CenterX = 160f;
        const float CenterY = 160f;
        const float BubbleSize = 46f;

        static readonly Color Accent = Color.FromArgb(255, 128, 10);
        static readonly Font BubbleFont = new Font("Segoe UI Semibold", 12f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font TinyFont = new Font("Segoe UI Semibold", 10f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font CenterFont = new Font("Segoe UI Semibold", 15f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font CountFont = new Font("Segoe UI Semibold", 22f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font CaptionFont = new Font("Segoe UI", 12f, FontStyle.Regular, GraphicsUnit.Pixel);
        static readonly Font SymbolFont = new Font("Segoe UI Symbol", 26f, FontStyle.Regular, GraphicsUnit.Pixel);

        WheelState state = WheelState.Hidden;
        bool fixedMode;                       // opened from the menu: works with clicks, not with a drag
        readonly List<DraggedFile> files = new List<DraggedFile>();
        List<FormatOption> options = new List<FormatOption>();
        string suggested;
        string title = "";
        int hovered = -1;

        float scale = 1f;
        Point origin;                         // top-left corner on screen, in pixels
        int pxW;
        int pxH;
        bool lightTheme = true;

        float openProgress = 1f;
        DateTime animStart;
        int done;
        int total;
        bool lastSuccess;
        string message = "";
        List<string> lastOutputs = new List<string>();

        readonly System.Windows.Forms.Timer animTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer hideTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer pollTimer = new System.Windows.Forms.Timer();

        public WheelForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            AllowDrop = true;
            Text = "FileWheel";
            Size = new Size(1, 1);

            animTimer.Interval = 16;
            animTimer.Tick += OnAnimTick;
            hideTimer.Tick += OnHideTick;
            pollTimer.Interval = 250;
            pollTimer.Tick += OnPollTick;
        }

        public WheelState State
        {
            get { return state; }
        }

        /// <summary>Creates the window handle early, so showing the wheel later is instant.</summary>
        public void PrepareHandle()
        {
            IntPtr handle = Handle;
        }

        // ---------------------------------------------------------------- Window style

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        // ---------------------------------------------------------------- Showing and hiding

        /// <summary>
        /// Called when Shift + a mouse drag starts. The wheel appears almost invisible under the cursor;
        /// if the drag carries convertible files, DragEnter makes it visible.
        /// </summary>
        public void ShowProbe(Point cursor)
        {
            if (state != WheelState.Hidden) return;
            ResetContent();
            fixedMode = false;
            Place(cursor);
            state = WheelState.Probing;
            ShowNow();
        }

        /// <summary>Opens the wheel for files picked from the menu (click a format instead of dragging).</summary>
        public bool ShowFixed(IEnumerable<string> paths, Point anchor)
        {
            if (state != WheelState.Hidden) HideWheel();
            SetFiles(paths);
            fixedMode = true;
            Place(anchor);
            if (options.Count == 0)
            {
                ShowMessageOnly(files.Count == 0 ? "No convertible files" : NoOptionsMessage(), 3500);
                return false;
            }
            state = WheelState.Choosing;
            ShowNow();
            StartOpening();
            return true;
        }

        public void HideWheel()
        {
            animTimer.Stop();
            hideTimer.Stop();
            pollTimer.Stop();
            state = WheelState.Hidden;
            fixedMode = false;
            ResetContent();
            if (Visible) Hide();
        }

        public void OnPointerDown(Point screenPoint)
        {
            if (!fixedMode) return;
            if (state != WheelState.Choosing && state != WheelState.Finished) return;
            Rectangle area = new Rectangle(origin.X, origin.Y, pxW, pxH);
            if (!area.Contains(screenPoint)) HideWheel();
        }

        public void OnPointerUp(Point screenPoint)
        {
            if (fixedMode) return;
            // Wait a moment: the drop event arrives right after the mouse button is released.
            if (state == WheelState.Probing || state == WheelState.Choosing) ScheduleHide(350);
        }

        void ResetContent()
        {
            files.Clear();
            options = new List<FormatOption>();
            suggested = null;
            title = "";
            message = "";
            hovered = -1;
        }

        void ShowMessageOnly(string text, int hideAfterMs)
        {
            options = new List<FormatOption>();
            state = WheelState.Finished;
            lastSuccess = false;
            lastOutputs = new List<string>();
            message = text;
            ShowNow();
            ScheduleHide(hideAfterMs);
        }

        void Place(Point anchor)
        {
            scale = DpiScaleAt(anchor);
            pxW = (int)Math.Round(LogicalW * scale);
            pxH = (int)Math.Round(LogicalH * scale);
            int x = anchor.X - (int)Math.Round(CenterX * scale);
            int y = anchor.Y - (int)Math.Round(CenterY * scale);
            Rectangle area = Screen.FromPoint(anchor).WorkingArea;
            x = Math.Max(area.Left + 4, Math.Min(x, area.Right - pxW - 4));
            y = Math.Max(area.Top + 4, Math.Min(y, area.Bottom - pxH - 4));
            origin = new Point(x, y);
            lightTheme = IsLightTheme();
        }

        void ShowNow()
        {
            SetBounds(origin.X, origin.Y, pxW, pxH);
            if (!Visible) Show();
            Render();
            pollTimer.Start();
        }

        // ---------------------------------------------------------------- Files and formats

        void SetFiles(IEnumerable<string> paths)
        {
            files.Clear();
            foreach (string p in paths)
            {
                try
                {
                    if (!File.Exists(p)) continue;   // also skips folders
                    Category category;
                    if (!Formats.TryDetect(Path.GetExtension(p), out category)) continue;
                    DraggedFile f = new DraggedFile();
                    f.FullPath = p;
                    f.Category = category;
                    files.Add(f);
                }
                catch { }
            }

            suggested = files.Count > 0
                ? Formats.SmartTarget(files[0].Category, Path.GetExtension(files[0].FullPath))
                : null;
            options = BuildOptions(files, suggested);
            title = files.Count == 1 ? Path.GetFileName(files[0].FullPath) : files.Count + " files";
            hovered = -1;
        }

        /// <summary>Formats that at least one file can be converted to (the recommended one goes on top).</summary>
        static List<FormatOption> BuildOptions(List<DraggedFile> list, string suggestedExt)
        {
            List<string> order = new List<string>();
            Dictionary<string, int> counts = new Dictionary<string, int>();
            foreach (DraggedFile f in list)
            {
                string src = Formats.Normalize(Path.GetExtension(f.FullPath));
                foreach (string ext in Formats.Targets(f.Category))
                {
                    if (ext == src) continue;
                    if (!counts.ContainsKey(ext)) { counts[ext] = 0; order.Add(ext); }
                    counts[ext]++;
                }
            }
            if (suggestedExt != null && order.Remove(suggestedExt)) order.Insert(0, suggestedExt);

            List<FormatOption> result = new List<FormatOption>();
            foreach (string ext in order)
            {
                FormatOption o = new FormatOption();
                o.Ext = ext;
                o.Count = counts[ext];
                result.Add(o);
                if (result.Count == 12) break;
            }
            return result;
        }

        string NoOptionsMessage()
        {
            foreach (DraggedFile f in files)
                if (f.Category == Category.Document && !Tools.HasDocumentEngine)
                    return "Documents need Microsoft Word or LibreOffice";
            return "No conversions available";
        }

        // ---------------------------------------------------------------- Drag and drop

        protected override void OnDragEnter(DragEventArgs e)
        {
            HandleDrag(e, true);
        }

        protected override void OnDragOver(DragEventArgs e)
        {
            HandleDrag(e, false);
        }

        protected override void OnDragLeave(EventArgs e)
        {
            if (hovered != -1)
            {
                hovered = -1;
                Render();
            }
        }

        void HandleDrag(DragEventArgs e, bool entering)
        {
            e.Effect = DragDropEffects.None;
            if (state == WheelState.Working || state == WheelState.Finished) return;

            if (entering && state == WheelState.Probing)
            {
                string[] paths = null;
                try { paths = e.Data.GetData(DataFormats.FileDrop) as string[]; }
                catch { }
                if (paths == null) return;           // not files: stay invisible

                SetFiles(paths);
                if (files.Count == 0) return;        // files we don't know: stay invisible
                if (options.Count == 0)
                {
                    ShowMessageOnly(NoOptionsMessage(), 3000);
                    return;
                }
                state = WheelState.Choosing;
                StartOpening();
            }

            if (state != WheelState.Choosing) return;

            int index = HitBubble(ToLogical(PointToClient(new Point(e.X, e.Y))));
            if (index != hovered)
            {
                hovered = index;
                Render();
            }
            if (index >= 0) e.Effect = DragDropEffects.Copy;
        }

        protected override void OnDragDrop(DragEventArgs e)
        {
            int index = hovered;
            hovered = -1;
            if (state != WheelState.Choosing || index < 0 || index >= options.Count)
            {
                Render();
                return;
            }
            RunConversion(options[index].Ext);
        }

        // ---------------------------------------------------------------- Clicks (menu mode)

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (state != WheelState.Choosing) return;
            int index = HitBubble(ToLogical(e.Location));
            if (index != hovered)
            {
                hovered = index;
                Render();
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (state == WheelState.Choosing)
            {
                int index = HitBubble(ToLogical(e.Location));
                if (index >= 0) RunConversion(options[index].Ext);
                else if (fixedMode) HideWheel();
            }
            else if (state == WheelState.Finished)
            {
                Reveal();
                HideWheel();
            }
        }

        void Reveal()
        {
            try
            {
                if (lastOutputs.Count > 0)
                    Process.Start("explorer.exe", "/select,\"" + lastOutputs[0] + "\"");
            }
            catch { }
        }

        // ---------------------------------------------------------------- Conversion

        static string OutputDirectory(string source)
        {
            string custom = Settings.Get("outputDir");
            if (!string.IsNullOrEmpty(custom) && Directory.Exists(custom)) return custom;
            return Path.GetDirectoryName(source);
        }

        async void RunConversion(string ext)
        {
            try
            {
                List<DraggedFile> batch = new List<DraggedFile>();
                foreach (DraggedFile f in files)
                {
                    if (Formats.Targets(f.Category).Contains(ext) &&
                        Formats.Normalize(Path.GetExtension(f.FullPath)) != ext)
                        batch.Add(f);
                }
                if (batch.Count == 0)
                {
                    HideWheel();
                    return;
                }

                hideTimer.Stop();
                state = WheelState.Working;
                hovered = -1;
                done = 0;
                total = batch.Count;
                Render();

                int ok = 0;
                int fail = 0;
                string lastError = "Conversion failed";
                List<string> outputs = new List<string>();

                for (int i = 0; i < batch.Count; i++)
                {
                    DraggedFile f = batch[i];
                    try
                    {
                        string result = await Converter.ConvertAsync(f.FullPath, ext, f.Category, OutputDirectory(f.FullPath));
                        outputs.Add(result);
                        ok++;
                        Settings.Set("last_" + Formats.Title(f.Category), ext);
                    }
                    catch (Exception ex)
                    {
                        fail++;
                        lastError = ex.Message.Replace("\r", " ").Replace("\n", " ");
                    }
                    done = i + 1;
                    Render();
                }

                lastOutputs = outputs;
                lastSuccess = fail == 0;
                if (fail == 0)
                    message = ok == 1 ? "Done \u00B7 " + Path.GetFileName(outputs[0]) : "Done \u00B7 " + ok + " files in " + ext.ToUpperInvariant();
                else if (ok == 0)
                    message = lastError;
                else
                    message = ok + " converted, " + fail + " failed";

                state = WheelState.Finished;
                Render();
                if (ok > 0) System.Media.SystemSounds.Asterisk.Play();
                ScheduleHide(fail == 0 ? 2500 : 5000);
            }
            catch (Exception)
            {
                HideWheel();
            }
        }

        // ---------------------------------------------------------------- Timers

        void StartOpening()
        {
            openProgress = 0f;
            animStart = DateTime.UtcNow;
            animTimer.Start();
            Render();
        }

        /// <summary>Short animation (about a quarter of a second): then the timer stops and uses nothing.</summary>
        void OnAnimTick(object sender, EventArgs e)
        {
            double x = (DateTime.UtcNow - animStart).TotalMilliseconds / 240.0;
            if (x >= 1.0)
            {
                x = 1.0;
                animTimer.Stop();
            }
            openProgress = (float)(1.0 - Math.Pow(1.0 - x, 3.0));
            Render();
        }

        void ScheduleHide(int milliseconds)
        {
            hideTimer.Stop();
            hideTimer.Interval = milliseconds;
            hideTimer.Start();
        }

        void OnHideTick(object sender, EventArgs e)
        {
            hideTimer.Stop();
            if (state == WheelState.Working) return;
            HideWheel();
        }

        /// <summary>Safety net: if the mouse button is up and the drag is over, the wheel goes away.</summary>
        void OnPollTick(object sender, EventArgs e)
        {
            if (fixedMode || hideTimer.Enabled) return;
            bool dragging = state == WheelState.Probing || state == WheelState.Choosing;
            if (dragging && (Native.GetAsyncKeyState(Native.VK_LBUTTON) & 0x8000) == 0) ScheduleHide(350);
        }

        // ---------------------------------------------------------------- Geometry

        static float RadiusFor(int count)
        {
            return Math.Max(92f, count * 54f / (2f * (float)Math.PI));
        }

        static PointF BubbleCenter(int index, int count)
        {
            double angle = -Math.PI / 2.0 + 2.0 * Math.PI * index / Math.Max(count, 1);
            float r = RadiusFor(count);
            return new PointF(CenterX + r * (float)Math.Cos(angle), CenterY + r * (float)Math.Sin(angle));
        }

        PointF ToLogical(Point client)
        {
            return new PointF(client.X / scale, client.Y / scale);
        }

        int HitBubble(PointF p)
        {
            if (state != WheelState.Choosing) return -1;
            float hit = BubbleSize / 2f + 10f;
            int best = -1;
            float bestDistance = float.MaxValue;
            for (int i = 0; i < options.Count; i++)
            {
                PointF b = BubbleCenter(i, options.Count);
                float dx = b.X - p.X;
                float dy = b.Y - p.Y;
                float d = (float)Math.Sqrt(dx * dx + dy * dy);
                if (d < hit && d < bestDistance)
                {
                    bestDistance = d;
                    best = i;
                }
            }
            return best;
        }

        static float DpiScaleAt(Point p)
        {
            try
            {
                IntPtr monitor = Native.MonitorFromPoint(new Native.POINT(p.X, p.Y), Native.MONITOR_DEFAULTTONEAREST);
                uint dx;
                uint dy;
                if (Native.GetDpiForMonitor(monitor, Native.MDT_EFFECTIVE_DPI, out dx, out dy) == 0 && dx > 0)
                    return dx / 96f;
            }
            catch { }
            return 1f;
        }

        static bool IsLightTheme()
        {
            try
            {
                object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                    "AppsUseLightTheme", 1);
                return v == null || Convert.ToInt32(v) != 0;
            }
            catch
            {
                return true;
            }
        }

        // ---------------------------------------------------------------- Drawing

        static Color Fade(Color c, float factor)
        {
            int a = (int)Math.Max(0f, Math.Min(255f, c.A * factor));
            return Color.FromArgb(a, c.R, c.G, c.B);
        }

        void Render()
        {
            if (!IsHandleCreated || !Visible || pxW <= 0 || pxH <= 0) return;
            using (Bitmap bmp = new Bitmap(pxW, pxH, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                    g.ScaleTransform(scale, scale);
                    Draw(g);
                }
                Present(bmp);
            }
        }

        static void Label(Graphics g, string text, Font font, Color color, RectangleF rect, StringTrimming trimming)
        {
            using (StringFormat sf = new StringFormat())
            using (Brush brush = new SolidBrush(color))
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                sf.Trimming = trimming;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                g.DrawString(text, font, brush, rect, sf);
            }
        }

        void Draw(Graphics g)
        {
            Color bg = lightTheme ? Color.FromArgb(240, 250, 250, 250) : Color.FromArgb(240, 38, 38, 40);
            Color fg = lightTheme ? Color.FromArgb(255, 28, 28, 30) : Color.FromArgb(255, 242, 242, 245);
            Color sub = lightTheme ? Color.FromArgb(255, 110, 110, 118) : Color.FromArgb(255, 170, 170, 178);
            Color edge = lightTheme ? Color.FromArgb(60, 0, 0, 0) : Color.FromArgb(70, 255, 255, 255);
            Color centerFill = lightTheme ? Color.FromArgb(255, 255, 255, 255) : Color.FromArgb(255, 52, 52, 56);

            PointF c = new PointF(CenterX, CenterY);

            if (state == WheelState.Probing)
            {
                // Practically invisible, but not fully transparent: the window needs something
                // under the cursor that Windows can hit, so DragEnter can fire.
                using (Brush b = new SolidBrush(Color.FromArgb(3, 0, 0, 0)))
                    g.FillEllipse(b, c.X - 120f, c.Y - 120f, 240f, 240f);
                return;
            }

            float p = openProgress;
            int n = options.Count;
            float r = n > 0 ? RadiusFor(n) : 0f;

            // Background disc
            float discR = n > 0 ? (r + BubbleSize / 2f + 10f) * (0.55f + 0.45f * p) : 50f;
            using (Brush b = new SolidBrush(Fade(bg, p)))
                g.FillEllipse(b, c.X - discR, c.Y - discR, discR * 2f, discR * 2f);
            using (Pen pen = new Pen(Fade(edge, p), 1f))
                g.DrawEllipse(pen, c.X - discR, c.Y - discR, discR * 2f, discR * 2f);

            // Star rays
            using (Pen ray = new Pen(Fade(Color.FromArgb(70, Accent.R, Accent.G, Accent.B), p), 1.5f))
            {
                for (int i = 0; i < n; i++)
                {
                    PointF bc = BubbleCenter(i, n);
                    g.DrawLine(ray, c, new PointF(c.X + (bc.X - c.X) * p, c.Y + (bc.Y - c.Y) * p));
                }
            }

            // Format bubbles
            for (int i = 0; i < n; i++)
            {
                PointF bc = BubbleCenter(i, n);
                PointF pos = new PointF(c.X + (bc.X - c.X) * p, c.Y + (bc.Y - c.Y) * p);
                bool isHover = i == hovered;
                bool isSuggested = options[i].Ext == suggested;
                float d = BubbleSize * (isHover ? 1.25f : 1f) * (0.4f + 0.6f * p);
                RectangleF rect = new RectangleF(pos.X - d / 2f, pos.Y - d / 2f, d, d);

                Color fill = isHover ? Accent : Color.FromArgb(40, Accent.R, Accent.G, Accent.B);
                using (Brush b = new SolidBrush(Fade(fill, p)))
                    g.FillEllipse(b, rect);
                Color ring = Color.FromArgb(isHover ? 255 : 150, Accent.R, Accent.G, Accent.B);
                using (Pen pen = new Pen(Fade(ring, p), isSuggested ? 2.5f : 1f))
                    g.DrawEllipse(pen, rect);

                Label(g, options[i].Ext.ToUpperInvariant(), BubbleFont, Fade(isHover ? Color.White : fg, p), rect, StringTrimming.None);

                if (isSuggested)
                    Label(g, "\u2605", TinyFont, Fade(Color.FromArgb(255, 255, 190, 30), p),
                        new RectangleF(rect.Right - 12f, rect.Top - 3f, 14f, 14f), StringTrimming.None);
                if (options[i].Count < files.Count)
                    Label(g, options[i].Count.ToString(), TinyFont, Fade(sub, p),
                        new RectangleF(rect.Right - 12f, rect.Bottom - 8f, 14f, 14f), StringTrimming.None);
            }

            // Center: the file
            float cr = 34f;
            using (Brush b = new SolidBrush(centerFill))
                g.FillEllipse(b, c.X - cr, c.Y - cr, cr * 2f, cr * 2f);
            using (Pen pen = new Pen(Color.FromArgb(160, Accent.R, Accent.G, Accent.B), 2f))
                g.DrawEllipse(pen, c.X - cr, c.Y - cr, cr * 2f, cr * 2f);
            RectangleF centerRect = new RectangleF(c.X - cr, c.Y - cr, cr * 2f, cr * 2f);

            switch (state)
            {
                case WheelState.Choosing:
                    if (files.Count == 1)
                    {
                        string ext = Formats.Normalize(Path.GetExtension(files[0].FullPath)).ToUpperInvariant();
                        Label(g, ext, CenterFont, Accent, centerRect, StringTrimming.None);
                    }
                    else
                    {
                        Label(g, files.Count.ToString(), CountFont, Accent,
                            new RectangleF(c.X - cr, c.Y - cr + 8f, cr * 2f, 34f), StringTrimming.None);
                        Label(g, "files", TinyFont, sub,
                            new RectangleF(c.X - cr, c.Y + 8f, cr * 2f, 16f), StringTrimming.None);
                    }
                    break;

                case WheelState.Working:
                    double frac = total == 0 ? 0.0 : (double)done / total;
                    using (Pen pen = new Pen(Accent, 4f))
                    {
                        pen.StartCap = LineCap.Round;
                        pen.EndCap = LineCap.Round;
                        g.DrawArc(pen, c.X - 30f, c.Y - 30f, 60f, 60f, -90f, (float)(360.0 * Math.Max(frac, 0.05)));
                    }
                    Label(g, done + "/" + total, BubbleFont, fg, centerRect, StringTrimming.None);
                    break;

                case WheelState.Finished:
                    if (lastSuccess)
                        Label(g, "\u2714", SymbolFont, Color.FromArgb(255, 40, 170, 80), centerRect, StringTrimming.None);
                    else
                        Label(g, "!", SymbolFont, Color.FromArgb(255, 255, 140, 0), centerRect, StringTrimming.None);
                    break;
            }

            // Caption
            string caption = "";
            switch (state)
            {
                case WheelState.Choosing:
                    caption = hovered >= 0 && hovered < options.Count
                        ? "Convert to " + options[hovered].Ext.ToUpperInvariant()
                        : title;
                    break;
                case WheelState.Working: caption = "Converting\u2026"; break;
                case WheelState.Finished: caption = message; break;
            }
            RectangleF pill = new RectangleF(10f, 322f, 300f, 22f);
            using (GraphicsPath path = RoundedRect(pill, 11f))
            using (Brush b = new SolidBrush(Fade(bg, 0.97f)))
                g.FillPath(b, path);
            Label(g, Fit(g, caption, CaptionFont, pill.Width - 24f), CaptionFont, sub,
                new RectangleF(pill.X + 8f, pill.Y, pill.Width - 16f, pill.Height), StringTrimming.None);
        }

        /// <summary>Shortens a text with an ellipsis so it fits in the given width.</summary>
        static string Fit(Graphics g, string text, Font font, float maxWidth)
        {
            if (string.IsNullOrEmpty(text) || g.MeasureString(text, font).Width <= maxWidth) return text;
            string t = text;
            while (t.Length > 1 && g.MeasureString(t + "\u2026", font).Width > maxWidth)
                t = t.Substring(0, t.Length - 1);
            return t + "\u2026";
        }

        static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            float d = radius * 2f;
            GraphicsPath path = new GraphicsPath();
            path.AddArc(r.X, r.Y, d, d, 180f, 90f);
            path.AddArc(r.Right - d, r.Y, d, d, 270f, 90f);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0f, 90f);
            path.AddArc(r.X, r.Bottom - d, d, d, 90f, 90f);
            path.CloseFigure();
            return path;
        }

        /// <summary>Pushes the drawn bitmap to the screen as a layered window with per-pixel transparency.</summary>
        void Present(Bitmap bmp)
        {
            IntPtr screenDc = Native.GetDC(IntPtr.Zero);
            IntPtr memDc = Native.CreateCompatibleDC(screenDc);
            IntPtr hBitmap = IntPtr.Zero;
            IntPtr oldBitmap = IntPtr.Zero;
            try
            {
                hBitmap = bmp.GetHbitmap(Color.FromArgb(0));
                oldBitmap = Native.SelectObject(memDc, hBitmap);

                Native.SIZE size = new Native.SIZE(bmp.Width, bmp.Height);
                Native.POINT source = new Native.POINT(0, 0);
                Native.POINT destination = new Native.POINT(origin.X, origin.Y);
                Native.BLENDFUNCTION blend = new Native.BLENDFUNCTION();
                blend.BlendOp = Native.AC_SRC_OVER;
                blend.BlendFlags = 0;
                blend.SourceConstantAlpha = 255;
                blend.AlphaFormat = Native.AC_SRC_ALPHA;

                Native.UpdateLayeredWindow(Handle, screenDc, ref destination, ref size, memDc, ref source, 0, ref blend, Native.ULW_ALPHA);
            }
            finally
            {
                Native.ReleaseDC(IntPtr.Zero, screenDc);
                if (hBitmap != IntPtr.Zero)
                {
                    Native.SelectObject(memDc, oldBitmap);
                    Native.DeleteObject(hBitmap);
                }
                Native.DeleteDC(memDc);
            }
        }
    }
}
