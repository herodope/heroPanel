#!/usr/bin/env python3
"""Generate heroPanel's glyph textures.

heroPanel needs the lock, caret and check in the exact colours the design
fixes, and a tint cannot get there from Blizzard's art: SetVertexColor
multiplies, so a gold padlock tinted #75798C comes out muted gold. Drawing the
glyphs from solid blocks solves the colour and loses the quality - a staircase
of 2px blocks rendered at eight device pixels reads as Lego.

So the shapes are rasterised here into white, anti-aliased alpha masks. White
tints exactly, the alpha carries the shape, and the client does the filtering.
The design handoff allows "a simple included texture set"; this is it.

Output: 32x32 uncompressed 32-bit TGA, which is what a 3.3.5a client reads.
Dimensions must stay powers of two.

    python tools/glyphgen/glyphgen.py

Re-run after editing a shape. The addon falls back to its block glyphs if these
files are missing or the client cannot read them, so a bad run degrades to the
previous look rather than to nothing.
"""

import math
import os
import struct

SIZE = 64           # texture edge, power of two
SS = 4              # supersampling factor per axis
DESIGN = 32.0       # shapes are authored in this space and scaled to SIZE
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "heroPanel", "media")


# ---------------------------------------------------------------------------
# Distance helpers. Everything is drawn as a stroked path, so coverage is just
# "is this sample within half a stroke width of the path".
# ---------------------------------------------------------------------------

def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    if length == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dist_to_arc(px, py, cx, cy, radius, start_deg, end_deg):
    """Distance to a circular arc, measuring angles clockwise from due left.

    Outside the sweep the nearest endpoint wins, which gives the arc round
    caps for free and keeps the shackle joining the lock body cleanly.
    """
    angle = math.degrees(math.atan2(-(py - cy), px - cx)) % 360
    lo, hi = start_deg % 360, end_deg % 360
    inside = (lo <= angle <= hi) if lo <= hi else (angle >= lo or angle <= hi)
    if inside:
        return abs(math.hypot(px - cx, py - cy) - radius)

    best = None
    for deg in (start_deg, end_deg):
        ax = cx + radius * math.cos(math.radians(deg))
        ay = cy - radius * math.sin(math.radians(deg))
        d = math.hypot(px - ax, py - ay)
        best = d if best is None else min(best, d)
    return best


def dist_to_round_rect(px, py, x0, y0, x1, y1, radius):
    """Signed distance to a rounded rectangle; negative inside."""
    hw, hh = (x1 - x0) / 2.0 - radius, (y1 - y0) / 2.0 - radius
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    dx, dy = abs(px - cx) - hw, abs(py - cy) - hh
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    return outside + min(max(dx, dy), 0.0) - radius


# ---------------------------------------------------------------------------
# Shapes. Each returns the signed distance to the shape at a point, negative
# inside, in a 32x32 space with y running downwards.
# ---------------------------------------------------------------------------

# The line-drawn glyphs fill the canvas as far as their stroke allows, because
# the canvas maps to the whole glyph frame: a shape drawn across half of it is
# a shape rendered at half the size it was asked for. That cost the caret most -
# a chevron is wide and shallow, so a timid one ended up about three device
# pixels tall. Strokes are heavy for the same reason; a hairline does not
# survive the downscale to roughly ten device pixels.
CARET_STROKE = 4.2
CHECK_STROKE = 4.0


def caret(px, py):
    """Chevron pointing up. Flipped vertically by the addon for 'collapsed'."""
    d = min(
        dist_to_segment(px, py, 3.2, 21.5, 16.0, 9.5),
        dist_to_segment(px, py, 16.0, 9.5, 28.8, 21.5),
    )
    return d - CARET_STROKE / 2.0


def check(px, py):
    """Tick: a short arm down and a long arm up, which is what makes it a
    check rather than a V."""
    d = min(
        dist_to_segment(px, py, 3.5, 16.5, 12.0, 25.0),
        dist_to_segment(px, py, 12.0, 25.0, 28.5, 7.5),
    )
    return d - CHECK_STROKE / 2.0


