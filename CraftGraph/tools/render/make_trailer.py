#!/usr/bin/env python3
"""A short parody trailer for CraftGraph: an overblown film preview in under
half a minute.

    python3 tools/render/make_trailer.py <frames folder from scenes.lua> <real-graph.svg> <output.mp4>

Everything is made here. The pictures are the addon's own interface (from
scenes.lua and real.lua), animated frame by frame with Pillow. The music is
composed and synthesised with numpy: drums, a string ostinato, braams, a
riser. The only voice is the addon's own, from espeak-ng, used once.
Needs ffmpeg, rsvg-convert, espeak-ng, and Python with numpy, scipy, Pillow.
"""
import math
import os
import random
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
from scipy import signal

W, H, FPS = 1280, 720, 30
BAR = 62                                   # wide-screen bars
BEAT = 0.5                                 # 120 beats a minute; every cut sits on a beat
HEAVY = "/usr/share/fonts/TTF/FiraSansCompressed-Heavy.ttf"
ITALIC = "/usr/share/fonts/TTF/FiraSansCondensed-LightItalic.ttf"
MEDIUM = "/usr/share/fonts/TTF/FiraSansCondensed-Medium.ttf"
WHITE, GREY, RED, GREEN = (245, 238, 222), (150, 142, 128), (255, 70, 55), (80, 255, 90)
rng = random.Random(7)


def run(*cmd, **kw):
    done = subprocess.run([str(c) for c in cmd], capture_output=True, **kw)
    if done.returncode != 0:
        sys.exit("failed: %s\n%s" % (" ".join(str(c) for c in cmd[:5]), done.stderr.decode()[-1200:]))
    return done.stdout


# ----------------------------------------------------------------------------
# Pictures
# ----------------------------------------------------------------------------
def ease(x):
    x = max(0.0, min(1.0, x))
    return 1 - (1 - x) ** 3


def text_layer(text, size, colour=WHITE, tracking=0.06, font=HEAVY, glow=True, outline=0, plate=False, fit=0.88):
    """A line of text as its own picture, with a soft glow behind it.
    colour "gold" fills it with a gold gradient. It is made smaller until it
    fits `fit` of the screen's width. plate: a dark band behind it, for
    text that sits on a busy picture."""
    while True:
        f = ImageFont.truetype(font, int(size))
        gap = size * tracking
        widths = [f.getlength(ch) for ch in text]
        width = int(sum(widths) + gap * (len(text) - 1))
        if width <= W * fit or size < 20:
            break
        size *= 0.96
    size = int(size)
    pad = int(size * 0.6)
    mask = Image.new("L", (width + 2 * pad, int(size * 1.35) + 2 * pad), 0)
    draw = ImageDraw.Draw(mask)
    x = pad
    for ch, w in zip(text, widths):
        draw.text((x, pad), ch, font=f, fill=255)
        x += w + gap
    if colour == "gold":
        ramp = Image.new("RGB", (1, mask.height))
        for y in range(mask.height):
            k = (y - pad) / (size * 1.2)
            k = max(0.0, min(1.0, k))
            top, mid, low = (255, 246, 190), (255, 209, 0), (178, 108, 0)
            a, b, t = (top, mid, k * 2) if k < 0.5 else (mid, low, k * 2 - 1)
            ramp.putpixel((0, y), tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3)))
        fill = ramp.resize(mask.size)
        tint = (255, 190, 40)
    else:
        fill = Image.new("RGB", mask.size, colour)
        tint = colour
    layer = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    if plate:
        band = Image.new("L", mask.size, 0)
        ImageDraw.Draw(band).rounded_rectangle((pad * 0.35, pad * 0.75, mask.width - pad * 0.35, mask.height - pad * 0.7),
                                                 radius=size * 0.3, fill=190)
        layer.paste(Image.new("RGBA", mask.size, (0, 0, 0, 255)), (0, 0), band.filter(ImageFilter.GaussianBlur(size * 0.18)))
    if outline:
        edge = mask.filter(ImageFilter.MaxFilter(outline * 2 + 1)).filter(ImageFilter.GaussianBlur(1.2))
        layer.paste(Image.new("RGBA", mask.size, (0, 0, 0, 255)), (0, 0), edge)
    if glow:
        halo = mask.filter(ImageFilter.GaussianBlur(size * 0.16)).point(lambda v: int(v * 0.55))
        layer = Image.alpha_composite(layer, Image.merge("RGBA", (*Image.new("RGB", mask.size, tint).split(), halo)))
    layer.paste(fill, (0, 0), mask)
    layer.info["mask"] = mask
    return layer


