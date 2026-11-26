"""An original, understated music bed for the launch video, synthesised from scratch (no samples, no licences).

    python music/score.py music/scenes.json public/music/bed.wav

Warm and quiet on purpose: rounded pads (filtered triangle + sine, slow attack, gentle chorus), a soft sine
pluck arpeggio, a felt-like sub pulse, no noise percussion. The 1-4 kHz band is kept clear for the voice.
The arrangement follows the edit (music/scenes.json): calm under the cold open, a swell into the logo,
a light pulse through the four steps, a hush on the FlagShift catch, a lift for the proof, a resolve.
"""
import json
import sys

import numpy as np
import soundfile as sf

SR = 48000
BPM = 96
BEAT = 60 / BPM
BAR = 4 * BEAT
rng = np.random.default_rng(11)

scenes = {s["id"]: s for s in json.load(open(sys.argv[1]))}
TOTAL = max(s["end"] for s in scenes.values()) + 0.5
N = int(TOTAL * SR)
L = np.zeros(N)
R = np.zeros(N)


def t_of(id_, key="start"):
    return scenes[id_][key]


def add(sig, at, pan=0.0, gain=1.0):
    i = int(at * SR)
    if i >= N or i < 0:
        return
    sig = sig[: N - i] * gain
    L[i: i + len(sig)] += sig * np.sqrt(0.5 * (1 - pan))
    R[i: i + len(sig)] += sig * np.sqrt(0.5 * (1 + pan))


def spectral(x, fn):
    """filter in the frequency domain: fn(freqs) -> gain"""
    n = len(x)
    nf = 1 << max(1, (n - 1).bit_length())
    fr = np.fft.rfftfreq(nf, 1 / SR)
    return np.fft.irfft(np.fft.rfft(x, nf) * fn(fr), nf)[:n]


def lowpass(x, fc, order=2):
    return spectral(x, lambda f: 1 / np.sqrt(1 + (f / fc) ** (2 * order)))


def env(n, a=0.01, r=0.2):
    t = np.arange(n) / SR
    return np.minimum(1, t / max(a, 1e-4)) * np.clip((n / SR - t) / max(r, 1e-4), 0, 1)


def tri(f, n, phase=0.0):
    t = np.arange(n) / SR
    ph = (f * t + phase) % 1
    return 4 * np.abs(ph - 0.5) - 1


def midi(m):
    return 440 * 2 ** ((m - 69) / 12)


# D major-ish, warm and optimistic: Dmaj7 - Bm7 - Gmaj7 - A6, two bars each
CHORDS = [[50, 57, 61, 64, 66], [47, 54, 57, 62, 66], [43, 50, 54, 59, 62], [45, 52, 57, 61, 66]]
BASS = [38, 35, 31, 33]


def pad(t0, t1, gain, bright=1400):
    t, k = t0, int(t0 / (2 * BAR))
    while t < t1:
        dur = min(2 * BAR, t1 - t)
        n = int((dur + 2.5) * SR)
        ch = CHORDS[k % 4]
        sig = np.zeros(n)
        for m in ch:
            for d in (-0.0035, 0.0, 0.0042):           # gentle chorus
                sig += tri(midi(m) * (1 + d), n, rng.random()) * 0.6
                sig += np.sin(2 * np.pi * midi(m) * (1 + d) * np.arange(n) / SR) * 0.4
        sig /= len(ch) * 3
        sig = lowpass(sig, bright, order=2) * env(n, a=1.4, r=2.4)
        add(sig, t, pan=-0.3, gain=gain)
        add(np.roll(sig, int(0.017 * SR)), t, pan=0.3, gain=gain * 0.95)
        t += 2 * BAR
        k += 1


_pl = {}


def pluck(m, length=0.9):
    if m in _pl:
        return _pl[m]
    n = int(length * SR)
    t = np.arange(n) / SR
    f = midi(m)
    x = (np.sin(2 * np.pi * f * t) + 0.25 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t * 9)) * np.exp(-t * 4.5)
    x *= np.minimum(1, t / 0.004)
    _pl[m] = x
    return x


def sub(f, length):
    n = int(length * SR)
    t = np.arange(n) / SR
    return np.sin(2 * np.pi * f * t) * env(n, a=0.02, r=length * 0.6)


def thump(gain=1.0):
    """a soft, felt-like kick: sine with a short pitch drop and no click"""
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    f = 48 + 55 * np.exp(-t * 22)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 8) * np.minimum(1, t / 0.006)
    return x * gain


