#!/usr/bin/env python3
"""Generate Raccoon's AppIcon: a graphite rounded-square tile with a centered
monochrome raccoon-mask silhouette + a thin amber (#C8841E) eye-shine.

Pure-stdlib PNG writer (no PIL). Renders one high-res master via supersampled
software rasterization, then `sips` is used by the caller to downscale to all
macOS sizes and `iconutil` to assemble the .icns / appiconset.

Design (normalized 0..1 coords on the tile):
  - tile fill: warm graphite #1D1C1A, rounded-square (continuous-ish) corners
  - raccoon "mask": a soft dark band across the eyes with two eye holes; the
    classic bandit mask reads instantly at small sizes. Rendered slightly
    lighter than the tile (#2A2825) so it's visible but stays monochrome.
  - eye-shine: two thin amber arcs / dots (#C8841E) — the single chromatic accent.
"""
import struct
import zlib
import math
import sys

# --- geometry / palette -------------------------------------------------------
TILE = (0x1D, 0x1C, 0x1A)      # warm graphite
MASK = (0x2E, 0x2B, 0x27)      # mask band, a touch lighter than tile
MASK_EDGE = (0x38, 0x34, 0x2F) # subtle mask rim
AMBER = (0xC8, 0x84, 0x1E)     # eye-shine (the one chromatic color)
AMBER_HI = (0xE0, 0xA8, 0x48)  # eye-shine highlight


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def render(master=1024, ss=2):
    """Render at master*ss then box-downsample by ss for cheap antialiasing."""
    W = master * ss
    H = master * ss
    # RGBA buffer
    buf = bytearray(W * H * 4)

    cx, cy = W / 2.0, H / 2.0
    # rounded-square mask: superellipse-ish via rounded rect with radius
    margin = 0.085 * W          # transparent margin so the tile isn't edge-to-edge
    radius = 0.225 * W          # corner radius (macOS squircle vibe)
    x0, y0 = margin, margin
    x1, y1 = W - margin, H - margin

    def coverage_round_rect(px, py):
        # signed distance for a rounded rectangle:
        # shrink rect by radius, compute distance to that inner rect, subtract r
        ix0, iy0, ix1, iy1 = x0 + radius, y0 + radius, x1 - radius, y1 - radius
        ddx = max(ix0 - px, 0.0, px - ix1)
        ddy = max(iy0 - py, 0.0, py - iy1)
        dist = math.hypot(ddx, ddy) - radius
        # inside if dist < 0
        aa = 1.5 * ss
        return max(0.0, min(1.0, 0.5 - dist / aa))

    # mask band ellipse params (the bandit mask across the eyes)
    mask_cy = cy - 0.02 * H
    mask_w = 0.62 * W          # half-width
    mask_h = 0.20 * H          # half-height

    def in_mask(px, py):
        nx = (px - cx) / mask_w
        ny = (py - mask_cy) / mask_h
        d = nx * nx + ny * ny
        aa = 0.06
        return max(0.0, min(1.0, (1.0 - d) / aa + 0.5))

    # two eyes
    eye_dx = 0.215 * W
    eye_cy = mask_cy + 0.005 * H
    eye_r = 0.085 * W

    def eye_cov(px, py, sign):
        ex = cx + sign * eye_dx
        d = math.hypot(px - ex, py - eye_cy) - eye_r
        aa = 1.5 * ss
        return max(0.0, min(1.0, 0.5 - d / aa))

    def eyeshine_cov(px, py, sign):
        # thin amber crescent: ring just inside the eye, brighter on upper-left
        ex = cx + sign * eye_dx
        dd = math.hypot(px - ex, py - eye_cy)
        ring_r = eye_r * 0.62
        thick = eye_r * 0.20
        ring = 1.0 - min(1.0, abs(dd - ring_r) / thick)
        if ring <= 0:
            return 0.0, 0.0
        # emphasize upper portion for a "shine"
        ang = math.atan2(eye_cy - py, px - ex)
        hi = max(0.0, math.cos(ang - math.radians(120)))
        return ring, hi

    for y in range(H):
        py = y + 0.5
        row = y * W * 4
        for x in range(W):
            px = x + 0.5
            a = coverage_round_rect(px, py)
            if a <= 0.0:
                continue  # leave transparent
            # base tile
            r, g, b = TILE
            # mask band
            m = in_mask(px, py)
            if m > 0.0:
                mb = lerp(TILE, MASK, m)
                r, g, b = mb
            # eye holes (darker than mask)
            for sign in (-1, 1):
                ec = eye_cov(px, py, sign)
                if ec > 0.0:
                    dark = lerp((r, g, b), (0x12, 0x11, 0x10), ec)
                    r, g, b = dark
                shine, hi = eyeshine_cov(px, py, sign)
                if shine > 0.0:
                    amb = lerp(AMBER, AMBER_HI, hi)
                    t = shine
                    r, g, b = lerp((r, g, b), amb, t * 0.95)
            off = row + x * 4
            buf[off + 0] = r
            buf[off + 1] = g
            buf[off + 2] = b
            buf[off + 3] = int(round(255 * a))

    # downsample ss x ss -> master
    out = bytearray(master * master * 4)
    for oy in range(master):
        for ox in range(master):
            ar = ag = ab = aa = 0
            for dy in range(ss):
                for dx in range(ss):
                    sxi = ox * ss + dx
                    syi = oy * ss + dy
                    o = (syi * W + sxi) * 4
                    al = buf[o + 3]
                    ar += buf[o + 0] * al
                    ag += buf[o + 1] * al
                    ab += buf[o + 2] * al
                    aa += al
            oo = (oy * master + ox) * 4
            if aa == 0:
                out[oo + 0] = out[oo + 1] = out[oo + 2] = 0
                out[oo + 3] = 0
            else:
                out[oo + 0] = ar // aa
                out[oo + 1] = ag // aa
                out[oo + 2] = ab // aa
                out[oo + 3] = aa // (ss * ss)
    return master, master, bytes(out)


def write_png(path, w, h, rgba):
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        raw.extend(rgba[y * w * 4:(y + 1) * w * 4])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raccoon_master.png"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    w, h, rgba = render(master=size, ss=2)
    write_png(out_path, w, h, rgba)
    print("wrote", out_path, w, "x", h)