def place(frame, layer, cx, cy, scale=1.0, alpha=1.0):
    if scale != 1.0:
        layer = layer.resize((max(1, int(layer.width * scale)), max(1, int(layer.height * scale))), Image.BILINEAR)
    if alpha < 1.0:
        layer = layer.copy()
        layer.putalpha(layer.getchannel("A").point(lambda v: int(v * alpha)))
    frame.alpha_composite(layer, (int(cx - layer.width / 2), int(cy - layer.height / 2)))


def camera(image, start, end, k):
    """A view of a picture that moves from one rectangle to another."""
    x, y, w, h = (start[i] + (end[i] - start[i]) * k for i in range(4))
    return image.resize((W, H), Image.BILINEAR, box=(x, y, x + w, y + h)).convert("RGBA")


VIGNETTE = None


def finish(frame, flash=0.0, shake=(0, 0), dim=1.0):
    """Shake, vignette, bars, flash."""
    global VIGNETTE
    if VIGNETTE is None:
        yy, xx = np.mgrid[0:H, 0:W]
        d = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
        a = np.clip((d - 0.55) / 0.75, 0, 1) ** 1.6 * 200
        VIGNETTE = Image.merge("RGBA", (*Image.new("RGB", (W, H), 0).split(), Image.fromarray(a.astype("uint8"))))
    if shake != (0, 0):
        frame = ImageChops.offset(frame, int(shake[0]), int(shake[1]))
    frame = Image.alpha_composite(frame, VIGNETTE)
    draw = ImageDraw.Draw(frame)
    draw.rectangle((0, 0, W, BAR), fill=(0, 0, 0, 255))
    draw.rectangle((0, H - BAR, W, H), fill=(0, 0, 0, 255))
    out = frame.convert("RGB")
    if dim < 1.0:
        out = Image.blend(Image.new("RGB", (W, H), 0), out, dim)
    if flash > 0.01:
        out = Image.blend(out, Image.new("RGB", (W, H), (255, 244, 214)), min(0.85, flash))
    return out


class Slam:
    """Text that lands hard: starts big, snaps to size, shakes the frame."""

    def __init__(self, layer, cy, at=0.0, power=1.0, cx=W / 2, fade=False, jitter=0.0):
        self.layer, self.cy, self.at, self.power, self.cx, self.fade, self.jitter = layer, cy, at, power, cx, fade, jitter

    def draw(self, frame, t):
        tau = t - self.at
        if tau < 0:
            return 0.0, 0.0
        if self.fade:                                  # the quiet kind: it just appears
            place(frame, self.layer, self.cx, self.cy, 1.0 + 0.012 * tau, ease(tau / 0.5))
            return 0.0, 0.0
        scale = 1.0 + 1.7 * self.power * math.exp(-tau * 22) + 0.022 * tau
        jx = rng.uniform(-1, 1) * self.jitter * 6
        place(frame, self.layer, self.cx + jx, self.cy, scale, min(1.0, tau * FPS / 2 + 0.35))
        return 0.75 * self.power * math.exp(-tau * 16), 15 * self.power * math.exp(-tau * 9)


# ----------------------------------------------------------------------------
# Sound
# ----------------------------------------------------------------------------
SR = 44100


def env(n, attack, decay):
    t = np.arange(n) / SR
    return np.minimum(1, t / max(attack, 1e-4)) * np.exp(-t / decay)


def lowpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, "low", fs=SR, output="sos"), x)


def highpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, "high", fs=SR, output="sos"), x)


def saws(freq, n, voices=5, spread=0.012):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for v in range(voices):
        f = freq * (1 + spread * (v - (voices - 1) / 2) / voices * 2)
        out += signal.sawtooth(2 * np.pi * f * t + v * 1.7)
    return out / voices


