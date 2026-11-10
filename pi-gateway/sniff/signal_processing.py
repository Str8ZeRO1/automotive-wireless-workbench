"""
DSP primitives for the sub-GHz / TPMS sniffing pipeline:
  - Butterworth low-pass filter (envelope smoothing on the magnitude stream)
  - Otsu's method (adaptive binary threshold -> OOK bitstream)
  - Microsecond pulse-width parser (bitstream -> list of (level, duration_us))

These operate on plain lists/arrays of floats so they have no hard dependency
on numpy being present on a stripped-down Pi Zero image, though numpy is used
when available for speed. Pure-Python fallback paths are provided.
"""
from __future__ import annotations

from dataclasses import dataclass

try:
    import numpy as np

    _HAVE_NUMPY = True
except ImportError:  # pragma: no cover - Pi Zero images without numpy
    _HAVE_NUMPY = False


@dataclass(slots=True)
class Pulse:
    """One run-length-encoded pulse: level is True for 'high' (carrier
    present), False for 'low' (gap). duration_us is the run length in
    microseconds given the sample rate used to capture it."""

    level: bool
    duration_us: float


def butterworth_lowpass_coeffs(cutoff_hz: float, sample_rate_hz: float, order: int = 2) -> tuple[list[float], list[float]]:
    """
    Compute 2nd-order (or cascaded biquad for higher even orders) Butterworth
    low-pass filter coefficients via the bilinear transform. Returns (b, a)
    numerator/denominator coefficients for a direct-form-II filter.

    Implemented from first principles (no scipy dependency) since scipy is
    too heavy for a Pi Zero's limited RAM/flash.
    """
    if order % 2 != 0:
        raise ValueError("This implementation supports even filter orders only (cascaded biquads)")

    import math

    nyquist = sample_rate_hz / 2.0
    normalized_cutoff = cutoff_hz / nyquist
    if not (0.0 < normalized_cutoff < 1.0):
        raise ValueError(f"cutoff_hz={cutoff_hz} must be between 0 and Nyquist ({nyquist} Hz)")

    # Pre-warp the cutoff frequency for the bilinear transform.
    warped = math.tan(math.pi * normalized_cutoff / 2.0)

    n_biquads = order // 2
    b_total = [1.0]
    a_total = [1.0]

    for k in range(n_biquads):
        # Butterworth pole angle for this biquad section (analog prototype
        # pole pair at angle theta on the unit circle), then bilinear-
        # transformed to a digital biquad using the pre-warped cutoff.
        theta = math.pi * (2 * k + 1) / (2 * order)
        k2 = warped * warped
        norm = 1.0 / (1.0 + 2.0 * warped * math.sin(theta) + k2)
        b0 = k2 * norm
        b1 = 2.0 * b0
        b2 = b0
        a1 = 2.0 * (k2 - 1.0) * norm
        a2 = (1.0 - 2.0 * warped * math.sin(theta) + k2) * norm

        b_total = _poly_mul(b_total, [b0, b1, b2])
        a_total = _poly_mul(a_total, [1.0, a1, a2])

    return b_total, a_total


def _poly_mul(p: list[float], q: list[float]) -> list[float]:
    result = [0.0] * (len(p) + len(q) - 1)
    for i, pi in enumerate(p):
        for j, qj in enumerate(q):
            result[i + j] += pi * qj
    return result


def apply_iir_filter(signal: list[float], b: list[float], a: list[float]) -> list[float]:
    """Direct-form-II transposed IIR filter application, matching the shape
    of scipy.signal.lfilter's output for the same (b, a). a[0] is assumed
    normalized to 1.0 (true for our Butterworth coefficients above)."""
    if _HAVE_NUMPY:
        sig = np.asarray(signal, dtype=np.float64)
        b_arr = np.asarray(b, dtype=np.float64)
        a_arr = np.asarray(a, dtype=np.float64)
        n = max(len(b_arr), len(a_arr))
        z = np.zeros(n - 1)
        out = np.empty_like(sig)
        b_pad = np.pad(b_arr, (0, n - len(b_arr)))
        a_pad = np.pad(a_arr, (0, n - len(a_arr)))
        for i, x in enumerate(sig):
            y = b_pad[0] * x + z[0]
            z[:-1] = z[1:] + b_pad[1:-1] * x - a_pad[1:-1] * y
            z[-1] = b_pad[-1] * x - a_pad[-1] * y
            out[i] = y
        return out.tolist()

    # Pure-Python fallback.
    n = max(len(b), len(a))
    b_pad = b + [0.0] * (n - len(b))
    a_pad = a + [0.0] * (n - len(a))
    z = [0.0] * (n - 1)
    out: list[float] = []
    for x in signal:
        y = b_pad[0] * x + (z[0] if z else 0.0)
        new_z = []
        for i in range(n - 1):
            z_next = (z[i + 1] if i + 1 < len(z) else 0.0) + b_pad[i + 1] * x - a_pad[i + 1] * y
            new_z.append(z_next)
        z = new_z
        out.append(y)
    return out


