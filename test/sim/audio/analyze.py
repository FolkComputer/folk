#!/usr/bin/env python3
"""Tone / silence analysis of captured audio. numpy only; importable and a CLI.

    import analyze
    wav = analyze.load("capture.wav")              # mono float in -1..1, wav.rate, wav.duration
    analyze.segments(wav, win=0.05)                # [(t0, t1, dominant_hz | None, rms_dbfs), ...]
    wav.find_tone(440, tol_hz=10)                  # [(t0, t1), ...] where a 440 Hz component is present
    wav.assert_tone(440, min_dur=0.9)              # -> (t0, t1), or AssertionError with a description
    wav.assert_silence(0.0, 0.2)
    wav.onsets()                                   # [t, ...] silence -> sound transitions (about 1 ms)
    wav.peaks(t0, t1)                              # [(hz, dbfs), ...] strongest components (chords)
    wav.epoch(t)                                   # wall-clock time of capture time t (needs the sidecar)

    analyze.py capture.wav [--json] [--tone HZ:MIN_DUR ...] [--no-tone HZ ...] [--silence T0:T1 ...]
    analyze.py --selftest

Levels are dB relative to full scale: a full-scale sine has an RMS of -3.01 dBFS and a tone
component of amplitude 1.0 is reported by find_tone/peaks as 0 dBFS. Times are seconds from
the first sample. sink.sh's recorder writes <file>.json with the wall-clock time of the first
sample ("t0_epoch"); load() picks it up as wav.t0_epoch.
"""

import json
import math
import os
import struct
import sys

import numpy as np

SILENCE_DBFS = -60.0   # an RMS below this is silence
TONE_DBFS = -40.0      # a tone component must be at least this strong (amplitude re full scale)


def _db(x):
    return 20.0 * np.log10(np.maximum(x, 1e-10))