def note(semis_from_d2):
    return 73.42 * 2 ** (semis_from_d2 / 12)


def boom(power=1.0):
    n = int(SR * 2.6)
    t = np.arange(n) / SR
    sweep = 34 + 70 * np.exp(-t * 16)
    body = np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t / 0.75)
    crack = lowpass(np.random.default_rng(1).standard_normal(n), 900) * np.exp(-t / 0.05) * 0.9
    rumble = lowpass(np.random.default_rng(2).standard_normal(n), 120, 3) * np.exp(-t / 0.9) * 1.6
    return np.tanh((body * 1.7 + crack + rumble) * 1.5) * 0.95 * power


def braam(semis, seconds, bright=900):
    n = int(SR * seconds)
    x = saws(note(semis), n, 7, 0.02) + 0.7 * saws(note(semis + 12), n, 5, 0.015) + 0.5 * saws(note(semis - 12), n, 3)
    x = lowpass(x, bright, 2)
    t = np.arange(n) / SR
    shape = np.minimum(1, t / 0.04) * np.exp(-t / (seconds * 0.55)) * (1 + 0.25 * np.sin(2 * np.pi * 5.5 * t) * np.minimum(1, t))
    return np.tanh(x * shape * 3.2) * 0.62


def taiko(power=1.0, low=True):
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    f = (62 if low else 96) + 60 * np.exp(-t * 30)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / (0.16 if low else 0.09))
    skin = lowpass(np.random.default_rng(3).standard_normal(n), 2400) * np.exp(-t / 0.018) * 0.5
    return np.tanh((body + skin) * 1.6) * 0.6 * power


def stab(semis, seconds=0.2, power=1.0, bright=2600):
    """A short string note: the ostinato every trailer has."""
    n = int(SR * seconds)
    x = lowpass(saws(note(semis), n, 5, 0.014) + 0.5 * saws(note(semis + 12), n, 3, 0.01), bright)
    return x * env(n, 0.006, seconds * 0.38) * 0.42 * power


def pluck(semis, power=1.0):
    n = int(SR * 0.45)
    t = np.arange(n) / SR
    f = note(semis)
    x = np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * 2 * f * t) + 0.2 * np.sin(2 * np.pi * 3 * f * t)
    return x * np.exp(-t / 0.11) * 0.5 * power


def bell(freq, seconds=1.6, power=1.0):
    n = int(SR * seconds)
    t = np.arange(n) / SR
    x = sum(a * np.sin(2 * np.pi * freq * r * t) * np.exp(-t / (seconds * d))
            for r, a, d in ((1, 1, 0.35), (2.76, 0.45, 0.2), (5.4, 0.25, 0.1), (8.9, 0.12, 0.06)))
    return x * 0.22 * power


def riser(seconds):
    n = int(SR * seconds)
    t = np.arange(n) / SR
    k = t / seconds
    noise = np.random.default_rng(4).standard_normal(n)
    sweep = np.zeros(n)
    step = 2048                                        # a filter that opens as it goes
    for i in range(0, n, step):
        hz = 200 + 7000 * (i / n) ** 2
        sweep[i:i + step] = signal.sosfilt(signal.butter(2, [hz * 0.7, min(hz * 1.4, 20000)], "band", fs=SR, output="sos"),
                                           noise[max(0, i - step):i + step])[-len(sweep[i:i + step]):]
    tone = np.sin(2 * np.pi * np.cumsum(110 * 2 ** (k * 3.2)) / SR) * 0.35
    return (sweep * 0.5 + tone) * k ** 2.2 * 0.7


def heartbeat():
    n = int(SR * 0.5)
    t = np.arange(n) / SR
    one = np.sin(2 * np.pi * 52 * t) * np.exp(-t / 0.07)
    two = np.zeros(n)
    d = int(SR * 0.17)
    two[d:] = one[:n - d] * 0.7
    return (one + two) * 0.55


