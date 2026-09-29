# Apen icon

Two white aspen trunks (with the tree's dark "eye" bark marks) lean into an A under a crown of golden aspen
leaves, on a peach-to-pink-to-violet sunset.

| File | What |
| --- | --- |
| `AppIcon.svg` | Full-detail icon (1024 canvas, macOS squircle at 100–924) |
| `AppIcon-small.svg` | Bolder variant used for the 16 and 32 px sizes |
| `gen2.py`, `gen3.py` | Generate the icon SVGs (shared aspen-leaf geometry) |
| `variants2.py` | Generates the menu bar template glyphs (`mb2-idle/recording/busy.svg`, 21 × 18 pt) |
| `render.swift` | Renders an SVG to PNG with NSImage; `shadow` adds the macOS icon drop shadow |

Regenerate: `cd Design && python3 gen3.py && python3 variants2.py && swiftc -O render.swift -o /tmp/render`,
then render `F-final.svg`/`F-small.svg` into `App/Resources/Assets.xcassets/AppIcon.appiconset` (sizes in its
`Contents.json`; `shadow` for 128 px and up) and copy the `mb2-*.svg` files into the `MenuBar*` image sets.