def swell(dur, gain=0.5):
    """a rising pad swell instead of a noise riser"""
    n = int(dur * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    for m in (62, 66, 69, 74):
        x += np.sin(2 * np.pi * midi(m) * t) + 0.3 * tri(midi(m) * 1.003, n)
    x = lowpass(x / 4, 2500)
    return x * (t / dur) ** 2.2 * gain


def boom(gain=0.6):
    n = int(3.5 * SR)
    t = np.arange(n) / SR
    x = np.sin(2 * np.pi * np.cumsum(34 + 40 * np.exp(-t * 5)) / SR) * np.exp(-t * 1.3)
    shimmer = sum(np.sin(2 * np.pi * midi(m) * t) for m in (74, 78, 81)) * np.exp(-t * 1.8) * 0.12
    return (x + shimmer) * np.minimum(1, t / 0.01) * gain


def groove(t0, t1, arp=True, kick=True, bass=True, gain=1.0):
    t = np.ceil(t0 / BEAT) * BEAT
    i = int(round(t / BEAT))
    while t < t1:
        bar = int(t / BAR)
        ch = CHORDS[(bar // 2) % 4]
        if kick and i % 2 == 0:
            add(thump(0.55), t, gain=gain)
        if bass:
            add(sub(midi(BASS[(bar // 2) % 4]), BEAT * 0.9), t + BEAT / 2, gain=gain * 0.22)
        if arp:
            for k in range(2):  # eighth notes, up and down the chord, an octave up
                m = ch[(i * 2 + k) % len(ch)] + 12
                add(pluck(m), t + k * BEAT / 2, pan=0.35 * (1 if (i + k) % 2 else -1), gain=gain * 0.05)
        t += BEAT
        i += 1


title, steps, release, twist, apply_, proof, outro = (t_of(x) for x in ("title", "steps", "release", "twist", "apply", "proof", "outro"))
pad(0.0, title, gain=0.22, bright=700)                 # cold open: low, dark
add(swell(2.4, 0.18), title - 2.4)
add(boom(0.55), title)
pad(title, release, gain=0.2, bright=1500)
groove(title + BAR, steps, arp=True, kick=False, bass=True, gain=0.7)
add(swell(1.6, 0.12), steps - 1.6)
add(boom(0.35), steps)
groove(steps, release, arp=True, kick=True, bass=True, gain=0.85)
pad(release, apply_, gain=0.18, bright=800)            # the catch: hush
groove(twist, apply_, arp=True, kick=False, bass=False, gain=0.55)
pad(apply_, TOTAL, gain=0.2, bright=1600)
groove(apply_, proof, arp=False, kick=True, bass=True, gain=0.7)
add(swell(2.0, 0.15), proof - 2.0)
add(boom(0.4), proof)
groove(proof, outro, arp=True, kick=True, bass=True, gain=0.9)
add(boom(0.45), outro)

# ---- master: plate-ish reverb, voice pocket, soft limiting, fades -----------------------
ir_n = int(2.4 * SR)
ir = rng.standard_normal(ir_n) * np.exp(-np.arange(ir_n) / SR * 2.6)
ir = lowpass(ir, 3500)
ir /= np.sqrt((ir ** 2).sum())


def conv(x, h):
    n = len(x) + len(h) - 1
    nf = 1 << (n - 1).bit_length()
    return np.fft.irfft(np.fft.rfft(x, nf) * np.fft.rfft(h, nf), nf)[: len(x)]


L = L + 0.3 * conv(L, ir)
R = R + 0.3 * conv(R, np.roll(ir, 331))
# leave room for the voice: -5 dB bell around 2 kHz, gentle top cut
pocket = lambda f: (1 - 0.44 * np.exp(-((np.log2(np.maximum(f, 1) / 2000)) ** 2) / (2 * 0.9 ** 2))) / np.sqrt(1 + (f / 9000) ** 4)
L, R = spectral(L, pocket), spectral(R, pocket)
mix = np.stack([L, R], 1)
mix /= np.abs(mix).max() / 0.9
mix = np.tanh(mix * 1.1) / np.tanh(1.1) * 0.9
fade_in = np.clip(np.arange(N) / (1.0 * SR), 0, 1)
fade_out = np.clip((TOTAL - 0.3 - np.arange(N) / SR) / 3.5, 0, 1)
mix *= (fade_in * fade_out)[:, None]
sf.write(sys.argv[2], mix.astype(np.float32), SR, subtype="PCM_16")
print(f"{sys.argv[2]}: {TOTAL:.1f} s")