TTS_HOME = Path(os.environ.get("CRAFTGRAPH_TTS", Path.home() / ".local/share/craftgraph-tts"))
# Who speaks: the narrator of every film preview, and the addon itself.
VOICES = {
    "narrator": dict(kokoro="am_onyx", speed=1.22, deep=0.91, espeak=("en-gb-x-rp", 135, 16)),
    "addon": dict(kokoro="bf_emma", speed=1.1, deep=1.0, espeak=("en-gb-x-rp", 150, 42)),
    "small": dict(kokoro="bf_emma", speed=1.7, deep=1.0, espeak=("en-gb-x-rp", 215, 42)),
}


def speak(path, text, who):
    """One spoken line as samples. Uses Kokoro (a small neural voice, in its
    own environment under ~/.local/share/craftgraph-tts) when it is there,
    and espeak-ng when it is not."""
    v = VOICES[who]
    raw = Path(str(path) + ".raw.wav")
    python, script = TTS_HOME / ".venv/bin/python", TTS_HOME / "say.py"
    if python.exists() and script.exists():
        run(python, script, v["kokoro"], v["speed"], raw, text)
    else:
        voice, speed, pitch = v["espeak"]
        run("espeak-ng", "-v", voice, "-s", speed, "-p", pitch, "-w", raw, text)
    if who == "narrator":
        # Lower and bigger: played back a little slow, more chest, a hall.
        chain = ("aresample=48000,asetrate=48000*%f,aresample=%d,bass=g=6:f=120,treble=g=2:f=5000,"
                 "acompressor=threshold=-20dB:ratio=3:makeup=4,aecho=0.8:0.5:55|110:0.22|0.12" % (v["deep"], SR))
    else:
        # The addon: a small, polite speaker.
        chain = "highpass=f=220,lowpass=f=5200,acompressor=threshold=-18dB:ratio=3:makeup=3,aresample=%d" % SR
    run("ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-af", chain, "-ac", "1", "-c:a", "pcm_s16le", path)
    with wave.open(str(path)) as f:
        x = np.frombuffer(f.readframes(f.getnframes()), dtype="<i2").astype(float) / 32768
    # Trim the quiet at both ends, so that timing is by the words.
    loud = np.nonzero(np.abs(x) > 0.02)[0]
    if len(loud):
        x = x[max(0, loud[0] - 400):loud[-1] + 2400]
    return x / max(1e-6, np.abs(x).max())


