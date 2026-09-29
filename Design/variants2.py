import math, importlib.util, contextlib, io
spec = importlib.util.spec_from_file_location("g3", "gen3.py"); g3 = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()): spec.loader.exec_module(g3)
line, glyph, LEAF, STEM = g3.line, g3.glyph, g3.LEAF, g3.STEM
W = 21
A = (line(1.9, 17.0, 7.0, 4.4, 1.6, "#000") + line(12.1, 17.0, 7.0, 4.4, 1.6, "#000")
     + line(4.0, 12.4, 10.0, 12.4, 1.2, "#000"))
VEIN = "M 8.4 4.3 L 9.6 4.3 L 9.6 13.2 L 8.4 13.2 Z"
def leaf(cx, cy, s, rot):
    return (f'<g transform="translate({cx} {cy}) scale({s}) rotate({rot}) translate(-9 -9.3)">'
            f'<path d="{STEM}" fill="none" stroke="#000" stroke-width="1.6" stroke-linecap="round"/>'
            f'<path d="{LEAF} {VEIN}" fill-rule="evenodd" fill="#000"/></g>')
L = leaf(16.3, 5.4, 0.5, 36)
arcs = "".join(f'<path d="M {12.0 + r*math.cos(math.radians(a0)):.3f} {13.6 + r*math.sin(math.radians(a0)):.3f} A {r} {r} 0 0 1 {12.0 + r*math.cos(math.radians(a1)):.3f} {13.6 + r*math.sin(math.radians(a1)):.3f}" fill="none" stroke="#000" stroke-width="1.15" stroke-linecap="round"/>'
               for r, a0, a1 in [(2.6, -38, 42), (4.7, -34, 38)])
dots = "".join(f'<circle cx="{x}" cy="15.2" r="0.85" fill="#000"/>' for x in (14.4, 16.5, 18.6))
open("mb2-idle.svg", "w").write(glyph(A + L, W))
open("mb2-recording.svg", "w").write(glyph(A + L + arcs, W))
open("mb2-busy.svg", "w").write(glyph(A + L + dots, W))
