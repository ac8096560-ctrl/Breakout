#!/usr/bin/env python3
"""Synthesise Pixel Breakout's sound effects into audio/*.wav.

Original, generated from scratch (no samples, no downloads): every effect is a
short tone / noise envelope written by this script, mono 22050 Hz 16-bit.
"""
import math
import os
import random
import struct
import wave

RATE = 22050
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")


def write(name, samples):
    path = os.path.join(OUT, name)
    data = b"".join(struct.pack("<h", max(-32767, min(32767, int(s * 32767)))) for s in samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(data)
    print("wrote", path, "%.2fs" % (len(samples) / RATE))


def tone(freq, dur, amp=0.6, decay=6.0, wave_type="sine", glide_to=None):
    n = int(RATE * dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = freq if glide_to is None else freq + (glide_to - freq) * (i / n)
        phase += 2 * math.pi * f / RATE
        if wave_type == "square":
            v = 1.0 if math.sin(phase) >= 0 else -1.0
        elif wave_type == "tri":
            v = 2.0 * abs(2.0 * ((phase / (2 * math.pi)) % 1.0) - 1.0) - 1.0
        else:
            v = math.sin(phase)
        env = math.exp(-decay * t) * min(1.0, t / 0.004)
        out.append(v * env * amp)
    return out


def noise(dur, amp=0.5, decay=14.0, lowpass=0.35):
    n = int(RATE * dur)
    out = []
    prev = 0.0
    rnd = random.Random(7)
    for i in range(n):
        t = i / RATE
        white = rnd.uniform(-1.0, 1.0)
        prev = prev + lowpass * (white - prev)
        env = math.exp(-decay * t) * min(1.0, t / 0.002)
        out.append(prev * env * amp)
    return out


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, v in enumerate(t):
            out[i] += v
    return [max(-1.0, min(1.0, v)) for v in out]


def seq(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


write("bounce.wav", mix(tone(760, 0.06, 0.35, 34.0), noise(0.03, 0.10, 40.0)))
write("brick_break.wav", mix(noise(0.07, 0.55, 26.0, 0.55), tone(240, 0.07, 0.30, 30.0, "tri")))
write("powerup.wav", seq(tone(660, 0.07, 0.36, 8.0),
                        tone(880, 0.07, 0.36, 8.0),
                        tone(1320, 0.11, 0.36, 10.0)))
write("lose_life.wav", seq(tone(620, 0.13, 0.42, 6.0, "tri", 420),
                           tone(300, 0.22, 0.42, 7.0, "tri", 160)))
write("click.wav", tone(1180, 0.03, 0.30, 60.0))
write("confirm.wav", seq(tone(700, 0.06, 0.32, 14.0), tone(1050, 0.09, 0.32, 12.0)))
write("start.wav", tone(430, 0.22, 0.40, 5.0, "tri", 860))
write("countdown.wav", tone(660, 0.09, 0.32, 12.0, "square"))
write("victory.wav", seq(tone(523, 0.10, 0.34, 6.0),
                         tone(659, 0.10, 0.34, 6.0),
                         tone(784, 0.10, 0.34, 6.0),
                         tone(1046, 0.28, 0.36, 4.0)))
write("defeat.wav", seq(tone(523, 0.12, 0.34, 6.0, "tri"),
                        tone(392, 0.12, 0.34, 6.0, "tri"),
                        tone(247, 0.30, 0.36, 5.0, "tri")))
write("error.wav", seq(tone(220, 0.08, 0.30, 10.0, "square"),
                       tone(180, 0.12, 0.30, 8.0, "square")))
