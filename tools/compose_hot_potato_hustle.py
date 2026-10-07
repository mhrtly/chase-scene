#!/usr/bin/env python3
"""Hot Potato Hustle — the original chase tune that ships with Chase Scene.

Written and synthesized from scratch by Spudnik (Claude) for this project, and
dedicated to the public domain (CC0). No samples, no borrowed melodies: every
note below is original and every sound is generated with numpy.

    python3 tools/compose_hot_potato_hustle.py out.wav

Requires numpy and scipy. The app ships an AAC (.m4a) encoding of the result:

    ffmpeg -i out.wav -c:a aac -b:a 128k Resources/hot-potato-hustle.m4a
"""
import sys
import wave

import numpy as np
from scipy.signal import butter, sosfilt

SR = 44100
BPM = 172
EIGHTH = 60.0 / BPM / 2
rng = np.random.default_rng(1104)  # deterministic: same tune every build

NOTE_INDEX = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


def midi(name):
    letter, rest = name[0], name[1:]
    accidental = 0
    while rest and rest[0] in '#b':
        accidental += 1 if rest[0] == '#' else -1
        rest = rest[1:]
    return 12 * (int(rest) + 1) + NOTE_INDEX[letter] + accidental


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


# ---------------------------------------------------------------------------
# The score. One entry per bar: (chord, [(note-or-rest, length in eighths)...])
# ---------------------------------------------------------------------------
r = 'r'
SCORE = [
    # A section — the getaway
    ('C',   [('E5', 1), (r, 1), ('D#5', 1), ('E5', 1), ('G5', 1), (r, 1), ('E5', 1), ('C5', 1)]),
    ('C',   [('D5', 1), ('C5', 1), ('A4', 1), ('G4', 1), ('E4', 2), ('G4', 1), ('A4', 1)]),
    ('A7',  [('C#5', 1), (r, 1), ('C#5', 1), ('D5', 1), ('E5', 1), (r, 1), ('G5', 2)]),
    ('A7',  [('A5', 1), ('G5', 1), ('E5', 1), ('C#5', 1), ('A4', 2), (r, 2)]),
    ('D7',  [('F#5', 1), (r, 1), ('F#5', 1), ('G5', 1), ('A5', 1), ('F#5', 1), ('D5', 1), (r, 1)]),
    ('D7',  [('C5', 1), ('A4', 1), ('F#4', 1), ('A4', 1), ('C5', 2), ('D5', 1), ('D#5', 1)]),
    ('G7',  [('D5', 1), ('F5', 1), ('B4', 1), ('D5', 1), ('G5', 2), ('F5', 1), ('D5', 1)]),
    ('G7',  [('B4', 1), ('G4', 1), ('A4', 1), ('B4', 1), ('D5', 2), (r, 2)]),
    ('C',   [('E5', 1), (r, 1), ('D#5', 1), ('E5', 1), ('G5', 1), (r, 1), ('E5', 1), ('C5', 1)]),
    ('C',   [('D5', 1), ('C5', 1), ('A4', 1), ('G4', 1), ('C5', 2), ('D5', 1), ('D#5', 1)]),
    ('E7',  [('E5', 1), (r, 1), ('G#4', 1), ('B4', 1), ('E5', 1), (r, 1), ('D5', 2)]),
    ('Am',  [('C5', 1), ('B4', 1), ('A4', 1), ('G#4', 1), ('A4', 2), ('C5', 1), ('E5', 1)]),
    ('D7',  [('F#5', 1), ('E5', 1), ('D5', 1), ('C5', 1), ('A4', 1), ('F#4', 1), ('A4', 1), ('C5', 1)]),
    ('G7',  [('B4', 1), ('A4', 1), ('G4', 1), ('F4', 1), ('D4', 1), ('F4', 1), ('G4', 1), ('B4', 1)]),
    ('C',   [('C5', 1), (r, 1), ('E5', 1), (r, 1), ('G5', 1), (r, 1), ('C6', 2)]),
    ('G7',  [('B5', 1), ('A5', 1), ('G5', 1), ('F5', 1), ('D5', 1), ('B4', 1), ('G4', 1), (r, 1)]),
    # B section — the potato doubles back
    ('F',   [('F5', 3), ('C5', 1), (r, 1), ('A4', 1), ('F4', 2)]),
    ('F',   [('G4', 1), ('A4', 1), ('Bb4', 1), ('B4', 1), ('C5', 2), ('A4', 2)]),
    ('C',   [('G4', 3), ('E4', 1), (r, 1), ('C4', 1), ('E4', 1), ('G4', 1)]),
    ('C',   [('C5', 1), ('B4', 1), ('C5', 1), ('D5', 1), ('E5', 2), (r, 2)]),
    ('D7',  [('F#5', 3), ('D5', 1), (r, 1), ('A4', 1), ('C5', 1), ('D5', 1)]),
    ('G7',  [('F5', 1), ('E5', 1), ('D5', 1), ('C5', 1), ('B4', 2), ('G4', 2)]),
    ('C',   [('C5', 1), ('E5', 1), ('G5', 1), ('E5', 1), ('C5', 1), ('E5', 1), ('G5', 1), ('E5', 1)]),
    ('C7',  [('C6', 2), (r, 1), ('G5', 1), ('A5', 1), ('G5', 1), ('F5', 1), ('E5', 1)]),
    ('F',   [('F5', 3), ('C5', 1), (r, 1), ('A4', 1), ('F4', 2)]),
    ('F#dim', [('F#4', 1), ('A4', 1), ('C5', 1), ('D#5', 1), ('F#5', 2), ('D#5', 1), ('C5', 1)]),
    ('C/G', [('G4', 1), ('C5', 1), ('E5', 1), ('G5', 1), ('E5', 2), ('C5', 2)]),
    ('A7',  [('C#5', 1), ('E5', 1), ('G5', 1), ('A5', 1), ('G5', 1), ('E5', 1), ('C#5', 1), ('A4', 1)]),
    ('D7',  [('D5', 1), (r, 1), ('F#5', 1), (r, 1), ('A5', 2), ('F#5', 1), ('D5', 1)]),
    ('G7',  [('G5', 1), ('F5', 1), ('D5', 1), ('B4', 1), ('G4', 1), ('B4', 1), ('D5', 1), ('F5', 1)]),
    ('C',   [('E5', 1), (r, 1), ('C5', 1), (r, 1), ('C5', 1), ('E5', 1), ('G5', 1), ('C6', 1)]),
    ('G7',  [('G5', 2), ('F5', 1), ('D5', 1), ('B4', 1), ('C5', 1), ('D5', 1), ('D#5', 1)]),
]