class Wav:
    def __init__(self, samples, rate, t0_epoch=None, path=None):
        x = np.asarray(samples, dtype=np.float64)
        if x.ndim == 2:                       # (frames, channels) -> mono
            x = x.mean(axis=1)
        self.x = x
        self.rate = int(rate)
        self.t0_epoch = t0_epoch
        self.path = path

    @property
    def duration(self):
        return len(self.x) / self.rate

    def epoch(self, t):
        if self.t0_epoch is None:
            raise ValueError("no capture timestamp (missing %s.json)" % (self.path or "<wav>"))
        return self.t0_epoch + t

    # ---- spectra -------------------------------------------------------------------------

    def _spectra(self, win, hop, centred):
        """Yields (index, freqs, amplitude spectrum, rms) per window. Amplitudes are scaled so
        that a sine of amplitude A that fills the window peaks at A."""
        n = max(32, int(round(win * self.rate)))
        h = max(1, int(round(hop * self.rate)))
        x = self.x
        if centred:                           # window i is centred on i*hop
            x = np.concatenate([np.zeros(n // 2), x, np.zeros(n)])
            count = len(self.x) // h + 1
        else:                                 # window i covers [i*hop, i*hop + win)
            count = max(1, int(math.ceil(len(x) / h)))
            x = np.concatenate([x, np.zeros(n)])
        nfft = 1 << int(math.ceil(math.log2(n * 4)))
        window = np.hanning(n)
        scale = 2.0 / window.sum()
        freqs = np.fft.rfftfreq(nfft, 1.0 / self.rate)
        step = max(1, (8 << 20) // nfft)       # bounded memory
        for i0 in range(0, count, step):
            idx = np.arange(i0, min(count, i0 + step))
            frames = x[idx[:, None] * h + np.arange(n)[None, :]]
            spec = np.abs(np.fft.rfft(frames * window, nfft, axis=1)) * scale
            rms = np.sqrt((frames ** 2).mean(axis=1))
            for k, i in enumerate(idx):
                yield int(i), freqs, spec[k], float(rms[k])

    @staticmethod
    def _peak(freqs, spec, lo, hi):
        """Strongest local maximum in [lo, hi] Hz -> (hz, amplitude), parabolic interpolation."""
        a = int(np.searchsorted(freqs, lo))
        b = int(np.searchsorted(freqs, hi, side="right"))
        a, b = max(a, 1), min(b, len(spec) - 1)
        if b <= a:
            return None, 0.0
        k = a + int(np.argmax(spec[a:b]))
        y0, y1, y2 = spec[k - 1], spec[k], spec[k + 1]
        d = y0 - 2 * y1 + y2
        off = 0.0 if d == 0 else float(np.clip(0.5 * (y0 - y2) / d, -1, 1))
        return float(freqs[k] + off * (freqs[1] - freqs[0])), float(y1 - 0.25 * (y0 - y2) * off)

    # ---- segments ------------------------------------------------------------------------

    def segments(self, win=0.05, silence_dbfs=SILENCE_DBFS, tol_hz=None, min_hz=30.0):
        """[(t0, t1, dominant_hz or None for silence, rms_dbfs)]: consecutive windows of `win`
        seconds with the same content merged. Boundaries are accurate to one window; use
        find_tone() or onsets() for better timing. tol_hz: how far the dominant frequency may
        drift inside one segment (default: 3 % or 5 Hz). A chord of equally strong notes
        comes out as several segments (the dominant note flips): use find_tone() per note."""
        out = []          # [t0, t1, sum of hz, sum of power, windows]
        total = self.duration
        for i, freqs, spec, rms in self._spectra(win, win, centred=False):
            t0, t1 = i * win, min((i + 1) * win, total)
            if t1 <= t0:
                break
            # the last window may be partly padding: take its level from the real samples
            a, b = int(round(t0 * self.rate)), int(round(t1 * self.rate))
            rms = float(np.sqrt((self.x[a:b] ** 2).mean())) if b > a else 0.0
            hz = None
            if _db(rms) >= silence_dbfs:
                hz, _ = self._peak(freqs, spec, min_hz, self.rate / 2.0)
            if out:
                last = out[-1]
                last_hz = None if last[2] is None else last[2] / last[4]
                tol = None if last_hz is None else (tol_hz if tol_hz is not None else max(5.0, 0.03 * last_hz))
                same = (hz is None and last_hz is None) or \
                       (hz is not None and last_hz is not None and abs(hz - last_hz) <= tol)
                if same:
                    last[1] = t1
                    last[2] = None if hz is None else last[2] + hz
                    last[3] += rms * rms
                    last[4] += 1
                    continue
            out.append([t0, t1, hz, rms * rms, 1])
        # A window that a tone only just reaches into (or out of) is quiet and its spectrum
        # is smeared, so its "dominant frequency" means little: give it to the neighbour.
        i = 0
        while i < len(out):
            s = out[i]
            if s[4] == 1 and s[2] is not None:
                for j in (i + 1, i - 1):
                    if 0 <= j < len(out) and out[j][2] is not None and out[j][3] / out[j][4] >= 4.0 * s[3] \
                            and (out[j][4] >= 2 or abs(out[j][2] - s[2]) > 1.0):
                        out[j][0], out[j][1] = min(out[j][0], s[0]), max(out[j][1], s[1])
                        del out[i]
                        i -= 1
                        break
            i += 1
        return [(s[0], s[1], None if s[2] is None else s[2] / s[4],
                 float(_db(math.sqrt(s[3] / s[4])))) for s in out]

    # ---- tones ---------------------------------------------------------------------------

    def find_tone(self, freq, tol_hz=10.0, min_dbfs=TONE_DBFS, win=0.05, max_gap=0.0):
        """[(t0, t1)] intervals in which a sinusoidal component within tol_hz of freq and at
        least min_dbfs strong is present (also as one note of a chord). Edges are placed where
        the component passes half of the interval's peak amplitude: accurate to about win/5.
        max_gap: join intervals separated by no more than this (tolerates short dropouts)."""
        hop = win / 5.0
        guard = 2.0 * self.rate / max(32, int(round(win * self.rate)))   # Hann main lobe half width
        amps = []
        for i, freqs, spec, rms in self._spectra(win, hop, centred=True):
            hz, amp = self._peak(freqs, spec, max(1.0, freq - tol_hz - guard), freq + tol_hz + guard)
            amps.append(amp if hz is not None and abs(hz - freq) <= tol_hz else 0.0)
        amps = np.array(amps)
        thr = 10.0 ** (min_dbfs / 20.0)
        out = []
        i, n = 0, len(amps)
        while i < n:
            if amps[i] < thr:
                i += 1
                continue
            j = i
            while j + 1 < n and amps[j + 1] >= thr:
                j += 1
            half = amps[i:j + 1].max() / 2.0
            a = i
            while amps[a] < half:
                a += 1
            b = j
            while amps[b] < half:
                b -= 1

            def cross(k_out, k_in):           # linear interpolation of the half-amplitude point
                if k_out < 0 or k_out >= n:
                    return k_in
                lo, hi = amps[k_out], amps[k_in]
                return k_in if hi <= lo else k_in + (k_out - k_in) * (hi - half) / (hi - lo)
            t0 = max(0.0, cross(a - 1, a) * hop)
            t1 = min(self.duration, cross(b + 1, b) * hop)
            if t1 > t0:
                if out and max_gap > 0 and t0 - out[-1][1] <= max_gap:
                    out[-1] = (out[-1][0], float(t1))
                else:
                    out.append((float(t0), float(t1)))
            i = j + 1
        return out

    def assert_tone(self, freq, min_dur, tol_hz=10.0, t0=None, t1=None, min_dbfs=TONE_DBFS, win=0.05,
                    max_gap=0.0):
        """Asserts one uninterrupted interval of the tone lasting at least min_dur seconds
        (inside [t0, t1] if given; dropouts up to max_gap seconds are bridged). Returns that
        interval (the longest one)."""
        found = self.find_tone(freq, tol_hz=tol_hz, min_dbfs=min_dbfs, win=win, max_gap=max_gap)
        lo = 0.0 if t0 is None else t0
        hi = self.duration if t1 is None else t1
        clipped = [(max(a, lo), min(b, hi)) for a, b in found if min(b, hi) > max(a, lo)]
        best = max(clipped, key=lambda iv: iv[1] - iv[0], default=None)
        if best is None or best[1] - best[0] < min_dur:
            raise AssertionError("no %.1f Hz tone of at least %.3f s in [%.3f, %.3f]: found %s\n%s" % (
                freq, min_dur, lo, hi,
                ", ".join("%.3f-%.3f" % iv for iv in clipped) or "none", self.describe()))
        return best

    def assert_no_tone(self, freq, tol_hz=10.0, t0=None, t1=None, min_dbfs=TONE_DBFS, win=0.05):
        lo = 0.0 if t0 is None else t0
        hi = self.duration if t1 is None else t1
        hits = [(a, b) for a, b in self.find_tone(freq, tol_hz=tol_hz, min_dbfs=min_dbfs, win=win)
                if min(b, hi) > max(a, lo)]
        if hits:
            raise AssertionError("unexpected %.1f Hz tone at %s\n%s" % (
                freq, ", ".join("%.3f-%.3f" % iv for iv in hits), self.describe()))

    def peaks(self, t0=None, t1=None, n=5, min_rel_db=-30.0, min_hz=30.0):
        """[(hz, dbfs)] of up to n strongest spectral peaks in [t0, t1], strongest first."""
        a = 0 if t0 is None else max(0, int(round(t0 * self.rate)))
        b = len(self.x) if t1 is None else min(len(self.x), int(round(t1 * self.rate)))
        x = self.x[a:b]
        if len(x) < 32:
            return []
        window = np.hanning(len(x))
        nfft = 1 << int(math.ceil(math.log2(len(x) * 4)))
        spec = np.abs(np.fft.rfft(x * window, nfft)) * 2.0 / window.sum()
        freqs = np.fft.rfftfreq(nfft, 1.0 / self.rate)
        lobe = 2.0 * self.rate / len(x)
        out = []
        spec = spec.copy()
        spec[freqs < min_hz] = 0
        for _ in range(n):
            hz, amp = self._peak(freqs, spec, min_hz, self.rate / 2.0)
            if hz is None or amp <= 0 or (out and _db(amp) - out[0][1] < min_rel_db) or _db(amp) < -90:
                break
            out.append((hz, float(_db(amp))))
            spec[(freqs > hz - 2 * lobe) & (freqs < hz + 2 * lobe)] = 0
        return out

    # ---- levels --------------------------------------------------------------------------

    def _envelope(self, block):
        n = max(1, int(round(block * self.rate)))
        count = len(self.x) // n
        if count == 0:
            return n, np.zeros(0)
        return n, np.sqrt((self.x[:count * n].reshape(count, n) ** 2).mean(axis=1))

    def level(self, t0=None, t1=None):
        """RMS level in dBFS of [t0, t1]."""
        a = 0 if t0 is None else max(0, int(round(t0 * self.rate)))
        b = len(self.x) if t1 is None else min(len(self.x), int(round(t1 * self.rate)))
        return float(_db(math.sqrt(float((self.x[a:b] ** 2).mean())))) if b > a else -200.0

    def assert_silence(self, t0=None, t1=None, max_dbfs=SILENCE_DBFS):
        """Asserts that no 10 ms block inside [t0, t1] is louder than max_dbfs (RMS)."""
        lo = 0.0 if t0 is None else max(0.0, t0)
        hi = self.duration if t1 is None else min(self.duration, t1)
        a, b = int(round(lo * self.rate)), int(round(hi * self.rate))
        part = Wav(self.x[a:b], self.rate)
        n, env = part._envelope(0.01)
        if len(env) == 0:
            env = np.array([math.sqrt(float((part.x ** 2).mean()))]) if len(part.x) else np.zeros(1)
        k = int(np.argmax(env))
        if _db(env[k]) > max_dbfs:
            raise AssertionError("not silent in [%.3f, %.3f]: %.1f dBFS at %.3f s (limit %.1f)\n%s" % (
                lo, hi, _db(env[k]), lo + k * n / self.rate, max_dbfs, self.describe()))

    def sounds(self, threshold_dbfs=-50.0, min_silence=0.05):
        """[(t0, t1)] stretches of sound separated by at least min_silence seconds below the
        threshold. Edges are refined to the first / last sample above the threshold."""
        n, env = self._envelope(0.002)
        thr = 10.0 ** (threshold_dbfs / 20.0)
        loud = np.flatnonzero(env >= thr)
        if len(loud) == 0:
            return []
        gap = max(1, int(round(min_silence / 0.002)))
        out = []
        start = prev = int(loud[0])
        for k in loud[1:]:
            k = int(k)
            if k - prev > gap:
                out.append((start, prev))
                start = k
            prev = k
        out.append((start, prev))
        res = []
        for a, b in out:
            first = np.flatnonzero(np.abs(self.x[a * n:(a + 1) * n]) >= thr)
            last = np.flatnonzero(np.abs(self.x[b * n:(b + 1) * n]) >= thr)
            s0 = a * n + (int(first[0]) if len(first) else 0)
            s1 = b * n + (int(last[-1]) + 1 if len(last) else n)
            res.append((s0 / self.rate, s1 / self.rate))
        return res

    def onsets(self, threshold_dbfs=-50.0, min_silence=0.05):
        """Times at which sound starts after at least min_silence seconds of silence."""
        return [a for a, b in self.sounds(threshold_dbfs, min_silence)]

    # ---- reporting -----------------------------------------------------------------------

    def describe(self, win=0.05):
        lines = ["%s: %.3f s, %d Hz" % (self.path or "<wav>", self.duration, self.rate)]
        for t0, t1, hz, dbfs in self.segments(win):
            lines.append("  %8.3f - %8.3f  %7.3f s  %s  %6.1f dBFS" % (
                t0, t1, t1 - t0, "silence   " if hz is None else "%7.1f Hz" % hz, dbfs))
        return "\n".join(lines)


# ---- module-level API ---------------------------------------------------------------------

def load(path):
    """Loads a WAV file (PCM 8/16/24/32 bit or float 32/64, any channel count, also one whose
    header was never finalised) -> Wav (mono float)."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("%s: not a RIFF/WAVE file" % path)
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = pos + 8
        if cid == b"fmt ":
            tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", data[body:body + 16])
            if tag == 0xFFFE and size >= 26:      # WAVE_FORMAT_EXTENSIBLE
                tag = struct.unpack("<H", data[body + 24:body + 26])[0]
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            end = body + size
            if size == 0 or size >= 0xFFFFFF00 or end > len(data):   # streamed / killed writer
                end = len(data)
            pcm = data[body:end]
            break
        pos = body + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError("%s: missing fmt or data chunk" % path)
    tag, channels, rate, bits = fmt
    width = bits // 8
    pcm = pcm[:len(pcm) - len(pcm) % (width * channels)]
    if tag == 1 and bits == 8:
        x = (np.frombuffer(pcm, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
    elif tag == 1 and bits == 16:
        x = np.frombuffer(pcm, dtype="<i2").astype(np.float64) / 32768.0
    elif tag == 1 and bits == 24:
        b = np.frombuffer(pcm, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = np.where(v >= 1 << 23, v - (1 << 24), v).astype(np.float64) / float(1 << 23)
    elif tag == 1 and bits == 32:
        x = np.frombuffer(pcm, dtype="<i4").astype(np.float64) / float(1 << 31)
    elif tag == 3 and bits in (32, 64):
        x = np.frombuffer(pcm, dtype="<f4" if bits == 32 else "<f8").astype(np.float64)
    else:
        raise ValueError("%s: unsupported WAV format tag %d, %d bits" % (path, tag, bits))
    t0 = None
    try:
        with open(path + ".json") as f:
            t0 = json.load(f).get("t0_epoch")
    except (OSError, ValueError):
        pass
    return Wav(x.reshape(-1, channels), rate, t0_epoch=t0, path=path)


def write_wav(path, samples, rate, channels=1):
    """Writes float samples (-1..1; interleaved if channels > 1) as 16-bit PCM."""
    pcm = (np.clip(np.asarray(samples, dtype=np.float64), -1, 1) * 32767.0).round().astype("<i2").tobytes()
    with open(path, "wb") as f:
        f.write(wav_header(len(pcm), rate, channels))
        f.write(pcm)


def wav_header(data_bytes, rate, channels, bits=16):
    align = channels * bits // 8
    return (b"RIFF" + struct.pack("<I", (36 + data_bytes) & 0xFFFFFFFF) + b"WAVEfmt " +
            struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * align, align, bits) +
            b"data" + struct.pack("<I", data_bytes & 0xFFFFFFFF))


def _wav(w):
    return w if isinstance(w, Wav) else load(w)


def segments(wav, win=0.05, **kw):
    return _wav(wav).segments(win, **kw)


def find_tone(wav, freq, tol_hz=10.0, **kw):
    return _wav(wav).find_tone(freq, tol_hz=tol_hz, **kw)


def assert_tone(wav, freq, min_dur, **kw):
    return _wav(wav).assert_tone(freq, min_dur, **kw)


def assert_no_tone(wav, freq, **kw):
    return _wav(wav).assert_no_tone(freq, **kw)


def assert_silence(wav, t0=None, t1=None, **kw):
    return _wav(wav).assert_silence(t0, t1, **kw)


def onsets(wav, **kw):
    return _wav(wav).onsets(**kw)


# ---- self test ----------------------------------------------------------------------------

def sine(freq, dur, rate=48000, amp=0.5, phase=0.0):
    t = np.arange(int(round(dur * rate))) / rate
    return amp * np.sin(2 * np.pi * freq * t + phase)


def selftest(verbose=True):
    import tempfile
    rate = 48000
    checks = []

    def check(name, cond, detail=""):
        checks.append((name, bool(cond)))
        if verbose or not cond:
            print("%s %s%s" % ("ok  " if cond else "FAIL", name, (": " + str(detail)) if detail else ""))

    def raises(fn):
        try:
            fn()
        except AssertionError:
            return True
        return False

    def near(a, b, tol):
        return a is not None and abs(a - b) <= tol

    # 1. pure tones: one segment, right frequency and level
    for freq, amp, r in ((440.0, 0.5, 48000), (1000.0, 0.1, 48000), (3000.0, 0.9, 44100), (82.4, 0.5, 48000)):
        w = Wav(sine(freq, 1.0, r, amp), r)
        segs = w.segments()
        level = 20 * math.log10(amp / math.sqrt(2))
        check("pure %.1f Hz amp %.1f @%d: one segment" % (freq, amp, r),
              len(segs) == 1 and near(segs[0][2], freq, 1.0) and near(segs[0][3], level, 0.3)
              and near(segs[0][1], 1.0, 1e-6), segs)
        iv = w.find_tone(freq)
        check("pure %.1f Hz: find_tone covers it" % freq,
              len(iv) == 1 and near(iv[0][0], 0.0, 0.015) and near(iv[0][1], 1.0, 0.015), iv)
        pk = w.peaks()
        check("pure %.1f Hz: peak level" % freq,
              len(pk) >= 1 and near(pk[0][0], freq, 0.5) and near(pk[0][1], 20 * math.log10(amp), 0.2), pk)

    # 2. silence, 440 Hz 1.0 s, 880 Hz 0.5 s, silence (the tone page), at an awkward offset
    x = np.concatenate([np.zeros(int(0.3137 * rate)), sine(440, 1.0, rate), sine(880, 0.5, rate),
                        np.zeros(int(0.4 * rate))])
    w = Wav(x, rate)
    segs = w.segments()
    kinds = [None if s[2] is None else int(round(s[2] / 10.0)) * 10 for s in segs]
    check("sequence: silence/440/880/silence", kinds == [None, 440, 880, None], segs)
    if kinds == [None, 440, 880, None]:
        check("sequence: segment boundaries within one window",
              near(segs[1][0], 0.3137, 0.05) and near(segs[2][0], 1.3137, 0.05) and near(segs[3][0], 1.8137, 0.05), segs)
    a, b = w.find_tone(440), w.find_tone(880)
    check("sequence: find_tone(440)", len(a) == 1 and near(a[0][0], 0.3137, 0.015) and near(a[0][1], 1.3137, 0.015), a)
    check("sequence: find_tone(880)", len(b) == 1 and near(b[0][0], 1.3137, 0.015) and near(b[0][1], 1.8137, 0.015), b)
    check("sequence: find_tone(660) empty", w.find_tone(660) == [], w.find_tone(660))
    check("sequence: find_tone(466) empty (a semitone off)", w.find_tone(466.16) == [], w.find_tone(466.16))
    check("sequence: assert_tone(440, 0.95) passes", not raises(lambda: w.assert_tone(440, 0.95)))
    check("sequence: assert_tone(440, 1.1) fails", raises(lambda: w.assert_tone(440, 1.1)))
    check("sequence: assert_tone(440, 0.5, t0=1.0) fails", raises(lambda: w.assert_tone(440, 0.5, t0=1.0)))
    check("sequence: assert_tone(660, 0.1) fails", raises(lambda: w.assert_tone(660, 0.1)))
    check("sequence: assert_no_tone(660) passes", not raises(lambda: w.assert_no_tone(660)))
    check("sequence: assert_no_tone(880) fails", raises(lambda: w.assert_no_tone(880)))
    check("sequence: assert_silence(0, 0.3) passes", not raises(lambda: w.assert_silence(0, 0.3)))
    check("sequence: assert_silence(1.9, end) passes", not raises(lambda: w.assert_silence(1.9, None)))
    check("sequence: assert_silence(0.2, 0.5) fails", raises(lambda: w.assert_silence(0.2, 0.5)))
    on = w.onsets()
    check("sequence: one onset within 1 ms", len(on) == 1 and near(on[0], 0.3137, 0.001), on)
    snd = w.sounds()
    check("sequence: sound ends within 1 ms", len(snd) == 1 and near(snd[0][1], 1.8137, 0.001), snd)

    # 2b. a tone that only just reaches into its first and out of its last window
    w = Wav(np.concatenate([np.zeros(int(0.346 * rate)), sine(440, 1.008, rate), np.zeros(rate // 2)]), rate)
    segs = w.segments()
    check("edges: no spurious segment at a tone's edges",
          len(segs) == 3 and segs[0][2] is None and near(segs[1][2], 440, 1.0) and segs[2][2] is None
          and near(segs[1][0], 0.346, 0.05) and near(segs[1][1], 1.354, 0.05) and near(segs[1][3], -9.03, 0.5), segs)

    # 3. silence: digital zero and a -80 dBFS noise floor
    rng = np.random.default_rng(1)
    for name, x in (("zeros", np.zeros(rate)), ("noise floor", rng.normal(0, 1e-4, rate))):
        w = Wav(x, rate)
        segs = w.segments()
        check("silence (%s): one silent segment" % name, len(segs) == 1 and segs[0][2] is None, segs)
        check("silence (%s): no tone, no onset" % name, w.find_tone(440) == [] and w.onsets() == [])
        check("silence (%s): assert_silence passes" % name, not raises(lambda: w.assert_silence()))
    check("empty file: no segments, no crash",
          Wav(np.zeros(0), rate).segments() == [] and Wav(np.zeros(0), rate).find_tone(440) == [])

    # 4. a chord (A major) between two silences: every note found, nothing else
    notes = (440.0, 554.37, 659.25)
    chord = sum(sine(f, 0.8, rate, 0.25, phase=i) for i, f in enumerate(notes))
    w = Wav(np.concatenate([np.zeros(rate // 5), chord, np.zeros(rate // 5)]), rate)
    for f in notes:
        iv = w.find_tone(f)
        check("chord: find_tone(%.2f)" % f, len(iv) == 1 and near(iv[0][0], 0.2, 0.015) and near(iv[0][1], 1.0, 0.015), iv)
    check("chord: find_tone(500) empty", w.find_tone(500) == [], w.find_tone(500))
    pk = w.peaks(0.25, 0.95)
    check("chord: three peaks at -12 dBFS", len(pk) == 3 and all(
        any(near(p[0], f, 1.0) and near(p[1], 20 * math.log10(0.25), 0.5) for p in pk) for f in notes), pk)
    # With notes of equal strength the dominant one changes from window to window, so
    # segments() splits a chord into pieces: each piece must still name one of the notes.
    segs = w.segments()
    sounding = [s for s in segs if s[2] is not None]
    check("chord: every sounding segment names one of the notes",
          segs[0][2] is None and segs[-1][2] is None and sounding
          and near(sounding[0][0], 0.2, 0.05) and near(sounding[-1][1], 1.0, 0.05)
          and all(any(near(s[2], f, 3.0) for f in notes) for s in sounding), segs)

    # 5. a quiet tone in noise, and two bursts
    w = Wav(sine(1000, 1.0, rate, 0.1) + rng.normal(0, 0.003, rate), rate)
    iv = w.find_tone(1000)
    check("tone in noise: found", len(iv) == 1 and iv[0][1] - iv[0][0] > 0.95, iv)
    w = Wav(np.concatenate([np.zeros(4800), sine(660, 0.2, rate), np.zeros(9600), sine(660, 0.2, rate), np.zeros(4800)]), rate)
    check("two bursts: two onsets, two intervals",
          len(w.onsets()) == 2 and near(w.onsets()[1], 0.5, 0.001) and len(w.find_tone(660)) == 2,
          (w.onsets(), w.find_tone(660)))

    x = sine(660, 1.0, rate)
    x[int(0.5 * rate):int(0.56 * rate)] = 0          # a 60 ms dropout
    w = Wav(x, rate)
    check("dropout: strict assert_tone fails, max_gap=0.1 passes",
          len(w.find_tone(660)) == 2 and raises(lambda: w.assert_tone(660, 0.9))
          and not raises(lambda: w.assert_tone(660, 0.9, max_gap=0.1)), w.find_tone(660))

    # 6. WAV files: 16-bit stereo round trip, 44.1 kHz, a header that was never finalised, sidecar
    with tempfile.TemporaryDirectory() as d:
        mono = np.concatenate([np.zeros(4410), sine(440, 0.5, 44100)])
        p = os.path.join(d, "a.wav")
        write_wav(p, np.repeat(mono, 2), 44100, channels=2)
        w = load(p)
        check("wav: stereo 44.1 kHz round trip", w.rate == 44100 and len(w.x) == len(mono)
              and float(np.abs(w.x - mono).max()) < 1e-4 and len(w.find_tone(440)) == 1)
        with open(p, "rb") as f:
            raw = bytearray(f.read())
        raw[4:8] = b"\0\0\0\0"
        raw[40:44] = b"\0\0\0\0"
        q = os.path.join(d, "b.wav")
        with open(q, "wb") as f:
            f.write(raw)
        with open(q + ".json", "w") as f:
            json.dump({"t0_epoch": 1000.5}, f)
        w = load(q)
        check("wav: unfinalised header still loads", len(w.x) == len(mono))
        check("wav: sidecar timestamp", w.t0_epoch == 1000.5 and w.epoch(0.25) == 1000.75)
        check("wav: module-level functions take a path",
              len(find_tone(p, 440)) == 1 and len(segments(p)) == 2 and len(onsets(p)) == 1)

    failed = [n for n, ok in checks if not ok]
    print("analyze.py selftest: %d checks, %d failed" % (len(checks), len(failed)))
    return not failed


# ---- CLI ----------------------------------------------------------------------------------

def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Tone / silence analysis of a WAV capture.")
    ap.add_argument("wav", nargs="?")
    ap.add_argument("--selftest", action="store_true", help="run the built-in tests on synthetic signals")
    ap.add_argument("--win", type=float, default=0.05, help="analysis window in seconds (default 0.05)")
    ap.add_argument("--json", action="store_true", help="print segments, onsets and results as JSON")
    ap.add_argument("--tone", action="append", default=[], metavar="HZ:MIN_DUR",
                    help="assert a tone of at least MIN_DUR seconds (repeatable)")
    ap.add_argument("--no-tone", action="append", default=[], metavar="HZ", help="assert the tone is absent")
    ap.add_argument("--silence", action="append", default=[], metavar="T0:T1",
                    help="assert silence between T0 and T1 seconds (either may be empty)")
    ap.add_argument("--tol-hz", type=float, default=10.0)
    args = ap.parse_args(argv)
    if args.selftest:
        return 0 if selftest() else 1
    if not args.wav:
        ap.error("a WAV file or --selftest is required")
    wav = load(args.wav)
    result = {"file": args.wav, "duration": wav.duration, "rate": wav.rate, "t0_epoch": wav.t0_epoch,
              "segments": [list(s) for s in wav.segments(args.win)], "onsets": wav.onsets(),
              "tones": {}, "failures": []}
    for spec in args.tone:
        hz, _, dur = spec.partition(":")
        try:
            result["tones"][hz] = list(wav.assert_tone(float(hz), float(dur or 0.1), tol_hz=args.tol_hz, win=args.win))
        except AssertionError as e:
            result["failures"].append(str(e).split("\n")[0])
    for hz in args.no_tone:
        try:
            wav.assert_no_tone(float(hz), tol_hz=args.tol_hz, win=args.win)
        except AssertionError as e:
            result["failures"].append(str(e).split("\n")[0])
    for spec in args.silence:
        a, _, b = spec.partition(":")
        try:
            wav.assert_silence(float(a) if a else None, float(b) if b else None)
        except AssertionError as e:
            result["failures"].append(str(e).split("\n")[0])
    if args.json:
        print(json.dumps(result))
    else:
        print(wav.describe(args.win))
        print("onsets: " + (", ".join("%.3f" % t for t in result["onsets"]) or "none"))
        for hz, iv in result["tones"].items():
            print("tone %s Hz: %.3f - %.3f (%.3f s)" % (hz, iv[0], iv[1], iv[1] - iv[0]))
        for f in result["failures"]:
            print("FAIL: " + f)
    return 1 if result["failures"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
