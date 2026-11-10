#!/usr/bin/env python3
"""A tongue-in-cheek trailer for CraftGraph, in the manner of an overblown
film preview: title cards, a deep voice, drums.

    python3 tools/render/make_trailer.py <frames folder from scenes.lua> <real-graph.svg> <output.mp4>

Everything is made here: the pictures come from the addon's own interface
(scenes.lua and real.lua), the voice from espeak-ng, the drums and drones
from ffmpeg's tone generators. Needs ffmpeg, rsvg-convert and espeak-ng.
"""
import html
import subprocess
import sys
import tempfile
from pathlib import Path

W, H, FPS = 1280, 720, 24
GOLD, WHITE, GREY, RED, GREEN = "#ffd100", "#f2ead8", "#9d9484", "#ff5040", "#40ff40"


def run(*cmd):
    done = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit("failed: %s\n%s" % (" ".join(str(c) for c in cmd[:6]), done.stderr[-1500:]))
    return done.stdout


def length(path):
    return float(run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path))


def card(path, lines, background="#000000", band=None):
    """A title card. lines: (text, size, colour[, spacing])."""
    total = sum(size * 1.45 for _, size, *_ in lines)
    y = (H - total) / 2
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % (W, H),
             '<rect width="100%%" height="100%%" fill="%s"/>' % background]
    if band:
        parts.append('<rect x="60" y="60" width="%d" height="%d" fill="none" stroke="%s" stroke-width="3"/>'
                     % (W - 120, H - 120, band))
    for text, size, colour, *rest in lines:
        spacing = rest[0] if rest else 6
        y += size * 1.1
        parts.append('<text x="%d" y="%.0f" text-anchor="middle" font-family="DejaVu Serif, serif" font-weight="bold" '
                     'font-size="%d" letter-spacing="%d" fill="%s">%s</text>'
                     % (W / 2, y, size, spacing, colour, html.escape(text)))
        y += size * 0.35
    parts.append("</svg>")
    svg = Path(str(path) + ".svg")
    svg.write_text("\n".join(parts))
    run("rsvg-convert", svg, "-o", path)


def still_clip(out, image, seconds, crop=None, zoom=(1.0, 1.08), caption=None, colour=WHITE):
    """A picture with a slow push in, wide-screen bars and a caption."""
    frames = int(seconds * FPS)
    chain = []
    if crop:
        x, y, w, h = crop                      # given as left, top, width, height
        chain.append("crop=%d:%d:%d:%d" % (w, h, x, y))
    chain.append("scale=%d:%d:force_original_aspect_ratio=decrease:flags=lanczos" % (W * 2, H * 2))
    chain.append("pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black" % (W * 2, H * 2))
    z0, z1 = zoom
    chain.append("zoompan=z='%f+(%f)*on/%d':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=%d:s=%dx%d:fps=%d"
                 % (z0, z1 - z0, frames, frames, W, H, FPS))
    chain.append("drawbox=0:0:%d:54:black:fill" % W)
    chain.append("drawbox=0:%d:%d:54:black:fill" % (H - 54, W))
    inputs = ["-loop", "1", "-i", image]
    graph = ",".join(chain)
    if caption:
        cap = Path(str(out) + ".cap.png")
        caption_png(cap, caption, colour)
        inputs += ["-loop", "1", "-i", cap]
        graph = "[0:v]%s[v];[v][1:v]overlay=0:0" % graph
    run("ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, "-t", "%.3f" % seconds,
        "-r", FPS, "-pix_fmt", "yuv420p", "-c:v", "libx264", "-crf", "20", out)


def caption_png(path, text, colour):
    lines = text.split("\n")
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % (W, H)]
    y = H - 54 - 26 - (len(lines) - 1) * 44
    for line in lines:
        for dx, dy, fill in ((3, 3, "#000000"), (0, 0, colour)):
            parts.append('<text x="%d" y="%d" text-anchor="middle" font-family="DejaVu Serif, serif" font-weight="bold" '
                         'font-size="36" letter-spacing="3" fill="%s" stroke="#000" stroke-width="%d" paint-order="stroke">%s</text>'
                         % (W / 2 + dx, y + dy, fill, 6 if fill == "#000000" else 0, html.escape(line)))
        y += 44
    parts.append("</svg>")
    svg = Path(str(path) + ".svg")
    svg.write_text("\n".join(parts))
    run("rsvg-convert", svg, "-o", path)


def sequence_clip(out, pattern, rate, seconds, caption=None, colour=WHITE):
    """Frames played fast, like a montage."""
    chain = ("scale=%d:%d:force_original_aspect_ratio=decrease:flags=lanczos,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black,"
             "drawbox=0:0:%d:54:black:fill,drawbox=0:%d:%d:54:black:fill" % (W, H, W, H, W, H - 54, W))
    inputs = ["-framerate", rate, "-i", pattern]
    graph = chain
    if caption:
        cap = Path(str(out) + ".cap.png")
        caption_png(cap, caption, colour)
        inputs += ["-loop", "1", "-i", cap]
        graph = "[0:v]%s[v];[v][1:v]overlay=0:0" % chain
    run("ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, "-t", "%.3f" % seconds,
        "-r", FPS, "-pix_fmt", "yuv420p", "-c:v", "libx264", "-crf", "20", out)


