#!/usr/bin/env python3
"""Generates ios/Assets.xcassets/AppIcon.appiconset/icon-1024.png: an original night-road picture (a neon-edged
road running into a city skyline under a magenta horizon glow). Pure PIL + numpy, deterministic (fixed seed), no
external artwork. Run:  python3 ios/make_icon.py"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
S = 2                      # supersampling factor
W = 1024 * S
HZ = int(0.56 * W)         # horizon line
VP = (W // 2, HZ)          # vanishing point

def lerp(a, b, t):
    return a + (b - a) * t

def vgrad(h, stops):
    """Vertical gradient (h,3) float from [(pos 0..1, (r,g,b)), ...]."""
    t = np.linspace(0, 1, h)
    out = np.zeros((h, 3))
    for c in range(3):
        out[:, c] = np.interp(t, [p for p, _ in stops], [col[c] for _, col in stops])
    return out

# --- sky and ground -------------------------------------------------------------------------------------------
img = np.zeros((W, W, 3))
sky = vgrad(HZ, [(0.0, (6, 4, 28)), (0.55, (44, 10, 84)), (0.85, (150, 24, 120)), (1.0, (255, 92, 120))])
ground = vgrad(W - HZ, [(0.0, (30, 8, 48)), (0.12, (12, 8, 26)), (1.0, (5, 4, 12))])
img[:HZ] = sky[:, None, :]
img[HZ:] = ground[:, None, :]

# horizon glow: a wide soft ellipse of warm light centred on the vanishing point
yy, xx = np.mgrid[0:W, 0:W]
d = np.sqrt(((xx - VP[0]) / (0.62 * W)) ** 2 + ((yy - HZ) / (0.30 * W)) ** 2)
glow = np.clip(1.0 - d, 0, 1) ** 2.2
img += glow[..., None] * np.array([255, 120, 70]) * 0.55

# stars (upper sky only)
rng = np.random.default_rng(2)
for _ in range(70):
    x, y = rng.integers(0, W), rng.integers(0, int(HZ * 0.62))
    r = rng.integers(1, 3) * S // 2 + 1
    a = rng.uniform(0.35, 0.9)
    img[max(y - r, 0):y + r, max(x - r, 0):x + r] = lerp(img[max(y - r, 0):y + r, max(x - r, 0):x + r], 255, a)

base = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

# --- skyline silhouettes on the horizon ----------------------------------------------------------------------
sky_l = Image.new("RGBA", (W, W), (0, 0, 0, 0))
dl = ImageDraw.Draw(sky_l)
def skyline(x0, x1, seed, tall):
    r = np.random.default_rng(seed)
    x = x0
    while x < x1:
        bw = int(r.integers(int(0.028 * W), int(0.07 * W)))
        bh = int(r.integers(int(0.03 * W), int(tall * W)))
        dl.rectangle([x, HZ - bh, x + bw, HZ + 2], fill=(14, 7, 34, 255))
        # a few lit windows
        for _ in range(int(bw * bh / (W * W) * 900)):
            wx = int(r.integers(x + 4 * S, max(x + bw - 4 * S, x + 5 * S)))
            wy = int(r.integers(HZ - bh + 6 * S, HZ - 4 * S))
            if r.random() < 0.55:
                dl.rectangle([wx, wy, wx + 2 * S, wy + 3 * S], fill=(255, 200, 120, 230))
        x += bw + int(r.integers(0, int(0.012 * W)))
skyline(-10, int(0.40 * W), 11, 0.17)
skyline(int(0.60 * W), W + 10, 23, 0.17)
skyline(int(0.30 * W), int(0.43 * W), 5, 0.09)
skyline(int(0.57 * W), int(0.70 * W), 8, 0.09)
base = Image.alpha_composite(base, sky_l)

# --- road -----------------------------------------------------------------------------------------------------
road = Image.new("RGBA", (W, W), (0, 0, 0, 0))
dr = ImageDraw.Draw(road)
def road_x(t, half):            # x at depth t (0 = horizon, 1 = bottom edge), lateral half-width at the bottom = half
    return VP[0] + half * t
def y_at(t):
    return HZ + t * (W - HZ)
bottom_half = 0.64 * W
dr.polygon([(VP[0] - 2 * S, HZ), (VP[0] + 2 * S, HZ), (VP[0] + bottom_half, W), (VP[0] - bottom_half, W)],
           fill=(11, 9, 26, 255))
# asphalt shading: lighter near the horizon, so the road reads against the ground
shade = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ds = ImageDraw.Draw(shade)
for i in range(0, 200):
    t0, t1 = i / 200, (i + 1) / 200
    a = int(70 * (1 - t0) ** 2.2)
    ds.polygon([(road_x(t0, -bottom_half), y_at(t0)), (road_x(t0, bottom_half), y_at(t0)),
                (road_x(t1, bottom_half), y_at(t1)), (road_x(t1, -bottom_half), y_at(t1))], fill=(120, 40, 140, a))
mask = road.split()[3]
shade.putalpha(Image.fromarray((np.array(shade.split()[3]) * (np.array(mask) > 0)).astype(np.uint8)))
base = Image.alpha_composite(base, road)
base = Image.alpha_composite(base, shade)

# --- neon edge lines with glow --------------------------------------------------------------------------------
def neon_line(p0, p1, color, width, glow_w, glow_a):
    g = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(g).line([p0, p1], fill=color + (255,), width=glow_w)
    g = g.filter(ImageFilter.GaussianBlur(glow_w * 0.9))
    g.putalpha(g.split()[3].point(lambda v: int(v * glow_a)))
    c = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(c).line([p0, p1], fill=color + (255,), width=width)
    return Image.alpha_composite(g, c)

edge = 0.50 * W            # road edge lateral offset at the bottom
for sgn, col in ((-1, (255, 60, 150)), (1, (40, 230, 255))):
    top = (VP[0] + sgn * 2 * S, HZ)
    bot = (VP[0] + sgn * edge, W)
    base = Image.alpha_composite(base, neon_line(top, bot, col, 9 * S, 46 * S, 0.9))
    # second, fainter outer line (underglow spill on the ground)
    base = Image.alpha_composite(base, neon_line((top[0] + sgn * 2 * S, top[1]),
                                                 (VP[0] + sgn * (edge + 0.16 * W), W), col, 3 * S, 26 * S, 0.45))

# --- centre dashes in perspective ----------------------------------------------------------------------------
dash = Image.new("RGBA", (W, W), (0, 0, 0, 0))
dd = ImageDraw.Draw(dash)
t = 0.035
k = 0
while t < 1.05:
    t1 = min(t + 0.055 * (0.35 + t * 1.6) , 1.2)
    w0, w1 = max(1, 2.5 * S * t), max(1, 2.5 * S * t1) * 1.0
    x0, x1 = VP[0], VP[0]
    dd.polygon([(x0 - w0 * 3.2, y_at(t)), (x0 + w0 * 3.2, y_at(t)), (x1 + w1 * 3.2, y_at(t1)), (x1 - w1 * 3.2, y_at(t1))],
               fill=(255, 226, 150, 255))
    t = t1 + 0.05 * (0.35 + t1 * 1.6)
    k += 1
glow_d = dash.filter(ImageFilter.GaussianBlur(10 * S))
glow_d.putalpha(glow_d.split()[3].point(lambda v: int(v * 0.8)))
base = Image.alpha_composite(base, glow_d)
base = Image.alpha_composite(base, dash)

# --- speed streaks across the lower sky/road (diagonal, subtle) ---------------------------------------------
st = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ds2 = ImageDraw.Draw(st)
r = np.random.default_rng(9)
for _ in range(16):
    side = -1 if r.random() < 0.5 else 1
    y = int(r.uniform(HZ + 0.06 * W, W * 0.98))
    t = (y - HZ) / (W - HZ)
    x0 = VP[0] + side * (edge * t + r.uniform(0.04, 0.30) * W * t)
    ln = r.uniform(0.04, 0.12) * W * (0.4 + t)
    ds2.line([(x0, y), (x0 + side * ln * 0.55, y + ln * 0.5)],
             fill=(255, 255, 255, int(70 + 80 * t)), width=max(1, int(2.2 * S * (0.4 + t))))
st = st.filter(ImageFilter.GaussianBlur(1.2 * S))
base = Image.alpha_composite(base, st)

# --- vignette ------------------------------------------------------------------------------------------------
vy, vx = np.mgrid[0:W, 0:W]
vd = np.sqrt(((vx - W / 2) / (W * 0.72)) ** 2 + ((vy - W * 0.52) / (W * 0.72)) ** 2)
vig = np.clip(1.0 - 0.55 * np.clip(vd - 0.55, 0, 1) ** 1.4 * 2.2, 0.35, 1.0)
arr = np.array(base.convert("RGB")).astype(np.float32) * vig[..., None]
out = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").resize((1024, 1024), Image.LANCZOS)
os.makedirs(os.path.dirname(OUT), exist_ok=True)
out.save(OUT, "PNG", optimize=True)     # RGB, no alpha channel: required for iOS app icons
print("wrote", OUT, out.size, out.mode)
