import math, importlib.util
spec = importlib.util.spec_from_file_location("g2", "gen2.py"); g2 = importlib.util.module_from_spec(spec)
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()): spec.loader.exec_module(g2)
LEAF, STEM, icon, glyph, toothed_leaf, LEAF_DEFS = g2.LEAF, g2.STEM, g2.icon, g2.glyph, g2.toothed_leaf, g2.LEAF_DEFS
TOOTHED = toothed_leaf()

def line(x1, y1, x2, y2, w, color, extra=""):
    return f'<line x1="{x1:.3f}" y1="{y1:.3f}" x2="{x2:.3f}" y2="{y2:.3f}" stroke="{color}" stroke-width="{w}" stroke-linecap="round" {extra}/>'

def leaf(cx, cy, s, rot, fill, toothed=True):
    return f'<g transform="translate({cx} {cy}) scale({s}) rotate({rot}) translate(-9 -9.3)"><path d="{TOOTHED if toothed else LEAF}" fill="{fill}"/></g>'

def along(p, q, t):
    return (p[0] + (q[0]-p[0])*t, p[1] + (q[1]-p[1])*t)

APEX, LEFT_FOOT, RIGHT_FOOT = (9.0, 4.3), (5.0, 16.3), (13.0, 16.3)

def trunk_detail(foot, side):
    """Soft shading plus aspen bark: dark 'eye' scars and short horizontal lenticels."""
    dx, dy = APEX[0]-foot[0], APEX[1]-foot[1]
    L = math.hypot(dx, dy); nx, ny = -dy/L*side, dx/L*side          # normal pointing to the inner side
    top = along(foot, APEX, 0.72)
    shade = line(foot[0]+nx*0.38, foot[1]+ny*0.38 - 0.1, top[0]+nx*0.38, top[1]+ny*0.38, 0.42, "#EADFF1", 'opacity="0.75"')
    angle = math.degrees(math.atan2(dy, dx))
    eyes = ""
    for t, s in [(0.22, 1.0), (0.58, 0.8)]:
        cx, cy = along(foot, APEX, t)
        eyes += (f'<path d="M {cx-0.55*s:.3f} {cy:.3f} Q {cx:.3f} {cy-0.34*s:.3f} {cx+0.55*s:.3f} {cy:.3f} Q {cx:.3f} {cy+0.34*s:.3f} {cx-0.55*s:.3f} {cy:.3f} Z" '
                 f'fill="#2F2A26" transform="rotate({angle:.1f} {cx:.3f} {cy:.3f})"/>')
    return shade + eyes

def crown(center_fill="url(#gold)"):
    return (leaf(7.35, 3.95, 0.22, -48, "#FFB22E") + leaf(10.65, 3.95, 0.22, 46, "#FFD85A")
            + leaf(9.0, 2.75, 0.26, -4, center_fill))

# ---------- App icon (full detail) ----------
full = (line(6.75, 11.7, 11.25, 11.7, 0.78, "#FFFFFF")
        + line(*LEFT_FOOT, *APEX, 1.6, "#FFFFFF") + line(*RIGHT_FOOT, *APEX, 1.6, "#FBF7FD")
        + trunk_detail(LEFT_FOOT, 1) + trunk_detail(RIGHT_FOOT, -1)
        + crown()
        + leaf(14.55, 13.75, 0.15, 64, "#FFC43D") + leaf(3.75, 8.3, 0.13, -32, "#FFD45C") + leaf(15.3, 6.4, 0.09, 18, "#FFE07A"))
open("F-final.svg", "w").write(icon([(0, "#FFB199"), (0.55, "#FF6F91"), (1, "#9B6CE0")],
                                    f'<g transform="translate(512 520) scale(42) translate(-9 -9.8)">{full}</g>', LEAF_DEFS))

# ---------- Small sizes (16/32 px): bolder strokes, no bark or falling leaves ----------
small = (line(6.6, 11.9, 11.4, 11.9, 1.2, "#FFFFFF") + line(*LEFT_FOOT, *APEX, 2.1, "#FFFFFF") + line(*RIGHT_FOOT, *APEX, 2.1, "#FFFFFF")
         + leaf(9.0, 2.6, 0.34, -4, "url(#gold)", toothed=False))
open("F-small.svg", "w").write(icon([(0, "#FFB199"), (0.55, "#FF6F91"), (1, "#9B6CE0")],
                                    f'<g transform="translate(512 520) scale(44) translate(-9 -9.8)">{small}</g>', LEAF_DEFS))

# ---------- Menu bar template glyphs (18 × 18 pt, black = visible) ----------
def attached_leaf(ax, ay, s, rot, fill):
    """Places a leaf so its stem end sits exactly at (ax, ay)."""
    r = math.radians(rot)
    bx, by = 0, 5.6 * s                      # base offset from the leaf centre before rotation
    ox, oy = bx*math.cos(r) - by*math.sin(r), bx*math.sin(r) + by*math.cos(r)
    return leaf(ax - ox, ay - oy, s, rot, fill, toothed=False)

def mb(extra=""):
    base = (line(4.6, 17.0, 9.0, 6.4, 1.55, "#000") + line(13.4, 17.0, 9.0, 6.4, 1.55, "#000")
            + line(6.45, 12.6, 11.55, 12.6, 1.2, "#000")
            + line(9.0, 6.4, 9.0, 5.3, 0.9, "#000")
            + attached_leaf(8.85, 5.4, 0.27, -52, "#000") + attached_leaf(9.15, 5.4, 0.27, 52, "#000"))
    return glyph(base + extra)
arcs = "".join(f'<path d="M {12.0 + r*math.cos(math.radians(a0)):.3f} {10.2 + r*math.sin(math.radians(a0)):.3f} A {r} {r} 0 0 1 {12.0 + r*math.cos(math.radians(a1)):.3f} {10.2 + r*math.sin(math.radians(a1)):.3f}" fill="none" stroke="#000" stroke-width="1.1" stroke-linecap="round"/>'
               for r, a0, a1 in [(2.7, -40, 40), (4.6, -38, 38)])
dots = "".join(f'<circle cx="{x}" cy="10.4" r="0.8" fill="#000"/>' for x in (13.6, 15.4, 17.2))
open("mb-idle.svg", "w").write(mb())
open("mb-recording.svg", "w").write(mb(arcs))
open("mb-busy.svg", "w").write(mb(dots))
print("ok")