def voice(path, text, speed=118, pitch=18, deep=0.80):
    """The voice of every film preview, as well as a speech synthesiser can."""
    raw = Path(str(path) + ".raw.wav")
    run("espeak-ng", "-v", "en-gb-x-rp", "-s", speed, "-p", pitch, "-g", 2, "-w", raw, text)
    run("ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-af",
        "asetrate=22050*%f,aresample=44100,atempo=%f,bass=g=7:f=110,aecho=0.8:0.6:70|140:0.28|0.16,volume=2.2"
        % (deep, min(1.25, 1 / deep * 0.92)), "-ac", "2", path)


def main():
    frames, real_svg, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    work = Path(tempfile.mkdtemp(prefix="cg-trailer-"))
    stills = {}

    def still(name, source=None):
        if name not in stills:
            png = work / (name + ".png")
            run("rsvg-convert", "-w", 1920, source or (frames / "stills" / (name + ".svg")), "-o", png)
            stills[name] = png
        return stills[name]

    real = still("real", real_svg)
    for n in range(1, 30):                     # the rush, as frames
        src = frames / "wave" / ("%04d.svg" % n)
        if src.exists() and not (work / ("wave%04d.png" % n)).exists():
            run("rsvg-convert", "-w", 1280, src, "-o", work / ("wave%04d.png" % n))
    for n in range(1, 62):
        src = frames / "flow" / ("%04d.svg" % n)
        if src.exists():
            run("rsvg-convert", "-w", 1280, src, "-o", work / ("flow%04d.png" % n))

    # The film: (kind, what, least seconds, spoken line, drum).
    shots = [
        ("card", dict(lines=[("THE FOLLOWING PREVIEW HAS BEEN APPROVED FOR", 26, "#ffffff", 3),
                             ("ALL AUCTION HOUSES", 64, "#ffffff", 8),
                             ("by nobody in particular", 22, "#d8ffd8", 2)], background="#1a7a2e", band="#ffffff"),
         3.2, None, False),
        ("card", dict(lines=[("IN A WORLD", 84, WHITE, 14)]), 2.4, "In a world.", True),
        ("still", dict(image="overview", crop=(0, 60, 1920, 1080), caption="where Copper Ore costs 18 copper"),
         3.0, "Where copper ore. Costs eighteen copper.", False),
        ("card", dict(lines=[("ONE PLAYER", 84, WHITE, 14)]), 2.2, "One player.", True),
        ("card", dict(lines=[("WAS TIRED OF", 44, GREY, 8), ("DOING THE SUMS", 84, GOLD, 10)]),
         2.8, "Was tired. Of doing the sums.", True),
        ("still", dict(image="opportunities", crop=(100, 170, 1220, 686), zoom=(1.0, 1.12),
                       caption="He had a spreadsheet.\nIt was not enough."),
         3.2, "He had a spreadsheet. It was not enough.", False),
        ("card", dict(lines=[("THIS WINTER", 96, WHITE, 16)]), 2.4, "This winter.", True),
        ("seq", dict(pattern="flow%04d.png", rate=20, caption="IT KNOWS WHAT THINGS ARE MADE OF", colour=GOLD),
         2.8, "It knows what things are made of.", True),
        ("seq", dict(pattern="wave%04d.png", rate=9, caption="IT RIDES THE WAVE", colour=GOLD),
         3.2, "It rides the wave.", True),
        ("still", dict(image="plan", zoom=(1.0, 1.06), caption="IT PRESSES THE BUTTONS", colour=GOLD),
         2.6, "It presses the buttons.", True),
        ("still", dict(image="plan", crop=(1100, 380, 800, 450), zoom=(1.0, 1.0),
                       caption="(when you are standing next to them)", colour=GREY),
         2.6, "When you are standing next to them.", False),
        ("card", dict(lines=[("IT SEES THE FUTURE", 80, GOLD, 10)]), 2.2, "It sees. The future.", True),
        ("still", dict(image="real", crop=(1290, 640, 560, 315), zoom=(1.0, 1.0),
                       caption="\"Too early to forecast\"", colour=WHITE),
         2.8, "Too early to forecast.", False),
        ("card", dict(lines=[("...MOSTLY", 72, GREY, 12)]), 1.8, "Mostly.", False),
        ("card", dict(lines=[("BASED ON A", 40, GREY, 8), ("TRUE MARGIN", 92, WHITE, 12)]),
         2.4, "Based on a true margin.", True),
        ("still", dict(image="real", crop=(1300, 250, 560, 315), zoom=(1.0, 1.05),
                       caption="+6 silver, 11 copper\ngive or take 18 silver", colour=GREEN),
         3.4, "Six silver. Eleven copper. Give or take. Eighteen silver.", False),
        ("card", dict(lines=[("“Could lose 30 silver.”", 60, RED, 2), ("", 20, GREY),
                             ("— the addon, about its own advice", 30, GREY, 2)]),
         2.8, "Critics are saying. Could lose thirty silver.", True),
        ("card", dict(lines=[("“I don’t know.”", 68, WHITE, 2), ("", 20, GREY),
                             ("— the addon, when it doesn’t", 30, GREY, 2)]),
         2.6, "And. I don't know.", True),
        ("card", dict(lines=[("CRAFTGRAPH", 132, GOLD, 18), ("", 16, GREY), ("/cg", 54, WHITE, 6)]),
         3.6, "Craft. Graph.", True),
        ("card", dict(lines=[("Profits shown after the auction house's cut. Deposits not included.", 19, GREY, 1),
                             ("Past prices are no promise of future prices, least of all on a two-day-old realm.", 19, GREY, 1),
                             ("Experimental. Python optional. Spreadsheet no longer required.", 19, GREY, 1),
                             ("Not affiliated with or endorsed by Blizzard.", 19, GREY, 1),
                             ("No sellers were undercut by more than one copper.", 19, GREY, 1),
                             ("", 24, GREY), ("RATED G FOR GOLD", 44, GOLD, 10),
                             ("Coming soon to an auction house near you", 28, WHITE, 3)]),
         4.5, "Profits shown after the auction house's cut. Deposits not included. Python optional. "
              "No sellers were undercut by more than one copper. Rated G. For gold.", False),
    ]

    clips, events, at = [], [], 0.0
    for i, (kind, what, least, line, drum) in enumerate(shots):
        clip = work / ("clip%02d.mp4" % i)
        seconds = least
        if line:
            spoken = work / ("voice%02d.wav" % i)
            fast = i == len(shots) - 1
            voice(spoken, line, speed=230 if fast else 138, pitch=30 if fast else 16, deep=0.92 if fast else 0.78)
            seconds = max(least, length(spoken) + 0.35)
            events.append((at + 0.25, spoken, 1.0))
        if drum:
            events.append((at, "boom", 1.0))
        if kind == "card":
            png = work / ("card%02d.png" % i)
            card(png, **what)
            still_clip(clip, png, seconds, zoom=(1.0, 1.04))
        elif kind == "still":
            what = dict(what)
            image = what.pop("image")
            image = stills.get(image) or still(image)
            still_clip(clip, image, seconds, **what)
        else:
            what = dict(what)
            sequence_clip(clip, work / what.pop("pattern"), what.pop("rate"), seconds, **what)
        clips.append(clip)
        at += seconds
    total = at

    # Picture.
    listing = work / "clips.txt"
    listing.write_text("".join("file '%s'\n" % c for c in clips))
    silent = work / "silent.mp4"
    run("ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listing, "-c", "copy", silent)

    # Sound: a drum for the cards, a low drone under everything that drops
    # out for the punchlines, and the voice.
    boom = work / "boom.wav"
    run("ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=46:duration=2.2",
        "-f", "lavfi", "-i", "anoisesrc=color=brown:duration=2.2:amplitude=0.9",
        "-filter_complex",
        "[0:a]volume='3.2*exp(-2.2*t)':eval=frame[s];[1:a]lowpass=f=160,volume='2.6*exp(-7*t)':eval=frame[n];"
        "[s][n]amix=inputs=2:normalize=0,aecho=0.8:0.5:90:0.35,alimiter=limit=0.95",
        "-ac", "2", "-ar", "44100", boom)
    drone = work / "drone.wav"
    run("ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", "sine=frequency=55:duration=%.2f" % total,
        "-f", "lavfi", "-i", "sine=frequency=82.4:duration=%.2f" % total,
        "-f", "lavfi", "-i", "sine=frequency=110.6:duration=%.2f" % total,
        "-filter_complex",
        "[0:a][1:a][2:a]amix=inputs=3:normalize=0,tremolo=f=0.35:d=0.5,volume=0.16,"
        "afade=t=in:d=3,afade=t=out:st=%.2f:d=2.5" % (total - 3),
        "-ac", "2", "-ar", "44100", drone)
    inputs, graph, names = ["-i", drone], [], ["[0:a]"]
    for n, (when, what, gain) in enumerate(events, start=1):
        inputs += ["-i", boom if what == "boom" else what]
        graph.append("[%d:a]adelay=%d:all=1,volume=%.2f[e%d]" % (n, int(when * 1000), gain, n))
        names.append("[e%d]" % n)
    graph.append("%samix=inputs=%d:normalize=0:duration=first,alimiter=limit=0.95[a]" % ("".join(names), len(names)))
    sound = work / "sound.wav"
    run("ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(graph), "-map", "[a]", sound)
    out.parent.mkdir(parents=True, exist_ok=True)
    run("ffmpeg", "-y", "-loglevel", "error", "-i", silent, "-i", sound, "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
        "-shortest", "-movflags", "+faststart", out)
    print("%s  (%.0f seconds; working files in %s)" % (out, total, work))


if __name__ == "__main__":
    main()