def _lock_body(px, py):
    return dist_to_round_rect(px, py, 7.0, 15.0, 25.0, 27.0, 2.5)


def lock_closed(px, py):
    shackle = dist_to_arc(px, py, 16.0, 15.0, 5.5, 0, 180) - 2.6 / 2.0
    legs = min(
        dist_to_segment(px, py, 10.5, 15.0, 10.5, 16.0),
        dist_to_segment(px, py, 21.5, 15.0, 21.5, 16.0),
    ) - 2.6 / 2.0
    return min(_lock_body(px, py), shackle, legs)


def lock_open(px, py):
    # The shackle stays attached on the right and its left side is gone
    # entirely, leaving a hook. A shackle merely lifted or shifted is the
    # honest drawing of an open padlock and it is illegible here: these render
    # at roughly eight device pixels, where a two-pixel gap is nothing. The
    # difference between a closed U and an open hook survives that.
    shackle = dist_to_arc(px, py, 16.0, 14.0, 5.5, 0, 135) - 2.6 / 2.0
    leg = dist_to_segment(px, py, 21.5, 14.0, 21.5, 16.0) - 2.6 / 2.0
    return min(_lock_body(px, py), shackle, leg)


SHAPES = {
    "caret": caret,
    "check": check,
    "lock-closed": lock_closed,
    "lock-open": lock_open,
}


# ---------------------------------------------------------------------------
# Rasterise and write
# ---------------------------------------------------------------------------

def rasterise(shape):
    """Supersampled coverage, 0-255 per pixel.

    Sample coordinates are mapped back into the 32-unit design space, so the
    texture can be made larger without touching a single shape coordinate.
    """
    alpha = []
    scale = SIZE / DESIGN
    step = 1.0 / SS
    offset = step / 2.0
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            hits = 0
            for sy in range(SS):
                py = (y + offset + sy * step) / scale
                for sx in range(SS):
                    px = (x + offset + sx * step) / scale
                    if shape(px, py) <= 0.0:
                        hits += 1
            row.append(int(round(255.0 * hits / (SS * SS))))
        alpha.append(row)
    return alpha


