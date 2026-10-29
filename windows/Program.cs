using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace FileWheel
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool created;
            using (Mutex mutex = new Mutex(true, "FileWheel.SingleInstance", out created))
            {
                if (!created) return;   // already running: there is only one icon in the tray
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayContext());
            }
        }
    }

    /// <summary>The app itself: a tray icon, a menu, the mouse hook and the wheel.</summary>
    internal sealed class TrayContext : ApplicationContext
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        readonly NotifyIcon tray;
        readonly WheelForm wheel;
        readonly MouseHook hook;
        ToolStripMenuItem sameFolderItem;
        ToolStripMenuItem folderItem;
        ToolStripMenuItem startupItem;

        Point downPoint;
        bool leftDown;
        bool probePending;

        public TrayContext()
        {
            wheel = new WheelForm();
            wheel.PrepareHandle();

            tray = new NotifyIcon();
            tray.Icon = LoadIcon();
            tray.Text = "FileWheel";
            tray.ContextMenuStrip = BuildMenu();
            tray.DoubleClick += delegate { PickFiles(); };
            tray.Visible = true;

            hook = new MouseHook();
            hook.LeftDown += delegate (Point p)
            {
                downPoint = p;
                leftDown = true;
                wheel.OnPointerDown(p);
            };
            hook.LeftUp += delegate (Point p)
            {
                leftDown = false;
                probePending = false;
                wheel.OnPointerUp(p);
            };
            hook.Move += OnMove;

            Application.ApplicationExit += delegate
            {
                hook.Dispose();
                tray.Visible = false;
                tray.Dispose();
            };

            if (Settings.Get("introShown") == null)
            {
                Settings.Set("introShown", "1");
                tray.ShowBalloonTip(6000, "FileWheel is running",
                    "Hold Shift while dragging a file: a wheel with the available formats appears next to your cursor.",
                    ToolTipIcon.Info);
            }
        }

        /// <summary>Shift + left button held + the mouse moved a bit: a file drag may be starting.</summary>
        void OnMove(Point p)
        {
            if (!leftDown || probePending || wheel.State != WheelState.Hidden) return;
            if ((Native.GetAsyncKeyState(Native.VK_SHIFT) & 0x8000) == 0) return;

            int threshold = SystemInformation.DragSize.Width * 2;
            int dx = p.X - downPoint.X;
            int dy = p.Y - downPoint.Y;
            if (dx * dx + dy * dy < threshold * threshold) return;

            probePending = true;
            wheel.BeginInvoke(new Action(delegate
            {
                probePending = false;
                wheel.ShowProbe(Cursor.Position);
            }));
        }

        // ---------------------------------------------------------------- Menu

        ContextMenuStrip BuildMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();

            ToolStripMenuItem hint = new ToolStripMenuItem("Hold Shift while dragging a file");
            hint.Enabled = false;
            menu.Items.Add(hint);
            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add("Convert files\u2026", null, delegate { PickFiles(); });
            menu.Items.Add(new ToolStripSeparator());

            sameFolderItem = new ToolStripMenuItem("Save next to the original file", null, delegate
            {
                Settings.Remove("outputDir");
            });
            folderItem = new ToolStripMenuItem("Choose a destination folder\u2026", null, delegate { ChooseFolder(); });
            startupItem = new ToolStripMenuItem("Launch at login", null, delegate { SetStartup(!StartupEnabled()); });
            menu.Items.Add(sameFolderItem);
            menu.Items.Add(folderItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(startupItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, delegate { ExitThread(); });

            menu.Opening += delegate
            {
                string custom = Settings.Get("outputDir");
                sameFolderItem.Checked = string.IsNullOrEmpty(custom);
                folderItem.Checked = !string.IsNullOrEmpty(custom);
                folderItem.Text = string.IsNullOrEmpty(custom)
                    ? "Choose a destination folder\u2026"
                    : "Save to: " + Path.GetFileName(custom.TrimEnd('\\', '/')) + "\u2026";
                startupItem.Checked = StartupEnabled();
            };
            return menu;
        }

        void PickFiles()
        {
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "Choose files to convert";
                dialog.Multiselect = true;
                if (dialog.ShowDialog() != DialogResult.OK) return;

                Rectangle area = Screen.PrimaryScreen.WorkingArea;
                Point center = new Point(area.Left + area.Width / 2, area.Top + area.Height / 2);
                wheel.ShowFixed(new List<string>(dialog.FileNames), center);
            }
        }

        void ChooseFolder()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Where should converted files be saved?";
                if (dialog.ShowDialog() == DialogResult.OK)
                    Settings.Set("outputDir", dialog.SelectedPath);
            }
        }

        // ---------------------------------------------------------------- Launch at login

        static bool StartupEnabled()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey))
                return key != null && key.GetValue("FileWheel") != null;
        }

        static void SetStartup(bool enable)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (key == null) return;
                if (enable) key.SetValue("FileWheel", "\"" + Application.ExecutablePath + "\"");
                else key.DeleteValue("FileWheel", false);
            }
        }

        static Icon LoadIcon()
        {
            try
            {
                using (Stream s = typeof(TrayContext).Assembly.GetManifestResourceStream("app.ico"))
                {
                    if (s != null) return new Icon(s, SystemInformation.SmallIconSize);
                }
            }
            catch { }
            return SystemIcons.Application;
        }
    }
}
