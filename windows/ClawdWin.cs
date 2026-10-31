// Clawd 伴随 —— Windows（小狼毫 Weasel）版
// 项目主页：https://github.com/yzysiu777/rime-clawd
//
// 工作方式（和 macOS 版相同）：
//   1. lua/clawd.lua 在每次按键后把输入状态写进 %LOCALAPPDATA%\ClawdCompanion\state
//   2. 本程序监听这个文件；有输入时以约 60 帧找到小狼毫候选框窗口（窗口类名 WeaselPanel），
//      量出光标横坐标，在一个透明、点击穿透的分层窗口里逐像素画出 Clawd。
//   3. 不打字时不跑定时器。
//
// 编译：双击 build.bat（只用 Windows 自带的 .NET Framework 4.x 编译器，不需要另装东西）
// 语法只用到 C# 5，以便 Windows 自带的 csc.exe 能编译。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Clawd 伴随")]
[assembly: AssemblyProduct("rime-clawd")]
[assembly: AssemblyCompany("rime-clawd")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace ClawdWin
{
    // ───────────────────────── 像素精灵（与 macOS 版逐像素一致） ─────────────────────────

    enum Eyes { Open, Closed, Happy, Wide }

    class Pose
    {
        public int Look;          // -1 往左看，0 正视，1 往右看
        public Eyes Eyes = Eyes.Open;
        public int Legs;          // 0 站立；1、2 迈步的两个相位
        public int ArmL, ArmR;    // 0 平举，1 举起
        public bool Sit;          // 骑扫帚时腿收短
        public bool Breathe;      // 呼吸：钳子往下沉 1 像素
    }

    class Sprite
    {
        public Dictionary<Point, char> Px = new Dictionary<Point, char>();

        public void Rect(int x, int y, int w, int h, char c)
        {
            if (w <= 0 || h <= 0) return;
            for (int j = y; j < y + h; j++)
                for (int i = x; i < x + w; i++)
                    Px[new Point(i, j)] = c;
        }

        public void Stamp(string[] rows, int dx, int dy)
        {
            for (int j = 0; j < rows.Length; j++)
                for (int i = 0; i < rows[j].Length; i++)
                    if (rows[j][i] != '.') Px[new Point(dx + i, dy + j)] = rows[j][i];
        }

        public void Merge(Sprite o, int dx, int dy)
        {
            foreach (var kv in o.Px) Px[new Point(kv.Key.X + dx, kv.Key.Y + dy)] = kv.Value;
        }

        /// 以 x = axis2/2 为轴左右镜像
        public Sprite Mirrored(int axis2)
        {
            var s = new Sprite();
            foreach (var kv in Px) s.Px[new Point(axis2 - kv.Key.X, kv.Key.Y)] = kv.Value;
            return s;
        }

        public Sprite Shifted(int dy)
        {
            var s = new Sprite();
            s.Merge(this, 0, dy);
            return s;
        }
    }

    static class Art
    {
        public static readonly Dictionary<char, Color> Palette = new Dictionary<char, Color>
        {
            { 'O', Color.FromArgb(0xCB, 0x7A, 0x5D) },  // Clawd 身体
            { 'o', Color.FromArgb(0xA9, 0x64, 0x4C) },  // 暗部 / 帽檐阴影 / 扫帚绑绳
            { 'E', Color.FromArgb(0x00, 0x00, 0x00) },  // 眼睛
            { 'K', Color.FromArgb(0x2F, 0x2F, 0x2D) },  // 女巫帽
            { 'k', Color.FromArgb(0x4B, 0x4B, 0x47) },  // 帽子高光
            { 'S', Color.FromArgb(0x5B, 0x3A, 0x1B) },  // 扫帚杆
            { 'D', Color.FromArgb(0x2C, 0x19, 0x04) },  // 扫帚杆暗部
            { 'Y', Color.FromArgb(0xE6, 0xB4, 0x64) },  // 草穗
            { 'y', Color.FromArgb(0xB5, 0x86, 0x43) },  // 草穗暗部
            { 'L', Color.FromArgb(0xF0, 0xDC, 0xA2) },  // 草穗高光
            { 'B', Color.FromArgb(0x7F, 0xC4, 0xF0) },  // 汗珠
            { 'W', Color.FromArgb(0xFF, 0xFF, 0xFF) },
            { 'A', Color.FromArgb(0xD9, 0x77, 0x57) },  // Claude 橙：惊叹号
        };

        // 女巫帽：原点 (-2, -10)
        public static readonly string[] Hat = {
            "..............kKKKKKKK......",
            "...........kKKKKKKKKKKK.....",
            "..........kKKKKKKKKK..K.....",
            "..........kKKKKKKKKK........",
            ".........kKKKKKKKKK.........",
            ".........kKKKKKKKKK.........",
            ".........kKKKKKKKKK.........",
            "........KKKKKKKKKKKK........",
            ".......KKKKKKKKKKKKKK.......",
            "..kkkKKKKKKKKKKKKKKKKKKKKK..",
            ".kKKKKKKKKKKKKKKKKKKKKKKKKK.",
            "...KKKooooooooooooooooKKK...",
        };
        // 扫帚杆：原点 (-8, 11)
        public static readonly string[] Handle = {
            "..DSS...........................",
            "..DDSSSS........................",
            "...DDSSSSSS.....................",
            "....DDDDDSSSSSSSSSSSSSSSS.......",
            ".........DDDDDDDDDDDDDDSSSSSSSD.",
            ".......................DDDDDDDD.",
        };
        // 草穗：原点 (22, 8)
        public static readonly string[] Bristle = {
            "...........L..Y.",
            ".........LYYy.Y.",
            ".......LYYYyyYYL",
            ".....yyYYYYLLLL.",
            "..oyYYLLLLyyyyyY",
            "ooyYYyyyyYYYYYYY",
            "ooYLLLLYYYyyyyyL",
            "ooyYyyyyyLLLLLYY",
            "..oyYYYYyyyYYYy.",
            ".....yyyLLLyyY..",
            ".......yyYYy..Y.",
            ".........Y...y..",
        };

        /// 照 Claude 官方 Clawd 逐像素重画：身体 16×12，钳子各 4×4，眼睛 2×2，四条腿 2×4
        public static Sprite Clawd(Pose p)
        {
            var s = new Sprite();
            s.Rect(4, 0, 16, 12, 'O');
            if (p.ArmL == 1) { s.Rect(0, -4, 3, 4, 'O'); s.Rect(1, 0, 3, 2, 'O'); } else s.Rect(0, p.Breathe ? 5 : 4, 4, 4, 'O');
            if (p.ArmR == 1) { s.Rect(21, -4, 3, 4, 'O'); s.Rect(20, 0, 3, 2, 'O'); } else s.Rect(20, p.Breathe ? 5 : 4, 4, 4, 'O');
            int left = 6 + p.Look;
            foreach (int x in new[] { 6 + p.Look, 16 + p.Look })
            {
                switch (p.Eyes)
                {
                    case Eyes.Open: s.Rect(x, 2, 2, 2, 'E'); break;
                    case Eyes.Closed: s.Rect(x, 3, 2, 1, 'E'); break;
                    case Eyes.Wide: s.Rect(x, 1, 2, 3, 'E'); break;
                    case Eyes.Happy:   // ^ ^
                        int hx = x == left ? x - 1 : x;
                        s.Rect(hx, 3, 1, 1, 'E'); s.Rect(hx + 1, 2, 1, 1, 'E'); s.Rect(hx + 2, 3, 1, 1, 'E');
                        break;
                }
            }
            int[] legX = { 4, 8, 14, 18 };
            for (int i = 0; i < legX.Length; i++)
            {
                int h = 4;
                if (p.Sit) h = 2;
                else if (p.Legs == 1 && i % 2 == 0) h = 2;
                else if (p.Legs == 2 && i % 2 == 1) h = 2;
                s.Rect(legX[i], 12, 2, h, 'O');
            }
            return s;
        }

        public static Sprite Witch(Pose p)
        {
            var pose = new Pose { Look = p.Look, Eyes = p.Eyes, Legs = p.Legs, ArmL = p.ArmL, ArmR = p.ArmR, Sit = true, Breathe = p.Breathe };
            var s = new Sprite();
            s.Stamp(Handle, -8, 11);
            s.Stamp(Bristle, 22, 8);
            s.Merge(Clawd(pose), 0, 0);
            s.Stamp(Hat, -2, -10);
            return s;
        }

        /// 头顶的「!」：经典装在头上方，女巫装在帽檐右侧
        public static void AddExclaim(Sprite s, bool witch)
        {
            int x = witch ? 27 : 11, y = -9;
            s.Rect(x, y, 2, 4, 'A');
            s.Rect(x, y + 5, 2, 2, 'A');
        }

        /// 与 macOS 版 referencePoses() 一一对应，CI 用它逐像素比对
        public static List<KeyValuePair<string, Sprite>> ReferencePoses()
        {
            var r = new List<KeyValuePair<string, Sprite>>();
            Action<string, Sprite> add = (n, s) => r.Add(new KeyValuePair<string, Sprite>(n, s));
            add("stand", Clawd(new Pose()));
            add("walk1", Clawd(new Pose { Look = 1, Legs = 1 }));
            add("walk2", Clawd(new Pose { Look = 1, Legs = 2 }));
            add("blink", Clawd(new Pose { Eyes = Eyes.Closed }));
            add("breathe", Clawd(new Pose { Look = -1, Breathe = true }));
            var surprised = Clawd(new Pose { Look = -1, Eyes = Eyes.Wide }); AddExclaim(surprised, false);
            add("surprised", surprised);
            add("cheer", Clawd(new Pose { Eyes = Eyes.Happy, ArmL = 1, ArmR = 1 }));
            add("wave", Clawd(new Pose { Eyes = Eyes.Happy, ArmL = 1 }));
            add("witch", Witch(new Pose()));
            add("witch-right", Witch(new Pose { Look = 1 }).Mirrored(23));
            var ws = Witch(new Pose { Look = -1, Eyes = Eyes.Wide }); AddExclaim(ws, true);
            add("witch-surprised", ws);
            add("witch-cheer", Witch(new Pose { Eyes = Eyes.Happy, ArmL = 1, ArmR = 1 }));
            return r;
        }

        public static string Dump()
        {
            var sb = new StringBuilder();
            foreach (var kv in ReferencePoses())
            {
                var px = kv.Value.Px;
                int x0 = px.Keys.Min(p => p.X), x1 = px.Keys.Max(p => p.X);
                int y0 = px.Keys.Min(p => p.Y), y1 = px.Keys.Max(p => p.Y);
                sb.Append(kv.Key).Append(' ').Append(x0).Append(' ').Append(y0).Append(' ')
                  .Append(x1 - x0 + 1).Append(' ').Append(y1 - y0 + 1).Append('\n');
                for (int y = y0; y <= y1; y++)
                {
                    for (int x = x0; x <= x1; x++)
                    {
                        char c;
                        sb.Append(px.TryGetValue(new Point(x, y), out c) ? c : '.');
                    }
                    sb.Append('\n');
                }
            }
            return sb.ToString();
        }

        /// 把精灵和火花画到 g 上。(ox, oy) 是精灵坐标 (0,0) 的像素位置，unit 是每个像素格的边长
        public static void Draw(Graphics g, Sprite sp, IList<Spark> sparks, float unit, float ox, float oy)
        {
            g.SmoothingMode = SmoothingMode.None;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            var byColor = new Dictionary<char, List<RectangleF>>();
            foreach (var kv in sp.Px)
            {
                List<RectangleF> list;
                if (!byColor.TryGetValue(kv.Value, out list)) { list = new List<RectangleF>(); byColor[kv.Value] = list; }
                list.Add(new RectangleF(ox + kv.Key.X * unit, oy + kv.Key.Y * unit, unit, unit));
            }
            foreach (var kv in byColor)
            {
                Color c;
                if (!Palette.TryGetValue(kv.Key, out c)) continue;
                using (var b = new SolidBrush(c)) g.FillRectangles(b, kv.Value.ToArray());
            }
            if (sparks == null) return;
            foreach (var s in sparks)
            {
                float k = s.Age / s.Life;
                int a = (int)(255 * Math.Max(0, 1 - k * k));
                Color baseC;
                if (!Palette.TryGetValue(s.Color, out baseC)) baseC = Palette['A'];
                float cx = (float)Math.Round(s.X), cy = (float)Math.Round(s.Y);
                int[,] cells = k < 0.45f ? new int[,] { { 0, 0 }, { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
                             : k < 0.75f ? new int[,] { { 0, 0 }, { -1, -1 }, { 1, 1 }, { -1, 1 }, { 1, -1 } }
                             : new int[,] { { 0, 0 } };
                using (var b = new SolidBrush(Color.FromArgb(a, baseC)))
                    for (int i = 0; i < cells.GetLength(0); i++)
                        g.FillRectangle(b, ox + (cx + cells[i, 0]) * unit, oy + (cy + cells[i, 1]) * unit, unit, unit);
            }
        }

        /// 导出全部造型到一张 PNG，方便肉眼核对
        public static void RenderSheet(string path)
        {
            var poses = ReferencePoses();
            int unit = 6, cellW = 64 * unit, cellH = 40 * unit, cols = 3;
            int rows = (poses.Count + cols - 1) / cols;
            using (var bmp = new Bitmap(cellW * cols, cellH * rows, PixelFormat.Format32bppArgb))
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.FromArgb(0xFA, 0xF9, 0xF5));
                using (var f = new Font("Segoe UI", 16f, GraphicsUnit.Pixel))
                    for (int i = 0; i < poses.Count; i++)
                    {
                        float ox = (i % cols) * cellW + 18 * unit, oy = (i / cols) * cellH + 14 * unit;
                        Draw(g, poses[i].Value, null, unit, ox, oy);
                        g.SmoothingMode = SmoothingMode.AntiAlias;
                        g.DrawString(poses[i].Key, f, Brushes.Gray, (i % cols) * cellW + 12, (i / cols) * cellH + 8);
                    }
                bmp.Save(path, ImageFormat.Png);
            }
        }

        public static Bitmap IconBitmap(int size)
        {
            var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                float unit = (float)Math.Floor(size / 24.0);
                if (unit < 1) unit = 1;
                float w = 24 * unit, h = 16 * unit;
                Draw(g, Clawd(new Pose()), null, unit, (float)Math.Floor((size - w) / 2), (float)Math.Floor((size - h) / 2));
            }
            return bmp;
        }
    }

    class Spark
    {
        public float X, Y, VX, VY, Age, Life;
        public char Color;
        public Spark(float x, float y, float vx, float vy, float life, char color)
        { X = x; Y = y; VX = vx; VY = vy; Life = life; Color = color; }
    }

    // ───────────────────────── Win32 ─────────────────────────

    static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X = x; Y = y; } }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int CX, CY; public SIZE(int cx, int cy) { CX = cx; CY = cy; } }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
            IntPtr hdcSrc, ref POINT pprSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint dx, out uint dy);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;

        public static float DpiScale(IntPtr hwnd)
        {
            try
            {
                IntPtr mon = MonitorFromWindow(hwnd, 2);
                uint dx, dy;
                if (GetDpiForMonitor(mon, 0, out dx, out dy) == 0 && dx > 0) return dx / 96f;
            }
            catch { }
            using (var g = Graphics.FromHwnd(IntPtr.Zero)) return g.DpiX / 96f;
        }
    }

    // ───────────────────────── 输入法状态（由 clawd.lua 写入） ─────────────────────────

    class RimeState
    {
        public string Sid = "";
        public bool Composing;
        public int Commits;
        public string Input = "";
        public string PreCaret = "";

        public static RimeState Parse(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            string line = text.Split('\n')[0].TrimEnd('\r');
            string[] f = line.Split('\t');
            if (f.Length < 7 || f[1] != "v1") return null;
            int commits;
            int.TryParse(f[4], out commits);
            return new RimeState { Sid = f[2], Composing = f[3] == "1", Commits = commits, Input = f[5], PreCaret = f[6] };
        }
    }

    static class Paths
    {
        public static string StateDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClawdCompanion"); }
        }
        public static string StateFile { get { return Path.Combine(StateDir, "state"); } }
    }

    // ───────────────────────── 偏好设置（注册表 HKCU\Software\ClawdCompanion） ─────────────────────────

    static class Prefs
    {
        const string Key = @"Software\ClawdCompanion";
        public static string Forced;   // 录制 / 测试时强制装扮

        static object Get(string name, object def)
        {
            try { using (var k = Registry.CurrentUser.OpenSubKey(Key)) { if (k != null) { var v = k.GetValue(name); if (v != null) return v; } } }
            catch { }
            return def;
        }
        static void Set(string name, object v)
        {
            try { using (var k = Registry.CurrentUser.CreateSubKey(Key)) k.SetValue(name, v); } catch { }
        }

        public static bool Enabled { get { return Convert.ToInt32(Get("Enabled", 1)) != 0; } set { Set("Enabled", value ? 1 : 0); } }
        public static bool ShowTray { get { return Convert.ToInt32(Get("ShowTray", 1)) != 0; } set { Set("ShowTray", value ? 1 : 0); } }
        public static string Costume { get { return (string)Get("Costume", "auto"); } set { Set("Costume", value); } }
        public static string Size { get { return (string)Get("Size", "m"); } set { Set("Size", value); } }
        public static int OffsetX { get { return Convert.ToInt32(Get("OffsetX", 0)); } set { Set("OffsetX", value); } }
        public static int OffsetY { get { return Convert.ToInt32(Get("OffsetY", 0)); } set { Set("OffsetY", value); } }
        public static bool DidFirstRun { get { return Convert.ToInt32(Get("DidFirstRun", 0)) != 0; } set { Set("DidFirstRun", value ? 1 : 0); } }
        public static string RimeBackup { get { return (string)Get("RimeBackup", ""); } set { Set("RimeBackup", value); } }

        /// 100% 缩放下每个像素格的边长（物理像素，再乘以显示器缩放比例）
        public static float BaseUnit { get { return Size == "s" ? 1f : Size == "l" ? 3f : 2f; } }

        public static bool IsHalloweenSeason
        {
            get { var d = DateTime.Now; return (d.Month == 10 && d.Day >= 24) || (d.Month == 11 && d.Day <= 2); }
        }
        public static bool IsWitch
        {
            get
            {
                string c = Forced ?? Costume;
                if (c == "witch") return true;
                if (c == "classic") return false;
                return IsHalloweenSeason;
            }
        }
    }

    static class AutoStart
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string Name = "ClawdCompanion";
        public static bool IsOn
        {
            get { try { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(Name) != null; } catch { return false; } }
        }
        public static void Set(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(Name, "\"" + Application.ExecutablePath + "\"");
                else if (k.GetValue(Name) != null) k.DeleteValue(Name);
            }
        }
    }

    // ───────────────────────── 安装 / 卸载小狼毫配置 ─────────────────────────

    static class RimeInstaller
    {
        public const string BeginMark = "# >>> clawd（由 Clawd.exe 添加，卸载时会自动删除这一段）";
        public const string EndMark = "# <<< clawd";
        static readonly Encoding Utf8 = new UTF8Encoding(false);

        public static string RimeDir
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Rime\Weasel"))
                    {
                        var v = k == null ? null : k.GetValue("RimeUserDir") as string;
                        if (!string.IsNullOrEmpty(v)) return Environment.ExpandEnvironmentVariables(v);
                    }
                }
                catch { }
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Rime");
            }
        }

        public static string WeaselRoot
        {
            get
            {
                foreach (var key in new[] { @"SOFTWARE\WOW6432Node\Rime\Weasel", @"SOFTWARE\Rime\Weasel" })
                {
                    try
                    {
                        using (var k = Registry.LocalMachine.OpenSubKey(key))
                        {
                            var v = k == null ? null : k.GetValue("WeaselRoot") as string;
                            if (!string.IsNullOrEmpty(v) && Directory.Exists(v)) return v;
                        }
                    }
                    catch { }
                }
                foreach (var pf in new[] { Environment.GetEnvironmentVariable("ProgramFiles(x86)"), Environment.GetEnvironmentVariable("ProgramFiles") })
                {
                    if (string.IsNullOrEmpty(pf)) continue;
                    var rime = Path.Combine(pf, "Rime");
                    if (!Directory.Exists(rime)) continue;
                    var dirs = Directory.GetDirectories(rime, "weasel-*").OrderByDescending(d => d).ToArray();
                    if (dirs.Length > 0) return dirs[0];
                }
                return null;
            }
        }

        static string Read(string name)
        {
            var p = Path.Combine(RimeDir, name);
            return File.Exists(p) ? File.ReadAllText(p, Encoding.UTF8) : null;
        }
        static void Write(string name, string text) { File.WriteAllText(Path.Combine(RimeDir, name), text, Utf8); }

        public static string Resource(string name)
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            using (var r = new StreamReader(s, Encoding.UTF8)) return r.ReadToEnd();
        }

        public static bool IsInstalled
        {
            get
            {
                var t = Read("rime_ice.custom.yaml");
                return File.Exists(Path.Combine(RimeDir, @"lua\clawd.lua")) && t != null && t.Contains("lua_translator@*clawd");
            }
        }

        public static string StatusText
        {
            get
            {
                if (WeaselRoot == null) return "没有检测到小狼毫（Weasel），请先安装小狼毫和雾凇拼音";
                if (!File.Exists(Path.Combine(RimeDir, "rime_ice.schema.yaml"))) return "没有检测到雾凇拼音（rime_ice），其他方案请参考 README 手动配置";
                return IsInstalled ? "已安装 ✓" : "尚未安装";
            }
        }

        static string Block
        {
            get
            {
                return BeginMark + "\n" +
                       "  \"engine/translators/+\":\n" +
                       "    - lua_translator@*clawd\n" +
                       "  clawd:\n" +
                       "    style: companion\n" +
                       "    sparkle: true\n" +
                       EndMark;
            }
        }

        /// 只在「patch: 是唯一的顶层键」时才自动追加，避免把别人的 YAML 改坏
        static List<string> TopLevelKeys(string text)
        {
            var keys = new List<string>();
            foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
            {
                if (raw.Length == 0) continue;
                char c = raw[0];
                if (c == ' ' || c == '\t' || c == '#' || raw == "---") continue;
                keys.Add(raw.Split(':')[0]);
            }
            return keys;
        }

        public static void Deploy()
        {
            var root = WeaselRoot;
            if (root == null) return;
            var exe = Path.Combine(root, "WeaselDeployer.exe");
            if (!File.Exists(exe)) return;
            try { Process.Start(new ProcessStartInfo(exe, "/deploy") { UseShellExecute = false, WorkingDirectory = root }); }
            catch { }
        }

        public static string Install()
        {
            if (WeaselRoot == null) return "没有检测到小狼毫，请先安装：https://rime.im";
            try
            {
                var rime = RimeDir;
                Directory.CreateDirectory(Path.Combine(rime, "lua"));
                var backup = Path.Combine(rime, "backup_clawd_" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
                Directory.CreateDirectory(backup);
                foreach (var f in new[] { "weasel.custom.yaml", "rime_ice.custom.yaml" })
                    if (File.Exists(Path.Combine(rime, f))) File.Copy(Path.Combine(rime, f), Path.Combine(backup, f), true);
                Prefs.RimeBackup = backup;

                Write("weasel.custom.yaml", Resource("weasel.custom.yaml"));
                File.WriteAllText(Path.Combine(rime, @"lua\clawd.lua"), Resource("clawd.lua"), Utf8);

                string note = "";
                if (File.Exists(Path.Combine(rime, "rime_ice.schema.yaml")))
                {
                    var text = Read("rime_ice.custom.yaml") ?? "";
                    if (text.Contains(BeginMark) || text.Contains("lua_translator@*clawd")) { }
                    else if (text.Contains("engine/translators/+"))
                        note = "\n⚠ 你的 rime_ice.custom.yaml 里已经有 engine/translators/+，为避免冲突没有自动修改，请按 README 手动加一行 lua_translator@*clawd。";
                    else
                    {
                        var keys = TopLevelKeys(text);
                        if (keys.Count == 0) text = "patch:\n" + Block + "\n";
                        else if (keys.Count == 1 && keys[0] == "patch") { if (!text.EndsWith("\n")) text += "\n"; text += Block + "\n"; }
                        else note = "\n⚠ rime_ice.custom.yaml 结构比较特殊，没有自动修改，请按 README 手动配置。";
                        if (note.Length == 0) Write("rime_ice.custom.yaml", text);
                    }
                }
                else note = "\n⚠ 没有检测到雾凇拼音，只安装了主题；其他方案请按 README 手动挂上 clawd.lua。";
                Deploy();
                return "安装完成，小狼毫正在重新部署。原配置已备份到 " + backup + "。" + note;
            }
            catch (Exception e) { return "安装失败：" + e.Message; }
        }

        public static string Uninstall()
        {
            try
            {
                var text = Read("rime_ice.custom.yaml");
                if (text != null)
                {
                    int a = text.IndexOf(BeginMark, StringComparison.Ordinal);
                    int b = a < 0 ? -1 : text.IndexOf(EndMark, a, StringComparison.Ordinal);
                    if (a >= 0 && b >= 0)
                    {
                        int end = b + EndMark.Length;
                        if (end < text.Length && text[end] == '\r') end++;
                        if (end < text.Length && text[end] == '\n') end++;
                        Write("rime_ice.custom.yaml", text.Remove(a, end - a));
                    }
                }
                var lua = Path.Combine(RimeDir, @"lua\clawd.lua");
                if (File.Exists(lua)) File.Delete(lua);
                var backup = Prefs.RimeBackup;
                var theme = Path.Combine(RimeDir, "weasel.custom.yaml");
                if (!string.IsNullOrEmpty(backup) && File.Exists(Path.Combine(backup, "weasel.custom.yaml")))
                    File.Copy(Path.Combine(backup, "weasel.custom.yaml"), theme, true);
                else if (File.Exists(theme) && File.ReadAllText(theme).Contains("claude_light"))
                    File.Delete(theme);
                Deploy();
                return "已卸载并恢复原来的主题，小狼毫正在重新部署。";
            }
            catch (Exception e) { return "卸载失败：" + e.Message; }
        }
    }

    // ───────────────────────── 小狼毫主题里的字号和边距（用来算光标位置） ─────────────────────────

    class WeaselMetrics
    {
        public float FontPoint = 13;
        public float InsetX = 15;     // margin_x + border_width
        public string FontFace = "Microsoft YaHei UI";

        public static WeaselMetrics Load()
        {
            var m = new WeaselMetrics();
            try
            {
                var p = Path.Combine(RimeInstaller.RimeDir, "weasel.custom.yaml");
                if (!File.Exists(p)) return m;
                var s = File.ReadAllText(p, Encoding.UTF8);
                Func<string, float, float> num = (key, def) =>
                {
                    var mt = Regex.Match(s, "\"?style/" + Regex.Escape(key) + "\"?\\s*:\\s*(-?[0-9.]+)");
                    float v;
                    return mt.Success && float.TryParse(mt.Groups[1].Value, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out v) ? v : def;
                };
                m.FontPoint = num("font_point", 13);
                m.InsetX = num("layout/margin_x", 14) + Math.Max(0, num("layout/border_width", 1));
                var f = Regex.Match(s, "\"?style/font_face\"?\\s*:\\s*\"?([^\",:\\r\\n]+)");
                if (f.Success) m.FontFace = f.Groups[1].Value.Trim();
            }
            catch { }
            return m;
        }
    }

    // ───────────────────────── 透明悬浮窗 ─────────────────────────

    class OverlayForm : Form
    {
        public OverlayForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Size = new Size(1, 1);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                // LAYERED | TRANSPARENT（点击穿透）| TOOLWINDOW（不进任务栏和 Alt+Tab）| TOPMOST | NOACTIVATE
                cp.ExStyle |= 0x80000 | 0x20 | 0x80 | 0x8 | 0x8000000;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        public void Present(Bitmap bmp, int x, int y, float alpha)
        {
            IntPtr screen = Native.GetDC(IntPtr.Zero);
            IntPtr mem = Native.CreateCompatibleDC(screen);
            IntPtr hbmp = IntPtr.Zero, old = IntPtr.Zero;
            try
            {
                hbmp = bmp.GetHbitmap(Color.FromArgb(0));
                old = Native.SelectObject(mem, hbmp);
                var size = new Native.SIZE(bmp.Width, bmp.Height);
                var src = new Native.POINT(0, 0);
                var dst = new Native.POINT(x, y);
                var blend = new Native.BLENDFUNCTION
                {
                    BlendOp = 0, BlendFlags = 0,
                    SourceConstantAlpha = (byte)Math.Max(0, Math.Min(255, (int)(alpha * 255))),
                    AlphaFormat = 1
                };
                Native.UpdateLayeredWindow(Handle, screen, ref dst, ref size, mem, ref src, 0, ref blend, 2);
            }
            finally
            {
                Native.ReleaseDC(IntPtr.Zero, screen);
                if (hbmp != IntPtr.Zero) { Native.SelectObject(mem, old); Native.DeleteObject(hbmp); }
                Native.DeleteDC(mem);
            }
        }
    }

    // ───────────────────────── 动画控制 ─────────────────────────

    class Controller
    {
        const int CanvasW = 64, CanvasH = 54, AnchorX = 20, AnchorY = 32, FeetRow = 48;

        public readonly OverlayForm Overlay = new OverlayForm();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly Random rnd = new Random();
        FileSystemWatcher fsw;
        WeaselMetrics metrics = WeaselMetrics.Load();

        RimeState state = new RimeState();
        double lastTick;
        float clock;

        float x, targetX; bool hasX;
        int facing = 1;
        float walkClock, alpha, dropIn;
        bool showing;
        Rectangle lastPanel; IntPtr lastPanelHwnd; float lastScale = 1;
        float nextBlink = 2, blinkUntil, nextLook = 5, lookUntil; int lookDir;
        int lastInputLen; float backUntil, lastKeyAt;
        float? jumpT, hopT;
        float cheerSparkAt, trailAt, topmostAt;
        readonly List<Spark> sparks = new List<Spark>();
        readonly List<string> logLines = new List<string>();
        string lastLogKey = "";

        public Controller()
        {
            var h = Overlay.Handle;   // 先创建窗口句柄，后面要在 UI 线程上回调
            timer.Interval = 15;
            timer.Tick += (s, e) => Tick();
            try { Directory.CreateDirectory(Paths.StateDir); } catch { }
            if (!File.Exists(Paths.StateFile)) try { File.WriteAllText(Paths.StateFile, ""); } catch { }
            fsw = new FileSystemWatcher(Paths.StateDir, "state");
            fsw.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName;
            fsw.SynchronizingObject = Overlay;
            fsw.Changed += (s, e) => ReadState();
            fsw.Created += (s, e) => ReadState();
            fsw.EnableRaisingEvents = true;
        }

        public void ReloadMetrics() { metrics = WeaselMetrics.Load(); }

        void Log(string key, string msg)
        {
            if (key == lastLogKey) return;
            lastLogKey = key;
            logLines.Add(DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg);
            if (logLines.Count > 60) logLines.RemoveRange(0, logLines.Count - 60);
            try { File.WriteAllText(Path.Combine(Paths.StateDir, "live.log"), string.Join("\r\n", logLines), Encoding.UTF8); } catch { }
        }

        public void ReadState()
        {
            for (int i = 0; i < 3; i++)
            {
                try
                {
                    using (var fs = new FileStream(Paths.StateFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    using (var r = new StreamReader(fs, Encoding.UTF8))
                    {
                        var st = RimeState.Parse(r.ReadToEnd());
                        if (st != null) Receive(st);
                        return;
                    }
                }
                catch (IOException) { Thread.Sleep(5); }
                catch { return; }
            }
        }

        public void Receive(RimeState st)
        {
            var old = state;
            state = st;
            if (st.Composing != old.Composing || st.Commits != old.Commits)
                Log("state" + st.Composing + st.Commits, "收到输入法状态 composing=" + st.Composing + " commits=" + st.Commits + " input=" + st.Input);
            if (st.Sid == old.Sid && st.Commits > old.Commits && showing) { jumpT = 0; Burst(8); }
            int n = st.Input.Length;
            if (st.Composing)
            {
                if (n < lastInputLen) { backUntil = clock + 0.6f; hopT = 0; }
                if (n != lastInputLen) lastKeyAt = clock;
            }
            lastInputLen = st.Composing ? n : 0;
            Wake();
        }

        public void Wake()
        {
            if (timer.Enabled) return;
            lastTick = watch.Elapsed.TotalSeconds;
            timer.Start();
        }

        float Rand(float a, float b) { return a + (float)rnd.NextDouble() * (b - a); }

        void Burst(int count)
        {
            for (int i = 0; i < count; i++)
            {
                double a = (double)i / count * Math.PI * 2 + Rand(-0.3f, 0.3f);
                float sp = Rand(14, 24);
                sparks.Add(new Spark(12, 2, (float)Math.Cos(a) * sp, (float)Math.Sin(a) * sp - 10, Rand(0.45f, 0.7f), i % 3 == 0 ? 'L' : 'O'));
            }
        }

        bool FindPanel(out Rectangle rect, out IntPtr hwnd)
        {
            rect = Rectangle.Empty; hwnd = IntPtr.Zero;
            long bestArea = 0;
            IntPtr h = IntPtr.Zero;
            while ((h = Native.FindWindowEx(IntPtr.Zero, h, "WeaselPanel", null)) != IntPtr.Zero)
            {
                if (!Native.IsWindowVisible(h)) continue;
                Native.RECT rc;
                if (!Native.GetWindowRect(h, out rc)) continue;
                int w = rc.Right - rc.Left, hh = rc.Bottom - rc.Top;
                if (w < 30 || hh < 14) continue;
                long a = (long)w * hh;
                if (a > bestArea) { bestArea = a; hwnd = h; rect = new Rectangle(rc.Left, rc.Top, w, hh); }
            }
            return hwnd != IntPtr.Zero;
        }

        float TextWidth(string s, float scale)
        {
            if (string.IsNullOrEmpty(s)) return 0;
            float px = metrics.FontPoint * 96f / 72f * scale;
            try
            {
                using (var f = new Font(metrics.FontFace, px, GraphicsUnit.Pixel))
                    return TextRenderer.MeasureText(s, f, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
            }
            catch { return s.Length * px * 0.55f; }
        }

        void Tick()
        {
            double now = watch.Elapsed.TotalSeconds;
            float dt = (float)Math.Min(0.05, now - lastTick);
            lastTick = now;
            clock += dt;
            bool witch = Prefs.IsWitch;

            Rectangle panel = Rectangle.Empty; IntPtr panelHwnd = IntPtr.Zero;
            bool want = Prefs.Enabled && state.Composing && FindPanel(out panel, out panelHwnd);
            if (Prefs.Enabled && state.Composing)
                Log(want ? "panel-ok" : "panel-none", want
                    ? "找到候选框 " + panel.X + "," + panel.Y + " " + panel.Width + "×" + panel.Height + "，显示 Clawd"
                    : "在输入，但没找到小狼毫候选框窗口（WeaselPanel）");

            if (want)
            {
                if (panelHwnd != lastPanelHwnd) { lastScale = Native.DpiScale(panelHwnd); lastPanelHwnd = panelHwnd; }
                lastPanel = panel;
                if (!showing)
                {
                    showing = true;
                    dropIn = 6;
                    nextBlink = clock + 0.8f;
                    nextLook = clock + 1.6f;
                    Overlay.Show();
                }
            }
            float scale = lastScale;
            float unit = Math.Max(1f, (float)Math.Round(Prefs.BaseUnit * scale));

            if (want)
            {
                float caretX = panel.Left + metrics.InsetX * scale + TextWidth(state.PreCaret, scale) + 3 * scale;
                float bodyW = 24 * unit;
                float lo = panel.Left + 6 * scale, hi = Math.Max(lo, panel.Right - bodyW - 6 * scale);
                targetX = Math.Min(Math.Max(caretX - bodyW / 2, lo), hi);
                if (!hasX) { x = targetX; hasX = true; }
                alpha = Math.Min(1, alpha + dt / 0.15f);
            }
            else
            {
                if (jumpT == null) alpha = Math.Max(0, alpha - dt / 0.2f);
                if (alpha == 0 && showing && jumpT == null)
                {
                    showing = false;
                    hasX = false;
                    Overlay.Hide();
                    sparks.Clear();
                }
            }

            // 位移：平滑追赶目标，追赶时迈腿
            float dx = targetX - x;
            x += dx * (1 - (float)Math.Exp(-dt * 14));
            bool moving = Math.Abs(dx) > 0.75f * scale;
            if (moving) { facing = dx > 0 ? 1 : -1; walkClock += dt; } else walkClock = 0;
            int[] phases = { 1, 0, 2, 0 };
            int legPhase = moving ? phases[(int)(walkClock / 0.07f) % 4] : 0;

            var pose = new Pose { Legs = witch ? 0 : legPhase };
            bool idle = !moving && clock - lastKeyAt > 0.6f;
            if (moving) pose.Look = facing;
            else if (idle)
            {
                if (clock > nextLook) { lookDir = lookDir == 1 ? -1 : 1; lookUntil = clock + 0.55f; nextLook = clock + Rand(1.0f, 2.2f); }
                if (clock < lookUntil) pose.Look = lookDir;
                pose.Breathe = !witch && ((int)(clock / 0.55f)) % 2 == 1;
            }
            if (clock > nextBlink) { blinkUntil = clock + 0.13f; nextBlink = clock + Rand(1.6f, 3.4f); }
            if (clock < blinkUntil) pose.Eyes = Eyes.Closed;
            if (clock < backUntil) pose.Eyes = Eyes.Wide;

            string lower = state.Input.ToLowerInvariant();
            bool cheering = state.Composing && (lower.Contains("claude") || lower.Contains("kelaode"));
            if (cheering)
            {
                pose.Eyes = Eyes.Happy;
                int ph = ((int)(clock / 0.16f)) % 2;
                pose.ArmL = ph; pose.ArmR = 1 - ph;
                if (clock > cheerSparkAt)
                {
                    cheerSparkAt = clock + 0.14f;
                    sparks.Add(new Spark(Rand(-2, 26), Rand(-6, 2), Rand(-6, 6), -14, 0.6f, rnd.Next(2) == 0 ? 'O' : 'L'));
                }
            }

            // 上屏：跳一下、举双钳；退格：往上一弹
            float lift = 0;
            if (jumpT.HasValue)
            {
                float t = jumpT.Value, T = 0.42f;
                if (t < T)
                {
                    lift += 10 * 4 * (t / T) * (1 - t / T);
                    pose.ArmL = 1; pose.ArmR = 1; pose.Eyes = Eyes.Happy; pose.Legs = 0;
                    jumpT = t + dt;
                }
                else jumpT = null;
            }
            if (hopT.HasValue)
            {
                float t = hopT.Value, T = 0.22f;
                if (t < T) { lift += 4 * 4 * (t / T) * (1 - t / T); hopT = t + dt; } else hopT = null;
            }
            if (dropIn > 0) { lift += dropIn; dropIn = Math.Max(0, dropIn - dt * 40); }

            Sprite sprite;
            if (witch)
            {
                lift += 5 + (float)Math.Round(1.5 * Math.Sin(clock * 3.2));
                sprite = Art.Witch(pose);
                if (facing > 0) sprite = sprite.Mirrored(23);
                if (moving && clock > trailAt)   // 草穗后面拖出一串小火花
                {
                    trailAt = clock + 0.05f;
                    char[] cs = { 'L', 'Y', 'O' };
                    sparks.Add(new Spark(facing > 0 ? -12 : 36, Rand(12, 17), -facing * Rand(8, 16), Rand(-4, 4), 0.5f, cs[rnd.Next(3)]));
                }
            }
            else sprite = Art.Clawd(pose);

            if (clock < backUntil) Art.AddExclaim(sprite, witch);
            if (state.Composing && state.Input.Length >= 16 && !cheering)   // 编码很长：冒汗
            {
                int k = ((int)(clock / 0.12f)) % 6;
                sprite.Rect(witch && facing > 0 ? -3 : 25, -2 + k, 1, 2, 'B');
            }
            int liftPx = (int)Math.Round(lift);
            if (liftPx != 0) sprite = sprite.Shifted(-liftPx);

            for (int i = sparks.Count - 1; i >= 0; i--)
            {
                var s = sparks[i];
                s.Age += dt; s.X += s.VX * dt; s.Y += s.VY * dt; s.VY += 18 * dt;
                if (s.Age >= s.Life) sparks.RemoveAt(i);
            }

            // 脚底踩在候选框上沿
            if (showing)
            {
                int w = (int)(CanvasW * unit), h = (int)(CanvasH * unit);
                using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
                {
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.Clear(Color.Transparent);
                        Art.Draw(g, sprite, sparks, unit, AnchorX * unit, AnchorY * unit);
                    }
                    int ox = (int)Math.Round(x - AnchorX * unit) + (int)Math.Round(Prefs.OffsetX * scale);
                    int oy = (int)Math.Round(lastPanel.Top + 1 * scale - FeetRow * unit) + (int)Math.Round(Prefs.OffsetY * scale);
                    Overlay.Present(bmp, ox, oy, alpha);
                }
                if (clock > topmostAt)   // 小狼毫候选框也是置顶窗口，定期把自己提到它上面
                {
                    topmostAt = clock + 0.5f;
                    Native.SetWindowPos(Overlay.Handle, Native.HWND_TOPMOST, 0, 0, 0, 0,
                        Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
                }
            }

            if (!showing && sparks.Count == 0) timer.Stop();
        }
    }

    // ───────────────────────── 设置窗口 ─────────────────────────

    /// 设置窗口顶部的动画预览：Clawd 在一个小输入框上循环表演全部动作
    class PreviewControl : Control
    {
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly Random rnd = new Random();
        readonly List<Spark> sparks = new List<Spark>();
        double last; float t, sparkAt; int lastSeg = -1;
        public bool Witch;

        public PreviewControl()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            timer.Interval = 16;
            timer.Tick += (s, e) => Step();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) { last = watch.Elapsed.TotalSeconds; timer.Start(); } else timer.Stop();
        }

        protected override void Dispose(bool disposing) { if (disposing) timer.Dispose(); base.Dispose(disposing); }

        float Rand(float a, float b) { return a + (float)rnd.NextDouble() * (b - a); }

        void Step()
        {
            double now = watch.Elapsed.TotalSeconds;
            float dt = (float)Math.Min(0.05, now - last);
            last = now; t += dt;
            for (int i = sparks.Count - 1; i >= 0; i--)
            {
                var s = sparks[i];
                s.Age += dt; s.X += s.VX * dt; s.Y += s.VY * dt; s.VY += 18 * dt;
                if (s.Age >= s.Life) sparks.RemoveAt(i);
            }
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            float scale = g.DpiX / 96f;
            g.Clear(Color.FromArgb(0xFA, 0xF9, 0xF5));
            float baseY = Height - 30 * scale;
            var box = new RectangleF(50 * scale, baseY, Width - 100 * scale, 70 * scale);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = RoundRect(box, 14 * scale))
            using (var fill = new SolidBrush(Color.White))
            using (var pen = new Pen(Color.FromArgb(38, 31, 30, 29), 1))
            { g.FillPath(fill, path); g.DrawPath(pen, path); }

            float unit = (float)Math.Round(3 * scale);
            const float L = 8.4f;
            float k = t % L;
            var pose = new Pose();
            float xOff = 0, lift = 0; int facing = 1; bool exclaim = false, moving = false; int seg;
            if (k < 2.4f)
            {
                seg = 0;
                double ph = k / 2.4 * 2 * Math.PI;
                xOff = (float)Math.Sin(ph) * 46 * scale; facing = Math.Cos(ph) >= 0 ? 1 : -1; moving = true;
                int[] phases = { 1, 0, 2, 0 };
                pose.Look = facing; pose.Legs = phases[(int)(k / 0.08f) % 4];
            }
            else if (k < 3.8f)
            {
                seg = 1;
                pose.Breathe = ((int)(k / 0.5f)) % 2 == 1;
                if (k > 2.7f && k < 2.84f) pose.Eyes = Eyes.Closed;
                if (k > 3.0f && k < 3.45f) pose.Look = -1; else if (k > 3.45f) pose.Look = 1;
            }
            else if (k < 5.3f)
            {
                seg = 2;
                pose.Eyes = Eyes.Happy;
                int ph = ((int)(k / 0.16f)) % 2; pose.ArmL = ph; pose.ArmR = 1 - ph;
                if (t > sparkAt)
                {
                    sparkAt = t + 0.14f;
                    sparks.Add(new Spark(Rand(-2, 26), Rand(-6, 2), Rand(-6, 6), -14, 0.6f, rnd.Next(2) == 0 ? 'O' : 'L'));
                }
            }
            else if (k < 5.8f)
            {
                seg = 3;
                float tt = (k - 5.3f) / 0.42f;
                if (tt < 1) lift = 10 * 4 * tt * (1 - tt);
                pose.ArmL = 1; pose.ArmR = 1; pose.Eyes = Eyes.Happy;
            }
            else if (k < 6.6f)
            {
                seg = 4;
                pose.Eyes = Eyes.Wide; pose.Look = -1; exclaim = true;
                float tt = (k - 5.8f) / 0.22f;
                if (tt < 1) lift = 4 * 4 * tt * (1 - tt);
            }
            else
            {
                seg = 5;
                pose.Breathe = ((int)(k / 0.5f)) % 2 == 1;
                if (k > 7.6f && k < 7.74f) pose.Eyes = Eyes.Closed;
            }
            if (seg == 3 && lastSeg != 3)
                for (int i = 0; i < 8; i++)
                {
                    double a = i / 8.0 * Math.PI * 2;
                    sparks.Add(new Spark(12, 2, (float)Math.Cos(a) * 20, (float)Math.Sin(a) * 20 - 10, 0.6f, i % 3 == 0 ? 'L' : 'O'));
                }
            lastSeg = seg;

            Sprite sprite;
            if (Witch)
            {
                pose.Legs = 0;
                lift += 5 + (float)Math.Round(1.5 * Math.Sin(t * 3.2));
                sprite = Art.Witch(pose);
                if (facing > 0) sprite = sprite.Mirrored(23);
                if (moving && t > sparkAt)
                {
                    sparkAt = t + 0.05f;
                    char[] cs = { 'L', 'Y', 'O' };
                    sparks.Add(new Spark(facing > 0 ? -12 : 36, Rand(12, 17), -facing * Rand(8, 16), Rand(-4, 4), 0.5f, cs[rnd.Next(3)]));
                }
            }
            else sprite = Art.Clawd(pose);
            if (exclaim) Art.AddExclaim(sprite, Witch);

            float ox = (float)Math.Round(Width / 2f + xOff - 12 * unit);
            float oy = baseY + 1 - 16 * unit - (float)Math.Round(lift) * unit;
            Art.Draw(g, sprite, sparks, unit, ox, oy);
        }

        static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    class SettingsForm : Form
    {
        readonly ClawdApp app;
        readonly PreviewControl preview = new PreviewControl();
        readonly CheckBox enabled = new CheckBox(), autoStart = new CheckBox(), showTray = new CheckBox();
        readonly ComboBox costume = new ComboBox(), size = new ComboBox();
        readonly Label rimeStatus = new Label(), rimeMessage = new Label();
        readonly Button installBtn = new Button(), uninstallBtn = new Button();
        readonly NumericUpDown offX = new NumericUpDown(), offY = new NumericUpDown();
        bool loading;

        static readonly Color Paper = Color.FromArgb(0xF5, 0xF4, 0xF0);
        static readonly Color Accent = Color.FromArgb(0xC9, 0x64, 0x42);
        static readonly Color Muted = Color.FromArgb(0x6E, 0x6B, 0x64);

        public SettingsForm(ClawdApp app)
        {
            this.app = app;
            SuspendLayout();
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Text = "Clawd 伴随";
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Paper;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(460, 640);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            preview.SetBounds(0, 0, 460, 150);
            Controls.Add(preview);

            int y = 166;
            Section("外观", ref y);
            enabled.Text = "打字时显示 Clawd";
            Row(enabled, ref y);
            costume.DropDownStyle = ComboBoxStyle.DropDownList;
            costume.Items.AddRange(new object[] { "自动（节日换装）", "经典", "女巫" });
            LabeledRow("装扮", costume, ref y);
            size.DropDownStyle = ComboBoxStyle.DropDownList;
            size.Items.AddRange(new object[] { "小", "中", "大" });
            LabeledRow("大小", size, ref y);
            Note("「自动」会在万圣节前后（10 月 24 日 – 11 月 2 日）换上女巫装。", ref y);

            Section("小狼毫主题与小螃蟹脚本", ref y);
            rimeStatus.SetBounds(24, y + 4, 230, 22);
            Controls.Add(rimeStatus);
            installBtn.SetBounds(256, y, 92, 28);
            uninstallBtn.SetBounds(352, y, 84, 28);
            uninstallBtn.Text = "卸载";
            foreach (var b in new[] { installBtn, uninstallBtn }) { b.FlatStyle = FlatStyle.System; Controls.Add(b); }
            y += 34;
            rimeMessage.SetBounds(24, y, 412, 48);
            rimeMessage.ForeColor = Muted;
            Controls.Add(rimeMessage);
            y += 50;

            Section("系统", ref y);
            autoStart.Text = "开机自动启动";
            Row(autoStart, ref y);
            showTray.Text = "在通知区域（右下角）显示图标";
            Row(showTray, ref y);
            Note("隐藏图标后，再次打开 Clawd.exe 就会回到这个窗口。", ref y);

            Section("位置微调（如果 Clawd 没有正好站在候选框上，可以在这里调）", ref y);
            foreach (var n in new[] { offX, offY }) { n.Minimum = -200; n.Maximum = 200; n.Width = 70; }
            var lx = new Label { Text = "左右", AutoSize = true }; lx.Location = new Point(24, y + 3);
            offX.Location = new Point(64, y);
            var ly = new Label { Text = "上下", AutoSize = true }; ly.Location = new Point(160, y + 3);
            offY.Location = new Point(200, y);
            Controls.AddRange(new Control[] { lx, offX, ly, offY });
            y += 36;

            var openRime = new Button { Text = "打开 Rime 配置", FlatStyle = FlatStyle.System };
            openRime.SetBounds(24, y + 6, 130, 30);
            var quit = new Button { Text = "退出 Clawd", FlatStyle = FlatStyle.System };
            quit.SetBounds(336, y + 6, 100, 30);
            Controls.AddRange(new Control[] { openRime, quit });

            enabled.CheckedChanged += (s, e) => { if (!loading) { Prefs.Enabled = enabled.Checked; app.PrefsChanged(); } };
            costume.SelectedIndexChanged += (s, e) =>
            {
                if (loading) return;
                Prefs.Costume = new[] { "auto", "classic", "witch" }[costume.SelectedIndex];
                preview.Witch = Prefs.IsWitch; app.PrefsChanged();
            };
            size.SelectedIndexChanged += (s, e) => { if (!loading) { Prefs.Size = new[] { "s", "m", "l" }[size.SelectedIndex]; app.PrefsChanged(); } };
            autoStart.CheckedChanged += (s, e) =>
            {
                if (loading) return;
                try { AutoStart.Set(autoStart.Checked); }
                catch (Exception ex) { rimeMessage.Text = "开机启动设置失败：" + ex.Message; }
            };
            showTray.CheckedChanged += (s, e) => { if (!loading) { Prefs.ShowTray = showTray.Checked; app.UpdateTray(); } };
            offX.ValueChanged += (s, e) => { if (!loading) Prefs.OffsetX = (int)offX.Value; };
            offY.ValueChanged += (s, e) => { if (!loading) Prefs.OffsetY = (int)offY.Value; };
            installBtn.Click += (s, e) => { rimeMessage.Text = RimeInstaller.Install(); app.Controller.ReloadMetrics(); Refresh2(); };
            uninstallBtn.Click += (s, e) => { rimeMessage.Text = RimeInstaller.Uninstall(); Refresh2(); };
            openRime.Click += (s, e) => { try { Process.Start("explorer.exe", "\"" + RimeInstaller.RimeDir + "\""); } catch { } };
            quit.Click += (s, e) => app.Quit();

            ResumeLayout(false);
            Refresh2();
        }

        void Section(string title, ref int y)
        {
            var l = new Label { Text = title, AutoSize = true, Font = new Font(Font, FontStyle.Bold), ForeColor = Accent };
            l.Location = new Point(20, y);
            Controls.Add(l);
            y += 26;
        }
        void Row(Control c, ref int y) { c.SetBounds(24, y, 400, 24); Controls.Add(c); y += 28; }
        void LabeledRow(string label, Control c, ref int y)
        {
            var l = new Label { Text = label, AutoSize = true };
            l.Location = new Point(24, y + 3);
            c.SetBounds(96, y, 180, 24);
            Controls.Add(l); Controls.Add(c);
            y += 32;
        }
        void Note(string text, ref int y)
        {
            var l = new Label { Text = text, ForeColor = Muted };
            l.SetBounds(24, y, 412, 20);
            Controls.Add(l);
            y += 26;
        }

        public void Refresh2()
        {
            loading = true;
            enabled.Checked = Prefs.Enabled;
            costume.SelectedIndex = Prefs.Costume == "classic" ? 1 : Prefs.Costume == "witch" ? 2 : 0;
            size.SelectedIndex = Prefs.Size == "s" ? 0 : Prefs.Size == "l" ? 2 : 1;
            autoStart.Checked = AutoStart.IsOn;
            showTray.Checked = Prefs.ShowTray;
            offX.Value = Math.Max(-200, Math.Min(200, Prefs.OffsetX));
            offY.Value = Math.Max(-200, Math.Min(200, Prefs.OffsetY));
            preview.Witch = Prefs.IsWitch;
            bool installed = RimeInstaller.IsInstalled;
            rimeStatus.Text = RimeInstaller.StatusText;
            installBtn.Text = installed ? "重新安装" : "安装到小狼毫";
            uninstallBtn.Enabled = installed;
            loading = false;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
            base.OnFormClosing(e);
        }
    }

    // ───────────────────────── 托盘与程序入口 ─────────────────────────

    class ClawdApp
    {
        public readonly ApplicationContext Context = new ApplicationContext();
        public readonly Controller Controller = new Controller();
        NotifyIcon tray;
        SettingsForm settings;
        IntPtr trayIconHandle;

        public ClawdApp(EventWaitHandle showEvent, string[] args)
        {
            UpdateTray();
            if (!Prefs.DidFirstRun)
            {
                Prefs.DidFirstRun = true;
                try { AutoStart.Set(true); } catch { }
                ShowSettings();
            }
            else if (args.Contains("--settings")) ShowSettings();
            Controller.ReadState();

            // 再次打开 Clawd.exe 时，已运行的实例弹出设置窗口
            ThreadPool.RegisterWaitForSingleObject(showEvent, (s, timedOut) =>
            {
                try { Controller.Overlay.BeginInvoke((Action)ShowSettings); } catch { }
            }, null, -1, false);
        }

        public void UpdateTray()
        {
            if (Prefs.ShowTray)
            {
                if (tray == null)
                {
                    using (var bmp = Art.IconBitmap(32)) trayIconHandle = bmp.GetHicon();
                    tray = new NotifyIcon { Icon = Icon.FromHandle(trayIconHandle), Text = "Clawd 伴随", Visible = true };
                    tray.DoubleClick += (s, e) => ShowSettings();
                }
                BuildMenu();
            }
            else if (tray != null)
            {
                tray.Visible = false; tray.Dispose(); tray = null;
                Native.DestroyIcon(trayIconHandle);
            }
        }

        void BuildMenu()
        {
            if (tray == null) return;
            var m = new ContextMenuStrip();
            var title = new ToolStripMenuItem(Prefs.IsWitch ? "Clawd 伴随 · 万圣节快乐 🎃" : "Clawd 伴随") { Enabled = false };
            m.Items.Add(title);
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(new ToolStripMenuItem("设置…", null, (s, e) => ShowSettings()));
            m.Items.Add(new ToolStripMenuItem("显示 Clawd", null, (s, e) => { Prefs.Enabled = !Prefs.Enabled; PrefsChanged(); }) { Checked = Prefs.Enabled });

            var costume = new ToolStripMenuItem("装扮");
            string[] keys = { "auto", "classic", "witch" }, names = { "自动（节日换装）", "经典", "女巫" };
            for (int i = 0; i < keys.Length; i++)
            {
                string key = keys[i];
                costume.DropDownItems.Add(new ToolStripMenuItem(names[i], null, (s, e) => { Prefs.Costume = key; PrefsChanged(); }) { Checked = Prefs.Costume == key });
            }
            m.Items.Add(costume);

            var size = new ToolStripMenuItem("大小");
            string[] sk = { "s", "m", "l" }, sn = { "小", "中", "大" };
            for (int i = 0; i < sk.Length; i++)
            {
                string key = sk[i];
                size.DropDownItems.Add(new ToolStripMenuItem(sn[i], null, (s, e) => { Prefs.Size = key; PrefsChanged(); }) { Checked = Prefs.Size == key });
            }
            m.Items.Add(size);
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(new ToolStripMenuItem("开机自动启动", null, (s, e) =>
            {
                try { AutoStart.Set(!AutoStart.IsOn); } catch { }
                BuildMenu();
            }) { Checked = AutoStart.IsOn });
            m.Items.Add(new ToolStripMenuItem("打开 Rime 配置文件夹", null, (s, e) =>
            {
                try { Process.Start("explorer.exe", "\"" + RimeInstaller.RimeDir + "\""); } catch { }
            }));
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(new ToolStripMenuItem("退出 Clawd", null, (s, e) => Quit()));
            var old = tray.ContextMenuStrip;
            tray.ContextMenuStrip = m;
            if (old != null) old.Dispose();
        }

        public void PrefsChanged()
        {
            BuildMenu();
            Controller.Wake();
            if (settings != null && settings.Visible) settings.Refresh2();
        }

        public void ShowSettings()
        {
            if (settings == null || settings.IsDisposed) settings = new SettingsForm(this);
            settings.Refresh2();
            settings.Show();
            if (settings.WindowState == FormWindowState.Minimized) settings.WindowState = FormWindowState.Normal;
            settings.Activate();
        }

        public void Quit()
        {
            if (tray != null) { tray.Visible = false; tray.Dispose(); }
            Application.Exit();
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            // 命令行：导出造型（CI 用来和 macOS 版逐像素比对）
            int i = Array.IndexOf(args, "--dump-sprites");
            if (i >= 0 && i + 1 < args.Length) { File.WriteAllText(args[i + 1], Art.Dump(), new UTF8Encoding(false)); return 0; }
            i = Array.IndexOf(args, "--render-sheet");
            if (i >= 0 && i + 1 < args.Length) { Art.RenderSheet(args[i + 1]); return 0; }

            try { Native.SetProcessDpiAwarenessContext(new IntPtr(-4)); }   // 每个显示器单独感知 DPI（v2）
            catch { try { Native.SetProcessDPIAware(); } catch { } }

            bool created;
            var mutex = new Mutex(true, @"Local\ClawdCompanion.Single", out created);
            var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\ClawdCompanion.Show");
            if (!created) { showEvent.Set(); return 0; }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var app = new ClawdApp(showEvent, args);
            Application.Run(app.Context);
            GC.KeepAlive(mutex);
            return 0;
        }
    }
}
