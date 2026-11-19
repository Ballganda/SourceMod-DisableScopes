"""Mine one scope-spike run (ticket #4): python mine_spike.py <run dir>

Inputs in the run dir (written by Run-ScopeSpike.ps1):
  live.csv / playback.csv  screen samples: state changes (1 scoped, 0 unscoped) and key marks
  server.csv               scope_spike helper: per-command server state of the client
  scope_spike.dem          the client-recorded demo
Writes summary.json and summary.txt, prints summary.txt.
"""
import csv
import json
import os
import re
import struct
import sys

IN_ATTACK, IN_JUMP, IN_ATTACK2 = 1 << 0, 1 << 1, 1 << 11


def read_capture(path):
    """Scoped intervals [start, end] in ms and the key marks."""
    marks, intervals, start, end_t = [], [], None, None
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            t = float(row["t_ms"])
            end_t = t
            if row["kind"] == "mark":
                marks.append((t, row["value"]))
            elif row["kind"] != "state":
                continue
            elif row["value"] == "1" and start is None:
                start = t
            elif row["value"] == "0" and start is not None:
                intervals.append([start, t])
                start = None
    if start is not None:
        intervals.append([start, end_t])
    return intervals, marks


def label_intervals(intervals, marks):
    """Attach each scoped interval to the last key mark before it."""
    keys = [(t, m[4:]) for t, m in marks if m.startswith("key ")]
    out = []
    for s, e in intervals:
        prior = [k for k in keys if k[0] <= s]
        lab, kt = (prior[-1][1], prior[-1][0]) if prior else ("(none)", s)
        out.append({"after": lab, "delay_ms": round(s - kt, 1), "dur_ms": round(e - s, 1)})
    return out


def summarize_live(labelled, reps_by_lag):
    by = {}
    for iv in labelled:
        parts = iv["after"].split()
        if len(parts) >= 2 and parts[0] in ("air", "ground"):
            key = f"{parts[0]} {parts[1]}"
            by.setdefault(key, []).append(iv)
    return by


def align(live_iv, live_lab, pb_iv, tol=200.0):
    """Shift the playback timeline onto the live one (best offset matching interval starts) and
    say, for each live scoped interval, whether the demo playback showed a scope there too."""
    # anchor on the long (server-allowed ground) scopes, which both channels must show
    long_live = [iv for iv in live_iv if iv[1] - iv[0] > 1000]
    long_pb = [iv for iv in pb_iv if iv[1] - iv[0] > 1000]
    best = (-1, 0.0)
    for ls, _ in long_live:
        for ps, _ in long_pb:
            off = ps - ls
            score = sum(any(abs(p - (l + off)) <= tol for p, _ in long_pb) for l, _ in long_live)
            if score > best[0]:
                best = (score, off)
    off = best[1]
    rows, used = [], set()
    for (ls, le), lab in zip(live_iv, live_lab):
        hit = next((j for j, (ps, pe) in enumerate(pb_iv) if abs(ps - (ls + off)) <= tol), None)
        if hit is not None:
            used.add(hit)
        rows.append({"after": lab["after"], "live_dur_ms": lab["dur_ms"],
                     "playback_dur_ms": None if hit is None else round(pb_iv[hit][1] - pb_iv[hit][0], 1)})
    extra = [{"start_ms_on_live_clock": round(ps - off, 1), "dur_ms": round(pe - ps, 1)}
             for j, (ps, pe) in enumerate(pb_iv) if j not in used]
    return {"offset_ms": round(off, 1), "per_live_interval": rows, "playback_only": extra}


def read_server(path):
    rows = list(csv.DictReader(open(path, newline="")))
    cmd = [r for r in rows if r["kind"] == "cmd"]
    lag = 0
    seen_lags = {}
    air_attack2 = {}      # lag -> commands that reached the server airborne with attack2 still set
    scoped_air = {}       # lag -> commands where the server held fov < 90 while airborne
    scoped_any = {}
    for r in rows:
        if r["kind"] == "lag":
            lag = int(r["lag"])
            seen_lags[lag] = True
            continue
        if r["kind"] != "cmd":
            continue
        b, og, fov = int(r["buttons"]), int(r["onground"]), int(r["fov"])
        zoomed = 0 < fov < 90
        if og == 0 and b & IN_ATTACK2:
            air_attack2[lag] = air_attack2.get(lag, 0) + 1
        if og == 0 and zoomed:
            scoped_air[lag] = scoped_air.get(lag, 0) + 1
        if zoomed:
            scoped_any[lag] = scoped_any.get(lag, 0) + 1
    return {
        "commands": len(cmd),
        "lags": sorted(seen_lags),
        "airborne_cmds_with_attack2_after_plugins": air_attack2,
        "airborne_cmds_server_fov_zoomed": scoped_air,
        "cmds_server_fov_zoomed": scoped_any,
    }


