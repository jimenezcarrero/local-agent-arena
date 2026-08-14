#!/usr/bin/env python3
"""Round-5 results matrix for the Jetson local-agent campaign.

Status encoding is icon + word + color (never color alone). Label inks are the
darkened status steps so text clears 4.5:1 on its own cell fill.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

SURFACE = "#fcfcfb"
INK = "#1a1a1a"
INK2 = "#4a4a4a"
MUTED = "#8a8a88"
BLUE = "#2a78d6"

# fills (light) + label inks (dark enough for text on those fills)
FILL = {"P": "#d9f0da", "W": "#fdf0d5", "F": "#fbdedd", "-": "#eeeeec"}
TEXT = {"P": "#0a7d0a", "W": "#8a5a00", "F": "#b32c2c", "-": MUTED}
GLYPH = {"P": "✓ pass", "W": "◑ partial", "F": "✗ fail", "-": "not run"}

COLS = [
    "Arena 1\nsingle task",
    "Arena 2\nmulti-file\n(11 tests)",
    "Arena 3\nmarathon\n(11 turns)",
    "Arena 4\nheavy ctx,\nbig window",
    "Arena 4\nheavy ctx,\n32K + compaction",
]

# (label, badge, [(state, sub, sub2) x5])
ROWS = [
    ("Ornith-1.0-9B · IQ3_M", "UNDEFEATED", [
        ("P", "2m 51s", ""), ("P", "8m 03s", ""), ("P", "11/11 · 18m 06s", ""),
        ("P", "12m 40s", "used 50K ctx"), ("P", "9m 32s", "0 compactions")]),
    ("Agents-A1-4B · Q4_K_M", "", [
        ("P", "1m 19s", ""), ("P", "3m 18s", ""), ("P", "11/11 · 15m 47s", ""),
        ("P", "41m 41s", "used 67K ctx"), ("F", "overshoots", "the 32K window")]),
    ("Ling-3.0-tiny · Q3_K_M", "NEW", [
        ("P", "1m 22s", "1.0 kJ — best"), ("P", "5m 29s", "passed on retry"),
        ("W", "9/11 · 28m 42s", "at temp 0.3"),
        ("P", "38m 01s", "used 103K ctx"), ("F", "overshoots", "the 32K window")]),
    ("gemma-4-E4B QAT · Q4_K_XL", "", [
        ("P", "1m 01s", ""), ("P", "2m 34s", ""), ("W", "10/11 · 23m 34s", ""),
        ("F", "bloated", ">82K, compacted"), ("P", "16m 22s", "5 compactions")]),
    ("Nanbeige4.2-3B · Q4_K_M", "NEW", [
        ("P", "6m 55s", ""), ("P", "11m 42s", ""), ("F", "1/11", "hit 600s/turn cap"),
        ("F", "3h 08m", "5 turns timed out"), ("P", "23m 41s", "0 comp · 17K peak")]),
    ("gemma-4-E2B QAT · Q4_K_XL", "", [
        ("P", "1m 32s", ""), ("P", "1m 33s", ""), ("F", "3/11 · 14m 51s", ""),
        ("F", "bloated", ">114K, compacted"), ("W", "1 miss", "4 compactions")]),
    ("Qwen3.5-4B base · Q4_K_M", "", [
        ("P", "1m 21s", ""), ("F", "failed 3 tests", ""), ("P", "11/11 · 18m 58s", ""),
        ("P", "11m 18s", "used 49K ctx"), ("W", "anchors lost", "2 compactions")]),
    ("LFM2.5-2.6B · Q4_K_M", "NEW", [
        ("F", "4 configs tried", "edits rejected"), ("-", "", ""), ("-", "", ""),
        ("-", "", ""), ("-", "", "")]),
    ("Bonsai-27B · Q1_0", "", [
        ("P", "8m 14s", ""), ("-", "", ""), ("-", "", ""), ("-", "", "")  , ("-", "", "")]),
]

TILES = [
    ("10.7K", "all the context Ornith-9B needed for the crusher\nwhen capped at 32K — 0 compactions"),
    ("3h 08m → 23m 41s", "the rule: Nanbeige, same task — 49K window FAILS,\n32K window PASSES, 8× faster, anchors kept"),
    ("103K", "the exception: Ling-3.0-tiny is the only model that\nbloated past 100K and still passed the crusher"),
]


def rounded(ax, x, y, w, h, fc, ec="none", lw=0, r=0.012, z=1):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle=f"round,pad=0,rounding_size={r}",
        linewidth=lw, facecolor=fc, edgecolor=ec, mutation_aspect=1, zorder=z))


def draw(fname, W, H, square=False):
    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    fig.patch.set_facecolor(SURFACE)
    ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, 1); ax.set_ylim(0, 1); ax.axis("off")

    ts = 30 if not square else 25
    top = 0.965
    ax.text(0.055, top, "Which local AI agent survives real work",
            fontsize=ts, fontweight="bold", color=INK, va="top")
    ax.text(0.055, top - (0.037 if not square else 0.046), "on a $249 Jetson?",
            fontsize=ts, fontweight="bold", color=INK, va="top")
    sub_y = top - (0.079 if not square else 0.098)
    ax.text(0.055, sub_y,
            "9 models  ·  4 pytest-validated agent arenas  ·  Jetson Orin Nano 8GB  ·  16–18 W under load",
            fontsize=10.5 if not square else 9.5, color=INK2, va="top")

    # ---- matrix geometry ----
    left, right = 0.265, 0.965
    grid_top = sub_y - (0.055 if not square else 0.062)
    n = len(ROWS)
    row_h = (0.047 if not square else 0.039)
    gap = 0.008
    hdr_h = 0.052

    cw = (right - left) / len(COLS)
    for i, c in enumerate(COLS):
        ax.text(left + cw * (i + 0.5), grid_top, c, fontsize=8.6 if not square else 7.8,
                color=INK2, ha="center", va="top", linespacing=1.5)

    y = grid_top - hdr_h
    for label, badge, cells in ROWS:
        y -= row_h
        if badge == "UNDEFEATED":
            rounded(ax, 0.035, y - gap * 0.4, right - 0.035 + 0.005, row_h + gap * 0.8,
                    "#f2f7f2", r=0.008, z=0)
        ax.text(left - 0.022, y + row_h * 0.60, label, fontsize=10 if not square else 8.8,
                color=INK, ha="right", va="center",
                fontweight="bold" if badge == "UNDEFEATED" else "normal")
        if badge:
            bc = "#0a7d0a" if badge == "UNDEFEATED" else BLUE
            ax.text(left - 0.022, y + row_h * 0.22, badge, fontsize=6.6 if not square else 6.0,
                    color=bc, ha="right", va="center", fontweight="bold")

        for i, (state, sub, sub2) in enumerate(cells):
            x = left + cw * i + 0.004
            rounded(ax, x, y, cw - 0.008, row_h - 0.002, FILL[state], r=0.009)
            cx = x + (cw - 0.008) / 2
            if state == "-":
                ax.text(cx, y + row_h * 0.5, GLYPH[state], fontsize=8 if not square else 7.2,
                        color=MUTED, ha="center", va="center", style="italic")
                continue
            gy = row_h * (0.72 if sub2 else 0.66)
            ax.text(cx, y + gy, GLYPH[state], fontsize=10 if not square else 8.8,
                    color=TEXT[state], ha="center", va="center", fontweight="bold")
            if sub:
                ax.text(cx, y + row_h * (0.44 if sub2 else 0.28), sub,
                        fontsize=8.4 if not square else 7.4, color=INK2, ha="center", va="center")
            if sub2:
                ax.text(cx, y + row_h * 0.18, sub2, fontsize=7.2 if not square else 6.4,
                        color=MUTED, ha="center", va="center")

    # ---- finding + tiles ----
    fy = y - (0.062 if not square else 0.052)
    ax.text(0.055, fy, "The finding that matters:  context DISCIPLINE beats context CAPACITY — with one exception",
            fontsize=13 if not square else 10.5, fontweight="bold", color=INK, va="top")

    ty = fy - (0.045 if not square else 0.040)
    th = (0.175 if not square else 0.150)
    tw = (0.91 - 0.03 * 2) / 3
    for i, (big, small) in enumerate(TILES):
        x = 0.055 + i * (tw + 0.03)
        rounded(ax, x, ty - th, tw, th, "#f2f2f0", r=0.012)
        ax.add_patch(plt.Rectangle((x + 0.022, ty - th * 0.20), 0.038, 0.005,
                                   color=BLUE, zorder=3))
        fs = 26 if not square else 21
        if len(big) > 8:
            fs = 17 if not square else 14
        ax.text(x + 0.022, ty - th * 0.44, big, fontsize=fs, fontweight="bold",
                color=INK, va="center")
        ax.text(x + 0.022, ty - th * 0.78, small, fontsize=8.2 if not square else 7.2,
                color=INK2, va="center", linespacing=1.6)

    ax.text(0.055, 0.028,
            "First-party measurements  ·  August 2026  ·  github.com/jimenezcarrero/jetson-llm-benchmarks",
            fontsize=8.4 if not square else 7.6, color=MUTED, va="center")

    fig.savefig(fname, facecolor=SURFACE)
    plt.close(fig)
    print("wrote", fname)


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "/home/JetsonOrin/Repositories/jetson-llm-benchmarks"
    draw(f"{out}/results-chart.png", 1080, 1350, square=False)
    draw(f"{out}/results-chart-square.png", 1080, 1080, square=True)
