// Frame-capture probe for the scope spike (ticket #4). Loaded by Run-ScopeSpike.ps1 with Add-Type.
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

    public static void Focus(IntPtr hwnd)
    {
        keybd_event(0x12, 0, 0, UIntPtr.Zero);          // Alt lets SetForegroundWindow succeed
        ShowWindow(hwnd, 9);
        SetForegroundWindow(hwnd);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }

    public static void Key(IntPtr hwnd, byte vk, string label)
    {
        Focus(hwnd);
        Thread.Sleep(40);
        byte scan = (byte)MapVirtualKey(vk, 0);
        Mark("key " + label);
        keybd_event(vk, scan, 0, UIntPtr.Zero);
        Thread.Sleep(30);
        keybd_event(vk, scan, 2, UIntPtr.Zero);
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
    public static int Classify(IntPtr hwnd, out string detail)
    {
        RECT r; GetClientRect(hwnd, out r);
        POINT o = new POINT(); ClientToScreen(hwnd, ref o);
        int w = r.R - r.L, h = r.B - r.T;
        int y0 = (int)(h * 0.40), y1 = (int)(h * 0.60);
        if (_strip == null || _strip.Width != w || _strip.Height != y1 - y0 + 1)
        {
            if (_g != null) _g.Dispose();
            if (_strip != null) _strip.Dispose();
            _strip = new Bitmap(w, y1 - y0 + 1);
            _g = Graphics.FromImage(_strip);
        }
        _g.CopyFromScreen(o.X, o.Y + y0, 0, 0, _strip.Size);
        int[] xs = { (int)(w * 0.04), (int)(w * 0.96) };
        int[] ys = { 0, y1 - y0 };
        bool dark = true;
        detail = "";
        foreach (int y in ys)
            foreach (int x in xs)
            {
                Color c = _strip.GetPixel(x, y);
                if (Math.Max(c.R, Math.Max(c.G, c.B)) > DarkMax) dark = false;
                detail += string.Format("{0:X2}{1:X2}{2:X2} ", c.R, c.G, c.B);
            }
        return dark ? 1 : 0;
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