CHORDS = {
    'C': ('C', [0, 4, 7]), 'C7': ('C', [0, 4, 7, 10]), 'F': ('F', [0, 4, 7]),
    'G7': ('G', [0, 4, 7, 10]), 'A7': ('A', [0, 4, 7, 10]), 'D7': ('D', [0, 4, 7, 10]),
    'E7': ('E', [0, 4, 7, 10]), 'Am': ('A', [0, 3, 7]), 'F#dim': ('F#', [0, 3, 6, 9]),
    'C/G': ('C', [0, 4, 7]),
}

for number, (_, bar) in enumerate(SCORE, 1):
    assert sum(length for _, length in bar) == 8, 'bar %d does not add up to 8 eighths' % number

TOTAL = len(SCORE) * 8 * EIGHTH
N = int(round(TOTAL * SR))
TAIL = SR  # one second of overflow, folded back onto the start so the loop is seamless


def envelope(n, attack, release, sustain=1.0, decay=0.0):
    t = np.arange(n) / SR
    env = np.minimum(1.0, t / max(attack, 1e-4))
    if decay:
        env *= sustain + (1 - sustain) * np.exp(-t / decay)
    rel = int(release * SR)
    if rel and n > rel:
        env[-rel:] *= np.linspace(1, 0, rel) ** 2
    return env


def sax(freq, seconds):
    """A honky, slightly growly reed voice: band-limited saw + scoop + vibrato."""
    n = int(seconds * SR)
    t = np.arange(n) / SR
    cents = -45 * np.exp(-t / 0.025)                                  # scoop up into the note
    if seconds > 0.25:
        depth = np.clip((t - 0.12) / 0.15, 0, 1) * 14
        cents = cents + depth * np.sin(2 * np.pi * 5.6 * t)            # delayed vibrato
    inst = freq * 2 ** (cents / 1200)
    phase = 2 * np.pi * np.cumsum(inst) / SR
    out = np.zeros(n)
    brightness = 9 + 10 * np.exp(-t / 0.05)                           # brighter on the attack
    for k in range(1, int(min(11000 / freq, 40)) + 1):
        weight = (1.0 / k) * np.exp(-k / brightness)
        if k % 2 == 0:
            weight *= 0.8
        out += weight * np.sin(k * phase)
    growl = 1 + 0.18 * np.exp(-t / 0.06) * np.sin(2 * np.pi * 31 * t)
    breath = sosfilt(butter(2, [1800, 5200], btype='band', fs=SR, output='sos'), rng.standard_normal(n))
    out = out * growl + 0.035 * breath * np.exp(-t / 0.04)
    return out * envelope(n, 0.012, 0.035, sustain=0.78, decay=0.09)


