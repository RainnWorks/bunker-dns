"""Rebuild the README artwork with Python 3 + Pillow and rsvg-convert (librsvg/Pango).

Run: python3 assets/src/render.py

Writes hero.svg and how-it-works.svg here, and renders them plus icon-1024.svg
to PNG in assets/. The strings match config.example.nix (example.com,
192.168.1.100) and the ports in modules/dns/.
"""
from pathlib import Path
import subprocess
from PIL import Image

ROOT = Path(__file__).resolve().parent
SANS = 'Helvetica Neue, Helvetica, Arial, Liberation Sans, sans-serif'
MONO = 'Menlo, IBM Plex Mono, DejaVu Sans Mono, monospace'


def text(x, y, value, size=32, anchor='start', mono=False, opacity=1):
    family = MONO if mono else SANS
    return (f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
            f'font-family="{family}" fill-opacity="{opacity}">{value}</text>')


def path(d, dash=None, opacity=1):
    extra = f' stroke-dasharray="{dash}"' if dash else ''
    return (f'<path d="{d}" fill="none" stroke="white" stroke-width="2.5" '
            f'stroke-linecap="round" stroke-linejoin="round" stroke-opacity="{opacity}"{extra}/>')


def arrow(x1, y, x2):
    return path(f'M{x1} {y} H{x2} M{x2-9} {y-7} L{x2} {y} L{x2-9} {y+7}')


def box(x, y, w, h, r=14):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="none" stroke="white" stroke-width="2.5"/>'


def globe(cx, cy, r):
    out = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="white" stroke-width="2.5"/>'
    out += f'<ellipse cx="{cx}" cy="{cy}" rx="{r*0.45}" ry="{r}" fill="none" stroke="white" stroke-width="2.5"/>'
    out += path(f'M{cx-r} {cy} H{cx+r}')
    out += path(f'M{cx-r*0.87} {cy-r*0.5} H{cx+r*0.87} M{cx-r*0.87} {cy+r*0.5} H{cx+r*0.87}')
    return out


def pi_zero(x, y, w, h):
    """Raspberry Pi Zero 2 W outline: board, mounting holes, 2x20 header, SoC."""
    out = box(x, y, w, h, 18)
    for hx, hy in [(x+24, y+24), (x+w-24, y+24), (x+24, y+h-24), (x+w-24, y+h-24)]:
        out += f'<circle cx="{hx}" cy="{hy}" r="8" fill="none" stroke="white" stroke-width="2.5"/>'
    pitch = (w - 150) / 19
    for row in range(2):
        for col in range(20):
            out += f'<circle cx="{x+75+col*pitch:.1f}" cy="{y+22+row*20}" r="3.5"/>'
    out += box(x+w*0.42, y+h*0.46, h*0.36, h*0.36, 6)
    out += box(x+60, y+h-34, 46, 34, 4) + box(x+w-150, y+h-34, 46, 34, 4)
    return out


def check(x, y):
    return path(f'M{x} {y} L{x+10} {y+10} L{x+28} {y-10}')


def document(w, h, content):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">
<g fill="white" font-weight="400">
<rect width="100%" height="100%" fill="black"/>
{content}
</g></svg>'''


# Hero: the internet is cut, the Pi still answers every homelab name.
hero = globe(230, 360, 110)
hero += path('M140 470 L320 250')
hero += text(230, 540, 'Internet down', 34, 'middle')
hero += path('M360 360 H440', dash='10 12', opacity=0.55)
hero += path('M470 340 L490 380 M480 340 L500 380')
hero += path('M520 360 H570', dash='10 12', opacity=0.55)
hero += pi_zero(590, 285, 360, 170)
hero += text(770, 540, 'dns1 · dns2', 34, 'middle')
hero += text(770, 585, 'still answering', 26, 'middle', opacity=0.6)
names = ['ha.example.com', 'grafana.example.com', 'cameras.example.com']
for index, name in enumerate(names):
    y = 250 + index * 110
    hero += path(f'M970 370 C1020 370 1010 {y} 1060 {y}')
    hero += text(1080, y + 10, name, 30, mono=True)
    hero += text(1080, y + 50, '→ 192.168.1.100', 26, mono=True, opacity=0.6)
    hero += check(1500, y)
hero += text(800, 780, 'Same links, same names. No IPs to remember.', 36, 'middle')

# How it works: CoreDNS answers local names itself, everything else goes on.
flow = box(50, 235, 230, 110) + text(165, 300, 'Your devices', 30, 'middle')
flow += arrow(290, 290, 355)
flow += box(365, 235, 240, 110) + text(485, 300, 'CoreDNS', 36, 'middle')
flow += text(485, 385, 'the front door, :53', 23, 'middle', opacity=0.6)
flow += path('M605 290 H640 M640 150 V430')
flow += arrow(640, 150, 890) + arrow(640, 430, 890)
flow += text(662, 134, '*.example.com', 22, mono=True, opacity=0.8)
flow += text(662, 414, 'everything else', 22, opacity=0.8)
flow += box(900, 95, 300, 110) + text(1050, 145, 'Your homelab', 30, 'middle')
flow += text(1050, 183, '192.168.1.100', 24, 'middle', mono=True, opacity=0.8)
flow += text(1050, 245, 'answered on the Pi, even offline', 23, 'middle', opacity=0.6)
flow += box(900, 375, 250, 110) + text(1025, 440, 'AdGuard Home', 32, 'middle')
flow += text(1025, 525, 'ads and trackers → NXDOMAIN', 23, 'middle', opacity=0.6)
flow += arrow(1160, 430, 1205)
flow += box(1215, 375, 190, 110) + text(1310, 440, 'Unbound', 34, 'middle')
flow += text(1310, 525, 'your own resolver', 23, 'middle', opacity=0.6)
flow += arrow(1415, 430, 1455)
flow += globe(1515, 430, 48)
flow += text(1515, 525, 'Root servers', 23, 'middle', opacity=0.6)

for name, svg in [('hero', document(1600, 900, hero)), ('how-it-works', document(1600, 600, flow))]:
    source = ROOT / f'{name}.svg'
    source.write_text(svg)
    subprocess.run(['rsvg-convert', str(source), '-o', str(ROOT.parent / f'{name}.png')], check=True)

subprocess.run(['rsvg-convert', '--width', '1024', '--height', '1024',
                str(ROOT / 'icon-1024.svg'), '-o', str(ROOT.parent / 'icon-1024.png')], check=True)
with Image.open(ROOT.parent / 'icon-1024.png') as icon:
    for size in (16, 32):
        icon.resize((size, size), Image.Resampling.LANCZOS).save(ROOT / f'icon-preview-{size}.png')
