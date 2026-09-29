import math

SQ = '<clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath>'
def icon(stops, body, defs=""):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">{s}</linearGradient>
<radialGradient id="shine" cx="0.28" cy="0.16" r="0.8"><stop offset="0" stop-color="#fff" stop-opacity="0.35"/><stop offset="0.65" stop-color="#fff" stop-opacity="0"/></radialGradient>
{SQ}{defs}</defs>
<g clip-path="url(#sq)"><rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
<rect x="100" y="100" width="824" height="824" fill="url(#shine)"/>{body}</g></svg>'''

def glyph(body, w=18):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="18" viewBox="0 0 {w} 18">{body}</svg>'

def ellipse_path(cx, cy, rx, ry):
    return f"M {cx-rx:.3f} {cy:.3f} a {rx} {ry} 0 1 0 {2*rx:.3f} 0 a {rx} {ry} 0 1 0 {-2*rx:.3f} 0 Z"

# ---- aspen leaf (tip up), 18-unit space, center ≈ (9, 9.3) ----
LEAF_SEGS = [
    ((9, 1.6), (10.1, 3.2), (11.6, 3.9), (12.9, 5.2)),
    ((12.9, 5.2), (14.2, 6.5), (14.7, 7.9), (14.7, 9.3)),
    ((14.7, 9.3), (14.7, 12.5), (12.2, 14.9), (9, 14.9)),
    ((9, 14.9), (5.8, 14.9), (3.3, 12.5), (3.3, 9.3)),
    ((3.3, 9.3), (3.3, 7.9), (3.8, 6.5), (5.1, 5.2)),
    ((5.1, 5.2), (6.4, 3.9), (7.9, 3.2), (9, 1.6)),
]
LEAF = "M 9 1.6 " + " ".join(f"C {a[0]} {a[1]} {b[0]} {b[1]} {c[0]} {c[1]}" for _, a, b, c in LEAF_SEGS) + " Z"

def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return (u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
            u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1])

def toothed_leaf(teeth=46, amp=0.075):
    """Leaf outline with fine rounded teeth like a real aspen leaf (skips the tip)."""
    pts = []
    for seg in LEAF_SEGS:
        for i in range(60):
            pts.append(cubic(*seg, i / 60))
    n = len(pts)
    out = []
    cx, cy = 9, 9.3
    for i, (x, y) in enumerate(pts):
        s = i / n
        near_tip = min(s, 1 - s) < 0.07
        bump = 0 if near_tip else amp * abs(math.sin(math.pi * teeth * s))
        dx, dy = x - cx, y - cy
        d = math.hypot(dx, dy) or 1
        out.append((x + dx / d * bump, y + dy / d * bump))
    return "M " + " L ".join(f"{x:.3f} {y:.3f}" for x, y in out) + " Z"

STEM = "M 9 14.6 C 9.1 15.8 9.4 16.7 10.0 17.5"
LEAF_DEFS = ('<radialGradient id="gold" cx="0.38" cy="0.32" r="0.75">'
             '<stop offset="0" stop-color="#FFE98A"/><stop offset="0.6" stop-color="#FFC52E"/><stop offset="1" stop-color="#FF9F1C"/></radialGradient>')

def leaf_group(inner, cx, cy, scale, angle, toothed=True):
    shape = toothed_leaf() if toothed else LEAF
    return (f'<g transform="translate({cx} {cy}) scale({scale}) rotate({angle}) translate(-9 -9.3)">'
            f'<path d="{STEM}" fill="none" stroke="#A86B12" stroke-width="0.75" stroke-linecap="round"/>'
            f'<path d="{shape}" fill="url(#gold)"/>'
            f'<ellipse cx="7.1" cy="5.9" rx="1.7" ry="1.0" fill="#fff" opacity="0.35" transform="rotate(-35 7.1 5.9)"/>'
            f'{inner}</g>')

# ---------- D · Chatty Leaf ----------
face = ('<ellipse cx="7.25" cy="9.0" rx="0.78" ry="0.98" fill="#3A2A12"/><ellipse cx="10.75" cy="9.0" rx="0.78" ry="0.98" fill="#3A2A12"/>'
        '<circle cx="7.5" cy="8.62" r="0.27" fill="#fff"/><circle cx="11.0" cy="8.62" r="0.27" fill="#fff"/>'
        '<circle cx="5.95" cy="10.75" r="0.78" fill="#FF7A7A" opacity="0.5"/><circle cx="12.05" cy="10.75" r="0.78" fill="#FF7A7A" opacity="0.5"/>'
        '<clipPath id="mouthD"><path d="M 7.75 10.75 Q 9 13.35 10.25 10.75 Q 9 11.25 7.75 10.75 Z"/></clipPath>'
        '<path d="M 7.75 10.75 Q 9 13.35 10.25 10.75 Q 9 11.25 7.75 10.75 Z" fill="#4A2413"/>'
        '<ellipse cx="9" cy="12.35" rx="0.8" ry="0.45" fill="#FF7A93" clip-path="url(#mouthD)"/>')
breeze = "".join(
    f'<path d="{d}" fill="none" stroke="#fff" stroke-width="{w}" stroke-linecap="round" opacity="{o}"/>'
    for d, w, o in [("M 15.4 6.3 C 16.3 5.8 17.1 6.0 17.6 6.6", 0.5, 0.95),
                    ("M 15.9 8.3 C 17.0 7.9 17.9 8.2 18.4 8.9", 0.5, 0.85),
                    ("M 15.6 10.4 C 16.5 10.1 17.2 10.3 17.6 10.8", 0.5, 0.7)])
small_leaf = (f'<g transform="translate(245 262) scale(9.5) rotate(38) translate(-9 -9.3)">'
              f'<path d="{STEM}" fill="none" stroke="#C47D12" stroke-width="0.9" stroke-linecap="round"/>'
              f'<path d="{LEAF}" fill="#FFB938"/></g>')
bodyD = (small_leaf
         + f'<g transform="translate(470 560) scale(40) translate(-9 -9.3)">{breeze}</g>'
         + leaf_group(face, 470, 560, 40, -14))
open("D-icon.svg", "w").write(icon([(0, "#8BE3FF"), (1, "#2F7CF6")], bodyD, LEAF_DEFS))
glyphD = glyph('<g transform="translate(9 9.2) scale(0.93) rotate(-14) translate(-9 -9.3)">'
               f'<path d="{STEM}" fill="none" stroke="#000" stroke-width="1.0" stroke-linecap="round"/>'
               f'<path d="{LEAF} {ellipse_path(7.25, 9.0, 0.85, 1.05)} {ellipse_path(10.75, 9.0, 0.85, 1.05)} '
               'M 7.6 10.8 Q 9 13.5 10.4 10.8 Q 9 11.35 7.6 10.8 Z" fill-rule="evenodd" fill="#000"/></g>')
open("D-glyph.svg", "w").write(glyphD)

# ---------- E · Whispering Leaf (waveform veins) ----------
WAVE = [(6.1, 1.5), (7.05, 2.9), (8.0, 4.4), (9.0, 5.6), (10.0, 4.4), (10.95, 2.9), (11.9, 1.5)]
def wave(color, width, cy=9.6, scale=1.0):
    return "".join(f'<line x1="{x}" y1="{cy - h*scale/2:.2f}" x2="{x}" y2="{cy + h*scale/2:.2f}" stroke="{color}" stroke-width="{width}" stroke-linecap="round"/>' for x, h in WAVE)
bodyE = (leaf_group("", 512, 540, 42, 12)
         + f'<g transform="translate(512 540) scale(42) translate(-9 -9.3)">{wave("#B45309", 0.62, cy=9.9)}</g>')
open("E-icon.svg", "w").write(icon([(0, "#C4B5FD"), (1, "#7C3AED")], bodyE, LEAF_DEFS))
glyphE = glyph('<g transform="translate(9 9.2) scale(0.93) rotate(12) translate(-9 -9.3)">'
               f'<path d="{STEM}" fill="none" stroke="#000" stroke-width="1.0" stroke-linecap="round"/>'
               f'<path d="{LEAF}" fill="none" stroke="#000" stroke-width="1.2" stroke-linejoin="round"/>'
               + "".join(f'<line x1="{x}" y1="{9.6 - h*0.62/2:.2f}" x2="{x}" y2="{9.6 + h*0.62/2:.2f}" stroke="#000" stroke-width="0.85" stroke-linecap="round"/>'
                         for x, h in WAVE[1:-1]) + '</g>')
open("E-glyph.svg", "w").write(glyphE)

# ---------- F · two trunks forming an A, golden leaves on top ----------
def trunk(x1, y1, x2, y2, w, color):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{w}" stroke-linecap="round"/>'
def bark_eye(cx, cy, rot, s=1.0):
    return (f'<path d="M {cx-0.55*s} {cy} Q {cx} {cy-0.32*s} {cx+0.55*s} {cy} Q {cx} {cy+0.32*s} {cx-0.55*s} {cy} Z" '
            f'fill="#2F2A26" transform="rotate({rot} {cx} {cy})"/>')
def small(cx, cy, s, rot, fill):
    return f'<g transform="translate({cx} {cy}) scale({s}) rotate({rot}) translate(-9 -9.3)"><path d="{LEAF}" fill="{fill}"/></g>'
bodyF_inner = (trunk(5.0, 16.2, 9.0, 4.4, 1.55, "#FFFFFF") + trunk(13.0, 16.2, 9.0, 4.4, 1.55, "#F3F1EE")
               + trunk(6.8, 11.6, 11.2, 11.6, 0.8, "#FFFFFF")
               + bark_eye(6.1, 13.0, -71) + bark_eye(7.5, 8.9, -71, 0.85) + bark_eye(11.9, 13.4, 71) + bark_eye(10.6, 9.4, 71, 0.8)
               + small(9.0, 3.3, 0.23, -20, "url(#gold)") + small(7.4, 4.3, 0.2, -55, "#FFB938") + small(10.7, 4.1, 0.21, 35, "#FFD45C")
               + small(14.6, 13.3, 0.14, 70, "#FFC43D") + small(3.9, 7.8, 0.12, -35, "#FFD45C"))
bodyF = f'<g transform="translate(512 512) scale(42) translate(-9 -9.8)">{bodyF_inner}</g>'
open("F-icon.svg", "w").write(icon([(0, "#FFB199"), (0.55, "#FF6F91"), (1, "#9B6CE0")], bodyF, LEAF_DEFS))
glyphF = glyph('<g transform="translate(0 0.4)">'
               + trunk(5.0, 16.2, 9.0, 5.2, 1.45, "#000") + trunk(13.0, 16.2, 9.0, 5.2, 1.45, "#000")
               + trunk(6.9, 11.8, 11.1, 11.8, 1.0, "#000")
               + small(9.0, 3.3, 0.24, -20, "#000") + '</g>')
open("F-glyph.svg", "w").write(glyphF)
print("ok")
