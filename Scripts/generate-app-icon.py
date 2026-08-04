#!/usr/bin/env python3
"""Renders the PRV Beauty app icon straight from the design-system palette.

The icon is generated rather than hand-drawn so it can never drift from the
brand: the gradient endpoints are the same values as `Color.prv.accent` and
`Color.prv.accentSecondary` in Sources/PRVDesignSystem/Tokens.swift. Re-run
after changing those tokens.

Only the standard library is used — PNG is written with zlib directly, so the
script has no dependency to install.

Usage: Scripts/generate-app-icon.py [output.png] [size]
"""

import math
import struct
import sys
import zlib

# Sources/PRVDesignSystem/Tokens.swift — PRVColors.accent / .accentSecondary
ACCENT = (0.78, 0.35, 0.56)
ACCENT_SECONDARY = (0.94, 0.62, 0.48)


def srgb(channel: float) -> int:
    """Clamps a 0…1 component to a byte."""
    return max(0, min(255, round(channel * 255)))


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    """Hermite interpolation, for antialiased edges without supersampling."""
    if edge0 == edge1:
        return 0.0 if x < edge0 else 1.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def sparkle_coverage(nx: float, ny: float, radius: float, softness: float) -> float:
    """Coverage of a four-point sparkle (an astroid) at a normalized point.

    The astroid |x|^(2/3) + |y|^(2/3) = r gives the concave-sided star Apple's
    `sparkles` symbol suggests, which reads far better at small sizes than a
    straight-edged five-point star.
    """
    ax, ay = abs(nx), abs(ny)
    if ax < 1e-6 and ay < 1e-6:
        return 1.0
    value = ax ** (2 / 3) + ay ** (2 / 3)
    return 1.0 - smoothstep(radius - softness, radius + softness, value)


def render(size: int) -> bytes:
    """Renders the icon as raw RGB rows."""
    rows = bytearray()
    centre = (size - 1) / 2
    # A sparkle sized to sit comfortably inside the iOS icon mask.
    main_radius = 0.62
    softness = 1.6 / size * 6

    for y in range(size):
        rows.append(0)  # PNG filter type 0 (None) per scanline
        for x in range(size):
            # Diagonal brand gradient, top-leading to bottom-trailing.
            t = (x / (size - 1) + y / (size - 1)) / 2
            r = ACCENT[0] + (ACCENT_SECONDARY[0] - ACCENT[0]) * t
            g = ACCENT[1] + (ACCENT_SECONDARY[1] - ACCENT[1]) * t
            b = ACCENT[2] + (ACCENT_SECONDARY[2] - ACCENT[2]) * t

            # A soft radial lift behind the mark gives the flat gradient the
            # same sense of depth the Liquid Glass surfaces have.
            dx, dy = (x - centre) / centre, (y - centre) / centre
            glow = max(0.0, 1.0 - math.sqrt(dx * dx + dy * dy)) ** 2 * 0.14
            r, g, b = r + glow, g + glow, b + glow

            # Primary sparkle, plus a small companion — the pairing Apple's
            # own `sparkles` glyph uses.
            coverage = sparkle_coverage(dx / 0.78, dy / 0.78, main_radius, softness)
            companion = sparkle_coverage(
                (dx - 0.46) / 0.26, (dy + 0.44) / 0.26, main_radius, softness * 2.2
            )
            mark = max(coverage, companion * 0.9)

            if mark > 0:
                r = r + (1.0 - r) * mark
                g = g + (1.0 - g) * mark
                b = b + (1.0 - b) * mark

            rows.extend((srgb(r), srgb(g), srgb(b)))
    return bytes(rows)


def chunk(tag: bytes, payload: bytes) -> bytes:
    """One PNG chunk: length, type, payload, CRC."""
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def write_png(path: str, size: int) -> None:
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # 8-bit truecolour
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(render(size), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(png)


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png"
    dimension = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    write_png(output, dimension)
    print(f"wrote {output} ({dimension}×{dimension})")
