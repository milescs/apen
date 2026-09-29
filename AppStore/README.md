# App Store listing

| Path | What |
| --- | --- |
| `metadata/*.txt` | Listing text for App Store Connect: name, subtitle, promotional text, description, keywords, URLs, copyright, and the notes for App Review |
| `make-screenshots.swift` | Composes the five 2880×1800 store screenshots from the captures in `docs/screenshots` |
| `screenshots/` | Output of the script (gitignored) |

Regenerate the screenshots from the repository root:

```bash
swift AppStore/make-screenshots.swift
```

Limits: name and subtitle 30 characters, promotional text 170, keywords 100 (comma-separated, no words already in
the name or subtitle), description 4,000. App Store Connect rejects some symbols in these fields, including ⌥, so
write "Option-Space".