def _halve(alpha, width, height):
    """Box-filter an alpha plane down to half size, rounding to nearest."""
    new_w, new_h = max(1, width // 2), max(1, height // 2)
    out = []
    for y in range(new_h):
        row = []
        for x in range(new_w):
            total = 0
            for dy in range(2):
                sy = min(height - 1, y * 2 + dy)
                for dx in range(2):
                    sx = min(width - 1, x * 2 + dx)
                    total += alpha[sy][sx]
            row.append((total + 2) // 4)
        out.append(row)
    return out, new_w, new_h


def write_blp(path, alpha):
    """Palettised BLP2 with an 8-bit alpha channel and a full mip chain.

    BLP is what a 3.3.5a client reads natively; the TGA beside it does not load
    on the Ascension client at all, which is what sent the glyphs to their
    block fallback.

    Palettised suits this art exactly. The glyphs are white throughout and the
    shape lives entirely in the alpha channel, so one palette entry is enough
    and every index points at it - lossless here, which it would not be for
    anything with real colour in it.

    The mip chain is not optional in practice. A single-level BLP is a
    structurally valid file that this client accepts and then declines to
    decode, drawing its missing-texture green instead - which looks like a
    broken glyph rather than a rejected file.
    """
    levels = []
    level, width, height = alpha, SIZE, SIZE
    while True:
        levels.append((level, width, height))
        if width == 1 and height == 1:
            break
        level, width, height = _halve(level, width, height)

    offsets, sizes, blobs = [], [], []
    cursor = 148 + 1024                         # header, then the palette
    for level, width, height in levels:
        # One index byte and one alpha byte per pixel; every index is entry 0.
        blob = bytes(width * height)
        alphas = bytearray()
        for y in range(height):
            for x in range(width):
                alphas.append(level[y][x])
        blob = blob + bytes(alphas)

        offsets.append(cursor)
        sizes.append(len(blob))
        blobs.append(blob)
        cursor += len(blob)

    while len(offsets) < 16:
        offsets.append(0)
        sizes.append(0)

    header = bytearray()
    header += b"BLP2"
    header += struct.pack("<I", 1)              # uncompressed, not JPEG
    header += struct.pack("<BBBB", 1, 8, 0, 1)  # palettised, 8-bit alpha, -, has mips
    header += struct.pack("<II", SIZE, SIZE)
    header += struct.pack("<16I", *offsets)
    header += struct.pack("<16I", *sizes)

    palette = bytearray()
    palette += struct.pack("<BBBB", 255, 255, 255, 255)   # BGRA: white
    palette += bytes(4 * 255)                             # the rest unused

    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(palette)
        for blob in blobs:
            handle.write(blob)


def _rle_scanline(row):
    """RLE-encode one scanline of BGRA pixels into TGA packets.

    Runs never cross a scanline boundary. The spec allows it; decoders vary on
    whether they cope, and there is nothing to gain here by finding out.
    """
    out = bytearray()
    i, count = 0, len(row)
    while i < count:
        run = 1
        while (run < 128 and i + run < count and row[i + run] == row[i]):
            run += 1

        if run >= 2:
            out.append(0x80 | (run - 1))        # RLE packet: one pixel, repeated
            out += row[i]
            i += run
            continue

        # Raw packet: literal pixels up to the next run of two or more.
        start = i
        while (i - start < 128 and i < count
               and not (i + 1 < count and row[i + 1] == row[i])):
            i += 1
        if i == start:                          # never emit an empty packet
            i = start + 1
        out.append((i - start) - 1)
        for pixel in row[start:i]:
            out += pixel

    return out


def write_tga(path, alpha):
    """32-bit BGRA TGA with RLE compression, bottom-left origin.

    RLE rather than uncompressed on purpose. The uncompressed file is a valid
    TGA that this client will not load, and 32-bit-with-RLE is the format WoW
    addons have always shipped. Nothing else about the file changes.

    The header is kept minimal - no image ID, no colour map, no extension area
    or footer - since those trailing fields are the known source of TGAs that
    other tools write and WoW rejects.
    """
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,          # no image id
        0,          # no colour map
        10,         # run-length encoded true-colour
        0, 0, 0,    # colour map spec
        0, 0,       # origin
        SIZE, SIZE,
        32,         # bits per pixel
        8,          # descriptor: 8 alpha bits, origin bottom-left
    )

    body = bytearray()
    for y in range(SIZE - 1, -1, -1):
        # White where the glyph is drawn, so SetVertexColor lands on the exact
        # colour; the alpha channel carries the shape.
        #
        # Fully transparent pixels are black rather than white, which is the
        # convention every texture this client loads uses - checked, not
        # assumed. It costs nothing and removes one more way in which these
        # files are not like the ones known to work.
        row = [bytes((255, 255, 255, alpha[y][x])) if alpha[y][x] else bytes((0, 0, 0, 0))
               for x in range(SIZE)]
        body += _rle_scanline(row)

    # TGA 2.0 footer, with both optional areas absent. Not required by the
    # format, and this file is a valid TGA 1.0 without it - but the textures
    # this client is known to load carry it, so there is no reason to be the
    # one file that does not.
    footer = struct.pack("<II", 0, 0) + b"TRUEVISION-XFILE." + b"\x00"

    with open(path, "wb") as handle:
        handle.write(header)
        handle.write(body)
        handle.write(footer)


def main():
    out = os.path.normpath(OUT)
    if not os.path.isdir(out):
        os.makedirs(out)

    # TGA only.
    #
    # A hand-written .blp used to be written alongside each one. It never
    # decoded - the client drew its missing-texture green for it - so it was
    # dropped. Whether it was also what broke the .tga was never established:
    # it was removed in the same round as two other changes, and the glyphs
    # started working. Do not read a root cause into that; there isn't one on
    # record.
    for name, shape in sorted(SHAPES.items()):
        path = os.path.join(out, name + ".tga")
        write_tga(path, rasterise(shape))
        print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))


if __name__ == "__main__":
    main()
