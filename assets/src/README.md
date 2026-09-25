# BunkerDNS README artwork

All artwork is hand-authored SVG. No image generation was used.

- `icon-1024.svg`: standalone vector source. A bunker dome with a viewing slit and door on a ground line, and an antenna still transmitting. It uses the same rounded tile path and 24px white strokes as the other RainnWorks icons.
- `render.py`: writes `hero.svg` and `how-it-works.svg`, then renders all three sources to PNG in `assets/`, plus `icon-preview-16.png` and `icon-preview-32.png` here for checking the icon at small sizes.

## Rebuild

You need Python 3 with Pillow, and `rsvg-convert` (librsvg).

```sh
python3 assets/src/render.py
```

Edit strings and layout in `render.py`, not in the generated SVGs. The names and addresses in the artwork match `config.example.nix` (`example.com`, `192.168.1.100`), and the port and blocking answer match `modules/dns/`.

## Outputs

- `../icon-1024.png`: 1024 × 1024.
- `../hero.png`: 1600 × 900.
- `../how-it-works.png`: 1600 × 600.

Type falls back from Helvetica Neue to Arial or Liberation Sans, and from Menlo to DejaVu Sans Mono, so a rebuild on Linux looks close to one on a Mac but not identical.