def compose(total, marks, spoken):
    """The whole track, built on the same clock as the pictures."""
    n = int(SR * (total + 1.5))
    dry, wet = np.zeros(n), np.zeros(n)                # wet goes through the hall as well
    front = np.zeros(n)                                # the voice and the small jokes: added at a fixed level

    def add(buf, sound, at, gain=1.0):
        i = int(at * SR)
        if i >= n or i < 0:
            return
        j = min(n, i + len(sound))
        buf[i:j] += sound[:j - i] * gain

    m = marks
    # Act one: a heartbeat in the dark, and a hit for each card.
    for k in range(int((m["winter"] - 0) / 1.0)):
        if k * 1.0 < m["notenough"]:
            add(dry, heartbeat(), k * 1.0, 0.9)
    for name, power in (("world", 1.0), ("auctions", 0.55), ("player", 0.8), ("sheet", 0.9)):
        add(wet, boom(power), m[name])
        add(wet, braam(0, 1.6), m[name], 0.55 * power)
    # "It was not enough": everything stops, one sad little pluck.
    add(front, pluck(24, 0.9), m["notenough"] + 0.25)
    add(front, pluck(19, 0.9), m["notenough"] + 0.6)

    # Act two: drums and the ostinato, building to the cut.
    ostinato = [12, 12, 15, 12, 19, 12, 15, 14]        # D D F D A D F E
    start, stop = m["winter"], m["silence"]
    add(wet, boom(1.0), start)
    add(wet, braam(0, 2.2), start, 0.8)
    eighths = int((stop - start) / (BEAT / 2))
    for k in range(eighths):
        at = start + k * BEAT / 2
        build = 0.45 + 0.55 * k / eighths
        lift = 12 if at >= m["rapid"] else 0
        add(wet, stab(ostinato[k % 8] + lift, 0.2, build), at, 2.6)
        add(wet, stab(ostinato[k % 8] + lift - 12, 0.2, build * 0.7), at, 2.6)
        accent = k % 4 == 0
        add(dry, taiko(1.0 if accent else 0.5, low=accent or k % 2 == 0), at, build * 2.2)
        if at >= m["rapid"]:                           # sixteenths under the fast cuts
            add(dry, taiko(0.6, low=False), at + BEAT / 4, build * 2.2)
    for name in ("recipe", "wave", "buttons"):
        add(wet, boom(0.8), m[name])
        add(wet, braam({"recipe": 0, "wave": 3, "buttons": 5}[name], 1.5), m[name], 0.6)
    add(dry, riser(m["silence"] - m["rapid"]), m["rapid"], 4.5)
    add(wet, boom(0.8), m["rapid"])
    for k in range(8):                                 # a note climbing under the fast cuts
        add(wet, braam(k, 0.3, 1500), m["rapid"] + k * 0.125, 0.75)
    add(wet, boom(1.0), m["future"])
    add(wet, braam(7, m["silence"] - m["future"], 1400), m["future"], 0.95)
    # The cut: silence, hard.
    cut = int(m["silence"] * SR)
    for buf in (dry, wet):
        buf[cut:] = 0
        buf[cut - 300:cut] *= np.linspace(1, 0, 300)

    # "...mostly": two notes, falling.
    add(front, pluck(17, 1.0), m["mostly"] + 0.05)
    add(front, pluck(12, 1.0), m["mostly"] + 0.4)

    # The finale: everything, an octave up, a hit on every cut.
    start, stop = m["margin"], m["title"]
    eighths = int((stop - start) / (BEAT / 2))
    for k in range(eighths):
        at = start + k * BEAT / 2
        add(wet, stab(ostinato[k % 8] + 12, 0.2, 1.0), at, 2.8)
        add(wet, stab(ostinato[k % 8], 0.2, 0.8), at, 2.8)
        add(dry, taiko(1.0 if k % 2 == 0 else 0.6, low=k % 2 == 0), at, 2.4)
        add(dry, taiko(0.5, low=False), at + BEAT / 4, 2.4)
    for name, semis in (("margin", 0), ("profit", 3), ("lose", 5)):
        add(wet, boom(0.9), m[name])
        add(wet, braam(semis, 1.3), m[name], 0.7)
    add(dry, riser(0.9), m["title"] - 0.9, 1.8)
    # The title: the biggest hit, a major chord that rings, bells on top.
    add(wet, boom(1.25), m["title"])
    for semis, gain in ((0, 1.0), (7, 0.6), (16, 0.5)):          # D, A, F sharp
        add(wet, braam(semis, 3.4, 1700), m["title"], gain * 0.8)
    for i, f in enumerate((587.3, 740.0, 880.0, 1174.7, 1480.0)):
        add(wet, bell(f, 2.2), m["title"] + 0.12 + i * 0.11)
    # The stinger: a till, and the small print at speed.
    add(wet, bell(1318.5, 1.2, 1.4), m["rated"])
    add(wet, bell(1975.5, 1.2, 1.0), m["rated"] + 0.07)
    # Everything that is said, where its shot begins.
    voice = np.zeros(n)
    for name, samples, offset, gain in spoken:
        add(voice, samples, m[name] + offset, gain)

    # A hall: the wet part convolved with a decaying burst of noise.
    tail = np.random.default_rng(9).standard_normal(int(SR * 1.5)) * np.exp(-np.arange(int(SR * 1.5)) / (SR * 0.42))
    tail = lowpass(tail, 5200) * 0.02
    hall = signal.fftconvolve(wet, tail)[:n]
    mono = dry + wet + hall * 0.9
    side = signal.fftconvolve(wet, np.roll(tail, 331))[:n] * 0.5        # a little width
    # The cut is a cut: no hall ringing on into the quiet.
    gate = np.ones(n)
    a, b = int(m["silence"] * SR), int(m["mostly"] * SR)
    gate[a:b] = 0
    gate[a - 1300:a] = np.linspace(1, 0, 1300)
    mono, side = mono * gate, side * gate
    left, right = mono + side, mono - side
    # Level the music by its loud passages, not its single loudest sample,
    # press it gently against the ceiling, then put the voice in front.
    loud = max(np.percentile(np.abs(mono), 99.7), 1e-9)
    stereo = np.tanh(np.stack([left, right], axis=1) / loud * 0.9) * 0.9
    # The music steps back while someone speaks.
    level = np.abs(voice)
    hold = int(SR * 0.12)
    level = np.maximum.reduceat(np.pad(level, (0, hold)), np.arange(0, len(level), hold)).repeat(hold)[:n]
    level = lowpass(np.minimum(1, level * 4), 6, 1)
    stereo *= (1 - 0.55 * np.clip(level, 0, 1))[:, None]
    stereo += (front + voice * 0.85)[:, None]
    stereo = np.clip(stereo, -0.98, 0.98)
    end = int(total * SR)
    stereo = stereo[:end + int(SR * 0.8)]
    stereo[-int(SR * 0.6):] *= np.linspace(1, 0, int(SR * 0.6))[:, None]
    return stereo