class Bits:
    def __init__(self, data):
        self.v = int.from_bytes(data, "little")
        self.n = len(data) * 8
        self.p = 0

    def u(self, k):
        if self.p + k > self.n:
            raise EOFError
        x = (self.v >> self.p) & ((1 << k) - 1)
        self.p += k
        return x

    def f32(self):
        return struct.unpack("<f", struct.pack("<I", self.u(32)))[0]


def read_usercmd(data):
    """CUserCmd delta against a null command (Source 2009 ReadUsercmd)."""
    b = Bits(data)
    c = {"command_number": None, "buttons": 0}
    if b.u(1):
        c["command_number"] = b.u(32)
    if b.u(1):
        c["tick_count"] = b.u(32)
    for i in range(3):
        if b.u(1):
            c[f"view{i}"] = b.f32()
    for k in ("forwardmove", "sidemove", "upmove"):
        if b.u(1):
            c[k] = b.f32()
    if b.u(1):
        c["buttons"] = b.u(32)
    if b.u(1):
        c["impulse"] = b.u(8)
    if b.u(1):
        c["weaponselect"] = b.u(11)
        if b.u(1):
            c["weaponsubtype"] = b.u(6)
    return c


def names_in_bitstream(blob):
    """Every identifier-like string in a bit-packed blob, at all 8 bit alignments."""
    found = set()
    v = int.from_bytes(blob, "little")
    for shift in range(8):
        data = (v >> shift).to_bytes(len(blob), "little")
        for m in re.finditer(rb"[A-Za-z_][A-Za-z0-9_]{3,63}(?=\x00)", data):
            found.add(m.group().decode())
    return found


def read_demo(path):
    d = open(path, "rb").read()
    if d[:8] != b"HL2DEMO\x00":
        raise ValueError("not an HL2 demo")
    demo_proto, net_proto = struct.unpack_from("<ii", d, 8)
    o = 16
    strs = [d[o + i * 260:o + (i + 1) * 260].split(b"\x00")[0].decode(errors="replace") for i in range(4)]
    o += 1040
    play_time, ticks, frames, signon_len = struct.unpack_from("<fiii", d, o)
    o += 16
    counts, consolecmds, usercmds, cmdinfo_fields = {}, [], [], None
    signon, tables = b"", b""
    while o < len(d):
        cmd = d[o]
        if cmd == 7 or o + 5 > len(d):                # stop (its tick may be cut short)
            counts[7] = counts.get(7, 0) + 1
            break
        tick = struct.unpack_from("<i", d, o + 1)[0]
        o += 5
        counts[cmd] = counts.get(cmd, 0) + 1
        if cmd in (1, 2):
            o += 76 + 8                               # democmdinfo (flags, 3 x origin/angles/localangles x2) + seq in/out
            n = struct.unpack_from("<i", d, o)[0]
            o += 4
            if cmd == 1:
                signon += d[o:o + n]
            o += n
        elif cmd == 3:
            pass
        elif cmd == 4:
            n = struct.unpack_from("<i", d, o)[0]
            consolecmds.append((tick, d[o + 4:o + 4 + n].split(b"\x00")[0].decode(errors="replace")))
            o += 4 + n
        elif cmd == 5:
            seq, n = struct.unpack_from("<ii", d, o)
            try:
                uc = read_usercmd(d[o + 8:o + 8 + n])
            except EOFError:
                uc = {"buttons": 0, "bad": True}
            uc["tick"] = tick
            usercmds.append(uc)
            o += 8 + n
        elif cmd in (6, 8):
            n = struct.unpack_from("<i", d, o)[0]
            if cmd == 6:
                tables += d[o + 4:o + 4 + n]
            o += 4 + n
        elif cmd == 7:
            break
        else:
            raise ValueError(f"unknown demo command {cmd} at {o}")
    names = names_in_bitstream(tables) | names_in_bitstream(signon)
    want = re.compile(r"fov|zoom|scope|secondary|primary|shotsfired|clip1|ammo|button|tickbase|weapon_fire|bullet|player_jump|flags$", re.I)
    fields = sorted(n for n in names if want.search(n) and (n.startswith("m_") or n.islower()))
    # key presses as the demo stores them: rising edges of attack2 / jump / attack in the usercmd stream
    edges = {"attack2": 0, "jump": 0, "attack": 0}
    prev = 0
    for uc in usercmds:
        bt = uc["buttons"]
        for name, bit in (("attack2", IN_ATTACK2), ("jump", IN_JUMP), ("attack", IN_ATTACK)):
            if bt & bit and not prev & bit:
                edges[name] += 1
        prev = bt
    return {
        "demo_protocol": demo_proto, "net_protocol": net_proto, "map": strs[2],
        "playback_time_s": round(play_time, 2), "ticks": ticks, "frames": frames,
        "frame_counts": {str(k): v for k, v in sorted(counts.items())},
        "usercmds": len(usercmds), "usercmd_press_edges": edges,
        "consolecmds": consolecmds[:60], "consolecmd_count": len(consolecmds),
        "scope_shot_key_fields_in_sendtables_and_signon": fields,
    }


