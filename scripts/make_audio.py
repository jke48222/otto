#!/usr/bin/env python3
"""make_audio.py: the promo film's soundtrack, synthesized from scratch (no samples, no loops, no
third-party audio, so it is original and free to use under the repo's MIT license).

  python3 scripts/make_audio.py --cues build/promo-cues.json --out build/promo-audio.wav

• Music bed: a slow, warm pad in D major (Dmaj9, Bm9, Gmaj7#11, A6sus, twice, two bars each), a
  soft sub, and a sparse bell-like arpeggio that enters after the title card, all through a small
  synthetic room reverb. The tempo is fitted to the cut: the eight chords fill the time before the
  end card exactly (chord = end card / 8, about 82 bpm on the 1.1 film), so the last A6sus hands
  over to the Dmaj9 resolve as the end card starts.
• UI sounds, one per cue from scripts/make_video.swift (--cues): quiet ticks for clicks, a soft
  rising/falling breath for the notch opening/closing, a low tap for the drop, a two-note tick for
  send, a softer, lower rising two-tone breath as the listening pill grows, and an airy swell for
  the Settings window.
• Provenance: every sample is computed here from sine waves and seeded noise; nothing is read from
  disk but the cue list. The mix is deterministic (fixed seeds), so the same cut always gets the
  same track.
• Written as 48 kHz 16-bit stereo WAV with a 0.5 s fade-in (under the title card) and a 1.5 s
  fade-out (under the end card). scripts/make_video.sh
  then normalizes it to -16 LUFS integrated (ffmpeg loudnorm, two passes, linear) and muxes it.

The film still works muted: the captions carry every idea.
Requires numpy.
"""

import argparse
import json
import wave

import numpy as np

SR = 48_000
# Each chord lasts two bars (eight beats). The chord length (and so the tempo) is fitted to the cut
# in music(): CHORD_LEN = end card / len(PROGRESSION).
BEATS_PER_CHORD = 8

# Voicings (MIDI). Roots low, colour tones on top.
CHORDS = {
    "Dmaj9": [50, 57, 61, 64, 66],
    "Bm9": [47, 54, 57, 61, 62],
    "Gmaj7#11": [43, 50, 54, 59, 61],
    "A6sus": [45, 52, 54, 59, 62],
}
PROGRESSION = ["Dmaj9", "Bm9", "Gmaj7#11", "A6sus", "Dmaj9", "Bm9", "Gmaj7#11", "A6sus"]


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def rng(seed):
    return np.random.default_rng(seed)


def adsr(n, attack, release, sustain_level=1.0):
    t = np.arange(n) / SR
    env = np.minimum(1.0, t / max(attack, 1e-4)) * sustain_level
    tail = (n / SR) - t
    env *= np.clip(tail / max(release, 1e-4), 0, 1)
    # Smooth (raised-cosine) edges instead of linear ramps.
    return 0.5 - 0.5 * np.cos(np.pi * np.clip(env, 0, 1))