# ----------------------------------------------------------------------------
# The film
# ----------------------------------------------------------------------------
def main():
    frames_dir, real_svg, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    work = Path(tempfile.mkdtemp(prefix="cg-trailer-"))

    def picture(name, source=None, width=1920):
        png = work / (name + ".png")
        if not png.exists():
            run("rsvg-convert", "-w", width, source or (frames_dir / "stills" / (name + ".svg")), "-o", png)
        return Image.open(png).convert("RGB")

    real = picture("real", real_svg)
    lists = picture("opportunities")
    plan = picture("plan")
    flow = [picture("flow%02d" % i, frames_dir / "flow" / ("%04d.svg" % i), 1280) for i in range(1, 31, 2)]
    rush = [picture("wave%02d" % i, frames_dir / "wave" / ("%04d.svg" % i), 1280) for i in range(1, 30)]
    quick = [picture(n) for n in ("overview", "trends", "week", "rank", "when", "supply-demand", "this-item", "wave-ride")]

    def big(text, size=150, colour=WHITE, **kw):
        return text_layer(text, size, colour, **kw)

    def over(text, size=74, colour="gold"):
        return text_layer(text, size, colour, outline=4, plate=True)

    black = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    mid = H / 2

    # (name, seconds, picture for a moment, what lands on it). Every length is a whole number of beats.
    scenes = [
        ("world", 2.0, lambda k, t: black, [Slam(big("IN A WORLD", 170, tracking=0.16), mid, at=0.0)]),
        ("auctions", 1.5, lambda k, t: camera(lists, (100, 170, 1220, 686), (100, 420, 1220, 686), ease(k)),
         [Slam(over("OF 200,000 AUCTIONS", 96), mid + 150, at=0.0, power=0.7)]),
        ("player", 1.0, lambda k, t: black, [Slam(big("ONE PLAYER", 170, tracking=0.12), mid, at=0.0)]),
        ("sheet", 1.5, lambda k, t: black, [Slam(big("HAD A SPREADSHEET", 140, "gold"), mid, at=0.0)]),
        ("notenough", 1.5, lambda k, t: black,
         [Slam(text_layer("it was not enough.", 64, GREY, 0.02, ITALIC, glow=False), mid, at=0.25, fade=True)]),
        ("winter", 1.0, lambda k, t: black, [Slam(big("THIS WINTER", 190, tracking=0.14), mid, at=0.0, power=1.2)]),
        ("recipe", 1.5, lambda k, t: camera(flow[min(len(flow) - 1, int(t * 10))], (60, 130, 900, 506), (150, 180, 720, 405), ease(k)),
         [Slam(over("IT KNOWS THE RECIPE"), mid + 170, at=0.0, power=0.7)]),
        ("wave", 1.5, lambda k, t: camera(rush[min(len(rush) - 1, int(k * len(rush)))], (850, 395, 400, 225), (835, 385, 430, 242), k),
         [Slam(over("IT RIDES THE WAVE"), mid + 170, at=0.0, power=0.7)]),
        ("buttons", 1.5, lambda k, t: camera(plan, (820, 330, 1100, 619), (820, 1000, 1100, 619), ease(k)),
         [Slam(over("IT PRESSES THE BUTTONS"), mid + 170, at=0.0, power=0.7)]),
        ("rapid", 1.0, lambda k, t: camera(quick[min(7, int(t / 0.125))], (120, 110, 1680, 945), (200, 155, 1520, 855), (t % 0.125) / 0.125), []),
        ("future", 1.5, lambda k, t: black, [Slam(big("IT SEES THE FUTURE", 176, "gold", tracking=0.08), mid, at=0.0, power=1.4)]),
        ("silence", 2.5, lambda k, t: camera(real, (1290, 640, 560, 315), (1330, 664, 470, 264), k),
         [Slam(text_layer("“Too early to forecast.”", 60, WHITE, 0.02, MEDIUM, glow=False, outline=4, plate=True), mid + 185, at=0.75, fade=True)]),
        ("mostly", 1.0, lambda k, t: black,
         [Slam(text_layer("...mostly.", 84, GREY, 0.04, ITALIC, glow=False), mid, at=0.05, fade=True)]),
        ("margin", 1.0, lambda k, t: black, [Slam(big("BASED ON A", 70, GREY, tracking=0.3, glow=False), mid - 105, at=0.0, power=0.5),
                                             Slam(big("TRUE MARGIN", 180), mid + 30, at=0.0)]),
        ("profit", 1.5, lambda k, t: camera(real, (1300, 235, 560, 315), (1330, 252, 500, 281), ease(k)),
         [Slam(over("+6 SILVER 11 COPPER", 92, GREEN), mid + 105, at=0.0, power=0.8),
          Slam(over("GIVE OR TAKE 18 SILVER", 56, WHITE), mid + 195, at=0.5, power=0.5)]),
        ("lose", 1.0, lambda k, t: black, [Slam(big("COULD LOSE 30 SILVER", 150, RED), mid, at=0.0, power=1.3, jitter=1.0)]),
        ("title", 3.0, None, []),
        ("rated", 2.0, lambda k, t: black,
         [Slam(big("RATED G FOR GOLD", 110, "gold", tracking=0.14), mid - 30, at=0.0, power=0.8),
          Slam(text_layer("Experimental. Deposits not included. Not affiliated with or endorsed by Blizzard.", 26, GREY, 0.02, MEDIUM, glow=False),
               mid + 95, at=0.45, fade=True)]),
    ]
    # What is said in each shot: (who, words, seconds into the shot, loudness).
    lines = {
        "world": ("narrator", "In a world.", 0.15, 1.0),
        "auctions": ("narrator", "Of two hundred thousand auctions.", 0.1, 1.0),
        "player": ("narrator", "One player.", 0.1, 1.0),
        "sheet": ("narrator", "Had a spreadsheet.", 0.1, 1.0),
        "notenough": ("narrator", "It was not enough.", 0.3, 0.8),
        "winter": ("narrator", "This winter.", 0.1, 1.0),
        "recipe": ("narrator", "It knows the recipe.", 0.1, 1.0),
        "wave": ("narrator", "It rides the wave.", 0.1, 1.0),
        "buttons": ("narrator", "It presses the buttons.", 0.1, 1.0),
        "future": ("narrator", "It sees, the future!", 0.1, 1.0),
        "silence": ("addon", "Too early to forecast.", 0.7, 0.9),
        "mostly": ("narrator", "Mostly.", 0.15, 0.85),
        "margin": ("narrator", "Based on a true margin.", 0.1, 1.0),
        "profit": ("narrator", "Six silver, eleven copper. Give or take.", 0.1, 1.0),
        "lose": ("addon", "Could lose thirty silver.", 0.15, 0.9),
        "title": ("narrator", "Craft Graph.", 0.35, 1.0),
        "rated": ("small", "Experimental. Deposits not included. Rated G, for gold.", 0.3, 0.75),
    }
    spoken = []
    for i, (name, seconds, base, lands) in enumerate(scenes):
        if name in lines:
            who, words, offset, gain = lines[name]
            samples = speak(work / ("say_" + name + ".wav"), words, who)
            spoken.append((name, samples, offset, gain))
            need = offset + len(samples) / SR + 0.05
            if need > seconds:                         # whole beats, so the cuts stay on the pulse
                scenes[i] = (name, math.ceil(need / BEAT) * BEAT, base, lands)
    marks, at = {}, 0.0
    for name, seconds, *_ in scenes:
        marks[name] = at
        at += seconds
    total = at

    # The title card: gold letters, a glint that sweeps across, sparks rising.
    title = text_layer("CRAFTGRAPH", 230, "gold", tracking=0.12, fit=0.84)
    slash = text_layer("/cg", 80, WHITE, 0.08, MEDIUM, glow=False)
    sparks = [(rng.uniform(0, W), rng.uniform(0, H), rng.uniform(20, 70), rng.uniform(1.5, 3.5)) for _ in range(70)]

    def title_frame(k, t):
        frame = black.copy()
        glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        g = ImageDraw.Draw(glow)
        for r, a in ((520, 16), (380, 22), (250, 30)):
            g.ellipse((W / 2 - r * 1.6, mid - r * 0.55, W / 2 + r * 1.6, mid + r * 0.55), fill=(255, 170, 30, int(a * min(1, t * 3))))
        frame = Image.alpha_composite(frame, glow.filter(ImageFilter.GaussianBlur(60)))
        d = ImageDraw.Draw(frame)
        for x, y, speed, size in sparks:
            yy = (y - t * speed) % H
            d.ellipse((x, yy, x + size, yy + size), fill=(255, 215, 90, int(170 * min(1, t * 2))))
        scale = 1.0 + 1.9 * math.exp(-t * 20) + 0.018 * t
        layer = title
        if 0.5 < t < 1.5:                              # the glint
            band = Image.new("L", title.size, 0)
            x = int((t - 0.5) * (title.width + 400)) - 200
            ImageDraw.Draw(band).polygon([(x, 0), (x + 90, 0), (x + 10, title.height), (x - 80, title.height)], fill=230)
            shine = ImageChops.multiply(band.filter(ImageFilter.GaussianBlur(14)), title.info["mask"])
            layer = title.copy()
            layer.paste(Image.new("RGBA", title.size, (255, 255, 240, 255)), (0, 0), shine)
        place(frame, layer, W / 2, mid - 20, scale, min(1.0, t * FPS / 2 + 0.3))
        if t > 0.9:
            place(frame, slash, W / 2, mid + 150, 1.0, ease((t - 0.9) / 0.4))
        return frame, 0.9 * math.exp(-t * 14), 22 * math.exp(-t * 8)

    # Pictures, piped straight into the encoder.
    silent = work / "silent.mp4"
    encoder = subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H), "-r", str(FPS),
         "-i", "-", "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p", str(silent)],
        stdin=subprocess.PIPE)
    hard = {"silence", "mostly", "notenough"}          # these arrive without a flash: the joke needs the quiet
    for name, seconds, base, lands in scenes:
        count = int(round(seconds * FPS))
        for i in range(count):
            t = i / FPS
            k = i / max(1, count - 1)
            if name == "title":
                frame, flash, shake = title_frame(k, t)
            else:
                frame = base(k, t).copy()
                flash = 0.0 if name in hard else 0.5 * math.exp(-t * 18)        # a flash on every cut
                shake = 0.0
                for land in lands:
                    f, s = land.draw(frame, t)
                    flash, shake = max(flash, f), max(shake, s)
            offset = (rng.uniform(-1, 1) * shake, rng.uniform(-1, 1) * shake * 0.6)
            dim = 1.0
            if name == "rated" and t > seconds - 0.4:
                dim = max(0.0, (seconds - t) / 0.4)
            encoder.stdin.write(finish(frame, flash, offset, dim).tobytes())
    encoder.stdin.close()
    if encoder.wait() != 0:
        sys.exit("the encoder failed")

    # Sound, on the same clock.
    stereo = compose(total, marks, spoken)
    sound = work / "sound.wav"
    with wave.open(str(sound), "w") as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes((np.clip(stereo, -1, 1) * 32767).astype("<i2").tobytes())
    out.parent.mkdir(parents=True, exist_ok=True)
    run("ffmpeg", "-y", "-loglevel", "error", "-i", silent, "-i", sound, "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
        "-shortest", "-movflags", "+faststart", out)
    print("%s  (%.1f seconds)" % (out, total))
    for name in sorted(marks, key=marks.get):
        print("  %5.1f  %s" % (marks[name], name))


if __name__ == "__main__":
    main()
