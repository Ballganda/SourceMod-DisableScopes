// Frame-capture probe for the client-view channel (from the ticket #4 spike). Loaded with Add-Type by
// tests/client/Invoke-ClientCase.ps1 and tests/spike/Run-ScopeSpike.ps1.
// Samples the CS:S client area from the screen as fast as GDI allows and classifies each sample as
// scoped or unscoped: a sniper scope overlay paints the left and right screen edges solid black,
// so four edge points (left and right, at 40% and 60% height) all dark = scoped.
// Key presses go through keybd_event to the focused game window; marks share the sampler's clock.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class ScopeProbe
{
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    // Without DPI awareness, on a display scaled to 175% GetClientRect reported 585x438 for the 1024x768
    // game window and every read (scope edges, ammo HUD) went to the wrong pixels. Physical pixels from here on.
    static ScopeProbe() { SetProcessDPIAware(); }

    // Client area size in physical pixels, for the runner's check that the window is the size the probe expects.
    public static string ClientSize(IntPtr hwnd)
    {
        RECT r; GetClientRect(hwnd, out r);
        return (r.R - r.L) + "x" + (r.B - r.T);
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public const int DarkMax = 6;       // max channel value counted as scope black (the overlay is pure black)
    static readonly Stopwatch Clock = Stopwatch.StartNew();
    static Thread _thread;
    static volatile bool _run;
    static readonly List<string> Rows = new List<string>();
    public static long Samples;

    public static double Now() { return Clock.Elapsed.TotalMilliseconds; }

    // Top-left and topmost: other windows (another srcds console, Steam toasts) must not cover the
    // sampled edges, since the probe reads the desktop, not the game's own back buffer.
    public static void Place(IntPtr hwnd)
    {
        SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001);
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // Title of the window that has the keyboard now, for the runner's error message.
    public static string ForegroundTitle()
    {
        var sb = new System.Text.StringBuilder(256);
        GetWindowText(GetForegroundWindow(), sb, sb.Capacity);
        return sb.ToString();
    }

    // Gives the game window the keyboard; true once it is the foreground window. keybd_event goes to whatever
    // window is in front, so a key sent while another window held the foreground was silently lost (another
    // test's srcds console or a Steam window on the shared desktop). Retries with the foreground thread's input
    // attached, which lifts the foreground lock.
    public static bool Focus(IntPtr hwnd)
    {
        for (int i = 0; i < 10; i++)
        {
            if (GetForegroundWindow() == hwnd) return true;
            keybd_event(0x12, 0, 0, UIntPtr.Zero);          // Alt lets SetForegroundWindow succeed
            ShowWindow(hwnd, 9);
            uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero), me = GetCurrentThreadId();
            bool attached = fg != 0 && fg != me && AttachThreadInput(me, fg, true);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            if (attached) AttachThreadInput(me, fg, false);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            Thread.Sleep(50);
        }
        return GetForegroundWindow() == hwnd;
    }

    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static int PostedKeys;      // keys sent to the window directly because it could not get the foreground

    public static void Key(IntPtr hwnd, byte vk, string label)
    {
        byte scan = (byte)MapVirtualKey(vk, 0);
        if (Focus(hwnd))
        {
            Thread.Sleep(40);
            Mark("key " + label);
            keybd_event(vk, scan, 0, UIntPtr.Zero);
            Thread.Sleep(30);
            keybd_event(vk, scan, 2, UIntPtr.Zero);
            return;
        }
        // Another window holds the foreground and cannot be displaced (a Windows firewall prompt for another
        // test's srcds did, on the shared desktop). The game reads keys from its window messages, so post them
        // to the game window itself; the runner still checks that each case reaches the server.
        PostedKeys++;
        Mark("key " + label);
        PostMessage(hwnd, 0x0100, new IntPtr(vk), new IntPtr(1 | (scan << 16)));                                  // WM_KEYDOWN
        Thread.Sleep(30);
        PostMessage(hwnd, 0x0101, new IntPtr(vk), new IntPtr(unchecked((int)(1u | ((uint)scan << 16) | 0xC0000000u)))); // WM_KEYUP
    }

    public static void Mark(string label)
    {
        lock (Rows) { Rows.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:F2},mark,{1}", Now(), label)); }
    }

    // One classification of the current screen: 1 scoped, 0 unscoped; also returns the 4 edge colours.
    // One blit of the strip between 40% and 60% height (each screen read costs one desktop
    // composition, about 31 ms over Remote Desktop, so one read per sample).
    static Bitmap _strip;
    static Graphics _g;
    // Ammo HUD (clip counter, bottom right at 1024x768: x 790..860, y 700..750): its yellow-orange digits
    // are hashed on every sample, so a change of the clip number (a shot the client shows) is detectable.
    public static ulong AmmoHash;
    public static int AmmoLit;
    public static int Classify(IntPtr hwnd, out string detail)
    {
        RECT r; GetClientRect(hwnd, out r);
        POINT o = new POINT(); ClientToScreen(hwnd, ref o);
        int w = r.R - r.L, h = r.B - r.T;
        int y0 = (int)(h * 0.40), y1 = h - 1;
        if (_strip == null || _strip.Width != w || _strip.Height != y1 - y0 + 1)
        {
            if (_g != null) _g.Dispose();
            if (_strip != null) _strip.Dispose();
            _strip = new Bitmap(w, y1 - y0 + 1);
            _g = Graphics.FromImage(_strip);
        }
        _g.CopyFromScreen(o.X, o.Y + y0, 0, 0, _strip.Size);
        int[] xs = { (int)(w * 0.04), (int)(w * 0.96) };
        int[] ys = { 0, (int)(h * 0.60) - y0 };
        bool dark = true;
        detail = "";
        AmmoRegion(w, h, y0);
        foreach (int y in ys)
            foreach (int x in xs)
            {
                Color c = _strip.GetPixel(x, y);
                if (Math.Max(c.R, Math.Max(c.G, c.B)) > DarkMax) dark = false;
                detail += string.Format("{0:X2}{1:X2}{2:X2} ", c.R, c.G, c.B);
            }
        return dark ? 1 : 0;
    }
    static void AmmoRegion(int w, int h, int y0)
    {
        double sx = w / 1024.0, sy = h / 768.0;
        int ax0 = (int)(790 * sx), ax1 = Math.Min((int)(860 * sx), w - 1), ay0 = (int)(700 * sy) - y0, ay1 = Math.Min((int)(750 * sy) - y0, _strip.Height - 1);
        if (ay0 < 0 || ax1 <= ax0 || ay1 <= ay0) { AmmoHash = 0; AmmoLit = 0; return; }
        var data = _strip.LockBits(new Rectangle(ax0, ay0, ax1 - ax0 + 1, ay1 - ay0 + 1), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        ulong hash = 1469598103934665603UL; int lit = 0;
        try
        {
            byte[] row = new byte[data.Stride];
            for (int y = 0; y < data.Height; y++)
            {
                Marshal.Copy(new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), row, 0, data.Stride);
                for (int x = 0; x < data.Width; x++)
                {
                    int b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2];
                    // orange by hue, not brightness: the digits drew at about (210,144,67) in one run and
                    // (103,74,27) in another, and the old test (red above 110) saw none of the dim ones
                    bool on = r >= 60 && r * 10 > g * 12 && g * 10 > b * 18 && r - b > 40;
                    if (on) lit++;
                    hash = (hash ^ (on ? 1UL : 0UL)) * 1099511628211UL;
                }
            }
        }
        finally { _strip.UnlockBits(data); }
        AmmoHash = hash; AmmoLit = lit;
    }

    public static void Start(IntPtr hwnd)
    {
        lock (Rows) { Rows.Clear(); }
        Samples = 0;
        _run = true;
        _thread = new Thread(() =>
        {
            int last = -1;
            double nextProbe = 0;
            ulong shown = 0, pending = 0; int pendingN = 0; bool haveShown = false;
            while (_run)
            {
                string d;
                int s = Classify(hwnd, out d);
                Samples++;
                double t = Now();
                if (s != last)
                {
                    lock (Rows) { Rows.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:F2},state,{1},{2}", t, s, d.Trim())); }
                    last = s;
                }
                ulong ah = AmmoHash;
                if (!haveShown) { shown = ah; haveShown = true; }
                else if (ah == shown) { pendingN = 0; }
                else
                {
                    if (ah == pending) pendingN++; else { pending = ah; pendingN = 1; }
                    if (pendingN >= 2)          // stable for two samples: the clip counter changed
                    {
                        shown = ah; pendingN = 0;
                        lock (Rows) { Rows.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:F2},ammo,{1},{2}", t, ah, AmmoLit)); }
                    }
                }
                if (t >= nextProbe)               // edge colours every 500 ms, for diagnosis
                {
                    lock (Rows) { Rows.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:F2},probe,{1},{2}", t, s, d.Trim())); }
                    nextProbe = t + 500;
                }
            }
        });
        _thread.IsBackground = true;
        _thread.Start();
    }

    // Stops sampling and writes "t_ms,kind,value[,detail]" rows (state changes and marks, in time order).
    public static void Stop(string csvPath)
    {
        _run = false;
        if (_thread != null) _thread.Join();
        Mark("end samples=" + Samples);
        List<string> rows;
        lock (Rows) { rows = new List<string>(Rows); }
        rows.Sort((a, b) => double.Parse(a.Split(',')[0], System.Globalization.CultureInfo.InvariantCulture)
            .CompareTo(double.Parse(b.Split(',')[0], System.Globalization.CultureInfo.InvariantCulture)));
        rows.Insert(0, "t_ms,kind,value,detail");
        File.WriteAllLines(csvPath, rows.ToArray());
    }

    public static void Snapshot(IntPtr hwnd, string pngPath)
    {
        RECT r; GetClientRect(hwnd, out r);
        POINT o = new POINT(); ClientToScreen(hwnd, ref o);
        using (Bitmap b = new Bitmap(r.R - r.L, r.B - r.T))
        using (Graphics g = Graphics.FromImage(b))
        {
            g.CopyFromScreen(o.X, o.Y, 0, 0, b.Size);
            b.Save(pngPath, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