def main(run):
    out = {}
    live_iv, live_marks = read_capture(os.path.join(run, "live.csv"))
    live = label_intervals(live_iv, live_marks)
    out["live_scoped_intervals"] = live
    out["live_samples"] = next((m for t, m in live_marks if m.startswith("end samples=")), "")
    pb_path = os.path.join(run, "playback.csv")
    if os.path.exists(pb_path):
        pb_iv, pb_marks = read_capture(pb_path)
        out["playback_scoped_intervals"] = [{"start_ms": round(s, 1), "dur_ms": round(e - s, 1)} for s, e in pb_iv]
        out["playback_samples"] = next((m for t, m in pb_marks if m.startswith("end samples=")), "")
        out["alignment"] = align(live_iv, live, pb_iv)
    sv = os.path.join(run, "server.csv")
    if os.path.exists(sv):
        out["server"] = read_server(sv)
    dem = os.path.join(run, "scope_spike.dem")
    if os.path.exists(dem):
        out["demo"] = read_demo(dem)
    json.dump(out, open(os.path.join(run, "summary.json"), "w"), indent=1)

    lines = []
    by = summarize_live(live, None)
    lines.append("LIVE (what the client screen showed), scoped intervals per key group:")
    for k in sorted(by, key=lambda s: (s.split()[0], int(s.split()[1]))):
        ivs = by[k]
        lines.append(f"  {k:12s} {len(ivs):3d} intervals, durations ms {[iv['dur_ms'] for iv in ivs]}")
    other = [iv for iv in live if not iv["after"].startswith(("air", "ground"))]
    if other:
        lines.append(f"  other        {len(other)}: {other}")
    lines.append(f"  {out['live_samples']}")
    if "playback_scoped_intervals" in out:
        pb = out["playback_scoped_intervals"]
        lines.append(f"PLAYBACK of the client demo: {len(pb)} scoped intervals, durations ms {[p['dur_ms'] for p in pb]}")
        lines.append(f"  {out.get('playback_samples', '')}")
        a = out["alignment"]
        lines.append(f"LIVE vs PLAYBACK (playback shifted by {a['offset_ms']} ms onto the live clock):")
        groups = {}
        for r in a["per_live_interval"]:
            k = " ".join(r["after"].split()[:2])
            g = groups.setdefault(k, [0, 0, []])
            g[0] += 1
            g[1] += r["playback_dur_ms"] is not None
            g[2].append(r["playback_dur_ms"])
        for k, (n, m, durs) in groups.items():
            lines.append(f"  {k:12s} live scoped {n}, also scoped in playback {m}, playback durations ms {durs}")
        lines.append(f"  scoped only in playback (on the live clock; negative = before the demo started, e.g. loading screen): {a['playback_only']}")
    if "server" in out:
        s = out["server"]
        lines.append(f"SERVER: {s['commands']} commands; airborne with attack2 after plugins {s['airborne_cmds_with_attack2_after_plugins']}; "
                     f"airborne with server fov zoomed {s['airborne_cmds_server_fov_zoomed']}; any zoomed {s['cmds_server_fov_zoomed']}")
    if "demo" in out:
        d = out["demo"]
        lines.append(f"DEMO: protocol {d['demo_protocol']}/{d['net_protocol']} map {d['map']} {d['ticks']} ticks, frames by type {d['frame_counts']}")
        lines.append(f"  usercmd press edges {d['usercmd_press_edges']}; {d['consolecmd_count']} console commands, first: {[c for _, c in d['consolecmds'][:12]]}")
        lines.append(f"  scope/shot/key fields named in the demo: {d['scope_shot_key_fields_in_sendtables_and_signon']}")
    txt = "\n".join(lines)
    open(os.path.join(run, "summary.txt"), "w").write(txt + "\n")
    print(txt)


if __name__ == "__main__":
    main(sys.argv[1])