def otsu_threshold(values: list[float], bins: int = 256) -> float:
    """
    Compute Otsu's adaptive threshold for a 1-D sample of envelope
    magnitudes, separating 'carrier present' from 'carrier absent' samples
    without a hand-tuned fixed threshold (which drifts with RF gain/AGC).
    """
    if not values:
        return 0.0
    lo, hi = min(values), max(values)
    if hi <= lo:
        return lo

    hist = [0] * bins
    scale = (bins - 1) / (hi - lo)
    for v in values:
        idx = int((v - lo) * scale)
        hist[idx] += 1

    total = len(values)
    sum_total = sum(i * h for i, h in enumerate(hist))

    sum_bg = 0.0
    weight_bg = 0
    best_variance = -1.0
    best_bin = 0

    for i, h in enumerate(hist):
        weight_bg += h
        if weight_bg == 0:
            continue
        weight_fg = total - weight_bg
        if weight_fg == 0:
            break
        sum_bg += i * h
        mean_bg = sum_bg / weight_bg
        mean_fg = (sum_total - sum_bg) / weight_fg
        between_class_variance = weight_bg * weight_fg * (mean_bg - mean_fg) ** 2
        if between_class_variance > best_variance:
            best_variance = between_class_variance
            best_bin = i

    # best_bin is the last bin assigned to the "background" class; the
    # separating threshold sits at that bin's upper edge (+0.5), not its
    # lower edge, so that envelope_to_bitstream's `v >= threshold` correctly
    # routes background-class samples (including ones at the low cluster's
    # own value) below the line instead of classifying everything as high.
    return lo + (best_bin + 0.5) / scale


def envelope_to_bitstream(envelope: list[float], threshold: float) -> list[bool]:
    """Binarize a filtered envelope against an Otsu threshold."""
    return [v >= threshold for v in envelope]


def bitstream_to_pulses(bitstream: list[bool], sample_period_us: float) -> list[Pulse]:
    """Run-length encode a binary bitstream into (level, duration_us) pulses."""
    if not bitstream:
        return []
    pulses: list[Pulse] = []
    current_level = bitstream[0]
    run_length = 1
    for bit in bitstream[1:]:
        if bit == current_level:
            run_length += 1
        else:
            pulses.append(Pulse(level=current_level, duration_us=run_length * sample_period_us))
            current_level = bit
            run_length = 1
    pulses.append(Pulse(level=current_level, duration_us=run_length * sample_period_us))
    return pulses


def process_envelope_to_pulses(
    raw_envelope: list[float],
    sample_rate_hz: float,
    lowpass_cutoff_hz: float = 20_000.0,
    filter_order: int = 2,
) -> list[Pulse]:
    """
    Full pipeline: raw magnitude envelope -> Butterworth low-pass ->
    Otsu threshold -> bitstream -> run-length pulse list.

    This is the shared primitive the ingestion daemon calls per RF buffer;
    it is pure/stateless so it's trivially unit-testable without hardware.
    """
    b, a = butterworth_lowpass_coeffs(lowpass_cutoff_hz, sample_rate_hz, order=filter_order)
    filtered = apply_iir_filter(raw_envelope, b, a)
    threshold = otsu_threshold(filtered)
    bitstream = envelope_to_bitstream(filtered, threshold)
    sample_period_us = 1_000_000.0 / sample_rate_hz
    return bitstream_to_pulses(bitstream, sample_period_us)