def honky_piano(freq, seconds=0.2):
    n = int((seconds + 0.25) * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for detune in (-7, 6):                                            # two strings, out of tune on purpose
        f = freq * 2 ** (detune / 1200)
        for k in range(1, 9):
            if k * f > 12000:
                break
            out += (1 / k ** 1.4) * np.sin(2 * np.pi * k * f * t) * np.exp(-t * (6 + 2.2 * k))
    damp = np.ones(n)
    cut = int(seconds * SR)
    damp[cut:] = np.exp(-np.arange(n - cut) / SR / 0.035)
    return out * envelope(n, 0.002, 0.0) * damp * 0.5


def tuba(freq, seconds):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    out = np.sin(2 * np.pi * freq * t) + 0.45 * np.sin(4 * np.pi * freq * t) + 0.18 * np.sin(6 * np.pi * freq * t)
    return out * envelope(n, 0.018, 0.05, sustain=0.6, decay=0.12)


def kick():
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    f = 48 + 90 * np.exp(-t / 0.03)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.06)


def snare():
    n = int(0.18 * SR)
    t = np.arange(n) / SR
    noise = sosfilt(butter(2, [1200, 7000], btype='band', fs=SR, output='sos'), rng.standard_normal(n))
    return (0.7 * noise + 0.35 * np.sin(2 * np.pi * 190 * t)) * np.exp(-t / 0.045)


def hat(open_=False):
    n = int((0.09 if open_ else 0.04) * SR)
    t = np.arange(n) / SR
    noise = sosfilt(butter(2, 7500, btype='high', fs=SR, output='sos'), rng.standard_normal(n))
    return noise * np.exp(-t / (0.03 if open_ else 0.012))


def woodblock():
    n = int(0.06 * SR)
    t = np.arange(n) / SR
    return (np.sin(2 * np.pi * 1250 * t) + 0.4 * np.sin(2 * np.pi * 2600 * t)) * np.exp(-t / 0.012)


left = np.zeros(N + TAIL)
right = np.zeros(N + TAIL)


def place(signal, at_seconds, gain, pan=0.0):
    """pan: -1 = left, +1 = right (constant power)."""
    start = int(round(at_seconds * SR))
    end = min(start + len(signal), len(left))
    angle = (pan + 1) * np.pi / 4
    left[start:end] += signal[:end - start] * gain * np.cos(angle)
    right[start:end] += signal[:end - start] * gain * np.sin(angle)


for bar_number, (chord_name, bar) in enumerate(SCORE):
    bar_start = bar_number * 8 * EIGHTH
    # Melody
    position = 0
    for note, length in bar:
        if note != r:
            articulation = 0.9 if length > 1 else 0.72
            place(sax(hz(midi(note)), length * EIGHTH * articulation), bar_start + position * EIGHTH, 0.62, 0.05)
        position += length
    # Stride accompaniment: oom (bass) - pah (chord) - oom - pah
    root_name, intervals = CHORDS[chord_name]
    root = midi(root_name + '2')
    bass_notes = [root, root + 7] if chord_name != 'C/G' else [midi('G2'), midi('C3')]
    for beat, bass in zip((0, 4), bass_notes):
        place(tuba(hz(bass), EIGHTH * 1.6), bar_start + beat * EIGHTH, 0.42, 0.0)
    voicing = [midi(root_name + '4') + i for i in intervals]
    voicing = [v - 12 if v > midi('A4') else v for v in voicing]
    for beat in (2, 6):
        for v in voicing:
            place(honky_piano(hz(v), EIGHTH * 0.8), bar_start + beat * EIGHTH, 0.16, -0.35)
    # Drums
    for beat in (0, 4):
        place(kick(), bar_start + beat * EIGHTH, 0.38)
    for beat in (2, 6):
        place(snare(), bar_start + beat * EIGHTH, 0.22, 0.1)
    for eighth in range(8):
        place(hat(open_=(eighth == 7 and bar_number % 4 == 3)), bar_start + eighth * EIGHTH,
              0.07 if eighth % 2 else 0.04, 0.4)
    if bar_number >= 16:  # the woodblock joins the chase in the B section
        for eighth in (3, 7):
            place(woodblock(), bar_start + eighth * EIGHTH, 0.1, 0.55)

# Fold the overflow tail back onto the start for a seamless loop.
left[:TAIL] += left[N:]
right[:TAIL] += right[N:]
mix = np.stack([left[:N], right[:N]], axis=1)
mix = np.tanh(mix * 1.15)                      # a little tape-ish glue
mix *= 0.89 / np.max(np.abs(mix))              # peak at about -1 dBFS

out = sys.argv[1] if len(sys.argv) > 1 else 'hot-potato-hustle.wav'
with wave.open(out, 'wb') as handle:
    handle.setnchannels(2)
    handle.setsampwidth(2)
    handle.setframerate(SR)
    handle.writeframes((mix * 32767).astype('<i2').tobytes())
print('Wrote %s: %d bars, %.1f seconds at %d BPM' % (out, len(SCORE), TOTAL, BPM))