def pad_note(freq, dur, detune_cents, seed):
    """Additive, slightly detuned 'analog' pad voice (stereo)."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    r = rng(seed)
    out = np.zeros((n, 2))
    lfo = 0.5 + 0.5 * np.sin(2 * np.pi * 0.11 * t + r.uniform(0, 6.28))
    for ch, sign in ((0, -1), (1, 1)):
        f = freq * 2 ** (sign * detune_cents / 1200)
        voice = np.zeros(n)
        for h in range(1, 7):
            amp = 1.0 / h ** 1.7
            if h > 2:
                amp *= 0.55 + 0.45 * lfo  # the 'filter' breathes slowly
            voice += amp * np.sin(2 * np.pi * f * h * t + r.uniform(0, 6.28))
        out[:, ch] = voice
    return out


def bell(freq, dur, seed, decay=1.1):
    n = int(dur * SR)
    t = np.arange(n) / SR
    r = rng(seed)
    tone = (np.sin(2 * np.pi * freq * t)
            + 0.35 * np.sin(2 * np.pi * freq * 2.0 * t) * np.exp(-t * 3)
            + 0.12 * np.sin(2 * np.pi * freq * 3.01 * t) * np.exp(-t * 6))
    env = np.exp(-t / decay * 2.2) * np.minimum(1, t / 0.004)
    pan = r.uniform(0.3, 0.7)
    mono = tone * env
    return np.stack([mono * np.sqrt(1 - pan), mono * np.sqrt(pan)], axis=1)


def place(buf, clip, start):
    i = int(round(start * SR))
    if i >= len(buf):
        return
    j = min(len(buf), i + len(clip))
    buf[i:j] += clip[: j - i]


def reverb(x, seconds=2.4, wet=0.28, seed=5):
    """Convolution with decorrelated, exponentially decaying noise: a soft, neutral room."""
    r = rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    decay = np.exp(-t * 6.9 / seconds)
    out = np.zeros_like(x)
    size = 1 << int(np.ceil(np.log2(len(x) + n)))
    for ch in range(2):
        ir = r.standard_normal(n) * decay
        # Darken the tail: a gentle one-pole low-pass on the impulse response.
        smoothed = np.empty_like(ir)
        acc = 0.0
        for k in range(n):
            acc += 0.35 * (ir[k] - acc)
            smoothed[k] = acc
        ir = smoothed / np.sqrt(np.sum(smoothed ** 2))
        y = np.fft.irfft(np.fft.rfft(x[:, ch], size) * np.fft.rfft(ir, size), size)[: len(x)]
        out[:, ch] = y
    return (1 - wet) * x + wet * out


def music(duration, resolve_at):
    n = int(duration * SR)
    buf = np.zeros((n, 2))
    # The two-cycle progression fills the time before the end card exactly.
    chord_len = resolve_at / len(PROGRESSION)
    bpm = 60.0 * BEATS_PER_CHORD / chord_len
    print(f"tempo: {bpm:.1f} bpm, {chord_len:.2f} s per chord, resolve at {resolve_at:.2f} s")
    # Pad: each chord overlaps the next by a slow crossfade (the last one into the resolve).
    overlap = 1.6
    for i, name in enumerate(PROGRESSION):
        start = i * chord_len
        dur = chord_len + overlap
        voices = CHORDS[name]
        chord = np.zeros((int(dur * SR), 2))
        for k, m in enumerate(voices):
            chord += pad_note(hz(m), dur, 4 + k, seed=100 * i + k) * (0.9 if k else 0.7)
        env = adsr(len(chord), attack=1.4 if i else 0.4, release=overlap)
        place(buf, chord * env[:, None] * 0.055, start - (0 if i == 0 else overlap / 2))
        # Sub: the root an octave down, round and quiet.
        root = hz(voices[0] - 12)
        sub_len = int(dur * SR)
        tt = np.arange(sub_len) / SR
        sub = np.sin(2 * np.pi * root * tt) * adsr(sub_len, 0.8, overlap)
        place(buf, np.stack([sub, sub], axis=1) * 0.05, start - (0 if i == 0 else overlap / 2))
    # Final resolve: Dmaj9 again under the end card, so it lands home.
    dur = duration - resolve_at + 0.2
    chord = np.zeros((int(dur * SR), 2))
    for k, m in enumerate(CHORDS["Dmaj9"] + [69]):
        chord += pad_note(hz(m), dur, 5 + k, seed=900 + k)
    place(buf, chord * adsr(len(chord), 1.2, 2.0)[:, None] * 0.045, resolve_at)

    # Arpeggio: sparse bell notes from the upper chord tones, entering after the title card; under
    # the end card they follow the resolve.
    step = 60.0 / bpm / 2  # eighth notes
    pattern = [0, None, 2, None, 4, 3, None, 1, 0, None, 3, None, 4, None, 2, None]
    r = rng(42)
    t = 2.4
    k = 0
    while t < duration - 3.5:
        idx = pattern[k % len(pattern)]
        if idx is not None:
            if t >= resolve_at:
                name = "Dmaj9"
            else:
                name = PROGRESSION[min(int(t // chord_len), len(PROGRESSION) - 1)]
            upper = sorted(CHORDS[name])[1:]
            m = upper[idx % len(upper)] + 12
            vel = 0.5 + 0.5 * r.uniform()
            place(buf, bell(hz(m), 1.6, seed=k) * 0.028 * vel, t)
        t += step
        k += 1
    return buf


# UI sounds -----------------------------------------------------------------------------------------

def band_noise(n, lo, hi, seed):
    x = rng(seed).standard_normal(n)
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(spec, n)


def ui_sound(kind, seed):
    if kind == "click":
        n = int(0.05 * SR)
        t = np.arange(n) / SR
        s = band_noise(n, 2500, 7000, seed) * np.minimum(1, t / 0.0015) * np.exp(-t / 0.004) * 0.6
        s += np.sin(2 * np.pi * 1850 * t) * np.exp(-t / 0.012) * 0.35
        return s * 0.5
    if kind in ("open", "close"):
        n = int(0.26 * SR)
        t = np.arange(n) / SR
        f0, f1 = (430, 690) if kind == "open" else (660, 420)
        freq = f0 + (f1 - f0) * (1 - np.exp(-t / 0.07))
        phase = 2 * np.pi * np.cumsum(freq) / SR
        env = np.minimum(1, t / 0.018) * np.exp(-t / 0.075)
        s = np.sin(phase) * env * 0.5
        air = band_noise(n, 600, 5000, seed) * np.minimum(1, t / 0.03) * np.exp(-t / 0.06) * 0.18
        return (s + air) * 0.55
    if kind == "drop":
        n = int(0.2 * SR)
        t = np.arange(n) / SR
        s = np.sin(2 * np.pi * (150 + 60 * np.exp(-t / 0.02)) * t) * np.exp(-t / 0.05) * 0.8
        s += band_noise(n, 1500, 5000, seed) * np.minimum(1, t / 0.0015) * np.exp(-t / 0.006) * 0.3
        return s * 0.5
    if kind == "send":
        n = int(0.22 * SR)
        t = np.arange(n) / SR
        a = np.sin(2 * np.pi * 1320 * t) * np.exp(-t / 0.03)
        t2 = np.clip(t - 0.07, 0, None)
        b = np.sin(2 * np.pi * 1760 * t2) * np.exp(-t2 / 0.05) * (t >= 0.07)
        return (0.45 * a + 0.5 * b) * 0.45
    if kind == "listen":
        # The listening pill: a soft two-tone breath rising a fourth, lower and quieter than the
        # notch opening, with a little air.
        n = int(0.42 * SR)
        t = np.arange(n) / SR
        a = np.sin(2 * np.pi * 294 * t) * np.minimum(1, t / 0.03) * np.exp(-t / 0.12)
        t2 = np.clip(t - 0.11, 0, None)
        b = np.sin(2 * np.pi * 392 * t2) * np.minimum(1, t2 / 0.03) * np.exp(-t2 / 0.14) * (t >= 0.11)
        air = band_noise(n, 500, 3000, seed) * np.sin(np.pi * np.clip(t / 0.42, 0, 1)) ** 2 * 0.1
        return (0.5 * a + 0.55 * b + air) * 0.32
    if kind == "window":
        n = int(0.45 * SR)
        t = np.arange(n) / SR
        env = np.sin(np.pi * np.clip(t / 0.45, 0, 1)) ** 2
        return band_noise(n, 400, 3500, seed) * env * 0.12
    raise ValueError(kind)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.cues) as handle:
        doc = json.load(handle)
    duration = float(doc["duration"])

    # The end card's start (from the edit), where the music resolves.
    mix = music(duration, resolve_at=float(doc["endCard"]))
    fx = np.zeros_like(mix)
    for i, cue in enumerate(doc["cues"]):
        mono = ui_sound(cue["kind"], seed=1000 + i)
        pan = 0.5
        place(fx, np.stack([mono * np.sqrt(1 - pan), mono * np.sqrt(pan)], axis=1), float(cue["t"]))
    mix = reverb(mix) + reverb(fx, seconds=0.8, wet=0.18, seed=9)

    # Fades: 0.5 s in, 1.5 s out (raised cosine).
    n = len(mix)
    fade_in = int(0.5 * SR)
    fade_out = int(1.5 * SR)
    mix[:fade_in] *= (0.5 - 0.5 * np.cos(np.pi * np.arange(fade_in) / fade_in))[:, None]
    mix[n - fade_out:] *= (0.5 + 0.5 * np.cos(np.pi * np.arange(fade_out) / fade_out))[:, None]

    peak = np.max(np.abs(mix))
    if peak > 0:
        mix *= 0.5 / peak  # headroom; loudness is set afterwards by loudnorm
    pcm = (np.clip(mix, -1, 1) * 32767).astype("<i2")
    with wave.open(args.out, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {args.out} ({duration:.1f} s)")


if __name__ == "__main__":
    main()
